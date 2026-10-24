//! Absolutely positioned boxes (CSS 2.1 §10.1, §10.3.7, §10.6.4; CSS
//! Position 3 §4): their final size and position, once every box is laid
//! out and every containing block has its size.
//!
//! Box generation lays an absolutely positioned box out like a block in
//! normal flow (its children in tree order), sized against its containing
//! block's padding width, and records its static position — where its
//! margin box would be in flow — as its `offset` (`flow.offsetChildBlocks`).
//! This pass walks the box tree the way the renderer does — the same
//! origins, the same containing-block origin for out-of-flow boxes (the
//! padding box of the nearest positioned ancestor) — and for each
//! out-of-flow box:
//!   - gives an auto width its used value: stretched between `left` and
//!     `right` when both are set, else shrink-to-fit (§10.3.7);
//!   - gives an auto height the space between `top` and `bottom` when both
//!     are set (§10.6.4);
//!   - places the margin box: `left`, else `right` from the containing
//!     block's right padding edge, else the static position; likewise
//!     vertically. `position: fixed` boxes use the viewport.
//! The position is written as `insets` relative to the containing-block
//! origin the renderer uses for the box (cb_origin + insets + border_pos).

const std = @import("std");

const zss = @import("../zss.zig");
const math = zss.math;
const Unit = math.Unit;
const Layout = zss.Layout;
const BoxTree = zss.BoxTree;
const Subtree = BoxTree.Subtree;
const types = zss.values.types;

const solve = @import("./solve.zig");
const intrinsic = @import("./intrinsic.zig");
const relayout = @import("./relayout.zig");

const Cb = struct {
    /// Padding-box origin, in the renderer's coordinates.
    origin: math.Vector,
    /// Padding-box size.
    size: math.Size,
};

pub fn run(layout: *Layout) void {
    const box_tree = layout.box_tree.ptr;
    if (box_tree.subtrees.items.len == 0) return;
    const viewport: Cb = .{ .origin = .{ .x = 0, .y = 0 }, .size = layout.viewport };
    const root_id: Subtree.Id = @enumFromInt(0);
    const view = box_tree.getSubtree(root_id).view();
    if (view.len == 0) return;
    var it: Subtree.Iterator = .{ .current = 0, .end = view.items(.skip)[0] };
    while (it.next(view)) |index| visit(layout, view, root_id, index, .{ .x = 0, .y = 0 }, viewport, viewport);
}

fn visit(
    layout: *Layout,
    view: Subtree.View,
    subtree_id: Subtree.Id,
    index: Subtree.Size,
    parent_content: math.Vector,
    cb: Cb,
    viewport: Cb,
) void {
    const block_type = view.items(.type)[index];
    const out_of_flow = view.items(.out_of_flow)[index];
    if (out_of_flow and block_type == .block) place(layout, view, subtree_id, index, parent_content, cb, viewport);

    const bo = view.items(.box_offsets)[index];
    const offset = view.items(.offset)[index];
    const insets = view.items(.insets)[index];
    const origin = if (out_of_flow) cb.origin else parent_content;
    const border_origin: math.Vector = .{
        .x = origin.x + offset.x + insets.x + bo.border_pos.x,
        .y = origin.y + offset.y + insets.y + bo.border_pos.y,
    };
    const content: math.Vector = .{ .x = border_origin.x + bo.content_pos.x, .y = border_origin.y + bo.content_pos.y };
    const positioned = block_type == .block and (out_of_flow or view.items(.creates_absolute_cb)[index]);
    const child_cb: Cb = if (positioned) blk: {
        const borders = view.items(.borders)[index];
        break :blk .{
            .origin = .{ .x = border_origin.x + borders.left, .y = border_origin.y + borders.top },
            .size = .{
                .w = bo.border_size.w - borders.left - borders.right,
                .h = bo.border_size.h - borders.top - borders.bottom,
            },
        };
    } else cb;

    switch (block_type) {
        .subtree_proxy => |child_id| {
            const child_view = layout.box_tree.ptr.getSubtree(child_id).view();
            if (child_view.len > 0) visit(layout, child_view, child_id, 0, border_origin, child_cb, viewport);
        },
        else => {
            var it: Subtree.Iterator = .{ .current = index + 1, .end = index + view.items(.skip)[index] };
            while (it.next(view)) |child| visit(layout, view, subtree_id, child, content, child_cb, viewport);
        },
    }
}

