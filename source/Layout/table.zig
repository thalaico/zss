//! Tables: CSS 2.1 §17 with the automatic table layout algorithm
//! (§17.5.2.2) and the column width distribution of CSS Tables 3 (§3.9-3.10,
//! the algorithm Chromium's AutoTableLayout implements).
//!
//! Table parts are identified by their computed `display` (§17.2), never by
//! tag name. Each part is generated as an ordinary flow block
//! (`flow.blockElement`: styles, pseudo-elements and stacking contexts as
//! for any block) and tagged with its `Role`; the table records its structure
//! while its descendants are generated. When the table element closes
//! (`layoutTable`, called from `BoxGen.popFlowBlock`):
//!
//! 1. rows are ordered (header groups, then body rows, then footer groups)
//!    and cells get grid slots, honouring colspan and rowspan;
//! 2. every cell's min-content and max-content border-box width is measured
//!    from its generated boxes (`intrinsic.zig`);
//! 3. column measures follow from single-column cells, then spanning cells
//!    in order of increasing span distribute their excess;
//! 4. the table's used width is its specified width (at least the minimum)
//!    or, for `width: auto`, the maximum width clamped to the available
//!    space (never below the minimum);
//! 5. that width is distributed to columns by interpolating between the
//!    min-content, min-percentage, min-specified and max-content guesses,
//!    and excess beyond the max-content guess goes to auto columns in
//!    proportion to their max-content widths;
//! 6. each cell is relaid out at its column width (`relayout.zig`), rows
//!    take the height of their tallest cell (§17.5.3), rowspans extend
//!    their last row, and rows, groups and cells are positioned with
//!    `border-spacing` (separated borders model, §17.6.1).
//!
//! The collapsing border model (§17.6.2) resolves every grid edge between
//! the cells' and the table's borders (§17.6.2.1: hidden wins, then the
//! wider border, then the style order double > solid > dashed > dotted >
//! ridge > outset > groove > inset, then cell over table); each cell's box
//! takes half of each resolved edge and the table's box the outer halves,
//! as Chromium lays them out. Row and row-group borders do not take part
//! yet.
//!
//! Not supported yet (documented, not approximated): anonymous table
//! objects (§17.2.1: a row outside a table, or text directly in a row, is
//! laid out as a plain block), row/row-group borders in the collapsing
//! model, painting collapsed borders other than solid, column and
//! column-group widths and backgrounds, `table-layout: fixed`,
//! `inline-table`, caption-side bottom, vertical-align: baseline (treated as
//! top), and distributing a specified table height to rows.
const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const NodeId = zss.Environment.NodeId;
const Unit = zss.math.Unit;
const math = zss.math;
const types = zss.values.types;
const solve = @import("./solve.zig");
const Layout = zss.Layout;
const BoxTree = zss.BoxTree;
const BoxStyle = BoxTree.BoxStyle;
const Subtree = BoxTree.Subtree;
const BoxGen = Layout.BoxGen;
const BlockUsedSizes = BoxGen.BlockUsedSizes;

const flow = @import("./flow.zig");
const intrinsic = @import("./intrinsic.zig");
const relayout = @import("./relayout.zig");

/// A block's part in a table.
pub const Role = enum(u3) { none, table, row_group, row, cell, caption };

const GroupKind = enum(u2) { header, body, footer };

const Group = struct {
    /// The row-group block; null for the anonymous group of rows that are
    /// direct children of the table.
    block: ?Subtree.Size,
    kind: GroupKind,
    rows: std.ArrayListUnmanaged(u32) = .{},
};

const Row = struct {
    block: Subtree.Size,
    cells: std.ArrayListUnmanaged(u32) = .{},
    /// Specified `height` (content-box), if any.
    height: ?Unit,
};

const Cell = struct {
    block: Subtree.Size,
    node: NodeId,
    /// The cell's own border widths (left, right, top, bottom) before the
    /// collapsing model replaced them with half edges.
    own_borders: ?[4]Unit = null,
    colspan: u32,
    /// 0 = to the end of the row group (HTML).
    rowspan: u32,
    vertical_align: zss.values.types.VerticalAlign,
    /// Specified `height` (content-box), if any.
    height: ?Unit,
    // Filled by layout:
    row: u32 = 0,
    col: u32 = 0,
    span_rows: u32 = 1,
};

const Column = struct {
    min: Unit = 0,
    max: Unit = 0,
    /// A cell in this column has a fixed `width`.
    constrained: bool = false,
    /// Largest percentage `width` of a cell in this column (0..1), 0 = none.
    percent: f32 = 0,
    width: Unit = 0,
};

/// The recorded structure of one table, kept after layout so a relayout of
/// an enclosing box can rerun the table algorithm at a new width.
pub const Table = struct {
    block: Subtree.Size,
    subtree_id: Subtree.Id,
    spacing_h: Unit,
    spacing_v: Unit,
    groups: std.ArrayListUnmanaged(Group) = .{},
    rows: std.ArrayListUnmanaged(Row) = .{},
    cells: std.ArrayListUnmanaged(Cell) = .{},
    captions: std.ArrayListUnmanaged(Subtree.Size) = .{},
    /// The width of `width: auto`/fixed resolution: true when the table's
    /// specified width is not auto.
    specified_width: bool,
    node: NodeId,
    collapse: bool,
    /// Collapsing model: the table's own border widths (left, right, top,
    /// bottom) as specified, and the outer half edges its box takes.
    own_borders: [4]Unit = .{ 0, 0, 0, 0 },
    outer: [4]Unit = .{ 0, 0, 0, 0 },
    outer_colors: [4]math.Color = .{ .transparent, .transparent, .transparent, .transparent },

    fn deinit(t: *Table, allocator: Allocator) void {
        for (t.groups.items) |*g| g.rows.deinit(allocator);
        for (t.rows.items) |*r| r.cells.deinit(allocator);
        t.groups.deinit(allocator);
        t.rows.deinit(allocator);
        t.cells.deinit(allocator);
        t.captions.deinit(allocator);
    }
};

