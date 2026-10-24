const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../zss.zig");
const CascadeStorage = zss.cascade.Database.Storage;
const Environment = zss.Environment;
const NodeId = Environment.NodeId;
const Stack = zss.Stack;
const selectors = zss.selectors;

const groups = zss.values.groups;
const SpecifiedValues = groups.Tag.SpecifiedValues;
const ComputedValues = groups.Tag.ComputedValues;

const solve = @import("./solve.zig");

const StyleComputer = @This();

pub const Stage = enum {
    box_gen,

    fn ComputedValues(comptime stage: Stage) type {
        return switch (stage) {
            .box_gen => BoxGenComputedValues,
        };
    }
};

/// The computed values (CSS-CASCADE-4§4.4) of every property group for one
/// element, as filled in during box generation. A group is `null` when the
/// layout pass did not compute it for this element.
pub const NodeComputedValues = BoxGenComputedValues;

/// The per-element computed values retained after layout, indexed by
/// `NodeId.value`. Owned by the `BoxTree` that layout produced; freed by
/// `BoxTree.deinit`. Slices inside the values (multi-value groups such as
/// `background`) point into the `Environment`'s cascade storage, so the
/// table is only valid while that `Environment` is alive. It may be longer
/// than the document's node count (empty entries; `adoptTable`).
pub const ComputedStyles = struct {
    nodes: []NodeComputedValues = &.{},

    pub const empty: ComputedStyles = .{};

    pub fn deinit(cs: *ComputedStyles, allocator: Allocator) void {
        allocator.free(cs.nodes);
        cs.nodes = &.{};
    }

    /// The computed values for `node`, or `null` if layout never computed
    /// styles for it. Every element that box generation visits is covered —
    /// including `display: none` elements themselves — but the descendants of
    /// a `display: none` element are not visited and so have no entry. Text
    /// nodes have no entry (computed values belong to elements).
    pub fn get(cs: *const ComputedStyles, node: NodeId) ?*const NodeComputedValues {
        const index = node.value;
        if (index >= cs.nodes.len) return null;
        const values = &cs.nodes[index];
        if (values.box_style == null) return null;
        return values;
    }
};

const BoxGenComputedValues = struct {
    box_style: ?ComputedValues(.box_style) = null,
    content_width: ?ComputedValues(.content_width) = null,
    horizontal_edges: ?ComputedValues(.horizontal_edges) = null,
    content_height: ?ComputedValues(.content_height) = null,
    vertical_edges: ?ComputedValues(.vertical_edges) = null,
    border_styles: ?ComputedValues(.border_styles) = null,
    insets: ?ComputedValues(.insets) = null,
    z_index: ?ComputedValues(.z_index) = null,
    font: ?ComputedValues(.font) = null,
    grid_template: ?ComputedValues(.grid_template) = null,
    generated_content: ?ComputedValues(.generated_content) = null,
    // Cosmetic groups (merged from CosmeticComputedValues to avoid second pass)
    border_colors: ?ComputedValues(.border_colors) = null,
    border_radii: ?ComputedValues(.border_radii) = null,
    background_color: ?ComputedValues(.background_color) = null,
    background_clip: ?ComputedValues(.background_clip) = null,
    background: ?ComputedValues(.background) = null,
    color: ?ComputedValues(.color) = null,
    opacity: ?ComputedValues(.opacity) = null,
};

const Current = struct {
    node: NodeId,
    cascaded_values: *const CascadeStorage,
};

env: *const Environment,
current: Current,
allocator: Allocator,
active_stage: Stage = undefined,
box_gen_stage: StageData(.box_gen) = .{},

fn StageData(comptime stage: Stage) type {
    return struct {
        nodes: []stage.ComputedValues() = &.{},
        current_computed: stage.ComputedValues() = undefined,
        current_index: u32 = 0,
        /// The nodes this layout has visited: their entries were reset on
        /// the first visit (`setCurrentNode`).
        visited: std.DynamicBitSetUnmanaged = .{},
        /// The entry the current node had before its first visit reset it
        /// (`keepCurrentNode` puts it back).
        saved: stage.ComputedValues() = undefined,
        /// A retained table (`adoptTable`): entries not reset are still
        /// valid, and `completeTable` leaves the unvisited ones alone.
        /// Indexed by node value; values past its end count as blocked.
        blocked: ?[]const bool = null,
    };
}

