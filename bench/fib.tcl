# SPDX-License-Identifier: BSD-2-Clause
# Fibonacci 25 by plain recursion: about 250 000 calls.
proc fib {n} {
    if {$n < 2} { return $n }
    return [expr {[fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]}]
}
puts [fib 25]
