//! CSS Fonts 4 §4: the `@font-face` descriptors — parsing, the values font
//! matching needs, and their CSSOM serialization — plus the `src` list (§4.3)
//! and the `font` shorthand as CSS Font Loading 3 §3.2 "find the matching font
//! faces" reads it. One implementation for the layout host (which loads the
//! rules' fonts) and for script (`FontFace`, `FontFaceSet`).
//!
//! Not built: math functions in descriptor values (`calc()` is rejected), the
//! `font-variant` descriptor beyond `normal`, and `local()` sources (parsed,
//! never loadable: the host matches local fonts by family name only).

const std = @import("std");
const zss = @import("zss.zig");
const Allocator = std.mem.Allocator;
const SourceCode = zss.syntax.SourceCode;
const Token = zss.syntax.Token;

pub const Descriptor = enum {
    style,
    weight,
    stretch,
    unicode_range,
    feature_settings,
    variation_settings,
    display,
    ascent_override,
    descent_override,
    line_gap_override,
    size_adjust,
    variant,

    /// By the descriptor's CSS name (`font-stretch` and its Fonts 4 name `font-width`).
    pub fn fromName(name: []const u8) ?Descriptor {
        const kvs = [_]struct { []const u8, Descriptor }{
            .{ "font-style", .style },                       .{ "font-weight", .weight },
            .{ "font-stretch", .stretch },                   .{ "font-width", .stretch },
            .{ "unicode-range", .unicode_range },            .{ "font-feature-settings", .feature_settings },
            .{ "font-variation-settings", .variation_settings }, .{ "font-display", .display },
            .{ "ascent-override", .ascent_override },        .{ "descent-override", .descent_override },
            .{ "line-gap-override", .line_gap_override },    .{ "size-adjust", .size_adjust },
            .{ "font-variant", .variant },
        };
        for (kvs) |kv| if (std.ascii.eqlIgnoreCase(name, kv[0])) return kv[1];
        return null;
    }

    /// The serialization of the descriptor's initial value.
    pub fn initial(d: Descriptor) []const u8 {
        return switch (d) {
            .unicode_range => "U+0-10FFFF",
            .display => "auto",
            .size_adjust => "100%",
            else => "normal",
        };
    }
};

/// A `font-weight` / `font-stretch` range, bounds in order.
pub const Range = struct { min: f32, max: f32 };

pub const Style = union(enum) {
    auto,
    normal,
    italic,
    /// Degrees, bounds in order. A bare `oblique` is 14deg (§2.4).
    oblique: Range,
};

pub const CodepointRange = struct { first: u21, last: u21 };

const Tok = struct { token: Token, location: SourceCode.Location };

/// The tokens of a value, without whitespace and comments.
const Tokens = struct {
    source: SourceCode,
    items: []Tok,
    pos: usize = 0,

    fn init(allocator: Allocator, text: []const u8) Allocator.Error!?Tokens {
        const source = SourceCode.init(text) catch return null;
        var tokenizer = zss.syntax.Tokenizer.init(source);
        var list: std.ArrayListUnmanaged(Tok) = .empty;
        errdefer list.deinit(allocator);
        while (true) {
            const token, const location = (tokenizer.next() catch {
                list.deinit(allocator);
                return null;
            }) orelse break;
            switch (token) {
                .token_whitespace, .token_comments => {},
                else => try list.append(allocator, .{ .token = token, .location = location }),
            }
        }
        return .{ .source = source, .items = try list.toOwnedSlice(allocator) };
    }

    fn deinit(t: *Tokens, allocator: Allocator) void {
        allocator.free(t.items);
    }

    fn peek(t: *const Tokens) ?Tok {
        return if (t.pos < t.items.len) t.items[t.pos] else null;
    }

    fn next(t: *Tokens) ?Tok {
        const tok = t.peek() orelse return null;
        t.pos += 1;
        return tok;
    }

    fn done(t: *const Tokens) bool {
        return t.pos >= t.items.len;
    }

    fn isIdent(t: *const Tokens, tok: Tok, comptime name: []const u8) bool {
        return tok.token == .token_ident and t.source.identifierEqlIgnoreCase(tok.location, name);
    }

    /// The next token if it is the identifier `name`.
    fn acceptIdent(t: *Tokens, comptime name: []const u8) bool {
        const tok = t.peek() orelse return false;
        if (!t.isIdent(tok, name)) return false;
        t.pos += 1;
        return true;
    }

    fn acceptKeyword(t: *Tokens, comptime Enum: type) ?Enum {
        const tok = t.peek() orelse return null;
        if (tok.token != .token_ident) return null;
        const value = t.source.mapIdentifierEnum(tok.location, Enum) orelse return null;
        t.pos += 1;
        return value;
    }

    /// A <number> (an integer or a number token).
    fn acceptNumber(t: *Tokens) ?f32 {
        const tok = t.peek() orelse return null;
        const value: f32 = switch (tok.token) {
            .token_integer => |i| @floatFromInt(i orelse return null),
            .token_number => |n| n orelse return null,
            else => return null,
        };
        t.pos += 1;
        return value;
    }

    fn acceptInteger(t: *Tokens) ?i32 {
        const tok = t.peek() orelse return null;
        const value = switch (tok.token) {
            .token_integer => |i| i orelse return null,
            else => return null,
        };
        t.pos += 1;
        return value;
    }

    /// A <percentage>, in percent (the tokenizer holds the fraction; the
    /// product is rounded back to the written precision).
    fn acceptPercentage(t: *Tokens) ?f32 {
        const tok = t.peek() orelse return null;
        const value = switch (tok.token) {
            .token_percentage => |p| p orelse return null,
            else => return null,
        };
        t.pos += 1;
        return @round(value * 100 * 1e4) / 1e4;
    }

    /// An <angle> (CSS Values 4 §7.1), in degrees.
    fn acceptAngle(t: *Tokens) ?f32 {
        const tok = t.peek() orelse return null;
        const dimension = switch (tok.token) {
            .token_dimension => |d| d,
            else => return null,
        };
        const number = dimension.number orelse return null;
        const factor = t.source.mapIdentifierValue(dimension.unit_location, f32, &.{
            .{ "deg", 1.0 },
            .{ "grad", 0.9 },
            .{ "rad", 180.0 / std.math.pi },
            .{ "turn", 360.0 },
        }) orelse return null;
        t.pos += 1;
        return number * factor;
    }

    /// A <string>, allocator-owned.
    fn acceptString(t: *Tokens, allocator: Allocator) Allocator.Error!?[]u8 {
        const tok = t.peek() orelse return null;
        if (tok.token != .token_string) return null;
        t.pos += 1;
        return try t.source.copyString(tok.location, .{ .allocator = allocator });
    }

    fn accept(t: *Tokens, comptime tag: std.meta.Tag(Token)) bool {
        const tok = t.peek() orelse return false;
        if (tok.token != tag) return false;
        t.pos += 1;
        return true;
    }

    fn acceptFunction(t: *Tokens, comptime name: []const u8) bool {
        const tok = t.peek() orelse return false;
        if (tok.token != .token_function or !t.source.identifierEqlIgnoreCase(tok.location, name)) return false;
        t.pos += 1;
        return true;
    }
};

