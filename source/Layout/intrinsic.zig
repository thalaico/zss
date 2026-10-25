//! Intrinsic inline sizes of laid-out boxes (CSS Box Sizing 3 §5 "Intrinsic
//! Size Determination", CSS Sizing 3 §5.1 "Intrinsic Contributions").
//!
//! Computed from the box tree after box generation, the way the table, flex
//! and grid algorithms need them: every box's min-content and max-content
//! inline size, and its outer contribution to its parent.
//!
//! - Inline formatting context (CSS Text 3 §5): max-content is the widest
//!   line when only forced breaks (`<br>`, preserved newlines) are taken;
//!   min-content is the widest unbreakable segment when every soft wrap
//!   opportunity is taken. Soft wrap opportunities are the ones line
//!   breaking uses (`Ifc.break_opportunities`: collapsed spaces) plus both
//!   sides of every atomic inline (Chromium breaks around inline-blocks and
//!   replaced elements). A collapsible space at the end of a line hangs, so
//!   it does not count toward the segment it ends. Inline box padding,
//!   border and margin (BoxStart/BoxEnd advances) belong to the adjacent
//!   segment.
//! - Block container: the max of its in-flow children's contributions plus
//!   its own padding and border. Floats are in-flow for this purpose (their
//!   contributions add to the line in max-content; CSS 2.1 leaves the exact
//!   rule to the UA and Chromium takes the max, which is done here).
//! - Row flex container (CSS Flexbox 1 §9.9.1): max-content is the sum of
//!   its items' max-content contributions plus gaps; min-content is their
//!   sum for `nowrap` and the largest one when lines may wrap. A column flex
//!   container behaves as a block container. A grid container also does for
//!   now (CSS Grid 1 §12 track-based intrinsic sizes are not implemented).
//! - A box whose `width` is a fixed length contributes that border-box width
//!   (already clamped by min/max-width at layout); `auto` and percentage
//!   widths contribute their content size (CSS Sizing 3 §5.2.1: a cyclic
//!   percentage behaves as `auto` for intrinsic contributions). `auto` inline
//!   margins contribute zero.
const std = @import("std");
const zss = @import("../zss.zig");
const math = zss.math;
const Unit = math.Unit;
const BoxTree = zss.BoxTree;
const Subtree = BoxTree.Subtree;
const Ifc = BoxTree.InlineFormattingContext;
const BoxTreeManaged = zss.Layout.BoxTreeManaged;
const Layout = zss.Layout;
const table = @import("./table.zig");

pub const Sizes = struct {
    min: Unit = 0,
    max: Unit = 0,

    fn include(a: *Sizes, b: Sizes) void {
        a.min = @max(a.min, b.min);
        a.max = @max(a.max, b.max);
    }
};

/// Outer min/max-content contribution of block `index` in `subtree` to its
/// containing block: border box (or content-based size) plus non-auto
/// inline margins.
pub fn blockContribution(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size) Sizes {
    var sizes = blockBorderBoxSizes(layout, subtree, subtree_id, index);
    const margins = subtree.items(.specified_margins)[index];
    const margin_sum: Unit = margins[0] + margins[1];
    sizes.min += margin_sum;
    sizes.max += margin_sum;
    return sizes;
}

/// Min/max-content border-box inline size of block `index`.
pub fn blockBorderBoxSizes(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size) Sizes {
    const bo = subtree.items(.box_offsets)[index];
    const intrinsic = subtree.items(.intrinsic)[index];
    // A table's widths come from its columns (CSS 2.1 §17.5.2), not from
    // its rows as flow children.
    if (table.intrinsicSizes(layout, subtree, subtree_id, index)) |sizes| return sizes;
    if (intrinsic.width == .fixed) return .{ .min = bo.border_size.w, .max = bo.border_size.w };

    const edges = bo.border_size.w - bo.content_size.w;
    var content = contentSizes(layout, subtree, subtree_id, index);
    content.min += edges;
    content.max += edges;
    return content;
}

