const zss = @import("../zss.zig");
const Stylesheet = zss.Stylesheet;

const selectors = zss.selectors;
const Data = selectors.Data;
const Specificity = selectors.Specificity;

const Environment = zss.Environment;
const NamespaceId = Environment.Namespaces.Id;
const ElementType = Environment.ElementType;
const ElementAttribute = Environment.ElementAttribute;

const syntax = zss.syntax;
const Ast = syntax.Ast;
const Component = syntax.Component;
const SourceCode = syntax.SourceCode;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Parser = struct {
    env: *Environment,
    source_code: SourceCode,
    ast: Ast,
    namespaces: *const Stylesheet.Namespaces,
    default_namespace: NamespaceId,

    sequence: Ast.Sequence = undefined,
    specificities: std.ArrayList(Specificity),
    allocator: Allocator,
    valid: bool = undefined,
    specificity: Specificity = undefined,
    /// Tracks the pseudo-element of the most recently parsed compound selector.
    /// Reset before each compound, set by parsePseudoElementSelector.
    /// Used to encode pseudo-element info in the last trailing of a complex selector.
    last_pseudo_element: selectors.PseudoElement = .unrecognized,

    pub fn init(
        env: *Environment,
        allocator: Allocator,
        source_code: SourceCode,
        ast: Ast,
        namespaces: *const Stylesheet.Namespaces,
    ) Parser {
        return Parser{
            .env = env,
            .source_code = source_code,
            .ast = ast,
            .namespaces = namespaces,
            .default_namespace = namespaces.default orelse .any,

            .specificities = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(parser: *Parser) void {
        parser.specificities.deinit(parser.allocator);
    }

    /// Attempts to parse a <complex-selector-list> from `sequence`, and append the selector data to `data_list`.
    /// If any one of the complex selectors fails to parse, then the entire parse fails, and `data_list` is reverted to its original state.
    /// Each complex selector will have its specificity found in `parser.specificities.items`.
    pub fn parseComplexSelectorList(
        parser: *Parser,
        data_list: *std.ArrayList(Data),
        data_list_allocator: Allocator,
        sequence: Ast.Sequence,
    ) !void {
        parser.sequence = sequence;
        parser.specificities.clearRetainingCapacity();

        const managed = DataListManaged{ .list = data_list, .allocator = data_list_allocator };
        const old_len = managed.len();

        (try parseComplexSelector(parser, managed)) orelse {
            managed.reset(old_len);
            return parser.fail();
        };
        while (true) {
            _ = parser.skipSpaces();
            const comma_tag, _ = parser.next() orelse break;
            if (comma_tag != .token_comma) {
                managed.reset(old_len);
                return parser.fail();
            }
            (try parseComplexSelector(parser, managed)) orelse {
                managed.reset(old_len);
                return parser.fail();
            };
        }

        if (parser.specificities.items.len == 0) {
            managed.reset(old_len);
            return parser.fail();
        }
    }

    const SelectorKind = enum { id, class, attribute, pseudo_class, type, pseudo_element };

    fn addSpecificity(parser: *Parser, comptime kind: SelectorKind) void {
        const field_name = switch (kind) {
            .id => "a",
            .class, .attribute, .pseudo_class => "b",
            .type, .pseudo_element => "c",
        };
        const field = &@field(parser.specificity, field_name);
        field.* +|= 1;
    }

    fn fail(_: *Parser) error{ParseError} {
        return error.ParseError;
    }

    fn next(parser: *Parser) ?struct { Component.Tag, Ast.Index } {
        const index = parser.sequence.nextKeepSpaces(parser.ast) orelse return null;
        const tag = index.tag(parser.ast);
        return .{ tag, index };
    }

    /// If the next component is `accepted_tag`, then return that component index.
    fn accept(parser: *Parser, accepted_tag: Component.Tag) ?Ast.Index {
        const tag, const index = parser.next() orelse return null;
        if (accepted_tag == tag) {
            return index;
        } else {
            parser.sequence.reset(index);
            return null;
        }
    }

    /// Fails parsing if an unexpected component or EOF is encountered.
    fn expect(parser: *Parser, expected_tag: Component.Tag) !Ast.Index {
        const tag, const index = parser.next() orelse return parser.fail();
        return if (expected_tag == tag) index else parser.fail();
    }

    fn expectEof(parser: *Parser) !void {
        if (!parser.sequence.emptyKeepSpaces()) return parser.fail();
    }

    /// Returns true if any spaces were encountered.
    fn skipSpaces(parser: *Parser) bool {
        return parser.sequence.skipSpaces(parser.ast);
    }
};

const DataListManaged = struct {
    list: *std.ArrayList(Data),
    allocator: Allocator,

    fn len(data_list: DataListManaged) Data.ListIndex {
        return @intCast(data_list.list.items.len);
    }

    fn append(data_list: DataListManaged, code: Data) !void {
        if (data_list.list.items.len == std.math.maxInt(Data.ListIndex)) return error.OutOfMemory;
        try data_list.list.append(data_list.allocator, code);
    }

    fn appendSlice(data_list: DataListManaged, codes: []const Data) !void {
        if (codes.len > std.math.maxInt(Data.ListIndex) - data_list.list.items.len) return error.OutOfMemory;
        try data_list.list.appendSlice(data_list.allocator, codes);
    }

    fn beginComplexSelector(data_list: DataListManaged) !Data.ListIndex {
        const index = data_list.len();
        try data_list.append(undefined);
        return index;
    }

    /// `start` is the value previously returned by `beginComplexSelector`
    fn endComplexSelector(data_list: DataListManaged, start: Data.ListIndex) void {
        data_list.list.items[start] = .{ .next_complex_selector = data_list.len() };
        // NOTE: We do NOT overwrite the last trailing's combinator here.
        // parseComplexSelector encodes the pseudo-element of the rightmost compound
        // in the last trailing's combinator field (using end_none/end_before/end_after).
    }

    fn reset(data_list: DataListManaged, complex_selector_start: Data.ListIndex) void {
        data_list.list.shrinkRetainingCapacity(complex_selector_start);
    }
};

fn parseComplexSelector(parser: *Parser, data_list: DataListManaged) !?void {
    const complex_start = try data_list.beginComplexSelector();
    try parser.specificities.ensureUnusedCapacity(parser.allocator, 1);
    parser.specificity = .{};
    parser.valid = true;

    var compound_start = complex_start + 1;
    _ = parser.skipSpaces();
    parser.last_pseudo_element = .unrecognized;
    (try parseCompoundSelector(parser, data_list)) orelse return parser.fail();
    // Track the PE of the most recently successfully parsed compound.
    var last_valid_pe = parser.last_pseudo_element;

    while (true) {
        const combinator = parseCombinator(parser) orelse {
            // End of complex selector: write last trailing with PE encoding.
            const pe_combinator: selectors.Combinator = switch (last_valid_pe) {
                .before => .end_before,
                .after => .end_after,
                .unrecognized => .end_none,
            };
            try data_list.append(.{ .trailing = .{ .combinator = pe_combinator, .compound_selector_start = compound_start } });
            break;
        };
        try data_list.append(.{ .trailing = .{ .combinator = combinator, .compound_selector_start = compound_start } });

        compound_start = data_list.len();
        _ = parser.skipSpaces();
        parser.last_pseudo_element = .unrecognized;
        (try parseCompoundSelector(parser, data_list)) orelse {
            if (combinator == .descendant) {
                // Compound failed after descendant combinator (trailing space).
                // Update the previously written trailing to encode PE for last valid compound.
                const pe_combinator: selectors.Combinator = switch (last_valid_pe) {
                    .before => .end_before,
                    .after => .end_after,
                    .unrecognized => .end_none,
                };
                data_list.list.items[data_list.len() - 1].trailing.combinator = pe_combinator;
                break;
            } else {
                return parser.fail();
            }
        };
        last_valid_pe = parser.last_pseudo_element;
    }

    if (!parser.valid) {
        data_list.reset(complex_start);
        return null;
    }
    data_list.endComplexSelector(complex_start);
    parser.specificities.appendAssumeCapacity(parser.specificity);
}

/// Syntax: <combinator> = '>' | '+' | '~' | [ '|' '|' ]
fn parseCombinator(parser: *Parser) ?selectors.Combinator {
    const has_space = parser.skipSpaces();
    if (parser.accept(.token_delim)) |index| {
        switch (index.extra(parser.ast).codepoint) {
            '>' => return .child,
            '+' => return .next_sibling,
            '~' => return .subsequent_sibling,
            '|' => {
                if (parser.accept(.token_delim)) |second_pipe| {
                    if (second_pipe.extra(parser.ast).codepoint == '|') return .column;
                }
            },
            else => {},
        }
        parser.sequence.reset(index);
    }
    return if (has_space) .descendant else null;
}

fn parseCompoundSelector(parser: *Parser, data_list: DataListManaged) !?void {
    var parsed_any_selectors = false;

    if (try parseTypeSelector(parser, data_list)) |_| {
        parsed_any_selectors = true;
    }

    while (try parseSubclassSelector(parser, data_list)) |_| {
        parsed_any_selectors = true;
    }

    while (try parsePseudoElementSelector(parser, data_list)) |_| {
        parsed_any_selectors = true;
    }

    if (!parsed_any_selectors) return null;
}

fn parseTypeSelector(parser: *Parser, data_list: DataListManaged) !?void {
    const qn = parseQualifiedName(parser) orelse return null;
    const type_selector: ElementType = .{
        .namespace = switch (qn.namespace) {
            .identifier => |identifier| resolveNamespace(parser, identifier),
            .none => .none,
            .any => .any,
            .default => parser.default_namespace,
        },
        .name = switch (qn.name) {
            .identifier => |identifier| try parser.env.addTypeName(identifier.location(parser.ast), parser.source_code),
            .any => .any,
        },
    };
    try data_list.appendSlice(&.{
        .{ .simple_selector_tag = .type },
        .{ .type_selector = type_selector },
    });
    if (type_selector.name != .any) {
        parser.addSpecificity(.type);
    }
}

const QualifiedName = struct {
    namespace: Namespace,
    name: Name,

    const Namespace = union(enum) {
        identifier: Ast.Index,
        none,
        any,
        default,
    };
    const Name = union(enum) {
        identifier: Ast.Index,
        any,
    };
};

/// Syntax: <type-selector> = <wq-name> | <ns-prefix>? '*'
///         <ns-prefix>     = [ <ident-token> | '*' ]? '|'
///         <wq-name>       = <ns-prefix>? <ident-token>
///
///         Spaces are forbidden between any of these components.
fn parseQualifiedName(parser: *Parser) ?QualifiedName {
    // I consider the following grammar easier to comprehend.
    // Just like the real grammar, no spaces are allowed anywhere.
    //
    // Syntax: <type-selector> = <ns-prefix>? <type-name>
    //         <ns-prefix>     = <type-name>? '|'
    //         <type-name>     = <ident-token> | '*'

    var qn: QualifiedName = undefined;

    const tag, const index = parser.next() orelse return null;
    qn.name = name: {
        switch (tag) {
            .token_ident => break :name .{ .identifier = index },
            .token_delim => switch (index.extra(parser.ast).codepoint) {
                '*' => break :name .any,
                '|' => {
                    if (parseName(parser)) |name| {
                        return .{
                            .namespace = .none,
                            .name = name,
                        };
                    }
                },
                else => {},
            },
            else => {},
        }
        parser.sequence.reset(index);
        return null;
    };

    if (parser.accept(.token_delim)) |pipe_index| {
        if (pipe_index.extra(parser.ast).codepoint == '|') {
            if (parseName(parser)) |name| {
                qn.namespace = switch (qn.name) {
                    .identifier => |name_index| .{ .identifier = name_index },
                    .any => .any,
                };
                qn.name = name;
                return qn;
            }
        }
        parser.sequence.reset(pipe_index);
    }

    qn.namespace = .default;
    return qn;
}

/// Syntax: <ident-token> | '*'
fn parseName(parser: *Parser) ?QualifiedName.Name {
    const tag, const index = parser.next() orelse return null;
    switch (tag) {
        .token_ident => return .{ .identifier = index },
        .token_delim => if (index.extra(parser.ast).codepoint == '*') return .any,
        else => {},
    }
    parser.sequence.reset(index);
    return null;
}

fn resolveNamespace(parser: *Parser, index: Ast.Index) NamespaceId {
    const namespace_index = parser.namespaces.indexer.getFromIdentToken(.sensitive, index.location(parser.ast), parser.source_code) orelse {
        parser.valid = false;
        return undefined;
    };
    return parser.namespaces.ids.items[namespace_index];
}

fn parseSubclassSelector(parser: *Parser, data_list: DataListManaged) !?void {
    const first_component_tag, const first_component_index = parser.next() orelse return null;
    switch (first_component_tag) {
        .token_hash_id => {
            const location = first_component_index.location(parser.ast);
            const name = try parser.env.addIdName(location, parser.source_code);
            try data_list.appendSlice(&.{
                .{ .simple_selector_tag = .id },
                .{ .id_selector = name },
            });
            parser.addSpecificity(.id);
            return;
        },
        .token_delim => class_selector: {
            if (first_component_index.extra(parser.ast).codepoint != '.') break :class_selector;
            const class_name_index = parser.accept(.token_ident) orelse break :class_selector;
            const location = class_name_index.location(parser.ast);
            const name = try parser.env.addClassName(location, parser.source_code);
            try data_list.appendSlice(&.{
                .{ .simple_selector_tag = .class },
                .{ .class_selector = name },
            });
            parser.addSpecificity(.class);
            return;
        },
        .simple_block_square => {
            try parseAttributeSelector(parser, data_list, first_component_index);
            parser.addSpecificity(.attribute);
            return;
        },
        .token_colon => pseudo_class_selector: {
            // Peek ahead: if this is :not(), handle it specially to emit negated selector tags.
            // parsePseudo can't do this because it returns a PseudoClass enum, not selector data.
            const after_colon_tag, const after_colon_index = parser.next() orelse break :pseudo_class_selector;
            if (after_colon_tag == .function) {
                const fn_loc = after_colon_index.location(parser.ast);
                const is_not = parser.source_code.mapIdentifierValue(fn_loc, bool, &.{.{ "not", true }});
                if (is_not != null) {
                    try parseNotFunction(parser, data_list, after_colon_index);
                    // :not() specificity = specificity of its argument (CSS Selectors Level 3)
                    return;
                }
                // Check for :is() or :where()
                const fn_name = parser.source_code.mapIdentifierValue(fn_loc, []const u8, &.{
                    .{ "is", "is" },
                    .{ "where", "where" },
                }) orelse {
                    // Not :not/:is/:where — reset and fall through
                    parser.sequence.reset(after_colon_index);
                    const pseudo_class = parsePseudo(.class, parser) orelse break :pseudo_class_selector;
                    try data_list.appendSlice(&.{
                        .{ .simple_selector_tag = .pseudo_class },
                        .{ .pseudo_class_selector = pseudo_class },
                    });
                    parser.addSpecificity(.pseudo_class);
                    return;
                };
                if (std.mem.eql(u8, fn_name, "is")) {
                    try parseIsOrWhereFunction(parser, data_list, after_colon_index, true);
                    return;
                } else {
                    try parseIsOrWhereFunction(parser, data_list, after_colon_index, false);
                    return;
                }
            }
        },
        else => {},
    }

    parser.sequence.reset(first_component_index);
    return null;
}

fn parseAttributeSelector(parser: *Parser, data_list: DataListManaged, block_index: Ast.Index) !void {
    const sequence = parser.sequence;
    defer parser.sequence = sequence;
    parser.sequence = block_index.children(parser.ast);

    // Parse the attribute namespace and name
    _ = parser.skipSpaces();
    const qn = parseQualifiedName(parser) orelse return parser.fail();
    const attribute_selector: ElementAttribute = .{
        .namespace = switch (qn.namespace) {
            .identifier => |identifier| resolveNamespace(parser, identifier),
            .none => .none,
            .any => .any,
            .default => .none,
        },
        .name = switch (qn.name) {
            .identifier => |identifier| try parser.env.addAttributeName(identifier.location(parser.ast), parser.source_code),
            .any => return parser.fail(),
        },
    };

    _ = parser.skipSpaces();
    const after_qn_tag, const after_qn_index = parser.next() orelse {
        try data_list.appendSlice(&.{
            .{ .simple_selector_tag = .{ .attribute = null } },
            .{ .attribute_selector = attribute_selector },
        });
        return;
    };

    // Parse the attribute matcher
    const operator = operator: {
        if (after_qn_tag != .token_delim) return parser.fail();
        const codepoint = after_qn_index.extra(parser.ast).codepoint;
        const operator: selectors.AttributeOperator = switch (codepoint) {
            '=' => .equals,
            '~' => .list_contains,
            '|' => .equals_or_prefix_dash,
            '^' => .starts_with,
            '$' => .ends_with,
            '*' => .contains,
            else => return parser.fail(),
        };
        if (operator != .equals) {
            const equal_sign = try parser.expect(.token_delim);
            if (equal_sign.extra(parser.ast).codepoint != '=') return parser.fail();
        }
        break :operator operator;
    };

    // Parse the attribute value
    _ = parser.skipSpaces();
    const value_tag, const value_index = parser.next() orelse return parser.fail();
    const attribute_value = switch (value_tag) {
        .token_ident => try parser.env.addAttributeValueFromIdentToken(value_index.location(parser.ast), parser.source_code),
        .token_string => try parser.env.addAttributeValueFromStringToken(value_index.location(parser.ast), parser.source_code),
        else => return parser.fail(),
    };

    // Parse the case modifier
    _ = parser.skipSpaces();
    const case: selectors.AttributeCase = case: {
        if (parser.accept(.token_ident)) |case_index| {
            const location = case_index.location(parser.ast);
            const case = parser.source_code.mapIdentifierValue(location, selectors.AttributeCase, &.{
                .{ "i", .ignore_case },
                .{ "s", .same_case },
            }) orelse return parser.fail();
            break :case case;
        } else {
            break :case .default;
        }
    };

    _ = parser.skipSpaces();
    try parser.expectEof();
    try data_list.appendSlice(&.{
        .{ .simple_selector_tag = .{ .attribute = .{ .operator = operator, .case = case } } },
        .{ .attribute_selector = attribute_selector },
        .{ .attribute_selector_value = attribute_value },
    });
}

/// Parse the argument of :not() and emit the corresponding negated selector tag.
/// CSS Selectors Level 3: :not() accepts a single simple selector (type, id, class, or pseudo-class).
/// We emit not_class, not_id, or not_type tags that the matcher already understands.
fn parseNotFunction(parser: *Parser, data_list: DataListManaged, function_index: Ast.Index) !void {
    const saved_sequence = parser.sequence;
    defer parser.sequence = saved_sequence;
    parser.sequence = function_index.children(parser.ast);

    _ = parser.skipSpaces();
    const arg_tag, const arg_index = parser.next() orelse return;

    switch (arg_tag) {
        // :not(.class)
        .token_delim => {
            if (arg_index.extra(parser.ast).codepoint != '.') return;
            const class_name_index = parser.accept(.token_ident) orelse return;
            const name = try parser.env.addClassName(class_name_index.location(parser.ast), parser.source_code);
            try data_list.appendSlice(&.{
                .{ .simple_selector_tag = .not_class },
                .{ .class_selector = name },
            });
            parser.addSpecificity(.class);
        },
        // :not(#id)
        .token_hash_id => {
            const name = try parser.env.addIdName(arg_index.location(parser.ast), parser.source_code);
            try data_list.appendSlice(&.{
                .{ .simple_selector_tag = .not_id },
                .{ .id_selector = name },
            });
            parser.addSpecificity(.id);
        },
        // :not(type) — e.g., :not(div), :not(span)
        .token_ident => {
            const type_name = try parser.env.addTypeName(arg_index.location(parser.ast), parser.source_code);
            const element_type: Environment.ElementType = .{
                .namespace = parser.default_namespace,
                .name = type_name,
            };
            try data_list.appendSlice(&.{
                .{ .simple_selector_tag = .not_type },
                .{ .type_selector = element_type },
            });
            parser.addSpecificity(.type);
        },
        // :not(:pseudo-class) — e.g., :not(:focus), :not(:hover)
        .token_colon => {
            const pseudo_class = parsePseudo(.class, parser) orelse return;
            try data_list.appendSlice(&.{
                .{ .simple_selector_tag = .not_pseudo_class },
                .{ .pseudo_class_selector = pseudo_class },
            });
            parser.addSpecificity(.pseudo_class);
        },
        // Unsupported :not() argument (compound selectors, attribute selectors, etc.)
        // Treat as ignored — the selector still participates in the cascade.
        else => return,
    }
}

/// Parse :is() or :where() with a selector list argument.
/// Stores nested selectors in data_list and emits a NestedSelectorList reference.
fn parseIsOrWhereFunction(parser: *Parser, data_list: DataListManaged, function_index: Ast.Index, is_is: bool) Allocator.Error!void {
    const saved_sequence = parser.sequence;
    defer parser.sequence = saved_sequence;
    // Save/restore last_pseudo_element so nested selector parsing doesn't corrupt
    // the outer compound's pseudo-element tracking.
    const saved_pe = parser.last_pseudo_element;
    defer parser.last_pseudo_element = saved_pe;
    parser.sequence = function_index.children(parser.ast);

    // Remember where nested selectors start
    const nested_start: selectors.Data.ListIndex = @intCast(data_list.len());
    var selector_count: u8 = 0;

    // Parse first selector
    _ = parser.skipSpaces();
    const saved_specificities_len = parser.specificities.items.len;
    if ((parseComplexSelector(parser, data_list) catch return) != null) {} else return;
    selector_count += 1;

    // Parse additional selectors (comma-separated)
    while (true) {
        _ = parser.skipSpaces();
        const next_tag, _ = parser.next() orelse break;
        if (next_tag != .token_comma) break;
        _ = parser.skipSpaces();
        if ((parseComplexSelector(parser, data_list) catch break) != null) {} else break;
        selector_count += 1;
        if (selector_count == 255) break; // u8 max
    }

    // Emit the nested selector list reference
    const tag: Data.SimpleSelectorTag = if (is_is) .is else .where;
    const list_data = if (is_is)
        Data{ .is_selector_list = .{ .start = nested_start, .count = selector_count } }
    else
        Data{ .where_selector_list = .{ .start = nested_start, .count = selector_count } };

    try data_list.appendSlice(&.{
        .{ .simple_selector_tag = tag },
        list_data,
    });

    // Specificity handling:
    // :is() takes the highest specificity of its arguments (CSS Selectors Level 4)
    // :where() has zero specificity
    if (is_is) {
        // Find maximum specificity from all nested selectors
        var max_a: u8 = 0;
        var max_b: u8 = 0;
        var max_c: u8 = 0;
        var i = saved_specificities_len;
        while (i < parser.specificities.items.len) : (i += 1) {
            const spec = parser.specificities.items[i];
            if (spec.a > max_a) max_a = spec.a;
            if (spec.b > max_b) max_b = spec.b;
            if (spec.c > max_c) max_c = spec.c;
        }
        // Remove nested specificities and add the maximum
        parser.specificities.shrinkRetainingCapacity(saved_specificities_len);
        try parser.specificities.append(parser.allocator, .{ .a = max_a, .b = max_b, .c = max_c });
    } else {
        // :where() has zero specificity - remove all nested specificities
        parser.specificities.shrinkRetainingCapacity(saved_specificities_len);
    }
}

fn parsePseudoElementSelector(parser: *Parser, data_list: DataListManaged) !?void {
    const element_index = parser.accept(.token_colon) orelse return null;
    const pseudo_element: selectors.PseudoElement = blk: {
        if (parser.accept(.token_colon)) |_| {
            break :blk parsePseudo(.element, parser);
        } else {
            break :blk parsePseudo(.legacy_element, parser);
        }
    } orelse {
        parser.sequence.reset(element_index);
        return null;
    };
    try data_list.appendSlice(&.{
        .{ .simple_selector_tag = .pseudo_element },
        .{ .pseudo_element_selector = pseudo_element },
    });
    parser.addSpecificity(.pseudo_element);
    parser.last_pseudo_element = pseudo_element;

    while (true) {
        const class_index = parser.accept(.token_colon) orelse break;
        const pseudo_class = parsePseudo(.class, parser) orelse {
            parser.sequence.reset(class_index);
            break;
        };
        try data_list.appendSlice(&.{
            .{ .simple_selector_tag = .pseudo_class },
            .{ .pseudo_class_selector = pseudo_class },
        });
        parser.addSpecificity(.pseudo_class);
    }
}

const Pseudo = enum { element, class, legacy_element };

fn parsePseudo(comptime pseudo: Pseudo, parser: *Parser) ?switch (pseudo) {
    .element, .legacy_element => selectors.PseudoElement,
    .class => selectors.PseudoClass,
} {
    const main_component_tag, const main_component_index = parser.next() orelse return null;
    switch (main_component_tag) {
        .token_ident => {
            if (pseudo == .class) {
                // Try mapIdentifierEnum for single-word pseudo-classes first
                if (parser.source_code.mapIdentifierEnum(main_component_index.location(parser.ast), selectors.PseudoClass)) |pc| {
                    switch (pc) {
                        .root, .link, .visited, .hover, .active, .focus,
                        .enabled, .disabled, .checked, .empty,
                        => return pc,
                        .unrecognized, .ignored => {},
                        // Hyphenated names won't match via mapIdentifierEnum
                        else => {},
                    }
                }
                // Check hyphenated pseudo-class names manually
                if (matchHyphenatedPseudoClass(parser, main_component_index)) |pc| return pc;
            } else {
                // pseudo == .element or .legacy_element
                if (parser.source_code.mapIdentifierEnum(main_component_index.location(parser.ast), selectors.PseudoElement)) |pe| {
                    switch (pe) {
                        .before, .after => return pe,
                        .unrecognized => {},
                    }
                }
            }
            return unrecognizedPseudo(pseudo, parser, main_component_index);
        },
        .function => {
            // Functional pseudo-classes like :not(), :is(), :where(), :nth-child().
            // Consume arguments and treat as always-matching (.ignored) rather
            // than .unrecognized, which would cause the entire rule to be dropped.
            var function_values = main_component_index.children(parser.ast);
            if (anyValue(parser.ast, &function_values)) {
                if (pseudo == .class) return .ignored;
                return unrecognizedPseudo(pseudo, parser, main_component_index);
            }
        },
        else => {},
    }
    parser.sequence.reset(main_component_index);
    return null;
}

/// Match hyphenated pseudo-class names like :first-child, :last-child, :only-child, :first-of-type.
/// These can't be matched by mapIdentifierEnum because it uses enum field names (underscores).
fn matchHyphenatedPseudoClass(parser: *Parser, index: Ast.Index) ?selectors.PseudoClass {
    var it = parser.source_code.identTokenIterator(index.location(parser.ast));
    // Read into a small buffer for comparison
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    while (it.next()) |cp| {
        if (cp > 127 or len >= buf.len) return null; // Not ASCII or too long
        buf[len] = @intCast(cp | 0x20); // Lowercase
        len += 1;
    }
    const name = buf[0..len];
    const map = .{
        .{ "first-child", selectors.PseudoClass.first_child },
        .{ "last-child", selectors.PseudoClass.last_child },
        .{ "only-child", selectors.PseudoClass.only_child },
        .{ "first-of-type", selectors.PseudoClass.first_of_type },
        .{ "focus-visible", selectors.PseudoClass.focus }, // treat focus-visible as focus (never matches in static)
        .{ "read-only", selectors.PseudoClass.ignored }, // :read-only - treat as always-matching
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// Returns true if the sequence matches the grammar of <any-value>.
fn anyValue(ast: Ast, sequence: *Ast.Sequence) bool {
    while (sequence.nextKeepSpaces(ast)) |index| {
        switch (index.tag(ast)) {
            .token_bad_string, .token_bad_url, .token_right_paren, .token_right_square, .token_right_curly => return false,
            else => {},
        }
    }
    return true;
}

fn unrecognizedPseudo(comptime pseudo: Pseudo, parser: *Parser, main_component_index: Ast.Index) ?switch (pseudo) {
    .element, .legacy_element => selectors.PseudoElement,
    .class => selectors.PseudoClass,
} {
    zss.log.warn("Ignoring unsupported pseudo {s}: {f}", .{
        switch (pseudo) {
            .element, .legacy_element => "element",
            .class => "class",
        },
        parser.source_code.formatIdentToken(main_component_index.location(parser.ast)),
    });
    return .unrecognized;
}
