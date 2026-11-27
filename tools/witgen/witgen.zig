//! The bindings generator of WASI 0.3 (docs/dev/wasi-tasks/05-wit-bindings.md).
//!
//! The generator reads the WIT files of `wit/` and a list of the needed
//! functions, and writes `src/wasi/p3.zig`. It works in four passes:
//!
//! 1. A lexer splits each file into names, versions, and punctuation. It
//!    drops comments and the gates (`@since(...)`, `@unstable(...)`).
//! 2. A parser reads the packages, the interfaces, their `use` lines, the
//!    type definitions, the resources, and the functions. It skips the
//!    bodies of worlds. A file with no `package` line gets the package of
//!    the other files of its folder.
//! 3. For each needed function, the generator resolves each named type to
//!    its definition, also through `use`, and marks each definition that
//!    the function reaches.
//! 4. The writer gives one Zig struct for each interface: the marked types
//!    as `extern` types in the layout of the canonical ABI, and one struct
//!    for each function with its `extern` declaration. The parameters and
//!    the results follow the flattening of the canonical ABI. A synchronous
//!    import has at most 16 flat parameters and 1 flat result; past these,
//!    the parameters go in memory and the result goes to a return area. An
//!    `async func` uses the `[async-lower]` form: at most 4 flat
//!    parameters, the result always in a return area, and a status code as
//!    the core result. Each `stream<T>` and `future<T>` of a function gets
//!    the built-ins with the legacy names of docs/dev/wasi.md. The writer
//!    also computes the size and the alignment of each type from the rules
//!    of the canonical ABI, and writes a comptime check of each one against
//!    the Zig layout.
//!
//! The generator handles only the WIT types that WASI 0.3.2 uses. It gives
//! an error for a type that it does not know.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Source = struct {
    /// The folder of the file. The files of one folder are one package.
    dir: []const u8,
    path: []const u8,
    text: []const u8,
};

pub const Error = error{ Syntax, Unknown, OutOfMemory, WriteFailed };

// The lexer.

const Kind = enum { id, version, punct, arrow, eof };

const Tok = struct {
    kind: Kind,
    text: []const u8,
    /// The name had a `%` in front of it, so it is not a keyword.
    escaped: bool = false,
};

fn lex(a: Allocator, text: []const u8) Error![]Tok {
    var out: std.ArrayList(Tok) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < text.len) {
            if (std.ascii.isWhitespace(text[i])) {
                i += 1;
            } else if (std.mem.startsWith(u8, text[i..], "//")) {
                while (i < text.len and text[i] != '\n') i += 1;
            } else if (std.mem.startsWith(u8, text[i..], "/*")) {
                const end = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return error.Syntax;
                i = end + 2;
            } else break;
        }
        if (i >= text.len) break;
        const c = text[i];
        const start = i;
        if (c == '%' or std.ascii.isAlphabetic(c) or c == '_') {
            const escaped = c == '%';
            if (escaped) i += 1;
            const s = i;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-' or text[i] == '_')) i += 1;
            try out.append(a, .{ .kind = .id, .text = text[s..i], .escaped = escaped });
        } else if (std.ascii.isDigit(c)) {
            while (i < text.len) {
                const d = text[i];
                if (std.ascii.isAlphanumeric(d) or d == '-' or d == '+') {
                    i += 1;
                } else if (d == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1])) {
                    i += 1;
                } else break;
            }
            try out.append(a, .{ .kind = .version, .text = text[start..i] });
        } else if (c == '-' and i + 1 < text.len and text[i + 1] == '>') {
            i += 2;
            try out.append(a, .{ .kind = .arrow, .text = text[start..i] });
        } else {
            i += 1;
            try out.append(a, .{ .kind = .punct, .text = text[start..i] });
        }
    }
    try out.append(a, .{ .kind = .eof, .text = text[text.len..] });
    return out.items;
}

// The model.

const Prim = enum { bool, u8, s8, u16, s16, u32, s32, u64, s64, f32, f64, char };

const Type = union(enum) {
    prim: Prim,
    string,
    list: *const Type,
    option: *const Type,
    result: struct { ok: ?*const Type, err: ?*const Type },
    tuple: []const Type,
    /// `own<R>` or `borrow<R>`: a handle.
    handle: []const u8,
    stream: ?*const Type,
    future: ?*const Type,
    named: []const u8,
};

const Field = struct { name: []const u8, ty: Type };
const Case = struct { name: []const u8, ty: ?Type };

const Def = union(enum) {
    alias: Type,
    record: []const Field,
    variant: []const Case,
    @"enum": []const []const u8,
    flags: []const []const u8,
    resource,
};

const Func = struct {
    /// The name of the core import, such as `[method]descriptor.stat`.
    core: []const u8,
    /// The WIT text of the declaration, for the doc comment.
    wit: []const u8,
    params: []const Field,
    result: ?Type,
    is_async: bool,
};

const Use = struct { iface: []const u8, name: []const u8 };

const Iface = struct {
    /// The full name, such as `wasi:filesystem/types@0.3.2`.
    id: []const u8,
    /// The name in the Zig file, such as `filesystem_types`.
    zig: []const u8,
    defs: std.StringArrayHashMapUnmanaged(Def) = .empty,
    uses: std.StringHashMapUnmanaged(Use) = .empty,
    funcs: std.StringArrayHashMapUnmanaged(Func) = .empty,
};

const Pkg = struct { ns: []const u8, name: []const u8, version: ?[]const u8 };

// The parser.

