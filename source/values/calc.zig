//! Math functions (CSS Values 4 §10): calc(), min(), max(), clamp() whose
//! value is a <length-percentage>.
//!
//! Parsing type-checks the expression (§10.7: sums of same-typed values,
//! products with at least one <number>, division by a <number>) and
//! simplifies it (§10.10): sums and products of lengths fold into a
//! `Linear` (px + em × font size + percentage × base), and min()/max()/
//! clamp() fold when their arguments can be compared without context (all
//! numbers, or lengths in the same single unit). What does not fold —
//! a min() of a percentage and a length, a sum containing such a min() — is
//! kept as a tree of `Node`s in the Environment's `Table`, and evaluated at
//! used-value time against the percentage base.
//!
//! Absolute and viewport units fold to px at parse time, like other zss
//! lengths; `rem` against the initial font size (16px), as elsewhere in zss.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const Ast = zss.syntax.Ast;
const SourceCode = zss.syntax.SourceCode;

pub const Id = enum(u32) { _ };

/// The px value of a length in an absolute or viewport unit (CSS Values 4
/// §6.2: 1in = 96px = 2.54cm, 1pt = 1/72in, 1pc = 12pt, 1Q = 1/4mm; §6.1.2
/// vw/vh/vmin/vmax), or null for a font-relative unit (em, rem).
pub fn absoluteLengthPx(unit: zss.syntax.Token.Unit, number: f32, viewport_width_px: f32, viewport_height_px: f32) ?f32 {
    return switch (unit) {
        .px => number,
        .in => number * 96.0,
        .cm => number * 96.0 / 2.54,
        .mm => number * 96.0 / 25.4,
        .q => number * 96.0 / 101.6,
        .pt => number * 96.0 / 72.0,
        .pc => number * 16.0,
        .vw => number * viewport_width_px / 100.0,
        .vh => number * viewport_height_px / 100.0,
        .vmin => number * @min(viewport_width_px, viewport_height_px) / 100.0,
        .vmax => number * @max(viewport_width_px, viewport_height_px) / 100.0,
        .em, .rem => null,
    };
}

/// CSS Values 4 §10.9: a NaN result becomes 0, and infinities clamp to the
/// largest supported length — Chrome's (LayoutUnit), which zss shares so
/// that sums of such sizes stay in range.
pub fn clampPx(px: f32) f32 {
    const max_px: f32 = 33554428;
    if (std.math.isNan(px)) return 0;
    return std.math.clamp(px, -max_px, max_px);
}

/// px + em × (font size) + percentage × (percentage base).
pub const Linear = struct {
    px: f32 = 0,
    em: f32 = 0,
    percentage: f32 = 0,

    fn add(a: Linear, b: Linear) Linear {
        return .{ .px = a.px + b.px, .em = a.em + b.em, .percentage = a.percentage + b.percentage };
    }

    fn scale(a: Linear, factor: f32) Linear {
        // Absent terms stay absent (0 × ∞ would be NaN).
        const f = struct {
            fn mul(v: f32, k: f32) f32 {
                return if (v == 0) 0 else v * k;
            }
        }.mul;
        return .{ .px = f(a.px, factor), .em = f(a.em, factor), .percentage = f(a.percentage, factor) };
    }

    /// The single unit this value is expressed in, if it has exactly one
    /// (zero counts as px).
    const SoleUnit = enum { px, em, percentage };

    fn soleUnit(a: Linear) ?SoleUnit {
        const n = @as(u2, @intFromBool(a.px != 0)) + @intFromBool(a.em != 0) + @intFromBool(a.percentage != 0);
        if (n == 0) return .px;
        if (n > 1) return null;
        return if (a.px != 0) .px else if (a.em != 0) .em else .percentage;
    }

    fn component(a: Linear, unit: SoleUnit) f32 {
        return switch (unit) {
            .px => a.px,
            .em => a.em,
            .percentage => a.percentage,
        };
    }

    fn eval(a: Linear, font_size: f32, base: ?f32) ?f32 {
        if (a.percentage != 0 and base == null) return null;
        return a.px + a.em * font_size + a.percentage * (base orelse 0);
    }
};

pub const Node = union(enum) {
    linear: Linear,
    sum: Range,
    scale: struct { child: Id, factor: f32 },
    min: Range,
    max: Range,
    clamp: [3]Id,
};

