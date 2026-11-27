# VM snapshots, clones, and Tcl in a VM (ztcl#468)

This file has the design and the measurements of the snapshots of `ztcl::vm` on KVM, the plan of `thread::create -isolation vm`, and the plan of a ztcl unikernel.

## 1. Snapshots on KVM

`src/vm/kvm_snapshot.zig` has the file format and the steps. A snapshot pauses the guest, completes the pending I/O of each vCPU (`KVM_RUN` with `immediate_exit`), stops vhost-vsock and reads the available index of its two queues (`VHOST_GET_VRING_BASE`), and writes:

- the VM: the two PICs and the IOAPIC (`KVM_GET_IRQCHIP`), the PIT (`KVM_GET_PIT2`), the clock (`KVM_GET_CLOCK`), and the UART registers;
- each virtio device: its registers and its queues;
- each vCPU: the registers, the special registers, XSAVE, XCRs, the local APIC, the events, the MP state, the debug registers, and the MSRs of `KVM_GET_MSR_INDEX_LIST`;
- the memory pages that are not all zero, at a 2 MB boundary of the file.

A restore has two parts:

1. `prepare`: the VM, the PIT, the IRQ chip, the devices (with a new vsock context ID), and the vCPUs. These ioctls are most of the time. `KVM_CREATE_VCPU` is 2.6 ms to 6 ms on the test host at a load of 9 to 10.
2. The fast part: one `mmap` of the memory of the file with `MAP_PRIVATE`, `KVM_SET_USER_MEMORY_REGION`, the state of the devices and of each vCPU, `KVM_SET_CLOCK`, the start of vhost at the saved indices, and the vsock event `VIRTIO_VSOCK_EVENT_TRANSPORT_RESET`.

A pool can do `prepare` before it needs a guest, so a guest from the pool costs only the fast part.

The guest pages come from the page cache of the file on their first touch, and the first write to a page copies it. userfaultfd is not used: on the test host `vm.unprivileged_userfaultfd` is 0 and `/dev/userfaultfd` is for root only, and the faults of KVM on guest memory are kernel faults.

### The guest after a restore

- vsock: the transport reset event makes the driver read the new context ID and close the connections of the snapshot. The socket of the agent that listens stays. A connection of the host that comes before the guest reads the new ID gets no answer, so the first connection after a restore tries again each 2 ms.
- The clock: kvm-clock goes on from the time of the snapshot. The agent request `RESUME` (feature bit 3) sets `CLOCK_REALTIME` to the time of the host.
- Entropy: `RESUME` also gives 32 random bytes of the host to `RNDADDENTROPY` and then calls `RNDRESEEDCRNG`, so the clones of one snapshot do not give the same random numbers. The test checks this.
- The generation ID device (`vmgenid.device=4K@0xd0010000:3`, the host side of `docs/vmgenid.md` of ztcl-guest-kernel): a read-only 16-byte ID in an MMIO window and ISA interrupt 3. No other device of the guest has interrupt 3 (the kernel has one UART, no i8042, and no CMOS clock). A boot gets a random ID. Each restore and each clone writes a new random ID and gives an edge on the interrupt after the state of the interrupt controllers is set, so the guest takes it at its first run. The guest kernel then reseeds its RNG (`add_vmfork_randomness`) and steps `CLOCK_REALTIME` with `KVM_HC_CLOCK_PAIRING`. The monitor marks a guest that read the ID, and the snapshot header keeps the mark (`genid`). The first `start` of a restore of such a guest sends no `RESUME` when the clocksource of the host is the TSC: KVM answers the hypercall only then. The two checks of the clones (different random numbers, the clock of the host) then test the device.

With the device, the guest of c303719, and the prefault, the same loop of 20 restores as in the prefault section (three runs, a load of 11 to 13): `start` (the resume and the transport reset, with no `RESUME`) is 0.79 ms to 0.92 ms best and 1.7 ms to 3.0 ms median, against 2.0 ms to 2.3 ms best with `RESUME`. The first `exec` after it is 3.3 ms to 3.9 ms best, against 2.2 ms to 2.3 ms, because the first connection to the agent now comes after the start: `start` and the first `exec` together are 4.1 ms to 4.8 ms best with the device and 4.3 ms to 4.6 ms with `RESUME`.

The pools (`create -image` and the vm threads) take their snapshot 100 ms after the agent or the runner answers, so the guest kernel of c303719 reports the free pages of its boot (50 ms after a free) first. A 128 MB guest of that kernel: 17.5 MB of snapshot memory at once, 16.1 MB to 16.2 MB after 100 ms (three runs each).

### Free page reporting

