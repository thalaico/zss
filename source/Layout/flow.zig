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
            // Check if parent is a flex or grid container — CSS spec says float
            // and clear have no effect on flex/grid items, and flex children should
            // use a reduced width for proper text reflow.
            const parent_is_flex_row = if (box_gen.stacks.block_info.top) |parent_info|
                parent_info.is_flex_container and !parent_info.flex_is_column
            else
                false;
            const parent_is_flex_or_grid = if (box_gen.stacks.block_info.top) |parent_info|
                parent_info.is_flex_container or parent_info.is_grid_container
            else
                false;
            // Read box_style early so flex properties are available after commitNode.
            const box_style_specified = computer.getSpecifiedValue(.box_gen, .box_style);
            const layout_width: ContainingBlockWidth = if (parent_is_flex_row) blk: {
                // CSS Flexbox §9: flex items are initially laid out at the
                // container's full width. After all children are laid out,
                // offsetChildBlocksFlex resolves flexible lengths per §9.7
                // and re-lays out text at the resolved width.
                break :blk .{ .normal = containing_block_size.width };
            } else
                .{ .normal = containing_block_size.width };
            const sizes = solveAllSizes(computer, position, layout_width, containing_block_size.height);
            const stacking_context = solveStackingContext(computer, position);
            // Read and commit font group so child text nodes inherit font-size
            // during layout (getTextFont uses InheritedValue from box_gen stage).
            var font_specified = computer.getSpecifiedValue(.box_gen, .font);
            // Resolve font-size em → px using parent's computed font-size.
            font_specified.font_size = .{ .px = computer.resolvedFontSizePx(.box_gen) };
            // Chrome `default_fixed_font_size` quirk: monospace generic family
            // with UA-default 16px swaps to 13px. Must happen here (box_gen)
            // so text runs + line-box metrics use the quirked size.
            if (font_specified.font_family == .monospace and font_specified.font_size.px_val() == 16.0) {
                font_specified.font_size = .{ .px = 13.0 };
            }
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
                info.flex_gap = box_style_specified.column_gap;
                info.flex_wrap = box_style_specified.flex_wrap;
            }
            if (inner_block == .grid) {
                const info = &box_gen.stacks.block_info.top.?;
                info.is_grid_container = true;
                info.grid_column_gap = box_style_specified.column_gap;
                info.grid_row_gap = box_style_specified.row_gap;
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

    // Resolve content text (if any) before creating the box. Whitespace-only
    // content (e.g. `::before { content: " " }` used for the Foundation/Bootstrap
    // clearfix + `display: table` trick) should NOT generate an IFC — the space
    // is a spec-approved marker to force Chrome's table-wrapper rendering, not a
    // visible glyph. Rendering it as an IFC adds one line-height of vertical
    // space at every `.row:before` on the page, shifting all downstream content
    // downward (observed on Heroku-login @800, where the login form sat ~15px
    // lower than Chrome because of multiple clearfix `.row::before` nodes).
    const content_text: ?[]const u8 = switch (gen_content.content) {
        .string => |text_id| blk: {
            const t = layout.inputs.env.getText(text_id);
            if (t.len == 0) break :blk null;
            var all_ws = true;
            for (t) |ch| {
                if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') {
                    all_ws = false;
                    break;
                }
            }
            break :blk if (all_ws) null else t;
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
            .font_style = font.font_style,
            .text_transform = font.text_transform,
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
pub fn solveAllSizes(
    computer: *StyleComputer,
    position: BoxTree.BoxStyle.Position,
    containing_block_width: ContainingBlockWidth,
    containing_block_height: ?Unit,
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
            sizes.was_auto_inline_size = was_auto.inline_size;
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
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
            sizes.setAuto(.margin_inline_end);
        },
        .em => unreachable,
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
        .em => unreachable,
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
        .auto => {
            computed.height = .auto;
            sizes.setAuto(.block_size);
        },
        .em => unreachable,
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

/// Per-block-container record of placed floats, used by IFC layout to query
/// line-box exclusions (CSS 2.1 §9.5).
///
/// Floats are positioned during the block container's `popFlowBlock` (after
/// each float child closes). IFC layout (`splitIntoLineBoxes`) running for a
/// sibling text node consults this list to narrow each line's available
/// width based on float rectangles intersecting the line's y-range.
///
/// Stage 1 simplification: floats are recorded with y = 0 (assumes the float
/// is the first content of its parent block, so cursor = 0 when it's placed).
/// Width comes from the float's resolved border-box width, height includes
/// margins. Margin-collapsing edge cases and stacked floats are not yet
/// modeled — those produce slightly wrong line wraps but no panics.
pub const FloatContext = struct {
    placed_floats: [MAX_FLOATS]PlacedFloat = undefined,
    placed_count: u8 = 0,

    pub const MAX_FLOATS = 8;

    pub const Side = enum { left, right };

    pub const PlacedFloat = struct {
        side: Side,
        x: Unit,
        y: Unit,
        w: Unit,
        h: Unit,
        /// Subtree index of the float box, used by
        /// `finalizeFloatRectangles` to look up the canonical
        /// position/size set by `offsetChildBlocks` and overwrite the
        /// provisional values registered at `popFlowBlock` time.
        /// 0 means "no link" (legacy registration path).
        child_index: BoxTree.Subtree.Size = 0,
    };

    /// Compute line-box exclusion for a line at line_y of height line_h.
    /// `line_y` is in the parent block's content-box coordinates (same space
    /// as PlacedFloat.y). Returns the left edge offset and right edge limit.
    pub fn getLineExclusion(
        self: *const FloatContext,
        line_y: Unit,
        line_h: Unit,
        container_width: Unit,
    ) struct { left_offset: Unit, right_limit: Unit } {
        var left_offset: Unit = 0;
        var right_limit: Unit = container_width;
        var i: u8 = 0;
        while (i < self.placed_count) : (i += 1) {
            const f = self.placed_floats[i];
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

    pub fn registerFloat(self: *FloatContext, side: Side, x: Unit, y: Unit, w: Unit, h: Unit) void {
        if (self.placed_count >= MAX_FLOATS) return;
        self.placed_floats[self.placed_count] = .{ .side = side, .x = x, .y = y, .w = w, .h = h };
        self.placed_count += 1;
    }

    pub fn registerFloatWithIndex(
        self: *FloatContext,
        side: Side,
        x: Unit,
        y: Unit,
        w: Unit,
        h: Unit,
        child_index: BoxTree.Subtree.Size,
    ) void {
        if (self.placed_count >= MAX_FLOATS) return;
        self.placed_floats[self.placed_count] = .{ .side = side, .x = x, .y = y, .w = w, .h = h, .child_index = child_index };
        self.placed_count += 1;
    }
};

/// Walk the parent's `float_ctx` and overwrite each float entry's
/// rectangle with the canonical position+size set by `offsetChildBlocks`.
/// Called from `popFlowBlock` *after* `offsetChildBlocks` has finalized
/// float widths (via `floatContentWidth`) and stacked x-positions. The
/// IFC line-exclusion rectangle then matches what's actually rendered.
pub fn finalizeFloatRectangles(subtree: BoxTree.Subtree.View, float_ctx: *FloatContext) void {
    var i: u8 = 0;
    while (i < float_ctx.placed_count) : (i += 1) {
        const idx = float_ctx.placed_floats[i].child_index;
        if (idx == 0) continue; // legacy registration without a link
        const bo = subtree.items(.box_offsets)[idx];
        const off = subtree.items(.offset)[idx];
        const margins = subtree.items(.margins)[idx];
        float_ctx.placed_floats[i].x = off.x + bo.border_pos.x;
        float_ctx.placed_floats[i].y = off.y + bo.border_pos.y;
        float_ctx.placed_floats[i].w = bo.border_size.w;
        float_ctx.placed_floats[i].h = bo.border_size.h + margins.top + margins.bottom;
    }
}

/// Re-split direct IFC children of a block whose float_ctx was just
/// updated by `finalizeFloatRectangles`, so their line boxes pick up the
/// corrected float exclusion rectangles. Each IFC's stored
/// `persisted_parent_float_ctx` is also refreshed so subsequent
/// re-layouts (flex Phase 4, grid relayout) use the corrected context.
/// Returns the cumulative height delta — caller can grow the parent if
/// needed; for now we leave parent height alone since offsetChildBlocks
/// already finalized it. The IFC's own `border_size.h` is kept.
pub fn resplitDirectIfcsWithFloats(
    layout: *@import("../zss.zig").Layout,
    subtree: BoxTree.Subtree.View,
    parent_index: BoxTree.Subtree.Size,
    parent_skip: BoxTree.Subtree.Size,
    float_ctx: *const FloatContext,
) void {
    if (float_ctx.placed_count == 0) return;
    const inline_layout = @import("./inline.zig");
    const types_slice = subtree.items(.type);
    const skips = subtree.items(.skip);
    const end = parent_index + parent_skip;
    var gc = parent_index + 1;
    while (gc < end) {
        if (subtree.items(.out_of_flow)[gc]) {
            gc += skips[gc];
            continue;
        }
        switch (types_slice[gc]) {
            .ifc_container => |ifc_id| {
                const ifc = layout.box_tree.ptr.getIfc(ifc_id);
                // Translate float y from parent-content-box coords to
                // IFC-local coords. line_y inside splitIntoLineBoxes
                // starts at 0 corresponding to the IFC's top edge in the
                // parent; without translation, floats placed below the
                // IFC's top would never appear to overlap any line.
                const ifc_offset_y = subtree.items(.offset)[gc].y + subtree.items(.box_offsets)[gc].border_pos.y;
                var translated = float_ctx.*;
                var ti: u8 = 0;
                while (ti < translated.placed_count) : (ti += 1) {
                    translated.placed_floats[ti].y -= ifc_offset_y;
                }
                ifc.persisted_parent_float_ctx = translated;
                const ifc_w = subtree.items(.box_offsets)[gc].content_size.w;
                ifc.line_boxes.clearRetainingCapacity();
                _ = inline_layout.splitIntoLineBoxes(layout, subtree, ifc, ifc_w, translated) catch {};
            },
            else => {},
        }
        gc += skips[gc];
    }
}


pub fn offsetChildBlocks(
    subtree: Subtree.View,
    index: Subtree.Size,
    skip: Subtree.Size,
    container_width: Unit,
    /// border_block_start + padding_block_start of the parent. 0 means the
    /// first child's top margin can escape (parent-child collapsing).
    parent_block_start_edge: Unit,
    /// Optional box_tree pointer used by `floatContentWidth` to resolve the
    /// natural max-content width of an `ifc_container` child. When null,
    /// falls back to the IFC container's stored border_size.w (which equals
    /// the containing block width, NOT the IFC's actual content extent).
    box_tree: ?*const BoxTree,
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
    // Horizontal tracking for side-by-side float placement.
    // Left floats accumulate rightward; right floats accumulate leftward.
    var float_left_x: Unit = 0;
    var float_left_line_y: Unit = 0;
    var float_right_x: Unit = container_width;
    var float_right_line_y: Unit = 0;

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

            // Apply clear: push cursor below relevant floats and reset float x
            switch (clear_side) {
                .left => {
                    cursor = @max(cursor, float_left_bottom);
                    float_left_x = 0;
                    float_left_line_y = cursor;
                },
                .right => {
                    cursor = @max(cursor, float_right_bottom);
                    float_right_x = container_width;
                    float_right_line_y = cursor;
                },
                .both => {
                    cursor = @max(cursor, @max(float_left_bottom, float_right_bottom));
                    float_left_x = 0;
                    float_left_line_y = cursor;
                    float_right_x = container_width;
                    float_right_line_y = cursor;
                },
                .none => {},
            }

            switch (float_side) {
                .left => {
                    const child_skip = skips[child];
                    // CSS §10.3.5: Floated elements with auto width use shrink-to-fit.
                    // Measure the max content right of descendants to determine used width.
                    const content_w = floatContentWidth(subtree, child, child_skip, box_offsets, box_tree);
                    const child_border_width = content_w;
                    const child_height = margin_top + border_box_h + margin_bottom;
                    // Also shrink the float's border-box to content width.
                    subtree.items(.box_offsets)[child].border_size.w = @max(0, content_w - box_offsets.border_pos.x);
                    subtree.items(.box_offsets)[child].content_size.w = @max(0, content_w - box_offsets.content_pos.x * 2);
                    // If this float doesn't fit on the current line, wrap.
                    if (float_left_x > 0 and float_left_x + child_border_width > container_width) {
                        float_left_line_y = float_left_bottom;
                        float_left_x = 0;
                    }
                    // Use the higher of cursor and current float line.
                    const y = @max(cursor, float_left_line_y);
                    subtree.items(.offset)[child] = .{ .x = float_left_x, .y = y };
                    float_left_x += child_border_width;
                    float_left_bottom = @max(float_left_bottom, y + child_height);
                },
                .right => {
                    const child_skip = skips[child];
                    const content_w = floatContentWidth(subtree, child, child_skip, box_offsets, box_tree);
                    const child_border_width = content_w;
                    const child_height = margin_top + border_box_h + margin_bottom;
                    subtree.items(.box_offsets)[child].border_size.w = @max(0, content_w - box_offsets.border_pos.x);
                    subtree.items(.box_offsets)[child].content_size.w = @max(0, content_w - box_offsets.content_pos.x * 2);
                    // If this float doesn't fit, wrap.
                    if (float_right_x < container_width and float_right_x - child_border_width < 0) {
                        float_right_line_y = float_right_bottom;
                        float_right_x = container_width;
                    }
                    const y = @max(cursor, float_right_line_y);
                    const x = @max(0, float_right_x - child_border_width);
                    subtree.items(.offset)[child] = .{ .x = x, .y = y };
                    float_right_x = x;
                    float_right_bottom = @max(float_right_bottom, y + child_height);
                },
                .none => {
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
                },
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
        .auto_height = @max(normal_height, @max(float_left_bottom, float_right_bottom)),
        .escaped_margin_top = escaped_margin_top,
    };
}

/// Compute the content-dependent width for a floated element.
/// CSS §10.3.5: floated elements with auto width use shrink-to-fit.
/// Approximation: measure the rightmost edge of all direct children,
/// using IFC's natural max-content width (longest_line_box_length) for
/// `ifc_container` children, descendant max for nested blocks, and the
/// stored border_size.w otherwise.
pub fn floatContentWidth(
    subtree: Subtree.View,
    child: Subtree.Size,
    child_skip: Subtree.Size,
    bo: BoxTree.BoxOffsets,
    box_tree: ?*const BoxTree,
) Unit {
    const skips_slice = subtree.items(.skip);
    const types = subtree.items(.type);
    var max_content_right: Unit = 0;
    var gc = child + 1;
    const child_end = child + child_skip;
    while (gc < child_end) {
        if (!subtree.items(.out_of_flow)[gc]) {
            const gc_skip = skips_slice[gc];
            const gbo = subtree.items(.box_offsets)[gc];
            const goff = subtree.items(.offset)[gc];
            const gc_x = goff.x + gbo.border_pos.x;
            // Special-case IFC containers: their stored border_size.w equals
            // the containing block width (where lines wrap), NOT the actual
            // content extent. Look up the IFC's `longest_line_box_length`
            // — the natural max-content width of the inline content — when
            // a box_tree is available. Without it, fall back to border_size.w
            // and floats will refuse to shrink below their parent.
            const ifc_natural_w: ?Unit = blk: {
                if (box_tree == null) break :blk null;
                switch (types[gc]) {
                    .ifc_container => |ifc_id| {
                        const ifc = box_tree.?.getIfc(ifc_id);
                        break :blk ifc.longest_line_box_length;
                    },
                    else => break :blk null,
                }
            };
            if (ifc_natural_w) |w| {
                max_content_right = @max(max_content_right, gc_x + w);
            } else if (gc_skip == 1) {
                // Leaf block: its border_size.w is the actual content width.
                max_content_right = @max(max_content_right, gc_x + gbo.border_size.w);
            } else {
                // Non-leaf block: recurse to find content width.
                const inner_w = floatContentWidth(subtree, gc, gc_skip, gbo, box_tree);
                max_content_right = @max(max_content_right, gc_x + inner_w);
            }
        }
        gc += skips_slice[gc];
    }
    const left_edge = bo.content_pos.x;
    if (max_content_right > 0) {
        return max_content_right + left_edge;
    }
    // No descendants: use the element's own border-box width.
    return bo.border_pos.x + bo.border_size.w;
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
            flex_base_sizes[ci] = measureContentMainSize(box_tree, subtree, child_idx, flex_is_column);
        }

        // Hypothetical main size = flex base size clamped at zero
        hypothetical_main_sizes[ci] = @max(0, flex_base_sizes[ci]);
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
                const item_main = hypothetical_main_sizes[ci];
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
            flex_grows,
            flex_shrinks,
            container_main,
            flex_gap,
        );
    }

    // --- Phase 4: Apply resolved sizes to box tree ---
    // Resize items to their resolved main size and re-layout IFC text content.
    if (!flex_is_column) {
        for (0..child_count) |ci| {
            const child_idx = children[ci];
            const resolved_w = used_main_sizes[ci];
            const bo = &subtree.items(.box_offsets)[child_idx];
            const left_edge = bo.content_pos.x;

            if (resolved_w != bo.border_size.w) {
                const old_content_w = bo.content_size.w;
                bo.border_size.w = resolved_w;
                bo.content_size.w = @max(0, resolved_w - left_edge * 2);

                // Re-layout IFC (text) containers at the new width
                relayoutIfcAtWidth(layout, subtree, child_idx, bo.content_size.w, old_content_w);
            }
        }
    }

    // --- Phase 4b: Shrink items to content cross-size when not stretching ---
    // Children in a flex column are initially laid out at container width
    // (like ordinary block children), so their border_size.w equals the
    // container cross-size. The cross-axis algorithm (§9.4) assumes items
    // already have their final cross size so center/flex-start/flex-end
    // offsets can be computed; with a stretched cross size there's nothing
    // to center. When align-items != stretch, shrink each flex-column item
    // to its max-content cross size so the later centering math produces
    // a real offset. Measurement uses the same walk as §9.2's main-size
    // auto measurement (`measureContentMainSize`) but along the cross axis
    // — for flex-column, that's the HORIZONTAL content extent, i.e. the
    // measurement you'd get by asking the item for its main-size with
    // flex_is_column=false.
    //
    // Pages that authored `flex-direction: column; align-items: center`
    // for hero sections (React.dev, most Tailwind landing pages) rely on
    // this shrink-to-content to center their title + subtitle + CTA row.
    // Without it, each item is 100% wide with left-aligned text — visually
    // identical to no flex alignment at all.
    if (flex_is_column) {
        for (0..child_count) |ci| {
            const child_idx = children[ci];
            // Per §9.4, an item's cross size is its hypothetical (content)
            // cross size unless `align-items: stretch` (or effective stretch
            // via auto + container stretch) applies. align-self: auto
            // inherits from align-items; any other value wins.
            const self = subtree.items(.align_self)[child_idx];
            const stretch_effective = switch (self) {
                .auto => align_items == .stretch,
                .stretch => true,
                else => false,
            };
            if (stretch_effective) continue;
            const bo = &subtree.items(.box_offsets)[child_idx];
            const content_w_new = measureContentMainSize(box_tree, subtree, child_idx, false);
            const left_edge = bo.content_pos.x;
            const right_edge = bo.border_size.w - bo.content_pos.x - bo.content_size.w;
            const border_w_new = @min(bo.border_size.w, content_w_new);
            if (border_w_new != bo.border_size.w) {
                const old_content_w = bo.content_size.w;
                bo.border_size.w = border_w_new;
                bo.content_size.w = @max(0, border_w_new - left_edge - right_edge);
                relayoutIfcAtWidth(layout, subtree, child_idx, bo.content_size.w, old_content_w);
            }
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
            max_cross = @max(max_cross, childCrossSize(subtree, children[ci], flex_is_column));
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

    for (0..num_lines) |line_idx| {
        const ls = line_starts[line_idx];
        const le = line_starts[line_idx + 1];
        const line_child_count = le - ls;
        const line_cross = line_cross_sizes[line_idx];

        if (reverse_cross) {
            cross_cursor -= line_cross;
        }

        // Compute line main extent for justify-content
        var line_total_main: Unit = 0;
        for (ls..le) |ci| {
            line_total_main += childMainSize(subtree, children[ci], flex_is_column);
        }
        if (line_child_count > 1) line_total_main += flex_gap * @as(Unit, @intCast(line_child_count - 1));

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
            const effective_align: BlockInfo.FlexAlign = switch (subtree.items(.align_self)[child_idx]) {
                .auto => align_items,
                .stretch => .stretch,
                .flex_start => .flex_start,
                .flex_end => .flex_end,
                .center => .center,
                .baseline => .flex_start, // baseline unsupported; fall back
            };
            const cross_offset: Unit = cross_cursor + switch (effective_align) {
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

/// Measure an item's content main size by examining its children's extents.
/// For IFC containers (text), measures actual glyph advance widths.
/// For block containers, measures the maximum right edge of in-flow grandchildren.
/// CSS Flexbox §9.2: Measure the max-content main size of a flex item.
///
/// For row-direction flex, this returns the intrinsic width — the minimum
/// width needed to display all content with only forced line breaks.
///
/// Block children with auto width have border_size.w == container width
/// (they expand to fill during flow layout), so we cannot use that value.
/// Instead we recurse through the subtree, accumulating border+padding
/// edges at each level, until we reach IFC leaf nodes whose glyph-advance
/// sums give the true content width.
fn measureContentMainSize(box_tree: *BoxTree, subtree: Subtree.View, child_idx: Subtree.Size, flex_is_column: bool) Unit {
    if (flex_is_column) {
        return subtree.items(.box_offsets)[child_idx].border_size.h;
    }

    const types_slice = subtree.items(.type);
    const child_skip = subtree.items(.skip)[child_idx];
    const child_end = child_idx + child_skip;

    // IFC container: measure the widest line from glyph advances.
    switch (types_slice[child_idx]) {
        .ifc_container => |ifc_id| {
            return measureIfcContentWidth(box_tree, ifc_id, subtree, child_idx);
        },
        else => {},
    }

    // Block container: recurse into children to find the widest intrinsic
    // content width.  Each child contributes its own max-content width;
    // the parent's intrinsic width is the maximum of those plus its own
    // border+padding edges.
    var max_child_intrinsic: Unit = 0;
    var has_children = false;
    var gc = child_idx + 1;
    while (gc < child_end) {
        if (!subtree.items(.out_of_flow)[gc]) {
            has_children = true;
            const w = measureContentMainSize(box_tree, subtree, gc, flex_is_column);
            max_child_intrinsic = @max(max_child_intrinsic, w);
        }
        gc += subtree.items(.skip)[gc];
    }

    if (!has_children) {
        // Leaf block (replaced element, empty div).  border_size.w is the
        // only dimension we have — correct for replaced elements with
        // intrinsic sizing; for empty auto-width blocks it equals the
        // container width, but those contribute no visible content.
        return subtree.items(.box_offsets)[child_idx].border_size.w;
    }

    // This block's own edges (border + padding on each side).
    // content_pos.x = border_left + padding_left.
    // right_edge = border_size.w - content_pos.x - content_size.w
    //            = padding_right + border_right  (always correct).
    const bo = subtree.items(.box_offsets)[child_idx];
    const left_edge = bo.content_pos.x;
    const right_edge = bo.border_size.w - bo.content_pos.x - bo.content_size.w;
    return left_edge + max_child_intrinsic + right_edge;
}

/// Measure IFC content width from glyph advances.
fn measureIfcContentWidth(box_tree: *BoxTree, ifc_id: anytype, subtree: Subtree.View, child_idx: Subtree.Size) Unit {
    const ifc = box_tree.getIfc(ifc_id);
    if (ifc.glyphs.len == 0) return 0;

    // Use glyph-based max-content width instead of reading line boxes.
    // This works even before splitIntoLineBoxes has run, which is needed
    // for the measure pass in flex/grid algorithms.
    const inline_layout = @import("./inline.zig");
    const max_content = inline_layout.computeMaxContentWidth(ifc);

    const left_edge = subtree.items(.box_offsets)[child_idx].content_pos.x;
    return max_content + left_edge * 2;
}

/// CSS Flexbox §9.7: Resolve Flexible Lengths.
/// Distributes free space via flex-grow or absorbs overflow via flex-shrink.
fn resolveFlexibleLengths(
    line_children: []const Subtree.Size,
    flex_base: []const Unit,
    hypothetical: []const Unit,
    used: []Unit,
    flex_grows: anytype,
    flex_shrinks: anytype,
    container_main: Unit,
    flex_gap: Unit,
) void {
    const n = line_children.len;
    if (n == 0) return;

    // Step 1: Determine grow vs shrink.
    var sum_hypothetical_outer: Unit = 0;
    for (0..n) |i| {
        sum_hypothetical_outer += hypothetical[i];
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

    // Step 3: Calculate initial free space.
    var initial_free_space: Unit = container_main;
    if (n > 1) initial_free_space -= flex_gap * @as(Unit, @intCast(n - 1));
    for (0..n) |i| {
        if (frozen[i]) {
            initial_free_space -= targets[i];
        } else {
            initial_free_space -= flex_base[i];
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

        // Remaining free space
        var remaining: Unit = container_main;
        if (n > 1) remaining -= flex_gap * @as(Unit, @intCast(n - 1));
        var sum_factors: f32 = 0.0;
        for (0..n) |i| {
            if (frozen[i]) {
                remaining -= targets[i];
            } else {
                remaining -= flex_base[i];
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

/// Re-layout the flow-subtree rooted at a flex item at the new resolved flex
/// width. Re-splits IFC containers and recurses into flow block children so
/// their inner IFCs are also re-split; subsequent siblings are shifted down
/// by the accumulated height delta from preceding siblings.
///
/// Gated on the item's own `inner_block` type:
///   - `.flow`: do the full recursive walk — the item is a normal block and
///     its children stack in flow order, so growing one shifts the rest.
///   - `.flex` / `.grid`: DON'T descend into children. Those layout models
///     have their own independent positioning that must not be disturbed by
///     a flow-style walk. The item still gets its own IFC children (rare
///     for grid/flex containers but possible with anonymous blocks) handled,
///     but block children are left alone. This protects the 2026-04-14
///     Wikipedia header regression where `.vector-header-container` is a
///     flex container whose item `.mw-header` is a grid container — walking
///     into the grid items as if they were flow blocks previously corrupted
///     the header height (+109px on I-exact-wiki-rules).
///
/// The item's own height is grown by the accumulated delta (never shrunk)
/// so cross-size Phase 5 can see the new extent, matching CSS
/// "auto cross size = max-content of children" for the grow case while
/// preserving any pre-existing height for the no-growth case.
fn relayoutIfcAtWidth(
    layout: *@import("../zss.zig").Layout,
    subtree: Subtree.View,
    item_idx: Subtree.Size,
    new_content_w: Unit,
    /// Parent's content_size.w BEFORE the caller overwrote it with
    /// `new_content_w`. Used to decide which descendants were filling and
    /// to compute the shift delta for float:right children.
    old_content_w: Unit,
) void {
    const inline_layout = @import("./inline.zig");
    const types_slice = subtree.items(.type);
    const inner_blocks = subtree.items(.inner_block);
    const item_skip = subtree.items(.skip)[item_idx];
    const item_end = item_idx + item_skip;

    // Update this item's own width first. Keep border edges consistent with
    // the new content width.
    {
        const item_bo = &subtree.items(.box_offsets)[item_idx];
        const left_edge = item_bo.content_pos.x;
        const right_edge = item_bo.border_size.w - item_bo.content_pos.x - item_bo.content_size.w;
        item_bo.border_size.w = left_edge + new_content_w + right_edge;
        item_bo.content_size.w = new_content_w;
    }

    // If this item is itself a grid or flex container, its children were
    // positioned by those layout algorithms. We must NOT recurse into block
    // children, and we must NOT shift their y positions. We still re-split
    // any direct IFC containers at the new width (handles anonymous inline
    // boxes that can appear under a grid container for whitespace), but
    // we do not grow the item's height from the IFC delta either (the grid
    // algorithm owns that).
    const item_inner = inner_blocks[item_idx];
    const is_flow = (item_inner == .flow);

    if (!is_flow) {
        // Legacy direct-children IFC walk for pure-IFC flex items, preserving
        // the prior behavior that made A/B/C/D/F/G/H/I header-isolation tests
        // pass. Only update IFC heights; don't touch anything else.
        var total_ifc_height: Unit = 0;
        var has_non_ifc_child = false;
        var g = item_idx + 1;
        while (g < item_end) {
            if (!subtree.items(.out_of_flow)[g]) {
                switch (types_slice[g]) {
                    .ifc_container => |ifc_id| {
                        const ifc = layout.box_tree.ptr.getIfc(ifc_id);
                        ifc.line_boxes.clearRetainingCapacity();
                        const result = inline_layout.splitIntoLineBoxes(layout, subtree, ifc, new_content_w, null) catch {
                            break;
                        };
                        const bo = &subtree.items(.box_offsets)[g];
                        bo.border_size.w = new_content_w;
                        bo.content_size.w = new_content_w;
                        // CSS 2.1 §9.2.2.1: whitespace-only IFCs between block
                        // siblings contribute zero. The same rule applied at
                        // initial layout (inline.endMode) must apply here so
                        // flex re-layout doesn't resurrect line-box height.
                        const eff_h: Unit = if (ifc.has_visible_content) result.height else 0;
                        bo.border_size.h = eff_h;
                        bo.content_size.h = eff_h;
                        total_ifc_height += eff_h;
                    },
                    else => has_non_ifc_child = true,
                }
            }
            g += subtree.items(.skip)[g];
        }
        // Pure-IFC fallback (no block children): update item height.
        if (total_ifc_height > 0 and !has_non_ifc_child) {
            const item_bo = &subtree.items(.box_offsets)[item_idx];
            const pad_top = item_bo.content_pos.y;
            const pad_bot = item_bo.border_size.h - item_bo.content_pos.y - item_bo.content_size.h;
            item_bo.content_size.h = total_ifc_height;
            item_bo.border_size.h = pad_top + total_ifc_height + pad_bot;
        }
        return;
    }

    // is_flow == true: walk direct in-flow children, shift their y by any
    // accumulated growth, re-split IFCs at the new width, recurse into
    // nested flow blocks.
    //
    // Shift float:right direct children left by the parent's content-width
    // delta. A float:right was placed at `(old_content_w - border_w - prior)`
    // by offsetChildBlocks; after the parent shrinks by Δ = old - new, the
    // correct position is `offset.x - Δ`. Float:left children don't move
    // (positioned from x=0). Without this shift, float:right children sit
    // outside the parent's new content area and render off-screen — most
    // visibly Wikipedia's Rumen Radev portrait inside the In the news
    // flex column. Only run when the parent actually shrank.
    if (new_content_w < old_content_w) {
        const delta = old_content_w - new_content_w;
        const float_sides_slice = subtree.items(.float_side);
        var fc = item_idx + 1;
        while (fc < item_end) {
            if (subtree.items(.out_of_flow)[fc]) {
                fc += subtree.items(.skip)[fc];
                continue;
            }
            if (float_sides_slice[fc] == .right) {
                subtree.items(.offset)[fc].x -= delta;
                if (subtree.items(.offset)[fc].x < 0) {
                    subtree.items(.offset)[fc].x = 0;
                }
            }
            fc += subtree.items(.skip)[fc];
        }
    }

    var accumulated_y_delta: Unit = 0;
    var gc = item_idx + 1;
    while (gc < item_end) {
        if (subtree.items(.out_of_flow)[gc]) {
            gc += subtree.items(.skip)[gc];
            continue;
        }
        if (accumulated_y_delta != 0) {
            subtree.items(.box_offsets)[gc].border_pos.y += accumulated_y_delta;
        }
        switch (types_slice[gc]) {
            .ifc_container => |ifc_id| {
                const old_h = subtree.items(.box_offsets)[gc].border_size.h;
                const ifc = layout.box_tree.ptr.getIfc(ifc_id);
                ifc.line_boxes.clearRetainingCapacity();
                const result = inline_layout.splitIntoLineBoxes(layout, subtree, ifc, new_content_w, ifc.persisted_parent_float_ctx) catch {
                    break;
                };
                const bo = &subtree.items(.box_offsets)[gc];
                bo.border_size.w = new_content_w;
                bo.content_size.w = new_content_w;
                const eff_h: Unit = if (ifc.has_visible_content) result.height else 0;
                bo.border_size.h = eff_h;
                bo.content_size.h = eff_h;
                accumulated_y_delta += (eff_h - old_h);
            },
            .block => {
                // Recurse into nested flow blocks ONLY if the child was
                // filling its parent's content area (width:auto or 100%).
                // Children with an explicit narrower width (width:100px,
                // width:7.5rem, etc.) keep that width regardless of the
                // flex item's resolved width — descending into them would
                // stretch them to fill, which is exactly the bug this
                // gates against (Wikipedia #mp-left/#mp-right children,
                // .mp-thumb images, any author-sized child of a flex
                // item).
                //
                // Detection — we want to distinguish:
                //   width:auto, margin:0           → filling
                //   width:100px, margin:0          → NOT filling
                //   width:auto, margin: <left>     → filling (left margin
                //     is part of layout, but outer still fills)
                //
                // Comparing `border_w + margin.left + margin.right` to
                // `old_content_w` is fooled by CSS 2.1 §10.3.3
                // overconstrained-margin-right adjustment: a width:100px
                // block with default margin:0 ends up with margin-right
                // back-filled to (parent_content - width), making the
                // outer-plus-margins always equal old_content_w.
                //
                // `border_w + margin.left` instead — the pre-adjustment
                // left margin plus the actually-rendered border width —
                // only equals old_content_w for true fillers (width:auto
                // / width:100% / etc.) and stays smaller for explicit
                // narrower widths.
                const old_h = subtree.items(.box_offsets)[gc].border_size.h;
                const child_bo = subtree.items(.box_offsets)[gc];
                const child_left = child_bo.content_pos.x;
                const child_right = child_bo.border_size.w - child_bo.content_pos.x - child_bo.content_size.w;
                const child_margins = subtree.items(.margins)[gc];
                const fill_signal = child_bo.border_size.w + child_margins.left;
                // Tolerance of 4 ZSS units (= 1 CSS px) absorbs rounding.
                const was_filling = fill_signal >= old_content_w - 4;
                const child_old_content_w = child_bo.content_size.w;
                const child_new_w = new_content_w - child_left - child_right;
                if (was_filling and child_new_w > 0) {
                    relayoutIfcAtWidth(layout, subtree, gc, child_new_w, child_old_content_w);
                }
                const new_h = subtree.items(.box_offsets)[gc].border_size.h;
                accumulated_y_delta += (new_h - old_h);
            },
            .subtree_proxy => {
                // Subtree proxies are handled by grid's relayoutSubtree path.
                // No delta contribution.
            },
        }
        gc += subtree.items(.skip)[gc];
    }

    // Grow this item's own height by the accumulated delta. Never shrink.
    if (accumulated_y_delta > 0) {
        const item_bo = &subtree.items(.box_offsets)[item_idx];
        item_bo.content_size.h += accumulated_y_delta;
        item_bo.border_size.h += accumulated_y_delta;
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

const MAX_CHILDREN = 128;
const MAX_LINES = 32;