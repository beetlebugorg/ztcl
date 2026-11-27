# Module ztcl::vm

`ztcl::vm` starts a small Linux guest on the hypervisor of the host and talks to it over vsock. The guest has its own kernel, and it reaches only the folders, the disks, and the vsock ports that the script gives it.

```tcl
set vm [ztcl::vm create -kernel Image -initrd agent.cpio -cmdline "rdinit=/sbin/agent quiet" \
        -memory 64 -share {work /mnt/share rw}]
ztcl::vm start $vm
puts [ztcl::vm exec $vm /bin/busybox uname -m]   ;# exit 0 stdout {aarch64\n} stderr {}
ztcl::vm delete $vm
```

[Linux guests](../vm.md) is the guide: the hypervisor of each system, the images, the start times, and the security model.

The command is not a package: it exists when the embedder turns on the capability `vm`, and it is absent otherwise. A child interp never has it, so the limits count the guests of one interpreter. The paths of a guest also need the capability `file`, and the channels of a guest need `channels`.

The backends: Virtualization.framework on macOS 12 and later, the KVM monitor of ztcl on x86-64 Linux, and the monitor of ztcl on the Windows Hypervisor Platform on x86-64 Windows. On Linux a share is a 9p share, and the agent mounts it with 9p. On Windows a share is virtio-fs with a DAX window: the guest maps the pages of a host file into its memory, so a read is a load from memory with no message to the host. A file that the guest closed is free on the host after 1 s; while the guest has it open, the host cannot truncate it, as with a program of Windows that has the file mapped. `ZTCL_VM_DAX=0` in the environment of `create` turns the window off, and `ZTCL_VM_SHARE=9p` gives 9p, for a guest with no virtio-fs driver. On Windows a guest has one CPU. Windows needs its hypervisor, which runs with Virtualization-based Security or the feature Windows Hypervisor Platform, and no elevation. On another platform each command gives `ZTCL VM UNAVAILABLE`. The plan of the backends, the guest agent, and the base image is in `docs/dev/vm.md`.

## Commands

```tcl
ztcl::vm create ?option value ...?
ztcl::vm start VM
ztcl::vm stop VM ?-force?
ztcl::vm status VM
ztcl::vm snapshot VM FILE
ztcl::vm vsock VM PORT ?-timeout MS?
ztcl::vm exec VM ?-stdin DATA? ?-binary BOOL? ?-env LIST? ?-cwd DIR? ?-timeout MS? ?--? PROGRAM ?ARG ...?
ztcl::vm mount VM TAG PATH ?-readonly?
ztcl::vm listen VM PORT -command SCRIPT
ztcl::vm unlisten VM PORT
ztcl::vm console VM
ztcl::vm delete VM
```

`create` checks the configuration and gives the name of the guest, such as `vm1`. The guest does not run until `start`, unless `-warm 1`.

