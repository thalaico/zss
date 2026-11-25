const Fonts = @This();

const std = @import("std");
const hb = @import("harfbuzz").c;
const types = @import("values/types.zig");
const font_face = @import("font_face.zig");

pub const Handle = enum(u8) {
    invalid,
    sans_serif,
    serif,
    monospace,
    system_ui,
    _,
};

pub const FontEntry = struct {
    hb_font: *hb.hb_font_t,
    ft_face: hb.FT_Face,
    /// The family's other faces (CSS Fonts 4 §5.2 font matching reduced to
    /// the bold / italic axes). Null falls back to the regular face: a run
    /// is then shaped with regular advances, which is what the painter can
    /// draw without a matching face anyway.
    bold: ?Variant = null,
    italic: ?Variant = null,
    bold_italic: ?Variant = null,

    pub const Variant = struct {
        hb_font: *hb.hb_font_t,
        ft_face: hb.FT_Face,
    };

    /// The face for a run's font-weight / font-style (§5.2 step 4, with the
    /// bold threshold at 600 and oblique treated as italic).
    pub fn variantFor(entry: FontEntry, weight: types.FontWeight, style: types.FontStyle) Variant {
        const wants_bold = weight.isBold();
        const wants_italic = style != .normal;
        if (wants_bold and wants_italic) {
            if (entry.bold_italic) |v| return v;
            if (entry.bold) |v| return v;
            if (entry.italic) |v| return v;
        } else if (wants_bold) {
            if (entry.bold) |v| return v;
        } else if (wants_italic) {
            if (entry.italic) |v| return v;
        }
        return .{ .hb_font = entry.hb_font, .ft_face = entry.ft_face };
    }
};

/// Opaque handle to the vendored FreeType library instance.
/// All font loading and HarfBuzz shaping must go through the same
/// FreeType instance — mixing system and vendored FreeType causes
/// FT_Set_Char_Size to silently fail (different library state).
pub const FT_Library = hb.FT_Library;
pub const FT_Face = hb.FT_Face;
pub const HbFont = hb.hb_font_t;

/// Initialize the vendored FreeType library. Returns null on failure.
/// The caller must call doneFreeType() when finished.
pub fn initFreeType() ?FT_Library {
    var lib: hb.FT_Library = undefined;
    if (hb.FT_Init_FreeType(&lib) != 0) return null;
    return lib;
}

/// Release the vendored FreeType library.
pub fn doneFreeType(lib: FT_Library) void {
    _ = hb.FT_Done_FreeType(lib);
}

/// Load a font face from a file path using the vendored FreeType.
/// Returns null if the file cannot be opened or parsed.
pub fn loadFace(lib: FT_Library, path: [*:0]const u8) ?FT_Face {
    return loadFaceAt(lib, path, 0);
}

/// The face at `index` of a font file (a collection holds several).
pub fn loadFaceAt(lib: FT_Library, path: [*:0]const u8, index: c_long) ?FT_Face {
    var face: hb.FT_Face = undefined;
    if (hb.FT_New_Face(lib, path, index, &face) != 0) return null;
    return face;
}

/// Release a font face loaded with loadFace().
pub fn doneFace(face: FT_Face) void {
    _ = hb.FT_Done_Face(face);
}

/// HarfBuzz positions per CSS px: 16.16 fixed point, as Blink scales its fonts
/// (`HarfBuzzFace::GetScaledFont`: `SkiaScalarToHarfBuzzPosition(size)`). FreeType's
/// 26.6 (the scale hb-ft takes from the face) rounds every advance to 1/64 px: up to
/// half a layout unit per glyph (DejaVu Sans "iiiiiiiiii" came out 5/64 px wide of
/// Chromium).
pub const hb_units_per_px = 65536;

/// Create a HarfBuzz font from a vendored FT_Face: HarfBuzz's own OpenType font
/// functions (unhinted advances from `hmtx`, GPOS kerning, outline extents) — the
/// advances Skia gives Blink with subpixel positioning — over the FreeType face's
/// tables. Size it with `setFaceSize`.
pub fn createHbFont(face: FT_Face) ?*hb.hb_font_t {
    const hb_face = hb.hb_ft_face_create_referenced(face) orelse return null;
    defer hb.hb_face_destroy(hb_face);
    const font = hb.hb_font_create(hb_face) orelse return null;
    if (hb.hb_font_is_immutable(font) != 0) return null; // the empty font: out of memory
    return font;
}

