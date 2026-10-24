const BoxGen = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const math = zss.math;
const Environment = zss.Environment;
const Fonts = zss.Fonts;
const Images = zss.Images;
const NodeId = Environment.NodeId;
const Stack = zss.Stack;

const Layout = @import("../Layout.zig");
const IsRoot = Layout.IsRoot;

const flow = @import("flow.zig");
const grid = @import("grid.zig");
const intrinsic = @import("intrinsic.zig");
const bfc = @import("bfc.zig");
const initial = @import("initial.zig");
const @"inline" = @import("inline.zig");
const solve = @import("solve.zig");
const stf = @import("shrink_to_fit.zig");
const positioned = @import("positioned.zig");
const table = @import("table.zig");
const reuse = @import("reuse.zig");
pub const Absolute = @import("AbsoluteContainingBlocks.zig");
pub const StackingContextTreeBuilder = @import("StackingContextTreeBuilder.zig");

const BoxTree = zss.BoxTree;
const BackgroundImage = BoxTree.BackgroundImage;
const BackgroundImages = BoxTree.BackgroundImages;
const BlockRef = BoxTree.BlockRef;
const GeneratedBox = BoxTree.GeneratedBox;
const Ifc = BoxTree.InlineFormattingContext;
const StackingContext = BoxTree.StackingContext;
const StackingContextTree = BoxTree.StackingContextTree;
const Subtree = BoxTree.Subtree;

/// A stack used to keep track of block formatting contexts.
bfc_stack: zss.Stack(usize) = .init(undefined),
inline_context: @"inline".Context = .{},
stf_context: stf.Context = .{},
table_context: table.Context = undefined,
stacks: Stacks = .{},
sct_builder: StackingContextTreeBuilder = .{},
absolute: Absolute = .{},

/// Per-grid-container info preserved past initial layout so nested grids
/// can be re-laid-out when their parent grid resolves a smaller cell width.
/// Without this, relayoutSubtree only updates block widths and leaves the
/// inner grid's track sizes stale at the original (wider) container width.
grid_containers: std.AutoHashMapUnmanaged(GridContainerKey, GridContainerInfo) = .{},
/// Per-flex-container info preserved past initial layout so nested flex
/// containers can be re-laid-out when their parent grid resolves a smaller
/// cell width. Without this, relayoutSubtree only updates block widths and
/// leaves flex item sizes stale at the original (wider) container width.
flex_containers: std.AutoHashMapUnmanaged(FlexContainerKey, FlexContainerInfo) = .{},

pub const GridContainerKey = struct {
    subtree_id: Subtree.Id,
    block_idx: Subtree.Size,
};

pub const GridContainerInfo = struct {
    column_gap: math.Unit,
    row_gap: math.Unit,
    columns: zss.values.types.GridTrackList,
    rows: zss.values.types.GridTrackList,
    areas: zss.values.types.GridAreas,
    child_area_hashes: [128]u32,
    child_count: u8,
    /// `align-items` (CSS Box Alignment 3 §6.1; `normal` behaves as
    /// `stretch` for non-replaced grid items).
    align_items: BlockInfo.FlexAlign = .stretch,
};

pub const FlexContainerKey = struct {
    subtree_id: Subtree.Id,
    block_idx: Subtree.Size,
};

pub const FlexContainerInfo = struct {
    justify: BlockInfo.FlexJustify,
    align_items: BlockInfo.FlexAlign,
    flex_gap: zss.math.Unit,
    flex_is_column: bool,
    flex_wrap: zss.values.types.FlexWrap,
};

pub const Stacks = struct {
    mode: zss.Stack(Mode) = .{},
    subtree: zss.Stack(struct {
        id: Subtree.Id,
        depth: Subtree.Size,
    }) = .{},
    block: zss.Stack(Block) = .{},
    block_info: zss.Stack(BlockInfo) = .{},

    containing_block_size: zss.Stack(ContainingBlockSize) = .{},
};

pub const Mode = enum {
    flow,
    stf,
    @"inline",
};

pub fn getLayout(box_gen: *BoxGen) *Layout {
    return @fieldParentPtr("box_gen", box_gen);
}

pub fn deinit(box_gen: *BoxGen) void {
    const allocator = box_gen.getLayout().allocator;
    box_gen.bfc_stack.deinit(allocator);
    box_gen.inline_context.deinit(allocator);
    box_gen.stf_context.deinit(allocator);
    box_gen.table_context.deinit(allocator);
    box_gen.stacks.mode.deinit(allocator);
    box_gen.stacks.subtree.deinit(allocator);
    box_gen.stacks.block.deinit(allocator);
    box_gen.stacks.block_info.deinit(allocator);
    box_gen.stacks.containing_block_size.deinit(allocator);
    box_gen.sct_builder.deinit(allocator);
    box_gen.absolute.deinit(allocator);
    box_gen.grid_containers.deinit(allocator);
    box_gen.flex_containers.deinit(allocator);
}

pub fn run(box_gen: *BoxGen) !void {
    const allocator = box_gen.getLayout().allocator;
    box_gen.table_context = table.Context.init(allocator);
    const t_analyze = Layout.now();
    try analyzeAllNodes(box_gen);
    reuse.finish(box_gen.getLayout());
    try reuse.repaint(box_gen.getLayout());
    Layout.profile.analyze_ns += Layout.now() - t_analyze;
    // Absolutely positioned boxes: final sizes and positions.
    const t_abs = Layout.now();
    positioned.run(box_gen.getLayout());
    Layout.profile.abs_ns += Layout.now() - t_abs;
    box_gen.sct_builder.endFrame();
}

fn analyzeAllNodes(box_gen: *BoxGen) !void {
    {
        try initial.beginMode(box_gen);
        const root_node, const root_box_style = (try analyzeNode(box_gen.getLayout(), .root, false)) orelse {
            try box_gen.dispatchNullNode(.root, {});
            return;
        };
        try box_gen.dispatch(.root, {}, root_node, root_box_style);
    }

    while (box_gen.stacks.mode.top) |mode| {
        const parent_blockifies = if (box_gen.stacks.block_info.top) |parent_info|
            parent_info.is_flex_container or parent_info.is_grid_container
        else
            false;
        const t0 = Layout.now();
        const analyzed = try analyzeNode(box_gen.getLayout(), .not_root, parent_blockifies);
        const t1 = Layout.now();
        Layout.profile.analyze_node_ns += t1 - t0;
        const node, const box_style = analyzed orelse {
            try box_gen.dispatchNullNode(.not_root, mode);
            Layout.profile.null_ns += Layout.now() - t1;
            continue;
        };
        try box_gen.dispatch(.not_root, mode, node, box_style);
        Layout.profile.dispatch_ns[@intFromEnum(mode)] += Layout.now() - t1;
    }

    try box_gen.dispatchNullNode(.root, {});
}

/// Returns the next node and its box style, or `null` if there is no next node.
/// `parent_blockifies` is true when the parent block is a flex or grid
/// container, triggering CSS Display §2.7 blockification.
fn analyzeNode(layout: *Layout, comptime is_root: IsRoot, parent_blockifies: bool) !?struct { NodeId, BoxTree.BoxStyle } {
    const node = layout.currentNode() orelse return null;
    try layout.computer.setCurrentNode(.box_gen, node);

    switch (layout.inputs.env.getNodeProperty(.category, node)) {
        .text => {
            return .{ node, .text };
        },
        .element => {
            var specified_box_style = layout.computer.getSpecifiedValue(.box_gen, .box_style);
            // CSS Pseudo 4 §2.6: a ::before / ::after whose content computes
            // to none generates no box.
            if (layout.inputs.env.isPseudoElement(node)) switch (layout.computer.getSpecifiedValue(.box_gen, .generated_content).content) {
                .normal, .none => specified_box_style.display = .none,
                else => {},
            };
            const computed_box_style, const used_box_style = solve.boxStyle(specified_box_style, is_root, parent_blockifies);
            layout.computer.setComputedValue(.box_gen, .box_style, computed_box_style);
            return .{ node, used_box_style };
        },
    }
}

