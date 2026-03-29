const Environment = @This();

const zss = @import("zss.zig");
const cascade = zss.cascade;
const syntax = zss.syntax;
const Ast = syntax.Ast;
const Declarations = zss.Declarations;
const SourceCode = syntax.SourceCode;
const Stylesheet = zss.Stylesheet;
const Utf8StringInterner = zss.Utf8StringInterner;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

allocator: Allocator,

type_names: Utf8StringInterner,
attribute_names: Utf8StringInterner,
id_names: Utf8StringInterner,
class_names: Utf8StringInterner,
attribute_values_insensitive: Utf8StringInterner,
attribute_values_sensitive: Utf8StringInterner,
attribute_values_sensitive_to_insensitive: std.ArrayList(usize),
namespaces: Namespaces,
texts: Texts,
case_options: CaseOptions,
id_class_sensitivity: Utf8StringInterner.Case,

decls: Declarations,
cascade_db: cascade.Database,

document_tree_vtable: *const DocumentTreeVtable,
next_node_group: ?std.meta.Tag(NodeGroup),
root_node: ?NodeId,
node_properties: NodeProperties,
ids_to_nodes: std.AutoHashMapUnmanaged(IdName, NodeId),

nodes_to_classes: std.AutoHashMapUnmanaged(NodeId, []const ClassName) = .empty,
nodes_to_attributes: std.AutoHashMapUnmanaged(NodeId, []const NodeAttribute) = .empty,
next_url_id: ?UrlId.Int,
urls_to_images: std.AutoArrayHashMapUnmanaged(UrlId, zss.Images.Handle),


/// Viewport dimensions in CSS pixels, used for @media query evaluation.
/// Set to 0 to disable media query filtering (all @media blocks included).
viewport_width_px: u32 = 0,
viewport_height_px: u32 = 0,
testing: Testing,

pub const CaseOptions = struct {
    type_names: Utf8StringInterner.Case,
    attribute_names: Utf8StringInterner.Case,
    attribute_values: Utf8StringInterner.Case,

    pub const all_insensitive: CaseOptions = .{
        .type_names = .insensitive,
        .attribute_names = .insensitive,
        .attribute_values = .insensitive,
    };
};

/// Corresponds to the DOM concept of a [document's mode](https://dom.spec.whatwg.org/#concept-document-quirks).
pub const DomQuirksMode = enum {
    no_quirks,
    quirks,
    limited_quirks,
};

pub fn init(
    allocator: Allocator,
    document_tree_vtable: *const DocumentTreeVtable,
    case_options: CaseOptions,
    /// If the document is not a DOM document, set to `no_quirks`.
    dom_quirks_mode: DomQuirksMode,
) Environment {
    const id_class_sensitivity: Utf8StringInterner.Case = switch (dom_quirks_mode) {
        .no_quirks, .limited_quirks => .sensitive,
        .quirks => .insensitive,
    };

    return Environment{
        .allocator = allocator,

        .type_names = .init(.{
            .max_size = TypeName.max_unique_values,
            .case = case_options.type_names,
        }),
        .attribute_names = .init(.{
            .max_size = AttributeName.max_unique_values,
            .case = case_options.attribute_names,
        }),
        .id_names = .init(.{
            .max_size = IdName.max_unique_values,
            .case = id_class_sensitivity,
        }),
        .class_names = .init(.{
            .max_size = ClassName.max_unique_values,
            .case = id_class_sensitivity,
        }),
        .attribute_values_insensitive = .init(.{
            .max_size = AttributeValue.max_unique_values,
            .case = .insensitive,
        }),
        .attribute_values_sensitive = .init(.{
            .max_size = AttributeValue.max_unique_values,
            .case = .sensitive,
        }),
        .attribute_values_sensitive_to_insensitive = .empty,
        .namespaces = .{},
        .texts = .{},
        .case_options = case_options,
        .id_class_sensitivity = id_class_sensitivity,

        .decls = .{},
        .cascade_db = .{},

        .document_tree_vtable = document_tree_vtable,
        .next_node_group = 0,
        .root_node = null,
        .node_properties = .{},
        .ids_to_nodes = .empty,
        .nodes_to_classes = .empty,

        .next_url_id = 0,
        .urls_to_images = .empty,

        .testing = .{},
    };
}

