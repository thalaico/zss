//! Intrinsic sizes of form controls (HTML Rendering §15.5.14 "The input
//! element as a text entry widget", §15.5.15 "The textarea element",
//! §15.5.16 "The select element"). The spec leaves the exact algorithm to
//! the user agent; this is Chromium's (Blink `LayoutTextControlSingleLine`,
//! `LayoutTextControlMultiLine`, `LayoutMenuList`), checked against headless
//! Chromium's `getBoundingClientRect` on the host's font stack:
//!
//! - text entry `<input>`: content width = ceil(avg × size) + (max − avg),
//!   where avg is the font's rounded average character width (OS/2
//!   `xAvgCharWidth`, or the width of "0" when the table is missing) and max
//!   the rounded width of its bounding box; `size` defaults to 20. Content
//!   height = the font's normal line height.
//! - `<textarea>`: content width = ceil(avg × cols) + the scrollbar
//!   reservation, height = rows × line height (cols 20, rows 2 by default).
//! - `<select>` (menulist): content width = ceil(widest option text) + the
//!   arrow area, height = line height + 2.
//!
//! The sizes replace `auto` `width`/`height` only — an author size wins —
//! and are content-box sizes, so the UA stylesheet's padding and border add
//! to them (Chromium's controls are `box-sizing: border-box` for *specified*
//! sizes, which does not change the intrinsic case). Without this, an empty
//! `<input>` laid out as an inline-block with no children was 0×0: nothing
//! to paint, nothing to hit-test, nothing for Playwright to fill.
const std = @import("std");
const zss = @import("../zss.zig");
const hb = @import("harfbuzz").c;
const Environment = zss.Environment;
const NodeId = Environment.NodeId;
const Fonts = zss.Fonts;
const Layout = zss.Layout;
const BoxGen = Layout.BoxGen;
const BlockUsedSizes = BoxGen.BlockUsedSizes;
const solve = @import("./solve.zig");

/// Chromium reserves its non-overlay vertical scrollbar in a textarea's
/// intrinsic width (measured: 16px at 100% zoom on Linux).
const textarea_scrollbar_reserve_px: f32 = 16;
/// Chromium's menulist arrow + inner padding beyond the widest option.
const select_arrow_area_px: f32 = 20;
/// Chromium's menulist inner block padding (1px above and below the text).
const select_block_padding_px: f32 = 2;
const default_input_size: u32 = 20;
const default_textarea_cols: u32 = 20;
const default_textarea_rows: u32 = 2;

const Kind = enum { text_input, textarea, select };

/// Give a form control's `auto` width and height their intrinsic values.
/// No-op for other elements, for controls without a usable font, and for
/// input types that have no text entry widget (hidden, checkbox, radio,
/// buttons, file, range, color: their boxes come from the UA stylesheet or
/// their content).
/// A control's font and its normal line metrics.
const ControlFont = struct {
    props: zss.values.groups.Tag.SpecifiedValues(.font),
    handle: Fonts.Handle,
    size_px: f32,
    /// CSS `line-height: normal` the way Blink computes it: ascent, descent
    /// and line gap each rounded to whole pixels, then summed.
    line_height_px: f32,
    /// The rounded ascent: the baseline's distance below the line's top.
    ascent_px: f32,
};

fn controlFont(layout: *Layout, node: NodeId) ?ControlFont {
    const computer = &layout.computer;
    const font_props = computer.getSpecifiedValueForNode(.box_gen, .font, node);
    if (font_props.font == .none) return null;
    const font_size_px = computer.resolvedFontSizePxForNode(.box_gen, node);
    const fonts = layout.inputs.fonts;
    const handle = fonts.queryFamily(font_props.font_family);
    if (handle == .invalid) return null;
    const design = fonts.getDesignMetrics(handle);
    if (design.units_per_em == 0) return null;
    const scale = font_size_px / @as(f32, @floatFromInt(design.units_per_em));
    const ascent_px = @round(@as(f32, @floatFromInt(design.ascender)) * scale);
    return .{
        .props = font_props,
        .handle = handle,
        .size_px = font_size_px,
        .line_height_px = ascent_px +
            @round(@as(f32, @floatFromInt(design.descender)) * scale) +
            @round(@as(f32, @floatFromInt(design.line_gap)) * scale),
        .ascent_px = ascent_px,
    };
}

