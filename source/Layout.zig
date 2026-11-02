const Layout = @This();

const std = @import("std");
const solve = @import("Layout/solve.zig");
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
/// The `node_stack` depths (`rest.items.len`) of levels holding the children
/// of a `display: contents` element (CSS Display 3 §2.5: the element
/// generates no box and its children take its place in the box tree). Box
/// generation never sees such an element or the end of such a level:
/// `skipContents` steps into it and out of it.
contents_levels: std.ArrayListUnmanaged(usize) = .empty,
/// Levels `takeLevel` took off `node_stack`, top first.
taken_levels: std.ArrayListUnmanaged(struct { node: ?NodeId, contents: bool }) = .empty,
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
    layout.contents_levels.deinit(layout.allocator);
    layout.taken_levels.deinit(layout.allocator);
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
    try box_tree.node_to_generated_box.ensureNodes(allocator, layout.inputs.env.node_count);
    layout.box_tree = .{ .ptr = &box_tree };
    // The previous tree's remaining parts are freed whatever happens (on
    // success just before returning, as they pass spare storage to the new
    // tree).
    errdefer if (layout.incremental) |inc| {
        layout.reuse_state.releasePrevious(inc.previous, &box_tree);
        layout.incremental = null;
    };

    {
        layout.node_stack.top = layout.inputs.env.root_node;
        layout.contents_levels.clearRetainingCapacity();
        layout.computer.active_stage = .box_gen;
        if (layout.incremental) |inc| {
            if (std.meta.eql(inc.previous.viewport, layout.viewport)) {
                try layout.reuse_state.begin(layout.allocator, inc.previous, layout.inputs.env.node_count);
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

    if (layout.incremental) |inc| {
        layout.reuse_state.releasePrevious(inc.previous, &box_tree);
        layout.incremental = null;
    }
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

/// The next node box generation visits, or `null` at the end of the
/// current level. Steps over `display: contents` elements (`skipContents`).
pub fn currentNode(layout: *Layout) !?NodeId {
    try layout.skipContents();
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

/// Pop the current level (with the `display: contents` levels above it, when
/// a caller unwinds levels whose nodes are not done — `inline.blockElement`).
pub fn popNode(layout: *Layout) void {
    while (layout.topIsContentsLevel()) {
        _ = layout.node_stack.pop();
        _ = layout.contents_levels.pop();
    }
    _ = layout.node_stack.pop();
}

pub fn advanceNode(layout: *Layout) void {
    const node = &layout.node_stack.top.?;
    node.* = layout.inputs.env.boxNextSibling(node.*.?);
}

/// Take the current level off `node_stack` (with the `display: contents`
/// levels above it: one level of the box tree), for callers that unwind the
/// levels beneath it and put it back (`inline.blockElement`).
pub fn takeLevel(layout: *Layout) !void {
    assert(layout.taken_levels.items.len == 0);
    while (true) {
        const contents = layout.topIsContentsLevel();
        if (contents) _ = layout.contents_levels.pop();
        try layout.taken_levels.append(layout.allocator, .{ .node = layout.node_stack.pop(), .contents = contents });
        if (!contents) return;
    }
}

pub fn restoreLevel(layout: *Layout) !void {
    while (layout.taken_levels.pop()) |level| {
        try layout.node_stack.push(layout.allocator, level.node);
        if (level.contents) try layout.contents_levels.append(layout.allocator, layout.node_stack.rest.items.len);
    }
}

fn topIsContentsLevel(layout: *const Layout) bool {
    const depth = layout.contents_levels.getLastOrNull() orelse return false;
    return layout.node_stack.top != null and depth == layout.node_stack.rest.items.len;
}

/// CSS Display 3 §2.5: an element with `display: contents` generates no box;
/// its children (and ::before / ::after) are laid out as if they were the
/// element's in its place. Steps over such elements at the top of
/// `node_stack` — into a level of their children — and out of such levels
/// once they are done, so the current node is one that generates boxes (or
/// the end of a real level). The element still has computed values
/// (CSS Cascade 4 §4.4), committed here: its children inherit from it.
fn skipContents(layout: *Layout) !void {
    const env = layout.inputs.env;
    if (!env.decls.has_display_contents) return;
    while (true) {
        if (layout.node_stack.top.?) |node| {
            if (!layout.isContents(node)) return;
            try layout.commitContents(node);
            layout.node_stack.top.? = env.boxNextSibling(node);
            try layout.node_stack.push(layout.allocator, env.boxFirstChild(node));
            try layout.contents_levels.append(layout.allocator, layout.node_stack.rest.items.len);
        } else {
            if (!layout.topIsContentsLevel()) return;
            _ = layout.node_stack.pop();
            _ = layout.contents_levels.pop();
        }
    }
}

fn isContents(layout: *const Layout, node: NodeId) bool {
    const env = layout.inputs.env;
    if (env.getNodeProperty(.category, node) != .element) return false;
    // The root element's `display: contents` computes to `block`.
    if (env.root_node) |root| if (std.meta.eql(root, node)) return false;
    if (layout.computer.getSpecifiedValueForNode(.box_gen, .box_style, node).display != .contents) return false;
    // CSS Pseudo 4 §2.6: a ::before / ::after whose content computes to
    // none generates nothing (box generation makes it `display: none`).
    if (env.isPseudoElement(node)) switch (layout.computer.getSpecifiedValueForNode(.box_gen, .generated_content, node).content) {
        .normal, .none => return false,
        else => {},
    };
    return true;
}

/// Commit the computed values of a `display: contents` element without
/// disturbing the style computer's current node (the caller's).
fn commitContents(layout: *Layout, node: NodeId) !void {
    const sc = &layout.computer;
    const saved_current = sc.current;
    const saved_stage = sc.box_gen_stage.saveCurrent();
    defer {
        sc.current = saved_current;
        sc.box_gen_stage.restoreCurrent(saved_stage);
    }
    try sc.setCurrentNode(.box_gen, node);
    if (sc.getComputedValue(.box_gen, .box_style) == null) {
        const computed, _ = solve.boxStyle(sc.getSpecifiedValue(.box_gen, .box_style), .not_root, false);
        sc.setComputedValue(.box_gen, .box_style, computed);
    }
    sc.stageCosmeticValues(.box_gen);
    sc.commitNode(.box_gen);
}