const TableKey = struct { subtree_id: Subtree.Id, block: Subtree.Size };

pub const Context = struct {
    /// Tables whose elements are open, innermost last.
    open: std.ArrayListUnmanaged(*Table) = .{},
    /// Laid-out tables, for relayout.
    finished: std.AutoHashMapUnmanaged(TableKey, *Table) = .{},

    pub fn init(_: Allocator) Context {
        return .{};
    }

    pub fn deinit(ctx: *Context, allocator: Allocator) void {
        for (ctx.open.items) |t| {
            t.deinit(allocator);
            allocator.destroy(t);
        }
        var it = ctx.finished.valueIterator();
        while (it.next()) |t| {
            t.*.deinit(allocator);
            allocator.destroy(t.*);
        }
        ctx.open.deinit(allocator);
        ctx.finished.deinit(allocator);
    }
};

/// Generate the box of a block-level element whose computed `display` is a
/// table display type, if its parent allows it. Returns false when the
/// element is not a table part here (the caller lays it out as a plain
/// block — anonymous table objects are not generated).
pub fn dispatch(box_gen: *BoxGen, node: NodeId, box_style: BoxStyle) !bool {
    const layout = box_gen.getLayout();
    const box_style_values = layout.computer.getComputedValue(.box_gen, .box_style) orelse return false;
    const display = box_style_values.display;
    const parent_role: Role = if (box_gen.stacks.block_info.top) |info| info.table_role else .none;
    const open_table: ?*Table = if (box_gen.table_context.open.items.len > 0) box_gen.table_context.open.items[box_gen.table_context.open.items.len - 1] else null;

    const role: Role = switch (display) {
        .table => .table,
        .table_row_group, .table_header_group, .table_footer_group => if (parent_role == .table) .row_group else return false,
        .table_row => if (parent_role == .table or parent_role == .row_group) .row else return false,
        .table_cell => if (parent_role == .row) .cell else return false,
        .table_caption => if (parent_role == .table) .caption else return false,
        else => return false,
    };

    const allocator = layout.allocator;
    // Values that must be read while the element is the current node.
    const font = layout.computer.getSpecifiedValue(.box_gen, .font);
    const vertical_align = layout.computer.getSpecifiedValue(.box_gen, .box_style).vertical_align;
    const content_width = layout.computer.getSpecifiedValue(.box_gen, .content_width);

    try flow.blockElement(box_gen, node, .flow, box_style.position);
    const info = &box_gen.stacks.block_info.top.?;
    info.table_role = role;
    const block_index = box_gen.stacks.block.top.?.index;
    const specified_height = info.sizes.get(.block_size);

    switch (role) {
        .table => {
            // Tables establish a block formatting context (CSS 2.1 §17.4).
            info.is_bfc = true;
            const t = try allocator.create(Table);
            t.* = .{
                .block = block_index,
                .subtree_id = box_gen.currentSubtree(),
                // §17.6.2: no spacing between cells in the collapsing model.
                .spacing_h = if (font.border_collapse == .collapse) 0 else font.border_spacing.h,
                .spacing_v = if (font.border_collapse == .collapse) 0 else font.border_spacing.v,
                .specified_width = content_width.width != .auto,
                .node = node,
                .collapse = font.border_collapse == .collapse,
            };
            try box_gen.table_context.open.append(allocator, t);
        },
        .row_group => {
            const t = open_table.?;
            try t.groups.append(allocator, .{
                .block = block_index,
                .kind = switch (display) {
                    .table_header_group => .header,
                    .table_footer_group => .footer,
                    else => .body,
                },
            });
        },
        .row => {
            const t = open_table.?;
            const group_index: u32 = blk: {
                if (parent_role == .row_group) break :blk @intCast(t.groups.items.len - 1);
                // Consecutive rows directly in the table share one anonymous
                // body group.
                if (t.groups.items.len > 0 and t.groups.items[t.groups.items.len - 1].block == null) {
                    break :blk @intCast(t.groups.items.len - 1);
                }
                try t.groups.append(allocator, .{ .block = null, .kind = .body });
                break :blk @intCast(t.groups.items.len - 1);
            };
            try t.rows.append(allocator, .{ .block = block_index, .height = specified_height });
            try t.groups.items[group_index].rows.append(allocator, @intCast(t.rows.items.len - 1));
        },
        .cell => {
            // Cells establish a block formatting context (CSS 2.1 §17.4).
            info.is_bfc = true;
            const t = open_table.?;
            const env = layout.inputs.env;
            try t.cells.append(allocator, .{
                .block = block_index,
                .node = node,
                .colspan = env.getNodeProperty(.colspan, node),
                .rowspan = env.getNodeProperty(.rowspan, node),
                .vertical_align = vertical_align,
                .height = specified_height,
            });
            try t.rows.items[t.rows.items.len - 1].cells.append(allocator, @intCast(t.cells.items.len - 1));
        },
        .caption => try open_table.?.captions.append(allocator, block_index),
        .none => unreachable,
    }
    return true;
}

