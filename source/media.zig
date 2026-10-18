//! CSS @media query evaluator (Media Queries Level 4, with the Level 3
//! `media_query_list` grammar for `not`/`only`/media types).
//!
//! A query list is a comma-separated OR of media queries. Each query is
//! `[not|only]? <media-type>? [and <media-condition>]*` or a bare
//! `<media-condition> [and <media-condition>]*`. Evaluation is three-valued
//! (MQ4 §3.1): a feature the engine does not know, or a query that does not
//! parse, is *unknown* and evaluates to false even under `not` — the list
//! treats it as `not all`. This is what lets `@media (bogus), all` match
//! while `@media not all and (bogus)` does not.
//!
//! The environment this evaluates for: a continuous screen, 8 bits per colour
//! channel, no monochrome, 1dppx, fine pointer with hover, light colour
//! scheme, scripting enabled.

const std = @import("std");

pub const Viewport = struct {
    width_px: u32,
    height_px: u32,
    /// False while the host has not set a viewport: every block is included
    /// (static renderers). A configured 0×0 viewport is a real size.
    configured: bool = true,
};

/// Evaluate a @media condition string against the given viewport.
/// Returns true if the CSS block should be included for screen rendering.
pub fn evaluate(condition: []const u8, viewport: Viewport) bool {
    if (!viewport.configured) return true;

    const t = trim(condition);
    if (t.len == 0) return true; // bare @media {} — include

    // Comma-separated media query lists have OR semantics; an unknown or
    // malformed query counts as false, the other queries still get a say.
    var comma_it = std.mem.splitScalar(u8, t, ',');
    while (comma_it.next()) |query| {
        if (evaluateSingleQuery(trim(query), viewport) == .true) return true;
    }
    return false;
}

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
    fn of(b: bool) Truth {
        return if (b) .true else .false;
    }
};

/// Evaluate one media query (no commas). Compound conditions joined by `and`.
fn evaluateSingleQuery(query: []const u8, viewport: Viewport) Truth {
    if (query.len == 0) return .true;

    // Normalize whitespace: collapse runs of spaces/tabs/newlines to single
    // space (queries span lines in real stylesheets) and lowercase: media
    // types, keywords and feature names are ASCII case-insensitive.
    var normalized: [512]u8 = undefined;
    var norm_len: usize = 0;
    var in_ws = false;
    for (query) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            if (!in_ws and norm_len > 0) {
                if (norm_len < normalized.len) {
                    normalized[norm_len] = ' ';
                    norm_len += 1;
                }
            }
            in_ws = true;
        } else {
            if (norm_len < normalized.len) {
                normalized[norm_len] = std.ascii.toLower(ch);
                norm_len += 1;
            }
            in_ws = false;
        }
    }
    if (norm_len > 0 and normalized[norm_len - 1] == ' ') norm_len -= 1;
    const q = normalized[0..norm_len];

    var it = std.mem.splitSequence(u8, q, " and ");
    const first = trim(it.next() orelse return .true);

    // `not` / `only` apply to the whole query and require a media type.
    var negate = false;
    var head = first;
    if (startsWith(head, "not ")) {
        negate = true;
        head = trim(head[4..]);
    } else if (startsWith(head, "only ")) {
        head = trim(head[5..]);
    }

    var result: Truth = undefined;
    if (head.len > 0 and head[0] == '(') {
        // Bare condition list: `(feature) and (feature)`; `not`/`only` are
        // not allowed before a bare condition in this grammar.
        if (negate or head.ptr != first.ptr) return .unknown;
        result = evaluateCondition(head, viewport);
    } else {
        result = evaluateMediaType(head);
    }

    while (it.next()) |part| {
        const p = trim(part);
        if (p.len == 0) return .unknown;
        // After the media type, every term must be a parenthesised condition
        // (`all and color` is malformed — MQ3 §3: "not all").
        if (p[0] != '(') return .unknown;
        result = result.andWith(evaluateCondition(p, viewport));
    }
    return if (negate) result.not() else result;
}

/// A media type on its own (MQ4 §2.2): we are a screen.
fn evaluateMediaType(name: []const u8) Truth {
    if (eql(name, "all") or eql(name, "screen")) return .true;
    if (eql(name, "print") or eql(name, "speech")) return .false;
    // Deprecated types (tty, tv, projection, handheld, braille, embossed,
    // aural) must be recognized but never match (MQ4 §2.2).
    if (eql(name, "tty") or eql(name, "tv") or eql(name, "projection") or eql(name, "handheld") or
        eql(name, "braille") or eql(name, "embossed") or eql(name, "aural")) return .false;
    return .unknown;
}

