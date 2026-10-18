const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const Stylesheet = zss.Stylesheet;
const Utf8StringInterner = zss.Utf8StringInterner;

const Environment = zss.Environment;
const AttributeName = Environment.AttributeName;
const AttributeValue = Environment.AttributeValue;
const ClassName = Environment.ClassName;
const ElementAttribute = Environment.ElementAttribute;
const ElementType = Environment.ElementType;
const IdName = Environment.IdName;
const NamespaceId = Environment.Namespaces.Id;
const NodeId = Environment.NodeId;
const TypeName = Environment.TypeName;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const MultiArrayList = std.MultiArrayList;

pub const Parser = @import("selectors/parse.zig").Parser;

/// A data component of a complex selector.
/// Every complex selector is represented as a list of this data type.
///
/// When you have a list of this type, it should be laid out as follows:
/// <list> = [ `next_complex_selector` <complex-selector> ]*
/// <complex-selector> = [ <compound-selector> `trailing` ]+
/// <compound-selector> = [ `simple_selector_tag` <simple-selector> ]+
/// <simple-selector> = <variable data, depending on the previous `simple_selector_tag`>
pub const Data = union {
    /// The index of the start of the next complex selector.
    /// If this is the last complex selector within the data list, then this just points to the end of the data list.
    next_complex_selector: ListIndex,
    /// Found after every compound selector.
    trailing: Trailing,
    simple_selector_tag: SimpleSelectorTag,
    type_selector: ElementType,
    id_selector: IdName,
    class_selector: ClassName,
    attribute_selector: ElementAttribute,
    attribute_selector_value: AttributeValue,
    pseudo_class_selector: PseudoClass,
    /// Argument of the :nth-*() pseudo-classes (follows their `pseudo_class_selector`).
    nth: Nth,
    /// Argument of :lang() (follows its `pseudo_class_selector`).
    lang_value: AttributeValue,
    pseudo_element_selector: PseudoElement,
    /// :is() pseudo-class with nested selector list
    is_selector_list: NestedSelectorList,
    /// :where() pseudo-class with nested selector list
    where_selector_list: NestedSelectorList,

    /// Selectors 4 §3 An+B: matches sibling indices `a*n + b` for n >= 0.
    pub const Nth = packed struct {
        a: i16,
        b: i16,

        pub fn matches(nth: Nth, index: i32) bool {
            const a: i32 = nth.a;
            const b: i32 = nth.b;
            if (a == 0) return index == b;
            const diff = index - b;
            return @rem(diff, a) == 0 and @divTrunc(diff, a) >= 0;
        }
    };

    /// Reference to a list of nested selectors (for :is/:where)
    pub const NestedSelectorList = packed struct {
        /// Index of first complex selector in the nested list
        start: ListIndex,
        /// Number of complex selectors in the list
        count: u8,
    };

    pub const ListIndex = u24;

    // TODO: Make this an extern struct to avoid issues with undefined values within packed types.
    pub const Trailing = packed struct {
        /// The combinator applied to this compound selector (the left-hand side) and the compound selector after it (the right-hand side).
        /// If this is the last compound selector in a complex selector, this field is undefined and should not be used.
        combinator: Combinator,
        /// The index of the start of this compound selector (i.e. the first `simple_selector_tag` within this compound).
        compound_selector_start: ListIndex,
    };

    // TODO: Put payloads into this union, fit it all into 4 bytes
    pub const SimpleSelectorTag = union(enum) {
        /// The next Data is a `type_selector`
        type,
        /// The next Data is a `id_selector`
        id,
        /// The next Data is a `class_selector`
        class,
        /// The next Data is a `attribute_selector`
        /// If non-null, then there is also an `attribute_selector_value` following the `attribute_selector`
        attribute: ?AttributeOperatorCase,
        /// The next Data is a `pseudo_class_selector`
        pseudo_class,
        /// The next Data is a `pseudo_element_selector`
        pseudo_element,
        /// :not() negation: next Data is a `class_selector` to negate
        not_class,
        /// :not() negation: next Data is a `id_selector` to negate
        not_id,
        /// :not() negation: next Data is a `type_selector` to negate
        not_type,
        /// :not() negation: next Data is a `pseudo_class_selector` to negate
        not_pseudo_class,
        /// :is() pseudo-class: next Data is an `is_selector_list`
        is,
        /// :where() pseudo-class: next Data is a `where_selector_list`
        where,
    };

    pub const AttributeOperatorCase = struct {
        operator: AttributeOperator,
        case: AttributeCase,
    };
};

comptime {
    if (!zss.debug.runtime_safety) assert(@sizeOf(Data) == 4);
}

pub const Combinator = enum(u8) {
    descendant,
    child,
    next_sibling,
    subsequent_sibling,
    column,
    /// Used only in the last trailing of a complex selector to indicate no pseudo-element.
    end_none,
    /// Used only in the last trailing of a complex selector to indicate ::before.
    end_before,
    /// Used only in the last trailing of a complex selector to indicate ::after.
    end_after,
};

pub const PseudoElement = enum { before, after, unrecognized };

pub const PseudoClass = enum {
    root,
    link,
    visited,
    hover,
    active,
    focus,
    first_child,
    last_child,
    only_child,
    enabled,
    disabled,
    checked,
    empty,
    first_of_type,
    last_of_type,
    only_of_type,
    /// Followed by a `nth` Data (Selectors 4 §3: An+B).
    nth_child,
    nth_last_child,
    nth_of_type,
    nth_last_of_type,
    /// Followed by a `lang_value` Data (the language range).
    lang,
    any_link,
    scope,
    focus_within,
    focus_visible,
    target,
    required,
    optional,
    read_only,
    read_write,
    placeholder_shown,
    default,
    indeterminate,
    defined,
    unrecognized,
    ignored,
};

