const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const Fonts = zss.Fonts;
const Environment = zss.Environment;
const NodeId = Environment.NodeId;
const StyleComputer = zss.Layout.StyleComputer;
const Unit = zss.math.Unit;
const units_per_pixel = zss.math.units_per_pixel;

const hb = @import("harfbuzz").c;

const BoxGen = zss.Layout.BoxGen;
const BlockComputedSizes = BoxGen.BlockComputedSizes;
const BlockUsedSizes = BoxGen.BlockUsedSizes;
const SctBuilder = BoxGen.StackingContextTreeBuilder;
const SizeMode = BoxGen.SizeMode;

const solve = @import("./solve.zig");
const flow = @import("./flow.zig");

const BoxTree = zss.BoxTree;
const BoxStyle = BoxTree.BoxStyle;

/// Maximum columns supported for auto-layout pre-scan.
/// Tables with more columns fall back to equal distribution.
const MAX_COLUMNS: usize = 32;

/// Average character width in layout units (4 units = 1px).
/// DejaVuSans at 16px averages ~8px per character.
const AVG_CHAR_WIDTH: Unit = 32;

/// Minimum cell width in layout units (12px = 48 units).
/// Applied to cells with no text content (e.g. vote arrow divs).
const MIN_CELL_WIDTH: Unit = 48;

