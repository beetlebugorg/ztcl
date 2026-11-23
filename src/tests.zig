//! Tests of the parser, the interpreter, `expr`, and the core commands.
//!
//! Each case is a script and the string form of its result. The results
//! are those of tclsh 8.6.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl.zig");

const Case = struct { []const u8, []const u8 };

/// Runs each script in a new interpreter and compares the result. An
/// expected text that starts with "!" is an error message.
fn check(cases: []const Case) !void {
    for (cases) |c| {
        var it: tcl.Interp = undefined;
        try it.init(std.testing.allocator);
        defer it.deinit();
        it.step_limit = 10_000_000;
        var got: []const u8 = undefined;
        if (it.eval(c[0])) |v| {
            got = try it.str(v);
        } else |e| {
            if (e != error.TclError) return e;
            got = try std.fmt.allocPrint(it.alloc(), "!{s}", .{try it.str(it.result)});
        }
        std.testing.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("script: {s}\n", .{c[0]});
            return e;
        };
    }
}

test "the parser: words, quotes, and braces" {
    try check(&.{
        .{ "list a b c", "a b c" },
        .{ "list {a b} c", "{a b} c" },
        .{ "list \"a b\" c", "{a b} c" },
        .{ "set x 5; list \"x is $x\"", "{x is 5}" },
        .{ "set x 5; list {x is $x}", "{x is $x}" },
        .{ "list a{b}c", "a{b}c" },
        .{ "list {a {b c} d}", "{a {b c} d}" },
        .{ "llength {a {b c} d}", "3" },
        .{ "list {a\\}b}", "{a\\}b}" },
        .{ "list a;list b", "b" },
        .{ "list a\\ b", "{a b}" },
        .{ "list a \\\n   b", "a b" },
        .{ "set x {a\\\n    b}", "a b" },
        .{ "set x \"a\\\n    b\"", "a b" },
        .{ "list {a}b", "!extra characters after close-brace" },
        .{ "list \"a\"b", "!extra characters after close-quote" },
        .{ "list {a", "!missing close-brace" },
        .{ "list \"a", "!missing \"" },
        .{ "list [list a", "!missing close-bracket" },
        .{ "list a\"b\"c", "a\\\"b\\\"c" },
        .{ "", "" },
        .{ "  \n ; ;\n", "" },
    });
}

test "the parser: substitutions" {
    try check(&.{
        .{ "set a 1; set b $a$a", "11" },
        .{ "set a 1; set b ${a}x", "1x" },
        .{ "set a(k) v; set b $a(k)", "v" },
        .{ "set i k; set a(k) v; set b $a($i)", "v" },
        .{ "set {a(x y)} v; set i {x y}; set b $a($i)", "v" },
        .{ "set {a b} 3; set c ${a b}", "3" },
        .{ "set x [list a b][list c]", "a bc" },
        .{ "set x [set y 3; set z 4]", "4" },
        .{ "set x a[]b", "ab" },
        .{ "set x $", "$" },
        .{ "set x a$", "a$" },
        .{ "set x \"$ a\"", "$ a" },
        .{ "set x \\$a", "$a" },
        .{ "set x \\[a\\]", "[a]" },
        .{ "set x \\x41\\u0042\\103\\n", "ABC\n" },
        .{ "set x \\q", "q" },
        .{ "set x \"a [list b c] d\"", "a b c d" },
        .{ "set x \"[set y \"in]ner\"]\"", "in]ner" },
        .{ "set x {[not run]}", "[not run]" },
        .{ "set nope", "!can't read \"nope\": no such variable" },
        .{ "set x $nope", "!can't read \"nope\": no such variable" },
        .{ "set a::b 4; set c $a::b", "4" },
    });
}

test "the parser: expansion and comments" {
    try check(&.{
        .{ "set l {a b c}; list {*}$l", "a b c" },
        .{ "set l {a b c}; llength [list {*}$l {*}$l x]", "7" },
        .{ "list {*}{a b} {*}[list c d]", "a b c d" },
        .{ "list {*}", "*" },
        .{ "set l {}; list {*}$l", "" },
        .{ "{*}{set x 9}", "9" },
        .{ "# a comment\nset x 1", "1" },
        .{ "set x 1 ;# a comment", "1" },
        .{ "set x #no", "#no" },
        .{ "# a comment \\\n continues\nset x 2", "2" },
        .{ "set x {\n# in braces\n}", "\n# in braces\n" },
    });
}

test "procedures and frames" {
    try check(&.{
        .{ "proc f {a b} {expr {$a + $b}}; f 1 2", "3" },
        .{ "proc f {a {b 10}} {expr {$a + $b}}; list [f 1] [f 1 2]", "11 3" },
        .{ "proc f {a args} {list $a $args}; list [f 1] [f 1 2 3]", "{1 {}} {1 {2 3}}" },
        .{ "proc f {a} {}; f", "!wrong # args: should be \"f a\"" },
        .{ "proc f {a {b 1} args} {}; f", "!wrong # args: should be \"f a ?b? ?arg ...?\"" },
        .{ "proc f {} {return 5; set x 1}; f", "5" },
        .{ "proc f {} {set x 1}; f; info exists x", "0" },
        .{ "set g 1; proc f {} {global g; incr g}; f; set g", "2" },
        .{ "set g 1; proc f {} {set ::g 7}; f; set g", "7" },
        .{ "proc f {name} {upvar $name v; set v 5}; f x; set x", "5" },
        .{ "proc f {name} {upvar 1 $name v; incr v}; set x 1; f x; set x", "2" },
        .{ "proc f {} {uplevel {set y 3}}; f; set y", "3" },
        .{ "proc f {} {uplevel 1 set y 4}; f; set y", "4" },
        .{ "proc f {} {g}; proc g {} {uplevel #0 {set z 5}}; f; set z", "5" },
        .{ "proc f {} {g}; proc g {} {info level}; f", "2" },
        .{ "proc f {a} {info level 0}; f 3", "f 3" },
        .{ "proc fact n {if {$n <= 1} {return 1}; expr {$n * [fact [expr {$n - 1}]]}}; fact 10", "3628800" },
        .{ "proc f {} {f}; f", "!too many nested evaluations (infinite loop?)" },
        .{ "nosuch 1", "!invalid command name \"nosuch\"" },
        .{ "proc f {} {return a}; rename f g; g", "a" },
        .{ "proc f {} {}; rename f {}; f", "!invalid command name \"f\"" },
        .{ "apply {{a b} {expr {$a * $b}}} 3 4", "12" },
        .{ "info args [proc f {a b} {}; list f]", "a b" },
    });
}

test "return codes" {
    try check(&.{
        .{ "catch {error boom} m; set m", "boom" },
        .{ "catch {error boom}", "1" },
        .{ "catch {set x 1}", "0" },
        .{ "catch {return 3}", "2" },
        .{ "catch {break}", "3" },
        .{ "catch {continue}", "4" },
        .{ "proc f {} {return -code error bad}; list [catch {f} m] $m", "1 bad" },
        .{ "proc f {} {return -code break}; set n 0; while 1 {incr n; f}; set n", "1" },
        .{ "proc f {} {return -code continue}; set n 0; foreach i {1 2 3} {f; incr n}; set n", "0" },
        .{ "proc f {} {return -code return x}; proc g {} {f; return y}; g", "x" },
        .{ "proc f {} {return -level 2 x}; proc g {} {f; return y}; g", "x" },
        .{ "proc f {} {break}; f", "!invoked \"break\" outside of a loop" },
        .{ "break", "!invoked \"break\" outside of a loop" },
        .{ "error msg", "!msg" },
        .{ "catch {return -code error x} m o; lrange $o 0 3", "-code 1 -level 1" },
        .{ "return 7; set x 1", "7" },
    });
}

test "expr: integers and doubles" {
    try check(&.{
        .{ "expr {1 + 2 * 3}", "7" },
        .{ "expr {(1 + 2) * 3}", "9" },
        .{ "expr {7 / 2}", "3" },
        .{ "expr {-7 / 2}", "-4" },
        .{ "expr {7 % 3}", "1" },
        .{ "expr {-7 % 3}", "2" },
        .{ "expr {7 % -3}", "-2" },
        .{ "expr {7 / 2.0}", "3.5" },
        .{ "expr {1 / 0}", "!divide by zero" },
        .{ "expr {1.0 / 0}", "Inf" },
        .{ "expr {2 ** 10}", "1024" },
        .{ "expr {2 ** 3 ** 2}", "512" },
        .{ "expr {-2 ** 2}", "4" },
        .{ "expr {2 ** -1}", "0" },
        .{ "expr {2.0 ** 0.5}", "1.4142135623730951" },
        .{ "expr {1 << 4 | 1}", "17" },
        .{ "expr {0xff & ~0x0f}", "240" },
        .{ "expr {5 ^ 1}", "4" },
        .{ "expr {1.0}", "1.0" },
        .{ "expr {0.1 + 0.2}", "0.30000000000000004" },
        .{ "expr {1e3}", "1000.0" },
        .{ "expr {3 * 1.5}", "4.5" },
        .{ "expr {10 / 4 * 4}", "8" },
        .{ "expr {1 < 2}", "1" },
        .{ "expr {2 <= 1}", "0" },
        .{ "expr {1 == 1.0}", "1" },
        .{ "expr {\"abc\" < \"abd\"}", "1" },
        .{ "expr {\"1\" == \"1.0\"}", "1" },
        .{ "expr {\"1\" eq \"1.0\"}", "0" },
        .{ "expr {\"a\" ne \"b\"}", "1" },
        .{ "expr {1 ? \"y\" : \"n\"}", "y" },
        .{ "expr {0 ? 1 : 0 ? 2 : 3}", "3" },
        .{ "expr {1 && 0 || 1}", "1" },
        .{ "expr {0 && [error no]}", "0" },
        .{ "expr {1 || [error no]}", "1" },
        .{ "expr {!0}", "1" },
        .{ "expr {!\"true\"}", "0" },
        .{ "expr {true && yes}", "1" },
        .{ "expr {off}", "off" },
        .{ "expr {\"0x10\"}", "16" },
        .{ "expr {3eq2}", "0" },
        .{ "expr {!\"a\"}", "!can't use non-numeric string as operand of \"!\"" },
        .{ "variable v 3; proc f {} {variable v; incr v}; f", "4" },
        .{ "array set a {}; catch {set a(k)} m; set m", "can't read \"a(k)\": no such element in array" },
        .{ "if 1 {set a 1} else {set a 2} extra", "!wrong # args: extra words after \"else\" clause in \"if\" command" },
        .{ "proc f {} {error boom}; catch {f}; set errorInfo", "boom\n    while executing\n\"error boom\"\n    (procedure \"f\" line 1)\n    invoked from within\n\"f\"" },
        .{ "set tcl_platform(platform)", "unix" },
        .{ "expr {2 in {1 2 3}}", "1" },
        .{ "expr {4 ni {1 2 3}}", "1" },
        .{ "set x 5; expr {$x * 2}", "10" },
        .{ "set x 5; expr $x*2", "10" },
        .{ "set x 5; expr $x * 2 + 1", "11" },
        .{ "set x \" 5 \"; expr {$x + 1}", "6" },
        .{ "set x 0x10; expr {$x + 1}", "17" },
        .{ "set x 0x10; list $x", "0x10" },
        .{ "expr {[llength {a b}] + 1}", "3" },
        .{ "expr {\"a\" + 1}", "!can't use non-numeric string as operand of \"+\"" },
        .{ "expr {1.5 % 2}", "!can't use floating-point value as operand of \"%\"" },
        .{ "expr {9223372036854775807 + 1}", "9223372036854775808" },
        .{ "expr {1 +}", "!missing operand at _@_\nin expression \"1 +_@_\"" },
    });
}