pub fn deinit(env: *Environment) void {
    env.type_names.deinit(env.allocator);
    env.attribute_names.deinit(env.allocator);
    env.id_names.deinit(env.allocator);
    env.class_names.deinit(env.allocator);
    env.attribute_values_insensitive.deinit(env.allocator);
    env.attribute_values_sensitive.deinit(env.allocator);
    env.attribute_values_sensitive_to_insensitive.deinit(env.allocator);
    env.namespaces.deinit(env.allocator);
    env.texts.deinit(env.allocator);

    env.decls.deinit(env.allocator);
    env.cascade_db.deinit(env.allocator);

    env.node_properties.deinit(env.allocator);
    env.ids_to_nodes.deinit(env.allocator);
    // Free the class name slices stored in nodes_to_classes, then the map itself.
    {
        var it = env.nodes_to_classes.valueIterator();
        while (it.next()) |val| {
            env.allocator.free(val.*);
        }
        env.nodes_to_classes.deinit(env.allocator);
    }

    env.urls_to_images.deinit(env.allocator);
}

pub const Namespaces = struct {
    // TODO: Consider using zss.Utf8StringInterner
    map: std.StringArrayHashMapUnmanaged(void) = .empty,

    /// A handle to an interned namespace string.
    pub const Id = enum(u8) {
        /// Represents the null namespace, a.k.a. no namespace.
        none = max_unique_values,
        /// Not a valid namespace id. This value is used in selectors to represent any namespace.
        any = max_unique_values + 1,
        _,

        pub const max_unique_values = (1 << 8) - 2;
    };

    pub fn deinit(namespaces: *Namespaces, allocator: Allocator) void {
        for (namespaces.map.keys()) |key| {
            allocator.free(key);
        }
        namespaces.map.deinit(allocator);
    }
};

pub const NamespaceLocation = union(enum) {
    string_token: SourceCode.Location,
    url_token: SourceCode.Location,
};

pub fn addNamespaceFromToken(env: *Environment, ns_location: NamespaceLocation, source_code: SourceCode) !Namespaces.Id {
    try env.namespaces.map.ensureUnusedCapacity(env.allocator, 1);
    const namespace = switch (ns_location) {
        .string_token => |location| try source_code.copyString(location, .{ .allocator = env.allocator }),
        .url_token => |location| try source_code.copyUrl(location, .{ .allocator = env.allocator }),
    };
    if (namespace.len == 0) {
        env.allocator.free(namespace);
        // TODO: Does an empty URL represent the null namespace?
        return .none;
    }
    const gop_result = env.namespaces.map.getOrPutAssumeCapacity(namespace);
    if (gop_result.index >= @intFromEnum(Namespaces.Id.none)) {
        env.allocator.free(namespace);
        env.namespaces.map.orderedRemoveAt(gop_result.index);
        return error.MaxNamespaceLimitReached;
    }
    if (gop_result.found_existing) {
        env.allocator.free(namespace);
    }
    return @enumFromInt(gop_result.index);
}

/// A handle to an interned type name string.
pub const TypeName = enum(u20) {
    /// A type name that compares as not equal to any other type name (including other anonymous type names).
    anonymous = max_unique_values,
    /// Not a valid type name. This value is used in selectors to represent the '*' type name selector.
    any = max_unique_values + 1,
    _,

    pub const max_unique_values = (1 << 20) - 2;
};

pub fn addTypeName(
    env: *Environment,
    /// The location of an <ident-token>.
    identifier: SourceCode.Location,
    source_code: SourceCode,
) !TypeName {
    const index = switch (env.case_options.type_names) {
        inline else => |case| try env.type_names.addFromIdentToken(case, env.allocator, identifier, source_code),
    };
    const type_name: TypeName = @enumFromInt(index);
    assert(type_name != .anonymous);
    assert(type_name != .any);
    return type_name;
}

/// A handle to an interned attribute name string.
pub const AttributeName = enum(u20) {
    /// An attribute name that compares as not equal to any other attribute name (including other anonymous attribute names).
    anonymous = max_unique_values,
    _,

    pub const max_unique_values = (1 << 20) - 1;
};

