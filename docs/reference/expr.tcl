# Converted by tools/refdoc.tcl convert from math.txt.

command expr {
    area math
    since TODO
    synopsis {expr arg ?arg ...?}
    summary {Computes an expression with the operators of C and the math functions.}
    description {Computes an expression with the operators of C and the math functions. Put the expression in braces: then `expr` does its own substitution, a value from a variable stays a value, and the expression is compiled once. Integers have no fixed size. An integer divided by an integer is an integer, rounded down.}
    difference {The operators `eq`, `ne`, `in`, and `ni` compare strings and lists, as in Tcl 8.6.}
    example {expr {2 ** 100}} 1267650600228229401496703205376
    example {expr {7 / 2}} 3
    example {expr {-7 / 2}} -4
    example {expr {7 / 2.0}} 3.5
    example {expr {"a" eq "a" ? "same" : "other"}} same
    example {expr {5 in {1 5 9}}} 1
    error {expr {1 / 0}} {divide by zero} {ARITH DIVZERO {divide by zero}}
    error {expr {"ten" + 1}} {can't use non-numeric string as operand of "+"} {ARITH DOMAIN {non-numeric string}}
}
