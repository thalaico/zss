const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const Fonts = zss.Fonts;
const NodeId = zss.Environment.NodeId;
const Unit = zss.math.Unit;
const units_per_pixel = zss.math.units_per_pixel;

const Layout = zss.Layout;
const BoxTreeManaged = Layout.BoxTreeManaged;
const StyleComputer = Layout.StyleComputer;

const BoxGen = Layout.BoxGen;
const BlockComputedSizes = BoxGen.BlockComputedSizes;
const BlockUsedSizes = BoxGen.BlockUsedSizes;
const ContainingBlockSize = BoxGen.ContainingBlockSize;
const SctBuilder = BoxGen.StackingContextTreeBuilder;
const SizeMode = BoxGen.SizeMode;

const flow = @import("./flow.zig");
const stf = @import("./shrink_to_fit.zig");
const solve = @import("./solve.zig");

const groups = zss.values.groups;
const ComputedValues = groups.Tag.ComputedValues;

const BoxTree = zss.BoxTree;
const BlockRef = BoxTree.BlockRef;
const BoxStyle = BoxTree.BoxStyle;
const Ifc = BoxTree.InlineFormattingContext;
const GlyphIndex = Ifc.GlyphIndex;
const GeneratedBox = BoxTree.GeneratedBox;
const Subtree = BoxTree.Subtree;

const hb = @import("harfbuzz").c;

pub const Result = struct {
    min_width: Unit,
};

/// Create an IFC with shaped text for a pseudo-element's content property.
/// Handles the full lifecycle: beginMode -> shape text -> endMode.
/// Caller must push .@"inline" onto box_gen.stacks.mode before calling,
/// and pop it after this returns.
pub fn addPseudoElementText(box_gen: *BoxGen, text: []const u8, font_props: FontProps) !Result {
    const layout = box_gen.getLayout();

    // Create IFC with root inline box
    try beginMode(box_gen, .normal, box_gen.containingBlockSize());

    const ifc = box_gen.inline_context.ifc.top.?.ptr;

    // Configure font for the IFC from the pseudo-element's inherited font cascade
    const handle: Fonts.Handle = switch (font_props.font) {
        .default => layout.inputs.fonts.queryFamily(font_props.font_family),
        .none => .invalid,
    };
    box_gen.inline_context.setFont(handle);
    ifc.font_family = font_props.font_family;
    ifc.font_size = font_props.font_size;

    // Shape text with HarfBuzz
    layout.inputs.fonts.setFontSize(handle, font_props.font_size);
    if (layout.inputs.fonts.get(handle)) |hb_font| {
        const glyph_start: u32 = @intCast(ifc.glyphs.len);
        try ifcAddText(layout.box_tree, ifc, text, hb_font);
        const glyph_end: u32 = @intCast(ifc.glyphs.len);
        if (glyph_end > glyph_start) {
            try ifc.font_runs.append(layout.allocator, .{
                .glyph_start = glyph_start,
                .glyph_end = glyph_end,
                .font_weight = font_props.font_weight,
                .font_size = font_props.font_size,
            });
        }
    }

    // Solve metrics, split into line boxes, finalize IFC
    return try endMode(box_gen);
}

pub const FontProps = struct {
    font: zss.values.types.Font,
    font_family: zss.values.types.FontFamily,
    font_size: zss.values.types.FontSize,
    font_weight: zss.values.types.FontWeight,
};

pub fn beginMode(box_gen: *BoxGen, size_mode: SizeMode, containing_block_size: ContainingBlockSize) !void {
    assert(containing_block_size.width >= 0);
    if (containing_block_size.height) |h| assert(h >= 0);

    const ifc = try box_gen.pushIfc();
    try box_gen.inline_context.pushIfc(box_gen.getLayout().allocator, ifc, size_mode, containing_block_size);

    try pushRootInlineBox(box_gen);
}

fn endMode(box_gen: *BoxGen) !Result {
    _ = try popInlineBox(box_gen);

    const ifc = box_gen.inline_context.ifc.top.?;
    const containing_block_width = ifc.containing_block_size.width;

    const layout = box_gen.getLayout();
    const subtree = layout.box_tree.ptr.getSubtree(box_gen.currentSubtree()).view();
    // Ensure font is at the cascaded size before solving metrics.
    layout.inputs.fonts.setFontSize(ifc.ptr.font, ifc.ptr.font_size);
    ifcSolveMetrics(ifc.ptr, subtree, layout.inputs.fonts);
    const line_split_result = try splitIntoLineBoxes(layout, subtree, ifc.ptr, containing_block_width);

    box_gen.inline_context.popIfc();
    box_gen.popIfc(ifc.ptr.id, containing_block_width, line_split_result.height);

    return .{
        .min_width = line_split_result.longest_line_box_length,
    };
}

