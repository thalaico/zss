const std = @import("std");
const zss = @import("../zss.zig");

pub const CssWideKeyword = enum(u2) {
    initial = 1,
    inherit = 2,
    unset = 3,
};

pub const Display = enum {
    block,
    @"inline",
    inline_block,
    table,
    table_row,
    table_cell,
    table_row_group,
    table_header_group,
    table_footer_group,
    flex,
    grid,
    list_item,
    none,
};

//pub const Display = enum {
//    // display-outside, display-inside
//    block,
//    inline_,
//    run_in,
//    flow,
//    flow_root,
//    table,
//    flex,
//    grid,
//    ruby,
//    block_flow,
//    block_flow_root,
//    block_table,
//    block_flex,
//    block_grid,
//    block_ruby,
//    inline_flow,
//    inline_flow_root,
//    inline_table,
//    inline_flex,
//    inline_grid,
//    inline_ruby,
//    run_in_flow,
//    run_in_flow_root,
//    run_in_table,
//    run_in_flex,
//    run_in_grid,
//    run_in_ruby,
//    // display-listitem
//    list_item,
//    block_list_item,
//    inline_list_item,
//    run_in_list_item,
//    flow_list_item,
//    flow_root_list_item,
//    block_flow_list_item,
//    block_flow_root_list_item,
//    inline_flow_list_item,
//    inline_flow_root_list_item,
//    run_in_flow_list_item,
//    run_in_flow_root_list_item,
//    // display-internal
//    table_row_group,
//    table_header_group,
//    table_footer_group,
//    table_row,
//    table_cell,
//    table_column_group,
//    table_column,
//    table_caption,
//    ruby_base,
//    ruby_text,
//    ruby_base_container,
//    ruby_text_container,
//    // display-box
//    contents,
//    none,
//    // display-legacy
//    legacy_inline_block,
//    legacy_inline_table,
//    legacy_inline_flex,
//    legacy_inline_grid,
//    // css-wide
//};

pub const Position = enum {
    static,
    relative,
    absolute,
    sticky,
    fixed,
};

pub const ZIndex = union(enum) {
    integer: i32,
    auto,
};

pub const BoxSizing = enum {
    content_box,
    border_box,
};

pub const Float = enum {
    left,
    right,
    none,
};

pub const Overflow = enum {
    visible,
    hidden,
    scroll,
    auto,
};

pub const FlexDirection = enum {
    row,
    row_reverse,
    column,
    column_reverse,
};

pub const JustifyContent = enum {
    flex_start,
    flex_end,
    center,
    space_between,
    space_around,
};

pub const AlignItems = enum {
    stretch,
    flex_start,
    flex_end,
    center,
    baseline,
};

/// flex-grow / flex-shrink: non-negative number (default grow=0, shrink=1)
pub const FlexFactor = f32;

/// flex-basis: auto | <length> | <percentage>
pub const FlexBasis = union(enum) {
    auto,
    px: f32,
    percentage: f32,
};

pub const FlexWrap = enum {
    nowrap,
    wrap,
    wrap_reverse,
};

pub const WhiteSpace = enum {
    normal,
    nowrap,
    pre,
    pre_wrap,
    pre_line,
};

pub const OverflowWrap = enum {
    normal,
    break_word,
};

pub const ListStyleType = enum {
    disc,
    circle,
    square,
    decimal,
    none,
};

// --- CSS Grid types ---

/// Maximum number of explicit grid tracks per dimension.
pub const MAX_GRID_TRACKS = 8;
/// Maximum number of named grid areas per container.
pub const MAX_GRID_AREAS = 16;

