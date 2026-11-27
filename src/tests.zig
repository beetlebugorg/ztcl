//! Tests of the parser, the interpreter, `expr`, and the core commands.
//!
//! Each case is a script and the string form of its result. The results
//! are those of tclsh 8.6.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl.zig");
const modules = @import("modules.zig");

test {
    _ = @import("json/tests.zig");
}

const Case = struct { []const u8, []const u8 };

/// Runs each script in a new interpreter and compares the result. An
/// expected text that starts with "!" is an error message.
fn check(cases: []const Case) !void {
    for (cases) |c| {
        var it: tcl.Interp = undefined;
        try it.init(std.testing.allocator);
        defer it.deinit();
        it.compute_limit = 10_000_000;
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
        .{ "catch {return -code error -errorcode X msg} r o; set o", "-errorcode X -code 1 -level 1" },
        .{ "catch {return -code error -errorcode X -errorinfo EI m} r o; set o", "-errorcode X -errorinfo EI -code 1 -level 1 -errorline 1" },
        .{ "catch {return -errorcode A -options {-errorcode B} -x 1 m} r o; set o", "-errorcode B -x 1 -code 0 -level 1" },
        .{ "catch {return -code return -level 2 m} r o; set o", "-code 0 -level 3" },
        .{ "list [catch {return -level 0 -code break foo} r] $r", "3 foo" },
        .{ "list [catch {set a 5; break} r] $r", "3 {}" },
        .{ "proc f {} {set s {error t}; catch $s; set ::errorInfo}; f", "t\n    while executing\n\"error t\"\n    invoked from within\n\"catch $s\"" },
        .{ "proc f {} {catch {error t}; set ::errorInfo}; f", "t\n    while executing\n\"error t\"" },
        .{ "set s {error t}; catch $s m; set errorInfo", "t\n    while executing\n\"error t\"" },
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
        .{ "while 1 {}", "!compute limit reached" },
        .{ "catch {while 1 {}}", "!compute limit reached" },
        .{ "proc f {} {f2}; proc f2 {} {catch {while 1 {}}}; f", "!compute limit reached" },
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
        .{ "split \\u00e9x {}", "\u{e9} x" },
        .{ "split a\\u00e9b\\u00e9c \\u00e9", "a b c" },
        .{ "llength [split a\\u4e00b {}]", "3" },
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
        .{ "string map {abc 1 ab 2 a 3 {} z} xxabcabxaxyzab", "xx12x3xyz2" },
        .{ "string map -nocase {a b} AaAa", "bbbb" },
        .{ "string map {longkeyhere 1 e 2} {short e}", "short 2" },
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

test "the compute limit stops a long script" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.compute_limit = 1000;
    try std.testing.expectError(error.TclError, it.eval("set i 0; while {1} {incr i}"));
    try std.testing.expectEqualStrings("compute limit reached", try it.str(it.result));
    // A higher compute limit lets the interpreter run again.
    it.compute_limit = 1000;
    const v = try it.eval("set i");
    try std.testing.expect(v.asInt().? > 100);
}

test "a loop body and a braced expr compile once" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    _ = try it.eval("proc sum n {set s 0; for {set i 0} {$i < $n} {incr i} {set s [expr {$s + $i}]}; return $s}");
    _ = try it.eval("sum 10");
    const before = it.heap.bytes;
    const v = try it.eval("sum 20000");
    try std.testing.expectEqual(@as(?i64, 199990000), v.asInt());
    // 20 000 passes add no memory: the words of a command live on a
    // stack, and an integer needs no allocation.
    try std.testing.expect(it.heap.bytes - before < 64 * 1024);
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
        .{ "catch {return -code error -errorcode {Q 2} m} m o; set o", "-errorcode {Q 2} -code 1 -level 1" },
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

/// A child allocator that grows a block in place only when `in_place`
/// is true. Otherwise each growth is a copy to a new block.
const MoveAlloc = struct {
    child: std.mem.Allocator,
    in_place: bool,

    fn allocator(m: *MoveAlloc) std.mem.Allocator {
        return .{ .ptr = m, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const m: *MoveAlloc = @ptrCast(@alignCast(ctx));
        return m.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const m: *MoveAlloc = @ptrCast(@alignCast(ctx));
        if (n > mem.len and !m.in_place) return false;
        return m.child.rawResize(mem, a, n, ra);
    }
    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const m: *MoveAlloc = @ptrCast(@alignCast(ctx));
        if (n > mem.len and !m.in_place) return null;
        return m.child.rawRemap(mem, a, n, ra);
    }
    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const m: *MoveAlloc = @ptrCast(@alignCast(ctx));
        m.child.rawFree(mem, a, ra);
    }
};

/// The compute units, the memory count, and the peak of one run at the
/// memory limit `limit`, with the collector off.
fn moveRun(in_place: bool, limit: usize) ![3]usize {
    // On Linux, `page_allocator` grows a block with `mremap`.
    var m: MoveAlloc = .{ .child = std.heap.page_allocator, .in_place = in_place };
    var it: tcl.Interp = undefined;
    try it.init(m.allocator());
    defer it.deinit();
    it.gc_on = false;
    it.mem_limit = limit;
    it.compute_limit = 1_000_000;
    _ = it.eval("set n 1000; while 1 {set l [split [string repeat \"ab\\n\" $n] \\n]; incr n 1000}") catch {};
    return .{ 1_000_000 - @as(usize, @intCast(it.compute_limit)), it.memUsed(), it.counter.mem_peak };
}

test "the memory limit stops a script at the same point when the allocator grows a block in place or copies it" {
    // The JIT regions change the free addresses of the child allocator,
    // and so the growths that it does in place.
    var limit: usize = 200_000;
    while (limit < 1_000_000) : (limit += 997) {
        const a = try moveRun(true, limit);
        const b = try moveRun(false, limit);
        try std.testing.expectEqual(a, b);
    }
}

test "a request above twice the memory limit stops the script, and catch cannot catch it" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.gc_on = false;
    it.mem_limit = 8 << 20;
    const r = it.eval("set n 0; catch {string length [string repeat x 64000000]}; incr n");
    try std.testing.expectError(error.TclError, r);
    try std.testing.expectEqualStrings("the script used too much memory", try it.str(it.result));
    try std.testing.expectEqualStrings("the script used too much memory", try it.str(try it.getVarPlain("::errorInfo")));
    try std.testing.expect(it.counter.mem_peak <= 2 * it.mem_limit);
    try std.testing.expect(!it.overLimit());
    const v = try it.eval("set n");
    try std.testing.expectEqual(@as(?i64, 0), v.asInt());
}

test "after a memory error, the next eval runs and the limit still holds" {
    // The bomb leaves `s` live above the limit. The next eval must run,
    // and a second bomb must stop at the hard cap.
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.mem_limit = 16 << 20;
    it.compute_limit = 10_000_000;
    const bomb = "set s x; catch {while 1 {append s $s}}";
    try std.testing.expectError(error.TclError, it.eval(bomb));
    try std.testing.expectEqualStrings("the script used too much memory", try it.str(it.result));
    try std.testing.expect(it.memUsed() > it.mem_limit);
    const v = try it.eval("set x 1; expr {$x+1}");
    try std.testing.expectEqual(@as(?i64, 2), v.asInt());
    try std.testing.expectError(error.TclError, it.eval(bomb));
    try std.testing.expectEqualStrings("the script used too much memory", try it.str(it.result));
    try std.testing.expect(it.counter.mem_peak <= 2 * it.mem_limit);
    // After `unset`, a collection brings the count below the limit, and
    // the limit applies again in the same eval. With only the hard cap,
    // the list grows to about 320 strings.
    try std.testing.expectError(error.TclError, it.eval("unset s; set l {}; while 1 {lappend l [string repeat x 100000]}"));
    try std.testing.expectEqualStrings("the script used too much memory", try it.str(it.result));
    const n = (try it.eval("llength $l")).asInt().?;
    try std.testing.expect(n > 100 and n * 100000 < 16 << 20);
    try std.testing.expectEqual(@as(?i64, 3), (try it.eval("unset l; expr {1+2}")).asInt());
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
        // A sequence with zero repeats at the end of the input (an old underflow).
        .{ "regexp {a.{0,5}b{0,3}} a", "1" },
        .{ "regexp {^a+b$} xaaab", "0" },
        .{ "regexp {(\\d+)-(\\d+)} {tel 555-1234 x} all a b; list $all $a $b", "555-1234 555 1234" },
        .{ "regexp -inline {([a-z]+)(\\d)?} abc", "abc abc {}" },
        .{ "regexp -all -inline {\\w+} {one two  three}", "one two three" },
        .{ "regexp -all {a} banana", "3" },
        // The scan to the first candidate of a match.
        .{ "regexp -all -indices -inline {(fox|dog) \\d} {a fox 1 b dog 2 fox}", "{2 6} {2 4} {10 14} {10 12}" },
        .{ "regexp -inline -indices -nocase {B+} \\u00e9\\u00e9abbb", "{3 5}" },
        .{ "regexp -inline -indices {\\u65e5} xx\\u00e9\\u65e5", "{3 3}" },
        .{ "regexp -inline -start 3 -indices {a*b} aabxab", "{4 5}" },
        // The lazy DFA: threads of more than one start, a character
        // above 255, and a match after many cached steps.
        .{ "regexp -all -inline {[a-z]+ps} {the jumps cups x}", "jumps cups" },
        .{ "regexp -indices {ab*c|bd} abbbbd m; set m", "4 5" },
        .{ "regexp -inline -indices {x[ab]*y} xaxbby", "{2 5}" },
        .{ "regexp -inline -indices {a[^ ]*s} \"a\\u00e9 b a\\u00e9\\u00e9s\"", "{5 8}" },
        .{ "regsub -all {o[^ ]*s} {foos boots so} <&>", "f<oos> b<oots> so" },
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

test "the count cache of long strings stays true" {
    try check(&.{
        // A long string with one non-ASCII character, read two times.
        .{ "set s [string repeat abcd 100]\\u00e9; list [string length $s] [string index $s end] [string length $s] [string index $s 399]", "401 \u{e9} 401 d" },
        // An append that grows the buffer in place gives a new length.
        .{ "set s [string repeat x 300]; set n [string length $s]; append s \\u00e9\\u00e9; list $n [string length $s] [string index $s 301]", "300 302 \u{e9}" },
        // A prefix of a counted string has its own count.
        .{ "set a [string repeat ab 200]; string length $a; set a [string range $a 0 397]\\u00e9; list [string length $a] [string bytelength $a]", "399 400" },
    });
}

test "eval of a list value runs its words" {
    try check(&.{
        .{ "eval [list]", "" },
        .{ "set x [list set y {$z}]; eval $x; set y", "$z" },
        .{ "set l [list lset l 0 X]; eval $l; set l", "X l 0 X" },
        .{ "proc f {} {eval [list error boom]}; catch f; set errorInfo", "boom\n    while executing\n\"error boom\"\n    invoked from within\n\"eval [list error boom]\"\n    (procedure \"f\" line 1)\n    invoked from within\n\"f\"" },
        .{ "proc d n {if {$n > 0} {eval [list d [expr {$n - 1}]]} else {info level}}; d 4", "5" },
        .{ "catch {eval [list nosuch a]} m; set m", "invalid command name \"nosuch\"" },
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
        .{ "scan \\uDCDC %c", "56540" },
        .{ "scan [format %c 0xD800] %c", "55296" },
        .{ "scan \\uD83D\\uDE02 %c", "128514" },
        .{ "string length \\uD83Dx", "2" },
        .{ "string toupper \\U10428", "\u{10400}" },
        .{ "scan {} a%d x", "-1" },
        .{ "scan + %i x", "-1" },
        .{ "scan 0x %i%s", "0 x" },
        .{ "scan {0b10 0b101} {%i%s %b}", "0 b10 5" },
        .{ "scan 99999999999999999999 %d", "9223372036854775807" },
        .{ "scan 1ffffffffffffffff %llx", "36893488147419103231" },
        .{ "scan -1 %u", "18446744073709551615" },
        .{ "scan 5 %llu", "!unsigned bignum scans are invalid" },
        .{ "scan -Inf %g", "-Inf" },
        .{ "scan abc {bogus%1$c%5$c}", "{} {} {} {} {}" },
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
    it.compute_limit = 10_000_000;
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
    it.compute_limit = 100_000_000;
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
    it.compute_limit = 100_000_000;
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

test "the text cache gives the same script to a text that comes again" {
    try check(&.{
        // A redefined command and a changed namespace give a new lookup.
        .{ "proc p {} {return g}; namespace eval n1 {proc p {} {return n1}}; set r {}; foreach k {1 2} {lappend r [eval p {}] [namespace eval n1 {eval p {}}]}; proc p {} {return h}; lappend r [eval p {}]", "g n1 g n1 h" },
        // A renamed command gives a new lookup.
        .{ "proc p {} {return a}; set r [eval p {}]; rename p q; proc p {} {return b}; lappend r [eval p {}] [eval q {}]", "a b a" },
        // A syntax error gives the error at each eval.
        .{ "set r {}; foreach k {1 2} {lappend r [catch {eval {set x [} {}} m] $m}; set r", "1 {missing close-bracket} 1 {missing close-bracket}" },
    });
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    // A text that comes again at a new address has one script.
    _ = try it.eval("proc t {} {eval {set y 0} {;for {set i 0} {$i < 3} {incr i} {incr y}}; return $y}; t; t");
    var n: usize = 0;
    for (it.text_cache) |e| if (e.script != null) {
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), n);
    // The count and the bytes stay in their bounds.
    _ = try it.eval("for {set i 0} {$i < 200} {incr i} {eval set z$i [string repeat x 4000]}");
    try std.testing.expect(it.text_cache_used <= 256 << 10);
    try it.compact(&.{}, .{});
    try std.testing.expectEqual(@as(usize, 0), it.text_cache_used);
    try std.testing.expectEqualStrings("3", try evalStr(&it, "t"));
    try it.reset();
    try std.testing.expectEqual(@as(usize, 0), it.text_cache_used);
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
    // A build with modules has the small `package` by default.
    try std.testing.expect((it.findCommand("package") == null) == (modules.table.len == 0));
    for ([_][]const u8{ "interp", "clock", "file", "open", "socket", "exec", "pid", "time", "timerate", "chan", "encoding", "source", "load", "cd", "pwd", "glob", "after", "vwait", "update", "fileevent", "fblocked", "tcl::Bgerror", "ztcl::open", "ztcl::notify", "ztcl::mac::keychain", "ztcl::mac::defaults", "ztcl::win::registry", "ztcl::win::credential", "ztcl::win::folder" }) |name| {
        try std.testing.expect(it.findCommand(name) == null);
    }
}

test "ztcl::vt keeps a terminal state with no capability" {
    if (modules.find("ztcl::vt") == null) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try std.testing.expectEqual(@as(u32, 0), it.capabilities);
    try std.testing.expectEqualStrings("vt0 {[2;7R} {hello {red 中}} {6 1} 2", try it.str(try it.eval(
        \\package require ztcl::vt
        \\set t [ztcl::vt new -size {10 3}]
        \\ztcl::vt dirty $t
        \\set r [ztcl::vt feed $t "hello\r\n\x1b\[1;31mred\x1b\[0m \u4e2d\x1b\[6n"]
        \\list $t [string range $r 1 end] [ztcl::vt rows $t 0 1] [ztcl::vt cursor $t] [llength [ztcl::vt dirty $t]]
    )));
    try std.testing.expectEqualStrings("{r 1 1 {} bold} {中 2 {} {} {}} {{} 0 {} {} {}}", try it.str(try it.eval(
        \\set row [lindex [ztcl::vt cells $t 1] 0]
        \\list [lindex $row 0] {*}[lrange $row 4 5]
    )));
    try std.testing.expectEqualStrings("1 {4 2} 1", try it.str(try it.eval(
        \\ztcl::vt feed $t "a\r\nb\r\nc\r\n"
        \\ztcl::vt resize $t 4 2
        \\list [expr {[ztcl::vt scrollback $t] > 0}] [ztcl::vt size $t] [dict get [ztcl::vt modes $t] cursor_visible]
    )));
    // The interpreter frees a terminal that the script did not delete.
    _ = try it.eval("ztcl::vt new");
    try std.testing.expectEqualStrings("can not find terminal \"vt0\"", try it.str(try it.eval("ztcl::vt delete vt0; catch {ztcl::vt size vt0} m; set m")));
}

test "a built-in module installs once and runs with the limits" {
    if (modules.find("ztcl::hello") == null) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try std.testing.expectEqualStrings("1.0 0.9 1 {hello, a}", try it.str(try it.eval(
        \\list [package require ztcl::hello] [package require hello] $::ztcl::hello::installs [hello a]
    )));
    // The full command sees the modules too.
    try it.allow(@backingInt(tcl.interp.Capability.package));
    try std.testing.expectEqualStrings("1.0 1", try it.str(try it.eval("list [package require ztcl::hello] $::ztcl::hello::installs")));
    // `package forget` hides a built-in name, as it does a script package.
    try std.testing.expectEqualStrings("0 1 1", try it.str(try it.eval("package forget ztcl::hello; list [expr {\"ztcl::hello\" in [package names]}] [expr {\"hello\" in [package names]}] [catch {package require ztcl::hello}]")));

    // The script of a module stops at the compute limit.
    var it2: tcl.Interp = undefined;
    try it2.init(std.testing.allocator);
    defer it2.deinit();
    it2.compute_limit = 3;
    try std.testing.expectError(error.TclError, it2.eval("package require ztcl::hello"));
    try std.testing.expect(it2.findCommand("ztcl::hello") == null);
}

test "a module that needs a capability gives an error" {
    if (modules.find("ztcl::hellonet") == null) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try std.testing.expectEqualStrings("1 {module \"ztcl::hellonet\" needs the capability socket} {ZT PACKAGE CAPABILITY socket}", try it.str(try it.eval(
        \\list [catch {package require ztcl::hellonet} m o] $m [dict get $o -errorcode]
    )));
    try it.allow(@backingInt(tcl.interp.Capability.interp));
    try std.testing.expectEqualStrings("{} 1.0", try it.str(try it.eval(
        \\package require ztcl::hello; interp create c; list [c eval {info commands ztcl::hello}] [c eval {package require ztcl::hello}]
    )));
}

test "ztcl::tls needs socket and channels" {
    if (modules.find("ztcl::tls") == null) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try std.testing.expectEqualStrings("1 {ZT PACKAGE CAPABILITY channels}", try it.str(try it.eval(
        \\list [catch {package require ztcl::tls} m o] [dict get $o -errorcode]
    )));
    try it.allow(@backingInt(tcl.interp.Capability.socket) | @backingInt(tcl.interp.Capability.channels));
    try std.testing.expectEqualStrings("0.1", try it.str(try it.eval("package require ztcl::tls")));
    // The default network policy allows loopback only.
    try std.testing.expectEqualStrings("1 {ZTCL NET DENIED}", try it.str(try it.eval(
        \\list [catch {ztcl::tls socket 192.0.2.1 443} m o] [dict get $o -errorcode]
    )));
    try std.testing.expectEqualStrings("1 {bad option \"-x\": must be -alpn, -cadata, -servername, or -verify}", try it.str(try it.eval(
        \\list [catch {ztcl::tls socket -x 1 127.0.0.1 443} m] $m
    )));
    try std.testing.expectEqualStrings("1 {-cadata has no certificate}", try it.str(try it.eval(
        \\list [catch {ztcl::tls socket -cadata junk 127.0.0.1 443} m] $m
    )));
}

/// A TCP server on loopback that reads the ClientHello, answers with
/// bytes that are not TLS, and closes.
const NotTls = struct {
    server: std.Io.net.Server,

    fn run(n: *NotTls) void {
        const io = std.testing.io;
        const s = n.server.accept(io) catch return;
        defer s.close(io);
        var buf: [512]u8 = undefined;
        var r = s.reader(io, &buf);
        _ = r.interface.peek(5) catch return;
        var wb: [64]u8 = undefined;
        var w = s.writer(io, &wb);
        w.interface.writeAll("HTTP/1.0 400 Bad Request\r\n\r\n") catch return;
        w.interface.flush() catch return;
    }
};

test "ztcl::tls socket closes the channel after a failed handshake" {
    if (modules.find("ztcl::tls") == null) return error.SkipZigTest;
    const io = std.testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var n: NotTls = .{ .server = try addr.listen(io, .{}) };
    defer n.server.deinit(io);
    const th = try std.Thread.spawn(.{}, NotTls.run, .{&n});
    defer th.join();
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.socket) | @backingInt(tcl.interp.Capability.channels));
    const script = try std.fmt.allocPrint(std.testing.allocator,
        \\package require ztcl::tls
        \\list [catch {{ztcl::tls socket -verify 0 127.0.0.1 {d}}} m o] [lrange [dict get $o -errorcode] 0 1] [llength [lsearch -all [chan names] sock*]]
    , .{n.server.socket.address.getPort()});
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("1 {ZTCL TLS} 0", try it.str(try it.eval(script)));
}

test "package provides Tcl at the patch level" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.package));
    try std.testing.expectEqualStrings("1 1 1", try it.str(try it.eval(
        \\list [expr {[package require Tcl 8.6] eq $tcl_patchLevel}] [catch {package require Tcl 9}] [expr {"Tcl" in [package names]}]
    )));
}