pub fn init(env: *const Environment, allocator: Allocator) StyleComputer {
    return .{
        .env = env,
        .allocator = allocator,
        .current = undefined,
    };
}

pub fn deinit(self: *StyleComputer) void {
    self.box_gen_stage.visited.deinit(self.allocator);
}

fn stagePtr(sc: *StyleComputer, comptime stage: Stage) *StageData(stage) {
    return switch (stage) {
        .box_gen => &sc.box_gen_stage,
    };
}

/// Read-only view of a stage's data. A pointer, not a copy: StageData
/// carries `current_computed` (every computed-value group, ~1 KB), and the
/// by-value version was copied on every inherited-value lookup — 10% of a
/// 3000-row table's layout time.
fn stageConst(sc: *const StyleComputer, comptime stage: Stage) *const StageData(stage) {
    return switch (stage) {
        .box_gen => &sc.box_gen_stage,
    };
}

/// Allocate the per-node table for `stage` with `allocator` — the allocator
/// that will own the table once `takeStage` hands it to the `BoxTree`.
pub fn ensureCapacity(sc: *StyleComputer, comptime stage: Stage, allocator: Allocator, count: u32) !void {
    const s = sc.stagePtr(stage);
    // Raw allocation: `Allocator.alloc` fills new memory with 0xAA in safe
    // builds, and the table (~880 B per node, 13 MB for a 15k-node page)
    // is overwritten with `.{}` on the next line anyway.
    // The table is a quarter longer than the document (empty entries), so
    // the incremental layouts after DOM insertions grow into it rather than
    // copying it (`adoptTable`).
    const T = stage.ComputedValues();
    const len = count + count / 4;
    const bytes = allocator.rawAlloc(@sizeOf(T) * len, .of(T), @returnAddress()) orelse return error.OutOfMemory;
    s.nodes = @as([*]T, @ptrCast(@alignCast(bytes)))[0..len];
    @memset(s.nodes, .{});
    try s.visited.resize(sc.allocator, count, false);
    s.visited.unsetAll();
    s.blocked = null;
}

/// Start the stage from the table a previous layout of the same document
/// left (`ComputedStyles`), grown to `count` nodes. The entries of the
/// `blocked` nodes — those whose computed values may have changed — are
/// reset; the others are kept as they are for the nodes layout does not
/// visit again (`Layout/reuse.zig`). Takes ownership of `previous`, which
/// must have been allocated with `allocator`.
pub fn adoptTable(sc: *StyleComputer, comptime stage: Stage, allocator: Allocator, previous: *ComputedStyles, count: u32, blocked: []const bool) !void {
    comptime assert(stage == .box_gen);
    const s = sc.stagePtr(stage);
    var nodes = previous.nodes;
    previous.nodes = &.{};
    // The table may be longer than the document (entries past the node
    // count are empty); it grows by a quarter at a time, as mutations add
    // nodes a few at a time and each growth copies it (~1 KB per node).
    if (nodes.len < count) {
        const old_len = nodes.len;
        const new_len = @max(count, old_len + old_len / 4);
        nodes = allocator.realloc(nodes, new_len) catch |err| {
            allocator.free(nodes);
            return err;
        };
        @memset(nodes[old_len..], .{});
    }
    s.nodes = nodes;
    for (nodes[0..count], 0..) |*entry, value| {
        if (value >= blocked.len or blocked[value]) entry.* = .{};
    }
    try s.visited.resize(sc.allocator, count, false);
    s.visited.unsetAll();
    s.blocked = blocked;
}

/// Recompute the groups that do not affect layout (`color`, backgrounds,
/// border colors) of an element whose table entry is otherwise current —
/// one whose boxes a layout took over while only those changed
/// (`Layout/reuse.zig` repaint). Its parent's entry must be current.
pub fn refreshPaintValues(sc: *StyleComputer, comptime stage: Stage, node: NodeId) void {
    const s = sc.stagePtr(stage);
    const index: usize = @intCast(node.value);
    if (index >= s.nodes.len) return;
    if (sc.env.getNodeProperty(.category, node) != .element) return;
    const entry = &s.nodes[index];
    if (entry.box_style == null) return;
    const cascaded: *const CascadeStorage = sc.env.cascade_db.getStorage(node) orelse &.{};
    entry.color = sc.getSpecifiedValueForElement(stage, .color, node, cascaded);
    entry.border_colors = sc.getSpecifiedValueForElement(stage, .border_colors, node, cascaded);
    entry.background_color = sc.getSpecifiedValueForElement(stage, .background_color, node, cascaded);
    entry.background_clip = sc.getSpecifiedValueForElement(stage, .background_clip, node, cascaded);
    entry.background = sc.getSpecifiedValueForElement(stage, .background, node, cascaded);
}

