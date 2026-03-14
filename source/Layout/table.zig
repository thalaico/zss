const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const Environment = zss.Environment;
const NodeId = Environment.NodeId;
const StyleComputer = zss.Layout.StyleComputer;
const Unit = zss.math.Unit;

const BoxGen = zss.Layout.BoxGen;
const BlockComputedSizes = BoxGen.BlockComputedSizes;
const BlockUsedSizes = BoxGen.BlockUsedSizes;
const SctBuilder = BoxGen.StackingContextTreeBuilder;
const SizeMode = BoxGen.SizeMode;

const solve = @import("./solve.zig");
const flow = @import("./flow.zig");

const BoxTree = zss.BoxTree;
const BoxStyle = BoxTree.BoxStyle;

/// Table layout context
pub const Context = struct {
    pub const BlockType = enum { table, row, cell };
 
    /// Entry pairing a block type with the bfc_stack depth at push time.
    /// Used to correlate null node pops with the correct table element.
    pub const BlockEntry = struct {
        block_type: BlockType,
        bfc_depth: usize,
    };
    
    /// Current table depth (0 = not in table, >0 = in table)
    table_depth: usize = 0,
    /// Current row being processed
    current_row: usize = 0,
    /// Current column index within row
    current_column: usize = 0,
    /// Maximum columns seen across all rows (discovered incrementally)
    max_columns: usize = 0,
    /// Finalized column count (set after first row completes)
    known_columns: usize = 0,
    /// Table width (containing block size)
    table_width: Unit = 0,
    /// Cumulative x position within current row (layout units)
    row_x_cursor: Unit = 0,
    /// Count of cells with explicit widths in the current row
    explicit_cells_in_row: usize = 0,
    /// Sum of explicit widths in the current row (layout units)
    explicit_width_sum: Unit = 0,
    /// Stack of table states for nested tables
    stack: std.ArrayListUnmanaged(State) = .{},
    /// Stack tracking which table element type pushed each flow block.
    /// Each entry records the bfc_stack depth at push time so null node
    /// processing can match pops to the correct table element.
    block_type_stack: std.ArrayListUnmanaged(BlockEntry) = .{},
    
    pub const State = struct {
        row: usize,
        column: usize,
        max_columns: usize,
        known_columns: usize,
        table_width: Unit,
    };
    
    pub fn init(_: Allocator) Context {
        return .{};
    }
    
    pub fn deinit(ctx: *Context, allocator: Allocator) void {
        ctx.block_type_stack.deinit(allocator);
        ctx.stack.deinit(allocator);
    }
    
    pub fn pushTable(ctx: *Context, allocator: Allocator, table_width: Unit) !void {
        try ctx.stack.append(allocator, .{
            .row = ctx.current_row,
            .column = ctx.current_column,
            .max_columns = ctx.max_columns,
            .known_columns = ctx.known_columns,
            .table_width = ctx.table_width,
        });
        ctx.table_depth += 1;
        ctx.current_row = 0;
        ctx.current_column = 0;
        ctx.max_columns = 0;
        ctx.known_columns = 0;
        ctx.row_x_cursor = 0;
        ctx.table_width = table_width;
        ctx.explicit_cells_in_row = 0;
        ctx.explicit_width_sum = 0;
    }
    
    pub fn popTable(ctx: *Context) void {
        if (ctx.stack.items.len == 0) return;
        const state = ctx.stack.pop().?;
        ctx.table_depth -= 1;
        ctx.current_row = state.row;
        ctx.current_column = state.column;
        ctx.max_columns = state.max_columns;
        ctx.known_columns = state.known_columns;
        ctx.table_width = state.table_width;
        ctx.row_x_cursor = 0;
    }
    
    pub fn beginRow(ctx: *Context) void {
        // Update known_columns from observed max (keeps pre-computed value if larger)
        if (ctx.current_row >= 1 and ctx.max_columns > ctx.known_columns) {
            ctx.known_columns = ctx.max_columns;
        }
        ctx.current_column = 0;
        ctx.row_x_cursor = 0;
        ctx.explicit_cells_in_row = 0;
        ctx.explicit_width_sum = 0;
        ctx.current_row += 1;
    }
    
    pub fn addCell(ctx: *Context) void {
        // Auto-wrap to new row if we've exceeded finalized column count
        if (ctx.known_columns > 0 and ctx.current_column >= ctx.known_columns) {
            ctx.current_column = 0;
            ctx.row_x_cursor = 0;
            ctx.current_row += 1;
        }
        
        ctx.current_column += 1;
        if (ctx.current_column > ctx.max_columns) {
            ctx.max_columns = ctx.current_column;
        }
    }
    
    /// Advance the row cursor by the given cell width.
    pub fn advanceCursor(ctx: *Context, cell_width: Unit) void {
        ctx.row_x_cursor += cell_width;
    }
    
    /// Get the default cell width for auto-width cells.
    /// Uses known_columns after row 1, else divides table width by max seen so far.
    pub fn getDefaultCellWidth(ctx: *const Context) Unit {
        const cols: usize = if (ctx.known_columns > 0)
            ctx.known_columns
        else if (ctx.max_columns > 0)
            ctx.max_columns
        else
            1;
        return @divFloor(ctx.table_width, @as(Unit, @intCast(cols)));
    }
};