test "interp cancel and the uncatchable unwind" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.interp));
    try std.testing.expectEqualStrings("1 {eval canceled} {TCL CANCEL ICANCEL {eval canceled}}", try it.str(try it.eval("list [catch {interp cancel; while 1 {}} m o] $m [dict get $o -errorcode]")));
    try std.testing.expectEqualStrings("0 {eval canceled}", try it.str(try it.eval("interp create c; list [catch {c eval {catch {interp cancel; while 1 {}} m; set m}} r] $r")));
    try std.testing.expectEqualStrings("1 {eval unwound} ok", try it.str(try it.eval("list [catch {c eval {interp cancel -unwind; catch {while 1 {}}; set y not}} r] $r [c eval {set z ok}]")));
    try std.testing.expectEqualStrings("1 {could not find interpreter \"nosuch\"}", try it.str(try it.eval("list [catch {interp cancel nosuch} r] $r")));
    // An embedder call from another thread, as `cancelEval` allows. A
    // cancel that comes before the script starts stops it at its first
    // check point, so the test does not catch the error in the script.
    const S = struct {
        fn run(x: *tcl.Interp) void {
            x.cancelEval(false, "from a thread") catch {};
        }
    };
    const th = try std.Thread.spawn(.{}, S.run, .{&it});
    const r = it.eval("while 1 {}");
    th.join();
    try std.testing.expectError(error.TclError, r);
    try std.testing.expectEqualStrings("from a thread", try it.str(it.result));
    // A message longer than `cancel_max` stops at the end of the buffer.
    const long: [tcl.Interp.cancel_max + 10]u8 = @splat('x');
    try it.cancelEval(false, &long);
    try std.testing.expectError(error.TclError, it.eval("while 1 {}"));
    try std.testing.expectEqual(@as(usize, tcl.Interp.cancel_max), (try it.str(it.result)).len);
}

test "a child has no more capabilities than its parent" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.interp));
    // The child has no full `package`: `ifneeded` needs the capability.
    try std.testing.expectEqualStrings("1 0", try it.str(try it.eval("interp create c; list [c eval {catch {package ifneeded a 1 {}}}] [interp issafe c]")));
    try std.testing.expectEqualStrings("interp", try it.str(try it.eval("c eval {info commands interp}")));
    try std.testing.expectEqualStrings("{}", try it.str(try it.eval("interp create -safe s; list [s eval {info commands interp}]")));
    try std.testing.expectEqualStrings("7", try it.str(try it.eval("interp alias c dbl {} expr 3+; c eval {dbl 4}")));
    _ = try it.eval("interp delete c");
}

test "a child that deletes itself through an alias stays safe" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.interp));
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
    try it.allow(@backingInt(tcl.interp.Capability.clock));
    _ = it.eval("clock seconds") catch {};
    try std.testing.expectEqualStrings("the embedder gave no clock", try it.str(it.result));
    it.clock_host = .{ .now = fixedClock };
    try std.testing.expectEqualStrings("86400", try it.str(try it.eval("clock seconds")));
    try std.testing.expectEqualStrings("1970-01-02", try it.str(try it.eval("clock format [clock seconds] -format %Y-%m-%d -gmt 1")));
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("catch {clock format 0 -timezone :../../etc/passwd}")));
}

test "file and channels cannot leave the root folder" {
    if (!tcl.fsroot.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const linux = tcl.sys.os;
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
    const rc = if (@import("builtin").os.tag == .macos)
        linux.openat(base, "root", .{ .DIRECTORY = true, .CLOEXEC = true }, 0)
    else
        linux.openat(base, "root", .{ .DIRECTORY = true, .PATH = true, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    it.fs.fd = @intCast(rc);
    try it.allow(@backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.file));
    for ([_][]const u8{
        "open ../secret",           "open /../secret",     "open sub/../../secret",      "open out",                 "open sub/up/../secret",
        "open etc/passwd",          "open out w",          "source ../secret",           "source out",               "cd ..",
        "cd etc",                   "file size ../secret", "file delete ../secret",      "file mkdir ../made",       "file rename sub ../moved",
        "file copy ../secret here", "file copy out here",  "file link -symbolic x /etc", "file readlink out",
        // Case variants of a symlink name: on a file system that ignores
        // case (APFS), they name the same symlink.
               "open OUT",
        "open Sub/UP/../secret",    "source OUT",          "cd ETC",                     "file copy -force sub out",
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

test "the parent of a path refuses a last name that is not a plain entry" {
    if (!tcl.fsroot.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    for ([_][]const u8{ "", ".", "..", "sub/.", "sub/..", "sub/", "a\x00b", "sub/a\x00b" }) |rel| {
        switch (try tcl.fsroot.parentOf(&it, rel)) {
            .ok => return error.TestUnexpectedResult,
            .err => |e| try std.testing.expectEqual(tcl.sys.Errno.ACCES, e),
        }
    }
}

test "a folder swapped for a symlink during an open stays in the root" {
    if (!tcl.fsroot.supported or @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const linux = tcl.sys.os;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base: i32 = tmp.dir.handle;
    for ([_][*:0]const u8{ "root", "root/d", "root/keep", "outside" }) |d| {
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdirat(base, d, 0o777)));
    }
    for ([_][*:0]const u8{ "outside/f", "root/d/f" }) |f| {
        const rc = linux.openat(base, f, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o666);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        const text: []const u8 = if (f[0] == 'o') "hidden" else "inside";
        _ = linux.write(@intCast(rc), text.ptr, text.len);
        _ = linux.close(@intCast(rc));
    }
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("../outside", base, "root/link")));
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.fs.fd = @intCast(linux.openat(base, "root", .{ .DIRECTORY = true, .CLOEXEC = true }, 0));
    const Swap = struct {
        fn run(dir: i32, stop: *std.atomic.Value(bool)) void {
            while (!stop.load(.monotonic)) {
                _ = linux.renameat(dir, "root/d", dir, "root/keep/d");
                _ = linux.renameat(dir, "root/link", dir, "root/d");
                _ = linux.renameat(dir, "root/d", dir, "root/link");
                _ = linux.renameat(dir, "root/keep/d", dir, "root/d");
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const t = try std.Thread.spawn(.{}, Swap.run, .{ base, &stop });
    defer t.join();
    defer stop.store(true, .monotonic);
    var opened: usize = 0;
    for (0..20000) |_| {
        switch (try tcl.fsroot.openRel(&it, "d/f", .{}, 0)) {
            .fd => |fd| {
                var buf: [8]u8 = undefined;
                const n = linux.read(fd, &buf, buf.len);
                _ = linux.close(fd);
                try std.testing.expectEqualStrings("inside", buf[0..n]);
                opened += 1;
            },
            .err => {},
        }
    }
    try std.testing.expect(opened > 0);
}

const WinFs = struct {
    const H = ?*anyopaque;
    extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn RemoveDirectoryW(name: [*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: H) callconv(.winapi) H;
    extern "kernel32" fn CloseHandle(h: H) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(h: H, buf: [*]const u8, n: u32, put: *u32, over: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn ReadFile(h: H, buf: [*]u8, n: u32, got: *u32, over: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn DeviceIoControl(h: H, code: u32, in: ?*const anyopaque, in_len: u32, out: ?*anyopaque, out_len: u32, got: *u32, over: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetFullPathNameW(name: [*:0]const u16, size: u32, buf: [*]u16, file: ?*?[*]u16) callconv(.winapi) u32;
    extern "kernel32" fn GetShortPathNameW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    const bad: H = @ptrFromInt(~@as(usize, 0));

    fn w(a: std.mem.Allocator, text: []const u8) ![:0]u16 {
        return std.unicode.utf8ToUtf16LeAllocZ(a, text);
    }

    fn writeNew(a: std.mem.Allocator, path: []const u8, text: []const u8) !void {
        const h = CreateFileW((try w(a, path)).ptr, 0x4000_0000, 0, null, 2, 0x80, null);
        if (h == bad) return error.TestUnexpectedResult;
        defer _ = CloseHandle(h);
        var put: u32 = 0;
        if (WriteFile(h, text.ptr, @intCast(text.len), &put, null) == 0) return error.TestUnexpectedResult;
    }

    fn readAll(a: std.mem.Allocator, path: []const u8, buf: []u8) ![]u8 {
        const h = CreateFileW((try w(a, path)).ptr, 0x8000_0000, 7, null, 3, 0x80, null);
        if (h == bad) return error.TestUnexpectedResult;
        defer _ = CloseHandle(h);
        var got: u32 = 0;
        if (ReadFile(h, buf.ptr, @intCast(buf.len), &got, null) == 0) return error.TestUnexpectedResult;
        return buf[0..got];
    }

    /// A junction at `link` to the absolute folder `target`. It needs no
    /// privilege.
    fn junction(a: std.mem.Allocator, link: []const u8, target: []const u8) !void {
        const wl = try w(a, link);
        if (CreateDirectoryW(wl.ptr, null) == 0) return error.TestUnexpectedResult;
        // GENERIC_WRITE, with BACKUP_SEMANTICS and OPEN_REPARSE_POINT.
        const h = CreateFileW(wl.ptr, 0x4000_0000, 0, null, 3, 0x0200_0000 | 0x0020_0000, null);
        if (h == bad) return error.TestUnexpectedResult;
        defer _ = CloseHandle(h);
        const sub = try w(a, try std.fmt.allocPrint(a, "\\??\\{s}", .{target}));
        const sub_bytes: u16 = @intCast(sub.len * 2);
        var data: [2048]u8 align(4) = @splat(0);
        std.mem.writeInt(u32, data[0..4], 0xA000_0003, .little);
        std.mem.writeInt(u16, data[4..6], 8 + sub_bytes + 2 + 2, .little);
        std.mem.writeInt(u16, data[8..10], 0, .little);
        std.mem.writeInt(u16, data[10..12], sub_bytes, .little);
        std.mem.writeInt(u16, data[12..14], sub_bytes + 2, .little);
        std.mem.writeInt(u16, data[14..16], 0, .little);
        @memcpy(data[16..][0..sub_bytes], std.mem.sliceAsBytes(sub));
        var got: u32 = 0;
        if (DeviceIoControl(h, 0x0009_00A4, &data, 8 + 8 + @as(u32, sub_bytes) + 4, null, 0, &got, null) == 0) return error.TestUnexpectedResult;
    }
};

test "the Windows jail gives an error for each escape" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows or !tcl.fsroot.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = WinFs.CreateDirectoryW((try WinFs.w(a, ".zig-cache\\tmp")).ptr, null);
    var full: [1024]u16 = undefined;
    const name = try std.fmt.allocPrint(a, ".zig-cache\\tmp\\ztcl-jail-{d}-{d}", .{ WinFs.GetCurrentProcessId(), WinFs.GetTickCount64() });
    const n = WinFs.GetFullPathNameW((try WinFs.w(a, name)).ptr, full.len, &full, null);
    try std.testing.expect(n > 0 and n < full.len);
    const base = try std.unicode.utf16LeToUtf8Alloc(a, full[0..n]);
    const at = struct {
        fn p(x: std.mem.Allocator, dir: []const u8, rest: []const u8) ![]const u8 {
            return std.fmt.allocPrint(x, "{s}\\{s}", .{ dir, rest });
        }
    }.p;
    const root = try at(a, base, "root");
    try std.testing.expect(WinFs.CreateDirectoryW((try WinFs.w(a, base)).ptr, null) != 0);
    try std.testing.expect(WinFs.CreateDirectoryW((try WinFs.w(a, root)).ptr, null) != 0);
    try std.testing.expect(WinFs.CreateDirectoryW((try WinFs.w(a, try at(a, root, "sub"))).ptr, null) != 0);
    try WinFs.writeNew(a, try at(a, base, "secret"), "hidden");
    const long_name = try at(a, root, "longfilename-for-short.txt");
    try WinFs.writeNew(a, long_name, "long");
    // `out` and `sub\up` lead to a folder of this test. `win` is the real
    // Windows folder, so only the scripts that read go through it.
    try WinFs.junction(a, try at(a, root, "out"), base);
    try WinFs.junction(a, try at(a, root, "sub\\up"), base);
    try WinFs.junction(a, try at(a, root, "win"), "C:\\Windows");
    defer {
        _ = WinFs.RemoveDirectoryW((WinFs.w(a, at(a, root, "out") catch "") catch unreachable).ptr);
        _ = WinFs.RemoveDirectoryW((WinFs.w(a, at(a, root, "sub\\up") catch "") catch unreachable).ptr);
        _ = WinFs.RemoveDirectoryW((WinFs.w(a, at(a, root, "win") catch "") catch unreachable).ptr);
    }
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try tcl.fsroot.setRoot(&it, root);
    try it.allow(@backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.file) | @backingInt(tcl.interp.Capability.interp));
    var scripts: std.ArrayList([]const u8) = .empty;
    try scripts.appendSlice(a, &.{
        "open ../secret",                   "open /../secret",           "open sub/../../secret",         "open out",
        "open out/secret",                  "open sub/up/secret",        "open out/secret w",             "open out/new w",
        "open win/win.ini",                 "open win/system.ini",       "source ../secret",              "source out/secret",
        "source win/win.ini",               "cd ..",                     "cd out",                        "cd win",
        "file size ../secret",              "file size out/secret",      "file size win/win.ini",         "file delete ../secret",
        "file delete out/secret",           "file delete -force out",    "file mkdir ../made",            "file mkdir out/made",
        "file rename sub ../moved",         "file rename sub out/moved", "file copy ../secret here",      "file copy out/secret here",
        "file link -symbolic x C:/Windows", "file readlink out",         "glob -directory out *",         "open {plain.txt::$DATA} w",
        "open {plain.txt:hid} w",           "open {..\\..\\x}",          "open {..\\secret}",             "open C:x",
        "open {C:\\Windows\\win.ini}",      "open {\\\\?\\C:\\x}",       "open {\\\\.\\C:}",              "open {\\\\localhost\\c$\\x}",
        "open PROGRA~1",                    "open nul",                  "open NUL.txt",                  "open con w",
        "open {COM1.log} w",                "open {LPT9} w",             "open {AUX .txt} w",             "open {trailing.} w",
        "open {trailing } w",               "open {a*b} w",              "open {a?b} w",                  "open OUT/secret",
        "open Sub/UP/secret",               "open WIN/win.ini",          "cd OUT",                        "glob -directory Win *",
        "file delete -force OUT",           "file copy -force sub out",  "file mkdir OUT/made",           "open {COM\u{b9}} w",
        "open {conin$}",                    "open {CONOUT$.txt} w",      "open {out::$INDEX_ALLOCATION}",
    });
    for ([_][]const u8{ "$MFT", "$MFTMirr", "$LogFile", "$Volume", "$AttrDef", "$Bitmap", "$Boot", "$BadClus", "$Secure", "$UpCase", "$Extend" }) |meta| {
        const low = try std.ascii.allocLowerString(a, meta);
        try scripts.append(a, try std.fmt.allocPrint(a, "open {{{s}}}", .{meta}));
        try scripts.append(a, try std.fmt.allocPrint(a, "open {{{s}}} w", .{low}));
        try scripts.append(a, try std.fmt.allocPrint(a, "file size {{{s}}}", .{meta}));
        try scripts.append(a, try std.fmt.allocPrint(a, "file delete {{{s}}}", .{low}));
        try scripts.append(a, try std.fmt.allocPrint(a, "open {{{s}/x}}", .{meta}));
    }
    // The 8.3 name of the long file, on a volume that makes one.
    var short: [1024]u16 = undefined;
    const sn = WinFs.GetShortPathNameW((try WinFs.w(a, long_name)).ptr, &short, short.len);
    if (sn > 0 and sn < short.len) {
        const text = try std.unicode.utf16LeToUtf8Alloc(a, short[0..sn]);
        const leaf = text[(std.mem.lastIndexOfScalar(u8, text, '\\') orelse 0) + 1 ..];
        if (std.mem.indexOfScalar(u8, leaf, '~') != null) try scripts.append(a, try std.fmt.allocPrint(a, "open {s}", .{leaf}));
    }
    for (scripts.items) |script| {
        if (it.eval(script)) |_| {
            std.debug.print("escaped: {s}\n", .{script});
            return error.TestUnexpectedResult;
        } else |e| try std.testing.expectEqual(error.TclError, e);
    }
    // The file outside still has its text, and no new name exists there.
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hidden", try WinFs.readAll(a, try at(a, base, "secret"), &buf));
    for ([_][]const u8{ "made", "moved", "new" }) |gone| {
        try std.testing.expectEqual(~@as(u32, 0), WinFs.GetFileAttributesW((try WinFs.w(a, try at(a, base, gone))).ptr));
    }
    // The junctions are still there.
    try std.testing.expect(WinFs.GetFileAttributesW((try WinFs.w(a, try at(a, root, "win"))).ptr) & 0x400 != 0);
    try std.testing.expect(WinFs.GetFileAttributesW((try WinFs.w(a, try at(a, root, "out"))).ptr) & 0x400 != 0);
    // Work inside the root still runs.
    for ([_][2][]const u8{
        .{ "set f [open sub/a.txt w]; puts $f ok; close $f; set f [open sub/a.txt]; set x [gets $f]; close $f; set x", "ok" },
        .{ "set f [open sub/a.txt a]; puts $f more; close $f; file size sub/a.txt", "8" },
        .{ "set f [open sub/a.txt r+]; seek $f 3; set x [gets $f]; close $f; set x", "more" },
        .{ "set f [open sub/a.txt w]; close $f; file size sub/a.txt", "0" },
        .{ "file rename sub/a.txt sub/b.txt; list [file exists sub/a.txt] [file exists sub/b.txt]", "0 1" },
        .{ "file copy sub/b.txt sub/c.txt; file isfile sub/c.txt", "1" },
        .{ "file mkdir sub/d/e; file isdirectory sub/d/e", "1" },
        .{ "lsort [glob -directory sub -tails *]", "b.txt c.txt d up" },
        .{ "file type out", "link" },
        .{ "file delete -force sub/d sub/b.txt sub/c.txt; file exists sub/d", "0" },
        .{ "set f [open a~1.txt w]; close $f; set x [file exists a~1.txt]; file delete a~1.txt; set x", "1" },
        .{ "file mkdir sub/k; cd sub/k; set f [open here w]; close $f; cd /; set x [file exists sub/k/here]; file delete -force sub/k; set x", "1" },
    }) |case| {
        try std.testing.expectEqualStrings(case[1], try it.str(try it.eval(case[0])));
    }
    // As with `unlinkat`, a delete must match the kind of the object.
    _ = try it.eval("file mkdir sub/kind; set f [open sub/plain w]; close $f");
    const folder = (try tcl.fsroot.parentOf(&it, "sub/kind")).ok;
    defer tcl.sys.close(folder.fd);
    try std.testing.expectEqual(tcl.sys.Errno.ISDIR, tcl.fsroot.removeAt(folder, false).?);
    const plain = (try tcl.fsroot.parentOf(&it, "sub/plain")).ok;
    defer tcl.sys.close(plain.fd);
    try std.testing.expectEqual(tcl.sys.Errno.NOTDIR, tcl.fsroot.removeAt(plain, true).?);
    try std.testing.expectEqualStrings("1 1", try it.str(try it.eval("list [file isdirectory sub/kind] [file isfile sub/plain]")));
    try std.testing.expect(tcl.fsroot.removeAt(folder, true) == null);
    try std.testing.expect(tcl.fsroot.removeAt(plain, false) == null);
    try std.testing.expectEqualStrings("0 0", try it.str(try it.eval("list [file exists sub/kind] [file exists sub/plain]")));
    // A name that only starts like a metafile is a plain name.
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("set f [open {$MFT.txt} w]; close $f; set x [file exists {$MFT.txt}]; file delete {$MFT.txt}; set x")));
    // A child interpreter has the same jail.
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("interp create kid; set x [kid eval {catch {open ../secret}}]; interp delete kid; set x")));
    // The test files go away. The junctions go first, so no delete walks them.
    _ = WinFs.RemoveDirectoryW((try WinFs.w(a, try at(a, root, "out"))).ptr);
    _ = WinFs.RemoveDirectoryW((try WinFs.w(a, try at(a, root, "sub\\up"))).ptr);
    _ = WinFs.RemoveDirectoryW((try WinFs.w(a, try at(a, root, "win"))).ptr);
    _ = WinFs.DeleteFileW((try WinFs.w(a, long_name)).ptr);
    _ = WinFs.RemoveDirectoryW((try WinFs.w(a, try at(a, root, "sub"))).ptr);
    _ = WinFs.DeleteFileW((try WinFs.w(a, try at(a, base, "secret"))).ptr);
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
    try it.allow(@backingInt(cap.event) | @backingInt(cap.interp));
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
    if (!tcl.sys.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const cap = tcl.interp.Capability;
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.event) | @backingInt(cap.socket));
    fake_ticks = 0;
    it.event_host = .{ .now = fakeNow, .sleep = fakeSleep };
    for ([_][]const u8{
        "socket example.com 80",         "socket 192.0.2.1 80",                   "socket 10.0.0.1 80",
        "socket 0.0.0.0 80",             "socket ::ffff:192.0.2.1 80",            "socket -server x -myaddr 0.0.0.0 0",
        "socket -server x -myaddr :: 0", "socket -myaddr 192.0.2.1 localhost 80", "socket 127.0.0.1.example.com 80",
    }) |script| {
        if (it.eval(script)) |_| {
            std.debug.print("opened: {s}\n", .{script});
            return error.TestUnexpectedResult;
        } else |e| try std.testing.expectEqual(error.TclError, e);
    }
    const script =
        \\proc accept {s a p} {set ::peer $a; fileevent $s readable [list echo $s]}
        \\proc echo {s} {if {[gets $s line] < 0} {close $s; set ::ended 1; return}; puts $s "got $line"; flush $s}
        \\set srv [socket -server accept 0]
        \\set c [socket 127.0.0.1 [lindex [fconfigure $srv -sockname] 2]]
        \\puts $c hello; flush $c
        \\fileevent $c readable {set reply [gets $c]}
        \\vwait reply
        \\close $c; vwait ended; close $srv
        \\list $peer $reply [lindex [chan names] end]
    ;
    try std.testing.expectEqualStrings("127.0.0.1 {got hello} stdout", try it.str(try it.eval(script)));
}

test "exec has an allowlist and a time limit, and leaves no process" {
    if (!tcl.proc.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const linux = tcl.sys.os;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const cap = tcl.interp.Capability;
    // `file` and channels do not turn on `exec`.
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.file) | @backingInt(cap.interp));
    try std.testing.expect(it.findCommand("exec") == null);
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("catch {open |echo}")));
    try std.testing.expectEqualStrings("{}", try it.str(try it.eval("interp create c; list [c eval {info commands exec}]")));
    try it.allow(@backingInt(cap.exec));
    it.exec_host = .{ .allow = &.{ "echo", if (@import("builtin").os.tag == .macos) "/bin/cat" else "/usr/bin/cat", "sleep", "sh" }, .timeout_ms = 300, .env = &.{"PATH=/usr/bin:/bin"} };
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
    try std.testing.expectEqualStrings("PATH=/usr/bin:/bin", try it.str(try it.eval("exec sh -c {export -p | cut -d' ' -f2- | tr -d \\\"\\' | grep -v -e PWD -e OLDPWD -e SHLVL -e '^_=' ; true}")));
    // The time limit ends the program and each process that it made.
    const before = linux.getpid();
    _ = before;
    try std.testing.expectEqualStrings("1 {child killed: the time limit of 300 ms ended}", try it.str(try it.eval("list [catch {exec sh -c {sleep 60 & echo $! > /dev/null; wait}} m] $m")));
    // A background process ends with the interpreter.
    const pid_text = try it.str(try it.eval("exec sleep 60 &"));
    const pid = try std.fmt.parseInt(i32, pid_text, 10);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.kill(pid, @fromBackingInt(@intCast(0)))));
    const pipe_pid = try std.fmt.parseInt(i32, try it.str(try it.eval("set f [open {|sleep 60} r]; pid $f")), 10);
    it.deinit();
    try std.testing.expectEqual(linux.E.SRCH, linux.errno(linux.kill(pid, @fromBackingInt(@intCast(0)))));
    try std.testing.expectEqual(linux.E.SRCH, linux.errno(linux.kill(pipe_pid, @fromBackingInt(@intCast(0)))));
    try it.init(std.testing.allocator);
}