/// Whether this layout visited `node` (generated its boxes, or computed its
/// values) rather than keeping its previous entry.
pub fn visitedNode(sc: *const StyleComputer, comptime stage: Stage, node: NodeId) bool {
    const s = sc.stageConst(stage);
    return node.value < s.visited.bit_length and s.visited.isSet(node.value);
}

/// The current node's boxes were taken over from the previous layout
/// (`Layout/reuse.zig`): restore its entry from before this layout's visit,
/// and treat it as not visited (its table entry is complete).
pub fn keepCurrentNode(sc: *StyleComputer, comptime stage: Stage) void {
    const s = sc.stagePtr(stage);
    s.nodes[s.current_index] = s.saved;
    s.visited.unset(s.current_index);
}

pub fn deinitStage(sc: *StyleComputer, comptime stage: Stage, allocator: Allocator) void {
    allocator.free(sc.stagePtr(stage).nodes);
    sc.stagePtr(stage).nodes = &.{};
}

/// Move the box-generation stage's per-node table out of the computer so it
/// outlives layout. The caller (`Layout.run`) stores it on the `BoxTree`.
pub fn takeStage(sc: *StyleComputer, comptime stage: Stage) ComputedStyles {
    comptime assert(stage == .box_gen);
    const s = sc.stagePtr(stage);
    const nodes = s.nodes;
    s.nodes = &.{};
    return .{ .nodes = nodes };
}

/// Stage whichever of the inherited/cosmetic groups of the current element
/// (font with its font-size resolved to px, color, borders, background,
/// opacity) are not staged yet, without committing. Mirrors what the
/// flow/inline paths stage before they commit a box, for elements that
/// generate no box but still have computed values. Groups a layout path
/// already staged are left alone — absolute leaf blocks, for instance, commit
/// their cosmetic groups without ever committing `box_style`.
pub fn stageCosmeticValues(sc: *StyleComputer, comptime stage: Stage) void {
    const cur = &sc.stagePtr(stage).current_computed;
    if (cur.font == null) {
        cur.font = sc.computedFont(stage);
    }
    if (cur.color == null) cur.color = sc.getSpecifiedValue(stage, .color);
    if (cur.border_colors == null) cur.border_colors = sc.getSpecifiedValue(stage, .border_colors);
    if (cur.border_radii == null) cur.border_radii = sc.getSpecifiedValue(stage, .border_radii);
    if (cur.background_color == null) cur.background_color = sc.getSpecifiedValue(stage, .background_color);
    if (cur.background_clip == null) cur.background_clip = sc.getSpecifiedValue(stage, .background_clip);
    if (cur.background == null) cur.background = sc.getSpecifiedValue(stage, .background);
    if (cur.opacity == null) cur.opacity = sc.getSpecifiedValue(stage, .opacity);
}

pub fn setCurrentNode(sc: *StyleComputer, comptime stage: Stage, node: NodeId) !void {
    const cascaded_values: *const CascadeStorage = switch (sc.env.getNodeProperty(.category, node)) {
        .element => sc.env.cascade_db.getStorage(node) orelse &.{},
        .text => undefined,
    };
    sc.current = .{
        .node = node,
        .cascaded_values = cascaded_values,
    };

    const index: u32 = @intCast(node.value);
    const s = sc.stagePtr(stage);
    s.current_index = index;
    if (s.visited.isSet(index)) {
        s.current_computed = s.nodes[index];
    } else {
        // First visit in this layout: start from no computed values, as a
        // fresh table would (a retained table holds the previous layout's).
        s.visited.set(index);
        if (s.blocked != null) {
            s.saved = s.nodes[index];
            s.nodes[index] = .{};
        }
        s.current_computed = .{};
    }
}

