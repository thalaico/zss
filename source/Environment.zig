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
/// Opaque per-document state for `document_tree_vtable` (e.g. the host's
/// NodeId <-> DOM-node map). Set by the host after the Environment has its
/// final address; zss never reads it except to pass `env` to the vtable.
document_tree_context: ?*anyopaque = null,
next_node_group: ?std.meta.Tag(NodeGroup),
root_node: ?NodeId,
node_properties: NodeProperties,
ids_to_nodes: std.AutoHashMapUnmanaged(IdName, NodeId),
nodes_to_ids: std.AutoHashMapUnmanaged(NodeId, IdName) = .empty,

nodes_to_classes: std.AutoHashMapUnmanaged(NodeId, []const ClassName) = .empty,
nodes_to_attributes: std.AutoHashMapUnmanaged(NodeId, []const NodeAttribute) = .empty,
node_count: u32 = 0,
/// ::before / ::after pseudo-element nodes (CSS Pseudo 4 §2.6) that
/// generate a box, created after the cascade by `createPseudoNodes`. They
/// live in their own node group with node values after the document's, so
/// per-node tables index them like any node; zss owns their tree relations.
/// Only box generation visits them (`boxFirstChild` / `boxNextSibling`):
/// selectors and the document do not see them.
pseudo_group: ?NodeGroup = null,
pseudo_nodes: std.AutoHashMapUnmanaged(cascade.Database.PseudoKey, NodeId) = .empty,
pseudo_links: std.AutoHashMapUnmanaged(usize, PseudoLink) = .empty,
/// NodeId values of discarded ::before / ::after nodes and their text
/// nodes, reused by `createPseudoNodes`.
free_pseudo_values: std.ArrayListUnmanaged(usize) = .empty,
next_url_id: ?UrlId.Int,
urls_to_images: std.AutoArrayHashMapUnmanaged(UrlId, zss.Images.Handle),

/// Viewport dimensions in CSS pixels, used for @media query evaluation.
/// Set to 0 to disable media query filtering (all @media blocks included).
viewport_width_px: u32 = 0,
viewport_height_px: u32 = 0,
/// True once the host has set the viewport (a 0×0 viewport is then real —
/// an iframe sized to nothing — not "unknown"). While false, every @media
/// block is included.
viewport_configured: bool = false,
/// Lowercase names of custom @font-face registered fonts (lifetime owned by caller).
/// Used by the CSS font-family parser to recognize custom font names.
custom_font_names: []const []const u8 = &.{},
/// The distinct specified font-family lists, serialized (CSSOM), indexed by
/// `FontFamilyList` - 1 (`zss.values.types.FontFamilyList`).
font_family_lists: std.ArrayListUnmanaged([]const u8) = .empty,
font_family_list_ids: std.StringHashMapUnmanaged(u32) = .empty,
/// The math-function values (calc(), min(), ...) that did not fold to a
/// plain length or percentage at parse time.
calc: zss.values.calc.Table = .{},
/// "property:text" → the declaration block that parsing the var()-
/// substituted text gave (null: no valid declaration), shared by every
/// element and every cascade run (`zss.custom_properties`). Declaration
/// blocks are immutable once closed, so a block stays valid however often
/// the cascade re-runs. Each key is the tail of an allocation that starts
/// two bytes earlier ("x{" + key + "}").
substituted_blocks: std.StringHashMapUnmanaged(?Declarations.Block) = .empty,
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
        .nodes_to_ids = .empty,
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
    env.pseudo_nodes.deinit(env.allocator);
    env.pseudo_links.deinit(env.allocator);
    env.free_pseudo_values.deinit(env.allocator);
    env.ids_to_nodes.deinit(env.allocator);
    env.nodes_to_ids.deinit(env.allocator);
    // Free the class name slices stored in nodes_to_classes, then the map itself.
    {
        var it = env.nodes_to_classes.valueIterator();
        while (it.next()) |val| {
            env.allocator.free(val.*);
        }
        env.nodes_to_classes.deinit(env.allocator);
    }
    // Free the attribute slices stored in nodes_to_attributes, then the map itself.
    {
        var it = env.nodes_to_attributes.valueIterator();
        while (it.next()) |val| {
            env.allocator.free(val.*);
        }
        env.nodes_to_attributes.deinit(env.allocator);
    }

    env.urls_to_images.deinit(env.allocator);
    for (env.font_family_lists.items) |text| env.allocator.free(text);
    env.font_family_lists.deinit(env.allocator);
    env.font_family_list_ids.deinit(env.allocator);
    env.calc.deinit(env.allocator);
    {
        var it = env.substituted_blocks.keyIterator();
        while (it.next()) |key| {
            const start = key.ptr - 2;
            env.allocator.free(start[0 .. key.len + 3]);
        }
        env.substituted_blocks.deinit(env.allocator);
    }
}

