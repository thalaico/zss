const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const NodeId = zss.Environment.NodeId;
const StyleComputer = zss.Layout.StyleComputer;
const Unit = zss.math.Unit;

const BoxGen = zss.Layout.BoxGen;
const BlockComputedSizes = BoxGen.BlockComputedSizes;
const BlockUsedSizes = BoxGen.BlockUsedSizes;
const SctBuilder = BoxGen.StackingContextTreeBuilder;
const SizeMode = BoxGen.SizeMode;
const BlockInfo = BoxGen.BlockInfo;

const solve = @import("./solve.zig");
const @"inline" = @import("./inline.zig");

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
        .flow, .flex => {
            const containing_block_size = box_gen.containingBlockSize();
            const sizes = solveAllSizes(computer, position, .{ .normal = containing_block_size.width }, containing_block_size.height);
            const stacking_context = solveStackingContext(computer, position);
            // Read flex properties before commitNode consumes the node state
            const box_style_specified = computer.getSpecifiedValue(.box_gen, .box_style);
            // Read and commit font group so child text nodes inherit font-size
            // during layout (getTextFont uses InheritedValue from box_gen stage).
            const font_specified = computer.getSpecifiedValue(.box_gen, .font);
            computer.setComputedValue(.box_gen, .font, font_specified);
            computer.commitNode(.box_gen);

            try pushBlock(box_gen, node, sizes, stacking_context, position);
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
                info.flex_gap = box_style_specified.gap;
            }
            // Set float, clear, and BFC properties on the block
            {
                const info = &box_gen.stacks.block_info.top.?;
                info.float_side = box_style_specified.float;
                info.clear_side = box_style_specified.clear;
                if (box_style_specified.float != .none) {
                    info.is_bfc = true;
                }
                if (box_style_specified.overflow != .visible) {
                    info.is_bfc = true;
                }
            }
        },
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
    if (bfc_depth.* == 0) return null;
    box_gen.popFlowBlock(.normal);
    box_gen.getLayout().popNode();
}

pub const ContainingBlockWidth = union(SizeMode) {
    normal: Unit,
    stf,
};

pub fn solveAllSizes(
    computer: *StyleComputer,
    position: BoxTree.BoxStyle.Position,
    containing_block_width: ContainingBlockWidth,
    containing_block_height: ?Unit,
) BlockUsedSizes {
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    const specified_sizes = BlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .insets = computer.getSpecifiedValue(.box_gen, .insets),
    };
    const percentage_base_unit = switch (containing_block_width) {
        .normal => |value| value,
        .stf => 0,
    };

    var computed_sizes: BlockComputedSizes = undefined;
    var sizes: BlockUsedSizes = undefined;
    solveWidthAndHorizontalMargins(specified_sizes, containing_block_width, &computed_sizes, &sizes);
    solveHorizontalBorderPadding(specified_sizes.horizontal_edges, percentage_base_unit, border_styles, &computed_sizes.horizontal_edges, &sizes);
    solveHeight(specified_sizes.content_height, containing_block_height, &computed_sizes.content_height, &sizes);
    solveVerticalEdges(specified_sizes.vertical_edges, percentage_base_unit, border_styles, &computed_sizes.vertical_edges, &sizes);
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
    switch (containing_block_width) {
        .normal => {
            adjustWidthAndMargins(&sizes, percentage_base_unit);
            // TODO: Do this in adjustWidthAndMargins
            sizes.inline_size_untagged = solve.clampSize(sizes.get(.inline_size).?, sizes.min_inline_size, sizes.max_inline_size);
        },
        .stf => {},
    }
    if (sizes.get(.block_size)) |block_size| {
        sizes.block_size_untagged = solve.clampSize(block_size, sizes.min_block_size, sizes.max_block_size);
    }

    computed_sizes.insets = solve.insets(specified_sizes.insets);
    solveInsets(computed_sizes.insets, position, &sizes);

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
        .none => {
            computed.content_width.max_width = .none;
            sizes.max_inline_size = std.math.maxInt(Unit);
        },
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
        .auto => {
            computed.content_width.width = .auto;
            sizes.setAuto(.inline_size);
        },
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
        .auto => {
            computed.horizontal_edges.margin_left = .auto;
            sizes.setAuto(.margin_inline_start);
        },
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
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
            sizes.setAuto(.margin_inline_end);
        },
    }
}

fn solveHorizontalBorderPadding(
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
    }
}

