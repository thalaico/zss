/// The set of namespace prefixes and their corresponding namespace ids.
namespaces: Namespaces,
/// URLs found while parsing declaration blocks.
decl_urls: Urls,
cascade_source: cascade.Source,

pub const Namespaces = struct {
    indexer: zss.Utf8StringInterner = .init(.{ .max_size = NamespaceId.max_unique_values, .case = .sensitive }),
    /// Maps namespace prefixes to namespace ids.
    ids: std.ArrayListUnmanaged(NamespaceId) = .empty,
    /// The default namespace, or `null` if there is no default namespace.
    default: ?NamespaceId = null,

    pub fn deinit(namespaces: *Namespaces, allocator: Allocator) void {
        namespaces.indexer.deinit(allocator);
        namespaces.ids.deinit(allocator);
    }
};

const Stylesheet = @This();

const zss = @import("zss.zig");
const cascade = zss.cascade;
const Ast = zss.syntax.Ast;
const AtRule = zss.syntax.Token.AtRule;
const Declarations = zss.Declarations;
const Environment = zss.Environment;
const Importance = Declarations.Importance;
const NamespaceId = Environment.Namespaces.Id;
const SourceCode = zss.syntax.SourceCode;
const Urls = zss.values.parse.Urls;

const selectors = zss.selectors;
const Specificity = selectors.Specificity;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Releases all resources associated with the stylesheet.
pub fn deinit(stylesheet: *Stylesheet, allocator: Allocator) void {
    stylesheet.namespaces.deinit(allocator);
    stylesheet.decl_urls.deinit(allocator);
    stylesheet.cascade_source.deinit(allocator);
}

/// One `@font-face` rule (CSS Fonts 4 §4): its descriptors as written.
pub const FontFaceRule = struct {
    descriptors: []const Descriptor,

    pub const Descriptor = struct {
        /// ASCII-lowercased.
        name: []const u8,
        /// The value's source text, without surrounding whitespace.
        value: []const u8,
    };

    /// The value of the descriptor `name`; a repeated descriptor's last
    /// declaration wins, as in any declaration block.
    pub fn get(rule: FontFaceRule, name: []const u8) ?[]const u8 {
        var i = rule.descriptors.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, rule.descriptors[i].name, name)) return rule.descriptors[i].value;
        }
        return null;
    }
};

/// The `@font-face` rules of the style sheet in `ast` that apply — those at
/// the top level and those inside `@media` / `@supports` rules whose
/// condition holds for `env` — in order. Everything returned is allocated
/// with `arena`. A host runs this before `create`, because the names of the
/// families the rules define decide how `font-family` values are parsed
/// (`Environment.custom_font_names`).
pub fn collectFontFaceRules(
    allocator: Allocator,
    arena: Allocator,
    ast: Ast,
    rule_list_index: Ast.Index,
    source_code: SourceCode,
    env: *Environment,
) ![]const FontFaceRule {
    var stylesheet = Stylesheet{ .namespaces = .{}, .decl_urls = .init(env), .cascade_source = .{} };
    defer stylesheet.deinit(allocator);
    var collector: FontFaceCollector = .{ .arena = arena };
    var ctx = RuleProcessor{
        .allocator = allocator,
        .ast = ast,
        .source_code = source_code,
        .env = env,
        .stylesheet = &stylesheet,
        .selector_parser = selectors.Parser.init(env, allocator, source_code, ast, &stylesheet.namespaces),
        .unsorted_selectors = .{},
        .font_faces = &collector,
    };
    defer ctx.selector_parser.deinit();
    defer ctx.unsorted_selectors.deinit(allocator);
    try ctx.processRuleList(rule_list_index);
    return collector.rules.items;
}

const FontFaceCollector = struct {
    arena: Allocator,
    rules: std.ArrayListUnmanaged(FontFaceRule) = .empty,
};

