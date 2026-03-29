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
const types = values.types;
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

pub fn @"list-style-type"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"list-style-type") {
    ctx.initDecl(declaration_index);
    const value = values.parse.listStyleType(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .list_style_type = .{ .declared = value } } };
}

pub fn @"list-style"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"list-style") {
    ctx.initDecl(declaration_index);
    // list-style shorthand: <type> || <position> || <image>.
    // We only care about the type component; consume and ignore the rest.
    const value = values.parse.listStyleType(ctx) orelse return null;
    // Consume remaining tokens (position, image) without failing.
    while (!ctx.empty()) {
        _ = ctx.next();
    }
    return .{ .font = .{ .list_style_type = .{ .declared = value } } };
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
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_width = .{ .width = .{ .declared = value } } };
}

pub fn @"min-width"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"min-width") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_width = .{ .min_width = .{ .declared = value } } };
}

pub fn @"max-width"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"max-width") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageNone(ctx, types.MaxSize) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_width = .{ .max_width = .{ .declared = value } } };
}

pub fn height(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.height) {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_height = .{ .height = .{ .declared = value } } };
}

pub fn @"min-height"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"min-height") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_height = .{ .min_height = .{ .declared = value } } };
}

pub fn @"max-height"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"max-height") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentageNone(ctx, types.MaxSize) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .content_height = .{ .max_height = .{ .declared = value } } };
}

pub fn @"padding-left"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-left") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .padding_left = .{ .declared = value } } };
}

pub fn @"padding-right"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-right") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .horizontal_edges = .{ .padding_right = .{ .declared = value } } };
}

pub fn @"padding-top"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-top") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .padding_top = .{ .declared = value } } };
}

pub fn @"padding-bottom"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"padding-bottom") {
    ctx.initDecl(declaration_index);
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .vertical_edges = .{ .padding_bottom = .{ .declared = value } } };
}

pub fn padding(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.padding) {
    ctx.initDecl(declaration_index);
    var sizes: [4]values.groups.SingleValue(types.LengthPercentage) = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        const size = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse break;
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

/// Background shorthand: handles `background: <color>` and `background: linear-gradient(c1, c2)`.
pub fn background(ctx: *Context, declaration_index: Ast.Index, fba: *Fba, urls: zss.values.parse.Urls.Managed) !?ReturnType(.background) {
    // Try url(...) as a background-image layer first.
    // The `background` shorthand can start with a <bg-image> such as url(...).
    // We capture the URL here so it participates in the zss image pipeline.
    ctx.initDecl(declaration_index);
    if (try values.parse.background.image(ctx, urls)) |img| {
        // Allocate a single-element list for this background-image.
        fba.reset();
        const list = try fba.allocator().create([1]types.BackgroundImage);
        list[0] = img;
        return .{ .background = .{ .image = .{ .declared = list[0..1] } } };
    }
    // Try color.
    ctx.initDecl(declaration_index);
    if (values.parse.color(ctx)) |color_value| {
        if (ctx.empty()) {
            return .{ .background_color = .{ .color = .{ .declared = color_value } } };
        }
    }
    // Try linear-gradient().
    ctx.initDecl(declaration_index);
    if (values.parse.linearGradient(ctx)) |grad| {
        if (ctx.empty()) {
            return .{ .background_color = .{
                .gradient = .{ .declared = grad },
            } };
        }
    }
    return null;
}

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


pub fn @"font-family"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"font-family") {
    ctx.initDecl(declaration_index);
    // font-family consumes the entire comma-separated list internally;
    // don't check ctx.empty() since trailing unrecognized entries are skipped.
    const value = values.parse.fontFamily(ctx) orelse return null;
    return .{ .font = .{ .font_family = .{ .declared = value } } };
}

pub fn @"font-size"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"font-size") {
    ctx.initDecl(declaration_index);
    const value = values.parse.fontSize(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .font_size = .{ .declared = value } } };
}

pub fn @"font-weight"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"font-weight") {
    ctx.initDecl(declaration_index);
    const value = values.parse.fontWeight(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .font_weight = .{ .declared = value } } };
}

pub fn @"text-decoration"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"text-decoration") {
    ctx.initDecl(declaration_index);
    const value = values.parse.textDecoration(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .text_decoration = .{ .declared = value } } };
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
    return .{ .font = .{ .vertical_align = .{ .declared = value } } };
}

pub fn visibility(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.visibility) {
    ctx.initDecl(declaration_index);
    const value = values.parse.visibility(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .visibility = .{ .declared = value } } };
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
    const col = border_color orelse types.Color.black;
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
        .border_colors = .{ .top = .{ .declared = parsed.border_color orelse types.Color.black } },
        .border_styles = .{ .top = .{ .declared = parsed.style orelse .none } },
    };
}

pub fn @"border-right"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-right") {
    ctx.initDecl(declaration_index);
    const parsed = parseSingleBorder(ctx);
    if (parsed.bw == null and parsed.style == null and parsed.border_color == null) return null;
    return .{
        .horizontal_edges = .{ .border_right = .{ .declared = parsed.bw orelse .medium } },
        .border_colors = .{ .right = .{ .declared = parsed.border_color orelse types.Color.black } },
        .border_styles = .{ .right = .{ .declared = parsed.style orelse .none } },
    };
}

pub fn @"border-bottom"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-bottom") {
    ctx.initDecl(declaration_index);
    const parsed = parseSingleBorder(ctx);
    if (parsed.bw == null and parsed.style == null and parsed.border_color == null) return null;
    return .{
        .vertical_edges = .{ .border_bottom = .{ .declared = parsed.bw orelse .medium } },
        .border_colors = .{ .bottom = .{ .declared = parsed.border_color orelse types.Color.black } },
        .border_styles = .{ .bottom = .{ .declared = parsed.style orelse .none } },
    };
}

pub fn @"border-left"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-left") {
    ctx.initDecl(declaration_index);
    const parsed = parseSingleBorder(ctx);
    if (parsed.bw == null and parsed.style == null and parsed.border_color == null) return null;
    return .{
        .horizontal_edges = .{ .border_left = .{ .declared = parsed.bw orelse .medium } },
        .border_colors = .{ .left = .{ .declared = parsed.border_color orelse types.Color.black } },
        .border_styles = .{ .left = .{ .declared = parsed.style orelse .none } },
    };
}

pub fn @"border-spacing"(ctx: *Context, declaration_index: Ast.Index) ?ReturnType(.@"border-spacing") {
    ctx.initDecl(declaration_index);
    const value = values.parse.borderSpacing(ctx) orelse return null;
    if (!ctx.empty()) return null;
    return .{ .font = .{ .border_spacing = .{ .declared = value } } };
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