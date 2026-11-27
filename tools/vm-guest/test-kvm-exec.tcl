# The test of `exec -vm` and `open "|-vm ..."` (ztcl#577) on a guest of
# ztcl::vm (test-kvm.sh runs it in GUESTDIR, with the root folder there).
proc check {what got want} {
    if {$got ne $want} { error "$what: got \"$got\", want \"$want\"" }
    puts "ok: $what"
}
set kernel bzImage
if {[file exists kernel.name]} {
    set f [open kernel.name]; set kernel [read $f]; close $f
}
set vm [ztcl::vm create -kernel $kernel -initrd agent.cpio -cmdline "rdinit=/sbin/agent quiet" -memory 64]
ztcl::vm start $vm
set bb /bin/busybox

check "exec -vm: stdout" [exec -vm $vm $bb echo hello] hello
check "exec -vm: a bare name goes through the PATH of the guest" [exec -vm $vm busybox echo hi] hi
check "exec -vm: a pipeline in one guest" [exec -vm $vm $bb echo a b c | $bb wc -w] 3
check "exec -vm: three programs" [exec -vm $vm $bb printf "x\ny\nx\n" | $bb sort | $bb uniq] "x\ny"
check "exec -vm: << input" [exec -vm $vm $bb cat << "from the host"] "from the host"
check "exec -vm: -keepnewline" [exec -vm $vm -keepnewline $bb echo k] "k\n"
check "exec -vm: the guest is not the host" [exec -vm $vm $bb cat /proc/sys/kernel/hostname] [exec -vm $vm $bb hostname]

# Errors as for a process of the host.
check "exec -vm: an exit code" [catch {exec -vm $vm $bb sh -c {exit 3}} msg] 1
check "exec -vm: CHILDSTATUS" [lindex $::errorCode 0] CHILDSTATUS
check "exec -vm: the exit code in the code" [lindex $::errorCode 2] 3
check "exec -vm: stderr is an error" [catch {exec -vm $vm $bb sh -c {echo bad >&2}} msg] 1
check "exec -vm: the stderr text" $msg bad
check "exec -vm: -ignorestderr" [exec -vm $vm -ignorestderr $bb sh -c {echo ok; echo bad >&2}] ok
check "exec -vm: 2>@1" [exec -vm $vm $bb sh -c {echo bad >&2} 2>@1] bad
check "exec -vm: |& to the next program" [exec -vm $vm $bb sh -c {echo e >&2} |& $bb wc -l] 1
check "exec -vm: a missing program" [catch {exec -vm $vm /nope} msg] 1
check "exec -vm: its error code" [lrange $::errorCode 0 1] {POSIX ENOENT}
check "exec -vm: a missing bare name" [catch {exec -vm $vm no-such-tool} msg] 1
check "exec -vm: a signal" [catch {exec -vm $vm $bb sh -c {kill -9 $$}} msg] 1
check "exec -vm: CHILDKILLED" [lrange $::errorCode 0 0] CHILDKILLED
check "exec -vm: a missing guest" [catch {exec -vm vm999 $bb true} msg] 1
check "exec -vm: its code" [lrange $::errorCode 0 2] {ZTCL VM NAME}

# Redirections are copies through the host, under the root folder.
set f [open in.txt w]; puts -nonewline $f "line1\nline2\n"; close $f
check "exec -vm: < file" [exec -vm $vm $bb wc -l < in.txt] 2
exec -vm $vm $bb echo saved > out.txt
set f [open out.txt]; check "exec -vm: > file" [read $f] "saved\n"; close $f
exec -vm $vm $bb echo more >> out.txt
set f [open out.txt]; check "exec -vm: >> file" [read $f] "saved\nmore\n"; close $f
check "exec -vm: a path outside the root" [catch {exec -vm $vm $bb cat < /etc/passwd} msg] 1
check "exec -vm: the guest gets no host path" [catch {exec -vm $vm $bb cat [file normalize in.txt]}] 1
file delete in.txt out.txt

# A large stream through a pipeline: the queues keep the bound.
check "exec -vm: 4 MB through two programs" [exec -vm $vm $bb head -c 4000000 /dev/zero | $bb wc -c] 4000000
# A reader that ends first: the writer gets SIGPIPE.
check "exec -vm: yes | head" [catch {exec -vm $vm $bb yes | $bb head -n 2} msg] 1
check "exec -vm: the output of head" [string range $msg 0 2] "y\ny"
check "exec -vm: SIGPIPE for yes" [lrange $::errorCode 0 0][lindex $::errorCode 2] CHILDKILLEDSIGPIPE

# The background, pid, and a channel.
set pids [exec -vm $vm $bb sleep 0 &]
check "exec -vm &: one pid" [llength $pids] 1
check "exec -vm &: a guest pid" [string is integer -strict [lindex $pids 0]] 1
set ch [open "|-vm $vm $bb cat" r+]
check "open |-vm: a pid" [llength [pid $ch]] 1
puts $ch "through the guest"
flush $ch
check "open |-vm: a line back" [gets $ch] "through the guest"
close $ch
set ch [open "|-vm $vm $bb sh -c {exit 4}"]
check "open |-vm: close gives the exit" [catch {close $ch}] 1
check "open |-vm: CHILDSTATUS" [lindex $::errorCode 2] 4
set ch [open "|-vm $vm $bb seq 1 3"]
check "open |-vm: read" [read $ch] "1\n2\n3\n"
close $ch

# The kill of a channel that does not block, and of the interpreter end.
set ch [open "|-vm $vm $bb sleep 60"]
fconfigure $ch -blocking 0
close $ch

# Latency of a small exec in a running guest, best of 20.
set best 1e9
for {set i 0} {$i < 20} {incr i} {
    set t [clock microseconds]
    exec -vm $vm $bb true
    set d [expr {[clock microseconds] - $t}]
    if {$d < $best} { set best $d }
}
puts "exec -vm true: best of 20: $best us"
ztcl::vm stop $vm -force
ztcl::vm delete $vm
puts "all ok"
