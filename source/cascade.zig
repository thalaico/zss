const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const selectors = zss.selectors;
const Block = zss.Declarations.Block;
const Environment = zss.Environment;
const Importance = zss.Declarations.Importance;

/// The list of all cascade sources, grouped by their cascade origin.
///
/// You can affect the CSS cascade by inserting nodes into/removing nodes from the `user`, `author`, or `user_agent` lists.
/// Each list is independent of each other.
/// Nodes earlier in each list are considered to have a higher cascade order than later nodes in the same list.
///
/// During the cascade, each node is visited in the following way:
/// - If the node is a leaf node, its cascade source is applied.
/// - If the node is an inner node, each of its child nodes are visited in order, recursively.
pub const List = struct {
    user: []const *const Node = &.{},
    author: []const *const Node = &.{},
    user_agent: []const *const Node = &.{},
};

pub const Origin = enum { user, author, user_agent };

pub const Node = union(enum) {
    leaf: *const Source,
    inner: []const *const Node,
};

/// Contains the data necessary for a document to participate in the CSS cascade.
/// Every document that contains CSS style information should produce one of these.
///
/// During the cascade (if this cascade source participates in it), this cascade source will get applied.
/// Applying a cascade source means to assign all of its style information to the appropriate elements in the document tree.
pub const Source = struct {
    /// Pairs of elements and important declaration blocks.
    /// These declaration blocks must be the results of parsing [style attributes](https://www.w3.org/TR/css-style-attr/),
    /// or some equivalent mechanism by which the document applies style information directly to a specific element.
    style_attrs_important: std.AutoHashMapUnmanaged(zss.Environment.NodeId, Block) = .empty,
    /// Pairs of elements and normal declaration blocks.
    /// These declaration blocks must be the results of parsing [style attributes](https://www.w3.org/TR/css-style-attr/),
    /// or some equivalent mechanism by which the document applies style information directly to a specific element.
    style_attrs_normal: std.AutoHashMapUnmanaged(zss.Environment.NodeId, Block) = .empty,
    /// Pairs of elements and normal declaration blocks from HTML presentational attributes
    /// (e.g. width="100%", bgcolor="#fff"). Per CSS Cascading §6.4.2, these have specificity 0
    /// and must lose to any CSS selector declaration. Applied after selectors in the cascade.
    presentational_attrs_normal: std.AutoHashMapUnmanaged(zss.Environment.NodeId, Block) = .empty,
    /// Pairs of complex selectors and important declaration blocks.
    /// This list must be sorted such that selectors with higher cascade order appear earlier.
    selectors_important: std.MultiArrayList(SelectorBlock) = .empty,
    /// Pairs of complex selectors and normal declaration blocks.
    /// This list must be sorted such that selectors with higher cascade order appear earlier.
    selectors_normal: std.MultiArrayList(SelectorBlock) = .empty,
    selector_data: std.ArrayList(selectors.Data) = .empty,

    pub const SelectorBlock = struct {
        selector: selectors.Data.ListIndex,
        block: Block,
    };

    pub fn deinit(source: *Source, allocator: Allocator) void {
        source.style_attrs_important.deinit(allocator);
        source.style_attrs_normal.deinit(allocator);
        source.presentational_attrs_normal.deinit(allocator);
        source.selectors_important.deinit(allocator);
        source.selectors_normal.deinit(allocator);
        source.selector_data.deinit(allocator);
    }
};

