//! Media queries (Media Queries Level 4 §2-§4, with the Level 5 preference
//! features): parsing into a query list, evaluation against a `Device`, and
//! CSSOM serialization (`MediaQueryList.media`).
//!
//! Grammar (MQ4 §3):
//!
//!   <media-query-list> = <media-query>#
//!   <media-query>      = <media-condition>
//!                      | [ not | only ]? <media-type> [ and <media-condition-without-or> ]?
//!   <media-condition>  = <media-not> | <media-in-parens> [ <media-and>* | <media-or>* ]
//!   <media-in-parens>  = ( <media-condition> ) | <media-feature> | <general-enclosed>
//!   <media-feature>    = ( [ <mf-plain> | <mf-boolean> | <mf-range> ] )
//!
//! A query that does not match the grammar is `not all` (§3.2); the other
//! queries of the list still get a say. Evaluation is three-valued (§3.1,
//! Kleene logic): <general-enclosed>, and a feature that is not known or
//! whose value is not valid for it, are *unknown*; a query whose result is
//! unknown is false, also under `not`.

const std = @import("std");
const zss = @import("zss.zig");
const Allocator = std.mem.Allocator;
const Ast = zss.syntax.Ast;
const SourceCode = zss.syntax.SourceCode;
const Token = zss.syntax.Token;

/// The output device and user preferences media features are evaluated for.
pub const Device = struct {
    /// The viewport (MQ4 §4.1 `width`, §4.2 `height`), in CSS px.
    width_px: f32,
    height_px: f32,
    /// False while the host has not set a viewport: every `@media` block is
    /// included (static renderers). A configured 0×0 viewport is a real size.
    configured: bool = true,
    /// The screen (`device-width`/`device-height`); the viewport when null.
    device_width_px: ?f32 = null,
    device_height_px: ?f32 = null,
    media_type: MediaType = .screen,
    resolution_dppx: f32 = 1,
    color_scheme: ColorScheme = .light,
    reduced_motion: Reduce = .@"no-preference",
    reduced_transparency: Reduce = .@"no-preference",
    reduced_data: Reduce = .@"no-preference",
    contrast: Contrast = .@"no-preference",
    forced_colors: ForcedColors = .none,

    pub const MediaType = enum { screen, print };
    pub const ColorScheme = enum { light, dark };
    pub const Reduce = enum { @"no-preference", reduce };
    pub const Contrast = enum { @"no-preference", more, less, custom };
    pub const ForcedColors = enum { none, active };
};

/// MQ4 §3.1 three-valued logic.
const Truth = enum {
    true,
    false,
    unknown,

    fn not(t: Truth) Truth {
        return switch (t) {
            .true => .false,
            .false => .true,
            .unknown => .unknown,
        };
    }
    fn andWith(a: Truth, b: Truth) Truth {
        if (a == .false or b == .false) return .false;
        if (a == .unknown or b == .unknown) return .unknown;
        return .true;
    }
    fn orWith(a: Truth, b: Truth) Truth {
        if (a == .true or b == .true) return .true;
        if (a == .unknown or b == .unknown) return .unknown;
        return .false;
    }
    fn of(b: bool) Truth {
        return if (b) .true else .false;
    }
};

pub const Comparison = enum {
    lt,
    le,
    gt,
    ge,
    eq,

    fn text(op: Comparison) []const u8 {
        return switch (op) {
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .eq => "=",
        };
    }

    fn holds(op: Comparison, a: f32, b: f32) bool {
        return switch (op) {
            .lt => a < b,
            .le => a <= b,
            .gt => a > b,
            .ge => a >= b,
            .eq => a == b,
        };
    }
};

/// <mf-value> = <number> | <dimension> | <ident> | <ratio>, or a math function.
pub const Value = union(enum) {
    integer: i32,
    number: f32,
    dimension: struct { number: f32, unit: ?Token.Unit, unit_text: []const u8 },
    ident: []const u8,
    ratio: [2]f32,
    /// The source text of a math function (`calc(…)`); viewport units make its
    /// value depend on the device, so it is evaluated with the query.
    math: []const u8,
};

pub const Feature = struct {
    /// Lowercased, with a `min-`/`max-` prefix as written.
    name: []const u8,
    form: Form,

    pub const Form = union(enum) {
        /// `(name)`
        boolean,
        /// `(name: value)`
        plain: Value,
        /// `(value op name op value)`, either side optional (not both absent).
        range: struct {
            left: ?struct { value: Value, op: Comparison } = null,
            right: ?struct { op: Comparison, value: Value } = null,
        },
    };
};

pub const Condition = union(enum) {
    not: *const Condition,
    all: []const Condition,
    any: []const Condition,
    /// `( <media-condition> )`
    in_parens: *const Condition,
    feature: Feature,
    /// <general-enclosed>, or a feature that is not known or not valid: its
    /// source text. Evaluates to unknown.
    general_enclosed: []const u8,
};

pub const Query = struct {
    qualifier: enum { none, not, only } = .none,
    /// Lowercased; null for a bare <media-condition>.
    media_type: ?[]const u8 = null,
    condition: ?Condition = null,
    /// The query did not match the grammar: it is `not all`.
    invalid: bool = false,
};

