# Tcl 9.1 and Tcl 8.6

ztcl follows Tcl 9.1 by default, and it can follow Tcl 8.6. An interpreter follows one release. The commands that differ between the releases read the release of the interpreter.

The default is 9.1 for the `ztcl` runner, the programs of `ztcl build`, the WebAssembly builds, and the hosts of `ztcl::wasm package`. libztcl, the drop-in `libtcl8.6`, stays at 8.6: a C program built for the API of 8.6, such as NaviServer or Python `_tkinter`, gets an interpreter of 8.6 from `Tcl_CreateInterp`.

## Run 8.6 code

Much published Tcl code targets 8.6: tcllib, tklib, and the packages with C modules. Most of it runs on 9.1 unchanged. A script that depends on the behavior of 8.6, such as octal numbers, the encoding of bad bytes, or variable lookup in namespaces, runs with the release 8.6:

| Where | How |
|---|---|
| The runner | `ztcl --tcl 8.6 script.tcl` |
| The environment | `ZTCL_TCL=8.6 ztcl script.tcl`. `--tcl` wins over it. |
| A program of `ztcl build` | `ztcl build --tcl 8.6 -o app script.tcl`, also with `--wasm` and `--strip` |
| Zig | `try it.setTclVersion(.v8_6);` before the first script. `Interp.init` gives 8.6. |
| WebAssembly | `Interp.create(module, { tcl: "8.6" })` in `web/ztcl.mjs`, or `ztcl_set_tcl_version` |
| A child interpreter | `interp create -tcl 8.6 child` |

`--tcl 9.1` and `-tcl 9.1` still work. A child interpreter and a thread start with the release of their parent, and so does an isolated thread. `info tclversion`, `info patchlevel`, `$tcl_version`, `$tcl_patchLevel`, and `package provide Tcl` give `9.1` and `9.1.0`, or `8.6` and `8.6.16`.

<!-- run -->
```tcl
list [info tclversion] [info patchlevel]
```

The compute units of a script can differ between the releases, so a limit that `--compute` sets for one release can need a change for the other.

## What differs from 8.6

Each part below is a difference that can break a script of 8.6. The fix is a change to the script, or `--tcl 8.6`.

### Commands and subcommands

These commands and subcommands exist only in Tcl 9.1. In 8.6 they are absent, as in tclsh 8.6. A script of 8.6 that defines a proc of the same name, such as `lpop`, replaces the command.

- `lseq`, `lpop`, `lremove`, `ledit`, and `lfilter`.
- The option `-integer` of `switch`.
- The math functions of TIP 521 and TIP 745, such as `trunc()`, `log2()`, `isnan()`, and `signbit()`, and the commands `divmod`, `fpclassify`, `frexp`, `modf`, and `remquo`. The last digit of a function result can differ from tclsh 9.1.0, and the [reference](reference/README.md) lists the other differences.
- The option `-stride` of `lsearch`.
- `string insert`, the class `dict` of `string is`, `dict getdef` and `dict getwithdefault`, `array for`, and `array default`.
- `encoding profiles`, `encoding user`, and the options `-profile` and `-failindex` of `encoding convertfrom` and `encoding convertto`.
- The channel option `-profile`.

The error message of a bad subcommand lists the subcommands of the release.

The [command reference](reference/README.md) marks each command and subcommand of one release.

### Expressions

In 9.1 `expr` has the string order operators `lt`, `gt`, `le`, and `ge`, and a `#` starts a comment that runs to the end of the line:

```tcl
expr {"10" lt "9"}
# 1
expr {1 + # the base
      2}
# 3
```

A number can have `_` between two digits, and `0d` starts a decimal integer. These forms work in each command that reads a number:

| Script | 9.1 |
|---|---|
| `expr {1_000_000 + 1}` | 1000001 |
| `expr {0xff_ff}` | 65535 |
| `incr x 0d10` | 10 more |
| `string is double 1_0.5` | 1 |

### Encodings

In 9.1 the default encoding profile is `strict`. A byte that is not valid in the encoding is an error:

```tcl
encoding convertfrom utf-8 "a\xffb"
# error: unexpected byte sequence starting at index 1: '\xFF'
```

`-profile replace` puts U+FFFD for each bad byte, and `-profile tcl8` keeps the behavior of 8.6, where a bad byte is the character with the same value. `-failindex var` gives the text before the bad byte and puts the index of the byte in `var`, or -1.

A channel has the same profiles with `fconfigure $chan -profile`. With `strict`, a read of bad UTF-8 is an error: `error reading "file3": invalid or incomplete multibyte or wide character`, with the error code `POSIX EILSEQ`.

### Numbers

In 9.1 an integer with a leading zero is decimal, and only `0o` is octal:

| Script | 8.6 | 9.1 |
|---|---|---|
| `expr {010}` | 8 | 10 |
| `expr {0o10}` | 8 | 8 |
| `expr {08 + 1}` | error | 9 |
| `lindex {a b c d e f g h i j k} 010` | `i` | `k` |

The rule applies to each integer that a command reads, such as the arguments of `incr`, `lindex`, and `string is integer`.

### Variables in namespaces

In 9.1 a relative variable name in `namespace eval` refers only to the variable of the namespace. 8.6 also looks in the global namespace.

```tcl
set g 1
namespace eval q {set g}
# 8.6: 1
# 9.1: error: can't read "g": no such variable
```

A name with a namespace, such as `a::v`, also resolves only from the current namespace. A name that starts with `::` is the same in both releases.

### Other changes

- `glob` with no match gives an empty list in 9.1. In 8.6 it is an error unless `-nocomplain`.
- `tcl_precision` is absent in 9.1. A double has the shortest form that reads back as the same value.
- `string bytelength` is absent in 9.1.
- 9.1 has no tilde expansion. A path that starts with `~`, such as `~/notes.txt`, names a file in a folder `~`, not in `$env(HOME)`. Use `[file join $env(HOME) notes.txt]`.

## What is not done

These parts of Tcl 9.1 are not in ztcl yet. A script that uses them gets an error, or the behavior of 8.6, in both releases. [The TIP survey](dev/tips.md) lists each TIP and its issue.

- The commands `const`, `timer`, `unicode`, `tcl::process`, `coroinject`, and `coroprobe`.
- `info cmdtype`, `info constant`, `info consts`, `interp set`, `chan isbinary`, `file home`, `file tildeexpand`, `file tempdir`, `clock monotonic`, and `package files`.
- The options `-backslashes`, `-commands`, and `-variables` of `subst`.
- The removal of the old forms of `trace` (`variable`, `vdelete`, `vinfo`).
- The changes of `format` for 64-bit values, such as `format %x -1`, and integers above 64 bits in `string is integer`.
- The zipfs subcommands that 9.1 adds to the ones that ztcl has.
- C modules for Tcl 9. The stubs table of Tcl 9 differs from the table of 8.6, and the loader of C modules supports only 8.6. A C module for 8.6 loads in both releases: the loader gives it the table of 8.6.
- A list index above 2^31. Lists and strings of ztcl have 64-bit sizes, and an index in a list command still has 32 bits.

## Test results

`tools/suite.sh -t core-9-1-0` runs the test files of Tcl 9.1.0 with `--tcl 9.1`. [The suite results](dev/suite.md) have the counts of both releases.
