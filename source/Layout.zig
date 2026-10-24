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
pub const reuse = @import("Layout/reuse.zig");
pub const Incremental = reuse.Incremental;

box_tree: BoxTreeManaged,
computer: StyleComputer,
viewport: math.Size,
inputs: Inputs,
allocator: Allocator,
node_stack: zss.Stack(?NodeId),
box_gen: BoxGen,
/// Lay out again from the previous layout of the same document: unchanged
/// elements take over their boxes (`Layout/reuse.zig`). Set before `run`,
/// which consumes `previous`.
incremental: ?Incremental = null,
reuse_state: reuse.State = .{},

pub const Inputs = struct {
    width: u32,
    height: u32,
    env: *const Environment,
    images: *const Images,
    fonts: *const Fonts,
};

/// Coarse per-run profile counters (nanoseconds / calls), reset by `run`
/// and read by the host after layout, while `profile_enabled` is set (the
/// clock reads in the per-node dispatch loop were ~5% of layout).
pub const Profile = struct {
    shape_ns: u64 = 0,
    shape_calls: u64 = 0,
    glyph_ns: u64 = 0,
    line_split_ns: u64 = 0,
    line_split_calls: u64 = 0,
    analyze_ns: u64 = 0,
    abs_ns: u64 = 0,
    inline_modes: u64 = 0,
    stf_modes: u64 = 0,
    analyze_node_ns: u64 = 0,
    dispatch_ns: [3]u64 = .{ 0, 0, 0 },
    null_ns: u64 = 0,
    pop_flow_ns: u64 = 0,
    pop_flow_calls: u64 = 0,
};
pub var profile: Profile = .{};
/// Collect `profile` (the host turns it on for diagnostics).
pub var profile_enabled: bool = false;

/// Profile clock: the CPU timestamp counter on x86_64 (a few ns; the
/// libc-less `std.time.nanoTimestamp` is a real syscall here and 100k of
/// them tripled layout time). Ticks are converted to ns by `run` against
/// one wall-clock pair per layout.
pub inline fn now() u64 {
    if (!profile_enabled) return 0;
    if (@import("builtin").cpu.arch == .x86_64) {
        var lo: u32 = undefined;
        var hi: u32 = undefined;
        asm volatile ("rdtsc"
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
        );
        return (@as(u64, hi) << 32) | lo;
    }
    return @intCast(std.time.nanoTimestamp());
}

/// Wall ns per `now()` tick, measured over the last `run`.
pub var ns_per_tick: f64 = 1.0;

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
    layout.reuse_state.deinit(layout.allocator);
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

    profile = .{};
    const wall_start = std.time.nanoTimestamp();
    const tick_start = now();
    defer {
        const ticks = now() - tick_start;
        const wall: f64 = @floatFromInt(std.time.nanoTimestamp() - wall_start);
        if (ticks > 0) ns_per_tick = wall / @as(f64, @floatFromInt(ticks));
    }
    @import("Layout/inline.zig").resetShapeCache();
    var box_tree = BoxTree{ .allocator = allocator, .viewport = layout.viewport };
    errdefer box_tree.deinit();
    layout.box_tree = .{ .ptr = &box_tree };
    // The previous tree's remaining parts are freed whatever happens.
    defer if (layout.incremental) |inc| {
        layout.reuse_state.releasePrevious(inc.previous);
        layout.incremental = null;
    };

    {
        layout.node_stack.top = layout.inputs.env.root_node;
        layout.computer.active_stage = .box_gen;
        if (layout.incremental) |inc| {
            if (std.meta.eql(inc.previous.viewport, layout.viewport)) {
                try layout.reuse_state.begin(layout.allocator, inc.previous);
                try box_tree.node_to_generated_box.ensureTotalCapacity(allocator, inc.previous.node_to_generated_box.count());
                try layout.computer.adoptTable(.box_gen, allocator, &inc.previous.computed_styles, layout.inputs.env.node_count, inc.blocked);
            } else {
                layout.reuse_state.active = false;
                try layout.computer.ensureCapacity(.box_gen, allocator, layout.inputs.env.node_count);
            }
        } else try layout.computer.ensureCapacity(.box_gen, allocator, layout.inputs.env.node_count);
        errdefer layout.computer.deinitStage(.box_gen, allocator);
        try layout.box_gen.run();
        if (layout.inputs.env.root_node) |root| {
            try layout.computer.completeTable(.box_gen, root.group);
        }
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
        \\  @name(child) * (display: block; font-size: 2em; padding-left: 1em) {
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

    // Descendants of display:none are filled in after box generation: the
    // inner element inherits the hidden element's color and the 40px font.
    const inner = styles.get(node.get(&document, "inner")) orelse return error.TestFailure;
    try std.testing.expectEqual(zss.values.types.Display.block, inner.box_style.?.display);
    try std.testing.expectEqual(40.0, inner.font.?.font_size.px_val());
    try std.testing.expectEqual(hidden.color.?.color, inner.color.?.color);

    // Every committed element carries the layout-side groups too, with em
    // resolved against its own font-size: child has padding-left: 1em = 40px.
    try std.testing.expectEqual(40.0, child.horizontal_edges.?.padding_left.px);
    try std.testing.expect(root.content_width.?.width == .auto);
}

pub fn currentNode(layout: Layout) ?NodeId {
    return layout.node_stack.top.?;
}

/// Box generation walks the document with ::before / ::after as the first
/// and last children of their element (`Environment.boxFirstChild`).
pub fn pushNode(layout: *Layout) !void {
    const env = layout.inputs.env;
    const node = &layout.node_stack.top.?;
    const child = env.boxFirstChild(node.*.?);
    node.* = env.boxNextSibling(node.*.?);
    try layout.node_stack.push(layout.allocator, child);
}

pub fn popNode(layout: *Layout) void {
    _ = layout.node_stack.pop();
}

pub fn advanceNode(layout: *Layout) void {
    const node = &layout.node_stack.top.?;
    node.* = layout.inputs.env.boxNextSibling(node.*.?);
}
