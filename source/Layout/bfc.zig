//! Block formatting context layout with floats (CSS 2.1 §9.4.1, §9.5,
//! §8.3.1, §10.6.7).
//!
//! Box generation lays block content out bottom-up, which cannot place
//! floats: a float's position depends on where the content before it ended,
//! in the coordinates of its whole formatting context, and the line boxes
//! after it depend on the float. When a BFC root whose formatting context
//! contains floats is finished (`BoxGen.popFlowBlock`, or a relayout), this
//! pass lays the formatting context out again top-down, in the root's
//! content-box coordinates:
//!
//! - In-flow blocks get their width and inline margins (§10.3.3) and are
//!   stacked with margin collapsing done by a margin strut: a block's top
//!   margin collapses with its first child's while it has no top border or
//!   padding, a block with no content collapses through, and an auto-height
//!   block with no bottom border or padding passes its last child's bottom
//!   margin on (§8.3.1).
//! - Floats are sized shrink-to-fit when their width is auto (§10.3.5,
//!   `intrinsic.zig`) and placed by the §9.5.1 rules: no higher than an
//!   earlier float or the current position, as high as possible, then as far
//!   left (right) as possible, beside the floats still present at that
//!   height.
//! - `clear` adds clearance: the border box moves below the relevant floats
//!   and its top margin no longer collapses with the margins before it
//!   (§9.5.2).
//! - Every inline formatting context is re-split with the floats beside it
//!   (line boxes shortened, §9.5), translated to its own position.
//! - Block-level BFC roots (overflow other than visible, flex, grid, tables)
//!   must not overlap floats: they move down until they fit beside them,
//!   an auto width narrowing to the space left (§9.5).
//! - The root's auto height includes its floats' bottom margin edges
//!   (§10.6.7); an ordinary block's does not (§10.6.3).
//!
//! Not handled yet (documented, not approximated): a float that appears in
//! the middle of inline content splits that content into two inline
//! formatting contexts, so the text after it starts a new line instead of
//! continuing on the float's line.
const std = @import("std");
const zss = @import("../zss.zig");
const Unit = zss.math.Unit;
const Layout = zss.Layout;
const BoxTree = zss.BoxTree;
const Subtree = BoxTree.Subtree;

const flow = @import("./flow.zig");
const relayout = @import("./relayout.zig");
const intrinsic = @import("./intrinsic.zig");
const inline_layout = @import("./inline.zig");
const table = @import("./table.zig");

/// A placed float's margin box, in the root's content-box coordinates.
const Exclusion = struct {
    side: flow.FloatContext.Side,
    left: Unit,
    right: Unit,
    top: Unit,
    bottom: Unit,
};

/// Adjoining margins collapse to the largest positive plus the most
/// negative one (CSS 2.1 §8.3.1).
const MarginStrut = struct {
    positive: Unit = 0,
    negative: Unit = 0,

    fn append(strut: *MarginStrut, margin: Unit) void {
        if (margin > 0) strut.positive = @max(strut.positive, margin) else strut.negative = @min(strut.negative, margin);
    }

    fn sum(strut: MarginStrut) Unit {
        return strut.positive + strut.negative;
    }
};

const unresolved = std.math.minInt(Unit);

/// Lay out the formatting context of BFC root `root` (whose subtree size is
/// `skip`) at content width `content_w`. Returns the root's auto content
/// height.
pub fn layoutBfc(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, root: Subtree.Size, skip: Subtree.Size, content_w: Unit) Unit {
    const tops = layout.allocator.alloc(Unit, skip) catch return 0;
    defer layout.allocator.free(tops);
    @memset(tops, unresolved);
    var pass: Pass = .{ .layout = layout, .subtree = subtree, .subtree_id = subtree_id, .root = root, .tops = tops };
    defer pass.deinit();
    pass.walk(root, root + skip, 0, content_w) catch {};
    // The last child's bottom margin stays inside a BFC root.
    pass.resolve() catch {};
    var height = pass.y;
    for (pass.exclusions.items) |e| height = @max(height, e.bottom);
    pass.writeOffsets(root, root + skip, 0);
    return height;
}

const Queued = struct { index: Subtree.Size, x0: Unit, width: Unit };

