//! The shell of the runner in ztcl-shell.wasm: the line editor of
//! `src/shell/shell.zig` on a terminal of `ztcl::vt`.
//!
//! The page gives the bytes of each key to `ztcl_shell_feed`. The shell
//! writes its ANSI output, the output of `puts`, and the results into a
//! `vt.Term`. The page reads the cells of the screen with
//! `ztcl_shell_cells` and renders them. The output of `puts` goes
//! through a translation of "\n" to "\r\n", as the line discipline of
//! a terminal does. Ctrl-D on an empty line starts a new prompt, so the shell does
//! not end.
//!
//! A cell is three u32 words: the code point with the width in bits 21
//! and 22 and the attributes of `vt.Attrs` from bit 23, then the
//! foreground and the background. A color is 0 for the default,
//! 0x1000000 + index for the palette, and 0x2000000 + 0xRRGGBB for RGB.
//!
//! The shell has no capability of ztcl. `ztcl_shell_files` gives it a
//! bundle payload (`src/wasmbundle.zig`) of read-only files, with the
//! commands of `src/wasmfiles.zig`, so Tab completes the names of those
//! files. Each command gets the compute limit of `ztcl_shell_new`, and
//! each question of the shell for a completion gets 1,000,000 compute
//! units.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const root = @import("wasm.zig");
const vt = @import("vt.zig");
const wasmfiles = @import("wasmfiles.zig");
const Shell = @import("ztcl.zig").shell.Shell;
const Handle = root.Handle;
const gpa = root.gpa;

const WebShell = struct {
    h: *Handle,
    sh: Shell,
    term: *vt.Term,
    cells: std.ArrayList(u32) = .empty,
    row: std.ArrayList(vt.Cell) = .empty,
};

fn termOut(ctx: *anyopaque, bytes: []const u8) void {
    const ws: *WebShell = @ptrCast(@alignCast(ctx));
    ws.term.write(bytes);
}

fn putsOut(ctx: ?*anyopaque, bytes: []const u8) void {
    const ws: *WebShell = @ptrCast(@alignCast(ctx.?));
    var rest = bytes;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |k| {
        ws.term.write(rest[0..k]);
        ws.term.write("\r\n");
        rest = rest[k + 1 ..];
    }
    ws.term.write(rest);
}

/// A shell on the interpreter of `h`, with a terminal of `cols` by
/// `rows` cells and 2,000 lines of scrollback. Each command gets
/// `compute_limit` compute units.
export fn ztcl_shell_new(h: *Handle, cols: u16, rows: u16, compute_limit: u64) ?*WebShell {
    const ws = gpa.create(WebShell) catch return null;
    const term = vt.Term.create(gpa, @max(cols, 10), @max(rows, 2), 2000) catch {
        gpa.destroy(ws);
        return null;
    };
    ws.* = .{
        .h = h,
        .term = term,
        .sh = Shell.init(gpa, &h.it, .{ .io = std.Io.failing, .compute_limit = compute_limit, .probe_limit = 1_000_000, .puts_to_term = true }),
    };
    ws.sh.term.out = .{ .ctx = ws, .write = termOut };
    ws.sh.term.cols = term.colCount();
    ws.sh.term.rows = term.rowCount();
    ws.sh.begin() catch return null;
    return ws;
}

/// Gives the shell the read-only files of a bundle payload. The memory
/// at `ptr` stays valid while the shell lives.
export fn ztcl_shell_files(ws: *WebShell, ptr: [*]const u8, len: usize) i32 {
    const h = ws.h;
    if (h.files.on) return 0;
    h.files = .{ .payload = ptr[0..len], .on = true };
    wasmfiles.Commands(root.filesOf, gpa).register(&h.it) catch return 1;
    return 0;
}

/// Writes text to the terminal, for a line of the page above the prompt.
export fn ztcl_shell_print(ws: *WebShell, ptr: [*]const u8, len: usize) void {
    ws.term.write("\r\x1b[J");
    putsOut(ws, ptr[0..len]);
    ws.sh.resize(ws.term.colCount(), ws.term.rowCount()) catch {};
}