/// Size a face for `size_px`: the FreeType size (ascent / descent metrics, glyph
/// loading) and the HarfBuzz scale in 16.16 (Blink: the size × 65536 as an int,
/// truncated; `ptem` the size).
pub fn setFaceSize(ft_face: FT_Face, hb_font: *hb.hb_font_t, size_px: f32) void {
    const size_26_6: i32 = @intFromFloat(size_px * 64.0);
    _ = hb.FT_Set_Char_Size(ft_face, 0, size_26_6, 72, 72);
    const max_scale: f32 = @floatFromInt(std.math.maxInt(c_int) - 128);
    const scale: c_int = @intFromFloat(std.math.clamp(size_px * @as(f32, hb_units_per_px), 0, max_scale));
    hb.hb_font_set_scale(hb_font, scale, scale);
    hb.hb_font_set_ptem(hb_font, size_px);
}

/// Destroy a HarfBuzz font created with createHbFont().
pub fn destroyHbFont(font: *hb.hb_font_t) void {
    hb.hb_font_destroy(font);
}

/// Per-family font slots. Externally managed (caller owns the hb_font_t).
fonts: [4]?FontEntry = .{ null, null, null, null },
/// Custom font slots for @font-face registered fonts.
/// Handles 5..5+MAX_CUSTOM-1 map to custom_entries[0..MAX_CUSTOM-1].
custom_entries: [MAX_CUSTOM]?FontEntry = .{null} ** MAX_CUSTOM,
custom_count: u8 = 0,
/// The composite faces of the @font-face families (CSS Fonts 4 §4.5: the faces of a
/// family whose descriptors differ only in `unicode-range`), by custom index and
/// variant (regular, bold, italic, bold italic). Empty: no composite (an installed
/// family, or a variant no rule serves). The host owns the slices.
composites: [MAX_CUSTOM][4][]const SubFace = .{.{ &.{}, &.{}, &.{}, &.{} }} ** MAX_CUSTOM,

pub const MAX_CUSTOM = 24;


/// One face of a composite face: an @font-face rule's font.
pub const SubFace = struct {
    /// Null while the face is not loaded.
    hb_font: ?*hb.hb_font_t = null,
    ft_face: ?FT_Face = null,
    /// The rule's `unicode-range`; empty: every code point.
    ranges: []const font_face.CodepointRange = &.{},
    /// The host's id of the face, to request it (`Choice.pending`).
    id: u16,
    /// The face will not load (its sources failed): never used or waited for.
    failed: bool = false,

    pub fn inRange(sub: SubFace, cp: u21) bool {
        if (sub.ranges.len == 0) return true;
        for (sub.ranges) |r| if (cp >= r.first and cp <= r.last) return true;
        return false;
    }
};

/// The faces a character's glyph comes from (`faceFor`).
pub const Choice = struct {
    hb_font: *hb.hb_font_t,
    ft_face: FT_Face,
    /// A face before the chosen one would serve the character but is not loaded
    /// (CSS Fonts 4 §4.4): its family and id. The text is drawn with the chosen face
    /// meanwhile, and not at all during the face's block period.
    pending: ?Pending = null,

    pub const Pending = struct { family: u8, face: u16 };
};

/// Set the composite face of custom family `custom_index` for `variant` (0 regular,
/// 1 bold, 2 italic, 3 bold italic), its faces in the order they are tried (CSS Fonts 4
/// §4.5: the rule defined last first).
pub fn setComposite(fonts: *Fonts, custom_index: u8, variant: usize, faces: []const SubFace) void {
    if (custom_index >= MAX_CUSTOM) return;
    fonts.composites[custom_index][variant] = faces;
}

/// The composite of a custom family for a weight and style, falling back as
/// `FontEntry.variantFor` does; null: the family has none.
fn compositeFor(fonts: *const Fonts, custom_index: u8, weight: types.FontWeight, style: types.FontStyle) ?[]const SubFace {
    if (custom_index >= MAX_CUSTOM) return null;
    const c = fonts.composites[custom_index];
    const wants_bold = weight.isBold();
    const wants_italic = style != .normal;
    const order: []const usize = if (wants_bold and wants_italic)
        &.{ 3, 1, 2, 0 }
    else if (wants_bold)
        &.{ 1, 0, 3, 2 }
    else if (wants_italic)
        &.{ 2, 0, 3, 1 }
    else
        &.{ 0, 1, 2, 3 };
    for (order) |v| if (c[v].len > 0) return c[v];
    return null;
}

