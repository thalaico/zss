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
const initial = @import("initial.zig");
const @"inline" = @import("inline.zig");
const solve = @import("solve.zig");
const stf = @import("shrink_to_fit.zig");
const table = @import("table.zig");
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

const Stacks = struct {
    mode: zss.Stack(Mode) = .{},
    subtree: zss.Stack(struct {
        id: Subtree.Id,
        depth: Subtree.Size,
    }) = .{},
    block: zss.Stack(Block) = .{},
    block_info: zss.Stack(BlockInfo) = .{},

    containing_block_size: zss.Stack(ContainingBlockSize) = .{},
};

const Mode = enum {
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
}

pub fn run(box_gen: *BoxGen) !void {
    const allocator = box_gen.getLayout().allocator;
    box_gen.table_context = table.Context.init(allocator);
    try analyzeAllNodes(box_gen);
    
    // Layout absolutely positioned elements after normal flow
    try layoutAbsoluteBlocks(box_gen);
    
    box_gen.sct_builder.endFrame();
}

fn analyzeAllNodes(box_gen: *BoxGen) !void {
    {
        try initial.beginMode(box_gen);
        const root_node, const root_box_style = (try analyzeNode(box_gen.getLayout(), .root)) orelse {
            try box_gen.dispatchNullNode(.root, {});
            return;
        };
        try box_gen.dispatch(.root, {}, root_node, root_box_style);
    }

    while (box_gen.stacks.mode.top) |mode| {
        const node, const box_style = (try analyzeNode(box_gen.getLayout(), .not_root)) orelse {
            try box_gen.dispatchNullNode(.not_root, mode);
            continue;
        };
        try box_gen.dispatch(.not_root, mode, node, box_style);
    }

    try box_gen.dispatchNullNode(.root, {});
}

fn layoutAbsoluteBlocks(box_gen: *BoxGen) !void {
    // Layout absolutely positioned elements that were collected during analyzeAllNodes
    const absolute_blocks = box_gen.absolute.blocks.items;
    
    if (absolute_blocks.len == 0) return;
    
    
    const layout = box_gen.getLayout();
    
    for (absolute_blocks) |block| {
        // Find the containing block for this absolute element
        const containing_block_ref = findContainingBlockRef(&box_gen.absolute, block.containing_block) orelse {
            std.log.warn("[layoutAbsoluteBlocks] Could not find containing block for node", .{});
            continue;
        };
        
        
        // Get containing block size
        const containing_subtree = layout.box_tree.ptr.getSubtree(containing_block_ref.subtree);
        const containing_slice = containing_subtree.blocks.slice();
        const containing_box_offsets = containing_slice.items(.box_offsets)[containing_block_ref.index];
        const containing_block_size = containing_box_offsets.border_size;
        
        
        // Get element's computed styles and compute sizes
        try layout.computer.setCurrentNode(.box_gen, block.node);
        
        // Compute sizes using the same function as normal flow
        const containing_block_width = containing_block_size.w;
        const containing_block_height = containing_block_size.h;
        const sizes = flow.solveAllSizes(
            &layout.computer,
            .absolute,
            .{ .normal = containing_block_width },
            containing_block_height,
        );
        
        // Get the computed width and height (these return optionals)
        const width = sizes.get(.inline_size) orelse containing_block_width;
        const height = sizes.get(.block_size) orelse containing_block_height;
        
        // Position (left/top) is resolved by the cosmetic pass into insets.
        // We don't compute it here to avoid double-counting.
        // Create block box at the computed position and size
        // We can't use newBlock() because it requires stacks to be set up
        // Instead, manually create the block in the containing block's subtree (reuse from earlier)
        const index = try layout.box_tree.appendBlockBox(containing_subtree);
        const ref = BlockRef{ .subtree = containing_block_ref.subtree, .index = index };
        
        // Re-get the slice since appendBlockBox might have reallocated
        const blocks = containing_subtree.blocks.slice();
        
        // Offset is zero: the cosmetic pass writes CSS left/top into insets,
        // and the renderer sums offset + insets. Setting both would double-count.
        blocks.items(.offset)[index] = .{ .x = 0, .y = 0 };
        
        // Set the size
        blocks.items(.box_offsets)[index] = .{
            .border_pos = .{ .x = 0, .y = 0 },
            .border_size = .{ .w = width, .h = height },
            .content_pos = .{
                .x = sizes.border_inline_start + sizes.padding_inline_start,
                .y = sizes.border_block_start + sizes.padding_block_start,
            },
            .content_size = .{
                .w = width - sizes.border_inline_start - sizes.border_inline_end - sizes.padding_inline_start - sizes.padding_inline_end,
                .h = height - sizes.border_block_start - sizes.border_block_end - sizes.padding_block_start - sizes.padding_block_end,
            },
        };
        
        // Set borders and margins
        blocks.items(.borders)[index] = .{
            .left = sizes.border_inline_start,
            .right = sizes.border_inline_end,
            .top = sizes.border_block_start,
            .bottom = sizes.border_block_end,
        };
        
        blocks.items(.margins)[index] = .{
            .left = sizes.margin_inline_start_untagged,
            .right = sizes.margin_inline_end_untagged,
            .top = sizes.margin_block_start,
            .bottom = sizes.margin_block_end,
        };
        
        // Initialize all required fields
        blocks.items(.skip)[index] = 1; // Absolute blocks are leaf nodes
        blocks.items(.type)[index] = .block; // Regular block type
        blocks.items(.out_of_flow)[index] = true;
        blocks.items(.node)[index] = block.node;
        blocks.items(.stacking_context)[index] = null; // TODO: May need stacking context
        blocks.items(.insets)[index] = .{ .x = 0, .y = 0 }; // No relative positioning
        blocks.items(.border_colors)[index] = .{ .top = .transparent, .bottom = .transparent, .left = .transparent, .right = .transparent };
        blocks.items(.background)[index] = .{ .color = .transparent, .color_clip = .border, .images = .invalid, .gradient = null };
        blocks.items(.overflow)[index] = .visible;
        blocks.items(.opacity)[index] = 1.0;
        blocks.items(.float_side)[index] = .none;
        blocks.items(.clear_side)[index] = .none;
        blocks.items(.visibility)[index] = .visible;
        blocks.items(.flex_grow)[index] = 0.0;
        
        // Register the generated box for this node
        try layout.box_tree.setGeneratedBox(block.node, .{ .block_ref = ref });
        
        // Absolute blocks are appended at the end of the blocks array,
        // outside the skip-based tree. They are not part of the normal
        // child traversal. The cosmetic pass finds them via node_to_generated_box
        // (DOM node traversal), so they DO get backgrounds/borders/insets.
    }
}