fn dispatch(
    box_gen: *BoxGen,
    comptime is_root: IsRoot,
    current_mode: switch (is_root) {
        .root => void,
        .not_root => Mode,
    },
    node: NodeId,
    box_style: BoxTree.BoxStyle,
) !void {
    switch (box_style.outer) {
        .none => {
            // No box, but the element still has computed values
            // (CSS-CASCADE-4§4.4 — computation does not depend on box
            // generation): commit them so `BoxTree.computed_styles` covers it.
            // Its descendants are not visited.
            const layout = box_gen.getLayout();
            layout.computer.stageCosmeticValues(.box_gen);
            layout.computer.commitNode(.box_gen);
            layout.advanceNode();
        },
        .block => try box_gen.dispatchBlockElement(is_root, current_mode, node, box_style),
        .@"inline" => try box_gen.dispatchInlineElement(is_root, current_mode, node, box_style),
        .absolute => {
            // An absolutely positioned box (CSS 2.1 §9.6) is generated like
            // a block in flow, out of flow for its parent; its size and
            // position are finished by `positioned.run` once every
            // containing block is laid out.
            const block_box_style: BoxTree.BoxStyle = .{
                .outer = .{ .block = box_style.outer.absolute },
                .position = box_style.position,
            };
            try box_gen.dispatchBlockElement(is_root, current_mode, node, block_box_style);
        },
    }
}

fn dispatchBlockElement(
    box_gen: *BoxGen,
    comptime is_root: IsRoot,
    current_mode: switch (is_root) {
        .root => void,
        .not_root => Mode,
    },
    node: NodeId,
    box_style: BoxTree.BoxStyle,
) !void {

    // Regular block element handling
    // Get inner box style based on outer type
    const inner_box_style = switch (box_style.outer) {
        .block => |b| b,
        .absolute => |b| b,
        else => unreachable, // dispatchBlockElement should only be called with block or absolute
    };
    switch (is_root) {
        .root => try initial.blockElement(box_gen, node, inner_box_style, box_style.position),
        .not_root => sw: switch (current_mode) {
            .flow => {
                // An unchanged element takes over its previous boxes.
                if (try reuse.tryReuse(box_gen, node, box_style)) return;
                // Table boxes by computed `display` (CSS 2.1 §17.2), not by
                // tag name — also when the element ends an inline run.
                if (try table.dispatch(box_gen, node, box_style)) return;
                try flow.blockElement(box_gen, node, inner_box_style, box_style.position);
            },
            .stf => try stf.blockElement(box_gen, node, inner_box_style, box_style.position),
            .@"inline" => {
                const result = try @"inline".blockElement(box_gen);
                box_gen.afterInlineMode(result);
                const parent_mode = box_gen.stacks.mode.top orelse {
                    return dispatchBlockElement(box_gen, .root, {}, node, box_style);
                };
                continue :sw parent_mode;
            },
        },
    }
}

fn dispatchInlineElement(
    box_gen: *BoxGen,
    comptime is_root: IsRoot,
    current_mode: switch (is_root) {
        .root => void,
        .not_root => Mode,
    },
    node: NodeId,
    box_style: BoxTree.BoxStyle,
) !void {
    // Regular inline element handling
    switch (is_root) {
        .root => {
            const size_mode = initial.beforeInlineMode();
            try beginInlineMode(box_gen, .root, size_mode);
        },
        .not_root => blk: {
            const size_mode: SizeMode = switch (current_mode) {
                .flow => flow.beforeInlineMode(),
                .stf => try stf.beforeInlineMode(box_gen),
                .@"inline" => break :blk,
            };
            try beginInlineMode(box_gen, .not_root, size_mode);
        },
    }
    return @"inline".inlineElement(box_gen, node, box_style.outer.@"inline", box_style.position);
}

fn dispatchNullNode(
    box_gen: *BoxGen,
    comptime is_root: IsRoot,
    current_mode: switch (is_root) {
        .root => void,
        .not_root => Mode,
    },
) !void {
    switch (is_root) {
        .root => initial.nullNode(box_gen),
        .not_root => switch (current_mode) {
            .flow => {
                flow.nullNode(box_gen) orelse return;
                afterFlowMode(box_gen);
            },
            .stf => {
                const result = (try stf.nullNode(box_gen)) orelse return;
                afterStfMode(box_gen, result);
            },
            .@"inline" => {
                const result = (try @"inline".nullNode(box_gen)) orelse return;
                afterInlineMode(box_gen, result);
            },
        },
    }
}

pub fn beginFlowMode(box_gen: *BoxGen, comptime is_root: IsRoot) !void {
    switch (is_root) {
        .root => box_gen.stacks.mode.top = .flow,
        .not_root => try box_gen.stacks.mode.push(box_gen.getLayout().allocator, .flow),
    }
    try flow.beginMode(box_gen);
}

fn afterFlowMode(box_gen: *BoxGen) void {
    assert(box_gen.stacks.mode.pop() == .flow);
    const parent_mode = box_gen.stacks.mode.top orelse {
        return initial.afterFlowMode(box_gen);
    };
    switch (parent_mode) {
        .flow => flow.afterFlowMode(),
        .stf => stf.afterFlowMode(box_gen),
        .@"inline" => @"inline".afterFlowMode(box_gen),
    }
}

pub fn beginStfMode(box_gen: *BoxGen, inner_block: BoxTree.BoxStyle.InnerBlock, sizes: BlockUsedSizes) !void {
    try box_gen.stacks.mode.push(box_gen.getLayout().allocator, .stf);
    try stf.beginMode(box_gen, inner_block, sizes);
}

fn afterStfMode(box_gen: *BoxGen, result: stf.Result) void {
    assert(box_gen.stacks.mode.pop() == .stf);
    const parent_mode = box_gen.stacks.mode.top orelse {
        return initial.afterStfMode();
    };
    switch (parent_mode) {
        .flow => flow.afterStfMode(),
        .stf => stf.afterStfMode(),
        .@"inline" => @"inline".afterStfMode(box_gen, result),
    }
}

fn beginInlineMode(box_gen: *BoxGen, comptime is_root: IsRoot, size_mode: SizeMode) !void {
    switch (is_root) {
        .root => box_gen.stacks.mode.top = .@"inline",
        .not_root => try box_gen.stacks.mode.push(box_gen.getLayout().allocator, .@"inline"),
    }
    try @"inline".beginMode(box_gen, size_mode, box_gen.containingBlockSize());
}

fn afterInlineMode(box_gen: *BoxGen, result: @"inline".Result) void {
    assert(box_gen.stacks.mode.pop() == .@"inline");
    const parent_mode = box_gen.stacks.mode.top orelse {
        return initial.afterInlineMode();
    };
    switch (parent_mode) {
        .flow => flow.afterInlineMode(),
        .stf => stf.afterInlineMode(box_gen, result),
        .@"inline" => @"inline".afterInlineMode(),
    }
}

pub const SizeMode = enum { normal, stf };

pub fn currentSubtree(box_gen: *BoxGen) Subtree.Id {
    return box_gen.stacks.subtree.top.?.id;
}

pub fn pushInitialSubtree(box_gen: *BoxGen) !void {
    const layout = box_gen.getLayout();
    const subtree = try layout.box_tree.newSubtree();
    // An incremental layout's root subtree takes the storage the tree
    // before the previous one used (it is about as large).
    if (layout.incremental) |inc| {
        subtree.blocks = inc.previous.spare_blocks;
        inc.previous.spare_blocks = .{};
        // The first incremental layout after a full one has no spare
        // storage: size it once rather than growing it block by block.
        if (inc.previous.subtrees.items.len > 0) {
            try subtree.blocks.ensureTotalCapacity(layout.box_tree.ptr.allocator, inc.previous.subtrees.items[0].blocks.len);
        }
    }
    box_gen.stacks.subtree.top = .{ .id = subtree.id, .depth = 0 };
}

pub fn pushSubtree(box_gen: *BoxGen) !Subtree.Id {
    const layout = box_gen.getLayout();
    const subtree = try layout.box_tree.newSubtree();
    try box_gen.stacks.subtree.push(layout.allocator, .{ .id = subtree.id, .depth = 0 });
    return subtree.id;
}

pub fn popSubtree(box_gen: *BoxGen) void {
    const item = box_gen.stacks.subtree.pop();
    assert(item.depth == 0);
    const layout = box_gen.getLayout();
    const subtree = layout.box_tree.ptr.getSubtree(item.id).view();
    subtree.items(.offset)[0] = .zero;
}

pub const ContainingBlockSize = struct {
    width: math.Unit,
    height: ?math.Unit,
};

pub fn containingBlockSize(box_gen: *BoxGen) ContainingBlockSize {
    return box_gen.stacks.containing_block_size.top.?;
}