// ── font-weight ──────────────────────────────────────────────────────────────

const WeightValue = union(enum) { normal, bold, number: f32 };

fn weightValue(t: *Tokens) ?WeightValue {
    if (t.acceptIdent("normal")) return .normal;
    if (t.acceptIdent("bold")) return .bold;
    const save = t.pos;
    const n = t.acceptNumber() orelse return null;
    if (n < 1 or n > 1000) {
        t.pos = save;
        return null;
    }
    return .{ .number = n };
}

fn weightNumber(v: WeightValue) f32 {
    return switch (v) {
        .normal => 400,
        .bold => 700,
        .number => |n| n,
    };
}

const ParsedWeight = struct { auto: bool = false, values: [2]WeightValue = undefined, count: u8 = 0 };

/// `font-weight` descriptor (§4.4): auto | <font-weight-absolute>{1,2}.
fn parseWeightTokens(t: *Tokens) ?ParsedWeight {
    if (t.acceptIdent("auto")) return if (t.done()) .{ .auto = true } else null;
    var result: ParsedWeight = .{};
    while (result.count < 2) {
        result.values[result.count] = weightValue(t) orelse break;
        result.count += 1;
    }
    if (result.count == 0 or !t.done()) return null;
    return result;
}

/// The weight range a `font-weight` descriptor covers (`auto` is the initial
/// `normal` here: the host does not read the font's own weight), null when
/// the text is invalid.
pub fn parseWeight(allocator: Allocator, text: []const u8) Allocator.Error!?Range {
    var t = (try Tokens.init(allocator, text)) orelse return null;
    defer t.deinit(allocator);
    const parsed = parseWeightTokens(&t) orelse return null;
    return weightRange(parsed);
}

fn weightRange(parsed: ParsedWeight) Range {
    if (parsed.auto) return .{ .min = 400, .max = 400 };
    const a = weightNumber(parsed.values[0]);
    const b = if (parsed.count == 2) weightNumber(parsed.values[1]) else a;
    return .{ .min = @min(a, b), .max = @max(a, b) };
}

fn writeWeightValue(w: *std.Io.Writer, v: WeightValue) !void {
    switch (v) {
        .normal => try w.writeAll("normal"),
        .bold => try w.writeAll("bold"),
        .number => |n| try w.print("{d}", .{n}),
    }
}

// ── font-style ───────────────────────────────────────────────────────────────

const ParsedStyle = struct { style: Style, angles: [2]f32 = undefined, count: u8 = 0 };

/// `font-style` descriptor (§4.4): auto | normal | italic | oblique [ <angle [-90deg,90deg]>{1,2} ]?
fn parseStyleTokens(t: *Tokens) ?ParsedStyle {
    if (t.acceptIdent("auto")) return if (t.done()) .{ .style = .auto } else null;
    if (t.acceptIdent("normal")) return if (t.done()) .{ .style = .normal } else null;
    if (t.acceptIdent("italic")) return if (t.done()) .{ .style = .italic } else null;
    if (!t.acceptIdent("oblique")) return null;
    var result: ParsedStyle = .{ .style = .{ .oblique = .{ .min = 14, .max = 14 } } };
    while (result.count < 2) {
        const angle = t.acceptAngle() orelse break;
        if (angle < -90 or angle > 90) return null;
        result.angles[result.count] = angle;
        result.count += 1;
    }
    if (!t.done()) return null;
    if (result.count > 0) {
        const a = result.angles[0];
        const b = if (result.count == 2) result.angles[1] else a;
        // `oblique 0deg` is `normal` (the same faces match).
        if (a == 0 and b == 0) return .{ .style = .normal };
        result.style = .{ .oblique = .{ .min = @min(a, b), .max = @max(a, b) } };
        if (a == b) result.count = 1;
    }
    return result;
}

pub fn parseStyle(allocator: Allocator, text: []const u8) Allocator.Error!?Style {
    var t = (try Tokens.init(allocator, text)) orelse return null;
    defer t.deinit(allocator);
    const parsed = parseStyleTokens(&t) orelse return null;
    return parsed.style;
}

