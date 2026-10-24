const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const NodeId = zss.Environment.NodeId;
const StyleComputer = zss.Layout.StyleComputer;
const Unit = zss.math.Unit;
const selectors = zss.selectors;

const BoxGen = zss.Layout.BoxGen;
const BlockComputedSizes = BoxGen.BlockComputedSizes;
const BlockUsedSizes = BoxGen.BlockUsedSizes;
const SctBuilder = BoxGen.StackingContextTreeBuilder;
const SizeMode = BoxGen.SizeMode;
const BlockInfo = BoxGen.BlockInfo;

const solve = @import("./solve.zig");
const replaced = @import("./replaced.zig");
const @"inline" = @import("./inline.zig");
const form_controls = @import("./form_controls.zig");
const relayout = @import("./relayout.zig");
const intrinsic = @import("./intrinsic.zig");

const groups = zss.values.groups;
const SpecifiedValues = groups.Tag.SpecifiedValues;
const ComputedValues = groups.Tag.ComputedValues;

const BoxTree = zss.BoxTree;
const BoxStyle = BoxTree.BoxStyle;
const Subtree = BoxTree.Subtree;

pub fn beginMode(box_gen: *BoxGen) !void {
    const allocator = box_gen.getLayout().allocator;
    try box_gen.bfc_stack.push(allocator, 1);
}

fn endMode(box_gen: *BoxGen) void {
    const depth = box_gen.bfc_stack.pop();
    assert(depth == 0);
}

pub fn blockElement(box_gen: *BoxGen, node: NodeId, inner_block: BoxStyle.InnerBlock, position: BoxStyle.Position) !void {
    const computer = &box_gen.getLayout().computer;
    switch (inner_block) {
        .flow, .flex, .grid => {
            const containing_block_size = box_gen.containingBlockSize();
            const parent_is_flex_row = if (box_gen.stacks.block_info.top) |parent_info|
                parent_info.is_flex_container and !parent_info.flex_is_column
            else
                false;
            const parent_is_flex_or_grid = if (box_gen.stacks.block_info.top) |parent_info|
                parent_info.is_flex_container or parent_info.is_grid_container
            else
                false;
            const box_style_specified = computer.getSpecifiedValue(.box_gen, .box_style);
            const layout_width: ContainingBlockWidth = if (parent_is_flex_row) blk: {
                break :blk .{ .normal = containing_block_size.width };
            } else
                .{ .normal = containing_block_size.width };
            var sizes = solveAllSizes(computer, position, layout_width, containing_block_size.height, parent_is_flex_or_grid);
            form_controls.applyIntrinsicSizes(box_gen.getLayout(), node, &sizes);
            if (!parent_is_flex_or_grid and position != .absolute) {
                if (box_gen.stacks.block_info.top) |parent| alignToParentTextAlign(&sizes, containing_block_size.width, parent.text_align);
            }
            const stacking_context = solveStackingContext(computer, position);
            const font_specified = computer.computedFont(.box_gen);
            computer.setComputedValue(.box_gen, .font, font_specified);

            computer.setComputedValue(.box_gen, .color, computer.getSpecifiedValue(.box_gen, .color));
            computer.setComputedValue(.box_gen, .border_colors, computer.getSpecifiedValue(.box_gen, .border_colors));
            computer.setComputedValue(.box_gen, .border_radii, computer.getSpecifiedValue(.box_gen, .border_radii));
            computer.setComputedValue(.box_gen, .background_color, computer.getSpecifiedValue(.box_gen, .background_color));
            computer.setComputedValue(.box_gen, .background_clip, computer.getSpecifiedValue(.box_gen, .background_clip));
            computer.setComputedValue(.box_gen, .background, computer.getSpecifiedValue(.box_gen, .background));
            computer.setComputedValue(.box_gen, .opacity, computer.getSpecifiedValue(.box_gen, .opacity));
            computer.commitNode(.box_gen);

            try pushBlock(box_gen, node, sizes, stacking_context, position);
            box_gen.stacks.block_info.top.?.text_align = font_specified.text_align;
            setupContainer(box_gen, inner_block, box_style_specified);
            // Store per-block flex item properties and float/clear/BFC state
            {
                const info = &box_gen.stacks.block_info.top.?;
                info.flex_grow = box_style_specified.flex_grow;
                info.flex_shrink = box_style_specified.flex_shrink;
                info.align_self = box_style_specified.align_self;
                // §9.2: Resolve flex-basis to layout units (4 per CSS px).
                //   - Definite flex-basis → use directly.
                //   - flex-basis: auto + definite width → use width (§9.2D).
                //   - flex-basis: auto + width: auto → -1 (content measurement).
                info.flex_basis_px = switch (box_style_specified.flex_basis) {
                    .auto => blk: {
                        const cw = computer.getSpecifiedValue(.box_gen, .content_width);
                        break :blk switch (cw.width) {
                            .px => |v| @as(i32, @intFromFloat(@round(v * 4.0))),
                            .em => |v| @as(i32, @intFromFloat(@round(v * computer.resolvedFontSizePx(.box_gen) * 4.0))),
                            // CSS Flexbox §7.2 + §9.2A: flex-basis:auto uses the main
                            // size property. width:<percentage> resolved against a
                            // definite containing block is itself definite, so the
                            // flex base size = pct * container_main. This matches
                            // Chrome; falling back to content here caused e.g.
                            // Wikipedia's .mw-header (width:100%) to shrink to its
                            // intrinsic content width inside .vector-header-container.
                            .percentage => |pct| @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(containing_block_size.width)) * pct))),
                            .calc => |c| solve.positiveCalc(computer.env, .{ .id = c.id, .font_size = computer.resolvedFontSizePx(.box_gen) }, containing_block_size.width) orelse -1,
                            .auto => @as(i32, -1),
                        };
                    },
                    .px => |v| @intFromFloat(@round(v * 4.0)),
                    .percentage => |pct| @intFromFloat(@round(@as(f32, @floatFromInt(containing_block_size.width)) * pct)),
                };
                info.grid_area_hash = box_style_specified.grid_area;
                // CSS spec: float and clear have no effect on flex/grid items.
                // Suppress them when parent is a flex or grid container.
                if (parent_is_flex_or_grid) {
                    info.float_side = .none;
                    info.clear_side = .none;
                } else {
                    info.float_side = box_style_specified.float;
                    info.clear_side = box_style_specified.clear;
                }
                if (info.float_side != .none) {
                    info.is_bfc = true;
                }
                if (box_style_specified.overflow != .visible) {
                    info.is_bfc = true;
                }
            }
        },
    }
}

/// Record the flex or grid container facts of the block just pushed
/// (block_info.top) from its specified box style: block-level containers
/// here, inline-level ones from `inline.inlineElement`.
pub fn setupContainer(box_gen: *BoxGen, inner_block: BoxStyle.InnerBlock, box_style_specified: anytype) void {
    const computer = &box_gen.getLayout().computer;
    if (inner_block == .flex and (box_style_specified.flex_direction == .row or box_style_specified.flex_direction == .column)) {
        const info = &box_gen.stacks.block_info.top.?;
        info.is_flex_container = true;
        info.flex_is_column = (box_style_specified.flex_direction == .column);
        info.flex_justify = switch (box_style_specified.justify_content) {
            .flex_start => .flex_start,
            .center => .center,
            .flex_end => .flex_end,
            .space_between => .space_between,
            else => .flex_start,
        };
        info.flex_align = switch (box_style_specified.align_items) {
            .center => .center,
            .flex_start => .flex_start,
            .flex_end => .flex_end,
            .stretch => .stretch,
            else => .stretch,
        };
        info.flex_gap = box_style_specified.column_gap;
        info.flex_wrap = box_style_specified.flex_wrap;
    }
    if (inner_block == .grid) {
        const info = &box_gen.stacks.block_info.top.?;
        info.is_grid_container = true;
        info.flex_align = switch (box_style_specified.align_items) {
            .center => .center,
            .flex_start => .flex_start,
            .flex_end => .flex_end,
            else => .stretch,
        };
        info.grid_column_gap = box_style_specified.column_gap;
        info.grid_row_gap = box_style_specified.row_gap;
        // Read grid template properties from cascade
        const grid_tmpl = computer.getSpecifiedValue(.box_gen, .grid_template);
        info.grid_columns = grid_tmpl.columns;
        info.grid_rows = grid_tmpl.rows;
        info.grid_areas = grid_tmpl.areas;
    }
}

pub fn nullNode(box_gen: *BoxGen) ?void {
    popBlock(box_gen) orelse {
        endMode(box_gen);
        return {};
    };
    return null;
}

