//! Parsers for every supported CSS property in zss.
//! Each one is named exactly the same as the actual CSS property.
//!
//! Be aware that these parsers WILL NOT parse the CSS-wide keywords.
//! There is also no parser for the 'all' property.
//! These cases are instead handled by `zss.values.parse.cssWideKeyword`.

const std = @import("std");
const Fba = std.heap.FixedBufferAllocator;

const zss = @import("../zss.zig");
const max_list_len = zss.Declarations.max_list_len;
const Ast = zss.syntax.Ast;
const ReturnType = zss.property.Property.ParseFnReturnType;

const values = zss.values;
const Environment = zss.Environment;
const types = values.types;
const groups = values.groups;
const Context = values.parse.Context;

fn ParseFnValueType(comptime function: anytype) type {
    const return_type = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const no_error = switch (@typeInfo(return_type)) {
        .error_union => |eu| eu.payload,
        else => return_type,
    };
    const no_optional = switch (@typeInfo(no_error)) {
        .optional => |o| o.child,
        else => no_error,
    };
    return no_optional;
}

fn parseList(ctx: *Context, declaration_index: Ast.Index, fba: *Fba, parse_fn: anytype) !?[]const ParseFnValueType(parse_fn) {
    ctx.initDeclList(declaration_index) orelse return null;

    const Value = ParseFnValueType(parse_fn);
    const list = try fba.allocator().alloc(Value, max_list_len);
    var list_len: usize = 0;

    while (ctx.nextListItem()) |_| {
        const value_or_error = parse_fn(ctx);
        const value_or_null = switch (@typeInfo(@TypeOf(value_or_error))) {
            .error_union => try value_or_error,
            .optional => value_or_error,
            else => comptime unreachable,
        };
        const value = value_or_null orelse break;

        ctx.endListItem() orelse break;
        if (list_len == max_list_len) break;
        list[list_len] = value;
        list_len += 1;
    } else {
        return list[0..list_len];
    }

    return null;
}

pub fn all(ctx: *Context, declaration_index: Ast.Index) ?values.types.CssWideKeyword {
    ctx.initDecl(declaration_index);
    const cwk = values.parse.cssWideKeyword(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return cwk;
}

pub fn display(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.display) {
    ctx.initDecl(declaration_index);
    const value = values.parse.display(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .display = .{ .declared = value } } };
}

pub fn position(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.position) {
    ctx.initDecl(declaration_index);
    const value = values.parse.position(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .position = .{ .declared = value } } };
}

pub fn float(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.float) {
    ctx.initDecl(declaration_index);
    const value = values.parse.float(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .float = .{ .declared = value } } };
}

pub fn clear(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.clear) {
    ctx.initDecl(declaration_index);
    const value = values.parse.clear(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .clear = .{ .declared = value } } };
}

pub fn @"z-index"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"z-index") {
    ctx.initDecl(declaration_index);
    const value = values.parse.zIndex(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .z_index = .{ .z_index = .{ .declared = value } } };
}

pub fn overflow(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.overflow) {
    ctx.initDecl(declaration_index);
    const value = values.parse.overflow(ctx) orelse return null;
    // CSS Overflow L3: `overflow` accepts one or two keywords.
    // `overflow: hidden auto` means overflow-x: hidden, overflow-y: auto.
    // We store a single overflow value; consume and discard a second keyword.
    if (!ctx.empty()) {
        // Try to consume the second keyword; if it's valid, accept the declaration.
        _ = values.parse.overflow(ctx);
        if (!ctx.empty()) return null;
    }
    return .{ .box_style = .{ .overflow = .{ .declared = value } } };
}

pub fn @"flex-direction"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"flex-direction") {
    ctx.initDecl(declaration_index);
    const value = values.parse.flexDirection(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .flex_direction = .{ .declared = value } } };
}

pub fn @"justify-content"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"justify-content") {
    ctx.initDecl(declaration_index);
    const value = values.parse.justifyContent(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .justify_content = .{ .declared = value } } };
}

pub fn @"align-items"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"align-items") {
    ctx.initDecl(declaration_index);
    const value = values.parse.alignItems(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .align_items = .{ .declared = value } } };
}

pub fn @"align-self"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"align-self") {
    ctx.initDecl(declaration_index);
    const value = values.parse.alignSelf(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .align_self = .{ .declared = value } } };
}

pub fn gap(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.gap) {
    ctx.initDecl(declaration_index);
    const row_value = values.parse.gap(ctx) orelse return null;
    // CSS gap shorthand: <row-gap> <column-gap>?
    // If only one value, it applies to both.
    const col_value = values.parse.gap(ctx) orelse row_value;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .column_gap = .{ .declared = col_value }, .row_gap = .{ .declared = row_value } } };
}

pub fn @"flex-grow"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"flex-grow") {
    ctx.initDecl(declaration_index);
    const value = values.parse.flexFactor(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .flex_grow = .{ .declared = value } } };
}

pub fn @"flex-shrink"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"flex-shrink") {
    ctx.initDecl(declaration_index);
    const value = values.parse.flexFactor(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .flex_shrink = .{ .declared = value } } };
}

pub fn @"flex-basis"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"flex-basis") {
    ctx.initDecl(declaration_index);
    const value = values.parse.flexBasis(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .flex_basis = .{ .declared = value } } };
}

/// flex shorthand: flex: <grow> [<shrink>] [<basis>]
/// Common forms:
///   flex: 1      => flex-grow:1, flex-shrink:1, flex-basis:0%
///   flex: auto   => flex-grow:1, flex-shrink:1, flex-basis:auto
///   flex: none   => flex-grow:0, flex-shrink:0, flex-basis:auto
///   flex: 0 1 auto => explicit longhand values
pub fn flex(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.flex) {
    ctx.initDecl(declaration_index);
    // Try 'none' keyword: flex-grow:0, flex-shrink:0, flex-basis:auto
    if (values.parse.keyword(ctx, enum { none }, &.{.{ "none", .none }})) |_| {
        if (!ctx.empty()) return null;
        return .{ .box_style = .{
            .flex_grow = .{ .declared = 0.0 },
            .flex_shrink = .{ .declared = 0.0 },
            .flex_basis = .{ .declared = .auto },
        } };
    }
    // Try 'auto' keyword: flex-grow:1, flex-shrink:1, flex-basis:auto
    if (values.parse.keyword(ctx, enum { auto }, &.{.{ "auto", .auto }})) |_| {
        if (!ctx.empty()) return null;
        return .{ .box_style = .{
            .flex_grow = .{ .declared = 1.0 },
            .flex_shrink = .{ .declared = 1.0 },
            .flex_basis = .{ .declared = .auto },
        } };
    }
    // Try <number> [<number>] [<basis>]
    // When flex specifies a number, flex-basis defaults to 0% (not auto)
    const grow = values.parse.flexFactor(ctx) orelse return null;
    var shrink: f32 = 1.0;
    var basis: values.types.FlexBasis = .{ .percentage = 0.0 };
    // Optional second number (flex-shrink)
    if (values.parse.flexFactor(ctx)) |s| {
        shrink = s;
    }
    // Optional flex-basis
    if (values.parse.flexBasis(ctx)) |b| {
        basis = b;
    }
    if (!ctx.empty()) return null;
    return .{ .box_style = .{
        .flex_grow = .{ .declared = grow },
        .flex_shrink = .{ .declared = shrink },
        .flex_basis = .{ .declared = basis },
    } };
}

pub fn @"flex-wrap"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"flex-wrap") {
    ctx.initDecl(declaration_index);
    const value = values.parse.flexWrap(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .flex_wrap = .{ .declared = value } } };
}