/// A parenthesised media condition: `(feature)`, `(feature: value)`,
/// `(min-feature: value)`, `(max-feature: value)`.
fn evaluateCondition(atom: []const u8, viewport: Viewport) Truth {
    if (!(startsWith(atom, "(") and std.mem.endsWith(u8, atom, ")"))) return .unknown;
    const inner = trim(atom[1 .. atom.len - 1]);
    if (inner.len == 0) return .unknown;
    // Nested `not`/`and` inside parentheses (MQ4 §4) — supported shapes only.
    if (startsWith(inner, "not ")) return evaluateCondition(trim(inner[4..]), viewport).not();
    if (inner[0] == '(') {
        var result: Truth = .true;
        var parts = std.mem.splitSequence(u8, inner, " and ");
        while (parts.next()) |p| result = result.andWith(evaluateCondition(trim(p), viewport));
        return result;
    }
    return evalFeature(inner, viewport);
}

const Range = enum { min, max, exact };

/// Evaluate a media feature `name[: value]` (MQ4 §2.4): the `min-`/`max-`
/// prefixes are range comparisons, a bare name tests for a non-zero value.
fn evalFeature(feature: []const u8, viewport: Viewport) Truth {
    const f = trim(feature);
    var name_part: []const u8 = f;
    var value: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, f, ':')) |colon| {
        name_part = trim(f[0..colon]);
        value = trim(f[colon + 1 ..]);
        if (value.?.len == 0) return .unknown;
    }
    var range: Range = .exact;
    var name = name_part;
    if (startsWith(name, "min-")) {
        range = .min;
        name = name[4..];
    } else if (startsWith(name, "max-")) {
        range = .max;
        name = name[4..];
    }
    if (range != .exact and value == null) return .unknown; // `(min-width)` is invalid

    // Length features
    if (eql(name, "width") or eql(name, "device-width")) {
        return compareLength(@floatFromInt(viewport.width_px), range, value);
    }
    if (eql(name, "height") or eql(name, "device-height")) {
        return compareLength(@floatFromInt(viewport.height_px), range, value);
    }
    // Integer features
    if (eql(name, "color")) return compareInteger(8, range, value);
    if (eql(name, "color-index")) return compareInteger(0, range, value);
    if (eql(name, "monochrome")) return compareInteger(0, range, value);
    if (eql(name, "resolution")) return compareResolution(range, value);
    if (eql(name, "device-pixel-ratio") or eql(name, "-webkit-device-pixel-ratio") or eql(name, "-moz-device-pixel-ratio")) {
        const v = value orelse return .true;
        const n = std.fmt.parseFloat(f32, trim(v)) catch return .unknown;
        return compareNumber(1.0, range, n);
    }
    if (eql(name, "aspect-ratio") or eql(name, "device-aspect-ratio")) {
        if (viewport.height_px == 0) return .false;
        const actual = @as(f32, @floatFromInt(viewport.width_px)) / @as(f32, @floatFromInt(viewport.height_px));
        const v = value orelse return .true;
        const wanted = parseRatio(trim(v)) orelse return .unknown;
        return compareNumber(actual, range, wanted);
    }
    // Discrete features (no min-/max-)
    if (range != .exact) return .unknown;
    if (eql(name, "orientation")) {
        const v = value orelse return .true;
        if (eql(v, "landscape")) return Truth.of(viewport.width_px >= viewport.height_px);
        if (eql(v, "portrait")) return Truth.of(viewport.height_px > viewport.width_px);
        return .unknown;
    }
    if (eql(name, "grid")) return discrete(value, "0", &.{"1"});
    if (eql(name, "scan")) return discrete(value, "progressive", &.{"interlace"});
    if (eql(name, "update")) return discrete(value, "fast", &.{ "none", "slow" });
    if (eql(name, "overflow-block")) return discrete(value, "scroll", &.{ "none", "paged", "optional-paged" });
    if (eql(name, "overflow-inline")) return discrete(value, "scroll", &.{"none"});
    if (eql(name, "color-gamut")) return discrete(value, "srgb", &.{ "p3", "rec2020" });
    if (eql(name, "pointer") or eql(name, "any-pointer")) return discrete(value, "fine", &.{ "none", "coarse" });
    if (eql(name, "hover") or eql(name, "any-hover")) return discrete(value, "hover", &.{"none"});
    if (eql(name, "prefers-color-scheme")) return discrete(value, "light", &.{"dark"});
    if (eql(name, "prefers-reduced-motion")) return discreteNone(value, "no-preference", &.{"reduce"});
    if (eql(name, "prefers-reduced-transparency")) return discreteNone(value, "no-preference", &.{"reduce"});
    if (eql(name, "prefers-reduced-data")) return discreteNone(value, "no-preference", &.{"reduce"});
    if (eql(name, "prefers-contrast")) return discreteNone(value, "no-preference", &.{ "more", "less", "custom" });
    if (eql(name, "forced-colors")) return discreteNone(value, "none", &.{"active"});
    if (eql(name, "inverted-colors")) return discreteNone(value, "none", &.{"inverted"});
    if (eql(name, "dynamic-range") or eql(name, "video-dynamic-range")) return discrete(value, "standard", &.{"high"});
    if (eql(name, "scripting")) return discrete(value, "enabled", &.{ "none", "initial-only" });
    if (eql(name, "display-mode")) return discrete(value, "browser", &.{ "fullscreen", "standalone", "minimal-ui", "picture-in-picture", "window-controls-overlay" });

    // Unknown feature (MQ4 §3.1): unknown — never matches, even negated.
    return .unknown;
}

