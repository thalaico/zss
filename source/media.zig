/// CSS @media query evaluator.
///
/// Evaluates media query conditions against a viewport context.
/// Supports the subset needed for real-world sites (HN, Wikipedia):
/// - Media types: screen, print, all, not screen, not print
/// - `only` keyword (stripped per spec — acts as forward-compat guard)
/// - min-width, max-width, min-height, max-height
/// - orientation: landscape | portrait
/// - prefers-color-scheme: light | dark
/// - prefers-reduced-motion: reduce | no-preference
/// - Comma-separated query lists (OR semantics)
/// - Compound conditions with `and`
/// - -webkit-min-device-pixel-ratio, min-resolution (treated as DPR = 1)

const std = @import("std");

pub const Viewport = struct {
    width_px: u32,
    height_px: u32,
};

/// Evaluate a @media condition string against the given viewport.
/// Returns true if the CSS block should be included for screen rendering.
///
/// If viewport dimensions are zero (not configured), all @media blocks are
/// included — this preserves backward compatibility when viewport is unknown.
pub fn evaluate(condition: []const u8, viewport: Viewport) bool {
    // No viewport configured — include everything (backward compat).
    if (viewport.width_px == 0 and viewport.height_px == 0) return true;

    const t = trim(condition);
    if (t.len == 0) return true; // bare @media {} — include

    // Comma-separated media query lists have OR semantics.
    // "@media screen, print" → true if EITHER matches.
    var comma_it = std.mem.splitScalar(u8, t, ',');
    while (comma_it.next()) |query| {
        if (evaluateSingleQuery(trim(query), viewport)) return true;
    }
    return false;
}

/// Evaluate one media query (no commas). Compound conditions joined by `and`.
/// Handles multi-line conditions like `@media only screen\nand (min-width: 300px)`.
fn evaluateSingleQuery(query: []const u8, viewport: Viewport) bool {
    if (query.len == 0) return true;

    // Normalize whitespace: collapse runs of spaces/tabs/newlines to single space.
    // CSS media queries can span multiple lines (e.g., HN news.css).
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
                normalized[norm_len] = ch;
                norm_len += 1;
            }
            in_ws = false;
        }
    }
    // Trim trailing space
    if (norm_len > 0 and normalized[norm_len - 1] == ' ') norm_len -= 1;
    const q = normalized[0..norm_len];

    // Split on " and " for compound conditions.
    var it = std.mem.splitSequence(u8, q, " and ");
    while (it.next()) |part| {
        const p = trim(part);
        if (p.len == 0) continue;
        if (!evaluateAtom(p, viewport)) return false;
    }
    return true;
}

/// Evaluate a single atom: media type, parenthesized feature, or negation.
fn evaluateAtom(atom: []const u8, viewport: Viewport) bool {
    // Media types and keywords
    if (eql(atom, "screen") or eql(atom, "all")) return true;
    if (eql(atom, "only screen") or eql(atom, "only all")) return true;
    if (eql(atom, "print")) return false;
    if (eql(atom, "only print")) return false;
    if (eql(atom, "not screen")) return false;
    if (eql(atom, "not print")) return true;

    // Parenthesized feature: (min-width: 300px)
    if (std.mem.startsWith(u8, atom, "(") and std.mem.endsWith(u8, atom, ")")) {
        return evalFeature(atom[1 .. atom.len - 1], viewport);
    }

    // "only" prefix for compound: "only screen and (...)" — the "only screen" part
    // is split by " and " so we see "only screen" here.
    if (std.mem.startsWith(u8, atom, "only ")) {
        const inner = trim(atom["only ".len..]);
        if (eql(inner, "screen") or eql(inner, "all")) return true;
        if (eql(inner, "print")) return false;
    }

    // Unknown token — permissive (include).
    return true;
}

