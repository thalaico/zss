//! Incremental layout: box generation takes over an element's boxes from
//! the previous layout of the same document instead of generating them
//! again, when nothing that determines them changed (the LayoutNG idea of
//! reusing a clean subtree's fragments).
//!
//! An element's boxes are a contiguous range of blocks in a subtree (the
//! element's block and its descendants', `skip` long), the inline
//! formatting contexts of its `ifc_container` blocks and the child subtrees
//! of its `subtree_proxy` blocks, recursively. Taking them over copies the
//! block range to the end of the current subtree and moves the inline
//! formatting contexts and child subtrees to the new tree, renumbering what
//! refers to them: block indices (an IFC's parent block and its inline-block
//! glyphs), IFC and subtree ids, background image handles and the
//! node-to-box map.
//!
//! The copy is what generating the element again would produce when:
//! - neither the element, nor a descendant, nor an ancestor's style changed
//!   (`Incremental.blocked`, from the host's change records);
//! - it is generated in normal flow against the same containing block as
//!   last time, and every ancestor is a plain flow block — no flex, grid or
//!   table container, float, inline-level or absolutely positioned box,
//!   whose algorithms resize or relayout their contents after generating
//!   them (`relayout.zig`, `intrinsic.zig`);
//! - no float is in its block formatting context, now or in the previous
//!   layout (`bfc.zig` lays such contexts out again);
//! - its range holds no stacking context, positioned box or float (their
//!   registries — `StackingContextTreeBuilder`, `AbsoluteContainingBlocks`
//!   — are per layout; taking those over is not supported yet).
//! A parent places its children after generating them
//! (`flow.offsetChildBlocks`, which only writes their offsets), so the
//! element's position follows its new siblings.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const Environment = zss.Environment;
const NodeId = Environment.NodeId;
const BoxTree = zss.BoxTree;
const BlockRef = BoxTree.BlockRef;
const GeneratedBox = BoxTree.GeneratedBox;
const Ifc = BoxTree.InlineFormattingContext;
const Subtree = BoxTree.Subtree;

const Layout = @import("../Layout.zig");
const BoxGen = Layout.BoxGen;

pub const Incremental = struct {
    /// The previous layout of the document. `Layout.run` consumes it: the
    /// parts it takes over move to the new tree, the rest is freed.
    previous: *BoxTree,
    /// By node value: the node's boxes or computed values may differ from
    /// the previous layout's (`markBlocked`). Values past the end count as
    /// blocked.
    blocked: []const bool,
    /// Elements whose only changes are to groups that do not affect layout
    /// (`cascade.classifyChange` `.paint`, and `repaintNeedsLayout` false):
    /// not blocked; their taken-over boxes get the new colors (`repaint`).
    repaint: []const Repaint = &.{},
};

pub const Repaint = struct {
    node: NodeId,
    /// `color` changed: it inherits, and `currentColor` reaches borders and
    /// backgrounds, so the element's descendants are repainted too.
    color: bool,
    border_colors: bool,
};

/// A paint-only change that still needs layout: a table's collapsing border
/// model resolves cell and table edge colors from the cells' border colors
/// (CSS 2.1 §17.6.2), so a border-color change on such a block, or a
/// `color` change (currentColor) over one, relays the table out.
pub fn repaintNeedsLayout(previous: *const BoxTree, node: NodeId, change: Repaint) bool {
    if (!change.color and !change.border_colors) return false;
    if (!previous.has_collapsed_borders) return false;
    const gen = previous.node_to_generated_box.get(node) orelse return false;
    const ref = switch (gen) {
        .block_ref => |r| r,
        // An inline box's descendants are not one block range.
        else => return change.color,
    };
    const view = previous.getSubtree(ref.subtree).view();
    if (view.items(.collapsed_borders)[ref.index]) return true;
    if (!change.color) return false;
    return rangeHasCollapsedBorders(previous, view, ref.index, view.items(.skip)[ref.index]);
}

fn rangeHasCollapsedBorders(previous: *const BoxTree, view: Subtree.View, index: Subtree.Size, skip: Subtree.Size) bool {
    const types = view.items(.type);
    const flags = view.items(.collapsed_borders);
    for (index..index + skip) |i| {
        if (flags[i]) return true;
        switch (types[i]) {
            .subtree_proxy => |id| {
                const child = previous.getSubtree(id);
                if (rangeHasCollapsedBorders(previous, child.view(), 0, child.size())) return true;
            },
            else => {},
        }
    }
    return false;
}