test "expr: math functions" {
    try check(&.{
        .{ "expr {abs(-3)}", "3" },
        .{ "expr {abs(-3.5)}", "3.5" },
        .{ "expr {int(3.9)}", "3" },
        .{ "expr {int(-3.9)}", "-3" },
        .{ "expr {round(2.5)}", "3" },
        .{ "expr {round(-2.5)}", "-3" },
        .{ "expr {double(3)}", "3.0" },
        .{ "expr {sqrt(16)}", "4.0" },
        .{ "expr {pow(2, 10)}", "1024.0" },
        .{ "expr {max(1, 5, 3)}", "5" },
        .{ "expr {min(1.5, 2)}", "1.5" },
        .{ "expr {floor(2.7)}", "2.0" },
        .{ "expr {ceil(2.1)}", "3.0" },
        .{ "expr {fmod(7, 3)}", "1.0" },
        .{ "expr {hypot(3, 4)}", "5.0" },
        .{ "expr {atan2(0, 1)}", "0.0" },
        .{ "expr {sin(0)}", "0.0" },
        .{ "expr {clamp(5, 0, 3)}", "3.0" },
        .{ "expr {lerp(0, 10, 0.5)}", "5.0" },
        .{ "expr {noise3(1, 2, 3)}", "0.0" },
        .{ "expr {foo(1)}", "!invalid command name \"tcl::mathfunc::foo\"" },
        .{ "expr {sqrt()}", "!not enough arguments for math function \"sqrt\"" },
        .{ "expr {sqrt(1, 2)}", "!too many arguments for math function \"sqrt\"" },
        .{ "expr {srand(1) == srand(1)}", "1" },
    });
}

test "control flow" {
    try check(&.{
        .{ "if {1} {set x a} else {set x b}", "a" },
        .{ "if 0 {set x a} elseif 1 {set x c} else {set x b}", "c" },
        .{ "if {0} then {set x a} {set x b}", "b" },
        .{ "if 0 {set x a}", "" },
        .{ "set s 0; set i 0; while {$i < 5} {incr s $i; incr i}; set s", "10" },
        .{ "set s 0; for {set i 0} {$i < 5} {incr i} {if {$i == 3} continue; incr s $i}; set s", "7" },
        .{ "set s 0; for {set i 0} {$i < 5} {incr i} {if {$i == 3} break; incr s $i}; set s", "3" },
        .{ "set r {}; foreach x {a b c} {lappend r $x$x}; set r", "aa bb cc" },
        .{ "set r {}; foreach {x y} {1 2 3 4 5} {lappend r $x-$y}; set r", "1-2 3-4 5-" },
        .{ "set r {}; foreach x {1 2} y {a b c} {lappend r $x$y}; set r", "1a 2b c" },
        .{ "lmap x {1 2 3} {expr {$x * $x}}", "1 4 9" },
        .{ "lmap x {1 2 3 4} {if {$x % 2} continue; set x}", "2 4" },
        .{ "switch b {a {set r 1} b {set r 2} default {set r 3}}", "2" },
        .{ "switch z a {set r 1} default {set r 3}", "3" },
        .{ "switch a {a - b {set r ab} c {set r c}}", "ab" },
        .{ "switch -glob abc {a* {set r glob} default {set r no}}", "glob" },
        .{ "switch x {a {set r 1}}", "" },
        .{ "while 1 {}", "!step limit reached" },
        .{ "catch {while 1 {}}", "!step limit reached" },
        .{ "proc f {} {f2}; proc f2 {} {catch {while 1 {}}}; f", "!step limit reached" },
    });
}

test "variables" {
    try check(&.{
        .{ "set x 1; incr x; incr x 10; incr x -2", "10" },
        .{ "incr fresh", "1" },
        .{ "set x a; incr x", "!expected integer but got \"a\"" },
        .{ "set x a; append x b c; set x", "abc" },
        .{ "append fresh a", "a" },
        .{ "set x 1; unset x; info exists x", "0" },
        .{ "unset nope", "!can't unset \"nope\": no such variable" },
        .{ "unset -nocomplain nope", "" },
        .{ "set a(1) x; set a(2) y; array size a", "2" },
        .{ "set a(1) x; set a(2) y; array names a", "1 2" },
        .{ "array set a {k v k2 v2}; array get a", "k v k2 v2" },
        .{ "set a(1) x; set a", "!can't read \"a\": variable is array" },
        .{ "set a 1; set a(1) x", "!can't set \"a(1)\": variable isn't array" },
        .{ "set a(1) x; unset a(1); info exists a(1)", "0" },
        .{ "set a(1) x; incr a(n); incr a(n); set a(n)", "2" },
        .{ "set x 5; subst {x=$x [expr {$x + 1}] \\n}", "x=5 6 \n" },
    });
}

test "lists" {
    try check(&.{
        .{ "list", "" },
        .{ "list a {} c", "a {} c" },
        .{ "lindex {a b c} 1", "b" },
        .{ "lindex {a b c} end", "c" },
        .{ "lindex {a b c} end-1", "b" },
        .{ "lindex {a b c} 5", "" },
        .{ "lindex {a {b c} d} 1 1", "c" },
        .{ "lindex {a {b c} d} {1 0}", "b" },
        .{ "lindex {a b c}", "a b c" },
        .{ "llength {}", "0" },
        .{ "llength {a b {c d}}", "3" },
        .{ "llength \"a {b\"", "!unmatched open brace in list" },
        .{ "set l {}; lappend l a; lappend l {b c} d; set l", "a {b c} d" },
        .{ "set a [list 1 2]; set b $a; lappend a 3; lappend b 4; list $a $b", "{1 2 3} {1 2 4}" },
        .{ "lrange {a b c d e} 1 3", "b c d" },
        .{ "lrange {a b c d e} 3 end", "d e" },
        .{ "lrange {a b c} 2 1", "" },
        .{ "lsearch {a b c} b", "1" },
        .{ "lsearch {a b c} z", "-1" },
        .{ "lsearch -exact {a* b} a*", "0" },
        .{ "lsearch {abc bcd} b*", "1" },
        .{ "lsearch -all -inline {a1 b a2} a*", "a1 a2" },
        .{ "lsort {c a b}", "a b c" },
        .{ "lsort -integer {10 9 100}", "9 10 100" },
        .{ "lsort {10 9 100}", "10 100 9" },
        .{ "lsort -decreasing -real {1.5 10 2}", "10 2 1.5" },
        .{ "lsort -unique {b a b c a}", "a b c" },
        .{ "lsort -index 1 {{a 2} {b 1}}", "{b 1} {a 2}" },
        .{ "lreverse {a b c}", "c b a" },
        .{ "linsert {a b c} 1 x y", "a x y b c" },
        .{ "linsert {a b c} end x", "a b c x" },
        .{ "lreplace {a b c d} 1 2 x", "a x d" },
        .{ "lassign {1 2 3} a b; list $a $b", "1 2" },
        .{ "lrepeat 3 a b", "a b a b a b" },
        .{ "join {a b c} -", "a-b-c" },
        .{ "join {a {b c}}", "a b c" },
        .{ "split a,b,,c ,", "a b {} c" },
        .{ "split abc {}", "a b c" },
        .{ "split {a b}", "a b" },
        .{ "concat {a b} { c } {} d", "a b c d" },
        .{ "concat", "" },
        .{ "list [expr {1 + 1}] [expr {1.0}] x", "2 1.0 x" },
        .{ "lindex [list a\\{b] 0", "a{b" },
        .{ "list {} #a", "{} #a" },
        .{ "list #a", "{#a}" },
    });
}