pub fn addAttributeName(
    env: *Environment,
    /// The location of an <ident-token>.
    identifier: SourceCode.Location,
    source_code: SourceCode,
) !AttributeName {
    const index = switch (env.case_options.type_names) {
        inline else => |case| try env.attribute_names.addFromIdentToken(case, env.allocator, identifier, source_code),
    };
    const attribute_name: AttributeName = @enumFromInt(index);
    assert(attribute_name != .anonymous);
    return attribute_name;
}

/// A handle to an interned ID string.
pub const IdName = enum(u32) {
    _,
    pub const max_unique_values = 1 << 32;
};

pub fn addIdName(
    env: *Environment,
    /// The location of an ID <hash-token>.
    hash_id: SourceCode.Location,
    source_code: SourceCode,
) !IdName {
    const index = switch (env.id_class_sensitivity) {
        inline else => |case| try env.id_names.addFromHashIdToken(case, env.allocator, hash_id, source_code),
    };
    return @enumFromInt(index);
}

/// A handle to an interned class name string.
pub const ClassName = enum(u32) {
    _,
    pub const max_unique_values = 1 << 32;
};

pub fn addClassName(
    env: *Environment,
    /// The location of an <ident-token>.
    identifier: SourceCode.Location,
    source_code: SourceCode,
) !ClassName {
    const index = switch (env.id_class_sensitivity) {
        inline else => |case| try env.class_names.addFromIdentToken(case, env.allocator, identifier, source_code),
    };
    return @enumFromInt(index);
}

pub const AttributeValue = enum(u32) {
    _,
    const max_unique_values = 1 << 32;
};

pub fn addAttributeValueFromIdentToken(
    env: *Environment,
    /// The location of an <ident-token>.
    identifier: SourceCode.Location,
    source_code: SourceCode,
) !AttributeValue {
    return env.addAttributeValueFromToken(Utf8StringInterner.addFromIdentToken, identifier, source_code);
}

pub fn addAttributeValueFromStringToken(
    env: *Environment,
    /// The location of a <string-token>.
    string: SourceCode.Location,
    source_code: SourceCode,
) !AttributeValue {
    return env.addAttributeValueFromToken(Utf8StringInterner.addFromStringToken, string, source_code);
}

fn addAttributeValueFromToken(
    env: *Environment,
    comptime addFromToken: anytype,
    location: SourceCode.Location,
    source_code: SourceCode,
) !AttributeValue {
    switch (env.case_options.attribute_values) {
        .insensitive => {
            const index = try addFromToken(&env.attribute_values_insensitive, .insensitive, env.allocator, location, source_code);
            return @enumFromInt(index);
        },
        .sensitive => {
            const index = try addFromToken(&env.attribute_values_sensitive, .sensitive, env.allocator, location, source_code);
            if (index == env.attribute_values_sensitive_to_insensitive.items.len) {
                const index_insensitive = try addFromToken(&env.attribute_values_insensitive, .insensitive, env.allocator, location, source_code);
                try env.attribute_values_sensitive_to_insensitive.append(env.allocator, index_insensitive);
            }
            return @enumFromInt(index);
        },
    }
}

pub fn eqlAttributeValues(env: *const Environment, case: Utf8StringInterner.Case, lhs: AttributeValue, rhs: AttributeValue) bool {
    switch (env.case_options.attribute_values) {
        .insensitive => return lhs == rhs,
        .sensitive => {
            switch (case) {
                .insensitive => {
                    const lhs_insensitive = env.attribute_values_sensitive_to_insensitive.items[@intFromEnum(lhs)];
                    const rhs_insensitive = env.attribute_values_sensitive_to_insensitive.items[@intFromEnum(rhs)];
                    return lhs_insensitive == rhs_insensitive;
                },
                .sensitive => return lhs == rhs,
            }
        },
    }
}

/// Helper to extract attribute value string for substring matching.
/// Allocates a temporary buffer — caller must free the returned slice.
pub fn getAttributeValueString(env: *const Environment, allocator: std.mem.Allocator, value: AttributeValue, case: Utf8StringInterner.Case) ![]u8 {
    const interner = switch (env.case_options.attribute_values) {
        .insensitive => &env.attribute_values_insensitive,
        .sensitive => switch (case) {
            .sensitive => &env.attribute_values_sensitive,
            .insensitive => &env.attribute_values_insensitive,
        },
    };
    
    const index = @intFromEnum(value);
    const range_entry = interner.indexer.entries.items(.value)[index];
    const range = range_entry;
    
    // Collect string from segmented storage into a contiguous buffer
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, range.len);
    
    var it = interner.string.iterator(range.position, range.len);
    while (it.next()) |segment| {
        result.appendSliceAssumeCapacity(segment);
    }
    
    return try result.toOwnedSlice(allocator);
}

