# The checks of the area interps and commands: tests/cext/cxinterp.c.
load $dir/cxinterp.so
proc try {script} {
    set rc [catch {uplevel 1 $script} msg]
    puts "  $rc: $msg"
}

puts tokens
proc ::p1 {} {}
namespace eval ::ns { proc q {} {} }
try {cxinterp find set}
try {cxinterp find ::set}
try {cxinterp find p1}
try {cxinterp find ns::q}
try {cxinterp find ::ns::q}
try {cxinterp find cxinterp}
try {cxinterp find nosuch}
try {cxinterp find nosuch 512}
try {cxinterp find q 1}
try {cxinterp fromobj p1}
try {cxinterp fromobj nosuch}

puts traces
proc ::t1 {} {}
cxinterp trace t1 a
cxinterp trace t1 b
puts [cxinterp traceinfo t1]
rename t1 t2
puts [cxinterp log]
puts [cxinterp traceinfo t2]
cxinterp untrace t2 b
puts [cxinterp traceinfo t2]
rename t2 ::ns::t3
puts [cxinterp log]
rename ::ns::t3 {}
puts [cxinterp log]
puts [cxinterp traceinfo ::ns::t3]
try {cxinterp trace nosuch a}
proc ::t4 {} {}
cxinterp trace t4 a
cxinterp untrace t4 a
rename t4 {}
puts [cxinterp log]

puts math
cxinterp mathfuncs
puts [expr {twice(4)}]
puts [expr {twice(2.5)}]
puts [expr {twice(0x100000000)}]
puts [expr {hyp(3, 4)}]
puts [expr {hyp(3.0, 4)}]
puts [expr {kind(1.9, 2)}]
puts [expr {kind(3, 2.5)}]
try {expr {twice(13)}}
try {expr {twice("x")}}
try {expr {twice()}}
try {expr {twice(1, 2)}}
try {expr {hyp(1)}}
try {cxinterp mathinfo twice}
try {cxinterp mathinfo hyp}
try {cxinterp mathinfo sin}
try {cxinterp mathinfo nosuch}
puts [lsort [cxinterp mathlist t*]]
puts [lsort [cxinterp mathlist {[hk]*}]]

puts misc
puts [cxinterp putenv CXINTERP_A=one]
puts [cxinterp getenv CXINTERP_A]
puts [cxinterp putenv CXINTERP_A=two]
puts [cxinterp getenv CXINTERP_A]
puts [cxinterp hostname]
cxinterp proc pp {a {b 2}} {list $a $b}
puts [pp 1]
try {cxinterp proc bad}

