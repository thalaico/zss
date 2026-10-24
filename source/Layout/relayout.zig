//! Relayout of an already generated block subtree at a new containing-block
//! inline size.
//!
//! Box generation lays a subtree out once, against the containing block it
//! saw. Some formatting contexts only learn a box's final containing block
//! later: a table cell's width is known after every cell of the table has
//! been measured (CSS 2.1 §17.5.2). Relayout recomputes the subtree from the
//! retained box tree and the specified-size facts stored on each block
//! (`Subtree.Block.intrinsic`, `percent_width`), without regenerating boxes:
//!
//! - width and inline margins per CSS 2.1 §10.3.3 (block-level, non-replaced,
//!   in normal flow): `auto` width fills the containing block minus margins,
//!   borders and padding; a fixed width keeps its used value; a percentage
//!   resolves against the new containing block; auto margins of a non-auto
//!   width share the remaining space.
//! - inline formatting contexts re-split their lines at the new width;
//! - flex, grid and table containers rerun their own algorithm;
//! - `auto` heights are recomputed bottom-up from the relaid children.
//!
//! Flex and grid items are sized by their container's algorithm, which
//! calls back into `resizeItem` / `relayoutChild` here, so every
//! formatting context relays out through the same rules.
//!
//! A BFC root whose formatting context has floats is relaid by `bfc.zig`.
//!
//! Known limits (documented, not approximated): padding percentages are not
//! re-resolved; min/max-height are not re-applied to a recomputed auto
//! height outside `bfc.zig`.
const std = @import("std");
const zss = @import("../zss.zig");
const Unit = zss.math.Unit;
const Layout = zss.Layout;
const BoxTree = zss.BoxTree;
const Subtree = BoxTree.Subtree;
const BoxGen = Layout.BoxGen;

const flow = @import("./flow.zig");
const solve = @import("./solve.zig");
const grid = @import("./grid.zig");
const table = @import("./table.zig");
const bfc = @import("./bfc.zig");
const inline_layout = @import("./inline.zig");

/// Used inline size and inline margins of a block-level box.
pub const InlineSize = struct {
    margin_left: Unit,
    margin_right: Unit,
    content_w: Unit,
};

/// The used width and inline margins of block `index` in a containing block
/// of inline size `cb_width`, per CSS 2.1 §10.3.3 (block-level, non-replaced,
/// in normal flow). Grid items with `justify-self: normal` resolve the same
/// way against their grid area (CSS Grid 1 §6.2, CSS Box Alignment 3 §6.1).
pub fn usedInlineSize(env: *const zss.Environment, subtree: Subtree.View, index: Subtree.Size, cb_width: Unit) InlineSize {
    const bo = subtree.items(.box_offsets)[index];
    const margins = subtree.items(.margins)[index];
    const flags = subtree.items(.intrinsic)[index];
    const edges = bo.border_size.w - bo.content_size.w;

    // Start from the specified margins: the used end margin of an
    // over-constrained block absorbed the old leftover space. Percentage
    // margins (stored as 0) keep their used value.
    const specified = subtree.items(.specified_margins)[index];
    var margin_left: Unit = if (flags.margin_start_auto) 0 else if (specified[0] != 0) specified[0] else margins.left;
    var margin_right: Unit = if (flags.margin_end_auto) 0 else if (specified[1] != 0) specified[1] else if (flags.width == .auto) margins.right else 0;
    const content_w: Unit = switch (flags.width) {
        .fixed => bo.content_size.w,
        .percentage => blk: {
            const resolved: Unit = switch (subtree.items(.percent_width)[index]) {
                .percentage => |p| @intFromFloat(@round(p * @as(f32, @floatFromInt(cb_width)))),
                .calc => |c| solve.positiveCalc(env, c, cb_width).?,
            };
            break :blk @max(0, if (flags.border_box) resolved - edges else resolved);
        },
        .auto => @max(0, cb_width - edges - margin_left - margin_right),
    };
    if (flags.width != .auto) {
        // CSS 2.1 §10.3.3: auto margins take the remaining space (equally
        // when both are auto); with neither auto the end margin is ignored.
        const remaining = cb_width - content_w - edges;
        if (flags.margin_start_auto and flags.margin_end_auto) {
            margin_left = @max(0, @divFloor(remaining, 2));
            margin_right = remaining - margin_left;
        } else if (flags.margin_start_auto) {
            margin_left = remaining - margin_right;
        } else {
            margin_right = remaining - margin_left;
        }
    }
    return .{ .margin_left = margin_left, .margin_right = margin_right, .content_w = content_w };
}