/// Handles the key bytes at `ptr`. `flush` is 1 when the bytes end a
/// key, so a lone Escape is a key. Gives 0, or 1 when the memory ends.
export fn ztcl_shell_feed(ws: *WebShell, ptr: [*]const u8, len: usize, flush: u32) i32 {
    const more = ws.sh.feed(ptr[0..len], flush != 0) catch return 1;
    if (!more) ws.sh.begin() catch return 1;
    return 0;
}

export fn ztcl_shell_resize(ws: *WebShell, cols: u16, rows: u16) i32 {
    ws.term.resize(@max(cols, 10), @max(rows, 2)) catch return 1;
    ws.sh.resize(ws.term.colCount(), ws.term.rowCount()) catch return 1;
    return 0;
}

/// Sets the vim keys on (1) or off (0), as `shell mode vi` does.
export fn ztcl_shell_set_vi(ws: *WebShell, on: u32) void {
    ws.sh.setVi(on != 0) catch {};
}

export fn ztcl_shell_scrollback(ws: *WebShell) usize {
    return ws.term.scrollbackLen();
}

fn colorWord(c: vt.Color) u32 {
    return switch (c) {
        .default => 0,
        .index => |i| 0x1000000 + @as(u32, i),
        .rgb => |v| 0x2000000 + (@as(u32, v[0]) << 16) + (@as(u32, v[1]) << 8) + v[2],
    };
}

/// Fills the cells of the screen, `up` lines above the bottom of the
/// scrollback, and gives their address: rows times cols times three
/// words. Gives 0 when the memory ends.
export fn ztcl_shell_cells(ws: *WebShell, up: usize) usize {
    const cols = ws.term.colCount();
    const rows = ws.term.rowCount();
    ws.cells.resize(gpa, @as(usize, cols) * rows * 3) catch return 0;
    ws.row.resize(gpa, cols) catch return 0;
    const top = ws.term.scrollbackLen() -| up;
    for (0..rows) |y| {
        _ = ws.term.row(top + y, ws.row.items);
        for (ws.row.items, 0..) |c, x| {
            const at = (y * cols + x) * 3;
            const attrs: u32 = @as(u8, @truncate(@as(u16, @bitCast(c.attrs))));
            ws.cells.items[at] = @as(u32, c.cp) | (@as(u32, c.width) << 21) | (attrs << 23);
            ws.cells.items[at + 1] = colorWord(c.fg);
            ws.cells.items[at + 2] = colorWord(c.bg);
        }
    }
    return @intFromPtr(ws.cells.items.ptr);
}

/// The cursor: x in bits 0 to 15, y in bits 16 to 23, the DECSCUSR style
/// in bits 24 to 27, and bit 28 when the cursor shows.
export fn ztcl_shell_cursor(ws: *WebShell) u32 {
    const c = ws.term.cursor();
    const shown: u32 = @intFromBool(ws.term.modes().cursor_visible);
    return @as(u32, c.x) | (@as(u32, @min(c.y, 255)) << 16) | (@as(u32, ws.term.cursorStyle() & 15) << 24) | (shown << 28);
}

/// 1 after the editor key (Ctrl-X Ctrl-E, or `v` in normal mode): the
/// page edits the text of `ztcl_shell_line_ptr` and calls
/// `ztcl_shell_set_line`.
export fn ztcl_shell_editor(ws: *WebShell) u32 {
    return @intFromBool(ws.sh.editor_request);
}

export fn ztcl_shell_line_ptr(ws: *WebShell) [*]const u8 {
    return ws.sh.ed.buf.items.ptr;
}

export fn ztcl_shell_line_len(ws: *WebShell) usize {
    return ws.sh.ed.buf.items.len;
}

export fn ztcl_shell_set_line(ws: *WebShell, ptr: [*]const u8, len: usize) i32 {
    ws.sh.setLine(ptr[0..len]) catch return 1;
    return 0;
}

/// The compute units of the last command.
export fn ztcl_shell_last_compute(ws: *WebShell) u64 {
    return ws.sh.last_compute;
}