const Parser = struct {
    a: Allocator,
    toks: []const Tok,
    pos: usize = 0,
    pkg: Pkg,
    ifaces: *std.StringArrayHashMapUnmanaged(*Iface),
    path: []const u8,

    fn peek(p: *Parser) Tok {
        return p.toks[p.pos];
    }

    fn next(p: *Parser) Tok {
        const t = p.toks[p.pos];
        if (t.kind != .eof) p.pos += 1;
        return t;
    }

    fn fail(p: *Parser, what: []const u8) Error {
        std.debug.print("{s}: {s} at \"{s}\"\n", .{ p.path, what, p.peek().text });
        return error.Syntax;
    }

    fn isPunct(p: *Parser, s: []const u8) bool {
        const t = p.peek();
        return t.kind == .punct and std.mem.eql(u8, t.text, s);
    }

    fn isWord(p: *Parser, s: []const u8) bool {
        const t = p.peek();
        return t.kind == .id and !t.escaped and std.mem.eql(u8, t.text, s);
    }

    fn expect(p: *Parser, s: []const u8) Error!void {
        if (!p.isPunct(s)) return p.fail("expected punctuation");
        _ = p.next();
    }

    fn name(p: *Parser) Error![]const u8 {
        const t = p.next();
        if (t.kind != .id) {
            p.pos -= 1;
            return p.fail("expected a name");
        }
        return t.text;
    }

    /// Skips the gates before an item: `@since(version = 0.3.0)`.
    fn gates(p: *Parser) Error!void {
        while (p.isPunct("@")) {
            _ = p.next();
            _ = try p.name();
            if (p.isPunct("(")) try p.skipGroup("(", ")");
        }
    }

    fn skipGroup(p: *Parser, open: []const u8, close: []const u8) Error!void {
        try p.expect(open);
        var depth: usize = 1;
        while (depth > 0) {
            const t = p.next();
            if (t.kind == .eof) return p.fail("unclosed group");
            if (t.kind == .punct and std.mem.eql(u8, t.text, open)) depth += 1;
            if (t.kind == .punct and std.mem.eql(u8, t.text, close)) depth -= 1;
        }
    }

    fn ifaceId(p: *Parser, pkg: Pkg, iface: []const u8) Error![]const u8 {
        if (pkg.version) |v| return std.fmt.allocPrint(p.a, "{s}:{s}/{s}@{s}", .{ pkg.ns, pkg.name, iface, v });
        return std.fmt.allocPrint(p.a, "{s}:{s}/{s}", .{ pkg.ns, pkg.name, iface });
    }

    fn file(p: *Parser) Error!void {
        while (p.peek().kind != .eof) {
            try p.gates();
            if (p.isWord("package")) {
                while (!p.isPunct(";")) _ = p.next();
                _ = p.next();
            } else if (p.isWord("interface")) {
                _ = p.next();
                try p.interface(try p.name());
            } else if (p.isWord("world")) {
                _ = p.next();
                _ = try p.name();
                try p.skipGroup("{", "}");
            } else if (p.isWord("use")) {
                while (!p.isPunct(";")) _ = p.next();
                _ = p.next();
            } else return p.fail("unknown item");
        }
    }

    fn interface(p: *Parser, iname: []const u8) Error!void {
        const id = try p.ifaceId(p.pkg, iname);
        const gop = try p.ifaces.getOrPut(p.a, id);
        if (gop.found_existing) return p.fail("interface defined twice");
        const it = try p.a.create(Iface);
        it.* = .{ .id = id, .zig = try snake(p.a, try std.fmt.allocPrint(p.a, "{s}-{s}", .{ p.pkg.name, iname })) };
        gop.value_ptr.* = it;
        try p.expect("{");
        while (!p.isPunct("}")) {
            try p.gates();
            if (p.isWord("use")) {
                _ = p.next();
                try p.useLine(it);
            } else if (p.isWord("type")) {
                _ = p.next();
                const n = try p.name();
                try p.expect("=");
                const t = try p.ty();
                try p.expect(";");
                try it.defs.put(p.a, n, .{ .alias = t });
            } else if (p.isWord("record")) {
                _ = p.next();
                const n = try p.name();
                try it.defs.put(p.a, n, .{ .record = try p.fields("{", "}") });
            } else if (p.isWord("variant")) {
                _ = p.next();
                const n = try p.name();
                try it.defs.put(p.a, n, .{ .variant = try p.cases() });
            } else if (p.isWord("enum")) {
                _ = p.next();
                const n = try p.name();
                try it.defs.put(p.a, n, .{ .@"enum" = try p.names() });
            } else if (p.isWord("flags")) {
                _ = p.next();
                const n = try p.name();
                try it.defs.put(p.a, n, .{ .flags = try p.names() });
            } else if (p.isWord("resource")) {
                _ = p.next();
                try p.resource(it);
            } else {
                const start = p.peek().text;
                const n = try p.name();
                try p.expect(":");
                try p.func(it, n, n, null, start);
            }
        }
        _ = p.next();
    }

    fn useLine(p: *Parser, it: *Iface) Error!void {
        const first = try p.name();
        var target: []const u8 = undefined;
        if (p.isPunct(":")) {
            _ = p.next();
            const pkg = try p.name();
            try p.expect("/");
            const iname = try p.name();
            var version: ?[]const u8 = null;
            if (p.isPunct("@")) {
                _ = p.next();
                const v = p.next();
                if (v.kind != .version) return p.fail("expected a version");
                version = v.text;
            }
            target = try p.ifaceId(.{ .ns = first, .name = pkg, .version = version }, iname);
        } else target = try p.ifaceId(p.pkg, first);
        try p.expect(".");
        try p.expect("{");
        while (!p.isPunct("}")) {
            const n = try p.name();
            var local = n;
            if (p.isWord("as")) {
                _ = p.next();
                local = try p.name();
            }
            try it.uses.put(p.a, local, .{ .iface = target, .name = n });
            if (p.isPunct(",")) _ = p.next();
        }
        _ = p.next();
        try p.expect(";");
    }

    fn resource(p: *Parser, it: *Iface) Error!void {
        const r = try p.name();
        try it.defs.put(p.a, r, .resource);
        if (p.isPunct(";")) {
            _ = p.next();
            return;
        }
        try p.expect("{");
        while (!p.isPunct("}")) {
            try p.gates();
            const start = p.peek().text;
            if (p.isWord("constructor")) {
                _ = p.next();
                const params = try p.fields("(", ")");
                var result: Type = .{ .handle = r };
                if (p.peek().kind == .arrow) {
                    _ = p.next();
                    result = try p.ty();
                }
                try p.expect(";");
                const core = try std.fmt.allocPrint(p.a, "[constructor]{s}", .{r});
                try it.funcs.put(p.a, core, .{ .core = core, .wit = try p.span(start), .params = params, .result = result, .is_async = false });
                continue;
            }
            const n = try p.name();
            try p.expect(":");
            var static = false;
            if (p.isWord("static")) {
                _ = p.next();
                static = true;
            }
            const core = try std.fmt.allocPrint(p.a, "[{s}]{s}.{s}", .{ if (static) "static" else "method", r, n });
            try p.func(it, core, n, if (static) null else r, start);
        }
        _ = p.next();
    }

    /// The source text from `start` to the last token, with each run of
    /// white space as one space.
    fn span(p: *Parser, start: []const u8) Error![]const u8 {
        const last = p.toks[p.pos - 1].text;
        const raw = start.ptr[0 .. @intFromPtr(last.ptr) + last.len - @intFromPtr(start.ptr)];
        var out: std.ArrayList(u8) = .empty;
        var space = false;
        for (raw) |c| {
            if (std.ascii.isWhitespace(c)) {
                space = true;
                continue;
            }
            if (space and out.items.len > 0 and c != ')' and c != ',' and out.items[out.items.len - 1] != '(') try out.append(p.a, ' ');
            space = false;
            try out.append(p.a, c);
        }
        return out.items;
    }

    fn func(p: *Parser, it: *Iface, core: []const u8, _: []const u8, self: ?[]const u8, start: []const u8) Error!void {
        var is_async = false;
        if (p.isWord("async")) {
            _ = p.next();
            is_async = true;
        }
        if (!p.isWord("func")) return p.fail("expected func");
        _ = p.next();
        var params = try p.fields("(", ")");
        if (self) |r| {
            const all = try p.a.alloc(Field, params.len + 1);
            all[0] = .{ .name = "self", .ty = .{ .handle = r } };
            @memcpy(all[1..], params);
            params = all;
        }
        var result: ?Type = null;
        if (p.peek().kind == .arrow) {
            _ = p.next();
            result = try p.ty();
        }
        try p.expect(";");
        try it.funcs.put(p.a, core, .{ .core = core, .wit = try p.span(start), .params = params, .result = result, .is_async = is_async });
    }

    fn fields(p: *Parser, open: []const u8, close: []const u8) Error![]const Field {
        try p.expect(open);
        var out: std.ArrayList(Field) = .empty;
        while (true) {
            try p.gates();
            if (p.isPunct(close)) break;
            const n = try p.name();
            try p.expect(":");
            try out.append(p.a, .{ .name = n, .ty = try p.ty() });
            if (p.isPunct(",")) _ = p.next();
        }
        _ = p.next();
        return out.items;
    }

    fn cases(p: *Parser) Error![]const Case {
        try p.expect("{");
        var out: std.ArrayList(Case) = .empty;
        while (true) {
            try p.gates();
            if (p.isPunct("}")) break;
            const n = try p.name();
            var t: ?Type = null;
            if (p.isPunct("(")) {
                _ = p.next();
                t = try p.ty();
                try p.expect(")");
            }
            try out.append(p.a, .{ .name = n, .ty = t });
            if (p.isPunct(",")) _ = p.next();
        }
        _ = p.next();
        return out.items;
    }

    fn names(p: *Parser) Error![]const []const u8 {
        try p.expect("{");
        var out: std.ArrayList([]const u8) = .empty;
        while (true) {
            try p.gates();
            if (p.isPunct("}")) break;
            try out.append(p.a, try p.name());
            if (p.isPunct(",")) _ = p.next();
        }
        _ = p.next();
        return out.items;
    }

    fn boxed(p: *Parser, t: Type) Error!*const Type {
        const b = try p.a.create(Type);
        b.* = t;
        return b;
    }

    /// An optional type in angle brackets: `stream<u8>` or `stream`.
    fn optArg(p: *Parser) Error!?*const Type {
        if (!p.isPunct("<")) return null;
        _ = p.next();
        const t = try p.boxed(try p.ty());
        try p.expect(">");
        return t;
    }

    fn ty(p: *Parser) Error!Type {
        const t = p.next();
        if (t.kind != .id) {
            p.pos -= 1;
            return p.fail("expected a type");
        }
        if (t.escaped) return .{ .named = t.text };
        const w = t.text;
        if (std.meta.stringToEnum(Prim, w)) |prim| return .{ .prim = prim };
        if (std.mem.eql(u8, w, "string")) return .string;
        if (std.mem.eql(u8, w, "list")) {
            try p.expect("<");
            const e = try p.boxed(try p.ty());
            if (p.isPunct(",")) return p.fail("fixed-size lists are not supported");
            try p.expect(">");
            return .{ .list = e };
        }
        if (std.mem.eql(u8, w, "option")) {
            try p.expect("<");
            const e = try p.boxed(try p.ty());
            try p.expect(">");
            return .{ .option = e };
        }
        if (std.mem.eql(u8, w, "result")) {
            if (!p.isPunct("<")) return .{ .result = .{ .ok = null, .err = null } };
            _ = p.next();
            var ok: ?*const Type = null;
            if (p.isWord("_")) {
                _ = p.next();
            } else ok = try p.boxed(try p.ty());
            var err: ?*const Type = null;
            if (p.isPunct(",")) {
                _ = p.next();
                err = try p.boxed(try p.ty());
            }
            try p.expect(">");
            return .{ .result = .{ .ok = ok, .err = err } };
        }
        if (std.mem.eql(u8, w, "tuple")) {
            try p.expect("<");
            var out: std.ArrayList(Type) = .empty;
            while (!p.isPunct(">")) {
                try out.append(p.a, try p.ty());
                if (p.isPunct(",")) _ = p.next();
            }
            _ = p.next();
            return .{ .tuple = out.items };
        }
        if (std.mem.eql(u8, w, "own") or std.mem.eql(u8, w, "borrow")) {
            try p.expect("<");
            const r = try p.name();
            try p.expect(">");
            return .{ .handle = r };
        }
        if (std.mem.eql(u8, w, "stream")) return .{ .stream = try p.optArg() };
        if (std.mem.eql(u8, w, "future")) return .{ .future = try p.optArg() };
        if (std.mem.eql(u8, w, "map")) return p.fail("map is not supported");
        return .{ .named = w };
    }
};

