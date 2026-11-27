# test-kvm-image.sh runs it twice: with the release as it is (mode
# "good"), then with one byte of the root disk changed in the store
# (mode "bad").
proc check {what got want} {
    if {$got ne $want} { error "$what: got \"$got\", want \"$want\"" }
    puts "ok: $what"
}
set f [open mode]; set mode [read $f]; close $f
set sh {/bin/busybox sh -c}
if {$mode eq "good"} {
    check "the install" [dict get [ztcl::vm image install rel] name] ztcl-guest-test
    check "-image with -kernel" [catch {ztcl::vm create -image ztcl-guest-test -kernel x}] 1
    set t0 [clock microseconds]
    set vm [ztcl::vm create -image ztcl-guest-test -memory 128]
    ztcl::vm start $vm
    set r [ztcl::vm exec $vm {*}$sh {/bin/busybox cat /sys/block/dm-0/dm/name /sys/block/dm-0/dm/uuid 2>&1; /bin/busybox grep " / " /proc/mounts}]
    puts "start to the first exec: [expr {([clock microseconds] - $t0) / 1000.0}] ms"
    check "the root is dm-verity on squashfs" [string match "root*squashfs ro*" [string map {\n " "} [dict get $r stdout]]] 1
    check "the root is read-only" [dict get [ztcl::vm exec $vm {*}$sh {echo x > /x 2>/dev/null; echo $?}] stdout] "1\n"
    ztcl::vm delete $vm
    # The pool (1 guest, the default of the runner): the first create
    # started a thread that boots a guest of the image and pauses it. A
    # create then gets it, and the thread boots the next one.
    # The runner of the test has no event loop, so the wait is a loop on
    # the clock.
    proc wait {ms} {
        set end [expr {[clock milliseconds] + $ms}]
        while {[clock milliseconds] < $end} {}
    }
    proc firstExec {} {
        set t0 [clock microseconds]
        set vm [ztcl::vm create -image ztcl-guest-test -memory 128]
        set pooled [expr {[ztcl::vm status $vm] eq "paused"}]
        ztcl::vm start $vm
        set r [ztcl::vm exec $vm /bin/busybox cat /sys/block/dm-0/dm/name]
        set ms [expr {([clock microseconds] - $t0) / 1000.0}]
        ztcl::vm delete $vm
        return [list $pooled $ms [dict get $r stdout]]
    }
    wait 1000
    set pooled {}
    set times {}
    for {set i 0} {$i < 10} {incr i} {
        lassign [firstExec] p ms out
        check "a guest of the pool on dm-verity" $out "root\n"
        lappend pooled $p
        lappend times $ms
        wait 1000
    }
    check "each create took a guest of the pool" [lsort -unique $pooled] 1
    puts "create, start, and the first exec from the pool (ms, median of 10): [lindex [lsort -real $times] 5]"
} else {
    set vm [ztcl::vm create -image ztcl-guest-test -memory 128]
    ztcl::vm start $vm
    check "a changed root disk gives no agent" [catch {ztcl::vm exec $vm -timeout 3000 /bin/busybox true}] 1
    ztcl::vm delete $vm
}
