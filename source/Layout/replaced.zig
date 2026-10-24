//! Sizing of replaced elements with a natural size (an image): CSS 2.1
//! §10.3.2 (width), §10.6.2 (height) and the §10.4 table of min/max
//! constraint violations for a replaced element whose width and height
//! are both `auto`. The host gives the natural size in CSS px as the node
//! properties `natural_width` / `natural_height` (0 = none — a broken or
//! not yet loaded image is sized like an empty element).
//!
//! Runs inside the size solvers, before auto margins are resolved, so a
//! block-level replaced element's margins (§10.3.4) follow from its width.

const std = @import("std");

const zss = @import("../zss.zig");
const Unit = zss.math.Unit;
const units_per_pixel = zss.math.units_per_pixel;
const NodeId = zss.Environment.NodeId;

const BlockUsedSizes = zss.Layout.BoxGen.BlockUsedSizes;

/// Give a replaced element's `auto` width and/or height their used values.
/// `width_auto` says whether the specified width was `auto` (a block's
/// auto width may already hold the containing block's width).
pub fn applyNaturalSize(env: *const zss.Environment, node: NodeId, sizes: *BlockUsedSizes, width_auto: bool) void {
    const nw = env.getNodeProperty(.natural_width, node);
    const nh = env.getNodeProperty(.natural_height, node);
    if (!(nw > 0 and nh > 0)) return;
    const height_auto = sizes.get(.block_size) == null;
    if (!width_auto and !height_auto) return;

    const upp: f32 = @floatFromInt(units_per_pixel);
    const natural_w: f32 = nw * upp;
    const natural_h: f32 = nh * upp;
    const ratio = natural_w / natural_h;

    const min_w: f32 = @floatFromInt(sizes.min_inline_size);
    const max_w: f32 = @max(min_w, units(sizes.max_inline_size));
    const min_h: f32 = @floatFromInt(sizes.min_block_size);
    const max_h: f32 = @max(min_h, units(sizes.max_block_size));

    var w: f32 = undefined;
    var h: f32 = undefined;
    if (width_auto and height_auto) {
        // §10.4: the natural size, adjusted to the min/max constraints with
        // the aspect ratio kept where they allow.
        w = natural_w;
        h = natural_h;
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
    } else if (width_auto) {
        // §10.3.2: the used height times the ratio.
        h = @floatFromInt(sizes.get(.block_size).?);
        w = std.math.clamp(h * ratio, min_w, max_w);
    } else {
        // §10.6.2: the used width divided by the ratio.
        w = @floatFromInt(sizes.get(.inline_size).?);
        h = std.math.clamp(w / ratio, min_h, max_h);
    }

    if (width_auto) {
        sizes.setValue(.inline_size, @intFromFloat(@round(w)));
        sizes.was_auto_inline_size = false;
        // The width is the element's own, not the containing block's: its
        // intrinsic contributions are that width.
        sizes.intrinsic.width = .fixed;
    }
    if (height_auto) {
        sizes.setValue(.block_size, @intFromFloat(@round(h)));
        sizes.intrinsic.height_auto = false;
    }
}

fn units(v: Unit) f32 {
    return @floatFromInt(v);
}
