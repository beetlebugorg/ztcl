# NAT networking for ztcl::vm (ztcl#461)

This is the plan of `-net nat`: a virtio-net device and a user-mode NAT in Zig, for KVM, the Windows Hypervisor Platform, and macOS. The NAT has no root, no TAP device, no iptables, and no library such as slirp. The plan sets the speed targets first, because they decide the data structures.

## Model

- A guest has no network device unless `create` has `-net nat`. `-net` needs the network capability of the interpreter, and each host connection of the NAT passes the network policy of the embedder (`loopback` by default) and then the allow list of the guest.
- `-net nat ?-allow LIST? ?-deny LIST? ?-dns on|off? ?-forward {hostport guestport ...}?`. An item of a list is a host name, an address range in CIDR form, or either with `:port`.
- The guest is 10.0.2.15/24. The gateway 10.0.2.2 is the host: a connection to 10.0.2.2 goes to 127.0.0.1 of the host. 10.0.2.3 is the DNS server of the NAT.
- `ztcl::vm netlog VM` gives the events since the last call: each connection, each refusal with the rule that refused it, and each DNS answer. The counts of bytes go to the metering of ztcl#243.

## Parts

1. `src/vm/virtio/net.zig`: the virtio-net device (ID 1) on the shared transport of `mmio.zig`. Its backend is an interface of two calls: `fromGuest(frames)` and a ring of frames to the guest.
2. `src/vm/nat/`: the NAT. Ethernet and ARP for the gateway, DHCP (the offer and the ack for 10.0.2.15, with the router, the DNS server, and a lease), IPv4, ICMP echo to the gateway, UDP, TCP, and DNS. TCP and UDP of the guest end in the NAT, and the NAT opens ordinary sockets of the host with `sys.zig`. DNS queries go to the name servers of the host, and the NAT reads each answer, so that the allow list can match a host name to the addresses that the guest then uses.
3. The policy: the allow list and the deny list compile to a decision table (see the speed section).
4. The backends: KVM first (`src/kvm.zig`), then WHP. On macOS, a `VZFileHandleNetworkDeviceAttachment` on a socketpair gives the frames of the guest to the same NAT.

## Speed

The target is the line rate of the host loopback for one stream, and a time per round trip that is close to that of a host socket. These are the design rules:

- No copy in the NAT for the bulk of TCP data. The guest has TSO and checksum offload (`VIRTIO_NET_F_GUEST_CSUM`, `HOST_TSO4`, `HOST_TSO6`, `HOST_USO`), so it sends segments of up to 64 KB with no checksum. The NAT gives the payload of the descriptors to `sendmsg` as an iovec over guest memory. Toward the guest, `GUEST_TSO4` and mergeable receive buffers (`MRG_RXBUF`) let the NAT write up to 64 KB of a host `recv` in one frame. MSG_ZEROCOPY and io_uring `send_zc` are measured against a plain `sendmsg` for large writes.
- Fewer exits and interrupts. The device has event index (`RING_EVENT_IDX`), so the guest notifies and the device interrupts only when a ring was empty. The packed ring (`RING_PACKED`) comes after the split ring, with a measurement. On KVM, the transmit notify of the guest goes to an ioeventfd. Measured on 2026-11-27 (docs/dev/vm.md): one exit to user space costs about 8 us, and an irqfd on an ISA line was slower than `KVM_IRQ_LINE` for request and answer traffic. So the receive interrupt stays `KVM_IRQ_LINE` until a measurement of the net device says otherwise. virtio-mmio has no MSI, so multiqueue (`VIRTIO_NET_F_MQ`, one pair of queues for each vCPU) shares one interrupt line, and it comes after the measurements of one queue.
- One thread for each queue pair, with no lock on the fast path. The thread owns its connections, its ring indexes, and its sockets, and it waits on one epoll set (or one io_uring) for the notify eventfd and the sockets. Batches: `recvmmsg` and `sendmmsg` for UDP, and one pass over the transmit ring for each wake.
- Flat tables. A connection is a slot in an array, found by a hash of the 4-tuple with open addressing. The state of a TCP connection fits in two cache lines.
- Checksums with SIMD (`@Vector` sums of 16-bit words, AVX2 and NEON from the same Zig code), and only where an offload does not remove them: IPv4 headers, and packets of the NAT itself.
- The policy at line rate. The lists compile to a sorted table of address ranges with port masks, searched with a branch-free binary search, and host names become address entries as DNS answers arrive. A lookup is under 20 ns. A JIT of the table with the assembler of ztcl comes only if a measurement shows the table as a cost.