fn findContainingBlockRef(absolute: *const Absolute, id: Absolute.ContainingBlock.Id) ?BlockRef {
    const slice = absolute.containing_blocks.slice();
    const ids = slice.items(.id);
    const refs = slice.items(.ref);
    
    for (ids, refs, 0..) |containing_id, ref, i| {
        _ = i;
        if (containing_id == id) {
            return ref;
        }
    }
    
    return null;
}

/// Returns the next node and its box style, or `null` if there is no next node.
fn analyzeNode(layout: *Layout, comptime is_root: IsRoot) !?struct { NodeId, BoxTree.BoxStyle } {
    const node = layout.currentNode() orelse return null;
    try layout.computer.setCurrentNode(.box_gen, node);

    switch (layout.inputs.env.getNodeProperty(.category, node)) {
        .text => {
            return .{ node, .text };
        },
        .element => {
            const specified_box_style = layout.computer.getSpecifiedValue(.box_gen, .box_style);
            const computed_box_style, const used_box_style = solve.boxStyle(specified_box_style, is_root);
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
        .none => box_gen.getLayout().advanceNode(),
        .block => try box_gen.dispatchBlockElement(is_root, current_mode, node, box_style),
        .@"inline" => try box_gen.dispatchInlineElement(is_root, current_mode, node, box_style),
        .absolute => {
            // Add to absolute positioning list for out-of-flow layout
            const inner_box_style = box_style.outer.absolute;
            const allocator = box_gen.getLayout().allocator;
            try box_gen.absolute.addBlock(allocator, node, inner_box_style);
            // Advance to next node without laying out in normal flow
            box_gen.getLayout().advanceNode();
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
    // Check if this is a table element by checking tag name
    const env = box_gen.getLayout().inputs.env;
    if (env.getNodeProperty(.category, node) == .element) {
        const type_info = env.getNodeProperty(.type, node);
        var type_iter = env.type_names.iterator(@intFromEnum(type_info.name));
        
        // Route table elements to table layout mode
        if (type_iter.eql("table")) {
            return try table.tableElement(box_gen, node, box_style.position);
        } else if (type_iter.eql("tr")) {
            return try table.rowElement(box_gen, node, box_style.position);
        }
    }
    
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
            .flow => try flow.blockElement(box_gen, node, inner_box_style, box_style.position),
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
    // Check if this is a table-cell element
    const env = box_gen.getLayout().inputs.env;
    if (env.getNodeProperty(.category, node) == .element) {
        const type_info = env.getNodeProperty(.type, node);
        var type_iter = env.type_names.iterator(@intFromEnum(type_info.name));
        
        if (type_iter.eql("td") or type_iter.eql("th")) {
            return try table.cellElement(box_gen, node);
        }
    }
    
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
                // Only pop block_type_stack if the top entry's depth matches
                // the current bfc_stack depth — this means the block being
                // closed IS the table element that pushed the entry.
                const stack = &box_gen.table_context.block_type_stack;
                if (stack.items.len > 0) {
                    const top = stack.items[stack.items.len - 1];
                    if (box_gen.bfc_stack.top != null and top.bfc_depth == box_gen.bfc_stack.top.?) {
                        _ = stack.pop();
                        if (top.block_type == .table) {
                            box_gen.table_context.popTable();
                        }
                    }
                }
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
    const subtree = try box_gen.getLayout().box_tree.newSubtree();
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
    is_table_row: bool = false,
    is_flex_container: bool = false,
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
    vertical_align: zss.values.types.VerticalAlign = .baseline,
    /// flex-grow factor for this block (used when parent is a flex container)
    flex_grow: f32 = 0.0,

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

fn addSkip(box_gen: *BoxGen, skip: Subtree.Size) void {
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
    _ = flow.offsetChildBlocks(subtree, index, block.skip, block_info.sizes.get(.inline_size).?, parent_edge);
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

    // If the parent is a grid container, record this child's grid-area hash
    if (box_gen.stacks.block_info.top) |*parent_info| {
        if (parent_info.is_grid_container and block_info.grid_area_hash != 0) {
            if (parent_info.grid_child_count < parent_info.grid_child_area_hashes.len) {
                parent_info.grid_child_area_hashes[parent_info.grid_child_count] = block_info.grid_area_hash;
            }
        }
        if (parent_info.is_grid_container) {
            parent_info.grid_child_count +|= 1;
        }
    }

    const subtree = layout.box_tree.ptr.getSubtree(box_gen.currentSubtree()).view();
    const auto_height = if (block_info.is_flex_container) blk: {
        const container_width = block_info.sizes.get(.inline_size).?;
        const container_height = block_info.sizes.get(.block_size);
        break :blk flow.offsetChildBlocksFlex(layout.box_tree.ptr, subtree, block.index, block.skip, container_width, container_height, block_info.flex_justify, block_info.flex_align, block_info.flex_gap, block_info.flex_is_column, block_info.flex_wrap);
    } else if (block_info.is_grid_container) blk: {
        const container_width = block_info.sizes.get(.inline_size).?;
        const container_height = block_info.sizes.get(.block_size);
        break :blk grid.layoutGridChildren(subtree, block.index, block.skip, container_width, container_height, block_info.grid_column_gap, block_info.grid_row_gap, block_info.grid_columns, block_info.grid_rows, block_info.grid_areas, &block_info.grid_child_area_hashes, block_info.grid_child_count);
    } else if (block_info.is_table_row)
        flow.offsetChildBlocksHorizontal(subtree, block.index, block.skip)
    else blk: {
        const container_width = switch (auto_width) {
            .normal => block_info.sizes.get(.inline_size).?,
            .stf => |aw| aw,
        };
        var parent_edge = block_info.sizes.border_block_start + block_info.sizes.padding_block_start;
        // BFC roots prevent parent-child margin escape (CSS 2.1 §8.3.1)
        if (block_info.is_bfc and parent_edge == 0) parent_edge = 1;
        const result = flow.offsetChildBlocks(subtree, block.index, block.skip, container_width, parent_edge);
        // Parent-child margin collapsing: adjust parent's margin to absorb
        // the first child's escaped margin (CSS 2.1 Section 8.3.1).
        if (!block_info.is_bfc) {
            if (result.escaped_margin_top > block_info.sizes.margin_block_start) {
                block_info.sizes.margin_block_start = result.escaped_margin_top;
            }
        }
        break :blk result.auto_height;
    };
    const width = switch (auto_width) {
        .normal => block_info.sizes.get(.inline_size).?,
        .stf => |aw| flow.solveUsedWidth(aw, block_info.sizes.min_inline_size, block_info.sizes.max_inline_size),
    };
    const height = flow.solveUsedHeight(block_info.sizes, auto_height);
    // Table cell vertical-align: shift content origin down to center/bottom.
    // Adjusts padding so content_pos.y moves down without changing border_size.
    // This affects both inline text (line boxes) and block children uniformly.
    if (block_info.vertical_align != .baseline and height > auto_height) {
        const shift: math.Unit = switch (block_info.vertical_align) {
            .middle => @divFloor(height - auto_height, 2),
            .bottom => height - auto_height,
            else => 0,
        };
        if (shift > 0) {
            block_info.sizes.padding_block_start += shift;
            // Keep border_size unchanged: compensate by reducing bottom padding.
            block_info.sizes.padding_block_end = @max(0, block_info.sizes.padding_block_end - shift);
        }
    }
    setDataBlock(subtree, block.index, block_info.sizes, block.skip, width, height, block_info.stacking_context_id, block_info.node, block_info.out_of_flow);
    subtree.items(.float_side)[block.index] = block_info.float_side;
    subtree.items(.clear_side)[block.index] = block_info.clear_side;
    subtree.items(.visibility)[block.index] = .visible;
    subtree.items(.flex_grow)[block.index] = block_info.flex_grow;
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
    const auto_height = flow.offsetChildBlocks(subtree, block.index, block.skip, container_width, parent_edge).auto_height;
    const width = flow.solveUsedWidth(auto_width, sizes.min_inline_size, sizes.max_inline_size); // TODO This is probably redundant
    const height = flow.solveUsedHeight(sizes, auto_height);
    setDataBlock(subtree, block.index, sizes, block.skip, width, height, stacking_context_id, node, false);

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

pub fn addAbsoluteBlock(box_gen: *BoxGen, node: NodeId, inner_box_style: BoxTree.BoxStyle.InnerBlock) !void {
    return box_gen.absolute.addBlock(box_gen.getLayout().allocator, node, inner_box_style);
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
}