/// Relayout block `index` for a containing block of inline size `cb_width`:
/// its used width and margins, then its content. The content is only laid
/// out again when the content box width changed (it depends on nothing
/// else that a relayout can change).
pub fn relayoutBlock(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size, cb_width: Unit) void {
    const used = usedInlineSize(layout.inputs.env, subtree, index, cb_width);
    const bo = &subtree.items(.box_offsets)[index];
    const margins = &subtree.items(.margins)[index];
    const edges = bo.border_size.w - bo.content_size.w;
    const changed = used.content_w != bo.content_size.w;
    margins.left = used.margin_left;
    margins.right = used.margin_right;
    bo.border_pos.x = used.margin_left;
    bo.border_size.w = used.content_w + edges;
    bo.content_size.w = used.content_w;

    if (changed) relayoutContent(layout, subtree, subtree_id, index, used.content_w);
}

/// Relayout in-flow child `index` (a block, an anonymous inline formatting
/// context or a subtree proxy) for a containing block of inline size
/// `cb_width`.
pub fn relayoutChild(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size, cb_width: Unit) void {
    switch (subtree.items(.type)[index]) {
        .block => relayoutBlock(layout, subtree, subtree_id, index, cb_width),
        .ifc_container => |ifc_id| relayoutIfc(layout, subtree, index, ifc_id, cb_width),
        .subtree_proxy => |child_id| {
            const child_subtree = layout.box_tree.ptr.getSubtree(child_id).view();
            relayoutBlock(layout, child_subtree, child_id, 0, cb_width);
            syncProxy(subtree, index, child_subtree);
        },
    }
}

/// Give flex or grid item `index` the border-box inline size `border_w`
/// chosen by its container's sizing algorithm, and lay out its content at
/// that size.
pub fn resizeItem(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size, border_w: Unit) void {
    switch (subtree.items(.type)[index]) {
        .block => {
            const bo = &subtree.items(.box_offsets)[index];
            if (bo.border_size.w == border_w) return;
            const content_w = @max(0, border_w - (bo.border_size.w - bo.content_size.w));
            bo.border_size.w = border_w;
            bo.content_size.w = content_w;
            relayoutContent(layout, subtree, subtree_id, index, content_w);
        },
        .ifc_container => |ifc_id| {
            if (subtree.items(.box_offsets)[index].border_size.w == border_w) return;
            relayoutIfc(layout, subtree, index, ifc_id, border_w);
        },
        .subtree_proxy => |child_id| {
            const child_subtree = layout.box_tree.ptr.getSubtree(child_id).view();
            resizeItem(layout, child_subtree, child_id, 0, border_w);
            syncProxy(subtree, index, child_subtree);
        },
    }
}

/// Re-split the lines of the inline formatting context at child `index` for
/// a content width of `width`.
fn relayoutIfc(layout: *Layout, subtree: Subtree.View, index: Subtree.Size, ifc_id: BoxTree.InlineFormattingContext.Id, width: Unit) void {
    const ifc = layout.box_tree.ptr.getIfc(ifc_id);
    ifc.line_boxes.clearRetainingCapacity();
    const result = inline_layout.splitIntoLineBoxes(layout, subtree, ifc, width, null) catch return;
    // CSS 2.1 §9.2.2.1: an IFC with no visible content (inter-element white
    // space) contributes no height — the same rule inline.endMode applies at
    // generation.
    const height: Unit = if (ifc.has_visible_content) result.height else 0;
    const bo = &subtree.items(.box_offsets)[index];
    bo.border_size = .{ .w = width, .h = height };
    bo.content_size = .{ .w = width, .h = height };
}

