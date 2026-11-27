# The checks of the execution traces: tests/cext/cxtrace.c.
# While a trace exists, a command of the top level has no command
# substitution and the inline flag is in procs only: tclsh runs the top
# level of a file with no bytecode, and the WebAssembly library compiles
# it. A command of a body ends at its terminator here: Tcl keeps the
# white space before a close brace in the text, and ztcl does not.
load $dir/cxtrace.so
proc show {} {
    set l [cxtrace log]
    puts -nonewline $l
}
proc add {a b} {expr {$a + $b}}
proc inl {} {set v 1; incr v; add 1 [llength {a b}]}
proc sub {} {set x [list a]; if {1} {set y [add 1 [llength {b}]]}}
proc deny {} {puts [catch {add 1 2} m]:$m}

puts "top level"
cxtrace obj all 100
set x 1
incr x
add $x 3
sub
cxtrace delete all
show

puts "level 1"
cxtrace obj one 1
add 1 2
if {1} {set y 1}
sub
cxtrace delete one
show

puts "level 2"
cxtrace obj two 2
add 1 2
sub
cxtrace delete two
show

puts "inline"
cxtrace obj in 100 inline
inl
cxtrace delete in
show

puts "string trace"
cxtrace str s 100
set w a
add 4 5
sub
cxtrace delete s
show

puts "deny"
cxtrace obj d 100 deny add 1
deny
cxtrace delete d
cxtrace obj b 100 deny add 3
deny
cxtrace delete b
show

puts "two traces"
cxtrace obj a1 100
cxtrace obj a2 100
set q 1
cxtrace delete a1
set q 2
cxtrace delete a2
show

puts "eval forms"
proc ev {} {eval {set r 1}; eval [list set r 2]; uplevel #0 {set r 3}}
cxtrace obj e 100
ev
proc body {} {foreach i {1 2} {set j $i}}
body
cxtrace delete e
show

puts "compiled before the trace"
proc hot {} {set s 0; foreach i {1 2} {incr s $i}; return $s}
for {set k 0} {$k < 300} {incr k} { hot }
cxtrace obj h 100
hot
cxtrace delete h
show
puts [hot]