pub fn afterFlowMode() noreturn {
    unreachable;
}

pub fn beforeInlineMode() SizeMode {
    return .normal;
}

pub fn afterInlineMode() void {}

pub fn afterStfMode() noreturn {
    unreachable;
}

fn pushBlock(
    box_gen: *BoxGen,
    node: NodeId,
    sizes: BlockUsedSizes,
    stacking_context: SctBuilder.Type,
    position: BoxStyle.Position,
) !void {
    // The operations here must have corresponding reverse operations in `popBlock`.
    box_gen.bfc_stack.top.? += 1;
    const box_style = BoxStyle{ .outer = .{ .block = .flow }, .position = position };
    const ref = try box_gen.pushFlowBlock(box_style, sizes, .normal, stacking_context, node);
    try box_gen.getLayout().box_tree.setGeneratedBox(node, .{ .block_ref = ref });
    try box_gen.getLayout().pushNode();
}

fn popBlock(box_gen: *BoxGen) ?void {
    // The operations here must be the reverse of the ones in `pushBlock`.
    const bfc_depth = &box_gen.bfc_stack.top.?;
    bfc_depth.* -= 1;
    if (bfc_depth.* == 0) {
        box_gen.registerFloatLeaf();
        return null;
    }
    box_gen.popFlowBlock(.normal);
    box_gen.getLayout().popNode();
}

pub const ContainingBlockWidth = union(SizeMode) {
    normal: Unit,
    stf,
};

/// Resolve all em values in block sizes to px using the element's computed font-size.
/// Called before passing sizes to solve functions which expect only px/percentage/auto.
pub fn resolveBlockEm(sizes: BlockComputedSizes, fs: f32) BlockComputedSizes {
    return .{
        .content_width = .{
            .width = sizes.content_width.width.resolveEm(fs),
            .min_width = sizes.content_width.min_width.resolveEm(fs),
            .max_width = sizes.content_width.max_width.resolveEm(fs),
            .box_sizing = sizes.content_width.box_sizing,
        },
        .horizontal_edges = .{
            .margin_left = sizes.horizontal_edges.margin_left.resolveEm(fs),
            .margin_right = sizes.horizontal_edges.margin_right.resolveEm(fs),
            .padding_left = sizes.horizontal_edges.padding_left.resolveEm(fs),
            .padding_right = sizes.horizontal_edges.padding_right.resolveEm(fs),
            .border_left = sizes.horizontal_edges.border_left,
            .border_right = sizes.horizontal_edges.border_right,
        },
        .content_height = .{
            .height = sizes.content_height.height.resolveEm(fs),
            .min_height = sizes.content_height.min_height.resolveEm(fs),
            .max_height = sizes.content_height.max_height.resolveEm(fs),
        },
        .vertical_edges = .{
            .margin_top = sizes.vertical_edges.margin_top.resolveEm(fs),
            .margin_bottom = sizes.vertical_edges.margin_bottom.resolveEm(fs),
            .padding_top = sizes.vertical_edges.padding_top.resolveEm(fs),
            .padding_bottom = sizes.vertical_edges.padding_bottom.resolveEm(fs),
            .border_top = sizes.vertical_edges.border_top,
            .border_bottom = sizes.vertical_edges.border_bottom,
        },
        .insets = .{
            .top = sizes.insets.top.resolveEm(fs),
            .right = sizes.insets.right.resolveEm(fs),
            .bottom = sizes.insets.bottom.resolveEm(fs),
            .left = sizes.insets.left.resolveEm(fs),
        },
    };
}
/// Blink's legacy alignment of block-level children (CSS 2.1 §10.3.3 plus
/// LayoutBox::ComputeInlineDirectionMargins): when the parent's text-align
/// is -webkit-center/-right/-left and the child has a non-auto width and no
/// auto inline margins, its margin box is centered / right / left aligned
/// in the containing block instead of the end margin absorbing the rest.
pub fn alignToParentTextAlign(sizes: *BlockUsedSizes, cb_width: Unit, parent_align: zss.values.types.TextAlign) void {
    switch (parent_align) {
        .@"-webkit-center", .@"-webkit-right", .@"-webkit-left" => {},
        else => return,
    }
    if (sizes.intrinsic.width == .auto or sizes.intrinsic.margin_start_auto or sizes.intrinsic.margin_end_auto) return;
    const width = sizes.get(.inline_size) orelse return;
    const edges = sizes.border_inline_start + sizes.border_inline_end + sizes.padding_inline_start + sizes.padding_inline_end;
    const start = sizes.specified_margins[0];
    const end = sizes.specified_margins[1];
    const leftover = cb_width - width - edges - start - end;
    if (leftover <= 0) return;
    const new_start: Unit = switch (parent_align) {
        .@"-webkit-center" => start + @divFloor(leftover, 2),
        .@"-webkit-right" => start + leftover,
        else => start,
    };
    sizes.setValue(.margin_inline_start, new_start);
    sizes.setValue(.margin_inline_end, cb_width - width - edges - new_start);
}

/// The specified-value kinds `Layout/intrinsic.zig` needs: whether `width`
/// is auto, a fixed length or a percentage, and which inline margins are
/// auto (they contribute zero).
pub fn intrinsicFlags(env: *const zss.Environment, specified: BlockComputedSizes) BoxTree.Subtree.IntrinsicFlags {
    return .{
        .width = switch (specified.content_width.width) {
            .auto => .auto,
            .percentage => .percentage,
            // A math function with a percentage is cyclic like one (CSS
            // Sizing 3 §5.2.1).
            .calc => |c| if (solve.calcHasPercentage(env, c)) .percentage else .fixed,
            else => .fixed,
        },
        .margin_start_auto = specified.horizontal_edges.margin_left == .auto,
        .margin_end_auto = specified.horizontal_edges.margin_right == .auto,
        .height_auto = specified.content_height.height == .auto,
        .border_box = specified.content_width.box_sizing == .border_box,
    };
}

/// Specified inline margins in layout units; auto and percentages are 0
/// (CSS Sizing 3 §5.2.1: percentage margins contribute zero to intrinsic
/// sizes).
pub fn specifiedMargins(env: *const zss.Environment, specified: BlockComputedSizes) [2]Unit {
    const conv = struct {
        fn f(e: *const zss.Environment, m: zss.values.types.Margin) Unit {
            return switch (m) {
                .px => |px| @intFromFloat(@round(px * @as(f32, @floatFromInt(zss.math.units_per_pixel)))),
                // Percentages resolve against zero here.
                .calc => |c| solve.calc(e, c, 0).?,
                else => 0,
            };
        }
    };
    return .{ conv.f(env, specified.horizontal_edges.margin_left), conv.f(env, specified.horizontal_edges.margin_right) };
}

pub fn percentWidth(env: *const zss.Environment, specified: BlockComputedSizes) BoxTree.Subtree.PercentWidth {
    return switch (specified.content_width.width) {
        .percentage => |p| .{ .percentage = p },
        .calc => |c| if (solve.calcHasPercentage(env, c)) .{ .calc = c } else .{ .percentage = 0 },
        else => .{ .percentage = 0 },
    };
}

/// The percentage base of a containing block width: none while shrinking to fit.
fn cbwBase(containing_block_width: ContainingBlockWidth) ?Unit {
    return switch (containing_block_width) {
        .normal => |cbw| cbw,
        .stf => null,
    };
}