pub fn commitNode(sc: *StyleComputer, comptime stage: Stage) void {
    const s = sc.stagePtr(stage);
    s.nodes[s.current_index] = s.current_computed;
}

/// Fill in the groups layout itself never stages (it reads their specified
/// values on the fly), so the retained table holds the full computed value
/// set for the current element. Computed values of lengths have `em`
/// resolved against the element's own font-size (CSS-VALUES-4 §6.1.2);
/// percentages and `auto` stay as declared (CSS-CASCADE-4 §4.4). Runs after
/// box generation — layout stages some of these groups itself (inline boxes
/// set `horizontal_edges` after their first commit), and `setComputedValue`
/// requires each group to be set once.
fn completeComputedValues(sc: *StyleComputer, comptime stage: Stage) void {
    const cur = &sc.stagePtr(stage).current_computed;
    const font_px = sc.resolvedFontSizePx(stage);
    const root_px = rootFontSizePx(stage, sc, sc.current.node);

    if (cur.content_width == null) {
        var v = sc.getSpecifiedValue(stage, .content_width);
        v.width = v.width.resolveEm(font_px, root_px);
        v.min_width = v.min_width.resolveEm(font_px, root_px);
        v.max_width = v.max_width.resolveEm(font_px, root_px);
        cur.content_width = v;
    }
    if (cur.content_height == null) {
        var v = sc.getSpecifiedValue(stage, .content_height);
        v.height = v.height.resolveEm(font_px, root_px);
        v.min_height = v.min_height.resolveEm(font_px, root_px);
        v.max_height = v.max_height.resolveEm(font_px, root_px);
        cur.content_height = v;
    }
    if (cur.horizontal_edges == null) {
        var v = sc.getSpecifiedValue(stage, .horizontal_edges);
        v.padding_left = v.padding_left.resolveEm(font_px, root_px);
        v.padding_right = v.padding_right.resolveEm(font_px, root_px);
        v.margin_left = v.margin_left.resolveEm(font_px, root_px);
        v.margin_right = v.margin_right.resolveEm(font_px, root_px);
        cur.horizontal_edges = v;
    }
    if (cur.vertical_edges == null) {
        var v = sc.getSpecifiedValue(stage, .vertical_edges);
        v.padding_top = v.padding_top.resolveEm(font_px, root_px);
        v.padding_bottom = v.padding_bottom.resolveEm(font_px, root_px);
        v.margin_top = v.margin_top.resolveEm(font_px, root_px);
        v.margin_bottom = v.margin_bottom.resolveEm(font_px, root_px);
        cur.vertical_edges = v;
    }
    if (cur.insets == null) {
        var v = sc.getSpecifiedValue(stage, .insets);
        v.left = v.left.resolveEm(font_px, root_px);
        v.right = v.right.resolveEm(font_px, root_px);
        v.top = v.top.resolveEm(font_px, root_px);
        v.bottom = v.bottom.resolveEm(font_px, root_px);
        cur.insets = v;
    }
    if (cur.z_index == null) cur.z_index = sc.getSpecifiedValue(stage, .z_index);
    if (cur.border_styles == null) cur.border_styles = sc.getSpecifiedValue(stage, .border_styles);
}

/// Finish the per-element table after box generation (CSS-CASCADE-4 §4.4:
/// every element has computed values for every property, whether or not it
/// generates a box):
/// - elements box generation never visited — the descendants of
///   `display: none` elements — get their box style and cosmetic groups;
/// - every element gets the groups layout reads on the fly without staging
///   (sizes, edges, insets, z-index, border styles).
/// Inheritance resolves through `InheritedValue`, which computes a missing
/// parent on the fly, so node order does not matter.
pub fn completeTable(sc: *StyleComputer, comptime stage: Stage, group: Environment.NodeGroup) !void {
    const s = sc.stagePtr(stage);
    for (0..@min(s.nodes.len, sc.env.node_count)) |index| {
        const node: NodeId = .{ .group = group, .value = index };
        // A retained table: an entry layout neither visited nor reset is
        // the previous layout's complete one, still valid.
        if (s.blocked) |blocked| {
            if (!s.visited.isSet(index) and index < blocked.len and !blocked[index]) continue;
        }
        if (sc.env.getNodeProperty(.category, node) != .element) continue;
        try sc.setCurrentNode(stage, node);
        if (s.current_computed.box_style == null) {
            const specified = sc.getSpecifiedValue(stage, .box_style);
            const computed, _ = solve.boxStyle(specified, .not_root, false);
            sc.setComputedValue(stage, .box_style, computed);
            sc.stageCosmeticValues(stage);
        }
        sc.completeComputedValues(stage);
        sc.commitNode(stage);
    }
}