/// flex-flow shorthand: <flex-direction> || <flex-wrap>
/// Values can appear in either order. Missing values get their initial values
/// (direction=row, wrap=nowrap).
pub fn @"flex-flow"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"flex-flow") {
    ctx.initDecl(declaration_index);
    var direction: ?types.FlexDirection = null;
    var wrap: ?types.FlexWrap = null;

    // Parse up to 2 tokens in any order
    var i: u8 = 0;
    while (i < 2) : (i += 1) {
        if (direction == null) {
            if (values.parse.flexDirection(ctx)) |d| {
                direction = d;
                continue;
            }
        }
        if (wrap == null) {
            if (values.parse.flexWrap(ctx)) |w| {
                wrap = w;
                continue;
            }
        }
        break;
    }

    // At least one value must have been parsed
    if (direction == null and wrap == null) return null;
    if (!ctx.empty()) return null;

    return .{ .box_style = .{
        .flex_direction = .{ .declared = direction orelse .row },
        .flex_wrap = .{ .declared = wrap orelse .nowrap },
    } };
}

pub fn @"white-space"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"white-space") {
    ctx.initDecl(declaration_index);
    const value = values.parse.whiteSpace(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .white_space = .{ .declared = value } } };
}

pub fn @"overflow-wrap"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"overflow-wrap") {
    ctx.initDecl(declaration_index);
    const value = values.parse.overflowWrap(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .overflow_wrap = .{ .declared = value } } };
}

pub fn @"list-style-type"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"list-style-type") {
    ctx.initDecl(declaration_index);
    const value = values.parse.listStyleType(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .list_style_type = .{ .declared = value } } };
}

pub fn @"word-wrap"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"word-wrap") {
    ctx.initDecl(declaration_index);
    const value = values.parse.overflowWrap(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .overflow_wrap = .{ .declared = value } } };
}

pub fn @"list-style"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"list-style") {
    ctx.initDecl(declaration_index);
    // list-style shorthand: <type> || <position> || <image> (order-independent).
    var found_type: ?@import("../values/types.zig").ListStyleType = null;
    var tokens_consumed: u8 = 0;
    while (!ctx.empty()) : (tokens_consumed += 1) {
        if (tokens_consumed >= 3) return null;
        if (values.parse.listStyleType(ctx)) |t| {
            if (found_type != null) return null;
            found_type = t;
            continue;
        }
        // Skip position keywords (inside/outside) and url() for image.
        const save = ctx.savePoint();
        if (values.parse.identifier(ctx)) |ident| {
            if (ctx.source_code.mapIdentifierValue(ident, enum { inside, outside }, &.{
                .{ "inside", .inside },
                .{ "outside", .outside },
            })) |_| {
                continue;
            }
        }
        ctx.resetPoint(save);
        _ = ctx.next();
    }
    return .{ .font = .{ .list_style_type = .{ .declared = found_type orelse .none } } };
}

pub fn opacity(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.opacity) {
    ctx.initDecl(declaration_index);
    const value = values.parse.opacity(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .opacity = .{ .opacity = .{ .declared = value } } };
}

pub fn @"box-sizing"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"box-sizing") {
    ctx.initDecl(declaration_index);
    const value = values.parse.boxSizing(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_width = .{ .box_sizing = .{ .declared = value } } };
}

pub fn width(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.width) {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_width = .{ .width = .{ .declared = value } } };
}

pub fn @"min-width"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"min-width") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_width = .{ .min_width = .{ .declared = value } } };
}

pub fn @"max-width"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"max-width") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentageNone(ctx, types.MaxSize) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_width = .{ .max_width = .{ .declared = value } } };
}

pub fn height(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.height) {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_height = .{ .height = .{ .declared = value } } };
}

pub fn @"min-height"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"min-height") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_height = .{ .min_height = .{ .declared = value } } };
}

pub fn @"max-height"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"max-height") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentageNone(ctx, types.MaxSize) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_height = .{ .max_height = .{ .declared = value } } };
}

pub fn @"padding-left"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-left") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .padding_left = .{ .declared = value } } };
}

pub fn @"padding-right"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-right") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .padding_right = .{ .declared = value } } };
}

pub fn @"padding-top"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-top") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .padding_top = .{ .declared = value } } };
}

pub fn @"padding-bottom"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-bottom") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .padding_bottom = .{ .declared = value } } };
}

// Logical-edge aliases. LTR-only: inline-start = left, inline-end = right,
// block-start = top, block-end = bottom. Without these, Tailwind ps-X / pe-X
// classes (used by react.dev's search input, modern utility-CSS sites) lose
// their padding entirely because zss skips unknown property names.
pub fn @"padding-inline-start"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-inline-start") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .padding_left = .{ .declared = value } } };
}

pub fn @"padding-inline-end"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-inline-end") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .padding_right = .{ .declared = value } } };
}

pub fn @"padding-block-start"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-block-start") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .padding_top = .{ .declared = value } } };
}

pub fn @"padding-block-end"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-block-end") {
    ctx.initDecl(declaration_index);
    const value = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .padding_bottom = .{ .declared = value } } };
}

pub fn padding(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.padding) {
    ctx.initDecl(declaration_index);
    var sizes: [4]values.groups.SingleValue(types.LengthPercentage) = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        const size = values.parse.nonNegativeLengthPercentage(ctx, types.LengthPercentage) orelse break;
        sizes[i] = .{ .declared = size };
        num += 1;
    }
    if (!ctx.empty()) return null;
    switch (num) {
        0 => return null,
        1 => return .{
            .horizontal_edges = .{ .padding_left = sizes[0], .padding_right = sizes[0] },
            .vertical_edges = .{ .padding_top = sizes[0], .padding_bottom = sizes[0] },
        },
        2 => return .{
            .horizontal_edges = .{ .padding_left = sizes[1], .padding_right = sizes[1] },
            .vertical_edges = .{ .padding_top = sizes[0], .padding_bottom = sizes[0] },
        },
        3 => return .{
            .horizontal_edges = .{ .padding_left = sizes[1], .padding_right = sizes[1] },
            .vertical_edges = .{ .padding_top = sizes[0], .padding_bottom = sizes[2] },
        },
        4 => return .{
            .horizontal_edges = .{ .padding_left = sizes[3], .padding_right = sizes[1] },
            .vertical_edges = .{ .padding_top = sizes[0], .padding_bottom = sizes[2] },
        },
        else => unreachable,
    }
}

pub fn @"border-left-width"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-left-width") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderWidth(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .border_left = .{ .declared = value } } };
}

pub fn @"border-right-width"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-right-width") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderWidth(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .border_right = .{ .declared = value } } };
}

pub fn @"border-top-width"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-top-width") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderWidth(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .border_top = .{ .declared = value } } };
}

pub fn @"border-bottom-width"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-bottom-width") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderWidth(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .border_bottom = .{ .declared = value } } };
}

pub fn @"border-width"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-width") {
    ctx.initDecl(declaration_index);
    var widths: [4]types.BorderWidth = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        widths[i] = values.parse.borderWidth(ctx) orelse break;
        num += 1;
    }
    if (!ctx.empty()) return null;
    switch (num) {
        0 => return null,
        1 => return .{
            .horizontal_edges = .{ .border_left = .{ .declared = widths[0] }, .border_right = .{ .declared = widths[0] } },
            .vertical_edges = .{ .border_top = .{ .declared = widths[0] }, .border_bottom = .{ .declared = widths[0] } },
        },
        2 => return .{
            .horizontal_edges = .{ .border_left = .{ .declared = widths[1] }, .border_right = .{ .declared = widths[1] } },
            .vertical_edges = .{ .border_top = .{ .declared = widths[0] }, .border_bottom = .{ .declared = widths[0] } },
        },
        3 => return .{
            .horizontal_edges = .{ .border_left = .{ .declared = widths[1] }, .border_right = .{ .declared = widths[1] } },
            .vertical_edges = .{ .border_top = .{ .declared = widths[0] }, .border_bottom = .{ .declared = widths[2] } },
        },
        4 => return .{
            .horizontal_edges = .{ .border_left = .{ .declared = widths[3] }, .border_right = .{ .declared = widths[1] } },
            .vertical_edges = .{ .border_top = .{ .declared = widths[0] }, .border_bottom = .{ .declared = widths[2] } },
        },
        else => unreachable,
    }
}

