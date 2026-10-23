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
/// table is only valid while that `Environment` is alive.
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
    _ = self;
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
    const T = stage.ComputedValues();
    const bytes = allocator.rawAlloc(@sizeOf(T) * count, .of(T), @returnAddress()) orelse return error.OutOfMemory;
    s.nodes = @as([*]T, @ptrCast(@alignCast(bytes)))[0..count];
    @memset(s.nodes, .{});
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
        var font = sc.getSpecifiedValue(stage, .font);
        font.font_size = .{ .px = sc.resolvedFontSizePx(stage) };
        cur.font = font;
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
    s.current_computed = s.nodes[index];
}

/// Set up the style computer to read cascaded values for a pseudo-element
/// (::before or ::after) attached to the given node. Returns true if the
/// pseudo-element has cascaded styles; false means no CSS rules matched.
/// Unlike setCurrentNode, this does not allocate or cache computed values.
pub fn setPseudoElement(sc: *StyleComputer, comptime stage: Stage, node: NodeId, pseudo: selectors.PseudoElement) bool {
    const cascaded_values = sc.env.cascade_db.getPseudoStorage(node, pseudo) orelse return false;
    sc.current = .{
        .node = node,
        .cascaded_values = cascaded_values,
    };
    // Fresh computed values for the pseudo-element (not stored in the per-node map).
    sc.stagePtr(stage).current_computed = .{};
    return true;
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

    if (cur.content_width == null) {
        var v = sc.getSpecifiedValue(stage, .content_width);
        v.width = v.width.resolveEm(font_px);
        v.min_width = v.min_width.resolveEm(font_px);
        v.max_width = v.max_width.resolveEm(font_px);
        cur.content_width = v;
    }
    if (cur.content_height == null) {
        var v = sc.getSpecifiedValue(stage, .content_height);
        v.height = v.height.resolveEm(font_px);
        v.min_height = v.min_height.resolveEm(font_px);
        v.max_height = v.max_height.resolveEm(font_px);
        cur.content_height = v;
    }
    if (cur.horizontal_edges == null) {
        var v = sc.getSpecifiedValue(stage, .horizontal_edges);
        v.padding_left = v.padding_left.resolveEm(font_px);
        v.padding_right = v.padding_right.resolveEm(font_px);
        v.margin_left = v.margin_left.resolveEm(font_px);
        v.margin_right = v.margin_right.resolveEm(font_px);
        cur.horizontal_edges = v;
    }
    if (cur.vertical_edges == null) {
        var v = sc.getSpecifiedValue(stage, .vertical_edges);
        v.padding_top = v.padding_top.resolveEm(font_px);
        v.padding_bottom = v.padding_bottom.resolveEm(font_px);
        v.margin_top = v.margin_top.resolveEm(font_px);
        v.margin_bottom = v.margin_bottom.resolveEm(font_px);
        cur.vertical_edges = v;
    }
    if (cur.insets == null) {
        var v = sc.getSpecifiedValue(stage, .insets);
        v.left = v.left.resolveEm(font_px);
        v.right = v.right.resolveEm(font_px);
        v.top = v.top.resolveEm(font_px);
        v.bottom = v.bottom.resolveEm(font_px);
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
    for (0..s.nodes.len) |index| {
        const node: NodeId = .{ .group = group, .value = index };
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
pub fn resolvedFontSizePx(sc: *const StyleComputer, comptime stage: Stage) f32 {
    const font = sc.getSpecifiedValue(stage, .font);
    return switch (font.font_size) {
        .px => |v| v,
        .em => |em_val| blk: {
            const parent = sc.current.node.parent(sc.env) orelse break :blk em_val * 16.0;
            const cascaded_values: *const CascadeStorage = sc.env.cascade_db.getStorage(parent) orelse &.{};
            const parent_font = sc.getSpecifiedValueForElement(stage, .font, parent, cascaded_values);
            const parent_fs: f32 = switch (parent_font.font_size) {
                .px => |v| v,
                // Recursive case: parent also uses em. In practice, nesting >1 level is rare.
                .em => |pem| pem * 16.0,
            };
            break :blk em_val * parent_fs;
        },
    };
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
    return switch (font.font_size) {
        .px => |v| v,
        .em => |em_val| blk: {
            const parent = node.parent(sc.env) orelse break :blk em_val * 16.0;
            const parent_cascaded: *const CascadeStorage = sc.env.cascade_db.getStorage(parent) orelse &.{};
            const parent_font = sc.getSpecifiedValueForElement(stage, .font, parent, parent_cascaded);
            const parent_fs: f32 = switch (parent_font.font_size) {
                .px => |v| v,
                .em => |pem| pem * 16.0,
            };
            break :blk em_val * parent_fs;
        },
    };
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
        .font => {
            // Resolve font-size em against parent's computed font-size.
            var result = specified;
            result.font_size = switch (specified.font_size) {
                .px => specified.font_size,
                .em => |em_val| blk: {
                    const parent_font_size = if (node.parent(sc.env)) |parent| pfz: {
                        var inherited = InheritedValue(.font){ .node = parent };
                        break :pfz inherited.get(sc, stage).font_size.px_val();
                    } else 16.0; // root: initial font-size
                    break :blk .{ .px = em_val * parent_font_size };
                },
            };
            return result;
        },
        .color => {
            return .{
                .color = specified.color,
            };
        },
        else => std.debug.panic("TODO: specifiedToComputed for aggregate '{s}'", .{@tagName(group)}),
    }
}
