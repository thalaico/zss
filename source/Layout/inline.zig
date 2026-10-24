const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const Fonts = zss.Fonts;
const NodeId = zss.Environment.NodeId;
const Unit = zss.math.Unit;
const units_per_pixel = zss.math.units_per_pixel;
const selectors = zss.selectors;

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
const form_controls = @import("./form_controls.zig");
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

const TransformMode = enum { upper, lower, capitalize };

fn transformCase(allocator: std.mem.Allocator, text: []const u8, mode: TransformMode) ![]const u8 {
    const result = try allocator.dupe(u8, text);
    switch (mode) {
        .upper => {
            for (result) |*ch| ch.* = std.ascii.toUpper(ch.*);
        },
        .lower => {
            for (result) |*ch| ch.* = std.ascii.toLower(ch.*);
        },
        .capitalize => {
            var prev_was_space = true;
            for (result) |*ch| {
                if (prev_was_space and std.ascii.isAlphabetic(ch.*)) {
                    ch.* = std.ascii.toUpper(ch.*);
                }
                prev_was_space = std.ascii.isWhitespace(ch.*);
            }
        },
    }
    return result;
}

pub const Result = struct {
    min_width: Unit,
};

pub const FontProps = struct {
    font: zss.values.types.Font,
    font_family: zss.values.types.FontFamily,
    font_size: zss.values.types.FontSize,
    font_weight: zss.values.types.FontWeight,
    font_style: zss.values.types.FontStyle,
    text_transform: zss.values.types.TextTransform,
};