pub fn solveAllSizes(
    computer: *StyleComputer,
    position: BoxTree.BoxStyle.Position,
    containing_block_width: ContainingBlockWidth,
    containing_block_height: ?Unit,
    parent_is_flex_or_grid: bool,
) BlockUsedSizes {
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    // Get element's computed font-size for em resolution.
    const font_size_px = computer.resolvedFontSizePx(.box_gen);

    // Resolve em values in specified sizes using element's computed font-size.
    const specified_sizes = resolveBlockEm(BlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .insets = computer.getSpecifiedValue(.box_gen, .insets),
    }, font_size_px);
    const percentage_base_unit = switch (containing_block_width) {
        .normal => |value| value,
        .stf => 0,
    };

    var computed_sizes: BlockComputedSizes = undefined;
    var sizes: BlockUsedSizes = undefined;
    sizes.was_auto_inline_size = false;
    sizes.intrinsic = intrinsicFlags(computer.env, specified_sizes);
    sizes.percent_width = percentWidth(computer.env, specified_sizes);
    sizes.specified_margins = specifiedMargins(computer.env, specified_sizes);
    const env = computer.env;
    solveWidthAndHorizontalMargins(env, specified_sizes, containing_block_width, &computed_sizes, &sizes);
    solveHorizontalBorderPadding(env, specified_sizes.horizontal_edges, percentage_base_unit, border_styles, &computed_sizes.horizontal_edges, &sizes);
    solveHeight(env, specified_sizes.content_height, containing_block_height, &computed_sizes.content_height, &sizes);
    solveVerticalEdges(env, specified_sizes.vertical_edges, percentage_base_unit, border_styles, &computed_sizes.vertical_edges, &sizes);
    // box-sizing: border-box — specified width/height includes padding and border.
    // Subtract them to get content-box dimensions that the layout engine uses internally.
    if (specified_sizes.content_width.box_sizing == .border_box) {
        if (sizes.get(.inline_size)) |w| {
            const h_adjustment = sizes.border_inline_start + sizes.border_inline_end +
                sizes.padding_inline_start + sizes.padding_inline_end;
            sizes.setValue(.inline_size, @max(0, w - h_adjustment));
        }
        if (sizes.get(.block_size)) |h| {
            const v_adjustment = sizes.border_block_start + sizes.border_block_end +
                sizes.padding_block_start + sizes.padding_block_end;
            sizes.setValue(.block_size, @max(0, h - v_adjustment));
        }
    }
    // A replaced element's auto sizes come from its natural size (CSS 2.1
    // §10.3.2, §10.6.2), before auto margins are resolved (§10.3.4).
    replaced.applyNaturalSize(computer.env, computer.current.node, &sizes, sizes.isAuto(.inline_size));
    switch (containing_block_width) {
        .normal => {
            // Save auto flags before adjustWidthAndMargins clears them
            const was_auto = .{
                .inline_size = sizes.isAuto(.inline_size),
                .margin_inline_start = sizes.isAuto(.margin_inline_start),
                .margin_inline_end = sizes.isAuto(.margin_inline_end),
            };
            sizes.was_auto_inline_size = was_auto.inline_size;
            if (parent_is_flex_or_grid) {
                // CSS Flexbox §8.1 / Grid §11.3: flex/grid items do NOT use
                // the block-level overconstrained rule (CSS 2.1 §10.3.3).
                // Auto margins resolve to 0 here; the flex algorithm handles
                // free-space distribution via auto margins during positioning.
                if (was_auto.margin_inline_start) sizes.setValue(.margin_inline_start, 0);
                if (was_auto.margin_inline_end) sizes.setValue(.margin_inline_end, 0);
                if (was_auto.inline_size) {
                    sizes.setValue(.inline_size, percentage_base_unit -
                        (sizes.border_inline_start + sizes.border_inline_end +
                         sizes.padding_inline_start + sizes.padding_inline_end +
                         sizes.margin_inline_start_untagged + sizes.margin_inline_end_untagged));
                }
                sizes.setValueFlagOnly(.margin_inline_start);
                sizes.setValueFlagOnly(.margin_inline_end);
                sizes.setValueFlagOnly(.inline_size);
            } else {
                adjustWidthAndMargins(&sizes, percentage_base_unit);
            }
            // TODO: Do this in adjustWidthAndMargins
            const width_before_clamp = sizes.get(.inline_size).?;
            sizes.inline_size_untagged = solve.clampSize(width_before_clamp, sizes.min_inline_size, sizes.max_inline_size);
            // CSS2.2§10.4: when max-width constrains an auto width,
            // re-compute auto margins as if width were a fixed value.
            if (was_auto.inline_size) {
                if (was_auto.margin_inline_start or was_auto.margin_inline_end) {
                    const width_margin_space = percentage_base_unit -
                        (sizes.border_inline_start + sizes.border_inline_end +
                         sizes.padding_inline_start + sizes.padding_inline_end);
                    const shr_amount = @intFromBool(was_auto.margin_inline_start and was_auto.margin_inline_end);
                    const leftover_margin = @max(0, width_margin_space -
                        (sizes.inline_size_untagged + sizes.margin_inline_start_untagged + sizes.margin_inline_end_untagged));
                    if (was_auto.margin_inline_start) sizes.setValue(.margin_inline_start, leftover_margin >> shr_amount);
                    if (was_auto.margin_inline_end) sizes.setValue(.margin_inline_end, (leftover_margin >> shr_amount) + @mod(leftover_margin, 2));
                }
            }
        },
        .stf => {},
    }
    if (sizes.get(.block_size)) |block_size| {
        sizes.block_size_untagged = solve.clampSize(block_size, sizes.min_block_size, sizes.max_block_size);
    }

    computed_sizes.insets = solve.insets(specified_sizes.insets);
    solveInsets(computed_sizes.insets, position, &sizes);

    // solveWidthAndHorizontalMargins fills width/min/max only; the computed
    // value of box-sizing is its specified value (it is not a length).
    computed_sizes.content_width.box_sizing = specified_sizes.content_width.box_sizing;
    computer.setComputedValue(.box_gen, .content_width, computed_sizes.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed_sizes.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed_sizes.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed_sizes.vertical_edges);
    computer.setComputedValue(.box_gen, .insets, computed_sizes.insets);
    computer.setComputedValue(.box_gen, .border_styles, border_styles);

    return sizes;
}

/// Solves the following list of properties according to CSS2§10.2, CSS2§10.3.3, and CSS2§10.4.
/// Properties: 'min-width', 'max-width', 'width', 'margin-left', 'margin-right'
fn solveWidthAndHorizontalMargins(
    env: *const zss.Environment,
    specified: BlockComputedSizes,
    containing_block_width: ContainingBlockWidth,
    computed: *BlockComputedSizes,
    sizes: *BlockUsedSizes,
) void {
    // TODO: Also use the logical properties ('inline-size', 'border-inline-start', etc.) to determine lengths.

    switch (containing_block_width) {
        .normal => |cbw| assert(cbw >= 0),
        .stf => {},
    }

    switch (specified.content_width.min_width) {
        .px => |value| {
            computed.content_width.min_width = .{ .px = value };
            sizes.min_inline_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_width = .{ .percentage = value };
            sizes.min_inline_size = switch (containing_block_width) {
                .normal => |cbw| solve.positivePercentage(value, cbw),
                .stf => 0,
            };
        },
        .calc => |value| {
            computed.content_width.min_width = .{ .calc = value };
            sizes.min_inline_size = solve.positiveCalc(env, value, cbwBase(containing_block_width)) orelse 0;
        },
        .em => unreachable,
    }
    switch (specified.content_width.max_width) {
        .px => |value| {
            computed.content_width.max_width = .{ .px = value };
            sizes.max_inline_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_width = .{ .percentage = value };
            sizes.max_inline_size = switch (containing_block_width) {
                .normal => |cbw| solve.positivePercentage(value, cbw),
                .stf => std.math.maxInt(Unit),
            };
        },
        .calc => |value| {
            computed.content_width.max_width = .{ .calc = value };
            sizes.max_inline_size = solve.positiveCalc(env, value, cbwBase(containing_block_width)) orelse std.math.maxInt(Unit);
        },
        .none => {
            computed.content_width.max_width = .none;
            sizes.max_inline_size = std.math.maxInt(Unit);
        },
        .em => unreachable,
    }

    switch (specified.content_width.width) {
        .px => |value| {
            computed.content_width.width = .{ .px = value };
            sizes.setValue(.inline_size, solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_width.width = .{ .percentage = value };
            switch (containing_block_width) {
                .normal => |cbw| sizes.setValue(.inline_size, solve.positivePercentage(value, cbw)),
                .stf => sizes.setAuto(.inline_size),
            }
        },
        .calc => |value| {
            computed.content_width.width = .{ .calc = value };
            if (solve.positiveCalc(env, value, cbwBase(containing_block_width))) |w|
                sizes.setValue(.inline_size, w)
            else
                sizes.setAuto(.inline_size);
        },
        .auto => {
            computed.content_width.width = .auto;
            sizes.setAuto(.inline_size);
        },
        .em => unreachable,
    }
    switch (specified.horizontal_edges.margin_left) {
        .px => |value| {
            computed.horizontal_edges.margin_left = .{ .px = value };
            sizes.setValue(.margin_inline_start, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_left = .{ .percentage = value };
            switch (containing_block_width) {
                .normal => |cbw| sizes.setValue(.margin_inline_start, solve.percentage(value, cbw)),
                .stf => sizes.setAuto(.margin_inline_start),
            }
        },
        .calc => |value| {
            computed.horizontal_edges.margin_left = .{ .calc = value };
            if (solve.calc(env, value, cbwBase(containing_block_width))) |m|
                sizes.setValue(.margin_inline_start, m)
            else
                sizes.setAuto(.margin_inline_start);
        },
        .auto => {
            computed.horizontal_edges.margin_left = .auto;
            sizes.setAuto(.margin_inline_start);
        },
        .em => unreachable,
    }
    switch (specified.horizontal_edges.margin_right) {
        .px => |value| {
            computed.horizontal_edges.margin_right = .{ .px = value };
            sizes.setValue(.margin_inline_end, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_right = .{ .percentage = value };
            switch (containing_block_width) {
                .normal => |cbw| sizes.setValue(.margin_inline_end, solve.percentage(value, cbw)),
                .stf => sizes.setAuto(.margin_inline_end),
            }
        },
        .calc => |value| {
            computed.horizontal_edges.margin_right = .{ .calc = value };
            if (solve.calc(env, value, cbwBase(containing_block_width))) |m|
                sizes.setValue(.margin_inline_end, m)
            else
                sizes.setAuto(.margin_inline_end);
        },
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
            sizes.setAuto(.margin_inline_end);
        },
        .em => unreachable,
    }
}

fn solveHorizontalBorderPadding(
    env: *const zss.Environment,
    specified: SpecifiedValues(.horizontal_edges),
    containing_block_width: Unit,
    border_styles: SpecifiedValues(.border_styles),
    computed: *ComputedValues(.horizontal_edges),
    sizes: *BlockUsedSizes,
) void {
    assert(containing_block_width >= 0);

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.left);
        switch (specified.border_left) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_left = .{ .px = width };
                sizes.border_inline_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_left = .{ .px = width };
                sizes.border_inline_start = solve.positiveLength(.px, width);
            },
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.right);
        switch (specified.border_right) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_right = .{ .px = width };
                sizes.border_inline_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_right = .{ .px = width };
                sizes.border_inline_end = solve.positiveLength(.px, width);
            },
        }
    }

    switch (specified.padding_left) {
        .px => |value| {
            computed.padding_left = .{ .px = value };
            sizes.padding_inline_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_left = .{ .percentage = value };
            sizes.padding_inline_start = solve.positivePercentage(value, containing_block_width);
        },
        .calc => |value| {
            computed.padding_left = .{ .calc = value };
            sizes.padding_inline_start = solve.positiveCalc(env, value, containing_block_width).?;
        },
        .em => unreachable,
    }
    switch (specified.padding_right) {
        .px => |value| {
            computed.padding_right = .{ .px = value };
            sizes.padding_inline_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_right = .{ .percentage = value };
            sizes.padding_inline_end = solve.positivePercentage(value, containing_block_width);
        },
        .calc => |value| {
            computed.padding_right = .{ .calc = value };
            sizes.padding_inline_end = solve.positiveCalc(env, value, containing_block_width).?;
        },
        .em => unreachable,
    }
}