/// Lay out the table whose element is closing (block `table_index` of
/// `subtree`): sets `sizes`' used inline size (and auto margins) and returns
/// the table's content height.
pub fn layoutTable(box_gen: *BoxGen, subtree: Subtree.View, subtree_id: Subtree.Id, table_index: Subtree.Size, sizes: *BlockUsedSizes) Unit {
    const layout = box_gen.getLayout();
    const ctx = &box_gen.table_context;
    const t = ctx.open.pop().?;
    std.debug.assert(t.block == table_index);
    ctx.finished.put(layout.allocator, .{ .subtree_id = subtree_id, .block = table_index }, t) catch {};

    // `sizes.inline_size` is the specified width, or for `auto` the width the
    // table would take as a plain block: the available space.
    var available = sizes.get(.inline_size).?;
    if (t.collapse) {
        // §17.6.2: the table's box takes the outer halves of the collapsed
        // edges as its border, and has no padding.
        t.own_borders = .{ sizes.border_inline_start, sizes.border_inline_end, sizes.border_block_start, sizes.border_block_end };
        prepareCollapsed(layout, subtree, t);
        const old_h = sizes.border_inline_start + sizes.border_inline_end + sizes.padding_inline_start + sizes.padding_inline_end;
        sizes.border_inline_start = t.outer[0];
        sizes.border_inline_end = t.outer[1];
        sizes.border_block_start = t.outer[2];
        sizes.border_block_end = t.outer[3];
        sizes.padding_inline_start = 0;
        sizes.padding_inline_end = 0;
        sizes.padding_block_start = 0;
        sizes.padding_block_end = 0;
        if (!t.specified_width) available += old_h - (t.outer[0] + t.outer[1]);
    }
    const result = layoutGrid(layout, subtree, t, available);
    sizes.setValue(.inline_size, result.width);

    // CSS 2.1 §10.3.3 for the table's used width: auto margins share the
    // remaining space (block-level tables center with `margin: auto`).
    const cb_width: Unit = if (box_gen.stacks.containing_block_size.top) |cb| cb.width else result.width;
    const edges = sizes.border_inline_start + sizes.border_inline_end + sizes.padding_inline_start + sizes.padding_inline_end;
    const remaining = cb_width - result.width - edges;
    const flags = sizes.intrinsic;
    if (flags.margin_start_auto and flags.margin_end_auto) {
        const start = @max(0, @divFloor(remaining, 2));
        sizes.setValue(.margin_inline_start, start);
        sizes.setValue(.margin_inline_end, remaining - start);
    } else if (flags.margin_start_auto) {
        sizes.setValue(.margin_inline_start, remaining - sizes.margin_inline_end_untagged);
    } else if (flags.margin_end_auto) {
        sizes.setValue(.margin_inline_end, remaining - sizes.margin_inline_start_untagged);
    } else if (box_gen.stacks.block_info.top) |parent| {
        // A table is a non-auto-width box for legacy alignment.
        const saved_width_kind = sizes.intrinsic.width;
        sizes.intrinsic.width = .fixed;
        sizes.setValue(.margin_inline_start, sizes.specified_margins[0]);
        sizes.setValue(.margin_inline_end, remaining - sizes.specified_margins[0]);
        flow.alignToParentTextAlign(sizes, cb_width, parent.text_align);
        sizes.intrinsic.width = saved_width_kind;
    }
    return result.height;
}

/// Rerun the table algorithm for a table block being relaid out with a
/// content box `content_w` wide. Returns the new content height, or null if
/// `index` is not a laid-out table.
pub fn relayoutTable(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size, content_w: Unit) ?Unit {
    const t = layout.box_gen.table_context.finished.get(.{ .subtree_id = subtree_id, .block = index }) orelse return null;
    if (t.collapse) prepareCollapsed(layout, subtree, t);
    const available = if (t.specified_width) subtree.items(.box_offsets)[index].content_size.w else content_w;
    const result = layoutGrid(layout, subtree, t, available);
    const bo = &subtree.items(.box_offsets)[index];
    const edges = bo.border_size.w - bo.content_size.w;
    bo.content_size.w = result.width;
    bo.border_size.w = result.width + edges;
    return result.height;
}

/// Whether block `index` is a laid-out table.
pub fn isTable(layout: *const Layout, subtree_id: Subtree.Id, index: Subtree.Size) bool {
    return layout.box_gen.table_context.finished.contains(.{ .subtree_id = subtree_id, .block = index });
}

/// Min/max-content border-box width of a laid-out table block, or null if
/// `index` is not one (used by `intrinsic.zig` for tables nested in cells).
pub fn intrinsicSizes(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size) ?intrinsic.Sizes {
    const t = layout.box_gen.table_context.finished.get(.{ .subtree_id = subtree_id, .block = index }) orelse return null;
    var measured = measure(layout, subtree, t) catch return null;
    defer measured.deinit();
    const bo = subtree.items(.box_offsets)[index];
    const edges = bo.border_size.w - bo.content_size.w;
    if (t.specified_width) {
        const w = @max(bo.content_size.w, measured.table_min) + edges;
        return .{ .min = @max(measured.table_min + edges, w), .max = w };
    }
    return .{ .min = measured.table_min + edges, .max = measured.table_max + edges };
}

const GridResult = struct { width: Unit, height: Unit };

/// Steps 1-4 shared by layout and intrinsic sizing: row order, grid slots,
/// column measures and the table's min/max content widths (excluding the
/// table's own padding and border).
const Measured = struct {
    allocator: Allocator,
    order: std.ArrayListUnmanaged(u32) = .{},
    group_order: std.ArrayListUnmanaged(u32) = .{},
    cols: []Column = &.{},
    measures: []intrinsic.Sizes = &.{},
    nrows: u32 = 0,
    ncols: u32 = 0,
    spacing_total: Unit = 0,
    table_min: Unit = 0,
    table_max: Unit = 0,

    fn deinit(m: *Measured) void {
        m.order.deinit(m.allocator);
        m.group_order.deinit(m.allocator);
        m.allocator.free(m.cols);
        m.allocator.free(m.measures);
    }
};