pub const Texts = struct {
    list: std.ArrayListUnmanaged([]const u8) = .empty,
    arena: std.heap.ArenaAllocator.State = .{},

    pub fn deinit(texts: *Texts, allocator: Allocator) void {
        texts.list.deinit(allocator);
        var arena = texts.arena.promote(allocator);
        defer texts.arena = arena.state;
        arena.deinit();
    }
};

pub const TextId = enum(u32) {
    _,
    pub const empty_string: TextId = @enumFromInt(0);
};

pub fn addTextFromStringToken(env: *Environment, string: SourceCode.Location, source_code: SourceCode) !TextId {
    var iterator = source_code.stringTokenIterator(string);
    if (iterator.next() == null) return .empty_string;
    const id = std.math.cast(std.meta.Tag(TextId), try std.math.add(usize, 1, env.texts.list.items.len)) orelse return error.OutOfTexts;

    try env.texts.list.ensureUnusedCapacity(env.allocator, 1);
    var arena = env.texts.arena.promote(env.allocator);
    defer env.texts.arena = arena.state;
    env.texts.list.appendAssumeCapacity(try source_code.copyString(string, .{ .allocator = arena.allocator() })); // TODO: Arena allocation wastes memory here
    return @enumFromInt(id);
}

/// `string` must be UTF-8 encoded.
pub fn addTextFromString(env: *Environment, string: []const u8) !TextId {
    if (string.len == 0) return .empty_string;
    const id = std.math.cast(std.meta.Tag(TextId), try std.math.add(usize, 1, env.texts.list.items.len)) orelse return error.OutOfTexts;

    try env.texts.list.ensureUnusedCapacity(env.allocator, 1);
    var arena = env.texts.arena.promote(env.allocator);
    defer env.texts.arena = arena.state;
    env.texts.list.appendAssumeCapacity(try arena.allocator().dupe(u8, string));
    return @enumFromInt(id);
}

pub fn getText(env: *const Environment, id: TextId) []const u8 {
    const int = @intFromEnum(id);
    if (int == 0) return "";
    return env.texts.list.items[int - 1];
}

/// A unique identifier for each URL.
pub const UrlId = enum(u16) {
    _,
    pub const Int = std.meta.Tag(@This());
};

/// Create a new URL value.
pub fn addUrl(env: *Environment) !UrlId {
    const int = if (env.next_url_id) |*int| int else return error.OutOfUrls;
    defer env.next_url_id = std.math.add(UrlId.Int, int.*, 1) catch null;
    return @enumFromInt(int.*);
}

pub fn linkUrlToImage(env: *Environment, url: UrlId, image: zss.Images.Handle) !void {
    try env.urls_to_images.put(env.allocator, url, image);
}

pub const NodeGroup = enum(usize) { _ };

pub fn addNodeGroup(env: *Environment) !NodeGroup {
    const int = if (env.next_node_group) |*int| int else return error.OutOfNodeGroups;
    defer env.next_node_group = std.math.add(std.meta.Tag(NodeGroup), int.*, 1) catch null;
    return @enumFromInt(int.*);
}

pub const NodeRelative = enum {
    parent,
    previous_sibling,
    next_sibling,
    first_child,
    last_child,
};

pub const DocumentTreeVtable = struct {
    // TODO: Make these functions "restricted function types"
    //       https://github.com/ziglang/zig/issues/23367

    /// Returns the node that has the relationship to `node` corresponding to `relative`, or
    /// `null` if no such node exists.
    nodeRelative: *const fn (env: *const Environment, node: NodeId, relative: NodeRelative) ?NodeId,

    pub const empty_document: DocumentTreeVtable = .{
        .nodeRelative = &empty_document_fns.nodeRelative,
    };

    const empty_document_fns = struct {
        fn nodeRelative(_: *const Environment, _: NodeId, _: NodeRelative) ?NodeId {
            unreachable;
        }
    };
};

