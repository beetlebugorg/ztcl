//! The canonical ABI imports of WASI 0.3.2 that ztcl uses. `zig build
//! witgen` writes this file from `wit/` and `tools/witgen/needed.txt`.
//! Do not edit it. Each address and each handle is a `u32`, so the
//! layouts are the same on each target. A comptime check compares the
//! layout of each type with the size and the alignment of the canonical
//! ABI.
//!
//! SPDX-License-Identifier: BSD-2-Clause

/// A `list<T>` in memory: the address of the first element and the count.
pub fn List(comptime T: type) type {
    return extern struct {
        ptr: u32,
        len: u32,

        pub const Elem = T;
    };
}

pub const String = List(u8);

/// An `option<T>`: the case byte, 0 for `none` and 1 for `some`.
pub fn Option(comptime T: type) type {
    return extern struct { tag: u8, value: T };
}

/// A `result<T, E>`: the case byte, 0 for `ok` and 1 for `err`. `void`
/// is a case with no value.
pub fn Result(comptime T: type, comptime E: type) type {
    if (T == void and E == void) return extern struct { tag: u8 };
    if (E == void) return extern struct { tag: u8, payload: extern union { ok: T } };
    if (T == void) return extern struct { tag: u8, payload: extern union { err: E } };
    return extern struct { tag: u8, payload: extern union { ok: T, err: E } };
}

fn check(comptime T: type, comptime size: usize, comptime alignment: usize) void {
    if (@sizeOf(T) != size or @alignOf(T) != alignment) @compileError("the layout of " ++ @typeName(T) ++ " is not the layout of the canonical ABI");
}

/// The interface `wasi:cli/environment@0.3.2`.
pub const cli_environment = struct {
    const module = "wasi:cli/environment@0.3.2";

    /// `get-environment: func() -> list<tuple<string, string>>;`
    pub const get_environment = struct {
        /// The return area.
        pub const Ret = List(extern struct { @"0": String, @"1": String });
        pub const call = @extern(*const fn (ret: u32) callconv(.c) void, .{ .name = "get-environment", .library_name = "wasi:cli/environment@0.3.2" });

        comptime {
            check(Ret, 8, 4);
        }
    };

    /// `get-arguments: func() -> list<string>;`
    pub const get_arguments = struct {
        /// The return area.
        pub const Ret = List(String);
        pub const call = @extern(*const fn (ret: u32) callconv(.c) void, .{ .name = "get-arguments", .library_name = "wasi:cli/environment@0.3.2" });

        comptime {
            check(Ret, 8, 4);
        }
    };

    /// `get-initial-cwd: func() -> option<string>;`
    pub const get_initial_cwd = struct {
        /// The return area.
        pub const Ret = Option(String);
        pub const call = @extern(*const fn (ret: u32) callconv(.c) void, .{ .name = "get-initial-cwd", .library_name = "wasi:cli/environment@0.3.2" });

        comptime {
            check(Ret, 12, 4);
        }
    };
};

/// The interface `wasi:cli/exit@0.3.2`.
pub const cli_exit = struct {
    const module = "wasi:cli/exit@0.3.2";

    /// `exit: func(status: result);`
    pub const exit = struct {
        pub const call = @extern(*const fn (status: u32) callconv(.c) void, .{ .name = "exit", .library_name = "wasi:cli/exit@0.3.2" });
    };
};

/// The interface `wasi:cli/stderr@0.3.2`.
pub const cli_stderr = struct {
    const module = "wasi:cli/stderr@0.3.2";

    /// `write-via-stream: func(data: stream<u8>) -> future<result<_, error-code>>;`
    pub const write_via_stream = struct {
        pub const call = @extern(*const fn (data: u32) callconv(.c) u32, .{ .name = "write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });

        /// The built-ins of `stream` 0 of this function.
        pub const stream0 = struct {
            pub const Elem = u8;
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[stream-new-0]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-read-0]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-write-0]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-read-0]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-write-0]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-readable-0]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-writable-0]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
        };

        /// The built-ins of `future` 1 of this function.
        pub const future1 = struct {
            pub const Elem = Result(void, cli_types.ErrorCode);
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[future-new-1]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-read-1]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-write-1]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-read-1]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-write-1]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-readable-1]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-writable-1]write-via-stream", .library_name = "wasi:cli/stderr@0.3.2" });
        };

        comptime {
            check(stream0.Elem, 1, 1);
            check(future1.Elem, 2, 1);
        }
    };
};