/// The temporary folder of the tests. On macOS /tmp is a symlink, and
/// the root folder of a jail must be a path with no symlink.
const tmp_base = if (@import("builtin").os.tag == .macos) "/private/tmp" else "/tmp";

/// Makes a fresh folder in /tmp for a test. The caller removes it.
fn tmpFolder(buf: *[64:0]u8, what: []const u8) ![:0]const u8 {
    const linux = tcl.sys.os;
    const z = try std.fmt.bufPrintSentinel(buf, "{s}/ztcl-{s}-{d}", .{ tmp_base, what, linux.getpid() }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdirat(linux.AT.FDCWD, z, 0o700)));
    return z;
}

/// Removes a test folder with `rm -rf`, from the host.
fn removeFolder(path: []const u8) void {
    var it: tcl.Interp = undefined;
    it.init(std.testing.allocator) catch return;
    defer it.deinit();
    it.allow(@backingInt(tcl.interp.Capability.exec)) catch return;
    it.exec_host = .{ .allow = &.{"rm"}, .timeout_ms = 5000, .env = &.{"PATH=/usr/bin:/bin"} };
    const script = std.fmt.allocPrint(it.alloc(), "exec rm -rf -- {{{s}}}", .{path}) catch return;
    _ = it.eval(script) catch {};
}

fn execJail(it: *tcl.Interp, root: []const u8) !void {
    try it.init(std.testing.allocator);
    errdefer it.deinit();
    try tcl.fsroot.setRoot(it, root);
    const cap = tcl.interp.Capability;
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.file) | @backingInt(cap.exec));
}

test "the exec allowlist checks the file that runs" {
    if (!tcl.proc.supported or !tcl.fsroot.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var name: [64:0]u8 = undefined;
    const root = try tmpFolder(&name, "allow");
    defer removeFolder(root);
    var it: tcl.Interp = undefined;
    try execJail(&it, root);
    defer it.deinit();
    it.exec_host = .{ .allow = &.{"/bin/echo"}, .timeout_ms = 2000, .env = &.{"PATH=/usr/bin:/bin"} };
    // The script writes a program at the path of the allowed program.
    _ = try it.eval("file mkdir /bin; set f [open /bin/echo {WRONLY CREAT} 0755]; puts $f {#!/bin/sh}; puts $f {printf planted}; close $f");
    // The word is a host path, so the host program runs.
    try std.testing.expectEqualStrings("real", try it.str(try it.eval("exec /bin/echo real")));
    // A relative word names no host file.
    try std.testing.expectEqualStrings("1 {couldn't execute \"bin/echo\": a program path must be a full path or a bare name}", try it.str(try it.eval("list [catch {exec bin/echo} m] $m")));
    // A bare name that the PATH of the embedder finds in the root folder
    // does not run, also with an allowlist that names it.
    const pa = try std.fmt.allocPrintSentinel(it.alloc(), "PATH={s}/bin:/usr/bin", .{root}, 0);
    it.exec_host = .{ .allow = &.{ "echo", "/bin/echo" }, .timeout_ms = 2000, .env = &.{pa} };
    try std.testing.expectEqualStrings("1 {couldn't execute \"echo\": the program is in the root folder} {ZTCL EXEC DENIED}", try it.str(try it.eval("list [catch {exec echo x} m] $m $::errorCode")));
    it.exec_host.allow = null;
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("catch {exec echo x}")));
    try std.testing.expectEqualStrings("1", try it.str(try it.eval(try std.fmt.allocPrint(it.alloc(), "catch {{exec {s}/bin/echo x}}", .{root}))));
    // `allow_root` lists a file below the root, and the script runs it.
    it.exec_host = .{ .allow = &.{}, .allow_root = &.{"/bin/echo"}, .timeout_ms = 2000, .env = &.{"PATH=/usr/bin:/bin"} };
    try std.testing.expectEqualStrings("planted", try it.str(try it.eval("exec /bin/echo")));
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("catch {exec /bin/sh -c {printf x}}")));
}

test "exec refuses a relative PATH entry" {
    if (!tcl.proc.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.exec));
    for ([_][:0]const u8{ "PATH=bin:/usr/bin:/bin", "PATH=/usr/bin::/bin", "PATH=/usr/bin:/bin:", "PATH=./bin:/usr/bin" }) |pa| {
        it.exec_host = .{ .allow = &.{"true"}, .timeout_ms = 2000, .env = &.{pa} };
        try std.testing.expectEqualStrings("1 {ZTCL EXEC PATH}", try it.str(try it.eval("list [catch {exec true}] $::errorCode")));
    }
    it.exec_host = .{ .allow = &.{"true"}, .timeout_ms = 2000, .env = &.{"PATH=/usr/bin:/bin"} };
    try std.testing.expectEqualStrings("0", try it.str(try it.eval("catch {exec true}")));
}

test "exec follows symlinks in the root folder to the host file" {
    if (!tcl.proc.supported or !tcl.fsroot.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const linux = tcl.sys.os;
    var name: [64:0]u8 = undefined;
    const root = try tmpFolder(&name, "links");
    defer removeFolder(root);
    var it: tcl.Interp = undefined;
    try execJail(&it, root);
    defer it.deinit();
    const a = it.alloc();
    // The embedder makes the links. A script cannot make a link.
    _ = try it.eval("file mkdir /bin; set f [open /planted {WRONLY CREAT} 0755]; puts $f {#!/bin/sh}; puts $f {printf planted}; close $f");
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("/bin/echo", linux.AT.FDCWD, try std.fmt.allocPrintSentinel(a, "{s}/bin/echo", .{root}, 0))));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("../planted", linux.AT.FDCWD, try std.fmt.allocPrintSentinel(a, "{s}/bin/inside", .{root}, 0))));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat(try std.fmt.allocPrintSentinel(a, "{s}/planted", .{root}, 0), linux.AT.FDCWD, try std.fmt.allocPrintSentinel(a, "{s}/bin/full", .{root}, 0))));
    const pa = try std.fmt.allocPrintSentinel(a, "PATH={s}/bin:/usr/bin:/bin", .{root}, 0);
    it.exec_host = .{ .allow = &.{ "echo", "inside", "full", "/bin/echo" }, .timeout_ms = 2000, .env = &.{pa} };
    // A link to an allowed host program runs that host program.
    try std.testing.expectEqualStrings("hi", try it.str(try it.eval("exec echo hi")));
    // A link to a file below the root does not run.
    try std.testing.expectEqualStrings("1 {couldn't execute \"inside\": the program is in the root folder}", try it.str(try it.eval("list [catch {exec inside} m] $m")));
    try std.testing.expectEqualStrings("1 {couldn't execute \"full\": the program is in the root folder}", try it.str(try it.eval("list [catch {exec full} m] $m")));
    try std.testing.expectEqualStrings("x", try it.str(try it.eval(try std.fmt.allocPrint(a, "exec {s}/bin/echo x", .{root}))));
    // A script word is a host path: the link /bin/echo of the root is
    // not read.
    try std.testing.expectEqualStrings("x", try it.str(try it.eval("exec /bin/echo x")));
    // The script replaces the link with its own file. It does not run.
    _ = try it.eval("file delete /bin/echo; set f [open /bin/echo {WRONLY CREAT} 0755]; puts $f {#!/bin/sh}; close $f");
    try std.testing.expectEqualStrings("1 {couldn't execute \"echo\": the program is in the root folder}", try it.str(try it.eval("list [catch {exec echo} m] $m")));
}

/// Gives true when a process with this pid ended within one second.
fn processEnds(pid: i32) bool {
    const linux = tcl.sys.os;
    var n: usize = 0;
    while (n < 100) : (n += 1) {
        if (linux.errno(linux.kill(pid, @fromBackingInt(@intCast(0)))) == .SRCH) return true;
        // A poll of no descriptor waits 10 ms.
        _ = linux.poll(@ptrFromInt(8), 0, 10);
    }
    _ = linux.kill(pid, linux.SIG.KILL);
    return false;
}

/// Runs a script that starts a process that leaves the process group,
/// and checks that the time limit kills it. The process writes its pid
/// to a file of the root folder.
fn escapeKilled(script: []const u8) !void {
    var name: [64:0]u8 = undefined;
    const root = try tmpFolder(&name, "tree");
    defer removeFolder(root);
    var it: tcl.Interp = undefined;
    try execJail(&it, root);
    defer it.deinit();
    it.exec_host = .{ .allow = &.{ "sh", "setsid", "sleep", "perl" }, .timeout_ms = 300, .env = &.{"PATH=/usr/bin:/bin"} };
    try std.testing.expectEqualStrings("1 {child killed: the time limit of 300 ms ended}", try it.str(try it.eval(script)));
    const text = try it.str(try it.eval("set f [open /pid]; set p [string trim [read $f]]; close $f; set p"));
    try std.testing.expect(processEnds(try std.fmt.parseInt(i32, text, 10)));
}