// ── font-stretch ─────────────────────────────────────────────────────────────

const StretchKeyword = enum {
    normal,
    @"ultra-condensed",
    @"extra-condensed",
    condensed,
    @"semi-condensed",
    @"semi-expanded",
    expanded,
    @"extra-expanded",
    @"ultra-expanded",

    fn percent(k: StretchKeyword) f32 {
        return switch (k) {
            .normal => 100,
            .@"ultra-condensed" => 50,
            .@"extra-condensed" => 62.5,
            .condensed => 75,
            .@"semi-condensed" => 87.5,
            .@"semi-expanded" => 112.5,
            .expanded => 125,
            .@"extra-expanded" => 150,
            .@"ultra-expanded" => 200,
        };
    }
};

const StretchValue = union(enum) { keyword: StretchKeyword, percentage: f32 };

fn stretchValue(t: *Tokens) ?StretchValue {
    if (t.acceptKeyword(StretchKeyword)) |k| return .{ .keyword = k };
    const save = t.pos;
    const p = t.acceptPercentage() orelse return null;
    if (p < 0) {
        t.pos = save;
        return null;
    }
    return .{ .percentage = p };
}

fn stretchPercent(v: StretchValue) f32 {
    return switch (v) {
        .keyword => |k| k.percent(),
        .percentage => |p| p,
    };
}

const ParsedStretch = struct { auto: bool = false, values: [2]StretchValue = undefined, count: u8 = 0 };

/// `font-stretch` / `font-width` descriptor (§4.4): auto | <'font-width'>{1,2}.
fn parseStretchTokens(t: *Tokens) ?ParsedStretch {
    if (t.acceptIdent("auto")) return if (t.done()) .{ .auto = true } else null;
    var result: ParsedStretch = .{};
    while (result.count < 2) {
        result.values[result.count] = stretchValue(t) orelse break;
        result.count += 1;
    }
    if (result.count == 0 or !t.done()) return null;
    return result;
}

fn stretchRange(parsed: ParsedStretch) Range {
    if (parsed.auto) return .{ .min = 100, .max = 100 };
    const a = stretchPercent(parsed.values[0]);
    const b = if (parsed.count == 2) stretchPercent(parsed.values[1]) else a;
    return .{ .min = @min(a, b), .max = @max(a, b) };
}

fn writeStretchValue(w: *std.Io.Writer, v: StretchValue) !void {
    switch (v) {
        .keyword => |k| try w.writeAll(@tagName(k)),
        .percentage => |p| try w.print("{d}%", .{p}),
    }
}

// ── unicode-range ────────────────────────────────────────────────────────────

/// `unicode-range` descriptor (§4.5): <urange>#. A <urange> is read from the
/// text of the value (CSS Syntax 3 §7.1): `U+` and 1-6 hex digits, trailing
/// `?` wildcards, or a `first-last` range. Null when the text is invalid;
/// allocator-owned otherwise.
pub fn parseUnicodeRange(allocator: Allocator, text: []const u8) Allocator.Error!?[]CodepointRange {
    var ranges: std.ArrayListUnmanaged(CodepointRange) = .empty;
    errdefer ranges.deinit(allocator);
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t\r\n\x0c");
        const range = parseUrange(item) orelse {
            ranges.deinit(allocator);
            return null;
        };
        try ranges.append(allocator, range);
    }
    return try ranges.toOwnedSlice(allocator);
}

fn parseUrange(item: []const u8) ?CodepointRange {
    if (item.len < 3 or (item[0] != 'u' and item[0] != 'U') or item[1] != '+') return null;
    const body = item[2..];
    var i: usize = 0;
    var first: u32 = 0;
    while (i < body.len and std.ascii.isHex(body[i])) : (i += 1) {
        first = first * 16 + (std.fmt.charToDigit(body[i], 16) catch unreachable);
        if (i >= 6) return null;
    }
    const digits = i;
    var last: u32 = first;
    var wildcards: usize = 0;
    while (i < body.len and body[i] == '?') : (i += 1) {
        wildcards += 1;
        first *= 16;
        last = last * 16 + 15;
    }
    if (digits + wildcards == 0 or digits + wildcards > 6) return null;
    if (i < body.len) {
        if (wildcards > 0 or body[i] != '-') return null;
        i += 1;
        const start = i;
        last = 0;
        while (i < body.len and std.ascii.isHex(body[i])) : (i += 1) {
            last = last * 16 + (std.fmt.charToDigit(body[i], 16) catch unreachable);
            if (i - start >= 6) return null;
        }
        if (i == start or i != body.len) return null;
    }
    if (last > 0x10FFFF or first > last) return null;
    return .{ .first = @intCast(first), .last = @intCast(last) };
}

// ── font-feature-settings, font-variation-settings ───────────────────────────

/// A feature or axis tag: a <string> of exactly four characters in U+20-7E.
fn acceptTag(t: *Tokens, allocator: Allocator) Allocator.Error!?[]u8 {
    const save = t.pos;
    const tag = (try t.acceptString(allocator)) orelse return null;
    var ok = tag.len == 4;
    for (tag) |ch| ok = ok and ch >= 0x20 and ch <= 0x7e;
    if (!ok) {
        allocator.free(tag);
        t.pos = save;
        return null;
    }
    return tag;
}