pub fn getText(sc: *const StyleComputer) []const u8 {
    const node = sc.current.node;
    assert(sc.env.getNodeProperty(.category, node) == .text);
    const id = sc.env.getNodeProperty(.text, node);
    return sc.env.getText(id);
}

pub fn getTextFont(sc: *const StyleComputer, comptime stage: Stage) ComputedValues(.font) {
    const node = sc.current.node;
    assert(sc.env.getNodeProperty(.category, node) == .text);
    var inherited_value = InheritedValue(.font){ .node = node };
    return inherited_value.get(sc, stage);
}

/// Get the current element's resolved font-size in px.
/// Resolves em values against the parent's computed font-size.
/// The current element's computed font size in px.
/// The root element's computed font size, for `rem` (CSS Values 4 §6.1.1).
pub fn resolvedRootFontSizePx(sc: *const StyleComputer, comptime stage: Stage) f32 {
    return rootFontSizePx(stage, sc, sc.current.node);
}

pub fn resolvedFontSizePx(sc: *const StyleComputer, comptime stage: Stage) f32 {
    return sc.computedFont(stage).font_size.px_val();
}

/// The current element's computed `font` group: its specified value with
/// the font size computed (`computeFont`).
pub fn computedFont(sc: *const StyleComputer, comptime stage: Stage) ComputedValues(.font) {
    return computeFont(stage, sc.getSpecifiedValue(stage, .font), sc, sc.current.node);
}

/// The committed computed value of `group` for an element already visited
/// in this stage (null if it was not committed).
pub fn committedValue(sc: *const StyleComputer, comptime stage: Stage, comptime group: groups.Tag, node: NodeId) ?ComputedValues(group) {
    const s = sc.stageConst(stage);
    const index: usize = @intCast(node.value);
    if (index >= s.nodes.len) return null;
    return @field(s.nodes[index], @tagName(group));
}

/// The current element's computed value for `group`, if it has been set
/// (box_style is set by BoxGen.analyzeNode before dispatch).
pub fn getComputedValue(sc: *const StyleComputer, comptime stage: Stage, comptime group: groups.Tag) ?ComputedValues(group) {
    return @field(sc.stageConst(stage).current_computed, @tagName(group));
}

pub fn setComputedValue(sc: *StyleComputer, comptime stage: Stage, comptime group: groups.Tag, value: ComputedValues(group)) void {
    const field = &@field(sc.stagePtr(stage).current_computed, @tagName(group));
    assert(field.* == null);
    field.* = value;
}

pub fn getSpecifiedValue(sc: *const StyleComputer, comptime stage: Stage, comptime group: groups.Tag) SpecifiedValues(group) {
    return sc.getSpecifiedValueForElement(stage, group, sc.current.node, sc.current.cascaded_values);
}

/// Like getSpecifiedValue but reads from a specific node instead of sc.current.node.
/// Use when sc.current.node may not be the element you need (e.g. ::after from nullNode).
pub fn getSpecifiedValueForNode(
    sc: *const StyleComputer,
    comptime stage: Stage,
    comptime group: groups.Tag,
    node: NodeId,
) SpecifiedValues(group) {
    const cascaded_values: *const CascadeStorage = sc.env.cascade_db.getStorage(node) orelse &.{};
    return sc.getSpecifiedValueForElement(stage, group, node, cascaded_values);
}

/// Like resolvedFontSizePx but for a specific node instead of sc.current.node.
pub fn resolvedFontSizePxForNode(sc: *const StyleComputer, comptime stage: Stage, node: NodeId) f32 {
    const cascaded_values: *const CascadeStorage = sc.env.cascade_db.getStorage(node) orelse &.{};
    const font = sc.getSpecifiedValueForElement(stage, .font, node, cascaded_values);
    return computeFont(stage, font, sc, node).font_size.px_val();
}

