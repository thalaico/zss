//! CSS Text 3 §2.1 `text-transform`: the case transforms, with Unicode's full case
//! mappings (ICU `ucasemap`, as Chromium): `uppercase` maps "ß" to "SS" and "é" to
//! "É", so the result can be longer than the text. `capitalize` is Blink's
//! (platform/text/capitalize.cc): the text after the character before it is split into
//! words with ICU's word break iterator, the first character of each word gets its
//! titlecase mapping (`u_totitle`), the rest stays as written; a word that began
//! before the text (`previous`, the last character of the preceding text in the same
//! inline formatting context) is not capitalized again.
//!
//! Not done: the content language (`lang`): the mappings are the language-neutral
//! ones (no Turkish dotted i, no Greek accent removal, no Dutch "ij"); word breaks
//! are stock ICU's, and Chromium's differ in places ("a.b" is one word here,
//! "A.B" in Chromium); `full-width` and `full-size-kana` are not parsed.
const std = @import("std");
const icu_import = @import("icu");
const icu = icu_import.c;
const func = icu_import.func;
const TextTransform = @import("values/types.zig").TextTransform;

const Kind = enum { upper, lower };

/// One case map per thread and kind, and one word break iterator per thread (an
/// iterator holds its text: not shared between threads). Never freed: a thread lays
/// out for the process's life.
threadlocal var maps: [2]?*icu.UCaseMap = .{ null, null };

fn mapFor(kind: Kind) ?*icu.UCaseMap {
    const slot = &maps[@intFromEnum(kind)];
    if (slot.* == null) {
        var status: icu.UErrorCode = icu.U_ZERO_ERROR;
        const m = func("ucasemap_open")("", 0, &status);
        if (status > icu.U_ZERO_ERROR) return null;
        slot.* = m;
    }
    return slot.*;
}

fn call(kind: Kind, m: *icu.UCaseMap, dest: [*c]u8, cap: i32, src: []const u8, status: *icu.UErrorCode) i32 {
    const len: i32 = @intCast(src.len);
    return switch (kind) {
        .upper => func("ucasemap_utf8ToUpper")(m, dest, cap, src.ptr, len, status),
        .lower => func("ucasemap_utf8ToLower")(m, dest, cap, src.ptr, len, status),
    };
}

/// `text` with `transform` applied, allocated with `allocator` (also for `.none`, a
/// copy). UTF-8 in and out. `previous` is the character before `text` in its inline
/// formatting context (a space at its start); only `capitalize` reads it. ICU's only
/// failure on valid arguments is an allocation failure (U_MEMORY_ALLOCATION_ERROR),
/// reported as one.
pub fn apply(allocator: std.mem.Allocator, text: []const u8, transform: TextTransform, previous: u21) error{OutOfMemory}![]u8 {
    const kind: Kind = switch (transform) {
        .none => return allocator.dupe(u8, text),
        .uppercase => .upper,
        .lowercase => .lower,
        .capitalize => return capitalize(allocator, text, previous),
    };
    if (text.len == 0 or text.len > std.math.maxInt(i32) / 4) return allocator.dupe(u8, text);
    const m = mapFor(kind) orelse return error.OutOfMemory;
    // Most text keeps its length: try a buffer of the text's size first, then the
    // size ICU asks for.
    var buf = try allocator.alloc(u8, text.len);
    var status: icu.UErrorCode = icu.U_ZERO_ERROR;
    const needed = call(kind, m, buf.ptr, @intCast(buf.len), text, &status);
    if (status == icu.U_BUFFER_OVERFLOW_ERROR) {
        buf = try allocator.realloc(buf, @intCast(needed));
        status = icu.U_ZERO_ERROR;
        _ = call(kind, m, buf.ptr, @intCast(buf.len), text, &status);
    }
    if (status > icu.U_ZERO_ERROR) {
        allocator.free(buf);
        return error.OutOfMemory;
    }
    // U_STRING_NOT_TERMINATED_WARNING is expected when the result fills the buffer.
    const n: usize = @intCast(needed);
    if (n == buf.len) return buf;
    return allocator.realloc(buf, n);
}

threadlocal var word_breaks: ?*icu.UBreakIterator = null;

const nbsp: u21 = 0xA0;