fn measure(layout: *Layout, subtree: Subtree.View, t: *Table) !Measured {
    const allocator = layout.allocator;
    const box_offsets = subtree.items(.box_offsets);
    var result: Measured = .{ .allocator = allocator };
    errdefer result.deinit();

    // 1. Row order: header groups, body rows, footer groups (CSS 2.1 §17.2).
    const order = &result.order;
    const group_order = &result.group_order;
    inline for (.{ GroupKind.header, GroupKind.body, GroupKind.footer }) |kind| {
        for (t.groups.items, 0..) |g, gi| {
            if (g.kind != kind) continue;
            try group_order.append(allocator, @intCast(gi));
            for (g.rows.items) |r| try order.append(allocator, r);
        }
    }
    result.nrows = @intCast(order.items.len);

    const ncols = try assignSlots(allocator, t, group_order.items);
    // 2-3. Column measures.
    result.ncols = ncols;
    result.cols = try allocator.alloc(Column, ncols);
    const cols = result.cols;
    @memset(cols, .{});
    result.measures = try allocator.alloc(intrinsic.Sizes, t.cells.items.len);
    const measures = result.measures;
    for (t.cells.items, 0..) |cell, ci| {
        var m = intrinsic.blockBorderBoxSizes(layout, subtree, t.subtree_id, cell.block);
        const flags = subtree.items(.intrinsic)[cell.block];
        if (flags.width == .fixed) {
            // A specified cell width is a minimum and the preferred width
            // (CSS Tables 3 §3.9.2); content still sets the floor.
            const content = intrinsic.contentBorderBoxSizes(layout, subtree, t.subtree_id, cell.block);
            m.min = @max(content.min, box_offsets[cell.block].border_size.w);
            m.max = m.min;
        }
        measures[ci] = m;
        if (cell.colspan == 1) {
            const col = &cols[cell.col];
            col.min = @max(col.min, m.min);
            if (flags.width == .fixed) {
                col.max = if (col.constrained) @max(col.max, m.max) else m.max;
                col.constrained = true;
            } else if (!col.constrained) {
                col.max = @max(col.max, m.max);
            }
            if (flags.width == .percentage) col.percent = @max(col.percent, subtree.items(.percent_width)[cell.block].fraction());
            col.max = @max(col.max, col.min);
        }
    }
    // Spanning cells, narrowest span first.
    var span: u32 = 2;
    while (span <= ncols) : (span += 1) {
        for (t.cells.items, 0..) |cell, ci| {
            if (cell.colspan != span) continue;
            const spanned = cols[cell.col..@min(ncols, cell.col + span)];
            const spacing_inside = t.spacing_h * @as(Unit, @intCast(spanned.len - 1));
            distributeExcess(spanned, measures[ci].min - spacing_inside, .min);
            distributeExcess(spanned, measures[ci].max - spacing_inside, .max);
            for (spanned) |*col| col.max = @max(col.max, col.min);
        }
    }

    // 4. The table's used content width.
    const spacing_total: Unit = if (ncols > 0) t.spacing_h * @as(Unit, @intCast(ncols + 1)) else 0;
    var sum_min: Unit = 0;
    var sum_max: Unit = 0;
    var sum_percent: f32 = 0;
    var max_non_percent: Unit = 0;
    for (cols) |col| {
        sum_min += col.min;
        sum_max += col.max;
        sum_percent += col.percent;
        if (col.percent == 0) max_non_percent += col.max;
    }
    var table_max = sum_max + spacing_total;
    if (sum_percent > 0) {
        // Percentage columns widen the table's max-content width so each
        // keeps its share (Chromium AutoTableLayout).
        const pct_total = @min(sum_percent, 1.0);
        for (cols) |col| {
            if (col.percent > 0) table_max = @max(table_max, @as(Unit, @intFromFloat(@as(f32, @floatFromInt(col.max)) / col.percent)) + spacing_total);
        }
        if (pct_total < 1.0) table_max = @max(table_max, @as(Unit, @intFromFloat(@as(f32, @floatFromInt(max_non_percent)) / (1.0 - pct_total))) + spacing_total);
    }
    result.spacing_total = spacing_total;
    result.table_min = sum_min + spacing_total;
    result.table_max = table_max;
    return result;
}