/// The containing block of an absolutely positioned (or fixed) box being
/// generated (CSS 2.1 §10.1): the padding box of the nearest positioned
/// ancestor, else (and for `fixed`) the viewport. Its height is null while
/// the ancestor's height is auto (it is known only after its layout; see
/// `positioned.run`).
pub fn absoluteContainingBlockSize(box_gen: *BoxGen, position: BoxTree.BoxStyle.Position) ContainingBlockSize {
    const viewport = box_gen.getLayout().viewport;
    const icb: ContainingBlockSize = .{ .width = viewport.w, .height = viewport.h };
    if (position == .fixed) return icb;
    const stack = &box_gen.stacks.block_info;
    var i: usize = stack.rest.items.len + 1;
    while (i > 0) {
        i -= 1;
        const info: *const BlockInfo = if (i == stack.rest.items.len) &(stack.top orelse return icb) else &stack.rest.items[i];
        if (info.position == .static) continue;
        const sizes = info.sizes;
        const width = sizes.get(.inline_size) orelse return box_gen.containingBlockSize();
        return .{
            .width = width + sizes.padding_inline_start + sizes.padding_inline_end,
            .height = if (sizes.get(.block_size)) |h| h + sizes.padding_block_start + sizes.padding_block_end else null,
        };
    }
    return icb;
}

const Block = struct {
    index: Subtree.Size,
    skip: Subtree.Size,
};

pub const BlockInfo = struct {
    sizes: BlockUsedSizes,
    stacking_context_id: ?StackingContextTree.Id,
    absolute_containing_block_id: ?Absolute.ContainingBlock.Id,
    node: NodeId,
    out_of_flow: bool,
    position: BoxTree.BoxStyle.Position = .static,
    /// The block's part in a table (CSS 2.1 §17.2), set by `table.zig`.
    /// Rows and row groups are positioned by the table when it closes.
    table_role: table.Role = .none,
    /// This block's computed text-align: the legacy -webkit-* values align
    /// block-level children (`flow.alignToParentTextAlign`).
    text_align: zss.values.types.TextAlign = .start,
    is_flex_container: bool = false,
    /// An inline-level flex or grid container with an auto width: the
    /// available inline size it was generated against. popFlowBlock gives
    /// it its shrink-to-fit width (CSS 2.1 §10.3.9) before running the
    /// flex or grid algorithm.
    fit_content_available: ?math.Unit = null,
    /// justify-content for flex containers (default: flex_start)
    flex_justify: FlexJustify = .flex_start,
    /// align-items for flex containers (default: stretch)
    flex_align: FlexAlign = .stretch,
    /// CSS gap property for flex containers (in layout units, 4 units = 1px)
    flex_gap: zss.math.Unit = 0,
    /// flex-direction for flex containers
    flex_is_column: bool = false,
    /// flex-wrap for flex containers
    flex_wrap: zss.values.types.FlexWrap = .nowrap,
    /// Grid layout container (display: grid)
    is_grid_container: bool = false,
    /// CSS column-gap for grid containers (in layout units, 4 units = 1px)
    grid_column_gap: zss.math.Unit = 0,
    /// CSS row-gap for grid containers (in layout units, 4 units = 1px)
    grid_row_gap: zss.math.Unit = 0,
    /// Grid template columns (parsed track list)
    grid_columns: zss.values.types.GridTrackList = .{},
    /// Grid template rows (parsed track list)
    grid_rows: zss.values.types.GridTrackList = .{},
    /// Grid named areas
    grid_areas: zss.values.types.GridAreas = .{},
    /// Grid area placement hash for this block (0 = auto)
    grid_area_hash: zss.values.types.GridAreaPlacement = 0,
    /// Grid area hashes for children (populated during child block finalization).
    /// Index i corresponds to the i-th in-flow child.
    grid_child_area_hashes: [128]u32 = [_]u32{0} ** 128,
    grid_child_count: u8 = 0,
    /// CSS float property for this block
    float_side: zss.values.types.Float = .none,
    /// CSS clear property for this block
    clear_side: zss.values.types.Clear = .none,
    /// Block establishes a new BFC (table cell, float, overflow!=visible).
    /// Prevents parent-child margin escape through this block.
    is_bfc: bool = false,
    /// Vertical alignment for table cell content (CSS vertical-align on td/th)
    /// flex-grow factor for this block (used when parent is a flex container)
    flex_grow: f32 = 0.0,
    /// flex-shrink factor for this block (used when parent is a flex container)
    flex_shrink: f32 = 1.0,
    /// flex-basis resolved to layout units; -1 = auto
    flex_basis_px: math.Unit = -1,
    /// align-self override for this item (default .auto = defer to container's
    /// align-items). See BoxTree.Subtree.Block.align_self for full semantics.
    align_self: zss.values.types.AlignSelf = .auto,
    /// A float was generated in this BFC root's formatting context:
    /// `bfc.zig` lays the context out when the root is finished.
    bfc_has_floats: bool = false,

    pub const FlexJustify = enum { flex_start, center, flex_end, space_between };
    pub const FlexAlign = enum { stretch, center, flex_start, flex_end };
};

fn newBlock(box_gen: *BoxGen) !BlockRef {
    const layout = box_gen.getLayout();
    const subtree = layout.box_tree.ptr.getSubtree(box_gen.stacks.subtree.top.?.id);
    const index = try layout.box_tree.appendBlockBox(subtree);
    return .{ .subtree = subtree.id, .index = index };
}

fn pushBlock(box_gen: *BoxGen) !BlockRef {
    const ref = try box_gen.newBlock();
    try box_gen.stacks.block.push(box_gen.getLayout().allocator, .{
        .index = ref.index,
        .skip = 1,
    });
    box_gen.stacks.subtree.top.?.depth += 1;
    return ref;
}

fn popBlock(box_gen: *BoxGen) Block {
    const block = box_gen.stacks.block.pop();
    box_gen.stacks.subtree.top.?.depth -= 1;
    box_gen.addSkip(block.skip);
    return block;
}

pub fn addSkip(box_gen: *BoxGen, skip: Subtree.Size) void {
    if (box_gen.stacks.subtree.top.?.depth > 0) {
        box_gen.stacks.block.top.?.skip += skip;
    }
}

pub fn pushInitialContainingBlock(box_gen: *BoxGen, size: math.Size) !BlockRef {
    const ref = try box_gen.newBlock();
    box_gen.stacks.block.top = .{
        .index = ref.index,
        .skip = 1,
    };
    assert(box_gen.stacks.subtree.top.?.depth == 0);
    box_gen.stacks.subtree.top.?.depth += 1;

    const layout = box_gen.getLayout();
    const stacking_context_id = try box_gen.sct_builder.pushInitial(layout.box_tree.ptr, ref);
    const absolute_containing_block_id = try box_gen.absolute.pushInitialContainingBlock(layout.allocator, ref);
    box_gen.stacks.block_info.top = .{
        .sizes = BlockUsedSizes.icb(size),
        .stacking_context_id = stacking_context_id,
        .absolute_containing_block_id = absolute_containing_block_id,
        .node = undefined,
        .out_of_flow = false,
    };
    box_gen.stacks.containing_block_size.top = .{
        .width = size.w,
        .height = size.h,
    };

    return ref;
}

pub fn popInitialContainingBlock(box_gen: *BoxGen) void {
    box_gen.sct_builder.popInitial();
    // box_gen.popAbsoluteContainingBlock();
    const block = box_gen.stacks.block.pop();
    box_gen.stacks.subtree.top.?.depth -= 1;
    assert(box_gen.stacks.subtree.top.?.depth == 0);
    const block_info = box_gen.stacks.block_info.pop();
    _ = box_gen.stacks.containing_block_size.pop();

    const box_tree = box_gen.getLayout().box_tree;
    const subtree = box_tree.ptr.getSubtree(box_gen.stacks.subtree.top.?.id).view();
    const index = block.index;
    // CSS 2.1 Section 8.3.1: The margins of the root element's box do not collapse.
    // Treat the ICB as having a non-zero edge to prevent margin escape through it.
    const parent_edge: @TypeOf(block_info.sizes.border_block_start) = 1;
    _ = flow.offsetChildBlocks(subtree, index, block.skip, block_info.sizes.get(.inline_size).?, parent_edge, box_tree.ptr);
    const width = block_info.sizes.get(.inline_size).?;
    const height = block_info.sizes.get(.block_size).?;
    subtree.items(.skip)[index] = block.skip;
    subtree.items(.type)[index] = .block;
    subtree.items(.stacking_context)[index] = block_info.stacking_context_id;
    subtree.items(.node)[index] = null;
    subtree.items(.box_offsets)[index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
        .border_size = .{ .w = width, .h = height },
    };
    subtree.items(.borders)[index] = .{};
    subtree.items(.margins)[index] = .{};
    subtree.items(.insets)[index] = .{ .x = 0, .y = 0 };
    subtree.items(.out_of_flow)[index] = false;
    subtree.items(.float_side)[index] = .none;
    subtree.items(.clear_side)[index] = .none;
    subtree.items(.visibility)[index] = .visible;
    subtree.items(.flex_grow)[index] = 0.0;
    subtree.items(.flex_shrink)[index] = 1.0;
    subtree.items(.flex_basis_px)[index] = -1;
    subtree.items(.align_self)[index] = .auto;
    subtree.items(.list_style_type)[index] = .none;
    subtree.items(.border_colors)[index] = .{};
    subtree.items(.border_radii)[index] = .{};
    subtree.items(.background)[index] = .{};
    subtree.items(.overflow)[index] = .visible;
    subtree.items(.opacity)[index] = 1.0;
    subtree.items(.creates_absolute_cb)[index] = false;
}