pub const QueryList = struct {
    arena: std.heap.ArenaAllocator,
    queries: []const Query,

    pub fn deinit(list: *QueryList) void {
        list.arena.deinit();
    }

    /// Parse a media query list from text (CSSOM §4.1 "parse a media query list").
    pub fn parse(allocator: Allocator, text: []const u8) Allocator.Error!QueryList {
        var list: QueryList = .{ .arena = .init(allocator), .queries = &.{} };
        errdefer list.deinit();
        const source = SourceCode.init(text) catch {
            list.queries = try list.arena.allocator().dupe(Query, &.{.{ .invalid = true }});
            return list;
        };
        var parser = zss.syntax.Parser.init(source, allocator);
        defer parser.deinit();
        var ast, const root = parser.parseListOfComponentValues(allocator) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                list.queries = try list.arena.allocator().dupe(Query, &.{.{ .invalid = true }});
                return list;
            },
        };
        defer ast.deinit(allocator);
        list.queries = try parseQueries(list.arena.allocator(), ast, source, root.children(ast));
        return list;
    }

    /// Parse the media query list in `sequence` (an `@media` prelude).
    pub fn parseSequence(allocator: Allocator, ast: Ast, source: SourceCode, sequence: Ast.Sequence) Allocator.Error!QueryList {
        var list: QueryList = .{ .arena = .init(allocator), .queries = &.{} };
        errdefer list.deinit();
        list.queries = try parseQueries(list.arena.allocator(), ast, source, sequence);
        return list;
    }

    /// MQ4 §2: an empty list is true; otherwise true if any query is.
    pub fn matches(list: *const QueryList, allocator: Allocator, device: Device) bool {
        if (list.queries.len == 0) return true;
        for (list.queries) |query| {
            if (evaluateQuery(query, allocator, device) == .true) return true;
        }
        return false;
    }

    /// CSSOM §4.2 "serialize a media query list".
    pub fn format(list: *const QueryList, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (list.queries, 0..) |query, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeQuery(writer, query);
        }
    }

    pub fn serialize(list: *const QueryList, allocator: Allocator) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        list.format(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
};

/// Whether the media query list `text` matches `device`.
pub fn evaluate(allocator: Allocator, text: []const u8, device: Device) Allocator.Error!bool {
    if (!device.configured) return true;
    var list = try QueryList.parse(allocator, text);
    defer list.deinit();
    return list.matches(allocator, device);
}

// --- Parsing ---

fn parseQueries(arena: Allocator, ast: Ast, source: SourceCode, sequence: Ast.Sequence) Allocator.Error![]const Query {
    var parser: Parser = .{ .arena = arena, .ast = ast, .source = source };
    var queries: std.ArrayList(Query) = .empty;
    var rest = sequence;
    var part_start = rest.start;
    var commas: usize = 0;
    while (rest.nextKeepSpaces(ast)) |index| {
        if (index.tag(ast) != .token_comma) continue;
        commas += 1;
        try queries.append(arena, try parser.query(.{ .start = part_start, .end = index }));
        part_start = rest.start;
    }
    var last: Ast.Sequence = .{ .start = part_start, .end = sequence.end };
    // "If the media query list is empty (the declaration is the empty string
    // or consists solely of whitespace) it evaluates to true."
    if (commas == 0 and last.emptySkipSpaces(ast)) return &.{};
    try queries.append(arena, try parser.query(.{ .start = part_start, .end = sequence.end }));
    return queries.items;
}