/// The baseline of a form control as an inline-level box, from its
/// border-box top; null for other elements. Blink aligns a
/// control by its inner text's baseline, which is a line of the control's
/// font centred in the content box — empty or not (CSS 2.1 §10.8.1 would
/// give an empty control no baseline; HTML Rendering leaves controls to
/// the UA).
pub fn baseline(layout: *Layout, node: NodeId, box_offsets: zss.BoxTree.BoxOffsets) ?zss.math.Unit {
    const env = layout.inputs.env;
    // A checkbox or radio button aligns by its border-box bottom, its
    // bottom margin below the baseline (Blink `LayoutTheme::BaselinePosition`).
    if (env.nodeTagEql(node, "input")) {
        var buf: [32]u8 = undefined;
        if (attributeString(env, node, "type", &buf)) |t| {
            if (std.ascii.eqlIgnoreCase(t, "checkbox") or std.ascii.eqlIgnoreCase(t, "radio")) return box_offsets.border_size.h;
        }
    }
    const kind = kindOf(env, node) orelse return null;
    if (kind == .textarea) return null;
    const font = controlFont(layout, node) orelse return null;
    const upp: f32 = @floatFromInt(zss.math.units_per_pixel);
    const line_h: zss.math.Unit = @intFromFloat(font.line_height_px * upp);
    const ascent: zss.math.Unit = @intFromFloat(font.ascent_px * upp);
    return box_offsets.content_pos.y + @divFloor(box_offsets.content_size.h - line_h, 2) + ascent;
}

pub fn applyIntrinsicSizes(layout: *Layout, node: NodeId, sizes: *BlockUsedSizes) void {
    const env = layout.inputs.env;
    const kind = kindOf(env, node) orelse return;
    if (sizes.get(.inline_size) != null and !sizes.was_auto_inline_size and sizes.get(.block_size) != null) return;

    const font = controlFont(layout, node) orelse return;
    const font_props = font.props;
    const font_size_px = font.size_px;
    const fonts = layout.inputs.fonts;
    const handle = font.handle;
    const chars = fonts.getCharWidthMetrics(handle, font_size_px);
    const line_height_px = font.line_height_px;

    var width_px: f32 = 0;
    var height_px: f32 = 0;
    switch (kind) {
        .text_input => {
            const size = attributeInteger(env, node, "size", default_input_size);
            width_px = @ceil(chars.avg * @as(f32, @floatFromInt(size))) + (chars.max - chars.avg);
            height_px = line_height_px;
        },
        .textarea => {
            const cols = attributeInteger(env, node, "cols", default_textarea_cols);
            const rows = attributeInteger(env, node, "rows", default_textarea_rows);
            width_px = @ceil(chars.avg * @as(f32, @floatFromInt(cols))) + textarea_scrollbar_reserve_px;
            height_px = line_height_px * @as(f32, @floatFromInt(rows));
        },
        .select => {
            fonts.setFontSizeVariant(handle, font_props.font_weight, font_props.font_style, font_size_px);
            const hb_font = fonts.getVariant(handle, font_props.font_weight, font_props.font_style);
            width_px = @ceil(widestOptionWidth(env, node, hb_font)) + select_arrow_area_px;
            height_px = line_height_px + select_block_padding_px;
        },
    }

    // A block-level control's `width: auto` has already been filled in with
    // the containing block's width by `adjustWidthAndMargins`; the flag says
    // it was auto. Controls do not stretch (Chromium: a `display: block`
    // input keeps its intrinsic width, left-aligned).
    // The sizes are the control's own, not its content's: its intrinsic
    // contributions (shrink-to-fit floats and absolutely positioned boxes,
    // flex and table sizing) are that width, and relayout keeps the height.
    if (sizes.get(.inline_size) == null or sizes.was_auto_inline_size) {
        sizes.setValue(.inline_size, solve.positiveLength(.px, width_px));
        sizes.was_auto_inline_size = false;
        sizes.intrinsic.width = .fixed;
    }
    if (sizes.get(.block_size) == null) {
        sizes.setValue(.block_size, solve.positiveLength(.px, height_px));
        sizes.intrinsic.height_auto = false;
    }
}