/// Get average character width from the default (sans-serif) font.
/// Falls back to AVG_CHAR_WIDTH if no font is available.
fn getRealCharWidth(fonts: *const Fonts) Unit {
    const handle = fonts.queryFamily(.sans_serif);
    const hb_font = fonts.get(handle) orelse return AVG_CHAR_WIDTH;
    // Get glyph ID for 'x' (U+0078) — representative of average width
    var glyph: u32 = 0;
    if (hb.hb_font_get_glyph(hb_font, 'x', 0, &glyph) == 0) return AVG_CHAR_WIDTH;
    const advance = hb.hb_font_get_glyph_h_advance(hb_font, glyph);
    // Convert from HarfBuzz 26.6 fixed-point to layout units
    const width: Unit = @divFloor(advance * units_per_pixel, 64);
    return if (width > 0) width else AVG_CHAR_WIDTH;
}

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
    /// Default border-spacing (2px = 8 units, CSS default for border-collapse: separate)
    border_spacing: Unit = 8,
    /// Number of <td>/<th> cells in the current row (set by rowElement)
    cells_in_current_row: usize = 0,
    /// Pre-computed column widths from auto-layout algorithm.
    /// Only valid when has_auto_widths is true and index < known_columns.
    column_widths: [MAX_COLUMNS]Unit = [_]Unit{0} ** MAX_COLUMNS,
    /// Whether column_widths has been computed for the current table.
    has_auto_widths: bool = false,
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
        column_widths: [MAX_COLUMNS]Unit,
        has_auto_widths: bool,
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
            .column_widths = ctx.column_widths,
            .has_auto_widths = ctx.has_auto_widths,
        });
        ctx.table_depth += 1;
        ctx.current_row = 0;
        ctx.current_column = 0;
        ctx.max_columns = 0;
        ctx.known_columns = 0;
        ctx.row_x_cursor = ctx.border_spacing;
        ctx.table_width = table_width;
        ctx.explicit_cells_in_row = 0;
        ctx.explicit_width_sum = 0;
        ctx.column_widths = [_]Unit{0} ** MAX_COLUMNS;
        ctx.has_auto_widths = false;
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
        ctx.column_widths = state.column_widths;
        ctx.has_auto_widths = state.has_auto_widths;
        ctx.row_x_cursor = ctx.border_spacing;
    }
    
    pub fn beginRow(ctx: *Context) void {
        // Update known_columns from observed max (keeps pre-computed value if larger)
        if (ctx.current_row >= 1 and ctx.max_columns > ctx.known_columns) {
            ctx.known_columns = ctx.max_columns;
        }
        ctx.current_column = 0;
        ctx.row_x_cursor = ctx.border_spacing; // Start with left border-spacing
        ctx.explicit_cells_in_row = 0;
        ctx.explicit_width_sum = 0;
        ctx.current_row += 1;
    }
    
    pub fn addCell(ctx: *Context) void {
        // Auto-wrap to new row if we've exceeded finalized column count
        if (ctx.known_columns > 0 and ctx.current_column >= ctx.known_columns) {
            ctx.current_column = 0;
            ctx.row_x_cursor = ctx.border_spacing;
            ctx.current_row += 1;
        }
        
        ctx.current_column += 1;
        if (ctx.current_column > ctx.max_columns) {
            ctx.max_columns = ctx.current_column;
        }
    }
    
    /// Advance the row cursor by the given cell width.
    pub fn advanceCursor(ctx: *Context, cell_width: Unit) void {
        ctx.row_x_cursor += cell_width + ctx.border_spacing; // Add spacing between cells
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
        // Available width = table width minus spacing on edges and between cells
        const total_spacing = ctx.border_spacing * @as(Unit, @intCast(cols + 1));
        const available = @max(0, ctx.table_width - total_spacing);
        return @divFloor(available, @as(Unit, @intCast(cols)));
    }

    /// Get the pre-computed width for column `col_idx` (0-based).
    /// Falls back to equal distribution if auto-layout was not computed.
    pub fn getColumnWidth(ctx: *const Context, col_idx: usize) Unit {
        if (ctx.has_auto_widths and col_idx < ctx.known_columns and col_idx < MAX_COLUMNS) {
            return ctx.column_widths[col_idx];
        }
        return ctx.getDefaultCellWidth();
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

/// Count effective columns in a <tr> by summing colspan of each <td>/<th>.
fn countCellsInRow(tr: NodeId, env: *const Environment) usize {
    var count: usize = 0;
    var child = tr.firstChild(env);
    while (child) |ch| : (child = ch.nextSibling(env)) {
        if (nodeTagEql(env, ch, "td") or nodeTagEql(env, ch, "th")) {
            count += env.getNodeProperty(.colspan, ch);
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

// ─── CSS Table Auto-Layout (§17.5.2) ────────────────────────────────────────
//
// Pre-scans the table DOM to estimate min/max content width per column,
// then distributes the table width using the CSS 2.1 automatic layout algorithm:
//   1. Each column gets at least its minimum content width
//   2. Remaining space is distributed proportionally to (max - min)
//
// Text width is estimated from character count × AVG_CHAR_WIDTH. This is
// not pixel-accurate but produces correct column proportions for the common
// case (short labels vs. long text).

/// Min/max content width pair for a single cell.
const CellWidthEstimate = struct {
    /// Width of the longest unbreakable word (cannot be narrower than this).
    min: Unit,
    /// Width of the entire text on one line (preferred width without wrapping).
    max: Unit,
};

/// Estimate the content width of a cell by walking its text nodes.
/// Returns min (longest word) and max (total text) widths.
fn estimateCellContentWidth(cell_node: NodeId, env: *const Environment, char_width: Unit) CellWidthEstimate {
    var stats = TextStats{ .total_len = 0, .max_word_len = 0 };
    collectTextStats(cell_node, env, &stats);

    if (stats.total_len == 0) {
        // No text content — use minimum for non-text elements (images, divs)
        const min_cell_w = @max(MIN_CELL_WIDTH, char_width);
        return .{ .min = min_cell_w, .max = min_cell_w };
    }

    const min_cell_w = @max(MIN_CELL_WIDTH, char_width);
    const min_w = @max(min_cell_w, @as(Unit, @intCast(stats.max_word_len)) * char_width);
    const max_w = @as(Unit, @intCast(stats.total_len)) * char_width;
    return .{ .min = min_w, .max = @max(min_w, max_w) };
}

const TextStats = struct {
    total_len: usize,
    max_word_len: usize,
};

/// Recursively collect text statistics from a subtree.
fn collectTextStats(node: NodeId, env: *const Environment, stats: *TextStats) void {
    var child = node.firstChild(env);
    while (child) |ch| : (child = ch.nextSibling(env)) {
        if (env.getNodeProperty(.category, ch) == .text) {
            const text_id = env.getNodeProperty(.text, ch);
            const text = env.getText(text_id);
            if (text.len == 0) continue;

            // Accumulate total non-whitespace-only text length
            stats.total_len += text.len;

            // Find longest word (split on whitespace)
            var word_start: usize = 0;
            for (text, 0..) |byte, i| {
                if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') {
                    const word_len = i - word_start;
                    if (word_len > stats.max_word_len) stats.max_word_len = word_len;
                    word_start = i + 1;
                }
            }
            // Last word (or only word if no spaces)
            const last_word = text.len - word_start;
            if (last_word > stats.max_word_len) stats.max_word_len = last_word;
        } else {
            // Recurse into child elements
            collectTextStats(ch, env, stats);
        }
    }
}

/// Pre-scan all rows/cells to compute per-column min/max content widths,
/// then distribute table width per CSS 2.1 §17.5.2 auto-layout.
/// Writes results into ctx.column_widths and sets ctx.has_auto_widths.
fn computeAutoColumnWidths(ctx: *Context, table_node: NodeId, env: *const Environment, fonts: *const Fonts) void {
    const char_width = getRealCharWidth(fonts);
    const num_cols = ctx.known_columns;
    if (num_cols == 0 or num_cols > MAX_COLUMNS) return;

    // Accumulate per-column min/max across all rows
    var col_min: [MAX_COLUMNS]Unit = [_]Unit{0} ** MAX_COLUMNS;
    var col_max: [MAX_COLUMNS]Unit = [_]Unit{0} ** MAX_COLUMNS;

    var tr_iter = TrIterator.init(table_node, env);
    while (tr_iter.next(env)) |tr| {
        // Only include rows where cell count matches expected columns.
        // Rows with colspan produce fewer cells and would misalign
        // content to the wrong column index.
        const row_cells = countCellsInRow(tr, env);
        if (row_cells != num_cols) continue;

        var col_idx: usize = 0;
        var cell_child = tr.firstChild(env);
        while (cell_child) |cell| : (cell_child = cell.nextSibling(env)) {
            if (!nodeTagEql(env, cell, "td") and !nodeTagEql(env, cell, "th")) continue;
            if (col_idx >= num_cols) break;

            const colspan: usize = env.getNodeProperty(.colspan, cell);
            const est = estimateCellContentWidth(cell, env, char_width);
            // Distribute content width across spanned columns
            const span = @min(colspan, num_cols - col_idx);
            for (col_idx..col_idx + span) |c_idx| {
                const per_col_min = @divFloor(est.min, @as(Unit, @intCast(span)));
                const per_col_max = @divFloor(est.max, @as(Unit, @intCast(span)));
                if (per_col_min > col_min[c_idx]) col_min[c_idx] = per_col_min;
                if (per_col_max > col_max[c_idx]) col_max[c_idx] = per_col_max;
            }
            col_idx += span;
        }
    }

    // CSS 2.1 §17.5.2 distribution:
    // 1. Each column gets at least its minimum width
    // 2. Remaining space distributed proportionally to (max - min)
    const total_spacing = ctx.border_spacing * @as(Unit, @intCast(num_cols + 1));
    const available = @max(0, ctx.table_width - total_spacing);

    var sum_min: Unit = 0;
    for (0..num_cols) |i| {
        // Ensure every column has at least MIN_CELL_WIDTH
        if (col_min[i] == 0) col_min[i] = MIN_CELL_WIDTH;
        sum_min += col_min[i];
    }

    if (sum_min >= available) {
        // Not enough space — scale down proportionally
        if (sum_min > 0) {
            for (0..num_cols) |i| {
                ctx.column_widths[i] = @divFloor(col_min[i] * available, sum_min);
            }
        }
    } else {
        // Distribute remaining space proportional to (max - min)
        const remaining = available - sum_min;
        var sum_excess: Unit = 0;
        for (0..num_cols) |i| {
            sum_excess += @max(0, col_max[i] - col_min[i]);
        }

        for (0..num_cols) |i| {
            if (sum_excess > 0) {
                const excess = @max(0, col_max[i] - col_min[i]);
                ctx.column_widths[i] = col_min[i] + @divFloor(excess * remaining, sum_excess);
            } else {
                // All columns at min — distribute remaining equally
                ctx.column_widths[i] = col_min[i] + @divFloor(remaining, @as(Unit, @intCast(num_cols)));
            }
        }
    }

    ctx.has_auto_widths = true;
}

pub fn beginMode(box_gen: *BoxGen) !void {
    _ = box_gen;
    // Table mode initialization happens in tableElement
}

fn endMode(box_gen: *BoxGen) void {
    _ = box_gen;
}

/// Handle a table element
pub fn tableElement(box_gen: *BoxGen, node: NodeId, position: BoxTree.BoxStyle.Position) !void {
    const computer = &box_gen.getLayout().computer;
    const containing_block_size = box_gen.containingBlockSize();
    
    // Treat table as a block, but track it in table context
    const sizes = flow.solveAllSizes(computer, position, .{ .normal = containing_block_size.width }, containing_block_size.height);
    const stacking_context = flow.solveStackingContext(computer, position);

    // Read border-spacing from cascade (set by cellspacing HTML attr or CSS)
    const font_specified = computer.getSpecifiedValue(.box_gen, .font);
    const border_spacing_val: Unit = font_specified.border_spacing;

    computer.commitNode(.box_gen);
    
    // Push table state and pre-compute column count from DOM structure.
    // This lets row 1 cells be positioned horizontally (not stacked).
    try box_gen.table_context.pushTable(box_gen.getLayout().allocator, sizes.inline_size_untagged);
    box_gen.table_context.border_spacing = border_spacing_val;
    const env = box_gen.getLayout().inputs.env;
    const dom_columns = countColumnsFromDom(node, env);
    if (dom_columns > 0) {
        box_gen.table_context.known_columns = dom_columns;
        box_gen.table_context.max_columns = dom_columns;

        // Pre-scan cell content to compute auto-layout column widths
        computeAutoColumnWidths(&box_gen.table_context, node, env, box_gen.getLayout().inputs.fonts);
    }
    
    const alloc = box_gen.getLayout().allocator;
    box_gen.bfc_stack.top.? += 1;
    try box_gen.table_context.block_type_stack.append(alloc, .{ .block_type = .table, .bfc_depth = box_gen.bfc_stack.top.? });
    const box_style = BoxTree.BoxStyle{ .outer = .{ .block = .flow }, .position = position };
    const ref = try box_gen.pushFlowBlock(box_style, sizes, .normal, stacking_context, node);
    try box_gen.getLayout().box_tree.setGeneratedBox(node, .{ .block_ref = ref });
    try box_gen.getLayout().pushNode();
}

/// Handle a table-row element
pub fn rowElement(box_gen: *BoxGen, node: NodeId, position: BoxTree.BoxStyle.Position) !void {
    const computer = &box_gen.getLayout().computer;
    const containing_block_size = box_gen.containingBlockSize();
    
    // Count cells in this row and begin tracking
    const env = box_gen.getLayout().inputs.env;
    box_gen.table_context.cells_in_current_row = countCellsInRow(node, env);
    box_gen.table_context.beginRow();
    
    // Treat row as a block
    const sizes = flow.solveAllSizes(computer, position, .{ .normal = containing_block_size.width }, containing_block_size.height);
    const stacking_context = flow.solveStackingContext(computer, position);
    computer.commitNode(.box_gen);
    
    const alloc = box_gen.getLayout().allocator;
    box_gen.bfc_stack.top.? += 1;
    try box_gen.table_context.block_type_stack.append(alloc, .{ .block_type = .row, .bfc_depth = box_gen.bfc_stack.top.? });
    const box_style = BoxTree.BoxStyle{ .outer = .{ .block = .flow }, .position = position };
    const ref = try box_gen.pushFlowBlock(box_style, sizes, .normal, stacking_context, node);
    box_gen.stacks.block_info.top.?.is_table_row = true;
    try box_gen.getLayout().box_tree.setGeneratedBox(node, .{ .block_ref = ref });
    try box_gen.getLayout().pushNode();
}

/// Handle a table-cell element.
/// Positions the cell horizontally using row_x_cursor and sizes it
/// based on CSS width (from HTML width attr injection) or auto-layout widths.
pub fn cellElement(box_gen: *BoxGen, node: NodeId) !void {
    const computer = &box_gen.getLayout().computer;
    const containing_block_size = box_gen.containingBlockSize();
    const table_ctx = &box_gen.table_context;
    
    // Track cell for column counting
    table_ctx.addCell();
    
    // Read colspan from the DOM node
    const env = box_gen.getLayout().inputs.env;
    const colspan: usize = env.getNodeProperty(.colspan, node);
    // Advance column counter for spanned columns (addCell already added 1)
    if (colspan > 1) {
        table_ctx.current_column += colspan - 1;
        if (table_ctx.current_column > table_ctx.max_columns) {
            table_ctx.max_columns = table_ctx.current_column;
        }
    }
    
    // Solve sizes — CSS width (if injected from HTML attr) is picked up here
    var sizes = flow.solveAllSizes(computer, .static, .{ .normal = containing_block_size.width }, containing_block_size.height);
    const stacking_context = flow.solveStackingContext(computer, .static);
    
    // Determine the cell's actual width:
    // If solveAllSizes produced full containing-block width, the cell has
    // no explicit CSS width — use auto-layout or heuristic sizing.
    const resolved_width = sizes.inline_size_untagged;
    const table_w = table_ctx.table_width;
    const has_explicit_width = resolved_width < table_w and table_w > 0;

    // Track explicit-width cells for auto-width distribution
    if (has_explicit_width) {
        table_ctx.explicit_cells_in_row += 1;
        table_ctx.explicit_width_sum += resolved_width;
    }

    // 0-based column index for auto-layout lookup (points to first spanned column)
    const col_idx = if (table_ctx.current_column >= colspan) table_ctx.current_column - colspan else 0;
    // Last cell in the row: use cell count from DOM (handles colspan correctly,
    // unlike nextSibling which may return whitespace text nodes).
    const is_last_cell = table_ctx.current_column >= table_ctx.cells_in_current_row;

    const cell_width = if (has_explicit_width)
        resolved_width // explicit CSS width (from HTML attr or inline style)
    else if (table_w == 0)
        resolved_width // no table width known — can't distribute
    else if (table_ctx.known_columns == 0)
        resolved_width // no column count available yet
    else if (colspan > 1 and table_ctx.has_auto_widths) blk: {
        // Sum column widths + internal spacing for spanned cell
        var total: Unit = 0;
        var k: usize = 0;
        while (k < colspan and col_idx + k < table_ctx.known_columns) : (k += 1) {
            total += table_ctx.getColumnWidth(col_idx + k);
            if (k > 0) total += table_ctx.border_spacing;
        }
        break :blk if (total > 0) total else table_ctx.getDefaultCellWidth();
    } else if (is_last_cell) blk: {
        // Last cell always gets remaining width (handles colspan and rounding)
        const remaining = table_w - table_ctx.row_x_cursor - table_ctx.border_spacing;
        break :blk if (remaining > 0) remaining else table_ctx.getDefaultCellWidth();
    } else if (table_ctx.has_auto_widths)
        table_ctx.getColumnWidth(col_idx)
    else
        table_ctx.getDefaultCellWidth();

    // Apply horizontal positioning whenever column count is known
    if (table_ctx.known_columns > 0) {
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