/// After box generation: give the paint-only changed elements whose boxes
/// were taken over (not generated again) their new colors — computed
/// values and the boxes' cosmetic fields, as box generation writes them.
pub fn repaint(layout: *Layout) !void {
    const inc = layout.incremental orelse return;
    if (!layout.reuse_state.active) return;
    const env = layout.inputs.env;
    for (inc.repaint) |r| {
        if (!r.color) {
            try repaintNode(layout, r.node);
            continue;
        }
        // Tree order: each element's parent entry is current first.
        var it = SubtreeIterator{ .env = env, .root = r.node, .next_node = r.node };
        while (it.next()) |n| try repaintNode(layout, n);
    }
}

fn repaintNode(layout: *Layout, node: NodeId) !void {
    const env = layout.inputs.env;
    if (env.getNodeProperty(.category, node) != .element) return;
    // Generated again in this layout: already current.
    if (layout.computer.visitedNode(.box_gen, node)) return;
    layout.computer.refreshPaintValues(.box_gen, node);
    const tree = layout.box_tree.ptr;
    const gen = tree.node_to_generated_box.get(node) orelse return;
    switch (gen) {
        .block_ref => |ref| try repaintBlock(layout, ref, node),
        .inline_box => |b| @import("inline.zig").writeInlineBoxCosmetic(layout, tree.getIfc(b.ifc_id), b.index, node),
        .text => {},
    }
}

/// The paint fields of an element's block (`BoxGen.writeBlockCosmetic`'s
/// colors and backgrounds) and the text color of the IFCs directly in it.
fn repaintBlock(layout: *Layout, ref: BlockRef, node: NodeId) !void {
    const tree = layout.box_tree.ptr;
    const view = tree.getSubtree(ref.subtree).view();
    if (view.items(.type)[ref.index] != .block) return;
    const entry = layout.computer.box_gen_stage.nodes[@intCast(node.value)];
    const color = entry.color orelse return;
    const solve = @import("solve.zig");
    _, const used_color = solve.colorProperty(color);
    if (!view.items(.collapsed_borders)[ref.index]) {
        if (entry.border_colors) |bc| view.items(.border_colors)[ref.index] = solve.borderColors(bc, used_color);
    }
    if (entry.background_color) |bg_color| {
        if (entry.background_clip) |bg_clip| if (entry.background) |bg| {
            try BoxGen.resolveBlockBackgrounds(
                layout,
                &view.items(.box_offsets)[ref.index],
                &view.items(.borders)[ref.index],
                used_color,
                bg_color,
                bg_clip,
                bg,
                &view.items(.background)[ref.index],
            );
        };
    }
    // The IFCs of its own content (anonymous blocks among its children).
    const types = view.items(.type);
    const skips = view.items(.skip);
    var child = ref.index + 1;
    const end = ref.index + skips[ref.index];
    while (child < end) : (child += skips[child]) {
        switch (types[child]) {
            .ifc_container => |id| tree.getIfc(id).font_color = used_color,
            else => {},
        }
    }
}


