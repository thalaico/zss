const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const types = zss.values.types;
const Ast = zss.syntax.Ast;
const Component = zss.syntax.Component;
const Environment = zss.Environment;
const Location = SourceCode.Location;
const SourceCode = zss.syntax.SourceCode;

/// CSS Level 3 Named Colors (147 colors) as key-value pairs
/// https://www.w3.org/TR/css-color-3/#svg-color
/// Format: RRGGBBAA (big-endian u32)
const namedColorKVs = [_]SourceCode.KV(u32){
    // Basic 16 colors
    .{ "black", 0x000000FF }, .{ "silver", 0xC0C0C0FF }, .{ "gray", 0x808080FF }, .{ "grey", 0x808080FF },
    .{ "white", 0xFFFFFFFF }, .{ "maroon", 0x800000FF }, .{ "red", 0xFF0000FF }, .{ "purple", 0x800080FF },
    .{ "fuchsia", 0xFF00FFFF }, .{ "green", 0x008000FF }, .{ "lime", 0x00FF00FF }, .{ "olive", 0x808000FF },
    .{ "yellow", 0xFFFF00FF }, .{ "navy", 0x000080FF }, .{ "blue", 0x0000FFFF }, .{ "teal", 0x008080FF },
    .{ "aqua", 0x00FFFFFF }, .{ "cyan", 0x00FFFFFF }, .{ "magenta", 0xFF00FFFF },
    // Extended colors (alphabetically)
    .{ "aliceblue", 0xF0F8FFFF }, .{ "antiquewhite", 0xFAEBD7FF }, .{ "aquamarine", 0x7FFFD4FF },
    .{ "azure", 0xF0FFFFFF }, .{ "beige", 0xF5F5DCFF }, .{ "bisque", 0xFFE4C4FF },
    .{ "blanchedalmond", 0xFFEBCDFF }, .{ "blueviolet", 0x8A2BE2FF }, .{ "brown", 0xA52A2AFF },
    .{ "burlywood", 0xDEB887FF }, .{ "cadetblue", 0x5F9EA0FF }, .{ "chartreuse", 0x7FFF00FF },
    .{ "chocolate", 0xD2691EFF }, .{ "coral", 0xFF7F50FF }, .{ "cornflowerblue", 0x6495EDFF },
    .{ "cornsilk", 0xFFF8DCFF }, .{ "crimson", 0xDC143CFF }, .{ "darkblue", 0x00008BFF },
    .{ "darkcyan", 0x008B8BFF }, .{ "darkgoldenrod", 0xB8860BFF }, .{ "darkgray", 0xA9A9A9FF },
    .{ "darkgrey", 0xA9A9A9FF }, .{ "darkgreen", 0x006400FF }, .{ "darkkhaki", 0xBDB76BFF },
    .{ "darkmagenta", 0x8B008BFF }, .{ "darkolivegreen", 0x556B2FFF }, .{ "darkorange", 0xFF8C00FF },
    .{ "darkorchid", 0x9932CCFF }, .{ "darkred", 0x8B0000FF }, .{ "darksalmon", 0xE9967AFF },
    .{ "darkseagreen", 0x8FBC8FFF }, .{ "darkslateblue", 0x483D8BFF }, .{ "darkslategray", 0x2F4F4FFF },
    .{ "darkslategrey", 0x2F4F4FFF }, .{ "darkturquoise", 0x00CED1FF }, .{ "darkviolet", 0x9400D3FF },
    .{ "deeppink", 0xFF1493FF }, .{ "deepskyblue", 0x00BFFFFF }, .{ "dimgray", 0x696969FF },
    .{ "dimgrey", 0x696969FF }, .{ "dodgerblue", 0x1E90FFFF }, .{ "firebrick", 0xB22222FF },
    .{ "floralwhite", 0xFFFAF0FF }, .{ "forestgreen", 0x228B22FF }, .{ "gainsboro", 0xDCDCDCFF },
    .{ "ghostwhite", 0xF8F8FFFF }, .{ "gold", 0xFFD700FF }, .{ "goldenrod", 0xDAA520FF },
    .{ "greenyellow", 0xADFF2FFF }, .{ "honeydew", 0xF0FFF0FF }, .{ "hotpink", 0xFF69B4FF },
    .{ "indianred", 0xCD5C5CFF }, .{ "indigo", 0x4B0082FF }, .{ "ivory", 0xFFFFF0FF },
    .{ "khaki", 0xF0E68CFF }, .{ "lavender", 0xE6E6FAFF }, .{ "lavenderblush", 0xFFF0F5FF },
    .{ "lawngreen", 0x7CFC00FF }, .{ "lemonchiffon", 0xFFFACDFF }, .{ "lightblue", 0xADD8E6FF },
    .{ "lightcoral", 0xF08080FF }, .{ "lightcyan", 0xE0FFFFFF }, .{ "lightgoldenrodyellow", 0xFAFAD2FF },
    .{ "lightgray", 0xD3D3D3FF }, .{ "lightgrey", 0xD3D3D3FF }, .{ "lightgreen", 0x90EE90FF },
    .{ "lightpink", 0xFFB6C1FF }, .{ "lightsalmon", 0xFFA07AFF }, .{ "lightseagreen", 0x20B2AAFF },
    .{ "lightskyblue", 0x87CEFAFF }, .{ "lightslategray", 0x778899FF }, .{ "lightslategrey", 0x778899FF },
    .{ "lightsteelblue", 0xB0C4DEFF }, .{ "lightyellow", 0xFFFFE0FF }, .{ "limegreen", 0x32CD32FF },
    .{ "linen", 0xFAF0E6FF }, .{ "mediumaquamarine", 0x66CDAAFF }, .{ "mediumblue", 0x0000CDFF },
    .{ "mediumorchid", 0xBA55D3FF }, .{ "mediumpurple", 0x9370DBFF }, .{ "mediumseagreen", 0x3CB371FF },
    .{ "mediumslateblue", 0x7B68EEFF }, .{ "mediumspringgreen", 0x00FA9AFF }, .{ "mediumturquoise", 0x48D1CCFF },
    .{ "mediumvioletred", 0xC71585FF }, .{ "midnightblue", 0x191970FF }, .{ "mintcream", 0xF5FFFAFF },
    .{ "mistyrose", 0xFFE4E1FF }, .{ "moccasin", 0xFFE4B5FF }, .{ "navajowhite", 0xFFDEADFF },
    .{ "oldlace", 0xFDF5E6FF }, .{ "olivedrab", 0x6B8E23FF }, .{ "orange", 0xFFA500FF },
    .{ "orangered", 0xFF4500FF }, .{ "orchid", 0xDA70D6FF }, .{ "palegoldenrod", 0xEEE8AAFF },
    .{ "palegreen", 0x98FB98FF }, .{ "paleturquoise", 0xAFEEEEFF }, .{ "palevioletred", 0xDB7093FF },
    .{ "papayawhip", 0xFFEFD5FF }, .{ "peachpuff", 0xFFDAB9FF }, .{ "peru", 0xCD853FFF },
    .{ "pink", 0xFFC0CBFF }, .{ "plum", 0xDDA0DDFF }, .{ "powderblue", 0xB0E0E6FF },
    .{ "rosybrown", 0xBC8F8FFF }, .{ "royalblue", 0x4169E1FF }, .{ "saddlebrown", 0x8B4513FF },
    .{ "salmon", 0xFA8072FF }, .{ "sandybrown", 0xF4A460FF }, .{ "seagreen", 0x2E8B57FF },
    .{ "seashell", 0xFFF5EEFF }, .{ "sienna", 0xA0522DFF }, .{ "skyblue", 0x87CEEBFF },
    .{ "slateblue", 0x6A5ACDFF }, .{ "slategray", 0x708090FF }, .{ "slategrey", 0x708090FF },
    .{ "snow", 0xFFFAFAFF }, .{ "springgreen", 0x00FF7FFF }, .{ "steelblue", 0x4682B4FF },
    .{ "tan", 0xD2B48CFF }, .{ "thistle", 0xD8BFD8FF }, .{ "tomato", 0xFF6347FF },
    .{ "turquoise", 0x40E0D0FF }, .{ "violet", 0xEE82EEFF }, .{ "wheat", 0xF5DEB3FF },
    .{ "whitesmoke", 0xF5F5F5FF }, .{ "yellowgreen", 0x9ACD32FF },
};

