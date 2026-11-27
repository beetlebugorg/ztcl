# The boot test of ztcl::vm on Linux with KVM (test-kvm.sh runs it): the
# x86-64 guest of tools/vm-guest boots, the probe of the agent echoes over vsock (port 1025), the
# agent runs programs, the guest reads a disk, a stopped guest starts again, and a warm guest
# answers after start. Then the times of a start, best of 10.
proc check {what got want} {
    if {$got ne $want} { error "$what: got \"$got\", want \"$want\"" }
    puts "ok: $what"
}
# test-kvm.sh writes the name of the kernel (KERNEL) to kernel.name.
set kernel bzImage
if {[file exists kernel.name]} {
    set f [open kernel.name]; set kernel [read $f]; close $f
}
puts "kernel: $kernel"
set boot [list -kernel $kernel -initrd agent.cpio -cmdline "rdinit=/sbin/agent quiet" -memory 64]

# The boot time of the guest, in ns, from the 16 bytes of the agent.
proc hello {ch} {
    binary scan [read $ch 16] ww main listen
    return $main
}

set vm [ztcl::vm create {*}$boot]
check "a new guest" [ztcl::vm status $vm] created
ztcl::vm start $vm
check "a started guest" [ztcl::vm status $vm] running
set ch [ztcl::vm vsock $vm 1025]
hello $ch
puts -nonewline $ch "hello from tcl\n"
flush $ch
check "the echo over vsock" [gets $ch] "hello from tcl"
close $ch
ztcl::vm stop $vm -force
check "a stopped guest" [ztcl::vm status $vm] stopped
ztcl::vm start $vm
check "a guest that started again" [ztcl::vm status $vm] running
close [ztcl::vm vsock $vm 1025]

# The agent on port 1024 runs programs.
set r [ztcl::vm exec $vm /bin/busybox sh -c {echo out; echo err >&2; exit 3}]
check "exec: the exit code" [dict get $r exit] 3
check "exec: stdout" [dict get $r stdout] "out\n"
check "exec: stderr" [dict get $r stderr] "err\n"
check "exec: stdin" [dict get [ztcl::vm exec $vm -stdin "a b c" /bin/busybox wc -w] stdout] "3\n"
# Text goes as UTF-8; with -binary 1, each character is one byte.
set od {/bin/busybox od -An -tx1}
check "exec: UTF-8 stdin" [string trim [dict get [ztcl::vm exec $vm -stdin "h\u00e9 \u4e16" {*}$od] stdout]] "68 c3 a9 20 e4 b8 96"
check "exec: UTF-8 stdout" [dict get [ztcl::vm exec $vm -stdin "h\u00e9 \u4e16" /bin/busybox cat] stdout] "h\u00e9 \u4e16"
set bin [binary format H* 00ff80c3a90a7f]
check "exec: binary stdin" [string trim [dict get [ztcl::vm exec $vm -binary 1 -stdin $bin {*}$od] stdout]] "00 ff 80 c3 a9 0a 7f"
check "exec: binary stdin and stdout" [dict get [ztcl::vm exec $vm -binary 1 -stdin $bin /bin/busybox cat] stdout] $bin
check "exec: -cwd and -env" [dict get [ztcl::vm exec $vm -cwd /tmp -env {Z=1} /bin/busybox sh -c {echo $PWD $Z}] stdout] "/tmp 1\n"
check "exec: a missing program" [catch {ztcl::vm exec $vm /nope}] 1
check "exec: its error code" [lrange $::errorCode 0 2] {ZTCL VM AGENT}
check "mount: a missing share" [catch {ztcl::vm mount $vm share9 /mnt/x}] 1
ztcl::vm delete $vm

# Shares with 9p: share0 at /mnt/share (rw), share1 read-only.
file delete -force share ro
file mkdir share/sub ro
set f [open share/hello.txt w]; puts -nonewline $f "from the host"; close $f
set f [open ro/x.txt w]; puts -nonewline $f "read only"; close $f
set vm [ztcl::vm create {*}$boot -share {share /mnt/share rw} -share {ro /mnt/ro}]
ztcl::vm start $vm
set sh {/bin/busybox sh -c}
check "the share at /mnt/share" [dict get [ztcl::vm exec $vm /bin/busybox cat /mnt/share/hello.txt] stdout] "from the host"
ztcl::vm exec $vm {*}$sh {echo written by the guest > /mnt/share/sub/from-guest.txt}
set f [open share/sub/from-guest.txt]; set got [read $f]; close $f
check "a file of the guest on the host" $got "written by the guest\n"
check "a listing of the share" [dict get [ztcl::vm exec $vm /bin/busybox ls /mnt/share] stdout] "hello.txt\nsub\n"
# The image has BusyBox with no links of its applets.
set r [ztcl::vm exec $vm {*}$sh {b=/bin/busybox; cd /mnt/share && $b mkdir d && $b mv sub/from-guest.txt d/f && $b ln -s f d/l && $b cat d/l > d/copy && $b rm -r sub && $b chmod 600 d/copy && $b truncate -s 3 d/copy}]
check "the work of the guest" [dict get $r exit]:[dict get $r stderr] 0:
check "the work of the guest on the host" [lsort [glob -tails -directory share/d *]] {copy f l}
check "a truncated file" [file size share/d/copy] 3
check "a link stays a link" [dict get [ztcl::vm exec $vm /bin/busybox readlink /mnt/share/d/l] stdout] "f\n"
ztcl::vm exec $vm /bin/busybox ln -s .. /mnt/share/up
check "a link out of the share goes to the guest" [dict get [ztcl::vm exec $vm /bin/busybox ls /mnt/share/up] stdout] "share\n"
ztcl::vm mount $vm share1 /mnt/ro -readonly
check "the read-only share" [dict get [ztcl::vm exec $vm /bin/busybox cat /mnt/ro/x.txt] stdout] "read only"
check "a write to the read-only share" [dict get [ztcl::vm exec $vm {*}$sh {echo x > /mnt/ro/y 2>/dev/null; echo $?}] stdout] "1\n"
ztcl::vm delete $vm
check "no write reached the read-only folder" [glob -tails -directory ro *] x.txt
file delete -force share ro