fn getSpecifiedValueForElement(
    self: *const StyleComputer,
    comptime stage: Stage,
    comptime group: groups.Tag,
    node: NodeId,
    cascaded_values: *const CascadeStorage,
) SpecifiedValues(group) {
    assert(self.env.getNodeProperty(.category, node) == .element);
    const cascaded_value = cascaded_values.getPtr(group);

    const inheritance_type = comptime group.inheritanceType();
    const default: enum { inherit, initial } = default: {
        // Use the value of the 'all' property.
        //
        // TODO: Handle 'direction', 'unicode-bidi', and custom properties specially here.
        // CSS-CASCADE-4§3.2: The all property is a shorthand that resets all CSS properties except direction and unicode-bidi.
        //                    [...] It does not reset custom properties.
        if (cascaded_values.all) |all| switch (all) {
            .initial => break :default .initial,
            .inherit => break :default .inherit,
            .unset => {},
        };

        // Just use the inheritance type.
        switch (inheritance_type) {
            .inherited => break :default .inherit,
            .not_inherited => break :default .initial,
        }
    };

    const initial_value = group.initialValues();
    if (cascaded_value == null and default == .initial) {
        return initial_value;
    }

    var inherited_value = InheritedValue(group){ .node = node };
    if (cascaded_value == null and default == .inherit) {
        return inherited_value.get(self, stage);
    }

    var specified: SpecifiedValues(group) = undefined;
    inline for (group.fields()) |field| {
        const cascaded_property = @field(cascaded_value.?, field.name);
        const specified_property = &@field(specified, field.name);
        specified_property.* = switch (cascaded_property) {
            .inherit => @field(inherited_value.get(self, stage), field.name),
            .initial => @field(initial_value, field.name),
            .unset => switch (inheritance_type) {
                .inherited => @field(inherited_value.get(self, stage), field.name),
                .not_inherited => @field(initial_value, field.name),
            },
            .undeclared => switch (default) {
                .inherit => @field(inherited_value.get(self, stage), field.name),
                .initial => @field(initial_value, field.name),
            },
            .declared => |declared| declared,
        };
    }

    return specified;
}

fn InheritedValue(comptime group: groups.Tag) type {
    return struct {
        value: ?ComputedValues(group) = null,
        node: NodeId,

        fn get(self: *@This(), sc: *const StyleComputer, comptime stage: Stage) ComputedValues(group) {
            if (self.value) |value| return value;

            const s = sc.stageConst(stage);
            self.value = if (self.node.parent(sc.env)) |parent| blk: {
                const parent_index: u32 = @intCast(parent.value);
                if (parent_index < s.nodes.len) {
                    if (@field(s.nodes[parent_index], @tagName(group))) |inherited_value| {
                        break :blk inherited_value;
                    }
                }
                // TODO: Cache the parent's computed value for faster access in future calls.

                const cascaded_values: *const CascadeStorage = sc.env.cascade_db.getStorage(parent) orelse &.{};
                // TODO: Recursive call here
                const specified_value = sc.getSpecifiedValueForElement(stage, group, parent, cascaded_values);
                break :blk specifiedToComputed(stage, group, specified_value, sc, parent);
            } else group.initialValues();
            return self.value.?;
        }
    };
}