/// Whether a font has a glyph for `cp` in its character map.
fn hasGlyph(font: *hb.hb_font_t, cp: u21) bool {
    var glyph: hb.hb_codepoint_t = 0;
    return hb.hb_font_get_nominal_glyph(font, cp, &glyph) != 0;
}

/// The face for code point `cp` of text in `chain` (CSS Fonts 4 §5.3 cluster
/// matching, a character at a time): the first family of the chain with a face whose
/// `unicode-range` and character map cover it — for a composite face, its faces in
/// order. A face whose range covers `cp` but which is not loaded is skipped and
/// recorded as `pending`. When no family covers `cp`, the `primary` family's face.
/// Null only if `primary` has no font either.
pub fn faceFor(fonts: *const Fonts, chain: []const types.FontFamily, primary: Handle, weight: types.FontWeight, style: types.FontStyle, cp: u21) ?Choice {
    var pending: ?Choice.Pending = null;
    for (chain) |family| {
        if (family == .custom) {
            if (fonts.compositeFor(family.custom, weight, style)) |faces| {
                for (faces) |sub| {
                    if (sub.failed or !sub.inRange(cp)) continue;
                    const hb_font = sub.hb_font orelse {
                        if (pending == null) pending = .{ .family = family.custom, .face = sub.id };
                        continue;
                    };
                    if (!hasGlyph(hb_font, cp)) continue;
                    return .{ .hb_font = hb_font, .ft_face = sub.ft_face.?, .pending = pending };
                }
                continue;
            }
        }
        const entry = fonts.entryFor(familyToHandle(family)) orelse continue;
        const v = entry.variantFor(weight, style);
        if (!hasGlyph(v.hb_font, cp)) continue;
        return .{ .hb_font = v.hb_font, .ft_face = v.ft_face, .pending = pending };
    }
    const entry = fonts.entryFor(primary) orelse return null;
    const v = entry.variantFor(weight, style);
    return .{ .hb_font = v.hb_font, .ft_face = v.ft_face, .pending = pending };
}

pub fn init() Fonts {
    return .{};
}

pub fn deinit(fonts: *Fonts) void {
    _ = fonts;
}

/// Register a font for the given generic family. Returns a handle for that family.
/// For custom fonts, use addCustomFont instead.
pub fn setFont(fonts: *Fonts, font: *hb.hb_font_t, ft_face: hb.FT_Face, family: types.FontFamily) Handle {
    const slot: usize = switch (family) {
        .sans_serif => 0,
        .serif => 1,
        .monospace => 2,
        .system_ui => 3,
        .custom => return .invalid,
    };
    fonts.fonts[slot] = .{ .hb_font = font, .ft_face = ft_face };
    return familyToHandle(family);
}

/// Register a @font-face custom font. Returns its Handle (5 + index), or .invalid if at capacity.
pub fn addCustomFont(fonts: *Fonts, ft_face: FT_Face, hb_font: *hb.hb_font_t) Handle {
    if (fonts.custom_count >= MAX_CUSTOM) return .invalid;
    const idx = fonts.custom_count;
    fonts.custom_entries[idx] = .{ .hb_font = hb_font, .ft_face = ft_face };
    fonts.custom_count += 1;
    return @enumFromInt(5 + idx);
}

/// Attach the bold / italic / bold-italic faces of a registered family
/// (generic or custom handle). The caller owns the hb_font_t objects.
pub fn setVariants(fonts: *Fonts, handle: Handle, bold: ?FontEntry.Variant, italic: ?FontEntry.Variant, bold_italic: ?FontEntry.Variant) void {
    const entry = fonts.entryPtr(handle) orelse return;
    entry.bold = bold;
    entry.italic = italic;
    entry.bold_italic = bold_italic;
}

fn entryPtr(fonts: *Fonts, handle: Handle) ?*FontEntry {
    const raw = @intFromEnum(handle);
    if (raw >= 5) {
        const idx = raw - 5;
        if (idx >= fonts.custom_count) return null;
        return if (fonts.custom_entries[idx]) |*e| e else null;
    }
    const slot: usize = switch (handle) {
        .sans_serif => 0,
        .serif => 1,
        .monospace => 2,
        .system_ui => 3,
        else => return null,
    };
    return if (fonts.fonts[slot]) |*e| e else null;
}

