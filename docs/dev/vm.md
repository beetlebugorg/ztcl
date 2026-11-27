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
- A disk is a descriptor that ztcl opens in the file jail. The vCPU thread runs each request with `pread` and `pwrite`. A read-only disk has `VIRTIO_BLK_F_RO`, and the monitor refuses its writes.
- The monitor adds `reboot=k panic=-1` to the command line. The guest stops itself with a reboot (the reset of the keyboard controller at port 0x64) or a panic. There is no ACPI, so a power-off of the guest halts it and does not stop it: `stop` without `-force` stops the guest at once on Linux until the agent has `poweroff`.
- A pause sets `immediate_exit` of each vCPU and sends its thread a signal (40, with an empty handler), so `KVM_RUN` returns, and the thread waits on a futex. A warm guest (`-warm 1`) is a booted guest in this pause.
- A share is not available on Linux yet (`ZTCL VM SHARE`). virtio-fs needs a FUSE server on the host side, which ztcl writes in Zig, in the file jail. A first step can share folders with virtio-9p, a smaller protocol, with the same Tcl API. The x86-64 guest kernel has 9P built in for it.
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

## The shared virtio devices

The monitors that give the guest its devices on virtio-mmio (KVM, and the Windows Hypervisor Platform) share the transport and the devices that run in ztcl. They are in `src/vm/virtio/`, with no system calls:

- `queue.zig`: `Mem` (the guest memory as one host range from guest address 0, with a bounds check of each address and length of the guest), `Queue` (the split virtqueue), and `Chain` (a chain of descriptors as host slices).
- `mmio.zig`: `Device`, the registers of the virtio-mmio transport, version 2, and the devices: `Device.console`, `Device.blk`, `Device.rng`, and `Device.external` for a device that the hypervisor runs (vhost-vsock on KVM).

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

vsock on KVM is vhost-vsock, an external device. A monitor without vhost (WHP) needs a vsock device in ztcl, with the queues of section 5.10 of virtio 1.2, the next device for `src/vm/virtio/`.

## Windows: the Host Compute Service

- HCS (`computecore.dll`): `HcsCreateComputeSystem` with a JSON document for a Linux utility VM, the same kind of VM as WSL 2 and the Linux containers of Windows. The kernel and the initramfs boot directly.
- vsock is a Hyper-V socket on the host (`AF_HYPERV` with the VM id and a service id made from the port), and `AF_VSOCK` in the guest. The guest kernel needs `CONFIG_HYPERV_VSOCKETS`.
- A share is a Plan 9 share of HCS, mounted in the guest with `9p` over vsock. The guest kernel needs `CONFIG_NET_9P` and `CONFIG_9P_FS`.
- The Windows Hypervisor Platform (`WHvCreatePartition`) is the fallback, the same shape as KVM with our own devices, for a Windows edition without HCS.
- A service of a Hyper-V socket of a normal VM needs a key under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices`, which needs an administrator. The JSON schema of HCS has `HvSocketConfig` with a table of services for one compute system, with no change to the registry: the spike of the Windows part checks that route first. Port 1024 of vsock is the service GUID `00000400-FACB-11E6-BD58-64006A7986D3`.
- HCS needs the feature Virtual Machine Platform (the one of WSL 2), which Windows 11 Home has. The calls of HCS likely need an administrator, so the Windows part may need a service: the spike checks it.
- The bootstrap secret of `docs/dev/isolation.md` goes on the command line of the kernel, which HCS gives with `LinuxKernelDirect`.

## Tests

- A unit test of `vz.zig` that makes and checks a configuration. It runs on each macOS host and needs no entitlement for the parts before `validateWithError:`.
- A boot test that runs the spike checks (ready line, vsock echo, a file in a share) on a Mac with the hypervisor. GitHub's macOS runners are VMs themselves, so a guest there needs nested virtualization from the host of the runner. The test asks `VZVirtualMachine.isSupported` and skips when it is false. Step 2 finds out with a run on the runners.
- On Linux, `tools/vm-guest/test-kvm.sh` runs the boot test (vsock echo, a stop and a new start, 2 CPUs, a disk, the entropy device, the console, a warm start) and the times, with the bzImage and with the `vmlinux`. It skips with the reason when the host has no access to `/dev/kvm` or `/dev/vhost-vsock`. The x86-64 job of `vm-guest.yml` opens `/dev/kvm` to the runner user with a udev rule and loads `vhost_vsock`.

## Steps

1. The spike (this PR).
2. `vz.zig` as the core of `src/microvm.zig` with `create`, `start`, `stop`, `status`, `console`, `vsock`, `delete`, `-warm`, and the capability, on macOS (done). `vm.zig` is the name of the bytecode file, so the new file is `src/microvm.zig`, and the command stays `ztcl::vm`. A child interp has no `vm`, so the limits count the guests of one interpreter. `tools/vm-guest/test.sh` runs the boot test on a Mac with the hypervisor.
3. The entitlements in the Zig signer (done): `src/macho.zig` writes the requirements, the XML, and the DER blobs with their special slots. `zig build` signs the macOS `ztcl` with `tools/macho-sign`, and `ztcl build` signs an app with `vm` in `--allow`.
4. The agent with `exec` and `mount` (done): the protocol is `docs/dev/vm-agent.md`, the host side `src/vmagent.zig`, and `ztcl::vm exec` and `mount` on macOS. The image builds for arm64 and x86-64 (`tools/vm-guest`, the artifacts `vm-guest` and `vm-guest-x86_64`). The signed image is ztcl#312.
5. The KVM part on x86-64 (done, except the shares): `src/kvm.zig`. arm64 later.
6. The HCS part.
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