/// A run of `Table.children`.
pub const Range = struct { start: u32, len: u32 };

pub const Table = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    children: std.ArrayListUnmanaged(Id) = .empty,

    pub fn deinit(table: *Table, allocator: Allocator) void {
        table.nodes.deinit(allocator);
        table.children.deinit(allocator);
    }

    fn add(table: *Table, allocator: Allocator, node: Node) !Id {
        try table.nodes.append(allocator, node);
        return @enumFromInt(table.nodes.items.len - 1);
    }

    pub fn addLinear(table: *Table, allocator: Allocator, linear: Linear) !Id {
        return table.add(allocator, .{ .linear = linear });
    }

    fn addRange(table: *Table, allocator: Allocator, ids: []const Id) !Range {
        const start: u32 = @intCast(table.children.items.len);
        try table.children.appendSlice(allocator, ids);
        return .{ .start = start, .len = @intCast(ids.len) };
    }

    /// The value in px for an element with font size `font_size`, with
    /// percentages of `base` (px). Null if the value has a percentage and
    /// `base` is null (an indefinite percentage base).
    pub fn eval(table: *const Table, id: Id, font_size: f32, base: ?f32) ?f32 {
        switch (table.nodes.items[@intFromEnum(id)]) {
            .linear => |l| return l.eval(font_size, base),
            .sum => |r| {
                var total: f32 = 0;
                for (table.range(r)) |child| total += table.eval(child, font_size, base) orelse return null;
                return total;
            },
            .scale => |s| return (table.eval(s.child, font_size, base) orelse return null) * s.factor,
            inline .min, .max => |r, tag| {
                var result: ?f32 = null;
                for (table.range(r)) |child| {
                    const v = table.eval(child, font_size, base) orelse return null;
                    result = if (result) |acc| (if (tag == .min) @min(acc, v) else @max(acc, v)) else v;
                }
                return result.?;
            },
            .clamp => |c| {
                const lo = table.eval(c[0], font_size, base) orelse return null;
                const val = table.eval(c[1], font_size, base) orelse return null;
                const hi = table.eval(c[2], font_size, base) orelse return null;
                // §10.4: max(MIN, min(VAL, MAX)) — MIN wins over MAX.
                return @max(lo, @min(val, hi));
            },
        }
    }

    /// Whether the value depends on the percentage base.
    pub fn hasPercentage(table: *const Table, id: Id) bool {
        switch (table.nodes.items[@intFromEnum(id)]) {
            .linear => |l| return l.percentage != 0,
            .scale => |s| return table.hasPercentage(s.child),
            .sum, .min, .max => |r| {
                for (table.range(r)) |child| if (table.hasPercentage(child)) return true;
                return false;
            },
            .clamp => |c| return table.hasPercentage(c[0]) or table.hasPercentage(c[1]) or table.hasPercentage(c[2]),
        }
    }

    fn range(table: *const Table, r: Range) []const Id {
        return table.children.items[r.start..][0..r.len];
    }
};

