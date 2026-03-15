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
        // FT_Set_Char_Size takes 1/64 points; convert px → pt at 96 DPI.
        // pt = px * 72/96 = px * 0.75; in 26.6 fixed-point: px * 48.
        const size_26_6: i32 = @intFromFloat(size_px * 48.0);
        _ = hb.FT_Set_Char_Size(entry.ft_face, 0, size_26_6, 96, 96);
        // Tell HarfBuzz to re-read metrics from the resized FT face.
        // Required for HarfBuzz < 11.0.0 (no auto-detection).
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