pub const Context = struct {
    ifc: zss.Stack(struct {
        ptr: *Ifc,
        depth: Ifc.Size,
        containing_block_size: ContainingBlockSize,
        percentage_base_unit: Unit,
        font_handle: ?Fonts.Handle,
    }) = .init(undefined),
    inline_box: zss.Stack(InlineBox) = .init(undefined),

    const InlineBox = struct {
        index: Ifc.Size,
        skip: Ifc.Size,
    };

    pub fn deinit(ctx: *Context, allocator: Allocator) void {
        ctx.ifc.deinit(allocator);
        ctx.inline_box.deinit(allocator);
    }

    fn pushIfc(
        ctx: *Context,
        allocator: Allocator,
        ptr: *Ifc,
        size_mode: SizeMode,
        containing_block_size: ContainingBlockSize,
    ) !void {
        const percentage_base_unit: Unit = switch (size_mode) {
            .normal => containing_block_size.width,
            .stf => 0,
        };
        try ctx.ifc.push(allocator, .{
            .ptr = ptr,
            .depth = 0,
            .containing_block_size = containing_block_size,
            .percentage_base_unit = percentage_base_unit,
            .font_handle = null,
        });
    }

    fn popIfc(ctx: *Context) void {
        const ifc = ctx.ifc.pop();
        assert(ifc.depth == 0);
    }

    fn pushInlineBox(ctx: *Context, allocator: Allocator, index: Ifc.Size) !void {
        try ctx.inline_box.push(allocator, .{ .index = index, .skip = 1 });
        ctx.ifc.top.?.depth += 1;
    }

    fn popInlineBox(ctx: *Context) InlineBox {
        const inline_box = ctx.inline_box.pop();
        ctx.ifc.top.?.depth -= 1;
        return inline_box;
    }

    fn accumulateSkip(ctx: *Context, skip: Ifc.Size) void {
        ctx.inline_box.top.?.skip += skip;
    }

    fn setFont(ctx: *Context, handle: Fonts.Handle) void {
        const ifc = &ctx.ifc.top.?;
        ifc.font_handle = handle;
        ifc.ptr.font = handle;
    }
};

pub fn inlineElement(box_gen: *BoxGen, node: NodeId, inner_inline: BoxStyle.InnerInline, position: BoxStyle.Position) !void {
    const ctx = &box_gen.inline_context;
    const ifc = ctx.ifc.top.?;
    const layout = box_gen.getLayout();

    // TODO: Check position and float properties
    switch (inner_inline) {
        .text => {
            const generated_box = GeneratedBox{ .text = ifc.ptr.id };
            try layout.box_tree.setGeneratedBox(node, generated_box);

            const font = layout.computer.getTextFont(.box_gen);
            const handle: Fonts.Handle = switch (font.font) {
                .default => layout.inputs.fonts.queryFamily(font.font_family),
                .none => .invalid,
            };
            box_gen.inline_context.setFont(handle);
            // Propagate cascaded font properties to the IFC.
            ifc.ptr.font_family = font.font_family;
            // Set IFC font_size from first text node only (block element's cascaded size).
            // Later text nodes (e.g. comhead at 8pt) must not overwrite this —
            // ifc.font_size is used for line-height and as the default rendering size.
            if (ifc.ptr.font_runs.items.len == 0) {
                ifc.ptr.font_size = font.font_size;
            }
            // Resize the FreeType face so HarfBuzz shapes at the actual font-size.
            layout.inputs.fonts.setFontSize(handle, font.font_size);
            if (layout.inputs.fonts.get(handle)) |hb_font| {
                // Record glyph range for this text node's font run.
                const glyph_start: u32 = @intCast(ifc.ptr.glyphs.len);
                const text = layout.computer.getText();
                try ifcAddText(layout.box_tree, ifc.ptr, text, hb_font);
                const glyph_end: u32 = @intCast(ifc.ptr.glyphs.len);
                if (glyph_end > glyph_start) {
                    // Extend the last run if same weight and font size, otherwise start a new one.
                    const runs = &ifc.ptr.font_runs;
                    if (runs.items.len > 0 and
                        runs.items[runs.items.len - 1].font_weight == font.font_weight and
                        runs.items[runs.items.len - 1].font_size == font.font_size and
                        runs.items[runs.items.len - 1].glyph_end == glyph_start)
                    {
                        runs.items[runs.items.len - 1].glyph_end = glyph_end;
                    } else {
                        try runs.append(layout.allocator, .{
                            .glyph_start = glyph_start,
                            .glyph_end = glyph_end,
                            .font_weight = font.font_weight,
                            .font_size = font.font_size,
                        });
                    }
                }
            }

            layout.advanceNode();
        },
        .@"inline" => {
            { // TODO: Grabbing useless data to satisfy inheritance...
                const data = .{
                    .content_width = layout.computer.getSpecifiedValue(.box_gen, .content_width),
                    .content_height = layout.computer.getSpecifiedValue(.box_gen, .content_height),
                    .z_index = layout.computer.getSpecifiedValue(.box_gen, .z_index),
                };
                layout.computer.setComputedValue(.box_gen, .content_width, data.content_width);
                layout.computer.setComputedValue(.box_gen, .content_height, data.content_height);
                layout.computer.setComputedValue(.box_gen, .z_index, data.z_index);

                layout.computer.commitNode(.box_gen);
            }

            const inline_box_index = try pushInlineBox(box_gen, node);
            const generated_box = GeneratedBox{ .inline_box = .{ .ifc_id = ifc.ptr.id, .index = inline_box_index } };
            try layout.box_tree.setGeneratedBox(node, generated_box);
            try layout.pushNode();
        },
        .block => |block_inner| switch (block_inner) {
            .flow, .flex, .grid => {
                const sizes = inlineBlockSolveSizes(&layout.computer, position, ifc.containing_block_size);
                const stacking_context = inlineBlockSolveStackingContext(&layout.computer, position);
                layout.computer.commitNode(.box_gen);

                if (sizes.get(.inline_size)) |_| {
                    const box_style = BoxTree.BoxStyle{ .outer = .{ .block = .flow }, .position = position };
                    const ref = try box_gen.pushFlowBlock(box_style, sizes, .normal, stacking_context, node);
                    try layout.box_tree.setGeneratedBox(node, .{ .block_ref = ref });
                    try ifcAddInlineBlock(layout.box_tree, ifc.ptr, ref.index);
                    try layout.pushNode();
                    return box_gen.beginFlowMode(.not_root);
                } else {
                    const available_width_unclamped = ifc.containing_block_size.width -
                        (sizes.margin_inline_start_untagged + sizes.margin_inline_end_untagged +
                            sizes.border_inline_start + sizes.border_inline_end +
                            sizes.padding_inline_start + sizes.padding_inline_end);
                    const available_width = solve.clampSize(available_width_unclamped, sizes.min_inline_size, sizes.max_inline_size);

                    const box_style = BoxTree.BoxStyle{ .outer = .{ .block = .flow }, .position = position };
                    const ref = try box_gen.pushFlowBlock(box_style, sizes, .{ .stf = available_width }, stacking_context, node);
                    try layout.box_tree.setGeneratedBox(node, .{ .block_ref = ref });
                    try ifcAddInlineBlock(layout.box_tree, ifc.ptr, ref.index);
                    try layout.pushNode();
                    return box_gen.beginStfMode(.flow, sizes);
                }
            },
        },
    }
}

