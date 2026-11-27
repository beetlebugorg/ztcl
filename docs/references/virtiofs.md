# References for virtio-fs

The virtio-fs device and the FUSE server of `src/vm/virtio/` (plan: `docs/dev/virtiofs.md`) use these sources. ztcl has no code of any of them. No source code of QEMU, virtiofsd, libfuse, or the Linux kernel was read, except the one header below, under its BSD license.

## The virtio file system device

OASIS, "Virtual I/O Device (VIRTIO) Version 1.2", section 5.11 (the file system device) and section 4.2.2 (the registers of virtio-mmio, with the shared memory regions). The text of 5.11 comes from the source of the specification: https://github.com/oasis-tcs/virtio-spec, `device-types/fs/description.tex`. https://docs.oasis-open.org/virtio/virtio/v1.2/csd01/virtio-v1.2-csd01.html

**License:** the text of the specification. ztcl copies no text from it.

**How ztcl uses it:**

- The device ID 26, and the one feature bit `VIRTIO_FS_F_NOTIFICATION` (0).
- The configuration: `tag` (36 bytes of UTF-8, padded with NUL bytes), `num_request_queues` (le32, 1 or more), and `notify_buf_size` (le32, with the feature only): 44 bytes.
- The queues: 0 is the high priority queue (`FUSE_INTERRUPT`, `FUSE_FORGET`, and `FUSE_BATCH_FORGET` only), 1 is the notification queue with the feature, and the request queues follow.
- A request: the readable part is `fuse_in_header` and the arguments, and the writable part is `fuse_out_header` and the answer. The driver chooses the byte order in `FUSE_INIT`, and each `FUSE_INIT` starts a session.
- Shared memory region 0 is the DAX window. The registers of virtio-mmio: `SHMSel` at 0x0ac (write), `SHMLenLow` and `SHMLenHigh` at 0x0b0 and 0x0b4, and `SHMBaseLow` and `SHMBaseHigh` at 0x0b8 and 0x0bc (read). A region that does not exist gives a length of -1 and a base of all ones.

## The FUSE protocol

The Linux kernel, `include/uapi/linux/fuse.h`, protocol 7.47. https://github.com/torvalds/linux/blob/master/include/uapi/linux/fuse.h