fn entryFor(fonts: *const Fonts, handle: Handle) ?FontEntry {
    const raw = @intFromEnum(handle);
    if (raw >= 5) {
        const idx = raw - 5;
        if (idx >= fonts.custom_count) return null;
        return fonts.custom_entries[idx];
    }
    return switch (handle) {
        .sans_serif => fonts.fonts[0],
        .serif => fonts.fonts[1],
        .monospace => fonts.fonts[2],
        .system_ui => fonts.fonts[3],
        else => null,
    };
}

/// The family's face for a weight and style (`FontEntry.variantFor`).
pub fn entryVariant(fonts: *const Fonts, handle: Handle, weight: types.FontWeight, style: types.FontStyle) ?FontEntry.Variant {
    const entry = fonts.entryFor(handle) orelse return null;
    return entry.variantFor(weight, style);
}

/// The HarfBuzz font to shape a run with: the family's face matching the
/// run's weight and style, or its regular face.
pub fn getVariant(fonts: *const Fonts, handle: Handle, weight: types.FontWeight, style: types.FontStyle) ?*hb.hb_font_t {
    const entry = fonts.entryFor(handle) orelse return null;
    return entry.variantFor(weight, style).hb_font;
}

/// `setFontSize` for the face `getVariant` would return.
pub fn setFontSizeVariant(fonts: *const Fonts, handle: Handle, weight: types.FontWeight, style: types.FontStyle, size_px: f32) void {
    const entry = fonts.entryFor(handle) orelse return;
    const v = entry.variantFor(weight, style);
    setFaceSize(v.ft_face, v.hb_font, size_px);
}

/// Reserve a custom slot without populating it (e.g. when @font-face download failed).
/// queryFamily for this slot falls through to sans-serif. Keeps indices aligned with
/// other registered names.
pub fn reserveCustomSlot(fonts: *Fonts) void {
    if (fonts.custom_count < MAX_CUSTOM) fonts.custom_count += 1;
    // custom_entries[idx] stays null — queryFamily returns sans-serif as fallback
}

/// Legacy: set the default (sans-serif) font. Used by demo/test call sites
/// that don't have a separate FT_Face.
pub fn setDefaultFont(fonts: *Fonts, font: *hb.hb_font_t, ft_face: hb.FT_Face) Handle {
    return fonts.setFont(font, ft_face, .sans_serif);
}

/// Query for the best font matching a family. Falls back to sans-serif.
pub fn queryFamily(fonts: Fonts, family: types.FontFamily) Handle {
    switch (family) {
        .custom => |idx| {
            if (idx < fonts.custom_count and fonts.custom_entries[idx] != null)
                return @enumFromInt(5 + idx);
            if (fonts.fonts[0] != null) return .sans_serif;
            return .invalid;
        },
        else => {
            const slot: usize = switch (family) {
                .sans_serif => 0,
                .serif => 1,
                .monospace => 2,
                .system_ui => 3,
                .custom => unreachable,
            };
            if (fonts.fonts[slot] != null) return familyToHandle(family);
            if (fonts.fonts[0] != null) return .sans_serif;
            return .invalid;
        },
    }
}

/// Legacy: query for the default font handle.
pub fn query(fonts: Fonts) Handle {
    return fonts.queryFamily(.sans_serif);
}

pub fn get(fonts: Fonts, handle: Handle) ?*hb.hb_font_t {
    const raw = @intFromEnum(handle);
    if (raw >= 5) {
        const idx = raw - 5;
        if (idx < fonts.custom_count) {
            return if (fonts.custom_entries[idx]) |e| e.hb_font else null;
        }
        return null;
    }
    return switch (handle) {
        .invalid => null,
        .sans_serif => if (fonts.fonts[0]) |e| e.hb_font else null,
        .serif => if (fonts.fonts[1]) |e| e.hb_font else null,
        .monospace => if (fonts.fonts[2]) |e| e.hb_font else null,
        .system_ui => if (fonts.fonts[3]) |e| e.hb_font else null,
        _ => null,
    };
}