pub fn parseAndCreate(allocator: Allocator, source_code: SourceCode, env: *Environment) !Stylesheet {
    var parser = zss.syntax.Parser.init(source_code, allocator);
    defer parser.deinit();
    var ast, const rule_list_index = try parser.parseCssStylesheet(allocator);
    defer ast.deinit(allocator);
    return create(allocator, ast, rule_list_index, source_code, env);
}

/// Create a `Stylesheet` from an Ast `rule_list` node.
/// Free using `deinit`.
pub fn create(
    allocator: Allocator,
    ast: Ast,
    rule_list_index: Ast.Index,
    source_code: SourceCode,
    env: *Environment,
) !Stylesheet {
    var stylesheet = Stylesheet{
        .namespaces = .{},
        .decl_urls = .init(env),
        .cascade_source = .{},
    };
    errdefer stylesheet.deinit(allocator);

    var ctx = RuleProcessor{
        .allocator = allocator,
        .ast = ast,
        .source_code = source_code,
        .env = env,
        .stylesheet = &stylesheet,
        .selector_parser = selectors.Parser.init(env, allocator, source_code, ast, &stylesheet.namespaces),
        .unsorted_selectors = .{},
    };
    defer ctx.selector_parser.deinit();
    defer ctx.unsorted_selectors.deinit(allocator);

    try ctx.processRuleList(rule_list_index);

    stylesheet.decl_urls.commit(env);

    const unsorted_selectors_slice = ctx.unsorted_selectors.slice();

    // Sort the selectors such that items with a higher cascade order appear earlier in each list.
    for ([_]Importance{ .important, .normal }) |importance| {
        const list = switch (importance) {
            .important => &stylesheet.cascade_source.selectors_important,
            .normal => &stylesheet.cascade_source.selectors_normal,
        };
        const SortContext = struct {
            selector_number: []const selectors.Data.ListIndex,
            blocks: []const Declarations.Block,
            specificities: []const Specificity,

            pub fn lessThan(sort_ctx: @This(), a_index: usize, b_index: usize) bool {
                const a_spec = sort_ctx.specificities[sort_ctx.selector_number[a_index]];
                const b_spec = sort_ctx.specificities[sort_ctx.selector_number[b_index]];
                switch (a_spec.order(b_spec)) {
                    .lt => return false,
                    .gt => return true,
                    .eq => {},
                }

                const a_block = sort_ctx.blocks[a_index];
                const b_block = sort_ctx.blocks[b_index];
                return b_block.earlierThan(a_block);
            }
        };
        list.sortUnstable(SortContext{
            .selector_number = list.items(.selector),
            .blocks = list.items(.block),
            .specificities = unsorted_selectors_slice.items(.specificity),
        });

        for (list.items(.selector)) |*selector_index| {
            selector_index.* = unsorted_selectors_slice.items(.index)[selector_index.*];
        }
    }

    return stylesheet;
}