test "dict" {
    try check(&.{
        .{ "dict create a 1 b 2", "a 1 b 2" },
        .{ "dict create a 1 b 2 a 3", "a 3 b 2" },
        .{ "dict get {a 1 b 2} b", "2" },
        .{ "dict get {a {x 1 y 2}} a y", "2" },
        .{ "dict get {a 1} z", "!key \"z\" not known in dictionary" },
        .{ "dict get {a 1 b}", "!missing value to go with key" },
        .{ "dict exists {a 1} a", "1" },
        .{ "dict exists {a 1} b", "0" },
        .{ "dict exists {a {x 1}} a x", "1" },
        .{ "dict set d a 1; dict set d b 2; dict set d a 3", "a 3 b 2" },
        .{ "dict set d a x 1; dict set d a y 2; set d", "a {x 1 y 2}" },
        .{ "set d {a 1 b 2}; dict unset d a; set d", "b 2" },
        .{ "dict keys {a 1 b 2 c 3}", "a b c" },
        .{ "dict keys {a 1 b 2 ab 3} a*", "a ab" },
        .{ "dict values {a 1 b 2}", "1 2" },
        .{ "dict size {a 1 b 2}", "2" },
        .{ "set r {}; dict for {k v} {a 1 b 2} {lappend r $k=$v}; set r", "a=1 b=2" },
        .{ "dict merge {a 1 b 2} {b 3 c 4}", "a 1 b 3 c 4" },
        .{ "dict incr d n; dict incr d n 5", "n 6" },
        .{ "dict lappend d k a; dict lappend d k b c", "k {a b c}" },
        .{ "dict append d k ab; dict append d k cd", "k abcd" },
    });
}

test "strings and format" {
    try check(&.{
        .{ "string length hello", "5" },
        .{ "string index hello 1", "e" },
        .{ "string index hello end", "o" },
        .{ "string range hello 1 3", "ell" },
        .{ "string range hello 3 end", "lo" },
        .{ "string equal a a", "1" },
        .{ "string equal -nocase A a", "1" },
        .{ "string compare a b", "-1" },
        .{ "string compare b a", "1" },
        .{ "string first l hello", "2" },
        .{ "string last l hello", "3" },
        .{ "string first z hello", "-1" },
        .{ "string map {a 1 b 2} abcab", "12c12" },
        .{ "string tolower ABC", "abc" },
        .{ "string toupper abc", "ABC" },
        .{ "string trim {  a b  }", "a b" },
        .{ "string trimleft xxaxx x", "axx" },
        .{ "string trimright xxaxx x", "xxa" },
        .{ "string repeat ab 3", "ababab" },
        .{ "string is integer 12", "1" },
        .{ "string is integer 1.2", "0" },
        .{ "string is integer {}", "1" },
        .{ "string is integer -strict {}", "0" },
        .{ "string is double 1.5e3", "1" },
        .{ "string is double abc", "0" },
        .{ "string match a*c abc", "1" },
        .{ "string match {a[0-9]} a5", "1" },
        .{ "string match a?c ac", "0" },
        .{ "string reverse abc", "cba" },
        .{ "string bogus", "!unknown or ambiguous subcommand \"bogus\": must be bytelength, cat, compare, equal, first, index, is, last, length, map, match, range, repeat, replace, reverse, tolower, totitle, toupper, trim, trimleft, trimright, wordend, or wordstart" },
        .{ "format %d 42", "42" },
        .{ "format %5d|%-5d| 42 42", "   42|42   |" },
        .{ "format %05d -42", "-0042" },
        .{ "format %+d 42", "+42" },
        .{ "format %x 255", "ff" },
        .{ "format %#X 255", "0XFF" },
        .{ "format %o 8", "10" },
        .{ "format %c 65", "A" },
        .{ "format %s%% a", "a%" },
        .{ "format %10s| a", "         a|" },
        .{ "format %.2s abcdef", "ab" },
        .{ "format %.2f 3.14159", "3.14" },
        .{ "format %f 1", "1.000000" },
        .{ "format %.2f 2.675", "2.67" },
        .{ "format %.0f|%.0f|%.0f 0.5 1.5 2.5", "0|2|2" },
        .{ "format %.1f|%.1f 0.25 0.35", "0.2|0.3" },
        .{ "format %.2f|%.1f 9.995 9.95", "9.99|9.9" },
        .{ "format %.0f|%.1f 9.5 0.95", "10|0.9" },
        .{ "format %.2f 1.005", "1.00" },
        .{ "format %8.3f| 2.5", "   2.500|" },
        .{ "format %e 12345.678", "1.234568e+04" },
        .{ "format %g 0.0001", "0.0001" },
        .{ "format %g 1234567", "1.23457e+06" },
        .{ "format %g 100", "100" },
        .{ "format %*d 4 7", "   7" },
        .{ "format %d a", "!expected integer but got \"a\"" },
        .{ "format %d", "!not enough arguments for all format specifiers" },
    });
}

fn collect(ctx: ?*anyopaque, bytes: []const u8) void {
    const list: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
    list.appendSlice(std.testing.allocator, bytes) catch {};
}

test "puts writes to the output of the embedder" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.output = .{ .ctx = &out, .write = collect };
    _ = try it.eval("puts hello; puts -nonewline a; puts stdout b");
    try std.testing.expectEqualStrings("hello\nab\n", out.items);
}

test "no command reaches the outside world" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    for ([_][]const u8{ "open", "socket", "exec", "file", "clock", "source", "exit", "cd", "glob", "load", "after" }) |name| {
        try std.testing.expect(!it.commands.contains(name));
    }
}

test "deep nesting is an error and no crash" {
    const a = std.testing.allocator;
    var it: tcl.Interp = undefined;
    try it.init(a);
    defer it.deinit();
    const n = 100_000;
    const brackets = try a.alloc(u8, n);
    defer a.free(brackets);
    @memset(brackets, '[');
    try std.testing.expectError(error.TclError, it.eval(brackets));
    const parens = try std.fmt.allocPrint(a, "expr {{{s}}}", .{brackets});
    defer a.free(parens);
    @memset(parens[6 .. 6 + n], '(');
    try std.testing.expectError(error.TclError, it.eval(parens));
    @memset(parens[6 .. 6 + n], '-');
    try std.testing.expectError(error.TclError, it.eval(parens));
    // A long chain of operators makes a deep tree.
    var chain: std.ArrayList(u8) = .empty;
    defer chain.deinit(a);
    try chain.appendSlice(a, "expr {1");
    for (0..n) |_| try chain.appendSlice(a, "+1");
    try chain.append(a, '}');
    try std.testing.expectError(error.TclError, it.eval(chain.items));
    try std.testing.expectEqualStrings("the expression is too large", try it.str(it.result));
}

test "the step limit stops a long script" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.step_limit = 1000;
    try std.testing.expectError(error.TclError, it.eval("set i 0; while {1} {incr i}"));
    try std.testing.expectEqualStrings("step limit reached", try it.str(it.result));
    // A higher step limit lets the interpreter run again.
    it.step_limit = 1000;
    const v = try it.eval("set i");
    try std.testing.expect(v.asInt().? > 100);
}

test "a loop body and a braced expr compile once" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    _ = try it.eval("proc sum n {set s 0; for {set i 0} {$i < $n} {incr i} {set s [expr {$s + $i}]}; return $s}");
    _ = try it.eval("sum 10");
    const before = it.arena.queryCapacity();
    const v = try it.eval("sum 20000");
    try std.testing.expectEqual(@as(?i64, 199990000), v.asInt());
    // 20 000 passes add no memory: the words of a command live on a
    // stack, and an integer needs no allocation.
    try std.testing.expect(it.arena.queryCapacity() - before < 64 * 1024);
}

test "try, throw, and the error code" {
    try check(&.{
        .{ "try {expr {1+1}}", "2" },
        .{ "try {error boom} on error {m} {list got $m}", "got boom" },
        .{ "try {throw {A B} oops} trap {A} {m o} {list $m [dict get $o -errorcode]}", "oops {A B}" },
        .{ "try {throw {A B} oops} trap {X} {m} {list no} trap {A B} {m} {list yes $m}", "yes oops" },
        .{ "try {throw {A B} oops} trap {X} {m} {list no}", "!oops" },
        .{ "set x 0; catch {try {error boom} finally {set x 1}}; set x", "1" },
        .{ "try {set a 1} on ok {v} {list ok $v} finally {set b 2}", "ok 1" },
        .{ "try {error a} on error {} - on break {} {list both}", "both" },
        .{ "proc p {} {try {return 7} finally {set z 1}}; p", "7" },
        .{ "catch {throw {MY CODE} msg}; set errorCode", "MY CODE" },
        .{ "catch {error msg info {E 1}} m o; dict get $o -errorcode", "E 1" },
        .{ "catch {return -code error -errorcode {Q 2} m} m o; set o", "-code 1 -level 1" },
        .{ "proc p {} {return -code error -errorcode {Q 2} m}; catch p; set errorCode", "Q 2" },
        .{ "catch {expr {1/0}}; set errorCode", "ARITH DIVZERO {divide by zero}" },
    });
}

test "the memory limit stops a script, and reset frees the script data" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.mem_limit = it.memUsed() + (1 << 20);
    try std.testing.expectError(error.TclError, it.eval("set s x; while {1} {catch {append s $s$s}}"));
    try std.testing.expectEqualStrings("the script used too much memory", try it.str(it.result));
    try it.reset();
    const v = try it.eval("info exists s");
    try std.testing.expectEqual(@as(?i64, 0), v.asInt());
}