pub fn blockElement(box_gen: *BoxGen) !Result {
    // Close nested inline boxes down to depth 1.
    // Each inline box was opened with pushInlineBox + pushNode. We must pop
    // the corresponding node entries. The block element's node sits at the
    // top of the stack and needs to survive, so we save it, pop the
    // intermediate entries, then restore it.
    const layout = box_gen.getLayout();
    const saved_node = layout.node_stack.pop();
    while (box_gen.inline_context.ifc.top.?.depth > 1) {
        _ = try popInlineBox(box_gen);
        layout.popNode();
    }
    try layout.node_stack.push(layout.allocator, saved_node);

    // Now at depth 1, end the IFC normally
    return try endMode(box_gen);
}

pub fn nullNode(box_gen: *BoxGen) !?Result {
    const ctx = &box_gen.inline_context;
    const ifc = ctx.ifc.top.?;
    if (ifc.depth == 1) {
        return try endMode(box_gen);
    }
    const skip = try popInlineBox(box_gen);
    box_gen.getLayout().popNode();
    ctx.accumulateSkip(skip);
    return null;
}

pub fn afterFlowMode(box_gen: *BoxGen) void {
    box_gen.popFlowBlock(.normal);
    box_gen.getLayout().popNode();
}

pub fn afterInlineMode() noreturn {
    unreachable;
}

pub fn afterStfMode(box_gen: *BoxGen, result: stf.Result) void {
    box_gen.popFlowBlock(.{ .stf = result.auto_width });
    box_gen.getLayout().popNode();
}

fn pushRootInlineBox(box_gen: *BoxGen) !void {
    const ctx = &box_gen.inline_context;
    const ifc = &ctx.ifc.top.?;
    const layout = box_gen.getLayout();

    const index = try layout.box_tree.appendInlineBox(ifc.ptr);
    setDataRootInlineBox(ifc.ptr, index);
    try ifcAddBoxStart(layout.box_tree, ifc.ptr, index);
    try ctx.pushInlineBox(layout.allocator, index);
}

fn pushInlineBox(box_gen: *BoxGen, node: NodeId) !Ifc.Size {
    const ctx = &box_gen.inline_context;
    const ifc = &ctx.ifc.top.?;
    const layout = box_gen.getLayout();

    const index = try layout.box_tree.appendInlineBox(ifc.ptr);
    setDataInlineBox(&layout.computer, ifc.ptr.slice(), index, node, ifc.percentage_base_unit);
    try ifcAddBoxStart(layout.box_tree, ifc.ptr, index);
    try ctx.pushInlineBox(layout.allocator, index);
    return index;
}

fn popInlineBox(box_gen: *BoxGen) !Ifc.Size {
    const ctx = &box_gen.inline_context;
    const ifc = ctx.ifc.top.?;
    const inline_box = ctx.popInlineBox();
    ifc.ptr.slice().items(.skip)[inline_box.index] = inline_box.skip;
    try ifcAddBoxEnd(box_gen.getLayout().box_tree, ifc.ptr, inline_box.index);
    return inline_box.skip;
}

fn ifcAddBoxStart(box_tree: BoxTreeManaged, ifc: *Ifc, inline_box_index: Ifc.Size) !void {
    try box_tree.appendSpecialGlyph(ifc, .BoxStart, inline_box_index);
}

fn ifcAddBoxEnd(box_tree: BoxTreeManaged, ifc: *Ifc, inline_box_index: Ifc.Size) !void {
    try box_tree.appendSpecialGlyph(ifc, .BoxEnd, inline_box_index);
}

fn ifcAddInlineBlock(box_tree: BoxTreeManaged, ifc: *Ifc, block_box_index: Subtree.Size) !void {
    try box_tree.appendSpecialGlyph(ifc, .InlineBlock, block_box_index);
}

fn ifcAddLineBreak(box_tree: BoxTreeManaged, ifc: *Ifc) !void {
    try box_tree.appendSpecialGlyph(ifc, .LineBreak, {});
}