const Parser = struct {
    arena: Allocator,
    ast: Ast,
    source: SourceCode,

    const invalid_query: Query = .{ .invalid = true };

    fn isIdent(p: *const Parser, index: Ast.Index, comptime keyword: []const u8) bool {
        return index.tag(p.ast) == .token_ident and p.source.identifierEqlIgnoreCase(index.location(p.ast), keyword);
    }

    fn identText(p: *const Parser, index: Ast.Index) Allocator.Error![]const u8 {
        const copy = try p.source.copyIdentifier(index.location(p.ast), .{ .allocator = p.arena });
        for (copy) |*c| c.* = std.ascii.toLower(c.*);
        return copy;
    }

    /// The source text of the block or function at `index`, closing
    /// parenthesis included.
    fn sourceText(p: *const Parser, index: Ast.Index) Allocator.Error![]const u8 {
        const text = p.source.text;
        const start: u32 = @intFromEnum(index.location(p.ast));
        var tokenizer = zss.syntax.Tokenizer.init(p.source);
        tokenizer.setLocation(index.location(p.ast));
        var depth: usize = 0;
        const end: usize = while (true) {
            const token, _ = (tokenizer.next() catch break text.len) orelse break text.len;
            switch (token) {
                .token_left_paren, .token_function, .token_left_square, .token_left_curly => depth += 1,
                .token_right_paren, .token_right_square, .token_right_curly => {
                    depth -|= 1;
                    if (depth == 0) break @intFromEnum(tokenizer.getLocation());
                },
                else => {},
            }
        };
        return p.arena.dupe(u8, text[start..end]);
    }

    fn query(p: *Parser, sequence: Ast.Sequence) Allocator.Error!Query {
        var seq = sequence;
        const start = seq.start;
        const first = seq.nextSkipSpaces(p.ast) orelse return invalid_query;
        if (first.tag(p.ast) != .token_ident) {
            seq.reset(start);
            const cond = (try p.condition(&seq, true)) orelse return invalid_query;
            return .{ .condition = cond };
        }
        var result: Query = .{};
        var type_index = first;
        if (p.isIdent(first, "not") or p.isIdent(first, "only")) {
            const after_qualifier = seq.start;
            const next = seq.nextSkipSpaces(p.ast) orelse return invalid_query;
            if (next.tag(p.ast) != .token_ident) {
                // `not ( … )` is a <media-not> condition; `only` needs a type.
                if (!p.isIdent(first, "not")) return invalid_query;
                seq.reset(start);
                const cond = (try p.condition(&seq, true)) orelse return invalid_query;
                return .{ .condition = cond };
            }
            _ = after_qualifier;
            result.qualifier = if (p.isIdent(first, "not")) .not else .only;
            type_index = next;
        }
        // <media-type> = <ident>, except the keywords of the grammar.
        inline for (.{ "only", "not", "and", "or", "layer" }) |reserved| {
            if (p.isIdent(type_index, reserved)) return invalid_query;
        }
        result.media_type = try p.identText(type_index);
        const and_keyword = seq.nextSkipSpaces(p.ast) orelse return result;
        if (!p.isIdent(and_keyword, "and")) return invalid_query;
        result.condition = (try p.condition(&seq, false)) orelse return invalid_query;
        return result;
    }

    /// <media-condition> (or <media-condition-without-or>), consuming all of
    /// `seq`. Null if it does not match the grammar.
    fn condition(p: *Parser, seq: *Ast.Sequence, allow_or: bool) Allocator.Error!?Condition {
        const first = seq.nextSkipSpaces(p.ast) orelse return null;
        if (p.isIdent(first, "not")) {
            const operand_index = seq.nextSkipSpaces(p.ast) orelse return null;
            const operand = (try p.inParens(operand_index)) orelse return null;
            if (!seq.emptySkipSpaces(p.ast)) return null;
            const boxed = try p.arena.create(Condition);
            boxed.* = operand;
            return .{ .not = boxed };
        }
        const head = (try p.inParens(first)) orelse return null;
        var operands: std.ArrayList(Condition) = .empty;
        try operands.append(p.arena, head);
        const Junction = enum { @"and", @"or" };
        var junction: ?Junction = null;
        while (seq.nextSkipSpaces(p.ast)) |keyword| {
            const this: Junction = if (p.isIdent(keyword, "and")) .@"and" else if (allow_or and p.isIdent(keyword, "or")) .@"or" else return null;
            // `and` and `or` may not be mixed at one level.
            if (junction != null and junction.? != this) return null;
            junction = this;
            const operand_index = seq.nextSkipSpaces(p.ast) orelse return null;
            try operands.append(p.arena, (try p.inParens(operand_index)) orelse return null);
        }
        const j = junction orelse return head;
        return switch (j) {
            .@"and" => .{ .all = operands.items },
            .@"or" => .{ .any = operands.items },
        };
    }

    /// <media-in-parens>. Null if `index` is neither a ()-block nor a function.
    fn inParens(p: *Parser, index: Ast.Index) Allocator.Error!?Condition {
        switch (index.tag(p.ast)) {
            .simple_block_paren => {
                if (try p.feature(index)) |f| {
                    // A feature that is not known, or used in a way it does not
                    // allow, is <general-enclosed>.
                    if (evaluateFeature(f, p.arena, .{ .width_px = 0, .height_px = 0 }) != .unknown) return .{ .feature = asTyped(f) };
                    return .{ .general_enclosed = try p.sourceText(index) };
                }
                var inner = index.children(p.ast);
                if (try p.condition(&inner, true)) |nested| {
                    const boxed = try p.arena.create(Condition);
                    boxed.* = nested;
                    return .{ .in_parens = boxed };
                }
                return .{ .general_enclosed = try p.sourceText(index) };
            },
            .function => return .{ .general_enclosed = try p.sourceText(index) },
            else => return null,
        }
    }

    /// <media-feature>: the contents of the ()-block at `block`. Null if they
    /// are not <mf-plain>, <mf-boolean> or <mf-range>.
    fn feature(p: *Parser, block: Ast.Index) Allocator.Error!?Feature {
        var seq = block.children(p.ast);
        const start = seq.start;
        const first = seq.nextSkipSpaces(p.ast) orelse return null;
        if (first.tag(p.ast) == .token_ident) {
            const name = try p.identText(first);
            const after = seq.nextSkipSpaces(p.ast) orelse return .{ .name = name, .form = .boolean };
            switch (after.tag(p.ast)) {
                .token_colon => {
                    const v = (try p.value(&seq)) orelse return null;
                    if (!seq.emptySkipSpaces(p.ast)) return null;
                    return .{ .name = name, .form = .{ .plain = v } };
                },
                .token_delim => {
                    const op = p.comparison(after, &seq) orelse return null;
                    const v = (try p.value(&seq)) orelse return null;
                    if (!seq.emptySkipSpaces(p.ast)) return null;
                    return .{ .name = name, .form = .{ .range = .{ .right = .{ .op = op, .value = v } } } };
                },
                else => return null,
            }
        }
        // <mf-value> <mf-comparison> <mf-name> [ <mf-comparison> <mf-value> ]?
        seq.reset(start);
        const left = (try p.value(&seq)) orelse return null;
        const left_op_index = seq.nextSkipSpaces(p.ast) orelse return null;
        if (left_op_index.tag(p.ast) != .token_delim) return null;
        const left_op = p.comparison(left_op_index, &seq) orelse return null;
        const name_index = seq.nextSkipSpaces(p.ast) orelse return null;
        if (name_index.tag(p.ast) != .token_ident) return null;
        const name = try p.identText(name_index);
        const right_op_index = seq.nextSkipSpaces(p.ast) orelse
            return .{ .name = name, .form = .{ .range = .{ .left = .{ .value = left, .op = left_op } } } };
        if (right_op_index.tag(p.ast) != .token_delim) return null;
        const right_op = p.comparison(right_op_index, &seq) orelse return null;
        const right = (try p.value(&seq)) orelse return null;
        if (!seq.emptySkipSpaces(p.ast)) return null;
        // <mf-value> <mf-lt> <mf-name> <mf-lt> <mf-value>, or both <mf-gt>.
        const descending = left_op == .gt or left_op == .ge;
        const ascending = left_op == .lt or left_op == .le;
        if (!((ascending and (right_op == .lt or right_op == .le)) or (descending and (right_op == .gt or right_op == .ge)))) return null;
        return .{ .name = name, .form = .{ .range = .{
            .left = .{ .value = left, .op = left_op },
            .right = .{ .op = right_op, .value = right },
        } } };
    }

    /// <mf-comparison> starting at the delim `first`: `<`, `>`, `=`, `<=`, `>=`
    /// (no whitespace inside the two-character forms).
    fn comparison(p: *Parser, first: Ast.Index, seq: *Ast.Sequence) ?Comparison {
        const c = first.extra(p.ast).codepoint;
        if (c == '=') return .eq;
        if (c != '<' and c != '>') return null;
        if (!seq.emptyKeepSpaces()) {
            const next = seq.start;
            if (next.tag(p.ast) == .token_delim and next.extra(p.ast).codepoint == '=') {
                _ = seq.nextKeepSpaces(p.ast);
                return if (c == '<') .le else .ge;
            }
        }
        return if (c == '<') .lt else .gt;
    }

    /// <mf-value>. Consumes nothing and returns null if there is none.
    fn value(p: *Parser, seq: *Ast.Sequence) Allocator.Error!?Value {
        const start = seq.start;
        const index = seq.nextSkipSpaces(p.ast) orelse return null;
        switch (index.tag(p.ast)) {
            .token_integer, .token_number => {
                const number: f32 = if (index.tag(p.ast) == .token_integer)
                    @floatFromInt(index.extra(p.ast).integer orelse {
                        seq.reset(start);
                        return null;
                    })
                else
                    index.extra(p.ast).number orelse {
                        seq.reset(start);
                        return null;
                    };
                // <ratio> = <number [0,∞]> [ / <number [0,∞]> ]?
                const after_number = seq.start;
                if (seq.nextSkipSpaces(p.ast)) |slash| {
                    if (slash.tag(p.ast) == .token_delim and slash.extra(p.ast).codepoint == '/') {
                        if (seq.nextSkipSpaces(p.ast)) |second| {
                            const denominator: ?f32 = switch (second.tag(p.ast)) {
                                .token_integer => if (second.extra(p.ast).integer) |i| @as(f32, @floatFromInt(i)) else null,
                                .token_number => second.extra(p.ast).number,
                                else => null,
                            };
                            if (denominator) |d| return .{ .ratio = .{ number, d } };
                        }
                        seq.reset(start);
                        return null;
                    }
                }
                seq.reset(after_number);
                if (index.tag(p.ast) == .token_integer) return .{ .integer = index.extra(p.ast).integer.? };
                return .{ .number = number };
            },
            .token_dimension => {
                const number = index.extra(p.ast).number orelse {
                    seq.reset(start);
                    return null;
                };
                var children = index.children(p.ast);
                const unit_index = children.nextSkipSpaces(p.ast) orelse {
                    seq.reset(start);
                    return null;
                };
                return .{ .dimension = .{
                    .number = number,
                    .unit = unit_index.extra(p.ast).unit,
                    .unit_text = try p.identText(unit_index),
                } };
            },
            .token_ident => return .{ .ident = try p.identText(index) },
            .function => {
                if (!zss.values.calc.isMathFunction(p.source, p.ast, index)) {
                    seq.reset(start);
                    return null;
                }
                return .{ .math = try p.sourceText(index) };
            },
            else => {
                seq.reset(start);
                return null;
            },
        }
    }
};