/// Mutable context for processing CSS rules during stylesheet creation.
/// Extracted so @media can recursively process nested rule lists.
const RuleProcessor = struct {
    allocator: Allocator,
    ast: Ast,
    source_code: SourceCode,
    env: *Environment,
    stylesheet: *Stylesheet,
    selector_parser: selectors.Parser,
    unsorted_selectors: std.MultiArrayList(struct { index: selectors.Data.ListIndex, specificity: Specificity }),
    /// Set by `collectFontFaceRules`: the pass only gathers `@font-face`
    /// rules; style rules and `@namespace` are left to `create`.
    font_faces: ?*FontFaceCollector = null,

    /// Process all rules in a rule_list AST node.
    fn processRuleList(ctx: *RuleProcessor, rule_list_index: Ast.Index) anyerror!void {
        assert(rule_list_index.tag(ctx.ast) == .rule_list);
        var rule_sequence = rule_list_index.children(ctx.ast);
        while (rule_sequence.nextSkipSpaces(ctx.ast)) |index| {
            switch (index.tag(ctx.ast)) {
                .at_rule => {
                    const at_rule = index.extra(ctx.ast).at_rule orelse {
                        zss.log.warn("Ignoring unknown at-rule: @{f}", .{ctx.source_code.formatAtKeywordToken(index.location(ctx.ast))});
                        continue;
                    };
                    ctx.handleAtRule(at_rule, index) catch |err| switch (err) {
                        error.InvalidAtRule => {
                            zss.log.warn("Ignoring invalid @{s} at-rule", .{@tagName(at_rule)});
                            continue;
                        },
                        error.UnrecognizedAtRule => {
                            zss.log.warn("Ignoring unknown at-rule: @{s}", .{@tagName(at_rule)});
                            continue;
                        },
                        else => |e| return e,
                    };
                },
                .qualified_rule => {
                    if (ctx.font_faces == null) try ctx.processQualifiedRule(index);
                },
                else => unreachable,
            }
        }
    }

    /// Process a single qualified rule (selector + declarations).
    fn processQualifiedRule(ctx: *RuleProcessor, index: Ast.Index) !void {
        const selector_sequence = ctx.ast.qualifiedRulePrelude(index);
        const first_complex_selector: selectors.Data.ListIndex = @intCast(ctx.stylesheet.cascade_source.selector_data.items.len);
        ctx.selector_parser.parseComplexSelectorList(&ctx.stylesheet.cascade_source.selector_data, ctx.allocator, selector_sequence) catch |err| switch (err) {
            error.ParseError => return,
            else => |e| return e,
        };

        // Parse the style block
        const last_declaration = selector_sequence.end.extra(ctx.ast).index;
        var buffer: [zss.property.recommended_buffer_size]u8 = undefined;
        const decl_block = try zss.property.parseDeclarationsFromAst(ctx.env, ctx.ast, ctx.source_code, &buffer, last_declaration, ctx.stylesheet.decl_urls.toManaged(ctx.allocator));

        var index_of_complex_selector = first_complex_selector;
        const selector_data_len = ctx.stylesheet.cascade_source.selector_data.items.len;
        for (ctx.selector_parser.specificities.items) |specificity| {
            // Defensive bounds check: in some cases `specificities.items.len`
            // can exceed the length of the `next_complex_selector` chain
            // appended to `selector_data` for this rule. Observed on
            // lobste.rs where `:focus-visible` and `:first-child` selectors
            // emit parse warnings and leave specificities/selector_data out
            // of sync, panicking at index 973 of 973 items. Break cleanly
            // rather than reading past the end.
            if (index_of_complex_selector >= selector_data_len) {
                zss.log.warn("Selector specificity/data mismatch — skipping remaining selectors in rule", .{});
                break;
            }
            const selector_number: selectors.Data.ListIndex = @intCast(ctx.unsorted_selectors.len);
            try ctx.unsorted_selectors.append(ctx.allocator, .{ .index = index_of_complex_selector, .specificity = specificity });

            for ([_]Importance{ .important, .normal }) |importance| {
                const destination_list = switch (importance) {
                    .important => &ctx.stylesheet.cascade_source.selectors_important,
                    .normal => &ctx.stylesheet.cascade_source.selectors_normal,
                };
                if (!ctx.env.decls.hasValues(decl_block, importance)) continue;

                try destination_list.append(ctx.allocator, .{
                    // Temporarily store the selector number; after sorting, this is replaced with the selector index.
                    .selector = selector_number,
                    .block = decl_block,
                });
            }

            index_of_complex_selector = ctx.stylesheet.cascade_source.selector_data.items[index_of_complex_selector].next_complex_selector;
        }
        // Note: if we broke early due to a selector/specificity length
        // mismatch, index_of_complex_selector may be < items.len. That's
        // non-fatal — we've processed what we could.
        assert(index_of_complex_selector <= ctx.stylesheet.cascade_source.selector_data.items.len);
    }

    /// Handle a recognized at-rule.
    fn handleAtRule(ctx: *RuleProcessor, at_rule: AtRule, at_rule_index: Ast.Index) !void {
        switch (at_rule) {
            .import => return error.UnrecognizedAtRule,
            .namespace => {
                if (ctx.font_faces != null) return;
                try handleNamespace(ctx.stylesheet, ctx.allocator, ctx.ast, ctx.source_code, ctx.env, at_rule_index);
            },
            .media => {
                try ctx.handleMediaRule(at_rule_index);
            },
            .supports => {
                try ctx.handleSupportsRule(at_rule_index);
            },
            .@"font-face" => {
                if (ctx.font_faces) |collector| try ctx.collectFontFace(collector, at_rule_index);
            },
        }
    }

    /// `@font-face { <declaration-list> }`: record each `name: value`
    /// declaration of the block. The block is a list of component values;
    /// declarations end at top-level semicolons (CSS Syntax 3 §5.4.5).
    fn collectFontFace(ctx: *RuleProcessor, collector: *FontFaceCollector, at_rule_index: Ast.Index) !void {
        var children = at_rule_index.children(ctx.ast);
        const block = while (children.nextSkipSpaces(ctx.ast)) |child| {
            if (child.tag(ctx.ast) == .simple_block_curly) break child;
        } else return;
        const text = ctx.source_code.text;
        // The end of the block: its closing brace, or the end of the text.
        const block_end: usize = blk: {
            var tokenizer = zss.syntax.Tokenizer.init(ctx.source_code);
            tokenizer.setLocation(block.location(ctx.ast));
            var depth: usize = 0;
            while (true) {
                const token, const location = (tokenizer.next() catch break :blk text.len) orelse break :blk text.len;
                switch (token) {
                    .token_left_curly, .token_left_paren, .token_left_square, .token_function => depth += 1,
                    .token_right_curly, .token_right_paren, .token_right_square => {
                        depth -|= 1;
                        if (depth == 0) break :blk @intFromEnum(location);
                    },
                    else => {},
                }
            }
        };

        var descriptors: std.ArrayListUnmanaged(FontFaceRule.Descriptor) = .empty;
        var contents = block.children(ctx.ast);
        while (true) {
            // One declaration: <ident> : <value> up to the next top-level `;`.
            const name_index = contents.nextSkipSpaces(ctx.ast) orelse break;
            var colon: ?Ast.Index = null;
            var end: usize = block_end;
            if (name_index.tag(ctx.ast) == .token_semicolon) continue;
            var first = true;
            var more = false;
            while (contents.nextKeepSpaces(ctx.ast)) |component| {
                switch (component.tag(ctx.ast)) {
                    .token_semicolon => {
                        end = @intFromEnum(component.location(ctx.ast));
                        more = true;
                        break;
                    },
                    .token_whitespace, .token_comments => {},
                    else => |tag| {
                        if (first and tag == .token_colon) colon = component;
                        first = false;
                    },
                }
            }
            if (name_index.tag(ctx.ast) == .token_ident) {
                if (colon) |colon_index| {
                    const name = try ctx.source_code.copyIdentifier(name_index.location(ctx.ast), .{ .allocator = collector.arena });
                    for (name) |*ch| ch.* = std.ascii.toLower(ch.*);
                    const value_start = @intFromEnum(colon_index.location(ctx.ast)) + 1;
                    const value = std.mem.trim(u8, text[@min(value_start, end)..end], " \t\r\n\x0c");
                    try descriptors.append(collector.arena, .{ .name = name, .value = try collector.arena.dupe(u8, value) });
                }
            }
            if (!more) break;
        }
        try collector.rules.append(collector.arena, .{ .descriptors = descriptors.items });
    }

    /// @media (CSS Conditional 3 §5): process the contained rules if the media
    /// query list in the prelude matches the environment's device.
    fn handleMediaRule(ctx: *RuleProcessor, at_rule_index: Ast.Index) !void {
        var prelude = at_rule_index.children(ctx.ast);
        var rule_list: ?Ast.Index = null;
        var probe = prelude;
        while (probe.nextKeepSpaces(ctx.ast)) |child| {
            if (child.tag(ctx.ast) == .rule_list) {
                rule_list = child;
                prelude.end = child;
                break;
            }
        }
        // @media without a block.
        const nested_rule_list = rule_list orelse return;
        const device = ctx.env.mediaDevice();
        if (device.configured) {
            var queries = try zss.media.QueryList.parseSequence(ctx.allocator, ctx.ast, ctx.source_code, prelude);
            defer queries.deinit();
            if (!queries.matches(ctx.allocator, device)) return;
        }
        try ctx.processRuleList(nested_rule_list);
    }

    /// @supports (CSS Conditional 3 §6): process the contained rules if the
    /// condition in the prelude holds. A prelude that is not a
    /// <supports-condition> makes the whole rule invalid.
    fn handleSupportsRule(ctx: *RuleProcessor, at_rule_index: Ast.Index) !void {
        var prelude = at_rule_index.children(ctx.ast);
        var rule_list: ?Ast.Index = null;
        var probe = prelude;
        while (probe.nextKeepSpaces(ctx.ast)) |child| {
            if (child.tag(ctx.ast) == .rule_list) {
                rule_list = child;
                prelude.end = child;
                break;
            }
        }
        const nested_rule_list = rule_list orelse return;
        const holds = (try ctx.supportsCondition(&prelude)) orelse return error.InvalidAtRule;
        if (holds) try ctx.processRuleList(nested_rule_list);
    }

    /// <supports-condition> = not <supports-in-parens>
    ///                      | <supports-in-parens> [ and <supports-in-parens> ]*
    ///                      | <supports-in-parens> [ or <supports-in-parens> ]*
    /// Consumes all of `sequence`. Null if it does not match the grammar.
    fn supportsCondition(ctx: *RuleProcessor, sequence: *Ast.Sequence) anyerror!?bool {
        const first = sequence.nextSkipSpaces(ctx.ast) orelse return null;
        if (first.tag(ctx.ast) == .token_ident and ctx.source_code.identifierEqlIgnoreCase(first.location(ctx.ast), "not")) {
            const operand = sequence.nextSkipSpaces(ctx.ast) orelse return null;
            const value = (try ctx.supportsInParens(operand)) orelse return null;
            if (!sequence.emptySkipSpaces(ctx.ast)) return null;
            return !value;
        }
        var result = (try ctx.supportsInParens(first)) orelse return null;
        const Op = enum { @"and", @"or" };
        var op: ?Op = null;
        while (sequence.nextSkipSpaces(ctx.ast)) |keyword| {
            if (keyword.tag(ctx.ast) != .token_ident) return null;
            const this_op = ctx.source_code.mapIdentifierValue(keyword.location(ctx.ast), Op, &.{
                .{ "and", .@"and" },
                .{ "or", .@"or" },
            }) orelse return null;
            // and/or may not be mixed without parentheses.
            if (op != null and op.? != this_op) return null;
            op = this_op;
            const operand = sequence.nextSkipSpaces(ctx.ast) orelse return null;
            const value = (try ctx.supportsInParens(operand)) orelse return null;
            result = switch (this_op) {
                .@"and" => result and value,
                .@"or" => result or value,
            };
        }
        return result;
    }

    /// <supports-in-parens> = ( <supports-condition> ) | <supports-feature> | <general-enclosed>
    /// <supports-feature> = <supports-selector-fn> | ( <declaration> )
    /// <general-enclosed> (any other ()-block or function) is false.
    fn supportsInParens(ctx: *RuleProcessor, index: Ast.Index) anyerror!?bool {
        switch (index.tag(ctx.ast)) {
            .simple_block_paren => {
                var inner = index.children(ctx.ast);
                var look = inner;
                const head = look.nextSkipSpaces(ctx.ast) orelse return false;
                if (head.tag(ctx.ast) == .token_ident) {
                    if (look.nextSkipSpaces(ctx.ast)) |after| {
                        if (after.tag(ctx.ast) == .token_colon) return try ctx.supportsDeclaration(index);
                    }
                }
                return (try ctx.supportsCondition(&inner)) orelse false;
            },
            .function => {
                if (ctx.source_code.identifierEqlIgnoreCase(index.location(ctx.ast), "selector")) {
                    return try ctx.supportsSelector(index);
                }
                return false;
            },
            else => return null,
        }
    }

    /// ( <declaration> ): supported if this implementation parses the
    /// property and value (a custom property, or a value with var(), always
    /// parses). The text between the parentheses is parsed as a one-declaration
    /// style block, the way `zss.custom_properties` parses substituted values.
    fn supportsDeclaration(ctx: *RuleProcessor, block_index: Ast.Index) !bool {
        const text = ctx.source_code.text;
        const open: u32 = @intFromEnum(block_index.location(ctx.ast));
        var tokenizer = zss.syntax.Tokenizer.init(ctx.source_code);
        tokenizer.setLocation(@enumFromInt(open + 1));
        var depth: usize = 1;
        const close: u32 = while (true) {
            const token, const location = (tokenizer.next() catch return false) orelse return false;
            switch (token) {
                .token_left_paren, .token_function => depth += 1,
                .token_right_paren => {
                    depth -= 1;
                    if (depth == 0) break @intFromEnum(location);
                },
                else => {},
            }
        };
        return declarationParses(ctx.allocator, ctx.env, text[open + 1 .. close], .any);
    }

    /// selector( <complex-selector> ) (CSS Conditional 4 §6.1): supported if
    /// the selector parses and uses nothing this implementation cannot match.
    fn supportsSelector(ctx: *RuleProcessor, function_index: Ast.Index) !bool {
        var data_list: std.ArrayList(selectors.Data) = .empty;
        defer data_list.deinit(ctx.allocator);
        ctx.selector_parser.parseComplexSelectorList(&data_list, ctx.allocator, function_index.children(ctx.ast)) catch |err| switch (err) {
            error.ParseError => return false,
            else => |e| return e,
        };
        if (ctx.selector_parser.specificities.items.len != 1) return false;
        return !selectors.complexSelectorHasUnsupported(data_list.items, 0);
    }
};