pub fn pushFlowBlock(
    box_gen: *BoxGen,
    box_style: BoxTree.BoxStyle,
    sizes: BlockUsedSizes,
    available_width: union(SizeMode) {
        normal,
        stf: math.Unit,
    },
    stacking_context: StackingContextTreeBuilder.Type,
    node: NodeId,
) !BlockRef {
    const ref = try box_gen.pushBlock();

    const layout = box_gen.getLayout();
    const stacking_context_id = try box_gen.sct_builder.push(layout.allocator, stacking_context, layout.box_tree.ptr, ref);
    const absolute_containing_block_id = try box_gen.pushAbsoluteContainingBlock(box_style, ref);
    try box_gen.stacks.block_info.push(layout.allocator, .{
        .sizes = sizes,
        .stacking_context_id = stacking_context_id,
        .absolute_containing_block_id = absolute_containing_block_id,
        .node = node,
        .out_of_flow = box_style.position == .absolute or box_style.position == .fixed,
        .position = box_style.position,
    });
    try box_gen.stacks.containing_block_size.push(layout.allocator, .{
        .width = switch (available_width) {
            .normal => sizes.get(.inline_size).?,
            .stf => |aw| aw,
        },
        .height = sizes.get(.block_size),
    });

    return ref;
}

/// A float was just finished: mark the root of the formatting context it
/// is in (the nearest ancestor that is a BFC root, CSS 2.1 §9.4.1), which
/// lays the context out with `bfc.zig` when it is finished.
fn markFloat(box_gen: *BoxGen) void {
    const stack = &box_gen.stacks.block_info;
    if (stack.top == null) return;
    var i: usize = stack.rest.items.len + 1;
    while (i > 0) {
        i -= 1;
        const info: *BlockInfo = if (i == stack.rest.items.len) &stack.top.? else &stack.rest.items[i];
        const parent: ?*const BlockInfo = if (i == 0) null else &stack.rest.items[i - 1];
        const is_root = info.is_bfc or info.out_of_flow or info.float_side != .none or
            info.is_flex_container or info.is_grid_container or info.table_role != .none or
            // i == 1: the root element (i == 0 is the initial containing block).
            i <= 1 or (if (parent) |p| p.is_flex_container or p.is_grid_container else true);
        if (is_root) {
            info.bfc_has_floats = true;
            return;
        }
    }
}

/// Pop the current float block from the stack, set its box tree data,
/// and register it in the parent's float_ctx. Called from flow.popBlock
/// for bfc_depth == 0 leaf blocks that would normally skip popFlowBlock.
/// The parent's popFlowBlock will later finalizeFloatRectangles + resplit.
pub fn registerFloatLeaf(box_gen: *BoxGen) void {
    const block_info_top = box_gen.stacks.block_info.top;
    if (block_info_top == null) return;
    if (block_info_top.?.float_side == .none) return;

    const block = box_gen.popBlock();
    var block_info = box_gen.stacks.block_info.pop();
    _ = box_gen.stacks.containing_block_size.pop();

    // Set box tree data for the float so finalizeFloatRectangles
    // (called in the parent's popFlowBlock) can read dimensions.
    {
        const layout = box_gen.getLayout();
        const subtree = layout.box_tree.ptr.getSubtree(box_gen.currentSubtree()).view();
        const width = block_info.sizes.get(.inline_size) orelse return;
        const height = block_info.sizes.get(.block_size) orelse return;
        const inner_block: BoxTree.BoxStyle.InnerBlock = .flow;
        setDataBlock(subtree, block.index, block_info.sizes, block.skip, width, height, block_info.stacking_context_id, block_info.node, true, inner_block);
        subtree.items(.float_side)[block.index] = block_info.float_side;
        subtree.items(.clear_side)[block.index] = block_info.clear_side;
        subtree.items(.visibility)[block.index] = .visible;
        subtree.items(.is_bfc)[block.index] = true; // floats are BFC roots
        const cb = box_gen.stacks.containing_block_size.top orelse ContainingBlockSize{ .width = 0, .height = null };
        writeBlockCosmetic(layout, subtree, block.index, block_info.node, cb.width, cb.height, block_info.position) catch {};
    }

    box_gen.markFloat();
}

/// CSS 2.1 §10.3.9 shrink-to-fit inline size of an inline-level container
/// generated with an auto width: min(max(min-content, available),
/// max-content), clamped by min/max-width.
fn fitContentWidth(layout: *Layout, subtree: Subtree.View, subtree_id: Subtree.Id, index: Subtree.Size, skip: Subtree.Size, sizes: *BlockUsedSizes, available: math.Unit) void {
    const content = intrinsic.contentBoxSizes(layout, subtree, subtree_id, index, skip);
    sizes.setValue(.inline_size, @min(@max(content.min, available), content.max));
}