fn layoutGrid(layout: *Layout, subtree: Subtree.View, t: *Table, available: Unit) GridResult {
    const allocator = layout.allocator;
    const box_offsets = subtree.items(.box_offsets);
    var measured = measure(layout, subtree, t) catch return .{ .width = available, .height = 0 };
    defer measured.deinit();
    const order = &measured.order;
    const group_order = &measured.group_order;
    const cols = measured.cols;
    const nrows = measured.nrows;
    const ncols = measured.ncols;
    const spacing_total = measured.spacing_total;
    const width: Unit = if (t.specified_width)
        @max(available, measured.table_min)
    else
        @max(measured.table_min, @min(measured.table_max, available));

    // 5. Distribute to columns.
    distributeWidth(cols, width - spacing_total);

    // 6. Cells at their widths.
    const col_x = allocator.alloc(Unit, ncols + 1) catch return .{ .width = width, .height = 0 };
    defer allocator.free(col_x);
    {
        var x = t.spacing_h;
        for (cols, 0..) |col, c| {
            col_x[c] = x;
            x += col.width + t.spacing_h;
        }
        col_x[ncols] = x;
    }
    const cell_heights = allocator.alloc(Unit, t.cells.items.len) catch return .{ .width = width, .height = 0 };
    defer allocator.free(cell_heights);
    for (t.cells.items, 0..) |cell, ci| {
        const end_col = @min(ncols, cell.col + cell.colspan);
        const cell_w = col_x[end_col] - t.spacing_h - col_x[cell.col];
        const bo = &box_offsets[cell.block];
        const edges = bo.border_size.w - bo.content_size.w;
        const content_w = @max(0, cell_w - edges);
        bo.border_size.w = content_w + edges;
        bo.content_size.w = content_w;
        // Cells have no margins (CSS 2.1 §17.5).
        subtree.items(.margins)[cell.block].left = 0;
        subtree.items(.margins)[cell.block].right = 0;
        bo.border_pos = .{ .x = 0, .y = 0 };
        relayout.relayoutContent(layout, subtree, t.subtree_id, cell.block, content_w);
        // A cell's specified height is a minimum (§17.5.3).
        if (cell.height) |h| {
            if (bo.content_size.h < h) relayout.setContentHeight(subtree, cell.block, h);
        }
        cell_heights[ci] = bo.border_size.h;
    }

    // Row heights (§17.5.3).
    const row_h = allocator.alloc(Unit, nrows) catch return .{ .width = width, .height = 0 };
    defer allocator.free(row_h);
    for (order.items, 0..) |r, pos| row_h[pos] = t.rows.items[r].height orelse 0;
    for (t.cells.items, 0..) |cell, ci| {
        if (cell.span_rows == 1) row_h[cell.row] = @max(row_h[cell.row], cell_heights[ci]);
    }
    for (t.cells.items, 0..) |cell, ci| {
        if (cell.span_rows == 1) continue;
        var have = t.spacing_v * @as(Unit, @intCast(cell.span_rows - 1));
        for (row_h[cell.row .. cell.row + cell.span_rows]) |h| have += h;
        if (cell_heights[ci] > have) row_h[cell.row + cell.span_rows - 1] += cell_heights[ci] - have;
    }
    const row_y = allocator.alloc(Unit, nrows) catch return .{ .width = width, .height = 0 };
    defer allocator.free(row_y);

    // Captions above the grid (caption-side: top).
    var y: Unit = 0;
    for (t.captions.items) |cap| {
        relayout.relayoutBlock(layout, subtree, t.subtree_id, cap, width);
        subtree.items(.offset)[cap] = .{ .x = 0, .y = y };
        y += box_offsets[cap].border_size.h + subtree.items(.margins)[cap].top + subtree.items(.margins)[cap].bottom;
    }
    if (nrows > 0) y += t.spacing_v;
    for (0..nrows) |pos| {
        row_y[pos] = y;
        y += row_h[pos] + t.spacing_v;
    }
    const grid_width = @max(0, width - 2 * t.spacing_h);

    // Groups and rows.
    var pos: u32 = 0;
    for (group_order.items) |gi| {
        const g = t.groups.items[gi];
        if (g.rows.items.len == 0) {
            if (g.block) |gb| placeBox(subtree, gb, t.spacing_h, y, grid_width, 0);
            continue;
        }
        const first = pos;
        const last = pos + @as(u32, @intCast(g.rows.items.len)) - 1;
        const group_top = row_y[first];
        const group_bottom = row_y[last] + row_h[last];
        // Rows are offset within their group, or within the table for the
        // anonymous group.
        const origin_x: Unit = if (g.block != null) 0 else t.spacing_h;
        const origin_y: Unit = if (g.block != null) group_top else 0;
        if (g.block) |gb| placeBox(subtree, gb, t.spacing_h, group_top, grid_width, group_bottom - group_top);
        for (g.rows.items) |r| {
            placeBox(subtree, t.rows.items[r].block, origin_x, row_y[pos] - origin_y, grid_width, row_h[pos]);
            pos += 1;
        }
    }

    // Cells within their row: x from the column grid, height spanning rows.
    for (t.cells.items) |cell| {
        const bo = &box_offsets[cell.block];
        var h = t.spacing_v * @as(Unit, @intCast(cell.span_rows - 1));
        for (row_h[cell.row .. cell.row + cell.span_rows]) |rh| h += rh;
        const content_h = bo.content_size.h;
        const top_edge = bo.content_pos.y;
        const bottom_edge = bo.border_size.h - bo.content_pos.y - bo.content_size.h;
        bo.border_size.h = h;
        const free = h - top_edge - bottom_edge - content_h;
        // CSS 2.1 §17.5.4: other values align the cell like baseline.
        const shift: Unit = switch (cell.vertical_align) {
            .middle => @divFloor(free, 2),
            .bottom => free,
            else => 0,
        };
        bo.content_pos.y = top_edge + @max(0, shift);
        bo.content_size.h = h - bo.content_pos.y - bottom_edge;
        subtree.items(.offset)[cell.block] = .{ .x = col_x[cell.col] - t.spacing_h, .y = 0 };
    }

    return .{ .width = width, .height = y };
}

fn placeBox(subtree: Subtree.View, index: Subtree.Size, x: Unit, y: Unit, w: Unit, h: Unit) void {
    const bo = &subtree.items(.box_offsets)[index];
    const margins = &subtree.items(.margins)[index];
    margins.* = .{};
    bo.border_pos = .{ .x = 0, .y = 0 };
    const edges_w = bo.border_size.w - bo.content_size.w;
    const edges_h = bo.border_size.h - bo.content_size.h;
    bo.border_size = .{ .w = w, .h = h };
    bo.content_size = .{ .w = @max(0, w - edges_w), .h = @max(0, h - edges_h) };
    subtree.items(.offset)[index] = .{ .x = x, .y = y };
}