/// Whether `declaration` ("property: value") is one declaration this
/// implementation parses (a custom property, or a value with var(), always
/// parses): `@supports (declaration)`, `CSS.supports()`. It is parsed as a
/// one-declaration style block, the way `zss.custom_properties` parses
/// substituted values; `env` only gains an unreferenced declaration block.
fn declarationParses(allocator: Allocator, env: *Environment, declaration: []const u8, importance: enum { any, normal }) !bool {
    const source_text = try std.fmt.allocPrint(allocator, "x{{{s}}}", .{declaration});
    defer allocator.free(source_text);
    const source = SourceCode.init(source_text) catch return false;
    var parser = zss.syntax.Parser.init(source, env.allocator);
    defer parser.deinit();
    var ast, const rules_index = parser.parseCssStylesheet(env.allocator) catch return false;
    defer ast.deinit(env.allocator);
    var rules = rules_index.children(ast);
    const rule = rules.nextSkipSpaces(ast) orelse return false;
    if (rule.tag(ast) != .qualified_rule) return false;
    // One rule: the declaration did not close the block.
    if (rules.nextSkipSpaces(ast) != null) return false;
    const last_declaration = ast.qualifiedRulePrelude(rule).end.extra(ast).index;
    // Exactly one declaration.
    if (@intFromEnum(last_declaration) == 0) return false;
    if (@intFromEnum(last_declaration.extra(ast).index) != 0) return false;
    var buffer: [zss.property.recommended_buffer_size]u8 = undefined;
    var urls = Urls.init(env);
    defer urls.deinit(env.allocator);
    const block = try zss.property.parseDeclarationsFromAst(env, ast, source, &buffer, last_declaration, urls.toManaged(env.allocator));
    return switch (importance) {
        .any => env.decls.hasValues(block, .normal) or env.decls.hasValues(block, .important),
        .normal => env.decls.hasValues(block, .normal),
    };
}