pub fn popFlowBlock(
    box_gen: *BoxGen,
    auto_width: union(SizeMode) {
        normal,
        stf: math.Unit,
    },
) void {
    const layout = box_gen.getLayout();
    box_gen.sct_builder.pop(layout.box_tree.ptr);
    box_gen.popAbsoluteContainingBlock();
    const block = box_gen.popBlock();
    var block_info = box_gen.stacks.block_info.pop();
    _ = box_gen.stacks.containing_block_size.pop();
    // The specified block margins, before child margins are folded into them.
    const specified_margin_top = block_info.sizes.margin_block_start;
    const specified_margin_bottom = block_info.sizes.margin_block_end;
    // The root element establishes the initial formatting context.
    // (Below it on the stack is only the initial containing block.)
    if (box_gen.stacks.block_info.rest.items.len == 0 and !block_info.out_of_flow) block_info.is_bfc = true;
    // Flex and grid items establish formatting contexts (CSS Flexbox §3,
    // Grid §3).
    if (box_gen.stacks.block_info.top) |parent_info| {
        if (parent_info.is_flex_container or parent_info.is_grid_container) block_info.is_bfc = true;
    }

    // If the parent is a grid container, record this child's grid-area hash.
    // IFC containers (generated for inter-element whitespace) are not grid
    // items per CSS Grid §9.1 — they must not be counted, otherwise
    // child_area_hashes alignment breaks and later children get auto-placed
    // into extra rows instead of their named areas.
    if (box_gen.stacks.block_info.top) |*parent_info| {
        if (parent_info.is_grid_container) {
            const subtree_view = layout.box_tree.ptr.getSubtree(box_gen.currentSubtree()).view();
            const is_ifc = subtree_view.items(.type)[block.index] == .ifc_container;
            if (!is_ifc) {
                if (block_info.grid_area_hash != 0) {
                    if (parent_info.grid_child_count < parent_info.grid_child_area_hashes.len) {
                        parent_info.grid_child_area_hashes[parent_info.grid_child_count] = block_info.grid_area_hash;
                    }
                }
                parent_info.grid_child_count +|= 1;
            }
        }
    }

    const subtree = layout.box_tree.ptr.getSubtree(box_gen.currentSubtree()).view();
    const auto_height = if (block_info.is_flex_container) blk: {
        const key = FlexContainerKey{
            .subtree_id = box_gen.currentSubtree(),
            .block_idx = block.index,
        };
        box_gen.flex_containers.put(box_gen.getLayout().allocator, key, .{
            .justify = block_info.flex_justify,
            .align_items = block_info.flex_align,
            .flex_gap = block_info.flex_gap,
            .flex_is_column = block_info.flex_is_column,
            .flex_wrap = block_info.flex_wrap,
        }) catch {};
        if (block_info.fit_content_available) |available| fitContentWidth(layout, subtree, box_gen.currentSubtree(), block.index, block.skip, &block_info.sizes, available);
        const container_width = block_info.sizes.get(.inline_size).?;
        const container_height = block_info.sizes.get(.block_size);
        const height = flow.offsetChildBlocksFlex(layout, subtree, box_gen.currentSubtree(), block.index, block.skip, container_width, container_height, block_info.flex_justify, block_info.flex_align, block_info.flex_gap, block_info.flex_is_column, block_info.flex_wrap);
        break :blk height;
    } else if (block_info.is_grid_container) blk: {
        const container_height = block_info.sizes.get(.block_size);
        // Persist grid template + children info so that if a parent grid later
        // resizes this block's containing cell, relayout.zig can re-run
        // grid layout instead of just resizing this block's box. Without this
        // step nested grids inside narrower outer cells overflow (Wikipedia
        // .vector-column-end clipping case).
        const key = GridContainerKey{
            .subtree_id = box_gen.currentSubtree(),
            .block_idx = block.index,
        };
        box_gen.grid_containers.put(box_gen.getLayout().allocator, key, .{
            .column_gap = block_info.grid_column_gap,
            .row_gap = block_info.grid_row_gap,
            .columns = block_info.grid_columns,
            .rows = block_info.grid_rows,
            .areas = block_info.grid_areas,
            .child_area_hashes = block_info.grid_child_area_hashes,
            .child_count = block_info.grid_child_count,
            .align_items = block_info.flex_align,
        }) catch {};
        if (block_info.fit_content_available) |available| fitContentWidth(layout, subtree, box_gen.currentSubtree(), block.index, block.skip, &block_info.sizes, available);
        const grid_width = block_info.sizes.get(.inline_size).?;
        break :blk grid.layoutGridChildren(layout, subtree, block.index, block.skip, grid_width, container_height, block_info.grid_column_gap, block_info.grid_row_gap, block_info.grid_columns, block_info.grid_rows, block_info.grid_areas, &block_info.grid_child_area_hashes, block_info.grid_child_count);
    } else if (block_info.table_role == .table)
        // CSS 2.1 §17.5 / CSS Tables 3: columns, the table's used width,
        // cell relayout, rows and positions. Sets the used inline size.
        table.layoutTable(box_gen, subtree, box_gen.currentSubtree(), block.index, &block_info.sizes)
    else if (block_info.table_role == .row or block_info.table_role == .row_group)
        // Sized and positioned by the table's layout when the table closes.
        0
    else blk: {
        const container_width = switch (auto_width) {
            .normal => block_info.sizes.get(.inline_size).?,
            .stf => |aw| aw,
        };
        var parent_edge = block_info.sizes.border_block_start + block_info.sizes.padding_block_start;
        // BFC roots (absolutely positioned boxes among them) prevent
        // parent-child margin collapsing (CSS 2.1 §8.3.1, §9.4.1).
        const bfc_root = block_info.is_bfc or block_info.out_of_flow;
        if (bfc_root and parent_edge == 0) parent_edge = 1;
        const result = flow.offsetChildBlocks(subtree, block.index, block.skip, container_width, parent_edge, layout.box_tree.ptr);
        // A formatting context with floats is laid out top-down instead.
        if (block_info.bfc_has_floats) break :blk bfc.layoutBfc(layout, subtree, box_gen.currentSubtree(), block.index, block.skip, container_width);
        // Parent-child margin collapsing: adjust parent's margin to absorb
        // the first child's escaped margin (CSS 2.1 Section 8.3.1).
        if (!bfc_root) block_info.sizes.margin_block_start = result.escaped_top.with(block_info.sizes.margin_block_start).sum();
        // The last child's bottom margin collapses with this block's.
        const end_edges = block_info.sizes.border_block_end + block_info.sizes.padding_block_end;
        if (flow.collapsesBottomMargin(bfc_root, block_info.sizes.get(.block_size) == null, end_edges, result, block_info.sizes.min_block_size, block_info.sizes.max_block_size)) {
            block_info.sizes.margin_block_end = result.trailing.with(block_info.sizes.margin_block_end).sum();
            break :blk result.content_end;
        }
        break :blk result.auto_height;
    };
    const width = switch (auto_width) {
        .normal => block_info.sizes.get(.inline_size).?,
        .stf => |aw| flow.solveUsedWidth(aw, block_info.sizes.min_inline_size, block_info.sizes.max_inline_size),
    };
    const height = blk: {
        const base = flow.solveUsedHeight(block_info.sizes, auto_height);
        if (block_info.sizes.get(.block_size) == null and auto_height == 0 and width > 0) {
            const ar_w = layout.inputs.env.getNodeProperty(.aspect_ratio_w, block_info.node);
            const ar_h = layout.inputs.env.getNodeProperty(.aspect_ratio_h, block_info.node);
            if (ar_w > 0 and ar_h > 0) {
                break :blk solve.clampSize(
                    @divFloor(width * @as(math.Unit, ar_h), @as(math.Unit, ar_w)),
                    block_info.sizes.min_block_size,
                    block_info.sizes.max_block_size,
                );
            }
        }
        break :blk base;
    };
    const inner_block: BoxTree.BoxStyle.InnerBlock =
        if (block_info.is_flex_container) .flex else if (block_info.is_grid_container) .grid else .flow;
    setDataBlock(subtree, block.index, block_info.sizes, block.skip, width, height, block_info.stacking_context_id, block_info.node, block_info.out_of_flow, inner_block);
    subtree.items(.block_margins)[block.index] = .{ specified_margin_top, specified_margin_bottom };
    subtree.items(.bfc_floats)[block.index] = block_info.bfc_has_floats;
    subtree.items(.float_side)[block.index] = block_info.float_side;
    subtree.items(.clear_side)[block.index] = block_info.clear_side;
    subtree.items(.visibility)[block.index] = .visible;
    // Mirror the BFC flag onto the subtree so layout-time consumers
    // (e.g. flow.resplitWalk) can scope outer-float exclusion correctly.
    // Flex/grid items are also BFCs per CSS Flexbox §3 and Grid §3.
    const parent_was_flex_or_grid = if (box_gen.stacks.block_info.top) |parent_info|
        (parent_info.is_flex_container or parent_info.is_grid_container)
    else
        false;
    subtree.items(.is_bfc)[block.index] = block_info.is_bfc or parent_was_flex_or_grid;
    subtree.items(.flex_grow)[block.index] = block_info.flex_grow;
    subtree.items(.flex_shrink)[block.index] = block_info.flex_shrink;
    subtree.items(.flex_basis_px)[block.index] = block_info.flex_basis_px;
    subtree.items(.align_self)[block.index] = block_info.align_self;
    subtree.items(.list_style_type)[block.index] = .none;

    const cb = box_gen.stacks.containing_block_size.top orelse ContainingBlockSize{ .width = 0, .height = null };
    writeBlockCosmetic(layout, subtree, block.index, block_info.node, cb.width, cb.height, block_info.position) catch {};
    if (block_info.table_role == .table) table.afterTableCosmetic(box_gen, subtree, box_gen.currentSubtree(), block.index);

    if (block_info.float_side != .none) box_gen.markFloat();
}

pub fn pushStfFlowBlock(
    box_gen: *BoxGen,
    // box_style: BoxTree.BoxStyle,
    sizes: BlockUsedSizes,
    available_width: math.Unit,
    stacking_context: StackingContextTreeBuilder.Type,
) !?StackingContextTree.Id {
    const layout = box_gen.getLayout();
    try box_gen.stacks.containing_block_size.push(layout.allocator, .{
        .width = available_width,
        .height = sizes.get(.block_size),
    });
    const stacking_context_id = try box_gen.sct_builder.pushWithoutBlock(layout.allocator, stacking_context, layout.box_tree.ptr);
    // const absolute_containing_block_id = try box_gen.pushAbsoluteContainingBlock(box_style, undefined);
    return stacking_context_id;
}

pub fn popStfFlowBlock(box_gen: *BoxGen) void {
    _ = box_gen.stacks.containing_block_size.pop();
    box_gen.sct_builder.pop(box_gen.getLayout().box_tree.ptr);
    // box_gen.popAbsoluteContainingBlock();
}

pub fn pushStfFlowBlock2(box_gen: *BoxGen) !BlockRef {
    return box_gen.pushBlock();
}