test "lset, lsort options, and binary" {
    try check(&.{
        .{ "set l {a b c}; lset l 1 x", "a x c" },
        .{ "set l {a {b c} d}; lset l 1 0 x", "a {x c} d" },
        .{ "set l {a {b c} d}; lset l {1 end} x", "a {b x} d" },
        .{ "set l {a b}; lset l 2 c", "a b c" },
        .{ "set l {a b}; lset l 5 c", "!list index out of range" },
        .{ "set l {a b}; lset l z", "z" },
        .{ "lsort -stride 2 {b 2 a 1 c 3}", "a 1 b 2 c 3" },
        .{ "lsort -stride 2 -index 1 -integer {b 20 a 100 c 3}", "c 3 b 20 a 100" },
        .{ "lsort -index {0 1} {{{a 2}} {{b 1}}}", "{{b 1}} {{a 2}}" },
        .{ "lsort -command {apply {{a b} {expr {$a - $b}}}} {3 1 2}", "1 2 3" },
        .{ "lsort -dictionary {a10 a2 A3 a1}", "a1 a2 A3 a10" },
        .{ "lsort -indices {c a b}", "1 2 0" },
        .{ "binary scan [binary format i 258] c* b; set b", "2 1 0 0" },
        .{ "binary scan [binary format d 1.5] d x; set x", "1.5" },
        .{ "binary scan \\xff\\x01 cuc a b; list $a $b", "255 1" },
        .{ "binary scan [binary format a3S ab 513] a3H4 s h; list $s $h", "ab\x00 0201" },
        .{ "string length [binary format w 1]", "8" },
    });
}

test "regexp, regsub, and the -regexp options" {
    try check(&.{
        .{ "regexp {a+b} xaaab", "1" },
        .{ "regexp {^a+b$} xaaab", "0" },
        .{ "regexp {(\\d+)-(\\d+)} {tel 555-1234 x} all a b; list $all $a $b", "555-1234 555 1234" },
        .{ "regexp -inline {([a-z]+)(\\d)?} abc", "abc abc {}" },
        .{ "regexp -all -inline {\\w+} {one two  three}", "one two three" },
        .{ "regexp -all {a} banana", "3" },
        .{ "regexp -indices {an+} banana m; set m", "1 2" },
        .{ "regexp -nocase {HELLO} {say hello}", "1" },
        .{ "regexp {a|ab} ab m; set m", "ab" },
        .{ "regexp {x*?y} xxy m; set m", "xxy" },
        .{ "regexp {a{2,3}} aaaa m; set m", "aaa" },
        .{ "regexp {[[:digit:]]+} ab123 m; set m", "123" },
        .{ "regexp {(a)\\1} xaa", "1" },
        .{ "regexp {\\mfoo\\M} {a foo b}", "1" },
        .{ "regexp {(a*)*b} aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac", "0" },
        .{ "regexp {(} x", "!couldn't compile regular expression pattern: parentheses () not balanced" },
        .{ "regsub -all {a} banana A", "bAnAnA" },
        .{ "regsub {(\\w+) (\\w+)} {hello world} {\\2 \\1}", "world hello" },
        .{ "regsub -all {\\s+} {a  b   c} { } v; set v", "a b c" },
        .{ "regsub -all {x*} abc -", "-a-b-c-" },
        .{ "regsub -all {b} abc {[&]}", "a[b]c" },
        .{ "switch -regexp abc {^x {list no} {b+} {list yes}}", "yes" },
        .{ "switch -regexp -matchvar m abc {{a(b)c} {set m}}", "abc b" },
        .{ "lsearch -regexp {foo bar baz} {^b}", "1" },
        .{ "lsearch -all -inline -regexp {foo bar baz} {^b}", "bar baz" },
        .{ "lsearch -index 1 -exact {{a 1} {b 2}} 2", "1" },
        .{ "lsearch -start 2 {a b a b} a", "2" },
        .{ "lsearch -sorted -integer {1 3 5 7} 5", "2" },
        .{ "lsearch -bisect -integer {1 3 5 7} 4", "1" },
        .{ "lsearch -nocase -exact {A B} b", "1" },
    });
}

test "namespaces" {
    try check(&.{
        .{ "namespace current", "::" },
        .{ "namespace eval foo {namespace current}", "::foo" },
        .{ "namespace eval foo {namespace eval bar {namespace current}}", "::foo::bar" },
        .{ "namespace eval foo {proc f {} {return [namespace current]}}; foo::f", "::foo" },
        .{ "namespace eval foo {proc f {} {return 1}; proc g {} {f}}; ::foo::g", "1" },
        .{ "namespace eval foo {variable n 5; proc get {} {variable n; return $n}}; list [foo::get] $foo::n $::foo::n", "5 5 5" },
        .{ "namespace eval foo {set count 0; proc bump {} {variable count; incr count}; bump; bump; set count}", "2" },
        .{ "namespace eval foo {set x 1}; set ::foo::x", "1" },
        .{ "set g 7; namespace eval foo {set g}", "7" },
        .{ "namespace eval foo {variable v 3}; info exists v", "0" },
        .{ "proc f {} {return global}; namespace eval foo {proc f {} {return inner}; proc call {} {f}}; list [f] [foo::call]", "global inner" },
        .{ "namespace eval a::b {proc f {} {return ab}}; list [a::b::f] [namespace children ::a] [namespace parent ::a::b]", "ab ::a::b ::a" },
        .{ "namespace eval foo {namespace export f; proc f {} {return 1}; proc g {} {}}; namespace import foo::*; list [f] [catch g]", "1 1" },
        .{ "namespace eval e {namespace export a b; proc a {x} {return a$x}; proc b {} {return b}; proc hid {} {}; namespace ensemble create}; list [e a 1] [e b]", "a1 b" },
        .{ "namespace eval e {namespace export a b; proc a {} {}; proc b {} {}; namespace ensemble create}; e zz", "!unknown or ambiguous subcommand \"zz\": must be a, or b" },
        .{ "namespace eval e {proc impl {x} {return i$x}; namespace ensemble create -map {go impl}}; e go 5", "i5" },
        .{ "namespace eval e {proc one {} {return 1}; namespace ensemble create -command ::ee -subcommands {one}}; list [ee one] [namespace ensemble exists ee] [namespace ensemble exists set]", "1 1 0" },
        .{ "namespace eval foo {proc f {} {return 1}}; namespace delete foo; list [namespace exists foo] [catch {foo::f}]", "0 1" },
        .{ "list [namespace qualifiers ::a::b::c] [namespace tail ::a::b::c] [namespace tail x]", "::a::b c x" },
        .{ "namespace eval foo {proc f {} {return 1}}; namespace which foo::f", "::foo::f" },
        .{ "namespace eval foo {variable x 9}; proc p {} {namespace upvar ::foo x y; return $y}; p", "9" },
        .{ "namespace eval foo {namespace code {set z}}", "::namespace inscope ::foo {set z}" },
        .{ "proc ::foo::bar::f {} {return [namespace current]}; foo::bar::f", "::foo::bar" },
        .{ "namespace eval foo {proc f {} {return 1}}; rename foo::f foo::g; foo::g", "1" },
    });
}

test "a glob match has a bounded time" {
    try check(&.{
        .{ "string match {*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b} [string repeat a 4000]", "0" },
        .{ "string match {a*b*c} axxbyyc", "1" },
        .{ "string match {a*b*c} axxbyy", "0" },
        .{ "string match {*[0-9]?x} ab12x", "1" },
        .{ "string match {a\\*b} a*b", "1" },
        .{ "string match -nocase {A*Z} abcz", "1" },
        .{ "string match {} {}", "1" },
        .{ "string match {*} {}", "1" },
        .{ "string match {a*} b", "0" },
    });
}

test "string commands count characters" {
    try check(&.{
        .{ "string length caf\\u00e9", "4" },
        .{ "string length \\u65e5\\u672c\\u8a9e", "3" },
        .{ "string index \\u65e5\\u672c\\u8a9e 1", "\u{672c}" },
        .{ "string index \\u65e5\\u672c\\u8a9e end", "\u{8a9e}" },
        .{ "string range a\\u00e9b\\u00e9c 1 3", "\u{e9}b\u{e9}" },
        .{ "string reverse a\\u00e9b", "b\u{e9}a" },
        .{ "string first b \\u00e9\\u00e9b", "2" },
        .{ "string last b \\u00e9b\\u00e9b", "3" },
        .{ "string replace \\u00e9\\u00e9\\u00e9 1 1 x", "\u{e9}x\u{e9}" },
        .{ "string first b \\u00e9b\\u00e9b 2", "3" },
        .{ "string length abc", "3" },
    });
}

test "more dict subcommands and binary encode" {
    try check(&.{
        .{ "dict remove {a 1 b 2 c 3} b z", "a 1 c 3" },
        .{ "dict replace {a 1 b 2} b 5 c 6", "a 1 b 5 c 6" },
        .{ "dict map {k v} {a 1 b 2} {expr {$v * 10}}", "a 10 b 20" },
        .{ "dict filter {a 1 b 2 ab 3} key a*", "a 1 ab 3" },
        .{ "dict filter {a 1 b 2 c 1} value 1", "a 1 c 1" },
        .{ "dict filter {a 1 b 2 c 3} script {k v} {expr {$v > 1}}", "b 2 c 3" },
        .{ "set d {a 1 b 2}; dict update d a x b y {incr x 10; unset y}; set d", "a 11" },
        .{ "set d {a 1 b 2}; dict with d {incr a; set b 9}; set d", "a 2 b 9" },
        .{ "set d {p {a 1}}; dict with d p {incr a 4}; set d", "p {a 5}" },
        .{ "binary encode hex abc", "616263" },
        .{ "binary decode hex 616263", "abc" },
        .{ "binary encode base64 {hello world}", "aGVsbG8gd29ybGQ=" },
        .{ "binary decode base64 aGVsbG8gd29ybGQ=", "hello world" },
        .{ "binary encode base64 -maxlen 4 abcdef", "YWJj\nZGVm" },
        .{ "binary decode hex 6g", "!invalid hexadecimal digit \"g\" at position 1" },
    });
}