const Pass = struct {
    layout: *Layout,
    subtree: Subtree.View,
    subtree_id: Subtree.Id,
    root: Subtree.Size,
    /// Border-box top of each entry (an IFC's top), relative to the root.
    tops: []Unit,
    exclusions: std.ArrayListUnmanaged(Exclusion) = .empty,
    /// Blocks whose top margin still collapses with what follows: their
    /// border-box top is where the strut resolves.
    pending: std.ArrayListUnmanaged(Subtree.Size) = .empty,
    line_floats: std.ArrayListUnmanaged(flow.FloatContext.PlacedFloat) = .empty,
    /// Floats met while the block offset was unresolved (pending margins):
    /// they are placed where it resolves, as in Chromium.
    queued: std.ArrayListUnmanaged(Queued) = .empty,
    /// The bottom of the last in-flow content.
    y: Unit = 0,
    strut: MarginStrut = .{},
    /// §9.5.1 rule 5: a float's top is not above an earlier float's.
    float_top: Unit = 0,

    fn deinit(pass: *Pass) void {
        const allocator = pass.layout.allocator;
        pass.exclusions.deinit(allocator);
        pass.pending.deinit(allocator);
        pass.line_floats.deinit(allocator);
        pass.queued.deinit(allocator);
    }

    fn top(pass: *Pass, index: Subtree.Size) *Unit {
        return &pass.tops[index - pass.root];
    }

    /// Content after adjoining margins: they collapse into one, and every
    /// pending block's border-box top is there.
    fn resolve(pass: *Pass) !void {
        const position = pass.y + pass.strut.sum();
        for (pass.pending.items) |index| pass.top(index).* = position;
        pass.pending.clearRetainingCapacity();
        pass.y = position;
        pass.strut = .{};
        for (pass.queued.items) |q| try pass.placeFloat(q.index, q.x0, q.width);
        pass.queued.clearRetainingCapacity();
    }

    /// The lowest bottom of the floats `clear` applies to.
    fn clearBottom(pass: *const Pass, clear: zss.values.types.Clear) ?Unit {
        var bottom: ?Unit = null;
        for (pass.exclusions.items) |e| {
            const applies = switch (clear) {
                .none => false,
                .left => e.side == .left,
                .right => e.side == .right,
                .both => true,
            };
            if (applies) bottom = @max(bottom orelse e.bottom, e.bottom);
        }
        return bottom;
    }

    const Opportunity = struct { left: Unit, right: Unit, constrained: bool };

    /// The inline space between the floats present over [y, y + height)
    /// within [x0, x0 + width).
    fn opportunity(pass: *const Pass, y: Unit, height: Unit, x0: Unit, width: Unit) Opportunity {
        var result: Opportunity = .{ .left = x0, .right = x0 + width, .constrained = false };
        for (pass.exclusions.items) |e| {
            if (e.bottom <= y or e.top >= y + @max(height, 1)) continue;
            switch (e.side) {
                .left => if (e.right > result.left) {
                    result.left = e.right;
                    result.constrained = true;
                },
                .right => if (e.left < result.right) {
                    result.right = e.left;
                    result.constrained = true;
                },
            }
        }
        return result;
    }

    /// The next float bottom below `y` among the floats present at `y`.
    fn nextBottom(pass: *const Pass, y: Unit) ?Unit {
        var next: ?Unit = null;
        for (pass.exclusions.items) |e| {
            if (e.bottom > y and e.top <= y) next = @min(next orelse e.bottom, e.bottom);
        }
        return next;
    }

    fn walk(pass: *Pass, container: Subtree.Size, end: Subtree.Size, x0: Unit, width: Unit) error{OutOfMemory}!void {
        const subtree = pass.subtree;
        const skips = subtree.items(.skip);
        var child = container + 1;
        while (child < end) : (child += skips[child]) {
            if (subtree.items(.out_of_flow)[child]) continue;
            switch (subtree.items(.type)[child]) {
                .ifc_container => |ifc_id| try pass.inlineContent(child, ifc_id, x0, width),
                .subtree_proxy => {
                    try pass.resolve();
                    pass.top(child).* = pass.y;
                    pass.y += subtree.items(.box_offsets)[child].border_size.h;
                },
                .block => {
                    if (subtree.items(.float_side)[child] != .none) {
                        try pass.float(child, x0, width);
                    } else if (isBfcRoot(pass, child)) {
                        try pass.bfcRoot(child, x0, width);
                    } else {
                        try pass.block(child, x0, width);
                    }
                },
            }
        }
    }

    fn isBfcRoot(pass: *const Pass, index: Subtree.Size) bool {
        const subtree = pass.subtree;
        return subtree.items(.is_bfc)[index] or subtree.items(.inner_block)[index] != .flow or
            subtree.items(.overflow)[index] != .visible or table.isTable(pass.layout, pass.subtree_id, index);
    }

    fn inlineContent(pass: *Pass, index: Subtree.Size, ifc_id: BoxTree.InlineFormattingContext.Id, x0: Unit, width: Unit) !void {
        const ifc = pass.layout.box_tree.ptr.getIfc(ifc_id);
        const bo = &pass.subtree.items(.box_offsets)[index];
        if (!ifc.has_visible_content) {
            // Inter-element white space: no line boxes (§9.2.2.1).
            pass.top(index).* = pass.y;
            return;
        }
        try pass.resolve();
        const ifc_top = pass.y;
        pass.line_floats.clearRetainingCapacity();
        for (pass.exclusions.items) |e| {
            if (e.bottom <= ifc_top) continue;
            try pass.line_floats.append(pass.layout.allocator, .{
                .side = e.side,
                .x = e.left - x0,
                .y = e.top - ifc_top,
                .w = e.right - e.left,
                .h = e.bottom - e.top,
            });
        }
        const floats: ?flow.FloatContext = if (pass.line_floats.items.len > 0) .{ .floats = pass.line_floats.items } else null;
        ifc.line_boxes.clearRetainingCapacity();
        const result = inline_layout.splitIntoLineBoxes(pass.layout, pass.subtree, ifc, width, floats) catch return;
        bo.border_size = .{ .w = width, .h = result.height };
        bo.content_size = .{ .w = width, .h = result.height };
        pass.top(index).* = ifc_top;
        pass.y = ifc_top + result.height;
    }

    /// Clearance (§9.5.2): if the border box would start above the floats
    /// `clear` applies to, it starts at their bottom, and the margins
    /// before it resolve without its top margin. Returns whether it applied.
    fn clearance(pass: *Pass, index: Subtree.Size, strut_before: MarginStrut, margin_top: Unit) !bool {
        const clear = pass.subtree.items(.clear_side)[index];
        if (clear == .none) return false;
        if (pass.queued.items.len > 0) {
            // Floats waiting for the block offset are placed first, where
            // the margins before this box resolve.
            pass.strut = strut_before;
            try pass.resolve();
            pass.strut.append(margin_top);
        }
        const bottom = pass.clearBottom(clear) orelse return false;
        if (bottom <= pass.y + pass.strut.sum()) return false;
        pass.strut = strut_before;
        try pass.resolve();
        pass.y = @max(bottom, pass.y + margin_top);
        pass.top(index).* = pass.y;
        return true;
    }

    fn setMargins(pass: *Pass, index: Subtree.Size, margins: [2]Unit) void {
        const m = &pass.subtree.items(.margins)[index];
        m.top = margins[0];
        m.bottom = margins[1];
        pass.subtree.items(.box_offsets)[index].border_pos.y = margins[0];
    }

    fn block(pass: *Pass, index: Subtree.Size, x0: Unit, width: Unit) !void {
        const subtree = pass.subtree;
        const bo = &subtree.items(.box_offsets)[index];
        const used = relayout.usedInlineSize(pass.layout.inputs.env, subtree, index, width);
        const edges_w = bo.border_size.w - bo.content_size.w;
        const margins = &subtree.items(.margins)[index];
        margins.left = used.margin_left;
        margins.right = used.margin_right;
        bo.border_pos.x = used.margin_left;
        bo.border_size.w = used.content_w + edges_w;
        bo.content_size.w = used.content_w;
        subtree.items(.offset)[index].x = 0;

        const m = subtree.items(.block_margins)[index];
        pass.setMargins(index, m);
        const strut_before = pass.strut;
        pass.strut.append(m[0]);
        const edges_top = bo.content_pos.y;
        if (!try pass.clearance(index, strut_before, m[0])) {
            if (edges_top > 0) {
                try pass.resolve();
                pass.top(index).* = pass.y;
            } else {
                try pass.pending.append(pass.layout.allocator, index);
            }
        }
        if (pass.top(index).* != unresolved) pass.y = pass.top(index).* + edges_top;

        try pass.walk(index, index + subtree.items(.skip)[index], x0 + used.margin_left + bo.content_pos.x, used.content_w);

        const edges_bottom = bo.border_size.h - bo.content_pos.y - bo.content_size.h;
        const height_auto = subtree.items(.intrinsic)[index].height_auto;
        const min_h = subtree.items(.min_block_size)[index];
        const max_h = subtree.items(.max_block_size)[index];
        if (pass.top(index).* == unresolved) {
            if (height_auto and edges_bottom == 0 and min_h <= 0) {
                // No content: its margins collapse through it (§8.3.1). Its
                // top is where it would be with a bottom border.
                const position = pass.y + pass.strut.sum();
                while (pass.pending.items.len > 0 and pass.pending.items[pass.pending.items.len - 1] >= index) {
                    pass.top(pass.pending.pop().?).* = position;
                }
                setHeight(bo, 0);
                pass.strut.append(m[1]);
                return;
            }
            try pass.resolve();
        }
        const content_top = pass.top(index).* + edges_top;
        if (height_auto and edges_bottom == 0) {
            const h = pass.y - content_top;
            if (std.math.clamp(h, min_h, @max(min_h, max_h)) == h) {
                // The last child's bottom margin collapses with this one's.
                setHeight(bo, h);
                pass.strut.append(m[1]);
                return;
            }
        }
        const inner_end = pass.y + pass.strut.sum();
        pass.strut = .{};
        const h = if (height_auto) std.math.clamp(inner_end - content_top, min_h, @max(min_h, max_h)) else bo.content_size.h;
        setHeight(bo, h);
        pass.y = content_top + h + edges_bottom;
        pass.strut.append(m[1]);
    }

    fn setHeight(bo: *BoxTree.BoxOffsets, content_h: Unit) void {
        const bottom = bo.border_size.h - bo.content_pos.y - bo.content_size.h;
        bo.content_size.h = content_h;
        bo.border_size.h = bo.content_pos.y + content_h + bottom;
    }

    /// A block-level BFC root: its border box may not overlap floats in
    /// this formatting context (§9.5).
    fn bfcRoot(pass: *Pass, index: Subtree.Size, x0: Unit, width: Unit) !void {
        const subtree = pass.subtree;
        const m = subtree.items(.block_margins)[index];
        pass.setMargins(index, m);
        const strut_before = pass.strut;
        pass.strut.append(m[0]);
        if (!try pass.clearance(index, strut_before, m[0])) try pass.resolve();
        var y = pass.y;
        const is_table = table.isTable(pass.layout, pass.subtree_id, index);
        const auto_width = subtree.items(.intrinsic)[index].width == .auto and !is_table;
        const specified = subtree.items(.specified_margins)[index];
        var left = x0;
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            const bo = subtree.items(.box_offsets)[index];
            const opp = pass.opportunity(y, bo.border_size.h, x0, width);
            if (!opp.constrained or attempts > pass.exclusions.items.len) {
                if (!is_table) relayout.relayoutBlock(pass.layout, subtree, pass.subtree_id, index, width);
                left = x0;
                break;
            }
            const available = opp.right - opp.left;
            const fits = if (auto_width)
                available >= intrinsic.blockContribution(pass.layout, subtree, pass.subtree_id, index).min
            else
                bo.border_size.w + specified[0] + specified[1] <= available;
            if (fits) {
                if (!is_table) relayout.relayoutBlock(pass.layout, subtree, pass.subtree_id, index, available);
                // The relaid box may be taller: it must still fit there.
                const again = pass.opportunity(y, subtree.items(.box_offsets)[index].border_size.h, x0, width);
                if (again.right - again.left >= available or again.left == opp.left and again.right == opp.right) {
                    left = opp.left;
                    break;
                }
            }
            y = pass.nextBottom(y) orelse {
                left = x0;
                break;
            };
        }
        subtree.items(.offset)[index].x = left - x0;
        pass.top(index).* = y;
        pass.y = y + subtree.items(.box_offsets)[index].border_size.h;
        pass.strut.append(m[1]);
    }

    fn float(pass: *Pass, index: Subtree.Size, x0: Unit, width: Unit) !void {
        if (pass.pending.items.len > 0) {
            try pass.queued.append(pass.layout.allocator, .{ .index = index, .x0 = x0, .width = width });
            return;
        }
        try pass.placeFloat(index, x0, width);
    }

    fn placeFloat(pass: *Pass, index: Subtree.Size, x0: Unit, width: Unit) !void {
        const subtree = pass.subtree;
        const specified = subtree.items(.specified_margins)[index];
        const m = subtree.items(.block_margins)[index];
        const flags = subtree.items(.intrinsic)[index];
        const margin_left: Unit = if (flags.margin_start_auto) 0 else specified[0];
        const margin_right: Unit = if (flags.margin_end_auto) 0 else specified[1];
        const available = @max(0, width - margin_left - margin_right);
        {
            const bo = subtree.items(.box_offsets)[index];
            const edges = bo.border_size.w - bo.content_size.w;
            // §10.3.5: an auto width is shrink-to-fit.
            const border_w = switch (flags.width) {
                .auto => blk: {
                    const sizes = intrinsic.blockBorderBoxSizes(pass.layout, subtree, pass.subtree_id, index);
                    break :blk @min(@max(sizes.min, available), sizes.max);
                },
                .fixed => bo.border_size.w,
                .percentage => relayout.usedInlineSize(pass.layout.inputs.env, subtree, index, width).content_w + edges,
            };
            relayout.resizeItem(pass.layout, subtree, pass.subtree_id, index, border_w);
        }
        const bo = &subtree.items(.box_offsets)[index];
        const margins = &subtree.items(.margins)[index];
        margins.left = margin_left;
        margins.right = margin_right;
        bo.border_pos.x = margin_left;
        pass.setMargins(index, m);
        const outer_w = margin_left + bo.border_size.w + margin_right;
        const outer_h = m[0] + bo.border_size.h + m[1];
        const side: flow.FloatContext.Side = if (subtree.items(.float_side)[index] == .left) .left else .right;

        // §9.5.1 rules 4-9.
        var y = @max(pass.y + pass.strut.sum(), pass.float_top);
        if (subtree.items(.clear_side)[index] != .none) {
            if (pass.clearBottom(subtree.items(.clear_side)[index])) |bottom| y = @max(y, bottom);
        }
        var opp = pass.opportunity(y, outer_h, x0, width);
        while (opp.constrained and opp.right - opp.left < outer_w) {
            y = pass.nextBottom(y) orelse break;
            opp = pass.opportunity(y, outer_h, x0, width);
        }
        const x = switch (side) {
            .left => opp.left,
            .right => opp.right - outer_w,
        };
        try pass.exclusions.append(pass.layout.allocator, .{ .side = side, .left = x, .right = x + outer_w, .top = y, .bottom = y + outer_h });
        pass.float_top = y;
        subtree.items(.offset)[index].x = x - x0;
        pass.top(index).* = y + m[0];
    }

    /// Turn the tops into offsets relative to each parent's content box.
    fn writeOffsets(pass: *Pass, container: Subtree.Size, end: Subtree.Size, content_top: Unit) void {
        const subtree = pass.subtree;
        const skips = subtree.items(.skip);
        var child = container + 1;
        while (child < end) : (child += skips[child]) {
            if (subtree.items(.out_of_flow)[child]) continue;
            const child_top = pass.top(child).*;
            if (child_top == unresolved) continue;
            const offset = &subtree.items(.offset)[child];
            switch (subtree.items(.type)[child]) {
                .ifc_container => offset.* = .{ .x = 0, .y = child_top - content_top },
                .subtree_proxy => offset.y = child_top - content_top,
                .block => {
                    const bo = subtree.items(.box_offsets)[child];
                    offset.y = child_top - bo.border_pos.y - content_top;
                    if (subtree.items(.float_side)[child] == .none and !pass.isBfcRoot(child)) {
                        pass.writeOffsets(child, child + skips[child], child_top + bo.content_pos.y);
                    }
                },
            }
        }
    }
};
