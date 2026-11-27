//! Serial ports as channels (#251, task 05 of
//! docs/dev/web-api-tasks/README.md). `open /dev/ttyUSB0 r+` (Linux),
//! `open /dev/cu.usbserial r+` (macOS), and `open COM3 r+` (Windows) give
//! a channel, and `fconfigure` has the options of a serial port of Tcl 8.6:
//!
//!   -mode baud,parity,data,stop   parity n, o, e, m, or s; data 5 to 8;
//!                                 stop 1 or 2
//!   -handshake type               none, rtscts, xonxoff, or dtrdsr
//!                                 (Windows only)
//!   -xchar {xon xoff}             the characters of xonxoff
//!   -ttycontrol {RTS 1 DTR 0 BREAK 0}
//!                                 sets the output lines
//!   -ttystatus                    a dict of CTS, DSR, RING, and DCD
//!   -queue                        the bytes in the input and the output
//!                                 queue of the system
//!
//! A channel is a serial port when the system takes it as a terminal:
//! `tcgetattr` (`TCGETS2` on Linux, `TIOCGETA` on macOS) or
//! `GetCommState` works on it. `open` puts a new serial port in raw mode,
//! as Tcl does: no echo, no line editing, and no change of the bytes.
//!
//! Linux sets the baud with `termios2` and `BOTHER`, so a rate such as
//! 250000 works. macOS sets a rate out of the table of `termios` with the
//! ioctl `IOSSIOSPEED`. Windows sets the `DCB` of the port.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl.zig");
const Interp = ztcl.Interp;
const Value = ztcl.Value;
const Error = ztcl.interp.Error;

const on_linux = builtin.os.tag == .linux;
const on_mac = builtin.os.tag == .macos;
const on_win = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64;

/// True on the targets with serial ports.
pub const supported = on_linux or on_mac or on_win;

/// The options of a serial port, for the errors of `fconfigure`.
pub const names = [_][]const u8{ "-mode", "-handshake", "-queue", "-ttycontrol", "-ttystatus", "-xchar" };

/// The settings of a port in one form for each system.
const Mode = struct {
    baud: u32,
    parity: u8,
    data: u8,
    stop: u8,
};

// ---- Linux and macOS ----