/// Per-layout bookkeeping of what was taken from the previous tree.
pub const State = struct {
    active: bool = false,
    /// By old id: moved to the new tree, with its new id.
    taken_ifcs: std.ArrayListUnmanaged(bool) = .empty,
    new_ifc: std.ArrayListUnmanaged(Ifc.Id) = .empty,
    taken_subtrees: std.ArrayListUnmanaged(bool) = .empty,
    new_subtree: std.ArrayListUnmanaged(Subtree.Id) = .empty,
    /// Elements taken over in this layout (statistics for the host).
    reused_elements: u32 = 0,
    reused_blocks: u32 = 0,
    /// The elements whose boxes were taken over, and their blocks in the
    /// new tree. Hosts that keep derived geometry can move it with them.
    ranges: std.ArrayListUnmanaged(Range) = .empty,
    /// By node value: 1 + the index in `ranges` of the range whose boxes
    /// the node's boxes are part of, or 0.
    node_range: std.ArrayListUnmanaged(u32) = .empty,
    /// By old IFC id: 1 + the index of the range it was taken with.
    ifc_range: std.ArrayListUnmanaged(u32) = .empty,

    pub const Range = struct { root: NodeId, block: BlockRef };

    pub fn deinit(state: *State, allocator: Allocator) void {
        state.ranges.deinit(allocator);
        state.node_range.deinit(allocator);
        state.ifc_range.deinit(allocator);
        state.taken_ifcs.deinit(allocator);
        state.new_ifc.deinit(allocator);
        state.taken_subtrees.deinit(allocator);
        state.new_subtree.deinit(allocator);
    }

    pub fn begin(state: *State, allocator: Allocator, previous: *const BoxTree, node_count: usize) !void {
        state.ranges.clearRetainingCapacity();
        try state.node_range.resize(allocator, node_count);
        @memset(state.node_range.items, 0);
        try state.ifc_range.resize(allocator, previous.ifcs.items.len);
        try state.taken_ifcs.resize(allocator, previous.ifcs.items.len);
        @memset(state.taken_ifcs.items, false);
        try state.new_ifc.resize(allocator, previous.ifcs.items.len);
        try state.taken_subtrees.resize(allocator, previous.subtrees.items.len);
        @memset(state.taken_subtrees.items, false);
        try state.new_subtree.resize(allocator, previous.subtrees.items.len);
        state.reused_elements = 0;
        state.reused_blocks = 0;
        state.active = true;
    }

    /// Free what the new tree did not take over of `previous`. Its root
    /// subtree's block storage (copied from, never taken over) goes to
    /// `new_tree` as spare storage for the next layout.
    pub fn releasePrevious(state: *State, previous: *BoxTree, new_tree: *BoxTree) void {
        if (previous.subtrees.items.len > 0 and !(state.active and state.taken_subtrees.items[0])) {
            const root = previous.subtrees.items[0];
            root.blocks.shrinkRetainingCapacity(0);
            new_tree.spare_blocks.deinit(new_tree.allocator);
            new_tree.spare_blocks = root.blocks;
            root.blocks = .{};
        }
        if (state.active) {
            previous.deinitExcept(state.taken_subtrees.items, state.taken_ifcs.items);
        } else {
            previous.deinit();
        }
        state.active = false;
    }
};

/// The nodes whose boxes or computed values may have changed since the
/// previous layout, for `Incremental.blocked`: `restyled` elements and
/// their descendants (computed values inherit), and the ancestors of those
/// and of the `changed` nodes (an element whose children or text changed,
/// a text node whose data changed). Returns a table indexed by node value.
pub fn markBlocked(env: *const Environment, allocator: Allocator, restyled: []const NodeId, changed: []const NodeId) ![]bool {
    const blocked = try allocator.alloc(bool, env.node_count);
    @memset(blocked, false);
    for (restyled) |root| {
        if (root.value >= blocked.len or blocked[root.value]) {
            markAncestors(env, blocked, root);
            continue;
        }
        var it = SubtreeIterator{ .env = env, .root = root, .next_node = root };
        while (it.next()) |n| {
            if (n.value < blocked.len) blocked[n.value] = true;
        }
        markAncestors(env, blocked, root);
    }
    for (changed) |node| {
        if (node.value < blocked.len) blocked[node.value] = true;
        markAncestors(env, blocked, node);
    }
    return blocked;
}

fn markAncestors(env: *const Environment, blocked: []bool, node: NodeId) void {
    var n = node.parent(env);
    while (n) |p| : (n = p.parent(env)) {
        if (p.value >= blocked.len) continue;
        if (blocked[p.value]) {
            // Its ancestors were marked with it — unless it was marked as
            // a descendant of a restyled element, whose own ancestors were
            // marked too.
            return;
        }
        blocked[p.value] = true;
    }
}