test "info default and info args in a namespace" {
    try check(&.{
        .{ "proc p {a {b 5}} {}; list [info default p b v] $v [info default p a w] $w", "1 5 0 {}" },
        .{ "namespace eval n {proc q {x y} {}}; info args n::q", "x y" },
    });
}

test "return codes above 4" {
    try check(&.{
        .{ "proc p {} {return -code 5 hi}; list [catch p m] $m", "5 hi" },
        .{ "proc p {} {return -code 7 x}; try {p} on 7 {m} {list seven $m}", "seven x" },
        .{ "proc p {} {return -code 5 hi}; p", "!command returned bad code: 5" },
        .{ "catch {return -code 6 v} m o; set o", "-code 6 -level 1" },
    });
}

test "dict keys: integers and strings together" {
    try check(&.{
        .{ "dict get [list 1 a x b [expr {1+1}] c] [expr {4-2}]", "c" },
        .{ "dict get [list 1 a x b [expr {1+1}] c] 2", "c" },
        .{ "dict exists [list [expr {5}] a] 05", "0" },
    });
}

test "scan" {
    try check(&.{
        .{ "scan {12 abc 3.5} {%d %s %f} a b c; list $a $b $c", "12 abc 3.5" },
        .{ "scan {12 abc 3.5} {%d %s %f}", "12 abc 3.5" },
        .{ "scan ff %x", "255" },
        .{ "scan 0x1A %i", "26" },
        .{ "scan A %c", "65" },
        .{ "scan {x=42;} {x=%d;} v; set v", "42" },
        .{ "scan abc123 {%[a-z]%d} w n; list $w $n", "abc 123" },
        .{ "scan 12345 %2d%3d a b; list $a $b", "12 345" },
        .{ "scan {} %d v", "-1" },
        .{ "scan abc %d v", "0" },
        .{ "scan {1 2} {%*d %d}", "2" },
        .{ "scan -7 %d", "-7" },
        .{ "scan 1 {%d %d} a", "!different numbers of variable names and field specifiers" },
    });
}

test "a script that runs itself is an error and no crash" {
    const msg = "!too many nested evaluations (infinite loop?)";
    try check(&.{
        .{ "set s {eval $s}; eval $s", msg },
        .{ "set s {namespace eval :: $s}; eval $s", msg },
        .{ "set s {namespace eval n $s}; eval $s", msg },
        .{ "set s {try $s}; eval $s", msg },
        .{ "set s {catch $s; error [set errorInfo x]}; catch {eval $s}", "1" },
        .{ "set s {dict map {k v} {a 1} $s}; eval $s", msg },
        .{ "set s {subst {[eval $s]}}; eval $s", msg },
        .{ "set s {expr {[eval $s]}}; eval $s", msg },
        .{ "set s {uplevel 0 $s}; eval $s", msg },
        .{ "proc c {a b} {lsort -command c {1 2}}; c 1 2", msg },
        .{ "lsort -integer {3 1 2 1}", "1 1 2 3" },
        .{ "lsort -index 0 {{b 1} {a 2} {b 0} {a 1}}", "{a 2} {a 1} {b 1} {b 0}" },
        .{ "lsort -unique {b a b c a}", "a b c" },
    });
}

test "the bytecode: a changed core command takes the general path" {
    try check(&.{
        .{ "proc f {} {set x 1; rename set zset; catch {set x 2} m; rename zset set; list $x $m}; f", "1 {invalid command name \"set\"}" },
        .{ "proc f {} {set i 0; set r [incr i]; list $i $r}; f; proc incr {v args} {upvar $v x; set x 100; return hooked}; f", "100 hooked" },
        .{ "namespace eval n {proc set {args} {return mine}; proc f {} {set x 1}}; n::f", "mine" },
        .{ "proc f {} {set i 0; while {$i < 2} {incr i}; set i}; f; rename while w; proc while {args} {return mine}; f", "0" },
        .{ "proc f {} {set x 1}; f; rename set s2; rename s2 set; f", "1" },
    });
}

test "the bytecode: loops and return codes" {
    try check(&.{
        .{ "proc f {} {for {set i 0} {$i < 5} {incr i} {if {$i == 1} continue; if {$i == 3} break; lappend o $i}; list $o $i}; f", "{0 2} 3" },
        .{ "proc f {} {foreach x {1 2 3 4} {set y [if {$x == 2} {continue} else {list $x}]; if {$x == 4} break; lappend o $y}; set o}; f", "1 3" },
        .{ "proc f {} {set n 0; for {set i 0} {$i < 3} {incr i; break} {incr n}; list $n $i}; f", "1 1" },
        .{ "proc f {} {set n 0; while {[incr n] < 5} {if {$n == 2} {eval break}}; set n}; f", "2" },
        .{ "proc f {} {foreach {a b} {1 2 3} {lappend o $a:$b}; set o}; f", "1:2 3:" },
        .{ "proc f {} break; f", "!invoked \"break\" outside of a loop" },
        .{ "proc g {} {return -level 2 up}; proc f {} {g; return no}; f", "up" },
    });
}

test "the bytecode: slots and other frames" {
    try check(&.{
        .{ "proc f {} {set a 1; unset a; set l [info locals]; set b 2; list $l [lsort [info locals]] [info exists a]}; f", "{} {b l} 0" },
        .{ "proc u {} {upvar 1 v w; set w 7; incr w; uplevel 1 {set made 5}}; proc f {} {set v 1; u; list $v $made}; f", "8 5" },
        .{ "set g 10; proc f {} {global g; incr g; set h $g; list $g $h}; f", "11 11" },
        .{ "proc f {} {set x(1) 2; catch {set x 3} m; set m}; f", "can't set \"x\": variable is array" },
        .{ "proc f {} {set l {}; lappend l a; set m $l; lappend l b; lappend m c; list $l $m}; f", "{a b} {a c}" },
        .{ "set i 0; set t 0; while {$i < 4} {incr i; incr t $i}; set t", "10" },
        .{ "set a abc; append a d; set b $a; append a e; append b f; list $a $b", "abcde abcdf" },
        .{ "set d {a 1 b 2}; dict incr d a; set e $d; dict incr d b 5; list $d $e", "{a 2 b 7} {a 2 b 2}" },
    });
}

test "the bytecode: a dict in place stays a value" {
    try check(&.{
        .{ "proc f {} {set d {a 1 b 2}; dict incr d a; dict incr d a; set e $d; dict incr d a; dict set d b 9; list $d $e}; f", "{a 4 b 9} {a 3 b 2}" },
        .{ "proc r {n} {upvar 1 $n x; set c $x; dict incr x k; return $c}; proc f {} {set d {k 1}; dict incr d k; dict incr d k; set o [r d]; dict incr d k; list $d $o}; f", "{k 5} {k 3}" },
        .{ "proc f {} {set d {k 1}; dict incr d k; dict incr d k; foreach {a b} $d {dict incr d k; lappend o $a $b}; list $o $d}; f", "{k 3} {k 4}" },
        .{ "proc f {} {set d {k 1}; dict incr d k; dict incr d k; unset d; catch {set d} m; dict incr d q; list $m $d}; f", "{can't read \"d\": no such variable} {q 1}" },
        .{ "proc f {} {set d {k 1}; set r [dict incr d k]; dict incr d k; list $r $d}; f", "{k 2} {k 3}" },
    });
}

test "the bytecode: append" {
    try check(&.{
        .{ "proc f {} {set s a; append s b; set t $s; append s \"c$s\"; append t \"d[string length $s]\"; list $s $t}; f", "abcab abd5" },
        .{ "proc f {} {set s q; append s $s; append s \"$s$s\"; set s}; f", "qqqqqq" },
        .{ "proc f {} {set a(1) x; catch {append a y} m; set m}; f", "can't set \"a\": variable is array" },
        .{ "proc f {} {set i 7; append i \"x$i\"; set l [list a b]; append l c; list $i $l}; f", "7x7 {a bc}" },
    });
}

test "a large dict keeps the order and the value semantics" {
    try check(&.{
        // New keys, then reads in the order of the first insert.
        .{ "set d {}; for {set i 0} {$i < 1000} {incr i} {dict set d k$i $i}; list [dict size $d] [dict get $d k777] [lindex [dict keys $d] 999] [dict exists $d k1000]", "1000 777 k999 0" },
        // A copy keeps its keys when the first dict gets more keys.
        .{ "set d {}; for {set i 0} {$i < 100} {incr i} {dict set d $i x}; set c $d; for {} {$i < 200} {incr i} {dict set d $i y}; list [dict size $c] [dict exists $c 150] [dict size $d] [dict exists $d 150]", "100 0 200 1" },
        // Two copies grow apart from one buffer.
        .{ "set d {}; for {set i 0} {$i < 40} {incr i} {dict set d $i x}; set a $d; set b $d; dict set a new 1; dict set b new 2; dict set b other 3; list [dict get $a new] [dict get $b new] [dict size $a] [dict size $b] [dict exists $a other]", "1 2 41 42 0" },
        // An integer key and its string form are one key.
        .{ "set d {}; for {set i 0} {$i < 40} {incr i} {dict set d $i x}; dict set d [string trim { 7 }] y; list [dict size $d] [dict get $d 7] [dict get $d [expr {3 + 4}]]", "40 y y" },
        // A key with another text of the same number is a new key.
        .{ "set d {}; for {set i 0} {$i < 40} {incr i} {dict set d $i x}; dict set d 07 y; list [dict size $d] [dict get $d 7] [dict get $d 07]", "41 x y" },
        // In a proc: new keys and updates, with a copy in the middle.
        .{ "proc p {} {set d {}; for {set i 0} {$i < 100} {incr i} {dict set d $i 0; dict incr d $i 5}; set c $d; dict incr d 3 10; dict set d new 1; list [dict get $c 3] [dict get $d 3] [dict size $c] [dict size $d]}; p", "5 15 100 101" },
        // Remove and insert after a large dict.
        .{ "set d {}; for {set i 0} {$i < 50} {incr i} {dict set d $i $i}; dict unset d 25; dict set d 25 back; list [dict size $d] [lindex [dict keys $d] end] [dict exists $d 24]", "50 25 1" },
        // A list with repeated keys becomes a dict with the last value.
        .{ "set l {}; for {set i 0} {$i < 100} {incr i} {lappend l [expr {$i % 20}] $i}; list [dict size $l] [dict get $l 3] [lindex [dict keys $l] 19]", "20 83 19" },
        // A list append after a dict view does not change the dict.
        .{ "set d {}; for {set i 0} {$i < 40} {incr i} {dict set d $i x}; set l $d; lappend l extra; dict set d new 1; list [llength $l] [lindex $l end] [dict size $d] [dict get $d new]", "81 extra 41 1" },
    });
}

