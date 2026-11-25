// The example scripts of the playground.
// SPDX-License-Identifier: BSD-2-Clause
export const presets = [
  {
    name: "Hello",
    code: `puts "Hello from ztcl [info patchlevel]"
set who WebAssembly
puts "This script runs in $who, in a Web Worker."
expr {6 * 7}
`,
  },
  {
    name: "Fibonacci",
    code: `proc fib {n} {
    if {$n < 2} { return $n }
    expr {[fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]}
}
foreach n {5 10 15 20 25} {
    puts "fib $n = [fib $n]"
}
`,
  },
  {
    name: "Endless loop (step limit)",
    code: `# This loop never ends. The step limit stops it.
# Each loop pass uses steps. Set a larger limit, or click Stop.
set i 0
while 1 {
    incr i
}
`,
  },
  {
    name: "Memory bomb (memory limit)",
    code: `# The string doubles on each pass.
# The memory limit stops the script, and catch cannot catch the error.
set s x
catch {
    while 1 {
        append s $s
        puts "[string length $s] bytes"
    }
}
puts "this line does not run"
`,
  },
  {
    name: "Strings and lists",
    code: `set words [split "the quick brown fox jumps over the lazy dog"]
puts "words:    [llength $words]"
puts "sorted:   [lsort -unique $words]"
puts "lengths:  [lmap w $words {string length $w}]"
puts "upper:    [string toupper [lindex $words end]]"
puts "reversed: [lreverse $words]"
puts [format "%-8s|%5.2f|%x" ztcl 3.14159 255]
regexp {(\\w+) (\\w+)$} [join $words] -> a b
puts "last two: $a $b"
`,
  },
  {
    name: "Dicts",
    code: `set stock [dict create apple 3 pear 0 plum 12]
dict incr stock apple 2
dict set stock fig 7
dict for {fruit n} $stock {
    puts [format "%-6s %3d" $fruit $n]
}
puts "in stock: [dict keys [dict filter $stock script {k v} {expr {$v > 0}}]]"
puts "total:    [tcl::mathop::+ {*}[dict values $stock]]"
`,
  },
  {
    name: "Threads (a pool and tsv)",
    code: `# Four worker threads count the primes below 40000.
# Each thread has its own interpreter in its own Web Worker.
# This needs a cross-origin isolated page. The service worker of the
# playground makes the page isolated.
proc isprime {n} {
    if {$n < 2} { return 0 }
    for {set d 2} {$d * $d <= $n} {incr d} {
        if {$n % $d == 0} { return 0 }
    }
    return 1
}
set pool [tpool::create -maxworkers 4 -initcmd [list proc isprime {n} [info body isprime]]]
set jobs {}
foreach a {0 10000 20000 30000} {
    lappend jobs [tpool::post $pool [string map [list A $a] {
        set c 0
        for {set i A} {$i < A + 10000} {incr i} {
            if {[isprime $i]} { incr c }
        }
        tsv::incr counts primes $c
        list [thread::id] $c
    }]]
}
foreach j $jobs {
    tpool::wait $pool $j
    lassign [tpool::get $pool $j] id n
    puts "job $j in $id: $n primes"
}
tpool::release $pool
puts "total: [tsv::get counts primes]"
`,
  },
];