/// A single grid track size definition.
/// Covers the subset needed for Wikipedia: fixed, fr, min-content, max-content, auto, minmax().
pub const GridTrackSize = struct {
    kind: Kind = .auto,
    /// For .fixed: the resolved length in layout units.
    /// For .fr: the fraction value encoded via @bitCast from f32.
    /// For .minmax: the min value in layout units (min is always fixed or 0).
    value: i32 = 0,
    /// For .minmax only: the max track sizing function.
    max_kind: Kind = .auto,
    /// For .minmax only: the max value (same encoding as value).
    max_value: i32 = 0,

    pub const Kind = enum(u8) {
        auto,
        fixed,
        fr,
        min_content,
        max_content,
        /// minmax() function. min is in value (fixed units), max described by max_kind/max_value.
        minmax,
    };

    pub fn initFixed(units: i32) GridTrackSize {
        return .{ .kind = .fixed, .value = units };
    }

    pub fn initFr(fraction: f32) GridTrackSize {
        return .{ .kind = .fr, .value = @bitCast(fraction) };
    }

    /// minmax(fixed_min, fr_max) — covers Wikipedia's `minmax(0, 1fr)` pattern.
    pub fn initMinmaxFixedFr(min_units: i32, max_fr: f32) GridTrackSize {
        return .{
            .kind = .minmax,
            .value = min_units,
            .max_kind = .fr,
            .max_value = @bitCast(max_fr),
        };
    }

    pub fn frValue(self: GridTrackSize) f32 {
        return @bitCast(self.value);
    }

    pub fn maxFrValue(self: GridTrackSize) f32 {
        return @bitCast(self.max_value);
    }
};

/// Grid track list for one dimension (columns or rows).
pub const GridTrackList = struct {
    tracks: [MAX_GRID_TRACKS]GridTrackSize = [_]GridTrackSize{.{}} ** MAX_GRID_TRACKS,
    count: u8 = 0,
};

/// A named grid area entry: maps a name hash to a rectangular region.
pub const GridAreaEntry = struct {
    /// FNV-1a hash of the area name.
    name_hash: u32 = 0,
    row_start: u8 = 0,
    row_end: u8 = 0,
    col_start: u8 = 0,
    col_end: u8 = 0,
};

/// Named grid areas for a grid container.
pub const GridAreas = struct {
    entries: [MAX_GRID_AREAS]GridAreaEntry = [_]GridAreaEntry{.{}} ** MAX_GRID_AREAS,
    count: u8 = 0,

    /// Look up an area by name hash. Returns row/col bounds or null.
    pub fn findArea(self: *const GridAreas, name_hash: u32) ?GridAreaEntry {
        if (name_hash == 0) return null;
        for (self.entries[0..self.count]) |entry| {
            if (entry.name_hash == name_hash) return entry;
        }
        return null;
    }
};

/// Grid placement for a child element (grid-area property).
/// Stores the FNV-1a hash of the area name (0 = auto-placement).
pub const GridAreaPlacement = u32;

/// FNV-1a hash for grid area name strings.
pub fn gridAreaNameHash(name: []const u8) u32 {
    var h: u32 = 2166136261;
    for (name) |byte| {
        h ^= byte;
        h *%= 16777619;
    }
    return h;
}

pub const Clear = enum {
    left,
    right,
    both,
    none,
};

pub const LengthPercentageAuto = union(enum) {
    px: f32,
    em: f32,
    percentage: f32,
    auto,

    /// Resolve em to px using the element's computed font-size.
    /// After resolution, .em is unreachable.
    pub fn resolveEm(self: LengthPercentageAuto, font_size_px: f32) LengthPercentageAuto {
        return switch (self) {
            .em => |v| .{ .px = v * font_size_px },
            else => self,
        };
    }
};

pub const Size = LengthPercentageAuto;
pub const Margin = LengthPercentageAuto;
pub const Inset = LengthPercentageAuto;

pub const LengthPercentage = union(enum) {
    px: f32,
    em: f32,
    percentage: f32,

    pub fn resolveEm(self: LengthPercentage, font_size_px: f32) LengthPercentage {
        return switch (self) {
            .em => |v| .{ .px = v * font_size_px },
            else => self,
        };
    }
};

pub const MinSize = LengthPercentage;
pub const Padding = LengthPercentage;

pub const MaxSize = union(enum) {
    px: f32,
    em: f32,
    percentage: f32,
    none,

    pub fn resolveEm(self: MaxSize, font_size_px: f32) MaxSize {
        return switch (self) {
            .em => |v| .{ .px = v * font_size_px },
            else => self,
        };
    }
};

pub const BorderWidth = union(enum) {
    px: f32,
    thin,
    medium,
    thick,
};