/// Resize the underlying FreeType face so HarfBuzz shapes at the given px size.
/// Mutates the FT face (external C state), not the Fonts struct itself.
pub fn setFontSize(fonts: *const Fonts, handle: Handle, size_px: f32) void {
    const raw = @intFromEnum(handle);
    if (raw >= 5) {
        const idx = raw - 5;
        if (idx < fonts.custom_count) {
            if (fonts.custom_entries[idx]) |entry| setFaceSize(entry.ft_face, entry.hb_font, size_px);
        }
        return;
    }
    const slot: usize = switch (handle) {
        .sans_serif => 0,
        .serif => 1,
        .monospace => 2,
        .system_ui => 3,
        .invalid => return,
        _ => return,
    };
    if (fonts.fonts[slot]) |entry| setFaceSize(entry.ft_face, entry.hb_font, size_px);
}

fn familyToHandle(family: types.FontFamily) Handle {
    return switch (family) {
        .sans_serif => .sans_serif,
        .serif => .serif,
        .monospace => .monospace,
        .system_ui => .system_ui,
        .custom => |idx| @enumFromInt(5 + idx),
    };
}

// Raw font design metrics from the hhea table (size-independent).
// Use these to compute line-height at any font size without FreeType's
// ceil/floor pixel-boundary rounding (which overshoots Chrome by ~0.8px/line).
//
// `line_gap` is the font-intrinsic leading: per CSS line-height:normal,
// Chrome/Firefox distribute it half-above / half-below to widen the
// line-box without moving the baseline. Omitting it makes every text
// line ~(line_gap/upem * font-size) px shorter than Chrome, so baselines
// drift upward progressively in multi-line blocks.
pub const DesignMetrics = struct {
    ascender: i16, // hhea ascent (font units, positive above baseline)
    descender: i16, // |hhea descent| (font units, positive magnitude)
    line_gap: i16, // hhea line-gap (font units, >= 0)
    units_per_em: u16,
};

/// Per-font character widths at a given size, as Blink reads them for text
/// control sizing (`SimpleFontData::PlatformInit`): the OS/2 table's
/// `xAvgCharWidth` (the advance of "0" when the table is missing or zero —
/// Blink's "invalid average char width" fallback) and the face bounding
/// box's width, each rounded to whole pixels.
pub const CharWidthMetrics = struct {
    avg: f32,
    max: f32,
};

// FreeType's SFNT table access (freetype/tttables.h), declared here because
// the HarfBuzz import only pulls in FT_FREETYPE_H. Only the leading fields
// of TT_OS2 are read.
const FT_SFNT_OS2: c_int = 2;
extern fn FT_Get_Sfnt_Table(face: hb.FT_Face, tag: c_int) ?*anyopaque;
const TT_OS2_Head = extern struct {
    version: u16,
    xAvgCharWidth: i16,
};
/// TT_OS2 up to `sxHeight` (FreeType's layout; FT_ULong is c_ulong).
const TT_OS2_XHeight = extern struct {
    version: u16,
    xAvgCharWidth: i16,
    usWeightClass: u16,
    usWidthClass: u16,
    fsType: u16,
    ySubscriptXSize: i16,
    ySubscriptYSize: i16,
    ySubscriptXOffset: i16,
    ySubscriptYOffset: i16,
    ySuperscriptXSize: i16,
    ySuperscriptYSize: i16,
    ySuperscriptXOffset: i16,
    ySuperscriptYOffset: i16,
    yStrikeoutSize: i16,
    yStrikeoutPosition: i16,
    sFamilyClass: i16,
    panose: [10]u8,
    ulUnicodeRange1: c_ulong,
    ulUnicodeRange2: c_ulong,
    ulUnicodeRange3: c_ulong,
    ulUnicodeRange4: c_ulong,
    achVendID: [4]i8,
    fsSelection: u16,
    usFirstCharIndex: u16,
    usLastCharIndex: u16,
    sTypoAscender: i16,
    sTypoDescender: i16,
    sTypoLineGap: i16,
    usWinAscent: u16,
    usWinDescent: u16,
    ulCodePageRange1: c_ulong,
    ulCodePageRange2: c_ulong,
    sxHeight: i16,
};

/// A font's line metrics in CSS px, as Blink computes them
/// (SimpleFontData::PlatformInit): ascent, descent and line gap each
/// rounded to whole pixels; the x-height from the OS/2 table's sxHeight, or
/// the height of the "x" glyph when the table has none (as Skia does).
pub const LineMetrics = struct {
    ascent: f32 = 0,
    descent: f32 = 0,
    line_gap: f32 = 0,
    x_height: f32 = 0,
};