fn writeCssString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |ch| {
        if (ch == '"' or ch == '\\') try w.writeByte('\\');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

/// `font-feature-settings` (§6.12): normal | [ <string> [ <integer [0,∞]> | on | off ]? ]#
fn serializeFeatureSettings(t: *Tokens, allocator: Allocator, w: *std.Io.Writer) !bool {
    if (t.acceptIdent("normal")) {
        try w.writeAll("normal");
        return t.done();
    }
    var first = true;
    while (true) {
        const tag = (try acceptTag(t, allocator)) orelse return false;
        defer allocator.free(tag);
        var value: i32 = 1;
        if (t.acceptIdent("on")) {
            value = 1;
        } else if (t.acceptIdent("off")) {
            value = 0;
        } else if (t.acceptInteger()) |n| {
            if (n < 0) return false;
            value = n;
        }
        if (!first) try w.writeAll(", ");
        first = false;
        try writeCssString(w, tag);
        if (value != 1) try w.print(" {d}", .{value});
        if (t.done()) return true;
        if (!t.accept(.token_comma)) return false;
    }
}

/// `font-variation-settings` (§7.2): normal | [ <string> <number> ]#
fn serializeVariationSettings(t: *Tokens, allocator: Allocator, w: *std.Io.Writer) !bool {
    if (t.acceptIdent("normal")) {
        try w.writeAll("normal");
        return t.done();
    }
    var first = true;
    while (true) {
        const tag = (try acceptTag(t, allocator)) orelse return false;
        defer allocator.free(tag);
        const value = t.acceptNumber() orelse return false;
        if (!first) try w.writeAll(", ");
        first = false;
        try writeCssString(w, tag);
        try w.print(" {d}", .{value});
        if (t.done()) return true;
        if (!t.accept(.token_comma)) return false;
    }
}

// ── serialization for script ─────────────────────────────────────────────────

/// The descriptor value in `text`, as JSON for the script side: `text` is its
/// CSSOM serialization, and font matching's numbers ride along — `min`/`max`
/// (weight, stretch percent, oblique degrees), `kind` (style) and `ranges`
/// (unicode-range). Null when the value is invalid. Allocator-owned.
pub fn describe(allocator: Allocator, descriptor: Descriptor, text: []const u8) Allocator.Error!?[]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const ok = describeInto(allocator, descriptor, text, &out.writer) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.WriteFailed => return error.OutOfMemory,
    };
    if (!ok) return null;
    return try out.toOwnedSlice();
}

fn jsonString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

fn describeInto(allocator: Allocator, descriptor: Descriptor, text: []const u8, w: *std.Io.Writer) !bool {
    var value: std.Io.Writer.Allocating = .init(allocator);
    defer value.deinit();
    const v = &value.writer;

    if (descriptor == .unicode_range) {
        const ranges = (try parseUnicodeRange(allocator, text)) orelse return false;
        defer allocator.free(ranges);
        for (ranges, 0..) |r, i| {
            if (i > 0) try v.writeAll(", ");
            if (r.first == r.last) try v.print("U+{X}", .{r.first}) else try v.print("U+{X}-{X}", .{ r.first, r.last });
        }
        try w.writeAll("{\"text\":");
        try jsonString(w, value.written());
        try w.writeAll(",\"ranges\":[");
        for (ranges, 0..) |r, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("[{d},{d}]", .{ r.first, r.last });
        }
        try w.writeAll("]}");
        return true;
    }

    var t = (try Tokens.init(allocator, text)) orelse return false;
    defer t.deinit(allocator);
    var extra: std.Io.Writer.Allocating = .init(allocator);
    defer extra.deinit();
    const x = &extra.writer;

    switch (descriptor) {
        .unicode_range => unreachable,
        .weight => {
            const parsed = parseWeightTokens(&t) orelse return false;
            if (parsed.auto) {
                try v.writeAll("auto");
            } else {
                try writeWeightValue(v, parsed.values[0]);
                if (parsed.count == 2 and weightNumber(parsed.values[0]) != weightNumber(parsed.values[1])) {
                    try v.writeByte(' ');
                    try writeWeightValue(v, parsed.values[1]);
                }
            }
            const range = weightRange(parsed);
            try x.print(",\"min\":{d},\"max\":{d}", .{ range.min, range.max });
        },
        .stretch => {
            const parsed = parseStretchTokens(&t) orelse return false;
            if (parsed.auto) {
                try v.writeAll("auto");
            } else {
                try writeStretchValue(v, parsed.values[0]);
                if (parsed.count == 2 and stretchPercent(parsed.values[0]) != stretchPercent(parsed.values[1])) {
                    try v.writeByte(' ');
                    try writeStretchValue(v, parsed.values[1]);
                }
            }
            const range = stretchRange(parsed);
            try x.print(",\"min\":{d},\"max\":{d}", .{ range.min, range.max });
        },
        .style => {
            const parsed = parseStyleTokens(&t) orelse return false;
            switch (parsed.style) {
                .auto, .normal, .italic => {
                    try v.writeAll(@tagName(parsed.style));
                    try x.print(",\"kind\":\"{s}\"", .{@tagName(parsed.style)});
                },
                .oblique => |range| {
                    try v.writeAll("oblique");
                    for (parsed.angles[0..parsed.count]) |angle| try v.print(" {d}deg", .{angle});
                    try x.print(",\"kind\":\"oblique\",\"min\":{d},\"max\":{d}", .{ range.min, range.max });
                },
            }
        },
        .feature_settings => if (!try serializeFeatureSettings(&t, allocator, v)) return false,
        .variation_settings => if (!try serializeVariationSettings(&t, allocator, v)) return false,
        .display => {
            const keyword = t.acceptKeyword(enum { auto, block, swap, fallback, optional }) orelse return false;
            if (!t.done()) return false;
            try v.writeAll(@tagName(keyword));
        },
        .ascent_override, .descent_override, .line_gap_override => {
            if (t.acceptIdent("normal")) {
                try v.writeAll("normal");
            } else {
                const p = t.acceptPercentage() orelse return false;
                if (p < 0) return false;
                try v.print("{d}%", .{p});
            }
            if (!t.done()) return false;
        },
        .size_adjust => {
            const p = t.acceptPercentage() orelse return false;
            if (p < 0 or !t.done()) return false;
            try v.print("{d}%", .{p});
        },
        .variant => {
            if (!t.acceptIdent("normal") or !t.done()) return false;
            try v.writeAll("normal");
        },
    }
    try w.writeAll("{\"text\":");
    try jsonString(w, value.written());
    try w.writeAll(extra.written());
    try w.writeByte('}');
    return true;
}