/// Grow the spanned columns so together they reach `target` for the given
/// measure, in proportion to their max-content widths (equally when those
/// are all zero).
fn distributeExcess(spanned: []Column, target: Unit, comptime which: enum { min, max }) void {
    var have: Unit = 0;
    var weight: i64 = 0;
    for (spanned) |col| {
        have += @field(col, @tagName(which));
        weight += col.max;
    }
    if (target <= have) return;
    const excess = target - have;
    var given: Unit = 0;
    for (spanned, 0..) |*col, i| {
        const share: Unit = if (i == spanned.len - 1)
            excess - given
        else if (weight > 0)
            @intCast(@divFloor(@as(i64, excess) * col.max, weight))
        else
            @divFloor(excess, @as(Unit, @intCast(spanned.len)));
        @field(col, @tagName(which)) += share;
        given += share;
    }
}

/// CSS Tables 3 §3.10: distribute `target` (the table width minus spacing)
/// to the columns.
fn distributeWidth(cols: []Column, target: Unit) void {
    if (cols.len == 0) return;
    const guesses = [_]Guess{ .min, .min_percent, .min_specified, .max };
    var sums: [guesses.len]Unit = undefined;
    for (guesses, 0..) |g, gi| {
        var sum: Unit = 0;
        for (cols) |col| sum += guess(col, g, target);
        sums[gi] = sum;
    }
    if (target <= sums[0]) {
        for (cols) |*col| col.width = col.min;
        return;
    }
    // Interpolate between the two guesses bracketing the target.
    var gi: usize = 0;
    while (gi + 1 < guesses.len) : (gi += 1) {
        if (target <= sums[gi + 1]) {
            const span = sums[gi + 1] - sums[gi];
            var given: Unit = 0;
            for (cols, 0..) |*col, c| {
                const a = guess(col.*, guesses[gi], target);
                const b = guess(col.*, guesses[gi + 1], target);
                col.width = if (c == cols.len - 1)
                    target - given
                else if (span > 0)
                    a + @as(Unit, @intCast(@divFloor(@as(i64, b - a) * (target - sums[gi]), span)))
                else
                    a;
                given += col.width;
            }
            return;
        }
    }
    // Beyond the max-content guess: excess to auto columns with a max-content
    // width, else to all auto columns, else to constrained columns, else to
    // percentage columns, in proportion to max-content widths.
    for (cols) |*col| col.width = guess(col.*, .max, target);
    const excess = target - sums[guesses.len - 1];
    const Pick = enum { auto_with_max, auto_any, constrained, percent, all };
    inline for (.{ Pick.auto_with_max, Pick.auto_any, Pick.constrained, Pick.percent, Pick.all }) |pick| {
        var count: usize = 0;
        var weight: i64 = 0;
        for (cols) |col| {
            if (picked(col, pick)) {
                count += 1;
                weight += col.max;
            }
        }
        if (count > 0) {
            var given: Unit = 0;
            var seen: usize = 0;
            for (cols) |*col| {
                if (!picked(col.*, pick)) continue;
                seen += 1;
                const share: Unit = if (seen == count)
                    excess - given
                else if (weight > 0 and pick != .auto_any and pick != .all)
                    @intCast(@divFloor(@as(i64, excess) * col.max, weight))
                else
                    @divFloor(excess, @as(Unit, @intCast(count)));
                col.width += share;
                given += share;
            }
            return;
        }
    }
}

fn picked(col: Column, pick: anytype) bool {
    const is_auto = !col.constrained and col.percent == 0;
    return switch (pick) {
        .auto_with_max => is_auto and col.max > 0,
        .auto_any => is_auto,
        .constrained => col.constrained and col.percent == 0,
        .percent => col.percent > 0,
        .all => true,
    };
}

const Guess = enum { min, min_percent, min_specified, max };

fn guess(col: Column, g: Guess, target: Unit) Unit {
    const percent_width: Unit = @intFromFloat(col.percent * @as(f32, @floatFromInt(target)));
    return switch (g) {
        .min => col.min,
        .min_percent => if (col.percent > 0) @max(col.min, percent_width) else col.min,
        .min_specified => if (col.percent > 0) @max(col.min, percent_width) else if (col.constrained) col.max else col.min,
        .max => if (col.percent > 0) @max(col.min, percent_width) else col.max,
    };
}

/// Row order (header groups, body, footer groups — CSS 2.1 §17.2) into
/// `group_order` / `order`.
fn orderRows(allocator: Allocator, t: *const Table, order: *std.ArrayListUnmanaged(u32), group_order: *std.ArrayListUnmanaged(u32)) !void {
    inline for (.{ GroupKind.header, GroupKind.body, GroupKind.footer }) |kind| {
        for (t.groups.items, 0..) |g, gi| {
            if (g.kind != kind) continue;
            try group_order.append(allocator, @intCast(gi));
            for (g.rows.items) |r| try order.append(allocator, r);
        }
    }
}

/// Grid slots for every cell (row in display order, first column, rows
/// spanned), honouring colspan and rowspan. Returns the column count.
fn assignSlots(allocator: Allocator, t: *Table, group_order: []const u32) !u32 {
    // `busy[c]` = first ordered row index at which column c is free again.
    var busy: std.ArrayListUnmanaged(u32) = .{};
    defer busy.deinit(allocator);
    var ncols: u32 = 0;
    var row_pos: u32 = 0;
    for (group_order) |gi| {
        const g = t.groups.items[gi];
        const group_end = row_pos + @as(u32, @intCast(g.rows.items.len));
        for (g.rows.items) |r| {
            var col: u32 = 0;
            for (t.rows.items[r].cells.items) |ci| {
                const cell = &t.cells.items[ci];
                while (col < busy.items.len and busy.items[col] > row_pos) col += 1;
                const span_rows: u32 = if (cell.rowspan == 0) group_end - row_pos else @min(cell.rowspan, group_end - row_pos);
                cell.row = row_pos;
                cell.col = col;
                cell.span_rows = @max(1, span_rows);
                const end_col = col + cell.colspan;
                while (busy.items.len < end_col) try busy.append(allocator, 0);
                var c = col;
                while (c < end_col) : (c += 1) busy.items[c] = row_pos + cell.span_rows;
                col = end_col;
                ncols = @max(ncols, end_col);
            }
            row_pos += 1;
        }
    }
    return ncols;
}

