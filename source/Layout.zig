const Layout = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const math = zss.math;
const BoxTree = zss.BoxTree;
const Environment = zss.Environment;
const Fonts = zss.Fonts;
const Images = zss.Images;
const NodeId = Environment.NodeId;

pub const BoxGen = @import("Layout/BoxGen.zig");
pub const BoxTreeManaged = @import("Layout/BoxTreeManaged.zig");
pub const StyleComputer = @import("Layout/StyleComputer.zig");

box_tree: BoxTreeManaged,
computer: StyleComputer,
viewport: math.Size,
inputs: Inputs,
allocator: Allocator,
node_stack: zss.Stack(?NodeId),
box_gen: BoxGen,

pub const Inputs = struct {
    width: u32,
    height: u32,
    env: *const Environment,
    images: *const Images,
    fonts: *const Fonts,
};

pub const Error = error{
    OutOfMemory,
    SizeLimitExceeded,
    ViewportTooLarge,
};

const Mode = enum {
    flow,
    stf,
    @"inline",
};

pub const IsRoot = enum {
    root,
    not_root,
};

pub fn init(
    env: *const Environment,
    allocator: Allocator,
    /// The width of the viewport in pixels.
    width: u32,
    /// The height of the viewport in pixels.
    height: u32,
    images: *const Images,
    fonts: *const Fonts,
) Layout {
    return .{
        .box_tree = undefined,
        .computer = StyleComputer.init(env, allocator),
        .viewport = undefined,
        .inputs = .{
            .width = width,
            .height = height,
            .env = env,
            .images = images,
            .fonts = fonts,
        },
        .allocator = allocator,
        .node_stack = .{},
        .box_gen = .{},
    };
}

pub fn deinit(layout: *Layout) void {
    layout.computer.deinit();
    layout.node_stack.deinit(layout.allocator);
    layout.box_gen.deinit();
}

pub fn run(layout: *Layout, allocator: Allocator) Error!BoxTree {
    const cast = math.pixelsToUnits;
    const width_units = cast(layout.inputs.width) orelse return error.ViewportTooLarge;
    const height_units = cast(layout.inputs.height) orelse return error.ViewportTooLarge;
    layout.viewport = .{
        .w = width_units,
        .h = height_units,
    };

    var box_tree = BoxTree{ .allocator = allocator };
    errdefer box_tree.deinit();
    layout.box_tree = .{ .ptr = &box_tree };

    {
        layout.node_stack.top = layout.inputs.env.root_node;
        layout.computer.active_stage = .box_gen;
        try layout.computer.ensureCapacity(.box_gen, allocator, layout.inputs.env.node_count);
        errdefer layout.computer.deinitStage(.box_gen, allocator);
        try layout.box_gen.run();
    }

    // The per-element computed values are part of the result of layout: the
    // box tree keeps them so callers can read computed styles (getComputedStyle,
    // inheritance queries) without re-running the cascade.
    box_tree.computed_styles = layout.computer.takeStage(.box_gen);

    return box_tree;
}

test "layout retains per-element computed styles" {
    const allocator = std.testing.allocator;

    // root 20px -> child 2em (= 40px, inherits color) -> display:none grandchild
    // (still has computed values) -> great-grandchild inside display:none
    // (never visited: no entry).
    const source_code = try zss.syntax.SourceCode.init(
        \\@name(root) * (display: block; font-size: 20px; color: rgb(255, 0, 0)) {
        \\  @name(child) * (display: block; font-size: 2em) {
        \\    @name(hidden) * (display: none; color: rgb(0, 0, 255)) {
        \\      @name(inner) * (display: block) {}
        \\    }
        \\  }
        \\}
    );
    var document = try zss.zml.parseAndCreateDocument(allocator, source_code);
    defer document.deinit(allocator);

    const cascade_list: zss.cascade.List = .{
        .author = &.{&.{ .leaf = &document.cascade_source }},
    };
    try zss.cascade.run(&cascade_list, &document.env, allocator);

    var images = Images.init();
    defer images.deinit(allocator);
    var fonts = Fonts.init();
    defer fonts.deinit();

    var layout = Layout.init(&document.env, allocator, 800, 600, &images, &fonts);
    defer layout.deinit();
    var box_tree = try layout.run(allocator);
    defer box_tree.deinit();

    const styles = &box_tree.computed_styles;
    const node = struct {
        fn get(doc: *const zss.zml.Document, name: []const u8) NodeId {
            return doc.named_nodes.get(name).?.toZssNode(doc);
        }
    };

    const root = styles.get(node.get(&document, "root")) orelse return error.TestFailure;
    try std.testing.expectEqual(20.0, root.font.?.font_size.px_val());
    try std.testing.expectEqual(zss.values.types.Display.block, root.box_style.?.display);

    const child = styles.get(node.get(&document, "child")) orelse return error.TestFailure;
    try std.testing.expectEqual(40.0, child.font.?.font_size.px_val());
    try std.testing.expectEqual(root.color.?.color, child.color.?.color);

    const hidden = styles.get(node.get(&document, "hidden")) orelse return error.TestFailure;
    try std.testing.expectEqual(zss.values.types.Display.none, hidden.box_style.?.display);
    try std.testing.expectEqual(40.0, hidden.font.?.font_size.px_val());
    try std.testing.expect(!std.meta.eql(root.color.?.color, hidden.color.?.color));

    try std.testing.expectEqual(null, styles.get(node.get(&document, "inner")));
}

pub fn currentNode(layout: Layout) ?NodeId {
    return layout.node_stack.top.?;
}

pub fn pushNode(layout: *Layout) !void {
    const node = &layout.node_stack.top.?;
    const child = node.*.?.firstChild(layout.inputs.env);
    node.* = node.*.?.nextSibling(layout.inputs.env);
    try layout.node_stack.push(layout.allocator, child);
}

pub fn popNode(layout: *Layout) void {
    _ = layout.node_stack.pop();
}

pub fn advanceNode(layout: *Layout) void {
    const node = &layout.node_stack.top.?;
    node.* = node.*.?.nextSibling(layout.inputs.env);
}