pub fn beginMode(box_gen: *BoxGen, size_mode: SizeMode, containing_block_size: ContainingBlockSize) !void {
    Layout.profile.inline_modes += 1;
    assert(containing_block_size.width >= 0);
    if (containing_block_size.height) |h| assert(h >= 0);

    const ifc = try box_gen.pushIfc();
    // Floats shorten line boxes only once their positions are known: the
    // BFC pass (bfc.zig) re-splits this IFC when its formatting context has
    // floats.
    const parent_float_ctx: ?flow.FloatContext = null;
    try box_gen.inline_context.pushIfc(box_gen.getLayout().allocator, ifc, size_mode, containing_block_size, parent_float_ctx);

    try pushRootInlineBox(box_gen);

    // Set IFC font properties from the containing block's pre-read values.
    // CSS inheritance means the containing block already has correct inherited
    // font/color. Setting at creation time (not bottom-up in popFlowBlock)
    // avoids parent overwriting child IFC fonts.
    if (box_gen.stacks.block_info.top) |block_info| {
        const layout = box_gen.getLayout();
        const parent_index: u32 = @intCast(block_info.node.value);
        if (parent_index < layout.computer.box_gen_stage.nodes.len) {
            const bgc = layout.computer.box_gen_stage.nodes[parent_index];
            if (bgc.font) |font_specified| {
                ifc.font_family = font_specified.font_family;
                ifc.font_size = font_specified.font_size.px_val();
                ifc.font_weight = font_specified.font_weight;
                ifc.font_style = font_specified.font_style;
                ifc.text_transform = font_specified.text_transform;
                ifc.overflow_wrap = font_specified.overflow_wrap;
                ifc.text_decoration = font_specified.text_decoration;
                ifc.text_align = font_specified.text_align;
                ifc.line_height = font_specified.line_height;
            }
            if (bgc.color) |color_specified| {
                _, const used_color = solve.colorProperty(color_specified);
                ifc.font_color = used_color;
            }
        }
    }
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
    const t_split = Layout.now();
    const line_split_result = try splitIntoLineBoxes(layout, subtree, ifc.ptr, containing_block_width, ifc.parent_float_ctx);
    Layout.profile.line_split_ns += Layout.now() - t_split;
    Layout.profile.line_split_calls += 1;

    // CSS 2.1 §9.2.2.1: In a block container with only block-level children,
    // whitespace-only text content does not generate boxes. Detect whitespace-
    // only IFCs by checking if total glyph advance is negligible (a single
    // collapsed space). Without this, every whitespace text node between block
    // elements adds ~line-height of empty space.
    var effective_height = line_split_result.height;
    // CSS 2.1 §9.2.2.1: In a block container with only block-level children,
    // whitespace-only text content does not generate boxes. We track per-IFC
    // whether ANY visible content (non-whitespace text, an inline box, an
    // inline-block) was added; if not, the IFC contributes zero height to
    // its containing block. This replaces the older width-heuristic that
    // missed cases where the collapsed space rendered slightly wider than
    // the threshold (different fonts produce 16-100 internal-unit spaces).
    if (!ifc.has_visible_content) {
        effective_height = 0;
    }
    // Persist the flag on the IFC so flex re-layout (relayoutIfcAtWidth)
    // re-applies the same zeroing instead of resurrecting line-box height.
    ifc.ptr.has_visible_content = ifc.has_visible_content;
    // Persist the IFC's natural max-content width so consumers (e.g.
    // flow.floatContentWidth for shrink-to-fit floats) can read it without
    // re-running line splitting.
    ifc.ptr.longest_line_box_length = line_split_result.longest_line_box_length;

    box_gen.inline_context.popIfc();
    box_gen.popIfc(ifc.ptr.id, containing_block_width, effective_height);

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
        /// CSS 2.1 §9.2.2.1: tracks whether this IFC has any non-whitespace
        /// inline content. False means the IFC is purely whitespace text and
        /// can be discarded between block-level siblings (no line boxes).
        /// Set to true the moment we see ANY non-whitespace text run, ANY
        /// inline box (which itself may contain content), or ANY inline-block.
        has_visible_content: bool,
        /// Snapshot of the parent block's float context, used by splitIntoLineBoxes
        /// to query per-line exclusions for floats placed before this IFC.
        /// Null when the IFC has no parent block container with float tracking.
        ///
        /// Stored by value (not pointer) because the parent's block_info stack
        /// can realloc during IFC content processing, which would dangle a
        /// pointer captured at beginMode.
        parent_float_ctx: ?flow.FloatContext,
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
        parent_float_ctx: ?flow.FloatContext,
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
            .has_visible_content = false,
            .parent_float_ctx = parent_float_ctx,
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
                ifc.ptr.font_size = font.font_size.px_val();
                ifc.ptr.line_height = font.line_height;
            }
            // Resize the FreeType face so HarfBuzz shapes at the actual font-size,
            // using the family's face for this run's weight/style (a bold run is
            // measured with the bold face — its advances differ from regular).
            layout.inputs.fonts.setFontSizeVariant(handle, font.font_weight, font.font_style, font.font_size.px_val());
            if (layout.inputs.fonts.getVariant(handle, font.font_weight, font.font_style)) |hb_font| {
                // Record glyph range for this text node's font run.
                const glyph_start: u32 = @intCast(ifc.ptr.glyphs.len);
                const raw_text = layout.computer.getText();
                const text = switch (font.text_transform) {
                    .none => raw_text,
                    .uppercase => try transformCase(layout.allocator, raw_text, .upper),
                    .lowercase => try transformCase(layout.allocator, raw_text, .lower),
                    .capitalize => try transformCase(layout.allocator, raw_text, .capitalize),
                };
                // Track for whitespace-only IFC discard (CSS 2.1 §9.2.2.1).
                // If any character in this text run is not HTML whitespace, the
                // IFC has visible content and must not be zeroed in endMode.
                if (!ctx.ifc.top.?.has_visible_content) {
                    // Preserved white space is content (CSS Text 3 §4.1.1).
                    for (text) |ch| {
                        const visible = switch (ch) {
                            ' ', '\t' => font.white_space == .pre or font.white_space == .pre_wrap,
                            '\n' => font.white_space != .normal and font.white_space != .nowrap,
                            '\r', 0x0c => false,
                            else => true,
                        };
                        if (visible) {
                            ctx.ifc.top.?.has_visible_content = true;
                            break;
                        }
                    }
                }
                try ifcAddText(layout.box_tree, ifc.ptr, text, hb_font, font.white_space);
                const glyph_end: u32 = @intCast(ifc.ptr.glyphs.len);
                if (glyph_end > glyph_start) {
                    // Extend the last run if same weight and font size, otherwise start a new one.
                    const runs = &ifc.ptr.font_runs;
                    if (runs.items.len > 0 and
                        runs.items[runs.items.len - 1].font_weight == font.font_weight and
                        runs.items[runs.items.len - 1].font_style == font.font_style and
                        runs.items[runs.items.len - 1].text_transform == font.text_transform and
                        runs.items[runs.items.len - 1].font_size == font.font_size.px_val() and
                        runs.items[runs.items.len - 1].glyph_end == glyph_start)
                    {
                        runs.items[runs.items.len - 1].glyph_end = glyph_end;
                    } else {
                        try runs.append(layout.allocator, .{
                            .glyph_start = glyph_start,
                            .glyph_end = glyph_end,
                            .font_weight = font.font_weight,
                            .font_style = font.font_style,
                            .text_transform = font.text_transform,
                            .font_size = font.font_size.px_val(),
                        });
                    }
                }
            }

            layout.advanceNode();
        },
        .@"inline" => {
            // <br> is a forced line break (HTML5 §4.5.27). It computes to
            // display:inline like other phrasing content, but its layout
            // role is "end this line, start a new one" — not "open an
            // inline box, run text inside, close box". CSS doesn't have
            // a property for this; browsers wire it directly in inline
            // layout. Emit a LineBreak special glyph and skip the normal
            // inline-box machinery (br is a void element — no children,
            // no content). Without this, every `<br>` was silently
            // dropped: "a<br>b" rendered as "a b" on one line, breaking
            // herokuapp/checkbox, contact-form layouts, address blocks,
            // etc.
            if (layout.computer.env.nodeTagEql(node, "br")) {
                try ifcAddLineBreak(layout.box_tree, ifc.ptr);
                ctx.ifc.top.?.has_visible_content = true;
                layout.advanceNode();
                return;
            }

            {
                const data = .{
                    .content_width = layout.computer.getSpecifiedValue(.box_gen, .content_width),
                    .content_height = layout.computer.getSpecifiedValue(.box_gen, .content_height),
                    .z_index = layout.computer.getSpecifiedValue(.box_gen, .z_index),
                };
                layout.computer.setComputedValue(.box_gen, .content_width, data.content_width);
                layout.computer.setComputedValue(.box_gen, .content_height, data.content_height);
                layout.computer.setComputedValue(.box_gen, .z_index, data.z_index);

                const font_specified = layout.computer.computedFont(.box_gen);
                layout.computer.setComputedValue(.box_gen, .font, font_specified);

                layout.computer.setComputedValue(.box_gen, .color, layout.computer.getSpecifiedValue(.box_gen, .color));
                layout.computer.setComputedValue(.box_gen, .border_colors, layout.computer.getSpecifiedValue(.box_gen, .border_colors));
                layout.computer.setComputedValue(.box_gen, .border_radii, layout.computer.getSpecifiedValue(.box_gen, .border_radii));
                layout.computer.setComputedValue(.box_gen, .background_color, layout.computer.getSpecifiedValue(.box_gen, .background_color));
                layout.computer.setComputedValue(.box_gen, .background_clip, layout.computer.getSpecifiedValue(.box_gen, .background_clip));
                layout.computer.setComputedValue(.box_gen, .background, layout.computer.getSpecifiedValue(.box_gen, .background));
                layout.computer.setComputedValue(.box_gen, .insets, layout.computer.getSpecifiedValue(.box_gen, .insets));
                layout.computer.setComputedValue(.box_gen, .opacity, layout.computer.getSpecifiedValue(.box_gen, .opacity));
                layout.computer.commitNode(.box_gen);
            }

            const inline_box_index = try pushInlineBox(box_gen, node);
            const generated_box = GeneratedBox{ .inline_box = .{ .ifc_id = ifc.ptr.id, .index = inline_box_index } };
            try layout.box_tree.setGeneratedBox(node, generated_box);

            writeInlineBoxCosmetic(layout, ifc.ptr, inline_box_index, node);

            // CSS 2.1 §9.4.2: inline boxes are visible content only when they
            // have non-zero margins, padding, or borders. An empty <a> wrapping
            // only an abs-positioned child must NOT set this flag — doing so
            // gives the IFC a non-zero strut that shifts subsequent floats down.
            if (!ctx.ifc.top.?.has_visible_content) {
                const ifc_slice = ifc.ptr.slice();
                const s = ifc_slice.items(.inline_start)[inline_box_index];
                const e = ifc_slice.items(.inline_end)[inline_box_index];
                const bs = ifc_slice.items(.block_start)[inline_box_index];
                const be = ifc_slice.items(.block_end)[inline_box_index];
                const m = ifc_slice.items(.margins)[inline_box_index];
                if (s.border != 0 or s.padding != 0 or
                    e.border != 0 or e.padding != 0 or
                    bs.border != 0 or bs.padding != 0 or
                    be.border != 0 or be.padding != 0 or
                    m.start != 0 or m.end != 0)
                {
                    ctx.ifc.top.?.has_visible_content = true;
                }
            }
            try layout.pushNode();
        },
        .block => |block_inner| switch (block_inner) {
            .flow, .flex, .grid => {
                var sizes = inlineBlockSolveSizes(&layout.computer, position, ifc.containing_block_size);
                form_controls.applyIntrinsicSizes(layout, node, &sizes);
                const stacking_context = inlineBlockSolveStackingContext(&layout.computer, position);

                const box_style_specified = layout.computer.getSpecifiedValue(.box_gen, .box_style);
                const ib_font = layout.computer.computedFont(.box_gen);
                layout.computer.setComputedValue(.box_gen, .font, ib_font);
                layout.computer.setComputedValue(.box_gen, .color, layout.computer.getSpecifiedValue(.box_gen, .color));
                layout.computer.setComputedValue(.box_gen, .border_colors, layout.computer.getSpecifiedValue(.box_gen, .border_colors));
                layout.computer.setComputedValue(.box_gen, .border_radii, layout.computer.getSpecifiedValue(.box_gen, .border_radii));
                layout.computer.setComputedValue(.box_gen, .background_color, layout.computer.getSpecifiedValue(.box_gen, .background_color));
                layout.computer.setComputedValue(.box_gen, .background_clip, layout.computer.getSpecifiedValue(.box_gen, .background_clip));
                layout.computer.setComputedValue(.box_gen, .background, layout.computer.getSpecifiedValue(.box_gen, .background));
                layout.computer.setComputedValue(.box_gen, .opacity, layout.computer.getSpecifiedValue(.box_gen, .opacity));
                layout.computer.commitNode(.box_gen);

                if (block_inner != .flow) {
                    // An inline-level flex or grid container (CSS Display 3
                    // §2.1): generated like a block in flow so its children
                    // are flex or grid items. An auto width is provisional
                    // (the available width) until popFlowBlock shrinks it to
                    // fit, before the container's algorithm runs.
                    const auto_width = sizes.get(.inline_size) == null;
                    const available = solve.clampSize(ifc.containing_block_size.width -
                        (sizes.margin_inline_start_untagged + sizes.margin_inline_end_untagged +
                            sizes.border_inline_start + sizes.border_inline_end +
                            sizes.padding_inline_start + sizes.padding_inline_end), sizes.min_inline_size, sizes.max_inline_size);
                    if (auto_width) sizes.setValue(.inline_size, available);
                    const box_style = BoxTree.BoxStyle{ .outer = .{ .block = .flow }, .position = position };
                    const ref = try box_gen.pushFlowBlock(box_style, sizes, .normal, stacking_context, node);
                    // An inline-block is a BFC root (CSS 2.1 §9.4.1).
                    box_gen.stacks.block_info.top.?.is_bfc = true;
                    if (auto_width) box_gen.stacks.block_info.top.?.fit_content_available = available;
                    flow.setupContainer(box_gen, block_inner, box_style_specified);
                    try layout.box_tree.setGeneratedBox(node, .{ .block_ref = ref });
                    ctx.ifc.top.?.has_visible_content = true;
                    try ifcAddInlineBlock(layout.box_tree, ifc.ptr, ref.index, ib_font.white_space);
                    try layout.pushNode();
                    return box_gen.beginFlowMode(.not_root);
                }

                if (sizes.get(.inline_size)) |_| {
                    const box_style = BoxTree.BoxStyle{ .outer = .{ .block = .flow }, .position = position };
                    const ref = try box_gen.pushFlowBlock(box_style, sizes, .normal, stacking_context, node);
                    // An inline-block is a BFC root (CSS 2.1 §9.4.1).
                    box_gen.stacks.block_info.top.?.is_bfc = true;
                    try layout.box_tree.setGeneratedBox(node, .{ .block_ref = ref });
                    // Inline-block is visible content for whitespace-only IFC discard.
                    ctx.ifc.top.?.has_visible_content = true;
                    try ifcAddInlineBlock(layout.box_tree, ifc.ptr, ref.index, ib_font.white_space);
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
                    // An inline-block is a BFC root (CSS 2.1 §9.4.1).
                    box_gen.stacks.block_info.top.?.is_bfc = true;
                    try layout.box_tree.setGeneratedBox(node, .{ .block_ref = ref });
                    // Inline-block is visible content for whitespace-only IFC discard.
                    ctx.ifc.top.?.has_visible_content = true;
                    try ifcAddInlineBlock(layout.box_tree, ifc.ptr, ref.index, ib_font.white_space);
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
    if (ifc.depth == 1) return try endMode(box_gen);
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
    // The root inline box takes the containing block's font (its strut).
    const block_font = if (box_gen.stacks.block_info.top) |info| layout.computer.committedValue(.box_gen, .font, info.node) else null;
    setInlineBoxMetrics(layout, ifc.ptr, index, block_font orelse layout.computer.computedFont(.box_gen), .baseline, null);
    try ifcAddBoxStart(layout.box_tree, ifc.ptr, index);
    try ctx.pushInlineBox(layout.allocator, index);
}

/// CSS 2.1 §10.8.1: inline box `index`'s content area and layout box from its
/// own font and line-height, and where its baseline sits relative to the root
/// inline box's, from `vertical-align` against its parent inline box
/// (`parent`; null for the root). `top` / `bottom` (aligned to the line box)
/// are not supported for inline boxes and align as `baseline`.
fn setInlineBoxMetrics(layout: *Layout, ifc: *Ifc, index: Ifc.Size, font: anytype, vertical_align: zss.values.types.VerticalAlign, parent: ?Ifc.Size) void {
    const upp: f32 = @floatFromInt(units_per_pixel);
    const handle: Fonts.Handle = switch (font.font) {
        .default => layout.inputs.fonts.queryFamily(font.font_family),
        .none => .invalid,
    };
    const size = font.font_size.px_val();
    const m = layout.inputs.fonts.lineMetrics(handle, size);
    const ascent: Unit = @intFromFloat(m.ascent * upp);
    const descent: Unit = @intFromFloat(m.descent * upp);
    const content: Unit = ascent + descent;
    const line_height: Unit = switch (font.line_height) {
        .normal => content + @as(Unit, @intFromFloat(m.line_gap * upp)),
        .number => |n| @intFromFloat(@round(n * size * upp)),
        .length => |px| @intFromFloat(@round(px * upp)),
        // Font-relative lengths are computed to lengths
        // (StyleComputer.computeFont); these are computed values.
        .em, .rem => unreachable,
    };
    // Blink floors the half-leading above the ascent to whole pixels; the
    // descent side gets the rest.
    const half_leading = @divFloor(@divFloor(line_height - content, 2), units_per_pixel) * units_per_pixel;
    const above = ascent + half_leading;
    const below = line_height - above;

    const slice = ifc.inline_boxes.slice();
    var shift: Unit = 0;
    if (parent) |p| {
        const p_shift = slice.items(.shift)[p];
        const p_em: f32 = @floatFromInt(slice.items(.em)[p]);
        const relative: Unit = switch (vertical_align) {
            .baseline, .top, .bottom => 0,
            // Blink: sub lowers by the parent's font size / 5 + 1px, super
            // raises by its font size / 3 + 1px.
            .sub => @intFromFloat(p_em / 5.0 + upp),
            .super => -@as(Unit, @intFromFloat(p_em / 3.0 + upp)),
            // The content area's top / bottom at the parent's.
            .text_top => ascent - slice.items(.ascent)[p],
            .text_bottom => slice.items(.descent)[p] - descent,
            // The layout box's midpoint at the parent's baseline plus half
            // its x-height.
            .middle => -@divFloor(slice.items(.x_height)[p], 2) - @divFloor(below - above, 2),
            .px => |v| -@as(Unit, @intFromFloat(v * upp)),
            .em => |v| -@as(Unit, @intFromFloat(v * size * upp)),
            .percentage => |v| -@as(Unit, @intFromFloat(v * @as(f32, @floatFromInt(line_height)))),
        };
        shift = p_shift + relative;
    }
    slice.items(.ascent)[index] = ascent;
    slice.items(.descent)[index] = descent;
    slice.items(.above)[index] = above;
    slice.items(.below)[index] = below;
    slice.items(.shift)[index] = shift;
    slice.items(.em)[index] = @intFromFloat(size * upp);
    slice.items(.x_height)[index] = @intFromFloat(m.x_height * upp);
    slice.items(.vertical_align)[index] = vertical_align;
}

fn pushInlineBox(box_gen: *BoxGen, node: NodeId) !Ifc.Size {
    const ctx = &box_gen.inline_context;
    const ifc = &ctx.ifc.top.?;
    const layout = box_gen.getLayout();

    const index = try layout.box_tree.appendInlineBox(ifc.ptr);
    setDataInlineBox(&layout.computer, ifc.ptr.slice(), index, node, ifc.percentage_base_unit);
    if (layout.computer.committedValue(.box_gen, .font, node)) |font| {
        const box_style = layout.computer.committedValue(.box_gen, .box_style, node);
        setInlineBoxMetrics(layout, ifc.ptr, index, font, if (box_style) |b| b.vertical_align else .baseline, ctx.inline_box.top.?.index);
    }
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

/// An atomic inline: a soft wrap opportunity before and after it when
/// its white-space allows wrapping (CSS Text 3 §5.1, as Chromium does).
fn ifcAddInlineBlock(box_tree: BoxTreeManaged, ifc: *Ifc, block_box_index: Subtree.Size, white_space: zss.values.types.WhiteSpace) !void {
    const wrap = white_space != .nowrap and white_space != .pre;
    const allocator = box_tree.ptr.allocator;
    if (wrap and ifc.glyphs.len > 0) try ifc.atomic_breaks.append(allocator, @intCast(ifc.glyphs.len - 1));
    try box_tree.appendSpecialGlyph(ifc, .InlineBlock, block_box_index);
    if (wrap) try ifc.atomic_breaks.append(allocator, @intCast(ifc.glyphs.len - 1));
    ifc.ends_in_collapsible_space = false;
}

fn ifcAddLineBreak(box_tree: BoxTreeManaged, ifc: *Ifc) !void {
    try box_tree.appendSpecialGlyph(ifc, .LineBreak, {});
}

/// CSS Text 3 §4.1.1 white space processing of one text run, then shaping.
/// Collapsible spaces and tabs (`normal`, `nowrap`, `pre-line`) become one
/// space, which collapses into a collapsible space before it in the same
/// inline formatting context (even across inline box boundaries); segment
/// breaks are forced line breaks with `pre`, `pre-wrap` and `pre-line` (which
/// also removes the collapsible spaces around them) and collapsible spaces
/// otherwise. Preserved tabs advance to tab stops (`Tab` glyphs). Spaces
/// are soft wrap opportunities unless `nowrap` or `pre`.
fn ifcAddText(box_tree: BoxTreeManaged, ifc: *Ifc, text: []const u8, font: *hb.hb_font_t, white_space: zss.values.types.WhiteSpace) !void {
    const buffer = hb.hb_buffer_create() orelse unreachable;
    defer hb.hb_buffer_destroy(buffer);
    // TODO: Need to put a limit on the length of text
    _ = hb.hb_buffer_pre_allocate(buffer, @intCast(text.len));
    // TODO direction, script, and language must be determined by examining the text itself
    hb.hb_buffer_set_direction(buffer, hb.HB_DIRECTION_LTR);
    hb.hb_buffer_set_script(buffer, hb.HB_SCRIPT_LATIN);
    hb.hb_buffer_set_language(buffer, hb.hb_language_from_string("en", -1));

    const allocator = box_tree.ptr.allocator;
    const collapse = switch (white_space) {
        .normal, .nowrap, .pre_line => true,
        .pre, .pre_wrap => false,
    };
    const preserve_breaks = switch (white_space) {
        .normal, .nowrap => false,
        .pre, .pre_wrap, .pre_line => true,
    };
    const wrap = switch (white_space) {
        .normal, .pre_wrap, .pre_line => true,
        .nowrap, .pre => false,
    };

    var run_begin: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (preserve_breaks and ch == '\n') {
            try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, i);
            if (white_space == .pre_line) dropTrailingCollapsibleSpace(ifc);
            try ifcAddLineBreak(box_tree, ifc);
            // pre-line: spaces after the break collapse away too.
            ifc.ends_in_collapsible_space = collapse;
            run_begin = i + 1;
            continue;
        }
        const is_space = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
        if (!is_space) continue;
        if (collapse) {
            try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, i);
            if (!ifc.ends_in_collapsible_space) {
                try ifcAddTextRun(box_tree, ifc, buffer, font, " ", wrap);
                try ifc.spaces.append(allocator, .{ .glyph = @intCast(ifc.glyphs.len - 1), .collapsible = true });
                ifc.ends_in_collapsible_space = true;
            }
            run_begin = i + 1;
        } else if (ch == '\t') {
            try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, i);
            const space = try shapeRun(buffer, font, " ");
            const space_advance: u16 = if (space.len > 0) @intCast(@max(0, space[0].advance)) else 0;
            try box_tree.appendSpecialGlyph(ifc, .Tab, space_advance);
            if (wrap) try ifc.break_opportunities.append(allocator, @intCast(ifc.glyphs.len - 1));
            run_begin = i + 1;
        } else if (ch == ' ') {
            // A run of preserved spaces: a soft wrap opportunity after it
            // (pre-wrap), hanging at a line's end.
            try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, i);
            var end = i;
            while (end < text.len and text[end] == ' ') end += 1;
            const first: u32 = @intCast(ifc.glyphs.len);
            try ifcAddTextRun(box_tree, ifc, buffer, font, text[i..end], wrap);
            if (white_space == .pre_wrap) {
                var g = first;
                while (g < ifc.glyphs.len) : (g += 1) try ifc.spaces.append(allocator, .{ .glyph = g, .collapsible = false });
            }
            ifc.ends_in_collapsible_space = false;
            run_begin = end;
            i = end - 1;
        }
    }
    try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, text.len);
}