`src/vm/virtio/balloon.zig` is a virtio balloon (ID 5) that offers only `VIRTIO_BALLOON_F_PAGE_REPORTING`. The KVM monitor gives it the last device slot (`-balloon 1`, the default) and drops the host pages of each reported range with `MADV_DONTNEED`. A reported page of an anonymous mapping reads as zero after that, so it does not go in a snapshot. A reported page of a restored guest goes back to the page of the file.

## Measurements

The test host: i7-6700K (4 cores, 8 threads), Linux 7.2, a load of 9 to 11 from other work. Guest: 1 CPU, 64 MB, `tools/vm-guest/agent.cpio`. `tools/vm-guest/test-kvm-snapshot.tcl` prints these numbers (best and median of 10).

| Step | Best | Median |
|---|---|---|
| `snapshot` of a warm guest (20 MB of 64 MB written) | 7.9 ms | |
| `create -snapshot` into a prepared machine | 0.45 ms | 1.1 ms |
| The same with no prepared machine (`prepare` inline) | 12 ms | 15 ms |
| `start` of a restore to a ready agent (resume, the reset, the resume port 1027), before the prefault (below) | 2.8 ms | 4.3 ms |
| The first `exec` after that start | 2.0 ms | 2.7 ms |
| 4 clones of one file, restore of all four (2 prepared, 2 inline) | 37 ms | |

Of a restore into a prepared machine, the vCPU and VM state is about 0.2 ms. With 4 prepared machines (`ZTCL_VM_POOL=4`), 4 clones of one file restore in 1.0 ms in all.

Before port 1027, the start of a restore to a ready agent was 4 ms with one connection to the agent for `RESUME` on port 1024, and the agent forks a child for each connection there: the first `exec` of a warm guest with no snapshot is 1.0 ms to 3.0 ms on the same host. `MADV_POPULATE_READ` on the chunks with data at the restore made the restore 1.6 ms and did not make the start faster, so the restore does not do it. The agent now serves the resume on port 1027 in its first process with no fork. With it, the start to a ready agent is 2.8 ms best and 4.3 ms median. The rest was the first touches of the guest after the restore: each page that the guest kernel and the agent touch is a fault of the EPT.

### The prefault

A restore now gives the 2 MB chunks with data to vCPU 0 (`kvm.prefaultStart`). While the machine is paused, the parked vCPU 0 thread maps them in the EPT with `KVM_PRE_FAULT_MEMORY` (Linux 6.11 and later, `KVM_CAP_PRE_FAULT_MEMORY`), low addresses first, in calls of 256 KB, and stops at the resume. A host without the call gets `MADV_POPULATE_READ` of the host pages in its place. A guest of a pool waits for its start, so the prefault is off the path of `start`. KVM maps the pages for reads, so the first write of the guest to a page of the snapshot still faults and copies the page.

A loop of 20 restores of a 64 MB guest (the loop of `test-kvm-snapshot.tcl` with a 30 ms wait between `create -snapshot` and `start`, the 7.3.6 kernel of ztcl-guest-kernel c303719, a load of 10 to 15), three runs of each build:

| Build | Start to a ready agent, best | Median | First exec, best |
|---|---|---|---|
| no prefault | 2.15 to 2.32 ms | 3.6 to 4.1 ms | 2.3 to 2.6 ms |
| prefault | 1.43 to 1.48 ms | 2.2 to 4.2 ms | 1.9 to 2.1 ms |

The prefault of the 24 MB of chunks with data is 4.6 ms to 7.0 ms. Without it, the vCPU thread has about 320 faults of the host in a start (`getrusage` of the thread), and the start is 0.7 ms to 0.9 ms longer at best: about 2.5 us for each fault, with the fault-around of 16 pages of the page cache. The rest of the start is the vsock round trips: the wait for the transport reset (0.2 ms to 0.4 ms), the connection to port 1027 (0.3 ms to 0.8 ms), and the answer of the resume (about 0.6 ms). The target of 1 ms needs fewer round trips: see the generation ID device.

Without the cache of `kvm.probe`, each `create` opened and closed `/dev/kvm` and `/dev/vhost-vsock`, and a restore was 4 ms in place of 0.45 ms.

The balloon, 128 MB guest, 6 s after boot (the growth of the resident size of the process):

| Guest | Resident | Snapshot memory |
|---|---|---|
| no balloon | 31.7 MB | 16.4 MB |
| balloon, default report order (2 MB blocks) | 29.5 MB | 16.5 MB |
| balloon, `page_reporting.page_reporting_order=0` | 24.3 MB | 14.2 MB |
| 256 MB guest, after the guest wrote and deleted a 100 MB file in tmpfs: no balloon | 127.7 MB | 14.8 MB |
| the same with the balloon (229 MB reported) | 33.5 MB | 14.8 MB |