pub const BorderRadius = union(enum) {
    px: f32,
};
pub const BorderStyle = enum {
    none,
    hidden,
    dotted,
    dashed,
    solid,
    double,
    groove,
    ridge,
    inset,
    outset,
};

pub const Color = union(enum) {
    rgba: u32,
    current_color,
    transparent,

    pub const black = Color{ .rgba = 0xff };
};

pub const LinearGradient = union(enum) {
    gradient: struct { from_rgba: u32, to_rgba: u32 },
    none,
};

pub const BackgroundImage = union(enum) {
    image: zss.Images.Handle,
    url: zss.Environment.UrlId,
    none,
};

pub const BackgroundRepeat = struct {
    pub const Style = enum { repeat, no_repeat, space, round };

    x: Style = .repeat,
    y: Style = .repeat,
};

pub const BackgroundAttachment = enum {
    scroll,
    fixed,
    local,
};

pub const BackgroundPosition = struct {
    pub const Side = enum { start, end, center };
    pub const Offset = union(enum) {
        px: f32,
        percentage: f32,
    };

    // TODO: Make this a tagged union instead
    pub const SideOffset = struct {
        /// `.start` corresponds to left (x-axis) and top (y-axis)
        /// `.end` corresponds to right (x-axis) and bottom (y-axis)
        /// `.center` corresponds to center (either axis), and will cause `offset` to be ignored during layout
        side: Side,
        offset: Offset,
    };

    x: SideOffset,
    y: SideOffset,
};

pub const BackgroundClip = enum {
    border_box,
    padding_box,
    content_box,
};

pub const BackgroundOrigin = enum {
    border_box,
    padding_box,
    content_box,
};

pub const BackgroundSize = union(enum) {
    pub const SizeType = union(enum) {
        px: f32,
        percentage: f32,
        auto,
    };

    size: struct {
        width: SizeType,
        height: SizeType,
    },
    contain,
    cover,
};

pub const Font = enum {
    default,
    none,
};

pub const Opacity = f32;


/// Font-size value: px (absolute) or em (relative to parent's font-size).
pub const FontSize = union(enum) {
    px: f32,
    em: f32,

    /// Resolve em against parent's computed font-size. Returns px.
    pub fn resolve(self: FontSize, parent_font_size_px: f32) f32 {
        return switch (self) {
            .px => |v| v,
            .em => |v| v * parent_font_size_px,
        };
    }

    /// Extract px value. Panics if still em (must be resolved first).
    pub fn px_val(self: FontSize) f32 {
        return switch (self) {
            .px => |v| v,
            .em => unreachable,
        };
    }
};

pub const FontWeight = enum {
    normal,
    bold,
};

pub const FontStyle = enum {
    normal,
    italic,
    oblique,
};
pub const FontFamily = enum {
    sans_serif,
    serif,
    monospace,
    system_ui,
};

pub const TextDecoration = enum {
    none,
    underline,
    overline,
    line_through,
};

pub const TextTransform = enum {
    none,
    uppercase,
    lowercase,
    capitalize,
};

pub const TextAlign = enum {
    left,
    right,
    center,
    justify,
};

pub const VerticalAlign = enum {
    baseline,
    top,
    middle,
    bottom,
};

pub const Visibility = enum {
    visible,
    hidden,
    collapse,
};

/// CSS border-spacing: stored as layout units (4 units = 1px).
pub const BorderSpacing = @import("../zss.zig").math.Unit;

/// CSS line-height: stored as layout units (4 units = 1px). 0 = normal.
pub const LineHeight = @import("../zss.zig").math.Unit;

/// CSS content property for generated content (::before/::after).
/// Drives box generation in insertPseudoElement: .normal/.none suppress generation,
/// .empty_string creates a leaf block (clearfix), .string creates an IFC with shaped text.
pub const Content = union(enum) {
    /// Default: no generated content (for real elements)
    normal,
    /// Explicitly suppresses generation
    none,
    /// content: '' — the clearfix pattern (empty block, typically with clear:both)
    empty_string,
    /// content: 'text' — generates an inline formatting context with shaped text.
    /// TextId indexes into Environment.texts; resolved at layout time via env.getText().
    string: @import("../zss.zig").Environment.TextId,
};