pub fn @"margin-left"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"margin-left") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .margin_left = .{ .declared = value } } };
}

pub fn @"margin-right"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"margin-right") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .margin_right = .{ .declared = value } } };
}

pub fn @"margin-top"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"margin-top") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .margin_top = .{ .declared = value } } };
}

pub fn @"margin-bottom"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"margin-bottom") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .margin_bottom = .{ .declared = value } } };
}

// Logical-edge margin aliases — see padding-inline-start above for rationale.
pub fn @"margin-inline-start"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"margin-inline-start") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .margin_left = .{ .declared = value } } };
}

pub fn @"margin-inline-end"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"margin-inline-end") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .margin_right = .{ .declared = value } } };
}

pub fn @"margin-block-start"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"margin-block-start") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .margin_top = .{ .declared = value } } };
}

pub fn @"margin-block-end"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"margin-block-end") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .margin_bottom = .{ .declared = value } } };
}

pub fn margin(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.margin) {
    ctx.initDecl(declaration_index);
    var sizes: [4]values.groups.SingleValue(types.LengthPercentageAuto) = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        const size = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse break;
        sizes[i] = .{ .declared = size };
        num += 1;
    }
    if (!ctx.empty()) return null;
    switch (num) {
        0 => return null,
        1 => return .{
            .horizontal_edges = .{ .margin_left = sizes[0], .margin_right = sizes[0] },
            .vertical_edges = .{ .margin_top = sizes[0], .margin_bottom = sizes[0] },
        },
        2 => return .{
            .horizontal_edges = .{ .margin_left = sizes[1], .margin_right = sizes[1] },
            .vertical_edges = .{ .margin_top = sizes[0], .margin_bottom = sizes[0] },
        },
        3 => return .{
            .horizontal_edges = .{ .margin_left = sizes[1], .margin_right = sizes[1] },
            .vertical_edges = .{ .margin_top = sizes[0], .margin_bottom = sizes[2] },
        },
        4 => return .{
            .horizontal_edges = .{ .margin_left = sizes[3], .margin_right = sizes[1] },
            .vertical_edges = .{ .margin_top = sizes[0], .margin_bottom = sizes[2] },
        },
        else => unreachable,
    }
}

pub fn left(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.left) {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .insets = .{ .left = .{ .declared = value } } };
}

pub fn right(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.right) {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .insets = .{ .right = .{ .declared = value } } };
}

pub fn top(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.top) {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .insets = .{ .top = .{ .declared = value } } };
}

/// CSS Logical 1 §4.3 `inset`: one to four values — top, right, bottom, left, the
/// missing ones taken as for `margin`.
pub fn inset(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.inset) {
    ctx.initDecl(declaration_index);
    var sizes: [4]values.groups.SingleValue(types.LengthPercentageAuto) = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        const size = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse break;
        sizes[i] = .{ .declared = size };
        num += 1;
    }
    if (!ctx.empty()) return null;
    const top_value = if (num >= 1) sizes[0] else return null;
    const right_value = if (num >= 2) sizes[1] else top_value;
    const bottom_value = if (num >= 3) sizes[2] else top_value;
    const left_value = if (num >= 4) sizes[3] else right_value;
    return .{ .insets = .{ .top = top_value, .right = right_value, .bottom = bottom_value, .left = left_value } };
}

pub fn bottom(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.bottom) {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .insets = .{ .bottom = .{ .declared = value } } };
}

pub fn @"border-left-color"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-left-color") {
    ctx.initDecl(declaration_index);
    const value = values.parse.color(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .border_colors = .{ .left = .{ .declared = value } } };
}

pub fn @"border-right-color"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-right-color") {
    ctx.initDecl(declaration_index);
    const value = values.parse.color(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .border_colors = .{ .right = .{ .declared = value } } };
}

pub fn @"border-top-color"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-top-color") {
    ctx.initDecl(declaration_index);
    const value = values.parse.color(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .border_colors = .{ .top = .{ .declared = value } } };
}

pub fn @"border-bottom-color"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-bottom-color") {
    ctx.initDecl(declaration_index);
    const value = values.parse.color(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .border_colors = .{ .bottom = .{ .declared = value } } };
}

pub fn @"border-color"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-color") {
    ctx.initDecl(declaration_index);
    var colors: [4]values.groups.SingleValue(types.Color) = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        const col = values.parse.color(ctx) orelse break;
        colors[i] = .{ .declared = col };
        num += 1;
    }
    if (!ctx.empty()) return null;
    switch (num) {
        0 => return null,
        1 => return .{ .border_colors = .{ .left = colors[0], .right = colors[0], .top = colors[0], .bottom = colors[0] } },
        2 => return .{ .border_colors = .{ .left = colors[1], .right = colors[1], .top = colors[0], .bottom = colors[0] } },
        3 => return .{ .border_colors = .{ .left = colors[1], .right = colors[1], .top = colors[0], .bottom = colors[2] } },
        4 => return .{ .border_colors = .{ .left = colors[3], .right = colors[1], .top = colors[0], .bottom = colors[2] } },
        else => unreachable,
    }
}

pub fn @"border-left-style"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-left-style") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderStyle(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .border_styles = .{ .left = .{ .declared = value } } };
}

pub fn @"border-right-style"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-right-style") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderStyle(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .border_styles = .{ .right = .{ .declared = value } } };
}

pub fn @"border-top-style"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-top-style") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderStyle(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .border_styles = .{ .top = .{ .declared = value } } };
}

pub fn @"border-bottom-style"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-bottom-style") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderStyle(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .border_styles = .{ .bottom = .{ .declared = value } } };
}

pub fn @"border-style"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-style") {
    ctx.initDecl(declaration_index);
    var styles: [4]types.BorderStyle = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        styles[i] = values.parse.borderStyle(ctx) orelse break;
        num += 1;
    }
    if (!ctx.empty()) return null;
    switch (num) {
        0 => return null,
        1 => return .{
            .border_styles = .{ .left = .{ .declared = styles[0] }, .right = .{ .declared = styles[0] }, .top = .{ .declared = styles[0] }, .bottom = .{ .declared = styles[0] } },
        },
        2 => return .{
            .border_styles = .{ .left = .{ .declared = styles[1] }, .right = .{ .declared = styles[1] }, .top = .{ .declared = styles[0] }, .bottom = .{ .declared = styles[0] } },
        },
        3 => return .{
            .border_styles = .{ .left = .{ .declared = styles[1] }, .right = .{ .declared = styles[1] }, .top = .{ .declared = styles[0] }, .bottom = .{ .declared = styles[2] } },
        },
        4 => return .{
            .border_styles = .{ .left = .{ .declared = styles[3] }, .right = .{ .declared = styles[1] }, .top = .{ .declared = styles[0] }, .bottom = .{ .declared = styles[2] } },
        },
        else => unreachable,
    }
}