/// `CSS.supports(conditionText)` (CSS Conditional 3 §6.1): whether
/// `condition_text`, parsed and evaluated as a <supports-condition> — or,
/// failing that, wrapped in parentheses — is true.
pub fn supportsConditionText(allocator: Allocator, env: *Environment, condition_text: []const u8) !bool {
    if (try evaluateSupportsCondition(allocator, env, condition_text) orelse false) return true;
    const wrapped = try std.fmt.allocPrint(allocator, "({s})", .{condition_text});
    defer allocator.free(wrapped);
    return try evaluateSupportsCondition(allocator, env, wrapped) orelse false;
}

/// `text` parsed as a list of component values (CSS Syntax 3 §5.3.10) and
/// evaluated as a <supports-condition>; null if it does not match the
/// grammar.
fn evaluateSupportsCondition(allocator: Allocator, env: *Environment, text: []const u8) !?bool {
    const source = SourceCode.init(text) catch return null;
    var parser = zss.syntax.Parser.init(source, allocator);
    defer parser.deinit();
    var ast, const list = parser.parseListOfComponentValues(allocator) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return null,
    };
    defer ast.deinit(allocator);
    var stylesheet = Stylesheet{ .namespaces = .{}, .decl_urls = .init(env), .cascade_source = .{} };
    defer stylesheet.deinit(allocator);
    var ctx = RuleProcessor{
        .allocator = allocator,
        .ast = ast,
        .source_code = source,
        .env = env,
        .stylesheet = &stylesheet,
        .selector_parser = selectors.Parser.init(env, allocator, source, ast, &stylesheet.namespaces),
        .unsorted_selectors = .{},
    };
    defer ctx.selector_parser.deinit();
    defer ctx.unsorted_selectors.deinit(allocator);
    var sequence = list.children(ast);
    return ctx.supportsCondition(&sequence);
}

