//! The notifications of `ztcl::notify` on Windows: a toast of the
//! notification center, through the WinRT API of
//! `Windows.UI.Notifications`.
//!
//! `toastXml` makes the payload: a `ToastGeneric` toast with the title,
//! the subtitle, and the body as its texts, each escaped for XML. `show`
//! loads it into a `Windows.Data.Xml.Dom.XmlDocument`, makes a
//! `ToastNotification` of it, and shows it with the notifier of
//! `ToastNotificationManager.CreateToastNotifierWithId`.
//!
//! A toast needs the app user model ID of the app. A packaged app has
//! one; an unpackaged program such as `ztcl` registers its ID once under
//! `HKCU\Software\Classes\AppUserModelId\ID` with a `DisplayName`, the
//! name that the notification center shows. That key is the only change
//! of the system, and it is made at the first real show. The tests check
//! the payload and show no toast unless `ZTCL_TEST_TOAST=1`.
//!
//! The IIDs and the slots of the interfaces follow
//! `windows.ui.notifications.h` and `windows.data.xml.dom.h` of the
//! Windows SDK 10.0.26100.0. A WinRT interface has the 6 slots of
//! `IInspectable` first.
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const notify = @import("notify.zig");

const HRESULT = i32;
const HSTRING = ?*anyopaque;

const GUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,

    fn parse(comptime s: []const u8) GUID {
        @setEvalBranchQuota(10_000);
        const hex = struct {
            fn n(comptime t: []const u8) u64 {
                return std.fmt.parseInt(u64, t, 16) catch unreachable;
            }
        }.n;
        var d: [8]u8 = undefined;
        d[0] = @intCast(hex(s[19..21]));
        d[1] = @intCast(hex(s[21..23]));
        inline for (0..6) |i| d[2 + i] = @intCast(hex(s[24 + 2 * i ..][0..2]));
        return .{ .a = @intCast(hex(s[0..8])), .b = @intCast(hex(s[9..13])), .c = @intCast(hex(s[14..18])), .d = d };
    }
};

const IID_IToastNotificationManagerStatics = GUID.parse("50ac103f-d235-4598-bbef-98fe4d1a3ad4");
const IID_IToastNotificationFactory = GUID.parse("04124b20-82c6-4229-b109-fd9ed4662b53");
const IID_IXmlDocumentIO = GUID.parse("6cd0e74e-ee65-4489-9ebf-ca43e87ba637");
const IID_IXmlDocument = GUID.parse("f7f3a506-1e87-42d6-bcfb-b8c809fa5494");

const slot = struct {
    const query_interface = 0;
    const release = 2;
    const create_toast_notifier_with_id = 7;
    const show = 6;
    const create_toast_notification = 6;
    const load_xml = 6;
};