# The kernel log of a guest, from the agent: a first byte of 1 asks
# for it.
proc dmesg {vm} {
    set ch [ztcl::vm vsock $vm 1025]
    read $ch 16
    puts -nonewline $ch "\x01"
    flush $ch
    set log ""
    while {![string match "*Run /sbin/agent*" $log]} {
        set got [read $ch 1]
        if {$got eq ""} break
        append log $got [chan read $ch [chan pending input $ch]]
    }
    close $ch
    return $log
}

set nq [lreplace $boot 5 5 "rdinit=/sbin/agent"]
set vm [ztcl::vm create {*}$nq -cpus 2]
ztcl::vm start $vm
check "two CPUs" [string match "*Total of 2 processors activated*" [dmesg $vm]] 1
ztcl::vm delete $vm

# A disk: the guest has /dev/vda, read-only.
set f [open disk.img w]
fconfigure $f -translation binary
puts -nonewline $f [string repeat "ztcl disk block\n" 4096]
close $f
set vm [ztcl::vm create {*}$nq -disk disk.img -entropy 1]
ztcl::vm start $vm
set log [dmesg $vm]
check "the disk in the log" [string match "*vda*128 512-byte*" $log] 1
check "the entropy device" [string match "*virtio-mmio.3 at 0xd0003000*" $log] 1
check "the bytes of the disk" [dict get [ztcl::vm exec $vm /bin/busybox head -c 32 /dev/vda] stdout] [string repeat "ztcl disk block\n" 2]
check "random bytes" [dict get [ztcl::vm exec $vm /bin/busybox sh -c {/bin/busybox head -c 16 /dev/hwrng | /bin/busybox wc -c}] stdout] "16\n"
ztcl::vm delete $vm

# The console: the kernel log of a guest on hvc0.
set vm [ztcl::vm create {*}[lreplace $boot 5 5 "rdinit=/sbin/agent console=hvc0"]]
set con [ztcl::vm console $vm]
ztcl::vm start $vm
close [ztcl::vm vsock $vm 1025]
fconfigure $con -blocking 0
check "the kernel log on the console" [string match "*Run /sbin/agent*" [read $con]] 1
ztcl::vm delete $vm

set w [ztcl::vm create {*}$boot -warm 1]
check "a warm guest" [ztcl::vm status $w] paused
set t [clock microseconds]
ztcl::vm start $w
set ch [ztcl::vm vsock $w 1025]
read $ch 16
set ms [expr {([clock microseconds] - $t) / 1000.0}]
close $ch
check "a warm start under 20 ms" [expr {$ms < 20}] 1
ztcl::vm delete $w

# The times, best of 10: start (the setup of KVM and the load of the
# kernel), start to the answer of the agent, the boot clock of the
# guest when the agent runs, and a warm start to the answer.
proc best {list} { lindex [lsort -real $list] 0 }
set starts {}; set answers {}; set boots {}; set warms {}
for {set i 0} {$i < 10} {incr i} {
    set vm [ztcl::vm create {*}$boot]
    set t0 [clock microseconds]
    ztcl::vm start $vm
    set t1 [clock microseconds]
    set ch [ztcl::vm vsock $vm 1025]
    set main [hello $ch]
    set t2 [clock microseconds]
    close $ch
    ztcl::vm delete $vm
    lappend starts [expr {($t1 - $t0) / 1000.0}]
    lappend answers [expr {($t2 - $t0) / 1000.0}]
    lappend boots [expr {$main / 1e6}]
    set w [ztcl::vm create {*}$boot -warm 1]
    set t0 [clock microseconds]
    ztcl::vm start $w
    set ch [ztcl::vm vsock $w 1025]
    read $ch 16
    lappend warms [expr {([clock microseconds] - $t0) / 1000.0}]
    close $ch
    ztcl::vm delete $w
}
puts [format "times (ms, best of 10): start %.2f, start to answer %.2f, guest boot to agent %.2f, warm start to answer %.3f" \
    [best $starts] [best $answers] [best $boots] [best $warms]]