/// `CSS.supports(property, value)` (CSS Conditional 3 §6.1): whether
/// `property` is a supported property (ASCII case-insensitive) or a custom
/// property name and `value` parses for it. `value` must be a value alone:
/// no `!important`, nothing that ends the declaration or its block.
pub fn supportsPropertyValue(allocator: Allocator, env: *Environment, property: []const u8, value: []const u8) !bool {
    // The property: one <ident-token>.
    {
        const source = SourceCode.init(property) catch return false;
        var tokenizer = zss.syntax.Tokenizer.init(source);
        const first, _ = (tokenizer.next() catch return false) orelse return false;
        if (first != .token_ident) return false;
        if ((tokenizer.next() catch return false) != null) return false;
    }
    // The value: balanced, with no `;` and no `{}` block outside a function
    // or block (they would end or nest the declaration).
    {
        const source = SourceCode.init(value) catch return false;
        var tokenizer = zss.syntax.Tokenizer.init(source);
        var depth: usize = 0;
        while (tokenizer.next() catch return false) |next| {
            const token, _ = next;
            switch (token) {
                .token_left_paren, .token_left_square, .token_function => depth += 1,
                .token_right_paren, .token_right_square => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .token_left_curly, .token_right_curly => return false,
                .token_semicolon => if (depth == 0) return false,
                else => {},
            }
        }
    }
    const declaration = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ property, value });
    defer allocator.free(declaration);
    return declarationParses(allocator, env, declaration, .normal);
}

