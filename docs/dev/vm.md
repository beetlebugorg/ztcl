# Plan: microVMs on the native hypervisor (`ztcl::vm`, ztcl#203)

A script with the `vm` capability starts a small Linux guest on the hypervisor of the host, runs programs in it, and talks to it over vsock. The guest has its own kernel, so a program in it is apart from the host, with only the folders and the ports that the script gives it. dockyard (beetlebugorg/dockyard#13) builds its containers on this module, and the confidential VMs of ztcl#180 use the same core.

The rule of the issue: native hypervisor APIs only. That is Virtualization.framework on macOS, the KVM ioctls on Linux with our own virtio devices, and the Host Compute Service on Windows. ztcl links no QEMU, no libkrun, and no other VMM.

ztcl is BSD-2-Clause and the work stays clean-room: it reads the virtio specification, Apple's documentation, Microsoft's documentation, man pages, and papers, and no source code of GPL or other copyleft projects (Linux beyond its configuration, QEMU, copyleft VMMs). The guest kernel and BusyBox are GPL binary inputs: the build configures them and copies no code from them into ztcl.

## The spike (macOS)

`tools/vm-guest` has the spike. It boots a guest, echoes a line over vsock, and shares one folder with virtio-fs.

- The guest: Linux 6.12.10 from `tinyconfig` with the options of `kernel.fragment` (virtio PCI, the virtio console, vsock, virtio-fs, all built in), and a static BusyBox 1.37.0. An arm64 runner builds both (`build.sh`, the workflow `vm-guest.yml`): the kernel `Image` is 4.4 MB and BusyBox is 2.2 MB. `pack.sh` adds the echo agent (`agent.zig`, built by Zig for `aarch64-linux-musl`) and `init`, and makes a 1.2 MB initramfs on any host.
- The host: `src/vz.zig` calls Virtualization.framework through the Objective-C runtime, as the AppKit backend of ztk does. The runtime and the framework load with `dlopen`, as `ztcl::mac` loads CoreFoundation, so the build needs no SDK. A completion handler is a block that `vz.zig` makes on the stack from a Zig function; the framework copies it before the call returns. Each call to the machine runs on its own serial dispatch queue (`dispatch_sync_f`), and the main thread waits on a dispatch semaphore.
- `spike.sh` builds `spike.zig`, signs it ad hoc with `codesign --sign - --entitlements vz.entitlements`, and runs it.

The result on an M1 Mac with macOS 27: the init of the guest prints its ready line 213 ms after `startWithCompletionHandler:`, with 2 CPUs and 256 MB. The echo over vsock port 1024 gives the line back, the guest reads the file of the host in the share and writes a file there that the host sees, and `stopWithCompletionHandler:` ends the machine.

Without the entitlement, `validateWithError:` fails with "The process doesn’t have the “com.apple.security.virtualization” entitlement." `ztcl::vm create` turns that into the error code `ZTCL VM ENTITLEMENT`.

## Start time (macOS)

The goal of ztcl#203: about 20 ms from `ztcl::vm start` to the answer of the guest agent, as an ideal. `spike bench` times each phase of a start, `spike snap` a restore of a saved state, and `spike warm` a resume of a paused guest. Each number is the best of 10 runs on the M1 Mac, with 1 CPU, 64 MB, no console device, and the agent as the first process (`rdinit=/sbin/agent quiet`) unless the row says otherwise. Each column is its own best, so a total can be less than the sum of its row.

| Guest | `validateWithError:` | `initWithConfiguration:` | VZ start | start to connect | connect to answer | start to answer | guest: boot to agent |
|---|---|---|---|---|---|---|---|
| 250 Hz kernel, 256 MB | 0.16 | 0.06 | 86.7 | 35.4 | 0.05 | 125.9 | 29.5 |
| 250 Hz kernel | 0.16 | 0.06 | 86.2 | 33.9 | 0.04 | 125.1 | 28.4 |
| 250 Hz kernel, no entropy device | 0.16 | 0.07 | 85.6 | 26.5 | 0.06 | 112.2 | 20.9 |
| 1000 Hz kernel | 0.15 | 0.06 | 85.9 | 13.3 | 0.06 | 100.9 | 9.9 |
| 1000 Hz kernel, no entropy device | 0.15 | 0.06 | 86.6 | 12.3 | 0.06 | 99.4 | 8.5 |
| the same, BusyBox and `init` (a shell script) start the agent | 0.15 | 0.06 | 87.5 | 22.4 | 0.05 | 110.0 | 18.9 |
| the same, restore of a saved state, then resume | 0.15 | 0.06 | 120.1 | 0.33 | 0.07 | 120.5 | |
| the same, resume of a booted, paused guest | | | | | | 0.24 | |

The times are in ms. "VZ start" is `startWithCompletionHandler:` to its handler, or `restoreMachineStateFromURL:` and `resumeWithCompletionHandler:` for the restore. "start to connect" is the handler to the first connection that the agent accepts: the host tries again at once after each refused connection. "guest: boot to agent" is the boot clock of the guest (`CLOCK_BOOTTIME`) when `main` of the agent runs.

What the numbers show:

- The framework costs about 86 ms for each start, the same at 64 MB and at 1,024 MB. Each machine runs in a new process of the XPC service `com.apple.Virtualization.VirtualMachine`, and the start launches it. ztcl cannot make that part faster.
- The kernel of `tinyconfig` runs at 250 Hz. The probe of each virtio PCI device sleeps a few ticks, and at 4 ms a tick the sleeps were 21 ms of the boot (`initcall_debug`, read over vsock with `spike dmesg`). At 1000 Hz the boot to the agent is 8.5 ms.
- The entropy device adds 1 ms to 8 ms to the boot, for the probe of its driver. A guest that needs no random numbers at boot can leave it out, and the agent can read `/dev/hwrng` later.
- The agent as the first process saves 10 ms over BusyBox and a shell script.
- The memory size, the gzip of a 6 KB initramfs, and `lpj=` make no difference in the runs. The start does not grow with the memory, so the framework maps it on demand, and the kernel already skips the calibration of its delay loop (the log says "Calibrating delay loop (skipped)").
- A restore of a saved state (2.8 MB at 64 MB) costs 120 ms, more than a fresh boot of this guest. After a restore, the first vsock connection closes at once, because the device resets its transport. The host connects again.
- A resume of a guest that booted and paused before costs 0.24 ms to the answer of the agent. This is the only form that meets the goal of 20 ms.

The levers of ztcl#203 that the framework rules out: the kernel `Image` of arm64 is already uncompressed (the framework accepts no other form), the virtio devices of the framework are on PCI only (no virtio-mmio), and the scan of the PCI bus costs 0.6 ms.

The plan for the start time on macOS:

1. The guest kernel at 1000 Hz, with no entropy device by default, and the agent as the first process. A fresh start is then about 100 ms, of which 86 ms is the framework.
2. A warm guest: `create -warm 1` boots the guest at once and pauses it when the agent answers, and `start` resumes it. `start` is then under 1 ms. A paused guest keeps its process and the memory that it touched.
3. A pool of warm guests in dockyard, for a terminal that opens at once.
4. A benchmark in CI, when a runner can run a guest (see "Tests"), with a gate on the start to answer, as for the frame times of ztk.

## Commands

```tcl
set vm [ztcl::vm create ?-cpus N? ?-memory MB? ?-kernel F? ?-initrd F? ?-cmdline TEXT? \
        ?-disk F ...? ?-share {host guest ?rw?} ...?]
ztcl::vm start $vm
ztcl::vm exec $vm ?-cwd dir? ?-env {NAME value ...}? ?-timeout ms? program ?arg ...?
set chan [ztcl::vm vsock $vm port]
set con [ztcl::vm console $vm]
ztcl::vm status $vm              ;# created | starting | running | stopped | {error TEXT}
ztcl::vm stop $vm ?-force?
ztcl::vm delete $vm
```

- `create` checks the configuration and gives a handle. The default is 1 CPU, 256 MB, and the base image of the guest (see "The guest image"). `-kernel` and `-initrd` give another kernel and initramfs.
- `-disk` adds a virtio block device, in the order of the options (`/dev/vda`, `/dev/vdb`, ...). A disk is read-only unless its file name is followed by `rw`, as in `-disk {data.img rw}`.
- `-share {host guest}` gives the folder `host` to the guest, mounted at `guest` by the agent. A share is read-only unless the third word is `rw`.
- `start` waits for the framework to say that the guest runs. `vsock` tries a refused connection again at once until its timeout, so the first connection waits for the program of the guest. With the agent of step 4, `start` waits for the agent.
- `exec` runs a program in the guest through the agent and gives its standard output, as `exec` does on the host. A program that ends with a code other than 0, or that writes to its standard error, gives an error with the code `CHILDSTATUS` or the text, as with `exec`. There is no shell, as with `exec` on the host.
- `vsock` connects to a port of the guest and gives a channel, readable and writable, in binary translation. `fileevent` and `fconfigure -blocking 0` work on it as on a socket.
- `console` gives the console of the guest (`hvc0`) as a channel.
- `stop` asks the guest to power off and waits up to 5 seconds, then stops it at once. `-force` stops it at once.
- `delete` stops the machine and frees it. The end of the interpreter deletes each machine.

## The `vm` capability and the limits

`ztcl::vm` exists only with the new capability `vm` (bit 262144). A child interp never gets it, so the limits count the guests of one interpreter. The channels of `vsock` and `console` also need `channels`.

- Each path (`-kernel`, `-initrd`, `-disk`, `-share`) also needs `file`, and each is a path below the root folder of the file jail (`fsroot.zig`). ztcl opens the path in the jail and gives the framework the final path of the open descriptor (`F_GETPATH` on macOS), so a link that a script makes cannot point the guest outside the root folder. The framework opens the path again, so a script that swaps the file between the two opens can give the guest another file below the root folder, and none outside it. The attachment of the framework for an open descriptor (`VZDiskBlockDeviceStorageDeviceAttachment`) is for block devices, so a disk image goes by its path.
- The guest is apart from the host: it reaches only its shares, its disks, and the vsock ports that the host connects to. The guest has no network in the first steps.
- The embedder sets the limits in `Interp.vm_host`: the most CPUs and memory of one guest, and the most guests at once. The default is 4 CPUs, 2,048 MB, and 4 guests.
- The memory of a guest is outside the memory limit of the interpreter, as the memory of a process of `exec` is.

WARNING: a share with `rw` lets the guest change the files of the host in that folder. A `rw` disk lets the guest change the file of the disk.

## macOS

- Virtualization.framework, macOS 12 and later (for `stopWithCompletionHandler:` and virtio-fs). The direct boot of a Linux kernel (`VZLinuxBootLoader`) needs an uncompressed arm64 `Image`. On an Intel Mac it needs an x86-64 `bzImage`, and the guest image has both.
- The entitlement `com.apple.security.virtualization`. The Zig signer of `macho.zig` writes an ad hoc signature with a code directory only. It needs two more blobs for the entitlements: the XML plist (magic `0xfade7171`, slot 5) and its DER form (magic `0xfade7172`, slot 7), with the hashes of both in the special slots of the code directory. A ztcl that a user builds from the CLI then runs VMs with no step on a Mac. The release builds get the entitlement from the same code.
- The queue: each machine has its own serial queue. The completion handlers and the delegate of the machine (`VZVirtualMachineDelegate`, for a guest that stops by itself) post to the event loop of the interpreter, with the same wake path as a socket.
- vsock: the host connects to a port of the guest (`connectToPort:completionHandler:`). The connection object owns the descriptor, so the channel keeps the object until `close`. A listener on the host for a port of the guest (`VZVirtioSocketListener`) comes with `ztcl::vm vsock $vm -listen port`, in a later step.

## The guest agent

The agent is a static Zig program in the guest, `/sbin/ztvm-agent`, started by init. It listens on vsock port 1024. Each connection has one request, framed as a 4-byte length (little-endian) and a JSON object:

```
{"op": "exec", "argv": [...], "env": {...}, "cwd": "...", "stdin": "<base64>"}
{"op": "mount", "tag": "share0", "path": "/work", "rw": false}
{"op": "poweroff"}
```

The answer of `exec` is a series of frames: `{"out": "<base64>"}`, `{"err": "<base64>"}`, and last `{"exit": code}` or `{"signal": "NAME"}`. The spike agent only echoes; the full agent replaces it.

## The guest image

The spike builds its own guest. The proper image is the tiny kernel and BusyBox base that dockyard#13 builds like Printdeck OS (Buildroot), and the signed tools disk from the releases. `ztcl::vm create` with no `-kernel` uses that base image: ztcl downloads it on the first use into its cache, and checks its SHA-256 and its signature. The kernel needs the options of `tools/vm-guest/kernel.fragment` built in.

## Linux: KVM

`src/kvm.zig` is a monitor of its own on the KVM ioctls of `/dev/kvm`, for x86-64 hosts. arm64 Linux comes later and gives `ZTCL VM UNAVAILABLE` until then.

- The boot: one anonymous mapping with `MAP_NORESERVE` is the guest memory, so the host gives a page only when the guest touches it. The monitor loads a bzImage (its protected-mode part at 1 MB) or an uncompressed ELF `vmlinux` (each segment at its physical address), writes the boot parameters, the command line, a GDT, page tables with an identity map of 4 GB, and an MP table, and starts the boot vCPU in 64-bit mode at the 64-bit entry point of the boot protocol. The MP table lists the CPUs and the I/O APIC, so `-cpus 2` and more work with no ACPI.
- KVM has the interrupt controllers (`KVM_CREATE_IRQCHIP`) and the PIT. Each vCPU is a host thread.
- The devices are on virtio-mmio, given to the guest on its command line (`virtio_mmio.device=`): the console (`hvc0`), vsock, the disks, and the entropy device with `-entropy 1`. An 8250 UART at 0x3f8 sends the output of `console=ttyS0` to the console channel too; it exits to the monitor for each byte and is slow (about 1.4 s for the log of a boot), so it is for debugging.
- vsock is vhost-vsock of the host kernel (`/dev/vhost-vsock`). An ioeventfd on the notify register kicks vhost and an irqfd gives its interrupts to the guest, so the data of a connection does not pass through ztcl. The host side is a normal `AF_VSOCK` socket to the context ID of the guest, which the monitor picks at random among the free ones.
- `create -image NAME` boots a release of the image store (`loadImage` of `src/microvm.zig`): the kernel and the initramfs in memory, each checked against its SHA-256 on those bytes, and the disks of the release first and read-only, so `/dev/vda` is the root that the command line of the manifest gives to dm-verity (`dm-mod.create=`). `tools/vm-guest/test-kvm-image.sh` boots the test release in the job `manifest-test` of `vm-guest.yml` and checks that a change of one byte of the root disk in the store gives a guest with no agent.
- A disk is a descriptor that ztcl opens in the file jail. The vCPU thread runs each request with `pread` and `pwrite`. A read-only disk has `VIRTIO_BLK_F_RO`, and the monitor refuses its writes.
- The monitor adds `reboot=k panic=-1` to the command line. The guest stops itself with a reboot (the reset of the keyboard controller at port 0x64) or a panic. There is no ACPI, so a power-off of the guest halts it and does not stop it: `stop` without `-force` stops the guest at once on Linux until the agent has `poweroff`.
- A pause sets `immediate_exit` of each vCPU and sends its thread a signal (40, with an empty handler), so `KVM_RUN` returns, and the thread waits on a futex. A warm guest (`-warm 1`) is a booted guest in this pause.
- A share is the 9p device of ztcl (virtio ID 9, `src/vm/virtio/ninep.zig`) with a server of 9P2000.L, and the guest mounts it with `trans=virtio,version=9p2000.L`. `-share {host guest ?rw?}` gives the tag `share0`, `share1`, ... in the order of the options, as on macOS: the agent mounts `share0` at `/mnt/share` at boot, and `ztcl::vm mount` mounts the others. ztcl opens the root folder of the share in the file jail with `O_PATH`, and `src/vm/share_linux.zig` opens each path of the guest from it with `openat2`, `RESOLVE_BENEATH`, and `RESOLVE_NO_SYMLINKS`. The server keeps the path of each fid and resolves `..` with the names of that path, so no path leaves the folder, and the host follows no symbolic link of the guest: the guest resolves them itself. A read-only share refuses each change with `EROFS`. Each lock of the guest succeeds, and extended attributes give `EOPNOTSUPP`. virtio-fs, with a FUSE server in Zig, can come later with the same Tcl API.
- The user needs read and write access to `/dev/kvm` and `/dev/vhost-vsock` (the `kvm` group). Without it, `create` gives `ZTCL VM UNAVAILABLE` with the fix in the text.

The x86-64 guest kernel has the options of `kernel.fragment` and `kernel-x86_64.fragment`: virtio-mmio with the devices of the command line, no PCI, no ACPI, the MP table, the paravirtual clock of KVM, the 8250 console, LZ4, 9P, and dm-verity with `dm-mod.create=` for the signed images of ztcl#312. The x86-64 job of `vm-guest.yml` builds it (the artifact `vm-guest-x86_64`: a 2.6 MB bzImage and a 14 MB `vmlinux`) and runs `tools/vm-guest/test-kvm.sh` with the agent of the spike.

### Start time (Linux)

`test-kvm.tcl` times each phase, best of 10, with 1 CPU, 64 MB, the agent as the first process (`rdinit=/sbin/agent quiet`), on an x86-64 Linux host (Intel Skylake, 4 GHz, 8 cores) that ran the builds of other work at the same time. The load of the host changes the numbers by a factor of 2 to 3:

| Kernel | `start` | start to answer | guest: boot to agent | warm start to answer |
|---|---|---|---|---|
| bzImage (LZ4), the host busy | 12.46 | 65.61 | 25.54 | 0.124 |
| bzImage (LZ4), the host less busy | 4.42 | 24.78 | 11.55 | 0.136 |
| ELF `vmlinux`, the host busy | 10.94 | 59.85 | 23.21 | 0.146 |

The times are in ms. `start` makes the VM, maps the memory, loads the kernel, makes the devices and the vCPUs, and starts the threads. "start to answer" is `start` to the 16 bytes of the agent over vsock.

What the numbers show:

- The setup of KVM (the VM, the interrupt controllers, the PIT, the memory) is 5 ms to 8 ms of `start`. The copy of the kernel into the guest memory is 1 ms for the bzImage and 5 ms to 6 ms for the `vmlinux` of 14 MB.
- The ELF `vmlinux` saves the decompression of the bzImage, about 5 ms.
- In the boot of the guest, the probe of the console device is 6 ms and the probe of vsock 3.4 ms (`initcall_debug`). These are the next levers, with the copy of the kernel (a copy-on-write mapping of the file instead).
- A warm start is 0.12 ms to the answer of the agent: the threads leave the futex and enter `KVM_RUN` again.

Two cuts of the host (2026-11-27): the guest memory starts on a 2 MB boundary with `MADV_HUGEPAGE`, so the first write to each 2 MB of the guest is one fault of the host, and each vCPU gets bit 0 (fast strings) of `IA32_MISC_ENABLE`, which KVM gives clear. The kernel is the 6.12.119 build of beetlebugorg/ztcl-guest-kernel (the artifact `guest-kernel-x86_64`), best of 10, the host with a load average of 6:

| Kernel | Monitor | `start` | start to answer | guest: boot to agent |
|---|---|---|---|---|
| bzImage | before | 6.30 to 6.36 | 31.80 to 32.35 | 8.05 to 8.47 |
| bzImage | with the cuts | 4.38 to 4.41 | 16.32 to 18.54 | 4.19 to 4.25 |
| ELF `vmlinux` | before | 5.26 to 5.36 | 13.73 to 13.79 | 4.28 to 4.29 |
| ELF `vmlinux` | with the cuts | 5.34 to 5.36 | 13.66 to 14.51 | 4.27 to 4.30 |

The cuts halve the time to the answer for the bzImage, whose decompression in the guest writes the full kernel to new memory. The `vmlinux` has no decompression, and its time does not change.

Exits of the devices (2026-11-27, the 6.12.119 bzImage, a host with a load average of 5 to 10). A trace of each access of the guest to a device window gave these counts for one start to the answer:

- The accesses come about 8 us apart during a probe, so one exit to this process and back costs about 8 us.
- The console has 44 accesses from the first one to DRIVER_OK, in about 0.9 ms. vsock has 57, in about 1.7 ms. The rest of each probe is work in the guest.
- After DRIVER_OK, vsock has one read of InterruptStatus and one write of InterruptACK for each interrupt: about 16 interrupts for each guest of `test-kvm.tcl`.

The write to InterruptACK of vsock now goes to an ioeventfd with no reader, since the register of an external device has no state. This cut the exits of vsock from a mean of 89 to 73 for each guest. The read of InterruptStatus stays an exit: KVM has no ioeventfd for a read. The change in the time to the answer is less than the noise of this host.

Two other changes were measured and left out. The medians of 6 runs of a bench in the guest (a read of a 32 MB disk with `dd`, a `cat` of a 32 MB file of a share, and an `ls -lR` of 500 files of a share):

- An ioeventfd on QueueNotify of the console, the disks, and the entropy device, with an I/O thread that runs the requests. The disk reads did not change (29.6 and 30.4 ms with `bs=4k`). With 9p on the I/O thread too, the `cat` and the `ls -lR` were 25 to 47% slower in each of 3 runs. Each request of 9p waits for its answer, and the wake of the I/O thread costs more than the exit to the vCPU thread.
- An irqfd in place of `KVM_IRQ_LINE` for these devices. The `cat` and the `ls -lR` were 11 to 18% slower, and in one run of 6 the agent did not answer. These tests did not find the cause. A possible cause is a wake of a kernel thread for each interrupt on an ISA line.

## The shared virtio devices

The monitors that give the guest its devices on virtio-mmio (KVM, and the Windows Hypervisor Platform) share the transport and the devices that run in ztcl. They are in `src/vm/virtio/`, with no system calls:

- `queue.zig`: `Mem` (the guest memory as one host range from guest address 0, with a bounds check of each address and length of the guest), `Queue` (the split virtqueue), and `Chain` (a chain of descriptors as host slices).
- `mmio.zig`: `Device`, the registers of the virtio-mmio transport, version 2, and the devices: `Device.console`, `Device.blk`, `Device.rng`, `Device.vsock`, and `Device.external` for a device that the hypervisor runs (vhost-vsock on KVM).
- `vsock.zig`: `Vsock`, the vsock device of section 5.10 of virtio 1.2 in ztcl, for a monitor with no vsock of its host kernel.
- `ninep.zig`: `Server`, the 9p device and its server of 9P2000.L, on an `Fs` of the backend.

A backend implements this interface:

| Part | What the backend does |
|---|---|
| `Host` | Gives `mem` and `interrupt(ctx, irq)`, an edge on the interrupt line of the device (`KVM_IRQ_LINE` 1 then 0 on KVM). |
| The window | Gives device n the 4 KB window at 0xd0000000 + 0x1000 * n and its interrupt, and lists each one on the command line of the guest (`virtio_mmio.device=4K@ADDR:IRQ`). |
| An access | Calls `Device.read(off, out)` or `Device.write(&host, off, data)` for each MMIO exit of a vCPU in the window, with `Device.lock` held. A write to QueueNotify runs the requests of that queue at once, on the thread of the vCPU. |
| `Console` | Gives `write(ctx, bytes)` for the output of the guest and `rx_ready(ctx)`, which the device calls when the driver adds receive buffers. The backend calls `Console.push(dev, &host, bytes)` with `Device.lock` held for the input; it gives the count of bytes that went in. |
| `Disk` | Gives `size`, `read_only`, and `read`, `write`, and `flush` at a byte offset. Each read or write is in full or gives false. |
| `rng` | Gives a function that fills a buffer with random bytes and gives the count. |
| `External` | Gives the virtio ID and the hooks `driverOk(ctx, dev)` and `reset(ctx, dev)`. The transport keeps the registers, and InterruptStatus always reads 1 (the device raises its own interrupts). |
| `Fs` | For `Device.ninep`: the calls on the files of a share (`stat`, `open`, `create`, `read`, `write`, `readdir`, `mkdir`, `unlink`, `rename`, `setattr`, and the others of `Fs.VTable`), each with a path below the root folder of the share and a Linux errno as its result. `src/vm/share_linux.zig` is the `Fs` of Linux. |
| `Vsock` | Gives a `Sink`: `data(ctx, conn, bytes)` for the bytes of the guest on a stream, and `event(ctx, conn, e)` for `connected`, `refused`, and `closed`. The backend calls `connect(dev, &host, port)`, `send`, and `close` with `Device.lock` held; `send` gives the count of bytes that went in. |

vsock on KVM is vhost-vsock, an external device. A monitor without vhost (WHP) uses `Vsock`, with the host as CID 2. A stream starts with a `connect` of the host to a port of the guest. The host sends no more than the credit of the guest (its `buf_alloc` less the bytes in flight), and gives each byte of the guest to the sink at once, so its own credit is its `fwd_cnt`. A REQUEST of the guest gets RST until the host can listen. KVM can use `Vsock` in the place of vhost-vsock.

## Windows: the Windows Hypervisor Platform

The Windows part runs on the Windows Hypervisor Platform (`WinHvPlatform.dll`), with our own devices, the same shape as the KVM part. The user chose it on 2026-11-26.

- The Host Compute Service needs the feature Virtual Machine Platform and its service `vmcompute`. On the Windows 11 Home host of the port the feature is off: `HcsEnumerateComputeSystems` gives `0x80370114`, and turning the feature on needs an administrator and a restart. The Windows Hypervisor Platform needs no change there: a process of a user, with no elevation, creates and sets up a partition, because the hypervisor of Virtualization-based Security already runs.
- The host side: one partition for each guest, its memory from `VirtualAlloc` mapped at guest address 0 (`WHvMapGpaRange`), one virtual processor for each CPU with a host thread that calls `WHvRunVirtualProcessor`, and the local APIC of the hypervisor (xAPIC emulation). The kernel boots with the 64-bit boot protocol of Linux, as `tools/vm-guest/whp-spike.zig` does.
- The devices are our own, on virtio-mmio from the command line of the kernel (`virtio_mmio.device=`): the console, entropy, block, and vsock. The KVM part writes them in files of no hypervisor, with an interface for each backend (guest memory, interrupt injection, MMIO dispatch), and the Windows part uses that interface. A guest interrupt is `WHvRequestInterrupt` to the local APIC. A virtio-mmio device needs an interrupt line, so the host also needs a small I/O APIC or MSI. The vsock of the host side is a connection of the device to a host channel, with no Hyper-V socket and no key in the registry.
- A share is virtio-9p first, as on Linux (question 4), with the 9p server of the KVM part in the file jail.
- The bootstrap secret of `docs/dev/isolation.md` goes on the command line of the kernel.
- HCS stays a later choice for a host where Virtual Machine Platform is on: it gives Hyper-V sockets and Plan 9 shares of the system. `HvSocketConfig` of its JSON schema gives a table of services with no key in the registry. Port 1024 of vsock is the service GUID `00000400-FACB-11E6-BD58-64006A7986D3`.

### The spike (Windows)

`tools/vm-guest/whp-spike.zig` boots the x86-64 guest of `build.sh` (the artifact `vm-guest-x86_64` of the workflow VM guest) in a partition and prints its serial console until the ready line of the init of the guest.

```sh
zig build-exe -OReleaseSafe tools/vm-guest/whp-spike.zig
whp-spike out/bzImage out/busybox tools/vm-guest/init 256
```

- The boot: the protected-mode part of the bzImage at 1 MiB, a zero page with the setup header of the file, the command line, and an e820 table, page tables that map 1 GiB with 2 MiB pages, a GDT with the segments 0x10 and 0x18, a busy TSS in TR, and the CPU in long mode at the 64-bit entry with RSI at the zero page. `WHV_REGISTER_VALUE` is 16-byte aligned, and an array of 8-byte alignment fails inside `WHvSetVirtualProcessorRegisters`.
- The guest has no ACPI, no PCI, and no PIT, so the command line gives `acpi=off pci=off` and the rate of the TSC (`tsc_early_khz`, which the spike measures on the host). The kernel finds the TSC deadline timer of the local APIC.
- The interrupts: an MP table of version 1.4 at 0xf0000 gives the kernel the CPU, the ISA bus, and an I/O APIC at 0xfec00000 with the ISA IRQs on its pins. The host emulates the I/O APIC (24 pins, the select register and the window, the redirection entries), and a raise of an unmasked pin sends its vector to the local APIC with `WHvRequestInterrupt`.
- The exits: the emulator of WinHvEmulation.dll (`WHvEmulatorTryIoEmulation` and `WHvEmulatorTryMmioEmulation`) decodes each port and MMIO access and calls the host for its data, so the host decodes no instruction.
- The console is an 8250 at 0x3f8 with the registers that the probe of the driver reads back, and the interrupt of its empty transmitter on IRQ 4. Without that interrupt the TTY of `ttyS0` never sends, and only the kernel log, which the console writes with no interrupt, comes out. The initramfs is a cpio archive (newc) that the spike makes, with `/dev/console` for the first process.
- A port with no device reads as 0, except the ports of the i8042, 0x60 and 0x64, which read as 0xff, a bus with no device. With 0 there, the probe of the i8042 waits for its timeouts, about 570 ms, before "Can't read CTR". A PIC that reads as 0xff could look present, so the other ports stay at 0.
- The results on an Intel Core i7-1165G7 with Windows 11 Home 25H2 and 256 MB, three runs each: the ready line of init 396 ms to 402 ms after the start with the full kernel log on the console (about 20,000 exits, nearly all a byte of the console), and 211 ms to 214 ms with `quiet` (about 500 exits). The first spike, with no interrupts and with 0 on the ports of the i8042, took 956 ms to 981 ms. The probe of the uncore PMU reads the MSR 0x396 and gives a warning with a trace.
- The monitor (ztcl#369): `src/whp.zig` on the shared devices, with the vsock device of `src/vm/virtio/vsock.zig` (ztcl#364) and the direct boot of `src/vm/boot.zig`. One CPU for now: the start of a second CPU through the startup IPI is not checked on the xAPIC emulation yet.
- The commands (`src/microvm.zig`): `create`, `start`, `stop`, `status`, `vsock`, `console`, `exec`, `delete`, and `-warm`, as on Linux, and `exec` through the agent. The monitor has no descriptor of a vsock stream, so a pump thread of each guest moves the bytes of the console and of each stream between the monitor and one end of a pair of loopback sockets, and the script gets the other end as its channel. The accepted socket of a pair must be the one that ztcl connected, so no other program gets in. A share is not available yet (`ZTCL VM SHARE`).
- The start time, on an Intel Core i7-1165G7 with Windows 11 Home 25H2, a guest of 256 MB, and `quiet`, the best of 10 from `start` to the answer of the agent on port 1025:

  | Kernel | Before | With the changes below |
  |---|---|---|
  | The xz kernel of `vm-guest-x86_64` | 285 ms | 158 ms |
  | An lz4 kernel of 2.4 MB | 176 ms | 35 ms |

  `exec` of `/bin/busybox true` went from 63 ms to 4 ms.
  - The hypervisor fills its map of a guest page on the first touch, with no exit to the monitor, and an lz4 kernel ran 50 ms from its start to its first exit. `WHvAdviseGpaRange` with the populate code fills 32 MB at each end of the guest memory first: the kernel loads at 16 MB and unpacks above it, and the initramfs and the first allocations of the kernel are at the top. The first exit then comes 4 ms after the start, and `start` is 11 ms longer. A touch of the pages from the host gave no gain, and 16 MB at each end misses the kernel.
  - `Sleep` waits to the next tick of the clock of the system, 15.6 ms by default, so each wait of 1 ms of the pump thread and of `vsock` was 15 ms. A waitable timer of `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION` waits the time it gets, and changes no setting of the system (`whp.sleepUs`).
  - A connection that the guest refuses tries again after 2 ms, in the place of 50 ms.
  - About 260 exits remain to the answer of the agent with the lz4 kernel, and all of them together cost the monitor under 1 ms. The most are the writes of the queue notify register (0x050) of the console, 268 with the xz kernel and 13 with the lz4 kernel, then the reads of the ports of no device (49).

## Tests

- A unit test of `vz.zig` that makes and checks a configuration. It runs on each macOS host and needs no entitlement for the parts before `validateWithError:`.
- A boot test that runs the spike checks (ready line, vsock echo, a file in a share) on a Mac with the hypervisor. GitHub's macOS runners are VMs themselves, so a guest there needs nested virtualization from the host of the runner. The test asks `VZVirtualMachine.isSupported` and skips when it is false. Step 2 finds out with a run on the runners.
- On Linux, `tools/vm-guest/test-kvm.sh` runs the boot test (vsock echo, a stop and a new start, 2 CPUs, a disk, the entropy device, the console, a warm start) and the times, with the bzImage and with the `vmlinux`. It skips with the reason when the host has no access to `/dev/kvm` or `/dev/vhost-vsock`. The x86-64 job of `vm-guest.yml` opens `/dev/kvm` to the runner user with a udev rule and loads `vhost_vsock`.
- The same job runs the test again with the kernel of beetlebugorg/ztcl-guest-kernel: the artifact `guest-kernel-x86_64` (ID 15177680182), checked by its SHA-256. GitHub deletes this artifact on 2027-02-25. Before that date, the kernel must move to durable storage, such as a release asset of beetlebugorg/ztcl-guest-kernel, and `vm-guest.yml` must download it from there. A release needs the yes of the owner. After the artifact is gone, the job prints a warning and skips this test.

## Steps

1. The spike (this PR).
2. `vz.zig` as the core of `src/microvm.zig` with `create`, `start`, `stop`, `status`, `console`, `vsock`, `delete`, `-warm`, and the capability, on macOS (done). `vm.zig` is the name of the bytecode file, so the new file is `src/microvm.zig`, and the command stays `ztcl::vm`. A child interp has no `vm`, so the limits count the guests of one interpreter. `tools/vm-guest/test.sh` runs the boot test on a Mac with the hypervisor.
3. The entitlements in the Zig signer (done): `src/macho.zig` writes the requirements, the XML, and the DER blobs with their special slots. `zig build` signs the macOS `ztcl` with `tools/macho-sign`, and `ztcl build` signs an app with `vm` in `--allow`.
4. The agent with `exec` and `mount` (done): the protocol is `docs/dev/vm-agent.md`, the host side `src/vmagent.zig`, and `ztcl::vm exec` and `mount` on macOS and KVM. The image builds for arm64 and x86-64 (`tools/vm-guest`, the artifacts `vm-guest` and `vm-guest-x86_64`). The signed image is ztcl#312.
5. The KVM part on x86-64 (done): `src/kvm.zig`, with 9p shares. arm64 later.
6. The Windows part on the Windows Hypervisor Platform: the spike, the interrupts, the monitor, and the commands (done, except the shares and a second CPU).
7. The docs page `docs/modules/vm.md` (#172).

## Questions

These are the defaults of this plan. Each can change in review.

1. A share is read-only unless it says `rw`. Default: read-only.
2. The guest has no network in the first steps. A later `-net nat` uses `VZNATNetworkDeviceAttachment` on macOS. Default: no network.
3. The base image downloads on the first use into the cache of ztcl. Another choice is a separate download that the user runs. Default: on the first use, with a check of the signature.
4. virtio-9p first on Linux, and virtio-fs later. Default: 9p first.
5. The limits of `Interp.vm_host`: 4 CPUs, 2,048 MB, and 4 guests. Default as written.
6. A warm guest (`create -warm 1`) is off by default, because a paused guest keeps a process and memory. Default: off, and dockyard turns it on.
7. The guest has no entropy device by default, for 1 ms to 8 ms less at boot. Default: none, and `-entropy 1` adds it.