extern "api-ms-win-core-winrt-l1-1-0" fn RoInitialize(kind: u32) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoUninitialize() callconv(.winapi) void;
extern "api-ms-win-core-winrt-l1-1-0" fn RoGetActivationFactory(class: HSTRING, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoActivateInstance(class: HSTRING, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateString(s: [*]const u16, len: u32, out: *HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsDeleteString(s: HSTRING) callconv(.winapi) HRESULT;
extern "advapi32" fn RegCreateKeyExW(key: usize, sub: [*:0]const u16, reserved: u32, class: ?[*:0]const u16, options: u32, access: u32, security: ?*anyopaque, out: *usize, disposition: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn RegOpenKeyExW(key: usize, sub: [*:0]const u16, options: u32, access: u32, out: *usize) callconv(.winapi) i32;
extern "advapi32" fn RegSetValueExW(key: usize, name: [*:0]const u16, reserved: u32, kind: u32, data: [*]const u8, len: u32) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(key: usize) callconv(.winapi) i32;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;

/// The app user model ID and the name of `ztcl` in the notification
/// center.
pub const app_id = "ztcl.ztcl";
pub const app_name = "ztcl";

/// Appends `t` with `&`, `<`, `>`, `"`, and `'` as entities.
fn escape(out: *std.ArrayList(u8), a: std.mem.Allocator, t: []const u8) !void {
    for (t) |ch| switch (ch) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&apos;"),
        else => try out.append(a, ch),
    };
}

/// The XML of the toast of `note`: the title, then the subtitle and the
/// body when they are there.
pub fn toastXml(a: std.mem.Allocator, note: *const notify.Note) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "<toast><visual><binding template=\"ToastGeneric\">");
    for ([_][]const u8{ note.title, note.subtitle, note.body }) |t| {
        if (t.len == 0) continue;
        try out.appendSlice(a, "<text>");
        try escape(&out, a, t);
        try out.appendSlice(a, "</text>");
    }
    try out.appendSlice(a, "</binding></visual></toast>");
    return out.toOwnedSlice(a);
}

/// The pointer type of a method: the object, then the types of `Args`.
fn Method(comptime Args: type, comptime R: type) type {
    const info = @typeInfo(Args).@"struct";
    var types: [info.field_types.len + 1]type = undefined;
    types[0] = *anyopaque;
    for (info.field_types, 0..) |ty, i| types[i + 1] = ty;
    const attrs: [types.len]std.builtin.Type.Fn.ParamAttributes = @splat(.{});
    return *const @Fn(&types, &attrs, R, .{ .@"callconv" = .winapi });
}

/// Calls the method at `index` of the table of `obj`.
fn call(comptime R: type, obj: *anyopaque, comptime index: usize, args: anytype) R {
    const F = Method(@TypeOf(args), R);
    const table: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    const f: F = @ptrCast(@alignCast(table.*[index]));
    return @call(.auto, f, .{obj} ++ args);
}

fn release(obj: *anyopaque) void {
    _ = call(u32, obj, slot.release, .{});
}

/// An HSTRING of a UTF-8 text. Free it with `WindowsDeleteString`.
fn hstring(a: std.mem.Allocator, t: []const u8) !HSTRING {
    const w = try std.unicode.utf8ToUtf16LeAlloc(a, t);
    defer a.free(w);
    var h: HSTRING = null;
    if (WindowsCreateString(w.ptr, @intCast(w.len), &h) < 0) return error.WinRT;
    return h;
}

/// The key of the app ID under HKCU, once: the name of the app in the
/// notification center.
fn registerApp(a: std.mem.Allocator) !void {
    const sub = try std.unicode.utf8ToUtf16LeAllocZ(a, "Software\\Classes\\AppUserModelId\\" ++ app_id);
    defer a.free(sub);
    const hkcu: usize = 0x80000001;
    var k: usize = 0;
    // KEY_READ
    if (RegOpenKeyExW(hkcu, sub, 0, 0x20019, &k) == 0) {
        _ = RegCloseKey(k);
        return;
    }
    // KEY_WRITE
    if (RegCreateKeyExW(hkcu, sub, 0, null, 0, 0x20006, null, &k, null) != 0) return error.Registry;
    defer _ = RegCloseKey(k);
    const name = std.unicode.utf8ToUtf16LeStringLiteral(app_name);
    const bytes = std.mem.sliceAsBytes(name[0 .. name.len + 1]);
    // REG_SZ
    if (RegSetValueExW(k, std.unicode.utf8ToUtf16LeStringLiteral("DisplayName"), 0, 1, bytes.ptr, @intCast(bytes.len)) != 0) return error.Registry;
}

/// Shows the toast of `note`. True when the notifier took it.
pub fn show(a: std.mem.Allocator, note: *const notify.Note) bool {
    showToast(a, note, false) catch return false;
    return true;
}

/// Makes the document, the toast, and the notifier of `note` with no
/// registry key and no show, for the tests of the calls.
pub fn dryRun(a: std.mem.Allocator, note: *const notify.Note) !void {
    return showToast(a, note, true);
}

fn showToast(a: std.mem.Allocator, note: *const notify.Note, dry: bool) !void {
    if (!dry) try registerApp(a);
    // RO_INIT_MULTITHREADED. S_FALSE and RPC_E_CHANGED_MODE keep the
    // apartment of the thread.
    const ro = RoInitialize(1);
    defer if (ro == 0 or ro == 1) RoUninitialize();
    const xml = try toastXml(a, note);
    defer a.free(xml);

    const doc_class = try hstring(a, "Windows.Data.Xml.Dom.XmlDocument");
    defer _ = WindowsDeleteString(doc_class);
    var doc: ?*anyopaque = null;
    if (RoActivateInstance(doc_class, &doc) < 0) return error.WinRT;
    defer release(doc.?);
    var io: ?*anyopaque = null;
    if (call(HRESULT, doc.?, slot.query_interface, .{ &IID_IXmlDocumentIO, &io }) < 0) return error.WinRT;
    defer release(io.?);
    const text = try hstring(a, xml);
    defer _ = WindowsDeleteString(text);
    if (call(HRESULT, io.?, slot.load_xml, .{text}) < 0) return error.WinRT;
    var xdoc: ?*anyopaque = null;
    if (call(HRESULT, doc.?, slot.query_interface, .{ &IID_IXmlDocument, &xdoc }) < 0) return error.WinRT;
    defer release(xdoc.?);

    const toast_class = try hstring(a, "Windows.UI.Notifications.ToastNotification");
    defer _ = WindowsDeleteString(toast_class);
    var factory: ?*anyopaque = null;
    if (RoGetActivationFactory(toast_class, &IID_IToastNotificationFactory, &factory) < 0) return error.WinRT;
    defer release(factory.?);
    var toast: ?*anyopaque = null;
    if (call(HRESULT, factory.?, slot.create_toast_notification, .{ xdoc.?, &toast }) < 0) return error.WinRT;
    defer release(toast.?);

    const mgr_class = try hstring(a, "Windows.UI.Notifications.ToastNotificationManager");
    defer _ = WindowsDeleteString(mgr_class);
    var mgr: ?*anyopaque = null;
    if (RoGetActivationFactory(mgr_class, &IID_IToastNotificationManagerStatics, &mgr) < 0) return error.WinRT;
    defer release(mgr.?);
    const id = try hstring(a, app_id);
    defer _ = WindowsDeleteString(id);
    var notifier: ?*anyopaque = null;
    if (call(HRESULT, mgr.?, slot.create_toast_notifier_with_id, .{ id, &notifier }) < 0) return error.WinRT;
    defer release(notifier.?);
    if (dry) return;
    if (call(HRESULT, notifier.?, slot.show, .{toast.?}) < 0) return error.WinRT;
}

const tt = std.testing;

test "notify on Windows: the toast is ToastGeneric with the texts escaped" {
    const x = try toastXml(tt.allocator, &.{ .title = "Build <done>", .subtitle = "", .body = "a & b \"c\"" });
    defer tt.allocator.free(x);
    try tt.expectEqualStrings("<toast><visual><binding template=\"ToastGeneric\"><text>Build &lt;done&gt;</text><text>a &amp; b &quot;c&quot;</text></binding></visual></toast>", x);
}

test "notify on Windows: a real toast with ZTCL_TEST_TOAST=1" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var buf: [8]u16 = undefined;
    if (GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZTCL_TEST_TOAST"), &buf, buf.len) == 0) return error.SkipZigTest;
    try tt.expect(show(tt.allocator, &.{ .title = "ztcl test", .body = "A toast of the tests of ztcl" }));
}

test "notify on Windows: the document, the toast, and the notifier come from WinRT, with no show" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    try dryRun(tt.allocator, &.{ .title = "ztcl test", .body = "A toast that does not show" });
}