/// Handle @namespace at-rule (separated because it doesn't need RuleProcessor context).
fn handleNamespace(
    stylesheet: *Stylesheet,
    allocator: Allocator,
    ast: Ast,
    source_code: SourceCode,
    env: *Environment,
    at_rule_index: Ast.Index,
) !void {
    // TODO: There are rules involving how some at-rules must be ordered
    //       Example 1: @namespace rules must come after @charset and @import
    //       Example 2: @import and @namespace must come before any other non-ignored at-rules and style rules

    const parse = zss.values.parse;
    var parse_ctx: parse.Context = .init(ast, source_code);

    // Spec: CSS Namespaces Level 3 Editor's Draft
    // Syntax: <namespace-prefix>? [ <string> | <url> ]
    //         <namespace-prefix> = <ident>

    parse_ctx.initSequence(at_rule_index.children(ast));
    const prefix_or_null = parse.identifier(&parse_ctx);
    const namespace: Environment.NamespaceLocation =
        if (parse.string(&parse_ctx)) |location|
            .{ .string_token = location }
        else if (parse.url(&parse_ctx)) |url|
            switch (url) {
                .string_token => |location| .{ .string_token = location },
                .url_token => |location| .{ .url_token = location },
            }
        else
            return error.InvalidAtRule;
    if (!parse_ctx.empty()) return error.InvalidAtRule;

    const id = try env.addNamespaceFromToken(namespace, source_code);
    if (prefix_or_null) |prefix| {
        const index = try stylesheet.namespaces.indexer.addFromIdentToken(.sensitive, allocator, prefix, source_code);
        if (index == stylesheet.namespaces.ids.items.len) {
            try stylesheet.namespaces.ids.append(allocator, id);
        } else {
            // NOTE: Later @namespace rules override previous ones.
            stylesheet.namespaces.ids.items[index] = id;
        }
    } else {
        // NOTE: Later @namespace rules override previous ones.
        stylesheet.namespaces.default = id;
    }
}