/// Evaluate a parenthesized media feature condition like "min-width: 300px".
fn evalFeature(feature: []const u8, viewport: Viewport) bool {
    const f = trim(feature);

    // Split on ':' to separate property name from value.
    // Handles both "min-width:300px" and "min-width : 300px".
    const colon_pos = std.mem.indexOfScalar(u8, f, ':') orelse return true;
    const name = trim(f[0..colon_pos]);
    const value = trim(f[colon_pos + 1 ..]);

    // Width queries
    if (eql(name, "min-width")) {
        const v = extractPxValue(value) orelse return true;
        return @as(f32, @floatFromInt(viewport.width_px)) >= v;
    }
    if (eql(name, "max-width")) {
        const v = extractPxValue(value) orelse return true;
        return @as(f32, @floatFromInt(viewport.width_px)) <= v;
    }

    // Height queries
    if (eql(name, "min-height")) {
        const v = extractPxValue(value) orelse return true;
        return @as(f32, @floatFromInt(viewport.height_px)) >= v;
    }
    if (eql(name, "max-height")) {
        const v = extractPxValue(value) orelse return true;
        return @as(f32, @floatFromInt(viewport.height_px)) <= v;
    }

    // Orientation
    if (eql(name, "orientation")) {
        if (eql(value, "landscape")) return viewport.width_px >= viewport.height_px;
        if (eql(value, "portrait")) return viewport.height_px > viewport.width_px;
        return true;
    }

    // Color scheme — we render light mode
    if (eql(name, "prefers-color-scheme")) {
        return eql(value, "light") or eql(value, "no-preference");
    }

    // Reduced motion
    if (eql(name, "prefers-reduced-motion")) {
        return !eql(value, "reduce");
    }

    // DPR/resolution — we render at 1x, so reject high-DPR conditions.
    if (eql(name, "-webkit-min-device-pixel-ratio") or
        eql(name, "min-device-pixel-ratio"))
    {
        return false;
    }
    if (eql(name, "min-resolution")) {
        return false;
    }

    // Unknown feature — permissive (include).
    return true;
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
    // Bare number (e.g., in device-pixel-ratio)
    return std.fmt.parseFloat(f32, s) catch null;
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

// --- Tests ---

test "basic media types" {
    const vp: Viewport = .{ .width_px = 1280, .height_px = 720 };
    try std.testing.expect(evaluate("screen", vp) == true);
    try std.testing.expect(evaluate("print", vp) == false);
    try std.testing.expect(evaluate("all", vp) == true);
    try std.testing.expect(evaluate("not print", vp) == true);
    try std.testing.expect(evaluate("not screen", vp) == false);
    try std.testing.expect(evaluate("only screen", vp) == true);
    try std.testing.expect(evaluate("only print", vp) == false);
}

test "min-width / max-width" {
    const vp: Viewport = .{ .width_px = 800, .height_px = 600 };
    try std.testing.expect(evaluate("(min-width: 300px)", vp) == true);
    try std.testing.expect(evaluate("(min-width: 800px)", vp) == true);
    try std.testing.expect(evaluate("(min-width: 801px)", vp) == false);
    try std.testing.expect(evaluate("(max-width: 800px)", vp) == true);
    try std.testing.expect(evaluate("(max-width: 799px)", vp) == false);
}

test "compound: only screen and (min-width)" {
    const vp: Viewport = .{ .width_px = 800, .height_px = 600 };
    // HN pattern: "only screen and (min-width : 300px) and (max-width : 750px)"
    try std.testing.expect(evaluate("only screen and (min-width: 300px) and (max-width: 750px)", vp) == false);
    try std.testing.expect(evaluate("only screen and (min-width: 300px) and (max-width: 900px)", vp) == true);
    // The critical HN rule that overrides min-width: 796px
    try std.testing.expect(evaluate("only screen and (min-width : 300px)", vp) == true);
}

test "comma-separated OR semantics" {
    const vp: Viewport = .{ .width_px = 1280, .height_px = 720 };
    // Wikipedia pattern: "(-webkit-min-device-pixel-ratio:2),(min-resolution:2dppx)"
    // Both are DPR ≥2 checks — should be false at 1x
    try std.testing.expect(evaluate("(-webkit-min-device-pixel-ratio:2),(min-resolution:2dppx)", vp) == false);
    // "screen, print" — screen matches
    try std.testing.expect(evaluate("screen, print", vp) == true);
    // "print, (min-width: 9999px)" — both false
    try std.testing.expect(evaluate("print, (min-width: 9999px)", vp) == false);
}

test "prefers-color-scheme" {
    const vp: Viewport = .{ .width_px = 1280, .height_px = 720 };
    try std.testing.expect(evaluate("(prefers-color-scheme: light)", vp) == true);
    try std.testing.expect(evaluate("(prefers-color-scheme: dark)", vp) == false);
}

test "zero viewport includes everything" {
    const vp: Viewport = .{ .width_px = 0, .height_px = 0 };
    try std.testing.expect(evaluate("(min-width: 9999px)", vp) == true);
    try std.testing.expect(evaluate("print", vp) == true);
}

test "HN news.css critical rules" {
    // At 800x600, the key @media rule that overrides min-width: 796px
    const vp800: Viewport = .{ .width_px = 800, .height_px = 600 };
    // "#hnmain { min-width: 796px; }" is outside any @media — always applies
    // This @media block should override it:
    try std.testing.expect(evaluate("only screen and (min-width : 300px)", vp800) == true);
    // Mobile-specific rules should NOT apply at 800px:
    try std.testing.expect(evaluate("only screen and (min-width : 300px) and (max-width : 750px)", vp800) == false);
    // Comment max-width range that includes 800px:
    try std.testing.expect(evaluate("only screen and (min-width : 690px) and (max-width : 809px)", vp800) == true);
}

test "multi-line media queries (HN news.css pattern)" {
    const vp800: Viewport = .{ .width_px = 800, .height_px = 600 };
    // HN news.css has: @media only screen\nand (min-width : 300px)\nand (max-width : 750px)
    try std.testing.expect(evaluate("only screen\nand (min-width : 300px)\nand (max-width : 750px)", vp800) == false);
    try std.testing.expect(evaluate("only screen\nand (min-width : 300px)", vp800) == true);
    // Tab/CRLF variants
    try std.testing.expect(evaluate("only screen\r\nand (min-width : 300px)\r\nand (max-width : 750px)", vp800) == false);
}