fn ifcAddText(box_tree: BoxTreeManaged, ifc: *Ifc, text: []const u8, font: *hb.hb_font_t) !void {
    const buffer = hb.hb_buffer_create() orelse unreachable;
    defer hb.hb_buffer_destroy(buffer);
    // TODO: Need to put a limit on the length of text
    _ = hb.hb_buffer_pre_allocate(buffer, @intCast(text.len));
    // TODO direction, script, and language must be determined by examining the text itself
    hb.hb_buffer_set_direction(buffer, hb.HB_DIRECTION_LTR);
    hb.hb_buffer_set_script(buffer, hb.HB_SCRIPT_LATIN);
    hb.hb_buffer_set_language(buffer, hb.hb_language_from_string("en", -1));

    // CSS white-space: normal — collapse whitespace sequences to a single space.
    // \n, \r, \t are treated as spaces; consecutive whitespace collapses.
    var run_begin: usize = 0;
    var run_end: usize = 0;
    var in_whitespace: bool = false;
    while (run_end < text.len) : (run_end += 1) {
        const ch = text[run_end];
        const is_ws = (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t');
        if (is_ws) {
            if (!in_whitespace) {
                // End non-whitespace run before this first whitespace char.
                try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, run_end);
                // Emit a single collapsed space.
                hb.hb_buffer_add_latin1(buffer, " ", 1, 0, 1);
                if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
                try ifcAddTextRun(box_tree, ifc, buffer, font);
                assert(hb.hb_buffer_set_length(buffer, 0) != 0);
                in_whitespace = true;
            }
            // Skip this whitespace char (already collapsed).
            run_begin = run_end + 1;
        } else {
            in_whitespace = false;
        }
    }

    try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, run_end);
}

fn ifcEndTextRun(box_tree: BoxTreeManaged, ifc: *Ifc, text: []const u8, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, run_begin: usize, run_end: usize) !void {
    if (run_end > run_begin) {
        hb.hb_buffer_add_utf8(buffer, text.ptr, @intCast(text.len), @intCast(run_begin), @intCast(run_end - run_begin));
        if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        try ifcAddTextRun(box_tree, ifc, buffer, font);
        assert(hb.hb_buffer_set_length(buffer, 0) != 0);
    }
}

fn ifcAddTextRun(box_tree: BoxTreeManaged, ifc: *Ifc, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t) !void {
    hb.hb_shape(font, buffer, null, 0);
    var glyph_count: c_uint = 0;
    const glyph_infos = hb.hb_buffer_get_glyph_infos(buffer, &glyph_count);
    var pos_count: c_uint = 0;
    const glyph_positions = hb.hb_buffer_get_glyph_positions(buffer, &pos_count);
    assert(glyph_count == pos_count);

    var i: c_uint = 0;
    while (i < glyph_count) : (i += 1) {
        const glyph_index: GlyphIndex = glyph_infos[i].codepoint;
        // Convert shaped advance from HarfBuzz 26.6 fixed-point to internal units.
        // This preserves kerning and GPOS positioning from hb_shape.
        const shaped_advance: Unit = @divFloor(glyph_positions[i].x_advance * units_per_pixel, 64);
        if (glyph_index == 0) {
            const special: Ifc.Special = .{
                .kind = .ZeroGlyphIndex,
                .data = undefined,
            };
            try ifc.glyphs.append(box_tree.ptr.allocator, .{
                .index = 0,
                .metrics = .{ .offset = 0, .advance = shaped_advance, .width = 0 },
            });
            try ifc.glyphs.append(box_tree.ptr.allocator, .{
                .index = @bitCast(special),
                .metrics = undefined,
            });
        } else {
            try ifc.glyphs.append(box_tree.ptr.allocator, .{
                .index = glyph_index,
                .metrics = .{ .offset = 0, .advance = shaped_advance, .width = 0 },
            });
        }
    }
}

fn setDataRootInlineBox(ifc: *const Ifc, inline_box_index: Ifc.Size) void {
    const ifc_slice = ifc.slice();
    ifc_slice.items(.node)[inline_box_index] = null;
    ifc_slice.items(.inline_start)[inline_box_index] = .{};
    ifc_slice.items(.inline_end)[inline_box_index] = .{};
    ifc_slice.items(.block_start)[inline_box_index] = .{};
    ifc_slice.items(.block_end)[inline_box_index] = .{};
    ifc_slice.items(.margins)[inline_box_index] = .{};
}