// ── font-family ──────────────────────────────────────────────────────────────

/// The `font-family` descriptor (§4.2): one <family-name> — a <string>, or
/// identifiers joined by single spaces. Null when invalid; allocator-owned.
pub fn parseFamilyName(allocator: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    var t = (try Tokens.init(allocator, text)) orelse return null;
    defer t.deinit(allocator);
    const name = (try familyName(&t, allocator)) orelse return null;
    if (!t.done()) {
        allocator.free(name.text);
        return null;
    }
    return name.text;
}

const FamilyName = struct { text: []u8, quoted: bool, idents: usize };

fn familyName(t: *Tokens, allocator: Allocator) Allocator.Error!?FamilyName {
    if (try t.acceptString(allocator)) |s| return .{ .text = s, .quoted = true, .idents = 0 };
    var name: std.ArrayListUnmanaged(u8) = .empty;
    errdefer name.deinit(allocator);
    var idents: usize = 0;
    while (t.peek()) |tok| {
        if (tok.token != .token_ident) break;
        t.pos += 1;
        const ident = try t.source.copyIdentifier(tok.location, .{ .allocator = allocator });
        defer allocator.free(ident);
        if (idents > 0) try name.append(allocator, ' ');
        try name.appendSlice(allocator, ident);
        idents += 1;
    }
    if (idents == 0) return null;
    return .{ .text = try name.toOwnedSlice(allocator), .quoted = false, .idents = idents };
}

// ── src ──────────────────────────────────────────────────────────────────────

pub const Source = union(enum) {
    /// A `url()` source this engine can load, as written (unresolved).
    url: []u8,
    /// A `local()` source: the face name.
    local: []u8,

    pub fn deinit(s: Source, allocator: Allocator) void {
        switch (s) {
            .url, .local => |text| allocator.free(text),
        }
    }
};

pub fn freeSources(allocator: Allocator, sources: []Source) void {
    for (sources) |s| s.deinit(allocator);
    allocator.free(sources);
}

/// Formats FreeType opens from memory: sfnt (TrueType / OpenType), WOFF and
/// WOFF2. `woff2-variations` & co. are the same containers (the pre-Fonts 4
/// way to ask for variations). Collections, EOT and SVG fonts are not loaded.
fn formatSupported(format: []const u8) bool {
    const base_end = std.mem.indexOfScalar(u8, format, '-') orelse format.len;
    if (base_end != format.len and !std.ascii.eqlIgnoreCase(format[base_end..], "-variations")) return false;
    inline for (.{ "woff2", "woff", "truetype", "opentype" }) |ok| {
        if (std.ascii.eqlIgnoreCase(format[0..base_end], ok)) return true;
    }
    return false;
}

/// Font technologies (§4.3.2 `tech()`) a loaded face gets here: OpenType
/// features (HarfBuzz shaping) and variable fonts as a container (FreeType
/// opens them; the default instance is used).
fn techSupported(tech: []const u8) bool {
    inline for (.{ "features-opentype", "variations" }) |ok| {
        if (std.ascii.eqlIgnoreCase(tech, ok)) return true;
    }
    return false;
}

/// The `src` descriptor (§4.3): a comma-separated list, parsed forgivingly —
/// an entry that does not parse, or whose `format()` / `tech()` this engine
/// does not support, is dropped; the descriptor is invalid (null) when no
/// entry is left. Without a `format()` hint a URL whose extension names a
/// format FreeType cannot open is dropped too. Allocator-owned
/// (`freeSources`).
pub fn parseSources(allocator: Allocator, text: []const u8) Allocator.Error!?[]Source {
    var t = (try Tokens.init(allocator, text)) orelse return null;
    defer t.deinit(allocator);
    var sources: std.ArrayListUnmanaged(Source) = .empty;
    errdefer {
        for (sources.items) |s| s.deinit(allocator);
        sources.deinit(allocator);
    }
    while (!t.done()) {
        if (try sourceEntry(&t, allocator)) |source| {
            if (t.done() or t.peek().?.token == .token_comma) {
                try sources.append(allocator, source);
            } else source.deinit(allocator);
        }
        // To the next entry.
        var depth: usize = 0;
        while (t.next()) |tok| switch (tok.token) {
            .token_function, .token_left_paren, .token_left_square, .token_left_curly => depth += 1,
            .token_right_paren, .token_right_square, .token_right_curly => depth -|= 1,
            .token_comma => if (depth == 0) break,
            else => {},
        };
    }
    if (sources.items.len == 0) {
        sources.deinit(allocator);
        return null;
    }
    return try sources.toOwnedSlice(allocator);
}

