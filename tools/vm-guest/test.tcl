# The boot test of ztcl::vm on a Mac with the hypervisor (test.sh runs
# it): the guest of tools/vm-guest boots, the agent echoes over vsock, the
# guest writes a file in a share, a stopped guest starts again, and a
# warm guest answers after start.
proc check {what got want} {
    if {$got ne $want} { error "$what: got \"$got\", want \"$want\"" }
    puts "ok: $what"
}
set boot {-kernel Image -initrd agent.cpio -cmdline "rdinit=/sbin/agent quiet" -memory 64}
file mkdir share
file delete -force share/from-guest.txt
set vm [ztcl::vm create {*}$boot -share {share /mnt/share rw}]
check "a new guest" [ztcl::vm status $vm] created
ztcl::vm start $vm
check "a started guest" [ztcl::vm status $vm] running
set ch [ztcl::vm vsock $vm 1024]
read $ch 16
puts -nonewline $ch "hello from tcl\n"
flush $ch
check "the echo over vsock" [gets $ch] "hello from tcl"
close $ch
check "the file of the guest in the share" [file exists share/from-guest.txt] 1
ztcl::vm stop $vm -force
check "a stopped guest" [ztcl::vm status $vm] stopped
ztcl::vm start $vm
check "a guest that started again" [ztcl::vm status $vm] running
close [ztcl::vm vsock $vm 1024]
ztcl::vm delete $vm
set w [ztcl::vm create {*}$boot -warm 1]
check "a warm guest" [ztcl::vm status $w] paused
set t [clock microseconds]
ztcl::vm start $w
set ch [ztcl::vm vsock $w 1024]
read $ch 16
set ms [expr {([clock microseconds] - $t) / 1000.0}]
close $ch
check "a warm start under 20 ms" [expr {$ms < 20}] 1
puts "warm start to the agent: $ms ms"