pub fn popStfFlowBlock2(
    box_gen: *BoxGen,
    auto_width: math.Unit,
    sizes: BlockUsedSizes,
    stacking_context_id: ?StackingContextTree.Id,
    // absolute_containing_block_id: ?Absolute.ContainingBlock.Id,
    node: NodeId,
) void {
    const block = box_gen.popBlock();

    const box_tree = box_gen.getLayout().box_tree;
    const subtree_id = box_gen.stacks.subtree.top.?.id;
    const subtree = box_tree.ptr.getSubtree(subtree_id).view();
    const container_width = sizes.get(.inline_size) orelse auto_width;
    const parent_edge = sizes.border_block_start + sizes.padding_block_start;
    const auto_height = flow.offsetChildBlocks(subtree, block.index, block.skip, container_width, parent_edge, box_tree.ptr).auto_height;
    const width = flow.solveUsedWidth(auto_width, sizes.min_inline_size, sizes.max_inline_size); // TODO This is probably redundant
    const height = blk: {
        const base = flow.solveUsedHeight(sizes, auto_height);
        if (sizes.get(.block_size) == null and auto_height == 0 and width > 0) {
            const env = box_gen.getLayout().inputs.env;
            const ar_w = env.getNodeProperty(.aspect_ratio_w, node);
            const ar_h = env.getNodeProperty(.aspect_ratio_h, node);
            if (ar_w > 0 and ar_h > 0) {
                break :blk solve.clampSize(
                    @divFloor(width * @as(math.Unit, ar_h), @as(math.Unit, ar_w)),
                    sizes.min_block_size,
                    sizes.max_block_size,
                );
            }
        }
        break :blk base;
    };
    // STF flow block: always flow (this is the split-text-flow subtree path).
    setDataBlock(subtree, block.index, sizes, block.skip, width, height, stacking_context_id, node, false, .flow);

    const ref: BlockRef = .{ .subtree = subtree_id, .index = block.index };
    if (stacking_context_id) |id| box_gen.sct_builder.setBlock(id, box_tree.ptr, ref);
    // if (absolute_containing_block_id) |id| box_gen.fixupAbsoluteContainingBlock(id, ref);
}

pub fn addSubtreeProxy(box_gen: *BoxGen, id: Subtree.Id) !void {
    box_gen.addSkip(1);

    const box_tree = box_gen.getLayout().box_tree;
    const ref = try box_gen.newBlock();
    const parent_subtree = box_tree.ptr.getSubtree(box_gen.stacks.subtree.top.?.id);
    const child_subtree = box_tree.ptr.getSubtree(id);
    setDataSubtreeProxy(parent_subtree.view(), ref.index, child_subtree);
    child_subtree.parent = ref;
}

pub fn pushIfc(box_gen: *BoxGen) !*Ifc {
    const box_tree = box_gen.getLayout().box_tree;
    const container = try box_gen.pushBlock();
    const ifc = try box_tree.newIfc(container);
    try box_gen.sct_builder.addIfc(box_tree.ptr, ifc.id);
    return ifc;
}

pub fn popIfc(box_gen: *BoxGen, ifc: Ifc.Id, containing_block_width: math.Unit, height: math.Unit) void {
    const block = box_gen.popBlock();

    const box_tree = box_gen.getLayout().box_tree;
    const subtree = box_tree.ptr.getSubtree(box_gen.stacks.subtree.top.?.id).view();
    setDataIfcContainer(subtree, ifc, block.index, block.skip, containing_block_width, height);
}

pub fn pushAbsoluteContainingBlock(
    box_gen: *BoxGen,
    box_style: BoxTree.BoxStyle,
    ref: BlockRef,
) !?Absolute.ContainingBlock.Id {
    return box_gen.absolute.pushContainingBlock(box_gen.getLayout().allocator, box_style, ref);
}

pub fn pushInitialAbsoluteContainingBlock(box_gen: *BoxGen, ref: BlockRef) !?Absolute.ContainingBlock.Id {
    return try box_gen.absolute.pushInitialContainingBlock(box_gen.getLayout().allocator, ref);
}

pub fn popAbsoluteContainingBlock(box_gen: *BoxGen) void {
    return box_gen.absolute.popContainingBlock();
}

pub fn fixupAbsoluteContainingBlock(box_gen: *BoxGen, id: Absolute.ContainingBlock.Id, ref: BlockRef) void {
    return box_gen.absolute.fixupContainingBlock(id, ref);
}


pub const BlockComputedSizes = struct {
    content_width: ComputedValues(.content_width),
    horizontal_edges: ComputedValues(.horizontal_edges),
    content_height: ComputedValues(.content_height),
    vertical_edges: ComputedValues(.vertical_edges),
    insets: ComputedValues(.insets),

    const ComputedValues = zss.values.groups.Tag.ComputedValues;
};

/// Fields ending with `_untagged` each have an associated flag.
/// If the flag is `.auto`, then the field will have a value of `0`.
// TODO: The field names of this struct are misleading.
//       zss currently does not support logical properties.
pub const BlockUsedSizes = struct {
    border_inline_start: math.Unit,
    border_inline_end: math.Unit,
    padding_inline_start: math.Unit,
    padding_inline_end: math.Unit,
    margin_inline_start_untagged: math.Unit,
    margin_inline_end_untagged: math.Unit,
    inline_size_untagged: math.Unit,
    min_inline_size: math.Unit,
    max_inline_size: math.Unit,

    border_block_start: math.Unit,
    border_block_end: math.Unit,
    padding_block_start: math.Unit,
    padding_block_end: math.Unit,
    margin_block_start: math.Unit,
    margin_block_end: math.Unit,
    block_size_untagged: math.Unit,
    min_block_size: math.Unit,
    max_block_size: math.Unit,

    inset_inline_start_untagged: math.Unit,
    inset_inline_end_untagged: math.Unit,
    inset_block_start_untagged: math.Unit,
    inset_block_end_untagged: math.Unit,

    flags: Flags,

    /// True when the cascaded `inline-size` (width) was `auto` BEFORE
    /// `adjustWidthAndMargins` filled it in with the containing-block's
    /// width. Used by `popFlowBlock` to distinguish auto-width floats
    /// (which register their IFC line-exclusion rectangle at the
    /// shrink-to-fit width) from explicitly-sized floats (which keep their
    /// author-specified width). After `adjustWidthAndMargins`, `flags
    /// .inline_size` is `.value` for both auto AND explicit.
    was_auto_inline_size: bool = false,
    /// Specified width / inline margin kinds, copied to the box for
    /// intrinsic contributions. Set by every size solver.
    intrinsic: BoxTree.Subtree.IntrinsicFlags = .{},
    percent_width: BoxTree.Subtree.PercentWidth = .{ .percentage = 0 },
    specified_margins: [2]math.Unit = .{ 0, 0 },

    pub const Flags = packed struct {
        inline_size: IsAutoTag,
        margin_inline_start: IsAutoTag,
        margin_inline_end: IsAutoTag,
        block_size: IsAutoTag,
        inset_inline_start: IsAutoOrPercentageTag,
        inset_inline_end: IsAutoOrPercentageTag,
        inset_block_start: IsAutoOrPercentageTag,
        inset_block_end: IsAutoOrPercentageTag,

        const Field = std.meta.FieldEnum(Flags);
    };

    pub const IsAutoTag = enum(u1) { value, auto };
    pub const IsAuto = union(IsAutoTag) {
        value: math.Unit,
        auto,
    };

    pub const IsAutoOrPercentageTag = enum(u2) { value, auto, percentage };
    pub const IsAutoOrPercentage = union(IsAutoOrPercentageTag) {
        value: math.Unit,
        auto,
        percentage: f32,
    };

    pub fn setValue(self: *BlockUsedSizes, comptime field: Flags.Field, value: math.Unit) void {
        @field(self.flags, @tagName(field)) = .value;
        const clamped_value = switch (field) {
            .inline_size => solve.clampSize(value, self.min_inline_size, self.max_inline_size),
            .margin_inline_start, .margin_inline_end => value,
            .block_size => solve.clampSize(value, self.min_block_size, self.max_block_size),
            .inset_inline_start, .inset_inline_end, .inset_block_start, .inset_block_end => value,
        };
        @field(self, @tagName(field) ++ "_untagged") = clamped_value;
    }

    pub fn setValueFlagOnly(self: *BlockUsedSizes, comptime field: Flags.Field) void {
        @field(self.flags, @tagName(field)) = .value;
    }

    pub fn setAuto(self: *BlockUsedSizes, comptime field: Flags.Field) void {
        @field(self.flags, @tagName(field)) = .auto;
        @field(self, @tagName(field) ++ "_untagged") = 0;
    }

    pub fn setPercentage(self: *BlockUsedSizes, comptime field: Flags.Field, value: f32) void {
        @field(self.flags, @tagName(field)) = .percentage;
        @field(self, @tagName(field) ++ "_untagged") = @bitCast(value);
    }

    pub fn GetReturnType(comptime field: Flags.Field) type {
        return switch (@FieldType(Flags, @tagName(field))) {
            IsAutoTag => ?math.Unit,
            IsAutoOrPercentageTag => IsAutoOrPercentage,
            else => comptime unreachable,
        };
    }

    pub fn get(self: BlockUsedSizes, comptime field: Flags.Field) GetReturnType(field) {
        const flag = @field(self.flags, @tagName(field));
        const value = @field(self, @tagName(field) ++ "_untagged");
        return switch (@FieldType(Flags, @tagName(field))) {
            IsAutoTag => switch (flag) {
                .value => value,
                .auto => null,
            },
            IsAutoOrPercentageTag => switch (flag) {
                .value => .{ .value = value },
                .auto => .auto,
                .percentage => .{ .percentage = @bitCast(value) },
            },
            else => comptime unreachable,
        };
    }

    pub fn isAuto(self: BlockUsedSizes, comptime field: Flags.Field) bool {
        return @field(self.flags, @tagName(field)) == .auto;
    }

    fn icb(size: math.Size) BlockUsedSizes {
        return .{
            .border_inline_start = 0,
            .border_inline_end = 0,
            .padding_inline_start = 0,
            .padding_inline_end = 0,
            .margin_inline_start_untagged = 0,
            .margin_inline_end_untagged = 0,
            .inline_size_untagged = size.w,
            .min_inline_size = size.w,
            .max_inline_size = size.w,

            .border_block_start = 0,
            .border_block_end = 0,
            .padding_block_start = 0,
            .padding_block_end = 0,
            .margin_block_start = 0,
            .margin_block_end = 0,
            .block_size_untagged = size.h,
            .min_block_size = size.h,
            .max_block_size = size.h,

            .inset_inline_start_untagged = 0,
            .inset_inline_end_untagged = 0,
            .inset_block_start_untagged = 0,
            .inset_block_end_untagged = 0,

            .flags = .{
                .inline_size = .value,
                .margin_inline_start = .value,
                .margin_inline_end = .value,
                .block_size = .value,
                .inset_inline_start = .value,
                .inset_inline_end = .value,
                .inset_block_start = .value,
                .inset_block_end = .value,
            },
        };
    }
};