fn kindOf(env: *const Environment, node: NodeId) ?Kind {
    if (env.nodeTagEql(node, "textarea")) return .textarea;
    if (env.nodeTagEql(node, "select")) return .select;
    if (!env.nodeTagEql(node, "input")) return null;
    var buf: [32]u8 = undefined;
    const type_value = attributeString(env, node, "type", &buf) orelse return .text_input;
    // HTML §4.10.5 — the types with no text entry widget. An unknown type
    // is "text" (the invalid value default).
    const widgetless = [_][]const u8{ "hidden", "checkbox", "radio", "submit", "button", "reset", "image", "file", "range", "color" };
    for (widgetless) |t| if (std.ascii.eqlIgnoreCase(type_value, t)) return null;
    return .text_input;
}

/// The value of attribute `name` on `node`, copied into `buf`; null when
/// absent or longer than the buffer.
fn attributeString(env: *const Environment, node: NodeId, name: []const u8, buf: []u8) ?[]const u8 {
    const value = env.nodeAttributeValueByName(node, name) orelse return null;
    const interner = switch (env.case_options.attribute_values) {
        .insensitive => &env.attribute_values_insensitive,
        .sensitive => &env.attribute_values_sensitive,
    };
    var it = interner.iterator(@intFromEnum(value));
    var len: usize = 0;
    while (it.next()) |segment| {
        if (len + segment.len > buf.len) return null;
        @memcpy(buf[len .. len + segment.len], segment);
        len += segment.len;
    }
    return buf[0..len];
}

/// HTML "rules for parsing non-negative integers" for a size/cols/rows
/// attribute; absent, invalid or zero values take the default (the
/// attributes' "limited to only positive numbers with fallback" reflection).
fn attributeInteger(env: *const Environment, node: NodeId, name: []const u8, default: u32) u32 {
    var buf: [32]u8 = undefined;
    const text = attributeString(env, node, name, &buf) orelse return default;
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    if (i < text.len and text[i] == '+') i += 1;
    var value: u32 = 0;
    var digits: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        digits += 1;
        if (value < 1_000_000) value = value * 10 + (text[i] - '0');
    }
    if (digits == 0 or value == 0) return default;
    return value;
}

/// The advance width in px of the widest `<option>` text under `node`
/// (through `<optgroup>`), shaped with `hb_font`; 0 without options or font.
fn widestOptionWidth(env: *const Environment, node: NodeId, hb_font: ?*hb.hb_font_t) f32 {
    const font = hb_font orelse return 0;
    var widest: f32 = 0;
    var child = env.document_tree_vtable.nodeRelative(env, node, .first_child);
    while (child) |c| : (child = env.document_tree_vtable.nodeRelative(env, c, .next_sibling)) {
        if (env.getNodeProperty(.category, c) != .element) continue;
        if (env.nodeTagEql(c, "optgroup")) {
            widest = @max(widest, widestOptionWidth(env, c, font));
            continue;
        }
        if (!env.nodeTagEql(c, "option")) continue;
        var grandchild = env.document_tree_vtable.nodeRelative(env, c, .first_child);
        while (grandchild) |g| : (grandchild = env.document_tree_vtable.nodeRelative(env, g, .next_sibling)) {
            if (env.getNodeProperty(.category, g) != .text) continue;
            const text = env.getText(env.getNodeProperty(.text, g));
            widest = @max(widest, textAdvancePx(font, std.mem.trim(u8, text, " \t\n\r")));
        }
    }
    return widest;
}

/// Total shaped advance of `text` in px (HarfBuzz 26.6 fixed point → px).
fn textAdvancePx(font: *hb.hb_font_t, text: []const u8) f32 {
    if (text.len == 0) return 0;
    const buffer = hb.hb_buffer_create() orelse return 0;
    defer hb.hb_buffer_destroy(buffer);
    hb.hb_buffer_set_direction(buffer, hb.HB_DIRECTION_LTR);
    hb.hb_buffer_set_script(buffer, hb.HB_SCRIPT_LATIN);
    hb.hb_buffer_set_language(buffer, hb.hb_language_from_string("en", -1));
    hb.hb_buffer_add_utf8(buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    if (hb.hb_buffer_allocation_successful(buffer) == 0) return 0;
    hb.hb_shape(font, buffer, null, 0);
    var count: c_uint = 0;
    const positions = hb.hb_buffer_get_glyph_positions(buffer, &count);
    var total: i64 = 0;
    var i: c_uint = 0;
    while (i < count) : (i += 1) total += positions[i].x_advance;
    return @as(f32, @floatFromInt(total)) / 64.0;
}
