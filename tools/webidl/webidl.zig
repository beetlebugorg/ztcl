//! The generator of the table of the Web IDL for the commands `web::`
//! (task 04 of docs/dev/web-api-tasks/README.md).
//!
//! `generate` reads Web IDL sources and writes `web/webidl-table.mjs`:
//! the interfaces with their attributes and operations, the
//! dictionaries, the enums, the typedefs, and the roots of `web::root`.
//! The group of a definition is the name of its file (`serial` for
//! `serial.webidl`). A source with no group (`base.webidl`) has the
//! roots and the types of other specs.
//!
//! The parser reads the definitions of the Web IDL spec that the tables
//! use. It skips constructors, constants, static members, stringifiers,
//! iterables, callbacks, and namespaces. A `maplike` gives `size`, `get`,
//! `has`, `keys`, and `values`, and a `setlike` gives `size`, `has`, and
//! `values`. `keys` and `values` give a sequence. A second operation
//! with the name of an earlier one (an overload) is left out. The mixins
//! of `includes` go into their interfaces.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Source = struct {
    /// The group, or null for a source of roots and shared types.
    group: ?[]const u8,
    text: []const u8,
};

pub const Error = error{ OutOfMemory, BadIdl };

const Arg = struct { name: []const u8, type: []const u8, optional: bool, variadic: bool };

const Member = struct {
    name: []const u8,
    /// The type of an attribute, or the return type of an operation.
    type: []const u8,
    op: bool,
    readonly: bool = false,
    args: []const Arg = &.{},
    group: ?[]const u8,
};

const Iface = struct {
    name: []const u8,
    inherits: ?[]const u8 = null,
    group: ?[]const u8 = null,
    mixin: bool = false,
    members: std.ArrayList(Member) = .empty,
};

const DictMember = struct { name: []const u8, type: []const u8, required: bool };

const Dict = struct {
    name: []const u8,
    inherits: ?[]const u8 = null,
    members: std.ArrayList(DictMember) = .empty,
};

const Enum = struct { name: []const u8, values: std.ArrayList([]const u8) = .empty };
const Typedef = struct { name: []const u8, type: []const u8 };
const Include = struct { target: []const u8, mixin: []const u8 };

const Tok = struct {
    kind: enum { ident, string, number, punct, eof },
    text: []const u8,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn tokenize(a: Allocator, s: []const u8) Error![]Tok {
    var out: std.ArrayList(Tok) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
        } else if (c == '/' and i + 1 < s.len and s[i + 1] == '/') {
            while (i < s.len and s[i] != '\n') i += 1;
        } else if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return error.BadIdl;
            i = end + 2;
        } else if (isIdentStart(c)) {
            const start = i;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '-')) i += 1;
            var t = s[start..i];
            // A leading `_` escapes a name that is a keyword.
            if (t.len > 1 and t[0] == '_') t = t[1..];
            try out.append(a, .{ .kind = .ident, .text = t });
        } else if (c == '"') {
            const end = std.mem.indexOfScalarPos(u8, s, i + 1, '"') orelse return error.BadIdl;
            try out.append(a, .{ .kind = .string, .text = s[i + 1 .. end] });
            i = end + 1;
        } else if (std.ascii.isDigit(c) or (c == '-' and i + 1 < s.len and (std.ascii.isDigit(s[i + 1]) or s[i + 1] == '.'))) {
            const start = i;
            i += 1;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '.')) i += 1;
            try out.append(a, .{ .kind = .number, .text = s[start..i] });
        } else if (c == '.' and std.mem.startsWith(u8, s[i..], "...")) {
            try out.append(a, .{ .kind = .punct, .text = "..." });
            i += 3;
        } else {
            try out.append(a, .{ .kind = .punct, .text = s[i .. i + 1] });
            i += 1;
        }
    }
    try out.append(a, .{ .kind = .eof, .text = "" });
    return out.items;
}