const posix = struct {
    const linux = std.os.linux;
    /// The ioctl numbers of Linux, or zeros on another system.
    const L = if (on_linux) linux.T else struct {
        const CGETS2 = 0;
        const CSETS2 = 0;
        const IOCMGET = 0;
        const IOCMBIS = 0;
        const IOCMBIC = 0;
        const IOCSBRK = 0;
        const IOCCBRK = 0;
        const FIONREAD = 0;
        const IOCOUTQ = 0;
    };

    /// `struct termios2` of Linux on x86-64 and arm64, and `struct
    /// termios` of macOS. Both have the flags as integers here, so one
    /// table of bits serves each system.
    const Termios = if (on_mac) extern struct {
        iflag: u64,
        oflag: u64,
        cflag: u64,
        lflag: u64,
        cc: [20]u8,
        ispeed: u64 align(8),
        ospeed: u64,
    } else extern struct {
        iflag: u32,
        oflag: u32,
        cflag: u32,
        lflag: u32,
        line: u8,
        cc: [19]u8,
        ispeed: u32,
        ospeed: u32,
    };

    comptime {
        if (on_mac) std.debug.assert(@sizeOf(Termios) == 72);
        if (on_linux) std.debug.assert(@sizeOf(Termios) == 44);
    }

    // The bits of the flags.
    const CSIZE = if (on_mac) 0x300 else 0o60;
    const CS_SHIFT = if (on_mac) 8 else 4;
    const CSTOPB = if (on_mac) 0x400 else 0o100;
    const CREAD = if (on_mac) 0x800 else 0o200;
    const PARENB = if (on_mac) 0x1000 else 0o400;
    const PARODD = if (on_mac) 0x2000 else 0o1000;
    const CLOCAL = if (on_mac) 0x8000 else 0o4000;
    const CRTSCTS = if (on_mac) 0x30000 else 0o20000000000;
    const CMSPAR = if (on_mac) 0 else 0o10000000000;
    const CBAUD = 0o010017;
    const CIBAUD = 0o2003600000;
    const BOTHER = 0o010000;
    const IXON = if (on_mac) 0x200 else 0o2000;
    const IXOFF = if (on_mac) 0x400 else 0o10000;
    const INPCK = 0x10;
    const IGNBRK = 1;
    const VSTART = if (on_mac) 12 else 8;
    const VSTOP = if (on_mac) 13 else 9;
    const VMIN = if (on_mac) 16 else 6;
    const VTIME = if (on_mac) 17 else 5;

    // The lines of the modem, the same on both systems.
    const TIOCM_DTR = 0x002;
    const TIOCM_RTS = 0x004;
    const TIOCM_CTS = 0x020;
    const TIOCM_CAR = 0x040;
    const TIOCM_RNG = 0x080;
    const TIOCM_DSR = 0x100;

    const mac_req = struct {
        const getattr: u32 = 0x40487413; // TIOCGETA
        const setattr: u32 = 0x80487414; // TIOCSETA
        const mget: u32 = 0x4004746a; // TIOCMGET
        const mbis: u32 = 0x8004746c; // TIOCMBIS
        const mbic: u32 = 0x8004746b; // TIOCMBIC
        const sbrk: u32 = 0x2000747b; // TIOCSBRK
        const cbrk: u32 = 0x2000747a; // TIOCCBRK
        const outq: u32 = 0x40047473; // TIOCOUTQ
        const inq: u32 = 0x4004667f; // FIONREAD
        const speed: u32 = 0x80085402; // IOSSIOSPEED
    };

    /// One ioctl. Gives 0, or the error number.
    fn ioctl(fd: i32, linux_req: u32, mac: u32, arg: usize) u16 {
        if (on_mac) {
            if (std.c.ioctl(fd, @bitCast(mac), arg) < 0) return @intCast(std.c._errno().*);
            return 0;
        }
        if (!on_linux) return 38;
        const rc = linux.ioctl(fd, linux_req, arg);
        return @intFromEnum(linux.errno(rc));
    }

    fn getAttr(fd: i32) ?Termios {
        var t: Termios = undefined;
        if (ioctl(fd, L.CGETS2, mac_req.getattr, @intFromPtr(&t)) != 0) return null;
        return t;
    }

    fn setAttr(fd: i32, t: *const Termios) u16 {
        return ioctl(fd, L.CSETS2, mac_req.setattr, @intFromPtr(t));
    }

    /// The rates of the table of macOS `termios`.
    const mac_rates = [_]u32{ 0, 50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 7200, 9600, 14400, 19200, 28800, 38400, 57600, 76800, 115200, 230400 };

    fn mode(t: Termios) Mode {
        const c: u64 = t.cflag;
        const parity: u8 = if (c & PARENB == 0) 'n' else if (CMSPAR != 0 and c & CMSPAR != 0) (if (c & PARODD != 0) 'm' else 's') else if (c & PARODD != 0) 'o' else 'e';
        return .{
            .baud = @intCast(t.ospeed),
            .parity = parity,
            .data = @intCast(5 + ((c & CSIZE) >> CS_SHIFT)),
            .stop = if (c & CSTOPB != 0) 2 else 1,
        };
    }

    fn setMode(t: *Termios, m: Mode) bool {
        var c: u64 = t.cflag;
        c &= ~@as(u64, CSIZE | CSTOPB | PARENB | PARODD | CMSPAR);
        c |= @as(u64, m.data - 5) << CS_SHIFT;
        if (m.stop == 2) c |= CSTOPB;
        switch (m.parity) {
            'o' => c |= PARENB | PARODD,
            'e' => c |= PARENB,
            'm', 's' => {
                if (CMSPAR == 0) return false;
                c |= PARENB | CMSPAR | @as(u64, if (m.parity == 'm') PARODD else 0);
            },
            else => {},
        }
        if (m.parity == 'n') t.iflag &= ~@as(@TypeOf(t.iflag), INPCK) else t.iflag |= INPCK;
        if (on_linux) {
            c &= ~@as(u64, CBAUD | CIBAUD);
            c |= BOTHER;
            t.ispeed = m.baud;
            t.ospeed = m.baud;
        } else {
            // A rate out of the table goes in with IOSSIOSPEED after the
            // set of the attributes.
            const in_table = std.mem.indexOfScalar(u32, &mac_rates, m.baud) != null;
            t.ispeed = if (in_table) m.baud else 9600;
            t.ospeed = t.ispeed;
        }
        t.cflag = @intCast(c);
        return true;
    }

    /// Raw mode, as `TtyInit` of Tcl sets it: no echo, no line editing,
    /// no change of the bytes, and a read that gives each byte at once.
    fn raw(fd: i32) void {
        var t = getAttr(fd) orelse return;
        t.iflag = IGNBRK;
        t.oflag = 0;
        t.lflag = 0;
        t.cflag |= CREAD | CLOCAL;
        t.cc[VMIN] = 1;
        t.cc[VTIME] = 0;
        _ = setAttr(fd, &t);
    }
};