With the default order, the guest kernel reports no free page of its boot, only memory that it frees later.

### Tcl at each level

`tools/vm-guest/bench-iso.tcl`: the same scripts on the host and in a thread of each level, best of 5 in ms, and the best start of 5 threads (from `thread::create` to the answer of a first `thread::send`). The guest of the level vm is the 7.3.6 kernel of ztcl-guest-kernel run 45991768972 and `pack-iso.sh`, 256 MB, 1 vCPU. The host load was 12 on 8 threads, so the numbers vary by about 20%.

| Level | Start | fib 24 | loop 1,000,000 | strs 100,000 | dicts 100,000 |
|---|---|---|---|---|---|
| host | | 15.30 | 3.19 | 30.75 | 78.36 |
| interp | 0.27 | 8.48 | 2.80 | 25.85 | 69.97 |
| process | 9.87 | 8.64 | 2.52 | 26.13 | 64.24 |
| vm | 9.60 | 9.29 | 3.58 | 39.27 | 95.07 |

The start of a vm thread from a clone is as fast as the start of a process thread. The scripts run 10% to 50% slower in the guest. The guest kernel has no transparent huge pages and a periodic tick at 1000 Hz (the configuration of run 45991768972), so each page of the heap is a 4 KB page in the guest and each tick is an exit to the host. The questions to the guest kernel are in the plan below. Before the chunks of a snapshot with no data went to an anonymous mapping with THP on the host, `strs` was 62.75 ms and `dicts` 95.91 ms in the guest.

### The boot bytes of a pool

A pool of `create -image` keeps the kernel and the initramfs of its image once, in a memfd with the seals `F_SEAL_WRITE`, `F_SEAL_SHRINK`, `F_SEAL_GROW`, and `F_SEAL_SEAL`. Each guest of the pool maps it read only with `MAP_PRIVATE`, so the guests share its pages. Before, each guest of the pool had its own heap copy of the two. The seals keep the bytes that the image store checked: a mapping of the store file itself gets the changes of a later write to the file.

The runner with `ZTCL_VM_POOL=4` and the test image of the vm-guest workflow (a kernel of 2.8 MB, no initramfs), 20 s after the first `create -image`, three runs: the growth of `VmRSS` for each guest of the pool is 9.9 MB to 10.8 MB before (`RssAnon` 9.8 MB to 10.7 MB) and 7.8 MB to 9.2 MB after (`RssAnon` 7.0 MB to 8.3 MB, and 3.1 MB of `RssShmem` for the four mappings of one memfd).

## 2. Tcl in a VM: `thread::create -isolation vm`

The plan:

1. The guest program: a static `ztcl` runner (musl target, no libc start code beyond the Zig start) as `rdinit=/sbin/ztcl`. With `--vm-child` it mounts the minimal file systems, listens on vsock port 1026, and for each connection runs `isothread.childMain` on the socket: the same frames of `isoproto.zig` as a process-level thread, over vsock in place of a pipe.
2. The host: the bridge of `isothread.zig` gets a transport for vm: a guest from the snapshot pool (paused after the runner listens), `start`, one vsock connection, then the handshake, `START`, and `READY` as today.
3. The pool: one snapshot of the runner guest per configuration, `prepare`d machines ahead, and a restore for each `thread::create`. The start cost is the fast part of a restore and one vsock connection.
4. Compute: the JIT on (`START` has the flag), 2 MB pages for guest memory where the host gives them (the boot mapping asks for THP today), one vCPU thread pinned to a host CPU with `sched_setaffinity` when the host allows it, and a guest command line for compute (questions to the kernel agent: `nohz_full`, no preemption, no RCU callbacks on the CPU).

## 3. A ztcl unikernel (a later stage)

ztcl running on the virtual hardware with no Linux, for threads of pure compute:

- Boot: the 64-bit entry of `vm/boot.zig` with page tables for all guest memory (2 MB pages), one GDT, an IDT with handlers for faults only, no interrupts but the vsock queue.
- Memory: one bump region and the page allocator of ztcl on top of it. No virtual memory beyond the identity map.
- Devices: a virtio-mmio vsock driver (polled, or one interrupt) and a console for panics. No block device, no file system, no network.
- The runtime: `isothread.childMain` with a `sys` backend for this target: no files, no clock but kvm-clock (or the TSC), no processes, no threads. The capabilities of the child are the ones that need none of these.
- The JIT: the code pages are guest memory with execute rights in the page tables.
- The start: a snapshot of the unikernel after its init is a few hundred KB, so a clone touches few pages.
- Linux stays for a thread that needs files, the network, or `exec`.