fn solveHeight(
    env: *const zss.Environment,
    specified: SpecifiedValues(.content_height),
    containing_block_height: ?Unit,
    computed: *ComputedValues(.content_height),
    sizes: *BlockUsedSizes,
) void {
    if (containing_block_height) |h| assert(h >= 0);

    switch (specified.min_height) {
        .px => |value| {
            computed.min_height = .{ .px = value };
            sizes.min_block_size = solve.positiveLength(.px, value);
        },

        .percentage => |value| {
            computed.min_height = .{ .percentage = value };
            sizes.min_block_size = if (containing_block_height) |s|
                solve.positivePercentage(value, s)
            else
                0;
        },
        .calc => |value| {
            computed.min_height = .{ .calc = value };
            sizes.min_block_size = solve.positiveCalc(env, value, containing_block_height) orelse 0;
        },
        .em => unreachable,
    }
    switch (specified.max_height) {
        .px => |value| {
            computed.max_height = .{ .px = value };
            sizes.max_block_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.max_height = .{ .percentage = value };
            sizes.max_block_size = if (containing_block_height) |s|
                solve.positivePercentage(value, s)
            else
                std.math.maxInt(Unit);
        },
        .calc => |value| {
            computed.max_height = .{ .calc = value };
            sizes.max_block_size = solve.positiveCalc(env, value, containing_block_height) orelse std.math.maxInt(Unit);
        },
        .none => {
            computed.max_height = .none;
            sizes.max_block_size = std.math.maxInt(Unit);
        },
        .em => unreachable,
    }
    switch (specified.height) {
        .px => |value| {
            computed.height = .{ .px = value };
            sizes.setValue(.block_size, solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.height = .{ .percentage = value };
            if (containing_block_height) |h|
                sizes.setValue(.block_size, solve.positivePercentage(value, h))
            else
                sizes.setAuto(.block_size);
        },
        .calc => |value| {
            computed.height = .{ .calc = value };
            if (solve.positiveCalc(env, value, containing_block_height)) |h|
                sizes.setValue(.block_size, h)
            else
                sizes.setAuto(.block_size);
        },
        .auto => {
            computed.height = .auto;
            sizes.setAuto(.block_size);
        },
        .em => unreachable,
    }
}

/// This is an implementation of CSS2§10.5 and CSS2§10.6.3.
fn solveVerticalEdges(
    env: *const zss.Environment,
    specified: SpecifiedValues(.vertical_edges),
    containing_block_width: Unit,
    border_styles: SpecifiedValues(.border_styles),
    computed: *ComputedValues(.vertical_edges),
    sizes: *BlockUsedSizes,
) void {
    // TODO: Also use the logical properties ('block-size', 'border-block-start', etc.) to determine lengths.

    assert(containing_block_width >= 0);

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.top);
        switch (specified.border_top) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_top = .{ .px = width };
                sizes.border_block_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_top = .{ .px = width };
                sizes.border_block_start = solve.positiveLength(.px, width);
            },
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.bottom);
        switch (specified.border_bottom) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_bottom = .{ .px = width };
                sizes.border_block_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_bottom = .{ .px = width };
                sizes.border_block_end = solve.positiveLength(.px, width);
            },
        }
    }
    switch (specified.padding_top) {
        .px => |value| {
            computed.padding_top = .{ .px = value };
            sizes.padding_block_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_top = .{ .percentage = value };
            sizes.padding_block_start = solve.positivePercentage(value, containing_block_width);
        },
        .calc => |value| {
            computed.padding_top = .{ .calc = value };
            sizes.padding_block_start = solve.positiveCalc(env, value, containing_block_width).?;
        },
        .em => unreachable,
    }
    switch (specified.padding_bottom) {
        .px => |value| {
            computed.padding_bottom = .{ .px = value };
            sizes.padding_block_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_bottom = .{ .percentage = value };
            sizes.padding_block_end = solve.positivePercentage(value, containing_block_width);
        },
        .calc => |value| {
            computed.padding_bottom = .{ .calc = value };
            sizes.padding_block_end = solve.positiveCalc(env, value, containing_block_width).?;
        },
        .em => unreachable,
    }
    switch (specified.margin_top) {
        .px => |value| {
            computed.margin_top = .{ .px = value };
            sizes.margin_block_start = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.margin_top = .{ .percentage = value };
            sizes.margin_block_start = solve.percentage(value, containing_block_width);
        },
        .calc => |value| {
            computed.margin_top = .{ .calc = value };
            sizes.margin_block_start = solve.calc(env, value, containing_block_width).?;
        },
        .auto => {
            computed.margin_top = .auto;
            sizes.margin_block_start = 0;
        },
        .em => unreachable,
    }
    switch (specified.margin_bottom) {
        .px => |value| {
            computed.margin_bottom = .{ .px = value };
            sizes.margin_block_end = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.margin_bottom = .{ .percentage = value };
            sizes.margin_block_end = solve.percentage(value, containing_block_width);
        },
        .calc => |value| {
            computed.margin_bottom = .{ .calc = value };
            sizes.margin_block_end = solve.calc(env, value, containing_block_width).?;
        },
        .auto => {
            computed.margin_bottom = .auto;
            sizes.margin_block_end = 0;
        },
        .em => unreachable,
    }
}