pub const Context = struct {
    ast: Ast,
    source_code: SourceCode,
    state: State,

    pub const State = struct {
        mode: Mode,
        sequence: Ast.Sequence,

        pub const Mode = enum {
            /// For parsing a general sequence of Ast nodes.
            normal,
            /// For parsing CSS declarations.
            decl,
            /// For parsing comma-separated lists within a CSS declaration.
            decl_list,
        };
    };

    pub fn init(ast: Ast, source_code: SourceCode) Context {
        return .{
            .ast = ast,
            .source_code = source_code,
            .state = undefined,
        };
    }

    /// Sets `sequence` as the current node sequence to iterate over.
    pub fn initSequence(ctx: *Context, sequence: Ast.Sequence) void {
        ctx.state = .{
            .mode = .normal,
            .sequence = sequence,
        };
    }

    /// Sets the children of `declaration_index` as the current node sequence to iterate over.
    pub fn initDecl(ctx: *Context, declaration_index: Ast.Index) void {
        switch (declaration_index.tag(ctx.ast)) {
            .declaration_normal, .declaration_important => {},
            else => unreachable,
        }
        ctx.state = .{
            .mode = .decl,
            .sequence = declaration_index.children(ctx.ast),
        };
    }

    /// Sets the children of `declaration_index` as the current node sequence to iterate over.
    /// In addition, it treats the sequence as a comma-separated list.
    /// A return value of `null` represents a parse error.
    pub fn initDeclList(ctx: *Context, declaration_index: Ast.Index) ?void {
        switch (declaration_index.tag(ctx.ast)) {
            .declaration_normal, .declaration_important => {},
            else => unreachable,
        }
        ctx.state = .{
            .mode = .decl_list,
            .sequence = declaration_index.children(ctx.ast),
        };
        return ctx.beginList();
    }

    pub const Item = struct {
        index: Ast.Index,
        tag: Component.Tag,
    };

    fn rawNext(ctx: *Context) ?Item {
        const index = ctx.state.sequence.nextSkipSpaces(ctx.ast) orelse return null;
        const tag = index.tag(ctx.ast);
        return .{ .index = index, .tag = tag };
    }

    /// Returns the next item in the current sequence or list item.
    pub fn next(ctx: *Context) ?Item {
        switch (ctx.state.mode) {
            .normal => return ctx.rawNext(),
            .decl => return ctx.rawNext(),
            .decl_list => {
                const item = ctx.rawNext() orelse return null;
                if (item.tag == .token_comma) {
                    ctx.state.sequence.reset(item.index);
                    return null;
                } else {
                    return item;
                }
            },
        }
    }

    /// Checks if the current sequence or list item is empty.
    pub fn empty(ctx: *Context) bool {
        switch (ctx.state.mode) {
            .normal => return ctx.state.sequence.emptySkipSpaces(ctx.ast),
            .decl => return ctx.state.sequence.emptySkipSpaces(ctx.ast),
            .decl_list => {
                const item = ctx.rawNext() orelse return true;
                ctx.state.sequence.reset(item.index);
                return item.tag == .token_comma;
            },
        }
    }

    /// Save the current point in the current sequence or list item.
    pub fn savePoint(ctx: *Context) Ast.Index {
        return ctx.state.sequence.start;
    }

    pub fn resetPoint(ctx: *Context, save_point: Ast.Index) void {
        ctx.state.sequence.reset(save_point);
    }

    /// Sets the children of the Ast node `index` as the current node sequence to iterate over.
    pub fn enterSequence(ctx: *Context, index: Ast.Index) State {
        const new_state: State = .{
            .sequence = index.children(ctx.ast),
            .mode = switch (ctx.state.mode) {
                .normal => .normal,
                .decl, .decl_list => .decl,
            },
        };
        defer ctx.state = new_state;
        return ctx.state;
    }

    pub fn resetState(ctx: *Context, previous_state: State) void {
        ctx.state = previous_state;
    }

    /// Checks for the beginning of a valid comma-separated list.
    /// A return value of `null` represents a parse error.
    fn beginList(ctx: *Context) ?void {
        ctx.assertIsList();
        const item = ctx.rawNext() orelse return;
        ctx.state.sequence.reset(item.index);
        if (item.tag == .token_comma) {
            return null; // Leading comma
        }
    }

    /// Checks that a list item in a comma-separated list has been fully consumed, and
    /// advances to the next list item.
    /// A return value of `null` represents a parse error.
    pub fn endListItem(ctx: *Context) ?void {
        ctx.assertIsList();
        const comma = ctx.rawNext() orelse return;
        if (comma.tag != .token_comma) return null; // List item not fully consumed
        const item = ctx.rawNext() orelse return null; // Trailing comma
        ctx.state.sequence.reset(item.index);
        if (item.tag == .token_comma) return null; // Two commas in a row
    }

    /// Checks for the presence of a next list item in a comma-separated list.
    /// A return value of `null` represents the end of the list.
    pub fn nextListItem(ctx: *Context) ?void {
        ctx.assertIsList();
        const item = ctx.rawNext() orelse return null;
        ctx.state.sequence.reset(item.index);
    }

    fn assertIsList(ctx: *const Context) void {
        switch (ctx.state.mode) {
            .normal, .decl => unreachable,
            .decl_list => {},
        }
    }
};