fn evalStr(it: *tcl.Interp, script: []const u8) ![]const u8 {
    return it.str(try it.eval(script));
}

test "the list parse cache keeps each read correct" {
    try check(&.{
        // Reads of one string, then an append that extends the string.
        .{ "set s [string repeat {a b } 20]; llength $s; llength $s; append s {c d}; list [llength $s] [lindex $s end]", "42 d" },
        // A write to a parsed copy leaves the string as it was.
        .{ "set s [string repeat {a b } 20]; llength $s; llength $s; set t $s; lset t 0 z; list [lindex $s 0] [lindex $t 0]", "a z" },
        .{ "set s [string repeat {a b } 20]; llength $s; llength $s; lappend s q; list [llength $s] [lindex $s end]", "41 q" },
        // A bad list gives the error at each read.
        .{ "set s \"[string repeat {a } 20]\\{\"; catch {llength $s}; catch {llength $s}; llength $s", "!unmatched open brace in list" },
    });
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.step_limit = 10_000_000;
    _ = try it.eval("set s [string repeat {x y } 30]; llength $s; llength $s");
    try it.compact(&.{}, .{});
    _ = try it.eval("set junk [string repeat {p q r } 30]");
    try std.testing.expectEqualStrings("60", try evalStr(&it, "llength $s"));
    try std.testing.expectEqualStrings("y", try evalStr(&it, "lindex $s 59"));
}

test "compact keeps the commands and returns the memory" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.step_limit = 100_000_000;
    _ = try it.eval(
        \\proc add {a {b 2}} { expr {$a + $b} }
        \\namespace eval m { variable n 5; proc f {} { variable n; incr n }; namespace export f; namespace ensemble create }
        \\namespace eval u { namespace import ::m::f }
        \\array set arr {x 1 y {2 3}}
        \\set big {}; for {set i 0} {$i < 100} {incr i} {dict set big k$i $i}
        \\upvar #0 arr alias
    );
    const before = it.memUsed();
    _ = try it.eval("for {set i 0} {$i < 2000} {incr i} {set junk [string repeat x 4000]}");
    try std.testing.expect(it.memUsed() > before + (4 << 20));
    try it.compact(&.{}, .{});
    try std.testing.expect(it.memUsed() < before + (1 << 16));
    try std.testing.expectEqualStrings("5", try evalStr(&it, "add 3"));
    try std.testing.expectEqualStrings("6", try evalStr(&it, "m f"));
    try std.testing.expectEqualStrings("7", try evalStr(&it, "u::f"));
    try std.testing.expectEqualStrings("2 3", try evalStr(&it, "set alias(y)"));
    try std.testing.expectEqualStrings("77", try evalStr(&it, "dict get $big k77"));
    try std.testing.expectEqualStrings("4000", try evalStr(&it, "string length $junk"));
    // A second pass after the proc compiled again.
    try it.compact(&.{}, .{});
    try std.testing.expectEqualStrings("9", try evalStr(&it, "add 4 5"));
    // The memory stays flat over many evaluations.
    var peak: usize = 0;
    for (0..50) |n| {
        _ = try it.eval("set junk [string repeat y 100000]; add 1 1");
        try it.compact(&.{}, .{});
        if (n == 5) peak = it.memUsed();
        if (n > 5) try std.testing.expect(it.memUsed() <= peak + 4096);
    }
}

test "compact keeps a root value and leaves shared data shared" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.step_limit = 100_000_000;
    var roots = [_]tcl.Value{
        try it.eval("list a {b c} [list d [expr {1 + 2}]]"),
        try it.eval("set s [string repeat abc 10]; string range $s 3 8"),
    };
    try it.compact(&roots, .{});
    try std.testing.expectEqualStrings("a {b c} {d 3}", try it.str(roots[0]));
    try std.testing.expectEqualStrings("abcabc", try it.str(roots[1]));
    // Each level holds the last level twice. A copy with no sharing
    // needs 2^40 cells.
    _ = try it.eval("set d x; for {set i 0} {$i < 40} {incr i} {set d [list $d $d]}");
    const used = it.memUsed();
    try it.compact(&.{}, .{});
    try std.testing.expect(it.memUsed() <= used);
    // Many overlapping substrings of one string copy their bytes once.
    _ = try it.eval("set t [string repeat q 20000]; set l {}; for {set i 0} {$i < 20000} {incr i} {lappend l [string range $t 0 $i]}");
    const used2 = it.memUsed();
    try it.compact(&.{}, .{});
    try std.testing.expect(it.memUsed() <= used2);
    try std.testing.expectEqualStrings("1234", try evalStr(&it, "string length [lindex $l 1233]"));
    // A deep list uses the work list and no native stack.
    _ = try it.eval("set deep x; for {set i 0} {$i < 200000} {incr i} {set deep [list $deep]}");
    try it.compact(&.{}, .{});
    try std.testing.expectEqualStrings("1", try evalStr(&it, "llength $deep"));
}

fn callCompact(it: *tcl.Interp, _: []const tcl.Value, _: ?*tcl.interp.Cmd) tcl.Error!tcl.Value {
    it.compact(&.{}, .{}) catch |e| switch (e) {
        error.InterpBusy => return .{ .str = "busy" },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .str = "done" };
}

test "compact refuses to run inside a script, and clears variables on request" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.register("callcompact", callCompact);
    try std.testing.expectEqualStrings("busy", try evalStr(&it, "callcompact"));
    try std.testing.expectEqualStrings("busy", try evalStr(&it, "proc p {} {callcompact}; p"));
    _ = it.eval("error boom") catch {};
    try it.compact(&.{}, .{});
    try std.testing.expectEqualStrings("boom", try evalStr(&it, "set errorInfo; lindex $errorInfo 0"));
    _ = try it.eval("set v 1; namespace eval n {variable w 2}; proc q {} {return ok}");
    try it.compact(&.{}, .{ .vars = .clear });
    try std.testing.expectEqualStrings("0 0 ok 8.6", try evalStr(&it, "list [info exists v] [info exists n::w] [q] $tcl_version"));
}

test "compact keeps the point programs" {
    var state: tcl.point.State = .{};
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try tcl.point.install(&it, &state);
    _ = try it.eval("point proc f {x} { offset [expr {$x * 2}] }");
    _ = try it.eval("string repeat z 100000");
    try it.compact(&.{}, .{});
    const p = state.program("f") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("f", p.name);
    try std.testing.expect(p.ops.len > 0);
    try std.testing.expectEqualStrings("f", (try evalStr(&it, "info procs f")));
}

test "big integers follow the overflow of Tcl" {
    try check(&.{
        .{ "expr {2**64}", "18446744073709551616" },
        .{ "expr {1<<64}", "18446744073709551616" },
        .{ "expr {-9223372036854775808 - 1}", "-9223372036854775809" },
        .{ "expr {9223372036854775807 * 2}", "18446744073709551614" },
        .{ "expr {0xFFFFFFFFFFFFFFFF}", "18446744073709551615" },
        .{ "expr {~0xFFFFFFFFFFFFFFFF}", "-18446744073709551616" },
        .{ "expr {18446744073709551616 % 7}", "2" },
        .{ "expr {(2**70) / (2**68)}", "4" },
        .{ "expr {abs(-9223372036854775808)}", "9223372036854775808" },
        .{ "expr {entier(1e30)}", "1000000000000000019884624838656" },
        .{ "expr {wide(2**64 + 5)}", "5" },
        .{ "expr {-340282366920938463463374607431768211457 | 0xFFFFFFFFFFFFFFFF}", "-340282366920938463463374607431768211457" },
        .{ "set i 9223372036854775807; incr i", "9223372036854775808" },
        .{ "proc p {} {set i 9223372036854775807; incr i; incr i -1; return $i}; p", "9223372036854775807" },
        .{ "set d {}; dict incr d k 9223372036854775807; dict incr d k; dict get $d k", "9223372036854775808" },
        .{ "format %lld 18446744073709551616", "18446744073709551616" },
        .{ "catch {expr {1 << 18446744073709551615}} r; set r", "integer value too large to represent" },
    });
}

test "the inline list and string reads keep the command semantics" {
    try check(&.{
        .{ "proc p {} {set l {a {b c} d}; list [llength $l] [lindex $l 1] [lindex $l end] [lindex $l 9] [lindex $l -1] [lindex $l {1 0}]}; p", "3 {b c} d {} {} b" },
        .{ "proc p {} {set s abc; list [string length $s] [string index $s 1] [string index $s end] [string index $s 9]}; p", "3 b c {}" },
        .{ "proc p {} {set s \"a \\{b\"; llength $s}; p", "!unmatched open brace in list" },
        .{ "proc p {} {lindex {a b} x}; p", "!bad index \"x\": must be integer?[+-]integer? or end?[+-]integer?" },
        .{ "proc p {} {llength {a b}}; p; rename llength ll; proc llength {x} {return custom}; p", "custom" },
        .{ "proc p {} {lindex {a b} 1}; p; rename lindex li; proc lindex {l i} {return mine}; p", "mine" },
        .{ "proc p {} {string length abc}; p; rename string st; proc string {args} {return other}; p", "other" },
        .{ "namespace eval n {proc llength {x} {return inner}; proc q {} {llength {a b}}}; n::q", "inner" },
    });
}

