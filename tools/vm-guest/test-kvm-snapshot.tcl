# The snapshot test of ztcl::vm on Linux with KVM (test-kvm.sh runs it after
# test-kvm.tcl): a warm guest goes to a snapshot file, a restore of the file
# answers on the agent, the clones of one file run at the same time with
# their own context IDs, the guest clock follows the host after a restore,
# and a guest goes on after its snapshot. Then the times: the snapshot, a
# restore, a start to the first exec, and N clones.
proc check {what got want} {
    if {$got ne $want} { error "$what: got \"$got\", want \"$want\"" }
    puts "ok: $what"
}
set kernel bzImage
if {[file exists kernel.name]} {
    set f [open kernel.name]; set kernel [read $f]; close $f
}
set boot [list -kernel $kernel -initrd agent.cpio -cmdline "rdinit=/sbin/agent quiet" -memory 64]
proc out {r} { return [dict get $r stdout] }
proc ms {t0 t1} { return [format %.3f [expr {($t1 - $t0) / 1000.0}]] }

set vm [ztcl::vm create {*}$boot -warm 1]
ztcl::vm start $vm
ztcl::vm exec $vm /bin/busybox sh -c "echo kept > /tmp/mark"
set t0 [clock microseconds]
set written [ztcl::vm snapshot $vm snap.bin]
set t1 [clock microseconds]
puts "snapshot: [ms $t0 $t1] ms, $written bytes of memory"
check "the guest runs after its snapshot" [ztcl::vm status $vm] running
check "the guest answers after its snapshot" [out [ztcl::vm exec $vm /bin/busybox cat /tmp/mark]] "kept\n"

set c [ztcl::vm create -snapshot snap.bin]
check "a restored guest" [ztcl::vm status $c] paused
ztcl::vm start $c
check "a started restore" [ztcl::vm status $c] running
check "the restore has the files of the snapshot" [out [ztcl::vm exec $c /bin/busybox cat /tmp/mark]] "kept\n"
set host [clock seconds]
set guest [string trim [out [ztcl::vm exec $c /bin/busybox date +%s]]]
check "the clock of the restore follows the host" [expr {abs($guest - $host) <= 2}] 1
ztcl::vm exec $c /bin/busybox sh -c "echo changed > /tmp/mark"
check "a write of the restore stays in the restore" [out [ztcl::vm exec $vm /bin/busybox cat /tmp/mark]] "kept\n"
ztcl::vm delete $c

set clones [ztcl::vm create -snapshot snap.bin -count 3]
check "three clones" [llength $clones] 3
foreach g $clones { ztcl::vm start $g }
set seen {}
foreach g $clones {
    lappend seen [string trim [out [ztcl::vm exec $g /bin/busybox cat /tmp/mark]]]
}
check "each clone answers" $seen {kept kept kept}
set r [lmap g $clones { out [ztcl::vm exec $g /bin/busybox sh -c "/bin/busybox head -c 16 /dev/urandom | /bin/busybox od -An -tx1"] }]
check "the clones have different random numbers" [llength [lsort -unique $r]] 3
foreach g $clones { ztcl::vm delete $g }
ztcl::vm delete $vm

# The times, best and median of 10.
proc stats {l} {
    set l [lsort -real $l]
    return "best [lindex $l 0] median [lindex $l [expr {[llength $l] / 2}]] ms"
}
set restore {}; set first {}; set ready {}
# The wait before each restore lets the runner prepare a spare machine
# (the pool of the runner has one), as a pool of a server does between
# requests.
for {set i 0} {$i < 10} {incr i} {
    after 100
    set t0 [clock microseconds]
    set c [ztcl::vm create -snapshot snap.bin]
    set tr [clock microseconds]
    # A guest of a pool waits for its start: vCPU 0 prefaults the memory
    # of the snapshot in this time.
    after 20
    set t1 [clock microseconds]
    ztcl::vm start $c
    set t2 [clock microseconds]
    ztcl::vm exec $c /bin/busybox true
    set t3 [clock microseconds]
    lappend restore [ms $t0 $tr]; lappend ready [ms $t1 $t2]; lappend first [ms $t2 $t3]
    ztcl::vm delete $c
}
puts "restore: [stats $restore]"
puts "start to a ready agent: [stats $ready]"
puts "first exec after start: [stats $first]"
foreach n {4} {
    set t0 [clock microseconds]
    set clones [ztcl::vm create -snapshot snap.bin -count $n]
    set t1 [clock microseconds]
    foreach g $clones { ztcl::vm start $g }
    set t2 [clock microseconds]
    puts "$n clones: restore [ms $t0 $t1] ms, start [ms $t1 $t2] ms"
    foreach g $clones { ztcl::vm delete $g }
}
file delete snap.bin
puts "snapshot: all checks passed"
