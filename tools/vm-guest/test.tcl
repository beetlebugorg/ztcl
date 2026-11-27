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
# Text goes as UTF-8; with -binary 1, each character is one byte.
set od {/bin/busybox od -An -tx1}
check "exec: UTF-8 stdin" [string trim [dict get [ztcl::vm exec $vm -stdin "h\u00e9 \u4e16" {*}$od] stdout]] "68 c3 a9 20 e4 b8 96"
check "exec: UTF-8 stdout" [dict get [ztcl::vm exec $vm -stdin "h\u00e9 \u4e16" /bin/busybox cat] stdout] "h\u00e9 \u4e16"
set bin [binary format H* 00ff80c3a90a7f]
check "exec: binary stdin" [string trim [dict get [ztcl::vm exec $vm -binary 1 -stdin $bin {*}$od] stdout]] "00 ff 80 c3 a9 0a 7f"
check "exec: binary stdin and stdout" [dict get [ztcl::vm exec $vm -binary 1 -stdin $bin /bin/busybox cat] stdout] $bin
check "exec: a missing program" [catch {ztcl::vm exec $vm /nope}] 1
check "exec: its error code" [lrange $::errorCode 0 2] {ZTCL VM AGENT}
check "the share at /mnt/share" [dict get [ztcl::vm exec $vm /bin/busybox cat /mnt/share/hello.txt] stdout] "from the host"
ztcl::vm exec $vm /bin/busybox sh -c {echo written by the guest > /mnt/share/from-guest.txt}
check "the file of the guest in the share" [file exists share/from-guest.txt] 1
ztcl::vm mount $vm share0 /mnt/ro -readonly
check "a read-only mount" [dict get [ztcl::vm exec $vm /bin/busybox sh -c {echo x > /mnt/ro/x 2>/dev/null; echo $?}] stdout] "1\n"
proc served {ch} {
    fconfigure $ch -translation lf -buffering line
    puts $ch "host got: [gets $ch]"
    close $ch
    set ::served 1
}
ztcl::vm listen $vm 3000 -command served
ztcl::vm exec $vm /bin/busybox sh -c {(echo hi | /sbin/agent connect 3000 > /tmp/out 2>&1 &)}
after 5000 {set ::served timeout}
vwait ::served
after 200
check "a connection of the guest to the host" [dict get [ztcl::vm exec $vm /bin/busybox cat /tmp/out] stdout] "host got: hi\n"
ztcl::vm unlisten $vm 3000
check "no connection after unlisten" [dict get [ztcl::vm exec $vm /bin/busybox sh -c {echo x | /sbin/agent connect 3000 2>/dev/null; echo $?}] stdout] "1\n"
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