/// pre-line: a collapsible space right before a segment break is removed.
fn dropTrailingCollapsibleSpace(ifc: *Ifc) void {
    if (!ifc.ends_in_collapsible_space) return;
    const spaces = ifc.spaces.items;
    if (spaces.len == 0 or !spaces[spaces.len - 1].collapsible or spaces[spaces.len - 1].glyph != ifc.glyphs.len - 1) return;
    _ = ifc.spaces.pop();
    ifc.glyphs.len -= 1;
    if (ifc.break_opportunities.items.len > 0 and ifc.break_opportunities.items[ifc.break_opportunities.items.len - 1] == ifc.glyphs.len) {
        _ = ifc.break_opportunities.pop();
    }
}

fn ifcEndTextRun(box_tree: BoxTreeManaged, ifc: *Ifc, text: []const u8, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, run_begin: usize, run_end: usize) !void {
    if (run_end > run_begin) {
        try ifcAddTextRun(box_tree, ifc, buffer, font, text[run_begin..run_end], false);
        ifc.ends_in_collapsible_space = false;
    }
}

/// One shaped glyph as the shaping cache stores it.
const ShapedGlyph = struct { index: GlyphIndex, advance: Unit };

/// Per-layout word shaping cache (Blink's CachingWordShaper idea): text is
/// shaped one collapsed-whitespace-delimited run at a time, and on real
/// pages the same words and the single space recur thousands of times — a
/// 3000-row table shapes 18k runs of which ~1k are distinct. Keyed by the
/// HarfBuzz font, its current scale and the run's bytes; the result is the
/// same glyphs and advances `hb_shape` returns for that run (runs are shaped
/// without surrounding context, as before: the buffer is LTR/Latin). The
/// scale is part of the key because `Fonts.setFontSizeVariant` resizes one
/// `hb_font_t` in place for every size of a face — keyed on the pointer
/// alone, text shaped at 32px was reused at 16px ("R e a c t"). Reset at the
/// start of every layout, so a freed and reused font pointer can never hit.
const FontKey = struct { ptr: usize, x_scale: i32, y_scale: i32 };
fn fontKey(font: *hb.hb_font_t) FontKey {
    var x: c_int = 0;
    var y: c_int = 0;
    hb.hb_font_get_scale(font, &x, &y);
    return .{ .ptr = @intFromPtr(font), .x_scale = x, .y_scale = y };
}
const ShapeKey = struct { font: FontKey, text: []const u8 };
const ShapeKeyContext = struct {
    pub fn hash(_: ShapeKeyContext, key: ShapeKey) u64 {
        const seed = std.hash.Wyhash.hash(0, std.mem.asBytes(&key.font));
        return std.hash.Wyhash.hash(seed, key.text);
    }
    pub fn eql(_: ShapeKeyContext, a: ShapeKey, b: ShapeKey) bool {
        return std.meta.eql(a.font, b.font) and std.mem.eql(u8, a.text, b.text);
    }
};
threadlocal var shape_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
threadlocal var shape_cache: std.HashMapUnmanaged(ShapeKey, []const ShapedGlyph, ShapeKeyContext, 80) = .{};