/// Stores the source locations of URLs found within the most recently parsed `Ast`.
// TODO: Deduplicate identical URLs.
pub const Urls = struct {
    start_id: ?UrlId.Int,
    descriptions: std.MultiArrayList(Description),

    const UrlId = Environment.UrlId;

    pub const Description = struct {
        type: Type,
        src_loc: SourceLocation,
    };

    pub const Type = enum {
        background_image,
    };

    pub const SourceLocation = union(enum) {
        /// The location of a `token_url` Ast node.
        url_token: SourceCode.Location,
        /// The location of a `token_string` Ast node.
        string_token: SourceCode.Location,
    };

    pub fn init(env: *const Environment) Urls {
        return .{
            .start_id = env.next_url_id,
            .descriptions = .empty,
        };
    }

    pub fn deinit(urls: *Urls, allocator: Allocator) void {
        urls.descriptions.deinit(allocator);
    }

    fn nextId(urls: *const Urls) ?UrlId.Int {
        const start_id = urls.start_id orelse return null;
        const len = std.math.cast(UrlId.Int, urls.descriptions.len) orelse return null;
        const int = std.math.add(UrlId.Int, start_id, len) catch return null;
        return int;
    }

    pub fn commit(urls: *const Urls, env: *Environment) void {
        assert(urls.start_id == env.next_url_id);
        env.next_url_id = urls.nextId();
    }

    pub fn clear(urls: *Urls, env: *const Environment) void {
        urls.start_id = env.next_url_id;
        urls.descriptions.clearRetainingCapacity();
    }

    pub const Iterator = struct {
        index: usize,
        urls: *const Urls,

        pub const Item = struct {
            id: UrlId,
            desc: Description,
        };

        pub fn next(it: *Iterator) ?Item {
            if (it.index == it.urls.descriptions.len) return null;
            defer it.index += 1;

            const id: UrlId = @enumFromInt(it.urls.start_id.? + it.index);
            const desc = it.urls.descriptions.get(it.index);
            return .{ .id = id, .desc = desc };
        }
    };

    /// Returns an iterator over all URLs currently stored within `urls`.
    pub fn iterator(urls: *const Urls) Iterator {
        return .{ .index = 0, .urls = urls };
    }

    pub const Managed = struct {
        unmanaged: *Urls,
        allocator: Allocator,

        pub fn addUrl(urls: Managed, desc: Description) !UrlId {
            const int = urls.unmanaged.nextId() orelse return error.OutOfUrls;
            try urls.unmanaged.descriptions.append(urls.allocator, desc);
            return @enumFromInt(int);
        }

        pub fn save(urls: Managed) usize {
            return urls.unmanaged.descriptions.len;
        }

        pub fn reset(urls: Managed, previous_state: usize) void {
            urls.unmanaged.descriptions.shrinkRetainingCapacity(previous_state);
        }
    };

    pub fn toManaged(urls: *Urls, allocator: Allocator) Managed {
        return .{ .unmanaged = urls, .allocator = allocator };
    }
};

