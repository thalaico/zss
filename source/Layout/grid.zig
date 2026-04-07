const std = @import("std");
const assert = std.debug.assert;
const zss = @import("../zss.zig");
const BoxTree = zss.BoxTree;
const Unit = zss.math.Unit;
const types = zss.values.types;

const Subtree = BoxTree.Subtree;

/// Resolved track sizes in pixels (layout units).
const MAX_TRACKS = types.MAX_GRID_TRACKS;

/// Lay out children of a grid container using CSS Grid Level 1 (subset).
///
/// Supports:
/// - Explicit track sizing: fixed, fr, min-content, auto, minmax()
/// - Named grid areas (grid-template-areas + grid-area)
/// - Auto-placement for children without explicit grid-area
///
/// Returns the total height of the grid in layout units.
pub fn layoutGridChildren(
    _: *@import("../zss.zig").Layout,
    subtree: Subtree.View,
    index: Subtree.Size,
    skip: Subtree.Size,
    container_width: Unit,
    container_height: ?Unit,
    column_gap: Unit,
    row_gap: Unit,
    template_columns: types.GridTrackList,
    template_rows: types.GridTrackList,
    template_areas: types.GridAreas,
    child_area_hashes: []const u32,
    child_count: u8,
) Unit {
    const skips = subtree.items(.skip);
    const out_of_flow_flags = subtree.items(.out_of_flow);
    const box_offsets = subtree.items(.box_offsets);
    const offsets = subtree.items(.offset);
    const block_types = subtree.items(.type);
    const end = index + skip;

    // --- Phase 1: Determine grid dimensions ---
    var num_cols: u8 = template_columns.count;
    var num_rows: u8 = template_rows.count;

    // If no explicit template, count children for auto-grid
    if (num_cols == 0) {
        // Count in-flow children
        var inflow_count: u32 = 0;
        var child = index + 1;
        while (child < end) {
            if (!out_of_flow_flags[child]) inflow_count += 1;
            child += skips[child];
        }
        if (inflow_count == 0) return 0;
        // Default: single column if no template
        num_cols = 1;
        num_rows = @intCast(@min(inflow_count, MAX_TRACKS));
    }

    // Derive grid dimensions from named areas when explicit tracks are missing.
    // E.g., grid-template-columns: 1fr; grid-template-areas: 'a' 'b' 'c';
    // gives 1 column and 3 rows even though grid-template-rows isn't set.
    if (template_areas.count > 0) {
        var max_area_row: u8 = 0;
        var max_area_col: u8 = 0;
        for (template_areas.entries[0..template_areas.count]) |area| {
            if (area.row_end > max_area_row) max_area_row = area.row_end;
            if (area.col_end > max_area_col) max_area_col = area.col_end;
        }
        if (max_area_row > num_rows) num_rows = max_area_row;
        if (max_area_col > num_cols) num_cols = max_area_col;
    }

    if (num_cols == 0) num_cols = 1;
    if (num_rows == 0) num_rows = 1;

    // --- Phase 1b: Pre-place items and measure intrinsic column widths ---
    // CSS Grid §12.4: Intrinsic track sizes must be resolved before fr distribution.
    // We need to know which items go in which columns to measure min-content widths.
    var intrinsic_col_sizes: [MAX_TRACKS]Unit = [_]Unit{0} ** MAX_TRACKS;
    var has_intrinsic_tracks = false;
    for (0..num_cols) |i| {
        const track = if (i < template_columns.count) template_columns.tracks[i] else types.GridTrackSize{};
        if (track.kind == .min_content or track.kind == .max_content or track.kind == .auto or
            (track.kind == .minmax and (track.max_kind == .auto or track.max_kind == .min_content or track.max_kind == .max_content)))
        {
            has_intrinsic_tracks = true;
            break;
        }
    }

    if (has_intrinsic_tracks) {
        // Pre-scan: determine column placement for each grid item
        var pre_idx: u8 = 0;
        var pre_child = index + 1;
        while (pre_child < end and pre_idx < child_count) {
            if (out_of_flow_flags[pre_child] or block_types[pre_child] == .ifc_container) {
                pre_child += skips[pre_child];
                continue;
            }
            var col: u8 = 0;
            if (pre_idx < child_count) {
                const area_hash = child_area_hashes[pre_idx];
                if (area_hash != 0) {
                    if (template_areas.findArea(area_hash)) |area| {
                        col = area.col_start;
                    }
                }
            }
            pre_idx +|= 1;

            // Check if this column needs intrinsic measurement
            if (col < num_cols) {
                const track = if (col < template_columns.count) template_columns.tracks[col] else types.GridTrackSize{};
                const needs_measure = track.kind == .min_content or track.kind == .max_content or track.kind == .auto or
                    (track.kind == .minmax and (track.max_kind == .auto or track.max_kind == .min_content or track.max_kind == .max_content));
                if (needs_measure) {
                    // Measure intrinsic width of this item
                    const item_w = measureGridItemWidth(subtree, pre_child);
                    if (item_w > intrinsic_col_sizes[col]) {
                        intrinsic_col_sizes[col] = item_w;
                    }
                }
            }
            pre_child += skips[pre_child];
        }
    }

    // --- Phase 2: Resolve column track sizes ---
    var col_sizes: [MAX_TRACKS]Unit = [_]Unit{0} ** MAX_TRACKS;
    resolveTrackSizes(&col_sizes, num_cols, &template_columns, container_width, column_gap, &intrinsic_col_sizes);

    // --- Phase 3: Resolve row track sizes ---
    // For rows, we need content heights. First pass: use specified sizes.
    // min-content and auto rows will be sized after children are laid out.
    const available_height = container_height orelse 0;
    var row_sizes: [MAX_TRACKS]Unit = [_]Unit{0} ** MAX_TRACKS;
    resolveTrackSizes(&row_sizes, num_rows, &template_rows, available_height, row_gap, null);

    // --- Phase 4: Place children and size rows ---
    // Record placement info so we can reposition after row sizes are finalized.
    // Row sizes start at 0 for auto/min-content/fr tracks and are updated as
    // children are placed, but children placed in DOM order may reference rows
    // whose occupants haven't been processed yet. A second positioning pass
    // using final row sizes is required.
    const PlacementInfo = struct {
        child_idx: Subtree.Size, // index into subtree
        placed_row: u8,
        placed_col: u8,
        span_rows: u8,
        span_cols: u8,
    };
    var placements: [128]PlacementInfo = undefined;
    var placement_count: u8 = 0;

    var auto_row: u8 = 0;
    var auto_col: u8 = 0;
    var child_index: u8 = 0; // index into child_area_hashes


    var child = index + 1;
    while (child < end and child_index < child_count) {
        // Skip out-of-flow and anonymous inline formatting context boxes.
        // IFC containers are generated for whitespace text between block children
        // and must not be treated as grid items.
        if (out_of_flow_flags[child] or block_types[child] == .ifc_container) {
            child += skips[child];
            continue;
        }

        var placed_row: u8 = auto_row;
        var placed_col: u8 = auto_col;
        var span_rows: u8 = 1;
        var span_cols: u8 = 1;

        // Try named area placement
        var named_placement = false;
        if (child_index < child_count) {
            const area_hash = child_area_hashes[child_index];
            if (area_hash != 0) {
                if (template_areas.findArea(area_hash)) |area| {
                    placed_row = area.row_start;
                    placed_col = area.col_start;
                    span_rows = area.row_end - area.row_start;
                    span_cols = area.col_end - area.col_start;
                    named_placement = true;

                    // Extend grid if named area exceeds explicit dimensions
                    if (area.row_end > num_rows and area.row_end <= MAX_TRACKS) {
                        for (num_rows..area.row_end) |r| {
                            row_sizes[r] = 0;
                        }
                        num_rows = area.row_end;
                    }
                    if (area.col_end > num_cols and area.col_end <= MAX_TRACKS) {
                        num_cols = area.col_end;
                    }
                }
            }
        }
        child_index +|= 1;

        if (!named_placement) {
            // Auto-placement: advance to next empty cell
            if (auto_row >= num_rows) {
                if (num_rows < MAX_TRACKS) {
                    num_rows += 1;
                    row_sizes[num_rows - 1] = 0;
                } else {
                    child += skips[child];
                    continue;
                }
            }

            placed_row = auto_row;
            placed_col = auto_col;

            // Advance auto-placement cursor
            auto_col += 1;
            if (auto_col >= num_cols) {
                auto_col = 0;
                auto_row += 1;
            }
        }

        // Set child width from column track sizes
        var cell_width: Unit = 0;
        for (0..span_cols) |sc| {
            const col_idx = placed_col + @as(u8, @intCast(sc));
            if (col_idx < num_cols) {
                cell_width += col_sizes[col_idx];
                if (sc > 0) cell_width += column_gap;
            }
        }
        if (cell_width > 0) {
            box_offsets[child].border_size.w = cell_width;
            const content_x = box_offsets[child].content_pos.x;
            const content_w = cell_width - content_x * 2;
            if (content_w > 0) {
                box_offsets[child].content_size.w = content_w;
            }
            // TODO: IFC relayout for text reflow at new column width.
            // Currently causes VP regression. Grid item children that are
            // block containers need their nested content re-laid-out.
        }

        // Track actual child height for auto-sized rows.
        // Only use non-spanning items (span_rows == 1) for row sizing.
        // Spanning items' contributions are complex (CSS Grid §11.5) and
        // would require distributing their height across spanned tracks.
        // Skipping them is safe when non-spanning items exist in those rows.
        const child_border_h = box_offsets[child].border_pos.y + box_offsets[child].border_size.h;
        if (span_rows == 1) {
            if (row_sizes[placed_row] == 0 or (template_rows.count > placed_row and template_rows.tracks[placed_row].kind == .auto) or (template_rows.count > placed_row and template_rows.tracks[placed_row].kind == .min_content)) {
                // Auto or min-content row: grow to fit content
                if (child_border_h > row_sizes[placed_row]) {
                    row_sizes[placed_row] = child_border_h;
                }
            }
        }

        // Record placement for repositioning pass
        if (placement_count < 128) {
            placements[placement_count] = .{
                .child_idx = child,
                .placed_row = placed_row,
                .placed_col = placed_col,
                .span_rows = span_rows,
                .span_cols = span_cols,
            };
            placement_count += 1;
        }

        // Set X position (column positions don't change)
        var x: Unit = 0;
        for (0..placed_col) |c| {
            x += col_sizes[c];
            x += column_gap;
        }
        offsets[child].x = x;

        child += skips[child];
    }

    // --- Phase 5: Reposition children using finalized row sizes ---
    // Row sizes are now correct (auto-sized from content). Recompute Y positions.
    for (placements[0..placement_count]) |p| {
        var y: Unit = 0;
        for (0..p.placed_row) |r| {
            y += row_sizes[r];
            y += row_gap;
        }
        offsets[p.child_idx].y = y;
    }

    // --- Phase 6: Compute total grid height ---
    var total_height: Unit = 0;
    for (0..num_rows) |r| {
        total_height += row_sizes[r];
        if (r > 0) total_height += row_gap;
    }

    return total_height;
}