/// The id of the serialized font-family list `text`, interning it.
pub fn internFontFamilyList(env: *Environment, text: []const u8) !zss.values.types.FontFamilyList {
    const gop = try env.font_family_list_ids.getOrPut(env.allocator, text);
    if (!gop.found_existing) {
        errdefer _ = env.font_family_list_ids.remove(text);
        const owned = try env.allocator.dupe(u8, text);
        errdefer env.allocator.free(owned);
        try env.font_family_lists.append(env.allocator, owned);
        gop.key_ptr.* = owned;
        gop.value_ptr.* = @intCast(env.font_family_lists.items.len);
    }
    return @enumFromInt(gop.value_ptr.*);
}

/// The serialized font-family list, or null for the initial value.
pub fn fontFamilyListText(env: *const Environment, list: zss.values.types.FontFamilyList) ?[]const u8 {
    if (list == .initial) return null;
    return env.font_family_lists.items[@intFromEnum(list) - 1];
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

/// True when the interned attribute value is the empty string.
pub fn attributeValueIsEmpty(env: *const Environment, value: AttributeValue) bool {
    const interner = switch (env.case_options.attribute_values) {
        .insensitive => &env.attribute_values_insensitive,
        .sensitive => &env.attribute_values_sensitive,
    };
    const range = interner.indexer.entries.items(.value)[@intFromEnum(value)];
    return range.len == 0;
}

/// Helper to extract attribute value string for substring matching.
/// Allocates a temporary buffer — caller must free the returned slice.
/// The string of `value`, ASCII-lowercased when `case` is insensitive (so
/// that callers compare insensitively with plain equality). `value` indexes
/// the interner the environment's case option interns values in.
pub fn getAttributeValueString(env: *const Environment, allocator: std.mem.Allocator, value: AttributeValue, case: Utf8StringInterner.Case) ![]u8 {
    const interner = switch (env.case_options.attribute_values) {
        .insensitive => &env.attribute_values_insensitive,
        .sensitive => &env.attribute_values_sensitive,
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
    if (case == .insensitive) {
        for (result.items) |*byte| byte.* = std.ascii.toLower(byte.*);
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

/// Element state that lives outside the content attributes and that the host
/// (the DOM) owns: HTML §4.10.5.1.15 checkedness, §4.10.10 selectedness and
/// §4.10.18.6 "actually disabled". Selector matching asks for it through
/// `DocumentTreeVtable.nodeState`, never by reading the attributes directly —
/// once a script has toggled a checkbox, the `checked` attribute only states
/// its default.
pub const ElementState = enum {
    checked,
    selected,
    disabled,
    /// Selectors 4 §13.2 user-action pseudo-classes. The host owns the
    /// pointer and focus state; a document without a user agent has none.
    hover,
    active,
    focus,
    /// `:focus-within`: the element or a descendant has focus.
    focus_within,
    /// `:focus-visible`: focus that the UA shows (keyboard focus, or focus on
    /// a text-entry control).
    focus_visible,
    /// `:target`: the element the document URL's fragment names.
    target,
    /// `:indeterminate`: checkbox indeterminate flag, radio group with no
    /// checked member, `progress` without a value.
    indeterminate,
    /// `:placeholder-shown`: a text control with a placeholder and an empty value.
    placeholder_shown,
};

pub const DocumentTreeVtable = struct {
    // TODO: Make these functions "restricted function types"
    //       https://github.com/ziglang/zig/issues/23367

    /// Returns the node that has the relationship to `node` corresponding to `relative`, or
    /// `null` if no such node exists.
    nodeRelative: *const fn (env: *const Environment, node: NodeId, relative: NodeRelative) ?NodeId,

    /// Returns whether `node` currently has the given state. Hosts without live
    /// element state use `attributeElementState`.
    nodeState: *const fn (env: *const Environment, node: NodeId, state: ElementState) bool,

    pub const empty_document: DocumentTreeVtable = .{
        .nodeRelative = &empty_document_fns.nodeRelative,
        .nodeState = &empty_document_fns.nodeState,
    };

    const empty_document_fns = struct {
        fn nodeRelative(_: *const Environment, _: NodeId, _: NodeRelative) ?NodeId {
            unreachable;
        }
        fn nodeState(_: *const Environment, _: NodeId, _: ElementState) bool {
            unreachable;
        }
    };
};

pub fn nodeState(env: *const Environment, node: NodeId, state: ElementState) bool {
    return env.document_tree_vtable.nodeState(env, node, state);
}

/// `nodeState` for a document whose element state has never diverged from its
/// content attributes (a freshly parsed document, or a host without scripts):
/// HTML's defaults. Checkedness is the `checked` attribute, selectedness the
/// `selected` attribute, and an element is actually disabled (§4.10.18.6)
/// when it carries `disabled` itself or sits inside a disabled `fieldset`,
/// unless it is inside that fieldset's first `legend` child.
pub fn attributeElementState(env: *const Environment, node: NodeId, state: ElementState) bool {
    switch (state) {
        .hover, .active, .focus, .focus_within, .focus_visible, .target => return false,
        // Without scripts nothing sets the indeterminate flag; a radio group
        // with no checked member is also indeterminate, but that needs the
        // group walk a host does from its form model.
        .indeterminate => return false,
        .placeholder_shown => {
            if (!env.nodeHasAttributeByName(node, "placeholder")) return false;
            if (env.nodeTagEql(node, "input")) {
                const v = env.nodeAttributeValueByName(node, "value") orelse return true;
                return env.attributeValueIsEmpty(v);
            }
            if (env.nodeTagEql(node, "textarea")) {
                var child = node.firstChild(env);
                while (child) |ch| : (child = ch.nextSibling(env)) {
                    switch (env.getNodeProperty(.category, ch)) {
                        .text => if (env.getText(env.getNodeProperty(.text, ch)).len > 0) return false,
                        .element => {},
                    }
                }
                return true;
            }
            return false;
        },
        .checked => return env.nodeHasAttributeByName(node, "checked"),
        .selected => return env.nodeHasAttributeByName(node, "selected"),
        .disabled => {
            if (env.nodeHasAttributeByName(node, "disabled")) return true;
            var child = node;
            var ancestor = node.parent(env);
            while (ancestor) |a| : ({
                child = a;
                ancestor = a.parent(env);
            }) {
                if (!env.nodeTagEql(a, "fieldset") or !env.nodeHasAttributeByName(a, "disabled")) continue;
                if (!(env.nodeTagEql(child, "legend") and isFirstLegendChild(env, a, child))) return true;
            }
            return false;
        },
    }
}

fn isFirstLegendChild(env: *const Environment, fieldset: NodeId, legend: NodeId) bool {
    var child = fieldset.firstChild(env);
    while (child) |c| : (child = c.nextSibling(env)) {
        if (env.nodeTagEql(c, "legend")) return c == legend;
    }
    return false;
}

pub const PseudoLink = struct {
    /// The originating element (for a pseudo-element node), or the
    /// pseudo-element (for its content text node).
    parent: NodeId,
    child: ?NodeId,
    kind: enum { before, after, text },
};

pub fn pseudoLink(env: *const Environment, node: NodeId) ?PseudoLink {
    const group = env.pseudo_group orelse return null;
    if (node.group != group) return null;
    return env.pseudo_links.get(node.value);
}

/// The ::before / ::after pseudo-element node generated for `element`, if
/// it has one (its `content` computes to something other than none).
pub fn pseudoElementNode(env: *const Environment, element: NodeId, pseudo: zss.selectors.PseudoElement) ?NodeId {
    return env.pseudo_nodes.get(.{ .node = element, .pseudo = pseudo });
}

/// Whether `node` is a ::before / ::after pseudo-element node.
pub fn isPseudoElement(env: *const Environment, node: NodeId) bool {
    const link = env.pseudoLink(node) orelse return false;
    return link.kind != .text;
}

/// The first child of `node` in the box tree's view of the document: its
/// ::before, then its children, then its ::after (CSS Pseudo 4 §2.6).
pub fn boxFirstChild(env: *const Environment, node: NodeId) ?NodeId {
    if (env.pseudoLink(node)) |link| return link.child;
    if (env.pseudo_nodes.get(.{ .node = node, .pseudo = .before })) |before| return before;
    return node.firstChild(env) orelse env.pseudo_nodes.get(.{ .node = node, .pseudo = .after });
}

/// The next sibling of `node` in the box tree's view of the document.
pub fn boxNextSibling(env: *const Environment, node: NodeId) ?NodeId {
    if (env.pseudoLink(node)) |link| return switch (link.kind) {
        .before => link.parent.firstChild(env) orelse env.pseudo_nodes.get(.{ .node = link.parent, .pseudo = .after }),
        .after, .text => null,
    };
    if (node.nextSibling(env)) |next| return next;
    if (env.pseudo_nodes.count() == 0) return null;
    const parent_node = node.parent(env) orelse return null;
    return env.pseudo_nodes.get(.{ .node = parent_node, .pseudo = .after });
}

/// Create a node for each ::before / ::after whose cascaded `content`
/// generates a box (not `normal` or `none`), with a text child holding
/// the content string, and move its cascaded values to the node. Run after
/// the cascade; idempotent across cascade runs.
pub fn createPseudoNodes(env: *Environment) !void {
    const allocator = env.allocator;
    var keys: std.ArrayListUnmanaged(cascade.Database.PseudoKey) = .empty;
    defer keys.deinit(allocator);
    var texts: std.ArrayListUnmanaged(TextId) = .empty;
    defer texts.deinit(allocator);
    {
        var it = env.cascade_db.pseudo_map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.pseudo == .unrecognized) continue;
            const declared = entry.value_ptr.getPtr(.generated_content) orelse continue;
            const text: TextId = switch (declared.content) {
                .declared => |content| switch (content) {
                    .normal, .none => continue,
                    .empty_string => .empty_string,
                    .string => |id| id,
                },
                else => continue,
            };
            try keys.append(allocator, entry.key_ptr.*);
            try texts.append(allocator, text);
        }
    }
    if (keys.items.len == 0) return;
    const group = env.pseudo_group orelse blk: {
        const g = try env.addNodeGroup();
        env.pseudo_group = g;
        break :blk g;
    };

    var new_count: u32 = 0;
    for (keys.items) |key| {
        if (!env.pseudo_nodes.contains(key)) new_count += 2;
    }
    // At most this many values beyond `node_count` (fewer when discarded
    // ones are reused).
    const total = env.node_count + new_count;
    if (env.node_properties.nodes.len < total) {
        const old = env.node_properties.nodes.len;
        env.node_properties.nodes = try allocator.realloc(env.node_properties.nodes, total);
        @memset(env.node_properties.nodes[old..], .{});
    }
    if (env.cascade_db.node_storage.len < total) {
        const old = env.cascade_db.node_storage.len;
        env.cascade_db.node_storage = try allocator.realloc(env.cascade_db.node_storage, total);
        @memset(env.cascade_db.node_storage[old..], .{});
    }

    for (keys.items, texts.items) |key, text| {
        const element: NodeId = env.pseudo_nodes.get(key) orelse blk: {
            const element: NodeId = .{ .group = group, .value = env.allocPseudoValue() };
            const text_node: NodeId = .{ .group = group, .value = env.allocPseudoValue() };
            try env.pseudo_nodes.put(allocator, key, element);
            try env.pseudo_links.put(allocator, element.value, .{
                .parent = key.node,
                .child = text_node,
                .kind = if (key.pseudo == .before) .before else .after,
            });
            try env.pseudo_links.put(allocator, text_node.value, .{ .parent = element, .child = null, .kind = .text });
            env.node_properties.nodes[@intCast(element.value)] = .{ .category = .element };
            break :blk element;
        };
        const text_node = env.pseudo_links.get(element.value).?.child.?;
        env.node_properties.nodes[@intCast(text_node.value)] = .{ .category = .text, .text = text };
        const removed = env.cascade_db.pseudo_map.fetchRemove(key).?;
        const slot = &env.cascade_db.node_storage[@intCast(element.value)];
        slot.custom_properties.deinit(allocator);
        slot.* = removed.value;
    }
}

// TODO: Make this a normal struct
pub const NodeId = packed struct {
    group: NodeGroup,
    value: usize,
    // TODO: generational nodes?

    pub fn parent(node: NodeId, env: *const Environment) ?NodeId {
        if (env.pseudoLink(node)) |link| return link.parent;
        return env.document_tree_vtable.nodeRelative(env, node, .parent);
    }

    pub fn previousSibling(node: NodeId, env: *const Environment) ?NodeId {
        if (env.pseudoLink(node) != null) return null;
        return env.document_tree_vtable.nodeRelative(env, node, .previous_sibling);
    }

    pub fn nextSibling(node: NodeId, env: *const Environment) ?NodeId {
        if (env.pseudoLink(node) != null) return null;
        return env.document_tree_vtable.nodeRelative(env, node, .next_sibling);
    }

    pub fn firstChild(node: NodeId, env: *const Environment) ?NodeId {
        if (env.pseudoLink(node)) |link| return link.child;
        return env.document_tree_vtable.nodeRelative(env, node, .first_child);
    }

    pub fn lastChild(node: NodeId, env: *const Environment) ?NodeId {
        if (env.pseudoLink(node)) |link| return link.child;
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
    /// HTML `colspan` (1..1000) and `rowspan` (0..65534; 0 = to the end of
    /// the row group), parsed by the host with the HTML rules.
    colspan: u16 = 1,
    rowspan: u16 = 1,
    aspect_ratio_w: u16 = 0,
    aspect_ratio_h: u16 = 0,
    /// The natural size of a replaced element (a loaded image) in CSS px,
    /// set by the host; 0 = none (Layout/replaced.zig).
    natural_width: f32 = 0,
    natural_height: f32 = 0,
};

const NodeProperties = struct {
    nodes: []NodeProperty = &.{},
    /// Only used to store cascaded values.
    arena: std.heap.ArenaAllocator.State = .{},

    pub fn initNodes(np: *NodeProperties, allocator: Allocator, count: u32) !void {
        np.nodes = try allocator.alloc(NodeProperty, count);
        @memset(np.nodes, .{});
    }

    fn deinit(np: *NodeProperties, allocator: Allocator) void {
        allocator.free(np.nodes);
        np.nodes = &.{};
        np.arena.promote(allocator).deinit();
    }

    fn getOrPutNode(np: *NodeProperties, _: Allocator, node: NodeId) *NodeProperty {
        return &np.nodes[@intCast(node.value)];
    }
};

pub fn setNodeProperty(
    env: *Environment,
    comptime field: std.meta.FieldEnum(NodeProperty),
    node: NodeId,
    value: @FieldType(NodeProperty, @tagName(field)),
) !void {
    const value_ptr = env.node_properties.getOrPutNode(env.allocator, node);
    @field(value_ptr, @tagName(field)) = value;
}

pub fn getNodeProperty(
    env: *const Environment,
    comptime field: std.meta.FieldEnum(NodeProperty),
    node: NodeId,
) @FieldType(NodeProperty, @tagName(field)) {
    const index: u32 = @intCast(node.value);
    if (index >= env.node_properties.nodes.len) return @field(@as(NodeProperty, .{}), @tagName(field));
    return @field(env.node_properties.nodes[index], @tagName(field));
}

pub fn getNodePropertyPtr(
    env: *Environment,
    comptime field: std.meta.FieldEnum(NodeProperty),
    node: NodeId,
) *@FieldType(NodeProperty, @tagName(field)) {
    const value_ptr = env.node_properties.getOrPutNode(env.allocator, node);
    return &@field(value_ptr, @tagName(field));
}

/// Record `node`'s ID. Several elements may carry the same ID (an ID
/// selector matches each of them); `getElementById` answers the first one
/// registered.
pub fn registerId(env: *Environment, id: IdName, node: NodeId) !void {
    try env.nodes_to_ids.put(env.allocator, node, id);
    const gop = try env.ids_to_nodes.getOrPut(env.allocator, id);
    if (!gop.found_existing) gop.value_ptr.* = node;
}

pub fn getElementById(env: *const Environment, id: IdName) ?NodeId {
    return env.ids_to_nodes.get(id);
}

/// Whether `node` carries the ID `id`.
pub fn nodeHasId(env: *const Environment, node: NodeId, id: IdName) bool {
    const own = env.nodes_to_ids.get(node) orelse return false;
    return own == id;
}

/// Make room in the per-node tables for `count` nodes: a host that keeps
/// one environment across document mutations maps new nodes after the
/// first cascade.
pub fn ensureNodeCapacity(env: *Environment, count: u32) !void {
    const nodes = &env.node_properties.nodes;
    if (nodes.len >= count) return;
    const old = nodes.len;
    nodes.* = try env.allocator.realloc(nodes.*, @max(count, old + old / 2));
    @memset(nodes.*[old..], .{});
}

/// Forget what the environment knows about `node` — its properties, ID,
/// classes and attributes — so the host can describe it again (its
/// attributes changed) or retire it (it left the document; its NodeId is
/// not reused).
pub fn clearNodeData(env: *Environment, node: NodeId) void {
    if (env.nodes_to_classes.fetchRemove(node)) |kv| env.allocator.free(kv.value);
    if (env.nodes_to_attributes.fetchRemove(node)) |kv| env.allocator.free(kv.value);
    if (env.nodes_to_ids.fetchRemove(node)) |kv| {
        if (env.ids_to_nodes.get(kv.value)) |owner| {
            if (std.meta.eql(owner, node)) _ = env.ids_to_nodes.remove(kv.value);
        }
    }
    env.resetNodeProperties(node);
}

/// Reset `node`'s `NodeProperty` slot to the defaults.
pub fn resetNodeProperties(env: *Environment, node: NodeId) void {
    const index: usize = @intCast(node.value);
    if (index < env.node_properties.nodes.len) env.node_properties.nodes[index] = .{};
}

/// Remove every ::before / ::after node `createPseudoNodes` made (before a
/// full cascade over a retained environment; the cascade creates them
/// anew). Their NodeId values are reused.
pub fn discardAllPseudoNodes(env: *Environment) void {
    var it = env.pseudo_nodes.valueIterator();
    while (it.next()) |element| env.freePseudoNode(element.*);
    env.pseudo_nodes.clearRetainingCapacity();
}

/// Remove `element`'s ::before / ::after nodes (before restyling it,
/// `cascade.restyle`).
pub fn discardPseudoNodesOf(env: *Environment, element: NodeId) void {
    inline for (.{ .before, .after }) |pseudo| {
        if (env.pseudo_nodes.fetchRemove(.{ .node = element, .pseudo = pseudo })) |kv| env.freePseudoNode(kv.value);
    }
}

fn freePseudoNode(env: *Environment, element: NodeId) void {
    const link = env.pseudo_links.fetchRemove(element.value) orelse return;
    if (link.value.child) |text| {
        _ = env.pseudo_links.remove(text.value);
        env.free_pseudo_values.append(env.allocator, text.value) catch {};
    }
    env.free_pseudo_values.append(env.allocator, element.value) catch {};
}

/// A NodeId value for a pseudo-element node: a discarded one, else the next
/// free value (the host's document nodes take values from `node_count` too).
fn allocPseudoValue(env: *Environment) usize {
    if (env.free_pseudo_values.pop()) |value| return value;
    defer env.node_count += 1;
    return env.node_count;
}

/// Discard every cascaded value so the cascade can run again over the
/// (possibly changed) document.
pub fn resetCascade(env: *Environment) !void {
    env.cascade_db.deinit(env.allocator);
    env.cascade_db = .{};
    try env.cascade_db.initNodes(env.allocator, env.node_count);
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

/// The value of the node's attribute whose interned name matches the given
/// (lowercase) string, without interning the name — for matchers that run on
/// a `const Environment` (`:lang()`).
pub fn nodeAttributeValueByName(env: *const Environment, node: NodeId, name_str: []const u8) ?AttributeValue {
    const attrs = env.nodes_to_attributes.get(node) orelse return null;
    for (attrs) |attr| {
        var it = env.attribute_names.iterator(@intFromEnum(attr.name));
        if (it.eql(name_str)) return attr.value;
    }
    return null;
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

/// True if `node` is an element whose type (tag) name is `tag`. Handles the
/// `anonymous`/`any` sentinels, which have no interned string — zml's `*`
/// elements are anonymous, and indexing the interner with a sentinel is out
/// of bounds. Assumes `tag` is lowercase.
pub fn nodeTagEql(env: *const Environment, node: NodeId, tag: []const u8) bool {
    if (env.getNodeProperty(.category, node) != .element) return false;
    const type_name = env.getNodeProperty(.type, node).name;
    if (type_name == .anonymous or type_name == .any) return false;
    var it = env.type_names.iterator(@intFromEnum(type_name));
    return it.eql(tag);
}

pub const Testing = struct {
    pub fn expectEqualTypeNames(testing: *const Testing, expected: []const u8, type_name: TypeName) !void {
        const env: *const Environment = @alignCast(@fieldParentPtr("testing", testing));
        var iterator = env.type_names.iterator(@intFromEnum(type_name));
        try std.testing.expect(iterator.eql(expected));
    }
};