/// A node and its descendants in the box tree's view of the document
/// (::before and ::after included), in tree order.
const SubtreeIterator = struct {
    env: *const Environment,
    root: NodeId,
    next_node: ?NodeId,

    fn next(it: *SubtreeIterator) ?NodeId {
        const n = it.next_node orelse return null;
        it.next_node = it.successor(n);
        return n;
    }

    fn successor(it: *const SubtreeIterator, n: NodeId) ?NodeId {
        if (it.env.boxFirstChild(n)) |child| return child;
        var cur = n;
        while (!eqlNode(cur, it.root)) {
            if (it.env.boxNextSibling(cur)) |sibling| return sibling;
            cur = cur.parent(it.env) orelse return null;
        }
        return null;
    }
};

fn eqlNode(a: NodeId, b: NodeId) bool {
    return a.value == b.value and a.group == b.group;
}

/// Box generation is at `node`, an element in normal flow about to be
/// generated as a block: take over its boxes from the previous layout if
/// that gives the same result. Returns whether it did; the element's node
/// has then been passed.
pub fn tryReuse(box_gen: *BoxGen, node: NodeId, box_style: BoxTree.BoxStyle) !bool {
    const layout = box_gen.getLayout();
    const state = &layout.reuse_state;
    if (!state.active) return false;
    const inc = layout.incremental.?;
    if (node.value >= inc.blocked.len or inc.blocked[node.value]) return false;
    if (box_style.position != .static) return false;
    if (box_style.outer != .block) return false;
    if (layout.computer.box_gen_stage.current_index != node.value) return false;

    // Every enclosing formatting context is normal flow, and every ancestor
    // a plain flow block.
    {
        const modes = &box_gen.stacks.mode;
        if (modes.top != .flow) return false;
        for (modes.rest.items) |m| if (m != .flow) return false;
    }
    const infos = &box_gen.stacks.block_info;
    // [0] is the initial containing block.
    if (infos.rest.items.len == 0) return false;
    {
        var i: usize = 1;
        while (i <= infos.rest.items.len) : (i += 1) {
            const info = if (i == infos.rest.items.len) &infos.top.? else &infos.rest.items[i];
            if (info.table_role != .none or info.is_flex_container or info.is_grid_container or
                info.out_of_flow or info.float_side != .none or info.fit_content_available != null) return false;
        }
    }

    const previous = inc.previous;
    const ref = switch (previous.node_to_generated_box.get(node) orelse return false) {
        .block_ref => |r| r,
        else => return false,
    };
    const ref_subtree: usize = @intFromEnum(ref.subtree);
    if (state.taken_subtrees.items[ref_subtree]) return false;
    const old_view = previous.getSubtree(ref.subtree).view();
    if (old_view.items(.type)[ref.index] != .block) return false;
    const old_node = old_view.items(.node)[ref.index] orelse return false;
    if (!eqlNode(old_node, node)) return false;
    const cb = box_gen.containingBlockSize();
    const old_cb = old_view.items(.containing_block)[ref.index];
    if (old_cb[0] != cb.width or old_cb[1] != (cb.height orelse -1)) return false;

    // No floats in its block formatting context (that of the nearest BFC
    // root among its ancestors, as `BoxGen.markFloat` finds it).
    {
        var i: usize = infos.rest.items.len + 1;
        while (i > 1) {
            i -= 1;
            const info = if (i == infos.rest.items.len) &infos.top.? else &infos.rest.items[i];
            if (!(info.is_bfc or i <= 1)) continue;
            if (info.bfc_has_floats) return false;
            const root_ref = switch (previous.node_to_generated_box.get(info.node) orelse return false) {
                .block_ref => |r| r,
                else => return false,
            };
            if (state.taken_subtrees.items[@intFromEnum(root_ref.subtree)]) return false;
            if (previous.getSubtree(root_ref.subtree).view().items(.bfc_floats)[root_ref.index]) return false;
            break;
        }
    }

    const skip = old_view.items(.skip)[ref.index];
    const range_ifcs = selfContainedIfcCount(previous, old_view, ref.index, skip) orelse return false;

    const new_tree = layout.box_tree.ptr;
    const new_subtree = new_tree.getSubtree(box_gen.currentSubtree());
    const start = new_subtree.blocks.len;
    if (start + skip > std.math.maxInt(Subtree.Size)) return false;

    // Take it over.
    const allocator = new_tree.allocator;
    // Room for the range and, as a guess, the rest of the old subtree after
    // it (unchanged siblings that follow are taken over too): growing a
    // large subtree copies all of it.
    const following = old_view.len - ref.index;
    try new_subtree.blocks.ensureTotalCapacity(allocator, @min(start + following + following / 8, std.math.maxInt(Subtree.Size)));
    try new_subtree.blocks.resize(allocator, start + skip);
    const new_view = new_subtree.view();
    inline for (comptime std.enums.values(Subtree.List.Field)) |field| {
        @memcpy(new_view.items(field)[start..][0..skip], old_view.items(field)[ref.index..][0..skip]);
    }
    const delta: i32 = @as(i32, @intCast(start)) - @as(i32, ref.index);
    try state.ranges.append(layout.allocator, .{ .root = node, .block = .{ .subtree = new_subtree.id, .index = @intCast(start) } });
    // Reserved once, sparing the lists' growth copies.
    try new_tree.ifcs.ensureUnusedCapacity(allocator, range_ifcs);
    try box_gen.sct_builder.reserveIfcs(new_tree, range_ifcs);
    try takeBlocks(box_gen, previous, ref.subtree, new_subtree, @intCast(start), skip, delta);

    layout.computer.keepCurrentNode(.box_gen);
    box_gen.addSkip(skip);
    layout.advanceNode();
    state.reused_elements += 1;
    state.reused_blocks += skip;
    return true;
}

