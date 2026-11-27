# The checks of the channel slots from scripts: tests/cext/cxfile.c. A
# script reads and writes a channel of a C package with the channel
# commands, a transform stacks on a channel of `open`, and C code opens
# files. The WebAssembly library has no channel commands, so only the
# native path runs this script.
puts [catch {load $dir/cxfile.so} msg]:$msg
set m [cxchan open]
puts $m "hello"
puts -nonewline $m "world\nline3"
puts [cxchan info $m]
flush $m
puts [cxchan raw $m]
puts [tell $m]
seek $m 0
puts [gets $m]
puts [gets $m line]:$line
puts [read $m 3]
puts [read $m]
puts [eof $m]
puts [gets $m line]:$line
puts [fconfigure $m]
puts [fconfigure $m -size]
fconfigure $m -translation crlf -buffering line
puts [fconfigure $m -translation]
puts [catch {fconfigure $m -bogus 1} e]:$e
puts [catch {fconfigure $m -buffering bad} e]:$e
puts $m "crlf"
puts [string map {\r <CR>} [cxchan raw $m]]
seek $m 0
fconfigure $m -translation auto
puts [read -nonewline $m]
puts [chan pending output $m]
puts [chan pending input $m]
puts [catch {seek $m -100} e]:$e
puts [chan names mem*]
seek $m 0
puts [chan gets $m]
chan configure $m -blocking 0
puts [fblocked $m]
close $m
puts [cxchan closed]
puts [catch {puts $m x} e]:$e
set r [cxchan open r]
puts [catch {puts $r x} e]:$e
puts [catch {flush $r} e]:$e
puts [gets $r]:[eof $r]
close $r
cxchan closed
# A transform on a channel of `open`.
set path $dir/rot.txt
set f [open $path w]
puts [cxchan push $f]
puts $f "Hello, World"
puts [fconfigure $f -translation]
close $f
puts [cxchan closed]
set f [open $path]
puts [read $f]
close $f
set f [open $path]
cxchan push $f
puts [gets $f]
puts [lrange [cxchan info $f] 1 end]
puts [cxchan pop $f]
close $f
puts [cxchan closed]
# C opens files.
set g [cxchan file $path r]
puts [cxchan read $g]
close $g
puts [catch {cxchan file $dir/nosuch/x r} e]:$e
set g [cxchan fd $dir/fd.txt]
puts $g "via fd"
close $g
set f [open $dir/fd.txt]
puts [read $f]
close $f
puts [cxchan names]
# fileevent on a channel of a C package. The driver runs the script in
# Tcl_NotifyChannel, and buffered input gives readable events.
set m [cxchan open]
puts $m "one\ntwo\nthree"
flush $m
seek $m 0
puts [gets $m]
set got {}
fileevent $m readable {
    lappend got [gets $m]
    if {[llength $got] == 2} {fileevent $m readable {}; set done 1}
}
puts [string trim [fileevent $m readable]]
vwait done
puts $got:[fileevent $m readable]
fileevent $m writable {set w fired; fileevent $m writable {}}
cxchan notify $m 4
puts $w:[fileevent $m writable]
proc bgerror {msg} {puts bgerror:$msg}
fileevent $m writable {error boom}
cxchan notify $m 4
update
puts gone:[fileevent $m writable]
set r [cxchan open r]
puts [catch {fileevent $r writable {}} e]:$e
close $r
cxchan closed
# fcopy from and to a channel of a C package.
seek $m 0
set f [open $dir/copy.txt w]
puts [fcopy $m $f -size 5]
puts [fcopy $m $f]
close $f
set f [open $dir/copy.txt]
set g [cxchan open]
puts [chan copy $f $g]
close $f
seek $g 0
puts [read $g]
close $m
close $g
puts [cxchan closed]
