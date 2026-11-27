# The ztcl unikernel (ztcl#471)

`thread::create -isolation vm` runs the thread in a guest of the hypervisor with no operating system: the ztcl runtime is the only program of the guest, on the virtual hardware. A Linux guest stays the choice for a thread that needs files, a network, or processes (`-guest linux`, not available yet).

```tcl
set t [thread::create -isolation vm -guest unikernel {thread::wait}]
thread::send $t {expr {6 * 7}}       ;# 42, computed in the guest
```

`-guest linux`, the default, is the Linux guest of ztcl#468 with the runner as its first process (`docs/dev/vm-turbo.md`). Both need the capability `vm`.

## ztcl is the kernel

The goal of the user (2026-11-27): JIT code runs in the kernel with no context switch, so Tcl in a vm thread runs faster than in a process thread on the same host. The design:

- One address space. The interpreter, the JIT code, and the drivers run at ring 0 of the guest. There is no system call: I/O is a direct call into the virtio driver of the image.
- The hypervisor is the security boundary, so rings in the guest add no protection. Defense in depth stays inside: W^X on the JIT pages through our page tables, an absent guard page under the stack, an absent page 0, and no path to the host except the frames of the protocol on vsock.
- No timer tick. The compute limit comes from the checks of the interpreter and of the JIT. The TSC deadline timer is a one-shot timer for the timed waits only.
- The FPU and SIMD state belong to the interpreter. No code saves or restores them: the interrupt handlers touch no vector register.
- The hot path has no interrupt: a wait polls the rings for 50 us before it halts the CPU. A notification is one write to the doorbell of the queue.
- Memory is an identity map in 2 MB pages, with 4 KiB pages only for the image, the guard pages, and the JIT window.

What is in the first version, and what is next:

| Part | Now | Next |
|---|---|---|
| JIT in the kernel | on, W^X pages in the JIT window | |
| Tick | none | |
| Rings | split rings, polled 50 us before a halt | packed rings; a batch of doorbell writes for each step of the pump |
| Pages | 2 MB pages for the heap | 1 GB pages; a prefault of the heap at boot, so no first-touch fault of the host comes later (a cost in host memory for each guest) |
| Start | a cold boot, 12 ms to 30 ms | a clone of a guest parked before `START` (#468) |

The sources are the virtio 1.2 specification of OASIS (4.2 virtio-mmio, 2.7 the split virtqueue, 5.10 the socket device), the Intel 64 and IA-32 Architectures Software Developer's Manual (volume 3: paging, the IDT, the local APIC), the Intel 82093AA I/O APIC datasheet, and our own monitor (`src/kvm.zig`, `src/vm/boot.zig`). No kernel source.

## The build

`zig build unikernel` writes `zig-out/bin/ztcl-unikernel`, an ELF image for x86-64 with no OS (`src/unikernel.zig`, `src/uk/`). It has the core of the interpreter, the JIT, the capability `thread`, and no modules. The image is built for the CPU of the runner, so the code in the guest is the code of the host. The runner looks for the image next to itself. The default build does not build it.

- `src/uk/link.ld`: the image at 2 MiB of guest physical memory.
- `src/unikernel.zig`: `_start` turns on SSE, and AVX and AVX-512 through XCR0 when the CPU has XSAVE, moves to the 8 MiB stack of the image, and calls `uk.start`.
- `src/uk/cpu.zig`: a GDT of the image (page 0, with the GDT of the monitor, is absent), the IDT, the PICs masked, the local APIC, and the I/O APIC line of the vsock device.
- `src/uk/paging.zig`: new page tables. Page 0 is absent, the code is read-only and executable, the read-only data is read-only, and each other page is not executable. The JIT window at 4 GiB is 1 GiB of 4 KiB pages: a page is absent, writable, or executable, never writable and executable (W^X).
- `src/uk/heap.zig`: one allocator over the memory above the image: size classes up to 4 KiB, page runs above that.
- `src/uk/vsock.zig`: the vsock driver on virtio-mmio. The guest listens on port 1024 for one stream.
- `src/uk/transport.zig`: the transport of `isoproto.zig` on that stream, and the entropy of the handshake (RDRAND).
- `src/uk/wait.zig`: the waits of `thread.zig`. With one CPU and one interpreter, a wait reads one frame of the host, or sleeps (`sti; hlt`) to the next interrupt.

The interpreter, the bytecode, the JIT, and the compute units are the same code as on the host. `thread.zig` has a mode `uk`, as it has `web`: no locks, waits that read frames, and no thread spawn.

## The protocol

The guest runs `isothread.childMain`: the child of an isolated thread of `docs/dev/isolation.md`, on vsock. The monitor puts a new bootstrap secret of 32 bytes on the command line (`ztcl.secret=`), and the handshake uses it as its salt, so only the host that started the guest can talk to it. The child gets the capabilities `thread`, `interp`, `clock`, and `event` of its creator, and no other: `thread::send` to the parent, `tsv`, the mutexes and the conditions through the broker of the parent, child interps, and the compute limit and the memory limit of `START`. The clock and the event loop come from the TSC (`uk/hosts.zig`): the monitor gives its rate and one time of the host at one count on the command line. A wait arms the TSC deadline timer of the local APIC for its slice.

A cancel reaches a script that computes: the interrupt of a frame stores zero in `mem_limit` of the interpreter, so its next safe point reads the frames that wait (`thread.safePoint`).

## The host

`src/isouk.zig` boots the image on `kvm.zig` with 1 CPU and twice the memory limit of the thread plus 32 MiB (at most 3 GiB), and connects to port 1024. The memory has `MAP_NORESERVE`, so a guest costs the pages that it touches. `isothread.zig` runs the bridge of the protocol on that socket, as for a child process. The end of the thread stops the guest.

## Tests

`tools/thread-tests.sh -p prelude/vm.tcl` runs the thread tests with each `thread::create` at the level vm (`tests/thread/prelude/vm.tcl`). `tools/unikernel-test.sh` runs the files that need no channels, sockets, or processes, and the workflow Unikernel runs it on KVM. The results on the host below:

| File | Result | Note |
|---|---|---|
| commands.tcl | 74 of 74 | |
| steps.tcl | 4 of 4 | the compute limit |
| sync.tcl | 39 of 39 | |
| tsv.tcl | 107 of 107 | |
| owned.tcl | 10 of 10 | |
| tpool.tcl | 33 of 33 | |
| limits.tcl | 18 of 19 | cap-5: the guest has no channel commands |
| collect.tcl | 4 of 5 | events-1 needs `socket`, as at the level process |
| totals.tcl | stops | the same stop as at the level process |
| churn.tcl | time limit | 12,800 cold starts; the snapshot clones of #468 are the fix |

Three faults that the tests found:

- A Zig struct with the default layout can put its fields in another order, so the rings of a virtqueue are `extern` structs.
- Page 0 is absent, and the GDT of the monitor is at 0x500, so the first interrupt gave a triple fault. The image has its own GDT.
- Each lost wakeup hung a guest with no error: a timer that fired before the `cli` of a sleep, a sent packet that came back while the driver waited for a free slot, and whole frames in the buffer of the `isoproto.Conn` while the vsock ring was empty.

## Numbers

Measured on 2026-11-27 on an x86-64 Linux host (Intel Skylake, 8 cores) with a load average of 13 to 16 from the builds of other work, so each number can change by a factor of 2. `create` is the best of 10 `thread::create` to the return, the memory is the growth of the resident memory of the process and its children for each of 8 threads, and the speed is the mean of 3 runs of `fib 24` and of a loop of 3,000,000 `incr` in the thread.

| Level | create | memory for each thread | fib 24 | loop 3,000,000 | round trip of a send |
|---|---|---|---|---|---|
| interp | 0.3 ms | 0.7 MB | 8.6 to 14.5 ms | 9.1 to 15.2 ms | 16.5 us |
| process | 4.6 to 5.0 ms | 5.3 MB | 13.9 to 14.2 ms | 10.5 to 15.3 ms | 63.5 us |
| vm | 19.7 to 21.3 ms | 11.3 MB | 9.0 to 9.4 ms | 8.8 to 9.9 ms | 119 to 139 us |

- The compute units are the same at each level: `fib 20` is 65,674 commands of `info cmdcount` in each.
- The JIT runs in the guest: the loop of 3,000,000 is 13 ms with the JIT and 116 ms with `ZTCL_JIT=off`, and the host gives 11 ms and 126 ms in the same run.
- In the guest the script runs at the speed of the host, within the noise of this host: no system call, no timer tick, and no other process shares the vCPU.
- A cold start of 12 ms to 30 ms is the setup of KVM (2 ms to 10 ms), the copy of the image and the devices (2 ms to 7 ms), and the connection (0.2 ms to 3 ms). The rest is the work of the monitor before `start`, not yet measured apart. The snapshot clones of #468 skip all of it.
- A send costs about two times the round trip of the level process: the frame passes vhost-vsock and an interrupt of the guest in each direction.
- Each guest uses about 11 MB of host memory, most of it the image and the heap pages that the interpreter touches. Not yet measured apart.

### Against the vm-turbo numbers

The scripts of `tools/vm-guest/bench-iso.tcl` (`docs/dev/vm-turbo.md`), best of 5 in ms, after the poll of the rings before a halt. The host had a load average of 45 to 50 from other work, so one run can differ from the next by a factor of 2. Start is `thread::create` to the answer of a first `thread::send`, best of 5, and the unikernel starts cold:

| Level | Start | fib 24 | loop 1,000,000 | strs 100,000 | dicts 100,000 |
|---|---|---|---|---|---|
| host | | 8.17 | 2.29 | 32.93 | 75.48 |
| interp | 0.94 | 7.70 | 2.75 | 51.30 | 73.14 |
| process | 12.30 | 8.57 | 2.79 | 25.19 | 58.38 |
| vm, unikernel | 16.87 | 12.01 | 3.12 | 17.11 | 90.25 |

In this run the unikernel is the fastest level for `strs` and slower for the others. A quiet host is needed to say whether it is faster than a process thread. The target stays: faster than a process thread on the same host.

## Next steps

1. A start from a snapshot clone of #468: a guest parked in `vsock.accept`, before `START`. The secret of a clone must be new, so the clone point is before the handshake and the monitor gives each clone its secret in guest memory or over a register.
2. The Windows Hypervisor Platform (`src/whp.zig`): the same image, with the vsock device of `vm/virtio/vsock.zig` in ztcl in place of vhost-vsock. The guest driver is the same.
3. arm64 KVM: an arm64 entry, page tables of the Armv8-A translation regime, the GIC in place of the APIC, and the same driver.
4. A VZ image: the arm64 image header of the Linux boot protocol (docs only), so Virtualization.framework loads the image as a kernel, and the virtio vsock device on PCI.
