# The checks of the parse slots and Tcl_ParseArgsObjv: tests/cext/cxparse.c.
load $dir/cxparse.so
foreach s {
    {set a 1}
    {  # a comment
       puts "x $y" ; list {a b} [c d]}
    {a\ b c\x41d \u00e9 \101 \U1F600 \n\t "q\"q"}
    {$a $a(i) $a($i,[j]) ${x y} $ $:: $::n::v $n::v(k) $(e)}
    {{*}$l {*}{a b {c d}} {*}{} {*} {*}x {*}"a b" {*}{a {b} \"c\"}}
    "a \\\n b \\\n"
    {set x [a [b c] "d]"]; set y}
    {a "b"c}
    {a {b}c}
    "a \{b"
    {a "b}
    {a [b}
    {a $x(b}
    "a \$\{x"
    "# only a comment\n\n"
    "\{#\n\{ x\n"
} {
    puts [list command $s]
    puts [cxparse command $s]
}
foreach e {
    {1 + 2 * 3}
    {$a(x) > [llength {a b}] ? "yes" : {no}}
    {-1 ** 2 ** -3}
    {!(1 < 2) && ~3 || 4 >= 5}
    {max(1, 2, $x) + rand()}
    {"a" eq "b" ne "c" in {a b} ni {c}}
    {1.5e3 + 0x1F + 0b101 + 0o17 + 017 + .5 + 3. + Inf + NaN}
    {true || off || yes}
    {(((1)))}
    {f()}
    {a + 1}
    {1 +}
    {(1}
    {1)}
    {1 2}
    {}
    {"abc}
    {1 ? 2}
    {1 : 2}
    {$}
    {09}
    {0b2}
    {[set x}
    {1 = 2}
    {x(1,}
    {#}
    {a_very_long_bareword_that_goes_on}
    {1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12 + 13 + @ + 14 + 15 + 16 + 17 + 18 + 19 + 20}
} {
    puts [list expr $e]
    puts [cxparse expr $e]
}
foreach {mode s} {
    braces {{a {b} c} rest}
    braces "{a \\\n b}"
    braces {{}}
    braces {{a \} b}}
    braces "\{a\n# x \{\n"
    braces "\{a"
    quoted {"a $b [c] \x"d}
    quoted {"abc}
    varname {$a(b)c}
    varname {${a b}c}
    varname {$}
    varname {$::a::b}
} {
    puts [list $mode $s]
    puts [cxparse $mode $s]
}
set a 5
array set arr {x 1 i,7 2}
set i i
proc j {} {return 7}
set l {p q}
set nl "a\\\nb"
foreach s {
    {set a 1}
    {x $a $arr(x) $arr($i,[j]) ${a}b [j]x \tA {*}$l}
    {y "q $a" {b $a} [set a]}
    {z $nosuch}
    {z $arr(nosuch)}
    {z [error boom]}
    {z [break] after}
} {
    puts [list words $s]
    puts [catch {cxparse words $s} msg]:$msg
}
puts [catch {cxparse words $nl} msg]:$msg
foreach s {{$a} {$arr(x)tail} {$} {${a}} {$nosuch}} {
    puts [list var $s [catch {cxparse var $s} msg] $msg]
}
puts [catch {cxparse tokens {x$a[j]}} msg]:$msg
puts [catch {cxparse tokens {$nosuch}} msg]:$msg
foreach a {
    {}
    {-count 3 -ratio 2.25 -name bob}
    {-c 4}
    {-v}
    {-verb -tick -tick -pair a b}
    {-count}
    {-count x}
    {-ratio y}
    {-pair a}
    {-bogus 1}
    {-count 1 -- -name x}
    {-help}
} {
    puts [list args $a [catch {cxparse args {*}$a} msg] $msg]
    puts [list argsrest $a [catch {cxparse argsrest {*}$a} msg] $msg]
}
puts [list argsrest [catch {cxparse argsrest x -count 2 y} msg] $msg]