/// Min/max-content border-box size of block `index` from its content alone,
/// ignoring a fixed `width` (a table cell's specified width is combined with
/// this by the table algorithm).
pub fn contentBorderBoxSizes(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size) Sizes {
    const bo = subtree.items(.box_offsets)[index];
    const edges = bo.border_size.w - bo.content_size.w;
    var content = contentSizes(layout, subtree, subtree_id, index);
    content.min += edges;
    content.max += edges;
    return content;
}

/// Min/max-content size of the content box of block `index`, whose subtree
/// size is `skip` (passed in: box generation writes it to the subtree only
/// when the block is finished).
pub fn contentBoxSizes(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size, skip: Subtree.Size) Sizes {
    return contentSizesTo(layout, subtree, subtree_id, index, index + skip);
}

/// Min/max-content size of the content box of block `index`: the widest
/// in-flow child contribution, or for a row flex container the sum of its
/// items' contributions (CSS Flexbox 1 §9.9.1).
fn contentSizes(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size) Sizes {
    return contentSizesTo(layout, subtree, subtree_id, index, index + subtree.items(.skip)[index]);
}

fn contentSizesTo(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size, end: Subtree.Size) Sizes {
    const box_tree = layout.box_tree.ptr;
    var result: Sizes = .{};
    const skips = subtree.items(.skip);
    const types = subtree.items(.type);
    if (layout.box_gen.grid_containers.get(.{ .subtree_id = subtree_id, .block_idx = index })) |info| {
        // CSS Grid 1 §12: with only fixed column tracks, both intrinsic
        // sizes are the tracks plus gaps.
        const columns = info.columns;
        if (columns.count > 0) fixed: {
            var sum: Unit = 0;
            for (columns.tracks[0..columns.count]) |track| {
                if (track.kind != .fixed) break :fixed;
                sum += track.value;
            }
            sum += info.column_gap * @as(Unit, columns.count - 1);
            return .{ .min = sum, .max = sum };
        }
    }
    const flex_row = if (layout.box_gen.flex_containers.get(.{ .subtree_id = subtree_id, .block_idx = index })) |info| (if (info.flex_is_column) null else info) else null;
    var items: Unit = 0;
    var child = index + 1;
    while (child < end) : (child += skips[child]) {
        if (subtree.items(.out_of_flow)[child]) continue;
        const sizes = switch (types[child]) {
            .ifc_container => |ifc_id| blk: {
                const ifc = box_tree.getIfc(ifc_id);
                // Inter-element white space is not a flex item (§4).
                if (flex_row != null and !ifc.has_visible_content) continue;
                break :blk ifcSizes(layout, ifc, subtree, subtree_id);
            },
            .subtree_proxy => |child_id| subtreeSizes(layout, child_id),
            else => blockContribution(layout, subtree, subtree_id, child),
        };
        if (flex_row) |info| {
            // §9.9.1: max-content is the sum of the items' max-content
            // contributions; min-content is their sum on a single line and
            // the largest one when lines may wrap. Gaps add between items.
            const gap: Unit = if (items > 0) info.flex_gap else 0;
            result.max += sizes.max + gap;
            result.min = if (info.flex_wrap == .nowrap) result.min + sizes.min + gap else @max(result.min, sizes.min);
            items += 1;
        } else result.include(sizes);
    }
    return result;
}

/// The content a subtree proxy stands for: the widest contribution among
/// the subtree's top-level entries (inline formatting contexts, blocks and
/// further proxies).
fn subtreeSizes(layout: *Layout, subtree_id: Subtree.Id) Sizes {
    const box_tree = layout.box_tree.ptr;
    const view = box_tree.getSubtree(subtree_id).view();
    const skips = view.items(.skip);
    var result: Sizes = .{};
    var entry: Subtree.Size = 0;
    while (entry < view.len) : (entry += skips[entry]) {
        if (view.items(.out_of_flow)[entry]) continue;
        result.include(switch (view.items(.type)[entry]) {
            .ifc_container => |ifc_id| ifcSizes(layout, box_tree.getIfc(ifc_id), view, subtree_id),
            .subtree_proxy => |child_id| subtreeSizes(layout, child_id),
            else => blockContribution(layout, view, subtree_id, entry),
        });
    }
    return result;
}

