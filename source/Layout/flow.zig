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
        .flow, .flex, .grid => {
            const containing_block_size = box_gen.containingBlockSize();
            // Check if parent is a flex row container — flex children should use
            // a reduced width to allow proper text reflow at the correct column width.
            const parent_is_flex_row = if (box_gen.stacks.block_info.top) |parent_info|
                parent_info.is_flex_container and !parent_info.flex_is_column
            else
                false;
            const flex_grow_val: f32 = if (parent_is_flex_row)
                computer.getSpecifiedValue(.box_gen, .box_style).flex_grow
            else
                0.0;
            // DEBUG: Log flex child creation
            if (parent_is_flex_row) {
                const css_cbw = @divTrunc(containing_block_size.width, 4);
                if (css_cbw < 2000) {
                    std.log.err("[FLEX-CHILD-DEBUG] Creating flex child: flex_grow={d:.2}, container_width={d}px", .{flex_grow_val, css_cbw});
                }
            }
            const layout_width: ContainingBlockWidth = if (parent_is_flex_row and flex_grow_val > 0.0) blk: {
                // For flex-grow items, estimate width by counting flex children.
                // Count DOM children of the parent node to estimate sibling count.
                const env = box_gen.getLayout().inputs.env;
                const parent_node = box_gen.stacks.block_info.top.?.node;
                var flex_child_count: u32 = 0;
                if (parent_node.firstChild(env)) |first| {
                    var sib: ?NodeId = first;
                    while (sib) |s| {
                        flex_child_count += 1;
                        sib = s.nextSibling(env);
                    }
                }
                if (flex_child_count < 1) flex_child_count = 1;
                const gap = box_gen.stacks.block_info.top.?.flex_gap;
                const total_gaps = gap * @as(Unit, @intCast(flex_child_count - 1));
                const per_child = @divFloor(@max(0, containing_block_size.width - total_gaps), @as(Unit, @intCast(flex_child_count)));
                break :blk .{ .normal = per_child };
            } else .{ .normal = containing_block_size.width };
            const sizes = solveAllSizes(computer, position, layout_width, containing_block_size.height);
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
                info.flex_wrap = box_style_specified.flex_wrap;
            }
            if (inner_block == .grid) {
                const info = &box_gen.stacks.block_info.top.?;
                info.is_grid_container = true;
                info.grid_column_gap = box_style_specified.gap;
                info.grid_row_gap = box_style_specified.gap;
                // Read grid template properties from cascade
                const grid_tmpl = computer.getSpecifiedValue(.box_gen, .grid_template);
                info.grid_columns = grid_tmpl.columns;
                info.grid_rows = grid_tmpl.rows;
                info.grid_areas = grid_tmpl.areas;
            }
            // Store per-block flex item properties and float/clear/BFC state
            {
                const info = &box_gen.stacks.block_info.top.?;
                info.flex_grow = box_style_specified.flex_grow;
                info.grid_area_hash = box_style_specified.grid_area;
                info.float_side = box_style_specified.float;
                info.clear_side = box_style_specified.clear;
                if (box_style_specified.float != .none) {
                    info.is_bfc = true;
                }
                if (box_style_specified.overflow != .visible) {
                    info.is_bfc = true;
                }
            }
            // Insert ::before pseudo-element as first child (after pushBlock descended)
            try insertPseudoElement(box_gen, node, .before);
        },
    }
}