// TODO: Make this a normal struct
pub const NodeId = packed struct {
    group: NodeGroup,
    value: usize,
    // TODO: generational nodes?

    pub fn parent(node: NodeId, env: *const Environment) ?NodeId {
        return env.document_tree_vtable.nodeRelative(env, node, .parent);
    }

    pub fn previousSibling(node: NodeId, env: *const Environment) ?NodeId {
        return env.document_tree_vtable.nodeRelative(env, node, .previous_sibling);
    }

    pub fn nextSibling(node: NodeId, env: *const Environment) ?NodeId {
        return env.document_tree_vtable.nodeRelative(env, node, .next_sibling);
    }

    pub fn firstChild(node: NodeId, env: *const Environment) ?NodeId {
        return env.document_tree_vtable.nodeRelative(env, node, .first_child);
    }

    pub fn lastChild(node: NodeId, env: *const Environment) ?NodeId {
        return env.document_tree_vtable.nodeRelative(env, node, .last_child);
    }
};

// TODO: Consider having a category for uninitialized nodes.
pub const NodeCategory = enum { element, text };

pub const ElementType = packed struct {
    namespace: Namespaces.Id,
    name: TypeName,
};

pub const ElementAttribute = packed struct {
    namespace: Namespaces.Id,
    name: AttributeName,
};

/// A DOM node's attribute: interned name paired with interned value.
/// Used for CSS attribute selector matching ([attr], [attr=val], etc.).
pub const NodeAttribute = struct {
    name: AttributeName,
    value: AttributeValue,
};

pub const NodeProperty = struct {
    category: NodeCategory = .text,
    type: ElementType = .{ .namespace = .none, .name = .anonymous },
    text: TextId = .empty_string,
    colspan: u8 = 1,
    explicit_width_px: u16 = 0, // HTML width attr in px, 0 = auto
};

const NodeProperties = struct {
    // TODO: Better memory management

    map: std.AutoHashMapUnmanaged(NodeId, NodeProperty) = .empty,
    /// Only used to store cascaded values.
    arena: std.heap.ArenaAllocator.State = .{},

    fn deinit(np: *NodeProperties, allocator: Allocator) void {
        np.map.deinit(allocator);
        np.arena.promote(allocator).deinit();
    }

    fn getOrPutNode(np: *NodeProperties, allocator: Allocator, node: NodeId) !*NodeProperty {
        const gop = try np.map.getOrPut(allocator, node);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }
};

pub fn setNodeProperty(
    env: *Environment,
    comptime field: std.meta.FieldEnum(NodeProperty),
    node: NodeId,
    value: @FieldType(NodeProperty, @tagName(field)),
) !void {
    const value_ptr = try env.node_properties.getOrPutNode(env.allocator, node);
    @field(value_ptr, @tagName(field)) = value;
}

pub fn getNodeProperty(
    env: *const Environment,
    comptime field: std.meta.FieldEnum(NodeProperty),
    node: NodeId,
) @FieldType(NodeProperty, @tagName(field)) {
    const value_ptr: *const NodeProperty = env.node_properties.map.getPtr(node) orelse &.{};
    return @field(value_ptr, @tagName(field));
}

pub fn getNodePropertyPtr(
    env: *Environment,
    comptime field: std.meta.FieldEnum(NodeProperty),
    node: NodeId,
) !*@FieldType(NodeProperty, @tagName(field)) {
    const value_ptr = try env.node_properties.getOrPutNode(env.allocator, node);
    return &@field(value_ptr, @tagName(field));
}

/// Returns `error.IdAlreadyExists` if `id` was already registered.
pub fn registerId(env: *Environment, id: IdName, node: NodeId) !void {
    const gop = try env.ids_to_nodes.getOrPut(env.allocator, id);
    // TODO: If `gop.found_existing == true`, the existing element may have been destroyed, so consider allowing the Id to be reused.
    if (gop.found_existing and gop.value_ptr.* != node) return error.IdAlreadyExists;
    gop.value_ptr.* = node;
}

pub fn getElementById(env: *const Environment, id: IdName) ?NodeId {
    // TODO: Even if an element was returned, it could have been destroyed.
    return env.ids_to_nodes.get(id);
}

/// Store the class names associated with a DOM node.
/// The caller must pass an allocator-owned slice; ownership transfers to the Environment.
pub fn registerClasses(env: *Environment, node: NodeId, class_names_slice: []const ClassName) !void {
    try env.nodes_to_classes.put(env.allocator, node, class_names_slice);
}