const ExtentsKey = struct { font: FontKey, glyph: GlyphIndex };
threadlocal var extents_cache: std.AutoHashMapUnmanaged(ExtentsKey, struct { Unit, Unit }) = .{};

/// Forget every cached shaping result and glyph extent (called by
/// `Layout.run`).
pub fn resetShapeCache() void {
    shape_cache = .{};
    extents_cache = .{};
    _ = shape_arena.reset(.retain_capacity);
}

fn shapeRun(buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, text: []const u8) ![]const ShapedGlyph {
    const key: ShapeKey = .{ .font = fontKey(font), .text = text };
    if (shape_cache.get(key)) |hit| return hit;

    const arena = shape_arena.allocator();
    const t_shape = Layout.now();
    assert(hb.hb_buffer_set_length(buffer, 0) != 0);
    hb.hb_buffer_add_utf8(buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
    hb.hb_shape(font, buffer, null, 0);
    Layout.profile.shape_ns += Layout.now() - t_shape;
    Layout.profile.shape_calls += 1;

    var glyph_count: c_uint = 0;
    const glyph_infos = hb.hb_buffer_get_glyph_infos(buffer, &glyph_count);
    var pos_count: c_uint = 0;
    const glyph_positions = hb.hb_buffer_get_glyph_positions(buffer, &pos_count);
    assert(glyph_count == pos_count);
    const glyphs = try arena.alloc(ShapedGlyph, glyph_count);
    // HarfBuzz 26.6 fixed point → layout units (¼ px), keeping kerning/GPOS.
    // Rounded cumulatively: each glyph's advance is the step between the
    // rounded running totals, so a run's width is exact to ¼ px instead of
    // accumulating a per-glyph rounding error (flooring lost ~⅛ px per glyph
    // against Chromium's fractional advances).
    var total_26_6: i64 = 0;
    var placed_units: Unit = 0;
    for (glyphs, 0..) |*g, i| {
        total_26_6 += glyph_positions[i].x_advance;
        const end_units: Unit = @intCast(@divFloor(total_26_6 * units_per_pixel + 32, 64));
        g.* = .{ .index = glyph_infos[i].codepoint, .advance = end_units - placed_units };
        placed_units = end_units;
    }
    try shape_cache.put(arena, .{ .font = key.font, .text = try arena.dupe(u8, text) }, glyphs);
    return glyphs;
}

fn ifcAddTextRun(box_tree: BoxTreeManaged, ifc: *Ifc, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, text: []const u8, is_break_opportunity: bool) !void {
    const shaped = try shapeRun(buffer, font, text);
    const t_glyphs = Layout.now();
    defer Layout.profile.glyph_ns += Layout.now() - t_glyphs;
    const glyph_count = shaped.len;

    for (shaped) |sg| {
        const glyph_index: GlyphIndex = sg.index;
        const shaped_advance: Unit = sg.advance;
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

    // Record a break opportunity at the LAST glyph of this run if it's a
    // CSS-collapsed space sequence. splitIntoLineBoxes consults this list
    // to prefer word-boundary breaks over character-level ones.
    if (is_break_opportunity and glyph_count > 0 and ifc.glyphs.len > 0) {
        const last_glyph_index: u32 = @intCast(ifc.glyphs.len - 1);
        try ifc.break_opportunities.append(box_tree.ptr.allocator, last_glyph_index);
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
    ifc_slice.items(.background)[inline_box_index] = .{};
    ifc_slice.items(.insets)[inline_box_index] = .{ .x = 0, .y = 0 };
    ifc_slice.items(.font_color)[inline_box_index] = .transparent;
}

fn setDataInlineBox(computer: *StyleComputer, ifc: Ifc.Slice, inline_box_index: Ifc.Size, node: NodeId, percentage_base_unit: Unit) void {
    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).
    const env = computer.env;
    // Resolve em values in edges using element's computed font-size.
    const font_size_px = computer.resolvedFontSizePx(.box_gen);
    const specified = .{
        .horizontal_edges = resolveHorizontalEdgesEm(computer.getSpecifiedValue(.box_gen, .horizontal_edges), font_size_px),
        .vertical_edges = resolveVerticalEdgesEm(computer.getSpecifiedValue(.box_gen, .vertical_edges), font_size_px),
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
        .calc => |value| {
            computed.horizontal_edges.margin_left = .{ .calc = value };
            used.margin_inline_start = solve.calc(env, value, percentage_base_unit).?;
        },
        .auto => {
            computed.horizontal_edges.margin_left = .auto;
            used.margin_inline_start = 0;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.horizontal_edges.padding_left = .{ .calc = value };
            used.padding_inline_start = solve.positiveCalc(env, value, percentage_base_unit).?;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.horizontal_edges.margin_right = .{ .calc = value };
            used.margin_inline_end = solve.calc(env, value, percentage_base_unit).?;
        },
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
            used.margin_inline_end = 0;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.horizontal_edges.padding_right = .{ .calc = value };
            used.padding_inline_end = solve.positiveCalc(env, value, percentage_base_unit).?;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.vertical_edges.padding_top = .{ .calc = value };
            used.padding_block_start = solve.positiveCalc(env, value, percentage_base_unit).?;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.vertical_edges.padding_bottom = .{ .calc = value };
            used.padding_block_end = solve.positiveCalc(env, value, percentage_base_unit).?;
        },
        .em => unreachable,
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

fn writeInlineBoxCosmetic(layout: *Layout, ifc: *Ifc, inline_box_index: Ifc.Size, node: NodeId) void {
    const bgc = layout.computer.box_gen_stage.nodes[@intCast(node.value)];
    const color_specified = bgc.color orelse return;
    _, const used_color = solve.colorProperty(color_specified);

    const ifc_slice = ifc.slice();

    if (bgc.border_colors) |bc| {
        const border_colors = solve.borderColors(bc, used_color);
        ifc_slice.items(.inline_start)[inline_box_index].border_color = border_colors.left;
        ifc_slice.items(.inline_end)[inline_box_index].border_color = border_colors.right;
        ifc_slice.items(.block_start)[inline_box_index].border_color = border_colors.top;
        ifc_slice.items(.block_end)[inline_box_index].border_color = border_colors.bottom;
    }

    ifc_slice.items(.font_color)[inline_box_index] = used_color;

    if (bgc.font) |font_specified| {
        ifc_slice.items(.text_decoration)[inline_box_index] = font_specified.text_decoration;
    }

    if (bgc.background_color) |bg_color| {
        if (bgc.background_clip) |bg_clip| {
            if (bgc.background) |bg| {
                const clips = bg_clip.clip;
                const background_clip = clips[(bg.image.len - 1) % clips.len];
                ifc_slice.items(.background)[inline_box_index] = solve.inlineBoxBackground(bg_color.color, background_clip, used_color);
            }
        }
    }
}

fn inlineBlockSolveSizes(
    computer: *StyleComputer,
    position: BoxTree.BoxStyle.Position,
    containing_block_size: ContainingBlockSize,
) BlockUsedSizes {
    // Resolve em values using element's computed font-size.
    const font_size_px = computer.resolvedFontSizePx(.box_gen);
    const specified = flow.resolveBlockEm(BlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .insets = computer.getSpecifiedValue(.box_gen, .insets),
    }, font_size_px);
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    const env = computer.env;
    var computed: BlockComputedSizes = undefined;
    var used: BlockUsedSizes = undefined;
    used.was_auto_inline_size = false;
    used.intrinsic = flow.intrinsicFlags(env, specified);
    used.percent_width = flow.percentWidth(env, specified);
    used.specified_margins = flow.specifiedMargins(env, specified);

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
        .calc => |value| {
            computed.horizontal_edges.padding_left = .{ .calc = value };
            used.padding_inline_start = solve.positiveCalc(env, value, containing_block_size.width).?;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.horizontal_edges.padding_right = .{ .calc = value };
            used.padding_inline_end = solve.positiveCalc(env, value, containing_block_size.width).?;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.horizontal_edges.margin_left = .{ .calc = value };
            used.setValue(.margin_inline_start, solve.calc(env, value, containing_block_size.width).?);
        },
        .auto => {
            computed.horizontal_edges.margin_left = .auto;
            used.setValue(.margin_inline_start, 0);
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.horizontal_edges.margin_right = .{ .calc = value };
            used.setValue(.margin_inline_end, solve.calc(env, value, containing_block_size.width).?);
        },
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
            used.setValue(.margin_inline_end, 0);
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.content_width.min_width = .{ .calc = value };
            used.min_inline_size = solve.positiveCalc(env, value, containing_block_size.width).?;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.content_width.max_width = .{ .calc = value };
            used.max_inline_size = solve.positiveCalc(env, value, containing_block_size.width).?;
        },
        .none => {
            computed.content_width.max_width = .none;
            used.max_inline_size = std.math.maxInt(Unit);
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.content_width.width = .{ .calc = value };
            used.setValue(.inline_size, solve.positiveCalc(env, value, containing_block_size.width).?);
        },
        .auto => {
            computed.content_width.width = .auto;
            used.setAuto(.inline_size);
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.vertical_edges.padding_top = .{ .calc = value };
            used.padding_block_start = solve.positiveCalc(env, value, containing_block_size.width).?;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.vertical_edges.padding_bottom = .{ .calc = value };
            used.padding_block_end = solve.positiveCalc(env, value, containing_block_size.width).?;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.vertical_edges.margin_top = .{ .calc = value };
            used.margin_block_start = solve.calc(env, value, containing_block_size.width).?;
        },
        .auto => {
            computed.vertical_edges.margin_top = .auto;
            used.margin_block_start = 0;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.vertical_edges.margin_bottom = .{ .calc = value };
            used.margin_block_end = solve.calc(env, value, containing_block_size.width).?;
        },
        .auto => {
            computed.vertical_edges.margin_bottom = .auto;
            used.margin_block_end = 0;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.content_height.min_height = .{ .calc = value };
            used.min_block_size = solve.positiveCalc(env, value, containing_block_size.height) orelse 0;
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.content_height.max_height = .{ .calc = value };
            used.max_block_size = solve.positiveCalc(env, value, containing_block_size.height) orelse std.math.maxInt(Unit);
        },
        .none => {
            computed.content_height.max_height = .none;
            used.max_block_size = std.math.maxInt(Unit);
        },
        .em => unreachable,
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
        .calc => |value| {
            computed.content_height.height = .{ .calc = value };
            if (solve.positiveCalc(env, value, containing_block_size.height)) |h|
                used.setValue(.block_size, h)
            else
                used.setAuto(.block_size);
        },
        .auto => {
            computed.content_height.height = .auto;
            used.setAuto(.block_size);
        },
        .em => unreachable,
    }

    computed.insets = solve.insets(specified.insets);
    flow.solveInsets(computed.insets, position, &used);

    // box-sizing: border-box (CSS Box Sizing §4) — a specified width/height
    // includes padding and border; the engine works in content-box sizes.
    // Same adjustment as flow.solveAllSizes; inline-blocks used to skip it,
    // so a `box-sizing: border-box` input/button was padding+border wider
    // than its specified width.
    computed.content_width.box_sizing = specified.content_width.box_sizing;
    if (specified.content_width.box_sizing == .border_box) {
        if (used.get(.inline_size)) |w| {
            const h_adjustment = used.border_inline_start + used.border_inline_end +
                used.padding_inline_start + used.padding_inline_end;
            used.setValue(.inline_size, @max(0, w - h_adjustment));
        }
        if (used.get(.block_size)) |h| {
            const v_adjustment = used.border_block_start + used.border_block_end +
                used.padding_block_start + used.padding_block_end;
            used.setValue(.block_size, @max(0, h - v_adjustment));
        }
    }

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
    var font = fonts.get(ifc.font);
    const ifc_slice = ifc.slice();
    const glyphs_slice = ifc.glyphs.slice();
    const runs = ifc.font_runs.items;

    // Track the current font run: each run's extents must come from the face
    // (weight/style variant) and size it was shaped with — glyph indices are
    // per face. Runs cover text glyphs only; special glyphs (BoxStart, etc.)
    // fall between runs.
    var run_idx: usize = 0;
    var current_run: ?usize = null;

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
                    setMetricsGlyphExtents(metrics, font, 0);
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
                // Advance set by line breaking (the next tab stop).
                .Tab => metrics.* = .{ .offset = 0, .advance = 0, .width = 0 },
            }
        } else {
            // Advance to the font run covering this glyph; restore its face and size.
            while (run_idx < runs.len and runs[run_idx].glyph_end <= i) {
                run_idx += 1;
            }
            if (run_idx < runs.len and i >= runs[run_idx].glyph_start and current_run != run_idx) {
                current_run = run_idx;
                const run = runs[run_idx];
                font = fonts.getVariant(ifc.font, run.font_weight, run.font_style) orelse font;
                fonts.setFontSizeVariant(ifc.font, run.font_weight, run.font_style, run.font_size);
            }
            // Advance already stored from hb_shape; fill extents only.
            setMetricsGlyphExtents(metrics, font, glyph_index);
        }
    }
}