test "create a stylesheet" {
    const allocator = std.testing.allocator;

    const input =
        \\@charset "utf-8";
        \\@import "import.css";
        \\@namespace test "example.com";
        \\@namespace test src("foo.bar");
        \\@namespace src("xyz");
        \\@namespace url(xyz);
        \\@namespace url("xyz");
        \\test {display: block}
    ;
    const source_code = try SourceCode.init(input);

    var ast, const rule_list_index = blk: {
        var parser = zss.syntax.Parser.init(source_code, allocator);
        defer parser.deinit();
        break :blk try parser.parseCssStylesheet(allocator);
    };
    defer ast.deinit(allocator);

    var env = Environment.init(allocator, &.empty_document, .all_insensitive, .no_quirks);
    defer env.deinit();

    var stylesheet = try create(allocator, ast, rule_list_index, source_code, &env);
    defer stylesheet.deinit(allocator);
}

test "@media rule processing" {
    const allocator = std.testing.allocator;

    const input =
        \\div { color: red; }
        \\@media screen and (min-width: 300px) {
        \\  #hnmain { min-width: 0; width: 100%; }
        \\}
        \\@media print {
        \\  body { display: none; }
        \\}
    ;
    const source_code = try SourceCode.init(input);

    var ast, const rule_list_index = blk: {
        var parser = zss.syntax.Parser.init(source_code, allocator);
        defer parser.deinit();
        break :blk try parser.parseCssStylesheet(allocator);
    };
    defer ast.deinit(allocator);

    var env = Environment.init(allocator, &.empty_document, .all_insensitive, .no_quirks);
    defer env.deinit();

    // Set viewport to 800x600 — the @media screen rule should match,
    // but @media print should not.
    env.viewport_width_px = 800;
    env.viewport_height_px = 600;
    env.viewport_configured = true;

    var stylesheet = try create(allocator, ast, rule_list_index, source_code, &env);
    defer stylesheet.deinit(allocator);

    // We should have selectors from "div" and "#hnmain" (2 rules),
    // but NOT from "body" (inside @media print).
    // The cascade_source should have selector data for the matching rules.
    const total_selectors = stylesheet.cascade_source.selectors_normal.len +
        stylesheet.cascade_source.selectors_important.len;
    // div + #hnmain = 2 normal selectors (no !important)
    try std.testing.expect(total_selectors == 2);
}