pub fn @"border-radius"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-radius") {
    ctx.initDecl(declaration_index);
    var radii: [4]types.BorderRadius = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        radii[i] = values.parse.borderRadius(ctx) orelse break;
        num += 1;
    }
    if (!ctx.empty()) return null;
    switch (num) {
        0 => return null,
        1 => return .{ .border_radii = .{ .top_left = .{ .declared = radii[0] }, .top_right = .{ .declared = radii[0] }, .bottom_right = .{ .declared = radii[0] }, .bottom_left = .{ .declared = radii[0] } } },
        2 => return .{ .border_radii = .{ .top_left = .{ .declared = radii[0] }, .top_right = .{ .declared = radii[1] }, .bottom_right = .{ .declared = radii[0] }, .bottom_left = .{ .declared = radii[1] } } },
        3 => return .{ .border_radii = .{ .top_left = .{ .declared = radii[0] }, .top_right = .{ .declared = radii[1] }, .bottom_right = .{ .declared = radii[2] }, .bottom_left = .{ .declared = radii[1] } } },
        4 => return .{ .border_radii = .{ .top_left = .{ .declared = radii[0] }, .top_right = .{ .declared = radii[1] }, .bottom_right = .{ .declared = radii[2] }, .bottom_left = .{ .declared = radii[3] } } },
        else => unreachable,
    }
}
pub fn color(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.color) {
    ctx.initDecl(declaration_index);
    const value = values.parse.color(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .color = .{ .color = .{ .declared = value } } };
}

pub fn @"background-color"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"background-color") {
    ctx.initDecl(declaration_index);
    const value = values.parse.color(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .background_color = .{ .color = .{ .declared = value } } };
}

/// CSS Backgrounds 3 §3.10, the `background` shorthand:
///   background = [ <bg-layer> , ]* <final-bg-layer>
///   <bg-layer> = <bg-image> || <bg-position> [ / <bg-size> ]? || <repeat-style> || <attachment> || <box> || <box>
///   <final-bg-layer> = <'background-color'> || <bg-layer>
/// Every sub-property a layer leaves out takes its initial value. One <box> sets
/// background-origin and background-clip, two set origin then clip.
pub fn background(ctx: *Context, declaration_index: Ast.Index, fba: *Fba, urls: zss.values.parse.Urls.Managed) !?ReturnType(.background) {
    ctx.initDeclList(declaration_index) orelse return null;
    const url_save_point = urls.save();
    fba.reset();
    const a = fba.allocator();
    const initial = groups.Background.initial_values;

    const images = try a.alloc(types.BackgroundImage, max_list_len);
    const repeats = try a.alloc(types.BackgroundRepeat, max_list_len);
    const attachments = try a.alloc(types.BackgroundAttachment, max_list_len);
    const positions = try a.alloc(types.BackgroundPosition, max_list_len);
    const origins = try a.alloc(types.BackgroundOrigin, max_list_len);
    const sizes = try a.alloc(types.BackgroundSize, max_list_len);
    const clips = try a.alloc(types.BackgroundClip, max_list_len);
    var n: usize = 0;
    var color_value: ?types.Color = null;

    const valid = layers: {
        while (ctx.nextListItem()) |_| {
            // A color belongs to the final layer only.
            if (n == max_list_len or color_value != null) break :layers false;
            var layer_image: ?types.BackgroundImage = null;
            var layer_position: ?types.BackgroundPosition = null;
            var layer_size: ?types.BackgroundSize = null;
            var layer_repeat: ?types.BackgroundRepeat = null;
            var layer_attachment: ?types.BackgroundAttachment = null;
            var layer_origin: ?types.BackgroundOrigin = null;
            var layer_clip: ?types.BackgroundClip = null;
            var boxes: u2 = 0;
            var components: usize = 0;
            while (true) : (components += 1) {
                if (layer_image == null) if (try values.parse.background.image(ctx, urls)) |v| {
                    layer_image = v;
                    continue;
                };
                if (layer_position == null) if (values.parse.background.position(ctx)) |v| {
                    layer_position = v;
                    if (ctx.next()) |item| {
                        if (item.tag == .token_delim and item.index.extra(ctx.ast).codepoint == '/') {
                            layer_size = values.parse.background.size(ctx) orelse break :layers false;
                        } else {
                            ctx.resetPoint(item.index);
                        }
                    }
                    continue;
                };
                if (layer_repeat == null) if (values.parse.background.repeat(ctx)) |v| {
                    layer_repeat = v;
                    continue;
                };
                if (layer_attachment == null) if (values.parse.background.attachment(ctx)) |v| {
                    layer_attachment = v;
                    continue;
                };
                if (boxes < 2) if (values.parse.background.clip(ctx)) |v| {
                    if (boxes == 0) layer_origin = switch (v) {
                        .border_box => .border_box,
                        .padding_box => .padding_box,
                        .content_box => .content_box,
                    };
                    layer_clip = v;
                    boxes += 1;
                    continue;
                };
                if (color_value == null) if (values.parse.color(ctx)) |v| {
                    color_value = v;
                    continue;
                };
                break;
            }
            if (components == 0) break :layers false;
            ctx.endListItem() orelse break :layers false;
            images[n] = layer_image orelse .none;
            repeats[n] = layer_repeat orelse initial.repeat;
            attachments[n] = layer_attachment orelse initial.attachment;
            positions[n] = layer_position orelse initial.position;
            origins[n] = layer_origin orelse initial.origin;
            sizes[n] = layer_size orelse initial.size;
            clips[n] = layer_clip orelse groups.BackgroundClip.initial_values.clip;
            n += 1;
        }
        break :layers n > 0;
    };
    if (!valid) {
        urls.reset(url_save_point);
        return null;
    }

    return .{
        .background_color = .{
            .color = if (color_value) |c| .{ .declared = c } else .initial,
        },
        .background = .{
            .image = .{ .declared = images[0..n] },
            .repeat = .{ .declared = repeats[0..n] },
            .attachment = .{ .declared = attachments[0..n] },
            .position = .{ .declared = positions[0..n] },
            .origin = .{ .declared = origins[0..n] },
            .size = .{ .declared = sizes[0..n] },
        },
        .background_clip = .{ .clip = .{ .declared = clips[0..n] } },
    };
}

/// `background-image: <bg-image>#`.
pub fn @"background-image"(ctx: *Context, declaration_index: Ast.Index, fba: *Fba, urls: zss.values.parse.Urls.Managed) !?ReturnType(.@"background-image") {
    ctx.initDeclList(declaration_index) orelse return null;
    const url_save_point = urls.save();

    const list = try fba.allocator().create([max_list_len]types.BackgroundImage);
    var list_len: usize = 0;

    while (ctx.nextListItem()) |_| {
        const value = (try values.parse.background.image(ctx, urls)) orelse break;
        ctx.endListItem() orelse break;
        if (list_len == max_list_len) break;
        list[list_len] = value;
        list_len += 1;
    } else {
        return .{ .background = .{ .image = .{ .declared = list[0..list_len] } } };
    }

    urls.reset(url_save_point);
    return null;
}

pub fn @"background-repeat"(ctx: *Context, declaration_index: Ast.Index, fba: *Fba) !?ReturnType(.@"background-repeat") {
    const list = (try parseList(ctx, declaration_index, fba, values.parse.background.repeat)) orelse return null;
    return .{ .background = .{ .repeat = .{ .declared = list } } };
}

pub fn @"background-attachment"(ctx: *Context, declaration_index: Ast.Index, fba: *Fba) !?ReturnType(.@"background-attachment") {
    const list = (try parseList(ctx, declaration_index, fba, values.parse.background.attachment)) orelse return null;
    return .{ .background = .{ .attachment = .{ .declared = list } } };
}

pub fn @"background-position"(ctx: *Context, declaration_index: Ast.Index, fba: *Fba) !?ReturnType(.@"background-position") {
    const list = (try parseList(ctx, declaration_index, fba, values.parse.background.position)) orelse return null;
    return .{ .background = .{ .position = .{ .declared = list } } };
}

