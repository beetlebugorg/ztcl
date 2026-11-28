//! The table of the features of a stripped build.
//!
//! A feature is a group of commands, or one option of a command, that
//! the build can leave out with `-Ddrop=NAME,NAME`. `ztcl build --strip`
//! maps each command and option of the scripts to a feature with this
//! table, and builds a runtime with the features that the scripts do
//! not use left out. A feature in `needs` stays in the build when the
//! feature that needs it stays.
//!
//! The file has no imports, so build.zig, the interpreter
//! (`features.zig`), and the scan (`stripscan.zig`) use the same table.
//!
//! SPDX-License-Identifier: BSD-2-Clause

pub const Kind = enum {
    /// Commands of the interpreter that each script can call.
    commands,
    /// The commands of a capability. A program without the capability
    /// in `--allow` cannot call them.
    capability,
    /// A built-in module of `package require`.
    module,
    /// A part of the runtime that no command name shows, such as the JIT.
    engine,
};

pub const Feature = struct {
    name: []const u8,
    kind: Kind,
    /// The commands of the feature, with no leading `::`. An entry that
    /// ends in `::` stands for each command in that namespace.
    commands: []const []const u8 = &.{},
    /// The options of other commands that need the feature, as
    /// "command option" or "command subcommand option".
    options: []const []const u8 = &.{},
    /// The features that stay in the build when this feature stays.
    needs: []const []const u8 = &.{},
    /// The names of `package require` of a module feature.
    packages: []const []const u8 = &.{},
    /// The capability name of `--allow`, for a capability feature.
    capability: []const u8 = "",
};

pub const table = [_]Feature{
    .{ .name = "regexp", .kind = .commands, .commands = &.{ "regexp", "regsub" }, .options = &.{ "switch -regexp", "lsearch -regexp", "array names -regexp", "array get -regexp", "array unset -regexp" } },
    .{ .name = "oo", .kind = .commands, .commands = &.{ "oo::", "self", "next", "nextto", "my", "info object", "info class" } },
    .{ .name = "coroutine", .kind = .commands, .commands = &.{ "coroutine", "yield", "yieldto" } },
    .{ .name = "binary", .kind = .commands, .commands = &.{"binary"} },
    .{ .name = "clock", .kind = .capability, .capability = "clock", .commands = &.{ "clock", "time", "timerate", "msgcat::" } },
    .{ .name = "interp", .kind = .capability, .capability = "interp", .commands = &.{"interp"} },
    .{ .name = "event", .kind = .capability, .capability = "event", .commands = &.{ "after", "vwait", "update", "fileevent", "tcl::Bgerror" } },
    .{ .name = "launch", .kind = .capability, .capability = "launch", .commands = &.{"ztcl::open"} },
    .{ .name = "exec", .kind = .capability, .capability = "exec", .commands = &.{ "exec", "pid", "ztcl::pty" } },
    .{ .name = "socket", .kind = .capability, .capability = "socket", .commands = &.{"socket"} },
    .{ .name = "thread", .kind = .capability, .capability = "thread", .commands = &.{ "thread::", "tsv::", "tpool::" } },
    .{ .name = "vm", .kind = .capability, .capability = "vm", .commands = &.{"ztcl::vm"} },
    .{ .name = "meter", .kind = .capability, .capability = "meter", .commands = &.{ "ztcl::meter", "ztcl::gc" } },
    .{ .name = "notify", .kind = .capability, .capability = "notify", .commands = &.{"ztcl::notify"} },
    .{ .name = "watch", .kind = .capability, .capability = "file", .commands = &.{"ztcl::watch"} },
    .{ .name = "registry", .kind = .capability, .capability = "registry", .commands = &.{"ztcl::win::registry"} },
    .{ .name = "credential", .kind = .capability, .capability = "credential", .commands = &.{"ztcl::win::credential"} },
    .{ .name = "folder", .kind = .capability, .capability = "env", .commands = &.{"ztcl::win::folder"} },
    .{ .name = "keychain", .kind = .capability, .capability = "keychain", .commands = &.{"ztcl::mac::keychain"} },
    .{ .name = "defaults", .kind = .capability, .capability = "defaults", .commands = &.{"ztcl::mac::defaults"} },
    .{ .name = "jit", .kind = .engine },
    .{ .name = "hello", .kind = .module, .commands = &.{ "ztcl::hello", "ztcl::hello::", "hello" }, .packages = &.{ "ztcl::hello", "hello", "ztcl::hellonet" } },
    .{ .name = "json", .kind = .module, .commands = &.{ "ztcl::json", "ztcl::json::", "json::" }, .packages = &.{ "ztcl::json", "json", "json::write" } },
    .{ .name = "vt", .kind = .module, .commands = &.{"ztcl::vt"}, .packages = &.{"ztcl::vt"} },
    .{ .name = "probe", .kind = .module, .commands = &.{ "ztcl::probe", "ztcl::probe::" }, .packages = &.{"ztcl::probe"} },
    .{ .name = "disasm", .kind = .module, .commands = &.{ "ztcl::disasm", "ztcl::disasm::" }, .packages = &.{"ztcl::disasm"} },
    .{ .name = "tls", .kind = .module, .commands = &.{"ztcl::tls::"}, .packages = &.{"ztcl::tls"}, .needs = &.{"socket"} },
    .{ .name = "fhe", .kind = .module, .commands = &.{"ztcl::fhe"}, .packages = &.{"ztcl::fhe"} },
};

/// The index of the feature `name`, or null.
pub fn index(name: []const u8) ?usize {
    for (table, 0..) |f, i| {
        if (eql(f.name, name)) return i;
    }
    return null;
}

/// The feature of the command `name` (no leading `::`), or null for a
/// command of the core.
pub fn ofCommand(name: []const u8) ?usize {
    for (table, 0..) |f, i| {
        for (f.commands) |c| {
            if (c.len > 2 and c[c.len - 2] == ':' and c[c.len - 1] == ':') {
                if (name.len > c.len and startsWith(name, c)) return i;
            } else if (eql(c, name)) return i;
        }
    }
    return null;
}

/// Sets `on[i]` for each feature that a feature in the build needs.
/// Gives true when it changed a flag.
pub fn closeNeeds(on: *[table.len]bool) bool {
    return closeNeedsIn(&table, on);
}

/// `closeNeeds` for the features of `tbl`, such as the table of ztk.
/// A name in `needs` that is not in `tbl` is skipped.
pub fn closeNeedsIn(tbl: []const Feature, on: []bool) bool {
    var any = false;
    var changed = true;
    while (changed) {
        changed = false;
        for (tbl, 0..) |f, i| {
            if (!on[i]) continue;
            for (f.needs) |n| {
                const j = for (tbl, 0..) |g, k| {
                    if (eql(g.name, n)) break k;
                } else continue;
                if (!on[j]) {
                    on[j] = true;
                    changed = true;
                    any = true;
                }
            }
        }
    }
    return any;
}

/// Gives true when the comma list `list` has `name`.
pub fn listHas(list: []const u8, name: []const u8) bool {
    var at: usize = 0;
    while (at <= list.len) {
        var end = at;
        while (end < list.len and list[end] != ',') end += 1;
        if (eql(list[at..end], name)) return true;
        at = end + 1;
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn startsWith(a: []const u8, p: []const u8) bool {
    return a.len >= p.len and eql(a[0..p.len], p);
}