pub fn solveInsets(
    computed: ComputedValues(.insets),
    position: BoxTree.BoxStyle.Position,
    sizes: *BlockUsedSizes,
) void {
    switch (position) {
        .static => {
            inline for (.{
                .inset_inline_start,
                .inset_inline_end,
                .inset_block_start,
                .inset_block_end,
            }) |field| {
                sizes.setValue(field, 0);
            }
        },
        .relative => {
            inline for (.{
                .{ "left", .inset_inline_start },
                .{ "right", .inset_inline_end },
                .{ "top", .inset_block_start },
                .{ "bottom", .inset_block_end },
            }) |pair| {
                switch (@field(computed, pair[0])) {
                    .px => |value| sizes.setValue(pair[1], solve.length(.px, value)),
                    .percentage => |percentage| sizes.setPercentage(pair[1], percentage),
                    // Insets are positioned from the specified values
                    // (BoxGen.solveInsets*); a math function is recorded like
                    // a percentage.
                    .calc => sizes.setPercentage(pair[1], 0),
                    .auto => sizes.setAuto(pair[1]),
                    .em => unreachable,
                }
            }
        },
        .absolute, .fixed => {
            // Absolute positioning: solve insets from computed styles
            inline for (.{
                .{ "left", .inset_inline_start },
                .{ "right", .inset_inline_end },
                .{ "top", .inset_block_start },
                .{ "bottom", .inset_block_end },
            }) |pair| {
                switch (@field(computed, pair[0])) {
                    .px => |value| sizes.setValue(pair[1], solve.length(.px, value)),
                    .percentage => |percentage| sizes.setPercentage(pair[1], percentage),
                    // Insets are positioned from the specified values
                    // (BoxGen.solveInsets*); a math function is recorded like
                    // a percentage.
                    .calc => sizes.setPercentage(pair[1], 0),
                    .auto => sizes.setAuto(pair[1]),
                    .em => unreachable,
                }
            }
        },
    }
}

/// Changes the sizes of a block that is in normal flow.
/// This implements the constraints described in CSS2.2§10.3.3.
pub fn adjustWidthAndMargins(sizes: *BlockUsedSizes, containing_block_width: Unit) void {
    // TODO: This algorithm doesn't completely follow the rules regarding `min-width` and `max-width`
    //       described in CSS 2.2 Section 10.4.
    const width_margin_space = containing_block_width -
        (sizes.border_inline_start + sizes.border_inline_end + sizes.padding_inline_start + sizes.padding_inline_end);
    const auto = .{
        .inline_size = sizes.isAuto(.inline_size),
        .margin_inline_start = sizes.isAuto(.margin_inline_start),
        .margin_inline_end = sizes.isAuto(.margin_inline_end),
    };

    if (!auto.inline_size and !auto.margin_inline_start and !auto.margin_inline_end) {
        // None of the values were auto, so one of the margins must be set according to the other values.
        // TODO the margin that gets set is determined by the 'direction' property
        sizes.setValue(.margin_inline_end, width_margin_space - sizes.inline_size_untagged - sizes.margin_inline_start_untagged);
    } else if (!auto.inline_size) {
        // 'inline-size' is not auto, but at least one of 'margin-inline-start' and 'margin-inline-end' is.
        // If there is only one "auto", then that value gets the remaining margin space.
        // Else, there are 2 "auto"s, and both values get half the remaining margin space.
        const shr_amount = @intFromBool(auto.margin_inline_start and auto.margin_inline_end);
        const leftover_margin = @max(0, width_margin_space -
            (sizes.inline_size_untagged + sizes.margin_inline_start_untagged + sizes.margin_inline_end_untagged));
        // TODO the margin that gets the extra 1 unit shall be determined by the 'direction' property
        if (auto.margin_inline_start) sizes.setValue(.margin_inline_start, leftover_margin >> shr_amount);
        if (auto.margin_inline_end) sizes.setValue(.margin_inline_end, (leftover_margin >> shr_amount) + @mod(leftover_margin, 2));
    } else {
        // 'inline-size' is auto, so it is set according to the other values.
        // The margin values don't need to change.
        sizes.setValue(.inline_size, width_margin_space - sizes.margin_inline_start_untagged - sizes.margin_inline_end_untagged);
        sizes.setValueFlagOnly(.margin_inline_start);
        sizes.setValueFlagOnly(.margin_inline_end);
    }
}

pub fn solveStackingContext(computer: *StyleComputer, position: BoxTree.BoxStyle.Position) SctBuilder.Type {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);

    switch (position) {
        .static => return .none,
        // TODO: Position the block using the values of the 'inset' family of properties.
        .relative => switch (z_index.z_index) {
            .integer => |integer| return .{ .parentable = integer },
            .auto => return .{ .non_parentable = 0 },
        },
        .absolute, .fixed => switch (z_index.z_index) {
            // Absolute positioning creates stacking context when z-index is specified
            .integer => |integer| return .{ .parentable = integer },
            .auto => return .{ .non_parentable = 0 },
        },
    }
}

pub fn solveUsedWidth(width: Unit, min_width: Unit, max_width: Unit) Unit {
    return solve.clampSize(width, min_width, max_width);
}

pub fn solveUsedHeight(sizes: BlockUsedSizes, auto_height: Unit) Unit {
    return sizes.get(.block_size) orelse solve.clampSize(auto_height, sizes.min_block_size, sizes.max_block_size);
}

/// Result of offsetChildBlocks: auto_height plus first-child's escaped margin
/// (for parent-child margin collapsing, CSS 2.1 Section 8.3.1).
pub const OffsetResult = struct {
    auto_height: Unit,
    /// Margin that escapes through the parent's top edge when the parent has
    /// no border-top or padding-top. Caller must adjust parent's margin.
    escaped_margin_top: Unit,
};

/// The floats beside one inline formatting context, for line-box
/// shortening (CSS 2.1 §9.5): float margin boxes in the IFC's coordinates
/// (x from its content-box left edge, y from its top). Built per IFC by the
/// BFC pass (`Layout/bfc.zig`).
pub const FloatContext = struct {
    floats: []const PlacedFloat,

    pub const Side = enum { left, right };

    pub const PlacedFloat = struct {
        side: Side,
        x: Unit,
        y: Unit,
        w: Unit,
        h: Unit,
    };

    /// Compute line-box exclusion for a line at line_y of height line_h.
    /// Returns the left edge offset and right edge limit.
    pub fn getLineExclusion(
        self: *const FloatContext,
        line_y: Unit,
        line_h: Unit,
        container_width: Unit,
    ) struct { left_offset: Unit, right_limit: Unit } {
        var left_offset: Unit = 0;
        var right_limit: Unit = container_width;
        for (self.floats) |f| {
            // Float rect [f.y, f.y + f.h) intersects line range [line_y, line_y + line_h)?
            if (f.y + f.h <= line_y) continue;
            if (f.y >= line_y + line_h) continue;
            switch (f.side) {
                .left => left_offset = @max(left_offset, f.x + f.w),
                .right => right_limit = @min(right_limit, f.x),
            }
        }
        return .{ .left_offset = left_offset, .right_limit = right_limit };
    }
};