pub fn @"background-clip"(ctx: *Context, declaration_index: Ast.Index, fba: *Fba) !?ReturnType(.@"background-clip") {
    const list = (try parseList(ctx, declaration_index, fba, values.parse.background.clip)) orelse return null;
    return .{ .background_clip = .{ .clip = .{ .declared = list } } };
}

pub fn @"background-origin"(ctx: *Context, declaration_index: Ast.Index, fba: *Fba) !?ReturnType(.@"background-origin") {
    const list = (try parseList(ctx, declaration_index, fba, values.parse.background.origin)) orelse return null;
    return .{ .background = .{ .origin = .{ .declared = list } } };
}

pub fn @"background-size"(ctx: *Context, declaration_index: Ast.Index, fba: *Fba) !?ReturnType(.@"background-size") {
    const list = (try parseList(ctx, declaration_index, fba, values.parse.background.size)) orelse return null;
    return .{ .background = .{ .size = .{ .declared = list } } };
}


/// The `font` shorthand (CSS Fonts 4 §2.9):
///   [ [ <'font-style'> || <font-variant-css2> || <font-weight-absolute> ||
///       <font-width-css3> ]? <'font-size'> [ / <'line-height'> ]? <'font-family'># ]
///   | <system-family-name>
/// Every longhand is reset: those not given take their initial values
/// (line-height `normal`). `normal` before the size stands for any of the
/// four optional parts not otherwise given, and each part appears at most
/// once. `bolder`/`lighter` are accepted as in Chrome and Firefox. `small-caps` (font-variant) and the font-width keywords are
/// parse-only: zss has no font-variant or font-width (font-stretch)
/// properties, so they reset nothing it tracks. The angle of
/// `oblique <angle>` is parse-only too (zss slants by a fixed amount). The
/// system family names (caption, icon, ...) are not supported: the
/// declaration is invalid here.
pub fn font(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.font) {
    ctx.initDecl(declaration_index);

    var font_style: ?types.FontStyle = null;
    var font_weight: ?types.FontWeight = null;
    var variant_given = false;
    var width_given = false;
    var parts: u3 = 0;
    while (parts < 4) {
        const save = ctx.savePoint();
        if (values.parse.keyword(ctx, void, &.{.{ "normal", {} }})) |_| {
            parts += 1;
            continue;
        }
        if (font_style == null) {
            if (values.parse.fontStyle(ctx)) |style| {
                font_style = style;
                if (style == .oblique) _ = values.parse.angle(ctx);
                parts += 1;
                continue;
            }
        }
        if (!variant_given) {
            if (values.parse.keyword(ctx, void, &.{.{ "small-caps", {} }})) |_| {
                variant_given = true;
                parts += 1;
                continue;
            }
        }
        if (font_weight == null) {
            // The grammar has <font-weight-absolute>, but engines (Chrome,
            // Firefox) accept bolder/lighter here too; so does zss.
            if (values.parse.fontWeight(ctx)) |weight| {
                font_weight = weight;
                parts += 1;
                continue;
            }
        }
        if (!width_given) {
            if (values.parse.keyword(ctx, void, &.{
                .{ "ultra-condensed", {} }, .{ "extra-condensed", {} }, .{ "condensed", {} },
                .{ "semi-condensed", {} },  .{ "semi-expanded", {} },   .{ "expanded", {} },
                .{ "extra-expanded", {} },  .{ "ultra-expanded", {} },
            })) |_| {
                width_given = true;
                parts += 1;
                continue;
            }
        }
        ctx.resetPoint(save);
        break;
    }

    const size = values.parse.fontSize(ctx) orelse return null;

    var line_height: types.LineHeight = .normal;
    {
        const save = ctx.savePoint();
        if (ctx.next()) |item| {
            if (item.tag == .token_delim and item.index.extra(ctx.ast).codepoint == '/') {
                line_height = values.parse.lineHeight(ctx) orelse return null;
            } else {
                ctx.resetPoint(save);
            }
        }
    }

    const generic_monospace = values.parse.familyIsGenericMonospace(ctx);
    const family = (try values.parse.fontFamily(ctx, env)) orelse return null;

    return .{ .font = .{
        .font_family = .{ .declared = family.family },
        .font_family_list = .{ .declared = family.list },
        .generic_monospace = .{ .declared = generic_monospace },
        .font_size = .{ .declared = size },
        .font_size_info = .{ .declared = values.parse.fontSizeInfo(size) },
        .font_weight = .{ .declared = font_weight orelse .normal },
        .font_style = .{ .declared = font_style orelse .normal },
        .line_height = .{ .declared = line_height },
    } };
}

pub fn @"font-family"(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.@"font-family") {
    ctx.initDecl(declaration_index);
    const generic_monospace = values.parse.familyIsGenericMonospace(ctx);
    const value = (try values.parse.fontFamily(ctx, env)) orelse return null;
    return .{ .font = .{
        .font_family = .{ .declared = value.family },
        .font_family_list = .{ .declared = value.list },
        .generic_monospace = .{ .declared = generic_monospace },
    } };
}

pub fn @"font-size"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"font-size") {
    ctx.initDecl(declaration_index);
    const value = values.parse.fontSize(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .font_size = .{ .declared = value }, .font_size_info = .{ .declared = values.parse.fontSizeInfo(value) } } };
}

pub fn @"font-weight"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"font-weight") {
    ctx.initDecl(declaration_index);
    const value = values.parse.fontWeight(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .font_weight = .{ .declared = value } } };
}

pub fn @"font-style"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"font-style") {
    ctx.initDecl(declaration_index);
    const value = values.parse.fontStyle(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .font_style = .{ .declared = value } } };
}

pub fn @"text-decoration"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"text-decoration") {
    ctx.initDecl(declaration_index);
    const value = values.parse.textDecoration(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .text_decoration = .{ .declared = value } } };
}

pub fn @"text-transform"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"text-transform") {
    ctx.initDecl(declaration_index);
    const value = values.parse.textTransform(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .text_transform = .{ .declared = value } } };
}

pub fn @"text-align"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"text-align") {
    ctx.initDecl(declaration_index);
    const value = values.parse.textAlign(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .text_align = .{ .declared = value } } };
}

pub fn @"vertical-align"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"vertical-align") {
    ctx.initDecl(declaration_index);
    const value = values.parse.verticalAlign(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .vertical_align = .{ .declared = value } } };
}

pub fn visibility(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.visibility) {
    ctx.initDecl(declaration_index);
    const value = values.parse.visibility(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .visibility = .{ .declared = value } } };
}

pub fn @"user-select"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"user-select") {
    ctx.initDecl(declaration_index);
    const value = values.parse.userSelect(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .user_select = .{ .declared = value } } };
}

pub fn @"pointer-events"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"pointer-events") {
    ctx.initDecl(declaration_index);
    const value = values.parse.pointerEvents(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .pointer_events = .{ .declared = value } } };
}

pub fn @"-webkit-user-select"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"-webkit-user-select") {
    ctx.initDecl(declaration_index);
    const value = values.parse.userSelect(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .user_select = .{ .declared = value } } };
}

pub fn cursor(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.cursor) {
    ctx.initDecl(declaration_index);
    const value = values.parse.cursor(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .cursor = .{ .declared = value } } };
}

