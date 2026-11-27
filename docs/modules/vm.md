# Module ztcl::vm

`ztcl::vm` starts a small Linux guest on the hypervisor of the host and talks to it over vsock. The guest has its own kernel, and it reaches only the folders, the disks, and the vsock ports that the script gives it.

```tcl
set vm [ztcl::vm create -kernel Image -initrd agent.cpio -cmdline "rdinit=/sbin/agent quiet" \
        -memory 64 -share {work /mnt/share rw}]
ztcl::vm start $vm
puts [ztcl::vm exec $vm /bin/busybox uname -m]   ;# exit 0 stdout {aarch64\n} stderr {}
ztcl::vm delete $vm
```

The command is not a package: it exists when the embedder turns on the capability `vm`, and it is absent otherwise. A child interp never has it, so the limits count the guests of one interpreter. The paths of a guest also need the capability `file`, and the channels of a guest need `channels`.

In this version only macOS has a backend: Virtualization.framework, on macOS 12 and later. On Linux and Windows each command gives `ZTCL VM UNAVAILABLE`. The plan for the KVM and HCS backends, the guest agent, and the base image is in `docs/dev/vm.md`.

## Commands

```tcl
ztcl::vm create ?option value ...?
ztcl::vm start VM
ztcl::vm stop VM ?-force?
ztcl::vm status VM
ztcl::vm vsock VM PORT ?-timeout MS?
ztcl::vm exec VM ?-stdin DATA? ?-env LIST? ?-cwd DIR? ?-timeout MS? ?--? PROGRAM ?ARG ...?
ztcl::vm mount VM TAG PATH ?-readonly?
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
| `-share {HOST GUEST ?rw?}` | A folder of the host, as virtio-fs: the tag `share0` for the first `-share`, `share1` for the second, and so on. `GUEST` is the folder of the guest for the agent of a later version; until then the guest mounts the tag itself (`mount -t virtiofs share0 /mnt/share`). Read-only unless the list ends in `rw`. | none |
| `-entropy 0\|1` | A virtio entropy device. Its driver adds 1 ms to 8 ms to the boot. | 0 |
| `-warm 0\|1` | Boots the guest at once, waits for a program of the guest to accept a connection on vsock port 1024, and pauses it. `start` then resumes it in under 1 ms. A paused guest keeps its process and the memory that it touched. | 0 |

Each path is a path below the root folder of `file`. The framework gets the final path of the open file, so a link in the root folder cannot point the guest outside it.

> [!WARNING]
> A share with `rw` lets the guest change the files of that folder of the host. A disk with `rw` lets the guest change the file of the disk.

- `start` starts a created or stopped guest and waits for the framework to say that it runs, or resumes a paused guest. It does not wait for a program of the guest: `vsock` does that.
- `stop` asks the guest to power off and waits up to 5 seconds, then stops it at once. `-force` stops it at once. A stopped guest can start again, with a new boot. The request is a press of the power button of the guest: a kernel with no driver for it, such as the spike guest of `tools/vm-guest`, ignores it, so `stop` waits the full 5 seconds. Use `-force` for such a guest.
- `status` gives `created`, `starting`, `running`, `pausing`, `paused`, `stopping`, `stopped`, or `error`.
- `vsock` connects to a port of the running guest and gives a channel, readable and writable, in binary translation. A refused connection is tried again at once until `-timeout` ms pass: 5,000 by default, and 0 for one try.
- `exec` runs a program in the guest through the guest agent (`tools/vm-guest/agent.zig`, the first process of the guest image) and waits for its end. It gives a dict: `exit` (the exit code, or minus the number of the signal that ended the program), `stdout`, and `stderr`, each output up to 64 MiB. `PROGRAM` is a path in the guest: there is no search of `PATH` and no shell, so a shell is `/bin/busybox sh -c {...}` in the guest image. `-stdin` gives the bytes of its input, which then ends; without it the input is empty. `-env` is a list of `NAME=value`, and the program gets no other variable. `-cwd` is its folder, `/` by default. `-timeout` is the most milliseconds of a wait for the agent with no output, 30,000 by default: past it, the connection closes and the agent ends the program.
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

The store is a folder of the user: `ZTCL_VM_IMAGES`, or `~/Library/Application Support/ztcl/vm-images` on macOS and `$XDG_DATA_HOME/ztcl/vm-images` (`~/.local/share/...`) on Linux. A script names an image, never a path of the store. `image fetch` and `image update` (a download of a release of GitHub) come later.

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
| `ZTCL VM UNAVAILABLE` | `ztcl::vm is not available on Linux yet` (and for Windows), or `this macOS has no Virtualization.framework` |
| `ZTCL VM ENTITLEMENT` | `ztcl::vm needs the entitlement com.apple.security.virtualization in the signature of this program` |
| `ZTCL VM KERNEL` | `a guest needs -kernel until the base image of the plan` |
| `ZTCL VM NOFILE` | `a path of ztcl::vm needs the file capability` |
| `ZTCL VM LIMIT` | `the memory in MB of a guest is more than the limit of 2048` (and for the CPU count), or `the interpreter has 4 guests, the limit` |
| `ZTCL VM NAME` | `no guest named "vm9"` |
| `ZTCL VM STATE` | `the guest vm1 is stopping` |
| `ZTCL VM CONNECT` | `no program of the guest vm1 accepted a connection on port 1024` |
| `ZTCL VM AGENT` | `no program of the guest accepted a connection on port 1024`, for `-warm 1` after 10 seconds; `exec failed (errno 2)` and the other errors of the agent; `the agent of the guest vm1 did not answer on port 1024` |
| `ZTCL VM TIMEOUT` | `the guest vm1 gave no answer in time`, for `exec` past `-timeout` |
| `ZTCL VM CONSOLE` | `the console of the guest vm1 is a channel already` |
| `ZTCL VM STORE` | `no store of images: the embedder gives no folder` |
| `ZTCL VM IMAGE SIGNATURE` | `the manifest is not signed by a key that this ztcl trusts`, and the other failures of the signature |
| `ZTCL VM IMAGE ROLLBACK` | `the store has a newer release of the image: pass -force to install an older one` |
| `ZTCL VM IMAGE HASH` | `a file of the image does not have the SHA-256 of its manifest` |
| `ZTCL VM IMAGE MISSING` | `the image has no files for arm64` |
| `ZTCL VM IMAGE NAME` | `no image named "x" in the store: install it with ztcl::vm image install` |
| `ZTCL VM FRAMEWORK` | The text of the framework, such as for a kernel file that it cannot boot |
| `POSIX EACCES` | `couldn't open "../x": permission denied`, for a path outside the root folder |