pub const background = @import("parse/background.zig");

pub fn cssWideKeyword(ctx: *Context) ?types.CssWideKeyword {
    return keyword(ctx, types.CssWideKeyword, &.{
        .{ "initial", .initial },
        .{ "inherit", .inherit },
        .{ "unset", .unset },
    });
}

fn genericLength(ctx: *const Context, comptime Type: type, index: Ast.Index) ?Type {
    var children = index.children(ctx.ast);
    const unit_index = children.nextSkipSpaces(ctx.ast).?;

    const number = index.extra(ctx.ast).number orelse return null;
    const unit = unit_index.extra(ctx.ast).unit orelse return null;
    return switch (unit) {
        .px => .{ .px = number },
        // Convert em to px using default font-size (16px).
        // TODO: Use computed font-size from cascade context for accurate em resolution.
        .em => .{ .px = number * 16.0 },
        // Convert viewport units to px using default viewport size.
        // TODO: Use actual viewport dimensions from layout context.
        .vw => .{ .px = number * 8.0 },  // 800px viewport width / 100
        .vh => .{ .px = number * 6.0 },  // 600px viewport height / 100
    };
}

fn genericPercentage(ctx: *const Context, comptime Type: type, index: Ast.Index) ?Type {
    const value = index.extra(ctx.ast).number orelse return null;
    return .{ .percentage = value };
}

pub fn identifier(ctx: *Context) ?Location {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_ident) return item.index.location(ctx.ast);

    ctx.resetPoint(item.index);
    return null;
}

pub fn keyword(ctx: *Context, comptime Type: type, kvs: []const SourceCode.KV(Type)) ?Type {
    const save_point = ctx.savePoint();
    const ident = identifier(ctx) orelse return null;
    if (ctx.source_code.mapIdentifierValue(ident, Type, kvs)) |result| {
        return result;
    } else {
        ctx.resetPoint(save_point);
        return null;
    }
}

pub fn integer(ctx: *Context) ?i32 {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_integer) {
        if (item.index.extra(ctx.ast).integer) |value| return value;
    }

    ctx.resetPoint(item.index);
    return null;
}

// Spec: CSS 2.2
// <length>
pub fn length(ctx: *Context, comptime Type: type) ?Type {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_dimension) {
        if (genericLength(ctx, Type, item.index)) |result| return result;
    }
    // CSS spec: unitless 0 is valid for lengths.
    if (item.tag == .token_integer) {
        if (item.index.extra(ctx.ast).integer) |i| {
            if (i == 0) return .{ .px = 0 };
        }
    }

    ctx.resetPoint(item.index);
    return null;
}

// Spec: CSS 2.2
// <percentage>
pub fn percentage(ctx: *Context, comptime Type: type) ?Type {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_percentage) {
        if (genericPercentage(ctx, Type, item.index)) |value| return value;
    }

    ctx.resetPoint(item.index);
    return null;
}

// Spec: CSS 2.2
// <length> | <percentage>
pub fn lengthPercentage(ctx: *Context, comptime Type: type) ?Type {
    return length(ctx, Type) orelse percentage(ctx, Type);
}

// Spec: CSS 2.2
// <length> | <percentage> | auto
pub fn lengthPercentageAuto(ctx: *Context, comptime Type: type) ?Type {
    return length(ctx, Type) orelse percentage(ctx, Type) orelse keyword(ctx, Type, &.{.{ "auto", .auto }});
}

// Spec: CSS 2.2
// <length> | <percentage> | none
pub fn lengthPercentageNone(ctx: *Context, comptime Type: type) ?Type {
    return length(ctx, Type) orelse percentage(ctx, Type) orelse keyword(ctx, Type, &.{.{ "none", .none }});
}

pub fn string(ctx: *Context) ?Location {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_string) {
        return item.index.location(ctx.ast);
    }

    ctx.resetPoint(item.index);
    return null;
}