/// The interface `wasi:cli/stdin@0.3.2`.
pub const cli_stdin = struct {
    const module = "wasi:cli/stdin@0.3.2";

    /// `read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>;`
    pub const read_via_stream = struct {
        /// The return area.
        pub const Ret = extern struct { @"0": u32, @"1": u32 };
        pub const call = @extern(*const fn (ret: u32) callconv(.c) void, .{ .name = "read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });

        /// The built-ins of `stream` 0 of this function.
        pub const stream0 = struct {
            pub const Elem = u8;
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[stream-new-0]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-read-0]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-write-0]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-read-0]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-write-0]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-readable-0]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-writable-0]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
        };

        /// The built-ins of `future` 1 of this function.
        pub const future1 = struct {
            pub const Elem = Result(void, cli_types.ErrorCode);
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[future-new-1]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-read-1]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-write-1]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-read-1]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-write-1]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-readable-1]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-writable-1]read-via-stream", .library_name = "wasi:cli/stdin@0.3.2" });
        };

        comptime {
            check(Ret, 8, 4);
            check(stream0.Elem, 1, 1);
            check(future1.Elem, 2, 1);
        }
    };
};

/// The interface `wasi:cli/stdout@0.3.2`.
pub const cli_stdout = struct {
    const module = "wasi:cli/stdout@0.3.2";

    /// `write-via-stream: func(data: stream<u8>) -> future<result<_, error-code>>;`
    pub const write_via_stream = struct {
        pub const call = @extern(*const fn (data: u32) callconv(.c) u32, .{ .name = "write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });

        /// The built-ins of `stream` 0 of this function.
        pub const stream0 = struct {
            pub const Elem = u8;
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[stream-new-0]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-read-0]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-write-0]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-read-0]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-write-0]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-readable-0]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-writable-0]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
        };

        /// The built-ins of `future` 1 of this function.
        pub const future1 = struct {
            pub const Elem = Result(void, cli_types.ErrorCode);
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[future-new-1]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-read-1]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-write-1]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-read-1]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-write-1]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-readable-1]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-writable-1]write-via-stream", .library_name = "wasi:cli/stdout@0.3.2" });
        };

        comptime {
            check(stream0.Elem, 1, 1);
            check(future1.Elem, 2, 1);
        }
    };
};

/// The interface `wasi:cli/types@0.3.2`.
pub const cli_types = struct {
    const module = "wasi:cli/types@0.3.2";

    pub const ErrorCode = enum(u8) {
        io,
        illegal_byte_sequence,
        pipe,
    };

    comptime {
        check(ErrorCode, 1, 1);
    }
};

/// The interface `wasi:clocks/monotonic-clock@0.3.2`.
pub const clocks_monotonic_clock = struct {
    const module = "wasi:clocks/monotonic-clock@0.3.2";

    pub const Mark = u64;

    /// `now: func() -> mark;`
    pub const now = struct {
        pub const call = @extern(*const fn () callconv(.c) u64, .{ .name = "now", .library_name = "wasi:clocks/monotonic-clock@0.3.2" });
    };

    /// `wait-for: async func(how-long: duration,);`
    pub const wait_for = struct {
        pub const call = @extern(*const fn (how_long: u64) callconv(.c) u32, .{ .name = "[async-lower]wait-for", .library_name = "wasi:clocks/monotonic-clock@0.3.2" });
    };

    /// `wait-until: async func(when: mark,);`
    pub const wait_until = struct {
        pub const call = @extern(*const fn (when: u64) callconv(.c) u32, .{ .name = "[async-lower]wait-until", .library_name = "wasi:clocks/monotonic-clock@0.3.2" });
    };

    comptime {
        check(Mark, 8, 8);
    }
};

/// The interface `wasi:clocks/system-clock@0.3.2`.
pub const clocks_system_clock = struct {
    const module = "wasi:clocks/system-clock@0.3.2";

    pub const Instant = extern struct {
        seconds: i64,
        nanoseconds: u32,
    };

    /// `now: func() -> instant;`
    pub const now = struct {
        /// The return area.
        pub const Ret = Instant;
        pub const call = @extern(*const fn (ret: u32) callconv(.c) void, .{ .name = "now", .library_name = "wasi:clocks/system-clock@0.3.2" });

        comptime {
            check(Ret, 16, 8);
        }
    };

    comptime {
        check(Instant, 16, 8);
    }
};