fn setDataInlineBox(computer: *StyleComputer, ifc: Ifc.Slice, inline_box_index: Ifc.Size, node: NodeId, percentage_base_unit: Unit) void {
    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).
    const specified = .{
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .border_styles = computer.getSpecifiedValue(.box_gen, .border_styles),
    };

    var computed: struct {
        horizontal_edges: ComputedValues(.horizontal_edges),
        vertical_edges: ComputedValues(.vertical_edges),
    } = undefined;

    var used: struct {
        margin_inline_start: Unit,
        border_inline_start: Unit,
        padding_inline_start: Unit,
        margin_inline_end: Unit,
        border_inline_end: Unit,
        padding_inline_end: Unit,
        border_block_start: Unit,
        padding_block_start: Unit,
        border_block_end: Unit,
        padding_block_end: Unit,
    } = undefined;

    switch (specified.horizontal_edges.margin_left) {
        .px => |value| {
            computed.horizontal_edges.margin_left = .{ .px = value };
            used.margin_inline_start = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_left = .{ .percentage = value };
            used.margin_inline_start = solve.percentage(value, percentage_base_unit);
        },
        .auto => {
            computed.horizontal_edges.margin_left = .auto;
            used.margin_inline_start = 0;
        },
    }
    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.left);
        switch (specified.horizontal_edges.border_left) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.horizontal_edges.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width);
            },
        }
    }
    switch (specified.horizontal_edges.padding_left) {
        .px => |value| {
            computed.horizontal_edges.padding_left = .{ .px = value };
            used.padding_inline_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_left = .{ .percentage = value };
            used.padding_inline_start = solve.positivePercentage(value, percentage_base_unit);
        },
    }
    switch (specified.horizontal_edges.margin_right) {
        .px => |value| {
            computed.horizontal_edges.margin_right = .{ .px = value };
            used.margin_inline_end = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_right = .{ .percentage = value };
            used.margin_inline_end = solve.percentage(value, percentage_base_unit);
        },
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
            used.margin_inline_end = 0;
        },
    }
    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.right);
        switch (specified.horizontal_edges.border_right) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.horizontal_edges.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width);
            },
        }
    }
    switch (specified.horizontal_edges.padding_right) {
        .px => |value| {
            computed.horizontal_edges.padding_right = .{ .px = value };
            used.padding_inline_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_right = .{ .percentage = value };
            used.padding_inline_end = solve.positivePercentage(value, percentage_base_unit);
        },
    }

    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.top);
        switch (specified.vertical_edges.border_top) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.vertical_edges.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width);
            },
        }
    }
    switch (specified.vertical_edges.padding_top) {
        .px => |value| {
            computed.vertical_edges.padding_top = .{ .px = value };
            used.padding_block_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_top = .{ .percentage = value };
            used.padding_block_start = solve.positivePercentage(value, percentage_base_unit);
        },
    }
    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.bottom);
        switch (specified.vertical_edges.border_bottom) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.vertical_edges.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width);
            },
        }
    }
    switch (specified.vertical_edges.padding_bottom) {
        .px => |value| {
            computed.vertical_edges.padding_bottom = .{ .px = value };
            used.padding_block_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_bottom = .{ .percentage = value };
            used.padding_block_end = solve.positivePercentage(value, percentage_base_unit);
        },
    }

    computed.vertical_edges.margin_top = specified.vertical_edges.margin_top;
    computed.vertical_edges.margin_bottom = specified.vertical_edges.margin_bottom;

    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, specified.border_styles);

    ifc.items(.node)[inline_box_index] = node;
    ifc.items(.inline_start)[inline_box_index] = .{ .border = used.border_inline_start, .padding = used.padding_inline_start };
    ifc.items(.inline_end)[inline_box_index] = .{ .border = used.border_inline_end, .padding = used.padding_inline_end };
    ifc.items(.block_start)[inline_box_index] = .{ .border = used.border_block_start, .padding = used.padding_block_start };
    ifc.items(.block_end)[inline_box_index] = .{ .border = used.border_block_end, .padding = used.padding_block_end };
    ifc.items(.margins)[inline_box_index] = .{ .start = used.margin_inline_start, .end = used.margin_inline_end };
}

