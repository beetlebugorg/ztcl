# thread::transfer, thread::detach, and thread::attach.
# thread-tests-flags: --allow channels,file,socket,exec --exec-allow cat
# SPDX-License-Identifier: BSD-2-Clause

set main [thread::id]
set t [thread::create]

# A file channel moves to a thread. Its buffered output goes out first.
set f [open data.txt w]
puts $f line1
thread::transfer $t $f
test file-1 {file exists data.txt} 1
test file-2 {thread::send $t [list puts $f line2]; thread::send $t [list close $f]} {}
test file-3 {set r [open data.txt]; set x [read $r]; close $r; set x} "line1\nline2\n"
test file-4 {lsearch [file channels] $f} -1

# Buffered input moves with the channel, and the channel comes back.
set r [open data.txt]
test in-1 {gets $r} line1
thread::transfer $t $r
test in-2 {thread::send $t [list gets $r]} line2
test in-3 {thread::send $t [list thread::transfer $main $r]; eof $r} 0
test in-4 {gets $r; eof $r} 1
close $r

# detach and attach in two steps.
set r [open data.txt]
test detach-1 {thread::detach $r; lsearch [file channels] $r} -1
test detach-2 {thread::send $t [list thread::attach $r]; thread::send $t [list gets $r]} line1
test detach-3 {thread::send $t [list close $r]} {}
test attach-1 {thread::attach $r} {!channel not detached}
test detach-4 {thread::detach nope} {!can not find channel named "nope"}
test transfer-1 {thread::transfer $t nope} {!can not find channel named "nope"}
test transfer-2 {thread::transfer tid0x999 nope} {!thread "tid0x999" does not exist}
test args-1 {thread::detach} {!wrong # args: should be "thread::detach channel"}
test args-2 {thread::attach} {!wrong # args: should be "thread::attach channel"}
test args-3 {thread::transfer a} {!wrong # args: should be "thread::transfer id channel"}

# A loopback socket moves to a thread and back.
proc accept {c a p} {set ::conn $c}
set srv [socket -server accept -myaddr 127.0.0.1 0]
set port [lindex [fconfigure $srv -sockname] 2]
set cl [socket 127.0.0.1 $port]
vwait ::conn
fconfigure $::conn -buffering line
thread::transfer $t $cl
test sock-1 {thread::send $t [list puts $cl hello]; thread::send $t [list flush $cl]; gets $::conn} hello
puts $::conn reply
test sock-2 {thread::send $t [list gets $cl]} reply
thread::send $t [list thread::transfer $main $cl]
test sock-3 {puts $cl back; flush $cl; gets $::conn} back

# The kinds that stay with their thread.
test refuse-1 {thread::transfer $t $srv} "!cannot move server socket \"$srv\""
set p [open |cat r+]
test refuse-2 {thread::transfer $t $p} "!cannot move command pipeline \"$p\""
close $p
fileevent $cl readable {set x 1}
test refuse-3 {thread::transfer $t $cl} "!cannot move channel \"$cl\" with a fileevent handler"
fileevent $cl readable {}
test refuse-4 {thread::transfer $t $cl; thread::send $t [list close $cl]} {}
close $::conn
close $srv

# A channel that is still detached at the end of the group closes.
set r [open data.txt]
thread::detach $r
done