/// Writes all of a block's data to the BoxTree.
fn setDataBlock(
    subtree: Subtree.View,
    index: Subtree.Size,
    used: BlockUsedSizes,
    skip: Subtree.Size,
    width: math.Unit,
    height: math.Unit,
    stacking_context: ?StackingContextTree.Id,
    node: NodeId,
    out_of_flow: bool,
    inner_block: BoxTree.BoxStyle.InnerBlock,
) void {
    subtree.items(.skip)[index] = skip;
    subtree.items(.type)[index] = .block;
    subtree.items(.stacking_context)[index] = stacking_context;
    subtree.items(.node)[index] = node;
    // Initialize insets to zero; cosmetic layout pass will set actual values for positioned elements
    subtree.items(.insets)[index] = .{ .x = 0, .y = 0 };
    subtree.items(.out_of_flow)[index] = out_of_flow;
    subtree.items(.float_side)[index] = .none;
    subtree.items(.clear_side)[index] = .none;
    subtree.items(.visibility)[index] = .visible;
    subtree.items(.flex_grow)[index] = 0.0;
    subtree.items(.flex_shrink)[index] = 1.0;
    subtree.items(.flex_basis_px)[index] = -1;
    subtree.items(.align_self)[index] = .auto;
    subtree.items(.list_style_type)[index] = .none;
    subtree.items(.inner_block)[index] = inner_block;
    subtree.items(.intrinsic)[index] = used.intrinsic;
    subtree.items(.percent_width)[index] = used.percent_width;
    subtree.items(.specified_margins)[index] = used.specified_margins;
    subtree.items(.block_margins)[index] = .{ used.margin_block_start, used.margin_block_end };
    subtree.items(.min_block_size)[index] = used.min_block_size;
    subtree.items(.max_block_size)[index] = used.max_block_size;
    subtree.items(.bfc_floats)[index] = false;
    // Default to false; popFlowBlock and other layout entry points
    // overwrite this when the block actually establishes a BFC.
    subtree.items(.is_bfc)[index] = false;
    subtree.items(.border_colors)[index] = .{};
    subtree.items(.border_radii)[index] = .{};
    subtree.items(.background)[index] = .{};
    subtree.items(.overflow)[index] = .visible;
    subtree.items(.opacity)[index] = 1.0;
    subtree.items(.creates_absolute_cb)[index] = false;

    const box_offsets = &subtree.items(.box_offsets)[index];
    const borders = &subtree.items(.borders)[index];
    const margins = &subtree.items(.margins)[index];

    // Horizontal sizes
    box_offsets.border_pos.x = used.get(.margin_inline_start).?;
    box_offsets.content_pos.x = used.border_inline_start + used.padding_inline_start;
    box_offsets.content_size.w = width;
    box_offsets.border_size.w = box_offsets.content_pos.x + box_offsets.content_size.w + used.padding_inline_end + used.border_inline_end;

    borders.left = used.border_inline_start;
    borders.right = used.border_inline_end;

    margins.left = used.get(.margin_inline_start).?;
    margins.right = used.get(.margin_inline_end).?;

    // Vertical sizes
    box_offsets.border_pos.y = used.margin_block_start;
    box_offsets.content_pos.y = used.border_block_start + used.padding_block_start;
    box_offsets.content_size.h = height;
    box_offsets.border_size.h = box_offsets.content_pos.y + box_offsets.content_size.h + used.padding_block_end + used.border_block_end;

    borders.top = used.border_block_start;
    borders.bottom = used.border_block_end;

    margins.top = used.margin_block_start;
    margins.bottom = used.margin_block_end;
}

fn writeBlockCosmetic(
    layout: *Layout,
    subtree: Subtree.View,
    index: Subtree.Size,
    node: NodeId,
    containing_block_width: math.Unit,
    containing_block_height: ?math.Unit,
    position: BoxTree.BoxStyle.Position,
) !void {
    const bgc = layout.computer.box_gen_stage.nodes[@intCast(node.value)];

    const color_specified = bgc.color orelse return;
    _, const used_color = solve.colorProperty(color_specified);

    if (bgc.border_colors) |bc| {
        subtree.items(.border_colors)[index] = solve.borderColors(bc, used_color);
    }
    if (bgc.border_radii) |br| {
        subtree.items(.border_radii)[index] = solve.borderRadii(br);
    }
    if (bgc.opacity) |op| {
        subtree.items(.opacity)[index] = solve.opacity(op);
    }

    subtree.items(.creates_absolute_cb)[index] = switch (position) {
        .static => false,
        .relative, .absolute, .fixed => true,
    };
    subtree.items(.overflow)[index] = if (bgc.box_style) |bs| blk: {
        const computed_bs, _ = solve.boxStyle(bs, .not_root, false);
        break :blk computed_bs.overflow;
    } else .visible;

    if (bgc.font) |font| {
        subtree.items(.visibility)[index] = font.visibility;

        const env = layout.inputs.env;
        if (env.nodeTagEql(node, "li")) {
            subtree.items(.list_style_type)[index] = font.list_style_type;
        }
    }

    // Resolve insets for positioned elements.
    const font_size_px: f32 = if (bgc.font) |f| f.font_size.px_val() else 16.0;
    const cb_size = math.Size{
        .w = containing_block_width,
        .h = containing_block_height orelse 0,
    };
    const used_insets = &subtree.items(.insets)[index];
    switch (position) {
        .static => {},
        .relative => {
            const insets_spec = bgc.insets orelse return;
            solveInsetsRelative(layout.inputs.env, insets_spec, cb_size, font_size_px, layout.computer.resolvedRootFontSizePx(.box_gen), used_insets);
        },
        .absolute => {
            const insets_spec = bgc.insets orelse return;
            solveInsetsAbsolute(layout.inputs.env, insets_spec, cb_size, font_size_px, layout.computer.resolvedRootFontSizePx(.box_gen), used_insets);
        },
        .fixed => {
            const insets_spec = bgc.insets orelse return;
            const icb_size = layout.viewport;
            solveInsetsAbsolute(layout.inputs.env, insets_spec, icb_size, font_size_px, layout.computer.resolvedRootFontSizePx(.box_gen), used_insets);
        },
    }

    // Resolve backgrounds (needs box_offsets which are now set by setDataBlock).
    if (bgc.background_color) |bg_color| {
        const bg_clip = bgc.background_clip orelse return;
        const bg = bgc.background orelse return;
        const box_offsets_ptr = &subtree.items(.box_offsets)[index];
        const borders_ptr = &subtree.items(.borders)[index];
        const background_ptr = &subtree.items(.background)[index];
        try resolveBlockBackgrounds(
            layout,
            box_offsets_ptr,
            borders_ptr,
            used_color,
            bg_color,
            bg_clip,
            bg,
            background_ptr,
        );
    }
}