fn inlineBlockSolveSizes(
    computer: *StyleComputer,
    position: BoxTree.BoxStyle.Position,
    containing_block_size: ContainingBlockSize,
) BlockUsedSizes {
    const specified = BlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .insets = computer.getSpecifiedValue(.box_gen, .insets),
    };
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    var computed: BlockComputedSizes = undefined;
    var used: BlockUsedSizes = undefined;

    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.left);
        switch (specified.horizontal_edges.border_left) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.horizontal_edges.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width);
            },
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.right);
        switch (specified.horizontal_edges.border_right) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.horizontal_edges.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width);
            },
        }
    }
    switch (specified.horizontal_edges.padding_left) {
        .px => |value| {
            computed.horizontal_edges.padding_left = .{ .px = value };
            used.padding_inline_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_left = .{ .percentage = value };
            used.padding_inline_start = solve.positivePercentage(value, containing_block_size.width);
        },
    }
    switch (specified.horizontal_edges.padding_right) {
        .px => |value| {
            computed.horizontal_edges.padding_right = .{ .px = value };
            used.padding_inline_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_right = .{ .percentage = value };
            used.padding_inline_end = solve.positivePercentage(value, containing_block_size.width);
        },
    }
    switch (specified.horizontal_edges.margin_left) {
        .px => |value| {
            computed.horizontal_edges.margin_left = .{ .px = value };
            used.setValue(.margin_inline_start, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_left = .{ .percentage = value };
            used.setValue(.margin_inline_start, solve.percentage(value, containing_block_size.width));
        },
        .auto => {
            computed.horizontal_edges.margin_left = .auto;
            used.setValue(.margin_inline_start, 0);
        },
    }
    switch (specified.horizontal_edges.margin_right) {
        .px => |value| {
            computed.horizontal_edges.margin_right = .{ .px = value };
            used.setValue(.margin_inline_end, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_right = .{ .percentage = value };
            used.setValue(.margin_inline_end, solve.percentage(value, containing_block_size.width));
        },
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
            used.setValue(.margin_inline_end, 0);
        },
    }
    switch (specified.content_width.min_width) {
        .px => |value| {
            computed.content_width.min_width = .{ .px = value };
            used.min_inline_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_width = .{ .percentage = value };
            used.min_inline_size = solve.positivePercentage(value, containing_block_size.width);
        },
    }
    switch (specified.content_width.max_width) {
        .px => |value| {
            computed.content_width.max_width = .{ .px = value };
            used.max_inline_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_width = .{ .percentage = value };
            used.max_inline_size = solve.positivePercentage(value, containing_block_size.width);
        },
        .none => {
            computed.content_width.max_width = .none;
            used.max_inline_size = std.math.maxInt(Unit);
        },
    }

    switch (specified.content_width.width) {
        .px => |value| {
            computed.content_width.width = .{ .px = value };
            used.setValue(.inline_size, solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_width.width = .{ .percentage = value };
            used.setValue(.inline_size, solve.positivePercentage(value, containing_block_size.width));
        },
        .auto => {
            computed.content_width.width = .auto;
            used.setAuto(.inline_size);
        },
    }

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.top);
        switch (specified.vertical_edges.border_top) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.vertical_edges.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width);
            },
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.bottom);
        switch (specified.vertical_edges.border_bottom) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.vertical_edges.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width);
            },
        }
    }
    switch (specified.vertical_edges.padding_top) {
        .px => |value| {
            computed.vertical_edges.padding_top = .{ .px = value };
            used.padding_block_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_top = .{ .percentage = value };
            used.padding_block_start = solve.positivePercentage(value, containing_block_size.width);
        },
    }
    switch (specified.vertical_edges.padding_bottom) {
        .px => |value| {
            computed.vertical_edges.padding_bottom = .{ .px = value };
            used.padding_block_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_bottom = .{ .percentage = value };
            used.padding_block_end = solve.positivePercentage(value, containing_block_size.width);
        },
    }
    switch (specified.vertical_edges.margin_top) {
        .px => |value| {
            computed.vertical_edges.margin_top = .{ .px = value };
            used.margin_block_start = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_top = .{ .percentage = value };
            used.margin_block_start = solve.percentage(value, containing_block_size.width);
        },
        .auto => {
            computed.vertical_edges.margin_top = .auto;
            used.margin_block_start = 0;
        },
    }
    switch (specified.vertical_edges.margin_bottom) {
        .px => |value| {
            computed.vertical_edges.margin_bottom = .{ .px = value };
            used.margin_block_end = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_bottom = .{ .percentage = value };
            used.margin_block_end = solve.percentage(value, containing_block_size.width);
        },
        .auto => {
            computed.vertical_edges.margin_bottom = .auto;
            used.margin_block_end = 0;
        },
    }
    switch (specified.content_height.min_height) {
        .px => |value| {
            computed.content_height.min_height = .{ .px = value };
            used.min_block_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.min_height = .{ .percentage = value };
            used.min_block_size = if (containing_block_size.height) |h|
                solve.positivePercentage(value, h)
            else
                0;
        },
    }
    switch (specified.content_height.max_height) {
        .px => |value| {
            computed.content_height.max_height = .{ .px = value };
            used.max_block_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.max_height = .{ .percentage = value };
            used.max_block_size = if (containing_block_size.height) |h|
                solve.positivePercentage(value, h)
            else
                std.math.maxInt(Unit);
        },
        .none => {
            computed.content_height.max_height = .none;
            used.max_block_size = std.math.maxInt(Unit);
        },
    }
    switch (specified.content_height.height) {
        .px => |value| {
            computed.content_height.height = .{ .px = value };
            used.setValue(.block_size, solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_height.height = .{ .percentage = value };
            if (containing_block_size.height) |h|
                used.setValue(.block_size, solve.positivePercentage(value, h))
            else
                used.setAuto(.block_size);
        },
        .auto => {
            computed.content_height.height = .auto;
            used.setAuto(.block_size);
        },
    }

    computed.insets = solve.insets(specified.insets);
    flow.solveInsets(computed.insets, position, &used);

    computer.setComputedValue(.box_gen, .content_width, computed.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .insets, computed.insets);
    computer.setComputedValue(.box_gen, .border_styles, border_styles);

    return used;
}

fn inlineBlockSolveStackingContext(
    computer: *StyleComputer,
    position: BoxTree.BoxStyle.Position,
) SctBuilder.Type {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);

    switch (position) {
        .static => return .{ .non_parentable = 0 },
        // TODO: Position the block using the values of the 'inset' family of properties.
        .relative => switch (z_index.z_index) {
            .integer => |integer| return .{ .parentable = integer },
            .auto => return .{ .non_parentable = 0 },
        },
        .absolute, .fixed => unreachable,
    }
}

fn ifcSolveMetrics(ifc: *Ifc, subtree: Subtree.View, fonts: *const Fonts) void {
    const font = fonts.get(ifc.font);
    const ifc_slice = ifc.slice();
    const glyphs_slice = ifc.glyphs.slice();
    const runs = ifc.font_runs.items;

    // Track current font run for per-run font sizing.
    // Runs cover text glyphs only; special glyphs (BoxStart, etc.) fall between runs.
    var run_idx: usize = 0;
    var current_font_size: f32 = ifc.font_size;

    var i: usize = 0;
    while (i < glyphs_slice.len) : (i += 1) {
        const glyph_index = glyphs_slice.items(.index)[i];
        const metrics = &glyphs_slice.items(.metrics)[i];

        if (glyph_index == 0) {
            i += 1;
            const special = Ifc.Special.decode(glyphs_slice.items(.index)[i]);
            const kind = @as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)));
            switch (kind) {
                .ZeroGlyphIndex => {
                    // Advance already stored from hb_shape; fill extents only.
                    setMetricsGlyphExtents(metrics, font.?, 0);
                },
                .BoxStart => {
                    const inline_box_index = @as(Ifc.Size, special.data);
                    setMetricsBoxStart(metrics, ifc_slice, inline_box_index);
                },
                .BoxEnd => {
                    const inline_box_index = @as(Ifc.Size, special.data);
                    setMetricsBoxEnd(metrics, ifc_slice, inline_box_index);
                },
                .InlineBlock => {
                    const block_box_index = @as(Subtree.Size, special.data);
                    setMetricsInlineBlock(metrics, subtree, block_box_index);
                },
                .LineBreak => setMetricsLineBreak(metrics),
            }
        } else {
            // Advance to the font run covering this glyph and set its font size.
            while (run_idx < runs.len and runs[run_idx].glyph_end <= i) {
                run_idx += 1;
            }
            if (run_idx < runs.len and i >= runs[run_idx].glyph_start and
                runs[run_idx].font_size != current_font_size)
            {
                current_font_size = runs[run_idx].font_size;
                fonts.setFontSize(ifc.font, current_font_size);
            }
            // Advance already stored from hb_shape; fill extents only.
            setMetricsGlyphExtents(metrics, font.?, glyph_index);
        }
    }
}

