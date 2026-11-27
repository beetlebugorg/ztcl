//! The module `ztcl::vt`: the state of a terminal, on libghostty-vt.
//!
//! `Term` holds a `Terminal` of libghostty-vt and its stream. `write`
//! feeds bytes to the parser of the stream, and the stream changes the
//! grid, the cursor, the modes, and the scrollback. The bytes that the
//! terminal sends back to the program (the replies of DA, DSR, the mode
//! queries, and the OSC color queries) go to `reply`. `row` reads one row of the screen by its
//! index from the top of the scrollback. `dirty` runs an update of a
//! `RenderState`, which gives the rows that changed since the last
//! update, and the update clears the dirty flags of the terminal.
//!
//! The terminal does no I/O. Its `std.Io` is `std.Io.failing`, so the
//! Kitty image forms that read a file fail. The memory comes from the
//! counting allocator of the interpreter, so the memory limit applies.
//!
//! The Tcl command is an ensemble of subcommands on a handle. `ztk`
//! uses `Term` for the core of `ztk::terminal`.
//!
//! libghostty-vt is MIT code by Mitchell Hashimoto and the Ghostty
//! contributors (`docs/references/ghostty.md`).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const gvt = @import("ghostty-vt");
const interp = @import("interp.zig");
const mods = @import("modules.zig");
const value = @import("value.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Allocator = std.mem.Allocator;

/// A color of a cell: the default, an index of the 256-color palette,
/// or RGB.
pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,
};

pub const Attrs = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
    _pad: u8 = 0,
};

pub const Cell = struct {
    /// The first code point, or 0 for an empty cell.
    cp: u21 = 0,
    /// 1 for a normal cell, 2 for the first cell of a wide character,
    /// and 0 for the spacer after it.
    width: u2 = 1,
    attrs: Attrs = .{},
    fg: Color = .default,
    bg: Color = .default,
};

pub const MouseMode = enum { none, x10, normal, button, any };

pub const Modes = struct {
    cursor_keys_app: bool,
    keypad_app: bool,
    cursor_visible: bool,
    bracketed_paste: bool,
    focus_events: bool,
    mouse: MouseMode,
    mouse_sgr: bool,
    alt_screen: bool,
};