/// The number of IFCs in the blocks [index, index + skip) of `view` and
/// the subtrees their proxies reach, or null if they hold a stacking
/// context, positioned box or float.
fn selfContainedIfcCount(previous: *const BoxTree, view: Subtree.View, index: Subtree.Size, skip: Subtree.Size) ?usize {
    const types = view.items(.type);
    const contexts = view.items(.stacking_context);
    const cbs = view.items(.creates_absolute_cb);
    const out_of_flow = view.items(.out_of_flow);
    const floats = view.items(.float_side);
    var ifcs: usize = 0;
    for (index..index + skip) |i| {
        if (contexts[i] != null or cbs[i] or out_of_flow[i] or floats[i] != .none) return null;
        switch (types[i]) {
            .block => {},
            .ifc_container => ifcs += 1,
            .subtree_proxy => |id| {
                const child = previous.getSubtree(id);
                ifcs += selfContainedIfcCount(previous, child.view(), 0, child.size()) orelse return null;
            },
        }
    }
    return ifcs;
}

/// Renumber what the blocks [start, start + count) of `subtree` (copied
/// from the previous tree, `delta` places later) refer to, moving their
/// inline formatting contexts and child subtrees to the new tree.
fn takeBlocks(box_gen: *BoxGen, previous: *BoxTree, old_subtree: Subtree.Id, subtree: *Subtree, start: Subtree.Size, count: Subtree.Size, delta: i32) !void {
    const layout = box_gen.getLayout();
    const new_tree = layout.box_tree.ptr;
    const state = &layout.reuse_state;
    // Nothing below resizes `subtree`'s blocks.
    const view = subtree.view();
    const types = view.items(.type);
    const nodes = view.items(.node);
    const backgrounds = view.items(.background);
    if (std.mem.indexOfScalar(bool, view.items(.collapsed_borders)[start..][0..count], true) != null) {
        new_tree.has_collapsed_borders = true;
    }
    for (start..start + count) |i| {
        const here: BlockRef = .{ .subtree = subtree.id, .index = @intCast(i) };
        switch (types[i]) {
            .block => {},
            .ifc_container => |old_id| {
                const ifc = previous.getIfc(old_id);
                const new_id_int = std.math.cast(std.meta.Tag(Ifc.Id), new_tree.ifcs.items.len) orelse return error.SizeLimitExceeded;
                new_tree.ifcs.appendAssumeCapacity(ifc);
                state.taken_ifcs.items[@intFromEnum(old_id)] = true;
                state.new_ifc.items[@intFromEnum(old_id)] = @enumFromInt(new_id_int);
                state.ifc_range.items[@intFromEnum(old_id)] = @intCast(state.ranges.items.len);
                ifc.id = @enumFromInt(new_id_int);
                ifc.parent_block = here;
                if (delta != 0 and ifc.has_inline_blocks) shiftInlineBlocks(ifc, delta);
                try box_gen.sct_builder.addIfc(new_tree, ifc.id);
                types[i] = .{ .ifc_container = ifc.id };
            },
            .subtree_proxy => |old_id| {
                const child = previous.getSubtree(old_id);
                const new_id_int = std.math.cast(std.meta.Tag(Subtree.Id), new_tree.subtrees.items.len) orelse return error.SizeLimitExceeded;
                try new_tree.subtrees.append(new_tree.allocator, child);
                state.taken_subtrees.items[@intFromEnum(old_id)] = true;
                state.new_subtree.items[@intFromEnum(old_id)] = @enumFromInt(new_id_int);
                child.id = @enumFromInt(new_id_int);
                child.parent = here;
                types[i] = .{ .subtree_proxy = child.id };
                try takeBlocks(box_gen, previous, old_id, child, 0, child.size(), 0);
            },
        }
        // The background and node are active on ordinary blocks only.
        if (types[i] != .block) continue;
        if (nodes[i]) |n| {
            // The node's entry, if it names this block.
            const old_ref: BlockRef = .{ .subtree = old_subtree, .index = @intCast(@as(i32, @intCast(i)) - delta) };
            if (previous.node_to_generated_box.get(n)) |old| switch (old) {
                .block_ref => |r| if (std.meta.eql(r, old_ref)) {
                    try layout.box_tree.ptr.node_to_generated_box.putNoClobber(new_tree.allocator, n, .{ .block_ref = here });
                    if (n.value < state.node_range.items.len) state.node_range.items[n.value] = @intCast(state.ranges.items.len);
                },
                else => {},
            };
        }
        const background = &backgrounds[i];
        if (previous.background_images.get(background.images)) |images| {
            const handle, const copy = try layout.box_tree.allocBackgroundImages(@intCast(images.len));
            @memcpy(copy, images);
            background.images = handle;
        }
    }
}