/// Position the in-flow children of a block container in normal flow, with
/// margin collapsing (CSS 2.1 §8.3.1). Floats and the formatting contexts
/// they appear in are laid out by `Layout/bfc.zig`; here a float child is
/// left where it is.
pub fn offsetChildBlocks(
    subtree: Subtree.View,
    index: Subtree.Size,
    skip: Subtree.Size,
    container_width: Unit,
    /// border_block_start + padding_block_start of the parent. 0 means the
    /// first child's top margin can escape (parent-child collapsing).
    parent_block_start_edge: Unit,
    /// Unused (kept for the callers' signature).
    box_tree: ?*const BoxTree,
) OffsetResult {
    _ = container_width;
    _ = box_tree;
    const skips = subtree.items(.skip);
    const out_of_flow_flags = subtree.items(.out_of_flow);
    const float_sides = subtree.items(.float_side);
    var child = index + 1;
    const end = index + skip;

    // CSS 2.1 Section 8.3.1: Collapsing margins.
    // `cursor` tracks the bottom of the last border box; `prev_margin`
    // holds the previous sibling's bottom margin for collapsing.
    var cursor: Unit = 0;
    var prev_margin: Unit = 0;
    var first_normal_child = true;
    var escaped_margin_top: Unit = 0;

    while (child < end) {
        if (out_of_flow_flags[child]) {
            subtree.items(.offset)[child] = .{ .x = 0, .y = 0 };
        } else if (float_sides[child] == .none) {
            const box_offsets = subtree.items(.box_offsets)[child];
            const margins = subtree.items(.margins)[child];
            const margin_top = box_offsets.border_pos.y; // = margin_block_start
            const border_box_h = box_offsets.border_size.h;
            const margin_bottom = margins.bottom;
            // CSS 2.1 §8.3.1: Empty box margin collapsing.
            // When a box has zero border-box height (no content, no
            // padding, no border), its top and bottom margins collapse
            // through it into a single margin of max(top, bottom).
            const is_empty_box = (border_box_h == 0);

            if (first_normal_child and parent_block_start_edge == 0 and cursor == 0) {
                // Parent-child margin collapsing: first child's top margin
                // escapes through the parent (which has no border/padding-top,
                // no floats above, and no clearance). CSS 2.1 Section 8.3.1.
                if (is_empty_box) {
                    // Empty first child: its collapsed margin escapes and is
                    // accumulated into escaped_margin_top. The parent-child
                    // collapsing opportunity carries forward to the next
                    // non-empty child, so first_normal_child stays true.
                    // CSS 2.1 §8.3.1: collapsing is transitive through
                    // self-collapsing boxes between parent and first content.
                    escaped_margin_top = @max(escaped_margin_top, margin_top, margin_bottom);
                    subtree.items(.offset)[child] = .{ .x = 0, .y = -margin_top };
                    // cursor stays at 0, prev_margin = escaped_margin_top so
                    // the next non-empty child collapses with it.
                    prev_margin = escaped_margin_top;
                    // first_normal_child stays true: next child can still escape.
                } else {
                    escaped_margin_top = @max(escaped_margin_top, margin_top);
                    subtree.items(.offset)[child] = .{ .x = 0, .y = -margin_top };
                    cursor = border_box_h;
                    prev_margin = margin_bottom;
                    first_normal_child = false;
                }
            } else {
                if (is_empty_box) {
                    // Empty box: top and bottom margins collapse through.
                    // The resulting margin is max(prev, top, bottom) and
                    // carries forward as prev_margin. Cursor doesn't move.
                    const self_collapsed = @max(margin_top, margin_bottom);
                    prev_margin = @max(prev_margin, self_collapsed);
                    // Place at current cursor so the box occupies zero space.
                    subtree.items(.offset)[child] = .{ .x = 0, .y = cursor + prev_margin - margin_top };
                } else {
                    // Collapse this child's top margin with previous sibling's bottom margin.
                    const collapsed = @max(prev_margin, margin_top);
                    const border_box_y = cursor + collapsed;
                    subtree.items(.offset)[child] = .{ .x = 0, .y = border_box_y - margin_top };
                    cursor = border_box_y + border_box_h;
                    prev_margin = margin_bottom;
                }
                first_normal_child = false;
            }
        }
        child += skips[child];
    }

    // Include the last normal-flow child's bottom margin in auto height,
    // but only if at least one child contributed non-zero height. When all
    // children are self-collapsing (cursor == 0), their collapsed margins
    // do not contribute to the parent's content height (CSS 2.1 §10.6.3).
    const normal_height = if (cursor > 0) cursor + prev_margin else cursor;
    return .{
        .auto_height = normal_height,
        .escaped_margin_top = escaped_margin_top,
    };
}

/// Offset children of a table row: all children at offset {0,0} (horizontal
/// positioning is handled by border_pos.x set during cell sizing).
/// Equalizes all cell heights to the tallest cell (CSS table row behavior).
/// Returns the maximum child height (the row's auto height).
pub fn offsetChildBlocksHorizontal(subtree: Subtree.View, index: Subtree.Size, skip: Subtree.Size) Unit {
    const skips = subtree.items(.skip);
    const out_of_flow_flags = subtree.items(.out_of_flow);
    const end = index + skip;

    // Pass 1: find max height and zero all offsets
    var child = index + 1;
    var max_height: Unit = 0;
    while (child < end) {
        subtree.items(.offset)[child] = .{ .x = 0, .y = 0 };
        if (!out_of_flow_flags[child]) {
            const box_offsets = subtree.items(.box_offsets)[child];
            const margins = subtree.items(.margins)[child];
            const child_height = box_offsets.border_pos.y + box_offsets.border_size.h + margins.bottom;
            max_height = @max(max_height, child_height);
        }
        child += skips[child];
    }

    // Pass 2: equalize cell content heights to the row height
    child = index + 1;
    while (child < end) {
        if (!out_of_flow_flags[child]) {
            const box_offsets = &subtree.items(.box_offsets)[child];
            const margins = subtree.items(.margins)[child];
            const non_content = box_offsets.border_pos.y + margins.bottom;
            box_offsets.border_size.h = max_height - non_content;
            // Recompute content_size.h from border_size.h
            box_offsets.content_size.h = box_offsets.border_size.h - box_offsets.content_pos.y;
        }
        child += skips[child];
    }

    return max_height;
}

