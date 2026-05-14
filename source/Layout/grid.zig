const std = @import("std");
const assert = std.debug.assert;
const zss = @import("../zss.zig");
const BoxTree = zss.BoxTree;
const Unit = zss.math.Unit;
const types = zss.values.types;

const Subtree = BoxTree.Subtree;
const flow = @import("./flow.zig");

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
    layout: *@import("../zss.zig").Layout,
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
    const subtree_id = layout.box_gen.currentSubtree();
    return layoutGridChildrenInSubtree(
        layout,
        subtree,
        subtree_id,
        index,
        skip,
        container_width,
        container_height,
        column_gap,
        row_gap,
        template_columns,
        template_rows,
        template_areas,
        child_area_hashes,
        child_count,
    );
}

/// Internal entry that takes the explicit subtree id (so it can be invoked
/// from relayoutSubtree when crossing subtree boundaries via subtree_proxy).
fn layoutGridChildrenInSubtree(
    layout: *@import("../zss.zig").Layout,
    subtree: Subtree.View,
    subtree_id: Subtree.Id,
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
                    const item_w = measureGridItemWidth(layout.box_tree.ptr, subtree, pre_child);
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
            const content_x = box_offsets[child].content_pos.x;
            const content_w = cell_width - content_x * 2;
            const old_w = box_offsets[child].border_size.w;
            if (content_w > 0 and cell_width != old_w) {
                // Two-pass layout: relayoutSubtree propagates resolved widths
                // into the grid item's subtree and re-lays out IFC text.
                const child_skip = subtree.items(.skip)[child];
                relayoutSubtree(layout, subtree, subtree_id, child, content_w);

                // Re-run offsetChildBlocks to recompute vertical positions
                // with margin collapsing and get correct auto_height.
                // NOTE (Bug 1): For flex/grid containers this call is WRONG —
                // relayoutSubtree already ran offsetChildBlocksFlex/layoutGridChildren
                // correctly, but this overwrites those heights with a block-flow
                // traversal that counts whitespace IFC nodes (skipped by flex/grid),
                // inflating min-content rows by ~45px (Wikipedia .vector-page-titlebar).
                // FIX: guard with `!is_flex and !is_grid` using layout.box_gen maps.
                // DEFERRED: apply only together with Bug 2 (#right-nav flex) fix,
                // since these spurious heights compensate for the JS-only CentralNotice
                // banner (105px) that ZenSurf never renders. Fixing alone regresses VP.
                const offset_result = flow.offsetChildBlocks(
                    subtree, child, child_skip, content_w, box_offsets[child].content_pos.y, layout.box_tree.ptr,
                );
                const edge_top = box_offsets[child].content_pos.y;
                const edge_bot = box_offsets[child].border_size.h - edge_top - box_offsets[child].content_size.h;
                box_offsets[child].content_size.h = offset_result.auto_height;
                box_offsets[child].border_size.h = edge_top + offset_result.auto_height + edge_bot;
            } else {
                box_offsets[child].border_size.w = cell_width;
                if (content_w > 0) {
                    box_offsets[child].content_size.w = content_w;
                }
            }
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

    // DIAGNOSTIC: dump grid container track sizes and item widths.
    // Enable with ZSS_DUMP_GRID=1
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
                        // minmax(fixed, fixed): start at MIN. The Maximize Tracks
                        // pass below grows it up to max only if there is space.
                        // Old behaviour clamped to max immediately, which overflows
                        // the container when available_space < sum of maxes
                        // (e.g. Wikipedia's nested .mw-body grid inside
                        // .mw-page-container-inner). CSS Grid §12.6.
                        fixed_total += track.value;
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

    // Second pass — Maximize Tracks (CSS Grid §12.6).
    // Grow minmax(fixed, fixed) tracks from their min toward their max,
    // bounded by the leftover space after pass 1's fixed bases. Runs before
    // fr distribution so fr tracks only consume what minmax-fixed didn't claim.
    // For fully-constrained cases (leftover >= total headroom), every
    // minmax-fixed track reaches its max. For under-constrained cases
    // (leftover < total headroom), distribute proportional to each track's
    // headroom — matches Chrome's behavior on Wikipedia's nested grids.
    {
        var used_for_max: Unit = 0;
        for (0..count) |i| used_for_max += sizes[i];
        const max_leftover = remaining - used_for_max;
        if (max_leftover > 0) {
            var total_headroom: Unit = 0;
            for (0..count) |i| {
                const track = if (i < template.count) template.tracks[i] else types.GridTrackSize{};
                if (track.kind == .minmax and track.max_kind == .fixed) {
                    const headroom = track.max_value - sizes[i];
                    if (headroom > 0) total_headroom += headroom;
                }
            }
            if (total_headroom > 0) {
                if (max_leftover >= total_headroom) {
                    for (0..count) |i| {
                        const track = if (i < template.count) template.tracks[i] else types.GridTrackSize{};
                        if (track.kind == .minmax and track.max_kind == .fixed) {
                            const headroom = track.max_value - sizes[i];
                            if (headroom > 0) {
                                sizes[i] += headroom;
                                fixed_total += headroom;
                            }
                        }
                    }
                } else {
                    for (0..count) |i| {
                        const track = if (i < template.count) template.tracks[i] else types.GridTrackSize{};
                        if (track.kind == .minmax and track.max_kind == .fixed) {
                            const headroom = track.max_value - sizes[i];
                            if (headroom <= 0) continue;
                            const grow_f: f32 = @as(f32, @floatFromInt(max_leftover)) *
                                @as(f32, @floatFromInt(headroom)) / @as(f32, @floatFromInt(total_headroom));
                            const grow: Unit = @intFromFloat(grow_f);
                            sizes[i] += grow;
                            fixed_total += grow;
                        }
                    }
                }
            }
        }
    }

    // Third pass: distribute remaining space to fr tracks
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
fn measureGridItemWidth(box_tree: *BoxTree, subtree: Subtree.View, child_idx: Subtree.Size) Unit {
    const bo = subtree.items(.box_offsets)[child_idx];
    const child_skip = subtree.items(.skip)[child_idx];
    const child_end = child_idx + child_skip;
    const types_slice = subtree.items(.type);

    // IFC container: compute max-content from shaped glyphs
    switch (types_slice[child_idx]) {
        .ifc_container => |ifc_id| {
            const ifc = box_tree.getIfc(ifc_id);
            if (ifc.glyphs.len == 0) return 0;
            const inline_layout = @import("./inline.zig");
            const max_content = inline_layout.computeMaxContentWidth(ifc);
            const left_edge = bo.content_pos.x;
            return max_content + left_edge * 2;
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
            const w = measureGridItemWidth(box_tree, subtree, gc);
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
    const child_based = left_edge + max_child_intrinsic + right_edge;

    // CSS Grid §6.6: a grid item's min-content contribution is the larger of
    // the size derived from its content and the size derived from its own
    // declared sizing (width). border_size.w was set during initial block
    // layout from the cascade, so it reflects an explicit `width` if present.
    // Without this max, items with `width: 15.5rem` and short text content
    // (e.g. Wikipedia's .vector-column-end) shrink the column to ~text
    // width and the explicit declared width is lost.
    return @max(child_based, bo.border_size.w);
}

/// Two-pass layout: after the grid algorithm resolves a grid item's width,
/// walk its entire subtree and re-lay out all content at the correct widths.
///
/// Sets block widths, re-runs splitIntoLineBoxes for IFCs, follows
/// subtree_proxy entries. If a descendant block is itself a grid container
/// (recorded in box_gen.grid_containers), re-runs layoutGridChildren on it
/// at the new container width so nested grids honor the shrunk cell.
/// Height propagation is handled by the caller re-running offsetChildBlocks.
fn relayoutSubtree(
    layout: *@import("../zss.zig").Layout,
    subtree: Subtree.View,
    subtree_id: Subtree.Id,
    block_idx: Subtree.Size,
    available_content_w: Unit,
) void {
    const inline_layout = @import("./inline.zig");
    const box_offsets = subtree.items(.box_offsets);
    const types_slice = subtree.items(.type);
    const bo = &box_offsets[block_idx];

    // Compute edges from OLD sizes before updating.
    const left_edge = bo.content_pos.x;
    const right_edge = bo.border_size.w - bo.content_pos.x - bo.content_size.w;

    // Set new width.
    bo.border_size.w = left_edge + available_content_w + right_edge;
    bo.content_size.w = available_content_w;

    // If the entry node is itself a subtree_proxy, we must follow the proxy
    // into the referenced child subtree — otherwise the block.skip is 1 and
    // the child-walk below does nothing, leaving the proxied content at its
    // stale (often viewport-width) border_size. Reported 2026-04-13: this
    // causes grid-item background widths to overflow ~1279px on Wikipedia.
    switch (types_slice[block_idx]) {
        .subtree_proxy => |child_subtree_id| {
            const proxy_left = bo.content_pos.x;
            const proxy_right = bo.border_size.w - bo.content_pos.x - bo.content_size.w;
            const child_content_w = available_content_w - proxy_left - proxy_right;
            if (child_content_w > 0) {
                const child_subtree = layout.box_tree.ptr.getSubtree(child_subtree_id).view();
                relayoutSubtree(layout, child_subtree, child_subtree_id, 0, child_content_w);

                // Re-run offsetChildBlocks on child subtree for correct heights.
                const child_skip = child_subtree.items(.skip)[0];
                const child_offset_result = flow.offsetChildBlocks(
                    child_subtree, 0, child_skip, child_content_w, child_subtree.items(.box_offsets)[0].content_pos.y, layout.box_tree.ptr,
                );
                const child_root = &child_subtree.items(.box_offsets)[0];
                const child_top = child_root.content_pos.y;
                const child_bot = child_root.border_size.h - child_root.content_pos.y - child_root.content_size.h;
                child_root.content_size.h = child_offset_result.auto_height;
                child_root.border_size.h = child_top + child_offset_result.auto_height + child_bot;

                // Update this proxy's outer height to match the child subtree's new height.
                const proxy_top = bo.content_pos.y;
                const proxy_bot = bo.border_size.h - bo.content_pos.y - bo.content_size.h;
                bo.content_size.h = child_root.border_size.h;
                bo.border_size.h = proxy_top + child_root.border_size.h + proxy_bot;
            }
            return;
        },
        else => {},
    }

    // If this block is a grid container, re-run grid layout at the new
    // available_content_w instead of treating its children as block-flow.
    // The grid will recompute track sizes (so minmax(0,X) shrinks to fit
    // the smaller cell) and re-call relayoutSubtree on each grid item with
    // its updated cell width. Without this nested-grid containers like
    // Wikipedia's .mw-body inside .mw-page-container-inner overflow.
    const grid_key = @import("BoxGen.zig").GridContainerKey{
        .subtree_id = subtree_id,
        .block_idx = block_idx,
    };
    if (layout.box_gen.grid_containers.getPtr(grid_key)) |info| {
        const block_skip2 = subtree.items(.skip)[block_idx];
        // Reset the grid's child-area-hash count is preserved as-is; children
        // haven't been re-generated.
        const new_height = layoutGridChildrenInSubtree(
            layout,
            subtree,
            subtree_id,
            block_idx,
            block_skip2,
            available_content_w,
            null,
            info.column_gap,
            info.row_gap,
            info.columns,
            info.rows,
            info.areas,
            &info.child_area_hashes,
            info.child_count,
        );
        // Update this block's content height to match the regrown grid.
        const top_e = bo.content_pos.y;
        const bot_e = bo.border_size.h - bo.content_pos.y - bo.content_size.h;
        bo.content_size.h = new_height;
        bo.border_size.h = top_e + new_height + bot_e;
        return;
    }

    // If this block is a flex container, re-run flex layout at the new
    // available_content_w so nested flex containers inside grid cells get
    // correct item widths. Then manually walk children and recursively
    // relayout each one using its updated content width.
    const flex_key = @import("BoxGen.zig").FlexContainerKey{
        .subtree_id = subtree_id,
        .block_idx = block_idx,
    };
    if (layout.box_gen.flex_containers.getPtr(flex_key)) |info| {
        const block_skip = subtree.items(.skip)[block_idx];
        const container_height = bo.content_size.h;
        const new_height = flow.offsetChildBlocksFlex(
            layout,
            subtree,
            subtree_id,
            block_idx,
            block_skip,
            available_content_w,
            container_height,
            info.justify,
            info.align_items,
            info.flex_gap,
            info.flex_is_column,
            info.flex_wrap,
        );
        const top_e = bo.content_pos.y;
        const bot_e = bo.border_size.h - bo.content_pos.y - bo.content_size.h;
        bo.content_size.h = new_height;
        bo.border_size.h = top_e + new_height + bot_e;

        const block_end = block_idx + block_skip;
        var child = block_idx + 1;
        while (child < block_end) {
            const c_skip = subtree.items(.skip)[child];
            defer child += c_skip;
            if (subtree.items(.out_of_flow)[child]) {
                continue;
            }
            switch (types_slice[child]) {
                .block => {
                    const child_bo = box_offsets[child];
                    const child_content_w = child_bo.content_size.w;
                    if (child_content_w > 0) {
                        relayoutSubtree(layout, subtree, subtree_id, child, child_content_w);
                    }
                },
                .ifc_container => {
                    // offsetChildBlocksFlex already re-lays out IFCs via
                    // relayoutIfcAtWidth when their width changed.
                },
                .subtree_proxy => |child_subtree_id| {
                    const proxy_bo = box_offsets[child];
                    const child_content_w = proxy_bo.content_size.w;
                    if (child_content_w > 0) {
                        const child_subtree = layout.box_tree.ptr.getSubtree(child_subtree_id).view();
                        relayoutSubtree(layout, child_subtree, child_subtree_id, 0, child_content_w);

                        // Re-run offsetChildBlocks on child subtree for correct heights.
                        const child_skip2 = child_subtree.items(.skip)[0];
                        const child_offset_result = flow.offsetChildBlocks(
                            child_subtree, 0, child_skip2, child_content_w, child_subtree.items(.box_offsets)[0].content_pos.y, layout.box_tree.ptr,
                        );
                        const child_root = &child_subtree.items(.box_offsets)[0];
                        const child_top = child_root.content_pos.y;
                        const child_bot = child_root.border_size.h - child_root.content_pos.y - child_root.content_size.h;
                        child_root.content_size.h = child_offset_result.auto_height;
                        child_root.border_size.h = child_top + child_offset_result.auto_height + child_bot;

                        // Update the proxy to match child subtree's new height.
                        const proxy_top = proxy_bo.content_pos.y;
                        const proxy_bot = proxy_bo.border_size.h - proxy_bo.content_pos.y - proxy_bo.content_size.h;
                        const proxy_bo_mut = &box_offsets[child];
                        proxy_bo_mut.content_size.h = child_root.border_size.h;
                        proxy_bo_mut.border_size.h = proxy_top + child_root.border_size.h + proxy_bot;
                    }
                },
            }
        }
        return;
    }

    // Walk children.
    const block_skip = subtree.items(.skip)[block_idx];
    const block_end = block_idx + block_skip;

    var gc: Subtree.Size = block_idx + 1;
    while (gc < block_end) {
        const gc_skip = subtree.items(.skip)[gc];
        defer gc += gc_skip;


        if (subtree.items(.out_of_flow)[gc]) {
            continue;
        }

        switch (types_slice[gc]) {
            .block => {
                const child_bo = box_offsets[gc];
                const child_left = child_bo.content_pos.x;
                const child_right = child_bo.border_size.w - child_bo.content_pos.x - child_bo.content_size.w;
                const child_content_w = available_content_w - child_left - child_right;
                if (child_content_w > 0) {
                    relayoutSubtree(layout, subtree, subtree_id, gc, child_content_w);
                }
            },
            .ifc_container => |ifc_id| {
                const ifc = layout.box_tree.ptr.getIfc(ifc_id);
                ifc.line_boxes.clearRetainingCapacity();
                const result = inline_layout.splitIntoLineBoxes(layout, subtree, ifc, available_content_w, ifc.persisted_parent_float_ctx) catch continue;

                var effective_height = result.height;
                if (ifc.line_boxes.items.len <= 1) {
                    if (result.longest_line_box_length <= 60) {
                        effective_height = 0;
                    }
                }

                const ifc_bo = &box_offsets[gc];
                ifc_bo.border_size.w = available_content_w;
                ifc_bo.content_size.w = available_content_w;
                ifc_bo.border_size.h = effective_height;
                ifc_bo.content_size.h = effective_height;
            },
            .subtree_proxy => |child_subtree_id| {
                const proxy_bo = box_offsets[gc];
                const proxy_left = proxy_bo.content_pos.x;
                const proxy_right = proxy_bo.border_size.w - proxy_bo.content_pos.x - proxy_bo.content_size.w;
                const child_content_w = available_content_w - proxy_left - proxy_right;
                if (child_content_w > 0) {
                    const child_subtree = layout.box_tree.ptr.getSubtree(child_subtree_id).view();
                    relayoutSubtree(layout, child_subtree, child_subtree_id, 0, child_content_w);

                    // Re-run offsetChildBlocks on child subtree for correct heights.
                    const child_skip = child_subtree.items(.skip)[0];
                    const child_offset_result = flow.offsetChildBlocks(
                        child_subtree, 0, child_skip, child_content_w, child_subtree.items(.box_offsets)[0].content_pos.y, layout.box_tree.ptr,
                    );
                    const child_root = &child_subtree.items(.box_offsets)[0];
                    const child_top = child_root.content_pos.y;
                    const child_bot = child_root.border_size.h - child_root.content_pos.y - child_root.content_size.h;
                    child_root.content_size.h = child_offset_result.auto_height;
                    child_root.border_size.h = child_top + child_offset_result.auto_height + child_bot;

                    // Update the proxy to match child subtree's new height.
                    const proxy_top = proxy_bo.content_pos.y;
                    const proxy_bot = proxy_bo.border_size.h - proxy_bo.content_pos.y - proxy_bo.content_size.h;
                    const proxy_bo_mut = &box_offsets[gc];
                    proxy_bo_mut.content_size.h = child_root.border_size.h;
                    proxy_bo_mut.border_size.h = proxy_top + child_root.border_size.h + proxy_bot;
                }
            },
        }
    }
}