pub fn lineMetrics(fonts: *const Fonts, handle: Handle, font_size_px: f32) LineMetrics {
    const entry = fonts.entryFor(handle) orelse return .{};
    const face = entry.ft_face;
    if (face.*.units_per_EM == 0) return .{};
    const scale = font_size_px / @as(f32, @floatFromInt(face.*.units_per_EM));
    const line_gap: i32 = @as(i32, face.*.height) - @as(i32, face.*.ascender) + @as(i32, face.*.descender);
    var x_height_units: i32 = 0;
    if (FT_Get_Sfnt_Table(face, FT_SFNT_OS2)) |os2_ptr| {
        const os2: *const TT_OS2_XHeight = @ptrCast(@alignCast(os2_ptr));
        if (os2.version >= 2) x_height_units = os2.sxHeight;
    }
    if (x_height_units <= 0) {
        const x_index = hb.FT_Get_Char_Index(face, 'x');
        if (x_index != 0 and hb.FT_Load_Glyph(face, x_index, hb.FT_LOAD_NO_SCALE) == 0) {
            x_height_units = @intCast(face.*.glyph.*.metrics.horiBearingY);
        }
    }
    return .{
        .ascent = @round(@as(f32, @floatFromInt(face.*.ascender)) * scale),
        .descent = @round(@as(f32, @floatFromInt(-face.*.descender)) * scale),
        .line_gap = @round(@as(f32, @floatFromInt(@max(0, line_gap))) * scale),
        .x_height = @as(f32, @floatFromInt(x_height_units)) * scale,
    };
}

pub fn getCharWidthMetrics(fonts: *const Fonts, handle: Handle, font_size_px: f32) CharWidthMetrics {
    const entry = fonts.entryFor(handle) orelse return .{ .avg = 0, .max = 0 };
    const face = entry.ft_face;
    if (face.*.units_per_EM == 0) return .{ .avg = 0, .max = 0 };
    const scale = font_size_px / @as(f32, @floatFromInt(face.*.units_per_EM));

    var avg_units: i32 = 0;
    if (FT_Get_Sfnt_Table(face, FT_SFNT_OS2)) |os2_ptr| {
        const os2: *const TT_OS2_Head = @ptrCast(@alignCast(os2_ptr));
        avg_units = os2.xAvgCharWidth;
    }
    if (avg_units <= 0) {
        const zero_index = hb.FT_Get_Char_Index(face, '0');
        if (zero_index != 0 and hb.FT_Load_Glyph(face, zero_index, hb.FT_LOAD_NO_SCALE) == 0) {
            avg_units = @intCast(face.*.glyph.*.advance.x);
        }
    }
    const max_units: i32 = @intCast(@max(0, face.*.bbox.xMax - face.*.bbox.xMin));
    return .{
        .avg = @round(@as(f32, @floatFromInt(avg_units)) * scale),
        .max = @round(@as(f32, @floatFromInt(max_units)) * scale),
    };
}

pub fn getDesignMetrics(fonts: *const Fonts, handle: Handle) DesignMetrics {
    const raw = @intFromEnum(handle);
    const entry: ?FontEntry = if (raw >= 5) blk: {
        const idx = raw - 5;
        break :blk if (idx < fonts.custom_count) fonts.custom_entries[idx] else null;
    } else switch (handle) {
        .sans_serif => fonts.fonts[0],
        .serif => fonts.fonts[1],
        .monospace => fonts.fonts[2],
        .system_ui => fonts.fonts[3],
        else => null,
    };
    if (entry) |e| {
        const face = e.ft_face[0];
        // FreeType exposes face.height = ascender - descender + lineGap (font units).
        // Back out lineGap: descender is negative in FT, so abs(descender) = -descender.
        const line_gap_i32: i32 = @as(i32, face.height) - @as(i32, face.ascender) - @as(i32, -face.descender);
        return .{
            .ascender = face.ascender,
            .descender = -face.descender,
            .line_gap = @intCast(@max(0, line_gap_i32)),
            .units_per_em = face.units_per_EM,
        };
    }
    return .{ .ascender = 0, .descender = 0, .line_gap = 0, .units_per_em = 0 };
}