/// Parse `border: <width> <style> <color>` shorthand.
/// Any of the three values may be omitted; order doesn't matter.
pub fn border(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.border) {
    ctx.initDecl(declaration_index);
    var bw: ?types.BorderWidth = null;
    var style: ?types.BorderStyle = null;
    var border_color: ?types.Color = null;
    // Parse up to 3 values in any order
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        if (ctx.empty()) break;
        if (bw == null) {
            if (values.parse.borderWidth(ctx)) |w| {
                bw = w;
                continue;
            }
        }
        if (style == null) {
            if (values.parse.borderStyle(ctx)) |s| {
                style = s;
                continue;
            }
        }
        if (border_color == null) {
            if (values.parse.color(ctx)) |col| {
                border_color = col;
                continue;
            }
        }
        break; // Unknown token
    }
    if (bw == null and style == null and border_color == null) return null;
    // Apply defaults for omitted values
    const w = bw orelse .medium;
    const s = style orelse .none;
    const col = border_color orelse .current_color;
    return .{
        .horizontal_edges = .{
            .border_left = .{ .declared = w },
            .border_right = .{ .declared = w },
        },
        .vertical_edges = .{
            .border_top = .{ .declared = w },
            .border_bottom = .{ .declared = w },
        },
        .border_colors = .{
            .top = .{ .declared = col },
            .right = .{ .declared = col },
            .bottom = .{ .declared = col },
            .left = .{ .declared = col },
        },
        .border_styles = .{
            .top = .{ .declared = s },
            .right = .{ .declared = s },
            .bottom = .{ .declared = s },
            .left = .{ .declared = s },
        },
    };
}

/// Parse `border-top: <width> <style> <color>` (single-side border shorthand).
fn parseSingleBorder(ctx: *Context) struct {
    bw: ?types.BorderWidth,
    style: ?types.BorderStyle,
    border_color: ?types.Color,
} {
    var bw: ?types.BorderWidth = null;
    var style: ?types.BorderStyle = null;
    var border_color: ?types.Color = null;
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        if (ctx.empty()) break;
        if (bw == null) {
            if (values.parse.borderWidth(ctx)) |w| {
                bw = w;
                continue;
            }
        }
        if (style == null) {
            if (values.parse.borderStyle(ctx)) |s| {
                style = s;
                continue;
            }
        }
        if (border_color == null) {
            if (values.parse.color(ctx)) |col| {
                border_color = col;
                continue;
            }
        }
        break;
    }
    return .{ .bw = bw, .style = style, .border_color = border_color };
}

pub fn @"border-top"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-top") {
    ctx.initDecl(declaration_index);
    const parsed = parseSingleBorder(ctx);
    if (parsed.bw == null and parsed.style == null and parsed.border_color == null) return null;
    return .{
        .vertical_edges = .{ .border_top = .{ .declared = parsed.bw orelse .medium } },
        .border_colors = .{ .top = .{ .declared = parsed.border_color orelse .current_color } },
        .border_styles = .{ .top = .{ .declared = parsed.style orelse .none } },
    };
}

pub fn @"border-right"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-right") {
    ctx.initDecl(declaration_index);
    const parsed = parseSingleBorder(ctx);
    if (parsed.bw == null and parsed.style == null and parsed.border_color == null) return null;
    return .{
        .horizontal_edges = .{ .border_right = .{ .declared = parsed.bw orelse .medium } },
        .border_colors = .{ .right = .{ .declared = parsed.border_color orelse .current_color } },
        .border_styles = .{ .right = .{ .declared = parsed.style orelse .none } },
    };
}

pub fn @"border-bottom"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-bottom") {
    ctx.initDecl(declaration_index);
    const parsed = parseSingleBorder(ctx);
    if (parsed.bw == null and parsed.style == null and parsed.border_color == null) return null;
    return .{
        .vertical_edges = .{ .border_bottom = .{ .declared = parsed.bw orelse .medium } },
        .border_colors = .{ .bottom = .{ .declared = parsed.border_color orelse .current_color } },
        .border_styles = .{ .bottom = .{ .declared = parsed.style orelse .none } },
    };
}

pub fn @"border-left"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-left") {
    ctx.initDecl(declaration_index);
    const parsed = parseSingleBorder(ctx);
    if (parsed.bw == null and parsed.style == null and parsed.border_color == null) return null;
    return .{
        .horizontal_edges = .{ .border_left = .{ .declared = parsed.bw orelse .medium } },
        .border_colors = .{ .left = .{ .declared = parsed.border_color orelse .current_color } },
        .border_styles = .{ .left = .{ .declared = parsed.style orelse .none } },
    };
}

pub fn @"border-spacing"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-spacing") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderSpacing(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .border_spacing = .{ .declared = value } } };
}

pub fn @"border-collapse"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-collapse") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderCollapse(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .border_collapse = .{ .declared = value } } };
}

pub fn @"line-height"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"line-height") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lineHeight(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .line_height = .{ .declared = value } } };
}

// --- CSS Grid property parsers ---

pub fn @"grid-template-columns"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"grid-template-columns") {
    ctx.initDecl(declaration_index);
    const value = values.parse.gridTrackList(ctx) orelse return null;
    return .{ .grid_template = .{ .columns = .{ .declared = value } } };
}

pub fn @"grid-template-rows"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"grid-template-rows") {
    ctx.initDecl(declaration_index);
    const value = values.parse.gridTrackList(ctx) orelse return null;
    return .{ .grid_template = .{ .rows = .{ .declared = value } } };
}

pub fn @"grid-template-areas"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"grid-template-areas") {
    ctx.initDecl(declaration_index);
    const value = values.parse.gridAreas(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .grid_template = .{ .areas = .{ .declared = value } } };
}

/// grid-template shorthand: <rows> / <columns> with optional area strings.
/// For now, parse the track lists separated by '/' and consume area strings if present.
pub fn @"grid-template"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"grid-template") {
    ctx.initDecl(declaration_index);
    // Try parsing: <row-tracks> / <column-tracks>
    // Also handle area strings interleaved with row tracks.
    const result = values.parse.gridTemplate(ctx) orelse return null;
    // Only set grid-template-areas if the shorthand actually contained area strings.
    // Per CSS spec, `grid-template: <rows> / <columns>` (without area strings)
    // resets grid-template-areas. But our cascade uses reverse-order first-write-wins,
    // so setting areas to empty here would overwrite a separately-declared
    // grid-template-areas that was parsed first. Only declare areas when present.
    const has_areas = result.areas.count > 0;
    return .{ .grid_template = .{
        .rows = .{ .declared = result.rows },
        .columns = .{ .declared = result.columns },
        .areas = if (has_areas) .{ .declared = result.areas } else .undeclared,
    } };
}

pub fn @"grid-area"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"grid-area") {
    ctx.initDecl(declaration_index);
    const value = values.parse.gridAreaPlacement(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .grid_area = .{ .declared = value } } };
}

pub fn @"column-gap"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"column-gap") {
    ctx.initDecl(declaration_index);
    const value = values.parse.gap(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .column_gap = .{ .declared = value } } };
}

pub fn @"row-gap"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"row-gap") {
    ctx.initDecl(declaration_index);
    const value = values.parse.gap(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .box_style = .{ .row_gap = .{ .declared = value } } };
}

pub fn content(ctx: *Context, declaration_index: Ast.Index, env: *@import("../zss.zig").Environment) !?ReturnType(.content) {
    ctx.initDecl(declaration_index);
    // Try keywords: normal, none
    if (values.parse.keyword(ctx, enum { normal, none }, &.{
        .{ "normal", .normal },
        .{ "none", .none },
    })) |kw| {
        if (!ctx.empty()) return null;
        return .{ .generated_content = .{ .content = .{ .declared = switch (kw) {
            .normal => .normal,
            .none => .none,
        } } } };
    }
    // Try string (content: '' or content: 'text')
    if (values.parse.string(ctx)) |loc| {
        if (!ctx.empty()) return null;
        const text_id = try env.addTextFromStringToken(loc, ctx.source_code);
        // addTextFromStringToken returns TextId.empty_string (sentinel 0) for ''
        if (text_id == @import("../zss.zig").Environment.TextId.empty_string) {
            return .{ .generated_content = .{ .content = .{ .declared = .empty_string } } };
        }
        return .{ .generated_content = .{ .content = .{ .declared = .{ .string = text_id } } } };
    }
    return null;
}
// ---------------------------------------------------------------------------
// CSS Animations 1 §4: the animation-* properties. Each longhand is a
// comma-separated list; its computed value is kept as the canonical
// serialization of that list (`types.AnimationValue`), which is also what
// getComputedStyle returns. Not supported, so such declarations are invalid:
// math functions in times and counts, the `linear()` easing function
// (CSS Easing 2), animation-timeline / animation-composition / animation-range.