/// A valid feature with its values in the feature's type: a <number> where a
/// <ratio> is expected is the ratio `n / 1` (CSS Values 4 §5.7), and is
/// serialized as one.
fn asTyped(feature: Feature) Feature {
    var name = feature.name;
    if (std.mem.startsWith(u8, name, "min-") or std.mem.startsWith(u8, name, "max-")) name = name[4..];
    const id = std.meta.stringToEnum(Name, name) orelse return feature;
    if (kindOf(id) != .ratio) return feature;
    const fix = struct {
        fn ratio(value: Value) Value {
            return switch (value) {
                .integer => |i| .{ .ratio = .{ @floatFromInt(i), 1 } },
                .number => |n| .{ .ratio = .{ n, 1 } },
                else => value,
            };
        }
    };
    var result = feature;
    switch (result.form) {
        .boolean => {},
        .plain => |*value| value.* = fix.ratio(value.*),
        .range => |*range| {
            if (range.left) |*left| left.value = fix.ratio(left.value);
            if (range.right) |*right| right.value = fix.ratio(right.value);
        },
    }
    return result;
}

// --- Evaluation ---

fn evaluateQuery(query: Query, allocator: Allocator, device: Device) Truth {
    if (query.invalid) return .false;
    var result: Truth = .true;
    if (query.media_type) |media_type| {
        // MQ4 §2.3: `all` matches every device; an unknown or deprecated type
        // matches none.
        result = Truth.of(std.mem.eql(u8, media_type, "all") or std.mem.eql(u8, media_type, @tagName(device.media_type)));
    }
    if (query.condition) |cond| result = result.andWith(evaluateCondition(cond, allocator, device));
    return if (query.qualifier == .not) result.not() else result;
}