/// Resolve track sizes for one dimension (columns or rows).
/// Handles: fixed, fr, min-content, max-content, auto, minmax().
fn resolveTrackSizes(
    sizes: *[MAX_TRACKS]Unit,
    count: u8,
    template: *const types.GridTrackList,
    available_space: Unit,
    gap_size: Unit,
    intrinsic_sizes: ?*const [MAX_TRACKS]Unit,
) void {
    if (count == 0) return;

    // Total gap space
    const total_gaps = gap_size * @as(Unit, @intCast(if (count > 1) count - 1 else 0));
    var remaining = available_space - total_gaps;
    if (remaining < 0) remaining = 0;

    // First pass: resolve fixed sizes and count fr units
    var total_fr: f32 = 0;
    var fixed_total: Unit = 0;
    var fr_count: u8 = 0;
    var auto_count: u8 = 0;

    for (0..count) |i| {
        const track = if (i < template.count) template.tracks[i] else types.GridTrackSize{};
        switch (track.kind) {
            .fixed => {
                sizes[i] = track.value;
                fixed_total += track.value;
            },
            .fr => {
                total_fr += track.frValue();
                fr_count += 1;
                sizes[i] = 0; // Will be resolved in second pass
            },
            .min_content, .auto => {
                auto_count += 1;
                // Use pre-measured intrinsic width if available
                const intrinsic = if (intrinsic_sizes) |is| is[i] else 0;
                sizes[i] = intrinsic;
                fixed_total += intrinsic;
            },
            .max_content => {
                const intrinsic = if (intrinsic_sizes) |is| is[i] else 0;
                sizes[i] = intrinsic;
                fixed_total += intrinsic;
                auto_count += 1;
            },
            .minmax => {
                // minmax(min, max): resolve based on max track sizing function
                sizes[i] = track.value; // start at min value
                switch (track.max_kind) {
                    .fr => {
                        // minmax(fixed, fr): participate in fr distribution (pass 2)
                        fixed_total += track.value;
                        total_fr += track.maxFrValue();
                        fr_count += 1;
                    },
                    .fixed => {
                        // minmax(fixed, fixed): clamp to max value
                        const max_val = track.max_value;
                        sizes[i] = if (max_val > track.value) max_val else track.value;
                        fixed_total += sizes[i];
                    },
                    .auto, .min_content, .max_content => {
                        // minmax(fixed, auto/content): use intrinsic width with floor
                        const intrinsic = if (intrinsic_sizes) |is| is[i] else 0;
                        const resolved = @max(intrinsic, track.value);
                        sizes[i] = resolved;
                        fixed_total += resolved;
                        auto_count += 1;
                    },
                    .minmax => {
                        // Nested minmax not valid CSS; treat as fixed at min
                        fixed_total += track.value;
                    },
                }
            },
        }
    }

    // Second pass: distribute remaining space to fr tracks
    const space_for_flex = remaining - fixed_total;
    if (space_for_flex > 0 and total_fr > 0) {
        for (0..count) |i| {
            const track = if (i < template.count) template.tracks[i] else types.GridTrackSize{};
            switch (track.kind) {
                .fr => {
                    const fraction = track.frValue();
                    sizes[i] = @intFromFloat(@as(f32, @floatFromInt(space_for_flex)) * fraction / total_fr);
                },
                .minmax => {
                    if (track.max_kind == .fr) {
                        const fraction = track.maxFrValue();
                        const fr_size: Unit = @intFromFloat(@as(f32, @floatFromInt(space_for_flex)) * fraction / total_fr);
                        // minmax: use max of min and fr allocation
                        if (fr_size > sizes[i]) {
                            sizes[i] = fr_size;
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Third pass: auto tracks may grow if remaining space exists
    // Don't shrink below intrinsic sizes already set in pass 1.
    if (auto_count > 0) {
        var used: Unit = 0;
        for (0..count) |i| used += sizes[i];
        const auto_space = remaining - used;
        if (auto_space > 0) {
            const per_auto = @divFloor(auto_space, @as(Unit, auto_count));
            for (0..count) |i| {
                const track = if (i < template.count) template.tracks[i] else types.GridTrackSize{};
                const is_auto = track.kind == .auto or track.kind == .min_content or track.kind == .max_content;
                const is_minmax_auto = track.kind == .minmax and (track.max_kind == .auto or track.max_kind == .min_content or track.max_kind == .max_content);
                if (is_auto or is_minmax_auto) {
                    const floor = if (is_minmax_auto) track.value else 0;
                    sizes[i] = @max(per_auto, @max(sizes[i], floor));
                }
            }
        }
    }
}

/// Measure the intrinsic content width of a grid item.
/// Uses the same approach as flex measureContentMainSize:
/// for blocks, recurse to find the maximum content width of children;
/// for IFC containers, measure the widest line.
fn measureGridItemWidth(subtree: Subtree.View, child_idx: Subtree.Size) Unit {
    const bo = subtree.items(.box_offsets)[child_idx];
    const child_skip = subtree.items(.skip)[child_idx];
    const child_end = child_idx + child_skip;
    const types_slice = subtree.items(.type);

    // IFC container: measure widest line
    switch (types_slice[child_idx]) {
        .ifc_container => |_| {
            // For IFC, border_size.w is the container width. We want content width.
            // Use content_size.w which was set during layout.
            return bo.border_size.w;
        },
        else => {},
    }

    // Block container: recurse to find max intrinsic child width
    var max_child_intrinsic: Unit = 0;
    var has_children = false;
    var gc = child_idx + 1;
    while (gc < child_end) {
        if (!subtree.items(.out_of_flow)[gc]) {
            has_children = true;
            const w = measureGridItemWidth(subtree, gc);
            max_child_intrinsic = @max(max_child_intrinsic, w);
        }
        gc += subtree.items(.skip)[gc];
    }

    if (!has_children) {
        return bo.border_size.w;
    }

    // Add this block's own edges
    const left_edge = bo.content_pos.x;
    const right_edge = bo.border_size.w - bo.content_pos.x - bo.content_size.w;
    return left_edge + max_child_intrinsic + right_edge;
}

/// Re-layout IFC text content inside a grid item at a new width.
/// Mirrors flow.relayoutIfcAtWidth but adapted for grid item children.
fn relayoutGridItemIfc(layout: *@import("../zss.zig").Layout, subtree: Subtree.View, item_idx: Subtree.Size, new_content_w: Unit) void {
    const inline_layout = @import("./inline.zig");
    const types_slice = subtree.items(.type);
    const item_skip = subtree.items(.skip)[item_idx];
    const item_end = item_idx + item_skip;

    var gc = item_idx + 1;
    while (gc < item_end) {
        if (!subtree.items(.out_of_flow)[gc]) {
            switch (types_slice[gc]) {
                .ifc_container => |ifc_id| {
                    const ifc = layout.box_tree.ptr.getIfc(ifc_id);
                    ifc.line_boxes.clearRetainingCapacity();
                    const result = inline_layout.splitIntoLineBoxes(layout, subtree, ifc, new_content_w) catch {
                        break;
                    };
                    const bo = &subtree.items(.box_offsets)[gc];
                    bo.border_size.w = new_content_w;
                    bo.content_size.w = new_content_w;
                    bo.border_size.h = result.height;
                    bo.content_size.h = result.height;
                },
                else => {
                    // Recurse into block children to find nested IFCs
                    const child_bo = subtree.items(.box_offsets)[gc];
                    const child_content_x = child_bo.content_pos.x;
                    const child_content_w = new_content_w - child_content_x * 2;
                    if (child_content_w > 0) {
                        relayoutGridItemIfc(layout, subtree, gc, child_content_w);
                    }
                },
            }
        }
        gc += subtree.items(.skip)[gc];
    }
}