/// CSSOM serialization of a computed math-function value (`em` terms
/// resolved against `font_size`), as Chrome writes it: `calc(50% - 10px)`,
/// `min(50%, 300px)`; percentages before lengths.
pub const Formatter = struct {
    table: *const Table,
    id: Id,
    font_size: f32,

    pub fn format(f: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try f.root(writer, f.id);
    }

    fn root(f: Formatter, w: *std.Io.Writer, id: Id) std.Io.Writer.Error!void {
        switch (f.table.nodes.items[@intFromEnum(id)]) {
            .linear => |l| {
                if (f.termCount(l) > 1) {
                    try w.writeAll("calc(");
                    try f.linear(w, l);
                    try w.writeAll(")");
                } else try f.linear(w, l);
            },
            .min, .max, .clamp => try f.inner(w, id),
            .sum, .scale => {
                try w.writeAll("calc(");
                try f.inner(w, id);
                try w.writeAll(")");
            },
        }
    }

    fn inner(f: Formatter, w: *std.Io.Writer, id: Id) std.Io.Writer.Error!void {
        switch (f.table.nodes.items[@intFromEnum(id)]) {
            .linear => |l| try f.linear(w, l),
            .sum => |r| for (f.table.range(r), 0..) |child, i| {
                if (i > 0) try w.writeAll(" + ");
                try f.inner(w, child);
            },
            .scale => |s| {
                try w.writeAll("(");
                try f.inner(w, s.child);
                try w.print(") * {d}", .{rounded(s.factor)});
            },
            inline .min, .max => |r, tag| {
                try w.writeAll(@tagName(tag) ++ "(");
                for (f.table.range(r), 0..) |child, i| {
                    if (i > 0) try w.writeAll(", ");
                    try f.inner(w, child);
                }
                try w.writeAll(")");
            },
            .clamp => |c| {
                try w.writeAll("clamp(");
                for (c, 0..) |child, i| {
                    if (i > 0) try w.writeAll(", ");
                    try f.inner(w, child);
                }
                try w.writeAll(")");
            },
        }
    }

    fn termCount(f: Formatter, l: Linear) usize {
        const px = l.px + l.em * f.font_size;
        return @as(usize, @intFromBool(l.percentage != 0)) + @intFromBool(px != 0);
    }

    fn linear(f: Formatter, w: *std.Io.Writer, l: Linear) std.Io.Writer.Error!void {
        const px = l.px + l.em * f.font_size;
        if (l.percentage != 0) {
            try w.print("{d}%", .{rounded(l.percentage * 100)});
            if (px != 0) try w.print(" {s} {d}px", .{ if (px < 0) "-" else "+", rounded(@abs(px)) });
        } else try w.print("{d}px", .{rounded(px)});
    }

    fn rounded(v: f32) f64 {
        return @round(@as(f64, v) * 10000.0) / 10000.0;
    }
};

/// The result of parsing a math function: a folded linear value, or a tree.
pub const Value = union(enum) {
    linear: Linear,
    node: Id,
};

/// What a sub-expression evaluates to (§10.7).
const Typed = union(enum) {
    number: f32,
    length: Value,
};

pub const Options = struct {
    /// Whether percentages are allowed (<length-percentage>) or not (<length>).
    percentages: bool,
    viewport_width_px: f32,
    viewport_height_px: f32,
};

