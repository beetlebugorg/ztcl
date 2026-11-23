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
        it.fuel = 10_000_000;
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
        .{ "expr {9223372036854775807 + 1}", "-9223372036854775808" },
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
        .{ "expr {sqrt()}", "!too few arguments for math function \"sqrt\"" },
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
        .{ "while 1 {}", "!the script ran out of fuel" },
        .{ "catch {while 1 {}}", "!the script ran out of fuel" },
        .{ "proc f {} {f2}; proc f2 {} {catch {while 1 {}}}; f", "!the script ran out of fuel" },
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
        .{ "llength \"a {b\"", "!unmatched open brace or quote in list" },
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
        .{ "string bogus", "!unknown or ambiguous subcommand \"bogus\": must be cat, compare, equal, first, index, is, last, length, map, match, range, repeat, replace, reverse, tolower, totitle, toupper, trim, trimleft, or trimright" },
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

test "the fuel counter stops a long script" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.fuel = 1000;
    try std.testing.expectError(error.TclError, it.eval("set i 0; while {1} {incr i}"));
    try std.testing.expectEqualStrings("the script ran out of fuel", try it.str(it.result));
    // More fuel lets the interpreter run again.
    it.fuel = 1000;
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
        .{ "catch {expr {1/0}}; set errorCode", "NONE" },
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
        .{ "regexp {a|ab} ab m; set m", "a" },
        .{ "regexp {x*?y} xxy m; set m", "xxy" },
        .{ "regexp {a{2,3}} aaaa m; set m", "aaa" },
        .{ "regexp {[[:digit:]]+} ab123 m; set m", "123" },
        .{ "regexp {(a)\\1} xaa", "1" },
        .{ "regexp {\\mfoo\\M} {a foo b}", "1" },
        .{ "regexp {(a*)*b} aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac", "!the script ran out of fuel" },
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
