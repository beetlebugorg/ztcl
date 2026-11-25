//! The interactive shell of the runner: the loop that reads a command
//! with the line editor, runs it, and prints its result.
//!
//! The shell starts when the runner gets no file and standard input and
//! output are a terminal. With TERM=dumb or no terminal, the runner keeps
//! its plain line input. At the start the shell reads `~/.ztclrc` in the
//! interpreter (with the command `shell` below) and the history file
//! `~/.ztcl_history`. After each command it adds the command to the
//! history and writes the file again, merged with the commands that other
//! sessions added (`History.merged`).
//!
//! The interpreter answers the questions of the editor. `info complete`
//! (the parser of Tcl) decides if Enter runs the command or adds a line.
//! The command table decides the color of a command name. Tab completes
//! from `info commands`, `info vars`, `namespace children`, the
//! subcommands that an ensemble lists in its error message, the methods of
//! a TclOO object, and `glob` when the interpreter has `file`. A probe of
//! the interpreter keeps `errorInfo`, `errorCode`, the result, and the
//! step limit as they were, so the questions of the shell do not change
//! the state of the script.
//!
//! The hint after the cursor is the newest history entry that starts
//! with the buffer. Right arrow, Ctrl-F, or End at the end of the buffer
//! accepts it. The row under the command shows the parameters of the proc
//! of the command at the cursor.
//!
//! A result prints in color. A long list prints one item on each row, and
//! a dict with keys in a column. An error prints its message in red, and
//! Alt-T prints the whole `errorInfo` of the last error.
//!
//! `shell` sets the shell from a script or the rc file:
//!
//!     shell mode vi|emacs
//!     shell color STYLE SGR        (command, string, variable, ...)
//!     shell prompt PROC            (the result of PROC is the prompt)
//!     shell history size N
//!     shell bind KEY ACTION        (KEY: ctrl-x or alt-x)
//!
//! The environment variable NO_COLOR turns the colors off.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const tcl = @import("ztcl");
const keys = @import("keys.zig");
const text = @import("text.zig");
const hl = @import("highlight.zig");
const render = @import("render.zig");
const termmod = @import("term.zig");
const editor = @import("editor.zig");
const History = @import("history.zig").History;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Editor = editor.Editor;
const Key = keys.Key;

pub const Options = struct {
    io: Io,
    /// The home folder, for the rc file and the history file.
    home: ?[]const u8 = null,
    no_color: bool = false,
    editor_cmd: ?[]const u8 = null,
};

/// The actions that `shell bind` names.
const actions = [_]struct { name: []const u8, act: editor.Action }{
    .{ .name = "accept", .act = .accept },
    .{ .name = "complete", .act = .complete },
    .{ .name = "clear-screen", .act = .clear_screen },
    .{ .name = "edit", .act = .open_editor },
    .{ .name = "trace", .act = .show_trace },
};

const Binding = struct { ctrl: bool, ch: u8, act: editor.Action };