test "the time limit of exec kills a process that calls setsid" {
    if (!tcl.proc.supported or !tcl.fsroot.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    // macOS has no setsid program: perl calls setsid there.
    const setsid = if (@import("builtin").os.tag == .macos)
        "list [catch {exec sh -c {perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' sh -c 'echo $$ > pid; exec sleep 47' > /dev/null 2>&1 < /dev/null & sleep 5}} m] $m"
    else
        "list [catch {exec sh -c {setsid sh -c 'echo $$ > pid; exec sleep 47' > /dev/null 2>&1 < /dev/null & sleep 5}} m] $m";
    // With no cgroup, the scan finds the process below the shell.
    tcl.proc.test_no_cgroup = true;
    defer tcl.proc.test_no_cgroup = false;
    try escapeKilled(setsid);
    tcl.proc.test_no_cgroup = false;
    if (!tcl.proc.treeAvailable()) return error.SkipZigTest;
    try escapeKilled(setsid);
    // A double fork: the parent of the process ends at once. Only the
    // cgroup finds the process.
    try escapeKilled("list [catch {exec sh -c {(setsid sh -c 'echo $$ > pid; exec sleep 48' > /dev/null 2>&1 < /dev/null &); sleep 5}} m] $m");
}

/// Makes a fresh folder in /tmp for a test, and an interpreter with
/// `file` in it.
fn fileJail(it: *tcl.Interp, buf: *[64:0]u8, what: []const u8) ![:0]const u8 {
    const linux = tcl.sys.os;
    const root = try std.fmt.bufPrintSentinel(buf, "{s}/ztcl-{s}-{d}", .{ tmp_base, what, linux.getpid() }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdirat(linux.AT.FDCWD, root, 0o700)));
    try it.init(std.testing.allocator);
    try tcl.fsroot.setRoot(it, root);
    const cap = tcl.interp.Capability;
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.file));
    return root;
}

/// Deletes the tree of a test and its root folder.
fn fileJailEnd(it: *tcl.Interp, root: [:0]const u8) void {
    const linux = tcl.sys.os;
    it.compute_limit = std.math.maxInt(u64);
    _ = it.eval("foreach f [glob -nocomplain /*] {file delete -force $f}") catch {};
    it.deinit();
    _ = linux.unlinkat(linux.AT.FDCWD, root, linux.AT.REMOVEDIR);
}

