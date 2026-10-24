//! Custom properties and var() substitution (CSS Variables 1 §2-3), run
//! once after the cascade.
//!
//! The cascade gives each element its own declared custom properties
//! (`Storage.custom_properties`, first declaration wins) and, for every
//! declaration whose value contains var(), the property fields it won
//! (`Storage.pending`; they hold `unset` meanwhile). This pass visits the
//! document in tree order:
//!
//! - an element's computed custom properties are its parent's (inherited,
//!   already computed) plus its own with var() substituted against them.
//!   A reference cycle, or a var() with no value and no fallback, makes the
//!   property invalid at computed-value time: the guaranteed-invalid value,
//!   so the name is treated as undefined (§2.3, §3.1);
//! - each pending declaration's value is substituted and then parsed by its
//!   property's parser; if substitution or parsing fails the declaration is
//!   invalid at computed-value time and its fields stay `unset` (§3.1).
//!
//! ::before / ::after storages are resolved against their element.
//! Parsed values are shared between elements with the same property and
//! substituted text, and across cascade runs (`Environment.substituted_blocks`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const zss = @import("zss.zig");
const Environment = zss.Environment;
const NodeId = Environment.NodeId;
const Storage = zss.cascade.Database.Storage;
const Declarations = zss.Declarations;

pub const Map = std.StringHashMapUnmanaged([]const u8);

pub fn resolve(env: *Environment) !void {
    const root = env.root_node orelse return;
    var resolver: Resolver = .{ .env = env, .arena = env.cascade_db.custom_arena.promote(env.allocator) };
    defer resolver.deinit();

    const Entry = struct { node: NodeId, parent_map: ?*const Map };
    var stack: std.ArrayListUnmanaged(Entry) = .empty;
    defer stack.deinit(env.allocator);
    try stack.append(env.allocator, .{ .node = root, .parent_map = null });
    while (stack.pop()) |entry| {
        if (env.getNodeProperty(.category, entry.node) != .element) continue;
        const map = if (env.cascade_db.getStorage(entry.node)) |storage| try resolver.element(storage, entry.parent_map) else entry.parent_map;
        inline for (.{ .before, .after }) |pseudo| {
            if (env.cascade_db.getPseudoStorage(entry.node, pseudo)) |pseudo_storage| _ = try resolver.element(pseudo_storage, map);
        }
        // Children in reverse so they pop in document order.
        var child = entry.node.lastChild(env);
        while (child) |c| : (child = c.previousSibling(env)) {
            try stack.append(env.allocator, .{ .node = c, .parent_map = map });
        }
    }
}