// ---- Windows ----

const win = struct {
    const HANDLE = ?*anyopaque;
    const BOOL = i32;
    const DWORD = u32;

    const DCB = extern struct {
        DCBlength: DWORD = @sizeOf(DCB),
        BaudRate: DWORD = 0,
        flags: DWORD = 0,
        wReserved: u16 = 0,
        XonLim: u16 = 0,
        XoffLim: u16 = 0,
        ByteSize: u8 = 0,
        Parity: u8 = 0,
        StopBits: u8 = 0,
        XonChar: u8 = 0,
        XoffChar: u8 = 0,
        ErrorChar: u8 = 0,
        EofChar: u8 = 0,
        EvtChar: u8 = 0,
        wReserved1: u16 = 0,
    };
    const COMMTIMEOUTS = extern struct { read_interval: DWORD, read_mult: DWORD, read_const: DWORD, write_mult: DWORD, write_const: DWORD };
    const COMSTAT = extern struct { flags: DWORD, in_que: DWORD, out_que: DWORD };

    comptime {
        if (on_win) std.debug.assert(@sizeOf(DCB) == 28);
    }

    // The bits of `DCB.flags`.
    const fBinary: DWORD = 1;
    const fParity: DWORD = 2;
    const fOutxCtsFlow: DWORD = 4;
    const fOutxDsrFlow: DWORD = 8;
    const fDtrControl_shift = 4; // two bits
    const fDsrSensitivity: DWORD = 0x40;
    const fOutX: DWORD = 0x100;
    const fInX: DWORD = 0x200;
    const fRtsControl_shift = 12; // two bits
    const control_enable: DWORD = 1;
    const control_handshake: DWORD = 2;

    const MS_CTS_ON: DWORD = 0x10;
    const MS_DSR_ON: DWORD = 0x20;
    const MS_RING_ON: DWORD = 0x40;
    const MS_RLSD_ON: DWORD = 0x80;
    const SETRTS: DWORD = 3;
    const CLRRTS: DWORD = 4;
    const SETDTR: DWORD = 5;
    const CLRDTR: DWORD = 6;
    const SETBREAK: DWORD = 8;
    const CLRBREAK: DWORD = 9;

    extern "kernel32" fn GetCommState(h: HANDLE, dcb: *DCB) callconv(.winapi) BOOL;
    extern "kernel32" fn SetCommState(h: HANDLE, dcb: *const DCB) callconv(.winapi) BOOL;
    extern "kernel32" fn SetCommTimeouts(h: HANDLE, t: *const COMMTIMEOUTS) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCommModemStatus(h: HANDLE, status: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn EscapeCommFunction(h: HANDLE, func: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn ClearCommError(h: HANDLE, errors: ?*DWORD, stat: ?*COMSTAT) callconv(.winapi) BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?*anyopaque) callconv(.winapi) HANDLE;

    fn handle(fd: i32) HANDLE {
        return ztcl.sys.win.handleOf(fd);
    }

    fn state(fd: i32) ?DCB {
        var d: DCB = .{};
        if (GetCommState(handle(fd), &d) == 0) return null;
        return d;
    }

    /// Timeouts for a blocking read, which gives the bytes that are
    /// there once one byte came, or for a read that gives at once.
    fn timeouts(fd: i32, blocking: bool) void {
        const max = std.math.maxInt(DWORD);
        const t: COMMTIMEOUTS = if (blocking) .{ .read_interval = max, .read_mult = max, .read_const = max - 1, .write_mult = 0, .write_const = 0 } else .{ .read_interval = max, .read_mult = 0, .read_const = 0, .write_mult = 0, .write_const = 0 };
        _ = SetCommTimeouts(handle(fd), &t);
    }

    fn mode(d: DCB) Mode {
        const p = "noems";
        return .{ .baud = d.BaudRate, .parity = if (d.Parity < p.len) p[d.Parity] else 'n', .data = d.ByteSize, .stop = if (d.StopBits == 2) 2 else 1 };
    }
};

// ---- The commands ----

/// True when `fd` is a serial port or another terminal.
pub fn isPort(fd: i32) bool {
    if (comptime on_win) return win.state(fd) != null;
    if (comptime on_linux or on_mac) return posix.getAttr(fd) != null;
    return false;
}

/// Puts a new port in raw mode (Linux and macOS) or sets its timeouts
/// for a blocking read (Windows). `open` calls it for each new file
/// channel that is a port.
pub fn init(fd: i32) void {
    if (comptime on_win) return win.timeouts(fd, true);
    if (comptime on_linux or on_mac) return posix.raw(fd);
}

/// Sets the read timeouts of a Windows port for `-blocking`.
pub fn setBlocking(fd: i32, on: bool) void {
    if (comptime on_win) {
        if (win.state(fd) != null) win.timeouts(fd, on);
    }
}

/// The path of the system for a name of a Windows port, `COM3` or
/// `\\.\COM3`, or null for another name.
pub fn winPortPath(path: []const u8) ?[]const u8 {
    var name = path;
    if (std.mem.startsWith(u8, name, "\\\\.\\") or std.mem.startsWith(u8, name, "//./")) name = name[4..];
    if (name.len < 4 or !std.ascii.eqlIgnoreCase(name[0..3], "com")) return null;
    for (name[3..]) |c| if (!std.ascii.isDigit(c)) return null;
    return name;
}

/// Opens a Windows port, such as `COM3`. Gives the fd, or an error.
pub fn openWin(it: *Interp, name: []const u8, read: bool, write: bool) Error!i32 {
    if (comptime !on_win) return it.fail("couldn't open \"{s}\": no such file or directory", .{name});
    var buf: [32]u16 = undefined;
    const prefix = "\\\\.\\";
    if (prefix.len + name.len + 1 > buf.len) return it.fail("couldn't open \"{s}\": no such file or directory", .{name});
    for (prefix, 0..) |c, k| buf[k] = c;
    for (name, 0..) |c, k| buf[prefix.len + k] = c;
    buf[prefix.len + name.len] = 0;
    const access: u32 = (if (read) @as(u32, 0x80000000) else 0) | (if (write) @as(u32, 0x40000000) else 0);
    const h = win.CreateFileW(buf[0 .. prefix.len + name.len :0], access, 0, null, 3, 0, null);
    if (@intFromPtr(h) == std.math.maxInt(usize)) {
        const e = win.GetLastError();
        if (e == 2) return it.failCode("POSIX ENOENT {no such file or directory}", "couldn't open \"{s}\": no such file or directory", .{name});
        if (e == 5) return it.failCode("POSIX EACCES {permission denied}", "couldn't open \"{s}\": permission denied", .{name});
        return it.fail("couldn't open \"{s}\": Windows error {d}", .{ name, e });
    }
    const fd = ztcl.sys.win.fdOfHandle(h) orelse return it.fail("couldn't open \"{s}\": bad handle", .{name});
    win.timeouts(fd, true);
    return fd;
}

fn currentMode(fd: i32) ?Mode {
    if (comptime on_win) return win.mode(win.state(fd) orelse return null);
    if (comptime on_linux or on_mac) return posix.mode(posix.getAttr(fd) orelse return null);
    return null;
}

fn parseMode(it: *Interp, text: []const u8) Error!Mode {
    const bad = "bad value for -mode: should be baud,parity,data,stop";
    var parts = std.mem.splitScalar(u8, text, ',');
    const b = parts.next() orelse return it.fail(bad, .{});
    const p = parts.next() orelse return it.fail(bad, .{});
    const d = parts.next() orelse return it.fail(bad, .{});
    const s = parts.next() orelse return it.fail(bad, .{});
    if (parts.next() != null) return it.fail(bad, .{});
    const baud = std.fmt.parseInt(u32, b, 10) catch return it.fail(bad, .{});
    if (baud == 0) return it.fail(bad, .{});
    if (p.len != 1 or std.mem.indexOfScalar(u8, "noems", std.ascii.toLower(p[0])) == null) return it.fail("bad value for -mode parity: should be n, o, e, m, or s", .{});
    const data = std.fmt.parseInt(u8, d, 10) catch 0;
    if (data < 5 or data > 8) return it.fail("bad value for -mode data: should be 5, 6, 7, or 8", .{});
    const stop = std.fmt.parseInt(u8, s, 10) catch 0;
    if (stop != 1 and stop != 2) return it.fail("bad value for -mode stop: should be 1 or 2", .{});
    return .{ .baud = baud, .parity = std.ascii.toLower(p[0]), .data = data, .stop = stop };
}

fn errorOf(it: *Interp, what: []const u8, code: u16) Error {
    if (comptime on_linux or on_mac) return ztcl.fsroot.posixError(it, @enumFromInt(code), what);
    return it.fail("{s}error {d}", .{ what, code });
}

fn setModeOf(it: *Interp, fd: i32, m: Mode) Error!void {
    if (comptime on_win) {
        var d = win.state(fd) orelse return it.fail("can't set the mode: not a serial port", .{});
        d.BaudRate = m.baud;
        d.ByteSize = m.data;
        d.Parity = @intCast(std.mem.indexOfScalar(u8, "noems", m.parity).?);
        d.StopBits = if (m.stop == 2) 2 else 0;
        if (m.parity == 'n') d.flags &= ~win.fParity else d.flags |= win.fParity;
        d.flags |= win.fBinary;
        if (win.SetCommState(win.handle(fd), &d) == 0) return it.fail("can't set the mode: Windows error {d}", .{win.GetLastError()});
        return;
    }
    if (comptime on_linux or on_mac) {
        var t = posix.getAttr(fd) orelse return it.fail("can't set the mode: not a serial port", .{});
        if (!posix.setMode(&t, m)) return it.fail("bad value for -mode parity: this system has no mark or space parity", .{});
        const e = posix.setAttr(fd, &t);
        if (e != 0) return errorOf(it, "can't set the mode: ", e);
        if (on_mac and t.ospeed != m.baud) {
            var speed: u64 = m.baud;
            const e2 = posix.ioctl(fd, 0, posix.mac_req.speed, @intFromPtr(&speed));
            if (e2 != 0) return errorOf(it, "can't set the baud: ", e2);
        }
        return;
    }
    return it.fail("serial ports are not available on this target", .{});
}

fn boolOf(it: *Interp, v: Value) Error!bool {
    return @import("expr.zig").truthy(it, v);
}

/// The value of the option `o` of a port, or null when `o` is not an
/// option of a port or `fd` is not a port.
pub fn get(it: *Interp, fd: i32, o: []const u8) Error!?Value {
    if (comptime !supported) return null;
    const a = it.alloc();
    if (std.mem.eql(u8, o, "-mode")) {
        const m = currentMode(fd) orelse return null;
        return .{ .str = try std.fmt.allocPrint(a, "{d},{c},{d},{d}", .{ m.baud, m.parity, m.data, m.stop }) };
    }
    if (std.mem.eql(u8, o, "-xchar")) {
        var x: [2]u8 = undefined;
        if (comptime on_win) {
            const d = win.state(fd) orelse return null;
            x = .{ d.XonChar, d.XoffChar };
        } else {
            const t = posix.getAttr(fd) orelse return null;
            x = .{ t.cc[posix.VSTART], t.cc[posix.VSTOP] };
        }
        return try ztcl.value.newList(a, &.{ .{ .str = try a.dupe(u8, x[0..1]) }, .{ .str = try a.dupe(u8, x[1..2]) } });
    }
    if (std.mem.eql(u8, o, "-ttystatus")) {
        var cts = false;
        var dsr = false;
        var ring = false;
        var dcd = false;
        if (comptime on_win) {
            var s: win.DWORD = 0;
            if (win.GetCommModemStatus(win.handle(fd), &s) == 0) {
                if (win.state(fd) == null) return null;
                return it.fail("can't read the line status: Windows error {d}", .{win.GetLastError()});
            }
            cts = s & win.MS_CTS_ON != 0;
            dsr = s & win.MS_DSR_ON != 0;
            ring = s & win.MS_RING_ON != 0;
            dcd = s & win.MS_RLSD_ON != 0;
        } else {
            if (posix.getAttr(fd) == null) return null;
            var bits: c_int = 0;
            const e = posix.ioctl(fd, posix.L.IOCMGET, posix.mac_req.mget, @intFromPtr(&bits));
            if (e != 0) return errorOf(it, "can't read the line status: ", e);
            cts = bits & posix.TIOCM_CTS != 0;
            dsr = bits & posix.TIOCM_DSR != 0;
            ring = bits & posix.TIOCM_RNG != 0;
            dcd = bits & posix.TIOCM_CAR != 0;
        }
        const b = struct {
            fn v(on: bool) Value {
                return .{ .int = @intFromBool(on) };
            }
        }.v;
        return try ztcl.value.newList(a, &.{ .{ .str = "CTS" }, b(cts), .{ .str = "DSR" }, b(dsr), .{ .str = "RING" }, b(ring), .{ .str = "DCD" }, b(dcd) });
    }
    if (std.mem.eql(u8, o, "-queue")) {
        var in: u32 = 0;
        var out: u32 = 0;
        if (comptime on_win) {
            var s: win.COMSTAT = undefined;
            if (win.ClearCommError(win.handle(fd), null, &s) == 0) return null;
            in = s.in_que;
            out = s.out_que;
        } else {
            if (posix.getAttr(fd) == null) return null;
            var n: c_int = 0;
            if (posix.ioctl(fd, posix.L.FIONREAD, posix.mac_req.inq, @intFromPtr(&n)) == 0) in = @intCast(@max(n, 0));
            n = 0;
            if (posix.ioctl(fd, posix.L.IOCOUTQ, posix.mac_req.outq, @intFromPtr(&n)) == 0) out = @intCast(@max(n, 0));
        }
        return try ztcl.value.newList(a, &.{ .{ .int = in }, .{ .int = out } });
    }
    return null;
}

/// Sets the option `o` of a port. Gives false when `o` is not an option
/// that a port sets, or `fd` is not a port.
pub fn set(it: *Interp, fd: i32, o: []const u8, v: Value) Error!bool {
    if (comptime !supported) return false;
    if (!isPort(fd)) return false;
    if (std.mem.eql(u8, o, "-mode")) {
        try setModeOf(it, fd, try parseMode(it, try it.str(v)));
        return true;
    }
    if (std.mem.eql(u8, o, "-handshake")) {
        const h = try it.str(v);
        const kinds = [_][]const u8{ "none", "rtscts", "xonxoff", "dtrdsr" };
        var k: usize = 0;
        while (k < kinds.len and !std.ascii.eqlIgnoreCase(h, kinds[k])) k += 1;
        if (k == kinds.len) return it.fail("bad value for -handshake: must be one of xonxoff, rtscts, dtrdsr, or none", .{});
        if (comptime on_win) {
            var d = win.state(fd).?;
            d.flags &= ~(win.fOutxCtsFlow | win.fOutxDsrFlow | win.fDsrSensitivity | win.fOutX | win.fInX | (3 << win.fDtrControl_shift) | (3 << win.fRtsControl_shift));
            d.flags |= win.control_enable << win.fDtrControl_shift | win.control_enable << win.fRtsControl_shift;
            switch (k) {
                1 => d.flags = (d.flags & ~@as(win.DWORD, 3 << win.fRtsControl_shift)) | win.fOutxCtsFlow | win.control_handshake << win.fRtsControl_shift,
                2 => d.flags |= win.fOutX | win.fInX,
                3 => d.flags = (d.flags & ~@as(win.DWORD, 3 << win.fDtrControl_shift)) | win.fOutxDsrFlow | win.fDsrSensitivity | win.control_handshake << win.fDtrControl_shift,
                else => {},
            }
            if (win.SetCommState(win.handle(fd), &d) == 0) return it.fail("can't set the handshake: Windows error {d}", .{win.GetLastError()});
            return true;
        }
        if (k == 3) return it.fail("bad value for -handshake: dtrdsr is only on Windows", .{});
        var t = posix.getAttr(fd).?;
        t.cflag &= ~@as(@TypeOf(t.cflag), posix.CRTSCTS);
        t.iflag &= ~@as(@TypeOf(t.iflag), posix.IXON | posix.IXOFF);
        if (k == 1) t.cflag |= posix.CRTSCTS;
        if (k == 2) t.iflag |= posix.IXON | posix.IXOFF;
        const e = posix.setAttr(fd, &t);
        if (e != 0) return errorOf(it, "can't set the handshake: ", e);
        return true;
    }
    if (std.mem.eql(u8, o, "-xchar")) {
        const l = try it.list(v);
        if (l.len != 2) return it.fail("bad value for -xchar: should be a list of two elements", .{});
        var x: [2]u8 = undefined;
        for (l, 0..) |e, k| {
            const s = try it.str(e);
            if (s.len != 1) return it.fail("bad value for -xchar: each element should be one character", .{});
            x[k] = s[0];
        }
        if (comptime on_win) {
            var d = win.state(fd).?;
            d.XonChar = x[0];
            d.XoffChar = x[1];
            if (win.SetCommState(win.handle(fd), &d) == 0) return it.fail("can't set -xchar: Windows error {d}", .{win.GetLastError()});
            return true;
        }
        var t = posix.getAttr(fd).?;
        t.cc[posix.VSTART] = x[0];
        t.cc[posix.VSTOP] = x[1];
        const e = posix.setAttr(fd, &t);
        if (e != 0) return errorOf(it, "can't set -xchar: ", e);
        return true;
    }
    if (std.mem.eql(u8, o, "-ttycontrol")) {
        const l = try it.list(v);
        if (l.len % 2 != 0) return it.fail("bad value for -ttycontrol: should be a list of signal,value pairs", .{});
        var k: usize = 0;
        while (k < l.len) : (k += 2) {
            const sig = try it.str(l[k]);
            const on = try boolOf(it, l[k + 1]);
            const which: u8 = if (std.ascii.eqlIgnoreCase(sig, "rts")) 'r' else if (std.ascii.eqlIgnoreCase(sig, "dtr")) 'd' else if (std.ascii.eqlIgnoreCase(sig, "break")) 'b' else return it.fail("bad signal \"{s}\" for -ttycontrol: must be DTR, RTS or BREAK", .{sig});
            if (comptime on_win) {
                const f: win.DWORD = switch (which) {
                    'r' => if (on) win.SETRTS else win.CLRRTS,
                    'd' => if (on) win.SETDTR else win.CLRDTR,
                    else => if (on) win.SETBREAK else win.CLRBREAK,
                };
                if (win.EscapeCommFunction(win.handle(fd), f) == 0) return it.fail("can't set -ttycontrol: Windows error {d}", .{win.GetLastError()});
                continue;
            }
            const L = posix.L;
            const e = switch (which) {
                'b' => if (on) posix.ioctl(fd, L.IOCSBRK, posix.mac_req.sbrk, 0) else posix.ioctl(fd, L.IOCCBRK, posix.mac_req.cbrk, 0),
                else => blk: {
                    var bits: c_int = if (which == 'r') posix.TIOCM_RTS else posix.TIOCM_DTR;
                    break :blk if (on) posix.ioctl(fd, L.IOCMBIS, posix.mac_req.mbis, @intFromPtr(&bits)) else posix.ioctl(fd, L.IOCMBIC, posix.mac_req.mbic, @intFromPtr(&bits));
                },
            };
            if (e != 0) return errorOf(it, "can't set -ttycontrol: ", e);
        }
        return true;
    }
    if (std.mem.eql(u8, o, "-ttystatus") or std.mem.eql(u8, o, "-queue")) return it.fail("option \"{s}\" is read-only", .{o});
    return false;
}

/// Appends the options of a port and their values, for `fconfigure`
/// with no option.
pub fn options(it: *Interp, fd: i32, out: *std.ArrayList(Value)) Error!void {
    if (comptime !supported) return;
    if (!isPort(fd)) return;
    for ([_][]const u8{ "-mode", "-xchar" }) |o| {
        const v = (try get(it, fd, o)) orelse continue;
        try out.append(it.alloc(), .{ .str = o });
        try out.append(it.alloc(), v);
    }
}

test "the text of -mode" {
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const m = try parseMode(&it, "250000,E,7,2");
    try std.testing.expectEqual(Mode{ .baud = 250000, .parity = 'e', .data = 7, .stop = 2 }, m);
    try std.testing.expectError(error.TclError, parseMode(&it, "9600,n,9,1"));
    try std.testing.expectError(error.TclError, parseMode(&it, "9600,x,8,1"));
    try std.testing.expectError(error.TclError, parseMode(&it, "fast,n,8,1"));
    try std.testing.expectEqualStrings("COM3", winPortPath("\\\\.\\COM3").?);
    try std.testing.expectEqualStrings("com12", winPortPath("com12").?);
    try std.testing.expect(winPortPath("COMX") == null);
    try std.testing.expect(winPortPath("/dev/ttyS0") == null);
}