fn place(
    layout: *Layout,
    view: Subtree.View,
    subtree_id: Subtree.Id,
    index: Subtree.Size,
    parent_content: math.Vector,
    renderer_cb: Cb,
    viewport: Cb,
) void {
    const node = view.items(.node)[index] orelse return;
    const computer = &layout.computer;
    const box_style = computer.committedValue(.box_gen, .box_style, node) orelse return;
    const specified = computer.committedValue(.box_gen, .insets, node) orelse return;
    const env = layout.inputs.env;
    const cb: Cb = if (box_style.position == .fixed) viewport else renderer_cb;

    const left = inset(env, specified.left, cb.size.w);
    const right = inset(env, specified.right, cb.size.w);
    const top = inset(env, specified.top, cb.size.h);
    const bottom = inset(env, specified.bottom, cb.size.h);

    // Auto margins are 0 here (§10.3.7, §10.6.4: when an inset is auto);
    // with all three of the inline properties set they would share the
    // leftover — not modelled, they stay 0.
    const flags = view.items(.intrinsic)[index];
    const specified_margins = view.items(.specified_margins)[index];
    const margins = &view.items(.margins)[index];
    const ml: Unit = if (flags.margin_start_auto) 0 else specified_margins[0];
    const mr: Unit = if (flags.margin_end_auto) 0 else specified_margins[1];
    const mt = margins.top;
    const mb = margins.bottom;

    // Width.
    if (flags.width == .auto) {
        const border_w = if (left != null and right != null)
            @max(0, cb.size.w - left.? - right.? - ml - mr)
        else blk: {
            const available = @max(0, cb.size.w - (left orelse 0) - (right orelse 0) - ml - mr);
            const sizes = intrinsic.blockBorderBoxSizes(layout, view, subtree_id, index);
            break :blk @min(@max(sizes.min, available), sizes.max);
        };
        relayout.resizeItem(layout, view, subtree_id, index, border_w);
    }
    // Height.
    const bo = &view.items(.box_offsets)[index];
    if (flags.height_auto and top != null and bottom != null) {
        const border_h = @max(0, cb.size.h - top.? - bottom.? - mt - mb);
        const edges = bo.border_size.h - bo.content_size.h;
        bo.border_size.h = border_h;
        bo.content_size.h = @max(0, border_h - edges);
    }

    margins.left = ml;
    margins.right = mr;
    bo.border_pos = .{ .x = ml, .y = mt };

    // The static position: the margin box where it was laid out in flow.
    const offset = view.items(.offset)[index];
    const static_x = parent_content.x + offset.x;
    const static_y = parent_content.y + offset.y;

    const x: Unit = if (left) |l|
        cb.origin.x + l
    else if (right) |r|
        cb.origin.x + cb.size.w - r - (ml + bo.border_size.w + mr)
    else
        static_x;
    const y: Unit = if (top) |t|
        cb.origin.y + t
    else if (bottom) |b|
        cb.origin.y + cb.size.h - b - (mt + bo.border_size.h + mb)
    else
        static_y;

    // The renderer places the box at renderer_cb.origin + offset + insets.
    view.items(.offset)[index] = .{ .x = 0, .y = 0 };
    view.items(.insets)[index] = .{ .x = x - renderer_cb.origin.x, .y = y - renderer_cb.origin.y };
}

/// A used inset, or null for `auto`.
fn inset(env: *const zss.Environment, value: types.LengthPercentageAuto, base: Unit) ?Unit {
    return switch (value) {
        .px => |v| solve.length(.px, v),
        .percentage => |p| solve.percentage(p, base),
        .calc => |c| solve.calc(env, c, base).?,
        .auto => null,
        .em => unreachable,
    };
}