pub fn hash(ctx: *Context) ?Location {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_hash_id, .token_hash_unrestricted => return item.index.location(ctx.ast),
        else => {},
    }
    ctx.resetPoint(item.index);
    return null;
}

/// Spec: CSS Color Level 4
/// Syntax: <color> = <color-base> | currentColor | <system-color>
///         <color-base> = <hex-color> | <color-function> | <named-color> | transparent
pub fn color(ctx: *Context) ?types.Color {
    // Check for CSS keywords first (currentColor, transparent)
    if (keyword(ctx, types.Color, &.{
        .{ "currentColor", .current_color },
        .{ "transparent", .transparent },
    })) |value| {
        return value;
    }
    
    // Check for CSS named colors (red, blue, green, etc.)
    if (identifier(ctx)) |ident| {
        if (ctx.source_code.mapIdentifierValue(ident, u32, &namedColorKVs)) |rgba| {
            return .{ .rgba = rgba };
        }
    }
    
    // Check for hex colors (#rgb, #rrggbb, etc.)
    if (hash(ctx)) |location| blk: {
        var digits: @Vector(8, u8) = undefined;
        const len = len: {
            var iterator = ctx.source_code.hashIdTokenIterator(location);
            var index: u4 = 0;
            while (iterator.next()) |codepoint| : (index += 1) {
                if (index == 8) break :blk;
                digits[index] = zss.unicode.hexDigitToNumber(codepoint) catch break :blk;
            }
            break :len index;
        };

        const rgba_vec: @Vector(4, u8) = sw: switch (len) {
            3 => {
                digits[3] = 0xF;
                continue :sw 4;
            },
            4 => {
                const vec = @shuffle(u8, digits, undefined, @Vector(4, i32){ 0, 1, 2, 3 });
                break :sw (vec << @splat(4)) | vec;
            },
            6 => {
                digits[6] = 0xF;
                digits[7] = 0xF;
                continue :sw 8;
            },
            8 => {
                const high = @shuffle(u8, digits, undefined, @Vector(4, i32){ 0, 2, 4, 6 });
                const low = @shuffle(u8, digits, undefined, @Vector(4, i32){ 1, 3, 5, 7 });
                break :sw (high << @splat(4)) | low;
            },
            else => break :blk,
        };

        var rgba = std.mem.bytesToValue(u32, &@as([4]u8, rgba_vec));
        rgba = std.mem.bigToNative(u32, rgba);
        return .{ .rgba = rgba };
    }

    return null;
}

// Syntax:
// <url> = <url()> | <src()>
// <url()> = url( <string> <url-modifier>* ) | <url-token>
// <src()> = src( <string> <url-modifier>* )
pub fn url(ctx: *Context) ?Urls.SourceLocation {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_url => return .{ .url_token = item.index.location(ctx.ast) },
        .function => blk: {
            const location = item.index.location(ctx.ast);
            _ = ctx.source_code.mapIdentifierValue(location, void, &.{
                .{ "url", {} },
                .{ "src", {} },
            }) orelse break :blk;

            const state = ctx.enterSequence(item.index);
            defer ctx.resetState(state);

            const str = string(ctx) orelse break :blk;
            if (!ctx.empty()) {
                // The URL may have contained URL modifiers, but these are not supported by zss.
                break :blk;
            }

            return .{ .string_token = str };
        },
        else => {},
    }

    ctx.resetPoint(item.index);
    return null;
}

pub fn urlManaged(ctx: *Context, urls: Urls.Managed, @"type": Urls.Type) !?Environment.UrlId {
    const src_loc = url(ctx) orelse return null;
    const id = try urls.addUrl(.{ .type = @"type", .src_loc = src_loc });
    return id;
}

// Spec: CSS 2.2
// inline | block | list-item | inline-block | table | inline-table | table-row-group | table-header-group
// | table-footer-group | table-row | table-column-group | table-column | table-cell | table-caption | none
pub fn display(ctx: *Context) ?types.Display {
    return keyword(ctx, types.Display, &.{
        .{ "inline", .@"inline" },
        .{ "block", .block },
        // .{ "list-item", .list_item },
        .{ "inline-block", .inline_block },
        .{ "table", .table },
        // .{ "inline-table", .inline_table },
        // .{ "table-row-group", .table_row_group },
        // .{ "table-header-group", .table_header_group },
        // .{ "table-footer-group", .table_footer_group },
        .{ "table-row", .table_row },
        // .{ "table-column-group", .table_column_group },
        // .{ "table-column", .table_column },
        .{ "table-cell", .table_cell },
        // .{ "table-caption", .table_caption },
        .{ "none", .none },
        .{ "flex", .flex },
    });
}

// Spec: CSS 2.2
// static | relative | absolute | fixed
pub fn position(ctx: *Context) ?types.Position {
    return keyword(ctx, types.Position, &.{
        .{ "static", .static },
        .{ "relative", .relative },
        .{ "absolute", .absolute },
        .{ "fixed", .fixed },
    });
}