/// Compute the max-content inline size of an IFC from its shaped glyphs.
/// CSS Box Sizing §5: max-content = size if no soft wrap opportunities were taken.
/// This is the sum of all glyph advances — everything on one line.
/// Includes inline-block/inline-flex element widths (InlineBlock specials).
pub fn computeMaxContentWidth(ifc: *const Ifc, subtree: ?Subtree.View) Unit {
    if (ifc.glyphs.len == 0) return 0;
    const glyphs = ifc.glyphs.slice();
    const indices = glyphs.items(.index);
    const metrics = glyphs.items(.metrics);

    var total: Unit = 0;
    var i: usize = 0;
    while (i < glyphs.len) : (i += 1) {
        const gi = indices[i];
        if (gi == 0) {
            // Special glyph pair: [0, encoded_special].
            // Decode the second entry to check for InlineBlock.
            if (i + 1 < glyphs.len) {
                const special = Ifc.Special.decode(indices[i + 1]);
                if (special.kind == .InlineBlock) {
                    if (subtree) |st| {
                        const block_box_index: Subtree.Size = special.data;
                        const box_offsets = st.items(.box_offsets)[block_box_index];
                        const margins = st.items(.margins)[block_box_index];
                        total += box_offsets.border_size.w + margins.left + margins.right;
                    }
                }
            }
            i += 1;
            continue;
        }
        total += metrics[i].advance;
    }
    return total;
}

/// Compute the min-content inline size of an IFC from its shaped glyphs.
/// CSS Box Sizing §5: min-content = size if all soft wrap opportunities were taken.
/// For text with whitespace collapsing, word boundaries are at space glyphs.
/// Space glyphs have width=0 (no ink) but advance>0 (they take horizontal room).
/// We track word segments between spaces and return the widest word's advance.
pub fn computeMinContentWidth(ifc: *const Ifc) Unit {
    if (ifc.glyphs.len == 0) return 0;
    const glyphs = ifc.glyphs.slice();
    const indices = glyphs.items(.index);
    const metrics = glyphs.items(.metrics);

    var max_word_width: Unit = 0;
    var current_word_width: Unit = 0;
    var i: usize = 0;
    while (i < glyphs.len) : (i += 1) {
        const gi = indices[i];
        if (gi == 0) {
            // Special glyph — skip the second element of the pair
            i += 1;
            continue;
        }
        const m = metrics[i];
        if (m.width == 0 and m.advance > 0) {
            // Space glyph (ink-width=0 but positive advance).
            // End current word, start a new one.
            max_word_width = @max(max_word_width, current_word_width);
            current_word_width = 0;
        } else {
            current_word_width += m.advance;
        }
    }
    // Don't forget the last word
    max_word_width = @max(max_word_width, current_word_width);

    return max_word_width;
}

