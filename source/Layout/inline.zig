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
    ifc.font_size = font_props.font_size.px_val();

    // Shape text with HarfBuzz
    layout.inputs.fonts.setFontSize(handle, font_props.font_size.px_val());
    if (layout.inputs.fonts.get(handle)) |hb_font| {
        const glyph_start: u32 = @intCast(ifc.glyphs.len);
        const transformed = switch (font_props.text_transform) {
            .none => text,
            .uppercase => try transformCase(layout.allocator, text, .upper),
            .lowercase => try transformCase(layout.allocator, text, .lower),
            .capitalize => try transformCase(layout.allocator, text, .capitalize),
        };
        try ifcAddText(layout.box_tree, ifc, transformed, hb_font);
        const glyph_end: u32 = @intCast(ifc.glyphs.len);
        if (glyph_end > glyph_start) {
            try ifc.font_runs.append(layout.allocator, .{
                .glyph_start = glyph_start,
                .glyph_end = glyph_end,
                .font_weight = font_props.font_weight,
                .font_style = font_props.font_style,
                .text_transform = font_props.text_transform,
                .font_size = font_props.font_size.px_val(),
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
    font_style: zss.values.types.FontStyle,
    text_transform: zss.values.types.TextTransform,
};

pub fn beginMode(box_gen: *BoxGen, size_mode: SizeMode, containing_block_size: ContainingBlockSize) !void {
    assert(containing_block_size.width >= 0);
    if (containing_block_size.height) |h| assert(h >= 0);

    const ifc = try box_gen.pushIfc();
    // Snapshot the nearest ancestor block's float context with placed floats.
    // CSS 2.1 §9.5: floats affect inline content within the same BFC, even
    // when the inline content is nested (e.g. inside an anonymous block or
    // an explicit <p> sibling of the float). Walk the block_info stack from
    // top down until we find an ancestor that has registered floats.
    //
    // Stage 2: When the float-host IS the immediate parent of this IFC
    // (the dominant case — anonymous inline text directly inside a div
    // that has float siblings), translate each float's y from the parent's
    // content-box coord space into the IFC's local coord space by
    // subtracting the parent's `running_cursor_y` (= where this IFC starts
    // in the parent). Floats placed before the IFC end up at negative y
    // (they overlap the IFC from above) or zero (lead the IFC) or extend
    // into the IFC if their height carries them past the IFC start.
    //
    // For deeper nesting (float-host is a grand-ancestor), translation is
    // approximate — we don't track the cumulative offset across intermediate
    // blocks. Acceptable for Stage 2; lines may be slightly over-narrowed
    // in those cases.
    //
    // Snapshot by value because block_info can realloc during IFC content
    // processing, dangling any captured pointer.
    //
    // BFC scoping (CSS 2.1 §9.4.1): floats only affect inline content within
    // the same Block Formatting Context. If we encounter a BFC root ancestor
    // (a float itself, table cell, overflow:hidden, etc.) before finding any
    // floats, stop — content inside a BFC is shielded from outer floats.
    // This is critical for sibling floats containing text: each sibling
    // float establishes its own BFC, so the second float's text must not
    // be wrapped around the first float.
    const parent_float_ctx: ?flow.FloatContext = blk: {
        const stack = &box_gen.stacks.block_info;
        if (stack.top) |info| {
            if (info.float_ctx.placed_count > 0) {
                var snap = info.float_ctx;
                const offset = info.running_cursor_y;
                if (offset != 0) {
                    var j: u8 = 0;
                    while (j < snap.placed_count) : (j += 1) {
                        snap.placed_floats[j].y -= offset;
                    }
                }
                break :blk snap;
            }
            if (info.is_bfc) break :blk null;
        }
        var i: usize = stack.rest.items.len;
        while (i > 0) {
            i -= 1;
            const info = stack.rest.items[i];
            if (info.float_ctx.placed_count > 0) break :blk info.float_ctx;
            if (info.is_bfc) break :blk null;
        }
        break :blk null;
    };
    try box_gen.inline_context.pushIfc(box_gen.getLayout().allocator, ifc, size_mode, containing_block_size, parent_float_ctx);

    try pushRootInlineBox(box_gen);

    // Set IFC font properties from the containing block's pre-read values.
    // CSS inheritance means the containing block already has correct inherited
    // font/color. Setting at creation time (not bottom-up in popFlowBlock)
    // avoids parent overwriting child IFC fonts.
    if (box_gen.stacks.block_info.top) |block_info| {
        const layout = box_gen.getLayout();
        if (layout.computer.box_gen_stage.map.get(block_info.node)) |bgc| {
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

    // Inject deferred inline ::before from parent block into this IFC.
    if (box_gen.stacks.block_info.top) |*block_info| {
        if (block_info.inline_before_state == .deferred) {
            try insertInlinePseudoElement(box_gen, block_info.node, .before);
            block_info.inline_before_state = .consumed;
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
    // Persist the parent float context on the IFC so later re-layout passes
    // (flex Phase 4 via flow.relayoutIfcAtWidth, grid relayout) can re-apply
    // the same per-line exclusions. Without this, those callers pass `null`
    // and overwrite correctly-wrapped lines with full-width lines.
    ifc.ptr.persisted_parent_float_ctx = ifc.parent_float_ctx;
    const line_split_result = try splitIntoLineBoxes(layout, subtree, ifc.ptr, containing_block_width, ifc.parent_float_ctx);

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
            // Resize the FreeType face so HarfBuzz shapes at the actual font-size.
            layout.inputs.fonts.setFontSize(handle, font.font_size.px_val());
            if (layout.inputs.fonts.get(handle)) |hb_font| {
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
                    for (text) |ch| {
                        switch (ch) {
                            ' ', '\t', '\n', '\r', 0x0c => {},
                            else => {
                                ctx.ifc.top.?.has_visible_content = true;
                                break;
                            },
                        }
                    }
                }
                try ifcAddText(layout.box_tree, ifc.ptr, text, hb_font);
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
            const env_ptr = layout.computer.env;
            const node_type = env_ptr.getNodeProperty(.type, node);
            var name_iter = env_ptr.type_names.iterator(@intFromEnum(node_type.name));
            if (name_iter.eql("br")) {
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

                var font_specified = layout.computer.getSpecifiedValue(.box_gen, .font);
                font_specified.font_size = .{ .px = layout.computer.resolvedFontSizePx(.box_gen) };
                if (font_specified.font_family == .monospace and font_specified.font_size.px_val() == 16.0) {
                    font_specified.font_size = .{ .px = 13.0 };
                }
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
            try insertInlinePseudoElement(box_gen, node, .before);
            try layout.pushNode();
        },
        .block => |block_inner| switch (block_inner) {
            .flow, .flex, .grid => {
                const sizes = inlineBlockSolveSizes(&layout.computer, position, ifc.containing_block_size);
                const stacking_context = inlineBlockSolveStackingContext(&layout.computer, position);

                var ib_font = layout.computer.getSpecifiedValue(.box_gen, .font);
                ib_font.font_size = .{ .px = layout.computer.resolvedFontSizePx(.box_gen) };
                if (ib_font.font_family == .monospace and ib_font.font_size.px_val() == 16.0) {
                    ib_font.font_size = .{ .px = 13.0 };
                }
                layout.computer.setComputedValue(.box_gen, .font, ib_font);
                layout.computer.setComputedValue(.box_gen, .color, layout.computer.getSpecifiedValue(.box_gen, .color));
                layout.computer.setComputedValue(.box_gen, .border_colors, layout.computer.getSpecifiedValue(.box_gen, .border_colors));
                layout.computer.setComputedValue(.box_gen, .border_radii, layout.computer.getSpecifiedValue(.box_gen, .border_radii));
                layout.computer.setComputedValue(.box_gen, .background_color, layout.computer.getSpecifiedValue(.box_gen, .background_color));
                layout.computer.setComputedValue(.box_gen, .background_clip, layout.computer.getSpecifiedValue(.box_gen, .background_clip));
                layout.computer.setComputedValue(.box_gen, .background, layout.computer.getSpecifiedValue(.box_gen, .background));
                layout.computer.setComputedValue(.box_gen, .opacity, layout.computer.getSpecifiedValue(.box_gen, .opacity));
                layout.computer.commitNode(.box_gen);

                if (sizes.get(.inline_size)) |_| {
                    const box_style = BoxTree.BoxStyle{ .outer = .{ .block = .flow }, .position = position };
                    const ref = try box_gen.pushFlowBlock(box_style, sizes, .normal, stacking_context, node);
                    try layout.box_tree.setGeneratedBox(node, .{ .block_ref = ref });
                    // Inline-block is visible content for whitespace-only IFC discard.
                    ctx.ifc.top.?.has_visible_content = true;
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
                    // Inline-block is visible content for whitespace-only IFC discard.
                    ctx.ifc.top.?.has_visible_content = true;
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
        // Inject deferred inline ::after from parent block into this IFC
        // before it closes. This is the last IFC for this block.
        if (box_gen.stacks.block_info.top) |*block_info| {
            if (block_info.inline_after_state == .deferred) {
                try insertInlinePseudoElement(box_gen, block_info.node, .after);
                block_info.inline_after_state = .consumed;
            }
        }
        return try endMode(box_gen);
    }
    // Emit ::after before closing this inline box.
    const inline_box_index = ctx.inline_box.top.?.index;
    if (ifc.ptr.slice().items(.node)[inline_box_index]) |node| {
        try insertInlinePseudoElement(box_gen, node, .after);
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

/// Inject a pseudo-element's string content as glyphs directly into the current IFC.
/// Used for ::before/::after on inline elements (as opposed to block elements,
/// which use insertPseudoElement in flow.zig to create a new block+IFC pair).
fn insertInlinePseudoElement(box_gen: *BoxGen, node: NodeId, pseudo: selectors.PseudoElement) !void {
    const layout = box_gen.getLayout();
    const computer = &layout.computer;
    const saved_current = computer.current;
    defer computer.current = saved_current;

    // Capture parent font and resolved font-size using the explicit element node.
    // sc.current.node may be a text node (e.g. ::after called from nullNode), so we
    // must NOT use getSpecifiedValue() which reads sc.current.node and asserts element.
    const parent_font = computer.getSpecifiedValueForNode(.box_gen, .font, node);
    const font_size_px = computer.resolvedFontSizePxForNode(.box_gen, node);

    if (!computer.setPseudoElement(.box_gen, node, pseudo)) {
        return;
    }

    const gen_content = computer.getSpecifiedValue(.box_gen, .generated_content);
    if (gen_content.content == .normal or gen_content.content == .none) {
        return;
    }

    const text: []const u8 = switch (gen_content.content) {
        .string => |text_id| blk: {
            const t = layout.inputs.env.getText(text_id);
            if (t.len == 0) return;
            break :blk t;
        },
        else => return,
    };

    const ctx = &box_gen.inline_context;
    const ifc = ctx.ifc.top.?.ptr;

    const handle: Fonts.Handle = switch (parent_font.font) {
        .default => layout.inputs.fonts.queryFamily(parent_font.font_family),
        .none => .invalid,
    };

    layout.inputs.fonts.setFontSize(handle, font_size_px);
    if (layout.inputs.fonts.get(handle)) |hb_font| {
        const glyph_start: u32 = @intCast(ifc.glyphs.len);
        try ifcAddText(layout.box_tree, ifc, text, hb_font);
        const glyph_end: u32 = @intCast(ifc.glyphs.len);
        if (glyph_end > glyph_start) {
            try ifc.font_runs.append(layout.allocator, .{
                .glyph_start = glyph_start,
                .glyph_end = glyph_end,
                .font_weight = parent_font.font_weight,
                .font_style = parent_font.font_style,
                .text_transform = parent_font.text_transform,
                .font_size = font_size_px,
            });
            ctx.ifc.top.?.has_visible_content = true;
        }
    }
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
                // Emit a single collapsed space. This space glyph is the
                // soft-wrap break opportunity for splitIntoLineBoxes.
                hb.hb_buffer_add_latin1(buffer, " ", 1, 0, 1);
                if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
                try ifcAddTextRun(box_tree, ifc, buffer, font, true);
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
        try ifcAddTextRun(box_tree, ifc, buffer, font, false);
        assert(hb.hb_buffer_set_length(buffer, 0) != 0);
    }
}

fn ifcAddTextRun(box_tree: BoxTreeManaged, ifc: *Ifc, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, is_break_opportunity: bool) !void {
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
    const bgc = layout.computer.box_gen_stage.map.get(node) orelse return;
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
        .auto => {
            computed.content_height.height = .auto;
            used.setAuto(.block_size);
        },
        .em => unreachable,
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
        var i: u8 = 0;
        while (i < fctx.placed_count) : (i += 1) {
            const f = fctx.placed_floats[i];
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

pub fn splitIntoLineBoxes(
    layout: *Layout,
    subtree: Subtree.View,
    ifc: *Ifc,
    max_line_box_length: Unit,
    parent_float_ctx: ?flow.FloatContext,
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
        //
        // Chrome's line-height:normal uses the font's intrinsic leading
        // (hhea.lineGap) distributed half-above / half-below the baseline —
        // it widens the line-box without shifting the baseline. Omitting it
        // leaves every line ~(line_gap/upem × font-size) px shorter than
        // Chrome, so baselines drift upward in multi-line blocks.
        const dm = layout.inputs.fonts.getDesignMetrics(ifc.font);
        if (dm.units_per_em > 0) {
            const upem: f32 = @floatFromInt(dm.units_per_em);
            const asc_design: f32 = @floatFromInt(dm.ascender);
            const desc_design: f32 = @floatFromInt(dm.descender);
            const line_gap: f32 = @floatFromInt(dm.line_gap);
            const total_design = asc_design + desc_design + line_gap;
            // Compute total line height in layout units, rounding once at the end
            // (Chrome keeps fractional px and only rounds at paint time).
            const scale = ifc.font_size * @as(f32, @floatFromInt(units_per_pixel)) / upem;
            const total_lu: i32 = @intFromFloat(@round(total_design * scale));
            // Split line-gap half above baseline, half below (CSS-aligned
            // half-leading). Baseline stays at ascender + line_gap/2 from top.
            const ascender_with_half_leading = asc_design + line_gap * 0.5;
            ifc.ascender = @intFromFloat(@round(@as(f32, @floatFromInt(total_lu)) * ascender_with_half_leading / total_design));
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

    // Apply explicit line-height before initializing line-split state,
    // so the state captures the adjusted ascender/descender heights.
    // Encoding: 0 = normal, >0 = absolute layout units, <0 = number × -1000.
    var nominal_line_h: Unit = top_height + bottom_height;
    const resolved_lh: Unit = if (ifc.line_height < 0) blk: {
        const factor = @as(f32, @floatFromInt(-ifc.line_height)) / 1000.0;
        break :blk @intFromFloat(@round(factor * ifc.font_size * @as(f32, @floatFromInt(units_per_pixel))));
    } else ifc.line_height;
    if (resolved_lh > 0) {
        // CSS2 §10.8.1 half-leading model: leading = line-height - content-area,
        // split equally above the ascender and below the descender.
        const leading = resolved_lh - nominal_line_h;
        const half_leading = @divFloor(leading, 2);
        top_height += half_leading;
        bottom_height = resolved_lh - top_height;
        nominal_line_h = resolved_lh;
    }

    var s = IFCLineSplitState.init(top_height, bottom_height);
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
    const break_ops = ifc.break_opportunities.items;
    var next_break_op_idx: usize = 0;
    var last_break_i: ?usize = null;
    var last_break_cursor: Unit = 0;
    var last_break_elements_1: usize = 0;
    var last_break_current_inline_box: Ifc.Size = 0;
    var last_break_stack_depth: usize = 0;

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
                    line_top_y += nominal_line_h;
                    if (parent_float_ctx) |fctx2| {
                        const cleared = clearLineYUntilFits(fctx2, line_top_y, nominal_line_h, max_line_box_length, min_useful_w);
                        line_top_y = cleared.line_y;
                        effective_left = cleared.left;
                        effective_right = cleared.right;
                    } else {
                        effective_left = 0;
                        effective_right = max_line_box_length;
                    }
                    s.line_box.x_offset = effective_left;
                    s.cursor = effective_left;
                    continue;
                },
                else => {},
            }
        }

        // TODO: (Bug) A glyph with a width of zero but an advance that is non-zero may overflow the width of the containing block
        // overflow-wrap: break-word allows breaking within words when the line would otherwise overflow.
        const overflow_break_word = ifc.overflow_wrap == .break_word;
        if (s.cursor > effective_left and metrics.width > 0 and s.cursor + metrics.offset + metrics.width > effective_right and (s.line_box.elements[1] > s.line_box.elements[0] or overflow_break_word)) {
            // Prefer rewinding to the last word-boundary break opportunity.
            // SAFETY: only rewind if the inline-box state (current_inline_box
            // and stack depth) is the SAME as it was at the break opportunity.
            // If it's changed, we crossed a BoxStart/BoxEnd between the break
            // and the overflow — re-processing the moved glyphs would corrupt
            // the inline-box stack and panic in popInlineBox. In that case we
            // fall through to the char-break path (pre-fix behavior).
            var rewound = false;
            if (!overflow_break_word) {
                if (last_break_i) |bi| {
                    if (last_break_elements_1 > s.line_box.elements[0]
                        and s.current_inline_box == last_break_current_inline_box
                        and s.inline_box_stack.items.len == last_break_stack_depth)
                    {
                        s.cursor = last_break_cursor;
                        s.line_box.elements[1] = last_break_elements_1;
                        s.finishLineBox();
                        try layout.box_tree.appendLineBox(ifc, s.line_box);
                        s.newLineBox(0);
                        line_top_y += nominal_line_h;
                        if (parent_float_ctx) |fctx2| {
                            const cleared = clearLineYUntilFits(fctx2, line_top_y, nominal_line_h, max_line_box_length, min_useful_w);
                            line_top_y = cleared.line_y;
                            effective_left = cleared.left;
                            effective_right = cleared.right;
                        } else {
                            effective_left = 0;
                            effective_right = max_line_box_length;
                        }
                        s.line_box.x_offset = effective_left;
                        s.cursor = effective_left;
                        i = bi; // loop's i+=1 will advance past the break glyph
                        last_break_i = null;
                        rewound = true;
                    }
                }
            }
            if (!rewound) {
                s.finishLineBox();
                try layout.box_tree.appendLineBox(ifc, s.line_box);
                s.newLineBox(0);
                line_top_y += nominal_line_h;
                if (parent_float_ctx) |fctx2| {
                    const cleared = clearLineYUntilFits(fctx2, line_top_y, nominal_line_h, max_line_box_length, min_useful_w);
                    line_top_y = cleared.line_y;
                    effective_left = cleared.left;
                    effective_right = cleared.right;
                } else {
                    effective_left = 0;
                    effective_right = max_line_box_length;
                }
                s.line_box.x_offset = effective_left;
                s.cursor = effective_left;
                last_break_i = null;
            }
            if (rewound) continue;
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

        // Record break-opportunity state AFTER processing the glyph (so
        // last_break_cursor/elements_1 reflect the line state with the
        // break glyph included). Also capture the inline-box stack state
        // for the rewind safety check.
        while (next_break_op_idx < break_ops.len and break_ops[next_break_op_idx] < i) {
            next_break_op_idx += 1;
        }
        if (next_break_op_idx < break_ops.len and break_ops[next_break_op_idx] == i) {
            last_break_i = i;
            last_break_cursor = s.cursor;
            last_break_elements_1 = s.line_box.elements[1];
            last_break_current_inline_box = s.current_inline_box;
            last_break_stack_depth = s.inline_box_stack.items.len;
            next_break_op_idx += 1;
        }
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