/// One entry: <url> [ format(<font-format>) ]? [ tech(<font-tech>#) ]? | local(<family-name>).
/// Null for an entry that is invalid or unsupported.
fn sourceEntry(t: *Tokens, allocator: Allocator) Allocator.Error!?Source {
    if (t.acceptFunction("local")) {
        const name = (try familyName(t, allocator)) orelse return null;
        if (!t.accept(.token_right_paren)) {
            allocator.free(name.text);
            return null;
        }
        return .{ .local = name.text };
    }
    const url: []u8 = blk: {
        const tok = t.peek() orelse return null;
        if (tok.token == .token_url) {
            t.pos += 1;
            break :blk try t.source.copyUrl(tok.location, .{ .allocator = allocator });
        }
        if (!t.acceptFunction("url")) return null;
        const s = (try t.acceptString(allocator)) orelse return null;
        if (!t.accept(.token_right_paren) and !t.done()) {
            allocator.free(s);
            return null;
        }
        break :blk s;
    };
    var keep = false;
    defer if (!keep) allocator.free(url);

    var has_format = false;
    if (t.acceptFunction("format")) {
        has_format = true;
        const format: []u8 = if (try t.acceptString(allocator)) |s| s else blk: {
            const tok = t.peek() orelse return null;
            if (tok.token != .token_ident) return null;
            t.pos += 1;
            break :blk try t.source.copyIdentifier(tok.location, .{ .allocator = allocator });
        };
        defer allocator.free(format);
        if (!t.accept(.token_right_paren)) return null;
        if (!formatSupported(format)) return null;
    }
    if (t.acceptFunction("tech")) {
        while (true) {
            const tok = t.next() orelse return null;
            if (tok.token != .token_ident) return null;
            const tech = try t.source.copyIdentifier(tok.location, .{ .allocator = allocator });
            defer allocator.free(tech);
            if (!techSupported(tech)) return null;
            if (t.accept(.token_right_paren)) break;
            if (!t.accept(.token_comma)) return null;
        }
    }
    if (!has_format) {
        const path_end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
        inline for (.{ ".eot", ".svg", ".svgz", ".ttc", ".otc" }) |bad| {
            if (std.ascii.endsWithIgnoreCase(url[0..path_end], bad)) return null;
        }
    }
    keep = true;
    return .{ .url = url };
}

/// The `src` descriptor as JSON for the script side: `{"urls":[…],"local":n}`
/// — the loadable URLs in order and the number of `local()` entries. Null
/// when the descriptor is invalid.
pub fn describeSources(allocator: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    const sources = (try parseSources(allocator, text)) orelse return null;
    defer freeSources(allocator, sources);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    writeSources(&out.writer, sources) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn writeSources(w: *std.Io.Writer, sources: []const Source) !void {
    try w.writeAll("{\"urls\":[");
    var urls: usize = 0;
    var locals: usize = 0;
    for (sources) |s| switch (s) {
        .url => |u| {
            if (urls > 0) try w.writeByte(',');
            try jsonString(w, u);
            urls += 1;
        },
        .local => locals += 1,
    };
    try w.print("],\"local\":{d}}}", .{locals});
}

// ── the font shorthand ───────────────────────────────────────────────────────

const generic_families = [_][]const u8{
    "serif",   "sans-serif", "monospace", "cursive",  "fantasy",       "system-ui",
    "emoji",   "math",       "fangsong",  "ui-serif", "ui-sans-serif", "ui-monospace",
    "ui-rounded",
};

const css_wide_keywords = [_][]const u8{ "inherit", "initial", "unset", "revert", "revert-layer", "default" };

fn isAnyOf(name: []const u8, list: []const []const u8) bool {
    for (list) |item| if (std.ascii.eqlIgnoreCase(name, item)) return true;
    return false;
}

/// A `font` shorthand value (CSS Fonts 4 §2.8) as CSS Font Loading 3 §3.2
/// reads it, as JSON: `{"families":[[name, generic]…],"weight":n,
/// "style":"normal"|"italic"|"oblique","stretch":percent}`. Relative keywords
/// resolve against the initial values (`bolder` 700, `lighter` 100); a system
/// font keyword names no family. Null when the value does not parse or is a
/// CSS-wide keyword.
pub fn describeFont(allocator: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    var t = (try Tokens.init(allocator, text)) orelse return null;
    defer t.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const ok = fontInto(&t, allocator, &out.writer) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.WriteFailed => return error.OutOfMemory,
    };
    if (!ok) return null;
    return try out.toOwnedSlice();
}

fn skipFunction(t: *Tokens) bool {
    var depth: usize = 1;
    while (t.next()) |tok| switch (tok.token) {
        .token_function, .token_left_paren, .token_left_square, .token_left_curly => depth += 1,
        .token_right_paren, .token_right_square, .token_right_curly => {
            depth -= 1;
            if (depth == 0) return true;
        },
        else => {},
    };
    return false;
}

const length_units = [_][]const u8{
    "px",  "em",  "rem",  "ex",   "rex",  "cap",  "rcap", "ch",   "rch",  "ic",   "ric", "lh",  "rlh", "vw",  "vh",
    "vi",  "vb",  "vmin", "vmax", "svw",  "svh",  "lvw",  "lvh",  "dvw",  "dvh",  "cm",  "mm",  "q",   "in",  "pt",
    "pc",
};