/// Check if a node's tag name matches the given string.
/// Creates a fresh iterator each time (eql consumes the iterator).
fn nodeTagEql(env: *const Environment, node: NodeId, tag: []const u8) bool {
    if (env.getNodeProperty(.category, node) != .element) return false;
    const type_info = env.getNodeProperty(.type, node);
    var it = env.type_names.iterator(@intFromEnum(type_info.name));
    return it.eql(tag);
}

/// Count columns by finding the first <tr> with <td>/<th> children.
/// Walks through <tbody>/<thead>/<tfoot> wrappers. Skips empty/spacer rows.
/// Returns 0 if no suitable <tr> is found (caller falls back to incremental counting).
fn countColumnsFromDom(table_node: NodeId, env: *const Environment) usize {
    var tr_iter = TrIterator.init(table_node, env);
    while (tr_iter.next(env)) |tr| {
        const count = countCellsInRow(tr, env);
        if (count > 0) return count;
    }
    return 0;
}

/// Count <td>/<th> children of a <tr> node.
fn countCellsInRow(tr: NodeId, env: *const Environment) usize {
    var count: usize = 0;
    var child = tr.firstChild(env);
    while (child) |ch| : (child = ch.nextSibling(env)) {
        if (nodeTagEql(env, ch, "td") or nodeTagEql(env, ch, "th")) {
            count += 1;
        }
    }
    return count;
}

/// Iterates through <tr> elements in a table, descending into <tbody>/<thead>/<tfoot>.
const TrIterator = struct {
    /// Current child of the table (or section element)
    current: ?NodeId,
    /// If inside a section, the section's next sibling to resume from
    section_resume: ?NodeId,

    fn init(table_node: NodeId, env: *const Environment) TrIterator {
        return .{
            .current = table_node.firstChild(env),
            .section_resume = null,
        };
    }

    fn next(self: *TrIterator, env: *const Environment) ?NodeId {
        while (true) {
            const node = self.current orelse {
                // End of section children — resume at table level
                if (self.section_resume) |resume_node| {
                    self.current = resume_node;
                    self.section_resume = null;
                    continue;
                }
                return null;
            };
            self.current = node.nextSibling(env);

            if (nodeTagEql(env, node, "tr")) return node;

            // Descend into section elements
            if (nodeTagEql(env, node, "tbody") or
                nodeTagEql(env, node, "thead") or
                nodeTagEql(env, node, "tfoot"))
            {
                // Save resume point and descend
                self.section_resume = self.current;
                self.current = node.firstChild(env);
            }
        }
    }
};