/// Fill only offset (x_bearing) and width (ink width) from glyph extents.
/// Advance is already stored from HarfBuzz shaped output — do not overwrite.
fn setMetricsGlyphExtents(metrics: *Ifc.Metrics, font: *hb.hb_font_t, glyph_index: GlyphIndex) void {
    var extents: hb.hb_glyph_extents_t = undefined;
    const extents_result = hb.hb_font_get_glyph_extents(font, glyph_index, &extents);
    if (extents_result == 0) {
        extents.width = 0;
        extents.x_bearing = 0;
    }
    metrics.offset = @divFloor(extents.x_bearing * units_per_pixel, 64);
    metrics.width = @divFloor(extents.width * units_per_pixel, 64);
}

fn setMetricsBoxStart(metrics: *Ifc.Metrics, ifc_slice: Ifc.Slice, inline_box_index: Ifc.Size) void {
    const inline_start = ifc_slice.items(.inline_start)[inline_box_index];
    const margin = ifc_slice.items(.margins)[inline_box_index].start;
    const width = inline_start.border + inline_start.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = margin, .advance = advance, .width = width };
}

fn setMetricsBoxEnd(metrics: *Ifc.Metrics, ifc_slice: Ifc.Slice, inline_box_index: Ifc.Size) void {
    const inline_end = ifc_slice.items(.inline_end)[inline_box_index];
    const margin = ifc_slice.items(.margins)[inline_box_index].end;
    const width = inline_end.border + inline_end.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = 0, .advance = advance, .width = width };
}

fn setMetricsLineBreak(metrics: *Ifc.Metrics) void {
    metrics.* = .{ .offset = 0, .advance = 0, .width = 0 };
}

fn setMetricsInlineBlock(metrics: *Ifc.Metrics, subtree: Subtree.View, block_box_index: Subtree.Size) void {
    const box_offsets = subtree.items(.box_offsets)[block_box_index];
    const margins = subtree.items(.margins)[block_box_index];

    const width = box_offsets.border_size.w;
    const advance = width + margins.left + margins.right;
    metrics.* = .{ .offset = margins.left, .advance = advance, .width = width };
}

const IFCLineSplitState = struct {
    cursor: Unit,
    line_box: Ifc.LineBox,
    inline_blocks_in_this_line_box: std.ArrayListUnmanaged(InlineBlockInfo),
    top_height: Unit,
    max_top_height: Unit,
    bottom_height: Unit,
    longest_line_box_length: Unit,
    inline_box_stack: std.ArrayListUnmanaged(Ifc.Size) = .{},
    current_inline_box: Ifc.Size = undefined,

    const InlineBlockInfo = struct {
        offset: *zss.math.Vector,
        cursor: Unit,
        height: Unit,
    };

    fn init(top_height: Unit, bottom_height: Unit) IFCLineSplitState {
        return IFCLineSplitState{
            .cursor = 0,
            .line_box = .{ .baseline = 0, .elements = [2]usize{ 0, 0 }, .inline_box = undefined },
            .inline_blocks_in_this_line_box = .{},
            .top_height = top_height,
            .max_top_height = top_height,
            .bottom_height = bottom_height,
            .longest_line_box_length = 0,
        };
    }

    fn deinit(self: *IFCLineSplitState, allocator: Allocator) void {
        self.inline_blocks_in_this_line_box.deinit(allocator);
        self.inline_box_stack.deinit(allocator);
    }

    fn finishLineBox(self: *IFCLineSplitState) void {
        self.line_box.baseline += self.max_top_height;
        self.longest_line_box_length = @max(self.longest_line_box_length, self.cursor);

        for (self.inline_blocks_in_this_line_box.items) |info| {
            info.offset.* = .{
                .x = info.cursor,
                .y = self.line_box.baseline - info.height,
            };
        }
    }

    fn newLineBox(self: *IFCLineSplitState, skipped_glyphs: usize) void {
        self.cursor = 0;
        self.line_box = .{
            .baseline = self.line_box.baseline + self.bottom_height,
            .elements = [2]usize{ self.line_box.elements[1] + skipped_glyphs, self.line_box.elements[1] + skipped_glyphs },
            .inline_box = self.current_inline_box,
        };
        self.max_top_height = self.top_height;
        self.inline_blocks_in_this_line_box.clearRetainingCapacity();
    }

    fn pushInlineBox(self: *IFCLineSplitState, allocator: Allocator, index: Ifc.Size) !void {
        if (index != 0) {
            try self.inline_box_stack.append(allocator, self.current_inline_box);
        }
        self.current_inline_box = index;
    }

    fn popInlineBox(self: *IFCLineSplitState, index: Ifc.Size) void {
        assert(self.current_inline_box == index);
        if (index != 0) {
            self.current_inline_box = self.inline_box_stack.pop().?;
        } else {
            self.current_inline_box = undefined;
        }
    }
};

