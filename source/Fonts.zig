const Fonts = @This();

const hb = @import("harfbuzz").c;
const types = @import("values/types.zig");

pub const Handle = enum(u8) {
    invalid,
    sans_serif,
    serif,
    monospace,
    _,
};

pub const FontEntry = struct {
    hb_font: *hb.hb_font_t,
    ft_face: hb.FT_Face,
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
fonts: [3]?FontEntry = .{ null, null, null },

pub fn init() Fonts {
    return .{};
}

pub fn deinit(fonts: *Fonts) void {
    _ = fonts;
}

/// Register a font for the given family. Returns a handle for that family.
pub fn setFont(fonts: *Fonts, font: *hb.hb_font_t, ft_face: hb.FT_Face, family: types.FontFamily) Handle {
    const slot = @intFromEnum(family);
    fonts.fonts[slot] = .{ .hb_font = font, .ft_face = ft_face };
    return familyToHandle(family);
}

/// Legacy: set the default (sans-serif) font. Used by demo/test call sites
/// that don't have a separate FT_Face.
pub fn setDefaultFont(fonts: *Fonts, font: *hb.hb_font_t, ft_face: hb.FT_Face) Handle {
    return fonts.setFont(font, ft_face, .sans_serif);
}

/// Query for the best font matching a family. Falls back to sans-serif.
pub fn queryFamily(fonts: Fonts, family: types.FontFamily) Handle {
    const slot = @intFromEnum(family);
    if (fonts.fonts[slot] != null) return familyToHandle(family);
    if (fonts.fonts[0] != null) return .sans_serif;
    return .invalid;
}

/// Legacy: query for the default font handle.
pub fn query(fonts: Fonts) Handle {
    return fonts.queryFamily(.sans_serif);
}

pub fn get(fonts: Fonts, handle: Handle) ?*hb.hb_font_t {
    return switch (handle) {
        .invalid => null,
        .sans_serif => if (fonts.fonts[0]) |e| e.hb_font else null,
        .serif => if (fonts.fonts[1]) |e| e.hb_font else null,
        .monospace => if (fonts.fonts[2]) |e| e.hb_font else null,
        _ => null,
    };
}

/// Resize the underlying FreeType face so HarfBuzz shapes at the given px size.
/// Mutates the FT face (external C state), not the Fonts struct itself.
pub fn setFontSize(fonts: *const Fonts, handle: Handle, size_px: f32) void {
    const slot: usize = switch (handle) {
        .sans_serif => 0,
        .serif => 1,
        .monospace => 2,
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
    };
}

// Raw font design metrics from the hhea table (size-independent).
// Use these to compute line-height at any font size without FreeType's
// ceil/floor pixel-boundary rounding (which overshoots Chrome by ~0.8px/line).
pub const DesignMetrics = struct {
    ascender: i16, // hhea ascent (font units, positive above baseline)
    descender: i16, // |hhea descent| (font units, positive magnitude)
    units_per_em: u16,
};

pub fn getDesignMetrics(fonts: *const Fonts, handle: Handle) DesignMetrics {
    const slot: usize = switch (handle) {
        .sans_serif => 0,
        .serif => 1,
        .monospace => 2,
        .invalid => return .{ .ascender = 0, .descender = 0, .units_per_em = 0 },
        _ => return .{ .ascender = 0, .descender = 0, .units_per_em = 0 },
    };
    if (fonts.fonts[slot]) |entry| {
        const face = entry.ft_face[0];
        return .{
            .ascender = face.ascender,
            .descender = -face.descender,
            .units_per_em = face.units_per_EM,
        };
    }
    return .{ .ascender = 0, .descender = 0, .units_per_em = 0 };
}