/// Min/max-content inline size of an inline formatting context. `subtree`
/// is the subtree holding the IFC's inline-block boxes.
pub fn ifcSizes(layout: *Layout, ifc: *const Ifc, subtree: Subtree.View, subtree_id: Subtree.Id) Sizes {
    if (ifc.glyphs.len == 0) return .{};
    const glyphs = ifc.glyphs.slice();
    const indices = glyphs.items(.index);
    const metrics = glyphs.items(.metrics);
    const breaks = ifc.break_opportunities.items;

    var result: Sizes = .{};
    var line: Unit = 0; // current line for max-content
    var line_has_content = false;
    var hanging: Unit = 0; // advance of collapsible spaces ending the line
    var segment: Unit = 0; // current unbreakable segment for min-content
    var next_break: usize = 0;

    var i: usize = 0;
    while (i < glyphs.len) : (i += 1) {
        if (indices[i] == 0) {
            // Special glyph pair [0, encoded]; its advance is on the first entry.
            const advance = metrics[i].advance;
            i += 1;
            const special = Ifc.Special.decode(indices[i]);
            switch (@as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)))) {
                .LineBreak => {
                    result.max = @max(result.max, line - hanging);
                    line = 0;
                    hanging = 0;
                    line_has_content = false;
                    result.min = @max(result.min, segment);
                    segment = 0;
                },
                .InlineBlock => {
                    // Atomic inline: soft wrap opportunity on both sides.
                    const block_index: Subtree.Size = special.data;
                    const atomic = inlineBlockContribution(layout, subtree, subtree_id, block_index);
                    line += atomic.max;
                    hanging = 0;
                    line_has_content = true;
                    result.min = @max(result.min, segment);
                    result.min = @max(result.min, atomic.min);
                    segment = 0;
                },
                // Out of flow: no contribution.
                .OutOfFlowInline, .OutOfFlowBlock => {},
                // A preserved tab, at its advance in the last line layout.
                .ZeroGlyphIndex, .Tab => {
                    line += advance;
                    hanging = 0;
                    line_has_content = true;
                    segment += advance;
                },
                .BoxStart, .BoxEnd => {
                    line += advance;
                    segment += advance;
                },
            }
        } else {
            const advance = metrics[i].advance;
            // Advance past break opportunities that precede this glyph.
            while (next_break < breaks.len and breaks[next_break] < i) next_break += 1;
            if (next_break < breaks.len and breaks[next_break] == i) {
                // A collapsed space: removed at the start of a line, hangs at
                // its end, and ends the current unbreakable segment.
                if (line_has_content) {
                    line += advance;
                    hanging += advance;
                }
                result.min = @max(result.min, segment);
                segment = 0;
            } else {
                line += advance;
                hanging = 0;
                line_has_content = true;
                segment += advance;
            }
        }
    }
    result.max = @max(result.max, line - hanging);
    result.min = @max(result.min, segment);
    return result;
}

fn inlineBlockContribution(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size) Sizes {
    switch (subtree.items(.type)[index]) {
        .subtree_proxy => |child_id| {
            const child_subtree = layout.box_tree.ptr.getSubtree(child_id).view();
            var sizes = blockBorderBoxSizes(layout, child_subtree, child_id, 0);
            const margins = subtree.items(.margins)[index];
            // An inline-block's margins are never over-constrained.
            sizes.min += margins.left + margins.right;
            sizes.max += margins.left + margins.right;
            return sizes;
        },
        else => return blockContribution(layout, subtree, subtree_id, index),
    }
}