// ─── Collapsing border model (CSS 2.1 §17.6.2) ──────────────────────────

const Edge = struct {
    width: Unit = 0,
    style_rank: u8 = 0,
    origin_rank: u8 = 0,
    color: math.Color = .transparent,
    hidden: bool = false,
    set: bool = false,
};

fn styleRank(style: types.BorderStyle) u8 {
    return switch (style) {
        .none, .hidden => 0,
        .inset => 1,
        .groove => 2,
        .outset => 3,
        .ridge => 4,
        .dotted => 5,
        .dashed => 6,
        .solid => 7,
        .double => 8,
    };
}

/// Offer one border to an edge (§17.6.2.1 conflict resolution). Earlier
/// offers win ties (the cell further left / higher up).
fn offer(edge: *Edge, width: Unit, style: types.BorderStyle, origin_rank: u8, color: math.Color) void {
    if (style == .hidden) {
        edge.hidden = true;
        return;
    }
    const w: Unit = if (style == .none) 0 else width;
    const rank = styleRank(style);
    if (edge.set) {
        if (w < edge.width) return;
        if (w == edge.width) {
            if (rank < edge.style_rank) return;
            if (rank == edge.style_rank and origin_rank <= edge.origin_rank) return;
        }
    }
    edge.* = .{ .width = w, .style_rank = rank, .origin_rank = origin_rank, .color = color, .hidden = edge.hidden, .set = true };
}

fn edgeWidth(e: Edge) Unit {
    return if (e.hidden) 0 else e.width;
}

const Sides = struct {
    widths: [4]Unit,
    styles: [4]types.BorderStyle,
    colors: [4]math.Color,
};

/// An element's own borders: widths as laid out before collapsing, styles
/// and colors from its committed computed values.
fn ownSides(layout: *Layout, node: NodeId, widths: [4]Unit) Sides {
    const computer = &layout.computer;
    var sides: Sides = .{ .widths = widths, .styles = .{ .none, .none, .none, .none }, .colors = .{ .transparent, .transparent, .transparent, .transparent } };
    if (computer.committedValue(.box_gen, .border_styles, node)) |bs| sides.styles = .{ bs.left, bs.right, bs.top, bs.bottom };
    const color_value = computer.committedValue(.box_gen, .color, node);
    const current: math.Color = if (color_value) |c| solve.colorProperty(c)[1] else .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    if (computer.committedValue(.box_gen, .border_colors, node)) |bc| {
        const used = solve.borderColors(bc, current);
        sides.colors = .{ used.left, used.right, used.top, used.bottom };
    }
    return sides;
}

