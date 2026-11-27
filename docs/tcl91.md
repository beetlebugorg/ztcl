# Tcl 9.1

ztcl follows Tcl 8.6 by default, and it can follow Tcl 9.1. An interpreter follows one release. The commands that differ between the releases read the release of the interpreter.

Tcl 8.6 is the default because most published Tcl code targets it: tcllib, tklib, and the packages with C modules. Tcl 9 changes behavior that some of this code depends on, such as encodings, octal numbers, and variable lookup in namespaces.

## Choose the release

| Where | How |
|---|---|
| The runner | `ztcl --tcl 9.1 script.tcl` |
| Zig | `try it.setTclVersion(.v9_1);` before the first script |
| WebAssembly | `Interp.create({ tcl: "9.1" })` in `web/ztcl.mjs`, or `ztcl_set_tcl_version` |
| A child interpreter | `interp create -tcl 9.1 child` |

A child interpreter and a thread start with the release of their parent. `info tclversion`, `info patchlevel`, `$tcl_version`, `$tcl_patchLevel`, and `package provide Tcl` give `8.6` and `8.6.16`, or `9.1` and `9.1.0`.

<!-- run -->
```tcl
list [info tclversion] [info patchlevel]
```

## What changes with 9.1

### Commands and subcommands

These commands and subcommands exist only in Tcl 9.1. In 8.6 they are absent, as in tclsh 8.6.

- `lseq`, `lpop`, `lremove`, `ledit`, and `lfilter`.
- The option `-integer` of `switch`.
- `string insert`, the class `dict` of `string is`, `dict getdef` and `dict getwithdefault`, and `array for`.
- `encoding profiles`, `encoding user`, and the options `-profile` and `-failindex` of `encoding convertfrom` and `encoding convertto`.
- The channel option `-profile`.

`string bytelength` is absent in 9.1, as in tclsh 9.1.0. The error message of a bad subcommand lists the subcommands of the release.

The [command reference](reference/README.md) marks each command and subcommand of one release.

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

## What is not done

These parts of Tcl 9.1 are not in ztcl yet. A script that uses them gets an error, or the behavior of 8.6. [The TIP survey](dev/tips.md) lists each TIP and its issue.

- The commands `const`, `timer`, `unicode`, `tcl::process`, `coroinject`, `coroprobe`, `divmod`, `fpclassify`, `frexp`, `modf`, and `remquo`.
- `array default`, `info cmdtype`, `info constant`, `info consts`, `interp set`, `chan isbinary`, `file home`, `file tildeexpand`, `file tempdir`, `clock monotonic`, and `package files`.
- The option `-stride` of `lsearch`, and the options `-backslashes`, `-commands`, and `-variables` of `subst`.
- The new math functions of 9.1, such as `trunc()` and `log2()`.
- The operators `lt`, `le`, `gt`, and `ge` of `expr`, and the number forms `0d10` and `1_000`.
- The removal of the old forms of `trace` (`variable`, `vdelete`, `vinfo`).
- The changes of `format` for 64-bit values, such as `format %x -1`, and integers above 64 bits in `string is integer`.
- The zipfs subcommands that 9.1 adds to the ones that ztcl has.
- C modules for Tcl 9. The stubs table of Tcl 9 differs from the table of 8.6, and the loader of C modules supports only 8.6.
- A list index above 2^31. Lists and strings of ztcl have 64-bit sizes, and an index in a list command still has 32 bits.

## Test results

`tools/suite.sh -t core-9-1-0` runs the test files of Tcl 9.1.0 with `--tcl 9.1`. [The suite results](dev/suite.md) have the counts of both releases.