/// CSS Flexbox §9 Layout Algorithm.
/// Items are initially laid out at container width. This function:
///   §9.2: Determines flex base size from flex-basis or content measurement
///   §9.3: Collects items into lines, resolves flexible lengths (§9.7)
///   §9.4: Determines cross sizes per line
///   §9.5-9.6: Positions items with justify-content and align-items
/// Returns auto height: total cross extent of all lines.
pub fn offsetChildBlocksFlex(
    layout: *zss.Layout,
    subtree: Subtree.View,
    subtree_id: Subtree.Id,
    index: Subtree.Size,
    skip: Subtree.Size,
    container_width: Unit,
    container_height: ?Unit,
    justify: BlockInfo.FlexJustify,
    align_items: BlockInfo.FlexAlign,
    flex_gap: Unit,
    flex_is_column: bool,
    flex_wrap: zss.values.types.FlexWrap,
) Unit {
    const box_tree = layout.box_tree.ptr;
    const skips = subtree.items(.skip);
    const out_of_flow_flags = subtree.items(.out_of_flow);
    const end = index + skip;

    const container_main = if (flex_is_column) (container_height orelse 0) else container_width;
    const container_cross = if (flex_is_column) container_width else (container_height orelse 0);
    const wrapping = flex_wrap != .nowrap;

    // --- Phase 1: Collect in-flow children ---
    // Per CSS Flexbox §4, whitespace-only anonymous flex items are not rendered.
    // In our box tree, inter-element whitespace generates IFC containers as direct
    // children of the flex container. These inflate cross sizes with their line-
    // height even though they contain only collapsible whitespace. Skip them,
    // matching grid.zig:114 which does the same for grid items.
    var children: [MAX_CHILDREN]Subtree.Size = undefined;
    var child_count: usize = 0;
    const block_types = subtree.items(.type);
    {
        var child = index + 1;
        while (child < end) {
            if (out_of_flow_flags[child]) {
                subtree.items(.offset)[child] = .{ .x = 0, .y = 0 };
            } else if (block_types[child] == .ifc_container) {
                // CSS Flexbox §4: anonymous text content directly inside a
                // flex container becomes an anonymous flex item. So
                // `<div style="display:flex">Hello</div>` makes "Hello" a
                // flex item that participates in justify/align. We must NOT
                // skip IFCs with real visible content — they need the flex
                // algorithm (centering, etc.) just like real block children.
                //
                // Whitespace-only IFCs (inter-element whitespace from
                // `<div>\n  <p>...</p>\n</div>`) still skip — rendering
                // them as flex items inflates cross-axis with their
                // line-height for zero visible benefit. has_visible_content
                // is set in inline.inlineElement when any non-whitespace
                // text run, inline-box, or inline-block is added.
                const ifc_id = switch (block_types[child]) {
                    .ifc_container => |id| id,
                    else => unreachable,
                };
                const ifc = box_tree.getIfc(ifc_id);
                if (!ifc.has_visible_content) {
                    subtree.items(.offset)[child] = .{ .x = 0, .y = 0 };
                } else if (child_count < MAX_CHILDREN) {
                    children[child_count] = child;
                    child_count += 1;
                }
            } else {
                if (child_count < MAX_CHILDREN) {
                    children[child_count] = child;
                    child_count += 1;
                }
            }
            child += skips[child];
        }
    }

    // --- Phase 1b (§9.2 step 2, §9.4 step 11): cross sizes of column items ---
    // A column item's height (its main size) depends on its width, so the
    // width is settled first. An item that stretches (`align-self: stretch`
    // with an auto width) fills the container's inner width minus its
    // margins; any other auto-width item is sized fit-content (§9.2 step 3:
    // min(max-content, available)); a definite width is kept. The content is
    // laid out at that width before its main size is measured.
    if (flex_is_column) {
        for (0..child_count) |ci| {
            const child_idx = children[ci];
            if (block_types[child_idx] != .block) continue;
            const stretch = switch (subtree.items(.align_self)[child_idx]) {
                .auto => align_items == .stretch,
                .stretch => true,
                else => false,
            };
            // Flex item margins are used as specified (auto margins are
            // resolved by alignment, §8.1), never over-constrained.
            const flags = subtree.items(.intrinsic)[child_idx];
            const margins = subtree.items(.specified_margins)[child_idx];
            const bo = subtree.items(.box_offsets)[child_idx];
            const available = @max(0, container_width - margins[0] - margins[1]);
            const border_w = switch (flags.width) {
                .auto => if (stretch and !flags.margin_start_auto and !flags.margin_end_auto)
                    available
                else
                    @min(available, intrinsic.blockBorderBoxSizes(layout, subtree, subtree_id, child_idx).max),
                .fixed => bo.border_size.w,
                .percentage => relayout.usedInlineSize(layout.inputs.env, subtree, child_idx, container_width).content_w + (bo.border_size.w - bo.content_size.w),
            };
            subtree.items(.margins)[child_idx].left = margins[0];
            subtree.items(.margins)[child_idx].right = margins[1];
            subtree.items(.box_offsets)[child_idx].border_pos.x = margins[0];
            relayout.resizeItem(layout, subtree, subtree_id, child_idx, border_w);
        }
    }

    // --- Phase 2 (§9.2): Determine flex base size and hypothetical main size ---
    const flex_basis_values = subtree.items(.flex_basis_px);
    const flex_grows = subtree.items(.flex_grow);
    const flex_shrinks = subtree.items(.flex_shrink);
    var flex_base_sizes: [MAX_CHILDREN]Unit = undefined;
    var hypothetical_main_sizes: [MAX_CHILDREN]Unit = undefined;

    for (0..child_count) |ci| {
        const child_idx = children[ci];
        const basis_px = flex_basis_values[child_idx];

        if (basis_px >= 0) {
            // Definite flex-basis: use it directly
            flex_base_sizes[ci] = basis_px;
        } else {
            // flex-basis: auto — use the item's content/intrinsic size
            flex_base_sizes[ci] = measureContentMainSize(layout, subtree, subtree_id, child_idx, flex_is_column);
        }

        // Hypothetical main size = flex base size clamped at zero
        hypothetical_main_sizes[ci] = @max(0, flex_base_sizes[ci]);
    }

    // §9: Flex item margins participate in sizing, line-breaking, and positioning.
    var main_margin_sums: [MAX_CHILDREN]Unit = undefined;
    for (0..child_count) |ci| {
        const mm = childMainMargins(subtree, children[ci], flex_is_column);
        main_margin_sums[ci] = mm[0] + mm[1];
    }

    // --- Phase 3 (§9.3): Collect into flex lines ---
    var line_starts: [MAX_LINES + 1]usize = undefined;
    var num_lines: usize = 0;
    {
        line_starts[0] = 0;
        if (!wrapping) {
            num_lines = 1;
            line_starts[1] = child_count;
        } else {
            var line_main: Unit = 0;
            var line_items: usize = 0;
            for (0..child_count) |ci| {
                const item_main = hypothetical_main_sizes[ci] + main_margin_sums[ci];
                const with_gap: Unit = if (line_items > 0) flex_gap else 0;
                if (line_items > 0 and line_main + with_gap + item_main > container_main and num_lines < MAX_LINES) {
                    num_lines += 1;
                    line_starts[num_lines] = ci;
                    line_main = item_main;
                    line_items = 1;
                } else {
                    line_main += with_gap + item_main;
                    line_items += 1;
                }
            }
            num_lines += 1;
            line_starts[num_lines] = child_count;
        }
    }

    // --- Phase 3b (§9.7): Resolve flexible lengths per line ---
    var used_main_sizes: [MAX_CHILDREN]Unit = undefined;
    for (0..num_lines) |line_idx| {
        const ls = line_starts[line_idx];
        const le = line_starts[line_idx + 1];

        resolveFlexibleLengths(
            children[ls..le],
            flex_base_sizes[ls..le],
            hypothetical_main_sizes[ls..le],
            used_main_sizes[ls..le],
            main_margin_sums[ls..le],
            flex_grows,
            flex_shrinks,
            container_main,
            flex_gap,
        );
    }

    // --- Phase 4: Apply resolved sizes to box tree ---
    // Each item takes its resolved main size and its content is laid out
    // again at that size (§9.4 step 7: the hypothetical cross size comes
    // from laying the item out with its used main size).
    if (!flex_is_column) {
        for (0..child_count) |ci| {
            relayout.resizeItem(layout, subtree, subtree_id, children[ci], used_main_sizes[ci]);
        }
    }

    // --- Phase 5 (§9.4): Determine cross sizes per line ---
    var line_cross_sizes: [MAX_LINES]Unit = undefined;
    var total_cross: Unit = 0;
    for (0..num_lines) |line_idx| {
        const ls = line_starts[line_idx];
        const le = line_starts[line_idx + 1];
        var max_cross: Unit = 0;
        for (ls..le) |ci| {
            const cm = childCrossMargins(subtree, children[ci], flex_is_column);
            max_cross = @max(max_cross, childCrossSize(subtree, children[ci], flex_is_column) + cm[0] + cm[1]);
        }
        line_cross_sizes[line_idx] = max_cross;
        total_cross += max_cross;
    }
    // §9.4: For a single-line flex-column container with a definite cross
    // (horizontal) size, the line cross size equals the container width so
    // centering computes offsets against the full container, not the widest
    // shrunken item. Without this, centering aligns items to each other's
    // bounding box — not to the container as the author expects.
    if (num_lines == 1 and flex_is_column and container_cross > 0) {
        // Pin to container cross-size whenever any item in the line wants
        // a non-stretch alignment (from align-items or per-item align-self).
        var any_non_stretch = align_items != .stretch;
        if (!any_non_stretch) {
            for (0..child_count) |ci| {
                const s = subtree.items(.align_self)[children[ci]];
                if (s != .auto and s != .stretch) {
                    any_non_stretch = true;
                    break;
                }
            }
        }
        if (any_non_stretch) {
            line_cross_sizes[0] = @max(line_cross_sizes[0], container_cross);
            total_cross = line_cross_sizes[0];
        }
    }

    // §9.4: Single-line container with definite cross size → line cross = container cross
    if (num_lines == 1 and container_cross > 0 and !flex_is_column) {
        line_cross_sizes[0] = @max(line_cross_sizes[0], container_cross);
        total_cross = line_cross_sizes[0];
    }
    if (num_lines > 1) total_cross += flex_gap * @as(Unit, @intCast(num_lines - 1));

    // --- Phase 6 (§9.5-9.6): Position items ---
    const reverse_cross = flex_wrap == .wrap_reverse;
    var cross_cursor: Unit = if (reverse_cross) total_cross else 0;
    // For a column flex container the block-size (height) is the MAIN-axis
    // extent — the tallest line's stacked items plus inter-item gaps — not the
    // cross extent. Track it per line and return it when flex_is_column; the
    // cross extent (cross_cursor) remains the height for a row flex.
    var max_main_extent: Unit = 0;

    for (0..num_lines) |line_idx| {
        const ls = line_starts[line_idx];
        const le = line_starts[line_idx + 1];
        const line_child_count = le - ls;
        const line_cross = line_cross_sizes[line_idx];

        if (reverse_cross) {
            cross_cursor -= line_cross;
        }

        // Compute line main extent for justify-content (outer sizes per §9.5)
        var line_total_main: Unit = 0;
        for (ls..le) |ci| {
            line_total_main += childMainSize(subtree, children[ci], flex_is_column) + main_margin_sums[ci];
        }
        if (line_child_count > 1) line_total_main += flex_gap * @as(Unit, @intCast(line_child_count - 1));
        max_main_extent = @max(max_main_extent, line_total_main);

        // Main-axis alignment (§9.5)
        const free_space = @max(0, container_main - line_total_main);
        var main_cursor: Unit = switch (justify) {
            .flex_start => 0,
            .flex_end => free_space,
            .center => @divFloor(free_space, 2),
            .space_between => 0,
        };
        const sb_gap: Unit = if (justify == .space_between and line_child_count > 1)
            @divFloor(free_space, @as(Unit, @intCast(line_child_count - 1)))
        else
            0;
        const total_item_gap = flex_gap + sb_gap;

        // Cross-axis alignment (§9.6). `align-self` on an item overrides the
        // container's `align-items` for that specific item — `.auto` defers
        // to the container. React.dev's hero <h1 class="self-center">
        // (Tailwind: `align-self: center`) is the canonical case: the parent
        // is flex-column with no explicit align-items, so the h1 wants to be
        // horizontally centered while siblings stretch.
        for (ls..le) |ci| {
            const child_idx = children[ci];
            const box_offsets = subtree.items(.box_offsets)[child_idx];
            const child_cross_sz = childCrossSize(subtree, child_idx, flex_is_column);
            const cm = childCrossMargins(subtree, child_idx, flex_is_column);
            const outer_cross_sz = child_cross_sz + cm[0] + cm[1];
            const mm = childMainMargins(subtree, child_idx, flex_is_column);
            const effective_align: BlockInfo.FlexAlign = switch (subtree.items(.align_self)[child_idx]) {
                .auto => align_items,
                .stretch => .stretch,
                .flex_start => .flex_start,
                .flex_end => .flex_end,
                .center => .center,
                .baseline => .flex_start, // baseline unsupported; fall back
            };
            // §9.4 step 11: a stretched item with an auto cross size and
            // no auto cross margins takes the line's cross size minus its
            // margins. (Column items were stretched in Phase 1b.)
            if (!flex_is_column and effective_align == .stretch and block_types[child_idx] == .block and
                subtree.items(.intrinsic)[child_idx].height_auto)
            {
                const edges = box_offsets.border_size.h - box_offsets.content_size.h;
                relayout.setContentHeight(subtree, child_idx, @max(0, line_cross - cm[0] - cm[1] - edges));
            }
            const cross_offset: Unit = cross_cursor + switch (effective_align) {
                .flex_start => 0,
                .flex_end => @max(0, line_cross - outer_cross_sz),
                .center => @max(0, @divFloor(line_cross - outer_cross_sz, 2)),
                .stretch => 0,
            };

            if (flex_is_column) {
                subtree.items(.offset)[child_idx] = .{
                    .x = cross_offset,
                    .y = main_cursor,
                };
                main_cursor += mm[0] + box_offsets.border_size.h + mm[1];
            } else {
                subtree.items(.offset)[child_idx] = .{
                    .x = main_cursor,
                    .y = cross_offset,
                };
                main_cursor += mm[0] + box_offsets.border_size.w + mm[1];
            }
            if (ci + 1 < le) main_cursor += total_item_gap;
        }

        if (!reverse_cross) {
            cross_cursor += line_cross;
            if (line_idx + 1 < num_lines) cross_cursor += flex_gap;
        } else {
            if (line_idx + 1 < num_lines) cross_cursor -= flex_gap;
        }
    }

    // Row flex: container height = cross extent. Column flex: container height
    // = main extent (CSS Flexbox §9.9 — the content block-size of a column
    // container is the sum of its items' outer main sizes plus inter-item gaps).
    if (flex_is_column) return max_main_extent;
    return if (reverse_cross) total_cross else cross_cursor;
}