| Option of `create` | Value | Default |
|---|---|---|
| `-kernel F` | The kernel: an uncompressed `Image` on arm64. This version needs it. | none |
| `-initrd F` | The initramfs. | none |
| `-cmdline TEXT` | The command line of the kernel. | `console=hvc0 quiet` |
| `-cpus N` | The CPUs of the guest. | 1 |
| `-memory MB` | The memory of the guest, in MB. | 256 |
| `-disk {F ?rw?}` | A disk image file, as a virtio block device: `/dev/vda` for the first `-disk`, `/dev/vdb` for the second, and so on. Read-only unless the list ends in `rw`. | none |
| `-share {HOST GUEST ?rw?}` | A folder of the host, as virtio-fs on macOS and Windows and 9p on Linux: the tag `share0` for the first `-share`, `share1` for the second, and so on. `GUEST` is the folder of the guest for the agent of a later version; until then the agent mounts `share0` at `/mnt/share`, and `ztcl::vm mount` mounts the others. Read-only unless the list ends in `rw`. | none |
| `-entropy 0\|1` | A virtio entropy device. Its driver adds 1 ms to 8 ms to the boot. | 0 |
| `-net nat\|none` | Linux with KVM, and macOS: a virtio-net device `eth0` on the user-mode NAT of ztcl. It needs the `socket` capability, and each host address of the NAT must pass the network policy of the interpreter (`loopback` by default). The guest is 10.0.2.15/24: the host gives it on the command line of the kernel (`ztcl.net=`) on macOS, and the agent sets it before it listens, about 0.5 ms, or asks with DHCP when the option is absent; and the gateway 10.0.2.2 goes to 127.0.0.1 of the host. This version has ARP, DHCP, ICMP echo to the gateway, and UDP. The guest configures `eth0` itself, for example with `udhcpc` of BusyBox. A guest with `-net nat` comes from no pool. | none |
| `-dns 0\|1` | With `-net nat`: UDP to port 53 of 10.0.2.3 goes to the first IPv4 name server of `/etc/resolv.conf` of the host. With 0, 10.0.2.3 gives no answer. | 1 |
| `-balloon 0\|1` | Linux (KVM) only: a virtio memory balloon with free page reporting. The guest kernel reports its free memory in blocks of 2 MB, and the host frees those pages. The guest kernel needs `CONFIG_VIRTIO_BALLOON` and `CONFIG_PAGE_REPORTING`; a kernel without them ignores the device. The balloon is the last device and needs a free interrupt: a guest with the most disks, shares, entropy, and `-net` has none. | 1 |
| `-snapshot F` | Linux (KVM) only: restores the guest of the snapshot file `F` (see [Snapshots](#snapshots)). The only other option is `-count`. | none |
| `-count N` | With `-snapshot`: makes N clones of the snapshot, and `create` gives the list of their names. | 1 |
| `-warm 0\|1` | Boots the guest at once, waits for a program of the guest to accept a connection on vsock port 1024, and pauses it. `start` then resumes it in under 1 ms. A paused guest keeps its process and the memory that it touched. | 0 |

Each path is a path below the root folder of `file`. The framework gets the final path of the open file, so a link in the root folder cannot point the guest outside it.

> [!WARNING]
> A share with `rw` lets the guest change the files of that folder of the host. A disk with `rw` lets the guest change the file of the disk.

- `start` starts a created or stopped guest and waits for the framework to say that it runs, or resumes a paused guest. It does not wait for a program of the guest: `vsock` does that.
- `stop` asks the guest to power off and waits up to 5 seconds, then stops it at once. `-force` stops it at once. A stopped guest can start again, with a new boot. The request is a press of the power button of the guest: a kernel with no driver for it, such as the spike guest of `tools/vm-guest`, ignores it, so `stop` waits the full 5 seconds. Use `-force` for such a guest.
- `status` gives `created`, `starting`, `running`, `pausing`, `paused`, `stopping`, `stopped`, or `error`.
- `vsock` connects to a port of the running guest and gives a channel, readable and writable, in binary translation. A refused connection is tried again at once until `-timeout` ms pass: 5,000 by default, and 0 for one try.
- `exec` runs a program in the guest through the guest agent (`tools/vm-guest/agent.zig`, the first process of the guest image) and waits for its end. It gives a dict: `exit` (the exit code, or minus the number of the signal that ended the program), `stdout`, and `stderr`, each output up to 64 MiB. `PROGRAM` is a path in the guest: there is no search of `PATH` and no shell, so a shell is `/bin/busybox sh -c {...}` in the guest image. `-stdin` gives its input, which then ends; without it the input is empty. The input is the UTF-8 of the text of `-stdin`, and `stdout` and `stderr` are the bytes of the output as UTF-8 text. `-binary 1` is for binary data, such as the result of `read` on a channel with `-translation binary` or of `binary format`: each character of `-stdin` is one byte (characters below 256), and each byte of the output is one character of `stdout` and `stderr`. `-env` is a list of `NAME=value`, and the program gets no other variable. `-cwd` is its folder, `/` by default. `-timeout` is the most milliseconds of a wait for the agent with no output, 30,000 by default: past it, the connection closes and the agent ends the program.
- `listen` takes the connections that programs of the guest make to the host on vsock port `PORT` (the CID of the host is 2). For each one the event loop calls `SCRIPT` with a channel of the connection appended, in binary translation. It needs the capability `event`, and a guest has one listener on a port. `unlisten` stops it, and `delete` stops each listener of the guest. A guest without `-net nat` has no network: a program there reaches the host only through its listeners. The agent of the image is a client too: `/sbin/agent connect PORT` copies its input to the host and the answer of the host to its output. On Linux with KVM, the vsock ports of the host are one space for the whole host: the first listener on a port binds it for the program, and a connection goes to the listener of the guest with the CID of the peer. A port that another program of the host has gives `ZTCL VM LISTEN` (`vsock port 3000 of the host is in use`). On Windows the vsock device of the monitor gets the connections, so each guest has its own ports. A program of the guest that ends its writes (`shutdown` of its sending side) still reads the answer of the host, and a close of the channel of the host sends its last bytes, then the end of the stream.
- `mount` mounts the share with the tag `TAG` (`share0` for the first `-share`) at `PATH` in the guest, read-only with `-readonly`. The agent mounts `share0` at `/mnt/share` when the guest starts.
- `console` gives the console of the guest (`hvc0`) as a channel, one time for each guest.
- `delete` stops the guest at once and frees it. The end of the interpreter deletes each guest.

## Images

A signed guest image comes from the release of the image (ztcl#312): a manifest of its files, signed with a key that ztcl has built in, the kernel, and a read-only root disk with `dm-verity`. `docs/dev/vm-image.md` has the format and the keys.

```tcl
ztcl::vm image install ./ztcl-guest            ;# name ztcl-guest counter 7 key current
set vm [ztcl::vm create -image ztcl-guest -memory 128]
ztcl::vm start $vm
ztcl::vm exec $vm /bin/busybox uname -m
```

- `image install DIR ?-force?` checks the signature of `DIR/manifest.json` and the SHA-256 of each file, copies the files of this architecture (and of each other one that `DIR` has) into the store, and makes the release the current one. `DIR` is a folder below the root folder. A release with a counter below the highest that the store has seen is a rollback, refused without `-force`. It gives a dict: `name`, `counter`, and `key` (the key that signed it).
- `image list` gives a dict for each image: `name`, `releases` (the counters in the store), and `current`.
- `image verify NAME` checks the signature of the current release and the SHA-256 of each of its files in the store again.
- `image remove NAME ?COUNTER?` removes a release, or each release of the image, and each file that no release needs. The highest counter stays, so a removal does not open the door to an older release.
- `create -image NAME` boots the current release: its kernel, its initramfs, its command line, and its disks, read-only and first (`/dev/vda` is the root). It checks the SHA-256 of the kernel and the initramfs at each `create`; a disk with `dm-verity` checks each block when the guest reads it. It takes no `-kernel`, `-initrd`, or `-cmdline`.

- `image fetch ?-version V? ?-url BASE? ?-force?` downloads a release over HTTPS and installs it as `install` does: first `manifest.json` and its signature, then, when the release is newer than the current one, the files of this architecture into a folder of the store, and then the checks of `install`. The release is the GitHub release `vm-image-vV` of ztcl, or the folder `BASE` of a mirror. With no `-version` and no `-url`, it reads the list of releases of ztcl from the GitHub API and takes the highest version `vm-image-vN` that is no draft: a release that fails (a download, the signature, or a check of `install`) gives way to the next lower one, and with none the error of the highest. The rollback check of `install` still refuses a counter below the current one. It gives a dict with `status` `installed` or `current` (the store has it already; `-force` fetches it again). It needs the capability `socket` and a program that gives `ztcl::vm` a download. In this version the `ztcl` runner has one only when built with `zig build -Dvm-fetch` (std.http and its TLS, about 650 KB); a default build gives `ZTCL VM UNAVAILABLE` until ztcl's own TLS. `image install` works in each build.
- `image update ?-url BASE?` is `fetch` of the latest release.

- A pool of booted guests makes `create -image` and `start` fast on macOS, on Windows, and on Linux with KVM: the program keeps guests of each image booted to the agent and paused (`Interp.vm_host.pool_size`), so `create -image` takes one and `start` resumes it, and a thread boots the next. On an M1 Mac, `create -image`, `start`, and the first answer of the agent take a median of 11 ms from the pool against 142 ms without it. On Windows with the Windows Hypervisor Platform, `start` to the first answer of the agent of a guest of the pool is 6 ms in a Debug build of ztcl, against about 200 ms from `create -image` for a guest that boots. On an x86-64 Linux host with KVM, `create -image`, `start`, and the first `exec` take a median of 9 ms from the pool against 85 ms without it. On KVM, a guest of the pool runs `/bin/busybox true` before its pause, so the first `exec` finds the pages of BusyBox in the page cache of the guest. On KVM, the pool of an image has its own key for each counter of the image, each `-cpus`, each `-memory`, and each `-entropy`. The `ztcl` runner keeps 1 guest of each image that a script used (`ZTCL_VM_POOL` sets another count, 0 none); an embedder has no pool unless it sets one. A guest of the pool holds the memory that it touched, and only a `create -image` with no `-share`, no `-disk`, and no `-warm` takes one.

The store is a folder of the user: `ZTCL_VM_IMAGES`, or `~/Library/Application Support/ztcl/vm-images` on macOS, `$XDG_DATA_HOME/ztcl/vm-images` (`~/.local/share/...`) on Linux, and `%LOCALAPPDATA%\ztcl\vm-images` on Windows. `create -image` works on macOS and on Windows. On Windows the monitor reads the kernel and the initramfs through the store into memory, and checks the SHA-256 of those bytes. A script names an image, never a path of the store.

## Snapshots

On Linux with KVM, `snapshot` writes the state of a guest to a file: the registers of each vCPU, the interrupt controllers, the clock, the state of each virtio device and of its queues, and the memory of the guest. A running guest pauses for the snapshot and then runs again. It gives the bytes of guest memory in the file. Only the pages that are not all zero go in the file, so the file is sparse.

`create -snapshot F` restores the guest of the file, paused, and `start` runs it. The restore maps the memory of the file copy-on-write: a page of the guest comes from the file at its first read, and the guest gets its own copy at its first write. So a restore copies no memory, and the clones of one file (`-count N`) share each page that none of them writes. The file stays the same.

```tcl
set vm [ztcl::vm create -image ztcl-guest -memory 128 -warm 1]
ztcl::vm snapshot $vm ready.snap
foreach g [ztcl::vm create -snapshot ready.snap -count 4] {
    ztcl::vm start $g
    puts [ztcl::vm exec $g /bin/busybox uname -n]
}
```

- Each clone gets its own vsock context ID. The guest gets the vsock event of a transport reset, reads its new ID, and closes the connections of the snapshot. A socket that listens, such as the one of the agent, stays.
- The first `start` of a restore sends the agent the request `RESUME`: the agent sets the clock of the guest to the clock of the host and adds 32 random bytes of the host to the random pool of the guest kernel. So clones of one snapshot have different random numbers. Without it, the clock of the guest goes on from the time of the snapshot.
- A guest with a `-share`, a `-disk`, or `-net` has no snapshot: their state is outside the guest memory. The disks of an image go in the snapshot as the name and the counter of the image, and the restore opens them from the store again.
- A snapshot is for the same host and the same version of ztcl. The CPU features of the host must not change between the snapshot and the restore.
- The file holds the memory of the guest. Keep it as private as the guest.
- With the pool on (`Host.pool_size`), the interpreter keeps prepared machines (a VM, its memory slot, its devices, and its vCPU threads) for `create -snapshot`, and a restore is about 0.5 ms; the pool of `create -image` makes its guests as clones of a snapshot of its first guest. `docs/dev/vm-turbo.md` has the measurements.

## Limits

The embedder sets `Interp.vm_host`:

| Field | Default |
|---|---|
| `max_cpus` | 4 |
| `max_memory_mb` | 2,048 |
| `max_guests` | 4 guests at once |

The memory of a guest is outside the memory limit of the interpreter, as the memory of a process of `exec` is.

## Signing on macOS

The program needs the entitlement `com.apple.security.virtualization` in its signature. `zig build` signs the macOS `ztcl` ad hoc with it, and `ztcl build --allow vm` signs an app with it, so neither needs a step with `codesign`. A program that you sign again yourself, for example with a Developer ID, needs the entitlement in that signature:

```sh
codesign --force --sign - --entitlements tools/vm-guest/vz.entitlements zig-out/bin/ztcl
```

Without it, `create` gives `ZTCL VM ENTITLEMENT`.

## Start time

A start of a guest with 1 CPU and 64 MB is about 100 ms on an M1 Mac, and 86 ms of it is the framework. A warm guest (`-warm 1`) answers on vsock 0.3 ms after `start`. The numbers of each phase are in `docs/dev/vm.md`.

## Errors

| `-errorcode` | Message |
|---|---|
| `ZTCL VM UNAVAILABLE` | `ztcl::vm is not available on this platform yet`, `this macOS has no Virtualization.framework`, the fix for a Linux with no access to `/dev/kvm`, or the fix for a Windows with no hypervisor |
| `ZTCL VM WHP` | The step of the Windows Hypervisor Platform that failed, such as `WHvSetupPartition failed` |
| `ZTCL VM ENTITLEMENT` | `ztcl::vm needs the entitlement com.apple.security.virtualization in the signature of this program` |
| `ZTCL VM KERNEL` | `a guest needs -kernel until the base image of the plan` |
| `ZTCL VM SNAPSHOT` | `the guest vm1 has a share: a guest with a share has no snapshot`, or `"F" is not a snapshot of this version of ztcl::vm` |
| `ZTCL VM NOFILE` | `a path of ztcl::vm needs the file capability` |
| `ZTCL VM LIMIT` | `the memory in MB of a guest is more than the limit of 2048` (and for the CPU count), or `the interpreter has 4 guests, the limit` |
| `ZTCL VM NAME` | `no guest named "vm9"` |
| `ZTCL VM STATE` | `the guest vm1 is stopping` |
| `ZTCL VM CONNECT` | `no program of the guest vm1 accepted a connection on port 1024` |
| `ZTCL VM AGENT` | `no program of the guest accepted a connection on port 1024`, for `-warm 1` after 10 seconds; `exec failed (errno 2)` and the other errors of the agent; `the agent of the guest vm1 did not answer on port 1024` |
| `ZTCL VM LISTEN` | `the guest vm1 has a listener on port 3000 already`, `no listener` for `unlisten`, and on KVM `vsock port 3000 of the host is in use` |
| `ZTCL VM NOEVENT` | `ztcl::vm listen needs the event capability` |
| `ZTCL VM TIMEOUT` | `the guest vm1 gave no answer in time`, for `exec` past `-timeout` |
| `ZTCL VM CONSOLE` | `the console of the guest vm1 is a channel already` |
| `ZTCL VM STORE` | `no store of images: the embedder gives no folder` |
| `ZTCL VM IMAGE SIGNATURE` | `the manifest is not signed by a key that this ztcl trusts`, and the other failures of the signature |
| `ZTCL VM IMAGE ROLLBACK` | `the store has a newer release of the image: pass -force to install an older one` |
| `ZTCL VM IMAGE HASH` | `a file of the image does not have the SHA-256 of its manifest` |
| `ZTCL VM IMAGE MISSING` | `the image has no files for arm64` |
| `ZTCL VM FETCH` | `the download of https://.../manifest.json failed: Status` |
| `ZTCL VM NONET` | `ztcl::vm image fetch needs the socket capability`, and `-net nat needs the socket capability` |
| `ZTCL VM IMAGE NAME` | `no image named "x" in the store: install it with ztcl::vm image install` |
| `ZTCL VM FRAMEWORK` | The text of the framework, such as for a kernel file that it cannot boot |
| `POSIX EACCES` | `couldn't open "../x": permission denied`, for a path outside the root folder |