/// Number of extra Data entries that follow a `pseudo_class_selector` of
/// this kind (its argument).
pub fn pseudoClassPayload(pseudo_class: PseudoClass) Data.ListIndex {
    return switch (pseudo_class) {
        .nth_child, .nth_last_child, .nth_of_type, .nth_last_of_type, .lang => 1,
        else => 0,
    };
}

pub const AttributeOperator = enum { equals, list_contains, equals_or_prefix_dash, starts_with, ends_with, contains };

pub const AttributeCase = enum { default, same_case, ignore_case };

/// Represents the specificity of a complex selector.
// TODO: Make this a normal struct
pub const Specificity = packed struct {
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,

    pub fn order(lhs: Specificity, rhs: Specificity) std.math.Order {
        return std.math.order(lhs.toInt(), rhs.toInt());
    }

    fn toInt(specificity: Specificity) u24 {
        // TODO: Figure out how to avoid this byte swapping
        return std.mem.nativeToBig(u24, @as(u24, @bitCast(specificity)));
    }
};

test "Specificity.order" {
    const Order = std.math.Order;
    const order = Specificity.order;
    const ex = std.testing.expectEqual;

    try ex(Order.lt, order(.{}, .{ .c = 1 }));
    try ex(Order.lt, order(.{}, .{ .b = 1 }));
    try ex(Order.lt, order(.{}, .{ .a = 1 }));

    try ex(Order.eq, order(.{ .a = 1 }, .{ .a = 1 }));
    try ex(Order.gt, order(.{ .a = 1, .b = 1 }, .{ .a = 1 }));
    try ex(Order.gt, order(.{ .a = 1, .c = 1 }, .{ .a = 1 }));
    try ex(Order.lt, order(.{ .a = 1, .c = 1 }, .{ .a = 1, .b = 1 }));

    try ex(Order.lt, order(.{}, .{ .a = 255, .b = 255, .c = 255 }));
}

/// Extract the pseudo-element (::before/::after) from the rightmost compound selector.
/// Returns null if no pseudo-element is present or if it's unrecognized.
/// The pseudo-element is encoded in the combinator field of the last trailing, set during parsing.
pub fn extractPseudoElement(data: []const Data, complex_selector_index: Data.ListIndex) ?PseudoElement {
    const last_trailing = data[complex_selector_index].next_complex_selector - 1;
    const trailing = data[last_trailing].trailing;
    return switch (trailing.combinator) {
        .end_before => .before,
        .end_after => .after,
        .end_none => null,
        // Older data or non-last trailing: no pseudo-element.
        else => null,
    };
}


/// Returns true if the given pseudo-class matches the element.
/// Used by both .pseudo_class and .not_pseudo_class matching.
/// HTML attributes whose values selectors match ASCII case-insensitively
/// (Selectors 4 §6.4 / HTML "case-sensitivity of selectors").
const case_insensitive_html_attributes = [_][]const u8{
    "accept",   "accept-charset", "align",    "alink",    "axis",     "bgcolor",  "charset",  "checked",
    "clear",    "codetype",       "color",    "compact",  "declare",  "defer",    "dir",      "direction",
    "disabled", "enctype",        "face",     "frame",    "hreflang", "http-equiv", "lang",   "language",
    "link",     "media",          "method",   "multiple", "nohref",   "noresize", "noshade",  "nowrap",
    "readonly", "rel",            "rev",      "rules",    "scope",    "scrolling", "selected", "shape",
    "target",   "text",           "type",     "valign",   "valuetype", "vlink",
};

fn isCaseInsensitiveHtmlAttribute(env: *const Environment, name: AttributeName) bool {
    if (name == .anonymous) return false;
    for (case_insensitive_html_attributes) |candidate| {
        var it = env.attribute_names.iterator(@intFromEnum(name));
        if (it.eql(candidate)) return true;
    }
    return false;
}

fn sameElementType(a: ElementType, b: ElementType) bool {
    return a.namespace == b.namespace and a.name == b.name;
}

/// The `input` types that take text (HTML §4.10.5): the ones whose controls
/// are `:read-write` unless readonly/disabled, and the ones that show a
/// placeholder.
pub fn isTextEntryInputType(type_value: []const u8) bool {
    const text_types = [_][]const u8{ "text", "search", "url", "tel", "email", "password", "date", "month", "week", "time", "datetime-local", "number" };
    for (text_types) |t| if (std.ascii.eqlIgnoreCase(type_value, t)) return true;
    return false;
}

/// Returns `true` if the complex selector matches `match_candidate`.
/// Asserts that `match_candidate` is an element node.
pub fn matchElement(
    data: []const Data,
    complex_selector_index: Data.ListIndex,
    env: *const Environment,
    match_candidate: NodeId,
    allocator: std.mem.Allocator,
) bool {
    return Matcher(EnvTree).matchElement(data, complex_selector_index, env, .{ .env = env }, match_candidate, allocator);
}

