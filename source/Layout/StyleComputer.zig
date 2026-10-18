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

fn stageVal(sc: StyleComputer, comptime stage: Stage) StageData(stage) {
    return switch (stage) {
        .box_gen => sc.box_gen_stage,
    };
}

/// Allocate the per-node table for `stage` with `allocator` — the allocator
/// that will own the table once `takeStage` hands it to the `BoxTree`.
pub fn ensureCapacity(sc: *StyleComputer, comptime stage: Stage, allocator: Allocator, count: u32) !void {
    const s = sc.stagePtr(stage);
    s.nodes = try allocator.alloc(stage.ComputedValues(), count);
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

/// Stage the inherited/cosmetic groups of the current element (font with its
/// font-size resolved to px, color, borders, background, opacity) without
/// committing. Mirrors what the flow/inline paths stage before they commit a
/// box, for elements that generate no box but still have computed values.
pub fn stageCosmeticValues(sc: *StyleComputer, comptime stage: Stage) void {
    var font = sc.getSpecifiedValue(stage, .font);
    font.font_size = .{ .px = sc.resolvedFontSizePx(stage) };
    sc.setComputedValue(stage, .font, font);
    sc.setComputedValue(stage, .color, sc.getSpecifiedValue(stage, .color));
    sc.setComputedValue(stage, .border_colors, sc.getSpecifiedValue(stage, .border_colors));
    sc.setComputedValue(stage, .border_radii, sc.getSpecifiedValue(stage, .border_radii));
    sc.setComputedValue(stage, .background_color, sc.getSpecifiedValue(stage, .background_color));
    sc.setComputedValue(stage, .background_clip, sc.getSpecifiedValue(stage, .background_clip));
    sc.setComputedValue(stage, .background, sc.getSpecifiedValue(stage, .background));
    sc.setComputedValue(stage, .opacity, sc.getSpecifiedValue(stage, .opacity));
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

pub fn getText(sc: StyleComputer) []const u8 {
    const node = sc.current.node;
    assert(sc.env.getNodeProperty(.category, node) == .text);
    const id = sc.env.getNodeProperty(.text, node);
    return sc.env.getText(id);
}

pub fn getTextFont(sc: StyleComputer, comptime stage: Stage) ComputedValues(.font) {
    const node = sc.current.node;
    assert(sc.env.getNodeProperty(.category, node) == .text);
    var inherited_value = InheritedValue(.font){ .node = node };
    return inherited_value.get(sc, stage);
}

/// Get the current element's resolved font-size in px.
/// Resolves em values against the parent's computed font-size.
pub fn resolvedFontSizePx(sc: StyleComputer, comptime stage: Stage) f32 {
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

pub fn setComputedValue(sc: *StyleComputer, comptime stage: Stage, comptime group: groups.Tag, value: ComputedValues(group)) void {
    const field = &@field(sc.stagePtr(stage).current_computed, @tagName(group));
    assert(field.* == null);
    field.* = value;
}

pub fn getSpecifiedValue(sc: StyleComputer, comptime stage: Stage, comptime group: groups.Tag) SpecifiedValues(group) {
    return sc.getSpecifiedValueForElement(stage, group, sc.current.node, sc.current.cascaded_values);
}

/// Like getSpecifiedValue but reads from a specific node instead of sc.current.node.
/// Use when sc.current.node may not be the element you need (e.g. ::after from nullNode).
pub fn getSpecifiedValueForNode(
    sc: StyleComputer,
    comptime stage: Stage,
    comptime group: groups.Tag,
    node: NodeId,
) SpecifiedValues(group) {
    const cascaded_values: *const CascadeStorage = sc.env.cascade_db.getStorage(node) orelse &.{};
    return sc.getSpecifiedValueForElement(stage, group, node, cascaded_values);
}

/// Like resolvedFontSizePx but for a specific node instead of sc.current.node.
pub fn resolvedFontSizePxForNode(sc: StyleComputer, comptime stage: Stage, node: NodeId) f32 {
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
    self: StyleComputer,
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

        fn get(self: *@This(), sc: StyleComputer, comptime stage: Stage) ComputedValues(group) {
            if (self.value) |value| return value;

            const s = sc.stageVal(stage);
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
fn specifiedToComputed(comptime stage: Stage, comptime group: groups.Tag, specified: SpecifiedValues(group), sc: StyleComputer, node: NodeId) ComputedValues(group) {
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
