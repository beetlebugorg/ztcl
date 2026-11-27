# The checks of the area variables: tests/cext/cxvar.c.
load $dir/cxvar.so
proc try {script} {
    set rc [catch {uplevel 1 $script} msg]
    puts "  $rc: $msg"
}

puts unset
set a 1
try {cxvar unset a}
puts [info exists a]
try {cxvar unset a}
try {cxvar unset a leave}
array set arr {x 1 y 2}
try {cxvar unset2 arr x}
puts [array names arr]
proc p {} { set loc 1; cxvar unset loc; info exists loc }
puts [p]

puts upvar
set g 10
proc q {} { cxvar upvar 1 g mine; incr mine; set mine }
puts [q]
puts $g
proc r {} { cxvar upvar2 arr y el; set el 22 }
r
puts $arr(y)
proc s {} { cxvar upvar #0 nosuch here; set here 5 }
s
puts $nosuch
try {cxvar upvar 99 g h}

puts traces
set t 1
cxvar trace t rwu one
set t 2
set x $t
puts [cxvar log]
cxvar trace t w deny
try {set t 3}
puts $t
puts [cxvar log]
puts [cxvar info t]
cxvar untrace t w
puts [cxvar log]
puts [cxvar info t]
set t 4
puts [cxvar log]
unset t
puts [cxvar log]
puts [cxvar info t]
set t 5
puts [cxvar log]
set e(k) 1
cxvar trace e rw elem k
set e(k) 2
set e(other) 3
puts [cxvar log]
cxvar untrace e
puts [cxvar log]
proc tp {} { set v 1; cxvar trace v w local; set v 2 }
tp
puts [cxvar log]
cxvar trace gv wg glob
proc tg {} { global gv; set gv 1 }
tg
puts [cxvar log]

puts links
puts [cxvar link]
puts "$lint $ldouble $lbool $lstr $lwide $lshort $lro"
set lint 42
set ldouble 2.25
set lbool no
set lstr hello
set lwide 123456789012
set lshort 9
puts [cxvar cvals]
try {set lint abc}
puts $lint
try {set lshort 70000}
try {set lbool maybe}
try {set ldouble x}
try {set lro 1}
puts $lro
cxvar bump
puts "$lint $lro"
unset lint
puts [info exists lint]
puts $lint
cxvar unlink
set lint 7
puts "$lint [cxvar cvals]"
