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
    // Fallback: sans-serif is always the default
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
        // Match Chrome/Skia convention: treat size_px as point-size at 72 DPI.
        // FT_Set_Char_Size(face, 0, px*64, 72, 72) gives pixel_size = px*64/64 * 72/72 = px.
        // This avoids the fractional rounding difference vs the px*48 + 96dpi path.
        const size_26_6: i32 = @intFromFloat(size_px * 64.0);
        _ = hb.FT_Set_Char_Size(entry.ft_face, 0, size_26_6, 72, 72);
        // Tell HarfBuzz to re-read glyph metrics (advances, positions) from the resized FT face.
        // NOTE: hb_ft_font_changed does NOT invalidate font-level extents (ascender/descender).
        // Use getDesignMetrics() + manual scaling for line-height computation.
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
            // FT face.descender is negative (below baseline); store as positive.
            .descender = -face.descender,
            .units_per_em = face.units_per_EM,
        };
    }
    return .{ .ascender = 0, .descender = 0, .units_per_em = 0 };
}