const Parser = struct {
    ast: Ast,
    source_code: SourceCode,
    table: *Table,
    allocator: Allocator,
    options: Options,

    const Error = error{ Invalid, OutOfMemory };

    /// A <length-percentage> math function at `function_index`, or null if it is
    /// not one (or not valid).
    fn function(p: *Parser, function_index: Ast.Index) Error!Typed {
        const name = p.source_code.mapIdentifierValue(function_index.location(p.ast), enum { calc, min, max, clamp }, &.{
            .{ "calc", .calc },
            .{ "min", .min },
            .{ "max", .max },
            .{ "clamp", .clamp },
        }) orelse return error.Invalid;
        var seq = function_index.children(p.ast);
        switch (name) {
            .calc => {
                const v = try p.sum(&seq);
                if (!seq.emptySkipSpaces(p.ast)) return error.Invalid;
                return v;
            },
            .min, .max => {
                var args: std.ArrayListUnmanaged(Typed) = .empty;
                defer args.deinit(p.allocator);
                while (true) {
                    try args.append(p.allocator, try p.sum(&seq));
                    const sep = seq.nextSkipSpaces(p.ast) orelse break;
                    if (sep.tag(p.ast) != .token_comma) return error.Invalid;
                }
                return if (name == .min) p.minMax(.min, args.items) else p.minMax(.max, args.items);
            },
            .clamp => {
                var args: [3]Typed = undefined;
                for (&args, 0..) |*arg, i| {
                    arg.* = try p.sum(&seq);
                    const sep = seq.nextSkipSpaces(p.ast);
                    if (i < 2) {
                        if (sep == null or sep.?.tag(p.ast) != .token_comma) return error.Invalid;
                    } else if (sep != null) return error.Invalid;
                }
                return p.clamp(args);
            },
        }
    }

    /// <calc-sum> = <calc-product> [ [ '+' | '-' ] <calc-product> ]*
    /// The operators must be surrounded by whitespace (§10.1).
    fn sum(p: *Parser, seq: *Ast.Sequence) Error!Typed {
        var acc = try p.product(seq);
        while (true) {
            const save = seq.start;
            if (!seq.skipSpaces(p.ast)) break;
            const op_index = seq.nextKeepSpaces(p.ast) orelse break;
            const sign: f32 = if (op_index.tag(p.ast) == .token_delim) switch (op_index.extra(p.ast).codepoint) {
                '+' => 1,
                '-' => -1,
                else => {
                    seq.reset(save);
                    break;
                },
            } else {
                seq.reset(save);
                break;
            };
            if (!seq.skipSpaces(p.ast)) return error.Invalid;
            const rhs = try p.product(seq);
            acc = try p.add(acc, try p.mul(rhs, .{ .number = sign }));
        }
        return acc;
    }

    /// <calc-product> = <calc-value> [ [ '*' | '/' ] <calc-value> ]*
    fn product(p: *Parser, seq: *Ast.Sequence) Error!Typed {
        var acc = try p.value(seq);
        while (true) {
            const save = seq.start;
            const op_index = seq.nextSkipSpaces(p.ast) orelse break;
            const op: u21 = if (op_index.tag(p.ast) == .token_delim) op_index.extra(p.ast).codepoint else 0;
            switch (op) {
                '*' => acc = try p.mul(acc, try p.value(seq)),
                '/' => {
                    const divisor = try p.value(seq);
                    switch (divisor) {
                        // Division by zero yields an infinity (§10.9),
                        // clamped when the value is used.
                        .number => |n| acc = try p.mul(acc, .{ .number = 1 / n }),
                        .length => return error.Invalid,
                    }
                },
                else => {
                    seq.reset(save);
                    break;
                },
            }
        }
        return acc;
    }

    /// <calc-value> = <number> | <dimension> | <percentage> | ( <calc-sum> ) | a math function
    fn value(p: *Parser, seq: *Ast.Sequence) Error!Typed {
        const index = seq.nextSkipSpaces(p.ast) orelse return error.Invalid;
        switch (index.tag(p.ast)) {
            .token_integer => return .{ .number = @floatFromInt(index.extra(p.ast).integer orelse return error.Invalid) },
            .token_number => return .{ .number = index.extra(p.ast).number orelse return error.Invalid },
            .token_percentage => {
                if (!p.options.percentages) return error.Invalid;
                return .{ .length = .{ .linear = .{ .percentage = index.extra(p.ast).number orelse return error.Invalid } } };
            },
            .token_dimension => {
                var children = index.children(p.ast);
                const unit_index = children.nextSkipSpaces(p.ast) orelse return error.Invalid;
                const number: f32 = index.extra(p.ast).number orelse
                    @floatFromInt(index.extra(p.ast).integer orelse return error.Invalid);
                const unit = unit_index.extra(p.ast).unit orelse return error.Invalid;
                const linear: Linear = switch (unit) {
                    .em => .{ .em = number },
                    .rem => .{ .px = number * 16.0 },
                    else => .{ .px = absoluteLengthPx(unit, number, p.options.viewport_width_px, p.options.viewport_height_px).? },
                };
                return .{ .length = .{ .linear = linear } };
            },
            .simple_block_paren => {
                var inner = index.children(p.ast);
                const v = try p.sum(&inner);
                if (!inner.emptySkipSpaces(p.ast)) return error.Invalid;
                return v;
            },
            .function => return p.function(index),
            else => return error.Invalid,
        }
    }

    fn add(p: *Parser, a: Typed, b: Typed) Error!Typed {
        switch (a) {
            .number => |x| switch (b) {
                .number => |y| return .{ .number = x + y },
                .length => return error.Invalid,
            },
            .length => |x| switch (b) {
                .number => return error.Invalid,
                .length => |y| {
                    if (x == .linear and y == .linear) return .{ .length = .{ .linear = x.linear.add(y.linear) } };
                    const ids = [2]Id{ try p.node(x), try p.node(y) };
                    return .{ .length = .{ .node = try p.table.add(p.allocator, .{ .sum = try p.table.addRange(p.allocator, &ids) }) } };
                },
            },
        }
    }

    fn mul(p: *Parser, a: Typed, b: Typed) Error!Typed {
        switch (a) {
            .number => |x| switch (b) {
                .number => |y| return .{ .number = x * y },
                .length => |y| return p.scaleLength(y, x),
            },
            .length => |x| switch (b) {
                .number => |y| return p.scaleLength(x, y),
                .length => return error.Invalid,
            },
        }
    }

    fn scaleLength(p: *Parser, v: Value, factor: f32) Error!Typed {
        return switch (v) {
            .linear => |l| .{ .length = .{ .linear = l.scale(factor) } },
            .node => |id| .{ .length = .{ .node = try p.table.add(p.allocator, .{ .scale = .{ .child = id, .factor = factor } }) } },
        };
    }

    fn minMax(p: *Parser, comptime op: enum { min, max }, args: []const Typed) Error!Typed {
        switch (args[0]) {
            .number => {
                var result: f32 = args[0].number;
                for (args[1..]) |arg| switch (arg) {
                    .number => |n| result = if (op == .min) @min(result, n) else @max(result, n),
                    .length => return error.Invalid,
                };
                return .{ .number = result };
            },
            .length => {},
        }
        for (args) |arg| if (arg == .number) return error.Invalid;
        // Comparable without context: all linear, in the same single unit.
        fold: {
            var unit: ?Linear.SoleUnit = null;
            for (args) |arg| {
                if (arg.length != .linear) break :fold;
                const u = arg.length.linear.soleUnit() orelse break :fold;
                const zero = arg.length.linear.px == 0 and arg.length.linear.em == 0 and arg.length.linear.percentage == 0;
                if (zero) continue;
                if (unit == null) unit = u else if (unit.? != u) break :fold;
            }
            const u = unit orelse .px;
            var result = args[0].length.linear.component(u);
            for (args[1..]) |arg| {
                const v = arg.length.linear.component(u);
                result = if (op == .min) @min(result, v) else @max(result, v);
            }
            var folded: Linear = .{};
            switch (u) {
                .px => folded.px = result,
                .em => folded.em = result,
                .percentage => folded.percentage = result,
            }
            return .{ .length = .{ .linear = folded } };
        }
        var ids: std.ArrayListUnmanaged(Id) = .empty;
        defer ids.deinit(p.allocator);
        for (args) |arg| try ids.append(p.allocator, try p.node(arg.length));
        const r = try p.table.addRange(p.allocator, ids.items);
        return .{ .length = .{ .node = try p.table.add(p.allocator, if (op == .min) .{ .min = r } else .{ .max = r }) } };
    }

    fn clamp(p: *Parser, args: [3]Typed) Error!Typed {
        if (args[0] == .number and args[1] == .number and args[2] == .number) {
            return .{ .number = @max(args[0].number, @min(args[1].number, args[2].number)) };
        }
        for (args) |arg| if (arg == .number) return error.Invalid;
        // clamp(MIN, VAL, MAX) = max(MIN, min(VAL, MAX)); reuse min/max folding.
        const inner = try p.minMax(.min, &.{ args[1], args[2] });
        return p.minMax(.max, &.{ args[0], inner });
    }

    fn node(p: *Parser, v: Value) Error!Id {
        return switch (v) {
            .node => |id| id,
            .linear => |l| try p.table.add(p.allocator, .{ .linear = l }),
        };
    }
};

/// Parses the math function at `function_index` as a <length> or
/// <length-percentage> (per `options`). Null if it is not a math function
/// or not valid. Nodes of a value that does not fold are added to `table`.
pub fn parseLength(
    ast: Ast,
    source_code: SourceCode,
    table: *Table,
    allocator: Allocator,
    function_index: Ast.Index,
    options: Options,
) Allocator.Error!?Value {
    var p: Parser = .{ .ast = ast, .source_code = source_code, .table = table, .allocator = allocator, .options = options };
    const typed = p.function(function_index) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return null,
    };
    return switch (typed) {
        .number => |n| if (n == 0) .{ .linear = .{} } else null,
        .length => |v| v,
    };
}

/// Whether the function at `index` is one of the math functions.
pub fn isMathFunction(source_code: SourceCode, ast: Ast, index: Ast.Index) bool {
    if (index.tag(ast) != .function) return false;
    return source_code.mapIdentifierValue(index.location(ast), void, &.{
        .{ "calc", {} },
        .{ "min", {} },
        .{ "max", {} },
        .{ "clamp", {} },
    }) != null;
}