// Spec: CSS 2.2
// left | right | none
pub fn float(ctx: *Context) ?types.Float {
    return keyword(ctx, types.Float, &.{
        .{ "left", .left },
        .{ "right", .right },
        .{ "none", .none },
    });
}

pub fn clear(ctx: *Context) ?types.Clear {
    return keyword(ctx, types.Clear, &.{
        .{ "none", .none },
        .{ "left", .left },
        .{ "right", .right },
        .{ "both", .both },
    });
}

pub fn overflow(ctx: *Context) ?types.Overflow {
    return keyword(ctx, types.Overflow, &.{
        .{ "visible", .visible },
        .{ "hidden", .hidden },
        .{ "scroll", .scroll },
        .{ "auto", .auto },
    });
}

pub fn flexDirection(ctx: *Context) ?types.FlexDirection {
    return keyword(ctx, types.FlexDirection, &.{
        .{ "row", .row },
        .{ "row-reverse", .row_reverse },
        .{ "column", .column },
        .{ "column-reverse", .column_reverse },
    });
}

pub fn justifyContent(ctx: *Context) ?types.JustifyContent {
    return keyword(ctx, types.JustifyContent, &.{
        .{ "flex-start", .flex_start },
        .{ "flex-end", .flex_end },
        .{ "center", .center },
        .{ "space-between", .space_between },
        .{ "space-around", .space_around },
    });
}

pub fn alignItems(ctx: *Context) ?types.AlignItems {
    return keyword(ctx, types.AlignItems, &.{
        .{ "stretch", .stretch },
        .{ "flex-start", .flex_start },
        .{ "flex-end", .flex_end },
        .{ "center", .center },
        .{ "baseline", .baseline },
    });
}

pub fn boxSizing(ctx: *Context) ?types.BoxSizing {
    return keyword(ctx, types.BoxSizing, &.{
        .{ "content-box", .content_box },
        .{ "border-box", .border_box },
    });
}

/// Parse linear-gradient(color1, color2). Returns the two color stops as RGBA u32.
pub fn linearGradient(ctx: *Context) ?types.LinearGradient {
    const item = ctx.next() orelse return null;
    if (item.tag != .function) {
        ctx.resetPoint(item.index);
        return null;
    }
    const location = item.index.location(ctx.ast);
    // Match function name "linear-gradient"
    _ = ctx.source_code.mapIdentifierValue(location, void, &.{
        .{ "linear-gradient", {} },
    }) orelse {
        ctx.resetPoint(item.index);
        return null;
    };
    // Enter function arguments
    const state = ctx.enterSequence(item.index);
    defer ctx.resetState(state);
    // Parse first color stop
    const from_color = parseColorRgba(ctx) orelse return null;
    // Skip comma
    const comma = ctx.next() orelse return null;
    if (comma.tag != .token_comma) return null;
    // Parse second color stop
    const to_color = parseColorRgba(ctx) orelse return null;
    return .{ .gradient = .{ .from_rgba = from_color, .to_rgba = to_color } };
}

/// Parse a color and return its RGBA u32 value.
fn parseColorRgba(ctx: *Context) ?u32 {
    // Try named color
    if (identifier(ctx)) |ident| {
        if (ctx.source_code.mapIdentifierValue(ident, u32, &namedColorKVs)) |rgba| {
            return rgba;
        }
    }
    // Try hex color
    if (hash(ctx)) |loc| blk: {
        var digits: @Vector(8, u8) = undefined;
        const len = len: {
            var iterator = ctx.source_code.hashIdTokenIterator(loc);
            var index: u4 = 0;
            while (iterator.next()) |codepoint| : (index += 1) {
                if (index == 8) break :blk;
                digits[index] = zss.unicode.hexDigitToNumber(codepoint) catch break :blk;
            }
            break :len index;
        };
        const rgba_vec: @Vector(4, u8) = sw: switch (len) {
            3 => { digits[3] = 0xF; continue :sw 4; },
            4 => {
                const vec = @shuffle(u8, digits, undefined, @Vector(4, i32){ 0, 1, 2, 3 });
                break :sw (vec << @splat(4)) | vec;
            },
            6 => { digits[6] = 0xF; digits[7] = 0xF; continue :sw 8; },
            8 => {
                const vec1 = @shuffle(u8, digits, undefined, @Vector(4, i32){ 0, 2, 4, 6 });
                const vec2 = @shuffle(u8, digits, undefined, @Vector(4, i32){ 1, 3, 5, 7 });
                break :sw (vec1 << @splat(4)) | vec2;
            },
            else => break :blk,
        };
        var rgba = std.mem.bytesToValue(u32, &@as([4]u8, rgba_vec));
        rgba = std.mem.bigToNative(u32, rgba);
        return rgba;
    }
    return null;
}

pub fn opacity(ctx: *Context) ?types.Opacity {
    const item = ctx.next() orelse return null;
    const value: f32 = switch (item.tag) {
        .token_integer => if (item.index.extra(ctx.ast).integer) |i| @as(f32, @floatFromInt(i)) else null,
        .token_number => item.index.extra(ctx.ast).number,
        .token_percentage => item.index.extra(ctx.ast).number,
        else => null,
    } orelse {
        ctx.resetPoint(item.index);
        return null;
    };
    // Clamp opacity to 0.0-1.0 range
    return @max(0.0, @min(1.0, value));
}

