//! Sizing of replaced elements: CSS 2.1 §10.3.2 (width), §10.6.2 (height)
//! and the §10.4 table of min/max constraint violations for a replaced
//! element with a natural ratio whose width and height are both `auto`.
//! The host gives the natural dimensions and ratio (CSS Images 3 §4.1) in
//! CSS px as the node properties `natural_width` / `natural_height` /
//! `natural_ratio`; any of them may be absent (an `<svg>` with only a
//! `viewBox` has a ratio and no dimensions). An image whose natural size is
//! not known (`Replaced.unsized_image`: not loaded, broken) is sized like an
//! empty element.
//!
//! Runs inside the size solvers, before auto margins are resolved, so a
//! block-level replaced element's margins (§10.3.4) follow from its width.

const std = @import("std");

const zss = @import("../zss.zig");
const Unit = zss.math.Unit;
const units_per_pixel = zss.math.units_per_pixel;
const NodeId = zss.Environment.NodeId;

const BlockUsedSizes = zss.Layout.BoxGen.BlockUsedSizes;

/// CSS 2.1 §10.3.2 / §10.6.2: the size of a replaced element with no natural
/// width, height or ratio to go by.
const default_width_px: f32 = 300;
const default_height_px: f32 = 150;

/// Give a replaced element's `auto` width and/or height their used values.
/// `width_auto` says whether the specified width was `auto` (a block's
/// auto width may already hold the containing block's width).
/// `stretch_width` is the width the constraint equation of a block-level
/// non-replaced element in normal flow gives (the containing block's width
/// less the element's margins, borders and padding), when it is known: §10.3.2
/// suggests it for an element with a natural ratio and no natural dimensions,
/// and Chromium uses it.
pub fn applyNaturalSize(env: *const zss.Environment, node: NodeId, sizes: *BlockUsedSizes, width_auto: bool, stretch_width: ?Unit) void {
    switch (env.getNodeProperty(.replaced, node)) {
        .no, .unsized_image => return,
        .object => {},
    }
    const height_auto = sizes.get(.block_size) == null;
    if (!width_auto and !height_auto) return;

    const upp: f32 = @floatFromInt(units_per_pixel);
    const natural_w: ?f32 = if (env.getNodeProperty(.natural_width, node)) |w| w * upp else null;
    const natural_h: ?f32 = if (env.getNodeProperty(.natural_height, node)) |h| h * upp else null;
    const ratio: ?f32 = env.getNodeProperty(.natural_ratio, node) orelse blk: {
        const w = natural_w orelse break :blk null;
        const h = natural_h orelse break :blk null;
        break :blk if (w > 0 and h > 0) w / h else null;
    };

    const min_w: f32 = @floatFromInt(sizes.min_inline_size);
    const max_w: f32 = @max(min_w, units(sizes.max_inline_size));
    const min_h: f32 = @floatFromInt(sizes.min_block_size);
    const max_h: f32 = @max(min_h, units(sizes.max_block_size));

    var w: f32 = undefined;
    var h: f32 = undefined;
    if (width_auto and height_auto) {
        // §10.3.2 and §10.6.2 for both `auto`, in their order.
        if (natural_w) |nw| {
            w = nw;
            h = natural_h orelse if (ratio) |r| nw / r else default_height_px * upp;
        } else if (natural_h) |nh| {
            h = nh;
            w = if (ratio) |r| nh * r else default_width_px * upp;
        } else if (ratio) |r| {
            w = if (stretch_width) |sw| @floatFromInt(@max(0, sw)) else default_width_px * upp;
            h = w / r;
        } else {
            w = default_width_px * upp;
            h = default_height_px * upp;
        }
        if (ratio != null and w > 0 and h > 0) {
            // §10.4: the size adjusted to the min/max constraints with the
            // ratio kept where they allow.
            if (w > max_w and h > max_h) {
                if (max_w / w <= max_h / h) {
                    h = @max(min_h, max_w * h / w);
                    w = max_w;
                } else {
                    w = @max(min_w, max_h * w / h);
                    h = max_h;
                }
            } else if (w < min_w and h < min_h) {
                if (min_w / w <= min_h / h) {
                    w = @min(max_w, min_h * w / h);
                    h = min_h;
                } else {
                    h = @min(max_h, min_w * h / w);
                    w = min_w;
                }
            } else if (w < min_w and h > max_h) {
                w = min_w;
                h = max_h;
            } else if (w > max_w and h < min_h) {
                w = max_w;
                h = min_h;
            } else if (w > max_w) {
                h = @max(max_w * h / w, min_h);
                w = max_w;
            } else if (w < min_w) {
                h = @min(min_w * h / w, max_h);
                w = min_w;
            } else if (h > max_h) {
                w = @max(max_h * w / h, min_w);
                h = max_h;
            } else if (h < min_h) {
                w = @min(min_h * w / h, max_w);
                h = min_h;
            }
        } else {
            w = std.math.clamp(w, min_w, max_w);
            h = std.math.clamp(h, min_h, max_h);
        }
    } else if (width_auto) {
        // §10.3.2: the used height times the ratio; else the natural width;
        // else 300px.
        h = @floatFromInt(sizes.get(.block_size).?);
        w = std.math.clamp(if (ratio) |r| h * r else natural_w orelse default_width_px * upp, min_w, max_w);
    } else {
        w = @floatFromInt(sizes.get(.inline_size).?);
        h = @floatFromInt(heightForWidth(env, node, sizes.get(.inline_size).?, sizes.min_block_size, sizes.max_block_size));
        // Laid out again at another width (a grid area, a flex item's size), the
        // height follows (`relayout.relayoutContent`).
        sizes.intrinsic.replaced_auto_height = true;
    }

    if (width_auto) {
        sizes.setValue(.inline_size, zss.math.unitsFromFloat(@round(w)));
        sizes.was_auto_inline_size = false;
        // The width is the element's own, not the containing block's: its
        // intrinsic contributions are that width.
        sizes.intrinsic.width = .fixed;
    }
    if (height_auto) {
        sizes.setValue(.block_size, zss.math.unitsFromFloat(@round(h)));
        sizes.intrinsic.height_auto = false;
    }
}

/// CSS 2.1 §10.6.2: the `auto` height of replaced element `node` at the used width
/// `width`: the width divided by the natural ratio; else the natural height; else
/// 150px — within the min/max heights.
pub fn heightForWidth(env: *const zss.Environment, node: NodeId, width: Unit, min_block_size: Unit, max_block_size: Unit) Unit {
    const upp: f32 = @floatFromInt(units_per_pixel);
    const natural_w: ?f32 = if (env.getNodeProperty(.natural_width, node)) |nw| nw * upp else null;
    const natural_h: ?f32 = if (env.getNodeProperty(.natural_height, node)) |nh| nh * upp else null;
    const ratio: ?f32 = env.getNodeProperty(.natural_ratio, node) orelse blk: {
        const nw = natural_w orelse break :blk null;
        const nh = natural_h orelse break :blk null;
        break :blk if (nw > 0 and nh > 0) nw / nh else null;
    };
    const min_h: f32 = @floatFromInt(min_block_size);
    const max_h: f32 = @max(min_h, units(max_block_size));
    const w: f32 = @floatFromInt(width);
    const h = std.math.clamp(if (ratio) |r| w / r else natural_h orelse default_height_px * upp, min_h, max_h);
    return zss.math.unitsFromFloat(@round(h));
}

fn units(v: Unit) f32 {
    return @floatFromInt(v);
}