const AnimationText = std.ArrayListUnmanaged(u8);
const AnimationPart = enum { name, duration, timing_function, delay, iteration_count, direction, fill_mode, play_state };

fn animationNumber(ctx: *Context) ?f32 {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_integer => if (item.index.extra(ctx.ast).integer) |i| return @floatFromInt(i),
        .token_number => if (item.index.extra(ctx.ast).number) |n| return n,
        else => {},
    }
    ctx.resetPoint(item.index);
    return null;
}

/// <time>, in seconds.
fn animationTime(ctx: *Context) ?f32 {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_dimension) {
        var children = item.index.children(ctx.ast);
        if (children.nextSkipSpaces(ctx.ast)) |unit_index| {
            if (item.index.extra(ctx.ast).number) |number| {
                const factor: ?f32 = ctx.source_code.mapIdentifierValue(unit_index.location(ctx.ast), f32, &.{
                    .{ "s", 1.0 },
                    .{ "ms", 1000.0 },
                });
                if (factor) |f| return number / f;
            }
        }
    }
    ctx.resetPoint(item.index);
    return null;
}

fn animationPutNumber(env: *Environment, out: *AnimationText, value: f32) !void {
    var buffer: [64]u8 = undefined;
    // Shortest text that reads back as the same f32; f64 formatting would show
    // the f32's rounding (0.3 -> 0.30000001192092896).
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try out.appendSlice(env.allocator, text);
}

/// <easing-function> (CSS Easing 1): the keywords, cubic-bezier(), steps().
fn animationEasing(ctx: *Context, env: *Environment, out: *AnimationText) !?void {
    const Keyword = enum { linear, ease, @"ease-in", @"ease-out", @"ease-in-out", @"step-start", @"step-end" };
    if (values.parse.keyword(ctx, Keyword, &.{
        .{ "linear", .linear },
        .{ "ease", .ease },
        .{ "ease-in", .@"ease-in" },
        .{ "ease-out", .@"ease-out" },
        .{ "ease-in-out", .@"ease-in-out" },
        .{ "step-start", .@"step-start" },
        .{ "step-end", .@"step-end" },
    })) |kw| {
        try out.appendSlice(env.allocator, switch (kw) {
            .@"step-start" => "steps(1, start)",
            .@"step-end" => "steps(1)",
            else => @tagName(kw),
        });
        return;
    }
    const item = ctx.next() orelse return null;
    if (item.tag != .function) {
        ctx.resetPoint(item.index);
        return null;
    }
    const Function = enum { @"cubic-bezier", steps };
    const function = ctx.source_code.mapIdentifierValue(item.index.location(ctx.ast), Function, &.{
        .{ "cubic-bezier", .@"cubic-bezier" },
        .{ "steps", .steps },
    }) orelse {
        ctx.resetPoint(item.index);
        return null;
    };
    const state = ctx.enterSequence(item.index);
    var ok = false;
    defer {
        ctx.resetState(state);
        if (!ok) ctx.resetPoint(item.index);
    }
    switch (function) {
        .@"cubic-bezier" => {
            var numbers: [4]f32 = undefined;
            for (&numbers, 0..) |*number, i| {
                if (i > 0) {
                    const comma = ctx.next() orelse return null;
                    if (comma.tag != .token_comma) return null;
                }
                number.* = animationNumber(ctx) orelse return null;
            }
            if (!ctx.empty()) return null;
            // The x coordinates are in [0, 1].
            if (numbers[0] < 0 or numbers[0] > 1 or numbers[2] < 0 or numbers[2] > 1) return null;
            try out.appendSlice(env.allocator, "cubic-bezier(");
            for (numbers, 0..) |number, i| {
                if (i > 0) try out.appendSlice(env.allocator, ", ");
                try animationPutNumber(env, out, number);
            }
            try out.append(env.allocator, ')');
        },
        .steps => {
            const count = values.parse.integer(ctx) orelse return null;
            const Position = enum { @"jump-start", @"jump-end", @"jump-none", @"jump-both", start, end };
            var step_position: Position = .end;
            if (ctx.next()) |comma| {
                if (comma.tag != .token_comma) return null;
                step_position = values.parse.keyword(ctx, Position, &.{
                    .{ "jump-start", .@"jump-start" },
                    .{ "jump-end", .@"jump-end" },
                    .{ "jump-none", .@"jump-none" },
                    .{ "jump-both", .@"jump-both" },
                    .{ "start", .start },
                    .{ "end", .end },
                }) orelse return null;
            }
            if (!ctx.empty()) return null;
            if (count < 1 or (step_position == .@"jump-none" and count < 2)) return null;
            var buffer: [32]u8 = undefined;
            try out.appendSlice(env.allocator, std.fmt.bufPrint(&buffer, "steps({d}", .{count}) catch unreachable);
            switch (step_position) {
                .end, .@"jump-end" => {},
                .@"jump-start" => try out.appendSlice(env.allocator, ", jump-start"),
                else => {
                    try out.appendSlice(env.allocator, ", ");
                    try out.appendSlice(env.allocator, @tagName(step_position));
                },
            }
            try out.append(env.allocator, ')');
        },
    }
    ok = true;
}

/// [ none | <keyframes-name> ]: `none`, a <custom-ident> (not a CSS-wide
/// keyword, not `default`) or a <string>.
fn animationNameValue(ctx: *Context, env: *Environment, out: *AnimationText) !?void {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_ident => {
            const location = item.index.location(ctx.ast);
            const Reserved = enum { none, reserved };
            if (ctx.source_code.mapIdentifierValue(location, Reserved, &.{
                .{ "none", .none },
                .{ "initial", .reserved },
                .{ "inherit", .reserved },
                .{ "unset", .reserved },
                .{ "revert", .reserved },
                .{ "revert-layer", .reserved },
                .{ "default", .reserved },
            })) |reserved| switch (reserved) {
                .none => {
                    try out.appendSlice(env.allocator, "none");
                    return;
                },
                .reserved => {
                    ctx.resetPoint(item.index);
                    return null;
                },
            };
            const name = try ctx.source_code.copyIdentifier(location, .{ .allocator = env.allocator });
            defer env.allocator.free(name);
            try out.appendSlice(env.allocator, name);
        },
        .token_string => {
            const name = try ctx.source_code.copyString(item.index.location(ctx.ast), .{ .allocator = env.allocator });
            defer env.allocator.free(name);
            // A string names the keyframes as an identifier would; only names an
            // identifier cannot spell stay quoted.
            const plain = name.len > 0 and !std.ascii.eqlIgnoreCase(name, "none") and for (name) |ch| {
                if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch >= 0x80)) break false;
            } else !std.ascii.isDigit(name[0]);
            if (plain) {
                try out.appendSlice(env.allocator, name);
            } else {
                try out.append(env.allocator, '"');
                for (name) |ch| {
                    if (ch == '"' or ch == '\\') try out.append(env.allocator, '\\');
                    try out.append(env.allocator, ch);
                }
                try out.append(env.allocator, '"');
            }
        },
        else => {
            ctx.resetPoint(item.index);
            return null;
        },
    }
}