fn evaluateCondition(cond: Condition, allocator: Allocator, device: Device) Truth {
    switch (cond) {
        .not => |operand| return evaluateCondition(operand.*, allocator, device).not(),
        .all => |operands| {
            var result: Truth = .true;
            for (operands) |operand| result = result.andWith(evaluateCondition(operand, allocator, device));
            return result;
        },
        .any => |operands| {
            var result: Truth = .false;
            for (operands) |operand| result = result.orWith(evaluateCondition(operand, allocator, device));
            return result;
        },
        .in_parens => |inner| return evaluateCondition(inner.*, allocator, device),
        .feature => |f| return evaluateFeature(f, allocator, device),
        .general_enclosed => return .unknown,
    }
}

const Name = enum {
    width,
    height,
    @"device-width",
    @"device-height",
    @"aspect-ratio",
    @"device-aspect-ratio",
    orientation,
    resolution,
    @"-webkit-device-pixel-ratio",
    color,
    @"color-index",
    monochrome,
    grid,
    scan,
    update,
    @"overflow-block",
    @"overflow-inline",
    @"color-gamut",
    pointer,
    @"any-pointer",
    hover,
    @"any-hover",
    @"prefers-color-scheme",
    @"prefers-reduced-motion",
    @"prefers-reduced-transparency",
    @"prefers-reduced-data",
    @"prefers-contrast",
    @"forced-colors",
    @"inverted-colors",
    @"dynamic-range",
    @"video-dynamic-range",
    scripting,
    @"display-mode",
};

/// The value type of a feature. The first five are "range" features (§2.4.1):
/// they take `min-`/`max-` prefixes and the range syntax.
const Kind = union(enum) {
    length,
    ratio,
    resolution,
    number,
    integer,
    /// <mq-boolean> = 0 | 1
    boolean,
    /// A keyword of the list.
    discrete: []const []const u8,

    fn isRange(kind: Kind) bool {
        return switch (kind) {
            .length, .ratio, .resolution, .number, .integer => true,
            .boolean, .discrete => false,
        };
    }
};

fn kindOf(name: Name) Kind {
    return switch (name) {
        .width, .height, .@"device-width", .@"device-height" => .length,
        .@"aspect-ratio", .@"device-aspect-ratio" => .ratio,
        .resolution => .resolution,
        .@"-webkit-device-pixel-ratio" => .number,
        .color, .@"color-index", .monochrome => .integer,
        .grid => .boolean,
        .orientation => .{ .discrete = &.{ "portrait", "landscape" } },
        .scan => .{ .discrete = &.{ "interlace", "progressive" } },
        .update => .{ .discrete = &.{ "none", "slow", "fast" } },
        .@"overflow-block" => .{ .discrete = &.{ "none", "scroll", "paged" } },
        .@"overflow-inline" => .{ .discrete = &.{ "none", "scroll" } },
        .@"color-gamut" => .{ .discrete = &.{ "srgb", "p3", "rec2020" } },
        .pointer, .@"any-pointer" => .{ .discrete = &.{ "none", "coarse", "fine" } },
        .hover, .@"any-hover" => .{ .discrete = &.{ "none", "hover" } },
        .@"prefers-color-scheme" => .{ .discrete = &.{ "light", "dark" } },
        .@"prefers-reduced-motion", .@"prefers-reduced-transparency", .@"prefers-reduced-data" => .{ .discrete = &.{ "no-preference", "reduce" } },
        .@"prefers-contrast" => .{ .discrete = &.{ "no-preference", "more", "less", "custom" } },
        .@"forced-colors" => .{ .discrete = &.{ "none", "active" } },
        .@"inverted-colors" => .{ .discrete = &.{ "none", "inverted" } },
        .@"dynamic-range", .@"video-dynamic-range" => .{ .discrete = &.{ "standard", "high" } },
        .scripting => .{ .discrete = &.{ "none", "initial-only", "enabled" } },
        .@"display-mode" => .{ .discrete = &.{ "fullscreen", "standalone", "minimal-ui", "browser", "picture-in-picture", "window-controls-overlay" } },
    };
}

/// The device's value of a range feature. A ratio is width / height.
fn numericValue(name: Name, device: Device) f32 {
    return switch (name) {
        .width => device.width_px,
        .height => device.height_px,
        .@"device-width" => device.device_width_px orelse device.width_px,
        .@"device-height" => device.device_height_px orelse device.height_px,
        .@"aspect-ratio" => device.width_px / device.height_px,
        .@"device-aspect-ratio" => (device.device_width_px orelse device.width_px) / (device.device_height_px orelse device.height_px),
        .resolution, .@"-webkit-device-pixel-ratio" => device.resolution_dppx,
        // 8 bits per colour component, no colour lookup table, not monochrome,
        // a bitmap (not grid) device.
        .color => 8,
        .@"color-index", .monochrome, .grid => 0,
        else => unreachable,
    };
}

/// The device's value of a discrete feature.
fn keywordValue(name: Name, device: Device) []const u8 {
    return switch (name) {
        .orientation => if (device.height_px >= device.width_px) "portrait" else "landscape",
        .scan => "progressive",
        .update => if (device.media_type == .print) "none" else "fast",
        .@"overflow-block" => if (device.media_type == .print) "paged" else "scroll",
        .@"overflow-inline" => if (device.media_type == .print) "none" else "scroll",
        .@"color-gamut" => "srgb",
        .pointer, .@"any-pointer" => "fine",
        .hover, .@"any-hover" => "hover",
        .@"prefers-color-scheme" => @tagName(device.color_scheme),
        .@"prefers-reduced-motion" => @tagName(device.reduced_motion),
        .@"prefers-reduced-transparency" => @tagName(device.reduced_transparency),
        .@"prefers-reduced-data" => @tagName(device.reduced_data),
        .@"prefers-contrast" => @tagName(device.contrast),
        .@"forced-colors" => @tagName(device.forced_colors),
        .@"inverted-colors" => "none",
        .@"dynamic-range", .@"video-dynamic-range" => "standard",
        .scripting => "enabled",
        .@"display-mode" => "browser",
        else => unreachable,
    };
}