pub fn beginMode(box_gen: *BoxGen) !void {
    _ = box_gen;
    // Table mode initialization happens in tableElement
}

fn endMode(box_gen: *BoxGen) void {
    _ = box_gen;
}

/// Handle a table element
pub fn tableElement(box_gen: *BoxGen, node: NodeId) !void {
    const computer = &box_gen.getLayout().computer;
    const containing_block_size = box_gen.containingBlockSize();
    
    // Treat table as a block, but track it in table context
    const sizes = flow.solveAllSizes(computer, .static, .{ .normal = containing_block_size.width }, containing_block_size.height);
    const stacking_context = flow.solveStackingContext(computer, .static);
    computer.commitNode(.box_gen);
    
    // Push table state and pre-compute column count from DOM structure.
    // This lets row 1 cells be positioned horizontally (not stacked).
    try box_gen.table_context.pushTable(box_gen.getLayout().allocator, sizes.inline_size_untagged);
    const env = box_gen.getLayout().inputs.env;
    const dom_columns = countColumnsFromDom(node, env);
    if (dom_columns > 0) {
        box_gen.table_context.known_columns = dom_columns;
        box_gen.table_context.max_columns = dom_columns;
    }
    
    const alloc = box_gen.getLayout().allocator;
    box_gen.bfc_stack.top.? += 1;
    try box_gen.table_context.block_type_stack.append(alloc, .{ .block_type = .table, .bfc_depth = box_gen.bfc_stack.top.? });
    const box_style = BoxTree.BoxStyle{ .outer = .{ .block = .flow }, .position = .static };
    const ref = try box_gen.pushFlowBlock(box_style, sizes, .normal, stacking_context, node);
    try box_gen.getLayout().box_tree.setGeneratedBox(node, .{ .block_ref = ref });
    try box_gen.getLayout().pushNode();
}

/// Handle a table-row element
pub fn rowElement(box_gen: *BoxGen, node: NodeId) !void {
    const computer = &box_gen.getLayout().computer;
    const containing_block_size = box_gen.containingBlockSize();
    
    // Begin new row
    box_gen.table_context.beginRow();
    
    // Treat row as a block
    const sizes = flow.solveAllSizes(computer, .static, .{ .normal = containing_block_size.width }, containing_block_size.height);
    const stacking_context = flow.solveStackingContext(computer, .static);
    computer.commitNode(.box_gen);
    
    const alloc = box_gen.getLayout().allocator;
    box_gen.bfc_stack.top.? += 1;
    try box_gen.table_context.block_type_stack.append(alloc, .{ .block_type = .row, .bfc_depth = box_gen.bfc_stack.top.? });
    const box_style = BoxTree.BoxStyle{ .outer = .{ .block = .flow }, .position = .static };
    const ref = try box_gen.pushFlowBlock(box_style, sizes, .normal, stacking_context, node);
    try box_gen.getLayout().box_tree.setGeneratedBox(node, .{ .block_ref = ref });
    try box_gen.getLayout().pushNode();
}