fn solveInsetsRelative(
    env: *const zss.Environment,
    specified: zss.values.groups.Tag.SpecifiedValues(.insets),
    containing_block_size: math.Size,
    font_size_px: f32,
    root_font_size_px: f32,
    used: *BoxTree.Insets,
) void {
    const left: ?math.Unit = switch (specified.left) {
        .px => |v| solve.length(.px, v),
        .percentage => |v| solve.percentage(v, containing_block_size.w),
        .calc => |v| solve.calc(env, .{ .id = v.id, .font_size = font_size_px }, containing_block_size.w).?,
        .auto => null,
        .em => |v| solve.length(.px, v * font_size_px),
        .rem => |v| solve.length(.px, v * root_font_size_px),
    };
    const right: ?math.Unit = switch (specified.right) {
        .px => |v| -solve.length(.px, v),
        .percentage => |v| -solve.percentage(v, containing_block_size.w),
        .calc => |v| -solve.calc(env, .{ .id = v.id, .font_size = font_size_px }, containing_block_size.w).?,
        .auto => null,
        .em => |v| -solve.length(.px, v * font_size_px),
        .rem => |v| -solve.length(.px, v * root_font_size_px),
    };
    const top: ?math.Unit = switch (specified.top) {
        .px => |v| solve.length(.px, v),
        .percentage => |v| solve.percentage(v, containing_block_size.h),
        .calc => |v| solve.calc(env, .{ .id = v.id, .font_size = font_size_px }, containing_block_size.h).?,
        .auto => null,
        .em => |v| solve.length(.px, v * font_size_px),
        .rem => |v| solve.length(.px, v * root_font_size_px),
    };
    const bottom: ?math.Unit = switch (specified.bottom) {
        .px => |v| -solve.length(.px, v),
        .percentage => |v| -solve.percentage(v, containing_block_size.h),
        .calc => |v| -solve.calc(env, .{ .id = v.id, .font_size = font_size_px }, containing_block_size.h).?,
        .auto => null,
        .em => |v| -solve.length(.px, v * font_size_px),
        .rem => |v| -solve.length(.px, v * root_font_size_px),
    };
    used.* = .{
        .x = left orelse right orelse 0,
        .y = top orelse bottom orelse 0,
    };
}

fn solveInsetsAbsolute(
    env: *const zss.Environment,
    specified: zss.values.groups.Tag.SpecifiedValues(.insets),
    containing_block_size: math.Size,
    font_size_px: f32,
    root_font_size_px: f32,
    used: *BoxTree.Insets,
) void {
    var left: math.Unit = 0;
    var top: math.Unit = 0;
    switch (specified.left) {
        .px => |v| left = solve.length(.px, v),
        .percentage => |v| left = solve.percentage(v, containing_block_size.w),
        .calc => |v| left = solve.calc(env, .{ .id = v.id, .font_size = font_size_px }, containing_block_size.w).?,
        .auto => {},
        .em => |v| left = solve.length(.px, v * font_size_px),
        .rem => |v| left = solve.length(.px, v * root_font_size_px),
    }
    switch (specified.top) {
        .px => |v| top = solve.length(.px, v),
        .percentage => |v| top = solve.percentage(v, containing_block_size.h),
        .calc => |v| top = solve.calc(env, .{ .id = v.id, .font_size = font_size_px }, containing_block_size.h).?,
        .auto => {},
        .em => |v| top = solve.length(.px, v * font_size_px),
        .rem => |v| top = solve.length(.px, v * root_font_size_px),
    }
    used.* = .{ .x = left, .y = top };
}

pub fn resolveBlockBackgrounds(
    layout: *Layout,
    box_offsets: *const BoxTree.BoxOffsets,
    borders: *const BoxTree.Borders,
    current_color: math.Color,
    bg_color_spec: zss.values.groups.Tag.SpecifiedValues(.background_color),
    bg_clip_spec: zss.values.groups.Tag.SpecifiedValues(.background_clip),
    bg_spec: zss.values.groups.Tag.SpecifiedValues(.background),
    background_ptr: *BoxTree.BlockBoxBackground,
) !void {
    background_ptr.color = solve.color(bg_color_spec.color, current_color);
    background_ptr.gradient = switch (bg_color_spec.gradient) {
        .gradient => |g| BoxTree.LinearGradient{
            .from = math.Color.fromRgbaInt(g.from_rgba),
            .to = math.Color.fromRgbaInt(g.to_rgba),
        },
        else => null,
    };

    const images = bg_spec.image;
    const clips = bg_clip_spec.clip;
    background_ptr.color_clip = solve.backgroundClip(clips[(images.len - 1) % clips.len]);

    var num_images: usize = 0;
    for (images) |image| switch (image) {
        .none => {},
        .image, .url => num_images += 1,
    };
    if (num_images == 0) {
        background_ptr.images = .invalid;
        return;
    }

    const handle, const buffer = try layout.box_tree.allocBackgroundImages(@intCast(num_images));
    var buffer_index: usize = 0;
    for (images, 0..) |image, img_idx| {
        if (image == .none) continue;
        defer buffer_index += 1;

        const image_handle = switch (image) {
            .image => |ih| ih,
            .url => |url| layout.inputs.env.urls_to_images.get(url) orelse {
                buffer[buffer_index] = .{};
                continue;
            },
            .none => unreachable,
        };

        const dimensions = layout.inputs.images.dimensions(image_handle);
        buffer[buffer_index] = solve.backgroundImage(
            image_handle,
            dimensions,
            .{
                .origin = bg_spec.origin[img_idx % bg_spec.origin.len],
                .position = bg_spec.position[img_idx % bg_spec.position.len],
                .size = bg_spec.size[img_idx % bg_spec.size.len],
                .repeat = bg_spec.repeat[img_idx % bg_spec.repeat.len],
                .attachment = bg_spec.attachment[img_idx % bg_spec.attachment.len],
                .clip = clips[img_idx % clips.len],
            },
            box_offsets,
            borders,
        );
    }
    background_ptr.images = handle;
}

fn setDataIfcContainer(
    subtree: Subtree.View,
    ifc: Ifc.Id,
    index: Subtree.Size,
    skip: Subtree.Size,
    width: math.Unit,
    height: math.Unit,
) void {
    subtree.items(.skip)[index] = skip;
    subtree.items(.type)[index] = .{ .ifc_container = ifc };
    subtree.items(.stacking_context)[index] = null;
    subtree.items(.box_offsets)[index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .border_size = .{ .w = width, .h = height },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
    };
    subtree.items(.borders)[index] = .{};
    subtree.items(.margins)[index] = .{};
    subtree.items(.insets)[index] = .{ .x = 0, .y = 0 };
    subtree.items(.out_of_flow)[index] = false;
    subtree.items(.float_side)[index] = .none;
    subtree.items(.clear_side)[index] = .none;
    subtree.items(.visibility)[index] = .visible;
    subtree.items(.flex_grow)[index] = 0.0;
    subtree.items(.flex_shrink)[index] = 1.0;
    subtree.items(.flex_basis_px)[index] = -1;
    subtree.items(.align_self)[index] = .auto;
    subtree.items(.list_style_type)[index] = .none;
}

fn setDataSubtreeProxy(
    subtree: Subtree.View,
    index: Subtree.Size,
    proxied_subtree: *Subtree,
) void {
    const border_size = blk: {
        const view = proxied_subtree.view();
        var border_size = view.items(.box_offsets)[0].border_size;
        const margins = view.items(.margins)[0];
        border_size.w += margins.left + margins.right;
        border_size.h += margins.top + margins.bottom;
        break :blk border_size;
    };

    subtree.items(.skip)[index] = 1;
    subtree.items(.type)[index] = .{ .subtree_proxy = proxied_subtree.id };
    subtree.items(.stacking_context)[index] = null;
    subtree.items(.box_offsets)[index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .border_size = border_size,
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = border_size,
    };
    subtree.items(.borders)[index] = .{};
    subtree.items(.margins)[index] = .{};
    subtree.items(.insets)[index] = .{ .x = 0, .y = 0 };
    subtree.items(.out_of_flow)[index] = false;
    subtree.items(.float_side)[index] = .none;
    subtree.items(.clear_side)[index] = .none;
    subtree.items(.visibility)[index] = .visible;
    subtree.items(.flex_grow)[index] = 0.0;
    subtree.items(.flex_shrink)[index] = 1.0;
    subtree.items(.flex_basis_px)[index] = -1;
    subtree.items(.align_self)[index] = .auto;
    subtree.items(.list_style_type)[index] = .none;
}