/// An IFC's inline-block and out-of-flow glyphs name their block by index
/// in the IFC's parent subtree.
fn shiftInlineBlocks(ifc: *Ifc, delta: i32) void {
    const indices = ifc.glyphs.items(.index);
    var g: usize = 0;
    while (g < indices.len) {
        if (indices[g] != 0) {
            g += 1;
            continue;
        }
        var special = Ifc.Special.decode(indices[g + 1]);
        if (special.kind == .InlineBlock or special.kind == .OutOfFlowInline or special.kind == .OutOfFlowBlock) {
            special.data = @intCast(@as(i32, special.data) + delta);
            indices[g + 1] = @bitCast(special);
        }
        g += 2;
    }
}

/// After box generation: the node-to-box entries of the inline boxes and
/// text in the inline formatting contexts taken over, renumbered (block
/// entries are carried over as their blocks are copied, `takeBlocks`).
pub fn finish(layout: *Layout) void {
    const state = &layout.reuse_state;
    if (!state.active) return;
    const previous = layout.incremental.?.previous;
    const new_entries = layout.box_tree.ptr.node_to_generated_box.entries;
    const map = &layout.box_tree.ptr.node_to_generated_box;
    for (previous.node_to_generated_box.entries, 0..) |maybe_old, value| {
        const old = maybe_old orelse continue;
        const old_ifc: Ifc.Id = switch (old) {
            .block_ref => continue,
            .inline_box => |b| b.ifc_id,
            .text => |id| id,
        };
        const new: GeneratedBox = switch (old) {
            .block_ref => unreachable,
            .inline_box => |b| if (state.taken_ifcs.items[@intFromEnum(b.ifc_id)])
                .{ .inline_box = .{ .ifc_id = state.new_ifc.items[@intFromEnum(b.ifc_id)], .index = b.index } }
            else
                continue,
            .text => |id| if (state.taken_ifcs.items[@intFromEnum(id)])
                .{ .text = state.new_ifc.items[@intFromEnum(id)] }
            else
                continue,
        };
        // Taken-over content is never generated again in the same layout.
        if (value >= new_entries.len or new_entries[value] != null) continue;
        new_entries[value] = new;
        map.len += 1;
        if (value < state.node_range.items.len) state.node_range.items[value] = state.ifc_range.items[@intFromEnum(old_ifc)];
    }
}