pub const Shell = struct {
    a: Allocator,
    it: *tcl.Interp,
    opts: Options,
    term: termmod.Term,
    ed: Editor,
    hist: History,
    screen: render.Screen,
    decoder: keys.Decoder,
    prompt_proc: ?[]u8 = null,
    bindings: std.ArrayList(Binding) = .empty,
    /// The whole errorInfo of the last error, for Alt-T.
    last_trace: ?[]u8 = null,
    /// The open completion menu: its items, the selection, and the start
    /// of the word that it replaces.
    menu: std.ArrayList([]u8) = .empty,
    menu_sel: ?usize = null,
    menu_start: usize = 0,
    hist_path: ?[]u8 = null,
    /// True for the last draw of a command: no hint, menu, or parameters.
    final: bool = false,

    pub fn init(a: Allocator, it: *tcl.Interp, opts: Options) Shell {
        var s: Shell = .{
            .a = a,
            .it = it,
            .opts = opts,
            .term = termmod.Term.init(),
            .ed = Editor.init(a),
            .hist = History.init(a),
            .screen = render.Screen.init(a),
            .decoder = keys.Decoder.init(a),
        };
        s.screen.theme.on = !opts.no_color;
        return s;
    }

    pub fn deinit(s: *Shell) void {
        s.ed.deinit();
        s.hist.deinit();
        s.screen.deinit();
        s.decoder.deinit();
        if (s.prompt_proc) |p| s.a.free(p);
        s.bindings.deinit(s.a);
        if (s.last_trace) |t| s.a.free(t);
        s.clearMenu();
        s.menu.deinit(s.a);
        if (s.hist_path) |p| s.a.free(p);
    }

    // ---- Questions to the interpreter ----

    /// Runs a script with the state of the interpreter kept: the result,
    /// errorInfo, errorCode, and the step limit. Gives a copy of the
    /// result text, or null after an error.
    fn probe(s: *Shell, script: []const u8) ?[]u8 {
        const it = s.it;
        const steps = it.step_limit;
        const saved_result = it.result;
        const info = it.getVarPlain("::errorInfo") catch null;
        const code = it.getVarPlain("::errorCode") catch null;
        it.step_limit = std.math.maxInt(u64);
        defer {
            it.step_limit = steps;
            it.result = saved_result;
            if (info) |v| it.setVar("::errorInfo", v) catch {};
            if (code) |v| it.setVar("::errorCode", v) catch {};
        }
        const v = it.eval(script) catch return null;
        const t = it.str(v) catch return null;
        return s.a.dupe(u8, t) catch null;
    }

    /// A word as one element of a list, for a probe script.
    fn quoted(s: *Shell, w: []const u8) ![]const u8 {
        const v = try tcl.value.newList(s.it.alloc(), &.{.{ .str = w }});
        return s.it.str(v);
    }

    /// The items of a Tcl list text.
    fn listItems(s: *Shell, t: []const u8) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        const items = s.it.list(.{ .str = t }) catch return out.toOwnedSlice(s.a);
        for (items) |v| try out.append(s.a, try s.a.dupe(u8, try s.it.str(v)));
        return out.toOwnedSlice(s.a);
    }

    fn freeItems(s: *Shell, items: [][]u8) void {
        for (items) |x| s.a.free(x);
        s.a.free(items);
    }

    fn isComplete(ctx: ?*anyopaque, t: []const u8) bool {
        const s: *Shell = @ptrCast(@alignCast(ctx.?));
        var arena = std.heap.ArenaAllocator.init(s.a);
        defer arena.deinit();
        var p: tcl.interp.Parser = .{ .a = arena.allocator(), .src = t };
        if (p.parseScript(false)) |_| {
            // A backslash at the end of the last line continues it.
            var k = t.len;
            var slashes: usize = 0;
            while (k > 0 and t[k - 1] == '\\') : (k -= 1) slashes += 1;
            return slashes % 2 == 0;
        } else |e| {
            if (e == error.OutOfMemory) return true;
            return std.mem.indexOf(u8, p.message, "missing") == null;
        }
    }

    fn commandExists(ctx: ?*anyopaque, name: []const u8) bool {
        const s: *Shell = @ptrCast(@alignCast(ctx.?));
        if (name.len == 0) return true;
        return s.it.findCommand(name) != null;
    }

    // ---- The frame ----

    fn promptText(s: *Shell) []const u8 {
        if (s.prompt_proc) |p| {
            if (s.probe(p)) |t| return t;
        }
        return s.a.dupe(u8, "% ") catch "% ";
    }

    /// The span of the command around the cursor: from the last `;`,
    /// newline, or `[` before it.
    fn commandStart(buf: []const u8, cur: usize) usize {
        var i = cur;
        while (i > 0) {
            const c = buf[i - 1];
            if (c == ';' or c == '\n' or c == '[') break;
            i -= 1;
        }
        return i;
    }

    fn firstWord(buf: []const u8, cur: usize) []const u8 {
        var i = commandStart(buf, cur);
        while (i < buf.len and (buf[i] == ' ' or buf[i] == '\t')) i += 1;
        var j = i;
        while (j < buf.len and buf[j] != ' ' and buf[j] != '\t' and buf[j] != '\n' and buf[j] != ';' and buf[j] != ']') j += 1;
        return buf[i..j];
    }

    /// The parameters of the proc of the command at the cursor, or null.
    fn argHint(s: *Shell) ?[]u8 {
        const name = firstWord(s.ed.buf.items, s.ed.cur);
        if (name.len == 0 or s.ed.cur <= commandStart(s.ed.buf.items, s.ed.cur) + name.len) return null;
        const cmd = s.it.findCommand(name) orelse return null;
        if (cmd.impl != .proc) return null;
        const q = s.quoted(name) catch return null;
        const script = std.fmt.allocPrint(s.a, "info args {s}", .{q}) catch return null;
        defer s.a.free(script);
        const args = s.probe(script) orelse return null;
        defer s.a.free(args);
        return std.fmt.allocPrint(s.a, "{s} {s}", .{ name, args }) catch null;
    }

    fn historyHint(s: *Shell) []const u8 {
        const b = s.ed.buf.items;
        if (b.len == 0 or s.ed.cur != b.len or s.ed.searching) return "";
        var i = s.hist.len();
        while (i > 0) {
            i -= 1;
            const h = s.hist.get(i);
            if (h.len > b.len and std.mem.startsWith(u8, h, b)) return h[b.len..];
        }
        return "";
    }

    fn draw(s: *Shell) !void {
        const a = s.a;
        const width = s.term.size().cols;
        var below: std.ArrayList([]const u8) = .empty;
        defer below.deinit(a);
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |x| a.free(x);
            owned.deinit(a);
        }
        const prompt = s.promptText();
        defer a.free(prompt);
        var buf: []const u8 = s.ed.buf.items;
        var cur = s.ed.cur;
        var pr: []const u8 = prompt;
        if (s.ed.searchLine()) |sl| {
            const p = try std.fmt.allocPrint(a, "(search) {s}: ", .{sl.query});
            try owned.append(a, p);
            pr = p;
            buf = sl.match orelse "";
            cur = buf.len;
        }
        const st = try a.alloc(hl.Style, buf.len);
        defer a.free(st);
        hl.styles(buf, st, .{ .ctx = s, .exists = commandExists });
        if (!s.final) {
            if (s.argHint()) |h| {
                try owned.append(a, h);
                try below.append(a, h);
            }
            for (s.menu.items) |m| try below.append(a, m);
        }
        const normal = s.ed.vi and (s.ed.mode == .normal or s.ed.mode == .visual);
        const frame = try render.build(a, .{
            .prompt = pr,
            // The normal mode of vim has a prompt of its own color.
            .prompt_style = if (normal) .prompt_normal else .prompt,
            .buf = buf,
            .cur = cur,
            .styles = st,
            .select = s.ed.selection(),
            .match = hl.matchAt(buf, cur),
            .hint = if (s.final) "" else s.historyHint(),
            .below = below.items,
            .below_sel = if (s.menu_sel) |k| k + @intFromBool(below.items.len > s.menu.items.len) else null,
            .width = width,
        });
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        // The cursor shape shows the mode of vim: a block in normal mode.
        if (s.ed.vi) try out.appendSlice(a, if (normal) "\x1b[2 q" else "\x1b[6 q");
        try s.screen.update(frame, &out);
        s.term.write(out.items);
    }

    // ---- Completion ----

    fn clearMenu(s: *Shell) void {
        for (s.menu.items) |x| s.a.free(x);
        s.menu.clearRetainingCapacity();
        s.menu_sel = null;
    }

    fn wordStart(buf: []const u8, cur: usize) usize {
        var i = cur;
        while (i > 0) {
            const c = buf[i - 1];
            if (c == ' ' or c == '\t' or c == '\n' or c == '[' or c == '{' or c == '"' or c == ';') break;
            i -= 1;
        }
        return i;
    }

    /// The candidates for the word at the cursor.
    fn candidates(s: *Shell, start: usize) !std.ArrayList([]u8) {
        const a = s.a;
        const buf = s.ed.buf.items;
        const word = buf[start..s.ed.cur];
        var out: std.ArrayList([]u8) = .empty;
        const cs = commandStart(buf, s.ed.cur);
        var k = cs;
        while (k < start and (buf[k] == ' ' or buf[k] == '\t')) k += 1;
        const first = k == start;
        if (word.len > 0 and word[0] == '$') {
            const pat = try s.quoted(try std.fmt.allocPrint(s.it.alloc(), "{s}*", .{word[1..]}));
            const script = try std.fmt.allocPrint(a, "lsort [info vars {s}]", .{pat});
            defer a.free(script);
            if (s.probe(script)) |t| {
                defer a.free(t);
                const items = try s.listItems(t);
                defer a.free(items);
                for (items) |x| {
                    defer a.free(x);
                    try out.append(a, try std.fmt.allocPrint(a, "${s}", .{x}));
                }
            }
            return out;
        }
        const pat = try s.quoted(try std.fmt.allocPrint(s.it.alloc(), "{s}*", .{word}));
        var scripts: [3][]u8 = undefined;
        var n: usize = 0;
        if (first) {
            scripts[n] = try std.fmt.allocPrint(a, "lsort [info commands {s}]", .{pat});
            n += 1;
            scripts[n] = try std.fmt.allocPrint(a, "lsort [namespace children :: {s}]", .{pat});
            n += 1;
        } else {
            const cmd = firstWord(buf, s.ed.cur);
            const qc = try s.quoted(cmd);
            // The subcommands that an ensemble lists in its error, and the
            // methods of a TclOO object.
            scripts[n] = try std.fmt.allocPrint(a,
                \\apply {{{{c p}} {{
                \\  if {{![catch {{info object isa object $c}} o] && $o}} {{ return [lsort [lsearch -all -inline [info object methods $c -all] $p]] }}
                \\  catch {{$c ztcl-no-such-subcommand}} m
                \\  if {{![regexp {{(?:must be|should be) (.*)$}} $m -> l]}} {{ return {{}} }}
                \\  set l [string map {{", or " " " ", " " " " or " " "}} $l]
                \\  lsort [lsearch -all -inline [split $l] $p]
                \\}}}} {s} {s}
            , .{ qc, pat });
            n += 1;
            scripts[n] = try std.fmt.allocPrint(a, "lsort [glob -nocomplain -- {s}]", .{pat});
            n += 1;
        }
        for (scripts[0..n]) |sc| {
            defer a.free(sc);
            const t = s.probe(sc) orelse continue;
            defer a.free(t);
            const items = try s.listItems(t);
            defer a.free(items);
            for (items) |x| {
                var dup = false;
                for (out.items) |y| {
                    if (std.mem.eql(u8, x, y)) dup = true;
                }
                if (dup or x.len == 0) a.free(x) else try out.append(a, x);
            }
        }
        return out;
    }

    fn complete(s: *Shell) !void {
        const a = s.a;
        // Tab again with a menu: the next item replaces the word.
        if (s.menu.items.len > 0) {
            const next = if (s.menu_sel) |k| (k + 1) % s.menu.items.len else 0;
            s.menu_sel = next;
            try s.ed.replaceWord(s.menu_start, std.mem.trim(u8, s.menu.items[next], " "));
            return;
        }
        const start = wordStart(s.ed.buf.items, s.ed.cur);
        var cands = try s.candidates(start);
        defer {
            for (cands.items) |x| a.free(x);
            cands.deinit(a);
        }
        if (cands.items.len == 0) return;
        if (cands.items.len == 1) {
            const c = cands.items[0];
            const end_ok = !(std.mem.endsWith(u8, c, "/") or std.mem.endsWith(u8, c, "::"));
            const with = try std.fmt.allocPrint(a, "{s}{s}", .{ c, if (end_ok) " " else "" });
            defer a.free(with);
            try s.ed.replaceWord(start, with);
            return;
        }
        // The longest common prefix, then a menu.
        var pre = cands.items[0];
        for (cands.items[1..]) |c| {
            var k: usize = 0;
            while (k < pre.len and k < c.len and pre[k] == c[k]) k += 1;
            pre = pre[0..k];
        }
        if (pre.len > s.ed.cur - start) try s.ed.replaceWord(start, pre);
        s.menu_start = start;
        const shown = @min(cands.items.len, 12);
        for (cands.items[0..shown]) |c| try s.menu.append(a, try std.fmt.allocPrint(a, "  {s}", .{c}));
        if (cands.items.len > shown) {
            // Only the shown items cycle. The last row says how many more.
            try s.menu.append(a, try std.fmt.allocPrint(a, "  ({d} more)", .{cands.items.len - shown}));
        }
    }

    // ---- The editor of the system ----

    fn openEditor(s: *Shell) !void {
        const a = s.a;
        const io = s.opts.io;
        const prog = s.opts.editor_cmd orelse "vi";
        var name: [96]u8 = undefined;
        const tmp = if (builtin.os.tag == .windows) "." else "/tmp";
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const path = try std.fmt.bufPrint(&name, "{s}/ztcl-edit-{x}.tcl", .{ tmp, std.mem.readInt(u64, &rnd, .little) });
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = s.ed.buf.items }) catch return;
        defer Io.Dir.cwd().deleteFile(io, path) catch {};
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try s.screen.finish(&out);
        s.term.write(out.items);
        s.term.restore();
        defer _ = s.term.enableRaw();
        // The editor command can have words: `code -w`.
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        var words = std.mem.tokenizeScalar(u8, prog, ' ');
        while (words.next()) |w| try argv.append(a, w);
        try argv.append(a, path);
        var child = std.process.spawn(io, .{ .argv = argv.items }) catch return;
        _ = child.wait(io) catch {};
        const t = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20)) catch return;
        defer a.free(t);
        try s.ed.setText(std.mem.trimEnd(u8, t, "\n"));
    }

    // ---- Results ----

    fn color(s: *Shell, out: *std.ArrayList(u8), style: render.Style) !void {
        const sgr = s.screen.theme.get(style);
        if (sgr.len > 0) try out.print(s.a, "\x1b[{s}m", .{sgr}) else if (s.screen.theme.on) try out.appendSlice(s.a, "\x1b[0m");
    }

    /// A result: plain when it fits on one row, else a list with one item
    /// on each row, or a dict with its keys in a column.
    fn printResult(s: *Shell, out: *std.ArrayList(u8), v: tcl.Value) !void {
        const a = s.a;
        const t = try s.it.str(v);
        if (t.len == 0) return;
        const width = s.term.size().cols;
        if (t.len <= width or std.mem.indexOfScalar(u8, t, '\n') != null) {
            try out.appendSlice(a, t);
            try out.appendSlice(a, "\r\n");
            return;
        }
        const items = s.it.list(v) catch {
            try out.appendSlice(a, t);
            try out.appendSlice(a, "\r\n");
            return;
        };
        var keyw: usize = 0;
        var dict = items.len >= 2 and items.len % 2 == 0;
        if (dict) {
            var k: usize = 0;
            while (k < items.len) : (k += 2) {
                const kt = try s.it.str(items[k]);
                if (kt.len > 30 or std.mem.indexOfAny(u8, kt, " \n") != null) dict = false;
                keyw = @max(keyw, text.width(kt));
            }
        }
        var k: usize = 0;
        while (k < items.len) {
            if (dict) {
                const kt = try s.it.str(items[k]);
                try s.color(out, .variable);
                try out.appendSlice(a, kt);
                try s.color(out, .plain);
                try out.appendNTimes(a, ' ', keyw - text.width(kt) + 2);
                try out.appendSlice(a, try s.it.str(items[k + 1]));
                k += 2;
            } else {
                try out.appendSlice(a, try s.it.str(items[k]));
                k += 1;
            }
            try out.appendSlice(a, "\r\n");
        }
    }

    fn run(s: *Shell, cmd: []const u8) !void {
        const a = s.a;
        const it = s.it;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        it.error_line = 0;
        // The command runs with the terminal in its normal mode, so the
        // output of `exec` and of a child program shows as usual.
        s.term.restore();
        const res = it.eval(cmd);
        _ = s.term.enableRaw();
        if (res) |v| {
            try s.printResult(&out, v);
        } else |e| {
            const msg = if (e == error.TclError) it.str(it.result) catch "out of memory" else @errorName(e);
            try s.color(&out, .unknown);
            try out.print(a, "error: {s}", .{msg});
            try s.color(&out, .plain);
            try out.appendSlice(a, "\r\n");
            const info = it.getVarPlain("::errorInfo") catch null;
            if (s.last_trace) |old| a.free(old);
            s.last_trace = if (info) |iv| try a.dupe(u8, it.str(iv) catch "") else null;
            if (s.last_trace) |tr| if (std.mem.indexOfScalar(u8, tr, '\n') != null) {
                try s.color(&out, .hint);
                try out.appendSlice(a, "  (Alt-T shows the whole trace)");
                try s.color(&out, .plain);
                try out.appendSlice(a, "\r\n");
            };
        }
        s.term.write(out.items);
    }

    // ---- Settings ----

    fn styleByName(name: []const u8) ?render.Style {
        inline for (@typeInfo(render.Style).@"enum".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
        }
        return null;
    }

    fn cmdShell(it: *tcl.Interp, argv: []const tcl.Value, _: ?*tcl.interp.Cmd) tcl.Error!tcl.Value {
        const s = active orelse return it.fail("the shell is not running", .{});
        if (argv.len < 2) return it.wrongArgs("shell mode|color|prompt|history|bind ?arg ...?");
        const sub = try it.str(argv[1]);
        const arg = struct {
            fn at(i: *tcl.Interp, v: []const tcl.Value, k: usize) tcl.Error![]const u8 {
                if (k >= v.len) return i.wrongArgs("shell mode|color|prompt|history|bind ?arg ...?");
                return i.str(v[k]);
            }
        }.at;
        if (std.mem.eql(u8, sub, "mode")) {
            const m = try arg(it, argv, 2);
            if (std.mem.eql(u8, m, "vi")) s.ed.setVi(true) else if (std.mem.eql(u8, m, "emacs")) s.ed.setVi(false) else return it.fail("bad mode \"{s}\": must be vi or emacs", .{m});
        } else if (std.mem.eql(u8, sub, "color")) {
            const name = try arg(it, argv, 2);
            const st = styleByName(name) orelse return it.fail("bad style \"{s}\"", .{name});
            s.screen.theme.sgr[@intFromEnum(st)] = s.a.dupe(u8, try arg(it, argv, 3)) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, sub, "prompt")) {
            if (s.prompt_proc) |p| s.a.free(p);
            s.prompt_proc = s.a.dupe(u8, try arg(it, argv, 2)) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, sub, "history")) {
            const n = argv[3].asInt() orelse return it.fail("expected integer but got \"{s}\"", .{try arg(it, argv, 3)});
            s.hist.limit = @intCast(@max(n, 1));
        } else if (std.mem.eql(u8, sub, "bind")) {
            const key = try arg(it, argv, 2);
            const name = try arg(it, argv, 3);
            const ctrl = std.mem.startsWith(u8, key, "ctrl-");
            if (!(ctrl or std.mem.startsWith(u8, key, "alt-")) or key.len != (if (ctrl) @as(usize, 6) else 5)) return it.fail("bad key \"{s}\": must be ctrl-x or alt-x", .{key});
            for (actions) |ac| {
                if (std.mem.eql(u8, ac.name, name)) {
                    s.bindings.append(s.a, .{ .ctrl = ctrl, .ch = key[key.len - 1], .act = ac.act }) catch return error.OutOfMemory;
                    return tcl.Value.empty;
                }
            }
            return it.fail("bad action \"{s}\"", .{name});
        } else return it.fail("bad option \"{s}\": must be mode, color, prompt, history, or bind", .{sub});
        return tcl.Value.empty;
    }

    fn bound(s: *Shell, k: Key) ?editor.Action {
        for (s.bindings.items) |b| {
            if (b.ctrl and k.code == .ctrl and k.code.ctrl == b.ch and !k.alt) return b.act;
            if (!b.ctrl and k.alt and k.code == .char and k.code.char == b.ch) return b.act;
        }
        return null;
    }

    fn loadFiles(s: *Shell) !void {
        const a = s.a;
        const io = s.opts.io;
        const home = s.opts.home orelse return;
        s.hist_path = try std.fmt.allocPrint(a, "{s}/.ztcl_history", .{home});
        if (Io.Dir.cwd().readFileAlloc(io, s.hist_path.?, a, .limited(16 << 20))) |t| {
            defer a.free(t);
            try s.hist.load(t);
        } else |_| {}
        const rc = try std.fmt.allocPrint(a, "{s}/.ztclrc", .{home});
        defer a.free(rc);
        if (Io.Dir.cwd().readFileAlloc(io, rc, a, .limited(1 << 20))) |t| {
            defer a.free(t);
            _ = s.it.eval(t) catch {
                const msg = s.it.str(s.it.result) catch "";
                const line = try std.fmt.allocPrint(a, "~/.ztclrc: {s}\r\n", .{msg});
                defer a.free(line);
                s.term.write(line);
            };
        } else |_| {}
    }

    fn saveHistory(s: *Shell) void {
        const a = s.a;
        const io = s.opts.io;
        const path = s.hist_path orelse return;
        const old = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20)) catch a.dupe(u8, "") catch return;
        defer a.free(old);
        const t = s.hist.merged(a, old) catch return;
        defer a.free(t);
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = t }) catch return;
        s.hist.markSaved();
    }

    /// The main loop. Ends at Ctrl-D on an empty line, at the end of the
    /// input, or when the terminal cannot go to raw mode.
    pub fn loop(s: *Shell) !void {
        const a = s.a;
        if (!s.term.enableRaw()) return error.NoTerminal;
        defer s.term.restore();
        active = s;
        defer active = null;
        try s.it.register("shell", cmdShell);
        s.ed.host = .{ .ctx = s, .complete = isComplete };
        s.ed.history = &s.hist;
        termmod.watchResize();
        s.term.write("\x1b[?2004h");
        defer s.term.write("\x1b[?2004l\x1b[0 q");
        try s.loadFiles();
        var inbuf: [4096]u8 = undefined;
        while (true) {
            s.ed.reset();
            s.clearMenu();
            s.screen.forget();
            try s.draw();
            const cmd: ?[]u8 = read: while (true) {
                const n = s.term.read(&inbuf, if (s.decoder.pending()) 30 else -1) orelse break :read null;
                if (termmod.resized.swap(false, .acq_rel)) {
                    // The terminal moved the old rows: draw again below.
                    s.term.write("\r\x1b[J");
                    s.screen.forget();
                }
                try s.decoder.feed(inbuf[0..n]);
                while (try s.decoder.next(n == 0)) |k| {
                    // A key in the menu: Tab cycles, each other key closes.
                    if (s.menu.items.len > 0 and !(k.code == .special and k.code.special == .tab)) s.clearMenu();
                    // The hint of the history.
                    const at_end = s.ed.cur == s.ed.buf.items.len and s.ed.mode != .normal;
                    const accepts_hint = (k.code == .special and (k.code.special == .right or k.code.special == .end)) or (k.code == .ctrl and k.code.ctrl == 'f');
                    if (at_end and accepts_hint and !k.alt) {
                        const h = s.historyHint();
                        if (h.len > 0) {
                            const copy = try a.dupe(u8, h);
                            defer a.free(copy);
                            try s.ed.insertText(copy);
                            continue;
                        }
                    }
                    const act = s.bound(k) orelse try s.ed.handle(k);
                    switch (act) {
                        .none => {},
                        .accept => break :read try a.dupe(u8, s.ed.buf.items),
                        .eof => break :read null,
                        .interrupt => {
                            s.ed.reset();
                            var out: std.ArrayList(u8) = .empty;
                            defer out.deinit(a);
                            try s.screen.finish(&out);
                            s.term.write(out.items);
                        },
                        .clear_screen => {
                            s.term.write("\x1b[H\x1b[2J");
                            s.screen.forget();
                        },
                        .complete => try s.complete(),
                        .open_editor => {
                            try s.openEditor();
                            s.screen.forget();
                        },
                        .show_trace => if (s.last_trace) |tr| {
                            var out: std.ArrayList(u8) = .empty;
                            defer out.deinit(a);
                            try s.screen.finish(&out);
                            var lines = std.mem.splitScalar(u8, tr, '\n');
                            while (lines.next()) |l| {
                                try out.appendSlice(a, l);
                                try out.appendSlice(a, "\r\n");
                            }
                            s.term.write(out.items);
                        },
                    }
                }
                try s.draw();
            };
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(a);
            // The frame without the hint, the menu, and the parameter row.
            s.clearMenu();
            s.final = true;
            try s.draw();
            s.final = false;
            const c = cmd orelse {
                try s.screen.finish(&out);
                s.term.write(out.items);
                return;
            };
            defer a.free(c);
            try s.screen.finish(&out);
            s.term.write(out.items);
            try s.hist.add(c);
            s.saveHistory();
            try s.run(c);
        }
    }
};

/// The shell that runs now, for the command `shell`.
var active: ?*Shell = null;