pub const Term = struct {
    gpa: Allocator,
    t: gvt.Terminal,
    stream: gvt.TerminalStream,
    render: gvt.RenderState = .empty,
    /// The bytes that the terminal sends back to the program.
    reply: std.ArrayList(u8) = .empty,
    bells: u32 = 0,
    /// True after a failed allocation of a reply.
    reply_failed: bool = false,

    /// A new terminal of `cols` by `rows` cells, with at most
    /// `scrollback` lines of scrollback.
    pub fn create(gpa: Allocator, cols: u16, rows: u16, scrollback: usize) !*Term {
        const self = try gpa.create(Term);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .t = try .init(std.Io.failing, gpa, .{
                .cols = @max(cols, 1),
                .rows = @max(rows, 1),
                .max_scrollback_bytes = null,
                .max_scrollback_lines = scrollback,
                // The OSC queries 10, 11, and 12 get black on white.
                .colors = .{
                    .foreground = .init(.{ .r = 0, .g = 0, .b = 0 }),
                    .background = .init(.{ .r = 255, .g = 255, .b = 255 }),
                    .cursor = .unset,
                    .palette = .default,
                },
            }),
            .stream = undefined,
        };
        self.stream = self.t.vtStream();
        self.stream.handler.effects.write_pty = writePty;
        self.stream.handler.effects.bell = bell;
        self.stream.handler.effects.device_attributes = deviceAttributes;
        return self;
    }

    pub fn destroy(self: *Term) void {
        const gpa = self.gpa;
        self.stream.deinit();
        self.render.deinit(gpa);
        self.reply.deinit(gpa);
        self.t.deinit(gpa);
        gpa.destroy(self);
    }

    fn fromHandler(h: *gvt.TerminalStream.Handler) *Term {
        const s: *gvt.TerminalStream = @alignCast(@fieldParentPtr("handler", h));
        return @alignCast(@fieldParentPtr("stream", s));
    }

    fn writePty(h: *gvt.TerminalStream.Handler, bytes: []const u8) void {
        const self = fromHandler(h);
        self.reply.appendSlice(self.gpa, bytes) catch {
            self.reply_failed = true;
        };
    }

    /// The reply of DA1, DA2, and DA3: the defaults of libghostty-vt.
    fn deviceAttributes(_: *gvt.TerminalStream.Handler) gvt.device_attributes.Attributes {
        return .{};
    }

    fn bell(h: *gvt.TerminalStream.Handler) void {
        fromHandler(h).bells +%= 1;
    }

    pub fn write(self: *Term, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    pub fn resize(self: *Term, cols: u16, rows: u16) !void {
        try self.t.resize(self.gpa, .{ .cols = @max(cols, 1), .rows = @max(rows, 1) });
    }

    pub fn colCount(self: *const Term) u16 {
        return self.t.cols;
    }

    pub fn rowCount(self: *const Term) u16 {
        return self.t.rows;
    }

    fn pages(self: *const Term) *const gvt.PageList {
        return &self.t.screens.active.pages;
    }

    /// The count of scrollback lines above the active area.
    pub fn scrollbackLen(self: *const Term) usize {
        const p = self.pages();
        return p.total_rows - p.rows;
    }

    /// The cursor in the active area, from 0.
    pub fn cursor(self: *const Term) struct { x: u16, y: u16 } {
        const c = self.t.screens.active.cursor;
        return .{ .x = c.x, .y = c.y };
    }

    /// The DECSCUSR style: 0 for the default, then 1 to 6.
    pub fn cursorStyle(self: *const Term) u8 {
        const c = self.t.screens.active.cursor;
        const blink = self.t.modes.get(.cursor_blinking);
        const base: u8 = switch (c.cursor_style) {
            .block, .block_hollow => 1,
            .underline => 3,
            .bar => 5,
        };
        return if (blink) base else base + 1;
    }

    pub fn modes(self: *const Term) Modes {
        const m = &self.t.modes;
        return .{
            .cursor_keys_app = m.get(.cursor_keys),
            .keypad_app = m.get(.keypad_keys),
            .cursor_visible = m.get(.cursor_visible),
            .bracketed_paste = m.get(.bracketed_paste),
            .focus_events = m.get(.focus_event),
            .mouse = switch (self.t.flags.mouse_event) {
                .none => .none,
                .x10 => .x10,
                .normal => .normal,
                .button => .button,
                .any => .any,
            },
            .mouse_sgr = self.t.flags.mouse_format == .sgr,
            .alt_screen = self.t.screens.active_key == .alternate,
        };
    }

    /// The title from OSC 0 or OSC 2, or empty.
    pub fn title(self: *const Term) []const u8 {
        return self.t.getTitle() orelse "";
    }

    /// Reads row `y` of the screen (0 is the top of the scrollback) into
    /// `out`, which has `colCount()` cells. Returns true when the row wraps
    /// into the next row.
    pub fn row(self: *const Term, y: usize, out: []Cell) bool {
        @memset(out, .{});
        const pin = self.pages().pin(.{ .screen = .{ .x = 0, .y = @intCast(y) } }) orelse return false;
        const rc = pin.rowAndCell();
        const cells = pin.cells(.all);
        for (cells[0..@min(cells.len, out.len)], out[0..@min(cells.len, out.len)]) |*c, *o| {
            o.* = convert(pin, c);
        }
        return rc.row.wrap;
    }

    fn convert(pin: gvt.Pin, c: *const gvt.Cell) Cell {
        var o: Cell = .{};
        switch (c.content_tag) {
            .codepoint, .codepoint_grapheme => o.cp = c.content.codepoint.data,
            .bg_color_palette => o.bg = .{ .index = c.content.color_palette.data },
            .bg_color_rgb => {
                const v = c.content.color_rgb;
                o.bg = .{ .rgb = .{ v.r, v.g, v.b } };
            },
        }
        o.width = switch (c.wide) {
            .narrow => 1,
            .wide => 2,
            .spacer_tail, .spacer_head => 0,
        };
        if (c.style_id == 0 or c.content_tag == .bg_color_palette or c.content_tag == .bg_color_rgb) return o;
        const s = pin.style(c);
        o.fg = color(s.fg_color.value());
        o.bg = color(s.bg_color.value());
        o.attrs = .{
            .bold = s.flags.bold,
            .dim = s.flags.faint,
            .italic = s.flags.italic,
            .underline = s.flags.underline != .none,
            .blink = s.flags.blink,
            .inverse = s.flags.inverse,
            .hidden = s.flags.invisible,
            .strike = s.flags.strikethrough,
        };
        return o;
    }

    fn color(v: anytype) Color {
        return switch (v) {
            .none => .default,
            .palette => |i| .{ .index = i },
            .rgb => |c| .{ .rgb = .{ c.r, c.g, c.b } },
        };
    }

    /// Runs an update of the render state and appends the indexes of
    /// the rows of the active area that changed since the last call.
    /// A change of the size or of the colors gives each row.
    pub fn dirty(self: *Term, out: *std.ArrayList(u16), a: Allocator) !void {
        try self.render.update(self.gpa, &self.t);
        const full = self.render.dirty == .full;
        const flags = self.render.row_data.items(.dirty);
        for (flags, 0..) |*d, i| {
            if (full or d.*) try out.append(a, @intCast(i));
            d.* = false;
        }
        self.render.dirty = .false;
    }

    /// The text of the screen: each row of the active area, with the
    /// trailing blanks removed.
    pub fn plainString(self: *Term, a: Allocator) ![]const u8 {
        return self.t.plainString(a);
    }
};