test "an incremental layout takes over unchanged boxes and matches a fresh one" {
    const allocator = std.testing.allocator;
    const source_code = try zss.syntax.SourceCode.init(
        \\@name(root) * (display: block) {
        \\  @name(a) * (display: block; padding-top: 3px) {
        \\    * (display: block; height: 10px) {}
        \\    "some text"
        \\  }
        \\  @name(b) * (display: block; margin-top: 5px) {
        \\    "more text" * (display: inline; padding-left: 2px) { "inline" }
        \\  }
        \\}
    );
    var document = try zss.zml.parseAndCreateDocument(allocator, source_code);
    defer document.deinit(allocator);
    const cascade_list: zss.cascade.List = .{ .author = &.{&.{ .leaf = &document.cascade_source }} };
    try zss.cascade.run(&cascade_list, &document.env, allocator);

    var images = zss.Images.init();
    defer images.deinit(allocator);
    var fonts = zss.Fonts.init();
    defer fonts.deinit();

    const named = struct {
        fn get(doc: *const zss.zml.Document, name: []const u8) NodeId {
            return doc.named_nodes.get(name).?.toZssNode(doc);
        }
    };
    const root = named.get(&document, "root");
    const a = named.get(&document, "a");

    for ([_]?NodeId{ null, a }) |restyled| {
        var fresh_layout = Layout.init(&document.env, allocator, 800, 600, &images, &fonts);
        defer fresh_layout.deinit();
        var fresh = try fresh_layout.run(allocator);
        defer fresh.deinit();

        var first_layout = Layout.init(&document.env, allocator, 800, 600, &images, &fonts);
        defer first_layout.deinit();
        var previous = try first_layout.run(allocator);

        const restyled_list: []const NodeId = if (restyled) |r| &.{r} else &.{};
        const blocked = try markBlocked(&document.env, allocator, restyled_list, &.{});
        defer allocator.free(blocked);
        try std.testing.expect(blocked[root.value] == (restyled != null));

        var layout = Layout.init(&document.env, allocator, 800, 600, &images, &fonts);
        defer layout.deinit();
        layout.incremental = .{ .previous = &previous, .blocked = blocked };
        var incremental = try layout.run(allocator);
        defer incremental.deinit();

        // With nothing changed, the root element's children are taken over;
        // with `a` restyled, `b` still is.
        try std.testing.expect(layout.reuse_state.reused_elements >= 1);

        try std.testing.expectEqual(fresh.subtrees.items.len, incremental.subtrees.items.len);
        try std.testing.expectEqual(fresh.ifcs.items.len, incremental.ifcs.items.len);
        for (fresh.subtrees.items, incremental.subtrees.items) |f, i| {
            const fv = f.view();
            const iv = i.view();
            try std.testing.expectEqual(fv.len, iv.len);
            for (0..fv.len) |k| {
                try std.testing.expectEqual(fv.items(.skip)[k], iv.items(.skip)[k]);
                try std.testing.expectEqual(fv.items(.offset)[k], iv.items(.offset)[k]);
                try std.testing.expectEqual(fv.items(.box_offsets)[k], iv.items(.box_offsets)[k]);
                try std.testing.expectEqual(std.meta.activeTag(fv.items(.type)[k]), std.meta.activeTag(iv.items(.type)[k]));
            }
        }
        for (fresh.ifcs.items, incremental.ifcs.items) |f, i| {
            try std.testing.expectEqual(f.line_boxes.items.len, i.line_boxes.items.len);
            try std.testing.expectEqual(f.glyphs.len, i.glyphs.len);
            try std.testing.expectEqual(f.parent_block, i.parent_block);
        }
        try std.testing.expectEqual(fresh.node_to_generated_box.count(), incremental.node_to_generated_box.count());
        for (fresh.node_to_generated_box.entries, 0..) |entry, value| {
            const node: NodeId = .{ .group = root.group, .value = value };
            try std.testing.expect(std.meta.eql(entry, incremental.node_to_generated_box.get(node)));
        }
        const fresh_a = fresh.computed_styles.get(a) orelse return error.TestFailure;
        const inc_a = incremental.computed_styles.get(a) orelse return error.TestFailure;
        try std.testing.expectEqual(fresh_a.vertical_edges.?.padding_top.px, inc_a.vertical_edges.?.padding_top.px);
    }
}