fn acceptLengthPercentage(t: *Tokens, allocator: Allocator, allow_number: bool) Allocator.Error!bool {
    const tok = t.peek() orelse return false;
    switch (tok.token) {
        .token_percentage => |p| if (p == null or p.? < 0) return false,
        .token_dimension => |d| {
            if (d.number == null or d.number.? < 0) return false;
            const unit = try t.source.copyIdentifier(d.unit_location, .{ .allocator = allocator });
            defer allocator.free(unit);
            if (!isAnyOf(unit, &length_units)) return false;
        },
        .token_integer => |i| if (i == null or (i.? != 0 and !allow_number) or i.? < 0) return false,
        .token_number => |n| if (!allow_number or n == null or n.? < 0) return false,
        .token_function => {
            const is_math = inline for (.{ "calc", "min", "max", "clamp" }) |name| {
                if (t.source.identifierEqlIgnoreCase(tok.location, name)) break true;
            } else false;
            if (!is_math) return false;
            t.pos += 1;
            return skipFunction(t);
        },
        else => return false,
    }
    t.pos += 1;
    return true;
}

fn fontInto(t: *Tokens, allocator: Allocator, w: *std.Io.Writer) !bool {
    var weight: ?f32 = null;
    var style: ?[]const u8 = null;
    var stretch: ?f32 = null;
    var variant = false;

    // A system font keyword alone.
    if (t.items.len == 1) {
        if (t.acceptKeyword(enum { caption, icon, menu, @"message-box", @"small-caption", @"status-bar" })) |_| {
            try w.writeAll("{\"families\":[],\"weight\":400,\"style\":\"normal\",\"stretch\":100}");
            return true;
        }
    }

    // [ <'font-style'> || <font-variant-css2> || <'font-weight'> || <font-width-css3> ]?
    var normals: usize = 0;
    while (true) {
        if (t.acceptIdent("normal")) {
            normals += 1;
            if (normals > 4) return false;
            continue;
        }
        if (style == null) {
            if (t.acceptIdent("italic")) {
                style = "italic";
                continue;
            }
            if (t.acceptIdent("oblique")) {
                style = "oblique";
                if (t.acceptAngle()) |angle| {
                    if (angle < -90 or angle > 90) return false;
                }
                continue;
            }
        }
        if (!variant and t.acceptIdent("small-caps")) {
            variant = true;
            continue;
        }
        if (weight == null) {
            if (t.acceptIdent("bold")) {
                weight = 700;
                continue;
            }
            if (t.acceptIdent("bolder")) {
                weight = 700;
                continue;
            }
            if (t.acceptIdent("lighter")) {
                weight = 100;
                continue;
            }
            const save = t.pos;
            if (t.acceptNumber()) |n| {
                if (n >= 1 and n <= 1000) {
                    weight = n;
                    continue;
                }
                t.pos = save;
            }
        }
        if (stretch == null) {
            if (t.acceptKeyword(StretchKeyword)) |k| {
                stretch = k.percent();
                continue;
            }
        }
        break;
    }

    // <'font-size'> [ / <'line-height'> ]?
    const size_keyword = t.acceptKeyword(enum { @"xx-small", @"x-small", small, medium, large, @"x-large", @"xx-large", @"xxx-large", larger, smaller, math });
    if (size_keyword == null and !try acceptLengthPercentage(t, allocator, false)) return false;
    if (t.peek()) |tok| {
        if (tok.token == .token_delim and tok.token.token_delim == '/') {
            t.pos += 1;
            if (!t.acceptIdent("normal") and !try acceptLengthPercentage(t, allocator, true)) return false;
        }
    }

    // <'font-family'>
    try w.writeAll("{\"families\":[");
    var count: usize = 0;
    while (true) {
        const name = (try familyName(t, allocator)) orelse return false;
        defer allocator.free(name.text);
        const single_ident = !name.quoted and name.idents == 1;
        if (single_ident and isAnyOf(name.text, &css_wide_keywords)) return false;
        const generic = single_ident and isAnyOf(name.text, &generic_families);
        if (count > 0) try w.writeByte(',');
        try w.writeByte('[');
        try jsonString(w, name.text);
        try w.writeAll(if (generic) ",true]" else ",false]");
        count += 1;
        if (t.done()) break;
        if (!t.accept(.token_comma)) return false;
    }
    try w.print("],\"weight\":{d},\"style\":\"{s}\",\"stretch\":{d}}}", .{ weight orelse 400, style orelse "normal", stretch orelse 100 });
    return true;
}

// ── tests ────────────────────────────────────────────────────────────────────

fn expectDescribe(descriptor: Descriptor, text: []const u8, expected: ?[]const u8) !void {
    const allocator = std.testing.allocator;
    const actual = try describe(allocator, descriptor, text);
    defer if (actual) |a| allocator.free(a);
    if (expected) |e| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(e, actual.?);
    } else try std.testing.expect(actual == null);
}

test "font-weight descriptor" {
    try expectDescribe(.weight, "normal", "{\"text\":\"normal\",\"min\":400,\"max\":400}");
    try expectDescribe(.weight, "BOLD", "{\"text\":\"bold\",\"min\":700,\"max\":700}");
    try expectDescribe(.weight, "900 100", "{\"text\":\"900 100\",\"min\":100,\"max\":900}");
    try expectDescribe(.weight, "500 500", "{\"text\":\"500\",\"min\":500,\"max\":500}");
    try expectDescribe(.weight, "350.5", "{\"text\":\"350.5\",\"min\":350.5,\"max\":350.5}");
    try expectDescribe(.weight, "normal bold", "{\"text\":\"normal bold\",\"min\":400,\"max\":700}");
    try expectDescribe(.weight, "auto", "{\"text\":\"auto\",\"min\":400,\"max\":400}");
    inline for (.{ "0", "1001", "0.999", "bolder", "lighter", "", "-1", "100 200 300", "bold a", "100 1001" }) |bad| {
        try expectDescribe(.weight, bad, null);
    }
}

