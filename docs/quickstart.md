# Quick start

[Install](install.md) ztcl first, or open the [playground](https://beetlebug.org/ztcl/playground/) to run Tcl in your browser.

## Run a script

Save this file as `sum.tcl`:

<!-- live -->
```tcl
proc sum {n} {
    set total 0
    for {set i 0} {$i < $n} {incr i} {
        incr total $i
    }
    return $total
}
puts [sum 10000000]
```

```sh
$ ztcl sum.tcl                       # with the JIT
49999995000000
$ ztcl --no-jit sum.tcl              # the same result, about 10 times as slow
49999995000000
```

Run `ztcl` with no file to start the [interactive shell](shell.md).

## Set limits

A script from a user or from the network can loop forever or fill the memory. Set a compute limit, and a memory limit in bytes. `hog.tcl` is the line `set l {}; while 1 {lappend l [string repeat x 1000]}`.

```sh
$ ztcl --compute 1000 sum.tcl
sum.tcl:3: compute limit reached
$ ztcl --mem 67108864 hog.tcl
hog.tcl:1: the script used too much memory
```

`catch` and `try` cannot catch the compute limit. The default memory limit of the runner is 2 GiB.

## Turn on host access

A script has no file, socket, clock, or process command by default. Turn on each one with `--allow`. The file commands use the real paths of the host, as in tclsh. `--root DIR` keeps them inside one folder, which a script sees as `/`.

```tcl
set f [open data/hello.txt w]
puts $f "hello from ztcl"
close $f
set f [open data/hello.txt]
puts [read -nonewline $f]
close $f
```

```sh
$ ztcl files.tcl
files.tcl:1: invalid command name "open"
$ ztcl --allow channels,file --root . files.tcl
hello from ztcl
```

[Limits and capabilities](limits.md) lists each capability.

## Read JSON

<!-- live -->
```tcl
package require ztcl::json
set d [ztcl::json parse {{"name": "ztcl", "tags": ["tcl", "zig"]}}]
puts [dict get $d name]
puts [ztcl::json encode -schema {object {name string stars int}} {name ztcl stars 43}]
```

```sh
$ ztcl json.tcl
ztcl
{"name":"ztcl","stars":43}
```

## Next steps

- [The language](language.md): what works and what differs from Tcl 8.6.
- [Embed in Zig](embedding.md) or [in a web page](webassembly.md).
- [Threads](threads.md) and [the JIT](jit.md).