pub fn nullNode(box_gen: *BoxGen) ?void {
    // Insert ::after pseudo-element as last child (before parent block is finalized)
    if (box_gen.stacks.block_info.top) |info| {
        insertPseudoElement(box_gen, info.node, .after) catch {};
    }
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

/// Create a virtual block box for a ::before or ::after pseudo-element.
/// For empty content (clearfix): creates a leaf block box.
/// For string content: creates a block box containing an IFC with shaped text.
fn insertPseudoElement(box_gen: *BoxGen, node: NodeId, pseudo: selectors.PseudoElement) !void {
    const layout = box_gen.getLayout();
    const computer = &layout.computer;

    // Check if this node has cascaded styles for the pseudo-element.
    if (!computer.setPseudoElement(.box_gen, node, pseudo)) return;

    // Only generate a box if content is active (not normal/none).
    const gen_content = computer.getSpecifiedValue(.box_gen, .generated_content);
    if (gen_content.content == .normal or gen_content.content == .none) return;

    // Read the pseudo-element's display and clear properties.
    const box_style_specified = computer.getSpecifiedValue(.box_gen, .box_style);
    const clear = box_style_specified.clear;

    // Compute block sizes from the pseudo-element's cascade.
    const containing_block_size = box_gen.containingBlockSize();
    const sizes = solveAllSizes(computer, .static, .{ .normal = containing_block_size.width }, containing_block_size.height);

    // Resolve content text (if any) before creating the box.
    const content_text: ?[]const u8 = switch (gen_content.content) {
        .string => |text_id| blk: {
            const t = layout.inputs.env.getText(text_id);
            break :blk if (t.len > 0) t else null;
        },
        else => null,
    };

    // Create a block box for the pseudo-element.
    box_gen.bfc_stack.top.? += 1;
    const box_style = BoxStyle{ .outer = .{ .block = .flow }, .position = .static };
    _ = try box_gen.pushFlowBlock(box_style, sizes, .normal, .none, node);

    // Apply the pseudo-element's clear value so it participates in float clearing.
    if (box_gen.stacks.block_info.top) |*info| {
        info.clear_side = clear;
    }

    if (content_text) |text| {
        // String content: create an IFC with shaped text inside the block.
        const font = computer.getSpecifiedValue(.box_gen, .font);
        try box_gen.stacks.mode.push(layout.allocator, .@"inline");
        _ = try @"inline".addPseudoElementText(box_gen, text, .{
            .font = font.font,
            .font_family = font.font_family,
            .font_size = font.font_size,
            .font_weight = font.font_weight,
        });
        assert(box_gen.stacks.mode.pop() == .@"inline");
    }

    box_gen.popFlowBlock(.normal);
    box_gen.bfc_stack.top.? -= 1;
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
            // Save auto flags before adjustWidthAndMargins clears them
            const was_auto = .{
                .inline_size = sizes.isAuto(.inline_size),
                .margin_inline_start = sizes.isAuto(.margin_inline_start),
                .margin_inline_end = sizes.isAuto(.margin_inline_end),
            };
            adjustWidthAndMargins(&sizes, percentage_base_unit);
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
                    .auto => sizes.setAuto(pair[1]),
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
/// Supports flex-wrap: items wrap to new lines when they exceed container main size.
/// For row: children placed horizontally; for column: vertically.
/// Returns auto height: total cross extent of all lines.
pub fn offsetChildBlocksFlex(
    box_tree: *BoxTree,
    subtree: Subtree.View,
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
    const skips = subtree.items(.skip);
    const out_of_flow_flags = subtree.items(.out_of_flow);
    const end = index + skip;

    const container_main = if (flex_is_column) (container_height orelse 0) else container_width;
    const container_cross = if (flex_is_column) container_width else (container_height orelse 0);
    const wrapping = flex_wrap != .nowrap;

    // --- Phase 1: IFC content measurement (row containers only) ---
    if (!flex_is_column) {
        resizeIfcContainers(box_tree, subtree, index, end);
    }

    // --- Phase 2: Collect in-flow children ---
    const MAX_CHILDREN = 128;
    var children: [MAX_CHILDREN]Subtree.Size = undefined;
    var child_count: usize = 0;
    {
        var child = index + 1;
        while (child < end) {
            if (!out_of_flow_flags[child]) {
                if (child_count < MAX_CHILDREN) {
                    children[child_count] = child;
                    child_count += 1;
                }
            } else {
                subtree.items(.offset)[child] = .{ .x = 0, .y = 0 };
            }
            child += skips[child];
        }
    }

    if (child_count == 0) return 0;

    // --- Phase 3: Break children into lines ---
    const MAX_LINES = 32;
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
                const child_main = childMainSize(subtree, children[ci], flex_is_column);
                const with_gap: Unit = if (line_items > 0) flex_gap else 0;
                if (line_items > 0 and line_main + with_gap + child_main > container_main and num_lines < MAX_LINES) {
                    num_lines += 1;
                    line_starts[num_lines] = ci;
                    line_main = child_main;
                    line_items = 1;
                } else {
                    line_main += with_gap + child_main;
                    line_items += 1;
                }
            }
            num_lines += 1;
            line_starts[num_lines] = child_count;
        }
    }

    // --- Phase 4: Per-line sizing and positioning ---
    var cross_cursor: Unit = 0;
    const reverse_cross = flex_wrap == .wrap_reverse;

    // Compute line cross sizes
    var line_cross_sizes: [MAX_LINES]Unit = undefined;
    var total_cross: Unit = 0;
    for (0..num_lines) |line_idx| {
        const ls = line_starts[line_idx];
        const le = line_starts[line_idx + 1];
        var max_cross: Unit = 0;
        for (ls..le) |ci| {
            max_cross = @max(max_cross, childCrossSize(subtree, children[ci], flex_is_column));
        }
        line_cross_sizes[line_idx] = max_cross;
        total_cross += max_cross;
    }

    // CSS Flexbox §9.4: If the flex container is single-line and has a
    // definite cross size, the flex line's cross size equals the container's
    // inner cross size (so that align-items:center works against the full
    // container height, not just the tallest child).
    if (num_lines == 1 and container_cross > 0) {
        line_cross_sizes[0] = @max(line_cross_sizes[0], container_cross);
        total_cross = line_cross_sizes[0];
    }
    if (num_lines > 1) total_cross += flex_gap * @as(Unit, @intCast(num_lines - 1));

    if (reverse_cross) {
        cross_cursor = total_cross;
    }

    for (0..num_lines) |line_idx| {
        const ls = line_starts[line_idx];
        const le = line_starts[line_idx + 1];
        const line_child_count = le - ls;
        const line_cross = line_cross_sizes[line_idx];

        if (reverse_cross) {
            cross_cursor -= line_cross;
        }

        // Measure line main extent
        var line_total_main: Unit = 0;
        var total_flex_grow: f32 = 0.0;
        for (ls..le) |ci| {
            line_total_main += childMainSize(subtree, children[ci], flex_is_column);
            total_flex_grow += subtree.items(.flex_grow)[children[ci]];
        }
        if (line_child_count > 1) line_total_main += flex_gap * @as(Unit, @intCast(line_child_count - 1));

        // Shrink non-grow items when overflowing
        const overflows = line_total_main > container_main;
        if (overflows and !flex_is_column) {
            shrinkNonGrowChildren(subtree, children[ls..le]);
            line_total_main = 0;
            for (ls..le) |ci| {
                line_total_main += childMainSize(subtree, children[ci], flex_is_column);
            }
            if (line_child_count > 1) line_total_main += flex_gap * @as(Unit, @intCast(line_child_count - 1));
        }

        // Distribute flex-grow space
        if (total_flex_grow > 0.0 and !flex_is_column) {
            distributeFlexGrow(subtree, children[ls..le], container_main, flex_gap, total_flex_grow);
            line_total_main = 0;
            for (ls..le) |ci| {
                line_total_main += childMainSize(subtree, children[ci], flex_is_column);
            }
            if (line_child_count > 1) line_total_main += flex_gap * @as(Unit, @intCast(line_child_count - 1));
        }

        // Position children on this line
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

        for (ls..le) |ci| {
            const child_idx = children[ci];
            const box_offsets = subtree.items(.box_offsets)[child_idx];
            const child_cross_sz = childCrossSize(subtree, child_idx, flex_is_column);
            const cross_offset: Unit = cross_cursor + switch (align_items) {
                .flex_start => 0,
                .flex_end => @max(0, line_cross - child_cross_sz),
                .center => @max(0, @divFloor(line_cross - child_cross_sz, 2)),
                .stretch => 0,
            };

            if (flex_is_column) {
                subtree.items(.offset)[child_idx] = .{
                    .x = cross_offset,
                    .y = main_cursor,
                };
                main_cursor += box_offsets.border_size.h;
            } else {
                subtree.items(.offset)[child_idx] = .{
                    .x = main_cursor,
                    .y = cross_offset,
                };
                main_cursor += box_offsets.border_size.w;
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

    return if (reverse_cross) total_cross else cross_cursor;
}

fn childMainSize(subtree: Subtree.View, child: Subtree.Size, flex_is_column: bool) Unit {
    const bo = subtree.items(.box_offsets)[child];
    return if (flex_is_column) bo.border_size.h else bo.border_size.w;
}

fn childCrossSize(subtree: Subtree.View, child: Subtree.Size, flex_is_column: bool) Unit {
    const bo = subtree.items(.box_offsets)[child];
    return if (flex_is_column) bo.border_size.w else bo.border_size.h;
}

/// Resize IFC containers to their content width.
fn resizeIfcContainers(
    box_tree: *BoxTree,
    subtree: Subtree.View,
    start: Subtree.Size,
    end: Subtree.Size,
) void {
    const types_slice = subtree.items(.type);
    const out_of_flow_flags = subtree.items(.out_of_flow);
    const skips_slice = subtree.items(.skip);
    var child = start + 1;
    while (child < end) {
        if (!out_of_flow_flags[child]) {
            switch (types_slice[child]) {
                .ifc_container => |ifc_id| {
                    const ifc = box_tree.getIfc(ifc_id);
                    if (ifc.glyphs.len == 0) {
                        const bo = &subtree.items(.box_offsets)[child];
                        bo.border_size.w = 0;
                        bo.content_size.w = 0;
                    } else {
                        var max_line_width: Unit = 0;
                        for (ifc.line_boxes.items) |line_box| {
                            var line_width: Unit = 0;
                            var i = line_box.elements[0];
                            while (i < line_box.elements[1]) {
                                const glyph_idx = ifc.glyphs.items(.index)[i];
                                line_width += ifc.glyphs.items(.metrics)[i].advance;
                                i += 1;
                                if (glyph_idx == 0 and i < line_box.elements[1]) i += 1;
                            }
                            max_line_width = @max(max_line_width, line_width);
                        }
                        const bo = &subtree.items(.box_offsets)[child];
                        const left_edge = bo.content_pos.x;
                        bo.border_size.w = max_line_width + left_edge * 2;
                        bo.content_size.w = max_line_width;
                    }
                },
                else => {},
            }
        }
        child += skips_slice[child];
    }
}

/// Shrink non-grow flex items to content width when overflowing.
fn shrinkNonGrowChildren(
    subtree: Subtree.View,
    line_children: []const Subtree.Size,
) void {
    const flex_grows = subtree.items(.flex_grow);
    for (line_children) |child| {
        if (flex_grows[child] == 0.0) {
            const bo = subtree.items(.box_offsets)[child];
            const child_skip = subtree.items(.skip)[child];
            var max_content_right: Unit = 0;
            var grandchild = child + 1;
            const child_end = child + child_skip;
            while (grandchild < child_end) {
                if (!subtree.items(.out_of_flow)[grandchild]) {
                    const gbo = subtree.items(.box_offsets)[grandchild];
                    const goff = subtree.items(.offset)[grandchild];
                    max_content_right = @max(max_content_right, goff.x + gbo.border_pos.x + gbo.border_size.w);
                }
                grandchild += subtree.items(.skip)[grandchild];
            }
            const left_edge = bo.content_pos.x;
            const content_width = max_content_right + left_edge + left_edge;
            const new_w = @min(bo.border_size.w, @max(left_edge * 2, content_width));
            subtree.items(.box_offsets)[child].border_size.w = new_w;
            subtree.items(.box_offsets)[child].content_size.w = new_w - left_edge * 2;
        }
    }
}

/// Distribute remaining space to flex-grow items proportionally.
fn distributeFlexGrow(
    subtree: Subtree.View,
    line_children: []const Subtree.Size,
    container_main: Unit,
    flex_gap: Unit,
    total_flex_grow: f32,
) void {
    const flex_grows = subtree.items(.flex_grow);
    var non_grow_main: Unit = 0;
    var total_items: usize = 0;
    for (line_children) |child| {
        if (flex_grows[child] == 0.0) {
            non_grow_main += subtree.items(.box_offsets)[child].border_size.w;
        }
        total_items += 1;
    }
    const total_gaps = flex_gap * @as(Unit, @intCast(@max(1, total_items) - 1));
    const avail_for_grow = @max(0, container_main - non_grow_main - total_gaps);
    for (line_children) |child| {
        const grow = flex_grows[child];
        if (grow > 0.0) {
            const target_w = @as(Unit, @intFromFloat(@round(@as(f32, @floatFromInt(avail_for_grow)) * grow / total_flex_grow)));
            const left_edge = subtree.items(.box_offsets)[child].content_pos.x;
            subtree.items(.box_offsets)[child].border_size.w = target_w;
            subtree.items(.box_offsets)[child].content_size.w = @max(0, target_w - left_edge * 2);
        }
    }
}