/// Fill only offset (x_bearing) and width (ink width) from glyph extents.
/// Advance is already stored from HarfBuzz shaped output — do not overwrite.
fn setMetricsGlyphExtents(metrics: *Ifc.Metrics, font_opt: ?*hb.hb_font_t, glyph_index: GlyphIndex) void {
    // No resolved font for this IFC (font resolution can fail for unusual
    // scripts/families): glyph advances were already stored at shape time,
    // so lay out with zero ink extents instead of crashing. The text won't
    // paint, but the boxes must still flow.
    const font = font_opt orelse {
        metrics.offset = 0;
        metrics.width = 0;
        return;
    };
    const key: ExtentsKey = .{ .font = fontKey(font), .glyph = glyph_index };
    const entry = extents_cache.getOrPut(shape_arena.allocator(), key) catch {
        metrics.offset, metrics.width = glyphExtents(font, glyph_index);
        return;
    };
    if (!entry.found_existing) entry.value_ptr.* = glyphExtents(font, glyph_index);
    metrics.offset, metrics.width = entry.value_ptr.*;
}

/// Ink offset and width of one glyph in layout units. `hb_font_get_glyph_
/// extents` loads the glyph outline through FreeType; a 3000-row table asks
/// for the same few dozen glyphs ~60k times per layout, so results are kept
/// in `extents_cache` (per layout, reset with the shaping cache).
fn glyphExtents(font: *hb.hb_font_t, glyph_index: GlyphIndex) struct { Unit, Unit } {
    var extents: hb.hb_glyph_extents_t = undefined;
    if (hb.hb_font_get_glyph_extents(font, glyph_index, &extents) == 0) return .{ 0, 0 };
    return .{
        @divFloor(extents.x_bearing * units_per_pixel, 64),
        @divFloor(extents.width * units_per_pixel, 64),
    };
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

const LineContext = struct {
    layout: *Layout,
    subtree: Subtree.View,
    ifc: *Ifc,
};

/// Where inline-block `index` sits on its line (CSS 2.1 §10.8.1): its
/// margin box's extent above the root baseline from `vertical-align`
/// against its parent inline box `parent`. With `baseline` its own baseline
/// (`inlineBlockBaseline`, else its bottom margin edge) is on the parent's.
fn inlineBlockPlacement(layout: *Layout, subtree: Subtree.View, ifc: *Ifc, index: Subtree.Size, cursor: Unit, at: usize, parent: Ifc.Size) IFCLineSplitState.InlineBlockInfo {
    const upp: f32 = @floatFromInt(units_per_pixel);
    const box_offsets = subtree.items(.box_offsets)[index];
    const margins = subtree.items(.margins)[index];
    const height = box_offsets.border_size.h + margins.top + margins.bottom;
    const boxes = ifc.inline_boxes.slice();
    const p_shift = boxes.items(.shift)[parent];
    const p_em: f32 = @floatFromInt(boxes.items(.em)[parent]);
    const align_value: zss.values.types.VerticalAlign = blk: {
        const node = subtree.items(.node)[index] orelse break :blk .baseline;
        const box_style = layout.computer.committedValue(.box_gen, .box_style, node) orelse break :blk .baseline;
        break :blk box_style.vertical_align;
    };
    const baseline_ascent: Unit = if (inlineBlockBaseline(layout, subtree, index)) |b| margins.top + b else height;
    // Its margin box's extent above the parent's baseline.
    const ascent: Unit = switch (align_value) {
        .baseline, .top, .bottom => baseline_ascent,
        .sub => baseline_ascent - @as(Unit, @intFromFloat(p_em / 5.0 + upp)),
        .super => baseline_ascent + @as(Unit, @intFromFloat(p_em / 3.0 + upp)),
        .text_top => boxes.items(.ascent)[parent],
        .text_bottom => height - boxes.items(.descent)[parent],
        // Its vertical midpoint at the parent's baseline plus half the
        // parent's x-height.
        .middle => @divFloor(height, 2) + @divFloor(boxes.items(.x_height)[parent], 2),
        .px => |v| baseline_ascent + @as(Unit, @intFromFloat(v * upp)),
        .em => |v| baseline_ascent + @as(Unit, @intFromFloat(v * p_em)),
        // Percentages refer to the element's own line-height; an
        // inline-block's is its parent's here (it inherits).
        .percentage => |v| baseline_ascent + @as(Unit, @intFromFloat(v * @as(f32, @floatFromInt(boxes.items(.above)[parent] + boxes.items(.below)[parent])))),
    };
    return .{
        .offset = &subtree.items(.offset)[index],
        .cursor = cursor,
        .at = at,
        .above = ascent - p_shift,
        .height = height,
        .line_relative = switch (align_value) {
            .top => .top,
            .bottom => .bottom,
            else => .no,
        },
    };
}

const IFCLineSplitState = struct {
    allocator: Allocator,
    cursor: Unit,
    line_box: Ifc.LineBox,
    inline_blocks_in_this_line_box: std.ArrayListUnmanaged(InlineBlockInfo),
    top_height: Unit,
    max_top_height: Unit,
    bottom_height: Unit,
    /// The current line's extent below its baseline: the strut's, or more
    /// when an inline-block hangs below the baseline.
    max_bottom_height: Unit,
    longest_line_box_length: Unit,
    inline_box_stack: std.ArrayListUnmanaged(Ifc.Size) = .{},
    current_inline_box: Ifc.Size = undefined,
    /// The inline boxes open where the current line starts.
    line_start_boxes: std.ArrayListUnmanaged(Ifc.Size) = .{},
    /// No content yet on the current line (collapsible spaces here are removed).
    at_line_start: bool = true,

    const InlineBlockInfo = struct {
        offset: *zss.math.Vector,
        cursor: Unit,
        /// The glyph index of its placeholder: on a line only if before the
        /// line's end (a rewound line re-places it on the next line).
        at: usize,
        /// Its margin box's extent above the root baseline (negative: below)
        /// and its height.
        above: Unit,
        height: Unit,
        /// `vertical-align: top / bottom` align it to the line box.
        line_relative: enum { no, top, bottom } = .no,
    };

    fn init(allocator: Allocator, top_height: Unit, bottom_height: Unit) IFCLineSplitState {
        return IFCLineSplitState{
            .allocator = allocator,
            .cursor = 0,
            .line_box = .{ .baseline = 0, .elements = [2]usize{ 0, 0 }, .inline_box = undefined },
            .inline_blocks_in_this_line_box = .{},
            .top_height = top_height,
            .max_top_height = top_height,
            .bottom_height = bottom_height,
            .max_bottom_height = bottom_height,
            .longest_line_box_length = 0,
        };
    }

    fn deinit(self: *IFCLineSplitState, allocator: Allocator) void {
        self.inline_blocks_in_this_line_box.deinit(allocator);
        self.inline_box_stack.deinit(allocator);
        self.line_start_boxes.deinit(allocator);
    }

    /// CSS 2.1 §10.8.1: the line box's height covers the strut, the layout
    /// box of every inline box on the line (open at its start or started on
    /// it), and the margin box of every inline-block on it; then the
    /// inline-blocks aligned to the line box itself.
    fn finishLineBox(self: *IFCLineSplitState, lc: LineContext) !void {
        // CSS Text 3 §4.1.2: spaces at the end of the line hang (they take
        // no width), past the inline box edges after them.
        {
            const g = lc.ifc.glyphs.slice();
            var k = self.line_box.elements[1];
            while (k > self.line_box.elements[0]) {
                const j = k - 1;
                if (j >= 1 and j - 1 >= self.line_box.elements[0] and g.items(.index)[j - 1] == 0) {
                    const special = Ifc.Special.decode(g.items(.index)[j]);
                    if (special.kind != .BoxStart and special.kind != .BoxEnd) break;
                    k -= 2;
                    continue;
                }
                if (spaceAt(lc.ifc, j) == null) break;
                self.cursor -= g.items(.metrics)[j].advance;
                self.line_box.trail_start = j;
                k -= 1;
            }
        }
        const boxes = lc.ifc.inline_boxes.slice();
        var above = self.top_height;
        var below = self.bottom_height;
        for (self.line_start_boxes.items) |b| {
            above = @max(above, boxes.items(.above)[b] - boxes.items(.shift)[b]);
            below = @max(below, boxes.items(.below)[b] + boxes.items(.shift)[b]);
        }
        const glyphs = lc.ifc.glyphs.slice();
        var j = self.line_box.elements[0];
        while (j + 1 < self.line_box.elements[1]) : (j += 1) {
            if (glyphs.items(.index)[j] != 0) continue;
            j += 1;
            const special = Ifc.Special.decode(glyphs.items(.index)[j]);
            if (special.kind != .BoxStart) continue;
            const b: Ifc.Size = @intCast(special.data);
            above = @max(above, boxes.items(.above)[b] - boxes.items(.shift)[b]);
            below = @max(below, boxes.items(.below)[b] + boxes.items(.shift)[b]);
        }
        const blocks = self.inline_blocks_in_this_line_box.items;
        for (blocks) |info| {
            if (info.at >= self.line_box.elements[1] or info.line_relative != .no) continue;
            above = @max(above, info.above);
            below = @max(below, info.height - info.above);
        }
        for (blocks) |info| {
            if (info.at >= self.line_box.elements[1] or info.line_relative == .no) continue;
            if (info.height > above + below) switch (info.line_relative) {
                .top => below = info.height - above,
                .bottom => above = info.height - below,
                .no => unreachable,
            };
        }
        self.max_top_height = above;
        self.max_bottom_height = below;
        self.line_box.baseline += above;
        self.longest_line_box_length = @max(self.longest_line_box_length, self.cursor);

        for (blocks) |info| {
            if (info.at >= self.line_box.elements[1]) continue;
            const top = switch (info.line_relative) {
                .no => self.line_box.baseline - info.above,
                .top => self.line_box.baseline - above,
                .bottom => self.line_box.baseline + below - info.height,
            };
            info.offset.* = .{ .x = info.cursor, .y = top };
        }
    }

    fn newLineBox(self: *IFCLineSplitState, skipped_glyphs: usize) void {
        self.cursor = 0;
        self.line_box = .{
            .baseline = self.line_box.baseline + self.max_bottom_height,
            .elements = [2]usize{ self.line_box.elements[1] + skipped_glyphs, self.line_box.elements[1] + skipped_glyphs },
            .inline_box = self.current_inline_box,
        };
        self.max_top_height = self.top_height;
        self.max_bottom_height = self.bottom_height;
        self.at_line_start = true;
        self.inline_blocks_in_this_line_box.clearRetainingCapacity();
        // The boxes open here continue on the new line.
        self.line_start_boxes.clearRetainingCapacity();
        self.line_start_boxes.appendSlice(self.allocator, self.inline_box_stack.items) catch {};
        self.line_start_boxes.append(self.allocator, self.current_inline_box) catch {};
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

/// CSS 2.1 §9.5: when a line box can't fit any inline content beside
/// the floats intersecting it, the line is moved down past the
/// shortest of those floats. Without this fallback, an IFC sandwiched
/// between wide floats keeps creating tiny `effective_right -
/// effective_left` gaps and squeezing one glyph per line into a few
/// pixels — producing the "char-per-line column" bug that wide
/// auto-resolved Wikipedia floats trigger.
///
/// `min_w` is the minimum horizontal space the line needs to be
/// useful. `nominal_line_h` matches IFC line height and is a
/// reasonable proxy for "wide enough for one char or short word".
fn clearLineYUntilFits(
    fctx: flow.FloatContext,
    initial_line_y: Unit,
    line_h: Unit,
    container_width: Unit,
    min_w: Unit,
) struct { line_y: Unit, left: Unit, right: Unit } {
    var line_y = initial_line_y;
    // Iteration limit guards against degenerate cases (overlapping
    // floats whose combined coverage spans many lines).
    var attempts: u8 = 0;
    while (attempts < 32) : (attempts += 1) {
        const ex = fctx.getLineExclusion(line_y, line_h, container_width);
        if (ex.right_limit - ex.left_offset >= min_w) {
            return .{ .line_y = line_y, .left = ex.left_offset, .right = ex.right_limit };
        }
        // Find the lowest float bottom among floats intersecting this
        // line range — that's the first y where one of them stops
        // contributing to the exclusion.
        var next_clear: ?Unit = null;
        for (fctx.floats) |f| {
            if (f.y + f.h <= line_y) continue;
            if (f.y >= line_y + line_h) continue;
            const bottom = f.y + f.h;
            if (next_clear == null or bottom < next_clear.?) next_clear = bottom;
        }
        if (next_clear) |nc| {
            // Step just past this float's bottom. Other floats may
            // still intersect the new line range, so we loop.
            line_y = nc;
        } else {
            break;
        }
    }
    const ex = fctx.getLineExclusion(line_y, line_h, container_width);
    return .{ .line_y = line_y, .left = ex.left_offset, .right = ex.right_limit };
}

/// Ends the current line box and starts the next one below it, shortened
/// by the floats beside it.
const LineStepper = struct {
    floats: ?flow.FloatContext,
    nominal_line_h: Unit,
    max_w: Unit,
    min_w: Unit,

    fn next(self: LineStepper, s: *IFCLineSplitState, lc: LineContext, skipped: usize, line_top: *Unit, right: *Unit) !void {
        try s.finishLineBox(lc);
        try lc.layout.box_tree.appendLineBox(lc.ifc, s.line_box);
        s.newLineBox(skipped);
        line_top.* += self.nominal_line_h;
        var left: Unit = 0;
        right.* = self.max_w;
        if (self.floats) |f| {
            const cleared = clearLineYUntilFits(f, line_top.*, self.nominal_line_h, self.max_w, self.min_w);
            line_top.* = cleared.line_y;
            left = cleared.left;
            right.* = cleared.right;
        }
        s.line_box.x_offset = left;
        s.cursor = left;
    }
};

/// Whether a soft wrap opportunity follows glyph `i`.
fn isBreakAfter(ifc: *const Ifc, i: usize) bool {
    const order = struct {
        fn f(key: u32, item: u32) std.math.Order {
            return std.math.order(key, item);
        }
    }.f;
    const key: u32 = @intCast(i);
    return std.sort.binarySearch(u32, ifc.break_opportunities.items, key, order) != null or
        std.sort.binarySearch(u32, ifc.atomic_breaks.items, key, order) != null;
}

/// The space glyph `i` is, if it is one line breaking treats specially.
fn spaceAt(ifc: *const Ifc, i: usize) ?Ifc.Space {
    const order = struct {
        fn f(key: u32, item: Ifc.Space) std.math.Order {
            return std.math.order(key, item.glyph);
        }
    }.f;
    const index = std.sort.binarySearch(Ifc.Space, ifc.spaces.items, @as(u32, @intCast(i)), order) orelse return null;
    return ifc.spaces.items[index];
}

pub fn splitIntoLineBoxes(
    layout: *Layout,
    subtree: Subtree.View,
    ifc: *Ifc,
    max_line_box_length: Unit,
    parent_float_ctx: ?flow.FloatContext,
) !IFCLineSplitResult {
    assert(max_line_box_length >= 0);

    // The strut: the root inline box's layout box (CSS 2.1 §10.8.1).
    const top_height = ifc.inline_boxes.items(.above)[0];
    const bottom_height = ifc.inline_boxes.items(.below)[0];
    const nominal_line_h: Unit = top_height + bottom_height;
    ifc.ascender = top_height;
    ifc.descender = bottom_height;
    const lc: LineContext = .{ .layout = layout, .subtree = subtree, .ifc = ifc };

    var s = IFCLineSplitState.init(layout.allocator, top_height, bottom_height);
    defer s.deinit(layout.allocator);
    // Minimum useful inline width: ~one font-em-square. Lines narrower
    // than this trigger the §9.5 line-clear fallback so we don't
    // produce char-per-line columns when a wide float dominates the
    // available width.
    const min_useful_w: Unit = nominal_line_h;
    var line_top_y: Unit = 0;
    var effective_left: Unit = 0;
    var effective_right: Unit = max_line_box_length;
    if (parent_float_ctx) |fctx| {
        const cleared = clearLineYUntilFits(fctx, line_top_y, nominal_line_h, max_line_box_length, min_useful_w);
        line_top_y = cleared.line_y;
        effective_left = cleared.left;
        effective_right = cleared.right;
    }

    const glyphs = ifc.glyphs.slice();

    // Word-boundary break-opportunity tracking (Option P).
    // We walk `ifc.break_opportunities` in parallel with the glyph stream
    // and capture state at each break glyph so that a later overflow can
    // rewind to the word boundary instead of breaking mid-word.
    //
    // CRITICAL: we also capture `current_inline_box` and the inline-box
    // stack depth at the break point. If the stack state has changed by
    // the time an overflow occurs (i.e. we crossed a BoxStart or BoxEnd
    // between the break opportunity and the overflow glyph), the rewind
    // is UNSAFE because the recursive inline box state would be inconsistent
    // after re-processing the moved glyphs. In that case we fall back to
    // the char-level break path (same as pre-fix behavior). This protects
    // against the 2026-04-14 popInlineBox assertion crash observed on
    // real-wikipedia / real-lobsters paragraphs with <i>, <b>, <a> inlines.
    var last_break_i: ?usize = null;
    var last_break_cursor: Unit = 0;
    var last_break_elements_1: usize = 0;
    var last_break_current_inline_box: Ifc.Size = 0;
    // The inline boxes open at the last soft wrap opportunity, restored when
    // the line is rewound to it.
    var last_break_stack: std.ArrayListUnmanaged(Ifc.Size) = .{};
    defer last_break_stack.deinit(layout.allocator);
    // CSS Text 3 §5: a word longer than the line overflows it; the line
    // ends at the next soft wrap opportunity.
    var overflowing = false;
    var effective_right_mut = effective_right;
    const lines: LineStepper = .{
        .floats = parent_float_ctx,
        .nominal_line_h = nominal_line_h,
        .max_w = max_line_box_length,
        .min_w = min_useful_w,
    };
    var line_top = line_top_y;

    {
        const gi = glyphs.items(.index)[0];
        assert(gi == 0);
        const special = Ifc.Special.decode(glyphs.items(.index)[1]);
        assert(special.kind == .BoxStart);
        assert(@as(Ifc.Size, special.data) == 0);
        s.pushInlineBox(layout.allocator, 0) catch unreachable;
        s.line_box.elements[1] = 2;
        s.line_box.inline_box = null;
        // Apply first-line float exclusion: shift line origin past any left
        // float, narrow wrap point at any right float.
        s.line_box.x_offset = effective_left;
        s.cursor = effective_left;
    }

    var i: usize = 2;
    while (i < glyphs.len) : (i += 1) {
        const gi = glyphs.items(.index)[i];
        var metrics = glyphs.items(.metrics)[i];
        const marker = i;

        if (gi == 0) {
            i += 1;
            const special = Ifc.Special.decode(glyphs.items(.index)[i]);
            switch (@as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)))) {
                .BoxStart => try s.pushInlineBox(layout.allocator, @as(Ifc.Size, special.data)),
                .BoxEnd => s.popInlineBox(@as(Ifc.Size, special.data)),
                .LineBreak => {
                    try lines.next(&s, lc, 2, &line_top, &effective_right_mut);
                    overflowing = false;
                    last_break_i = null;
                    continue;
                },
                .Tab => {
                    // CSS Text 3 §4.2: to the next tab stop (tab-size 8 spaces),
                    // skipping one closer than half a space.
                    s.at_line_start = false;
                    const space: Unit = special.data;
                    const stop: Unit = @max(1, 8 * space);
                    var advance = stop - @mod(s.cursor - s.line_box.x_offset, stop);
                    if (advance * 2 < space) advance += stop;
                    glyphs.items(.metrics)[marker].advance = advance;
                    metrics.advance = advance;
                },
                .InlineBlock, .ZeroGlyphIndex => s.at_line_start = false,
            }
        } else if (s.at_line_start) {
            if (spaceAt(ifc, i)) |space| {
                if (space.collapsible) {
                    // CSS Text 3 §4.1.2: removed at the start of a line.
                    s.line_box.elements[1] += 1;
                    s.line_box.lead_end = i + 1;
                    continue;
                }
            }
            s.at_line_start = false;
        }

        if (!overflowing and s.cursor > s.line_box.x_offset and metrics.width > 0 and s.cursor + metrics.offset + metrics.width > effective_right_mut) {
            if (last_break_i != null and last_break_elements_1 > s.line_box.elements[0]) {
                // End the line at the last soft wrap opportunity and lay
                // out what follows it again on the next line.
                s.cursor = last_break_cursor;
                s.line_box.elements[1] = last_break_elements_1;
                s.inline_box_stack.clearRetainingCapacity();
                try s.inline_box_stack.appendSlice(layout.allocator, last_break_stack.items);
                s.current_inline_box = last_break_current_inline_box;
                try lines.next(&s, lc, 0, &line_top, &effective_right_mut);
                i = last_break_i.?; // the loop's i += 1 resumes after it
                last_break_i = null;
                continue;
            } else if (ifc.overflow_wrap == .break_word) {
                // overflow-wrap: break-word — an unbreakable word may break
                // anywhere when the line has no other opportunity.
                try lines.next(&s, lc, 0, &line_top, &effective_right_mut);
            } else {
                overflowing = true;
            }
        }

        if (gi == 0) {
            const special = Ifc.Special.decode(glyphs.items(.index)[i]);
            switch (@as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)))) {
                .InlineBlock => {
                    const block_box_index = @as(Subtree.Size, special.data);
                    try s.inline_blocks_in_this_line_box.append(layout.allocator, inlineBlockPlacement(layout, subtree, ifc, block_box_index, s.cursor, i, s.current_inline_box));
                },
                .LineBreak => unreachable,
                else => {},
            }
            s.line_box.elements[1] += 2;
        } else {
            s.line_box.elements[1] += 1;
        }

        s.cursor += metrics.advance;

        if (isBreakAfter(ifc, i)) {
            if (overflowing) {
                // The overflowing word ends here.
                try lines.next(&s, lc, 0, &line_top, &effective_right_mut);
                overflowing = false;
                last_break_i = null;
                continue;
            }
            last_break_i = i;
            last_break_cursor = s.cursor;
            last_break_elements_1 = s.line_box.elements[1];
            last_break_current_inline_box = s.current_inline_box;
            last_break_stack.clearRetainingCapacity();
            try last_break_stack.appendSlice(layout.allocator, s.inline_box_stack.items);
        }
    }

    if (s.line_box.elements[1] > s.line_box.elements[0]) {
        try s.finishLineBox(lc);
        try layout.box_tree.appendLineBox(ifc, s.line_box);
    }

    return IFCLineSplitResult{
        .height = if (ifc.line_boxes.items.len > 0)
            ifc.line_boxes.items[ifc.line_boxes.items.len - 1].baseline + s.max_bottom_height
        else
            0, // TODO: This is never reached because the root inline box always creates at least 1 line box.
        .longest_line_box_length = s.longest_line_box_length,
    };
}