/// §2.4.2: in a boolean context a feature is true unless its value is 0 or
/// the keyword `none` — or a preference's `no-preference` (MQ5 §11).
fn isNoneKeyword(keyword: []const u8) bool {
    return std.mem.eql(u8, keyword, "none") or std.mem.eql(u8, keyword, "no-preference");
}

fn evaluateFeature(feature: Feature, allocator: Allocator, device: Device) Truth {
    var bare_name = feature.name;
    var prefix: ?Comparison = null;
    const prefixes = [_]struct { []const u8, []const u8, Comparison }{
        .{ "min-", "", .ge },
        .{ "max-", "", .le },
        .{ "-webkit-min-", "-webkit-", .ge },
        .{ "-webkit-max-", "-webkit-", .le },
    };
    var buffer: [64]u8 = undefined;
    for (prefixes) |entry| {
        if (!std.mem.startsWith(u8, bare_name, entry[0])) continue;
        const rest = bare_name[entry[0].len..];
        if (entry[1].len + rest.len > buffer.len) return .unknown;
        @memcpy(buffer[0..entry[1].len], entry[1]);
        @memcpy(buffer[entry[1].len..][0..rest.len], rest);
        bare_name = buffer[0 .. entry[1].len + rest.len];
        prefix = entry[2];
        break;
    }
    const name = std.meta.stringToEnum(Name, bare_name) orelse return .unknown;
    const kind = kindOf(name);
    // §2.4.3: the prefixes exist for range features, in the plain form only.
    if (prefix != null and (!kind.isRange() or feature.form != .plain)) return .unknown;

    switch (feature.form) {
        .boolean => switch (kind) {
            .discrete => return Truth.of(!isNoneKeyword(keywordValue(name, device))),
            .ratio => return Truth.of(numericValue(name, device) != 0 and !std.math.isNan(numericValue(name, device))),
            else => return Truth.of(numericValue(name, device) != 0),
        },
        .plain => |value| switch (kind) {
            .discrete => |keywords| {
                if (value != .ident) return .unknown;
                for (keywords) |keyword| {
                    if (std.mem.eql(u8, keyword, value.ident)) return Truth.of(std.mem.eql(u8, keyword, keywordValue(name, device)));
                }
                return .unknown;
            },
            else => {
                const wanted = resolveValue(kind, value, allocator, device) orelse return .unknown;
                return Truth.of((prefix orelse Comparison.eq).holds(numericValue(name, device), wanted));
            },
        },
        .range => |range| {
            if (!kind.isRange()) return .unknown;
            const actual = numericValue(name, device);
            var result: Truth = .true;
            if (range.left) |left| {
                const wanted = resolveValue(kind, left.value, allocator, device) orelse return .unknown;
                result = result.andWith(Truth.of(left.op.holds(wanted, actual)));
            }
            if (range.right) |right| {
                const wanted = resolveValue(kind, right.value, allocator, device) orelse return .unknown;
                result = result.andWith(Truth.of(right.op.holds(actual, wanted)));
            }
            return result;
        },
    }
}

/// `value` as a number comparable with `numericValue` of a feature of `kind`;
/// null if it is not a value of that type.
fn resolveValue(kind: Kind, value: Value, allocator: Allocator, device: Device) ?f32 {
    switch (kind) {
        .length => switch (value) {
            // A unitless zero is the only unitless <length>.
            .integer => |i| return if (i == 0) 0 else null,
            .number => |n| return if (n == 0) 0 else null,
            .dimension => |d| {
                const unit = d.unit orelse return null;
                return switch (unit) {
                    // §1.3: relative units are based on the initial value —
                    // the initial font size, 16px.
                    .em, .rem => d.number * 16,
                    else => zss.values.calc.absoluteLengthPx(unit, d.number, device.width_px, device.height_px),
                };
            },
            .math => |text| return mathLength(allocator, text, device),
            else => return null,
        },
        .ratio => switch (value) {
            .integer => |i| return if (i >= 0) @floatFromInt(i) else null,
            .number => |n| return if (n >= 0) n else null,
            .ratio => |r| return if (r[0] >= 0 and r[1] >= 0) r[0] / r[1] else null,
            else => return null,
        },
        .resolution => switch (value) {
            .dimension => |d| {
                const per_dppx: f32 = if (std.mem.eql(u8, d.unit_text, "dppx") or std.mem.eql(u8, d.unit_text, "x"))
                    1
                else if (std.mem.eql(u8, d.unit_text, "dpi"))
                    96
                else if (std.mem.eql(u8, d.unit_text, "dpcm"))
                    96.0 / 2.54
                else
                    return null;
                return d.number / per_dppx;
            },
            else => return null,
        },
        .number => switch (value) {
            .integer => |i| return @floatFromInt(i),
            .number => |n| return n,
            else => return null,
        },
        .integer => switch (value) {
            .integer => |i| return @floatFromInt(i),
            else => return null,
        },
        .boolean => switch (value) {
            .integer => |i| return if (i == 0 or i == 1) @floatFromInt(i) else null,
            else => return null,
        },
        .discrete => return null,
    }
}