/// A discrete feature whose current value is `current`: bare `(name)` is true
/// (the value is not none/0), `(name: v)` compares, unlisted keywords are unknown.
fn discrete(value: ?[]const u8, current: []const u8, others: []const []const u8) Truth {
    const v = value orelse return .true;
    if (eql(v, current)) return .true;
    for (others) |o| if (eql(v, o)) return .false;
    return .unknown;
}

/// Like `discrete` for features whose current value is a "none"-like keyword,
/// so the bare form `(name)` is false.
fn discreteNone(value: ?[]const u8, current: []const u8, others: []const []const u8) Truth {
    const v = value orelse return .false;
    if (eql(v, current)) return .true;
    for (others) |o| if (eql(v, o)) return .false;
    return .unknown;
}

fn compareLength(actual: f32, range: Range, value: ?[]const u8) Truth {
    const v = value orelse return Truth.of(actual > 0);
    const wanted = extractPxValue(v) orelse return .unknown;
    return compareNumber(actual, range, wanted);
}

fn compareInteger(actual: i32, range: Range, value: ?[]const u8) Truth {
    const v = value orelse return Truth.of(actual > 0);
    const wanted = std.fmt.parseInt(i32, trim(v), 10) catch return .unknown;
    if (wanted < 0) return .unknown;
    return compareNumber(@floatFromInt(actual), range, @floatFromInt(wanted));
}

fn compareNumber(actual: f32, range: Range, wanted: f32) Truth {
    return Truth.of(switch (range) {
        .min => actual >= wanted,
        .max => actual <= wanted,
        .exact => actual == wanted,
    });
}

/// We render at 1dppx = 96dpi.
fn compareResolution(range: Range, value: ?[]const u8) Truth {
    const v = trim(value orelse return .true);
    const wanted: f32 = blk: {
        if (std.mem.endsWith(u8, v, "dppx")) break :blk std.fmt.parseFloat(f32, v[0 .. v.len - 4]) catch return .unknown;
        if (std.mem.endsWith(u8, v, "dpi")) break :blk (std.fmt.parseFloat(f32, v[0 .. v.len - 3]) catch return .unknown) / 96.0;
        if (std.mem.endsWith(u8, v, "dpcm")) break :blk (std.fmt.parseFloat(f32, v[0 .. v.len - 4]) catch return .unknown) * 2.54 / 96.0;
        if (std.mem.endsWith(u8, v, "x")) break :blk std.fmt.parseFloat(f32, v[0 .. v.len - 1]) catch return .unknown;
        return .unknown;
    };
    return compareNumber(1.0, range, wanted);
}

fn parseRatio(v: []const u8) ?f32 {
    if (std.mem.indexOfScalar(u8, v, '/')) |slash| {
        const a = std.fmt.parseFloat(f32, trim(v[0..slash])) catch return null;
        const b = std.fmt.parseFloat(f32, trim(v[slash + 1 ..])) catch return null;
        if (b == 0) return null;
        return a / b;
    }
    return std.fmt.parseFloat(f32, v) catch null;
}

/// Extract a pixel value from a CSS length string like "300px", "16em", "calc(640px - 1px)".
fn extractPxValue(raw: []const u8) ?f32 {
    const s = trim(raw);
    if (std.mem.endsWith(u8, s, "px")) {
        return std.fmt.parseFloat(f32, s[0 .. s.len - 2]) catch null;
    }
    if (std.mem.endsWith(u8, s, "em") or std.mem.endsWith(u8, s, "rem")) {
        const unit_len: usize = if (std.mem.endsWith(u8, s, "rem")) 3 else 2;
        const v = std.fmt.parseFloat(f32, s[0 .. s.len - unit_len]) catch return null;
        return v * 16; // 1em = 16px for media queries (initial font-size)
    }
    // calc(Apx - Bpx) or calc(Apx + Bpx)
    if (std.mem.startsWith(u8, s, "calc(") and std.mem.endsWith(u8, s, ")")) {
        const inner = s["calc(".len .. s.len - 1];
        if (std.mem.indexOf(u8, inner, " - ")) |pos| {
            const a = extractPxValue(inner[0..pos]) orelse return null;
            const b = extractPxValue(inner[pos + 3 ..]) orelse return null;
            return a - b;
        }
        if (std.mem.indexOf(u8, inner, " + ")) |pos| {
            const a = extractPxValue(inner[0..pos]) orelse return null;
            const b = extractPxValue(inner[pos + 3 ..]) orelse return null;
            return a + b;
        }
        return extractPxValue(inner);
    }
    // Unitless zero is the only valid unitless length.
    if (eql(s, "0")) return 0;
    return null;
}