// The canonical ABI.

const Core = enum {
    i32,
    i64,
    f32,
    f64,

    fn zig(c: Core) []const u8 {
        return switch (c) {
            .i32 => "u32",
            .i64 => "u64",
            .f32 => "f32",
            .f64 => "f64",
        };
    }
};

const Layout = struct { size: u32, alignment: u32 };

/// A named type, resolved to the interface that defines it.
const Ref = struct { iface: *Iface, name: []const u8 };

const max_flat_params = 16;
const max_flat_results = 1;
const max_flat_async_params = 4;

fn alignTo(x: u32, a: u32) u32 {
    return (x + a - 1) / a * a;
}

fn discSize(n: usize) u32 {
    if (n <= 1 << 8) return 1;
    if (n <= 1 << 16) return 2;
    return 4;
}

fn flagsSize(n: usize) Error!u32 {
    if (n <= 8) return 1;
    if (n <= 16) return 2;
    if (n <= 32) return 4;
    return error.Unknown;
}

pub const Gen = struct {
    a: Allocator,
    ifaces: std.StringArrayHashMapUnmanaged(*Iface) = .empty,
    /// The definitions that the needed functions reach, by interface.
    marked: std.AutoArrayHashMapUnmanaged(*Iface, std.StringArrayHashMapUnmanaged(void)) = .empty,

    pub fn parse(g: *Gen, sources: []const Source) Error!void {
        // The package of each folder comes from its `package` lines.
        var pkgs: std.StringHashMapUnmanaged(Pkg) = .empty;
        for (sources) |s| {
            const toks = try lex(g.a, s.text);
            var i: usize = 0;
            while (i + 3 < toks.len) : (i += 1) {
                if (toks[i].kind == .id and std.mem.eql(u8, toks[i].text, "package") and !toks[i].escaped) {
                    var pkg: Pkg = .{ .ns = toks[i + 1].text, .name = toks[i + 3].text, .version = null };
                    if (i + 5 < toks.len and std.mem.eql(u8, toks[i + 4].text, "@")) pkg.version = toks[i + 5].text;
                    try pkgs.put(g.a, s.dir, pkg);
                    break;
                }
            }
        }
        for (sources) |s| {
            const pkg = pkgs.get(s.dir) orelse {
                std.debug.print("{s}: no package line in its folder\n", .{s.path});
                return error.Syntax;
            };
            var p: Parser = .{ .a = g.a, .toks = try lex(g.a, s.text), .pkg = pkg, .ifaces = &g.ifaces, .path = s.path };
            try p.file();
        }
    }

    fn resolve(g: *Gen, it: *Iface, n: []const u8) Error!Ref {
        if (it.defs.contains(n)) return .{ .iface = it, .name = n };
        if (it.uses.get(n)) |u| {
            const target = g.ifaces.get(u.iface) orelse {
                std.debug.print("{s}: no interface {s}\n", .{ it.id, u.iface });
                return error.Unknown;
            };
            return g.resolve(target, u.name);
        }
        std.debug.print("{s}: no type {s}\n", .{ it.id, n });
        return error.Unknown;
    }

    fn def(_: *Gen, r: Ref) Def {
        return r.iface.defs.get(r.name).?;
    }

    fn mark(g: *Gen, it: *Iface, t: Type) Error!void {
        switch (t) {
            .prim, .string => {},
            .list, .option => |e| try g.mark(it, e.*),
            .stream, .future => |e| if (e) |x| try g.mark(it, x.*),
            .result => |r| {
                if (r.ok) |x| try g.mark(it, x.*);
                if (r.err) |x| try g.mark(it, x.*);
            },
            .tuple => |ts| for (ts) |x| try g.mark(it, x),
            .handle, .named => |n| {
                const r = try g.resolve(it, n);
                const gop = try g.marked.getOrPut(g.a, r.iface);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                if (gop.value_ptr.contains(r.name)) return;
                try gop.value_ptr.put(g.a, r.name, {});
                switch (g.def(r)) {
                    .alias => |x| try g.mark(r.iface, x),
                    .record => |fs| for (fs) |f| try g.mark(r.iface, f.ty),
                    .variant => |cs| for (cs) |c| if (c.ty) |x| try g.mark(r.iface, x),
                    .@"enum", .flags, .resource => {},
                }
            },
        }
    }

    fn layout(g: *Gen, it: *Iface, t: Type) Error!Layout {
        return switch (t) {
            .prim => |p| switch (p) {
                .bool, .u8, .s8 => .{ .size = 1, .alignment = 1 },
                .u16, .s16 => .{ .size = 2, .alignment = 2 },
                .u32, .s32, .f32, .char => .{ .size = 4, .alignment = 4 },
                .u64, .s64, .f64 => .{ .size = 8, .alignment = 8 },
            },
            .string, .list => .{ .size = 8, .alignment = 4 },
            .handle, .stream, .future => .{ .size = 4, .alignment = 4 },
            .option => |e| g.variantLayout(it, &.{ null, e.* }),
            .result => |r| g.variantLayout(it, &.{ if (r.ok) |x| x.* else null, if (r.err) |x| x.* else null }),
            .tuple => |ts| g.recordLayout(it, ts),
            .named => |n| {
                const r = try g.resolve(it, n);
                return switch (g.def(r)) {
                    .alias => |x| g.layout(r.iface, x),
                    .record => |fs| blk: {
                        const ts = try g.a.alloc(Type, fs.len);
                        for (fs, ts) |f, *x| x.* = f.ty;
                        break :blk g.recordLayout(r.iface, ts);
                    },
                    .variant => |cs| blk: {
                        const ts = try g.a.alloc(?Type, cs.len);
                        for (cs, ts) |c, *x| x.* = c.ty;
                        break :blk g.variantLayout(r.iface, ts);
                    },
                    .@"enum" => |ns| .{ .size = discSize(ns.len), .alignment = discSize(ns.len) },
                    .flags => |ns| blk: {
                        const s = try flagsSize(ns.len);
                        break :blk .{ .size = s, .alignment = s };
                    },
                    .resource => .{ .size = 4, .alignment = 4 },
                };
            },
        };
    }

    fn recordLayout(g: *Gen, it: *Iface, ts: []const Type) Error!Layout {
        var off: u32 = 0;
        var al: u32 = 1;
        for (ts) |t| {
            const l = try g.layout(it, t);
            off = alignTo(off, l.alignment) + l.size;
            al = @max(al, l.alignment);
        }
        return .{ .size = alignTo(off, al), .alignment = al };
    }

    fn variantLayout(g: *Gen, it: *Iface, cs: []const ?Type) Error!Layout {
        const d = discSize(cs.len);
        var size: u32 = 0;
        var al: u32 = 1;
        for (cs) |c| if (c) |t| {
            const l = try g.layout(it, t);
            size = @max(size, l.size);
            al = @max(al, l.alignment);
        };
        const total = @max(d, al);
        return .{ .size = alignTo(alignTo(d, al) + size, total), .alignment = total };
    }

    fn flatten(g: *Gen, it: *Iface, t: Type, out: *std.ArrayList(Core)) Error!void {
        switch (t) {
            .prim => |p| try out.append(g.a, switch (p) {
                .u64, .s64 => .i64,
                .f32 => .f32,
                .f64 => .f64,
                else => .i32,
            }),
            .string, .list => try out.appendSlice(g.a, &.{ .i32, .i32 }),
            .handle, .stream, .future => try out.append(g.a, .i32),
            .option => |e| try g.flattenVariant(it, &.{ null, e.* }, out),
            .result => |r| try g.flattenVariant(it, &.{ if (r.ok) |x| x.* else null, if (r.err) |x| x.* else null }, out),
            .tuple => |ts| for (ts) |x| try g.flatten(it, x, out),
            .named => |n| {
                const r = try g.resolve(it, n);
                switch (g.def(r)) {
                    .alias => |x| try g.flatten(r.iface, x, out),
                    .record => |fs| for (fs) |f| try g.flatten(r.iface, f.ty, out),
                    .variant => |cs| {
                        const ts = try g.a.alloc(?Type, cs.len);
                        for (cs, ts) |c, *x| x.* = c.ty;
                        try g.flattenVariant(r.iface, ts, out);
                    },
                    .@"enum", .resource => try out.append(g.a, .i32),
                    .flags => |ns| {
                        _ = try flagsSize(ns.len);
                        try out.append(g.a, .i32);
                    },
                }
            },
        }
    }

    fn flattenVariant(g: *Gen, it: *Iface, cs: []const ?Type, out: *std.ArrayList(Core)) Error!void {
        try out.append(g.a, .i32);
        var joined: std.ArrayList(Core) = .empty;
        for (cs) |c| if (c) |t| {
            var one: std.ArrayList(Core) = .empty;
            try g.flatten(it, t, &one);
            for (one.items, 0..) |x, i| {
                if (i < joined.items.len) {
                    const y = joined.items[i];
                    joined.items[i] = if (x == y) x else if ((x == .i32 and y == .f32) or (x == .f32 and y == .i32)) .i32 else .i64;
                } else try joined.append(g.a, x);
            }
        };
        try out.appendSlice(g.a, joined.items);
    }

    /// The streams and the futures of a function, in the order of the
    /// built-ins: the parameters and then the result, the inner type of a
    /// stream or a future before it.
    fn streams(g: *Gen, it: *Iface, t: Type, out: *std.ArrayList(Type), seen: *std.ArrayList([]const u8)) Error!void {
        switch (t) {
            .prim, .string, .handle => {},
            .list, .option => |e| try g.streams(it, e.*, out, seen),
            .stream, .future => |e| {
                if (e) |x| try g.streams(it, x.*, out, seen);
                try out.append(g.a, t);
            },
            .result => |r| {
                if (r.ok) |x| try g.streams(it, x.*, out, seen);
                if (r.err) |x| try g.streams(it, x.*, out, seen);
            },
            .tuple => |ts| for (ts) |x| try g.streams(it, x, out, seen),
            .named => |n| {
                const r = try g.resolve(it, n);
                switch (g.def(r)) {
                    .alias => |x| try g.streams(r.iface, x, out, seen),
                    .record => |fs| for (fs) |f| try g.streams(r.iface, f.ty, out, seen),
                    .variant => |cs| for (cs) |c| if (c.ty) |x| try g.streams(r.iface, x, out, seen),
                    .@"enum", .flags, .resource => {},
                }
            },
        }
    }

    /// The Zig expression of a type, as seen from the struct of `from`.
    fn zigType(g: *Gen, w: *Writer, from: *Iface, it: *Iface, t: Type) Error!void {
        switch (t) {
            .prim => |p| try w.writeAll(switch (p) {
                .bool => "bool",
                .u8 => "u8",
                .s8 => "i8",
                .u16 => "u16",
                .s16 => "i16",
                .u32, .char => "u32",
                .s32 => "i32",
                .u64 => "u64",
                .s64 => "i64",
                .f32 => "f32",
                .f64 => "f64",
            }),
            .string => try w.writeAll("String"),
            .handle, .stream, .future => try w.writeAll("u32"),
            .list => |e| {
                try w.writeAll("List(");
                try g.zigType(w, from, it, e.*);
                try w.writeAll(")");
            },
            .option => |e| {
                try w.writeAll("Option(");
                try g.zigType(w, from, it, e.*);
                try w.writeAll(")");
            },
            .result => |r| {
                try w.writeAll("Result(");
                if (r.ok) |x| try g.zigType(w, from, it, x.*) else try w.writeAll("void");
                try w.writeAll(", ");
                if (r.err) |x| try g.zigType(w, from, it, x.*) else try w.writeAll("void");
                try w.writeAll(")");
            },
            .tuple => |ts| {
                try w.writeAll("extern struct { ");
                for (ts, 0..) |x, i| {
                    try w.print("@\"{d}\": ", .{i});
                    try g.zigType(w, from, it, x);
                    try w.writeAll(if (i + 1 < ts.len) ", " else " ");
                }
                try w.writeAll("}");
            },
            .named => |n| {
                const r = try g.resolve(it, n);
                if (r.iface != from) try w.print("{s}.", .{r.iface.zig});
                try w.print("{f}", .{std.zig.fmtId(try camel(g.a, r.name))});
            },
        }
    }

    fn typeText(g: *Gen, from: *Iface, it: *Iface, t: Type) Error![]const u8 {
        var aw: Writer.Allocating = .init(g.a);
        try g.zigType(&aw.writer, from, it, t);
        return aw.written();
    }

    /// Writes the bindings of the needed functions. Each line of `needed`
    /// is an interface and the name of a core import:
    /// `wasi:filesystem/types@0.3.2 [method]descriptor.stat`.
    pub fn write(g: *Gen, w: *Writer, needed: []const u8) Error!void {
        var want: std.AutoArrayHashMapUnmanaged(*Iface, std.ArrayList([]const u8)) = .empty;
        var lines = std.mem.tokenizeScalar(u8, needed, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var parts = std.mem.tokenizeAny(u8, line, " \t");
            const iid = parts.next().?;
            const fname = parts.next() orelse {
                std.debug.print("needed: no function in \"{s}\"\n", .{line});
                return error.Syntax;
            };
            const it = g.ifaces.get(iid) orelse {
                std.debug.print("needed: no interface {s}\n", .{iid});
                return error.Unknown;
            };
            if (std.mem.startsWith(u8, fname, "[resource-drop]")) {
                try g.mark(it, .{ .handle = fname["[resource-drop]".len..] });
            } else {
                const f = it.funcs.get(fname) orelse {
                    std.debug.print("needed: no function {s} in {s}\n", .{ fname, iid });
                    return error.Unknown;
                };
                for (f.params) |p| try g.mark(it, p.ty);
                if (f.result) |r| try g.mark(it, r);
            }
            const gop = try want.getOrPut(g.a, it);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(g.a, fname);
        }

        try w.writeAll(header);
        // The interfaces in the order of their names.
        var all: std.ArrayList(*Iface) = .empty;
        for (g.ifaces.values()) |it| if (want.contains(it) or g.marked.contains(it)) try all.append(g.a, it);
        std.mem.sort(*Iface, all.items, {}, struct {
            fn lt(_: void, x: *Iface, y: *Iface) bool {
                return std.mem.lessThan(u8, x.id, y.id);
            }
        }.lt);
        for (all.items) |it| {
            try w.print("\n/// The interface `{s}`.\npub const {s} = struct {{\n", .{ it.id, it.zig });
            try w.print("    const module = \"{s}\";\n", .{it.id});
            var checks: std.ArrayList(u8) = .empty;
            if (g.marked.get(it)) |set| {
                // The definitions in the order of the WIT file.
                for (it.defs.keys()) |n| if (set.contains(n)) try g.writeDef(w, it, n, &checks);
            }
            if (want.get(it)) |fs| for (fs.items) |f| try g.writeFunc(w, it, f);
            if (checks.items.len > 0) try w.print("\n    comptime {{\n{s}    }}\n", .{checks.items});
            try w.writeAll("};\n");
        }
    }

    fn writeDef(g: *Gen, w: *Writer, it: *Iface, n: []const u8, checks: *std.ArrayList(u8)) Error!void {
        const zn = try camel(g.a, n);
        const id = std.zig.fmtId(zn);
        const d = it.defs.get(n).?;
        try w.writeAll("\n");
        switch (d) {
            .alias => |t| try w.print("    pub const {f} = {s};\n", .{ id, try g.typeText(it, it, t) }),
            .resource => {
                try w.print("    /// A handle of the resource `{s}`.\n    pub const {f} = u32;\n", .{ n, id });
            },
            .record => |fs| {
                try w.print("    pub const {f} = extern struct {{\n", .{id});
                for (fs) |f| try w.print("        {f}: {s},\n", .{ fieldId(try snake(g.a, f.name)), try g.typeText(it, it, f.ty) });
                try w.writeAll("    };\n");
            },
            .@"enum" => |ns| try g.writeEnum(w, "    ", id, ns),
            .flags => |ns| {
                const bits = 8 * try flagsSize(ns.len);
                try w.print("    pub const {f} = packed struct(u{d}) {{\n", .{ id, bits });
                for (ns) |f| try w.print("        {f}: bool = false,\n", .{fieldId(try snake(g.a, f))});
                if (ns.len < bits) try w.print("        _: u{d} = 0,\n", .{bits - ns.len});
                try w.writeAll("    };\n");
            },
            .variant => |cs| {
                var payload = false;
                for (cs) |c| payload = payload or c.ty != null;
                const names = try g.a.alloc([]const u8, cs.len);
                for (cs, names) |c, *x| x.* = c.name;
                if (!payload) {
                    try g.writeEnum(w, "    ", id, names);
                } else {
                    try w.print("    pub const {f} = extern struct {{\n        tag: Tag,\n        payload: extern union {{\n", .{id});
                    for (cs) |c| if (c.ty) |t| try w.print("            {f}: {s},\n", .{ fieldId(try snake(g.a, c.name)), try g.typeText(it, it, t) });
                    try w.writeAll("        },\n\n");
                    try g.writeEnum(w, "        ", std.zig.fmtId("Tag"), names);
                    try w.writeAll("    };\n");
                }
            },
        }
        const l = try g.layout(it, .{ .named = n });
        try checks.print(g.a, "        check({f}, {d}, {d});\n", .{ id, l.size, l.alignment });
    }

    fn writeEnum(g: *Gen, w: *Writer, indent: []const u8, id: std.zig.FormatId, ns: []const []const u8) Error!void {
        try w.print("{s}pub const {f} = enum(u{d}) {{\n", .{ indent, id, 8 * discSize(ns.len) });
        for (ns) |n| try w.print("{s}    {f},\n", .{ indent, fieldId(try snake(g.a, n)) });
        try w.print("{s}}};\n", .{indent});
    }

    fn writeFunc(g: *Gen, w: *Writer, it: *Iface, core: []const u8) Error!void {
        if (std.mem.startsWith(u8, core, "[resource-drop]")) {
            const r = core["[resource-drop]".len..];
            try w.print("\n    /// Drops a handle of `{s}`.\n", .{r});
            try writeExtern(w, "    ", try std.fmt.allocPrint(g.a, "drop_{s}", .{try snake(g.a, r)}), it.id, core, "(handle: u32) void");
            return;
        }
        const f = it.funcs.get(core).?;
        // The struct name: the WIT name with the resource in front.
        var wit_name = core;
        if (std.mem.indexOfScalar(u8, core, ']')) |i| wit_name = core[i + 1 ..];
        const sname = try snake(g.a, wit_name);
        try w.print("\n    /// `{s}`\n    pub const {f} = struct {{\n", .{ f.wit, std.zig.fmtId(sname) });
        var checks: std.ArrayList(u8) = .empty;

        var flat: std.ArrayList(Core) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for (f.params) |p| {
            const start = flat.items.len;
            try g.flatten(it, p.ty, &flat);
            const k = flat.items.len - start;
            const base = try snake(g.a, p.name);
            for (0..k) |i| try names.append(g.a, if (k == 1) base else try std.fmt.allocPrint(g.a, "{s}_{d}", .{ base, i }));
        }
        var rflat: std.ArrayList(Core) = .empty;
        if (f.result) |r| try g.flatten(it, r, &rflat);

        const max_params: usize = if (f.is_async) max_flat_async_params else max_flat_params;
        const spill = flat.items.len > max_params;
        const ret_area = f.result != null and (f.is_async or rflat.items.len > max_flat_results);
        if (spill) {
            try w.writeAll("        /// The parameters in memory.\n        pub const Params = extern struct {\n");
            const ts = try g.a.alloc(Type, f.params.len);
            for (f.params, ts) |p, *x| {
                x.* = p.ty;
                try w.print("            {f}: {s},\n", .{ fieldId(try snake(g.a, p.name)), try g.typeText(it, it, p.ty) });
            }
            try w.writeAll("        };\n");
            const l = try g.recordLayout(it, ts);
            try checks.print(g.a, "            check(Params, {d}, {d});\n", .{ l.size, l.alignment });
        }
        if (ret_area) {
            const t = f.result.?;
            try w.print("        /// The return area.\n        pub const Ret = {s};\n", .{try g.typeText(it, it, t)});
            const l = try g.layout(it, t);
            try checks.print(g.a, "            check(Ret, {d}, {d});\n", .{ l.size, l.alignment });
        }

        const import = try std.fmt.allocPrint(g.a, "{s}{s}", .{ if (f.is_async) "[async-lower]" else "", core });
        var sig: Writer.Allocating = .init(g.a);
        const sw = &sig.writer;
        try sw.writeAll("(");
        var first = true;
        if (spill) {
            try sw.writeAll("params: u32");
            first = false;
        } else for (flat.items, names.items) |c, n| {
            if (!first) try sw.writeAll(", ");
            first = false;
            try sw.print("{f}: {s}", .{ std.zig.fmtId(n), c.zig() });
        }
        if (ret_area) try sw.print("{s}ret: u32", .{if (first) "" else ", "});
        const rtype = if (f.is_async) "u32" else if (ret_area or rflat.items.len == 0) "void" else rflat.items[0].zig();
        try sw.print(") {s}", .{rtype});
        try writeExtern(w, "        ", "call", it.id, import, sig.written());

        // The built-ins of the streams and the futures of the function.
        var sts: std.ArrayList(Type) = .empty;
        var seen: std.ArrayList([]const u8) = .empty;
        for (f.params) |p| try g.streams(it, p.ty, &sts, &seen);
        if (f.result) |r| try g.streams(it, r, &sts, &seen);
        for (sts.items, 0..) |st, i| {
            const is_stream = st == .stream;
            const kind = if (is_stream) "stream" else "future";
            const elem = if (is_stream) st.stream else st.future;
            try w.print("\n        /// The built-ins of `{s}` {d} of this function.\n        pub const {s}{d} = struct {{\n", .{ kind, i, kind, i });
            if (elem) |e| {
                try w.print("            pub const Elem = {s};\n", .{try g.typeText(it, it, e.*)});
                const l = try g.layout(it, e.*);
                try checks.print(g.a, "            check({s}{d}.Elem, {d}, {d});\n", .{ kind, i, l.size, l.alignment });
            } else try w.writeAll("            pub const Elem = void;\n");
            const ops = if (is_stream) [_][3][]const u8{
                .{ "new", "", "() u64" },
                .{ "read", "[async-lower]", "(end: u32, ptr: u32, len: u32) u32" },
                .{ "write", "[async-lower]", "(end: u32, ptr: u32, len: u32) u32" },
                .{ "cancel-read", "", "(end: u32) u32" },
                .{ "cancel-write", "", "(end: u32) u32" },
                .{ "drop-readable", "", "(end: u32) void" },
                .{ "drop-writable", "", "(end: u32) void" },
            } else [_][3][]const u8{
                .{ "new", "", "() u64" },
                .{ "read", "[async-lower]", "(end: u32, ptr: u32) u32" },
                .{ "write", "[async-lower]", "(end: u32, ptr: u32) u32" },
                .{ "cancel-read", "", "(end: u32) u32" },
                .{ "cancel-write", "", "(end: u32) u32" },
                .{ "drop-readable", "", "(end: u32) void" },
                .{ "drop-writable", "", "(end: u32) void" },
            };
            for (ops) |op| {
                const iname = try std.fmt.allocPrint(g.a, "{s}[{s}-{s}-{d}]{s}", .{ op[1], kind, op[0], i, core });
                try writeExtern(w, "            ", try snake(g.a, op[0]), it.id, iname, op[2]);
            }
            try w.writeAll("        };\n");
        }
        if (checks.items.len > 0) try w.print("\n        comptime {{\n{s}        }}\n", .{checks.items});
        try w.writeAll("    };\n");
    }
};