/// The px value of the math function `text` (CSS Values 4 §10) as a <length>.
fn mathLength(allocator: Allocator, text: []const u8, device: Device) ?f32 {
    const calc = zss.values.calc;
    const source = SourceCode.init(text) catch return null;
    var parser = zss.syntax.Parser.init(source, allocator);
    defer parser.deinit();
    var ast, const root = parser.parseListOfComponentValues(allocator) catch return null;
    defer ast.deinit(allocator);
    var children = root.children(ast);
    const function = children.nextSkipSpaces(ast) orelse return null;
    var table: calc.Table = .{};
    defer table.deinit(allocator);
    const value = (calc.parseLength(ast, source, &table, allocator, function, .{
        .percentages = false,
        .viewport_width_px = device.width_px,
        .viewport_height_px = device.height_px,
    }) catch return null) orelse return null;
    return switch (value) {
        .linear => |linear| linear.eval(16, null),
        .node => |id| table.eval(id, 16, null),
    };
}

// --- Serialization (CSSOM §4.2) ---

fn writeQuery(writer: *std.Io.Writer, query: Query) std.Io.Writer.Error!void {
    if (query.invalid) return writer.writeAll("not all");
    switch (query.qualifier) {
        .none => {},
        .not => try writer.writeAll("not "),
        .only => try writer.writeAll("only "),
    }
    const media_type = query.media_type orelse return writeCondition(writer, query.condition.?);
    const cond = query.condition orelse return writer.writeAll(media_type);
    // "If the media query … type is not `all` or … is negated" (and, as
    // browsers do, for `only`), the type is written before the condition.
    if (query.qualifier != .none or !std.mem.eql(u8, media_type, "all")) {
        try writer.writeAll(media_type);
        try writer.writeAll(" and ");
    }
    try writeCondition(writer, cond);
}

fn writeCondition(writer: *std.Io.Writer, cond: Condition) std.Io.Writer.Error!void {
    switch (cond) {
        .not => |operand| {
            try writer.writeAll("not ");
            try writeCondition(writer, operand.*);
        },
        inline .all, .any => |operands, tag| {
            for (operands, 0..) |operand, i| {
                if (i > 0) try writer.writeAll(if (tag == .all) " and " else " or ");
                try writeCondition(writer, operand);
            }
        },
        .in_parens => |inner| {
            try writer.writeByte('(');
            try writeCondition(writer, inner.*);
            try writer.writeByte(')');
        },
        .feature => |f| {
            try writer.writeByte('(');
            switch (f.form) {
                .boolean => try writer.writeAll(f.name),
                .plain => |value| {
                    try writer.writeAll(f.name);
                    try writer.writeAll(": ");
                    try writeValue(writer, value);
                },
                .range => |range| {
                    if (range.left) |left| {
                        try writeValue(writer, left.value);
                        try writer.print(" {s} ", .{left.op.text()});
                    }
                    try writer.writeAll(f.name);
                    if (range.right) |right| {
                        try writer.print(" {s} ", .{right.op.text()});
                        try writeValue(writer, right.value);
                    }
                },
            }
            try writer.writeByte(')');
        },
        .general_enclosed => |text| try writer.writeAll(text),
    }
}

fn writeValue(writer: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
    switch (value) {
        .integer => |i| try writer.print("{d}", .{i}),
        .number => |n| try writer.print("{d}", .{n}),
        .dimension => |d| try writer.print("{d}{s}", .{ d.number, d.unit_text }),
        .ident => |ident| try writer.writeAll(ident),
        .ratio => |r| try writer.print("{d} / {d}", .{ r[0], r[1] }),
        .math => |text| try writer.writeAll(text),
    }
}

// --- Tests ---

fn expectMatch(expected: bool, text: []const u8, device: Device) !void {
    const actual = try evaluate(std.testing.allocator, text, device);
    if (actual != expected) {
        std.debug.print("media query \"{s}\": expected {}, got {}\n", .{ text, expected, actual });
        return error.TestUnexpectedResult;
    }
}