**License:** `((GPL-2.0 WITH Linux-syscall-note) OR BSD-2-Clause)`. ztcl uses the header under BSD-2-Clause, and only this file of the kernel was read. The FUSE man page fuse(4) of man-pages 6.19 (https://man7.org/linux/man-pages/man4/fuse.4.html) describes the headers and the `FUSE_INIT` exchange.

**How ztcl uses it:** the layouts of the messages and the numbers of the protocol, in Zig structures of its own:

- The opcodes: `LOOKUP` 1, `FORGET` 2, `GETATTR` 3, `SETATTR` 4, `READLINK` 5, `SYMLINK` 6, `MKNOD` 8, `MKDIR` 9, `UNLINK` 10, `RMDIR` 11, `RENAME` 12, `LINK` 13, `OPEN` 14, `READ` 15, `WRITE` 16, `STATFS` 17, `RELEASE` 18, `FSYNC` 20, `SETXATTR` 21, `GETXATTR` 22, `LISTXATTR` 23, `REMOVEXATTR` 24, `FLUSH` 25, `INIT` 26, `OPENDIR` 27, `READDIR` 28, `RELEASEDIR` 29, `FSYNCDIR` 30, `ACCESS` 34, `CREATE` 35, `INTERRUPT` 36, `DESTROY` 38, `BATCH_FORGET` 42, `FALLOCATE` 43, `READDIRPLUS` 44, `RENAME2` 45, `LSEEK` 46, `SETUPMAPPING` 48, `REMOVEMAPPING` 49, `SYNCFS` 50.
- `fuse_in_header` (40 bytes): `len`, `opcode` (u32), `unique`, `nodeid` (u64), `uid`, `gid`, `pid` (u32), `total_extlen`, `padding` (u16). `fuse_out_header` (16 bytes): `len` (u32), `error` (i32, a negative errno), `unique` (u64). An error reply has no payload.
- `fuse_init_in`: `major`, `minor`, `max_readahead`, `flags`, `flags2`, `unused[11]` (u32). `fuse_init_out` (64 bytes): `major`, `minor`, `max_readahead`, `flags` (u32), `max_background`, `congestion_threshold` (u16), `max_write`, `time_gran` (u32), `max_pages`, `map_alignment` (u16), `flags2`, `max_stack_depth` (u32), `request_timeout` (u16), `unused[11]` (u16). The compat sizes of the reply: 8 bytes for a client before 7.5 and 24 bytes before 7.23.
- The flags of `INIT` used by ztcl: `ASYNC_READ` bit 0, `ATOMIC_O_TRUNC` 3, `BIG_WRITES` 5, `AUTO_INVAL_DATA` 12, `DO_READDIRPLUS` 13, `READDIRPLUS_AUTO` 14, `PARALLEL_DIROPS` 18, `MAX_PAGES` 22, `MAP_ALIGNMENT` 26, `INIT_EXT` 30 (the `flags2` field is present), and in `flags2` `HAS_INODE_DAX` bit 1 (bit 33 of the flags of 64 bits).
- `fuse_attr` (88 bytes): `ino`, `size`, `blocks`, `atime`, `mtime`, `ctime` (u64), `atimensec`, `mtimensec`, `ctimensec`, `mode`, `nlink`, `uid`, `gid`, `rdev`, `blksize`, `flags` (u32). `FUSE_ATTR_DAX` is bit 1 of `flags`.
- `fuse_entry_out` (128 bytes): `nodeid`, `generation`, `entry_valid`, `attr_valid` (u64), `entry_valid_nsec`, `attr_valid_nsec` (u32), `fuse_attr`. `fuse_attr_out` (104 bytes): `attr_valid` (u64), `attr_valid_nsec`, `dummy` (u32), `fuse_attr`.
- `fuse_getattr_in`: `getattr_flags`, `dummy` (u32), `fh` (u64). `fuse_setattr_in` (88 bytes): `valid`, `padding` (u32), `fh`, `size`, `lock_owner`, `atime`, `mtime`, `ctime` (u64), `atimensec`, `mtimensec`, `ctimensec`, `mode`, `unused4`, `uid`, `gid`, `unused5` (u32). The bits of `valid`: `MODE` 0, `UID` 1, `GID` 2, `SIZE` 3, `ATIME` 4, `MTIME` 5, `FH` 6, `ATIME_NOW` 7, `MTIME_NOW` 8, `LOCKOWNER` 9, `CTIME` 10.
- `fuse_open_in`: `flags`, `open_flags` (u32). `fuse_open_out`: `fh` (u64), `open_flags` (u32), `backing_id` (i32), `backing_id_64` (u64). `fuse_create_in`: `flags`, `mode`, `umask`, `open_flags` (u32); its reply is `fuse_entry_out` then `fuse_open_out`.
- `fuse_read_in` and `fuse_write_in` (40 bytes): `fh`, `offset` (u64), `size`, `read_flags` or `write_flags` (u32), `lock_owner` (u64), `flags`, `padding` (u32). The data of a write follows. `fuse_write_out`: `size`, `padding` (u32).
- `fuse_release_in`: `fh` (u64), `flags`, `release_flags` (u32), `lock_owner` (u64). `fuse_flush_in`: `fh` (u64), `unused`, `padding` (u32), `lock_owner` (u64). `fuse_fsync_in`: `fh` (u64), `fsync_flags`, `padding` (u32).
- `fuse_mkdir_in`: `mode`, `umask` (u32), then the name. `fuse_mknod_in`: `mode`, `rdev`, `umask`, `padding` (u32). `fuse_rename_in`: `newdir` (u64), then the old and the new name. `fuse_rename2_in`: `newdir` (u64), `flags`, `padding` (u32). `fuse_link_in`: `oldnodeid` (u64). A name ends with a NUL byte.
- `fuse_forget_in`: `nlookup` (u64). `fuse_batch_forget_in`: `count`, `dummy` (u32), then `count` times `fuse_forget_one`: `nodeid`, `nlookup` (u64). A forget has no reply.
- `fuse_dirent`: `ino`, `off` (u64), `namelen`, `type` (u32), then the name, each entry padded to 8 bytes. `fuse_direntplus`: `fuse_entry_out` then `fuse_dirent`, padded to 8 bytes.
- `fuse_kstatfs` (80 bytes): `blocks`, `bfree`, `bavail`, `files`, `ffree` (u64), `bsize`, `namelen`, `frsize`, `padding` (u32), `spare[6]` (u32).
- `fuse_access_in`: `mask`, `padding` (u32).
- DAX: `fuse_setupmapping_in` (40 bytes): `fh`, `foffset`, `len`, `flags`, `moffset` (u64), with `FLAG_WRITE` bit 0 and `FLAG_READ` bit 1. `fuse_removemapping_in`: `count` (u32), then `count` times `fuse_removemapping_one`: `moffset`, `len` (u64).
- The root is node 1. A read buffer of the client is at least 8,192 bytes.

go-fuse, `fuse/types.go`, `fuse/types_linux.go`, and `fuse/opcode.go` (https://github.com/hanwen/go-fuse, New BSD License) were read to check the opcode numbers and the flags of `INIT` against the header.