/// The code point at `text[i..]` and its length in bytes (an ill-formed byte is
/// itself, one byte long).
fn decodeAt(text: []const u8, i: usize) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = text[i], .len = 1 };
    if (i + n > text.len) return .{ .cp = text[i], .len = 1 };
    const cp = std.unicode.utf8Decode(text[i..][0..n]) catch return .{ .cp = text[i], .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// The last code point of `text`, or null when it is empty.
pub fn lastCodePoint(text: []const u8) ?u21 {
    if (text.len == 0) return null;
    var i = text.len - 1;
    while (i > 0 and text[i] & 0xC0 == 0x80) i -= 1;
    return decodeAt(text, i).cp;
}

fn appendCodePoint(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.append(allocator, @truncate(cp));
        return;
    };
    try out.appendSlice(allocator, buf[0..n]);
}

/// Blink's Capitalize(string, previous_character): words are found in `previous`
/// followed by the text, with no-break spaces read as spaces (ICU does not end a word
/// at one); a word starting inside the text has its first character titlecased.
fn capitalize(allocator: std.mem.Allocator, text: []const u8, previous: u21) error{OutOfMemory}![]u8 {
    var with_previous: std.ArrayListUnmanaged(u8) = .empty;
    defer with_previous.deinit(allocator);
    try appendCodePoint(&with_previous, allocator, if (previous == nbsp) ' ' else previous);
    const shift = with_previous.items.len;
    var i: usize = 0;
    while (i < text.len) {
        const d = decodeAt(text, i);
        if (d.cp == nbsp) try with_previous.append(allocator, ' ') else try with_previous.appendSlice(allocator, text[i..][0..d.len]);
        // A no-break space (2 bytes) read as a space (1 byte) would shift every
        // offset after it: pad so offsets in both strings agree.
        if (d.cp == nbsp) try with_previous.append(allocator, ' ');
        i += d.len;
    }
    const s = with_previous.items;

    var status: icu.UErrorCode = icu.U_ZERO_ERROR;
    if (word_breaks == null) {
        word_breaks = func("ubrk_open")(icu.UBRK_WORD, "", null, 0, &status);
        if (status > icu.U_ZERO_ERROR) {
            word_breaks = null;
            return error.OutOfMemory;
        }
    }
    const bi = word_breaks.?;
    var ut: icu.UText = std.mem.zeroes(icu.UText);
    ut.magic = icu.UTEXT_MAGIC;
    ut.sizeOfStruct = @sizeOf(icu.UText);
    _ = func("utext_openUTF8")(&ut, s.ptr, @intCast(s.len), &status);
    defer _ = func("utext_close")(&ut);
    func("ubrk_setUText")(bi, &ut, &status);
    if (status > icu.U_ZERO_ERROR) return error.OutOfMemory;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);
    var start: usize = @intCast(func("ubrk_first")(bi));
    while (true) {
        const next = func("ubrk_next")(bi);
        if (next == icu.UBRK_DONE) break;
        const end: usize = @intCast(next);
        var copy_from = @max(start, shift);
        if (start >= shift) {
            // The word's first character, in the text: titlecased (a no-break space
            // stays one).
            const d = decodeAt(text, start - shift);
            if (d.cp == nbsp) {
                try out.appendSlice(allocator, text[start - shift ..][0..d.len]);
            } else {
                const t: u21 = @intCast(func("u_totitle")(@intCast(d.cp)));
                try appendCodePoint(&out, allocator, t);
            }
            copy_from = start + d.len;
        }
        if (end > copy_from) try out.appendSlice(allocator, text[copy_from - shift .. end - shift]);
        start = end;
    }
    // ICU's word boundaries never fall inside a code point; anything short of the
    // whole text would be a bug: copy what is left as written.
    if (start < s.len and start >= shift) try out.appendSlice(allocator, text[start - shift ..]);
    return out.toOwnedSlice(allocator);
}

test "full case mappings" {
    const a = std.testing.allocator;
    const cases = [_]struct { []const u8, TextTransform, []const u8 }{
        .{ "Private beta", .uppercase, "PRIVATE BETA" },
        .{ "straße", .uppercase, "STRASSE" },
        .{ "café", .uppercase, "CAFÉ" },
        .{ "ÉCOLE", .lowercase, "école" },
        .{ "hello wORLD-x", .capitalize, "Hello WORLD-X" },
        .{ "a\u{a0}b", .capitalize, "A\u{a0}B" },
    };
    for (cases) |cs| {
        const out = try apply(a, cs[0], cs[1], ' ');
        defer a.free(out);
        try std.testing.expectEqualStrings(cs[2], out);
    }
}