test "recursion through subst, an ensemble, and unknown stays bounded" {
    try check(&.{
        .{ "set s {[subst $s]}; catch {subst $s} m; set m", "too many nested evaluations (infinite loop?)" },
        .{ "namespace ensemble create -command e1 -map {a {e1 a}}; catch {e1 a} m; set m", "too many nested evaluations (infinite loop?)" },
        .{ "proc unknown args {nosuch2 x}; catch {nosuch1} m; set m", "invalid command name \"nosuch2\"" },
    });
}

test "traces, upvar to an element, and tcl_precision" {
    try check(&.{
        .{ "proc w {n i o} {set ::log [list $n $i $o]}; trace add variable x write w; set x 1; set log", "x {} write" },
        .{ "proc u {} {upvar 1 q(1) y; set y 5}; u; set q(1)", "5" },
        .{ "set tcl_precision 3; set r [string cat [expr {1/3.0}]]; set tcl_precision 0; set r", "0.333" },
        .{ "::tcl::mathop::+ 1 2 3", "6" },
        .{ "tcl::prefix match {apple banana} b", "banana" },
    });
}

test "coroutines and tail calls" {
    if (!@import("coro.zig").supported) return error.SkipZigTest;
    try check(&.{
        .{ "proc g {} {set i 0; while 1 {yield [incr i]}}; list [coroutine c g] [c] [c]", "1 2 3" },
        .{ "proc g {} {yield 1; return 2}; coroutine c g; list [c] [info commands c]", "2 {}" },
        .{ "proc g {} {set x [yield a]; return $x}; coroutine c g; c hello", "hello" },
        .{ "catch {yield 1} m; set m", "yield can only be called in a coroutine" },
        .{ "proc g {} {catch {yield 1}; set ::after 1}; coroutine c g; rename c {}; info exists ::after", "0" },
        .{ "proc r {n} {r [incr n]}; catch {coroutine c r 0} m; set m", "too many nested evaluations (infinite loop?)" },
        .{ "proc f {n a} {if {$n == 0} {return $a}; tailcall f [expr {$n-1}] [expr {$a+1}]}; f 5000 0", "5000" },
    });
}

test "the optional commands are absent by default" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    for ([_][]const u8{ "package", "interp", "clock", "file", "open", "socket", "exec", "pid", "time", "timerate", "chan", "encoding", "source", "load", "cd", "pwd", "glob", "after", "vwait", "update", "fileevent", "fblocked", "tcl::Bgerror" }) |name| {
        try std.testing.expect(it.findCommand(name) == null);
    }
}

test "a child has no more capabilities than its parent" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@intFromEnum(tcl.interp.Capability.interp));
    try std.testing.expectEqualStrings("{} 0", try it.str(try it.eval("interp create c; list [c eval {info commands package}] [interp issafe c]")));
    try std.testing.expectEqualStrings("interp", try it.str(try it.eval("c eval {info commands interp}")));
    try std.testing.expectEqualStrings("{}", try it.str(try it.eval("interp create -safe s; list [s eval {info commands interp}]")));
    try std.testing.expectEqualStrings("7", try it.str(try it.eval("interp alias c dbl {} expr 3+; c eval {dbl 4}")));
    _ = try it.eval("interp delete c");
}

test "a child that deletes itself through an alias stays safe" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@intFromEnum(tcl.interp.Capability.interp));
    _ = try it.eval("interp create c; proc kill {} {interp delete c; return done}; interp alias c k {} kill");
    try std.testing.expectEqualStrings("done", try it.str(try it.eval("c eval {proc p {} {set x [k]; return $x}; p}")));
    try std.testing.expectEqualStrings("0", try it.str(try it.eval("interp exists c")));
}

fn fixedClock(_: ?*anyopaque) i64 {
    return 86_400_000_000;
}

test "clock reads the time only from the host callback" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@intFromEnum(tcl.interp.Capability.clock));
    _ = it.eval("clock seconds") catch {};
    try std.testing.expectEqualStrings("the embedder gave no clock", try it.str(it.result));
    it.clock_host = .{ .now = fixedClock };
    try std.testing.expectEqualStrings("86400", try it.str(try it.eval("clock seconds")));
    try std.testing.expectEqualStrings("1970-01-02", try it.str(try it.eval("clock format [clock seconds] -format %Y-%m-%d -gmt 1")));
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("catch {clock format 0 -timezone :../../etc/passwd}")));
}

test "file and channels cannot leave the root folder" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base: i32 = tmp.dir.handle;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdirat(base, "root", 0o777)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdirat(base, "root/sub", 0o777)));
    const secret = linux.openat(base, "secret", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o666);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(secret));
    _ = linux.write(@intCast(secret), "hidden", 6);
    _ = linux.close(@intCast(secret));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("../secret", base, "root/out")));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("..", base, "root/sub/up")));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("/etc", base, "root/etc")));
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const rc = linux.openat(base, "root", .{ .DIRECTORY = true, .PATH = true, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    it.fs.fd = @intCast(rc);
    try it.allow(@intFromEnum(tcl.interp.Capability.channels) | @intFromEnum(tcl.interp.Capability.file));
    for ([_][]const u8{
        "open ../secret", "open /../secret", "open sub/../../secret", "open out", "open sub/up/../secret",
        "open etc/passwd", "open out w", "source ../secret", "source out", "cd ..", "cd etc",
        "file size ../secret", "file delete ../secret", "file mkdir ../made", "file rename sub ../moved",
        "file copy ../secret here", "file copy out here", "file link -symbolic x /etc", "file readlink out",
    }) |script| {
        if (it.eval(script)) |_| {
            std.debug.print("escaped: {s}\n", .{script});
            return error.TestUnexpectedResult;
        } else |e| try std.testing.expectEqual(error.TclError, e);
    }
    // The file outside still has its text, and no new name exists there.
    const kept = linux.openat(base, "secret", .{}, 0);
    var buf: [16]u8 = undefined;
    const n = linux.read(@intCast(kept), &buf, buf.len);
    _ = linux.close(@intCast(kept));
    try std.testing.expectEqualStrings("hidden", buf[0..n]);
    try std.testing.expectEqual(linux.E.NOENT, linux.errno(linux.openat(base, "made", .{}, 0)));
    try std.testing.expectEqualStrings("ok", try it.str(try it.eval("set f [open sub/a.txt w]; puts $f ok; close $f; set f [open sub/a.txt]; set l [gets $f]; close $f; set l")));
}

var fake_ticks: i64 = 0;

fn fakeNow(_: ?*anyopaque) i64 {
    return fake_ticks;
}

fn fakeSleep(_: ?*anyopaque, micros: i64) void {
    fake_ticks += micros;
}

test "the event loop runs timers and idle scripts in order" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const cap = tcl.interp.Capability;
    try it.allow(@intFromEnum(cap.event) | @intFromEnum(cap.interp));
    _ = it.eval("after 10 {set x 1}") catch {};
    try std.testing.expectEqualStrings("the embedder gave no event clock", try it.str(it.result));
    fake_ticks = 0;
    it.event_host = .{ .now = fakeNow, .sleep = fakeSleep };
    try std.testing.expectEqualStrings("c a b", try it.str(try it.eval("after 20 {lappend l b; set done 1}; after 10 {lappend l a}; after idle {lappend l c}; vwait done; set l")));
    // The clock of the test moved only through the sleep callback.
    try std.testing.expectEqual(@as(i64, 20_000), fake_ticks);
    try std.testing.expectEqualStrings("can't wait for variable \"never\": would wait forever", try it.str(try it.eval("catch {vwait never} m; set m")));
    try std.testing.expectEqualStrings("1 {}", try it.str(try it.eval("set id [after 5 {set y 1}]; set n [llength [after info]]; after cancel $id; list $n [after info]")));
    try std.testing.expectEqualStrings("boom", try it.str(try it.eval("proc bgerror {m} {set ::got $m}; after 0 {error boom}; vwait got; set got")));
    // A child uses the loop of its parent, and its events end with it.
    try std.testing.expectEqualStrings("2 0", try it.str(try it.eval("interp create c; c eval {after 1 {set z 2}}; update; after 1; update; set r [c eval {set z}]; c eval {after 1000 {set q 1}}; interp delete c; list $r [llength [after info]]")));
    try std.testing.expectEqualStrings("{} {}", try it.str(try it.eval("interp create -safe s; list [s eval {info commands socket}] [s eval {info commands exec}]")));
    // An event script and an error handler can delete their interpreter.
    try std.testing.expectEqualStrings("0", try it.str(try it.eval("interp create d; interp alias d kill {} interp delete d; d eval {after 0 kill; after 0 {set never 1}}; update; interp exists d")));
    try std.testing.expectEqualStrings("0", try it.str(try it.eval("interp create e; interp alias e kill {} interp delete e; e eval {proc bgerror {m} {kill}; after 0 {error x}}; update; update; interp exists e")));
    // A long delay does not overflow.
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("set id [after 99999999999999 {set z 1}]; after cancel $id; llength [list $id]")));
}