/// Returns true if the given node has the specified class name.
pub fn nodeHasClass(env: *const Environment, node: NodeId, class_name: ClassName) bool {
    const classes = env.nodes_to_classes.get(node) orelse return false;
    for (classes) |cn| {
        if (cn == class_name) return true;
    }
    return false;
}

/// Intern a class name from a raw UTF-8 string (e.g. from a DOM class attribute).
/// Uses the same case sensitivity as the class_names interner was initialized with.
pub fn addClassNameFromString(env: *Environment, string: []const u8) !ClassName {
    const index = switch (env.id_class_sensitivity) {
        inline else => |case| try env.class_names.addFromString(case, env.allocator, string),
    };
    return @enumFromInt(index);
}

/// Intern an ID name from a raw UTF-8 string (e.g. from a DOM id attribute).
pub fn addIdNameFromString(env: *Environment, string: []const u8) !IdName {
    const index = switch (env.id_class_sensitivity) {
        inline else => |case| try env.id_names.addFromString(case, env.allocator, string),
    };
    return @enumFromInt(index);
}

/// Intern an attribute name from a raw UTF-8 string (e.g. from a DOM attribute name).
pub fn addAttributeNameFromString(env: *Environment, string: []const u8) !AttributeName {
    const index = switch (env.case_options.type_names) {
        inline else => |case| try env.attribute_names.addFromString(case, env.allocator, string),
    };
    return @enumFromInt(index);
}

/// Intern an attribute value from a raw UTF-8 string.
/// Uses sensitive interning; the case-insensitive variant is populated automatically.
pub fn addAttributeValueFromString(env: *Environment, string: []const u8) !AttributeValue {
    switch (env.case_options.attribute_values) {
        .insensitive => {
            const index = try env.attribute_values_insensitive.addFromString(.insensitive, env.allocator, string);
            return @enumFromInt(index);
        },
        .sensitive => {
            const index = try env.attribute_values_sensitive.addFromString(.sensitive, env.allocator, string);
            if (index == env.attribute_values_sensitive_to_insensitive.items.len) {
                const index_insensitive = try env.attribute_values_insensitive.addFromString(.insensitive, env.allocator, string);
                try env.attribute_values_sensitive_to_insensitive.append(env.allocator, index_insensitive);
            }
            return @enumFromInt(index);
        },
    }
}

/// Store the attributes associated with a DOM node.
/// The caller must pass an allocator-owned slice; ownership transfers to the Environment.
pub fn registerAttributes(env: *Environment, node: NodeId, attrs: []const NodeAttribute) !void {
    try env.nodes_to_attributes.put(env.allocator, node, attrs);
}

/// Return the value of a named attribute on a node, or null if the attribute is absent.
pub fn nodeGetAttributeValue(env: *const Environment, node: NodeId, name: AttributeName) ?AttributeValue {
    const attrs = env.nodes_to_attributes.get(node) orelse return null;
    for (attrs) |attr| {
        if (attr.name == name) return attr.value;
    }
    return null;
}

/// Return true if the node has an attribute with the given name (any value).
pub fn nodeHasAttribute(env: *const Environment, node: NodeId, name: AttributeName) bool {
    return env.nodeGetAttributeValue(node, name) != null;
}

/// Return true if the node has an attribute whose interned name matches the given string.
/// Used by pseudo-class matchers (:enabled, :disabled, :checked) that need to check
/// for specific attribute names without interning (const Environment constraint).
/// Assumes name_str is lowercase (HTML attribute names from Lexbor are always lowercase).
pub fn nodeHasAttributeByName(env: *const Environment, node: NodeId, name_str: []const u8) bool {
    const attrs = env.nodes_to_attributes.get(node) orelse return false;
    for (attrs) |attr| {
        var it = env.attribute_names.iterator(@intFromEnum(attr.name));
        if (it.eql(name_str)) return true;
    }
    return false;
}

pub const Testing = struct {
    pub fn expectEqualTypeNames(testing: *const Testing, expected: []const u8, type_name: TypeName) !void {
        const env: *const Environment = @alignCast(@fieldParentPtr("testing", testing));
        var iterator = env.type_names.iterator(@intFromEnum(type_name));
        try std.testing.expect(iterator.eql(expected));
    }
};