/// CSS Flexbox §9.2 step 3: the main size of a flex item whose flex basis is
/// `auto` (its `width` when definite, else its max-content size). Column
/// items were already laid out at their cross size (Phase 1b), so their
/// main size is their laid-out height.
fn measureContentMainSize(layout: *zss.Layout, subtree: Subtree.View, subtree_id: Subtree.Id, child_idx: Subtree.Size, flex_is_column: bool) Unit {
    if (flex_is_column) return subtree.items(.box_offsets)[child_idx].border_size.h;
    const box_tree = layout.box_tree.ptr;
    return switch (subtree.items(.type)[child_idx]) {
        .block => intrinsic.blockBorderBoxSizes(layout, subtree, subtree_id, child_idx).max,
        .ifc_container => |ifc_id| intrinsic.ifcSizes(layout, box_tree.getIfc(ifc_id), subtree, subtree_id).max,
        .subtree_proxy => |id| intrinsic.blockBorderBoxSizes(layout, box_tree.getSubtree(id).view(), id, 0).max,
    };
}

/// CSS Flexbox §9.7: Resolve Flexible Lengths.
/// Distributes free space via flex-grow or absorbs overflow via flex-shrink.
fn resolveFlexibleLengths(
    line_children: []const Subtree.Size,
    flex_base: []const Unit,
    hypothetical: []const Unit,
    used: []Unit,
    margin_sums: []const Unit,
    flex_grows: anytype,
    flex_shrinks: anytype,
    container_main: Unit,
    flex_gap: Unit,
) void {
    const n = line_children.len;
    if (n == 0) return;

    // Step 1: Determine grow vs shrink (using outer sizes per §9.7).
    var sum_hypothetical_outer: Unit = 0;
    for (0..n) |i| {
        sum_hypothetical_outer += hypothetical[i] + margin_sums[i];
    }
    if (n > 1) sum_hypothetical_outer += flex_gap * @as(Unit, @intCast(n - 1));
    const growing = sum_hypothetical_outer <= container_main;

    // Step 2: Initialize targets and frozen state.
    var targets: [MAX_CHILDREN]Unit = undefined;
    var frozen: [MAX_CHILDREN]bool = undefined;

    for (0..n) |i| {
        targets[i] = flex_base[i];
        const ci = line_children[i];

        if (growing) {
            frozen[i] = (flex_grows[ci] == 0.0) or (flex_base[i] > hypothetical[i]);
        } else {
            frozen[i] = (flex_shrinks[ci] == 0.0) or (flex_base[i] < hypothetical[i]);
        }

        if (frozen[i]) {
            targets[i] = hypothetical[i];
        }
    }

    // Step 3: Calculate initial free space (outer sizes include margins).
    var initial_free_space: Unit = container_main;
    if (n > 1) initial_free_space -= flex_gap * @as(Unit, @intCast(n - 1));
    for (0..n) |i| {
        if (frozen[i]) {
            initial_free_space -= targets[i] + margin_sums[i];
        } else {
            initial_free_space -= flex_base[i] + margin_sums[i];
        }
    }

    // Step 4: Iterative resolution loop.
    var iterations: u32 = 0;
    while (iterations < 10) : (iterations += 1) {
        var all_frozen = true;
        for (0..n) |i| {
            if (!frozen[i]) { all_frozen = false; break; }
        }
        if (all_frozen) break;

        // Remaining free space (outer sizes include margins)
        var remaining: Unit = container_main;
        if (n > 1) remaining -= flex_gap * @as(Unit, @intCast(n - 1));
        var sum_factors: f32 = 0.0;
        for (0..n) |i| {
            if (frozen[i]) {
                remaining -= targets[i] + margin_sums[i];
            } else {
                remaining -= flex_base[i] + margin_sums[i];
                const ci = line_children[i];
                if (growing) {
                    sum_factors += flex_grows[ci];
                } else {
                    sum_factors += flex_shrinks[ci] * @as(f32, @floatFromInt(@max(1, flex_base[i])));
                }
            }
        }

        // §9.7 step 4b: sum of factors < 1 caps free space
        if (sum_factors > 0.0 and sum_factors < 1.0) {
            const scaled = @as(Unit, @intFromFloat(@round(@as(f32, @floatFromInt(initial_free_space)) * sum_factors)));
            if ((growing and scaled < remaining) or (!growing and scaled > remaining)) {
                remaining = scaled;
            }
        }

        if (sum_factors <= 0.0) break;

        // Distribute proportionally
        for (0..n) |i| {
            if (frozen[i]) continue;
            const ci = line_children[i];
            if (growing) {
                const ratio = flex_grows[ci] / sum_factors;
                targets[i] = flex_base[i] + @as(Unit, @intFromFloat(@round(@as(f32, @floatFromInt(remaining)) * ratio)));
            } else {
                const scaled_shrink = flex_shrinks[ci] * @as(f32, @floatFromInt(@max(1, flex_base[i])));
                const ratio = scaled_shrink / sum_factors;
                const abs_remaining = @as(f32, @floatFromInt(@max(0, -remaining)));
                targets[i] = flex_base[i] - @as(Unit, @intFromFloat(@round(abs_remaining * ratio)));
            }
        }

        // Freeze items that hit zero (min violation)
        var any_frozen_this_round = false;
        for (0..n) |i| {
            if (frozen[i]) continue;
            if (targets[i] < 0) {
                targets[i] = 0;
                frozen[i] = true;
                any_frozen_this_round = true;
            }
        }
        if (!any_frozen_this_round) break;
    }

    // Write results
    for (0..n) |i| {
        used[i] = @max(0, targets[i]);
    }
}

fn childMainSize(subtree: Subtree.View, child: Subtree.Size, flex_is_column: bool) Unit {
    const bo = subtree.items(.box_offsets)[child];
    return if (flex_is_column) bo.border_size.h else bo.border_size.w;
}

fn childCrossSize(subtree: Subtree.View, child: Subtree.Size, flex_is_column: bool) Unit {
    const bo = subtree.items(.box_offsets)[child];
    return if (flex_is_column) bo.border_size.w else bo.border_size.h;
}

fn childMainMargins(subtree: Subtree.View, child: Subtree.Size, flex_is_column: bool) [2]Unit {
    const m = subtree.items(.margins)[child];
    return if (flex_is_column) .{ m.top, m.bottom } else .{ m.left, m.right };
}

fn childCrossMargins(subtree: Subtree.View, child: Subtree.Size, flex_is_column: bool) [2]Unit {
    const m = subtree.items(.margins)[child];
    return if (flex_is_column) .{ m.left, m.right } else .{ m.top, m.bottom };
}

const MAX_CHILDREN = 128;
const MAX_LINES = 32;