/// The Environment's own retained document tree, as the matcher sees it:
/// what the cascade matches against.
pub const EnvTree = struct {
    env: *const Environment,
    /// The `:scope` element; null means the root element.
    scope: ?NodeId = null,

    pub const Node = NodeId;

    pub fn isElement(t: EnvTree, n: NodeId) bool {
        return t.env.getNodeProperty(.category, n) == .element;
    }
    pub fn parent(t: EnvTree, n: NodeId) ?NodeId {
        return n.parent(t.env);
    }
    pub fn previousSibling(t: EnvTree, n: NodeId) ?NodeId {
        return n.previousSibling(t.env);
    }
    pub fn nextSibling(t: EnvTree, n: NodeId) ?NodeId {
        return n.nextSibling(t.env);
    }
    pub fn firstChild(t: EnvTree, n: NodeId) ?NodeId {
        return n.firstChild(t.env);
    }
    pub fn isRoot(t: EnvTree, n: NodeId) bool {
        return t.env.root_node != null and std.meta.eql(n, t.env.root_node.?);
    }
    pub fn scopeNode(t: EnvTree) ?NodeId {
        return t.scope;
    }
    pub fn typeMatches(t: EnvTree, n: NodeId, selector_type: ElementType) bool {
        return matchTypeSelector(selector_type, t.env.getNodeProperty(.type, n));
    }
    pub fn sameType(t: EnvTree, a: NodeId, b: NodeId) bool {
        return sameElementType(t.env.getNodeProperty(.type, a), t.env.getNodeProperty(.type, b));
    }
    pub fn hasId(t: EnvTree, n: NodeId, id: IdName) bool {
        const with_id = t.env.getElementById(id) orelse return false;
        return std.meta.eql(n, with_id);
    }
    pub fn hasClass(t: EnvTree, n: NodeId, class_name: ClassName) bool {
        return t.env.nodeHasClass(n, class_name);
    }
    pub fn hasAttribute(t: EnvTree, n: NodeId, name: AttributeName) bool {
        return t.env.nodeHasAttribute(n, name);
    }
    pub fn hasAttributeByName(t: EnvTree, n: NodeId, name: []const u8) bool {
        return t.env.nodeHasAttributeByName(n, name);
    }
    pub fn attributeEquals(t: EnvTree, n: NodeId, name: AttributeName, value: AttributeValue, case: Utf8StringInterner.Case) bool {
        const node_value = t.env.nodeGetAttributeValue(n, name) orelse return false;
        return t.env.eqlAttributeValues(case, node_value, value);
    }
    pub fn attributeString(t: EnvTree, allocator: Allocator, n: NodeId, name: AttributeName, case: Utf8StringInterner.Case) Allocator.Error!?[]u8 {
        const node_value = t.env.nodeGetAttributeValue(n, name) orelse return null;
        return try t.env.getAttributeValueString(allocator, node_value, case);
    }
    pub fn attributeStringByName(t: EnvTree, allocator: Allocator, n: NodeId, name: []const u8, case: Utf8StringInterner.Case) Allocator.Error!?[]u8 {
        const node_value = t.env.nodeAttributeValueByName(n, name) orelse return null;
        return try t.env.getAttributeValueString(allocator, node_value, case);
    }
    pub fn tagEql(t: EnvTree, n: NodeId, tag: []const u8) bool {
        return t.env.nodeTagEql(n, tag);
    }
    pub fn localNameHasDash(t: EnvTree, n: NodeId) bool {
        const type_name = t.env.getNodeProperty(.type, n).name;
        if (type_name == .anonymous or type_name == .any) return false;
        var it = t.env.type_names.iterator(@intFromEnum(type_name));
        while (it.next()) |segment| {
            if (std.mem.indexOfScalar(u8, segment, '-') != null) return true;
        }
        return false;
    }
    pub fn hasText(t: EnvTree, n: NodeId) bool {
        return switch (t.env.getNodeProperty(.category, n)) {
            .element => false,
            .text => t.env.getText(t.env.getNodeProperty(.text, n)).len > 0,
        };
    }
    pub fn state(t: EnvTree, n: NodeId, s: Environment.ElementState) bool {
        return t.env.nodeState(n, s);
    }
};