fn solveHeight(
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
        .none => {
            computed.max_height = .none;
            sizes.max_block_size = std.math.maxInt(Unit);
        },
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
        .auto => {
            computed.height = .auto;
            sizes.setAuto(.block_size);
        },
    }
}

/// This is an implementation of CSS2§10.5 and CSS2§10.6.3.
fn solveVerticalEdges(
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
        .auto => {
            computed.margin_top = .auto;
            sizes.margin_block_start = 0;
        },
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
        .auto => {
            computed.margin_bottom = .auto;
            sizes.margin_block_end = 0;
        },
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
                    .auto => sizes.setAuto(pair[1]),
                }
            }
        },
        .absolute, .fixed => {
            // Absolute positioning: insets computed during cosmetic layout
            // For now, set all insets to 0 in flow layout
            inline for (.{
                .inset_inline_start,
                .inset_inline_end,
                .inset_block_start,
                .inset_block_end,
            }) |field| {
                sizes.setValue(field, 0);
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

/// Position children of a block container, handling normal flow, floats, and clears.
/// Floated children are placed at the left/right edge at the current line position.
/// Clear children are pushed below the relevant floats.
/// Returns the auto height of the container.
/// Result of offsetChildBlocks: auto_height plus first-child's escaped margin
/// (for parent-child margin collapsing, CSS 2.1 Section 8.3.1).
pub const OffsetResult = struct {
    auto_height: Unit,
    /// Margin that escapes through the parent's top edge when the parent has
    /// no border-top or padding-top. Caller must adjust parent's margin.
    escaped_margin_top: Unit,
};

pub fn offsetChildBlocks(
    subtree: Subtree.View,
    index: Subtree.Size,
    skip: Subtree.Size,
    container_width: Unit,
    /// border_block_start + padding_block_start of the parent. 0 means the
    /// first child's top margin can escape (parent-child collapsing).
    parent_block_start_edge: Unit,
) OffsetResult {
    const skips = subtree.items(.skip);
    const out_of_flow_flags = subtree.items(.out_of_flow);
    const float_sides = subtree.items(.float_side);
    const clear_sides = subtree.items(.clear_side);
    var child = index + 1;
    const end = index + skip;

    // CSS 2.1 Section 8.3.1: Collapsing margins.
    // `cursor` tracks the bottom of the last border box; `prev_margin`
    // holds the previous sibling's bottom margin for collapsing.
    var cursor: Unit = 0;
    var prev_margin: Unit = 0;
    var first_normal_child = true;
    var escaped_margin_top: Unit = 0;
    var float_left_bottom: Unit = 0;
    var float_right_bottom: Unit = 0;

    while (child < end) {
        if (out_of_flow_flags[child]) {
            subtree.items(.offset)[child] = .{ .x = 0, .y = 0 };
        } else {
            const float_side = float_sides[child];
            const clear_side = clear_sides[child];
            const box_offsets = subtree.items(.box_offsets)[child];
            const margins = subtree.items(.margins)[child];
            const margin_top = box_offsets.border_pos.y; // = margin_block_start
            const border_box_h = box_offsets.border_size.h;
            const margin_bottom = margins.bottom;

            // Apply clear: push cursor below relevant floats
            switch (clear_side) {
                .left => cursor = @max(cursor, float_left_bottom),
                .right => cursor = @max(cursor, float_right_bottom),
                .both => cursor = @max(cursor, @max(float_left_bottom, float_right_bottom)),
                .none => {},
            }

            switch (float_side) {
                .left => {
                    const child_height = margin_top + border_box_h + margin_bottom;
                    subtree.items(.offset)[child] = .{ .x = 0, .y = cursor };
                    float_left_bottom = @max(float_left_bottom, cursor + child_height);
                },
                .right => {
                    const child_height = margin_top + border_box_h + margin_bottom;
                    const child_border_width = box_offsets.border_pos.x + box_offsets.border_size.w;
                    const x = @max(0, container_width - child_border_width);
                    subtree.items(.offset)[child] = .{ .x = x, .y = cursor };
                    float_right_bottom = @max(float_right_bottom, cursor + child_height);
                },
                .none => {
                    if (first_normal_child and parent_block_start_edge == 0 and cursor == 0) {
                        // Parent-child margin collapsing: first child's top margin
                        // escapes through the parent (which has no border/padding-top,
                        // no floats above, and no clearance). CSS 2.1 Section 8.3.1.
                        escaped_margin_top = margin_top;
                        subtree.items(.offset)[child] = .{ .x = 0, .y = -margin_top };
                        cursor = border_box_h;
                        prev_margin = margin_bottom;
                    } else {
                        // Collapse this child's top margin with previous sibling's bottom margin.
                        const collapsed = @max(prev_margin, margin_top);
                        const border_box_y = cursor + collapsed;
                        subtree.items(.offset)[child] = .{ .x = 0, .y = border_box_y - margin_top };
                        cursor = border_box_y + border_box_h;
                        prev_margin = margin_bottom;
                    }
                    first_normal_child = false;
                },
            }
        }
        child += skips[child];
    }

    // Include the last normal-flow child's bottom margin in auto height.
    const normal_height = cursor + prev_margin;
    return .{
        .auto_height = @max(normal_height, @max(float_left_bottom, float_right_bottom)),
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

/// Offset children of a flex container along the main axis.
/// For row: children are placed horizontally; for column: vertically.
/// Returns auto height: max child height (row) or total height + gaps (column).
pub fn offsetChildBlocksFlex(
    subtree: Subtree.View,
    index: Subtree.Size,
    skip: Subtree.Size,
    container_width: Unit,
    container_height: ?Unit,
    justify: BlockInfo.FlexJustify,
    align_items: BlockInfo.FlexAlign,
    flex_gap: Unit,
    flex_is_column: bool,
) Unit {
    const skips = subtree.items(.skip);
    const out_of_flow_flags = subtree.items(.out_of_flow);
    const end = index + skip;

    // Pass 1: measure total main-axis extent and max cross-axis extent
    var child = index + 1;
    var total_main: Unit = 0;
    var max_cross: Unit = 0;
    var child_count: usize = 0;
    while (child < end) {
        if (!out_of_flow_flags[child]) {
            const box_offsets = subtree.items(.box_offsets)[child];
            if (flex_is_column) {
                total_main += box_offsets.border_pos.y + box_offsets.border_size.h;
                max_cross = @max(max_cross, box_offsets.border_pos.x + box_offsets.border_size.w);
            } else {
                total_main += box_offsets.border_pos.x + box_offsets.border_size.w;
                max_cross = @max(max_cross, box_offsets.border_pos.y + box_offsets.border_size.h);
            }
            child_count += 1;
        }
        child += skips[child];
    }
    // Add gap spacing between children
    if (child_count > 1) total_main += flex_gap * @as(Unit, @intCast(child_count - 1));

    const container_main = if (flex_is_column) (container_height orelse 0) else container_width;
    const container_cross = if (flex_is_column) container_width else (container_height orelse max_cross);
    const free_space = @max(0, container_main - total_main);

    // Compute starting main-axis position based on justify-content
    var main_cursor: Unit = switch (justify) {
        .flex_start => 0,
        .flex_end => free_space,
        .center => @divFloor(free_space, 2),
        .space_between => 0,
    };
    // Gap: CSS gap + additional space-between gap
    const sb_gap: Unit = if (justify == .space_between and child_count > 1)
        @divFloor(free_space, @as(Unit, @intCast(child_count - 1)))
    else
        0;
    const total_gap = flex_gap + sb_gap;

    // Pass 2: position children
    child = index + 1;
    var placed: usize = 0;
    while (child < end) {
        if (out_of_flow_flags[child]) {
            subtree.items(.offset)[child] = .{ .x = 0, .y = 0 };
        } else {
            const box_offsets = subtree.items(.box_offsets)[child];
            // Cross-axis alignment
            const child_cross = if (flex_is_column)
                box_offsets.border_pos.x + box_offsets.border_size.w
            else
                box_offsets.border_pos.y + box_offsets.border_size.h;
            const cross_offset: Unit = switch (align_items) {
                .flex_start => 0,
                .flex_end => @max(0, container_cross - child_cross),
                .center => @max(0, @divFloor(container_cross - child_cross, 2)),
                .stretch => 0, // TODO: stretch child to container cross size
            };
            if (flex_is_column) {
                subtree.items(.offset)[child] = .{
                    .x = cross_offset,
                    .y = main_cursor,
                };
                main_cursor += box_offsets.border_pos.y + box_offsets.border_size.h;
            } else {
                subtree.items(.offset)[child] = .{
                    .x = main_cursor,
                    .y = cross_offset,
                };
                main_cursor += box_offsets.border_pos.x + box_offsets.border_size.w;
            }
            placed += 1;
            if (placed < child_count)
                main_cursor += total_gap;
        }
        child += skips[child];
    }

    // For row: auto height is max cross (tallest child)
    // For column: auto height is total main extent (sum of children + gaps)
    return if (flex_is_column) total_main else max_cross;
}