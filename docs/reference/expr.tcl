# The command reference: expr. The format is in
# docs/dev/reference-format.md.

command expr {
    area math
    since 1.0.0-beta.1
    synopsis {expr ARG ?ARG ...?}
    summary {Computes an expression with the operators of C and the math functions.}
    description {
        Joins the ARG words with spaces, reads the result as an expression, and gives its value. An expression has numbers, strings in quotes or braces, variables, command substitutions in brackets, operators, parentheses, and calls of math functions such as `sqrt(2)`.

        Put the expression in braces: `expr {$a * 2}`. Then `expr` does the substitution of variables and commands itself, a value from a variable stays one operand, and the expression is compiled once. With no braces, the parser of Tcl substitutes first, so `set a {1 + 1}; expr $a * 2` computes `1 + 1 * 2`.

        An integer has no fixed size: `2 ** 100` is exact. An integer divided by an integer is an integer rounded down, and `%` has the sign of the divisor. An operation with a double gives a double. An operation with no numeric result, such as `0.0 / 0` or `Inf - Inf`, is a domain error. A string compares as a number with `<` and `==` when both operands are numbers, and as text when one is not. `eq` and `ne` always compare the text.

        `&&`, `||`, and `?:` read their operands only as far as they need: `expr {0 && [error x]}` gives 0 and runs no command.

        The number forms are integers in decimal, `0x` hex, `0o` octal, and `0b` binary, and doubles such as `1.5`, `.5`, `1e3`, `Inf`, and `-Inf`. The values `true`, `false`, `yes`, `no`, `on`, and `off` are booleans for `!`, `&&`, `||`, and `?:`.
    }
    returns {The value of the expression: an integer, a double, a boolean as 0 or 1, or a string.}
    see {incr tcl::mathfunc tcl::mathop {string is} if while for}
    release {In Tcl 8.6 an integer with a leading zero, such as `010`, is octal (8). In Tcl 9.1 it is decimal (10), and only `0o10` is octal.}
    release {Tcl 9.1 has the string comparison operators `lt`, `le`, `gt`, and `ge`, the prefix `0d` of decimal integers, and `_` between the digits of a number, such as `1_000`.}
    difference {In Tcl 9.0.4 the message of an operand of the wrong type names the operand and its side, such as `cannot use non-numeric string "ten" as left operand of "+"`. ztcl gives the message of Tcl 8.6 in both releases ([issue 680](https://github.com/beetlebugorg/ztcl/issues/680)).}
    difference {A variable with no value has `-errorcode NONE`, where Tcl 8.6.16 and 9.0.4 give `TCL LOOKUP VARNAME` ([issue 658](https://github.com/beetlebugorg/ztcl/issues/658)).}
    argument ARG {
        type expression
        repeats
        summary {A part of the expression, joined to the other parts with spaces.}
        choice {- + ~ !} {Unary minus, plus, bitwise not, and logical not. The highest precedence.}
        choice ** {Power. It groups from the right: `2 ** 3 ** 2` is `2 ** 9`.}
        choice {* / %} {Multiply, divide, and remainder.}
        choice {+ -} {Add and subtract.}
        choice {<< >>} {Shift left and right.}
        choice {< > <= >=} {Compare as numbers, or as text when an operand is not a number.}
        choice {lt gt le ge} {Compare as text.} -tcl 9.1
        choice {== !=} {Equal and not equal, as numbers when both are numbers.}
        choice {eq ne} {Equal and not equal as text.}
        choice {in ni} {The left operand is, or is not, an element of the list on the right.}
        choice & {Bitwise and.}
        choice ^ {Bitwise exclusive or.}
        choice | {Bitwise or.}
        choice && {Logical and: the right operand runs only when the left one is true.}
        choice || {Logical or: the right operand runs only when the left one is false.}
        choice ?: {If then else: `a ? b : c`. The lowest precedence.}
    }
    example {expr {2 ** 100}} 1267650600228229401496703205376
    example {expr {7 / 2}} 3
    example {expr {-7 / 2}} -4
    example {expr {7 % -2}} -1
    example {expr {7 / 2.0}} 3.5
    example {expr {"a" eq "a" ? "same" : "other"}} same
    example {expr {5 in {1 5 9}}} 1
    example {expr {"1" == "1.0"}} 1
    example {expr {"1" eq "1.0"}} 0
    example {expr {2 ** 3 ** 2}} 512
    example {expr {0x10 + 0b101}} 21
    example {expr {1.0 / 0}} Inf
    example {expr {0 && [error never]}} 0
    example {expr {abs(-3) + max(1, 5)}} 8
    example {expr {1 + 2} {* 3}} 7
    example {
        set a {1 + 1}
        expr $a * 2
    } 3 -note {With no braces, the value of a is a part of the expression.}
    example {expr {010}} 8 -tcl 8.6
    example {expr {010}} 10 -tcl 9.1
    example {expr {1_000 + 1}} 1001 -tcl 9.1
    example {expr {"a" lt "b"}} 1 -tcl 9.1
    error {expr {1 / 0}} {divide by zero} {ARITH DIVZERO {divide by zero}}
    error {expr {0.0 / 0}} {domain error: argument not in valid range} {ARITH DOMAIN {domain error: argument not in valid range}}
    error {expr {"ten" + 1}} {can't use non-numeric string as operand of "+"} {ARITH DOMAIN {non-numeric string}}
    error {expr {7.0 % 2}} {can't use floating-point value as operand of "%"} {ARITH DOMAIN {floating-point value}}
    error {expr {0 ** -1}} {exponentiation of zero by negative power} {ARITH DOMAIN {exponentiation of zero by negative power}}
    error {expr {(1 + 2}} "unbalanced open paren\nin expression \"(1 + 2\"" {TCL PARSE EXPR UNBALANCED}
    error {expr {nosuchfunc(1)}} {invalid command name "tcl::mathfunc::nosuchfunc"} {TCL LOOKUP COMMAND tcl::mathfunc::nosuchfunc}
    error {expr} {wrong # args: should be "expr arg ?arg ...?"} {TCL WRONGARGS}
}