/// Writes `pub const NAME = @extern(...)` for the core import `import` of
/// `module`. `sig` is the parameter list and the result: `(end: u32) u32`.
/// `@extern` keeps the Zig name apart from the name of the import, so a
/// function struct `now` can hold the import `now`.
fn writeExtern(w: *Writer, indent: []const u8, name: []const u8, module: []const u8, import: []const u8, sig: []const u8) Error!void {
    const close = std.mem.lastIndexOfScalar(u8, sig, ')').?;
    try w.print("{s}pub const {f} = @extern(*const fn {s} callconv(.c){s}, .{{ .name = \"{s}\", .library_name = \"{s}\" }});\n", .{ indent, std.zig.fmtId(name), sig[0 .. close + 1], sig[close + 1 ..], import, module });
}

const header =
    \\//! The canonical ABI imports of WASI 0.3.2 that ztcl uses. `zig build
    \\//! witgen` writes this file from `wit/` and `tools/witgen/needed.txt`.
    \\//! Do not edit it. Each address and each handle is a `u32`, so the
    \\//! layouts are the same on each target. A comptime check compares the
    \\//! layout of each type with the size and the alignment of the canonical
    \\//! ABI.
    \\//!
    \\//! SPDX-License-Identifier: BSD-2-Clause
    \\
    \\/// A `list<T>` in memory: the address of the first element and the count.
    \\pub fn List(comptime T: type) type {
    \\    return extern struct {
    \\        ptr: u32,
    \\        len: u32,
    \\
    \\        pub const Elem = T;
    \\    };
    \\}
    \\
    \\pub const String = List(u8);
    \\
    \\/// An `option<T>`: the case byte, 0 for `none` and 1 for `some`.
    \\pub fn Option(comptime T: type) type {
    \\    return extern struct { tag: u8, value: T };
    \\}
    \\
    \\/// A `result<T, E>`: the case byte, 0 for `ok` and 1 for `err`. `void`
    \\/// is a case with no value.
    \\pub fn Result(comptime T: type, comptime E: type) type {
    \\    if (T == void and E == void) return extern struct { tag: u8 };
    \\    if (E == void) return extern struct { tag: u8, payload: extern union { ok: T } };
    \\    if (T == void) return extern struct { tag: u8, payload: extern union { err: E } };
    \\    return extern struct { tag: u8, payload: extern union { ok: T, err: E } };
    \\}
    \\
    \\fn check(comptime T: type, comptime size: usize, comptime alignment: usize) void {
    \\    if (@sizeOf(T) != size or @alignOf(T) != alignment) @compileError("the layout of " ++ @typeName(T) ++ " is not the layout of the canonical ABI");
    \\}
    \\