test "socket accepts only loopback addresses by default" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const cap = tcl.interp.Capability;
    try it.allow(@intFromEnum(cap.channels) | @intFromEnum(cap.event) | @intFromEnum(cap.socket));
    fake_ticks = 0;
    it.event_host = .{ .now = fakeNow, .sleep = fakeSleep };
    for ([_][]const u8{
        "socket example.com 80",     "socket 192.0.2.1 80",                "socket 10.0.0.1 80",
        "socket 0.0.0.0 80",         "socket ::ffff:192.0.2.1 80",         "socket -server x -myaddr 0.0.0.0 0",
        "socket -server x -myaddr :: 0", "socket -myaddr 192.0.2.1 localhost 80", "socket 127.0.0.1.example.com 80",
    }) |script| {
        if (it.eval(script)) |_| {
            std.debug.print("opened: {s}\n", .{script});
            return error.TestUnexpectedResult;
        } else |e| try std.testing.expectEqual(error.TclError, e);
    }
    const script =
        \\proc accept {s a p} {set ::peer $a; fileevent $s readable [list echo $s]}
        \\proc echo {s} {if {[gets $s line] < 0} {close $s; return}; puts $s "got $line"; flush $s}
        \\set srv [socket -server accept 0]
        \\set c [socket 127.0.0.1 [lindex [fconfigure $srv -sockname] 2]]
        \\puts $c hello; flush $c
        \\fileevent $c readable {set reply [gets $c]}
        \\vwait reply
        \\close $c; update; close $srv
        \\list $peer $reply [lindex [chan names] end]
    ;
    try std.testing.expectEqualStrings("127.0.0.1 {got hello} stdout", try it.str(try it.eval(script)));
}

test "exec has an allowlist and a time limit, and leaves no process" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const cap = tcl.interp.Capability;
    // `file` and channels do not turn on `exec`.
    try it.allow(@intFromEnum(cap.channels) | @intFromEnum(cap.file) | @intFromEnum(cap.interp));
    try std.testing.expect(it.findCommand("exec") == null);
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("catch {open |echo}")));
    try std.testing.expectEqualStrings("{}", try it.str(try it.eval("interp create c; list [c eval {info commands exec}]")));
    try it.allow(@intFromEnum(cap.exec));
    it.exec_host = .{ .allow = &.{ "echo", "/usr/bin/cat", "sleep", "sh" }, .timeout_ms = 300, .env = &.{"PATH=/usr/bin:/bin"} };
    try std.testing.expectEqualStrings("a b", try it.str(try it.eval("exec echo a b")));
    try std.testing.expectEqualStrings("A", try it.str(try it.eval("exec echo A | cat")));
    try std.testing.expectEqualStrings("in", try it.str(try it.eval("exec cat << in")));
    // A program that is not in the list does not start.
    try std.testing.expectEqualStrings("1 {couldn't execute \"ls\": the embedder does not allow this program}", try it.str(try it.eval("list [catch {exec ls} m] $m")));
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("catch {exec echo x | tr x y}")));
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("catch {exec /bin/ls}")));
    // The words go to the program as they are. No shell reads them.
    try std.testing.expectEqualStrings("$HOME; ls `id`", try it.str(try it.eval("exec echo {$HOME; ls `id`}")));
    // The program gets only the environment of the embedder.
    try std.testing.expectEqualStrings("PATH=/usr/bin:/bin", try it.str(try it.eval("exec sh -c {export -p | cut -d' ' -f2- | tr -d \\\" | grep -v -e PWD -e OLDPWD -e SHLVL -e '^_=' ; true}")));
    // The time limit ends the program and each process that it made.
    const before = linux.getpid();
    _ = before;
    try std.testing.expectEqualStrings("1 {child killed: the time limit of 300 ms ended}", try it.str(try it.eval("list [catch {exec sh -c {sleep 60 & echo $! > /dev/null; wait}} m] $m")));
    // A background process ends with the interpreter.
    const pid_text = try it.str(try it.eval("exec sleep 60 &"));
    const pid = try std.fmt.parseInt(i32, pid_text, 10);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.kill(pid, @enumFromInt(0))));
    const pipe_pid = try std.fmt.parseInt(i32, try it.str(try it.eval("set f [open {|sleep 60} r]; pid $f")), 10);
    it.deinit();
    try std.testing.expectEqual(linux.E.SRCH, linux.errno(linux.kill(pid, @enumFromInt(0))));
    try std.testing.expectEqual(linux.E.SRCH, linux.errno(linux.kill(pipe_pid, @enumFromInt(0))));
    try it.init(std.testing.allocator);
}

test "TclOO: classes, methods, next, mixins, and destructors" {
    try check(&.{
        .{ "oo::class create A {variable n; constructor {x} {set n $x}; method get {} {return $n}; method Hidden {} {return h}}; set o [A new 5]; list [$o get] [catch {$o Hidden}]", "5 1" },
        .{ "oo::class create B {method m {} {return b}}; oo::class create C {superclass B; method m {} {return c[next]}}; [C new] m", "cb" },
        .{ "oo::class create M {method m {} {return m[next]}}; oo::class create D {method m {} {return d}}; D create d; oo::objdefine d mixin M; d m", "md" },
        .{ "oo::class create E {destructor {lappend ::log gone}}; E create e; e destroy; list $::log [info commands e]", "gone {}" },
        .{ "oo::class create F {method who {} {self}}; F create f; list [f who] [info object class f] [info object isa object f]", "::f ::F 1" },
        .{ "oo::object create o; oo::objdefine o forward len string length; o len abcd", "4" },
        .{ "catch {self} m; set m", "invalid command name \"self\"" },
    });
}

test "the network policy of socket: allowlist, ranges, ports, and peers" {
    const sock = tcl.sock;
    const sys = tcl.sys;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lo4 = sys.parseAddr("127.0.0.1").?;
    const lo6 = sys.parseAddr("::1").?;
    const out4 = sys.parseAddr("192.0.2.7").?;
    const out6 = sys.parseAddr("2001:db8::7").?;
    // The default allows only loopback addresses.
    try std.testing.expect(sock.permits(.loopback, lo4, 80, null));
    try std.testing.expect(sock.permits(.loopback, lo6, 80, null));
    try std.testing.expect(sock.permits(.loopback, sys.parseAddr("127.9.9.9").?, 80, null));
    try std.testing.expect(!sock.permits(.loopback, out4, 80, "localhost"));
    try std.testing.expect(!sock.permits(.loopback, out6, 80, null));
    try std.testing.expect(!sock.permits(.loopback, sys.parseAddr("0.0.0.0").?, 80, null));
    try std.testing.expect(sock.permits(.any, out4, 1, null));
    // A list: a range with ports, one address, an IPv6 range, a host.
    const p = (try sock.parsePolicy(a, "allow=192.0.2.0/24:80-90,10.1.2.3,[2001:db8::]/32:443,example.test:8080")).?;
    try std.testing.expect(sock.permits(p, out4, 80, null));
    try std.testing.expect(sock.permits(p, out4, 90, null));
    try std.testing.expect(!sock.permits(p, out4, 91, null));
    try std.testing.expect(!sock.permits(p, sys.parseAddr("192.0.3.7").?, 80, null));
    try std.testing.expect(sock.permits(p, sys.parseAddr("10.1.2.3").?, 5, null));
    try std.testing.expect(!sock.permits(p, sys.parseAddr("10.1.2.4").?, 5, null));
    try std.testing.expect(sock.permits(p, out6, 443, null));
    try std.testing.expect(!sock.permits(p, out6, 80, null));
    try std.testing.expect(!sock.permits(p, sys.parseAddr("2001:db9::7").?, 443, null));
    // A host rule allows the addresses of that name only, and only
    // for a connection that the script made with the name.
    try std.testing.expect(sock.permits(p, sys.parseAddr("203.0.113.5").?, 8080, "Example.Test"));
    try std.testing.expect(!sock.permits(p, sys.parseAddr("203.0.113.5").?, 8080, "other.test"));
    try std.testing.expect(!sock.permits(p, sys.parseAddr("203.0.113.5").?, 8080, null));
    try std.testing.expect(!sock.permits(p, lo4, 80, null));
    try std.testing.expect((try sock.parsePolicy(a, "allow=1.2.3.4/40")) == null);
    try std.testing.expect((try sock.parsePolicy(a, "everything")) == null);
    try std.testing.expect(sys.parseAddr("1.2.3") == null);
    try std.testing.expect(sys.parseAddr("1::2::3") == null);
    try std.testing.expect(sys.parseAddr("256.1.1.1") == null);
}

test "socket refuses a blocked address and closes a blocked peer" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const cap = tcl.interp.Capability;
    try it.allow(@intFromEnum(cap.channels) | @intFromEnum(cap.event) | @intFromEnum(cap.socket) | @intFromEnum(cap.interp));
    fake_ticks = 0;
    it.event_host = .{ .now = fakeNow, .sleep = fakeSleep };
    // The list allows the address 127.0.0.2 and no other address. A
    // name that gives another address is refused: `localhost` gives
    // 127.0.0.1 and ::1.
    it.net = (try tcl.sock.parsePolicy(it.alloc(), "allow=127.0.0.2")).?;
    try std.testing.expectEqualStrings("1 1 1", try it.str(try it.eval("list [catch {socket localhost 9}] [catch {socket 127.0.0.1 9}] [catch {socket -server x -myaddr 127.0.0.1 0}]")));
    try std.testing.expectEqualStrings("ZTCL NET DENIED", try it.str(try it.eval("catch {socket localhost 9}; set errorCode")));
    // A child has the same policy.
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("interp create c; c eval {catch {socket 127.0.0.1 9}}")));
    // The server listens on the allowed address. The peer of the
    // connection is 127.0.0.1, so the server closes it and the accept
    // command does not run.
    const script =
        \\set got none
        \\set srv [socket -server {apply {{s a p} {set ::got $a; close $s}}} -myaddr 127.0.0.2 0]
        \\set c [socket 127.0.0.2 [lindex [fconfigure $srv -sockname] 2]]
        \\update
        \\set end [read $c]
        \\close $c; close $srv
        \\list $got [string length $end]
    ;
    try std.testing.expectEqualStrings("none 0", try it.str(try it.eval(script)));
}