/// Selectors 4 matching over any document tree. `EnvTree` is the reference
/// implementation of the interface a tree provides: `Node`; `isElement`,
/// `parent`, `previousSibling`, `nextSibling`, `firstChild`, `isRoot`,
/// `scopeNode`, `typeMatches`, `sameType`, `hasId`, `hasClass`,
/// `hasAttribute`, `hasAttributeByName`, `attributeEquals`,
/// `attributeString`, `attributeStringByName`, `tagEql`, `localNameHasDash`,
/// `hasText`, `state`. Selector names come from `env`'s interners, so a host
/// tree compares its own strings against them.
pub fn Matcher(comptime Tree: type) type {
    return struct {
        const Node = Tree.Node;

        fn eql(a: Node, b: Node) bool {
            return std.meta.eql(a, b);
        }

        /// Returns `true` if the complex selector matches `match_candidate`.
        /// Asserts that `match_candidate` is an element node.
        pub fn matchElement(
            data: []const Data,
            complex_selector_index: Data.ListIndex,
            env: *const Environment,
            tree: Tree,
            match_candidate: Node,
            allocator: Allocator,
        ) bool {
            assert(tree.isElement(match_candidate));
            const last_trailing = data[complex_selector_index].next_complex_selector - 1;
            return matchComplexSelector(data, complex_selector_index + 1, last_trailing, env, tree, match_candidate, allocator);
        }

        /// Returns `true` if any complex selector in the list starting at
        /// `first_complex_selector_index` and ending at `end` matches.
        pub fn matchSelectorList(
            data: []const Data,
            first_complex_selector_index: Data.ListIndex,
            end: Data.ListIndex,
            env: *const Environment,
            tree: Tree,
            match_candidate: Node,
            allocator: Allocator,
        ) bool {
            var index = first_complex_selector_index;
            while (index < end) : (index = data[index].next_complex_selector) {
                if (@This().matchElement(data, index, env, tree, match_candidate, allocator)) return true;
            }
            return false;
        }

        fn matchComplexSelector(
            data: []const Data,
            first_compound: Data.ListIndex,
            last_trailing: Data.ListIndex,
            env: *const Environment,
            tree: Tree,
            match_candidate: Node,
            allocator: Allocator,
        ) bool {
            const trailing = data[last_trailing].trailing;
            if (!matchCompoundSelector(data, trailing.compound_selector_start, last_trailing, env, tree, match_candidate, allocator)) return false;
            return matchLeftOfCompound(data, first_compound, trailing.compound_selector_start, env, tree, match_candidate, allocator);
        }

        /// Matches the part of a complex selector to the left of the compound selector
        /// starting at `compound_start`, given that compound already matched `anchor`.
        ///
        /// Selectors 4 §16 (combinators) describe a relationship between two elements;
        /// the descendant and subsequent-sibling combinators relate the anchor to ANY
        /// of several candidates, so a match of the left-hand compound against one
        /// candidate is not final: if the rest of the selector fails from there, the
        /// next candidate must be tried. `#a > div div > div` against the chain
        /// `#a > b > c > d > e` matches `e` only by anchoring the middle `div` at `b`,
        /// not at `c` (the nearest match) — committing to the nearest candidate is the
        /// classic bug Acid3 test 42 checks for.
        fn matchLeftOfCompound(
            data: []const Data,
            first_compound: Data.ListIndex,
            compound_start: Data.ListIndex,
            env: *const Environment,
            tree: Tree,
            anchor: Node,
            allocator: Allocator,
        ) bool {
            if (compound_start == first_compound) return true;
            const trailing_index = compound_start - 1;
            const trailing = data[trailing_index].trailing;
            const left_start = trailing.compound_selector_start;
            switch (trailing.combinator) {
                .descendant => {
                    var element = tree.parent(anchor);
                    while (element) |e| : (element = tree.parent(e)) {
                        if (!tree.isElement(e)) break;
                        if (matchCompoundSelector(data, left_start, trailing_index, env, tree, e, allocator) and
                            matchLeftOfCompound(data, first_compound, left_start, env, tree, e, allocator)) return true;
                    }
                    return false;
                },
                .child => {
                    const parent = tree.parent(anchor) orelse return false;
                    if (!tree.isElement(parent)) return false;
                    if (!matchCompoundSelector(data, left_start, trailing_index, env, tree, parent, allocator)) return false;
                    return matchLeftOfCompound(data, first_compound, left_start, env, tree, parent, allocator);
                },
                .subsequent_sibling => {
                    var element = tree.previousSibling(anchor);
                    while (element) |e| : (element = tree.previousSibling(e)) {
                        if (!tree.isElement(e)) continue;
                        if (matchCompoundSelector(data, left_start, trailing_index, env, tree, e, allocator) and
                            matchLeftOfCompound(data, first_compound, left_start, env, tree, e, allocator)) return true;
                    }
                    return false;
                },
                .next_sibling => {
                    var element = tree.previousSibling(anchor);
                    const sibling = while (element) |e| : (element = tree.previousSibling(e)) {
                        if (tree.isElement(e)) break e;
                    } else return false;
                    if (!matchCompoundSelector(data, left_start, trailing_index, env, tree, sibling, allocator)) return false;
                    return matchLeftOfCompound(data, first_compound, left_start, env, tree, sibling, allocator);
                },
                // Selectors 4 §16.4: the column combinator relates cells to
                // columns; no browser implements it, and neither does this.
                .column => return false,
                // end_* values only appear in the last trailing and are never reached here.
                .end_none, .end_before, .end_after => unreachable,
            }
        }

        /// Case for comparing a selector's attribute value with an element's
        /// (Selectors 4 §6.4): sensitive unless the selector says `i`, or the
        /// attribute is one HTML defines as ASCII case-insensitive.
        fn attributeCase(env: *const Environment, name: AttributeName, oc: Data.AttributeOperatorCase) Utf8StringInterner.Case {
            return switch (oc.case) {
                .default => if (isCaseInsensitiveHtmlAttribute(env, name)) .insensitive else .sensitive,
                .same_case => .sensitive,
                .ignore_case => .insensitive,
            };
        }

        fn matchAttributeOperator(
            env: *const Environment,
            tree: Tree,
            element: Node,
            name: AttributeName,
            oc: Data.AttributeOperatorCase,
            selector_value: AttributeValue,
            allocator: Allocator,
        ) bool {
            const case = attributeCase(env, name, oc);
            if (oc.operator == .equals) return tree.attributeEquals(element, name, selector_value, case);
            const node_str = (tree.attributeString(allocator, element, name, case) catch return false) orelse return false;
            defer allocator.free(node_str);
            const selector_str = env.getAttributeValueString(allocator, selector_value, case) catch return false;
            defer allocator.free(selector_str);
            switch (oc.operator) {
                .equals => unreachable,
                // [attr~=val]: val is one of the whitespace-separated words
                .list_contains => {
                    if (selector_str.len == 0) return false;
                    var it = std.mem.tokenizeAny(u8, node_str, " \t\n\r\x0c");
                    while (it.next()) |word| {
                        if (std.mem.eql(u8, word, selector_str)) return true;
                    }
                    return false;
                },
                // Selectors 4 §6.2: an empty value never matches the substring operators.
                .starts_with => return selector_str.len > 0 and std.mem.startsWith(u8, node_str, selector_str),
                .ends_with => return selector_str.len > 0 and std.mem.endsWith(u8, node_str, selector_str),
                .contains => return selector_str.len > 0 and std.mem.indexOf(u8, node_str, selector_str) != null,
                // [attr|=val]: val, or val followed by "-"
                .equals_or_prefix_dash => {
                    if (std.mem.eql(u8, node_str, selector_str)) return true;
                    return std.mem.startsWith(u8, node_str, selector_str) and
                        node_str.len > selector_str.len and node_str[selector_str.len] == '-';
                },
            }
        }

        fn matchCompoundSelector(
            data: []const Data,
            start: Data.ListIndex,
            end: Data.ListIndex,
            env: *const Environment,
            tree: Tree,
            element: Node,
            allocator: Allocator,
        ) bool {
            var index = start;
            while (index < end) : (index += 1) {
                switch (data[index].simple_selector_tag) {
                    .type => {
                        index += 1;
                        if (!tree.typeMatches(element, data[index].type_selector)) return false;
                    },
                    .id => {
                        index += 1;
                        if (!tree.hasId(element, data[index].id_selector)) return false;
                    },
                    .class => {
                        index += 1;
                        if (!tree.hasClass(element, data[index].class_selector)) return false;
                    },
                    .attribute => |op_case| {
                        index += 1;
                        const attr_selector = data[index].attribute_selector;
                        if (op_case) |oc| {
                            index += 1;
                            const selector_value = data[index].attribute_selector_value;
                            if (!matchAttributeOperator(env, tree, element, attr_selector.name, oc, selector_value, allocator)) return false;
                        } else {
                            // [attr] — attribute just needs to exist
                            if (!tree.hasAttribute(element, attr_selector.name)) return false;
                        }
                    },
                    .not_class => {
                        index += 1;
                        if (tree.hasClass(element, data[index].class_selector)) return false;
                    },
                    .not_id => {
                        index += 1;
                        if (tree.hasId(element, data[index].id_selector)) return false;
                    },
                    .not_type => {
                        index += 1;
                        if (tree.typeMatches(element, data[index].type_selector)) return false;
                    },
                    .not_pseudo_class => {
                        index += 1;
                        const negated_pc = data[index].pseudo_class_selector;
                        const payload = if (pseudoClassPayload(negated_pc) > 0) data[index + 1] else data[index];
                        index += pseudoClassPayload(negated_pc);
                        // If the pseudo-class MATCHES, the :not() fails.
                        if (matchPseudoClass(negated_pc, payload, element, env, tree, allocator)) return false;
                    },
                    .pseudo_class => {
                        index += 1;
                        const pseudo_class = data[index].pseudo_class_selector;
                        const payload = if (pseudoClassPayload(pseudo_class) > 0) data[index + 1] else data[index];
                        index += pseudoClassPayload(pseudo_class);
                        if (!matchPseudoClass(pseudo_class, payload, element, env, tree, allocator)) return false;
                    },
                    .pseudo_element => {
                        index += 1;
                        const pseudo_element = data[index].pseudo_element_selector;
                        switch (pseudo_element) {
                            // Skip recognized pseudo-elements — the cascade handles them.
                            .before, .after => {},
                            .unrecognized => return false,
                        }
                    },
                    // :is() / :where(): the element matches any complex selector of
                    // the nested list (the lists differ only in specificity, which the
                    // parser handled). The nested selector data is stored inline after
                    // the list entry, chained through next_complex_selector.
                    inline .is, .where => |_, tag| {
                        index += 1;
                        const list = if (tag == .is) data[index].is_selector_list else data[index].where_selector_list;
                        var matched = false;
                        var sel_idx = list.start;
                        for (0..list.count) |_| {
                            const next = data[sel_idx].next_complex_selector;
                            if (!matched and matchComplexSelector(data, sel_idx + 1, next - 1, env, tree, element, allocator)) matched = true;
                            sel_idx = next;
                        }
                        if (!matched) return false;
                        index = sel_idx - 1; // -1 compensates for the while loop increment
                    },
                }
            }
            return true;
        }

        /// 1-based position of `element` among its element siblings (Selectors 4 §14),
        /// counted from the start or the end, optionally only among siblings of the
        /// same type (the *-of-type family).
        fn siblingIndex(tree: Tree, element: Node, comptime of_type: bool, comptime from_end: bool) i32 {
            var index: i32 = 1;
            var sib = if (from_end) tree.nextSibling(element) else tree.previousSibling(element);
            while (sib) |s| : (sib = if (from_end) tree.nextSibling(s) else tree.previousSibling(s)) {
                if (!tree.isElement(s)) continue;
                if (of_type and !tree.sameType(element, s)) continue;
                index += 1;
            }
            return index;
        }

        /// Selectors 4 §14.3.1: no element children and no text children with any
        /// content (comments and processing instructions never enter the tree).
        fn isEmpty(tree: Tree, element: Node) bool {
            var child = tree.firstChild(element);
            while (child) |ch| : (child = tree.nextSibling(ch)) {
                if (tree.isElement(ch) or tree.hasText(ch)) return false;
            }
            return true;
        }

        /// Selectors 4 §8: the element's language is the nearest `lang` attribute on
        /// it or an ancestor; the range matches when it equals the language or is a
        /// dash-delimited prefix of it, ASCII case-insensitively (BCP 47 §2.1).
        fn matchLang(env: *const Environment, tree: Tree, element: Node, range: AttributeValue, allocator: Allocator) bool {
            const range_str = env.getAttributeValueString(allocator, range, .insensitive) catch return false;
            defer allocator.free(range_str);
            if (range_str.len == 0) return false;
            var e: ?Node = element;
            while (e) |node| : (e = tree.parent(node)) {
                if (!tree.isElement(node)) break;
                const lang = (tree.attributeStringByName(allocator, node, "lang", .insensitive) catch return false) orelse continue;
                defer allocator.free(lang);
                if (lang.len == 0) return false; // lang="" — the element has no language
                if (std.ascii.eqlIgnoreCase(lang, range_str)) return true;
                return lang.len > range_str.len and std.ascii.startsWithIgnoreCase(lang, range_str) and lang[range_str.len] == '-';
            }
            return false;
        }

        fn inputType(tree: Tree, element: Node, allocator: Allocator) ?[]u8 {
            return (tree.attributeStringByName(allocator, element, "type", .insensitive) catch return null);
        }

        /// Selectors 4 §14.6.2: `:checked` matches checkbox and radio `input`s whose
        /// checkedness is true and `option`s whose selectedness is true. The states
        /// come from the host (`Environment.nodeState`); the `checked`/`selected`
        /// attributes are only their defaults.
        fn matchChecked(tree: Tree, element: Node, allocator: Allocator) bool {
            if (tree.tagEql(element, "option")) return tree.state(element, .selected);
            if (!tree.tagEql(element, "input")) return false;
            const type_str = inputType(tree, element, allocator) orelse return false;
            defer allocator.free(type_str);
            if (!std.ascii.eqlIgnoreCase(type_str, "checkbox") and !std.ascii.eqlIgnoreCase(type_str, "radio")) return false;
            return tree.state(element, .checked);
        }

        /// HTML §4.16.3 `:link`/`:any-link`: `a` and `area` elements with an `href`.
        fn isLink(tree: Tree, element: Node) bool {
            if (!tree.tagEql(element, "a") and !tree.tagEql(element, "area")) return false;
            return tree.hasAttributeByName(element, "href");
        }

        /// Form controls that are candidates for `:required`/`:optional`
        /// (HTML §4.16.3): input, select, textarea.
        fn isRequirable(tree: Tree, element: Node) bool {
            return tree.tagEql(element, "input") or tree.tagEql(element, "select") or tree.tagEql(element, "textarea");
        }

        /// HTML §4.16.3 `:read-write`: text-entry inputs and textareas that are
        /// neither readonly nor disabled, and editing hosts (contenteditable).
        fn isReadWrite(tree: Tree, element: Node, allocator: Allocator) bool {
            if (tree.tagEql(element, "input")) {
                const type_str = inputType(tree, element, allocator);
                defer if (type_str) |t| allocator.free(t);
                // A missing or unknown type is "text" (HTML §4.10.5.1.1).
                if (type_str != null and type_str.?.len > 0 and !isTextEntryInputType(type_str.?)) return false;
                return !tree.hasAttributeByName(element, "readonly") and !tree.state(element, .disabled);
            }
            if (tree.tagEql(element, "textarea")) {
                return !tree.hasAttributeByName(element, "readonly") and !tree.state(element, .disabled);
            }
            const ce = (tree.attributeStringByName(allocator, element, "contenteditable", .insensitive) catch return false) orelse return false;
            defer allocator.free(ce);
            return ce.len == 0 or std.mem.eql(u8, ce, "true") or std.mem.eql(u8, ce, "plaintext-only");
        }

        /// HTML §4.10.6 default button: the first submit button in tree order
        /// among the form's descendants.
        fn isDefaultButton(tree: Tree, element: Node, allocator: Allocator) bool {
            // Walk up to the form owner.
            var form: ?Node = tree.parent(element);
            while (form) |f| : (form = tree.parent(f)) {
                if (!tree.isElement(f)) return false;
                if (tree.tagEql(f, "form")) break;
            } else return false;
            // Depth-first over the form's descendants until the first submit button.
            var node: ?Node = tree.firstChild(form.?);
            while (node) |n| {
                if (tree.isElement(n) and isSubmitButton(tree, n, allocator)) return eql(n, element);
                if (tree.isElement(n)) {
                    if (tree.firstChild(n)) |c| {
                        node = c;
                        continue;
                    }
                }
                var cur = n;
                node = while (true) {
                    if (tree.nextSibling(cur)) |ns| break ns;
                    const p = tree.parent(cur) orelse break null;
                    if (eql(p, form.?)) break null;
                    cur = p;
                };
            }
            return false;
        }

        fn isSubmitButton(tree: Tree, element: Node, allocator: Allocator) bool {
            if (tree.tagEql(element, "button")) {
                const t = inputType(tree, element, allocator) orelse return true;
                defer allocator.free(t);
                return std.ascii.eqlIgnoreCase(t, "submit");
            }
            if (tree.tagEql(element, "input")) {
                const t = inputType(tree, element, allocator) orelse return false;
                defer allocator.free(t);
                return std.ascii.eqlIgnoreCase(t, "submit") or std.ascii.eqlIgnoreCase(t, "image");
            }
            return false;
        }

        /// `payload` is the Data following the `pseudo_class_selector`; only read for
        /// pseudo-classes with an argument (`pseudoClassPayload`).
        fn matchPseudoClass(pseudo_class: PseudoClass, payload: Data, element: Node, env: *const Environment, tree: Tree, allocator: Allocator) bool {
            switch (pseudo_class) {
                .root => return tree.isRoot(element),
                // Selectors 4 §9.1: the scoping root, or the root element when
                // there is none.
                .scope => return if (tree.scopeNode()) |s| eql(s, element) else tree.isRoot(element),
                .first_child => return siblingIndex(tree, element, false, false) == 1,
                .last_child => return siblingIndex(tree, element, false, true) == 1,
                .only_child => return siblingIndex(tree, element, false, false) == 1 and siblingIndex(tree, element, false, true) == 1,
                .first_of_type => return siblingIndex(tree, element, true, false) == 1,
                .last_of_type => return siblingIndex(tree, element, true, true) == 1,
                .only_of_type => return siblingIndex(tree, element, true, false) == 1 and siblingIndex(tree, element, true, true) == 1,
                .nth_child => return payload.nth.matches(siblingIndex(tree, element, false, false)),
                .nth_last_child => return payload.nth.matches(siblingIndex(tree, element, false, true)),
                .nth_of_type => return payload.nth.matches(siblingIndex(tree, element, true, false)),
                .nth_last_of_type => return payload.nth.matches(siblingIndex(tree, element, true, true)),
                .lang => return matchLang(env, tree, element, payload.lang_value, allocator),
                .link, .any_link => return isLink(tree, element),
                // No history: nothing has been visited.
                .visited => return false,
                .hover => return tree.state(element, .hover),
                .active => return tree.state(element, .active),
                .focus => return tree.state(element, .focus),
                .focus_within => return tree.state(element, .focus_within),
                .focus_visible => return tree.state(element, .focus_visible),
                .target => return tree.state(element, .target),
                .enabled => {
                    if (!isFormElement(tree, element)) return false;
                    return !tree.state(element, .disabled);
                },
                .disabled => {
                    if (!isFormElement(tree, element)) return false;
                    return tree.state(element, .disabled);
                },
                .checked => return matchChecked(tree, element, allocator),
                .indeterminate => return tree.state(element, .indeterminate),
                .placeholder_shown => {
                    if (!tree.tagEql(element, "input") and !tree.tagEql(element, "textarea")) return false;
                    return tree.state(element, .placeholder_shown);
                },
                .required => return isRequirable(tree, element) and tree.hasAttributeByName(element, "required"),
                .optional => return isRequirable(tree, element) and !tree.hasAttributeByName(element, "required"),
                .read_write => return isReadWrite(tree, element, allocator),
                .read_only => return !isReadWrite(tree, element, allocator),
                .default => {
                    if (tree.tagEql(element, "option")) return tree.hasAttributeByName(element, "selected");
                    if (tree.tagEql(element, "input")) {
                        const t = inputType(tree, element, allocator) orelse return false;
                        defer allocator.free(t);
                        if (std.ascii.eqlIgnoreCase(t, "checkbox") or std.ascii.eqlIgnoreCase(t, "radio")) {
                            return tree.hasAttributeByName(element, "checked");
                        }
                    }
                    return isSubmitButton(tree, element, allocator) and isDefaultButton(tree, element, allocator);
                },
                // Without a custom element registry every built-in element is
                // defined and every custom element (a name with "-") is not.
                .defined => return !tree.localNameHasDash(element),
                .empty => return isEmpty(tree, element),
                .unrecognized => return false,
                .ignored => return true,
            }
        }

        /// Check if element is a form element (input, button, select, textarea, fieldset).
        /// Used by :enabled and :disabled pseudo-class matchers.
        fn isFormElement(tree: Tree, element: Node) bool {
            inline for (.{ "input", "button", "select", "textarea", "fieldset", "optgroup", "option" }) |tag| {
                if (tree.tagEql(element, tag)) return true;
            }
            return false;
        }
    };
}

