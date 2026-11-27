# The boot test of ztcl::vm on a Mac with the hypervisor (test.sh runs
# it): the guest of tools/vm-guest boots, the probe of the agent echoes
# over vsock, the agent runs programs and mounts a share, a stopped guest
# starts again, and a warm guest answers after start.
proc check {what got want} {
    if {$got ne $want} { error "$what: got \"$got\", want \"$want\"" }
    puts "ok: $what"
}
set boot {-kernel Image -initrd agent.cpio -cmdline "rdinit=/sbin/agent quiet" -memory 64}
file mkdir share
file delete -force share/from-guest.txt
set f [open share/hello.txt w]; puts -nonewline $f "from the host"; close $f
set vm [ztcl::vm create {*}$boot -share {share /mnt/share rw}]
check "a new guest" [ztcl::vm status $vm] created
ztcl::vm start $vm
check "a started guest" [ztcl::vm status $vm] running
set ch [ztcl::vm vsock $vm 1025]
read $ch 16
puts -nonewline $ch "hello from tcl\n"
flush $ch
check "the echo over vsock" [gets $ch] "hello from tcl"
close $ch
set r [ztcl::vm exec $vm /bin/busybox sh -c {echo out; echo err >&2; exit 3}]
check "exec: the exit code" [dict get $r exit] 3
check "exec: stdout" [dict get $r stdout] "out\n"
check "exec: stderr" [dict get $r stderr] "err\n"
check "exec: stdin" [dict get [ztcl::vm exec $vm -stdin "a b c" /bin/busybox wc -w] stdout] "3\n"
check "exec: a missing program" [catch {ztcl::vm exec $vm /nope}] 1
check "exec: its error code" [lrange $::errorCode 0 2] {ZTCL VM AGENT}
check "the share at /mnt/share" [dict get [ztcl::vm exec $vm /bin/busybox cat /mnt/share/hello.txt] stdout] "from the host"
ztcl::vm exec $vm /bin/busybox sh -c {echo written by the guest > /mnt/share/from-guest.txt}
check "the file of the guest in the share" [file exists share/from-guest.txt] 1
ztcl::vm mount $vm share0 /mnt/ro -readonly
check "a read-only mount" [dict get [ztcl::vm exec $vm /bin/busybox sh -c {echo x > /mnt/ro/x 2>/dev/null; echo $?}] stdout] "1\n"
ztcl::vm stop $vm -force
check "a stopped guest" [ztcl::vm status $vm] stopped
ztcl::vm start $vm
check "a guest that started again" [ztcl::vm status $vm] running
close [ztcl::vm vsock $vm 1025]
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
puts "warm start to the agent: $ms ms"
