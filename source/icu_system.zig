//! The `icu` import: the host's ICU (libicuuc) case mapping, for `text-transform`
//! (`text_transform.zig`). Through the headers, so the names follow whichever ICU
//! the build links. ICU renames every function with its major version
//! (`ucasemap_open` is `ucasemap_open_78`); translate-c cannot expand that macro,
//! so `func` finds the versioned declaration. The host supplies the include
//! directories (`-Dsystem-include-dir`) and links `icuuc`.
const std = @import("std");

pub const c = @cImport({
    @cInclude("unicode/uvernum.h");
    @cInclude("unicode/ucasemap.h");
    @cInclude("unicode/stringoptions.h");
    @cInclude("unicode/ubrk.h");
    @cInclude("unicode/utext.h");
    @cInclude("unicode/uchar.h");
});

const suffix = std.fmt.comptimePrint("_{d}", .{c.U_ICU_VERSION_MAJOR_NUM});

/// The ICU function `name` (unversioned name).
pub fn func(comptime name: []const u8) @TypeOf(@field(c, name ++ suffix)) {
    return @field(c, name ++ suffix);
}
