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

    if (num_cols == 0) num_cols = 1;
    if (num_rows == 0) num_rows = 1;

    // --- Phase 2: Resolve column track sizes ---
    var col_sizes: [MAX_TRACKS]Unit = [_]Unit{0} ** MAX_TRACKS;
    resolveTrackSizes(&col_sizes, num_cols, &template_columns, container_width, column_gap);

    // --- Phase 3: Resolve row track sizes ---
    // For rows, we need content heights. First pass: use specified sizes.
    // min-content and auto rows will be sized after children are laid out.
    const available_height = container_height orelse 0;
    var row_sizes: [MAX_TRACKS]Unit = [_]Unit{0} ** MAX_TRACKS;
    resolveTrackSizes(&row_sizes, num_rows, &template_rows, available_height, row_gap);

    // --- Phase 4: Place children in grid cells ---
    // Build a placement map: which child goes where.
    // Children with grid-area names go to their named area.
    // Others auto-place in row-major order.
    var auto_row: u8 = 0;
    var auto_col: u8 = 0;
    var child_index: u8 = 0; // index into child_area_hashes

    var child = index + 1;
    while (child < end) {
        if (out_of_flow_flags[child]) {
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

        // --- Phase 5: Size and position the child ---
        // Calculate x position from track sizes + gaps
        var x: Unit = 0;
        for (0..placed_col) |c| {
            x += col_sizes[c];
            x += column_gap;
        }

        // Calculate y position from track sizes + gaps
        var y: Unit = 0;
        for (0..placed_row) |r| {
            y += row_sizes[r];
            y += row_gap;
        }

        // Calculate cell width (spanning columns)
        var cell_width: Unit = 0;
        for (0..span_cols) |sc| {
            const col_idx = placed_col + @as(u8, @intCast(sc));
            if (col_idx < num_cols) {
                cell_width += col_sizes[col_idx];
                if (sc > 0) cell_width += column_gap;
            }
        }

        // Calculate cell height (spanning rows)
        var cell_height: Unit = 0;
        for (0..span_rows) |sr| {
            const row_idx = placed_row + @as(u8, @intCast(sr));
            if (row_idx < num_rows) {
                cell_height += row_sizes[row_idx];
                if (sr > 0) cell_height += row_gap;
            }
        }

        // Position child
        offsets[child].x = x;
        offsets[child].y = y;

        // Resize child to fit grid cell
        if (cell_width > 0) {
            box_offsets[child].border_size.w = cell_width;
            const content_x = box_offsets[child].content_pos.x;
            const content_w = cell_width - content_x * 2;
            if (content_w > 0) {
                box_offsets[child].content_size.w = content_w;
            }
        }

        // Track actual child height for auto-sized rows
        const child_border_h = box_offsets[child].border_pos.y + box_offsets[child].border_size.h;
        if (row_sizes[placed_row] == 0 or (template_rows.count > placed_row and template_rows.tracks[placed_row].kind == .auto) or (template_rows.count > placed_row and template_rows.tracks[placed_row].kind == .min_content)) {
            // Auto or min-content row: grow to fit content
            if (child_border_h > row_sizes[placed_row]) {
                row_sizes[placed_row] = child_border_h;
            }
        }

        child += skips[child];
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
                sizes[i] = 0; // Will be resolved from content
            },
            .max_content => {
                sizes[i] = 0; // Will be resolved from content
                auto_count += 1;
            },
            .minmax => {
                // Use min as base, will grow with fr/auto later
                sizes[i] = track.value; // min value (fixed)
                fixed_total += track.value;
                if (track.max_kind == .fr) {
                    total_fr += track.maxFrValue();
                    fr_count += 1;
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

    // Third pass: auto tracks get equal share of any remaining space
    if (auto_count > 0) {
        var used: Unit = 0;
        for (0..count) |i| used += sizes[i];
        const auto_space = remaining - used;
        if (auto_space > 0) {
            const per_auto = @divFloor(auto_space, @as(Unit, auto_count));
            for (0..count) |i| {
                const track = if (i < template.count) template.tracks[i] else types.GridTrackSize{};
                if (track.kind == .auto or track.kind == .min_content or track.kind == .max_content) {
                    sizes[i] = per_auto;
                }
            }
        }
    }
}