pub fn matchTypeSelector(selector_type: ElementType, element_type: ElementType) bool {
    assert(element_type.namespace != .any);
    assert(element_type.name != .any);

    switch (selector_type.namespace) {
        .any => {},
        else => if (selector_type.namespace != element_type.namespace) return false,
    }

    switch (selector_type.name) {
        .any => {},
        .anonymous => return false,
        _ => if (selector_type.name != element_type.name) return false,
    }

    return true;
}

test "matching type selectors" {
    const some_namespace = @as(NamespaceId, @enumFromInt(24));
    const some_name = @as(TypeName, @enumFromInt(42));

    const e1 = ElementType{ .namespace = .none, .name = .anonymous };
    const e2 = ElementType{ .namespace = .none, .name = some_name };
    const e3 = ElementType{ .namespace = some_namespace, .name = .anonymous };
    const e4 = ElementType{ .namespace = some_namespace, .name = some_name };

    const expect = std.testing.expect;
    const matches = matchTypeSelector;

    try expect(matches(.{ .namespace = .any, .name = .any }, e1));
    try expect(matches(.{ .namespace = .any, .name = .any }, e2));
    try expect(matches(.{ .namespace = .any, .name = .any }, e3));
    try expect(matches(.{ .namespace = .any, .name = .any }, e4));

    try expect(!matches(.{ .namespace = .any, .name = .anonymous }, e1));
    try expect(!matches(.{ .namespace = .any, .name = .anonymous }, e2));
    try expect(!matches(.{ .namespace = .any, .name = .anonymous }, e3));
    try expect(!matches(.{ .namespace = .any, .name = .anonymous }, e4));

    try expect(!matches(.{ .namespace = some_namespace, .name = .any }, e1));
    try expect(!matches(.{ .namespace = some_namespace, .name = .any }, e2));
    try expect(matches(.{ .namespace = some_namespace, .name = .any }, e3));
    try expect(matches(.{ .namespace = some_namespace, .name = .any }, e4));

    try expect(!matches(.{ .namespace = .any, .name = some_name }, e1));
    try expect(matches(.{ .namespace = .any, .name = some_name }, e2));
    try expect(!matches(.{ .namespace = .any, .name = some_name }, e3));
    try expect(matches(.{ .namespace = .any, .name = some_name }, e4));

    try expect(!matches(.{ .namespace = some_namespace, .name = .anonymous }, e1));
    try expect(!matches(.{ .namespace = some_namespace, .name = .anonymous }, e2));
    try expect(!matches(.{ .namespace = some_namespace, .name = .anonymous }, e3));
    try expect(!matches(.{ .namespace = some_namespace, .name = .anonymous }, e4));

    try expect(!matches(.{ .namespace = some_namespace, .name = some_name }, e1));
    try expect(!matches(.{ .namespace = some_namespace, .name = some_name }, e2));
    try expect(!matches(.{ .namespace = some_namespace, .name = some_name }, e3));
    try expect(matches(.{ .namespace = some_namespace, .name = some_name }, e4));
}