/// The baseline of inline-block `index`, as a distance from its border-box
/// top, or null when it has none (it then aligns by its bottom margin
/// edge). CSS 2.1 §10.8.1: the baseline of its last line box in normal
/// flow, unless it has no in-flow line boxes or its overflow is not
/// visible. A flex or grid container's baseline comes from its first item
/// (CSS Flexbox 1 §8.5, CSS Grid 1 §9.3; its last baseline from its last
/// item), synthesized from the item's bottom border edge when the item has
/// none.
fn inlineBlockBaseline(layout: *Layout, subtree: Subtree.View, index: Subtree.Size) ?Unit {
    return switch (subtree.items(.inner_block)[index]) {
        .flex, .grid => boxBaseline(layout, subtree, index, .first),
        .flow => if (subtree.items(.overflow)[index] != .visible) null else boxBaseline(layout, subtree, index, .last),
    };
}

const BaselineSet = enum { first, last };

/// The first or last baseline of block `index` (CSS Box Alignment 3 §9.1),
/// from its border-box top: from its in-flow children (the first or last
/// one that has a baseline; for a flex or grid container the first or last
/// item, synthesized from the item's bottom border edge if it has none).
fn boxBaseline(layout: *Layout, subtree: Subtree.View, index: Subtree.Size, comptime set: BaselineSet) ?Unit {
    const skips = subtree.items(.skip);
    const end = index + skips[index];
    const content_top = subtree.items(.box_offsets)[index].content_pos.y;
    const is_container = subtree.items(.inner_block)[index] != .flow;
    var result: ?Unit = null;
    var child = index + 1;
    while (child < end) : (child += skips[child]) {
        if (subtree.items(.out_of_flow)[child]) continue;
        if (!is_container and subtree.items(.type)[child] == .block and subtree.items(.float_side)[child] != .none) continue;
        const own = entryBaseline(layout, subtree, child, set) orelse
            (if (is_container and subtree.items(.type)[child] == .block) subtree.items(.box_offsets)[child].border_pos.y + subtree.items(.box_offsets)[child].border_size.h else null);
        if (own) |b| {
            const baseline = content_top + subtree.items(.offset)[child].y + b;
            if (set == .first) return baseline;
            result = baseline;
        }
    }
    return result;
}