/// A log function with no output. libghostty-vt logs the sequences
/// that it does not handle. The interpreter does not write to
/// stderr, so each root of a program sets `std_options.logFn` to this.
pub fn noLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

// ---- The Tcl command ----

pub const modules_list = [_]mods.Module{.{
    .name = "ztcl::vt",
    .version = "1.0",
    .install = install,
}};

pub const modules: []const mods.Module = &modules_list;

/// The terminals of one interpreter. A handle `vtN` is the index N.
pub const State = struct {
    terms: std.ArrayList(?*Term) = .empty,
};

fn install(it: *Interp) interp.Error!void {
    try it.register("ztcl::vt", cmd);
}

/// Frees each terminal of `it`. `Interp.deinit` calls it.
pub fn closeAll(it: *Interp) void {
    const s: *State = @ptrCast(@alignCast(it.vt_state orelse return));
    const gpa = it.heap.backing;
    for (s.terms.items) |t| if (t) |p| p.destroy();
    s.terms.deinit(gpa);
    gpa.destroy(s);
    it.vt_state = null;
}

fn state(it: *Interp) !*State {
    if (it.vt_state) |p| return @ptrCast(@alignCast(p));
    const s = try it.heap.backing.create(State);
    s.* = .{};
    it.vt_state = s;
    return s;
}

const usage = "ztcl::vt new|feed|resize|size|cursor|modes|rows|cells|dirty|scrollback|title|bells|delete ?arg ...?";

fn lookup(it: *Interp, v: Value) interp.Error!*Term {
    const name = try it.str(v);
    const s = try state(it);
    if (std.mem.startsWith(u8, name, "vt")) {
        if (std.fmt.parseInt(usize, name[2..], 10)) |i| {
            if (i < s.terms.items.len) if (s.terms.items[i]) |t| return t;
        } else |_| {}
    }
    return it.failCode("ZTCL VT HANDLE", "can not find terminal \"{s}\"", .{name});
}

fn size16(it: *Interp, v: Value) interp.Error!u16 {
    const n = try it.int(v);
    if (n < 1 or n > 4096) return it.failCode("ZTCL VT SIZE", "the size {d} is outside 1 to 4096", .{n});
    return @intCast(n);
}

fn list(it: *Interp, items: []const Value) interp.Error!Value {
    return value.wrapList(it.alloc(), try it.alloc().dupe(Value, items));
}