/// A subtree proxy's box is its child subtree root's border box.
fn syncProxy(subtree: Subtree.View, index: Subtree.Size, child_subtree: Subtree.View) void {
    const root_bo = child_subtree.items(.box_offsets)[0];
    const proxy_bo = &subtree.items(.box_offsets)[index];
    proxy_bo.border_size = root_bo.border_size;
    proxy_bo.content_size = root_bo.border_size;
}

/// Relayout the content of block `index`, whose content box is now
/// `content_w` wide, and recompute its auto height.
pub fn relayoutContent(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size, content_w: Unit) void {
    const box_tree = layout.box_tree.ptr;
    const bo = &subtree.items(.box_offsets)[index];
    const skip = subtree.items(.skip)[index];

    if (table.relayoutTable(layout, subtree, subtree_id, index, content_w)) |height| {
        setContentHeight(subtree, index, height);
        return;
    }

    if (layout.box_gen.grid_containers.getPtr(.{ .subtree_id = subtree_id, .block_idx = index })) |info| {
        const height = grid.layoutGridChildrenInSubtree(layout, subtree, subtree_id, index, skip, content_w, null, info.column_gap, info.row_gap, info.columns, info.rows, info.areas, &info.child_area_hashes, info.child_count);
        setContentHeight(subtree, index, height);
        return;
    }

    if (layout.box_gen.flex_containers.getPtr(.{ .subtree_id = subtree_id, .block_idx = index })) |info| {
        // The flex algorithm sizes each item and lays out its content at
        // the size it was given (`resizeItem`).
        const container_height: ?Unit = if (subtree.items(.intrinsic)[index].height_auto) null else bo.content_size.h;
        const height = flow.offsetChildBlocksFlex(layout, subtree, subtree_id, index, skip, content_w, container_height, info.justify, info.align_items, info.flex_gap, info.flex_is_column, info.flex_wrap);
        if (subtree.items(.intrinsic)[index].height_auto) setContentHeight(subtree, index, height);
        return;
    }

    // A formatting context with floats is laid out top-down (bfc.zig).
    if (subtree.items(.bfc_floats)[index]) {
        const height = bfc.layoutBfc(layout, subtree, subtree_id, index, skip, content_w);
        if (subtree.items(.intrinsic)[index].height_auto) setContentHeight(subtree, index, height);
        return;
    }

    // Flow: each child against this content box.
    var child = index + 1;
    while (child < index + skip) : (child += subtree.items(.skip)[child]) {
        if (subtree.items(.out_of_flow)[child]) continue;
        relayoutChild(layout, subtree, subtree_id, child, content_w);
    }

    // Vertical positions and the auto height (CSS 2.1 §10.6.3). A BFC root's
    // first child margin cannot escape (§8.3.1).
    var parent_edge = bo.content_pos.y;
    if (subtree.items(.is_bfc)[index] and parent_edge == 0) parent_edge = 1;
    const result = flow.offsetChildBlocks(subtree, index, skip, content_w, parent_edge, box_tree);
    if (subtree.items(.intrinsic)[index].height_auto) setContentHeight(subtree, index, result.auto_height);
}

/// Set the content height of block `index`, keeping its block-axis edges.
pub fn setContentHeight(subtree: Subtree.View, index: Subtree.Size, height: Unit) void {
    const bo = &subtree.items(.box_offsets)[index];
    const top = bo.content_pos.y;
    const bottom = bo.border_size.h - bo.content_pos.y - bo.content_size.h;
    bo.content_size.h = height;
    bo.border_size.h = top + height + bottom;
}