pub const IFCLineSplitResult = struct {
    height: Unit,
    longest_line_box_length: Unit,
};

fn splitIntoLineBoxes(
    layout: *Layout,
    subtree: Subtree.View,
    ifc: *Ifc,
    max_line_box_length: Unit,
) !IFCLineSplitResult {
    assert(max_line_box_length >= 0);

    var top_height: Unit = undefined;
    var bottom_height: Unit = undefined;
    if (layout.inputs.fonts.get(ifc.font)) |font| {
        _ = font; // HarfBuzz font still used for glyph shaping (advances/positions) below
        // Resize the FreeType face before querying metrics.
        layout.inputs.fonts.setFontSize(ifc.font, ifc.font_size);
        // Compute line metrics from font design units (hhea table) to avoid
        // FreeType's size->metrics ceil/floor pixel-boundary rounding, which
        // overshoots Chrome's unrounded computation by ~0.8px per line box.
        const dm = layout.inputs.fonts.getDesignMetrics(ifc.font);
        if (dm.units_per_em > 0) {
            const upem: f32 = @floatFromInt(dm.units_per_em);
            const asc_design: f32 = @floatFromInt(dm.ascender);
            const desc_design: f32 = @floatFromInt(dm.descender);
            const total_design = asc_design + desc_design;
            // Compute total line height in layout units, rounding once at the end
            // (Chrome keeps fractional px and only rounds at paint time).
            const scale = ifc.font_size * @as(f32, @floatFromInt(units_per_pixel)) / upem;
            const total_lu: i32 = @intFromFloat(@round(total_design * scale));
            // Split into ascender/descender proportionally to preserve baseline position.
            ifc.ascender = @intFromFloat(@round(@as(f32, @floatFromInt(total_lu)) * asc_design / total_design));
            ifc.descender = total_lu - ifc.ascender;
        } else {
            ifc.ascender = 0;
            ifc.descender = 0;
        }
        top_height    = ifc.ascender;
        bottom_height = ifc.descender;
    } else {
        ifc.ascender  = 0;
        ifc.descender = 0;
        top_height    = 0;
        bottom_height = 0;
    }

    var s = IFCLineSplitState.init(top_height, bottom_height);
    defer s.deinit(layout.allocator);

    const glyphs = ifc.glyphs.slice();

    {
        const gi = glyphs.items(.index)[0];
        assert(gi == 0);
        const special = Ifc.Special.decode(glyphs.items(.index)[1]);
        assert(special.kind == .BoxStart);
        assert(@as(Ifc.Size, special.data) == 0);
        s.pushInlineBox(layout.allocator, 0) catch unreachable;
        s.line_box.elements[1] = 2;
        s.line_box.inline_box = null;
    }

    var i: usize = 2;
    while (i < glyphs.len) : (i += 1) {
        const gi = glyphs.items(.index)[i];
        const metrics = glyphs.items(.metrics)[i];

        if (gi == 0) {
            i += 1;
            const special = Ifc.Special.decode(glyphs.items(.index)[i]);
            switch (@as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)))) {
                .BoxStart => try s.pushInlineBox(layout.allocator, @as(Ifc.Size, special.data)),
                .BoxEnd => s.popInlineBox(@as(Ifc.Size, special.data)),
                .LineBreak => {
                    s.finishLineBox();
                    try layout.box_tree.appendLineBox(ifc, s.line_box);
                    s.newLineBox(2);
                    continue;
                },
                else => {},
            }
        }

        // TODO: (Bug) A glyph with a width of zero but an advance that is non-zero may overflow the width of the containing block
        if (s.cursor > 0 and metrics.width > 0 and s.cursor + metrics.offset + metrics.width > max_line_box_length and s.line_box.elements[1] > s.line_box.elements[0]) {
            s.finishLineBox();
            try layout.box_tree.appendLineBox(ifc, s.line_box);
            s.newLineBox(0);
        }

        if (gi == 0) {
            const special = Ifc.Special.decode(glyphs.items(.index)[i]);
            switch (@as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)))) {
                .InlineBlock => {
                    const block_box_index = @as(Subtree.Size, special.data);
                    const offset = &subtree.items(.offset)[block_box_index];
                    const box_offsets = subtree.items(.box_offsets)[block_box_index];
                    const margins = subtree.items(.margins)[block_box_index];
                    const margin_box_height = box_offsets.border_size.h + margins.top + margins.bottom;
                    s.max_top_height = @max(s.max_top_height, margin_box_height);
                    try s.inline_blocks_in_this_line_box.append(
                        layout.allocator,
                        .{
                            .offset = offset,
                            .cursor = s.cursor,
                            // Remove margins.top subtraction - border_pos.y already accounts for it during rendering
                            .height = margin_box_height,
                        },
                    );
                },
                .LineBreak => unreachable,
                else => {},
            }
            s.line_box.elements[1] += 2;
        } else {
            s.line_box.elements[1] += 1;
        }

        s.cursor += metrics.advance;
    }

    if (s.line_box.elements[1] > s.line_box.elements[0]) {
        s.finishLineBox();
        try layout.box_tree.appendLineBox(ifc, s.line_box);
    }

    return IFCLineSplitResult{
        .height = if (ifc.line_boxes.items.len > 0)
            ifc.line_boxes.items[ifc.line_boxes.items.len - 1].baseline + s.bottom_height
        else
            0, // TODO: This is never reached because the root inline box always creates at least 1 line box.
        .longest_line_box_length = s.longest_line_box_length,
    };
}