/// The interface `wasi:clocks/types@0.3.2`.
pub const clocks_types = struct {
    const module = "wasi:clocks/types@0.3.2";

    pub const Duration = u64;

    comptime {
        check(Duration, 8, 8);
    }
};

/// The interface `wasi:filesystem/preopens@0.3.2`.
pub const filesystem_preopens = struct {
    const module = "wasi:filesystem/preopens@0.3.2";

    /// `get-directories: func() -> list<tuple<descriptor, string>>;`
    pub const get_directories = struct {
        /// The return area.
        pub const Ret = List(extern struct { @"0": filesystem_types.Descriptor, @"1": String });
        pub const call = @extern(*const fn (ret: u32) callconv(.c) void, .{ .name = "get-directories", .library_name = "wasi:filesystem/preopens@0.3.2" });

        comptime {
            check(Ret, 8, 4);
        }
    };
};

/// The interface `wasi:filesystem/types@0.3.2`.
pub const filesystem_types = struct {
    const module = "wasi:filesystem/types@0.3.2";

    pub const Filesize = u64;

    pub const DescriptorType = extern struct {
        tag: Tag,
        payload: extern union {
            other: Option(String),
        },

        pub const Tag = enum(u8) {
            block_device,
            character_device,
            directory,
            fifo,
            symbolic_link,
            regular_file,
            socket,
            other,
        };
    };

    pub const DescriptorFlags = packed struct(u8) {
        read: bool = false,
        write: bool = false,
        file_integrity_sync: bool = false,
        data_integrity_sync: bool = false,
        requested_write_sync: bool = false,
        mutate_directory: bool = false,
        _: u2 = 0,
    };

    pub const DescriptorStat = extern struct {
        type: DescriptorType,
        link_count: LinkCount,
        size: Filesize,
        data_access_timestamp: Option(clocks_system_clock.Instant),
        data_modification_timestamp: Option(clocks_system_clock.Instant),
        status_change_timestamp: Option(clocks_system_clock.Instant),
    };

    pub const PathFlags = packed struct(u8) {
        symlink_follow: bool = false,
        _: u7 = 0,
    };

    pub const OpenFlags = packed struct(u8) {
        create: bool = false,
        directory: bool = false,
        exclusive: bool = false,
        truncate: bool = false,
        _: u4 = 0,
    };

    pub const LinkCount = u64;

    pub const DirectoryEntry = extern struct {
        type: DescriptorType,
        name: String,
    };

    pub const ErrorCode = extern struct {
        tag: Tag,
        payload: extern union {
            other: Option(String),
        },

        pub const Tag = enum(u8) {
            access,
            already,
            bad_descriptor,
            busy,
            deadlock,
            quota,
            exist,
            file_too_large,
            illegal_byte_sequence,
            in_progress,
            interrupted,
            invalid,
            io,
            is_directory,
            loop,
            too_many_links,
            message_size,
            name_too_long,
            no_device,
            no_entry,
            no_lock,
            insufficient_memory,
            insufficient_space,
            not_directory,
            not_empty,
            not_recoverable,
            unsupported,
            no_tty,
            no_such_device,
            overflow,
            not_permitted,
            pipe,
            read_only,
            invalid_seek,
            text_file_busy,
            cross_device,
            other,
        };
    };

    /// A handle of the resource `descriptor`.
    pub const Descriptor = u32;

    /// `read-via-stream: func(/// The offset within the file at which to start reading. offset: filesize,) -> tuple<stream<u8>, future<result<_, error-code>>>;`
    pub const descriptor_read_via_stream = struct {
        /// The return area.
        pub const Ret = extern struct { @"0": u32, @"1": u32 };
        pub const call = @extern(*const fn (self: u32, offset: u64, ret: u32) callconv(.c) void, .{ .name = "[method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });

        /// The built-ins of `stream` 0 of this function.
        pub const stream0 = struct {
            pub const Elem = u8;
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[stream-new-0][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-read-0][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-write-0][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-read-0][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-write-0][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-readable-0][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-writable-0][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
        };

        /// The built-ins of `future` 1 of this function.
        pub const future1 = struct {
            pub const Elem = Result(void, ErrorCode);
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[future-new-1][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-read-1][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-write-1][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-read-1][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-write-1][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-readable-1][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-writable-1][method]descriptor.read-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
        };

        comptime {
            check(Ret, 8, 4);
            check(stream0.Elem, 1, 1);
            check(future1.Elem, 20, 4);
        }
    };

    /// `write-via-stream: func(/// Data to write data: stream<u8>, /// The offset within the file at which to start writing. offset: filesize,) -> future<result<_, error-code>>;`
    pub const descriptor_write_via_stream = struct {
        pub const call = @extern(*const fn (self: u32, data: u32, offset: u64) callconv(.c) u32, .{ .name = "[method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });

        /// The built-ins of `stream` 0 of this function.
        pub const stream0 = struct {
            pub const Elem = u8;
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[stream-new-0][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-read-0][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-write-0][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-read-0][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-write-0][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-readable-0][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-writable-0][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
        };

        /// The built-ins of `future` 1 of this function.
        pub const future1 = struct {
            pub const Elem = Result(void, ErrorCode);
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[future-new-1][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-read-1][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-write-1][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-read-1][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-write-1][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-readable-1][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-writable-1][method]descriptor.write-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
        };

        comptime {
            check(stream0.Elem, 1, 1);
            check(future1.Elem, 20, 4);
        }
    };

    /// `append-via-stream: func(data: stream<u8>) -> future<result<_, error-code>>;`
    pub const descriptor_append_via_stream = struct {
        pub const call = @extern(*const fn (self: u32, data: u32) callconv(.c) u32, .{ .name = "[method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });

        /// The built-ins of `stream` 0 of this function.
        pub const stream0 = struct {
            pub const Elem = u8;
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[stream-new-0][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-read-0][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-write-0][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-read-0][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-write-0][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-readable-0][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-writable-0][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
        };

        /// The built-ins of `future` 1 of this function.
        pub const future1 = struct {
            pub const Elem = Result(void, ErrorCode);
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[future-new-1][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-read-1][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-write-1][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-read-1][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-write-1][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-readable-1][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-writable-1][method]descriptor.append-via-stream", .library_name = "wasi:filesystem/types@0.3.2" });
        };

        comptime {
            check(stream0.Elem, 1, 1);
            check(future1.Elem, 20, 4);
        }
    };

    /// `get-flags: async func() -> result<descriptor-flags, error-code>;`
    pub const descriptor_get_flags = struct {
        /// The return area.
        pub const Ret = Result(DescriptorFlags, ErrorCode);
        pub const call = @extern(*const fn (self: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.get-flags", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// `get-type: async func() -> result<descriptor-type, error-code>;`
    pub const descriptor_get_type = struct {
        /// The return area.
        pub const Ret = Result(DescriptorType, ErrorCode);
        pub const call = @extern(*const fn (self: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.get-type", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// `set-size: async func(size: filesize) -> result<_, error-code>;`
    pub const descriptor_set_size = struct {
        /// The return area.
        pub const Ret = Result(void, ErrorCode);
        pub const call = @extern(*const fn (self: u32, size: u64, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.set-size", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// `read-directory: func() -> tuple<stream<directory-entry>, future<result<_, error-code>>>;`
    pub const descriptor_read_directory = struct {
        /// The return area.
        pub const Ret = extern struct { @"0": u32, @"1": u32 };
        pub const call = @extern(*const fn (self: u32, ret: u32) callconv(.c) void, .{ .name = "[method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });

        /// The built-ins of `stream` 0 of this function.
        pub const stream0 = struct {
            pub const Elem = DirectoryEntry;
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[stream-new-0][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-read-0][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-write-0][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-read-0][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-write-0][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-readable-0][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-writable-0][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
        };

        /// The built-ins of `future` 1 of this function.
        pub const future1 = struct {
            pub const Elem = Result(void, ErrorCode);
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[future-new-1][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-read-1][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-write-1][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-read-1][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-write-1][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-readable-1][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-writable-1][method]descriptor.read-directory", .library_name = "wasi:filesystem/types@0.3.2" });
        };

        comptime {
            check(Ret, 8, 4);
            check(stream0.Elem, 24, 4);
            check(future1.Elem, 20, 4);
        }
    };

    /// `sync: async func() -> result<_, error-code>;`
    pub const descriptor_sync = struct {
        /// The return area.
        pub const Ret = Result(void, ErrorCode);
        pub const call = @extern(*const fn (self: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.sync", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// `create-directory-at: async func(/// The relative path at which to create the directory. path: string,) -> result<_, error-code>;`
    pub const descriptor_create_directory_at = struct {
        /// The return area.
        pub const Ret = Result(void, ErrorCode);
        pub const call = @extern(*const fn (self: u32, path_0: u32, path_1: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.create-directory-at", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// `stat: async func() -> result<descriptor-stat, error-code>;`
    pub const descriptor_stat = struct {
        /// The return area.
        pub const Ret = Result(DescriptorStat, ErrorCode);
        pub const call = @extern(*const fn (self: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.stat", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Ret, 112, 8);
        }
    };

    /// `stat-at: async func(/// Flags determining the method of how the path is resolved. path-flags: path-flags, /// The relative path of the file or directory to inspect. path: string,) -> result<descriptor-stat, error-code>;`
    pub const descriptor_stat_at = struct {
        /// The return area.
        pub const Ret = Result(DescriptorStat, ErrorCode);
        pub const call = @extern(*const fn (self: u32, path_flags: u32, path_0: u32, path_1: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.stat-at", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Ret, 112, 8);
        }
    };

    /// `open-at: async func(/// Flags determining the method of how the path is resolved. path-flags: path-flags, /// The relative path of the object to open. path: string, /// The method by which to open the file. open-flags: open-flags, /// Flags to use for the resulting descriptor. %flags: descriptor-flags,) -> result<descriptor, error-code>;`
    pub const descriptor_open_at = struct {
        /// The parameters in memory.
        pub const Params = extern struct {
            self: u32,
            path_flags: PathFlags,
            path: String,
            open_flags: OpenFlags,
            flags: DescriptorFlags,
        };
        /// The return area.
        pub const Ret = Result(Descriptor, ErrorCode);
        pub const call = @extern(*const fn (params: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.open-at", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Params, 20, 4);
            check(Ret, 20, 4);
        }
    };

    /// `readlink-at: async func(/// The relative path of the symbolic link from which to read. path: string,) -> result<string, error-code>;`
    pub const descriptor_readlink_at = struct {
        /// The return area.
        pub const Ret = Result(String, ErrorCode);
        pub const call = @extern(*const fn (self: u32, path_0: u32, path_1: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.readlink-at", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// `remove-directory-at: async func(/// The relative path to a directory to remove. path: string,) -> result<_, error-code>;`
    pub const descriptor_remove_directory_at = struct {
        /// The return area.
        pub const Ret = Result(void, ErrorCode);
        pub const call = @extern(*const fn (self: u32, path_0: u32, path_1: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.remove-directory-at", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// `rename-at: async func(/// The relative source path of the file or directory to rename. old-path: string, /// The base directory for `new-path`. new-descriptor: borrow<descriptor>, /// The relative destination path to which to rename the file or directory. new-path: string,) -> result<_, error-code>;`
    pub const descriptor_rename_at = struct {
        /// The parameters in memory.
        pub const Params = extern struct {
            self: u32,
            old_path: String,
            new_descriptor: u32,
            new_path: String,
        };
        /// The return area.
        pub const Ret = Result(void, ErrorCode);
        pub const call = @extern(*const fn (params: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.rename-at", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Params, 24, 4);
            check(Ret, 20, 4);
        }
    };

    /// `unlink-file-at: async func(/// The relative path to a file to unlink. path: string,) -> result<_, error-code>;`
    pub const descriptor_unlink_file_at = struct {
        /// The return area.
        pub const Ret = Result(void, ErrorCode);
        pub const call = @extern(*const fn (self: u32, path_0: u32, path_1: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]descriptor.unlink-file-at", .library_name = "wasi:filesystem/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// Drops a handle of `descriptor`.
    pub const drop_descriptor = @extern(*const fn (handle: u32) callconv(.c) void, .{ .name = "[resource-drop]descriptor", .library_name = "wasi:filesystem/types@0.3.2" });

    comptime {
        check(Filesize, 8, 8);
        check(DescriptorType, 16, 4);
        check(DescriptorFlags, 1, 1);
        check(DescriptorStat, 104, 8);
        check(PathFlags, 1, 1);
        check(OpenFlags, 1, 1);
        check(LinkCount, 8, 8);
        check(DirectoryEntry, 24, 4);
        check(ErrorCode, 16, 4);
        check(Descriptor, 4, 4);
    }
};

/// The interface `wasi:random/random@0.3.2`.
pub const random_random = struct {
    const module = "wasi:random/random@0.3.2";

    /// `get-random-bytes: func(max-len: u64) -> list<u8>;`
    pub const get_random_bytes = struct {
        /// The return area.
        pub const Ret = List(u8);
        pub const call = @extern(*const fn (max_len: u64, ret: u32) callconv(.c) void, .{ .name = "get-random-bytes", .library_name = "wasi:random/random@0.3.2" });

        comptime {
            check(Ret, 8, 4);
        }
    };

    /// `get-random-u64: func() -> u64;`
    pub const get_random_u64 = struct {
        pub const call = @extern(*const fn () callconv(.c) u64, .{ .name = "get-random-u64", .library_name = "wasi:random/random@0.3.2" });
    };
};

/// The interface `wasi:sockets/ip-name-lookup@0.3.2`.
pub const sockets_ip_name_lookup = struct {
    const module = "wasi:sockets/ip-name-lookup@0.3.2";

    pub const ErrorCode = extern struct {
        tag: Tag,
        payload: extern union {
            other: Option(String),
        },

        pub const Tag = enum(u8) {
            access_denied,
            invalid_argument,
            name_unresolvable,
            temporary_resolver_failure,
            permanent_resolver_failure,
            other,
        };
    };

    /// `resolve-addresses: async func(name: string) -> result<list<ip-address>, error-code>;`
    pub const resolve_addresses = struct {
        /// The return area.
        pub const Ret = Result(List(sockets_types.IpAddress), ErrorCode);
        pub const call = @extern(*const fn (name_0: u32, name_1: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower]resolve-addresses", .library_name = "wasi:sockets/ip-name-lookup@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    comptime {
        check(ErrorCode, 16, 4);
    }
};

/// The interface `wasi:sockets/types@0.3.2`.
pub const sockets_types = struct {
    const module = "wasi:sockets/types@0.3.2";

    pub const ErrorCode = extern struct {
        tag: Tag,
        payload: extern union {
            other: Option(String),
        },

        pub const Tag = enum(u8) {
            access_denied,
            not_supported,
            invalid_argument,
            out_of_memory,
            timeout,
            invalid_state,
            address_not_bindable,
            address_in_use,
            remote_unreachable,
            connection_refused,
            connection_broken,
            connection_reset,
            connection_aborted,
            datagram_too_large,
            other,
        };
    };

    pub const IpAddressFamily = enum(u8) {
        ipv4,
        ipv6,
    };

    pub const Ipv4Address = extern struct { @"0": u8, @"1": u8, @"2": u8, @"3": u8 };

    pub const Ipv6Address = extern struct { @"0": u16, @"1": u16, @"2": u16, @"3": u16, @"4": u16, @"5": u16, @"6": u16, @"7": u16 };

    pub const IpAddress = extern struct {
        tag: Tag,
        payload: extern union {
            ipv4: Ipv4Address,
            ipv6: Ipv6Address,
        },

        pub const Tag = enum(u8) {
            ipv4,
            ipv6,
        };
    };

    pub const Ipv4SocketAddress = extern struct {
        port: u16,
        address: Ipv4Address,
    };

    pub const Ipv6SocketAddress = extern struct {
        port: u16,
        flow_info: u32,
        address: Ipv6Address,
        scope_id: u32,
    };

    pub const IpSocketAddress = extern struct {
        tag: Tag,
        payload: extern union {
            ipv4: Ipv4SocketAddress,
            ipv6: Ipv6SocketAddress,
        },

        pub const Tag = enum(u8) {
            ipv4,
            ipv6,
        };
    };

    /// A handle of the resource `tcp-socket`.
    pub const TcpSocket = u32;

    /// A handle of the resource `udp-socket`.
    pub const UdpSocket = u32;

    /// `create: static func(address-family: ip-address-family) -> result<tcp-socket, error-code>;`
    pub const tcp_socket_create = struct {
        /// The return area.
        pub const Ret = Result(TcpSocket, ErrorCode);
        pub const call = @extern(*const fn (address_family: u32, ret: u32) callconv(.c) void, .{ .name = "[static]tcp-socket.create", .library_name = "wasi:sockets/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// `bind: func(local-address: ip-socket-address) -> result<_, error-code>;`
    pub const tcp_socket_bind = struct {
        /// The return area.
        pub const Ret = Result(void, ErrorCode);
        pub const call = @extern(*const fn (self: u32, local_address_0: u32, local_address_1: u32, local_address_2: u32, local_address_3: u32, local_address_4: u32, local_address_5: u32, local_address_6: u32, local_address_7: u32, local_address_8: u32, local_address_9: u32, local_address_10: u32, local_address_11: u32, ret: u32) callconv(.c) void, .{ .name = "[method]tcp-socket.bind", .library_name = "wasi:sockets/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// `connect: async func(remote-address: ip-socket-address) -> result<_, error-code>;`
    pub const tcp_socket_connect = struct {
        /// The parameters in memory.
        pub const Params = extern struct {
            self: u32,
            remote_address: IpSocketAddress,
        };
        /// The return area.
        pub const Ret = Result(void, ErrorCode);
        pub const call = @extern(*const fn (params: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]tcp-socket.connect", .library_name = "wasi:sockets/types@0.3.2" });

        comptime {
            check(Params, 36, 4);
            check(Ret, 20, 4);
        }
    };

    /// `listen: func() -> result<stream<tcp-socket>, error-code>;`
    pub const tcp_socket_listen = struct {
        /// The return area.
        pub const Ret = Result(u32, ErrorCode);
        pub const call = @extern(*const fn (self: u32, ret: u32) callconv(.c) void, .{ .name = "[method]tcp-socket.listen", .library_name = "wasi:sockets/types@0.3.2" });

        /// The built-ins of `stream` 0 of this function.
        pub const stream0 = struct {
            pub const Elem = TcpSocket;
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[stream-new-0][method]tcp-socket.listen", .library_name = "wasi:sockets/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-read-0][method]tcp-socket.listen", .library_name = "wasi:sockets/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-write-0][method]tcp-socket.listen", .library_name = "wasi:sockets/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-read-0][method]tcp-socket.listen", .library_name = "wasi:sockets/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-write-0][method]tcp-socket.listen", .library_name = "wasi:sockets/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-readable-0][method]tcp-socket.listen", .library_name = "wasi:sockets/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-writable-0][method]tcp-socket.listen", .library_name = "wasi:sockets/types@0.3.2" });
        };

        comptime {
            check(Ret, 20, 4);
            check(stream0.Elem, 4, 4);
        }
    };

    /// `send: func(data: stream<u8>) -> future<result<_, error-code>>;`
    pub const tcp_socket_send = struct {
        pub const call = @extern(*const fn (self: u32, data: u32) callconv(.c) u32, .{ .name = "[method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });

        /// The built-ins of `stream` 0 of this function.
        pub const stream0 = struct {
            pub const Elem = u8;
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[stream-new-0][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-read-0][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-write-0][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-read-0][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-write-0][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-readable-0][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-writable-0][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
        };

        /// The built-ins of `future` 1 of this function.
        pub const future1 = struct {
            pub const Elem = Result(void, ErrorCode);
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[future-new-1][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-read-1][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-write-1][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-read-1][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-write-1][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-readable-1][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-writable-1][method]tcp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });
        };

        comptime {
            check(stream0.Elem, 1, 1);
            check(future1.Elem, 20, 4);
        }
    };

    /// `receive: func() -> tuple<stream<u8>, future<result<_, error-code>>>;`
    pub const tcp_socket_receive = struct {
        /// The return area.
        pub const Ret = extern struct { @"0": u32, @"1": u32 };
        pub const call = @extern(*const fn (self: u32, ret: u32) callconv(.c) void, .{ .name = "[method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });

        /// The built-ins of `stream` 0 of this function.
        pub const stream0 = struct {
            pub const Elem = u8;
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[stream-new-0][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-read-0][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32, len: u32) callconv(.c) u32, .{ .name = "[async-lower][stream-write-0][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-read-0][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[stream-cancel-write-0][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-readable-0][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[stream-drop-writable-0][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
        };

        /// The built-ins of `future` 1 of this function.
        pub const future1 = struct {
            pub const Elem = Result(void, ErrorCode);
            pub const new = @extern(*const fn () callconv(.c) u64, .{ .name = "[future-new-1][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const read = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-read-1][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const write = @extern(*const fn (end: u32, ptr: u32) callconv(.c) u32, .{ .name = "[async-lower][future-write-1][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const cancel_read = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-read-1][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const cancel_write = @extern(*const fn (end: u32) callconv(.c) u32, .{ .name = "[future-cancel-write-1][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const drop_readable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-readable-1][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
            pub const drop_writable = @extern(*const fn (end: u32) callconv(.c) void, .{ .name = "[future-drop-writable-1][method]tcp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });
        };

        comptime {
            check(Ret, 8, 4);
            check(stream0.Elem, 1, 1);
            check(future1.Elem, 20, 4);
        }
    };

    /// `get-local-address: func() -> result<ip-socket-address, error-code>;`
    pub const tcp_socket_get_local_address = struct {
        /// The return area.
        pub const Ret = Result(IpSocketAddress, ErrorCode);
        pub const call = @extern(*const fn (self: u32, ret: u32) callconv(.c) void, .{ .name = "[method]tcp-socket.get-local-address", .library_name = "wasi:sockets/types@0.3.2" });

        comptime {
            check(Ret, 36, 4);
        }
    };

    /// `get-remote-address: func() -> result<ip-socket-address, error-code>;`
    pub const tcp_socket_get_remote_address = struct {
        /// The return area.
        pub const Ret = Result(IpSocketAddress, ErrorCode);
        pub const call = @extern(*const fn (self: u32, ret: u32) callconv(.c) void, .{ .name = "[method]tcp-socket.get-remote-address", .library_name = "wasi:sockets/types@0.3.2" });

        comptime {
            check(Ret, 36, 4);
        }
    };

    /// Drops a handle of `tcp-socket`.
    pub const drop_tcp_socket = @extern(*const fn (handle: u32) callconv(.c) void, .{ .name = "[resource-drop]tcp-socket", .library_name = "wasi:sockets/types@0.3.2" });

    /// `create: static func(address-family: ip-address-family) -> result<udp-socket, error-code>;`
    pub const udp_socket_create = struct {
        /// The return area.
        pub const Ret = Result(UdpSocket, ErrorCode);
        pub const call = @extern(*const fn (address_family: u32, ret: u32) callconv(.c) void, .{ .name = "[static]udp-socket.create", .library_name = "wasi:sockets/types@0.3.2" });

        comptime {
            check(Ret, 20, 4);
        }
    };

    /// `send: async func(data: list<u8>, remote-address: option<ip-socket-address>) -> result<_, error-code>;`
    pub const udp_socket_send = struct {
        /// The parameters in memory.
        pub const Params = extern struct {
            self: u32,
            data: List(u8),
            remote_address: Option(IpSocketAddress),
        };
        /// The return area.
        pub const Ret = Result(void, ErrorCode);
        pub const call = @extern(*const fn (params: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]udp-socket.send", .library_name = "wasi:sockets/types@0.3.2" });

        comptime {
            check(Params, 48, 4);
            check(Ret, 20, 4);
        }
    };

    /// `receive: async func() -> result<tuple<list<u8>, ip-socket-address>, error-code>;`
    pub const udp_socket_receive = struct {
        /// The return area.
        pub const Ret = Result(extern struct { @"0": List(u8), @"1": IpSocketAddress }, ErrorCode);
        pub const call = @extern(*const fn (self: u32, ret: u32) callconv(.c) u32, .{ .name = "[async-lower][method]udp-socket.receive", .library_name = "wasi:sockets/types@0.3.2" });

        comptime {
            check(Ret, 44, 4);
        }
    };

    /// Drops a handle of `udp-socket`.
    pub const drop_udp_socket = @extern(*const fn (handle: u32) callconv(.c) void, .{ .name = "[resource-drop]udp-socket", .library_name = "wasi:sockets/types@0.3.2" });

    comptime {
        check(ErrorCode, 16, 4);
        check(IpAddressFamily, 1, 1);
        check(Ipv4Address, 4, 1);
        check(Ipv6Address, 16, 2);
        check(IpAddress, 18, 2);
        check(Ipv4SocketAddress, 6, 2);
        check(Ipv6SocketAddress, 28, 4);
        check(IpSocketAddress, 32, 4);
        check(TcpSocket, 4, 4);
        check(UdpSocket, 4, 4);
    }
};