test "complex selector matching" {
    const ns = struct {
        fn expectMatch(expected: bool, input: []const u8, env: *Environment, allocator: Allocator, target: Environment.NodeId) !void {
            const source_code = try zss.syntax.SourceCode.init(input);
            var ast, const component_list_index = blk: {
                var parser = zss.syntax.Parser.init(source_code, allocator);
                defer parser.deinit();
                break :blk try parser.parseListOfComponentValues(allocator);
            };
            defer ast.deinit(allocator);

            var parser = Parser.init(env, allocator, source_code, ast, &.{});
            defer parser.deinit();
            var data_list: std.ArrayList(Data) = .empty;
            defer data_list.deinit(allocator);
            try parser.parseComplexSelectorList(&data_list, allocator, component_list_index.children(ast));
            try std.testing.expectEqual(expected, matchElement(data_list.items, 0, env, target, allocator));
        }
    };

    const allocator = std.testing.allocator;

    const source_code = try zss.syntax.SourceCode.init(
        \\root #alice {
        \\  first {}
        \\  second {
        \\    grandchild {}
        \\  }
        \\  ""
        \\  third #bob {}
        \\}
    );
    var document = try zss.zml.parseAndCreateDocument(allocator, source_code);
    defer document.deinit(allocator);
    const env = &document.env;

    const nodes = blk: {
        const root = document.env.root_node.?;
        const first = root.firstChild(env).?;
        const second = first.nextSibling(env).?;
        const grandchild = second.firstChild(env).?;
        const third = second.nextSibling(env).?.nextSibling(env).?;
        break :blk .{ .root = root, .first = first, .second = second, .grandchild = grandchild, .third = third };
    };

    // zig fmt: off
    try ns.expectMatch(true , "root"                  , env, allocator, nodes.root      );
    try ns.expectMatch(true , ":root"                 , env, allocator, nodes.root      );
    try ns.expectMatch(true , "first"                 , env, allocator, nodes.first     );
    try ns.expectMatch(true , "root > first"          , env, allocator, nodes.first     );
    try ns.expectMatch(true , "root first"            , env, allocator, nodes.first     );
    try ns.expectMatch(true , "second"                , env, allocator, nodes.second    );
    try ns.expectMatch(true , "first + second"        , env, allocator, nodes.second    );
    try ns.expectMatch(true , "first ~ second"        , env, allocator, nodes.second    );
    try ns.expectMatch(true , "third"                 , env, allocator, nodes.third     );
    try ns.expectMatch(true , "second + third"        , env, allocator, nodes.third     );
    try ns.expectMatch(true , "second ~ third"        , env, allocator, nodes.third     );
    try ns.expectMatch(false, "first + third"         , env, allocator, nodes.third     );
    try ns.expectMatch(true , "first ~ third"         , env, allocator, nodes.third     );
    try ns.expectMatch(true , "grandchild"            , env, allocator, nodes.grandchild);
    try ns.expectMatch(true , "second > grandchild"   , env, allocator, nodes.grandchild);
    try ns.expectMatch(true , "second grandchild"     , env, allocator, nodes.grandchild);
    try ns.expectMatch(true , "root grandchild"       , env, allocator, nodes.grandchild);
    try ns.expectMatch(true , "root second grandchild", env, allocator, nodes.grandchild);
    try ns.expectMatch(false, "root > grandchild"     , env, allocator, nodes.grandchild);
    try ns.expectMatch(true , "#alice"                , env, allocator, nodes.root      );
    try ns.expectMatch(false, "#alice"                , env, allocator, nodes.third     );
    try ns.expectMatch(true , "#alice > #bob"         , env, allocator, nodes.third     );
    // zig fmt: on
}

// TODO: Make a fuzz test
