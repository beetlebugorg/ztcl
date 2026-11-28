# Variables and math

Each value in Tcl is a string. A command that needs a number reads the string as a number. This lesson gives `jot` a count of its notes, and shows the math traps that an agent puts in code.

<!-- checkpoint -->
```tcl
set note "buy milk"
```

## Variables

`set` with two words gives a value to a variable. `set` with one word gives the value back: [`set note`](run: "buy milk"). A variable that has no value is an error: [`set count`](run: "error: can't read \"count\": no such variable"). [`info exists count`](run: "0") checks first.

`incr` adds to an integer, and makes the variable with 0 first when it has no value. [`incr count`](run: "1") counts the first note. [`incr count 2`](run: "3") adds 2, and [`incr count -1`](run: "2") takes 1 away. `append` adds text: [`append note " and eggs"`](run: "buy milk and eggs").

## Math with expr

`expr` computes an expression. It has the operators of C, `**` for a power, and functions such as `abs`, `round`, and `max`. [`expr {$count * 10}`](run: "20") uses the variable. Integers have no fixed size: [`expr {2 ** 64}`](run: "18446744073709551616").

The type of the result comes from the operands. An integer divided by an integer is an integer: [`expr {7 / 2}`](run: "3"). One float operand makes a float: [`expr {7 / 2.0}`](run: "3.5"). Integer division rounds down, also for a negative number: [`expr {-7 / 2}`](run: "-4"). In C and in Go the result is -3.

A string that is a number works as a number: [`expr {"10" + 1}`](run: "11"). Another string is an error: [`expr {"ten" + 1}`](run: "error: cannot use non-numeric string \"ten\" as left operand of \"+\"").

## Compare numbers and strings

`==` compares two numbers when both are numbers: [`expr {"1.0" == "1"}`](run: "1"). `eq` compares the text: [`expr {"1.0" eq "1"}`](run: "0"). Use `eq` and `ne` for strings. `==` on two strings that look like numbers gives a number comparison.

## Reading code an agent wrote

- Each `expr` has braces. A value from input never goes into `expr` without them.
- A division of two integers gives an integer. Look for `/` where the code needs a fraction, and for a negative operand.
- Strings are compared with `eq` and `ne`, and numbers with `==` and `<`.
- `incr` is on a variable that holds an integer.

## Ask an agent

> Write a Tcl proc that gives the average of a list of numbers as a float. Put each `expr` in braces.

Check that the answer divides by a float or uses `double()`, and that an empty list gives an error with a clear message.

## Try this

- Make `expr {7 / 2}` give 3.5 with `double()`.
- Find which of `expr {"01" == "1"}` and `expr {"01" eq "1"}` is true.
- Run `incr note`, and read the error.