/// Handle a table-cell element.
/// Positions the cell horizontally using row_x_cursor and sizes it
/// based on CSS width (from HTML width attr injection) or equal distribution.
pub fn cellElement(box_gen: *BoxGen, node: NodeId) !void {
    const computer = &box_gen.getLayout().computer;
    const containing_block_size = box_gen.containingBlockSize();
    const table_ctx = &box_gen.table_context;
    
    // Track cell for column counting
    table_ctx.addCell();
    
    // Solve sizes — CSS width (if injected from HTML attr) is picked up here
    var sizes = flow.solveAllSizes(computer, .static, .{ .normal = containing_block_size.width }, containing_block_size.height);
    const stacking_context = flow.solveStackingContext(computer, .static);
    
    // Determine the cell's actual width:
    // If solveAllSizes produced full containing-block width, the cell has
    // no explicit CSS width — use heuristic sizing.
    const resolved_width = sizes.inline_size_untagged;
    const table_w = table_ctx.table_width;
    const has_explicit_width = resolved_width < table_w and table_w > 0;
    const first_row = table_ctx.known_columns == 0;  // fallback: no pre-computed columns

    // Track explicit-width cells for auto-width distribution
    if (has_explicit_width) {
        table_ctx.explicit_cells_in_row += 1;
        table_ctx.explicit_width_sum += resolved_width;
    }

    const cell_width = if (has_explicit_width)
        resolved_width // explicit CSS width (from HTML attr or inline style)
    else if (table_w == 0)
        resolved_width // no table width known — can't distribute
    else if (first_row)
        resolved_width // no column count available — stack vertically
    else blk: {
        // known_columns is available (from DOM pre-scan or row 1 observation).
        // Last expected column OR actual last cell in the row gets remaining.
        const env = box_gen.getLayout().inputs.env;
        const is_last_expected = table_ctx.current_column >= table_ctx.known_columns;
        const is_actual_last = node.nextSibling(env) == null;
        if (is_last_expected or is_actual_last) {
            const remaining = table_w - table_ctx.row_x_cursor;
            break :blk if (remaining > 0) remaining else resolved_width;
        } else if (table_ctx.explicit_cells_in_row > 0) {
            // Other cells have explicit widths — distribute remaining among auto cells.
            // This handles tables like HN's header: <td width=18px> <td auto> <td auto>
            const auto_cols = table_ctx.known_columns - table_ctx.explicit_cells_in_row;
            const available = table_w - table_ctx.explicit_width_sum;
            if (auto_cols > 0 and available > 0)
                break :blk @divFloor(available, @as(Unit, @intCast(auto_cols)))
            else
                break :blk resolved_width;
        } else {
            // No explicit widths — use small default to favor the last column.
            const small_default: Unit = 20 * 4; // 20px
            break :blk @min(small_default, table_ctx.getDefaultCellWidth());
        }
    };

    // Apply horizontal positioning for row 2+ (after column count is known).
    // First row keeps default layout — cells stack vertically.
    if (!first_row) {
        sizes.inline_size_untagged = cell_width;
        sizes.margin_inline_start_untagged = table_ctx.row_x_cursor;
    }

    // Advance cursor by full border-box width (content + padding + border)
    const cell_border_box = cell_width + sizes.padding_inline_start + sizes.padding_inline_end + sizes.border_inline_start + sizes.border_inline_end;
    table_ctx.advanceCursor(cell_border_box);
    
    computer.commitNode(.box_gen);
    
    const alloc = box_gen.getLayout().allocator;
    box_gen.bfc_stack.top.? += 1;
    try table_ctx.block_type_stack.append(alloc, .{ .block_type = .cell, .bfc_depth = box_gen.bfc_stack.top.? });
    const box_style = BoxTree.BoxStyle{ .outer = .{ .block = .flow }, .position = .static };
    const ref = try box_gen.pushFlowBlock(box_style, sizes, .normal, stacking_context, node);
    try box_gen.getLayout().box_tree.setGeneratedBox(node, .{ .block_ref = ref });
    try box_gen.getLayout().pushNode();
}

pub fn nullNode(box_gen: *BoxGen, element_type: enum { table, row, cell, unknown }) ?void {
    switch (element_type) {
        .table => {
            box_gen.table_context.popTable();
            box_gen.popFlowBlock(.normal);
            box_gen.getLayout().popNode();
        },
        .row => {
            box_gen.popFlowBlock(.normal);
            box_gen.getLayout().popNode();
        },
        .cell => {
            box_gen.popFlowBlock(.normal);
            box_gen.getLayout().popNode();
        },
        .unknown => {
            box_gen.popFlowBlock(.normal);
            box_gen.getLayout().popNode();
        },
    }
    return null;
}

pub fn afterFlowMode() noreturn {
    unreachable;
}

pub fn beforeInlineMode() SizeMode {
    return .normal;
}

pub fn afterInlineMode() void {}

pub fn afterStfMode() noreturn {
    unreachable;
}