## Start time

On macOS (#490), the network adds 0.53 ms before the agent listens, and about 0.4 ms of it is the open of the virtio-net driver, which fills its receive ring. Two changes on the host side cut this, with no change to the kernel:

- The queue size. The monitor gives QueueNumMax, and the driver fills each entry of the receive queue at open. With mergeable receive buffers, one entry is one buffer, so a smaller ring has the same largest frame but fewer buffers in flight. The plan: a QueueNumMax for each device in `mmio.zig` (256 now, for each device), then the boot cost and the throughput of TCP at 64, 128, and 256 entries. The default is the smallest size that keeps the throughput of 256 for one stream and for 8 streams. This measurement needs TCP (step 3).
- The pool. A guest with `-net nat` comes from no pool today. The design: a guest of the pool boots with the device and with no engine. The driver opens the device and fills its receive ring in the pool. At the take, `create` makes the engine of the guest with its own configuration (the policy, `-allow`, `-deny`, `-forward`, `-dns`), attaches it to the device, and the agent runs DHCP after the resume. On KVM, the attach registers the two ioeventfds of the device with the engine and starts its thread. Before the attach, a notify of the guest only sets the eventfd, and the engine reads the transmit queue at its start. The key of the pool gets a bit for `-net`, so a guest with no network never gets a device. A frame of the guest before the take (such as a DHCP DISCOVER of the agent) waits in the transmit queue and gets its answer after the take.

## Measurements

Each step publishes its numbers in this file. Each number is measured on the same host as the references, with no source of them read:

- Throughput from the guest to the host and from the host to the guest, one stream and 8 streams (`iperf3` or a Zig tool in the guest against a host server).
- The time of a round trip (TCP request and answer of 1 byte), and connections per second.
- CPU time per gigabit.
- The references: QEMU with passt and with slirp, and gVisor netstack, as programs under test only.

### Results

- Step 2, KVM, 2026-11-27, x86-64 host with a load average of 12: `ping -c 200 -i 0.01 10.0.2.2` in the guest gives a round trip of 0.114 ms at best and 0.194 ms on average. The engine answers the echo itself, so this is the time of the device and the interrupt path. No reference program ran yet.

## Steps

1. This plan.
2. The virtio-net device with the split ring, event index, and checksum offload, and a NAT with ARP, DHCP, ICMP echo, UDP, and DNS, on KVM. The test boots a guest with `-net nat ip=dhcp` and sends UDP to a server on the host loopback.
3. TCP in the NAT, with TSO and mergeable receive buffers. The test fetches a page from a local HTTP server with `wget` of BusyBox, and measures the throughput.
4. The policy, `ztcl::vm netlog`, and `-forward`. Tests: allow and deny, DNS, a port forward, and a guest without `-net nat` that has no network device.
5. The speed work, one measured change at a time: io_uring, MSG_ZEROCOPY, the packed ring, multiqueue.
6. WHP and macOS on the same NAT.

The guest kernel needs `CONFIG_INET`, `CONFIG_VIRTIO_NET`, `CONFIG_IP_PNP`, and `CONFIG_IP_PNP_DHCP` (so `ip=dhcp` on the command line configures the device with no DHCP client in the guest). `tools/vm-guest/kernel.fragment` gets them in step 2. The kernel of beetlebugorg/ztcl-guest-kernel gets them through its own repository.