fn cmd(it: *Interp, argv: []const Value, _: ?*interp.Cmd) interp.Error!Value {
    if (argv.len < 2) return it.wrongArgs(usage);
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "new")) return cmdNew(it, argv);
    if (argv.len < 3) return it.wrongArgs(usage);
    const t = try lookup(it, argv[2]);
    if (std.mem.eql(u8, sub, "feed")) {
        if (argv.len != 4) return it.wrongArgs("ztcl::vt feed handle bytes");
        t.write(try it.str(argv[3]));
        const r = try a.dupe(u8, t.reply.items);
        t.reply.clearRetainingCapacity();
        if (t.reply_failed) {
            t.reply_failed = false;
            return error.OutOfMemory;
        }
        return .{ .str = r };
    }
    if (std.mem.eql(u8, sub, "resize")) {
        if (argv.len != 5) return it.wrongArgs("ztcl::vt resize handle cols rows");
        t.resize(try size16(it, argv[3]), try size16(it, argv[4])) catch return error.OutOfMemory;
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "size")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::vt size handle");
        return list(it, &.{ .{ .int = t.colCount() }, .{ .int = t.rowCount() } });
    }
    if (std.mem.eql(u8, sub, "cursor")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::vt cursor handle");
        const c = t.cursor();
        return list(it, &.{ .{ .int = c.x }, .{ .int = c.y } });
    }
    if (std.mem.eql(u8, sub, "modes")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::vt modes handle");
        const m = t.modes();
        var out: [18]Value = undefined;
        var n: usize = 0;
        inline for (.{ "cursor_keys_app", "keypad_app", "cursor_visible", "bracketed_paste", "focus_events", "mouse_sgr", "alt_screen" }) |f| {
            out[n] = .{ .str = f };
            out[n + 1] = .{ .int = @intFromBool(@field(m, f)) };
            n += 2;
        }
        out[n] = .{ .str = "mouse" };
        out[n + 1] = .{ .str = @tagName(m.mouse) };
        out[n + 2] = .{ .str = "cursor_style" };
        out[n + 3] = .{ .int = t.cursorStyle() };
        return list(it, out[0 .. n + 4]);
    }
    if (std.mem.eql(u8, sub, "rows") or std.mem.eql(u8, sub, "cells")) return cmdRows(it, argv, t, sub[0] == 'c');
    if (std.mem.eql(u8, sub, "dirty")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::vt dirty handle");
        var ys: std.ArrayList(u16) = .empty;
        t.dirty(&ys, a) catch return error.OutOfMemory;
        const out = try a.alloc(Value, ys.items.len);
        for (ys.items, out) |y, *o| o.* = .{ .int = y };
        return value.wrapList(a, out);
    }
    if (std.mem.eql(u8, sub, "scrollback")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::vt scrollback handle");
        return .{ .int = @intCast(t.scrollbackLen()) };
    }
    if (std.mem.eql(u8, sub, "title")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::vt title handle");
        return .{ .str = try a.dupe(u8, t.title()) };
    }
    if (std.mem.eql(u8, sub, "bells")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::vt bells handle");
        return .{ .int = t.bells };
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::vt delete handle");
        const s = try state(it);
        for (s.terms.items) |*p| if (p.* == t) {
            p.* = null;
        };
        t.destroy();
        return Value.empty;
    }
    return it.failCode("TCL LOOKUP SUBCOMMAND", "unknown subcommand \"{s}\": must be new, feed, resize, size, cursor, modes, rows, cells, dirty, scrollback, title, bells, or delete", .{sub});
}