/// CSS Fonts 4 §2.5 computed font-size, plus Blink's generic family rule:
/// a size not derived from an absolute length is recomputed when the
/// element's family switches to or from the lone generic `monospace`
/// (FontBuilder::CheckForGenericFamilyChange): keyword sizes come from the
/// fixed-pitch keyword table, other sizes scale by 13/16 (Chrome's default
/// fixed and standard font sizes).
fn computeFont(comptime stage: Stage, specified: SpecifiedValues(.font), sc: *const StyleComputer, node: NodeId) ComputedValues(.font) {
    // InheritedValue(.font){ .node = node } is the parent's computed value.
    const parent: ComputedValues(.font) = if (node.parent(sc.env) != null) blk: {
        var inherited = InheritedValue(.font){ .node = node };
        break :blk inherited.get(sc, stage);
    } else root_parent_font;
    const parent_px = parent.font_size.px_val();
    const mono = specified.generic_monospace;
    var info = specified.font_size_info;
    var size: f32 = switch (specified.font_size) {
        // Declared absolute, or inherited with the parent's facts.
        .px => |v| v,
        .keyword => |k| keywordFontSize(k, mono),
        .em => |v| v * parent_px,
        .rem => |v| v * rootFontSizePx(stage, sc, node),
        // CSS Fonts 4 §2.5: Chrome scales by 1.2.
        .larger => parent_px * 1.2,
        .smaller => parent_px / 1.2,
    };
    switch (specified.font_size) {
        .px, .keyword => {},
        else => info = .{ .keyword = 0, .absolute = parent.font_size_info.absolute },
    }
    if (!info.absolute and mono != parent.generic_monospace) {
        size = if (info.keyword != 0)
            keywordFontSize(@intCast(info.keyword - 1), mono)
        else if (parent.generic_monospace)
            size * 16.0 / 13.0
        else
            size * 13.0 / 16.0;
    }
    var result = specified;
    // CSS Fonts 4 §2.2: relative weights from the inherited weight.
    const parent_weight: u16 = @intFromEnum(parent.font_weight);
    switch (specified.font_weight) {
        .bolder => result.font_weight = @enumFromInt(@as(u16, if (parent_weight < 350) 400 else if (parent_weight < 550) 700 else if (parent_weight < 900) 900 else parent_weight)),
        .lighter => result.font_weight = @enumFromInt(@as(u16, if (parent_weight < 100) parent_weight else if (parent_weight < 550) 100 else if (parent_weight < 750) 400 else 700)),
        else => {},
    }
    result.font_size = .{ .px = size };
    result.font_size_info = info;
    // CSS 2.1 §10.8.1: a percentage (and an em length) is relative to the
    // element's own font size; the computed value is the length.
    switch (specified.line_height) {
        .em => |m| result.line_height = .{ .length = m * size },
        .rem => |m| result.line_height = .{ .length = m * rootFontSizePx(stage, sc, node) },
        else => {},
    }
    return result;
}

/// The parent facts of the root element: the initial `medium`.
const root_parent_font: ComputedValues(.font) = blk: {
    var font = groups.Tag.font.initialValues();
    font.font_size = .{ .px = 16.0 };
    break :blk font;
};

/// Chrome's <absolute-size> tables (Blink FontSizeFunctions, for a 16px
/// standard and a 13px fixed-pitch default size).
fn keywordFontSize(k: u3, monospace: bool) f32 {
    const standard = [8]f32{ 9, 10, 13, 16, 18, 24, 32, 48 };
    const fixed = [8]f32{ 9, 10, 12, 13, 16, 20, 26, 39 };
    return if (monospace) fixed[k] else standard[k];
}

/// The root element's computed font size, for `rem`.
fn rootFontSizePx(comptime stage: Stage, sc: *const StyleComputer, node: NodeId) f32 {
    var root = node;
    while (root.parent(sc.env)) |p| root = p;
    // The root's own `rem` refers to the initial font size.
    if (root.value == node.value) return 16.0;
    const s = sc.stageConst(stage);
    const index: usize = @intCast(root.value);
    if (index < s.nodes.len) if (s.nodes[index].font) |font| return font.font_size.px_val();
    const cascaded_values: *const CascadeStorage = sc.env.cascade_db.getStorage(root) orelse &.{};
    const specified = sc.getSpecifiedValueForElement(stage, .font, root, cascaded_values);
    return computeFont(stage, specified, sc, root).font_size.px_val();
}

/// Given a specified value, returns a computed value.
fn specifiedToComputed(comptime stage: Stage, comptime group: groups.Tag, specified: SpecifiedValues(group), sc: *const StyleComputer, node: NodeId) ComputedValues(group) {
    switch (group) {
        .box_style => {
            const parent = node.parent(sc.env);
            // parent_blockifies=false here: cascade-time computation doesn't
            // know layout-time parent flex/grid context. BoxGen.analyzeNode
            // passes the real flag when it computes used_box_style.
            const computed_value, _ = if (parent == null) // TODO: Should check for equality with the root node instead
                solve.boxStyle(specified, .root, false)
            else
                solve.boxStyle(specified, .not_root, false);
            return computed_value;
        },
        .font => return computeFont(stage, specified, sc, node),
        .color => {
            return .{
                .color = specified.color,
            };
        },
        else => std.debug.panic("TODO: specifiedToComputed for aggregate '{s}'", .{@tagName(group)}),
    }
}
