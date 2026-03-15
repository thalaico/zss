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

/// Per-family font slots. Externally managed (caller owns the hb_font_t).
fonts: [3]?*hb.hb_font_t,

pub fn init() Fonts {
    return .{ .fonts = .{ null, null, null } };
}

pub fn deinit(fonts: *Fonts) void {
    _ = fonts;
}

/// Register a font for the given family. Returns a handle for that family.
pub fn setFont(fonts: *Fonts, font: *hb.hb_font_t, family: types.FontFamily) Handle {
    const slot = @intFromEnum(family);
    fonts.fonts[slot] = font;
    return familyToHandle(family);
}

/// Legacy: set the default (sans-serif) font. Used by existing call sites.
pub fn setDefaultFont(fonts: *Fonts, font: *hb.hb_font_t) Handle {
    return fonts.setFont(font, .sans_serif);
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
        .sans_serif => fonts.fonts[0],
        .serif => fonts.fonts[1],
        .monospace => fonts.fonts[2],
        _ => null,
    };
}

fn familyToHandle(family: types.FontFamily) Handle {
    return switch (family) {
        .sans_serif => .sans_serif,
        .serif => .serif,
        .monospace => .monospace,
    };
}
