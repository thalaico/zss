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
                    try ctx.processQualifiedRule(index);
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
        for (ctx.selector_parser.specificities.items) |specificity| {
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
        assert(index_of_complex_selector == ctx.stylesheet.cascade_source.selector_data.items.len);
    }

    /// Handle a recognized at-rule.
    fn handleAtRule(ctx: *RuleProcessor, at_rule: AtRule, at_rule_index: Ast.Index) !void {
        switch (at_rule) {
            .import => return error.UnrecognizedAtRule,
            .namespace => {
                try handleNamespace(ctx.stylesheet, ctx.allocator, ctx.ast, ctx.source_code, ctx.env, at_rule_index);
            },
            .media => {
                try ctx.handleMediaRule(at_rule_index);
            },
        }
    }

    /// Handle @media: evaluate the condition, and if it matches, process the
    /// contained rule list recursively.
    fn handleMediaRule(ctx: *RuleProcessor, at_rule_index: Ast.Index) !void {
        const media = zss.media;

        // Extract the media condition text from the source code.
        // The at-rule's children are: prelude tokens + rule_list node.
        // We find the rule_list child and extract the prelude text between
        // the @media keyword location and the rule_list's location.
        var children = at_rule_index.children(ctx.ast);
        var rule_list_child: ?Ast.Index = null;

        while (children.nextKeepSpaces(ctx.ast)) |child| {
            if (child.tag(ctx.ast) == .rule_list) {
                rule_list_child = child;
                break;
            }
        }

        const nested_rule_list = rule_list_child orelse {
            // @media without a block — skip silently.
            return;
        };

        // Extract prelude text from source. The at-rule location is at '@',
        // so skip past "@media" (6 bytes) to get the condition text.
        // The rule_list location is at '{', so the condition is between them.
        const at_loc = @intFromEnum(at_rule_index.location(ctx.ast));
        const block_loc = @intFromEnum(nested_rule_list.location(ctx.ast));

        // Skip "@media" prefix (6 chars). Guard against malformed input.
        const prelude_start = @min(at_loc + 6, @as(u32, @intCast(ctx.source_code.text.len)));
        const prelude_end = @min(block_loc, @as(u32, @intCast(ctx.source_code.text.len)));

        const condition = if (prelude_start < prelude_end)
            std.mem.trim(u8, ctx.source_code.text[prelude_start..prelude_end], " \t\n\r")
        else
            "";

        const viewport: media.Viewport = .{
            .width_px = ctx.env.viewport_width_px,
            .height_px = ctx.env.viewport_height_px,
        };

        if (!media.evaluate(condition, viewport)) {
            return; // Media condition doesn't match — skip this block.
        }

        // Condition matches — process the contained rules.
        try ctx.processRuleList(nested_rule_list);
    }
};

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