fn cmdNew(it: *Interp, argv: []const Value) interp.Error!Value {
    var cols: u16 = 80;
    var rows: u16 = 24;
    var sb: usize = 1000;
    var i: usize = 2;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) return it.wrongArgs("ztcl::vt new ?-size {{cols rows}}? ?-scrollback lines?");
        const opt = try it.str(argv[i]);
        if (std.mem.eql(u8, opt, "-size")) {
            const l = try it.list(argv[i + 1]);
            if (l.len != 2) return it.failCode("ZTCL VT SIZE", "the size must be a list of cols and rows", .{});
            cols = try size16(it, l[0]);
            rows = try size16(it, l[1]);
        } else if (std.mem.eql(u8, opt, "-scrollback")) {
            const n = try it.int(argv[i + 1]);
            if (n < 0 or n > 1_000_000) return it.failCode("ZTCL VT SCROLLBACK", "the scrollback {d} is outside 0 to 1000000", .{n});
            sb = @intCast(n);
        } else return it.failCode("TCL LOOKUP OPTION", "bad option \"{s}\": must be -size or -scrollback", .{opt});
    }
    const s = try state(it);
    const t = Term.create(it.heap.backing, cols, rows, sb) catch return error.OutOfMemory;
    errdefer t.destroy();
    try s.terms.append(it.heap.backing, t);
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "vt{d}", .{s.terms.items.len - 1}) };
}

/// `rows handle ?first? ?last?` gives the text of each row, and `cells`
/// gives a list of cells for each row. A row index is in the active
/// area from 0, and a negative index is a line of the scrollback (-1 is
/// the last line).
fn cmdRows(it: *Interp, argv: []const Value, t: *Term, cells: bool) interp.Error!Value {
    if (argv.len > 5) return it.wrongArgs("ztcl::vt rows|cells handle ?first? ?last?");
    const a = it.alloc();
    const sb: i64 = @intCast(t.scrollbackLen());
    const h: i64 = t.rowCount();
    const first = std.math.clamp(if (argv.len > 3) try it.int(argv[3]) else 0, -sb, h - 1);
    const last = std.math.clamp(if (argv.len > 4) try it.int(argv[4]) else if (argv.len > 3) first else h - 1, -sb, h - 1);
    const buf = try a.alloc(Cell, t.colCount());
    var out: std.ArrayList(Value) = .empty;
    var y = first;
    while (y <= last) : (y += 1) {
        _ = t.row(@intCast(y + sb), buf);
        try out.append(a, if (cells) try cellList(it, buf) else .{ .str = try rowText(a, buf) });
    }
    return value.wrapList(a, out.items);
}

fn rowText(a: Allocator, cells: []const Cell) ![]const u8 {
    var end = cells.len;
    while (end > 0 and (cells[end - 1].cp == 0 or cells[end - 1].cp == ' ')) end -= 1;
    var out: std.ArrayList(u8) = .empty;
    for (cells[0..end]) |c| {
        if (c.width == 0) continue;
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(if (c.cp == 0) ' ' else c.cp, &b) catch 1;
        try out.appendSlice(a, b[0..n]);
    }
    return out.items;
}

/// One cell is a list: the text, the width, the foreground, the
/// background, and the list of attributes. A color is empty for the
/// default, an index of the palette, or `#rrggbb`.
fn cellList(it: *Interp, cells: []const Cell) interp.Error!Value {
    const a = it.alloc();
    const out = try a.alloc(Value, cells.len);
    for (cells, out) |c, *o| {
        var b: [4]u8 = undefined;
        const n = if (c.cp == 0) 0 else std.unicode.utf8Encode(c.cp, &b) catch 0;
        var at: [8]Value = undefined;
        var k: usize = 0;
        inline for (.{ "bold", "dim", "italic", "underline", "blink", "inverse", "hidden", "strike" }) |f| {
            if (@field(c.attrs, f)) {
                at[k] = .{ .str = f };
                k += 1;
            }
        }
        o.* = try list(it, &.{
            .{ .str = try a.dupe(u8, b[0..n]) },
            .{ .int = c.width },
            try colorValue(a, c.fg),
            try colorValue(a, c.bg),
            try list(it, at[0..k]),
        });
    }
    return value.wrapList(a, out);
}

fn colorValue(a: Allocator, c: Color) !Value {
    return switch (c) {
        .default => Value.empty,
        .index => |i| .{ .int = i },
        .rgb => |v| .{ .str = try std.fmt.allocPrint(a, "#{x:0>2}{x:0>2}{x:0>2}", .{ v[0], v[1], v[2] }) },
    };
}
