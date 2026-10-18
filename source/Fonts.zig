const Fonts = @This();

const hb = @import("harfbuzz").c;
const types = @import("values/types.zig");

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
    var face: hb.FT_Face = undefined;
    if (hb.FT_New_Face(lib, path, 0, &face) != 0) return null;
    return face;
}

/// Release a font face loaded with loadFace().
pub fn doneFace(face: FT_Face) void {
    _ = hb.FT_Done_Face(face);
}

/// Create a HarfBuzz font from a vendored FT_Face.
/// hb_ft_font_create_referenced sets up FT-backed font functions internally.
/// We set NO_HINTING load flags for fractional advance accuracy.
pub fn createHbFont(face: FT_Face) ?*hb.hb_font_t {
    const font = hb.hb_ft_font_create_referenced(face) orelse return null;
    hb.hb_ft_font_set_load_flags(font, 1 << 1); // FT_LOAD_NO_HINTING
    return font;
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

pub const MAX_CUSTOM = 24;

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
    const size_26_6: i32 = @intFromFloat(size_px * 64.0);
    _ = hb.FT_Set_Char_Size(v.ft_face, 0, size_26_6, 72, 72);
    hb.hb_ft_font_changed(v.hb_font);
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
            if (fonts.custom_entries[idx]) |entry| {
                const size_26_6: i32 = @intFromFloat(size_px * 64.0);
                _ = hb.FT_Set_Char_Size(entry.ft_face, 0, size_26_6, 72, 72);
                hb.hb_ft_font_changed(entry.hb_font);
            }
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
    if (fonts.fonts[slot]) |entry| {
        const size_26_6: i32 = @intFromFloat(size_px * 64.0);
        _ = hb.FT_Set_Char_Size(entry.ft_face, 0, size_26_6, 72, 72);
        // Signal HarfBuzz to re-read FT face metrics at the new size.
        // Do NOT call hb_ft_font_set_funcs here — it resets internal caches
        // and breaks advance scaling. hb_ft_font_changed is sufficient when
        // the FT-backed functions were set at font creation time.
        hb.hb_ft_font_changed(entry.hb_font);
    }
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