fn animationKeyword(ctx: *Context, env: *Environment, out: *AnimationText, comptime names: []const []const u8) !?void {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_ident) {
        inline for (names) |name| {
            if (ctx.source_code.mapIdentifierValue(item.index.location(ctx.ast), void, &.{.{ name, {} }}) != null) {
                try out.appendSlice(env.allocator, name);
                return;
            }
        }
    }
    ctx.resetPoint(item.index);
    return null;
}

const animation_directions: []const []const u8 = &.{ "normal", "reverse", "alternate-reverse", "alternate" };
const animation_fill_modes: []const []const u8 = &.{ "none", "forwards", "backwards", "both" };
const animation_play_states: []const []const u8 = &.{ "running", "paused" };

/// One item of the list of the longhand `part`, serialized onto `out`.
fn animationComponent(ctx: *Context, env: *Environment, out: *AnimationText, comptime part: AnimationPart) !?void {
    switch (part) {
        .name => return animationNameValue(ctx, env, out),
        .duration => {
            const time = animationTime(ctx) orelse return null;
            if (time < 0) return null;
            try animationPutNumber(env, out, time);
            try out.append(env.allocator, 's');
        },
        .delay => {
            const time = animationTime(ctx) orelse return null;
            try animationPutNumber(env, out, time);
            try out.append(env.allocator, 's');
        },
        .timing_function => return animationEasing(ctx, env, out),
        .iteration_count => {
            if ((try animationKeyword(ctx, env, out, &.{"infinite"})) != null) return;
            const save = ctx.savePoint();
            const count = animationNumber(ctx) orelse return null;
            if (count < 0) {
                ctx.resetPoint(save);
                return null;
            }
            try animationPutNumber(env, out, count);
        },
        .direction => return animationKeyword(ctx, env, out, animation_directions),
        .fill_mode => return animationKeyword(ctx, env, out, animation_fill_modes),
        .play_state => return animationKeyword(ctx, env, out, animation_play_states),
    }
}

fn animationLonghand(ctx: *Context, declaration_index: Ast.Index, env: *Environment, comptime part: AnimationPart) !?values.types.AnimationValue {
    ctx.initDeclList(declaration_index) orelse return null;
    var out: AnimationText = .empty;
    defer out.deinit(env.allocator);
    var count: usize = 0;
    while (ctx.nextListItem()) |_| {
        if (count > 0) try out.appendSlice(env.allocator, ", ");
        (try animationComponent(ctx, env, &out, part)) orelse return null;
        ctx.endListItem() orelse return null;
        count += 1;
    }
    if (count == 0) return null;
    return try env.internAnimationValue(out.items);
}

pub fn @"animation-name"(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.@"animation-name") {
    const value = (try animationLonghand(ctx, declaration_index, env, .name)) orelse return null;
    return .{ .animation = .{ .name = .{ .declared = value } } };
}

pub fn @"animation-duration"(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.@"animation-duration") {
    const value = (try animationLonghand(ctx, declaration_index, env, .duration)) orelse return null;
    return .{ .animation = .{ .duration = .{ .declared = value } } };
}

pub fn @"animation-timing-function"(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.@"animation-timing-function") {
    const value = (try animationLonghand(ctx, declaration_index, env, .timing_function)) orelse return null;
    return .{ .animation = .{ .timing_function = .{ .declared = value } } };
}

pub fn @"animation-delay"(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.@"animation-delay") {
    const value = (try animationLonghand(ctx, declaration_index, env, .delay)) orelse return null;
    return .{ .animation = .{ .delay = .{ .declared = value } } };
}

pub fn @"animation-iteration-count"(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.@"animation-iteration-count") {
    const value = (try animationLonghand(ctx, declaration_index, env, .iteration_count)) orelse return null;
    return .{ .animation = .{ .iteration_count = .{ .declared = value } } };
}

pub fn @"animation-direction"(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.@"animation-direction") {
    const value = (try animationLonghand(ctx, declaration_index, env, .direction)) orelse return null;
    return .{ .animation = .{ .direction = .{ .declared = value } } };
}

pub fn @"animation-fill-mode"(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.@"animation-fill-mode") {
    const value = (try animationLonghand(ctx, declaration_index, env, .fill_mode)) orelse return null;
    return .{ .animation = .{ .fill_mode = .{ .declared = value } } };
}

pub fn @"animation-play-state"(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.@"animation-play-state") {
    const value = (try animationLonghand(ctx, declaration_index, env, .play_state)) orelse return null;
    return .{ .animation = .{ .play_state = .{ .declared = value } } };
}

/// The `animation` shorthand (CSS Animations 1 §4.9): <single-animation>#, with
/// <single-animation> = <time> || <easing-function> || <time> ||
///   <single-animation-iteration-count> || <single-animation-direction> ||
///   <single-animation-fill-mode> || <single-animation-play-state> ||
///   [ none | <keyframes-name> ]
/// The first <time> is the duration, the second the delay; a keyword that is
/// valid for another longhand goes to that longhand, not to the name. Every
/// longhand is set: those not given take their initial values.
pub fn animation(ctx: *Context, declaration_index: Ast.Index, env: *Environment) !?ReturnType(.animation) {
    ctx.initDeclList(declaration_index) orelse return null;
    const parts = comptime std.enums.values(AnimationPart);
    var lists: [parts.len]AnimationText = @splat(.empty);
    defer for (&lists) |*list| list.deinit(env.allocator);
    const initial_texts = values.groups.Animation.initial_texts;

    var count: usize = 0;
    while (ctx.nextListItem()) |_| {
        var item: [parts.len]AnimationText = @splat(.empty);
        defer for (&item) |*text| text.deinit(env.allocator);
        var seen: [parts.len]bool = @splat(false);
        var any = false;
        // Each round takes one component: the longhands in the order that
        // settles the ambiguities (times: duration then delay; the name last).
        const order = [_]AnimationPart{ .duration, .delay, .timing_function, .iteration_count, .direction, .fill_mode, .play_state, .name };
        round: while (!ctx.empty()) {
            inline for (order) |part| {
                const i = @intFromEnum(part);
                if (!seen[i]) {
                    if ((try animationComponent(ctx, env, &item[i], part)) != null) {
                        seen[i] = true;
                        any = true;
                        continue :round;
                    }
                    item[i].clearRetainingCapacity();
                }
            }
            return null;
        }
        if (!any) return null;
        ctx.endListItem() orelse return null;
        inline for (parts) |part| {
            const i = @intFromEnum(part);
            if (count > 0) try lists[i].appendSlice(env.allocator, ", ");
            try lists[i].appendSlice(env.allocator, if (seen[i]) item[i].items else @field(initial_texts, @tagName(part)));
        }
        count += 1;
    }
    if (count == 0) return null;
    var ids: [parts.len]values.types.AnimationValue = undefined;
    for (&ids, lists) |*id, list| id.* = try env.internAnimationValue(list.items);
    return .{ .animation = .{
        .name = .{ .declared = ids[@intFromEnum(AnimationPart.name)] },
        .duration = .{ .declared = ids[@intFromEnum(AnimationPart.duration)] },
        .timing_function = .{ .declared = ids[@intFromEnum(AnimationPart.timing_function)] },
        .delay = .{ .declared = ids[@intFromEnum(AnimationPart.delay)] },
        .iteration_count = .{ .declared = ids[@intFromEnum(AnimationPart.iteration_count)] },
        .direction = .{ .declared = ids[@intFromEnum(AnimationPart.direction)] },
        .fill_mode = .{ .declared = ids[@intFromEnum(AnimationPart.fill_mode)] },
        .play_state = .{ .declared = ids[@intFromEnum(AnimationPart.play_state)] },
    } };
}