const Resolver = struct {
    env: *Environment,
    /// Computed custom property maps and substituted strings (they live as
    /// long as the cascade database's values reference them).
    arena: std.heap.ArenaAllocator,
    fn deinit(r: *Resolver) void {
        // The maps and strings stay referenced by the storages: the cascade
        // database owns them.
        r.env.cascade_db.custom_arena = r.arena.state;
    }

    /// Resolve one element's custom properties and pending declarations.
    fn element(r: *Resolver, storage: *Storage, parent_map: ?*const Map) !?*const Map {
        const map: ?*const Map = if (storage.custom_properties.count() == 0) parent_map else blk: {
            const allocator = r.arena.allocator();
            const computed = try allocator.create(Map);
            computed.* = .empty;
            if (parent_map) |p| {
                var it = p.iterator();
                while (it.next()) |e| try computed.put(allocator, e.key_ptr.*, e.value_ptr.*);
            }
            var own: OwnValues = .{ .raw = &storage.custom_properties, .inherited = parent_map };
            defer own.state.deinit(r.env.allocator);
            var it = storage.custom_properties.iterator();
            while (it.next()) |e| {
                if (try r.ownValue(&own, e.key_ptr.*)) |value| {
                    try computed.put(allocator, e.key_ptr.*, value);
                } else {
                    // Guaranteed-invalid: the name is undefined here.
                    _ = computed.remove(e.key_ptr.*);
                }
            }
            break :blk computed;
        };
        storage.computed_custom = map;

        for (storage.pending.items) |pending| try r.pendingDeclaration(storage, pending, map);
        return map;
    }

    const OwnValues = struct {
        raw: *const Map,
        inherited: ?*const Map,
        state: std.StringHashMapUnmanaged(union(enum) { resolving, done: ?[]const u8 }) = .empty,
    };

    /// The computed value of the element's own custom property `name`, or
    /// null if it is invalid (a cycle, or an unresolvable var()).
    fn ownValue(r: *Resolver, own: *OwnValues, name: []const u8) error{OutOfMemory}!?[]const u8 {
        if (own.state.get(name)) |state| return switch (state) {
            .resolving => null, // a cycle (§2.3)
            .done => |value| value,
        };
        const raw = own.raw.get(name) orelse return if (own.inherited) |p| p.get(name) else null;
        try own.state.put(r.env.allocator, name, .resolving);
        const value = try r.substitute(raw, .{ .own = own });
        try own.state.put(r.env.allocator, name, .{ .done = value });
        return value;
    }

    const Lookup = union(enum) {
        own: *OwnValues,
        computed: ?*const Map,

        fn get(lookup: Lookup, r: *Resolver, name: []const u8) !?[]const u8 {
            return switch (lookup) {
                .own => |own| r.ownValue(own, name),
                .computed => |map| if (map) |m| m.get(name) else null,
            };
        }
    };

    /// CSS Variables 1 §3.1: replace each var(--name [, fallback]) in
    /// `text` by the value of --name, or by its substituted fallback; null
    /// if a reference has neither.
    fn substitute(r: *Resolver, text: []const u8, lookup: Lookup) error{OutOfMemory}!?[]const u8 {
        if (std.ascii.indexOfIgnoreCase(text, "var(") == null) return text;
        const allocator = r.arena.allocator();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            const ch = text[i];
            if (ch == '"' or ch == '\'') {
                const start = i;
                i += 1;
                while (i < text.len and text[i] != ch) : (i += 1) {
                    if (text[i] == '\\') i += 1;
                }
                i = @min(i + 1, text.len);
                try out.appendSlice(allocator, text[start..i]);
                continue;
            }
            const at_function = i + 4 <= text.len and std.ascii.eqlIgnoreCase(text[i .. i + 4], "var(") and
                (i == 0 or !isNameChar(text[i - 1]));
            if (!at_function) {
                try out.append(allocator, ch);
                i += 1;
                continue;
            }
            // The arguments, up to the matching ")".
            const args_start = i + 4;
            var depth: usize = 0;
            var j = args_start;
            var comma: ?usize = null;
            while (j < text.len) : (j += 1) {
                switch (text[j]) {
                    '(' => depth += 1,
                    ')' => {
                        if (depth == 0) break;
                        depth -= 1;
                    },
                    ',' => if (depth == 0 and comma == null) {
                        comma = j;
                    },
                    '"', '\'' => |q| {
                        j += 1;
                        while (j < text.len and text[j] != q) : (j += 1) {
                            if (text[j] == '\\') j += 1;
                        }
                    },
                    else => {},
                }
            }
            if (j >= text.len) return null; // unterminated
            const name = std.mem.trim(u8, text[args_start .. comma orelse j], " \t\r\n");
            if (name.len < 3 or !std.mem.startsWith(u8, name, "--")) return null;
            if (try lookup.get(r, name[2..])) |value| {
                try out.appendSlice(allocator, value);
            } else if (comma) |c| {
                const fallback = std.mem.trim(u8, text[c + 1 .. j], " \t\r\n");
                const substituted = (try r.substitute(fallback, lookup)) orelse return null;
                try out.appendSlice(allocator, substituted);
            } else return null;
            i = j + 1;
        }
        return out.items;
    }

    fn isNameChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch >= 0x80;
    }

    fn pendingDeclaration(r: *Resolver, storage: *Storage, pending: Storage.PendingValue, map: ?*const Map) !void {
        const env = r.env;
        const db = &env.cascade_db;
        const text = (try r.substitute(pending.text, .{ .computed = map })) orelse return; // stays unset
        const block = (try r.parse(pending.property, text)) orelse return;
        try storage.setFields(db, env.allocator, pending.property, pending.mask, .undeclared, false);
        try storage.applyDeclBlock(db, env.allocator, &env.decls, block, .normal);
        // A value its parser rejects is invalid at computed-value time.
        try storage.setFields(db, env.allocator, pending.property, pending.mask, .unset, true);
    }

    /// Parse `property: text` as a declaration block, or null if it has no
    /// valid declaration.
    fn parse(r: *Resolver, property: zss.property.Property, text: []const u8) !?Declarations.Block {
        const env = r.env;
        const source_text = try std.fmt.allocPrint(env.allocator, "x{{{s}:{s}}}", .{ @tagName(property), text });
        const gop = env.substituted_blocks.getOrPut(env.allocator, source_text[2 .. source_text.len - 1]) catch |err| {
            env.allocator.free(source_text);
            return err;
        };
        if (gop.found_existing) {
            env.allocator.free(source_text);
            return gop.value_ptr.*;
        }
        // The key keeps the whole allocation alive; `Environment.deinit`
        // frees it (see `substituted_blocks`).
        gop.value_ptr.* = null;

        const source = zss.syntax.SourceCode.init(source_text) catch return null;
        var parser = zss.syntax.Parser.init(source, env.allocator);
        defer parser.deinit();
        var ast, const rule_list = parser.parseCssStylesheet(env.allocator) catch return null;
        defer ast.deinit(env.allocator);
        var rules = rule_list.children(ast);
        while (rules.nextSkipSpaces(ast)) |rule| {
            if (rule.tag(ast) != .qualified_rule) continue;
            const prelude = ast.qualifiedRulePrelude(rule);
            const last_declaration = prelude.end.extra(ast).index;
            var buffer: [zss.property.recommended_buffer_size]u8 = undefined;
            var urls = zss.values.parse.Urls.init(env);
            defer urls.deinit(env.allocator);
            const block = try zss.property.parseDeclarationsFromAst(env, ast, source, &buffer, last_declaration, urls.toManaged(env.allocator));
            urls.commit(env);
            if (env.decls.hasValues(block, .normal)) gop.value_ptr.* = block;
            break;
        }
        return gop.value_ptr.*;
    }
};