;

/// A field name: a primitive name such as `type` needs no quotes.
fn fieldId(name: []const u8) std.zig.FormatId {
    return std.zig.fmtIdFlags(name, .{ .allow_primitive = true });
}

/// `descriptor-stat` to `descriptor_stat`, and `.` to `_`.
fn snake(a: Allocator, s: []const u8) Error![]const u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '-' or c.* == '.') c.* = '_';
    }
    return out;
}

/// `descriptor-stat` to `DescriptorStat`.
fn camel(a: Allocator, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var up = true;
    for (s) |c| {
        if (c == '-') {
            up = true;
            continue;
        }
        try out.append(a, if (up) std.ascii.toUpper(c) else c);
        up = false;
    }
    return out.items;
}

pub fn generate(a: Allocator, sources: []const Source, needed: []const u8) Error![]const u8 {
    var g: Gen = .{ .a = a };
    try g.parse(sources);
    var aw: Writer.Allocating = .init(a);
    try g.write(&aw.writer, needed);
    return aw.written();
}

test "the layout and the flattening of the canonical ABI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wit =
        \\package t:p@1.0.0;
        \\interface i {
        \\  use j.{e};
        \\  variant err { a, b, other(option<string>) }
        \\  flags fl { x, y }
        \\  record r { %type: u8, n: u64, o: option<u32> }
        \\  resource res {
        \\    m: async func(a: u64, b: u64, c: string) -> result<r, err>;
        \\  }
        \\  f: func(x: list<u8>, y: fl) -> tuple<stream<u8>, future<result<_, err>>>;
        \\  g: func() -> e;
        \\}
        \\interface j { enum e { p, q } }
    ;
    const out = try generate(a, &.{.{ .dir = "t", .path = "t.wit", .text = wit }}, "t:p/i@1.0.0 [method]res.m\nt:p/i@1.0.0 f\nt:p/i@1.0.0 g\n");
    // The record: u8 at 0, u64 at 8, option<u32> at 16; size 24, alignment 8.
    try std.testing.expect(std.mem.indexOf(u8, out, "check(R, 24, 8);") != null);
    // option<string> is 12 bytes, so the variant is 16 bytes.
    try std.testing.expect(std.mem.indexOf(u8, out, "check(Err, 16, 4);") != null);
    // The async method has 5 flat parameters, so they go in memory.
    try std.testing.expect(std.mem.indexOf(u8, out, "fn (params: u32, ret: u32) callconv(.c) u32, .{ .name = \"[async-lower][method]res.m\"") != null);
    // Two flat results go to a return area.
    try std.testing.expect(std.mem.indexOf(u8, out, "fn (x_0: u32, x_1: u32, y: u32, ret: u32) callconv(.c) void, .{ .name = \"f\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fn () callconv(.c) u64, .{ .name = \"[stream-new-0]f\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = \"[async-lower][future-read-1]f\"") != null);
    // A type of another interface through `use`.
    try std.testing.expect(std.mem.indexOf(u8, out, "fn () callconv(.c) u32, .{ .name = \"g\", .library_name = \"t:p/i@1.0.0\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const E = enum(u8) {") != null);
}
