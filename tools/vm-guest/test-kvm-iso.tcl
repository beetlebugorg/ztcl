# The boot test of `thread::create -isolation vm` on Linux with KVM
# (test-kvm.sh runs it, ztcl#613): the first vm thread boots the guest of
# the runner (iso.cpio of pack-iso.sh) and takes its snapshot, and the
# later ones are clones. Each thread answers a send. test-kvm.sh stops
# the run after 120 s, so a guest that does not start fails the test.
proc check {what got want} {
    if {$got ne $want} { error "$what: got \"$got\", want \"$want\"" }
    puts "ok: $what"
}
set ts {}
for {set i 0} {$i < 3} {incr i} {
    set t0 [clock milliseconds]
    lappend ts [thread::create -isolation vm {thread::wait}]
    puts "vm thread $i: [expr {[clock milliseconds] - $t0}] ms"
}
foreach t $ts {
    check "a send to the vm thread $t" [thread::send $t {expr {6 * 7}}] 42
    thread::release $t
}