const Parser = struct {
    a: Allocator,
    toks: []Tok,
    at: usize = 0,
    group: ?[]const u8,
    ifaces: *std.ArrayList(Iface),
    dicts: *std.ArrayList(Dict),
    enums: *std.ArrayList(Enum),
    typedefs: *std.ArrayList(Typedef),
    includes: *std.ArrayList(Include),

    fn peek(p: *Parser) Tok {
        return p.toks[p.at];
    }

    fn next(p: *Parser) Tok {
        const t = p.toks[p.at];
        if (t.kind != .eof) p.at += 1;
        return t;
    }

    fn is(p: *Parser, text: []const u8) bool {
        const t = p.peek();
        return t.kind != .string and std.mem.eql(u8, t.text, text);
    }

    fn eat(p: *Parser, text: []const u8) bool {
        if (!p.is(text)) return false;
        p.at += 1;
        return true;
    }

    fn expect(p: *Parser, text: []const u8) Error!void {
        if (!p.eat(text)) return error.BadIdl;
    }

    fn ident(p: *Parser) Error![]const u8 {
        const t = p.next();
        if (t.kind != .ident) return error.BadIdl;
        return t.text;
    }

    /// Skips the extended attributes `[...]` in front of a definition, a
    /// member, an argument, or a type.
    fn skipExt(p: *Parser) Error!void {
        while (p.is("[")) try p.skipGroup("[", "]");
    }

    /// Skips a balanced group that starts at `open`.
    fn skipGroup(p: *Parser, open: []const u8, close: []const u8) Error!void {
        try p.expect(open);
        var depth: usize = 1;
        while (depth > 0) {
            const t = p.next();
            if (t.kind == .eof) return error.BadIdl;
            if (t.kind == .punct and std.mem.eql(u8, t.text, open)) depth += 1;
            if (t.kind == .punct and std.mem.eql(u8, t.text, close)) depth -= 1;
        }
    }

    /// Skips to the `;` at the end of a statement, over balanced groups.
    fn skipStatement(p: *Parser) Error!void {
        while (true) {
            if (p.is("{")) {
                try p.skipGroup("{", "}");
            } else if (p.is("(")) {
                try p.skipGroup("(", ")");
            } else if (p.is("[")) {
                try p.skipGroup("[", "]");
            } else {
                const t = p.next();
                if (t.kind == .eof) return error.BadIdl;
                if (t.kind == .punct and t.text[0] == ';') return;
            }
        }
    }

    /// Reads a type and gives its text in a normal form: one space
    /// between words, `<` and `>` with no spaces, `, ` between
    /// arguments, and ` or ` in a union.
    fn typeText(p: *Parser) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try p.typeInto(&out);
        return out.items;
    }

    fn typeInto(p: *Parser, out: *std.ArrayList(u8)) Error!void {
        try p.skipExt();
        if (p.eat("(")) {
            try out.append(p.a, '(');
            try p.typeInto(out);
            while (p.eat("or")) {
                try out.appendSlice(p.a, " or ");
                try p.typeInto(out);
            }
            try p.expect(")");
            try out.append(p.a, ')');
        } else {
            const first = try p.ident();
            try out.appendSlice(p.a, first);
            // The types of more than one word.
            if (std.mem.eql(u8, first, "unsigned") or std.mem.eql(u8, first, "unrestricted")) {
                try out.append(p.a, ' ');
                const w = try p.ident();
                try out.appendSlice(p.a, w);
                if (std.mem.eql(u8, w, "long") and p.eat("long")) try out.appendSlice(p.a, " long");
            } else if (std.mem.eql(u8, first, "long") and p.eat("long")) {
                try out.appendSlice(p.a, " long");
            }
            if (p.eat("<")) {
                try out.append(p.a, '<');
                try p.typeInto(out);
                while (p.eat(",")) {
                    try out.appendSlice(p.a, ", ");
                    try p.typeInto(out);
                }
                try p.expect(">");
                try out.append(p.a, '>');
            }
        }
        if (p.eat("?")) try out.append(p.a, '?');
    }

    /// Skips a default value after `=`.
    fn skipDefault(p: *Parser) Error!void {
        if (!p.eat("=")) return;
        if (p.is("{")) return p.skipGroup("{", "}");
        if (p.is("[")) return p.skipGroup("[", "]");
        _ = p.next();
    }

    fn args(p: *Parser) Error![]const Arg {
        try p.expect("(");
        var out: std.ArrayList(Arg) = .empty;
        while (!p.eat(")")) {
            try p.skipExt();
            const optional = p.eat("optional");
            const t = try p.typeText();
            const variadic = p.eat("...");
            const n = try p.ident();
            try p.skipDefault();
            try out.append(p.a, .{ .name = n, .type = t, .optional = optional, .variadic = variadic });
            if (!p.eat(",")) {
                try p.expect(")");
                break;
            }
        }
        return out.items;
    }

    fn iface(p: *Parser, name: []const u8) Error!*Iface {
        for (p.ifaces.items) |*i| if (std.mem.eql(u8, i.name, name)) return i;
        try p.ifaces.append(p.a, .{ .name = name });
        return &p.ifaces.items[p.ifaces.items.len - 1];
    }

    fn add(p: *Parser, i: *Iface, m: Member) Error!void {
        for (i.members.items) |o| if (o.op == m.op and std.mem.eql(u8, o.name, m.name)) return;
        try i.members.append(p.a, m);
    }

    fn op(p: *Parser, i: *Iface, name: []const u8, ret: []const u8, a: []const Arg) Error!void {
        try p.add(i, .{ .name = name, .type = ret, .op = true, .args = a, .group = p.group });
    }

    fn interfaceBody(p: *Parser, name: []const u8, partial: bool, mixin: bool) Error!void {
        const i = try p.iface(name);
        if (!partial) {
            i.group = p.group;
            i.mixin = mixin;
        }
        if (p.eat(":")) i.inherits = try p.ident();
        try p.expect("{");
        while (!p.eat("}")) {
            try p.skipExt();
            if (p.is("constructor") or p.is("const") or p.is("static") or p.is("stringifier") or p.is("iterable") or p.is("async")) {
                try p.skipStatement();
                continue;
            }
            const readonly = p.eat("readonly");
            _ = p.eat("inherit");
            if (p.eat("attribute")) {
                const t = try p.typeText();
                const n = try p.ident();
                try p.expect(";");
                try p.add(i, .{ .name = n, .type = t, .op = false, .readonly = readonly, .group = p.group });
                continue;
            }
            if (p.eat("maplike") or p.eat("setlike")) {
                const map = std.mem.eql(u8, p.toks[p.at - 1].text, "maplike");
                try p.expect("<");
                const k = try p.typeText();
                var v = k;
                if (map) {
                    try p.expect(",");
                    v = try p.typeText();
                }
                try p.expect(">");
                try p.expect(";");
                const key = try p.a.dupe(Arg, &.{.{ .name = "key", .type = k, .optional = false, .variadic = false }});
                try p.add(i, .{ .name = "size", .type = "unsigned long", .op = false, .readonly = true, .group = p.group });
                if (map) try p.op(i, "get", try std.fmt.allocPrint(p.a, "{s}?", .{v}), key);
                try p.op(i, "has", "boolean", key);
                if (map) try p.op(i, "keys", try std.fmt.allocPrint(p.a, "sequence<{s}>", .{k}), &.{});
                try p.op(i, "values", try std.fmt.allocPrint(p.a, "sequence<{s}>", .{v}), &.{});
                continue;
            }
            // `getter`, `setter`, and `deleter` with a name are operations.
            _ = p.eat("getter") or p.eat("setter") or p.eat("deleter");
            const ret = try p.typeText();
            if (p.is("(")) {
                try p.skipStatement();
                continue;
            }
            const n = try p.ident();
            const a = try p.args();
            try p.expect(";");
            try p.op(i, n, ret, a);
        }
        try p.expect(";");
    }

    fn dictionary(p: *Parser, name: []const u8) Error!void {
        var d: *Dict = blk: {
            for (p.dicts.items) |*d| if (std.mem.eql(u8, d.name, name)) break :blk d;
            try p.dicts.append(p.a, .{ .name = name });
            break :blk &p.dicts.items[p.dicts.items.len - 1];
        };
        if (p.eat(":")) d.inherits = try p.ident();
        try p.expect("{");
        while (!p.eat("}")) {
            try p.skipExt();
            const required = p.eat("required");
            const t = try p.typeText();
            const n = try p.ident();
            try p.skipDefault();
            try p.expect(";");
            try d.members.append(p.a, .{ .name = n, .type = t, .required = required });
        }
        try p.expect(";");
    }

    fn definition(p: *Parser) Error!void {
        try p.skipExt();
        if (p.eat("callback") or p.eat("namespace")) return p.skipStatement();
        const partial = p.eat("partial");
        if (p.eat("interface")) {
            const mixin = p.eat("mixin");
            return p.interfaceBody(try p.ident(), partial, mixin);
        }
        if (p.eat("dictionary")) return p.dictionary(try p.ident());
        if (p.eat("enum")) {
            var e: Enum = .{ .name = try p.ident() };
            try p.expect("{");
            while (!p.eat("}")) {
                const t = p.next();
                if (t.kind != .string) return error.BadIdl;
                try e.values.append(p.a, t.text);
                _ = p.eat(",");
            }
            try p.expect(";");
            return p.enums.append(p.a, e);
        }
        if (p.eat("typedef")) {
            const t = try p.typeText();
            const n = try p.ident();
            try p.expect(";");
            return p.typedefs.append(p.a, .{ .name = n, .type = t });
        }
        const target = try p.ident();
        try p.expect("includes");
        const mixin = try p.ident();
        try p.expect(";");
        try p.includes.append(p.a, .{ .target = target, .mixin = mixin });
    }
};