test "a delete of a deep tree in a coroutine gives an error and no crash" {
    if (!tcl.coro.supported or !tcl.fsroot.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var name: [64:0]u8 = undefined;
    var it: tcl.Interp = undefined;
    const root = try fileJail(&it, &name, "deep");
    defer fileJailEnd(&it, root);
    _ = try it.eval("file mkdir /[string repeat d/ 2040]");
    // Before the walk on the heap, a ReleaseSafe build on x86-64 Linux
    // ended with SIGSEGV here: the recursion overflowed the coroutine
    // stack.
    it.compute_limit = 1000;
    const got = it.eval("coroutine c apply {{} {file delete -force /d}}");
    if (got) |_| {} else |_| try std.testing.expectEqualStrings("compute limit reached", try it.str(it.result));
    it.compute_limit = std.math.maxInt(u64);
    _ = try it.eval("coroutine c2 apply {{} {file delete -force /d}}");
    try std.testing.expectEqualStrings("0", try it.str(try it.eval("file exists /d")));
}

test "a copy of a folder into itself gives an error at once" {
    if (!tcl.fsroot.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var name: [64:0]u8 = undefined;
    var it: tcl.Interp = undefined;
    const root = try fileJail(&it, &name, "self");
    defer fileJailEnd(&it, root);
    _ = try it.eval("file mkdir /d/e; close [open /d/e/f w]");
    it.compute_limit = 100000;
    for ([_][]const u8{ "file copy /d /d/x", "file copy /d /d/e/x", "file copy -force /d /d", "file copy /d/./e/.. /d/e/x", "cd /d/e; file copy /d x" }) |script| {
        try std.testing.expectError(error.TclError, it.eval(script));
        try std.testing.expect(std.mem.endsWith(u8, try it.str(it.result), "trying to copy a directory into itself"));
        try std.testing.expectEqualStrings("POSIX EINVAL {invalid argument}", try it.str(try it.eval("set ::errorCode")));
    }
    _ = try it.eval("cd /");
    try std.testing.expectEqualStrings("/d/e /d/e/f", try it.str(try it.eval("lsort [concat [glob /d/*] [glob /d/*/*]]")));
}

test "file copy and file delete still work on a deep tree" {
    if (!tcl.fsroot.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var name: [64:0]u8 = undefined;
    var it: tcl.Interp = undefined;
    const root = try fileJail(&it, &name, "tree");
    defer fileJailEnd(&it, root);
    const script =
        \\set p /a
        \\for {set i 0} {$i < 300} {incr i} {
        \\    append p /n$i
        \\    file mkdir $p
        \\    set f [open $p/f w]; puts -nonewline $f $i; close $f
        \\}
        \\file mkdir /a/n0/empty
        \\file copy /a /b
        \\set f [open [string map {/a/ /b/} $p]/f]; set x [read $f]; close $f
        \\set r [list $x [llength [glob /b/n0/*]]]
        \\file copy -force /a /b
        \\lappend r [file exists /b/a/n0/empty]
        \\file delete -force /a /b
        \\lappend r [glob -nocomplain /*]
    ;
    try std.testing.expectEqualStrings("299 3 1 {}", try it.str(try it.eval(script)));
    try std.testing.expectEqualStrings("1 {error deleting \"/c\": directory not empty}", try it.str(try it.eval("file mkdir /c/d; list [catch {file delete /c} m] $m")));
}

test "the tree walk has a depth limit" {
    if (!tcl.fsroot.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var name: [64:0]u8 = undefined;
    var it: tcl.Interp = undefined;
    const root = try fileJail(&it, &name, "depth");
    defer fileJailEnd(&it, root);
    const keep = tcl.filecmd.tree_depth_limit;
    tcl.filecmd.tree_depth_limit = 50;
    defer tcl.filecmd.tree_depth_limit = keep;
    _ = try it.eval("file mkdir /[string repeat d/ 60]");
    try std.testing.expectEqualStrings("1 {error deleting \"/d\": the tree is deeper than 50 levels} {ZTCL TREE DEPTH}", try it.str(try it.eval("list [catch {file delete -force /d} m] $m $::errorCode")));
    try std.testing.expectEqualStrings("1 {error copying \"/d\": the tree is deeper than 50 levels}", try it.str(try it.eval("list [catch {file copy /d /e} m] $m")));
    tcl.filecmd.tree_depth_limit = keep;
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

test "TclOO: the caches of a call see each change" {
    try check(&.{
        // The cache of the declared variables belongs to one object.
        .{ "oo::class create A {variable v; constructor {x} {set v $x}; method get {} {return $v}}; set a [A new 1]; set b [A new 2]; list [$a get] [$b get] [$a get]", "1 2 1" },
        // `::oo::Link` outside a method links in the current namespace,
        // also while a method runs.
        .{ "oo::object create z; namespace eval s {variable q 11}; proc s::r {} {::oo::Link q; return $q}; s::r", "11" },
        .{ "namespace eval s {variable q 11}; proc s::r {} {::oo::Link q; return $q}; oo::class create A {variable q; constructor {} {set q mine}; method m {} {list $q [s::r] $q}}; [A new] m", "mine 11 mine" },
        // A method name word that changes between calls of one site.
        .{ "oo::class create A {method x {} {return x}; method y {} {return y}}; set o [A new]; set r {}; foreach m {x y x y} {lappend r [$o $m]}; set r", "x y x y" },
        // A new method of the same name after a call.
        .{ "oo::class create A {method m {} {return 1}}; set o [A new]; set r [$o m]; oo::define A method m {} {return 2}; lappend r [$o m]", "1 2" },
        // A name string that names another object after a rename.
        .{ "oo::class create A {method m {} {return a}}; oo::class create B {method m {} {return b}}; A create x; set n x; set r [$n m]; x destroy; B create x; lappend r [$n m]", "a b" },
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

test "Windows sockets keep the rules of sys.zig" {
    if (@import("builtin").os.tag != .windows or !tcl.sys.supported) return error.SkipZigTest;
    const sys = tcl.sys;
    const a = std.testing.allocator;
    const v4: sys.Addr = sys.parseAddr("127.0.0.1").?;
    const srv = sys.listenAt(v4, false).fd;
    defer sys.close(srv);
    try std.testing.expect(!sys.win.inheritable(srv));
    var to = sys.sockName(srv).?;
    to.bytes = v4.bytes;
    const client = sys.connectTo(to, null, true).fd;
    defer sys.close(client);
    try std.testing.expect(!sys.win.inheritable(client));
    var wants = [_]sys.Want{.{ .fd = srv, .read = true }};
    sys.poll(a, &wants, 5000);
    try std.testing.expect(wants[0].can_read);
    const got = sys.accept(srv).?;
    defer sys.close(got.fd);
    try std.testing.expect(!sys.win.inheritable(got.fd));
    try std.testing.expectEqual(sys.sockName(client).?.port, got.peer.port);
    try std.testing.expectEqual(to.port, sys.peerName(client).?.port);
    try std.testing.expectEqual(@as(usize, 2), sys.write(client, "hi").n);
    wants = .{.{ .fd = got.fd, .read = true }};
    sys.poll(a, &wants, 5000);
    try std.testing.expect(wants[0].can_read);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), sys.read(got.fd, &buf).n);
    try std.testing.expectEqualStrings("hi", buf[0..2]);
    // With no data, a socket that does not block gives `.again`.
    sys.setBlocking(got.fd, false);
    try std.testing.expect(sys.read(got.fd, &buf) == .again);
    sys.setBlocking(got.fd, true);
    try std.testing.expect(sys.seek(got.fd, 0, 0) == .err);
    // A closed peer is ready, and its read is the end of the data.
    sys.shutdown(client, 1);
    wants = .{.{ .fd = got.fd, .read = true }};
    sys.poll(a, &wants, 5000);
    try std.testing.expect(wants[0].can_read);
    try std.testing.expectEqual(@as(usize, 0), sys.read(got.fd, &buf).n);
    // An IPv6 socket has no IPv4 side, on a machine with IPv6.
    switch (sys.listenAt(sys.parseAddr("::1").?, false)) {
        .fd => |six| {
            defer sys.close(six);
            try std.testing.expect(sys.win.v6Only(six));
        },
        .err => {},
    }
    // A failed connect that does not wait reports once.
    const gone = sys.listenAt(v4, false).fd;
    var closed = sys.sockName(gone).?;
    closed.bytes = v4.bytes;
    sys.close(gone);
    const late = sys.connectTo(closed, null, false).fd;
    defer sys.close(late);
    wants = .{.{ .fd = late, .write = true }};
    sys.poll(a, &wants, 10000);
    try std.testing.expect(wants[0].can_write);
    try std.testing.expectEqualStrings("ECONNREFUSED", sys.connectError(late).?.name);
    try std.testing.expect(sys.connectError(late) == null);
    // That socket has no peer, so a read is an error.
    try std.testing.expectEqualStrings("ENOTCONN", sys.read(late, &buf).err.name);
}

test "socket refuses a blocked address and closes a blocked peer" {
    if (!tcl.sys.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const cap = tcl.interp.Capability;
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.event) | @backingInt(cap.socket) | @backingInt(cap.interp));
    fake_ticks = 0;
    it.event_host = .{ .now = fakeNow, .sleep = fakeSleep };
    // macOS has no 127.0.0.2 without an alias on the loopback device.
    if (@import("builtin").os.tag != .linux) {
        it.net = (try tcl.sock.parsePolicy(it.alloc(), "allow=127.0.0.1")).?;
        try std.testing.expectEqualStrings("1 1", try it.str(try it.eval("list [catch {socket ::1 9}] [catch {socket -server x -myaddr ::1 0}]")));
        try std.testing.expectEqualStrings("ZTCL NET DENIED", try it.str(try it.eval("catch {socket ::1 9}; set errorCode")));
        _ = try it.eval(
            \\set got none
            \\set srv [socket -server {apply {{s a p} {set ::got $a; close $s}}} -myaddr 127.0.0.1 0]
            \\set c [socket 127.0.0.1 [lindex [fconfigure $srv -sockname] 2]]
        );
        // The policy no longer has the peer, so the server closes it and
        // the accept command does not run.
        it.net = (try tcl.sock.parsePolicy(it.alloc(), "allow=::1")).?;
        const mac_script =
            \\fconfigure $c -blocking 0
            \\set n 0
            \\while {![eof $c] && [incr n] < 20000} {update; read $c}
            \\set end [eof $c]
            \\close $c; close $srv
            \\list $got $end
        ;
        try std.testing.expectEqualStrings("none 1", try it.str(try it.eval(mac_script)));
        return;
    }
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

// ---- The collector ----

/// Runs a script with no collection and with a collection at each Nth
/// allocation. The two results must be equal.
fn gcSame(script: []const u8, n: u32) !void {
    var want: []const u8 = undefined;
    var a: tcl.Interp = undefined;
    try a.init(std.testing.allocator);
    defer a.deinit();
    a.compute_limit = 10_000_000;
    try a.allow(@backingInt(tcl.interp.Capability.interp));
    want = try a.str(try a.eval(script));
    var b: tcl.Interp = undefined;
    try b.init(std.testing.allocator);
    defer b.deinit();
    b.compute_limit = 10_000_000;
    try b.allow(@backingInt(tcl.interp.Capability.interp));
    b.setGcStress(n);
    const got = try b.str(b.eval(script) catch |e| {
        std.debug.print("script: {s}\n{s}\n", .{ script, b.str(b.result) catch "" });
        return e;
    });
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(b.gcCount() > 0);
}

fn gcNested(it: *tcl.Interp, _: []const tcl.Value, _: ?*tcl.interp.Cmd) tcl.Error!tcl.Value {
    return it.eval("for {set i 0} {$i < 400} {incr i} {set t [string repeat u 200]}; set i");
}

test "a host call at nest 0 runs no collection, also through a nested eval" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.register("nested", gcNested);
    it.setGcStress(1);
    const script = try it.compile("nested; set a [string repeat k 300]; nested");
    // Only this frame holds the script, and it has no `enterHost`.
    const before = it.gcCount();
    for (script.cmds) |*c| _ = try it.evalCmd(c);
    const words = [_]tcl.Value{.{ .str = "nested" }};
    _ = try it.callWords(&words);
    try std.testing.expectEqual(before, it.gcCount());
    try std.testing.expectEqual(@as(u32, 0), it.heap.scopes);
    try std.testing.expectEqual(@as(u32, 0), it.nest);
    // A later `eval` collects again.
    _ = try it.eval("for {set i 0} {$i < 20} {incr i} {set t [string repeat v 50]}");
    if (tcl.gc.supported) try std.testing.expect(it.gcCount() > before);
}

test "enterHost scans the frame of the host" {
    if (tcl.gc.precise) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.setGcStress(1);
    const script = try it.compile("set a [string repeat k 300]; set b [string repeat m 300]; string length $a$b");
    it.enterHost();
    defer it.leaveHost();
    const before = it.gcCount();
    var last: tcl.Value = tcl.Value.empty;
    for (script.cmds) |*c| last = try it.evalCmd(c);
    try std.testing.expect(it.gcCount() > before);
    try std.testing.expectEqualStrings("600", try it.str(last));
}

test "the block size of a coroutine stack is the size that the mark reads" {
    if (!tcl.coro.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    _ = try it.eval("coroutine g apply {{} {yield 1; return 2}}");
    const c: *tcl.coro.Coro = @ptrCast(@alignCast(it.findCommand("g").?.ctx.?));
    try std.testing.expectEqual(tcl.heap.coro_stack_bytes, c.stack.len);
}

test "a child that runs a coroutine keeps the values of each stack" {
    if (!tcl.coro.supported) return error.SkipZigTest;
    try gcSame(
        \\set keep [string repeat p 90]
        \\interp create c
        \\c eval {
        \\    coroutine g apply {{} {
        \\        set s [string repeat k 40]
        \\        for {set i 0} {$i < 30} {incr i} {yield [string length $s[string repeat z $i]]}
        \\        return $s
        \\    }}
        \\    set out {}
        \\    for {set i 0} {$i < 29} {incr i} {lappend out [g]}
        \\    lappend out [g]
        \\}
        \\set r [c eval {set out}]
        \\interp delete c
        \\list $r [string length $keep]
    , 1);
}

test "a compare keeps the text of each string that looks like a number" {
    for ([_][]const u8{ "0", "-0", "+1", "007", "0x10", "0b1", " 1", "1 ", "1e3", "1.0", "9223372036854775807", "-9223372036854775808", "9223372036854775808", "-9223372036854775809" }) |text| {
        var it: tcl.Interp = undefined;
        try it.init(std.testing.allocator);
        defer it.deinit();
        const q = try std.fmt.allocPrint(std.testing.allocator, "proc f {{x}} {{ if {{$x < 5}} {{ set r 1 }} else {{ set r 0 }}; if {{$x == 5}} {{ incr r }}; return [list $x [string length $x] [string is integer -strict $x] [string is wideinteger -strict $x] [catch {{incr x 0}}]] }}; f {{{s}}}", .{text});
        defer std.testing.allocator.free(q);
        const got = try it.str(try it.eval(q));
        var chk: tcl.Interp = undefined;
        try chk.init(std.testing.allocator);
        defer chk.deinit();
        const list = try chk.list(.{ .str = got });
        try std.testing.expectEqualStrings(text, try chk.str(list[0]));
        try std.testing.expectEqual(@as(i64, @intCast(text.len)), try std.fmt.parseInt(i64, try chk.str(list[1]), 10));
    }
}

test "a child on the shared heap stops at the memory limit of its parent" {
    for ([_]u32{ 0, 16 }) |stress| {
        var it: tcl.Interp = undefined;
        try it.init(std.testing.allocator);
        defer it.deinit();
        try it.allow(@backingInt(tcl.interp.Capability.interp));
        it.mem_limit = 8 << 20;
        it.compute_limit = 50_000_000;
        it.setGcStress(stress);
        _ = try it.eval("interp create c");
        const r = it.eval("c eval {set l {}; while 1 {lappend l [string repeat x 4000]}}");
        try std.testing.expectError(error.TclError, r);
        try std.testing.expectEqualStrings("the script used too much memory", try it.str(it.result));
    }
}

test "compact keeps a string in tcl_precision" {
    var it: tcl.Interp = undefined;
    try it.init(std.heap.page_allocator);
    defer it.deinit();
    _ = try it.eval("set tcl_precision [string range 66 0 0]; set p [format %d 6]; set tcl_precision $p; unset p");
    var roots = [_]tcl.Value{};
    try it.compact(&roots, .{});
    // Reuse of the freed pages must not change the value.
    _ = try it.eval("for {set i 0} {$i < 200} {incr i} {set junk [string repeat z 64]}");
    try std.testing.expectEqualStrings("6", try it.str(try it.eval("set tcl_precision")));
    try std.testing.expectEqualStrings("3.333333", try it.str(try it.eval("set tcl_precision 7; expr {10.0 / 3}")));
    try std.testing.expectError(error.TclError, it.eval("set tcl_precision 99"));
    try std.testing.expectEqualStrings("7", try it.str(try it.eval("set tcl_precision")));
}

test "compact refuses an interpreter with objects, and the objects stay" {
    var it: tcl.Interp = undefined;
    try it.init(std.heap.page_allocator);
    defer it.deinit();
    _ = try it.eval("oo::class create C {variable v; constructor {} {set v [string repeat q 40]}; method get {} {return $v}}; C create o");
    var roots = [_]tcl.Value{};
    try std.testing.expectError(error.InterpBusy, it.compact(&roots, .{}));
    try std.testing.expectEqual(@as(usize, 40), (try it.str(try it.eval("o get"))).len);
    try std.testing.expectEqual(@as(usize, 40), (try it.str(try it.eval("[C new] get"))).len);
}

test "tcl_precision holds no array" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try std.testing.expectError(error.TclError, it.eval("array set tcl_precision {a 1}"));
    try std.testing.expectError(error.TclError, it.eval("set tcl_precision(a) 1"));
    _ = try it.eval("catch {unset tcl_precision}");
    try std.testing.expectError(error.TclError, it.eval("array set tcl_precision {a 1}"));
    try std.testing.expectError(error.TclError, it.eval("set tcl_precision(a) 1"));
    var roots = [_]tcl.Value{};
    try it.compact(&roots, .{});
}

test "compact ends each hold" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const v = try it.eval("string repeat h 40");
    try it.hold(v);
    var roots = [_]tcl.Value{v};
    try it.compact(&roots, .{});
    try std.testing.expectEqual(@as(usize, 0), it.held.items.len);
    try std.testing.expectEqual(@as(usize, 40), (try it.str(roots[0])).len);
}

test "a trace on an element link acts on the element, as in tclsh" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.event));
    it.event_host = .{ .now = fakeNow, .sleep = fakeSleep };
    _ = try it.eval(
        \\proc t {args} {lappend ::log $args}
        \\array set a {k 1 m 5}
        \\upvar #0 a(k) e
        \\trace add variable e write t
        \\set e 2
        \\lappend out $a(k) $e
        \\set a(k) 3
        \\lappend out $a(k) $e [trace info variable e] [trace info variable a(k)] [trace info variable a] $log
        \\set log {}
        \\trace remove variable e write t
        \\set e 4
        \\lappend out [llength $log] $a(k)
        \\proc p {} {upvar #0 a(k) x; trace add variable x {read write} t; set x 7; set y $x; trace remove variable x {read write} t; return $y}
        \\lappend out [p] $a(k) $log
        \\set log {}
        \\trace add variable e unset t
        \\unset e
        \\lappend out [info exists a(k)] $log
        \\after 0 {set f 42}
        \\array set b {q 1}
        \\upvar #0 b(q) f
        \\vwait f
        \\lappend out $b(q) $f
    );
    // The output of tclsh 8.6.16 for the same script.
    try std.testing.expectEqualStrings(
        \\2 2 3 3 {{write t}} {{write t}} {} {{e {} write} {a k write}} 0 4 7 7 {{x {} write} {x {} read}} 0 {{e {} unset}} 42 42
    , try it.str(try it.eval("set out")));
}

test "the modulo of the smallest integer does not overflow" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const v = try it.eval("set m -9223372036854775808; list [expr {$m % 3}] [expr {$m % -3}] [expr {$m % 7}] [expr {$m % 9223372036854775807}] [expr {7 % -3}] [expr {-7 % 3}]");
    // The values of tclsh 8.6.16.
    try std.testing.expectEqualStrings("1 -2 6 9223372036854775806 -2 2", try it.str(v));
}

test "the collector keeps a value in a variable, a list, a dict, an array, and a namespace" {
    try gcSame(
        \\set x [string repeat a 50]
        \\set l [list $x [string repeat b 40]]
        \\set d [dict create k $x m [string repeat c 40]]
        \\set arr(k) [string repeat e 40]
        \\namespace eval n {variable v [string repeat q 40]}
        \\list $x $l $d $arr(k) $n::v [string length [lindex $l 1]]
    , 1);
}

test "the collector keeps a value on the word stack and the last result" {
    try gcSame(
        \\list [string repeat a 30] [string repeat b 30] [string repeat c 30] [expr {1 + 2}] [string repeat d 30]
    , 1);
    try gcSame("string repeat xy 30; string repeat zw 25", 1);
}

test "the collector keeps the locals of a suspended coroutine" {
    if (!tcl.coro.supported) return error.SkipZigTest;
    try gcSame(
        \\coroutine g apply {{} {set s [string repeat k 40]; set l [list $s $s]; yield 1; yield $s; return $l}}
        \\list [g] [g]
    , 7);
}

test "the collector keeps a child interpreter and drops a deleted one" {
    try gcSame(
        \\interp create c
        \\c eval {set v [string repeat w 40]; proc f {} {return [string repeat y 20]}}
        \\set r [list [c eval {string length $v}] [c eval f]]
        \\interp delete c
        \\for {set i 0} {$i < 50} {incr i} {set t [string repeat u $i]}
        \\set r
    , 3);
}

test "the collector keeps traced variables, upvar links, and element links" {
    try gcSame(
        \\proc p {} {upvar 1 x y; set y [string repeat t 40]}
        \\set x 1
        \\p
        \\trace add variable x write {apply {{a b c} {set ::t [string repeat u 30]}}}
        \\set x 5
        \\set arr(a) [string repeat v 30]
        \\proc q {} {upvar 1 arr(a) e; set e [string repeat n 35]}
        \\q
        \\list $x $::t $arr(a)
    , 1);
}

test "the collector keeps compiled scripts, expressions, and caches" {
    try gcSame(
        \\proc f {n} {set s 0; for {set i 0} {$i < $n} {incr i} {set s [expr {$s + $i}]}; return $s}
        \\set body {incr z; string repeat a 10}
        \\set z 0
        \\for {set i 0} {$i < 30} {incr i} {eval $body}
        \\list [f 100] [f 200] $z
    , 5);
}

test "the collector keeps the buffer of a part of a string" {
    try gcSame(
        \\set s [string repeat abcdefghij 20]
        \\set t [string range $s 10 50]
        \\set s {}
        \\for {set i 0} {$i < 100} {incr i} {set u [string repeat z 30]}
        \\set a {}
        \\for {set i 0} {$i < 20} {incr i} {append a "x$i,"}
        \\list $t $a
    , 1);
}

test "a collection frees the garbage of a long loop" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.compute_limit = 100_000_000;
    it.collect();
    const start = it.memUsed();
    _ = try it.eval("proc go {n} {for {set i 0} {$i < $n} {incr i} {set s x$i; set l [list $i $i]; set d [dict create a $i]}}; go 200000");
    try std.testing.expect(it.memUsed() > start + (1 << 20));
    it.collect();
    try std.testing.expect(it.memUsed() < start + (1 << 20));
}

test "a held value survives 100 collections and an unheld value is freed" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    // The values stay out of the frame of the test. The helpers keep the
    // addresses as integers with the low bit set, so a scan of a native
    // stack or of the saved registers does not see them as pointers.
    const kept = try holdNew(&it, "string repeat ab 30");
    const gone = try evalAddr(&it, "string repeat cd 30");
    // A third block of the same size keeps the page.
    _ = try holdNew(&it, "string repeat ef 30");
    _ = try it.eval("set zz 1");
    for (0..100) |_| collectClean(&it);
    try expectHeldText(&it, kept, "abababababababababababababababababababababababababababababab");
    try expectFreed(&it, gone & ~@as(usize, 1));
    releaseAt(&it, kept);
    collectClean(&it);
    try expectFreed(&it, kept & ~@as(usize, 1));
}

/// Evaluates `script` and gives the address of the string of its value
/// with the low bit set.
noinline fn evalAddr(it: *tcl.Interp, script: []const u8) !usize {
    return @intFromPtr((try it.eval(script)).str.ptr) | 1;
}

/// Evaluates `script`, holds its value, and gives the address of the
/// string with the low bit set.
noinline fn holdNew(it: *tcl.Interp, script: []const u8) !usize {
    const v = try it.eval(script);
    try it.hold(v);
    return @intFromPtr(v.str.ptr) | 1;
}

/// The held value with the string at the address `addr` (low bit set).
noinline fn heldAt(it: *tcl.Interp, addr: usize) ?tcl.Value {
    for (it.held.items) |h| if (h == .str and @intFromPtr(h.str.ptr) == addr & ~@as(usize, 1)) return h;
    return null;
}

noinline fn expectHeldText(it: *tcl.Interp, addr: usize, want: []const u8) !void {
    const v = heldAt(it, addr) orelse return error.TestValueNotHeld;
    try std.testing.expectEqualStrings(want, try it.str(v));
}

noinline fn releaseAt(it: *tcl.Interp, addr: usize) void {
    if (heldAt(it, addr)) |v| it.release(v);
}

/// Clears 64 KiB of the stack below the caller, then collects. The
/// frames of the helpers above left their values in that memory, and a
/// conservative scan of the stack reads it.
noinline fn collectClean(it: *tcl.Interp) void {
    clearStack();
    it.collect();
}

noinline fn clearStack() void {
    var buf: [65536]u8 = undefined;
    @memset(&buf, 0);
    std.mem.doNotOptimizeAway(&buf);
}

/// Fails when the collector kept the block at `addr`. It first prints
/// each word of the roots of `it` that points into the block, with the
/// field of `Interp` that holds the word.
fn expectFreed(it: *tcl.Interp, addr: usize) !void {
    const heap = @import("heap.zig");
    if (heap.isFree(it.heap, addr)) return;
    const words: [*]const usize = @ptrCast(@alignCast(it));
    for (0..@sizeOf(tcl.Interp) / @sizeOf(usize)) |w| {
        const v = words[w];
        if (v < addr or v >= addr + 64) continue;
        const off = w * @sizeOf(usize);
        inline for (@typeInfo(tcl.Interp).@"struct".field_names) |name| {
            const at = @offsetOf(tcl.Interp, name);
            if (off >= at and off < at + @sizeOf(@FieldType(tcl.Interp, name))) std.debug.print("root: Interp.{s} + {d} = 0x{x}\n", .{ name, off - at, v });
        }
    }
    for (it.held.items) |h| if (h == .str and @intFromPtr(h.str.ptr) == addr) std.debug.print("root: held\n", .{});
    return error.TestBlockNotFreed;
}

test "a range from addRoot keeps the values in it" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    var slot: [2]tcl.Value = .{ try it.eval("string repeat xy 30"), try it.eval("string repeat zw 30") };
    try it.addRoot(std.mem.sliceAsBytes(&slot));
    _ = try it.eval("set zz 1");
    it.collect();
    try std.testing.expectEqualStrings("xyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxyxy", try it.str(slot[0]));
    try std.testing.expectEqualStrings("zwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzwzw", try it.str(slot[1]));
    it.removeRoot(std.mem.sliceAsBytes(&slot));
}

/// The steps left when the script reaches the memory limit.
fn stepsAtLimit(gc: bool, limit: usize) !u64 {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.gc_on = gc;
    it.compute_limit = 1_000_000_000;
    it.mem_limit = limit;
    const r = it.eval("set l {}; for {set i 0} {$i < 100000000} {incr i} {lappend l [string repeat x 50]}");
    try std.testing.expectError(error.TclError, r);
    try std.testing.expectEqualStrings("the script used too much memory", try it.str(it.result));
    return it.compute_limit;
}

test "with the collector off, the memory error stops at the same step" {
    const a = try stepsAtLimit(false, 8 << 20);
    const b = try stepsAtLimit(false, 8 << 20);
    try std.testing.expectEqual(a, b);
}

test "a loop under the limit gives the same result with the collector on or off" {
    for ([_]bool{ true, false }) |gc| {
        var it: tcl.Interp = undefined;
        try it.init(std.testing.allocator);
        defer it.deinit();
        it.gc_on = gc;
        it.compute_limit = 100_000_000;
        const v = try it.eval("set t 0; for {set i 0} {$i < 20000} {incr i} {set s [string repeat x [expr {$i % 50}]]; incr t [string length $s]}; set t");
        try std.testing.expectEqualStrings("490000", try it.str(v));
    }
}

// ---- lset in place ----

/// Runs `setup`, then the dropped form of `lset` on `name`, then `check`.
fn dropCheck(setup: []const u8, name: []const u8, index: []const u8, v: []const u8, script: []const u8, want: []const u8) !void {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.compute_limit = 1_000_000;
    _ = try it.eval(setup);
    const cell = (try it.findVar(it.frame, name, false)).?;
    try std.testing.expect(try tcl.more.lsetOwned(&it, cell, .{ .str = index }, .{ .str = v }));
    try std.testing.expectEqualStrings(want, try it.str(try it.eval(script)));
}

test "lset in place leaves a shared list alone" {
    try dropCheck("set a {1 2 3}; set b $a", "a", "0", "9", "list $a $b", "{9 2 3} {1 2 3}");
    // A result of the general command keeps its value.
    try check(&.{
        .{ "set a {1 2 3}; set b [lset a 0 9]; lset a 1 8; list $a $b", "{9 8 3} {9 2 3}" },
        .{ "set a {1 2 3}; set b $a; lset a 0 9; list $a $b", "{9 2 3} {1 2 3}" },
        .{ "set a {1 2 3}; lset a end 7; lset a end-1 6; lset a {0} 5", "5 6 7" },
        .{ "set a {a b}; lset a 2 c", "a b c" },
        .{ "set a {a b}; catch {lset a 3 c} m; set m", "list index out of range" },
    });
}

test "a second dropped lset writes in place" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.compute_limit = 1_000_000;
    _ = try it.eval("set a [lrepeat 100 0]");
    const cell = (try it.findVar(it.frame, "a", false)).?;
    try std.testing.expect(try tcl.more.lsetOwned(&it, cell, .{ .int = 3 }, .{ .int = 5 }));
    const buf = cell.v.owned.list.obj.buf.ptr;
    const used = it.memUsed();
    for (0..1000) |i| try std.testing.expect(try tcl.more.lsetOwned(&it, cell, .{ .int = 4 }, .{ .int = @intCast(i) }));
    try std.testing.expectEqual(buf, cell.v.owned.list.obj.buf.ptr);
    try std.testing.expectEqual(used, it.memUsed());
    // A general read ends the ownership.
    try std.testing.expectEqualStrings("999", try it.str(try it.eval("lindex $a 4")));
    try std.testing.expect(cell.v == .val);
}

test "lset in a proc does not change the list of the caller" {
    try check(&.{
        .{ "proc f {l} {for {set i 0} {$i < 50} {incr i} {lset l 1 $i}; return $l}; set x {a b c}; list [f $x] $x", "{a 49 c} {a b c}" },
        .{ "proc g {} {upvar 1 v w; lset w 0 z}; set v {a b}; g; set v", "z b" },
        .{ "set v {a b c}; trace add variable v read {apply {{n i o} {set ::seen 1}}}; lset v 1 q; list $v $seen", "{a q c} 1" },
        .{ "set v {a b c}; set r {}; foreach e $v {lset v 0 X; lappend r $e}; list $r $v", "{a b c} {X b c}" },
    });
}

// ---- switch as bytecode ----

test "switch in a proc: the forms that compile" {
    try check(&.{
        .{ "proc t {op} {set s 0; switch -exact -- $op {INC {incr s} MOVE {incr s 2}}}; list [t INC] [t MOVE] [t X]", "1 2 {}" },
        .{ "proc t {x} {switch -- $x {a - b {return AB} c {return C} default {return D}}}; list [t a] [t b] [t c] [t q]", "AB AB C D" },
        .{ "proc t {x} {switch $x a {return A} b {return B}}; list [t a] [t b] [t c]", "A B {}" },
        .{ "proc t {x} {switch -exact -- $x {1 {return one} 2 {return two}}}; list [t 1] [t 2] [t 3] [t 02]", "one two {} {}" },
        .{ "proc t {x} {switch -- $x {{a b} {return sp} default {return no}}}; list [t {a b}] [t a]", "sp no" },
        .{ "proc t {x} {switch -- $x {default {return d} x {return x}}}; list [t default] [t x]", "d x" },
        .{ "proc t {x} {set r [switch -- $x {a {string cat 1 2} b - c {string cat 3}}]; return $r}; list [t a] [t b] [t c] [t d]", "12 3 3 {}" },
        .{ "proc t {x} {set r {}; foreach i {1 2 3} {switch -- $i {2 continue 3 break}; lappend r $i}; return $r}; t 0", "1" },
        .{ "proc t {i} {switch -- [incr i] {1 {return a} 2 {return b}}}; list [t 0] [t 1] [t 5]", "a b {}" },
    });
}

test "switch: the guard and the cases of the general path" {
    try check(&.{
        .{ "proc t {x} {switch -- $x {a {return A}}}; rename switch sw2; proc switch {args} {return hijack}; t a", "hijack" },
        .{ "namespace eval n {proc switch {args} {return ns}}; proc t {x} {switch -- $x {a {return A}}}; t a", "A" },
        .{ "proc t {x} {switch -- $x {a {error boom}}}; catch {t a} m; set m", "boom" },
        .{ "proc t {x} {switch -glob -- $x {a* {return glob}}}; t abc", "glob" },
        .{ "proc t {x} {switch $x {a {return A}}}; catch {t -x} m; set m", "" },
        .{ "catch {switch -x y {a {return A}}} m; set m", "bad option \"-x\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --" },
        .{ "catch {switch -- x} m; set m", "extra switch pattern with no body" },
        .{ "catch {switch x {}} m; set m", "wrong # args: should be \"switch ?-option ...? string {?pattern body ...? ?default body?}\"" },
        .{ "proc t {x} {switch -- $x {a}}; catch {t a} m; set m", "extra switch pattern with no body" },
    });
}

test "messages of Tcl 8.6.16 from the suite" {
    try check(&.{
        .{ "set l {# 1 2 3}; lappend l", "# 1 2 3" },
        .{ "unset -nocomplain q; list [lappend q] [info exists q]", "{} 1" },
        .{ "set l \"1 \\{ 2\"; catch {lappend l} m; set m", "unmatched open brace in list" },
        .{ "catch {lmap {} {} {}} m; set m", "lmap varlist is empty" },
        .{ "catch {foreach {} {} {}} m; set m", "foreach varlist is empty" },
        .{ "catch {apply {x {} NO::SUCH} 1} m; set m", "namespace \"::NO::SUCH\" not found" },
        .{ "catch {dict incr d k 1 2} m; set m", "wrong # args: should be \"dict incr dictVarName key ?increment?\"" },
        .{ "catch {lsearch -index end+1 {a} a} m; set m", "index \"end+1\" cannot select an element from any list" },
        .{ "catch {lsort -index -1 {}} m; set m", "index \"-1\" cannot select an element from any list" },
        .{ "catch {lsearch -index end-5 {a} a} m; set m", "element -5 missing from sublist \"a\"" },
        .{ "catch {lsort -index 5 {{1 . c}}} m; set m", "element 5 missing from sublist \"1 . c\"" },
        .{ "catch {expr {0~0}} m; set m", "missing operator at _@_\nin expression \"0_@_~0\"" },
        .{ "catch {expr {()}} m; set m", "empty subexpression at _@_\nin expression \"(_@_)\"" },
        .{ "catch {expr {(}} m; set m", "unbalanced open paren\nin expression \"(\"" },
        .{ "catch {expr {a(0,)}} m; set m", "missing function argument at _@_\nin expression \"a(0,_@_)\"" },
        .{ "catch {expr {=}} m o; list $m [dict get $o -errorcode]", "{incomplete operator \"=\"\nin expression \"=\"} {TCL PARSE EXPR PARTOP}" },
        .{ "catch {expr {1 ? 2}} m; set m", "missing operator \":\" at _@_\nin expression \"1 ? 2_@_\"" },
        .{ "catch {expr {1 : 2}} m; set m", "unexpected operator \":\" without preceding \"?\"\nin expression \"1 : 2\"" },
        .{ "dict info {a 1 b 2}", "2 entries in table" },
        .{ "list [catch {dict info} m] $m [catch {dict info x} m] $m", "1 {wrong # args: should be \"dict info dictionary\"} 1 {missing value to go with key}" },
        .{ "set ::gx 0; list [info globals gx] [info globals :gx] [info globals ::gx] [info globals ::::gx]", "gx {} gx gx" },
        .{ "namespace eval nc {variable V 1}; set g 1; list [info vars *V*] [info globals *V*] [info vars nc::*] [info vars ::nc::V]", "{} {} ::nc::V ::nc::V" },
        .{ "namespace eval nc {variable V 1}; set g 1; namespace eval nc {lsort [info vars {[gV]}]}", "V g" },
        .{ "set x 08; list [catch {expr {$x + 1}} m] $m", "1 {can't use invalid octal number as operand of \"+\"}" },
        .{ "set x 08.5; expr {$x + 1}", "9.5" },
        .{ "set x 08e1; expr {$x + 1}", "81.0" },
        .{ "catch {expr {08}} m o; list $m [dict get $o -errorcode]", "{invalid bareword \"08\"\nin expression \"08\";\nshould be \"$08\" or \"{08}\" or \"08(...)\" or ... (invalid octal number?)} {TCL PARSE EXPR BADNUMBER OCTAL}" },
        .{ "set e \"123456789012345678901234567890*\\{abcdefghijklmnopqrstuvwxyz\"; catch {expr $e} m; set m", "missing close-brace\nin expression \"...012345678901234567890*{abcdefghijklmnopqrstuv...\"" },
        .{ "catch {expr {sin(1,2)}} m o; string match {*parsing*} [dict get $o -errorinfo]", "0" },
        .{ "catch {expr {1 +}} m o; dict get $o -errorinfo", "missing operand at _@_\nin expression \"1 +_@_\"\n    (parsing expression \"1 +\")\n    invoked from within\n\"expr {1 +}\"" },
    });
}

// ---- lassign and lset as bytecode ----

test "lassign in a proc" {
    try check(&.{
        .{ "proc t {} {lassign {1 2 3 4} x y; list $x $y}; t", "1 2" },
        .{ "proc t {} {set r [lassign {1 2 3 4} x y]; list $x $y $r}; t", "1 2 {3 4}" },
        .{ "proc t {} {set r [lassign {1} x y z]; list $x $y $z $r}; t", "1 {} {} {}" },
        .{ "proc t {} {lassign {a b} v(1) w; list [array get v] $w}; t", "{1 a} b" },
        .{ "proc t {} {upvar 1 g l; lassign {p q} l m; list $l $m}; set g 0; t; set g", "p" },
        .{ "proc t {} {trace add variable x write {apply {{a b c} {set ::hit 1}}}; lassign {5 6} x y; list $x $y $::hit}; t", "5 6 1" },
        .{ "proc t {} {lassign {a {b c} d} x y; list $y}; t", "{b c}" },
        .{ "proc t {} {catch {lassign {a {b} c} x y z} m; set m}; set hit {}; t", "" },
        .{ "set s \"a \\{b\"; proc t {s} {catch {lassign $s x} m; set m}; t $s", "unmatched open brace in list" },
        .{ "proc t {} {lassign {1 2} x y}; rename lassign la2; proc lassign {args} {return hijack}; t", "hijack" },
    });
}

test "lset in a proc" {
    try check(&.{
        .{ "proc t {} {set l {a b c}; lset l 1 Z; lset l end Q; lset l 0 {x y}; set l}; t", "{x y} Z Q" },
        .{ "proc t {} {set l {a b c}; catch {lset l 5 Z} m; list $l $m}; t", "{a b c} {list index out of range}" },
        .{ "proc t {} {set l {a b c}; set m [lset l 0 Z]; lset l 1 Y; list $l $m}; t", "{Z Y c} {Z b c}" },
        .{ "proc t {} {set l {a b c}; set k $l; lset l 0 Z; lset l 1 Y; list $l $k}; t", "{Z Y c} {a b c}" },
        .{ "set gl {o p}; proc t {} {global gl; lset gl 0 NEW; set gl}; t", "NEW p" },
        .{ "proc t {} {lset nope 0 x}; catch {t} m; set m", "can't read \"nope\": no such variable" },
        .{ "proc t {} {set l {a b c}; foreach e $l {lset l 0 X}; set l}; t", "X b c" },
        .{ "proc t {} {set l {a b c}; set r {}; foreach e $l {lset l 0 X; lappend r $e}; list $r $l}; t", "{a b c} {X b c}" },
        .{ "proc t {} {set l {a b}; lset l 0 1; lappend l c; lset l 1 2; set l}; t", "1 2 c" },
        .{ "proc t {} {set l {1 2 3 4}; lset l 0 9; dict set l 5 6; dict incr l 9; set l}; t", "9 3 3 4 5 6" },
        .{ "proc t {} {set l {a b}; lset l 0 1}; rename lset ls2; proc lset {args} {return hijack}; t", "hijack" },
    });
}

// ---- base64 ----

test "binary encode and decode base64" {
    try check(&.{
        .{ "binary encode base64 {}", "" },
        .{ "binary encode base64 a", "YQ==" },
        .{ "binary encode base64 ab", "YWI=" },
        .{ "binary encode base64 abc", "YWJj" },
        .{ "binary encode base64 abcd", "YWJjZA==" },
        .{ "binary decode base64 YQ==", "a" },
        .{ "binary decode base64 YWI=", "ab" },
        .{ "binary decode base64 YWJj", "abc" },
        .{ "binary decode base64 \"YWJj\\nZA==\"", "abcd" },
        .{ "binary decode base64 YWJj====", "!invalid base64 character \"=\" at position 6" },
        .{ "binary decode base64 -strict \"YWJj ZA==\"", "!invalid base64 character \" \" at position 4" },
        .{ "binary decode base64 YQ==Y", "!invalid base64 character \"Y\" at position 4" },
        .{ "binary decode base64 \"Y!Q=\"", "!invalid base64 character \"!\" at position 1" },
        .{ "binary encode base64 -maxlen 4 -wrapchar | abcdefgh", "YWJj|ZGVm|Z2g=" },
        .{ "string length [binary decode base64 [binary encode base64 [string repeat ab 1000]]]", "2000" },
        .{ "binary encode base64 \"\\u00e9\\u00ff\"", "6f8=" },
        .{ "string length [binary decode base64 6f8=]", "2" },
        .{ "binary encode hex abc", "616263" },
    });
}

test "a forged tail code runs no tail call" {
    try check(&.{
        .{ "proc p {} {return -code 2147483632}; catch p", "2147483632" },
        .{ "proc q {} {catch {tailcall string repeat Z 3} m; return -code 2147483632}; list [catch q r] $r", "2147483632 {}" },
    });
}

test "a constructor keeps its call chain through collections" {
    // The same script with and without a collection at each allocation.
    // `self caller` and `next` read the call chain of the outer `new`.
    const script =
        \\oo::class create Foo {
        \\    constructor {} { for {set i 0} {$i < 100} {incr i} { set x [string repeat ab 50] }; set ::c [catch {self caller} ::cr] }
        \\    method m {} { for {set i 0} {$i < 100} {incr i} { set x [string repeat cd 50] }; return [self next] }
        \\}
        \\oo::class create Bar { superclass Foo; method m {} { for {set i 0} {$i < 50} {incr i} { set y [string repeat ef 50] }; next } }
        \\set o [Bar new]
        \\list $::c $::cr [$o m]
    ;
    var got: [2][]const u8 = undefined;
    for ([_]u32{ 0, 1 }, 0..) |stress, k| {
        var it: tcl.Interp = undefined;
        try it.init(std.testing.allocator);
        defer it.deinit();
        it.setGcStress(stress);
        got[k] = try std.testing.allocator.dupe(u8, try it.str(try it.eval(script)));
    }
    defer for (got) |g| std.testing.allocator.free(g);
    try std.testing.expectEqualStrings(got[0], got[1]);
}

comptime {
    _ = @import("thread_tests.zig");
}

test "fsroot: the absolute host paths of host mode, for POSIX and Windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fs = tcl.fsroot;
    try std.testing.expectEqualStrings("/home/u/x", (try fs.joinPosix(a, "/home/u", "x")).?);
    try std.testing.expectEqualStrings("/etc/hosts", (try fs.joinPosix(a, "/home/u", "/etc/./hosts")).?);
    try std.testing.expectEqualStrings("/", (try fs.joinPosix(a, "/home", "../../..")).?);
    try std.testing.expectEqualStrings("/home/v", (try fs.joinPosix(a, "/home/u", "../v/")).?);
    try std.testing.expect((try fs.joinPosix(a, "/", "a\x00b")) == null);
    try std.testing.expectEqualStrings("C:/Users/u/x.txt", (try fs.joinWindows(a, "C:/Users/u", "x.txt")).?);
    try std.testing.expectEqualStrings("D:/a/c", (try fs.joinWindows(a, "C:/Users/u", "D:\\a\\b\\..\\c")).?);
    try std.testing.expectEqualStrings("C:/Windows", (try fs.joinWindows(a, "C:/Users/u", "/Windows")).?);
    try std.testing.expectEqualStrings("C:/", (try fs.joinWindows(a, "C:/Users", "../..")).?);
    try std.testing.expectEqualStrings("//srv/share/a", (try fs.joinWindows(a, "C:/x", "\\\\srv\\share\\a")).?);
    try std.testing.expectEqualStrings("//srv/share/b", (try fs.joinWindows(a, "//srv/share/a", "../b")).?);
    try std.testing.expectEqualStrings("E:/x", (try fs.joinWindows(a, "C:/", "E:x")).?);
}

test "fsroot: host mode uses the real paths of the host, and a root ends it" {
    if (comptime !tcl.fsroot.supported or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.file));
    try tcl.fsroot.setHost(&it);
    const v = try it.eval(
        \\set d [file join [pwd] .zig-cache ztcl-host-test]
        \\file delete -force $d
        \\file mkdir $d/sub
        \\set f [open $d/sub/a.txt w]; puts -nonewline $f hello; close $f
        \\set f [open $d/sub/a.txt]; set got [read $f]; close $f
        \\cd $d
        \\set r [list $got [glob sub/*.txt] [string equal [pwd] $d] [file exists $d/sub/a.txt]]
        \\lappend r [string equal [file normalize sub/../sub/a.txt] $d/sub/a.txt]
        \\file rename sub/a.txt sub/b.txt
        \\lappend r [file exists sub/b.txt]
        \\cd ..
        \\file delete -force $d
        \\lappend r [file exists $d]
    );
    try std.testing.expectEqualStrings("hello sub/a.txt 1 1 1 1 0", try it.str(v));
    // A root after host mode puts the interpreter in the jail again.
    try tcl.fsroot.setRoot(&it, ".");
    try std.testing.expect(!it.fs.host);
    try std.testing.expectEqualStrings("/", try it.str(try it.eval("pwd")));
}

var launch_buf: [512]u8 = undefined;
var launched: []const u8 = "";

fn recordOpen(_: ?*anyopaque, target: []const u8) bool {
    @memcpy(launch_buf[0..target.len], target);
    launched = launch_buf[0..target.len];
    return true;
}

test "ztcl::open gives a URL or the host path of a file to the opener" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.launch_host = .{ .open = recordOpen };
    try it.allow(@backingInt(tcl.interp.Capability.launch));
    _ = try it.eval("ztcl::open https://example.com/a?b=1");
    try std.testing.expectEqualStrings("https://example.com/a?b=1", launched);
    _ = try it.eval("ztcl::open MAILTO:a@example.com");
    try std.testing.expectEqualStrings("{ZTCL OPEN SCHEME} {ZTCL OPEN SCHEME} {ZTCL OPEN URL}", try it.str(try it.eval(
        \\set r {}
        \\foreach u [list file:///etc/passwd javascript:x "http://a\nb"] { catch {ztcl::open $u}; lappend r $::errorCode }
        \\set r
    )));
    // A file needs `file` too.
    try std.testing.expectEqualStrings("ZTCL OPEN NOFILE", try it.str(try it.eval("catch {ztcl::open a.txt}; set ::errorCode")));
    if (comptime !tcl.fsroot.supported or @import("builtin").os.tag == .wasi) return;
    try it.allow(@backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.file));
    try tcl.fsroot.setHost(&it);
    _ = try it.eval(
        \\set d [file join [pwd] .zig-cache ztcl-open-test]
        \\file delete -force $d
        \\file mkdir $d/sub
        \\file mkdir $d/sub/Tool.app
        \\foreach n {a.txt b.EXE c.ps1 d.command} { set f [open $d/sub/$n w]; close $f }
    );
    // In host mode the opener gets the normal host path.
    _ = try it.eval("ztcl::open $d/sub/../sub/a.txt");
    try std.testing.expect(std.mem.endsWith(u8, launched, "/ztcl-open-test/sub/a.txt"));
    if (@import("builtin").os.tag != .windows and @import("builtin").os.tag != .macos) {
        // Only Windows and macOS have the host path of a file in the jail.
        _ = try it.eval("file delete -force $d");
        return;
    }
    try tcl.fsroot.setRoot(&it, ".zig-cache/ztcl-open-test");
    launched = "";
    _ = try it.eval("ztcl::open sub/../sub/a.txt");
    try std.testing.expect(std.mem.endsWith(u8, launched, "/ztcl-open-test/sub/a.txt"));
    try std.testing.expect(launched[0] == '/' or launched[1] == ':');
    _ = try it.eval("ztcl::open sub");
    try std.testing.expect(std.mem.endsWith(u8, launched, "/ztcl-open-test/sub"));
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expectEqualStrings("{ZTCL OPEN BLOCKED} {ZTCL OPEN BLOCKED} {POSIX ENOENT {no such file or directory}}", try it.str(try it.eval(
            \\set r {}
            \\foreach p {sub/b.EXE /sub/c.ps1 sub/none.txt} { catch {ztcl::open $p}; lappend r $::errorCode }
            \\set r
        )));
    }
    if (@import("builtin").os.tag == .macos) {
        try std.testing.expectEqualStrings("{ZTCL OPEN BLOCKED} {ZTCL OPEN BLOCKED} {POSIX ENOENT {no such file or directory}}", try it.str(try it.eval(
            \\set r {}
            \\foreach p {sub/d.command /sub/Tool.app sub/none.txt} { catch {ztcl::open $p}; lappend r $::errorCode }
            \\set r
        )));
    }
    // The jail holds: a path out of the root is an error.
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("catch {ztcl::open ../../build.zig}")));
    try tcl.fsroot.setHost(&it);
    _ = try it.eval("file delete -force [file join [pwd] .zig-cache ztcl-open-test]");
}

test "ztcl::open: the scheme of a URL, and the blocked file types" {
    const l = tcl.launch;
    try std.testing.expectEqualStrings("https", l.schemeOf("https://a").?);
    try std.testing.expect(l.schemeOf("C:/a.txt") == null);
    try std.testing.expect(l.schemeOf("a/b:c") == null);
    try std.testing.expect(l.isBlocked("C:/x/setup.Exe"));
    try std.testing.expect(l.isBlocked("run.bat"));
    try std.testing.expect(!l.isBlocked("C:/x.exe/notes.txt"));
    try std.testing.expect(!l.isBlocked("README"));
}

test "ztcl::open: the shell of Windows fails on a missing file, with no dialog" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(!(try tcl.launch.win.shellOpen(std.testing.allocator, "C:/ztcl-no-such-folder/none.txt")));
}

test "ztcl::win::registry: the keys of the allow list" {
    const r = tcl.winreg;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const k = (try r.parseKey(aa, "hkcu/Software//App/x")).?;
    try std.testing.expectEqual(@as(usize, 1), k.root);
    try std.testing.expect(std.mem.eql(u8, k.path, "Software" ++ [_]u8{'\x5c'} ++ "App" ++ [_]u8{'\x5c'} ++ "x"));
    try std.testing.expect((try r.parseKey(aa, "HKEY_NOWHERE/a")) == null);
    const list = [_][]const u8{"HKEY_CURRENT_USER/Software/App"};
    try std.testing.expect(try r.allowed(aa, &list, (try r.parseKey(aa, "HKCU/software/app")).?));
    try std.testing.expect(try r.allowed(aa, &list, (try r.parseKey(aa, "HKCU/Software/App/Sub")).?));
    try std.testing.expect(!try r.allowed(aa, &list, (try r.parseKey(aa, "HKCU/Software/AppX")).?));
    try std.testing.expect(!try r.allowed(aa, &list, (try r.parseKey(aa, "HKLM/Software/App")).?));
    try std.testing.expect(!try r.allowed(aa, &.{}, (try r.parseKey(aa, "HKCU/Software/App")).?));
}

test "ztcl::win::registry: set, get, type, keys, values, and delete" {
    if (!tcl.winreg.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const list = [_][]const u8{"HKEY_CURRENT_USER/Software/ztcl-test"};
    it.registry_allow = &list;
    try it.allow(@backingInt(tcl.interp.Capability.registry));
    const ev = struct {
        fn f(i: *tcl.Interp, s: []const u8) ![]const u8 {
            return i.str(try i.eval(s));
        }
    }.f;
    _ = try ev(&it, "catch {ztcl::win::registry delete HKCU/Software/ztcl-test}");
    _ = try ev(&it, "set k HKCU/Software/ztcl-test/a");
    _ = try ev(&it, "ztcl::win::registry set $k s {hello world}");
    _ = try ev(&it, "ztcl::win::registry set $k n 42 dword");
    _ = try ev(&it, "ztcl::win::registry set $k q -5 qword");
    _ = try ev(&it, "ztcl::win::registry set $k m {one {two three}} multi_sz");
    _ = try ev(&it, "ztcl::win::registry set $k b [binary format c3 {1 255 0}] binary");
    _ = try ev(&it, "ztcl::win::registry set $k/sub");
    try std.testing.expectEqualStrings("{hello world} 42 -5 {one {two three}} sz dword multi_sz binary 3 1", try ev(&it, "list [ztcl::win::registry get $k s] [ztcl::win::registry get $k n] [ztcl::win::registry get $k q] [ztcl::win::registry get $k m] [ztcl::win::registry type $k s] [ztcl::win::registry type $k n] [ztcl::win::registry type $k m] [ztcl::win::registry type $k b] [string length [ztcl::win::registry get $k b]] [string equal [ztcl::win::registry get $k b] [binary format c3 {1 255 0}]]"));
    try std.testing.expectEqualStrings("b m n q s", try ev(&it, "lsort [ztcl::win::registry values $k]"));
    try std.testing.expectEqualStrings("sub", try ev(&it, "ztcl::win::registry keys $k"));
    try std.testing.expectEqualStrings("s", try ev(&it, "ztcl::win::registry values $k {[s]*}"));
    _ = try ev(&it, "ztcl::win::registry delete $k s");
    try std.testing.expectEqualStrings("ZTCL REGISTRY NOENT", try ev(&it, "catch {ztcl::win::registry get $k s}; set ::errorCode"));
    try std.testing.expectEqualStrings("ZTCL REGISTRY DENIED", try ev(&it, "catch {ztcl::win::registry get HKCU/Software/Microsoft x}; set ::errorCode"));
    _ = try ev(&it, "ztcl::win::registry delete HKCU/Software/ztcl-test");
    try std.testing.expectEqualStrings("ZTCL REGISTRY NOENT", try ev(&it, "catch {ztcl::win::registry keys HKCU/Software/ztcl-test}; set ::errorCode"));
}

test "ztcl::open: the open program of macOS fails on a missing file" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try std.testing.expect(!tcl.launch.mac.open(std.testing.allocator, "/ztcl-no-such-folder/none.txt"));
}

test "ztcl::win::credential: the allow list, the arguments, and the structure of an item" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.credential));
    try std.testing.expectEqualStrings("ZTCL WIN DENIED", try it.str(try it.eval("catch {ztcl::win::credential get org.example.app me}; set ::errorCode")));
    const list = [_][]const u8{"org.example.app"};
    it.credential_allow = &list;
    try std.testing.expectEqualStrings("a service is a name with no \"/\"", try it.str(try it.eval("catch {ztcl::win::credential get a/b me} m; set m")));
    try std.testing.expectEqualStrings("bad option \"read\": must be delete, get, or set", try it.str(try it.eval("catch {ztcl::win::credential read org.example.app me} m; set m")));
    try std.testing.expectEqualStrings("ZTCL WIN LENGTH", try it.str(try it.eval("catch {ztcl::win::credential set org.example.app me [string repeat x 3000]}; set ::errorCode")));
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expectEqualStrings("ZTCL WIN UNAVAILABLE", try it.str(try it.eval("catch {ztcl::win::credential get org.example.app me}; set ::errorCode")));
        return;
    }
    const wc = @import("wincred.zig");
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(wc.CREDENTIALW));
    const target = try wc.targetName(std.testing.allocator, "org.example.app", "me");
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("org.example.app/me"), target);
    const c = wc.credentialOf(target.ptr, target.ptr, "s3cret");
    try std.testing.expectEqual(@as(u32, 6), c.CredentialBlobSize);
    try std.testing.expectEqual(@as(u32, 1), c.Type);
    // A missing item: a read of the store, with no write.
    try std.testing.expectEqualStrings("ZTCL WIN NOTFOUND", try it.str(try it.eval("catch {ztcl::win::credential get org.example.app no-such-account-of-the-tests} m; set ::errorCode")));
}

test "ztcl::win::credential writes, reads, and deletes an item with ZTCL_TEST_CREDENTIAL=1" {
    // A write changes the credential store of the user, so it runs only
    // when the environment asks for it.
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const W = struct {
        extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;
    };
    var buf: [8]u16 = undefined;
    if (W.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZTCL_TEST_CREDENTIAL"), &buf, buf.len) == 0) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.credential));
    const list = [_][]const u8{"org.ztcl.test"};
    it.credential_allow = &list;
    _ = try it.eval("ztcl::win::credential set org.ztcl.test me {a secret}");
    try std.testing.expectEqualStrings("a secret", try it.str(try it.eval("ztcl::win::credential get org.ztcl.test me")));
    _ = try it.eval("ztcl::win::credential delete org.ztcl.test me");
    try std.testing.expectEqualStrings("ZTCL WIN NOTFOUND", try it.str(try it.eval("catch {ztcl::win::credential get org.ztcl.test me}; set ::errorCode")));
}

test "ztcl::win::folder gives the known folders of the user" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.env));
    try std.testing.expect(std.mem.startsWith(u8, try it.str(try it.eval("catch {ztcl::win::folder trash} m; set m")), "bad folder \"trash\": must be appdata, desktop,"));
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expectEqualStrings("ZTCL WIN UNAVAILABLE", try it.str(try it.eval("catch {ztcl::win::folder documents}; set ::errorCode")));
        return;
    }
    const local = try it.str(try it.eval("ztcl::win::folder localappdata"));
    try std.testing.expect(std.mem.indexOf(u8, local, "/AppData/Local") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, local, '\\') == null);
    try std.testing.expect((try it.str(try it.eval("ztcl::win::folder programfiles"))).len > 3);
}

test "ztcl::mac: the allow lists of the keychain and of the defaults" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.keychain) | @backingInt(tcl.interp.Capability.defaults));
    // An empty list reaches no service and no domain.
    try std.testing.expectEqualStrings("ZTCL MAC DENIED", try it.str(try it.eval("catch {ztcl::mac::keychain get org.example.app me}; set ::errorCode")));
    try std.testing.expectEqualStrings("ZTCL MAC DENIED", try it.str(try it.eval("catch {ztcl::mac::defaults get org.example.app k}; set ::errorCode")));
    const list = [_][]const u8{"org.ztcl.test"};
    it.keychain_allow = &list;
    it.defaults_allow = &list;
    try std.testing.expectEqualStrings("ZTCL MAC DENIED", try it.str(try it.eval("catch {ztcl::mac::keychain get org.ztcl.test.other me}; set ::errorCode")));
    try std.testing.expectEqualStrings("bad option \"read\": must be delete, get, or set", try it.str(try it.eval("catch {ztcl::mac::defaults read org.ztcl.test k} m; set m")));
    if (@import("builtin").os.tag != .macos) {
        try std.testing.expectEqualStrings("ZTCL MAC UNAVAILABLE", try it.str(try it.eval("catch {ztcl::mac::defaults get org.ztcl.test k}; set ::errorCode")));
        return;
    }
    // The calls of the system run only with ZTCL_TEST_MAC=1, as in CI:
    // a keychain can ask the user on a desktop.
    const v = std.c.getenv("ZTCL_TEST_MAC") orelse return error.SkipZigTest;
    if (v[0] != '1') return error.SkipZigTest;
    _ = try it.eval("ztcl::mac::defaults set org.ztcl.test greeting {héllo}");
    try std.testing.expectEqualStrings("héllo", try it.str(try it.eval("ztcl::mac::defaults get org.ztcl.test greeting")));
    _ = try it.eval("ztcl::mac::defaults delete org.ztcl.test greeting");
    try std.testing.expectEqualStrings("", try it.str(try it.eval("ztcl::mac::defaults get org.ztcl.test greeting")));
    _ = try it.eval("ztcl::mac::keychain set org.ztcl.test tester s3cret");
    _ = try it.eval("ztcl::mac::keychain set org.ztcl.test tester s3cret2");
    try std.testing.expectEqualStrings("s3cret2", try it.str(try it.eval("ztcl::mac::keychain get org.ztcl.test tester")));
    _ = try it.eval("ztcl::mac::keychain delete org.ztcl.test tester");
    try std.testing.expectEqualStrings("ZTCL MAC NOTFOUND", try it.str(try it.eval("catch {ztcl::mac::keychain get org.ztcl.test tester}; set ::errorCode")));
}

var notified: [3][128]u8 = undefined;
var notified_len: [3]usize = .{ 0, 0, 0 };

fn recordNote(_: ?*anyopaque, note: *const tcl.notify.Note) bool {
    for ([_][]const u8{ note.title, note.subtitle, note.body }, 0..) |s, k| {
        @memcpy(notified[k][0..s.len], s);
        notified_len[k] = s.len;
    }
    return !std.mem.eql(u8, note.title, "fail");
}

test "ztcl::notify gives the texts to the notifier" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.notify));
    it.notify_host = .{ .show = recordNote };
    _ = try it.eval("ztcl::notify Build -subtitle ztcl -body {all \"tests\" pass}");
    try std.testing.expectEqualStrings("Build", notified[0][0..notified_len[0]]);
    try std.testing.expectEqualStrings("ztcl", notified[1][0..notified_len[1]]);
    try std.testing.expectEqualStrings("all \"tests\" pass", notified[2][0..notified_len[2]]);
    try std.testing.expectEqualStrings("ZTCL NOTIFY FAILED", try it.str(try it.eval("catch {ztcl::notify fail}; set ::errorCode")));
    try std.testing.expectEqualStrings("ZTCL NOTIFY TEXT", try it.str(try it.eval("catch {ztcl::notify {}}; set ::errorCode")));
    try std.testing.expectEqualStrings("ZTCL NOTIFY LENGTH", try it.str(try it.eval("catch {ztcl::notify [string repeat x 300]}; set ::errorCode")));
    try std.testing.expectEqualStrings("bad option \"-icon\": must be -body or -subtitle", try it.str(try it.eval("catch {ztcl::notify a -icon b} m; set m")));
}

test "ztcl::notify: the texts are arguments of the script of osascript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try tcl.notify.osascriptArgs(arena.allocator(), &.{ .title = "a\" & (do shell script \"x\")", .body = "b", .subtitle = "c" });
    try std.testing.expectEqualStrings("/usr/bin/osascript", std.mem.span(argv[0].?));
    // The script is the fixed lines, and the texts come after them.
    try std.testing.expectEqualStrings("on run argv", std.mem.span(argv[2].?));
    try std.testing.expectEqualStrings("a\" & (do shell script \"x\")", std.mem.span(argv[7].?));
    try std.testing.expectEqualStrings("b", std.mem.span(argv[8].?));
    try std.testing.expectEqualStrings("c", std.mem.span(argv[9].?));
    try std.testing.expect(argv[10] == null);
}

test "ztcl::vm on Windows: a guest boots, and vsock and exec reach its agent" {
    const builtin = @import("builtin");
    if (comptime !(builtin.os.tag == .windows and builtin.cpu.arch == .x86_64)) return error.SkipZigTest;
    @import("whp.zig").probe() catch return error.SkipZigTest;
    // The x86-64 guest of tools/vm-guest (the artifact vm-guest-x86_64)
    // in zig-out/vm-guest, with the agent of docs/dev/vm-agent.md.
    std.Io.Dir.cwd().access(std.testing.io, "zig-out/vm-guest/bzImage", .{}) catch return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.vm) | @backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.file));
    try tcl.fsroot.setRoot(&it, "zig-out/vm-guest");
    const ev = struct {
        fn f(x: *tcl.Interp, s: []const u8) ![]const u8 {
            const v = x.eval(s) catch |e| {
                std.debug.print("tcl error: {s}\n", .{x.str(x.result) catch ""});
                return e;
            };
            return x.str(v);
        }
    }.f;
    try std.testing.expectEqualStrings("vm1", try ev(&it, "ztcl::vm create -kernel bzImage -initrd initramfs.cpio.gz -memory 128"));
    _ = try ev(&it, "ztcl::vm start vm1");
    try std.testing.expectEqualStrings("running", try ev(&it, "ztcl::vm status vm1"));
    // The probe of the agent: 16 bytes of its boot clock, then an echo.
    _ = try ev(&it, "set ch [ztcl::vm vsock vm1 1025 -timeout 10000]");
    try std.testing.expectEqualStrings("16", try ev(&it, "string length [read $ch 16]"));
    try std.testing.expectEqualStrings("ping", try ev(&it, "puts -nonewline $ch ping; flush $ch; read $ch 4"));
    _ = try ev(&it, "close $ch");
    // A program of the guest through the agent.
    try std.testing.expectEqualStrings("0 {hi\n}", try ev(&it, "set r [ztcl::vm exec vm1 /bin/busybox echo hi]; list [dict get $r exit] [dict get $r stdout]"));
    _ = try ev(&it, "ztcl::vm stop vm1");
    try std.testing.expectEqualStrings("stopped", try ev(&it, "ztcl::vm status vm1"));
    _ = try ev(&it, "ztcl::vm delete vm1");
    // A 9p share of a folder of the root, read and written in the guest.
    _ = try ev(&it, "file delete -force share-test; file mkdir share-test/sub; set f [open share-test/sub/in.txt w]; puts -nonewline $f {from the host}; close $f");
    _ = try ev(&it, "set v [ztcl::vm create -kernel bzImage -initrd initramfs.cpio.gz -memory 128 -share {share-test /mnt rw}]; ztcl::vm start $v");
    _ = try ev(&it, "close [ztcl::vm vsock $v 1025 -timeout 10000]; ztcl::vm mount $v share0 /mnt");
    try std.testing.expectEqualStrings("from the host", try ev(&it, "dict get [ztcl::vm exec $v /bin/busybox cat /mnt/sub/in.txt] stdout"));
    try std.testing.expectEqualStrings("0", try ev(&it, "dict get [ztcl::vm exec $v /bin/busybox sh -c {echo -n from the guest > /mnt/out.txt && /bin/busybox mkdir /mnt/made && /bin/busybox mv /mnt/sub/in.txt /mnt/made/moved.txt}] exit"));
    try std.testing.expectEqualStrings("in.txt made out.txt sub", try ev(&it, "lsort [list in.txt {*}[lmap x [glob -tails -directory share-test *] {set x}]]"));
    try std.testing.expectEqualStrings("from the guest", try ev(&it, "set f [open share-test/out.txt]; set t [read $f]; close $f; set t"));
    try std.testing.expectEqualStrings("from the host", try ev(&it, "set f [open share-test/made/moved.txt]; set t [read $f]; close $f; set t"));
    const ls = try ev(&it, "dict get [ztcl::vm exec $v /bin/busybox ls -l /mnt/out.txt] stdout");
    try std.testing.expect(std.mem.indexOf(u8, ls, " 14 ") != null);
    _ = try ev(&it, "ztcl::vm stop $v; ztcl::vm delete $v; file delete -force share-test");
}

test "ztcl::vm image: install, list, and create -image through the store" {
    if (comptime !@import("vmstore.zig").supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A release folder in the jail: the signed manifest of the fixtures
    // and its arm64 kernel, the 4 bytes "test".
    try tmp.dir.createDirPath(std.testing.io, "jail/rel");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "jail/rel/manifest.json", .data = @embedFile("vmimage_fixtures/manifest.json") });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "jail/rel/manifest.json.sig", .data = @embedFile("vmimage_fixtures/manifest.json.sig.good") });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "jail/rel/Image", .data = "test" });
    const jail = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/jail", .{tmp.sub_path});
    defer a.free(jail);
    const store = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/store", .{tmp.sub_path});
    defer a.free(store);
    var it: tcl.Interp = undefined;
    try it.init(a);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.vm) | @backingInt(tcl.interp.Capability.file));
    try tcl.fsroot.setRoot(&it, jail);
    it.vm_host.image_store = store;
    const ev = struct {
        fn f(x: *tcl.Interp, s: []const u8) ![]const u8 {
            const v = x.eval(s) catch |e| {
                std.debug.print("tcl error: {s}\n", .{x.str(x.result) catch ""});
                return e;
            };
            return x.str(v);
        }
    }.f;
    // The fixture has files for arm64 only, and install needs the files
    // of the host.
    if (comptime std.mem.eql(u8, @import("vmstore.zig").host_arch, "arm64")) {
        try std.testing.expectEqualStrings("ztcl-guest-test 3", try ev(&it, "set r [ztcl::vm image install /rel]; list [dict get $r name] [dict get $r counter]"));
        try std.testing.expect(std.mem.indexOf(u8, try ev(&it, "ztcl::vm image list"), "ztcl-guest-test") != null);
    } else {
        try std.testing.expectEqualStrings("ZTCL VM IMAGE MISSING", try ev(&it, "catch {ztcl::vm image install /rel}; join [lrange $::errorCode 0 3] { }"));
        try std.testing.expectEqualStrings("", try ev(&it, "ztcl::vm image list"));
    }
    // create -image on the Windows Hypervisor Platform. KVM has no
    // -image yet.
    if (comptime @import("builtin").os.tag != .windows) return;
    @import("whp.zig").probe() catch return;
    try std.testing.expectEqualStrings("-image gives the kernel, the initramfs, and the command line: no -kernel, -initrd, or -cmdline with it", try ev(&it, "catch {ztcl::vm create -image ztcl-guest-test -kernel /rel/Image} m; set m"));
    try std.testing.expectEqualStrings("ZTCL VM IMAGE NAME", try ev(&it, "catch {ztcl::vm create -image no-such-image}; join [lrange $::errorCode 0 3] { }"));
}

test "ztcl::vm on Windows: create -image boots the signed test release with its verity root" {
    const builtin = @import("builtin");
    if (comptime !(builtin.os.tag == .windows and builtin.cpu.arch == .x86_64)) return error.SkipZigTest;
    @import("whp.zig").probe() catch return error.SkipZigTest;
    // The release of tools/vm-guest/fetch-test-image.sh in
    // zig-out/vm-image-test, signed with the test key that a test build
    // trusts.
    std.Io.Dir.cwd().access(std.testing.io, "zig-out/vm-image-test/manifest.json", .{}) catch return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(store);
    var it: tcl.Interp = undefined;
    try it.init(a);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.vm) | @backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.file));
    try tcl.fsroot.setRoot(&it, "zig-out");
    it.vm_host.image_store = store;
    const ev = struct {
        fn f(x: *tcl.Interp, s: []const u8) ![]const u8 {
            const v = x.eval(s) catch |e| {
                std.debug.print("tcl error: {s}\n", .{x.str(x.result) catch ""});
                return e;
            };
            return x.str(v);
        }
    }.f;
    try std.testing.expectEqualStrings("ztcl-guest-test", try ev(&it, "dict get [ztcl::vm image install /vm-image-test] name"));
    _ = try ev(&it, "set v [ztcl::vm create -image ztcl-guest-test -memory 256]; ztcl::vm start $v");
    // The agent of the image answers its probe, then runs a program of
    // the root: a squashfs on dm-verity over the first disk.
    _ = try ev(&it, "set ch [ztcl::vm vsock $v 1025 -timeout 15000]; read $ch 16; close $ch");
    const mounts = try ev(&it, "dict get [ztcl::vm exec $v /bin/busybox cat /proc/mounts] stdout");
    try std.testing.expect(std.mem.indexOf(u8, mounts, "/dev/root / squashfs ro") != null);
    const cmdline = try ev(&it, "dict get [ztcl::vm exec $v /bin/busybox cat /proc/cmdline] stdout");
    try std.testing.expect(std.mem.indexOf(u8, cmdline, "verity") != null);
    _ = try ev(&it, "ztcl::vm stop $v; ztcl::vm delete $v");
    // The pool: a guest of the pool is paused at its create, booted to the
    // agent, and the refill of the first create boots it.
    it.vm_host.pool_size = 1;
    var from_pool = false;
    var k: usize = 0;
    while (k < 100 and !from_pool) : (k += 1) {
        _ = try ev(&it, "set v [ztcl::vm create -image ztcl-guest-test -memory 256]");
        from_pool = std.mem.eql(u8, try ev(&it, "ztcl::vm status $v"), "paused");
        if (!from_pool) {
            _ = try ev(&it, "ztcl::vm delete $v");
            tcl.proc.sleepMs(100);
        }
    }
    try std.testing.expect(from_pool);
    _ = try ev(&it, "ztcl::vm start $v; set ch [ztcl::vm vsock $v 1025 -timeout 15000]; read $ch 16; close $ch");
    try std.testing.expectEqualStrings("0", try ev(&it, "dict get [ztcl::vm exec $v /bin/busybox true] exit"));
    _ = try ev(&it, "ztcl::vm stop $v; ztcl::vm delete $v");
}

test "ztcl::vm: the capability, the jail of its paths, and the limits" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try std.testing.expectEqualStrings("0", try it.str(try it.eval("llength [info commands ztcl::vm]")));
    try it.allow(@backingInt(tcl.interp.Capability.vm) | @backingInt(tcl.interp.Capability.interp));
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("llength [info commands ztcl::vm]")));
    // A child interp has no `vm`, so the limits count the guests of one
    // interpreter.
    try std.testing.expectEqualStrings("0", try it.str(try it.eval("interp create k; k eval {llength [info commands ztcl::vm]}")));
    const builtin = @import("builtin");
    const on_kvm = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;
    const on_whp = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64;
    if (builtin.os.tag != .macos and !on_kvm and !on_whp) {
        try std.testing.expectEqualStrings("ZTCL VM UNAVAILABLE", try it.str(try it.eval("catch {ztcl::vm create -kernel Image}; set ::errorCode")));
        return;
    }
    if (on_kvm) {
        // A host without access to /dev/kvm gives the fix in the error.
        @import("kvm.zig").probe() catch {
            try std.testing.expectEqualStrings("ZTCL VM UNAVAILABLE", try it.str(try it.eval("catch {ztcl::vm create -kernel Image}; set ::errorCode")));
            return;
        };
    }
    if (on_whp) {
        // A host with no hypervisor gives the fix in the error.
        @import("whp.zig").probe() catch {
            try std.testing.expectEqualStrings("ZTCL VM UNAVAILABLE", try it.str(try it.eval("catch {ztcl::vm create -kernel Image}; set ::errorCode")));
            return;
        };
    }
    try std.testing.expectEqualStrings("ZTCL VM KERNEL", try it.str(try it.eval("catch {ztcl::vm create}; set ::errorCode")));
    try std.testing.expectEqualStrings("ZTCL VM NOFILE", try it.str(try it.eval("catch {ztcl::vm create -kernel Image}; set ::errorCode")));
    try std.testing.expectEqualStrings("ZTCL VM LIMIT", try it.str(try it.eval("catch {ztcl::vm create -cpus 5}; set ::errorCode")));
    try std.testing.expectEqualStrings("ZTCL VM LIMIT", try it.str(try it.eval("catch {ztcl::vm create -memory 4096}; set ::errorCode")));
    try std.testing.expectEqualStrings("ZTCL VM NAME", try it.str(try it.eval("catch {ztcl::vm start vm9}; set ::errorCode")));

    try it.allow(@backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.file));
    try tcl.fsroot.setHost(&it);
    _ = try it.eval("file mkdir .zig-cache/ztcl-vm-test/share; close [open .zig-cache/ztcl-vm-test/Image w]");
    try tcl.fsroot.setRoot(&it, ".zig-cache/ztcl-vm-test");
    try std.testing.expectEqualStrings("POSIX EACCES {permission denied}", try it.str(try it.eval("catch {ztcl::vm create -kernel ../../build.zig}; set ::errorCode")));
    if (on_kvm or on_whp) {
        {
            try std.testing.expectEqualStrings("-image gives the kernel, the initramfs, and the command line: no -kernel, -initrd, or -cmdline with it", try it.str(try it.eval("catch {ztcl::vm create -image x -kernel Image} m; set m")));
            // A share is a folder below the root folder.
            _ = try it.eval("ztcl::vm delete [ztcl::vm create -kernel Image -share {share /mnt rw}]");
            try std.testing.expectEqualStrings("ENOTDIR", try it.str(try it.eval("catch {ztcl::vm create -kernel Image -share {Image /mnt}}; lindex $::errorCode 1")));
        }
        try std.testing.expectEqualStrings("bad mode \"rx\": must be ro or rw", try it.str(try it.eval("catch {ztcl::vm create -kernel Image -disk {Image rx}} m; set m")));
        // An empty kernel fails at the start, and the guest stays.
        _ = try it.eval("set v [ztcl::vm create -kernel Image]");
        try std.testing.expectEqualStrings("ZTCL VM KERNEL", try it.str(try it.eval("catch {ztcl::vm start $v}; set ::errorCode")));
        try std.testing.expectEqualStrings("created", try it.str(try it.eval("ztcl::vm status $v")));
        _ = try it.eval("ztcl::vm delete $v");
        return;
    }
    try std.testing.expectEqualStrings("bad mode \"rx\": must be ro or rw", try it.str(try it.eval("catch {ztcl::vm create -kernel Image -share {share /mnt rx}} m; set m")));
    // The test program has no entitlement for the framework.
    try std.testing.expectEqualStrings("ZTCL VM ENTITLEMENT", try it.str(try it.eval("catch {ztcl::vm create -kernel Image -share {share /mnt}}; set ::errorCode")));
}

fn isoSpawn(_: ?*anyopaque) ?tcl.isothread.Fd {
    if (comptime @import("builtin").os.tag == .windows) {
        // An overlapped pipe pair, as the sandbox makes it.
        const ends = @import("isolate_windows.zig").pipePair(std.heap.page_allocator) catch return null;
        const t = tcl.isoproto.Transport.init(ends.child) catch return null;
        const th = std.Thread.spawn(.{}, isoChild, .{t}) catch return null;
        th.detach();
        return ends.parent;
    }
    var fds: [2]i32 = undefined;
    if (@import("builtin").os.tag == .linux) {
        const l = std.os.linux;
        if (l.errno(l.socketpair(l.AF.UNIX, l.SOCK.STREAM, 0, &fds)) != .SUCCESS) return null;
    } else if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return null;
    const t = tcl.isoproto.Transport.init(fds[1]) catch return null;
    const th = std.Thread.spawn(.{}, isoChild, .{t}) catch return null;
    th.detach();
    return fds[0];
}

fn isoChild(t: tcl.isoproto.Transport) void {
    _ = tcl.isothread.childMain(std.heap.page_allocator, t, .{});
}

test "isolated threads: send, results, errors, exit, and names across the protocol" {
    if (comptime !tcl.isothread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.iso_spawn = .{ .spawn = isoSpawn };
    try it.allow(@backingInt(tcl.interp.Capability.thread));
    _ = try it.eval("set t [thread::create -isolation process -joinable {proc sq x {expr {$x*$x}}; thread::wait}]");
    try std.testing.expectEqualStrings("144", try it.str(try it.eval("thread::send $t {sq 12}")));
    try std.testing.expectEqualStrings("a {b c} 3", try it.str(try it.eval("thread::send $t {list a {b c} 3}")));
    // The kinds cross: an integer stays an integer.
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("string is wide -strict [thread::send $t {expr {2**62}}]")));
    try std.testing.expectEqualStrings("boom {MY CODE}", try it.str(try it.eval("catch {thread::send $t {error boom {} {MY CODE}}} m o; list $m [dict get $o -errorcode]")));
    try std.testing.expectEqualStrings("1", try it.str(try it.eval("expr {$t in [thread::names]}")));
    // A send of the child to the parent, and its answer.
    try std.testing.expectEqualStrings("42", try it.str(try it.eval("thread::send $t [list thread::send [thread::id] {set ::back 42}]; set ::back")));
    _ = try it.eval("thread::release $t");
    try std.testing.expectEqualStrings("0", try it.str(try it.eval("thread::join $t")));
    try std.testing.expectEqualStrings("3", try it.str(try it.eval("thread::join [thread::create -isolation process -joinable {thread::exit 3}]")));
    try std.testing.expectEqualStrings("ZTCL ISOLATION LEVEL", try it.str(try it.eval("catch {thread::create -isolation vm {}}; set ::errorCode")));
    try std.testing.expectEqualStrings("bad isolation level \"x\": must be interp, process, or vm", try it.str(try it.eval("catch {thread::create -isolation x {}} m; set m")));
}

test "isolated threads: tsv and the locks through the broker" {
    if (comptime !tcl.isothread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.iso_spawn = .{ .spawn = isoSpawn };
    try it.allow(@backingInt(tcl.interp.Capability.thread));
    _ = try it.eval("tsv::set a x 1; tsv::set a l {1 2}; set t [thread::create -isolation process -joinable {thread::wait}]");
    try std.testing.expectEqualStrings("6 6", try it.str(try it.eval("list [thread::send $t {tsv::incr a x 5}] [tsv::get a x]")));
    try std.testing.expectEqualStrings("3", try it.str(try it.eval("thread::send $t {tsv::lappend a l 3; tsv::llength a l}")));
    try std.testing.expectEqualStrings("no key a(no)", try it.str(try it.eval("thread::send $t {catch {tsv::get a no} m; set m}")));
    try std.testing.expectEqualStrings("12", try it.str(try it.eval("thread::send $t {tsv::lock a {tsv::set a y [expr {[tsv::get a x] * 2}]}}; tsv::get a y")));
    try std.testing.expectEqualStrings("16", try it.str(try it.eval("thread::send $t {[tsv::object a x] incr 10}")));
    // A mutex that the child holds at its end goes free.
    _ = try it.eval("set m [thread::mutex create]; thread::send $t \"thread::mutex lock $m\"; thread::release $t; thread::join $t");
    try std.testing.expectEqualStrings("ok", try it.str(try it.eval("thread::mutex lock $m; thread::mutex unlock $m; set _ ok")));
}

test "isolated threads: thread::transfer moves a channel across the processes" {
    if (comptime !tcl.isothread.supported) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.iso_spawn = .{ .spawn = isoSpawn };
    try it.allow(@backingInt(tcl.interp.Capability.thread) | @backingInt(tcl.interp.Capability.file) | @backingInt(tcl.interp.Capability.channels));
    try tcl.fsroot.setRoot(&it, root);
    _ = try it.eval("set w [open d.txt w]; puts $w one\\ntwo\\nthree; close $w");
    _ = try it.eval("set t [thread::create -isolation process -joinable {thread::wait}]; set f [open d.txt]; gets $f");
    if (comptime !tcl.isothread.moves_channels) {
        try std.testing.expectEqualStrings("ZTCL ISOLATION TRANSFER", try it.str(try it.eval("catch {thread::transfer $t $f}; set ::errorCode")));
        try std.testing.expectEqualStrings("two", try it.str(try it.eval("gets $f")));
        return;
    }
    // The buffered input goes along with the descriptor.
    try std.testing.expectEqualStrings("0 two", try it.str(try it.eval("thread::transfer $t $f; list [expr {$f in [file channels]}] [thread::send $t \"gets $f\"]")));
    try std.testing.expectEqualStrings("three", try it.str(try it.eval("thread::send $t \"thread::transfer [thread::id] $f\"; gets $f")));
    _ = try it.eval("close $f; thread::release $t; thread::join $t");
}

test "isolated threads: no runner gives an error" {
    if (comptime !tcl.isothread.supported or !tcl.isothread.spawns_runner) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.thread));
    try std.testing.expectEqualStrings("ZTCL ISOLATION RUNNER", try it.str(try it.eval("catch {thread::create -isolation process {}}; set ::errorCode")));
}

test "isolated threads: a creator in host mode with files gets an error" {
    if (comptime !tcl.isothread.supported or !tcl.isothread.spawns_runner) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.iso_runner = "ztcl";
    try it.allow(@backingInt(tcl.interp.Capability.thread) | @backingInt(tcl.interp.Capability.file));
    try tcl.fsroot.setHost(&it);
    try std.testing.expectEqualStrings("ZTCL ISOLATION HOSTFILES", try it.str(try it.eval("catch {thread::create -isolation process {}}; set ::errorCode")));
    try std.testing.expectEqualStrings("host file mode is not available in an isolated thread: give the thread a root folder, or pass -files host", try it.str(try it.eval("catch {thread::create -isolation process {}} m; set m")));
    try std.testing.expectEqualStrings("bad files mode \"x\": must be host or root", try it.str(try it.eval("catch {thread::create -isolation process -files x {}} m; set m")));
    try std.testing.expectEqualStrings("-files host needs -isolation process", try it.str(try it.eval("catch {thread::create -files host {}} m; set m")));
    // A creator with a root folder has no files of the host to give.
    try tcl.fsroot.setRoot(&it, ".zig-cache");
    try std.testing.expectEqualStrings("-files host needs a creator in host mode", try it.str(try it.eval("catch {thread::create -isolation process -files host {}} m; set m")));
}

test "vm: the image releases, the highest version first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\[{"tag_name":"vm-image-v2","draft":false},{"tag_name":"v0.9.0","draft":false},
        \\ {"tag_name":"vm-image-v10","draft":false},{"tag_name":"vm-image-v11","draft":true},
        \\ {"tag_name":"vm-image-v1.5"},{"tag_name":"vm-image-vx"},{"tag_name":"vm-image-latest"},{"name":"no tag"}]
    ;
    const tags = try @import("microvm.zig").imageTags(arena.allocator(), json);
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("vm-image-v10", tags[0]);
    try std.testing.expectEqualStrings("vm-image-v2", tags[1]);
    try std.testing.expectEqualStrings("vm-image-v1.5", tags[2]);
    try std.testing.expectEqual(@as(usize, 0), (try @import("microvm.zig").imageTags(arena.allocator(), "[]")).len);
    try std.testing.expectError(error.NotList, @import("microvm.zig").imageTags(arena.allocator(), "{}"));
}