test "font-style descriptor" {
    try expectDescribe(.style, "ITALIC", "{\"text\":\"italic\",\"kind\":\"italic\"}");
    try expectDescribe(.style, "oblique", "{\"text\":\"oblique\",\"kind\":\"oblique\",\"min\":14,\"max\":14}");
    try expectDescribe(.style, "oblique 20deg 10deg", "{\"text\":\"oblique 20deg 10deg\",\"kind\":\"oblique\",\"min\":10,\"max\":20}");
    try expectDescribe(.style, "oblique 10deg 10deg", "{\"text\":\"oblique 10deg\",\"kind\":\"oblique\",\"min\":10,\"max\":10}");
    try expectDescribe(.style, "oblique 0deg", "{\"text\":\"normal\",\"kind\":\"normal\"}");
    try expectDescribe(.style, "oblique 0rad", "{\"text\":\"normal\",\"kind\":\"normal\"}");
    inline for (.{ "oblique 100deg", "italic 10deg", "bogus", "", "oblique 20", "oblique 20px", "oblique 10deg 20deg 30deg" }) |bad| {
        try expectDescribe(.style, bad, null);
    }
}

test "font-stretch, unicode-range and settings descriptors" {
    try expectDescribe(.stretch, "condensed", "{\"text\":\"condensed\",\"min\":75,\"max\":75}");
    try expectDescribe(.stretch, "200% 50%", "{\"text\":\"200% 50%\",\"min\":50,\"max\":200}");
    try expectDescribe(.stretch, "75", null);
    try expectDescribe(.stretch, "-1%", null);
    try expectDescribe(.unicode_range, "U+0025-00FF, u+4??", "{\"text\":\"U+25-FF, U+400-4FF\",\"ranges\":[[37,255],[1024,1279]]}");
    try expectDescribe(.unicode_range, "U+26", "{\"text\":\"U+26\",\"ranges\":[[38,38]]}");
    inline for (.{ "U+110000", "U+7F-0", "U+", "bogus", "", "U+0-7F U+100", "U+1??-2FF", "U+1234567" }) |bad| {
        try expectDescribe(.unicode_range, bad, null);
    }
    try expectDescribe(.feature_settings, "\"liga\" on, 'kern' 0, \"smcp\" 2", "{\"text\":\"\\\"liga\\\", \\\"kern\\\" 0, \\\"smcp\\\" 2\"}");
    try expectDescribe(.feature_settings, "\"toolong\"", null);
    try expectDescribe(.feature_settings, "liga", null);
    try expectDescribe(.feature_settings, "\"liga\" -1", null);
    try expectDescribe(.variation_settings, "\"wght\" 400", "{\"text\":\"\\\"wght\\\" 400\"}");
    try expectDescribe(.variation_settings, "\"wght\"", null);
    try expectDescribe(.display, "SWAP", "{\"text\":\"swap\"}");
    try expectDescribe(.size_adjust, "normal", null);
    try expectDescribe(.ascent_override, "10.5%", "{\"text\":\"10.5%\"}");
}

fn expectSources(text: []const u8, expected: ?[]const u8) !void {
    const allocator = std.testing.allocator;
    const actual = try describeSources(allocator, text);
    defer if (actual) |a| allocator.free(a);
    if (expected) |e| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(e, actual.?);
    } else try std.testing.expect(actual == null);
}

test "src descriptor" {
    try expectSources("url(/a.ttf)", "{\"urls\":[\"/a.ttf\"],\"local\":0}");
    try expectSources("url(\"/a b.ttf\") format(\"truetype\")", "{\"urls\":[\"/a b.ttf\"],\"local\":0}");
    try expectSources("url(/a.woff2) format(\"woff2\"), url(/b.ttf)", "{\"urls\":[\"/a.woff2\",\"/b.ttf\"],\"local\":0}");
    try expectSources("local(Arial), url(/x.eot), url(/x.ttf) format(truetype) tech(variations)", "{\"urls\":[\"/x.ttf\"],\"local\":1}");
    try expectSources("url(/a.ttf),", "{\"urls\":[\"/a.ttf\"],\"local\":0}");
    try expectSources("url(/a.eot) format(\"embedded-opentype\"), url(/a.woff) format(\"woff\")", "{\"urls\":[\"/a.woff\"],\"local\":0}");
    inline for (.{ "/a.ttf", "", "bogus", "url(/a.ttf) format(\"embedded-opentype\")", "url(/a.ttf) bogus", "url(/a.ttf) tech(color-svg)" }) |bad| {
        try expectSources(bad, null);
    }
}

test "font shorthand" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "20px \"Used Face\"", "{\"families\":[[\"Used Face\",false]],\"weight\":400,\"style\":\"normal\",\"stretch\":100}" },
        .{ "italic small-caps bold condensed 20px/2 Used Face, serif", "{\"families\":[[\"Used Face\",false],[\"serif\",true]],\"weight\":700,\"style\":\"italic\",\"stretch\":75}" },
        .{ "350 2em/normal a", "{\"families\":[[\"a\",false]],\"weight\":350,\"style\":\"normal\",\"stretch\":100}" },
        .{ "caption", "{\"families\":[],\"weight\":400,\"style\":\"normal\",\"stretch\":100}" },
        .{ "bogus", null },
        .{ "20px", null },
        .{ "", null },
        .{ "inherit", null },
        .{ "20px inherit", null },
        .{ "20px a,", null },
    };
    for (cases) |case| {
        const actual = try describeFont(allocator, case[0]);
        defer if (actual) |a| allocator.free(a);
        if (case[1]) |e| {
            try std.testing.expect(actual != null);
            try std.testing.expectEqualStrings(e, actual.?);
        } else try std.testing.expect(actual == null);
    }
}