// Spec: CSS 2.2
// auto | <integer>
pub fn zIndex(ctx: *Context) ?types.ZIndex {
    if (integer(ctx)) |int| {
        return .{ .integer = int };
    } else {
        return keyword(ctx, types.ZIndex, &.{.{ "auto", .auto }});
    }
}

// Spec: CSS 2.2
// Syntax: <length> | thin | medium | thick
pub fn borderWidth(ctx: *Context) ?types.BorderWidth {
    return length(ctx, types.BorderWidth) orelse
        keyword(ctx, types.BorderWidth, &.{
            .{ "thin", .thin },
            .{ "medium", .medium },
            .{ "thick", .thick },
        });
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <line-style> = none | hidden | dotted | dashed | solid | double | groove | ridge | inset | outset
pub fn borderStyle(ctx: *Context) ?types.BorderStyle {
    return keyword(ctx, types.BorderStyle, &.{
        .{ "none", .none },
        .{ "hidden", .hidden },
        .{ "dotted", .dotted },
        .{ "dashed", .dashed },
        .{ "solid", .solid },
        .{ "double", .double },
        .{ "groove", .groove },
        .{ "ridge", .ridge },
        .{ "inset", .inset },
        .{ "outset", .outset },
    });
}

test "value parsers" {
    const ns = struct {
        fn expectValue(comptime parser: anytype, input: []const u8, expected: ExpectedType(parser)) !void {
            const actual = try runParser(parser, input);
            if (expected) |expected_payload| {
                if (actual) |actual_payload| {
                    errdefer std.debug.print("Expected: {}\nActual: {}\n", .{ expected_payload, actual_payload });
                    return std.testing.expectEqual(expected_payload, actual_payload);
                } else {
                    errdefer std.debug.print("Expected: {}, found: null\n", .{expected_payload});
                    return error.TestExpectedEqual;
                }
            } else {
                errdefer std.debug.print("Expected: null, found: {}\n", .{actual.?});
                return std.testing.expect(actual == null);
            }
        }

        fn runParser(comptime parser: anytype, input: []const u8) !ExpectedType(parser) {
            const allocator = std.testing.allocator;

            const source_code = try SourceCode.init(input);
            var ast, const component_list_index = blk: {
                var syntax_parser = zss.syntax.Parser.init(source_code, allocator);
                defer syntax_parser.deinit();
                break :blk try syntax_parser.parseListOfComponentValues(allocator);
            };
            defer ast.deinit(allocator);

            var ctx = Context.init(ast, source_code);
            _ = ctx.enterSequence(component_list_index);

            switch (std.meta.ArgsTuple(@TypeOf(parser))) {
                struct { *Context } => return parser(&ctx),
                struct { *Context, Urls.Managed } => {
                    var env = Environment.init(allocator, &.empty_document, .all_insensitive, .no_quirks);
                    defer env.deinit();
                    var urls = Urls.init(&env);
                    defer urls.deinit(allocator);
                    const value = try parser(&ctx, urls.toManaged(allocator));
                    urls.commit(&env);
                    return value;
                },
                else => |T| @compileError(@typeName(T) ++ " is not a supported argument list for a value parser"),
            }
        }

        fn ExpectedType(comptime parser: anytype) type {
            const return_type = @typeInfo(@TypeOf(parser)).@"fn".return_type.?;
            return switch (@typeInfo(return_type)) {
                .error_union => |eu| eu.payload,
                .optional => return_type,
                else => comptime unreachable,
            };
        }

        const LengthPercentage = union(enum) { px: f32, percentage: f32 };

        fn lengthPercentage(ctx: *Context) ?LengthPercentage {
            return zss.values.parse.lengthPercentage(ctx, LengthPercentage);
        }

        const LengthPercentageAuto = union(enum) { px: f32, percentage: f32, auto };

        fn lengthPercentageAuto(ctx: *Context) ?LengthPercentageAuto {
            return zss.values.parse.lengthPercentageAuto(ctx, LengthPercentageAuto);
        }

        const LengthPercentageNone = union(enum) { px: f32, percentage: f32, none };

        fn lengthPercentageNone(ctx: *Context) ?LengthPercentageNone {
            return zss.values.parse.lengthPercentageNone(ctx, LengthPercentageNone);
        }
    };

    try ns.expectValue(display, "block", .block);
    try ns.expectValue(display, "inline", .@"inline");

    try ns.expectValue(position, "static", .static);

    try ns.expectValue(float, "left", .left);
    try ns.expectValue(float, "right", .right);
    try ns.expectValue(float, "none", .none);

    try ns.expectValue(zIndex, "42", .{ .integer = 42 });
    try ns.expectValue(zIndex, "-42", .{ .integer = -42 });
    try ns.expectValue(zIndex, "auto", .auto);
    try ns.expectValue(zIndex, "9999999999999999", null);
    try ns.expectValue(zIndex, "-9999999999999999", null);

    try ns.expectValue(ns.lengthPercentage, "5px", .{ .px = 5 });
    try ns.expectValue(ns.lengthPercentage, "5%", .{ .percentage = 0.05 });
    try ns.expectValue(ns.lengthPercentage, "5", null);
    try ns.expectValue(ns.lengthPercentage, "auto", null);

    try ns.expectValue(ns.lengthPercentageAuto, "5px", .{ .px = 5 });
    try ns.expectValue(ns.lengthPercentageAuto, "5%", .{ .percentage = 0.05 });
    try ns.expectValue(ns.lengthPercentageAuto, "5", null);
    try ns.expectValue(ns.lengthPercentageAuto, "auto", .auto);

    try ns.expectValue(ns.lengthPercentageNone, "5px", .{ .px = 5 });
    try ns.expectValue(ns.lengthPercentageNone, "5%", .{ .percentage = 0.05 });
    try ns.expectValue(ns.lengthPercentageNone, "5", null);
    try ns.expectValue(ns.lengthPercentageNone, "auto", null);
    try ns.expectValue(ns.lengthPercentageNone, "none", .none);

    try ns.expectValue(borderWidth, "5px", .{ .px = 5 });
    try ns.expectValue(borderWidth, "thin", .thin);
    try ns.expectValue(borderWidth, "medium", .medium);
    try ns.expectValue(borderWidth, "thick", .thick);

    try ns.expectValue(background.image, "none", .none);
    _ = try ns.runParser(background.image, "url(abcd)");
    _ = try ns.runParser(background.image, "url( \"abcd\" )");
    _ = try ns.runParser(background.image, "src(\"wxyz\")");
    try ns.expectValue(background.image, "invalid", null);

    try ns.expectValue(background.repeat, "repeat-x", .{ .x = .repeat, .y = .no_repeat });
    try ns.expectValue(background.repeat, "repeat-y", .{ .x = .no_repeat, .y = .repeat });
    try ns.expectValue(background.repeat, "repeat", .{ .x = .repeat, .y = .repeat });
    try ns.expectValue(background.repeat, "space", .{ .x = .space, .y = .space });
    try ns.expectValue(background.repeat, "round", .{ .x = .round, .y = .round });
    try ns.expectValue(background.repeat, "no-repeat", .{ .x = .no_repeat, .y = .no_repeat });
    try ns.expectValue(background.repeat, "invalid", null);
    try ns.expectValue(background.repeat, "repeat space", .{ .x = .repeat, .y = .space });
    try ns.expectValue(background.repeat, "round no-repeat", .{ .x = .round, .y = .no_repeat });
    try ns.expectValue(background.repeat, "invalid space", null);
    try ns.expectValue(background.repeat, "space invalid", .{ .x = .space, .y = .space });
    try ns.expectValue(background.repeat, "repeat-x invalid", .{ .x = .repeat, .y = .no_repeat });

    try ns.expectValue(background.attachment, "scroll", .scroll);
    try ns.expectValue(background.attachment, "fixed", .fixed);
    try ns.expectValue(background.attachment, "local", .local);

    try ns.expectValue(background.position, "center", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "left", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "top", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "50%", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0.5 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "50px", .{
        .x = .{ .side = .start, .offset = .{ .px = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "left top", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "left center", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "center right", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "50px right", .{
        .x = .{ .side = .start, .offset = .{ .px = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "right center", .{
        .x = .{ .side = .end, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "center center 50%", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "left center 20px", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "left 20px bottom 50%", .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 0.5 } },
    });
    try ns.expectValue(background.position, "center bottom 50%", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 0.5 } },
    });
    try ns.expectValue(background.position, "bottom 50% center", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 0.5 } },
    });
    try ns.expectValue(background.position, "bottom 50% left 20px", .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 0.5 } },
    });

    try ns.expectValue(background.clip, "border-box", .border_box);
    try ns.expectValue(background.clip, "padding-box", .padding_box);
    try ns.expectValue(background.clip, "content-box", .content_box);

    try ns.expectValue(background.origin, "border-box", .border_box);
    try ns.expectValue(background.origin, "padding-box", .padding_box);
    try ns.expectValue(background.origin, "content-box", .content_box);

    try ns.expectValue(background.size, "contain", .contain);
    try ns.expectValue(background.size, "cover", .cover);
    try ns.expectValue(background.size, "auto", .{ .size = .{ .width = .auto, .height = .auto } });
    try ns.expectValue(background.size, "auto auto", .{ .size = .{ .width = .auto, .height = .auto } });
    try ns.expectValue(background.size, "5px", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .px = 5 } } });
    try ns.expectValue(background.size, "5px 5%", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .percentage = 0.05 } } });

    try ns.expectValue(color, "currentColor", .current_color);
    try ns.expectValue(color, "transparent", .transparent);
    try ns.expectValue(color, "#abc", .{ .rgba = 0xaabbccff });
    try ns.expectValue(color, "#abcd", .{ .rgba = 0xaabbccdd });
    try ns.expectValue(color, "#123456", .{ .rgba = 0x123456ff });
    try ns.expectValue(color, "#12345678", .{ .rgba = 0x12345678 });

    try ns.expectValue(borderStyle, "none", .none);
    try ns.expectValue(borderStyle, "ridge", .ridge);
}
