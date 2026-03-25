const std = @import("std");
const assert = std.debug.assert;
const zss = @import("../zss.zig");
const BoxTree = zss.BoxTree;
const Unit = zss.math.Unit;

const Subtree = BoxTree.Subtree;

/// Layouts children of a grid container in a simple grid pattern.
/// For now, this creates a hardcoded 3-column grid with auto-placement.
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
) Unit {
    _ = container_height; // Not used yet
    
    const skips = subtree.items(.skip);
    const out_of_flow_flags = subtree.items(.out_of_flow);
    const box_offsets = subtree.items(.box_offsets);
    const offsets = subtree.items(.offset);
    const end = index + skip;

    // Hardcoded for now: 3 columns
    const num_columns = 3;
    const column_width = @divFloor(container_width - (column_gap * (num_columns - 1)), num_columns);

    // Count children (excluding out-of-flow)
    var child_count: usize = 0;
    {
        var child = index + 1;
        while (child < end) {
            if (!out_of_flow_flags[child]) {
                child_count += 1;
            }
            child += skips[child];
        }
    }

    if (child_count == 0) {
        return 0;
    }

    // Position each child in the grid
    var current_child: usize = 0;
    var max_row_height: Unit = 0;
    var current_row_y: Unit = 0;

    {
        var child = index + 1;
        while (child < end) {
            if (!out_of_flow_flags[child]) {
                const col = current_child % num_columns;
                const row = current_child / num_columns;

                // Calculate position
                const x = @as(Unit, @intCast(col)) * (column_width + column_gap);
                const y = current_row_y;

                // Set child offset
                offsets[child].x = x;
                offsets[child].y = y;

                // Resize child to fit in grid cell
                box_offsets[child].border_size.w = column_width;
                box_offsets[child].content_size.w = column_width - 
                    box_offsets[child].content_pos.x * 2;

                // Track max height in current row
                const child_height = box_offsets[child].border_pos.y + box_offsets[child].border_size.h;
                if (col == 0) {
                    // Start of new row
                    if (row > 0) {
                        current_row_y += max_row_height + row_gap;
                        offsets[child].y = current_row_y;
                    }
                    max_row_height = child_height;
                } else {
                    max_row_height = @max(max_row_height, child_height);
                }

                current_child += 1;
            }
            child += skips[child];
        }
    }

    // Return total grid height
    return current_row_y + max_row_height;
}