// --- Helpers ---

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\n\r");
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

test "media types and keywords" {
    const vp = Viewport{ .width_px = 1280, .height_px = 720 };
    try std.testing.expect(evaluate("screen", vp));
    try std.testing.expect(evaluate("all", vp));
    try std.testing.expect(evaluate("only screen", vp));
    try std.testing.expect(!evaluate("print", vp));
    try std.testing.expect(!evaluate("not screen", vp));
    try std.testing.expect(evaluate("not print", vp));
    try std.testing.expect(evaluate("screen, print", vp));
    try std.testing.expect(!evaluate("nonsense", vp));
    try std.testing.expect(evaluate("", vp));
    try std.testing.expect(evaluate("(bogus)", .{ .width_px = 0, .height_px = 0, .configured = false }));
}

test "viewport features" {
    const vp = Viewport{ .width_px = 1280, .height_px = 720 };
    try std.testing.expect(evaluate("(min-width: 1000px)", vp));
    try std.testing.expect(!evaluate("(min-width: 1300px)", vp));
    try std.testing.expect(evaluate("screen and (max-width: 1280px)", vp));
    try std.testing.expect(evaluate("only screen and (min-width: 300px) and (max-height: 800px)", vp));
    try std.testing.expect(evaluate("(orientation: landscape)", vp));
    try std.testing.expect(!evaluate("(orientation: portrait)", vp));
    try std.testing.expect(evaluate("(min-width: 50em)", vp));
    try std.testing.expect(!evaluate("(min-resolution: 2dppx)", vp));
    try std.testing.expect(evaluate("(min-resolution: 96dpi)", vp));
    try std.testing.expect(evaluate("(hover: hover) and (pointer: fine)", vp));
    try std.testing.expect(!evaluate("(prefers-color-scheme: dark)", vp));
    try std.testing.expect(evaluate("(prefers-reduced-motion: no-preference)", vp));
    try std.testing.expect(!evaluate("(prefers-reduced-motion: reduce)", vp));
    // A zero-sized but configured viewport is a real size.
    const tiny = Viewport{ .width_px = 0, .height_px = 0 };
    try std.testing.expect(evaluate("(max-width: 1em) and (max-height: 1em)", tiny));
    try std.testing.expect(!evaluate("(min-width: 1em)", tiny));
}

test "three-valued evaluation (Acid3 test 46)" {
    const vp = Viewport{ .width_px = 0, .height_px = 0 };
    try std.testing.expect(evaluate("all and (min-color: 0)", vp));
    try std.testing.expect(!evaluate("not all and (min-color: 0)", vp));
    try std.testing.expect(evaluate("only all and (min-color: 0)", vp));
    try std.testing.expect(!evaluate("(bogus)", vp));
    try std.testing.expect(!evaluate("all and (bogus)", vp));
    try std.testing.expect(!evaluate("not all and (bogus)", vp));
    try std.testing.expect(!evaluate("only all and (bogus)", vp));
    try std.testing.expect(evaluate("(bogus), all", vp));
    try std.testing.expect(evaluate("all and (bogus), all", vp));
    try std.testing.expect(evaluate("not all and (bogus), all", vp));
    try std.testing.expect(evaluate("all, (bogus)", vp));
    try std.testing.expect(evaluate("all, not all and (bogus)", vp));
    try std.testing.expect(!evaluate("all and color", vp));
    try std.testing.expect(!evaluate("all and min-color: 0", vp));
    try std.testing.expect(evaluate("all, all and color", vp));
    try std.testing.expect(evaluate("all and min-color: 0, all", vp));
    try std.testing.expect(!evaluate("(max-color: 0) and (max-monochrome: 0)", vp));
    try std.testing.expect(evaluate("(min-color: 1), (min-monochrome: 1)", vp));
    try std.testing.expect(evaluate("all and (min-color: 0) and (min-monochrome: 0)", vp));
    try std.testing.expect(evaluate("not all and (min-color: 1), not all and (min-monochrome: 1)", vp));
    try std.testing.expect(!evaluate("all and (min-height: 1em) and (min-width: 1em)", vp));
    try std.testing.expect(evaluate("all and (max-height: 1em) and (max-width: 1em)", vp));
}
