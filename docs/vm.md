# Linux guests

`ztcl::vm` starts a small Linux guest on the hypervisor of your computer, runs programs in it, and talks to it over vsock. The guest has its own kernel. A program in it reaches only the disks, the folders, and the ports that the script gives it. Use a guest for code that must not touch the host: a build of an untrusted project, a tool from an agent, or a program for another system.

```tcl
ztcl::vm image install ./ztcl-guest
set vm [ztcl::vm create -image ztcl-guest -memory 128]
ztcl::vm start $vm
set r [ztcl::vm exec $vm /bin/busybox uname -m]
puts [dict get $r stdout]    ;# x86_64 or aarch64
ztcl::vm delete $vm
```

The runner needs the capability `vm`, and `file` for the paths of the image: `ztcl --allow vm,file,channels script.tcl`. [ztcl::vm](modules/vm.md) has each command, each option, and each error.

## The hypervisor of each system

ztcl has no dependency for this: it calls the hypervisor of the system directly.

| System | Hypervisor | What it needs | Not yet |
|---|---|---|---|
| macOS 12 and later | Virtualization.framework | The entitlement `com.apple.security.virtualization` in the signature. `zig build` and `ztcl build --allow vm` add it. | |
| x86-64 Linux | KVM, with a monitor of ztcl | Read and write access to `/dev/kvm` and `/dev/vhost-vsock` (the `kvm` group) | `-share` (Coming: [#385](https://github.com/beetlebugorg/ztcl/pull/385), virtio-9p) |
| x86-64 Windows | Windows Hypervisor Platform, with a monitor of ztcl | The optional feature Windows Hypervisor Platform, or Virtualization-based Security. No administrator rights. | `-share`, more than one CPU, and the store of images |

On another system, each command gives `ZTCL VM UNAVAILABLE`.

## Images

A guest needs a kernel and a root. A signed image has both, and ztcl checks each byte before a guest uses it:

1. `ztcl::vm image install DIR` reads `manifest.json` and its SSH signature. The key must be one of the two keys that ztcl has built in.
2. The command checks the SHA-256 of each file against the manifest and copies the files into the store of the user.
3. `create -image NAME` checks the kernel and the initramfs again, and gives the root disk to the guest read-only, with the `dm-verity` hash tree of the manifest. The guest kernel checks each block of the disk when it reads it, so a disk that changes after the install fails on read.
4. Each release has a counter. A release with a counter below the highest that the store has seen is a rollback, and `install` refuses it without `-force`.

`image list`, `image verify NAME`, and `image remove NAME` manage the store. A script names an image, and never a path in the store. The store is on macOS and Linux. On Windows, boot a guest with `-kernel`, `-initrd`, and `-disk`.

> [!NOTE]
> No signed release of the guest image is published yet. The workflow `vm-guest.yml` builds the image for each pull request and signs it with the test key, which only a test build trusts. Until the first release, boot a guest of the workflow with `-kernel`, `-initrd`, and `-disk`. `ztcl::vm image fetch` (Coming: [#396](https://github.com/beetlebugorg/ztcl/pull/396)) downloads a release over HTTPS.

## Start times

The time from `ztcl::vm start` to the first answer of the guest agent over vsock, from the design notes of the repository (`docs/dev/vm.md`). The macOS and Linux numbers are the best of 10 runs, with 1 CPU, 64 MB, and the agent as the first process of the guest. The Windows number is an earlier measurement of the boot, to the ready line of init.

| Host | Cold | Warm |
|---|---|---|
| M1 Mac, Virtualization.framework | About 100 ms (86 ms is the framework) | 0.24 ms |
| Intel Skylake 4 GHz, KVM, a host with a light load | 24.78 ms | 0.136 ms |
| The same host, busy with builds | 65.61 ms | 0.124 ms |
| Intel Core i7-1165G7, Windows Hypervisor Platform, 256 MB, `quiet` | 211 ms to 214 ms (three runs) | Not measured |

A warm guest (`-warm 1`) boots at `create`, and pauses when its agent answers. `start` then resumes it. A paused guest keeps its memory, so use `-warm 1` for a pool of guests that each run one job.

## The security model

- **The guest is the boundary.** A program in the guest runs on its own kernel, on the hypervisor of the system. It reaches the host only through the devices that ztcl gives it: the console, vsock, the disks of `-disk` and of the image, and the folders of `-share`.
- **Read-only by default.** A disk or a folder is read-only unless its list ends in `rw`. A path of `-disk` and `-share` is below the root folder of `file`, and a link in that folder cannot point the guest outside it.
- **Limits.** The embedder sets the most CPUs, the most memory, and the most guests of an interpreter (`Interp.vm_host`: 4 CPUs, 2,048 MB, and 4 guests by default). A child interp never has `ztcl::vm`.
- **No network.** A guest has no network device in this version.
- **Signed images.** ztcl trusts two keys: the current key, which signs in a protected environment of CI, and the next key, which is offline. A test key is in the repository, and only a test build trusts it.
- **The monitors are ours.** On Linux and Windows, the devices of the guest are the Zig code of ztcl (`src/vm/`), with no QEMU. On Windows, the monitor gives each vsock stream to the script through a pair of loopback sockets, and checks that the accepted socket is the one that ztcl connected.

## Coming

- Folders of the host in a guest on Linux (virtio-9p, [#385](https://github.com/beetlebugorg/ztcl/pull/385)) and Windows.
- `ztcl::vm image fetch` and `image update`, and the first signed release of the guest image ([#312](https://github.com/beetlebugorg/ztcl/issues/312)).
- `thread::create -isolation vm`: a thread of ztcl in a guest ([#209](https://github.com/beetlebugorg/ztcl/issues/209)). [Isolated threads](isolation.md) has the levels of today.