/// Resolve the collapsed edges of table `t` and give each cell's box half
/// of each of its edges (start/top halves round down, end/bottom halves
/// take the rest). Records the table's outer halves in `t.outer`.
fn prepareCollapsed(layout: *Layout, subtree: Subtree.View, t: *Table) void {
    const allocator = layout.allocator;
    var order: std.ArrayListUnmanaged(u32) = .{};
    defer order.deinit(allocator);
    var group_order: std.ArrayListUnmanaged(u32) = .{};
    defer group_order.deinit(allocator);
    orderRows(allocator, t, &order, &group_order) catch return;
    const ncols = assignSlots(allocator, t, group_order.items) catch return;
    const nrows: u32 = @intCast(order.items.len);
    if (ncols == 0 or nrows == 0) {
        t.outer = .{ @divFloor(t.own_borders[0], 2), @divFloor(t.own_borders[1], 2), @divFloor(t.own_borders[2], 2), @divFloor(t.own_borders[3], 2) };
        return;
    }
    // Vertical edges: (nrows) x (ncols + 1); horizontal: (nrows + 1) x ncols.
    const v = allocator.alloc(Edge, nrows * (ncols + 1)) catch return;
    defer allocator.free(v);
    const h = allocator.alloc(Edge, (nrows + 1) * ncols) catch return;
    defer allocator.free(h);
    @memset(v, .{});
    @memset(h, .{});
    const V = struct {
        fn at(edges: []Edge, n: u32, r: u32, c: u32) *Edge {
            return &edges[r * (n + 1) + c];
        }
    };
    const H = struct {
        fn at(edges: []Edge, n: u32, r: u32, c: u32) *Edge {
            return &edges[r * n + c];
        }
    };

    // Cells first (origin rank 4), in row-major order so earlier cells win
    // ties, then the table (origin rank 0).
    for (t.cells.items) |*cell| {
        if (cell.own_borders == null) {
            const b = subtree.items(.borders)[cell.block];
            cell.own_borders = .{ b.left, b.right, b.top, b.bottom };
        }
        const sides = ownSides(layout, cell.node, cell.own_borders.?);
        const r0 = cell.row;
        const r1 = @min(nrows, cell.row + cell.span_rows);
        const c0 = cell.col;
        const c1 = @min(ncols, cell.col + cell.colspan);
        var r = r0;
        while (r < r1) : (r += 1) {
            offer(V.at(v, ncols, r, c0), sides.widths[0], sides.styles[0], 4, sides.colors[0]);
            offer(V.at(v, ncols, r, c1), sides.widths[1], sides.styles[1], 4, sides.colors[1]);
        }
        var c = c0;
        while (c < c1) : (c += 1) {
            offer(H.at(h, ncols, r0, c), sides.widths[2], sides.styles[2], 4, sides.colors[2]);
            offer(H.at(h, ncols, r1, c), sides.widths[3], sides.styles[3], 4, sides.colors[3]);
        }
    }
    const table_sides = ownSides(layout, t.node, t.own_borders);
    for (0..nrows) |r| {
        offer(V.at(v, ncols, @intCast(r), 0), table_sides.widths[0], table_sides.styles[0], 0, table_sides.colors[0]);
        offer(V.at(v, ncols, @intCast(r), ncols), table_sides.widths[1], table_sides.styles[1], 0, table_sides.colors[1]);
    }
    for (0..ncols) |c| {
        offer(H.at(h, ncols, 0, @intCast(c)), table_sides.widths[2], table_sides.styles[2], 0, table_sides.colors[2]);
        offer(H.at(h, ncols, nrows, @intCast(c)), table_sides.widths[3], table_sides.styles[3], 0, table_sides.colors[3]);
    }

    // Cells: half edges (widest segment of a spanning side).
    for (t.cells.items) |cell| {
        const r0 = cell.row;
        const r1 = @min(nrows, cell.row + cell.span_rows);
        const c0 = cell.col;
        const c1 = @min(ncols, cell.col + cell.colspan);
        var widths = [4]Unit{ 0, 0, 0, 0 };
        var colors = [4]math.Color{ .transparent, .transparent, .transparent, .transparent };
        var r = r0;
        while (r < r1) : (r += 1) {
            const left = V.at(v, ncols, r, c0).*;
            const right = V.at(v, ncols, r, c1).*;
            if (r == r0 or edgeWidth(left) > widths[0] * 2) colors[0] = left.color;
            if (r == r0 or edgeWidth(right) > widths[1] * 2) colors[1] = right.color;
            // A cell is on the end side of its left edge: it takes the
            // rounded-down half; the cell or table before it the rest.
            widths[0] = @max(widths[0], @divFloor(edgeWidth(left), 2));
            widths[1] = @max(widths[1], edgeWidth(right) - @divFloor(edgeWidth(right), 2));
        }
        var c = c0;
        while (c < c1) : (c += 1) {
            const top = H.at(h, ncols, r0, c).*;
            const bottom = H.at(h, ncols, r1, c).*;
            if (c == c0) {
                colors[2] = top.color;
                colors[3] = bottom.color;
            }
            widths[2] = @max(widths[2], @divFloor(edgeWidth(top), 2));
            widths[3] = @max(widths[3], edgeWidth(bottom) - @divFloor(edgeWidth(bottom), 2));
        }
        setCellBorders(subtree, cell.block, widths);
        subtree.items(.border_colors)[cell.block] = .{ .left = colors[0], .right = colors[1], .top = colors[2], .bottom = colors[3] };
    }

    // The table's box: outer halves — the part of each outer edge outside
    // the cells (the rounded-up half), widest along each side.
    var outer = [4]Unit{ 0, 0, 0, 0 };
    var outer_colors = [4]math.Color{ .transparent, .transparent, .transparent, .transparent };
    for (0..nrows) |r| {
        const left = V.at(v, ncols, @intCast(r), 0).*;
        const right = V.at(v, ncols, @intCast(r), ncols).*;
        const lw = edgeWidth(left) - @divFloor(edgeWidth(left), 2);
        const rw = @divFloor(edgeWidth(right), 2);
        if (r == 0 or lw > outer[0]) outer_colors[0] = left.color;
        if (r == 0 or rw > outer[1]) outer_colors[1] = right.color;
        outer[0] = @max(outer[0], lw);
        outer[1] = @max(outer[1], rw);
    }
    for (0..ncols) |c| {
        const top = H.at(h, ncols, 0, @intCast(c)).*;
        const bottom = H.at(h, ncols, nrows, @intCast(c)).*;
        const tw = edgeWidth(top) - @divFloor(edgeWidth(top), 2);
        const bw = @divFloor(edgeWidth(bottom), 2);
        if (c == 0 or tw > outer[2]) outer_colors[2] = top.color;
        if (c == 0 or bw > outer[3]) outer_colors[3] = bottom.color;
        outer[2] = @max(outer[2], tw);
        outer[3] = @max(outer[3], bw);
    }
    t.outer = outer;
    t.outer_colors = outer_colors;
}

/// Replace a laid-out block's border widths, keeping its padding and
/// content size.
fn setCellBorders(subtree: Subtree.View, index: Subtree.Size, widths: [4]Unit) void {
    const bo = &subtree.items(.box_offsets)[index];
    const borders = &subtree.items(.borders)[index];
    const pad_left = bo.content_pos.x - borders.left;
    const pad_top = bo.content_pos.y - borders.top;
    const pad_right = bo.border_size.w - bo.content_size.w - bo.content_pos.x - borders.right;
    const pad_bottom = bo.border_size.h - bo.content_size.h - bo.content_pos.y - borders.bottom;
    borders.* = .{ .left = widths[0], .right = widths[1], .top = widths[2], .bottom = widths[3] };
    bo.content_pos = .{ .x = widths[0] + pad_left, .y = widths[2] + pad_top };
    bo.border_size = .{
        .w = widths[0] + pad_left + bo.content_size.w + pad_right + widths[1],
        .h = widths[2] + pad_top + bo.content_size.h + pad_bottom + widths[3],
    };
}

/// After the table's own cosmetic values are written: in the collapsing
/// model its outer half edges take the resolved edge colors.
pub fn afterTableCosmetic(box_gen: *BoxGen, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size) void {
    const t = box_gen.table_context.finished.get(.{ .subtree_id = subtree_id, .block = index }) orelse return;
    if (!t.collapse) return;
    subtree.items(.border_colors)[index] = .{ .left = t.outer_colors[0], .right = t.outer_colors[1], .top = t.outer_colors[2], .bottom = t.outer_colors[3] };
}