/// The baseline of subtree entry `index` (a block, an IFC or a subtree
/// proxy), from the entry's offset origin.
fn entryBaseline(layout: *Layout, subtree: Subtree.View, index: Subtree.Size, comptime set: BaselineSet) ?Unit {
    const box_tree = layout.box_tree.ptr;
    const bo = subtree.items(.box_offsets)[index];
    return switch (subtree.items(.type)[index]) {
        .ifc_container => |ifc_id| blk: {
            const ifc = box_tree.getIfc(ifc_id);
            if (!ifc.has_visible_content or ifc.line_boxes.items.len == 0) break :blk null;
            const line = if (set == .first) ifc.line_boxes.items[0] else ifc.line_boxes.items[ifc.line_boxes.items.len - 1];
            break :blk bo.border_pos.y + line.baseline;
        },
        .block => if (boxBaseline(layout, subtree, index, set)) |b| bo.border_pos.y + b else null,
        .subtree_proxy => |child_id| blk: {
            const child_subtree = box_tree.getSubtree(child_id).view();
            const own = entryBaseline(layout, child_subtree, 0, set) orelse break :blk null;
            break :blk child_subtree.items(.offset)[0].y + own;
        },
    };
}

/// Resolve em values in horizontal edges to px.
fn resolveHorizontalEdgesEm(edges: ComputedValues(.horizontal_edges), fs: f32) ComputedValues(.horizontal_edges) {
    return .{
        .margin_left = edges.margin_left.resolveEm(fs),
        .margin_right = edges.margin_right.resolveEm(fs),
        .padding_left = edges.padding_left.resolveEm(fs),
        .padding_right = edges.padding_right.resolveEm(fs),
        .border_left = edges.border_left,
        .border_right = edges.border_right,
    };
}

/// Resolve em values in vertical edges to px.
fn resolveVerticalEdgesEm(edges: ComputedValues(.vertical_edges), fs: f32) ComputedValues(.vertical_edges) {
    return .{
        .margin_top = edges.margin_top.resolveEm(fs),
        .margin_bottom = edges.margin_bottom.resolveEm(fs),
        .padding_top = edges.padding_top.resolveEm(fs),
        .padding_bottom = edges.padding_bottom.resolveEm(fs),
        .border_top = edges.border_top,
        .border_bottom = edges.border_bottom,
    };
}
