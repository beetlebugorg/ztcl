# virtio-fs with a DAX window for the shares of ztcl::vm

The plan of a virtio-fs device of ztcl for `ztcl::vm create -share`, on the KVM monitor (`kvm.zig`) and the monitor of the Windows Hypervisor Platform (`whp.zig`), with the DAX window: the guest maps the pages of a host file into its address space, with no copy and no message for each read or write. The source is the virtio specification 1.2 (section 5.11, the file system device, and 4.2.2, the shared memory regions of virtio-mmio) and the documentation of the FUSE protocol. No code of another implementation goes in.

## Why

The shares are 9p today (`vm/virtio/ninep.zig`, #385 and #460). Measured on WHP in a guest of 1 GB, with the folder cache of #475:

| Phase | 9p share | The RAM disk of the guest |
|---|---|---|
| create 2,000 small files | 1,346 ms | 15 ms |
| `ls -lR` of them | 323 ms | 9 ms |
| read 2,000 small files | 1,359 ms | 15 ms |
| write 256 MB | 2,694 ms | 918 ms |
| read 256 MB, cold | 2,753 ms | 44 ms |

- The 9p client of Linux sends one page (4 KiB) in each `Tread` and `Twrite`, at each msize from 16 KiB to 128 KiB, on Linux 6.12 and 7.3.6. A large read is 65,536 messages for 256 MB, so 9p stops near 105 MB/s at about 35 µs a message.
- With `cache=loose` the guest keeps the attributes and the names, and `ls -lR` is 22 ms. Its pages can be old after a change on the host, so it is not the default.

virtio-fs answers both. A FUSE `READ` or `WRITE` has up to `max_pages` pages (256 pages, 1 MiB), the replies give the guest a time to keep each name and each set of attributes, and with the DAX window a read or a write needs no message. The guest kernel of ztcl (Linux 7.3.6, ztcl-guest-kernel run 46020516028) has the virtio-fs driver with DAX built in, and the agent prefers `virtiofs` to `9p` when it mounts a tag.

## The device

`src/vm/virtio/fs.zig`, on the shared devices of `vm/virtio/mmio.zig`:

- The device ID 26.
- The configuration: the tag (36 bytes, `share<n>`), and `num_request_queues` 1.
- The queues: queue 0 is the high priority queue (`FORGET`, `INTERRUPT`), and queue 1 is the request queue.
- Shared memory region 0, the DAX window: the registers `SHMSel`, `SHMLenLow`, `SHMLenHigh`, `SHMBaseLow`, and `SHMBaseHigh` of virtio-mmio give its guest address and its size. The window lies above the RAM and the MMIO range of the devices, and it is 1 GiB by default. A share with no DAX has no region (a length of -1), and the driver then uses the queue for each read and write.
- A request is one chain: the readable part has the `fuse_in_header` and the arguments, and the writable part has room for the `fuse_out_header` and the answer. The device runs it at once on the thread of the vCPU, as the 9p device does, and puts the chain in the used ring.

## The FUSE server

`src/vm/virtio/fuse.zig`, with no system calls, on the same `Fs` of the backends as 9p (`vm/share_linux.zig`, `vm/share_windows.zig`), so each backend serves both devices:

- The node IDs: a table of node ID to path, with a count of lookups. `LOOKUP` adds one, `FORGET` and `BATCH_FORGET` take them off, and a node at 0 goes. The root is node 1. A rename moves the path of each node below it.
- The operations: `INIT`, `LOOKUP`, `FORGET`, `BATCH_FORGET`, `GETATTR`, `SETATTR`, `OPEN`, `CREATE`, `READ`, `WRITE`, `FLUSH`, `RELEASE`, `FSYNC`, `OPENDIR`, `READDIR`, `READDIRPLUS`, `RELEASEDIR`, `MKDIR`, `UNLINK`, `RMDIR`, `RENAME`, `RENAME2`, `STATFS`, `ACCESS`, `DESTROY`, and for DAX `SETUPMAPPING` and `REMOVEMAPPING`. Another opcode gives `ENOSYS`, and the guest stops using it.
- `INIT` gets the version of the guest, gives `max_write` of 1 MiB, `max_pages` of 256, `map_alignment` of the backend (16 for the 64 KiB of a view of Windows, 12 for KVM), and the flags of DAX and of `READDIRPLUS`.
- The times of the cache: each `LOOKUP` and `GETATTR` reply gives an entry time and an attribute time of 1 s by default, the same bound as the folder cache of #475. A share can give 0 for a guest that must see each change of the host at once.
- The errors are the errno values of Linux, as in 9p.

## The DAX window

`SETUPMAPPING` gives a node, a file handle or all ones, an offset in the file, a length, a read or write flag, and an offset in the window. The guest of Linux 7.3.6 maps by node, with an fh of all ones, in ranges of 2 MiB, so the server opens the path of the node for the setup. The monitor maps those pages of the file at that place of the window, and `REMOVEMAPPING` removes ranges. The guest maps the window into the page cache of the file, so a read is a load from memory. The guest uses DAX for each file with `FUSE_ATTR_DAX`, after `FUSE_HAS_INODE_DAX` in `flags2` of `INIT`, with no option of the mount.

- Windows (`src/vm/dax_windows.zig`): each mapping keeps a handle of its file (`ReOpenFile`), with a section of the file (`CreateFileMappingW`), a view of the range (`MapViewOfFile`), and the view at the guest address of the window plus the offset (`WHvMapGpaRange`), read-only or read-write. `WHvAdviseGpaRange` fills the map of the hypervisor for each new view: with no advice, a cold read of 64 MB ran at 308 MB/s, one fault for each page. The window needs no reserved range of the host, since the hypervisor maps each view at its own guest address. The views and the reads of the host share the memory of the file cache of Windows, so an edit of the host shows in the guest at once, and a write of the guest shows on the host at once.
- Windows truncates no file with a section, and a view does not grow with its file. So a mapping can lose its view and keep its range. The server drops the views of a node before a `SETATTR` of the size, an `OPEN` with `O_TRUNC`, an `UNLINK`, and a `RENAME`, and a thread of the window drops the views of a file 1 s after the last `RELEASE` of the guest. A memory exit of the guest in a mapping with no view, or past its view after the file grew, maps the view again at the size of the file now, and the vCPU runs its instruction again with no emulation.
- KVM: a memory slot of the window range (`KVM_SET_USER_MEMORY_REGION`) over an `mmap` of the file at the offset. The KVM agent wires this part.

## Coherence with the host

- The DAX pages are the pages of the host, so their content is the same at each moment.
- A file that the guest closed is free on the host after 1 s: the host can truncate it, rename over it, and delete it. While the guest has the file open, a truncate of the host fails, as it does for a program of Windows with the file mapped.
- The names and the attributes stay in the guest for the times of the replies (1 s). After that the guest asks again.
- Next step: the notification queue of virtio-fs (`VIRTIO_FS_F_NOTIFICATION`) and the `INVAL_INODE` and `INVAL_ENTRY` notices of FUSE, sent from `ztcl::watch` on the folder of the share, so a change of the host shows at once with long times. This needs the driver of the guest to read that queue, which the plan checks first.

## Steps

1. This plan.
2. The device and the FUSE server with no DAX, on WHP, with the benchmark of #475 against 9p. The tests of `fuse.zig` run each operation on a test `Fs` with no guest.
3. The DAX window on WHP, and the benchmark.
4. The DAX window on KVM (the KVM agent).
5. The notices of host changes.
6. virtio-fs as the default share on KVM and WHP when the guest has the driver, and 9p for an older guest. On WHP virtio-fs with DAX is the default, `ZTCL_VM_DAX=0` turns the window off, and `ZTCL_VM_SHARE=9p` gives 9p.

## The targets

The same benchmark as above, on WHP, Release build:

- read and write of 256 MB: at least 1,000 MB/s with no DAX (1 MiB messages), and the speed of memory with DAX, near the RAM disk of the guest.
- `ls -lR` and `find` of 2,000 files: within 2 times the RAM disk of the guest, from the times of the cache.
- create and delete of 2,000 files: below 9p, with the cost of NTFS as the floor.

## Step 2, measured

The device and the FUSE server with no DAX, on WHP, Release build, in a guest of 1 GB on Linux 7.3.6, two runs of each. `ztcl::vm create` made the shares virtio-fs with `ZTCL_VM_VIRTIOFS=1` then; step 6 made it the default.

| Phase | 9p share, with #475 | virtio-fs share | The RAM disk of the guest |
|---|---|---|---|
| create 2,000 small files | 1,294 to 1,323 ms | 1,197 to 1,204 ms | 16 ms |
| `ls -lR` of them | 330 to 333 ms | 23 to 34 ms | 8 to 9 ms |
| `find` of them | 325 to 327 ms | 16 to 22 ms | 7 to 8 ms |
| read 2,000 small files | 1,369 to 1,406 ms | 437 to 440 ms | 11 to 14 ms |
| write 256 MB | 2,621 to 2,785 ms | 929 to 930 ms | 858 to 909 ms |
| read 256 MB, cold | 2,622 to 2,806 ms | 221 to 253 ms | 45 to 57 ms |
| delete 2,000 files | 1,323 to 1,492 ms | 465 to 493 ms | 19 to 30 ms |

- A cold read of 256 MB runs at about 1,100 MB/s, in messages of 1 MiB, and a write of 256 MB is as fast as the RAM disk of the guest.
- `ls -lR` and `find` keep the names and the attributes for 1 s, so they are within 4 times the RAM disk of the guest.
- The run found a fault of the backend of Windows: `readdir` read the folder again from its start at each offset, so a guest that deletes names as it reads them (`rm -r`) skipped names. The 9p client of Linux reads a folder of 2,000 names in one message, and the FUSE client reads 4 KiB at a time. The backend now reads the names of a folder at offset 0 and gives later offsets from that list.

## Step 3, measured

The DAX window on WHP, with the same benchmark, two runs of each. Each share has a window of 1 GiB at 4 GiB of guest addresses.

| Phase | virtio-fs | virtio-fs with DAX | The RAM disk of the guest |
|---|---|---|---|
| create 2,000 small files | 1,167 to 1,234 ms | 1,169 to 1,180 ms | 20 to 38 ms |
| `ls -lR` of them | 22 to 23 ms | 182 to 198 ms | 8 to 11 ms |
| `find` of them | 17 to 19 ms | 17 to 18 ms | 6 to 7 ms |
| read 2,000 small files | 440 to 441 ms | 469 to 474 ms | 8 to 10 ms |
| write 256 MB | 924 to 932 ms | 118 to 135 ms | 812 to 950 ms |
| read 256 MB, cold | 220 to 222 ms | 187 to 218 ms | 47 to 72 ms |
| delete 2,000 files | 468 to 471 ms | 438 to 482 ms | 18 to 34 ms |

And `dd` of 64 MB with blocks of 1 MiB:

| Access | virtio-fs | virtio-fs with DAX |
|---|---|---|
| write | 364 MB/s | 2.2 GB/s |
| read, cold | 1.7 GB/s | 2.2 GB/s |
| read of pages the guest has mapped | 2.8 GB/s | 9.7 GB/s |

- A write to a file with DAX skips the page cache of the guest: its pages are in a window, and the guest sends a `WRITE` of 1 MiB. The RAM disk of the guest is slower here, since each new page of the guest RAM is a first touch for the hypervisor.
- DAX goes to a file of 0 bytes and to a file of 256 KiB or more (`fuse.dax_min`). A small file costs less to read with `READ` than with a mapping of its own: with DAX for each file, the read of 2,000 small files took 635 to 649 ms.
- `ls -lR` after the create pays once for that rule: the new files had DAX at 0 bytes and lose it at 33 bytes, so the guest drops each inode once and looks it up again. With DAX only at 256 KiB or more, `ls -lR` is 23 to 29 ms, and a write of 256 MB is 919 to 923 ms: a new file then writes through the page cache of the guest. The rule keeps DAX at 0 bytes.
- The checks of the content and of the coherence pass with and without DAX: the bytes of a write of the guest on the host, an edit and an append of the host in a file that the guest has read, a truncate on both sides, and a delete on both sides.

## Questions

1. The size of the window. Default: 1 GiB of guest addresses, with no memory of the host until a mapping. The guest picks the ranges.
2. The times of the cache. Default: 1 s, as the folder cache of the backend of Windows.
3. 9p after virtio-fs. Default: 9p stays for a guest with no virtio-fs driver.
