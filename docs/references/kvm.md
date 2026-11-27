# References for the KVM monitor

`src/kvm.zig`, the Linux part of `ztcl::vm` (ztcl#203), uses these sources. ztcl has no code of any of them. The work is clean-room: no source code of QEMU, Firecracker, crosvm, cloud-hypervisor, or the Linux kernel was read.

## The KVM API

The Linux kernel, "The Definitive KVM (Kernel-based Virtual Machine) API Documentation", Documentation/virt/kvm/api.rst (v6.12). https://docs.kernel.org/virt/kvm/api.html

**License:** the text of the document (GPL-2.0 documentation). ztcl copies no text and no code from it.

**How ztcl uses it:** the ioctls of the system, the VM, and the vCPU, the layouts of `kvm_regs`, `kvm_sregs`, `kvm_userspace_memory_region`, `kvm_cpuid2`, `kvm_ioeventfd`, `kvm_irqfd`, and `kvm_pit_config`, the fields of `kvm_run` for the I/O and MMIO exits, and `immediate_exit` for the pause of a vCPU. The ioctl numbers are the ABI of Linux: the KVM ioctls use the type 0xAE and the vhost ioctls the type 0xAF, with the numbers of the Linux UAPI. The boot test checks each one on a host.

## The x86 boot protocol

The Linux kernel, "The Linux/x86 Boot Protocol" (Documentation/arch/x86/boot.rst) and "Zero Page" (Documentation/arch/x86/zero-page.rst), v6.12. https://docs.kernel.org/arch/x86/boot.html

**License:** the text of the documents. ztcl copies no text and no code from them.

**How ztcl uses it:** the setup header of a bzImage, the fields of the boot parameters that a boot loader fills (the command line, the initramfs, `type_of_loader`, `loadflags`, the E820 table), and the 64-bit boot protocol: the state of the CPU at the 64-bit entry point.

## virtio

OASIS, "Virtual I/O Device (VIRTIO) Version 1.2". https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html

**License:** the text of the specification. ztcl copies no text and no code from it.

**How ztcl uses it:** the split virtqueue (section 2.7), the virtio-mmio transport (4.2), and the console (5.3), block (5.2), entropy (5.4), and socket (5.10) devices.

## The MP table

Intel, "MultiProcessor Specification", version 1.4, May 1997.

**License:** the text of the specification. ztcl copies no text and no code from it.

**How ztcl uses it:** the floating pointer structure, the configuration table header, and the entries for the processors, the bus, the I/O APIC, the I/O interrupts, and the local interrupts.