fn expectSerialized(expected: []const u8, text: []const u8) !void {
    var list = try QueryList.parse(std.testing.allocator, text);
    defer list.deinit();
    const actual = try list.serialize(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "media types and keywords" {
    const vp = Device{ .width_px = 1280, .height_px = 720 };
    try expectMatch(true, "screen", vp);
    try expectMatch(true, "all", vp);
    try expectMatch(true, "only screen", vp);
    try expectMatch(false, "print", vp);
    try expectMatch(false, "not screen", vp);
    try expectMatch(true, "not print", vp);
    try expectMatch(true, "screen, print", vp);
    try expectMatch(false, "nonsense", vp);
    try expectMatch(true, "not nonsense", vp);
    try expectMatch(true, "", vp);
    try expectMatch(true, "(bogus)", .{ .width_px = 0, .height_px = 0, .configured = false });
    try expectMatch(true, "print", .{ .width_px = 800, .height_px = 600, .media_type = .print });
    try expectMatch(false, "screen", .{ .width_px = 800, .height_px = 600, .media_type = .print });
}

test "viewport features" {
    const vp = Device{ .width_px = 1280, .height_px = 720 };
    try expectMatch(true, "(min-width: 1000px)", vp);
    try expectMatch(false, "(min-width: 1300px)", vp);
    try expectMatch(true, "screen and (max-width: 1280px)", vp);
    try expectMatch(true, "only screen and (min-width: 300px) and (max-height: 800px)", vp);
    try expectMatch(true, "(orientation: landscape)", vp);
    try expectMatch(false, "(orientation: portrait)", vp);
    try expectMatch(true, "(min-width: 50em)", vp);
    try expectMatch(false, "(min-resolution: 2dppx)", vp);
    try expectMatch(true, "(min-resolution: 96dpi)", vp);
    try expectMatch(true, "(hover: hover) and (pointer: fine)", vp);
    try expectMatch(false, "(prefers-color-scheme: dark)", vp);
    try expectMatch(true, "(prefers-reduced-motion: no-preference)", vp);
    try expectMatch(false, "(prefers-reduced-motion: reduce)", vp);
    try expectMatch(false, "(prefers-reduced-motion)", vp);
    try expectMatch(true, "(min-width: calc(1000px + 10em))", vp);
    try expectMatch(false, "(min-width: calc(100vw + 1px))", vp);
    try expectMatch(true, "(aspect-ratio: 16/9)", vp);
    try expectMatch(true, "(min-aspect-ratio: 1)", vp);
    const tiny = Device{ .width_px = 0, .height_px = 0 };
    try expectMatch(true, "(max-width: 1em) and (max-height: 1em)", tiny);
    try expectMatch(false, "(min-width: 1em)", tiny);
    const dark = Device{ .width_px = 800, .height_px = 600, .color_scheme = .dark };
    try expectMatch(true, "(prefers-color-scheme: dark)", dark);
}

test "level 4 syntax: range, or, not" {
    const vp = Device{ .width_px = 1280, .height_px = 720 };
    try expectMatch(true, "(width >= 600px)", vp);
    try expectMatch(false, "(width < 600px)", vp);
    try expectMatch(true, "(width = 1280px)", vp);
    try expectMatch(true, "(600px <= width <= 1280px)", vp);
    try expectMatch(false, "(600px <= width < 1280px)", vp);
    try expectMatch(true, "(1300px > width)", vp);
    try expectMatch(false, "(600px <= width >= 100px)", vp);
    try expectMatch(false, "(width < = 600px)", vp);
    try expectMatch(true, "(width < 600px) or (height > 700px)", vp);
    try expectMatch(false, "(width < 600px) or (height > 800px)", vp);
    try expectMatch(true, "not (width < 600px)", vp);
    try expectMatch(true, "((width > 600px) and (height > 700px)) or (color: 1)", vp);
    try expectMatch(false, "(width > 600px) and (height > 700px) or (color)", vp);
    try expectMatch(false, "screen and ((color) or (bogus)) or (color)", vp);
    try expectMatch(true, "screen and ((color) or (bogus))", vp);
    try expectMatch(false, "(min-width >= 600px)", vp);
    try expectMatch(false, "(orientation >= landscape)", vp);
}

test "three-valued evaluation (Acid3 test 46)" {
    const vp = Device{ .width_px = 0, .height_px = 0 };
    try expectMatch(true, "all and (min-color: 0)", vp);
    try expectMatch(false, "not all and (min-color: 0)", vp);
    try expectMatch(true, "only all and (min-color: 0)", vp);
    try expectMatch(false, "(bogus)", vp);
    try expectMatch(false, "all and (bogus)", vp);
    try expectMatch(false, "not all and (bogus)", vp);
    try expectMatch(false, "only all and (bogus)", vp);
    try expectMatch(true, "(bogus), all", vp);
    try expectMatch(true, "all and (bogus), all", vp);
    try expectMatch(true, "not all and (bogus), all", vp);
    try expectMatch(true, "all, (bogus)", vp);
    try expectMatch(true, "all, not all and (bogus)", vp);
    try expectMatch(false, "all and color", vp);
    try expectMatch(false, "all and min-color: 0", vp);
    try expectMatch(true, "all, all and color", vp);
    try expectMatch(true, "all and min-color: 0, all", vp);
    try expectMatch(false, "(max-color: 0) and (max-monochrome: 0)", vp);
    try expectMatch(true, "(min-color: 1), (min-monochrome: 1)", vp);
    try expectMatch(true, "all and (min-color: 0) and (min-monochrome: 0)", vp);
    try expectMatch(true, "not all and (min-color: 1), not all and (min-monochrome: 1)", vp);
    try expectMatch(false, "all and (min-height: 1em) and (min-width: 1em)", vp);
    try expectMatch(true, "all and (max-height: 1em) and (max-width: 1em)", vp);
    try expectMatch(false, "not (bogus)", vp);
    try expectMatch(false, "(min-width)", vp);
}

test "serialization" {
    try expectSerialized("", "  ");
    try expectSerialized("screen", "SCREEN");
    try expectSerialized("not all", "screen and");
    try expectSerialized("not all, not all", ",");
    try expectSerialized("screen and (min-width: 100px)", "screen   and (MIN-WIDTH:100PX)");
    try expectSerialized("only screen and (color)", "only screen and (color)");
    try expectSerialized("(color)", "all and (color)");
    try expectSerialized("not all and (color)", "not all and (color)");
    try expectSerialized("(min-aspect-ratio: 1.5 / 1)", "(min-aspect-ratio: 1.5)");
    try expectSerialized("not print", "NOT print");
    try expectSerialized("(width >= 600px)", "(width>=600px)");
    try expectSerialized("(400px <= width <= 700px)", "(400px<=width<=700px)");
    try expectSerialized("(aspect-ratio: 16 / 9)", "(aspect-ratio:16/9)");
    try expectSerialized("(color) or (hover)", "(color)   or (hover)");
    try expectSerialized("not (color)", "not (color)");
    try expectSerialized("((color) and (hover))", "( (color) and (hover) )");
    try expectSerialized("screen, print", "screen,print");
}