/// A structure capable of storing the cascaded values of all CSS properties for every document node.
pub const Database = struct {
    node_map: std.AutoHashMapUnmanaged(Environment.NodeId, Storage) = .empty,
    /// Cascaded values for pseudo-elements (::before/::after) keyed by (node, pseudo).
    pseudo_map: std.AutoHashMapUnmanaged(PseudoKey, Storage) = .empty,
    arena: std.heap.ArenaAllocator.State = .{},

    pub const PseudoKey = struct {
        node: Environment.NodeId,
        pseudo: selectors.PseudoElement,
    };

    pub fn deinit(db: *Database, allocator: Allocator) void {
        // Deinit custom properties hashmaps
        var node_it = db.node_map.valueIterator();
        while (node_it.next()) |storage| {
            storage.custom_properties.deinit(allocator);
        }
        var pseudo_it = db.pseudo_map.valueIterator();
        while (pseudo_it.next()) |storage| {
            storage.custom_properties.deinit(allocator);
        }

        db.node_map.deinit(allocator);
        db.pseudo_map.deinit(allocator);

        var arena = db.arena.promote(allocator);
        defer db.arena = arena.state;
        arena.deinit();
    }

    pub fn addStorage(db: *Database, allocator: Allocator, node: Environment.NodeId) !*Storage {
        const gop = try db.node_map.getOrPut(allocator, node);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    pub fn getStorage(db: *const Database, node: Environment.NodeId) ?*Storage {
        return db.node_map.getPtr(node);
    }

    pub fn addPseudoStorage(db: *Database, allocator: Allocator, node: Environment.NodeId, pseudo: selectors.PseudoElement) !*Storage {
        const key = PseudoKey{ .node = node, .pseudo = pseudo };
        const gop = try db.pseudo_map.getOrPut(allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    pub fn getPseudoStorage(db: *const Database, node: Environment.NodeId, pseudo: selectors.PseudoElement) ?*Storage {
        const key = PseudoKey{ .node = node, .pseudo = pseudo };
        return db.pseudo_map.getPtr(key);
    }

    /// Stores the cascaded values of all CSS properties for a single document node.
    /// Pointers to cascaded values are not stable.
    pub const Storage = struct {
        /// Maps each value group to its cascaded values.
        group_map: Map = .{},
        /// The cascaded value for the 'all' CSS property.
        all: ?CssWideKeyword = null,
        /// Custom properties (CSS variables) declared on this element.
        /// Keys are property names (without --), values are unparsed token sequences.
        custom_properties: std.StringHashMapUnmanaged([]const u8) = .{},

        pub const Map = std.EnumMap(groups.Tag, usize);

        const CssWideKeyword = zss.values.types.CssWideKeyword;
        const groups = zss.values.groups;

        /// The main operation performed during the CSS cascade is "applying a declaration".
        ///
        /// To apply a declaration "decl" to a destination value "destValue" means the following:
        ///     1. If "destValue" is NOT equal to `.undeclared`, do nothing and return.
        ///     2. If "decl" is affected by the CSS 'all' property, then copy the value of the 'all' property into "destValue" and return.
        ///     3. Copy "decl" into "destValue".
        ///
        /// You can also apply an entire declaration block to a destination storage
        /// (where "destination storage" is some arbitrary data structure than can hold cascaded values).
        ///
        /// To apply a declaration block "block" to a destination storage "destStorage" means the following:
        ///     1. For each declaration "decl" within "block", apply "decl" to the corresponding value within "destStorage".
        ///
        /// Declaration blocks must be passed to this function in cascade order.
        pub fn applyDeclBlock(
            storage: *Storage,
            /// The `Database` that `storage` belongs to.
            db: *Database,
            /// The database's allocator.
            allocator: Allocator,
            decls: *const zss.Declarations,
            block: zss.Declarations.Block,
            importance: Importance,
        ) !void {
            // TODO: The 'all' property does not affect some properties
            if (storage.all != null) return;

            if (decls.getAll(block, importance)) |all| storage.all = all;

            var iterator = decls.groupIterator(block, importance);
            while (iterator.next()) |group| {
                const needs_init = !storage.group_map.contains(group);
                const map_value = if (needs_init) storage.group_map.putUninitialized(group) else storage.group_map.getPtrAssertContains(group);

                switch (group) {
                    inline else => |comptime_group| {
                        const CascadedValues = comptime_group.CascadedValues();
                        const cascaded_values: *CascadedValues = switch (comptime canFitWithinUsize(CascadedValues)) {
                            true => blk: {
                                const values: *CascadedValues = @ptrCast(map_value);
                                if (needs_init) values.* = .{};
                                break :blk values;
                            },
                            false => blk: {
                                if (needs_init) {
                                    var arena = db.arena.promote(allocator);
                                    defer db.arena = arena.state;

                                    const values = try arena.allocator().create(CascadedValues);
                                    values.* = .{};
                                    map_value.* = @intFromPtr(values);
                                }
                                break :blk @ptrFromInt(map_value.*);
                            },
                        };
                        decls.apply(comptime_group, block, importance, cascaded_values);
                    },
                }
            }
            
            // Apply custom properties from this declaration block
            const block_id = @intFromEnum(block);
            if (decls.custom_props_map.get(block_id)) |custom_props| {
                for (custom_props.items) |prop| {
                    try storage.custom_properties.put(allocator, prop.name, prop.value);
                }
            }
        }

        /// If there is a cascaded value for the value group `group`, returns a pointer to it. Otherwise returns `null`.
        pub fn getPtr(storage: *const Storage, comptime group: groups.Tag) ?*const group.CascadedValues() {
            const map_value_ptr = storage.group_map.getPtrConst(group) orelse return null;
            const CascadedValues = group.CascadedValues();
            return switch (comptime canFitWithinUsize(CascadedValues)) {
                true => @ptrCast(map_value_ptr),
                false => @ptrFromInt(map_value_ptr.*),
            };
        }

        fn canFitWithinUsize(comptime T: type) bool {
            return (@alignOf(T) <= @alignOf(usize) and @sizeOf(T) <= @sizeOf(usize));
        }

        pub fn reset(storage: *Storage) void {
            storage.group_map = .{}; // TODO: Leaks memory (but okay, because of arena allocation)
            storage.all = null;
        }
    };
};

const SelectorKey = union(enum) {
    id: Environment.IdName,
    class: Environment.ClassName,
    type_name: Environment.TypeName,
    universal,
};

fn extractRightmostKey(data: []const selectors.Data, complex_selector_index: selectors.Data.ListIndex) SelectorKey {
    const last_trailing_idx = data[complex_selector_index].next_complex_selector - 1;
    const trailing = data[last_trailing_idx].trailing;
    const start = trailing.compound_selector_start;
    const end = last_trailing_idx;

    var found_id: ?Environment.IdName = null;
    var found_class: ?Environment.ClassName = null;
    var found_type: ?Environment.TypeName = null;

    var idx = start;
    while (idx < end) : (idx += 1) {
        switch (data[idx].simple_selector_tag) {
            .id => {
                idx += 1;
                found_id = data[idx].id_selector;
            },
            .class => {
                idx += 1;
                if (found_class == null) found_class = data[idx].class_selector;
            },
            .type => {
                idx += 1;
                const et = data[idx].type_selector;
                if (et.name != .any and et.name != .anonymous) found_type = et.name;
            },
            .attribute => |op_case| {
                idx += 1; // skip attribute_selector
                if (op_case != null) idx += 1; // skip attribute_selector_value
            },
            .not_class, .not_id, .not_type, .not_pseudo_class, .pseudo_class => {
                idx += 1;
            },
            .pseudo_element => {
                idx += 1;
            },
            .is => {
                idx += 1;
                const list = data[idx].is_selector_list;
                if (list.count == 1) {
                    const nested_key = extractRightmostKey(data, list.start);
                    switch (nested_key) {
                        .id => |id| { if (found_id == null) found_id = id; },
                        .class => |cls| { if (found_class == null) found_class = cls; },
                        .type_name => |tn| { if (found_type == null) found_type = tn; },
                        .universal => {},
                    }
                }
                var skip_idx = list.start;
                for (0..list.count) |_| {
                    skip_idx = data[skip_idx].next_complex_selector;
                }
                idx = skip_idx - 1;
            },
            .where => {
                idx += 1;
                const list = data[idx].where_selector_list;
                if (list.count == 1) {
                    const nested_key = extractRightmostKey(data, list.start);
                    switch (nested_key) {
                        .id => |id| { if (found_id == null) found_id = id; },
                        .class => |cls| { if (found_class == null) found_class = cls; },
                        .type_name => |tn| { if (found_type == null) found_type = tn; },
                        .universal => {},
                    }
                }
                var skip_idx = list.start;
                for (0..list.count) |_| {
                    skip_idx = data[skip_idx].next_complex_selector;
                }
                idx = skip_idx - 1;
            },
        }
    }

    if (found_id) |id| return .{ .id = id };
    if (found_class) |cls| return .{ .class = cls };
    if (found_type) |tn| return .{ .type_name = tn };
    return .universal;
}

const PseudoTag = enum(u2) { none, before, after, unrecognized };
const SelectorEntry = struct {
    selector: selectors.Data.ListIndex,
    block: Block,
    source_order: u32,
    pseudo: PseudoTag,
    fast_match: bool,
    importance: Importance,
    ancestor_hashes: ?AncestorHashes,
};

const BLOOM_SIZE = 256;
const AncestorBloom = struct {
    counts: [BLOOM_SIZE]u8 = [_]u8{0} ** BLOOM_SIZE,

    fn hash1(val: u32) u8 {
        return @truncate(val);
    }
    fn hash2(val: u32) u8 {
        return @truncate(val >> 8);
    }
    fn addVal(self: *AncestorBloom, val: u32) void {
        self.counts[hash1(val)] +|= 1;
        self.counts[hash2(val)] +|= 1;
    }
    fn removeVal(self: *AncestorBloom, val: u32) void {
        self.counts[hash1(val)] -|= 1;
        self.counts[hash2(val)] -|= 1;
    }
    fn mightContain(self: *const AncestorBloom, val: u32) bool {
        return self.counts[hash1(val)] > 0 and self.counts[hash2(val)] > 0;
    }

    fn addNode(self: *AncestorBloom, env: *const Environment, node: Environment.NodeId) void {
        const element_type = env.getNodeProperty(.type, node);
        if (element_type.name != .any and element_type.name != .anonymous)
            self.addVal(@intFromEnum(element_type.name));
        if (env.nodes_to_classes.get(node)) |classes| {
            for (classes) |cls| self.addVal(@intFromEnum(cls));
        }
        if (env.nodes_to_ids.get(node)) |id| self.addVal(@intFromEnum(id));
    }

    fn removeNode(self: *AncestorBloom, env: *const Environment, node: Environment.NodeId) void {
        const element_type = env.getNodeProperty(.type, node);
        if (element_type.name != .any and element_type.name != .anonymous)
            self.removeVal(@intFromEnum(element_type.name));
        if (env.nodes_to_classes.get(node)) |classes| {
            for (classes) |cls| self.removeVal(@intFromEnum(cls));
        }
        if (env.nodes_to_ids.get(node)) |id| self.removeVal(@intFromEnum(id));
    }
};

const MAX_ANCESTOR_HASHES = 4;
const AncestorHashes = struct {
    hashes: [MAX_ANCESTOR_HASHES]u32 = undefined,
    len: u8 = 0,

    fn add(self: *AncestorHashes, val: u32) void {
        if (self.len < MAX_ANCESTOR_HASHES) {
            self.hashes[self.len] = val;
            self.len += 1;
        }
    }

    fn mightMatchBloom(self: *const AncestorHashes, bloom: *const AncestorBloom) bool {
        for (self.hashes[0..self.len]) |h| {
            if (!bloom.mightContain(h)) return false;
        }
        return true;
    }
};

fn canMatchStatic(data: []const selectors.Data, complex_selector_index: selectors.Data.ListIndex) bool {
    const last_trailing_idx = data[complex_selector_index].next_complex_selector - 1;
    var trailing_idx = last_trailing_idx;
    while (true) {
        const trailing = data[trailing_idx].trailing;
        const start = trailing.compound_selector_start;
        if (!compoundCanMatchStatic(data, start, trailing_idx)) return false;
        if (start <= complex_selector_index + 1) break;
        trailing_idx = start - 1;
    }
    return true;
}

fn compoundCanMatchStatic(data: []const selectors.Data, start: selectors.Data.ListIndex, end: selectors.Data.ListIndex) bool {
    var idx = start;
    while (idx < end) : (idx += 1) {
        switch (data[idx].simple_selector_tag) {
            .pseudo_class => {
                idx += 1;
                switch (data[idx].pseudo_class_selector) {
                    .hover, .active, .focus, .visited, .unrecognized => return false,
                    else => {},
                }
            },
            .type, .id, .class, .not_class, .not_id, .not_type, .not_pseudo_class, .pseudo_element => idx += 1,
            .attribute => |op_case| {
                idx += 1;
                if (op_case != null) idx += 1;
            },
            .is => {
                idx += 1;
                const list = data[idx].is_selector_list;
                var skip_idx = list.start;
                for (0..list.count) |_| skip_idx = data[skip_idx].next_complex_selector;
                idx = skip_idx - 1;
            },
            .where => {
                idx += 1;
                const list = data[idx].where_selector_list;
                var skip_idx = list.start;
                for (0..list.count) |_| skip_idx = data[skip_idx].next_complex_selector;
                idx = skip_idx - 1;
            },
        }
    }
    return true;
}

fn isFastMatch(data: []const selectors.Data, complex_selector_index: selectors.Data.ListIndex, key: SelectorKey) bool {
    const last_trailing_idx = data[complex_selector_index].next_complex_selector - 1;
    const trailing = data[last_trailing_idx].trailing;
    if (trailing.compound_selector_start != complex_selector_index + 1) return false;
    const start = trailing.compound_selector_start;
    const end = last_trailing_idx;
    var idx = start;
    while (idx < end) : (idx += 1) {
        switch (data[idx].simple_selector_tag) {
            .type => {
                idx += 1;
                const et = data[idx].type_selector;
                switch (key) {
                    .type_name => |tn| if (et.name == tn) continue,
                    else => {},
                }
                if (et.name != .any and et.name != .anonymous) return false;
            },
            .class => {
                idx += 1;
                switch (key) {
                    .class => |cls| if (data[idx].class_selector == cls) continue,
                    else => {},
                }
                return false;
            },
            .id => {
                idx += 1;
                switch (key) {
                    .id => |id_name| if (data[idx].id_selector == id_name) continue,
                    else => {},
                }
                return false;
            },
            .is => {
                idx += 1;
                const list = data[idx].is_selector_list;
                if (list.count != 1) return false;
                if (!isFastMatch(data, list.start, key)) return false;
                const skip_idx: selectors.Data.ListIndex = data[list.start].next_complex_selector;
                idx = skip_idx - 1;
            },
            .where => {
                idx += 1;
                const list = data[idx].where_selector_list;
                if (list.count != 1) return false;
                if (!isFastMatch(data, list.start, key)) return false;
                const skip_idx: selectors.Data.ListIndex = data[list.start].next_complex_selector;
                idx = skip_idx - 1;
            },
            else => return false,
        }
    }
    return true;
}

fn extractAncestorHashes(data: []const selectors.Data, complex_selector_index: selectors.Data.ListIndex) ?AncestorHashes {
    const last_trailing_idx = data[complex_selector_index].next_complex_selector - 1;
    const trailing = data[last_trailing_idx].trailing;
    if (trailing.compound_selector_start == complex_selector_index + 1) {
        return extractAncestorHashesFromWrappedPseudo(data, complex_selector_index);
    }
    var hashes = AncestorHashes{};
    var ti = trailing.compound_selector_start - 1;
    while (ti > complex_selector_index) {
        const t = data[ti].trailing;
        switch (t.combinator) {
            .descendant, .child => {
                const start = t.compound_selector_start;
                const end = ti;
                var idx = start;
                while (idx < end) : (idx += 1) {
                    switch (data[idx].simple_selector_tag) {
                        .type => {
                            idx += 1;
                            const et = data[idx].type_selector;
                            if (et.name != .any and et.name != .anonymous)
                                hashes.add(@intFromEnum(et.name));
                        },
                        .class => {
                            idx += 1;
                            hashes.add(@intFromEnum(data[idx].class_selector));
                        },
                        .id => {
                            idx += 1;
                            hashes.add(@intFromEnum(data[idx].id_selector));
                        },
                        .attribute => |op_case| {
                            idx += 1;
                            if (op_case != null) idx += 1;
                        },
                        .not_class, .not_id, .not_type, .not_pseudo_class, .pseudo_class => {
                            idx += 1;
                        },
                        .pseudo_element => idx += 1,
                        .is => {
                            idx += 1;
                            const list = data[idx].is_selector_list;
                            var skip_idx = list.start;
                            for (0..list.count) |_| skip_idx = data[skip_idx].next_complex_selector;
                            idx = skip_idx - 1;
                        },
                        .where => {
                            idx += 1;
                            const list = data[idx].where_selector_list;
                            var skip_idx = list.start;
                            for (0..list.count) |_| skip_idx = data[skip_idx].next_complex_selector;
                            idx = skip_idx - 1;
                        },
                    }
                }
            },
            else => {},
        }
        if (t.compound_selector_start <= complex_selector_index + 1) break;
        ti = t.compound_selector_start - 1;
    }
    if (hashes.len == 0) return null;
    return hashes;
}

fn extractAncestorHashesFromWrappedPseudo(data: []const selectors.Data, complex_selector_index: selectors.Data.ListIndex) ?AncestorHashes {
    const last_trailing_idx = data[complex_selector_index].next_complex_selector - 1;
    const trailing = data[last_trailing_idx].trailing;
    const start = trailing.compound_selector_start;
    const end = last_trailing_idx;
    var idx = start;
    while (idx < end) : (idx += 1) {
        switch (data[idx].simple_selector_tag) {
            .is => {
                idx += 1;
                const list = data[idx].is_selector_list;
                if (list.count == 1) return extractAncestorHashes(data, list.start);
                var skip_idx = list.start;
                for (0..list.count) |_| skip_idx = data[skip_idx].next_complex_selector;
                idx = skip_idx - 1;
            },
            .where => {
                idx += 1;
                const list = data[idx].where_selector_list;
                if (list.count == 1) return extractAncestorHashes(data, list.start);
                var skip_idx = list.start;
                for (0..list.count) |_| skip_idx = data[skip_idx].next_complex_selector;
                idx = skip_idx - 1;
            },
            .type, .class, .id, .not_class, .not_id, .not_type, .not_pseudo_class, .pseudo_class, .pseudo_element => idx += 1,
            .attribute => |op_case| {
                idx += 1;
                if (op_case != null) idx += 1;
            },
        }
    }
    return null;
}

fn testCandidates(
    ctx: *RunContext,
    candidates: []const SelectorEntry,
    data: []const selectors.Data,
    env: *const Environment,
    node: Environment.NodeId,
    allocator: Allocator,
    bloom: *const AncestorBloom,
) !void {
    for (candidates) |entry| {
        if (entry.fast_match) {
            switch (entry.pseudo) {
                .none => try ctx.appendDeclBlock(node, entry.block, entry.importance),
                .before => try ctx.appendPseudoDeclBlock(node, .before, entry.block, entry.importance),
                .after => try ctx.appendPseudoDeclBlock(node, .after, entry.block, entry.importance),
                .unrecognized => {},
            }
            continue;
        }
        if (entry.ancestor_hashes) |ah| {
            if (!ah.mightMatchBloom(bloom)) continue;
        }
        if (zss.selectors.matchElement(data, entry.selector, env, node, allocator)) {
            switch (entry.pseudo) {
                .none => try ctx.appendDeclBlock(node, entry.block, entry.importance),
                .before => try ctx.appendPseudoDeclBlock(node, .before, entry.block, entry.importance),
                .after => try ctx.appendPseudoDeclBlock(node, .after, entry.block, entry.importance),
                .unrecognized => {},
            }
        }
    }
}

const RunContext = struct {
    arena: std.heap.ArenaAllocator,
    element_to_decl_block_list: std.AutoArrayHashMapUnmanaged(Environment.NodeId, std.ArrayListUnmanaged(BlockImportance)) = .empty,
    /// Pseudo-element declaration blocks, collected during cascade and applied at the end.
    pseudo_to_decl_block_list: std.AutoArrayHashMapUnmanaged(Database.PseudoKey, std.ArrayListUnmanaged(BlockImportance)) = .empty,
    cascade_node_stack: zss.Stack([]const *const Node) = .{},
    document_node_stack: zss.Stack(?Environment.NodeId) = .{},

    const BlockImportance = struct {
        block: Block,
        importance: Importance,
    };

    fn appendDeclBlock(ctx: *RunContext, node: zss.Environment.NodeId, block: Block, importance: Importance) !void {
        const allocator = ctx.arena.allocator();
        const gop = try ctx.element_to_decl_block_list.getOrPut(allocator, node);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(allocator, .{ .block = block, .importance = importance });
    }

    fn appendPseudoDeclBlock(ctx: *RunContext, node: zss.Environment.NodeId, pseudo: selectors.PseudoElement, block: Block, importance: Importance) !void {
        const allocator = ctx.arena.allocator();
        const key = Database.PseudoKey{ .node = node, .pseudo = pseudo };
        const gop = try ctx.pseudo_to_decl_block_list.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(allocator, .{ .block = block, .importance = importance });
    }
};

/// Runs the CSS cascade.
pub fn run(list: *const List, env: *Environment, temp_allocator: Allocator) !void {
    var ctx = RunContext{ .arena = .init(temp_allocator) };
    defer ctx.arena.deinit();

    // CSS Cascading §6.1 cascade order (highest to lowest priority):
    // 1. UA important
    // 2. User important
    // 3. Author important  ─┐ merged: one DOM walk per source
    // 4. Author normal     ─┘
    // 5. User normal
    // 6. UA normal
    try traverseList(&ctx, list, env, .user_agent, .important);
    try traverseList(&ctx, list, env, .user, .important);
    try traverseListMerged(&ctx, list, env, .author);
    try traverseList(&ctx, list, env, .user, .normal);
    try traverseList(&ctx, list, env, .user_agent, .normal);

    var element_iterator = ctx.element_to_decl_block_list.iterator();
    while (element_iterator.next()) |entry| {
        const node = entry.key_ptr.*;
        const cascaded_values = try env.cascade_db.addStorage(env.allocator, node);
        cascaded_values.reset();
        
        // Inherit custom properties from parent
        if (node.parent(env)) |parent_node| {
            if (env.cascade_db.getStorage(parent_node)) |parent_storage| {
                // Copy parent's custom properties
                var prop_it = parent_storage.custom_properties.iterator();
                while (prop_it.next()) |prop_entry| {
                    try cascaded_values.custom_properties.put(env.allocator, prop_entry.key_ptr.*, prop_entry.value_ptr.*);
                }
            }
        }
        for (entry.value_ptr.*.items) |item| {
            try cascaded_values.applyDeclBlock(&env.cascade_db, env.allocator, &env.decls, item.block, item.importance);
        }
    }

    // Apply pseudo-element cascaded values
    var pseudo_iterator = ctx.pseudo_to_decl_block_list.iterator();
    while (pseudo_iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const cascaded_values = try env.cascade_db.addPseudoStorage(env.allocator, key.node, key.pseudo);
        cascaded_values.reset();
        for (entry.value_ptr.*.items) |item| {
            try cascaded_values.applyDeclBlock(&env.cascade_db, env.allocator, &env.decls, item.block, item.importance);
        }
    }
}

fn traverseList(ctx: *RunContext, list: *const List, env: *const Environment, origin: Origin, importance: Importance) !void {
    const node_list = switch (origin) {
        .user => list.user,
        .author => list.author,
        .user_agent => list.user_agent,
    };
    const allocator = ctx.arena.allocator();

    assert(ctx.cascade_node_stack.top == null);
    ctx.cascade_node_stack.top = node_list;
    while (ctx.cascade_node_stack.top) |*top| {
        if (top.*.len == 0) {
            _ = ctx.cascade_node_stack.pop();
            continue;
        }
        const node: *const Node = top.*[0];
        top.* = top.*[1..];

        switch (node.*) {
            .inner => |inner| try ctx.cascade_node_stack.push(allocator, inner),
            .leaf => |source| try applySource(ctx, source, env, importance),
        }
    }
}

fn traverseListMerged(ctx: *RunContext, list: *const List, env: *const Environment, origin: Origin) !void {
    const node_list = switch (origin) {
        .user => list.user,
        .author => list.author,
        .user_agent => list.user_agent,
    };
    const allocator = ctx.arena.allocator();

    assert(ctx.cascade_node_stack.top == null);
    ctx.cascade_node_stack.top = node_list;
    while (ctx.cascade_node_stack.top) |*top| {
        if (top.*.len == 0) {
            _ = ctx.cascade_node_stack.pop();
            continue;
        }
        const node: *const Node = top.*[0];
        top.* = top.*[1..];

        switch (node.*) {
            .inner => |inner| try ctx.cascade_node_stack.push(allocator, inner),
            .leaf => |source| try applySourceMerged(ctx, source, env),
        }
    }
}

fn applySource(ctx: *RunContext, source: *const Source, env: *const Environment, importance: Importance) !void {
    const selector_list = switch (importance) {
        .important => source.selectors_important,
        .normal => source.selectors_normal,
    };
    const style_attrs = switch (importance) {
        .important => source.style_attrs_important,
        .normal => source.style_attrs_normal,
    };
    if (selector_list.len == 0 and style_attrs.count() == 0 and
        (importance != .normal or source.presentational_attrs_normal.count() == 0))
        return;
    const importances: []const Importance = &.{importance};
    try applySourceImpl(ctx, source, env, importances);
}

fn applySourceMerged(ctx: *RunContext, source: *const Source, env: *const Environment) !void {
    const importances: []const Importance = &.{ .important, .normal };
    try applySourceImpl(ctx, source, env, importances);
}

fn applySourceImpl(ctx: *RunContext, source: *const Source, env: *const Environment, importances: []const Importance) !void {
    for (importances) |importance| {
        const style_attrs = switch (importance) {
            .important => source.style_attrs_important,
            .normal => source.style_attrs_normal,
        };
        var it = style_attrs.iterator();
        while (it.next()) |entry| {
            const node = entry.key_ptr.*;
            switch (env.getNodeProperty(.category, node)) {
                .text => unreachable,
                .element => {},
            }
            const block = entry.value_ptr.*;
            try ctx.appendDeclBlock(node, block, importance);
        }
    }

    const allocator = ctx.arena.allocator();
    const data = source.selector_data.items;

    var id_index = std.AutoArrayHashMapUnmanaged(Environment.IdName, std.ArrayListUnmanaged(SelectorEntry)).empty;
    var class_index = std.AutoArrayHashMapUnmanaged(Environment.ClassName, std.ArrayListUnmanaged(SelectorEntry)).empty;
    var type_index = std.AutoArrayHashMapUnmanaged(Environment.TypeName, std.ArrayListUnmanaged(SelectorEntry)).empty;
    var universal = std.ArrayListUnmanaged(SelectorEntry){};

    for (importances) |importance| {
        const selector_list = switch (importance) {
            .important => source.selectors_important,
            .normal => source.selectors_normal,
        };
        const sel_items = selector_list.items(.selector);
        const blk_items = selector_list.items(.block);

        for (sel_items, blk_items, 0..) |selector, block, i| {
            if (!canMatchStatic(data, selector)) continue;
            const pe = selectors.extractPseudoElement(data, selector);
            const key = extractRightmostKey(data, selector);
            const entry = SelectorEntry{
                .selector = selector,
                .block = block,
                .source_order = @intCast(i),
                .pseudo = if (pe) |p| switch (p) {
                    .before => .before,
                    .after => .after,
                    .unrecognized => .unrecognized,
                } else .none,
                .fast_match = isFastMatch(data, selector, key),
                .importance = importance,
                .ancestor_hashes = extractAncestorHashes(data, selector),
            };
            switch (key) {
                .id => |id| {
                    const gop = try id_index.getOrPut(allocator, id);
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    try gop.value_ptr.append(allocator, entry);
                },
                .class => |cls| {
                    const gop = try class_index.getOrPut(allocator, cls);
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    try gop.value_ptr.append(allocator, entry);
                },
                .type_name => |tn| {
                    const gop = try type_index.getOrPut(allocator, tn);
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    try gop.value_ptr.append(allocator, entry);
                },
                .universal => try universal.append(allocator, entry),
            }
        }
    }

    var merged = std.ArrayListUnmanaged(SelectorEntry){};
    var bloom = AncestorBloom{};
    var ancestor_node_stack = std.ArrayListUnmanaged(Environment.NodeId){};
    assert(ctx.document_node_stack.top == null);
    ctx.document_node_stack.top = env.root_node;
    while (ctx.document_node_stack.top) |*top| {
        const node = top.* orelse {
            _ = ctx.document_node_stack.pop();
            if (ancestor_node_stack.pop()) |parent| {
                bloom.removeNode(env, parent);
            }
            continue;
        };
        top.* = node.nextSibling(env);
        switch (env.getNodeProperty(.category, node)) {
            .text => continue,
            .element => {},
        }
        if (node.firstChild(env)) |first_child| {
            bloom.addNode(env, node);
            try ancestor_node_stack.append(allocator, node);
            try ctx.document_node_stack.push(allocator, first_child);
        }

        merged.clearRetainingCapacity();
        const element_type = env.getNodeProperty(.type, node);
        if (type_index.get(element_type.name)) |candidates| {
            try merged.appendSlice(allocator, candidates.items);
        }
        if (env.nodes_to_classes.get(node)) |classes| {
            for (classes) |cls| {
                if (class_index.get(cls)) |candidates| {
                    try merged.appendSlice(allocator, candidates.items);
                }
            }
        }
        if (env.nodes_to_ids.get(node)) |id| {
            if (id_index.get(id)) |candidates| {
                try merged.appendSlice(allocator, candidates.items);
            }
        }
        try merged.appendSlice(allocator, universal.items);

        std.mem.sortUnstable(SelectorEntry, merged.items, {}, struct {
            fn lessThan(_: void, a: SelectorEntry, b: SelectorEntry) bool {
                if (a.importance != b.importance)
                    return @intFromEnum(a.importance) > @intFromEnum(b.importance);
                return a.source_order < b.source_order;
            }
        }.lessThan);

        try testCandidates(ctx, merged.items, data, env, node, allocator, &bloom);
    }

    for (importances) |importance| {
        if (importance == .normal) {
            var it = source.presentational_attrs_normal.iterator();
            while (it.next()) |entry| {
                const node = entry.key_ptr.*;
                switch (env.getNodeProperty(.category, node)) {
                    .text => unreachable,
                    .element => {},
                }
                const block = entry.value_ptr.*;
                try ctx.appendDeclBlock(node, block, importance);
            }
        }
    }
}