fn byName(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn f(_: void, x: T, y: T) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.f;
}

fn sameGroup(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

fn str(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Error!void {
    try out.append(a, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(a, '\\');
        try out.append(a, c);
    }
    try out.append(a, '"');
}

fn optStr(a: Allocator, out: *std.ArrayList(u8), s: ?[]const u8) Error!void {
    if (s) |v| return str(a, out, v);
    try out.appendSlice(a, "null");
}

const header =
    \\// The table of the Web IDL for the commands `web::` (src/wasmweb.zig).
    \\// tools/webidl writes this file from tools/webidl/idl/: run
    \\// `zig build webidl`, and do not edit it. Each file of the IDL has the
    \\// URL of its spec in its header.
    \\
    \\
;

/// Gives the text of `web/webidl-table.mjs` for the sources.
pub fn generate(a: Allocator, sources: []const Source) Error![]const u8 {
    var ifaces: std.ArrayList(Iface) = .empty;
    var dicts: std.ArrayList(Dict) = .empty;
    var enums: std.ArrayList(Enum) = .empty;
    var typedefs: std.ArrayList(Typedef) = .empty;
    var includes: std.ArrayList(Include) = .empty;
    for (sources) |s| {
        var p: Parser = .{ .a = a, .toks = try tokenize(a, s.text), .group = s.group, .ifaces = &ifaces, .dicts = &dicts, .enums = &enums, .typedefs = &typedefs, .includes = &includes };
        while (p.peek().kind != .eof) try p.definition();
    }
    for (includes.items) |inc| {
        var mix: ?*Iface = null;
        for (ifaces.items) |*i| {
            if (std.mem.eql(u8, i.name, inc.mixin)) mix = i;
        }
        const members = (mix orelse return error.BadIdl).members.items;
        for (ifaces.items) |*i| {
            if (!std.mem.eql(u8, i.name, inc.target)) continue;
            for (members) |mem| {
                var dup = false;
                for (i.members.items) |o| dup = dup or (o.op == mem.op and std.mem.eql(u8, o.name, mem.name));
                if (!dup) try i.members.append(a, mem);
            }
        }
    }
    std.mem.sort(Iface, ifaces.items, {}, byName(Iface));
    std.mem.sort(Dict, dicts.items, {}, byName(Dict));
    std.mem.sort(Enum, enums.items, {}, byName(Enum));
    std.mem.sort(Typedef, typedefs.items, {}, byName(Typedef));

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, header);
    try out.appendSlice(a, "export const interfaces = {\n");
    var first = true;
    for (ifaces.items) |i| {
        if (i.mixin) continue;
        if (!first) try out.appendSlice(a, ",\n");
        first = false;
        try out.appendSlice(a, "  ");
        try str(a, &out, i.name);
        try out.appendSlice(a, ": {\n    \"group\": ");
        try optStr(a, &out, i.group);
        try out.appendSlice(a, ",\n    \"inherits\": ");
        try optStr(a, &out, i.inherits);
        for ([_]bool{ false, true }) |want_op| {
            try out.appendSlice(a, if (want_op) ",\n    \"operations\": {" else ",\n    \"attributes\": {");
            var any = false;
            for (i.members.items) |m| {
                if (m.op != want_op) continue;
                try out.appendSlice(a, if (any) ",\n      " else "\n      ");
                any = true;
                try str(a, &out, m.name);
                if (want_op) {
                    try out.appendSlice(a, ": { \"args\": [");
                    for (m.args, 0..) |arg, k| {
                        if (k > 0) try out.appendSlice(a, ", ");
                        try out.appendSlice(a, "{ \"name\": ");
                        try str(a, &out, arg.name);
                        try out.appendSlice(a, ", \"type\": ");
                        try str(a, &out, arg.type);
                        if (arg.optional) try out.appendSlice(a, ", \"optional\": true");
                        if (arg.variadic) try out.appendSlice(a, ", \"variadic\": true");
                        try out.appendSlice(a, " }");
                    }
                    try out.appendSlice(a, "], \"returns\": ");
                    try str(a, &out, m.type);
                } else {
                    try out.appendSlice(a, ": { \"type\": ");
                    try str(a, &out, m.type);
                    if (m.readonly) try out.appendSlice(a, ", \"readonly\": true");
                }
                if (!sameGroup(m.group, i.group)) {
                    try out.appendSlice(a, ", \"group\": ");
                    try optStr(a, &out, m.group);
                }
                try out.appendSlice(a, " }");
            }
            try out.appendSlice(a, if (any) "\n    }" else "}");
        }
        try out.appendSlice(a, "\n  }");
    }
    try out.appendSlice(a, "\n};\n\nexport const dictionaries = {\n");
    for (dicts.items, 0..) |d, n| {
        if (n > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "  ");
        try str(a, &out, d.name);
        try out.appendSlice(a, ": {\n    \"inherits\": ");
        try optStr(a, &out, d.inherits);
        try out.appendSlice(a, ",\n    \"members\": {");
        for (d.members.items, 0..) |m, k| {
            try out.appendSlice(a, if (k > 0) ",\n      " else "\n      ");
            try str(a, &out, m.name);
            try out.appendSlice(a, ": { \"type\": ");
            try str(a, &out, m.type);
            if (m.required) try out.appendSlice(a, ", \"required\": true");
            try out.appendSlice(a, " }");
        }
        try out.appendSlice(a, if (d.members.items.len > 0) "\n    }\n  }" else "}\n  }");
    }
    try out.appendSlice(a, "\n};\n\nexport const enums = {\n");
    for (enums.items, 0..) |e, n| {
        if (n > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "  ");
        try str(a, &out, e.name);
        try out.appendSlice(a, ": [");
        for (e.values.items, 0..) |v, k| {
            if (k > 0) try out.appendSlice(a, ", ");
            try str(a, &out, v);
        }
        try out.append(a, ']');
    }
    try out.appendSlice(a, "\n};\n\nexport const typedefs = {\n");
    for (typedefs.items, 0..) |t, n| {
        if (n > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "  ");
        try str(a, &out, t.name);
        try out.appendSlice(a, ": ");
        try str(a, &out, t.type);
    }
    // The roots: `navigator`, `window`, and each attribute of
    // `Navigator` that has the type of an interface.
    try out.appendSlice(a, "\n};\n\n// The root objects of `web::root`: a path from the global object, and\n// the interface of the object.\nexport const roots = {\n  \"navigator\": \"Navigator\",\n  \"window\": \"Window\"");
    for (ifaces.items) |i| {
        if (!std.mem.eql(u8, i.name, "Navigator")) continue;
        for (i.members.items) |m| {
            if (m.op) continue;
            for (ifaces.items) |t| {
                if (!std.mem.eql(u8, t.name, m.type)) continue;
                try out.appendSlice(a, ",\n  ");
                try str(a, &out, try std.fmt.allocPrint(a, "navigator.{s}", .{m.name}));
                try out.appendSlice(a, ": ");
                try str(a, &out, m.type);
            }
        }
    }
    try out.appendSlice(a, "\n};\n");
    return out.items;
}

test "an interface, a partial interface, a mixin, and a dictionary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "interface Navigator {};";
    const idl =
        \\[Exposed=Window] partial interface Navigator { [SameObject] readonly attribute Serial serial; };
        \\/* a comment */ interface Serial : EventTarget {
        \\  attribute EventHandler onconnect; // a comment
        \\  Promise <sequence<SerialPort>> getPorts();
        \\  [Exposed=Window] Promise<SerialPort> requestPort(optional SerialPortRequestOptions options = {});
        \\  undefined send(sequence<octet> data, optional unrestricted double t = 0, long long... more);
        \\  constructor(DOMString type);
        \\  const unsigned short X = 1;
        \\  readonly maplike<DOMString, SerialPort>;
        \\};
        \\interface mixin M { attribute EventHandler onx; };
        \\Serial includes M;
        \\dictionary O : P { required [EnforceRange] unsigned long baudRate; (DOMString or long)? u = null; };
        \\enum E { "a", "b", };
        \\typedef (DOMString or unsigned long) U;
        \\callback F = undefined (long x);
    ;
    const out = try generate(a, &.{ .{ .group = null, .text = base }, .{ .group = "serial", .text = idl } });
    const want = [_][]const u8{
        "\"navigator.serial\": \"Serial\"",
        "\"serial\": { \"type\": \"Serial\", \"readonly\": true, \"group\": \"serial\" }",
        "\"getPorts\": { \"args\": [], \"returns\": \"Promise<sequence<SerialPort>>\" }",
        "{ \"name\": \"options\", \"type\": \"SerialPortRequestOptions\", \"optional\": true }",
        "{ \"name\": \"t\", \"type\": \"unrestricted double\", \"optional\": true }, { \"name\": \"more\", \"type\": \"long long\", \"variadic\": true }",
        "\"get\": { \"args\": [{ \"name\": \"key\", \"type\": \"DOMString\" }], \"returns\": \"SerialPort?\" }",
        "\"onx\": { \"type\": \"EventHandler\" }",
        "\"baudRate\": { \"type\": \"unsigned long\", \"required\": true }",
        "\"u\": { \"type\": \"(DOMString or long)?\" }",
        "\"E\": [\"a\", \"b\"]",
        "\"U\": \"(DOMString or unsigned long)\"",
    };
    for (want) |w| {
        if (std.mem.indexOf(u8, out, w) == null) {
            std.debug.print("missing: {s}\n{s}\n", .{ w, out });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "\"M\"") == null);
    try std.testing.expectError(error.BadIdl, generate(a, &.{.{ .group = "x", .text = "interface A {" }}));
}
