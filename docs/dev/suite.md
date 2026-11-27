# Tcl 8.6.16 suite results

`tools/suite-run.sh` makes this page with `tools/suite-md.py`. Do not edit it by hand. Run on 2026-11-27 at commit `776a777`, with the suite runner `zig-out/bin/ztcl-suite` (ReleaseSafe) on all 152 test files. `docs/dev/suite-tests.tsv` has one line for each test.

A test is applicable when it is outside the buckets `design`, `platform`, `internals`, and `tcl`. The goal of issue 244 is a pass for each applicable test.

## Totals

| Run | Total | Pass | Fail | Skip | Unreached |
|---|---|---|---|---|---|
| Interpreter | 47,133 | 38,036 | 2,634 | 4,337 | 2,126 |
| JIT (`-j`) | 47,133 | 38,035 | 2,635 | 4,337 | 2,126 |

Unreached is the test count of `tools/suite-scope.tsv` minus the tests that ran: the file stopped before them.

## Tcl 9.1.0

`tools/suite.sh -t core-9-1-0` runs the 37 core test files of Tcl 9.1.0 with `--tcl 9.1`. `docs/dev/suite-counts-9.tsv` has the pass count of each file, and the scheduled CI run checks them. The counts do not compare with the counts of 8.6.16: the files differ.

| Run | Pass |
|---|---|
| Interpreter | 11,165 |
| JIT (`-j`) | 11,165 |

## Buckets

The tests of the interpreter run that do not pass, by bucket.

| Bucket | Meaning | Tests |
|---|---|---|
| `bug` | A bug in ztcl | 1,049 |
| `feature` | A missing feature or option | 3,233 |
| `message` | An error message or -errorcode differs | 131 |
| `internals` | Needs Tcl internals (C test commands, memory debugging) | 3,254 |
| `design` | Absent by design | 439 |
| `platform` | Platform only | 736 |
| `tcl` | Skipped by tclsh too (knownBug, emptyTest, and others) | 255 |
| `untriaged` | Not triaged yet | 0 |

Applicable tests: 42,449. Pass rate of the applicable tests: 89.6 %.

## Reasons

The tests of the buckets `bug`, `feature`, `message`, and `untriaged`, by the reason of their rule in `tools/suite-buckets.tsv`.

| Bucket | Reason | Tests |
|---|---|---|
| `bug` | the result differs from tclsh 8.6.16 | 334 |
| `bug` | channels: the result differs | 143 |
| `bug` | namespaces: the result differs | 72 |
| `bug` | file names and 'glob': the result differs | 71 |
| `bug` | 'trace': the result differs | 66 |
| `bug` | 'clock': the result differs | 63 |
| `bug` | 'interp': the result differs | 58 |
| `bug` | TclOO: the result differs | 48 |
| `bug` | 'expr': the result differs | 38 |
| `bug` | 'binary': the result differs | 31 |
| `bug` | encodings: the result differs | 19 |
| `bug` | the setup or the cleanup of the test fails | 17 |
| `bug` | regular expressions: the match differs | 16 |
| `bug` | safe interpreters: hidden commands and their messages | 14 |
| `bug` | regular expressions: the error class of a bad pattern | 13 |
| `bug` | regular expressions: a valid pattern that ztcl does not compile | 11 |
| `bug` | the recursion limit and its message | 11 |
| `bug` | coroutines: the result differs | 10 |
| `bug` | the standard channels are not in the channel table | 8 |
| `bug` | 'info': the result differs | 6 |
| `feature` | the 'http' package | 2,063 |
| `feature` | a library package of Tcl: safe, msgcat, http, the package index, tcl::tm, or opt | 283 |
| `feature` | 'chan create', 'chan push', 'chan pop', 'chan pipe', 'chan truncate' | 196 |
| `feature` | 'info frame' | 166 |
| `feature` | the real 'tcltest' package; the suite runs a stand-in | 157 |
| `feature` | the 'zlib' command | 71 |
| `feature` | the 'interp' subcommands bgerror, cancel, debug, limit, share, and transfer | 59 |
| `feature` | a form of 'clock scan' that ztcl does not parse | 52 |
| `feature` | the REG_U flags of 'regexp -about' | 50 |
| `feature` | 'file attributes' | 43 |
| `feature` | the 'msgcat' package | 21 |
| `feature` | the 'safe' package | 15 |
| `feature` | the 'opt' package | 14 |
| `feature` | the slot classes of TclOO ('oo::Slot') | 12 |
| `feature` | 'tcl::pkgconfig' | 9 |
| `feature` | 'file mtime' and 'file atime' with a new time | 6 |
| `feature` | 'tcl::unsupported::inject' and 'corotype' | 6 |
| `feature` | 'info hostname', and '~' with no 'env(HOME)' | 5 |
| `feature` | 'info errorstack' | 3 |
| `feature` | the 'platform' package | 2 |
| `message` | an error where tclsh also gives one, with another message | 130 |
| `message` | the -errorcode differs | 1 |

## JIT differences

Tests with a different result in the JIT run. `socket.test`, `io.test`, and `chanio.test` have timing tests that can change between two runs of one mode.

| File | Test | Interpreter | JIT |
|---|---|---|---|
| chanio.test | chan-io-36.1 | pass | fail |
| socket.test | socket_inet-13.1 | pass | fail |
| socket.test | socket_inet-3.2 | fail | pass |

## Files

| File | Scope | Total | Pass | Fail | Skip | Unreached | JIT pass | JIT fail | JIT skip |
|---|---|---|---|---|---|---|---|---|---|
| aaa_exit.test | decide | 2 | 2 | 0 | 0 | 0 | 2 | 0 | 0 |
| append.test | in | 45 | 44 | 1 | 0 | 0 | 44 | 1 | 0 |
| appendComp.test | in | 48 | 42 | 1 | 5 | 0 | 42 | 1 | 5 |
| apply.test | in | 42 | 35 | 3 | 4 | 0 | 35 | 3 | 4 |
| assemble.test | na | 284 | 0 | 280 | 4 | 0 | 0 | 280 | 4 |
| assocd.test | na | 11 | 0 | 0 | 11 | 0 | 0 | 0 | 11 |
| async.test | na | 12 | 0 | 0 | 12 | 0 | 0 | 0 | 12 |
| autoMkindex.test | decide | 11 | 1 | 9 | 1 | 0 | 1 | 9 | 1 |
| basic.test | in | 146 | 100 | 12 | 34 | 0 | 100 | 12 | 34 |
| binary.test | in | 717 | 604 | 34 | 79 | 0 | 604 | 34 | 79 |
| case.test | in | 15 | 15 | 0 | 0 | 0 | 15 | 0 | 0 |
| chan.test | decide | 41 | 39 | 2 | 0 | 0 | 39 | 2 | 0 |
| chanio.test | decide | 777 | 330 | 59 | 388 | 0 | 329 | 60 | 388 |
| clock.test | decide | 8,532 | 8,402 | 120 | 7 | 3 | 8,402 | 120 | 7 |
| cmdAH.test | decide | 323 | 99 | 42 | 182 | 0 | 99 | 42 | 182 |
| cmdIL.test | in | 146 | 137 | 3 | 6 | 0 | 137 | 3 | 6 |
| cmdInfo.test | na | 12 | 0 | 0 | 12 | 0 | 0 | 0 | 12 |
| cmdMZ.test | in | 92 | 86 | 5 | 1 | 0 | 86 | 5 | 1 |
| compExpr-old.test | in | 190 | 183 | 0 | 7 | 0 | 183 | 0 | 7 |
| compExpr.test | in | 80 | 76 | 0 | 4 | 0 | 76 | 0 | 4 |
| compile.test | in | 171 | 96 | 64 | 11 | 0 | 96 | 64 | 11 |
| concat.test | in | 9 | 9 | 0 | 0 | 0 | 9 | 0 | 0 |
| config.test | decide | 9 | 0 | 9 | 0 | 0 | 0 | 9 | 0 |
| coroutine.test | in | 59 | 37 | 19 | 3 | 0 | 37 | 19 | 3 |
| dcall.test | na | 6 | 0 | 0 | 6 | 0 | 0 | 0 | 6 |
| dict.test | in | 342 | 317 | 23 | 2 | 0 | 317 | 23 | 2 |
| dstring.test | na | 44 | 0 | 0 | 44 | 0 | 0 | 0 | 44 |
| encoding.test | decide | 101 | 82 | 1 | 18 | 0 | 82 | 1 | 18 |
| env.test | decide | 26 | 8 | 14 | 4 | 0 | 8 | 14 | 4 |
| error.test | in | 317 | 300 | 9 | 8 | 0 | 300 | 9 | 8 |
| eval.test | in | 12 | 11 | 1 | 0 | 0 | 11 | 1 | 0 |
| event.test | decide | 66 | 35 | 2 | 29 | 0 | 35 | 2 | 29 |
| exec.test | decide | 100 | 87 | 4 | 9 | 0 | 87 | 4 | 9 |
| execute.test | in | 157 | 71 | 6 | 80 | 0 | 71 | 6 | 80 |
| expr-old.test | in | 460 | 433 | 11 | 16 | 0 | 433 | 11 | 16 |
| expr.test | in | 14,185 | 14,124 | 27 | 34 | 0 | 14,124 | 27 | 34 |
| fCmd.test | decide | 256 | 124 | 83 | 48 | 1 | 124 | 83 | 48 |
| fileName.test | decide | 300 | 58 | 61 | 176 | 5 | 58 | 61 | 176 |
| fileSystem.test | decide | 137 | 38 | 40 | 59 | 0 | 38 | 40 | 59 |
| fileSystemEncoding.test | decide | 1 | 0 | 1 | 0 | 0 | 0 | 1 | 0 |
| for-old.test | in | 9 | 9 | 0 | 0 | 0 | 9 | 0 | 0 |
| for.test | in | 88 | 61 | 3 | 24 | 0 | 61 | 3 | 24 |
| foreach.test | in | 43 | 41 | 2 | 0 | 0 | 41 | 2 | 0 |
| format.test | in | 266 | 255 | 2 | 9 | 0 | 255 | 2 | 9 |
| get.test | in | 22 | 5 | 1 | 16 | 0 | 5 | 1 | 16 |
| history.test | decide | 62 | 17 | 45 | 0 | 0 | 17 | 45 | 0 |
| http.test | decide | 75 | 2 | 62 | 11 | 0 | 2 | 62 | 11 |
| http11.test | decide | 43 | 0 | 42 | 1 | 0 | 0 | 42 | 1 |
| httpPipeline.test | decide | 1,996 | 0 | 0 | 0 | 1,996 | 0 | 0 | 0 |
| httpold.test | decide | 32 | 3 | 28 | 0 | 1 | 3 | 28 | 0 |
| if-old.test | in | 33 | 33 | 0 | 0 | 0 | 33 | 0 | 0 |
| if.test | in | 73 | 73 | 0 | 0 | 0 | 73 | 0 | 0 |
| incr-old.test | in | 14 | 12 | 2 | 0 | 0 | 12 | 2 | 0 |
| incr.test | in | 66 | 62 | 4 | 0 | 0 | 62 | 4 | 0 |
| indexObj.test | na | 45 | 0 | 0 | 45 | 0 | 0 | 0 | 45 |
| info.test | in | 266 | 111 | 152 | 3 | 0 | 111 | 152 | 3 |
| init.test | decide | 36 | 17 | 19 | 0 | 0 | 17 | 19 | 0 |
| interp.test | decide | 352 | 198 | 141 | 13 | 0 | 198 | 141 | 13 |
| io.test | decide | 830 | 364 | 79 | 387 | 0 | 364 | 79 | 387 |
| ioCmd.test | decide | 348 | 98 | 148 | 102 | 0 | 98 | 148 | 102 |
| ioTrans.test | decide | 106 | 2 | 67 | 37 | 0 | 2 | 67 | 37 |
| iogt.test | decide | 17 | 0 | 0 | 17 | 0 | 0 | 0 | 17 |
| join.test | in | 10 | 10 | 0 | 0 | 0 | 10 | 0 | 0 |
| lindex.test | in | 83 | 80 | 3 | 0 | 0 | 80 | 3 | 0 |
| link.test | na | 29 | 0 | 0 | 29 | 0 | 0 | 0 | 29 |
| linsert.test | in | 28 | 28 | 0 | 0 | 0 | 28 | 0 | 0 |
| list.test | in | 78 | 77 | 1 | 0 | 0 | 77 | 1 | 0 |
| listObj.test | in | 47 | 42 | 0 | 5 | 0 | 42 | 0 | 5 |
| llength.test | in | 6 | 6 | 0 | 0 | 0 | 6 | 0 | 0 |
| lmap.test | in | 66 | 65 | 1 | 0 | 0 | 65 | 1 | 0 |
| load.test | decide | 30 | 0 | 8 | 22 | 0 | 0 | 8 | 22 |
| lrange.test | in | 34 | 32 | 0 | 2 | 0 | 32 | 0 | 2 |
| lrepeat.test | in | 12 | 12 | 0 | 0 | 0 | 12 | 0 | 0 |
| lreplace.test | in | 1,787 | 1,787 | 0 | 0 | 0 | 1,787 | 0 | 0 |
| lsearch.test | in | 118 | 116 | 2 | 0 | 0 | 116 | 2 | 0 |
| lset.test | in | 89 | 83 | 5 | 1 | 0 | 83 | 5 | 1 |
| lsetComp.test | in | 19 | 19 | 0 | 0 | 0 | 19 | 0 | 0 |
| macOSXFCmd.test | na | 14 | 0 | 0 | 14 | 0 | 0 | 0 | 14 |
| macOSXLoad.test | na | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| main.test | decide | 67 | 13 | 18 | 36 | 0 | 13 | 18 | 36 |
| mathop.test | in | 349 | 347 | 2 | 0 | 0 | 347 | 2 | 0 |
| misc.test | in | 301 | 1 | 1 | 299 | 0 | 1 | 1 | 299 |
| msgcat.test | decide | 109 | 49 | 60 | 0 | 0 | 49 | 60 | 0 |
| namespace-old.test | in | 126 | 121 | 5 | 0 | 0 | 121 | 5 | 0 |
| namespace.test | in | 313 | 235 | 75 | 3 | 0 | 235 | 75 | 3 |
| notify.test | na | 23 | 0 | 0 | 23 | 0 | 0 | 0 | 23 |
| nre.test | in | 28 | 4 | 1 | 23 | 0 | 4 | 1 | 23 |
| obj.test | na | 92 | 3 | 0 | 89 | 0 | 3 | 0 | 89 |
| oo.test | in | 306 | 217 | 72 | 17 | 0 | 217 | 72 | 17 |
| ooNext2.test | in | 62 | 50 | 7 | 5 | 0 | 50 | 7 | 5 |
| opt.test | decide | 31 | 0 | 30 | 0 | 1 | 0 | 30 | 0 |
| package.test | decide | 402 | 357 | 45 | 0 | 0 | 357 | 45 | 0 |
| parse.test | in | 271 | 114 | 5 | 152 | 0 | 114 | 5 | 152 |
| parseExpr.test | in | 284 | 67 | 0 | 217 | 0 | 67 | 0 | 217 |
| parseOld.test | in | 158 | 154 | 1 | 3 | 0 | 154 | 1 | 3 |
| pid.test | decide | 5 | 5 | 0 | 0 | 0 | 5 | 0 | 0 |
| pkgMkIndex.test | decide | 27 | 0 | 25 | 2 | 0 | 0 | 25 | 2 |
| platform.test | decide | 6 | 1 | 2 | 1 | 2 | 1 | 2 | 1 |
| proc-old.test | in | 74 | 66 | 8 | 0 | 0 | 66 | 8 | 0 |
| proc.test | in | 38 | 26 | 3 | 9 | 0 | 26 | 3 | 9 |
| pwd.test | decide | 3 | 3 | 0 | 0 | 0 | 3 | 0 | 0 |
| reg.test | in | 1,141 | 925 | 106 | 110 | 0 | 925 | 106 | 110 |
| regexp.test | in | 244 | 240 | 1 | 3 | 0 | 240 | 1 | 3 |
| regexpComp.test | in | 179 | 177 | 2 | 0 | 0 | 177 | 2 | 0 |
| registry.test | na | 125 | 0 | 0 | 125 | 0 | 0 | 0 | 125 |
| rename.test | in | 19 | 10 | 1 | 8 | 0 | 10 | 1 | 8 |
| resolver.test | na | 10 | 0 | 0 | 10 | 0 | 0 | 0 | 10 |
| result.test | na | 26 | 1 | 3 | 22 | 0 | 1 | 3 | 22 |
| safe-stock.test | decide | 4 | 0 | 4 | 0 | 0 | 0 | 4 | 0 |
| safe.test | decide | 102 | 2 | 91 | 8 | 1 | 2 | 91 | 8 |
| scan.test | in | 181 | 180 | 0 | 1 | 0 | 180 | 0 | 1 |
| security.test | decide | 1 | 1 | 0 | 0 | 0 | 1 | 0 | 0 |
| set-old.test | in | 153 | 142 | 11 | 0 | 0 | 142 | 11 | 0 |
| set.test | in | 64 | 61 | 2 | 1 | 0 | 61 | 2 | 1 |
| socket.test | decide | 175 | 157 | 7 | 11 | 0 | 157 | 7 | 11 |
| source.test | decide | 23 | 18 | 5 | 0 | 0 | 18 | 5 | 0 |
| split.test | in | 17 | 16 | 1 | 0 | 0 | 16 | 1 | 0 |
| stack.test | decide | 3 | 1 | 2 | 0 | 0 | 1 | 2 | 0 |
| string.test | in | 1,266 | 1,246 | 2 | 18 | 0 | 1,246 | 2 | 18 |
| stringComp.test | in | 279 | 278 | 0 | 1 | 0 | 278 | 0 | 1 |
| stringObj.test | na | 75 | 0 | 0 | 75 | 0 | 0 | 0 | 75 |
| subst.test | in | 63 | 60 | 2 | 1 | 0 | 60 | 2 | 1 |
| switch.test | in | 113 | 109 | 4 | 0 | 0 | 109 | 4 | 0 |
| tailcall.test | in | 37 | 20 | 9 | 8 | 0 | 20 | 9 | 8 |
| tcltest.test | decide | 159 | 2 | 40 | 1 | 116 | 2 | 40 | 1 |
| thread.test | decide | 52 | 18 | 0 | 34 | 0 | 18 | 0 | 34 |
| timer.test | decide | 54 | 53 | 1 | 0 | 0 | 53 | 1 | 0 |
| tm.test | decide | 21 | 0 | 21 | 0 | 0 | 0 | 21 | 0 |
| trace.test | in | 295 | 212 | 66 | 17 | 0 | 212 | 66 | 17 |
| unixFCmd.test | decide | 49 | 2 | 28 | 19 | 0 | 2 | 28 | 19 |
| unixFile.test | decide | 7 | 0 | 0 | 7 | 0 | 0 | 0 | 7 |
| unixForkEvent.test | na | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 1 |
| unixInit.test | decide | 8 | 3 | 3 | 2 | 0 | 3 | 3 | 2 |
| unixNotfy.test | decide | 4 | 2 | 0 | 2 | 0 | 2 | 0 | 2 |
| unknown.test | in | 7 | 7 | 0 | 0 | 0 | 7 | 0 | 0 |
| unload.test | decide | 27 | 0 | 7 | 20 | 0 | 0 | 7 | 20 |
| uplevel.test | in | 57 | 49 | 8 | 0 | 0 | 49 | 8 | 0 |
| upvar.test | in | 65 | 43 | 14 | 8 | 0 | 43 | 14 | 8 |
| utf.test | in | 498 | 126 | 18 | 354 | 0 | 126 | 18 | 354 |
| util.test | in | 2,291 | 2,124 | 23 | 144 | 0 | 2,124 | 23 | 144 |
| var.test | in | 110 | 69 | 21 | 20 | 0 | 69 | 21 | 20 |
| while-old.test | in | 15 | 14 | 1 | 0 | 0 | 14 | 1 | 0 |
| while.test | in | 46 | 45 | 1 | 0 | 0 | 45 | 1 | 0 |
| winConsole.test | na | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 1 |
| winDde.test | na | 50 | 0 | 0 | 50 | 0 | 0 | 0 | 50 |
| winFCmd.test | na | 178 | 0 | 0 | 178 | 0 | 0 | 0 | 178 |
| winFile.test | na | 11 | 0 | 0 | 11 | 0 | 0 | 0 | 11 |
| winNotify.test | na | 14 | 0 | 0 | 14 | 0 | 0 | 0 | 14 |
| winPipe.test | na | 56 | 0 | 0 | 56 | 0 | 0 | 0 | 56 |
| winTime.test | na | 3 | 0 | 0 | 3 | 0 | 0 | 0 | 3 |
| word.test | in | 50 | 45 | 5 | 0 | 0 | 45 | 5 | 0 |
| zlib.test | decide | 73 | 0 | 1 | 72 | 0 | 0 | 1 | 72 |

## Tests that do not pass

Each failure has its own line. Skips are grouped by the constraint that stopped them.

### append.test

| Test | Bucket | Result (start) |
|---|---|---|
| append-9.0 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't read "myvar(key)": no such variable} \| want: 0 {{new value}} |

### appendComp.test

| Test | Bucket | Result (start) |
|---|---|---|
| appendComp-9.0 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't read "::myvar(key)": BOOM. no such variable} \| want: 0 {{new value}} |

| Skipped by | Tests | Bucket |
|---|---|---|
| expr:bug-3057639 | 5 | `tcl`: the test file sets the constraint false, or it is false in tclsh 8.6 on Linux |

### apply.test

| Test | Bucket | Result (start) |
|---|---|---|
| apply-4.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "::apply lambdaExpr x" \| want: wrong # args: should ... |
| apply-4.4 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "::apply lambdaExpr x" \| want: wrong # args: should ... |
| apply-4.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "::apply lambdaExpr self x" \| want: wrong # args: sh... |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 3 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| applylambda | 1 | `internals`: a C test command or package of the Tcl test binary |

### assemble.test

| Test | Bucket | Result (start) |
|---|---|---|
| assemble-1.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-1.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-1.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {invalid command name "assemble"     wh... |
| assemble-1.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: this is a test |
| assemble-10.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-10.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-10.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 11 |
| assemble-10.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 11 |
| assemble-10.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 11 |
| assemble-10.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-10.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-11.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-11.10 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 123 |
| assemble-11.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-11.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-11.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 0 |
| assemble-11.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 0 0 |
| assemble-11.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: a 1 b 222 c 3 |
| assemble-11.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: a 1 b {2 2} c 3 |
| assemble-11.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 123 |
| assemble-11.9 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 123 |
| assemble-12.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-12.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-12.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-12.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 8 |
| assemble-12.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 8 |
| assemble-12.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-13.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-13.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-13.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-13.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-13.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-13.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-13.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: -127 0 |
| assemble-13.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 8 |
| assemble-13.9 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-14.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-14.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-14.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-14.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-14.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-14.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: -127 0 |
| assemble-14.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 8 |
| assemble-15.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-15.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-15.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-15.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: bad index "rubbish"* |
| assemble-15.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: c |
| assemble-15.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: b |
| assemble-15.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: c |
| assemble-15.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want:  |
| assemble-15.9 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want:  |
| assemble-16.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-16.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-16.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-16.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-16.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::assemble" \| want: 1 2 |
| assemble-16.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 1 1 1 |
| assemble-17.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-17.10 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: x |
| assemble-17.11 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: no yes |
| assemble-17.12 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: yes no |
| assemble-17.13 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-17.14 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: invalid command name "assemble"     while executing "assemble {#1      #2  ... |
| assemble-17.15 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: -abababababababababababababababab- |
| assemble-17.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-17.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-17.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-17.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-17.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-17.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-17.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: ceadbf |
| assemble-17.9 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: abcd |
| assemble-18.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-18.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-18.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-18.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-18.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-18.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: {a b c} {d e f} {g h j} |
| assemble-18.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: d e f |
| assemble-18.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: h |
| assemble-19.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-19.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-19.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-19.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-19.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-19.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want:  |
| assemble-19.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello |
| assemble-19.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello world |
| assemble-2.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: {this is a test} {this is a test} |
| assemble-2.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: value1 value2 |
| assemble-2.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want:  |
| assemble-20.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-20.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-20.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-20.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-20.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-20.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: b |
| assemble-20.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: a d c |
| assemble-21.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-21.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-21.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-21.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-21.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-21.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 3 |
| assemble-21.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 |
| assemble-22.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-22.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-22.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-22.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-22.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-22.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 |
| assemble-22.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 3 |
| assemble-22.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 |
| assemble-23.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-23.10 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 |
| assemble-23.11 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: can't unset "a(b)": no such variable |
| assemble-23.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-23.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-23.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected boolean value but got "rubb... |
| assemble-23.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: {0 0} {1 1} {0 1} |
| assemble-23.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 |
| assemble-23.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 |
| assemble-23.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: can't unset "a": no such variable |
| assemble-23.9 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 |
| assemble-24.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-24.10 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 |
| assemble-24.11 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 |
| assemble-24.12 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: can't unset "a(b)": no such variable |
| assemble-24.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-24.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-24.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected boolean value but got "rubb... |
| assemble-24.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-24.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: variable "::foo::bar" is not local |
| assemble-24.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 |
| assemble-24.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 |
| assemble-24.9 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: can't unset "a": no such variable |
| assemble-25.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-25.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-25.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-25.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-25.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-25.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 |
| assemble-26.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-26.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-26.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-26.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-26.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-26.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-26.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: a 1 b 4 c 3 |
| assemble-27.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-27.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-27.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-27.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-27.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-27.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-27.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: a 1 c 3 |
| assemble-28.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-28.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-28.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-28.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-28.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-28.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: a 1 b 44 c 3 |
| assemble-29.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-29.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-29.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-29.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected boolean value but got "rubb... |
| assemble-29.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 |
| assemble-29.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 |
| assemble-29.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 |
| assemble-3.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args:* |
| assemble-3.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args:* |
| assemble-30.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 |
| assemble-30.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} \| want: 0 1 |
| assemble-30.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} \| want: 0 {1 {1 whatever}} |
| assemble-30.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} {{invalid... |
| assemble-30.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} {invalid ... |
| assemble-30.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {TCL LOOKUP COMMAND assemble} {invalid command name "assemble"     while ... |
| assemble-31.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-31.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-31.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: assembly code may not contain substi... |
| assemble-31.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: unmatched open brace in list |
| assemble-31.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} {invalid ... |
| assemble-31.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} {invalid ... |
| assemble-31.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: {none of the above} one two three ... |
| assemble-4.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {invalid command name "assemble"     wh... |
| assemble-4.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: goodbye |
| assemble-40.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0: 1 {invalid command name "assemble"} {invalid command name "assemble"     whil... |
| assemble-40.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0: 1 {invalid command name "assemble"} {invalid command name "assemble"     whil... |
| assemble-41.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: invalid command name "assemble"     while executing "assemble {   load y   ... |
| assemble-41.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: invalid command name "assemble"     while executing "assemble {   load y   ... |
| assemble-41.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: invalid command name "assemble"     while executing "assemble {   load y   ... |
| assemble-5.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-5.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-5.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-5.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello world |
| assemble-50.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 2 16 4 16 16 52 8 52 16 52 16 40... |
| assemble-52.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "::tcl::unsupported::assemble" \| want:  |
| assemble-6.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-6.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-6.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello |
| assemble-6.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello |
| assemble-7,34 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: -1 1 0 |
| assemble-7.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-7.10 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 1 0 0 |
| assemble-7.11 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 0 |
| assemble-7.12 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 81 |
| assemble-7.13 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 3.141592653589793 |
| assemble-7.13a | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: missing operand at _@_ in expression... |
| assemble-7.13b | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {invalid command name "assemble"     wh... |
| assemble-7.14 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: {1 0 1 0} {0 0 1 1} {1 1 0 0} |
| assemble-7.15 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 12 |
| assemble-7.16 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 12 |
| assemble-7.17 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: {0 0} {0 1} {0 1} {1 1} |
| assemble-7.18 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: charlie dog |
| assemble-7.19 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: baker charlie |
| assemble-7.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 4 |
| assemble-7.20 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: c |
| assemble-7.21 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 4 |
| assemble-7.22 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: charlie |
| assemble-7.23 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: baker |
| assemble-7.24 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: {a b} {c d} {e i} {g h} |
| assemble-7.25 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 256 |
| assemble-7.26 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 456 |
| assemble-7.27 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 111111111 |
| assemble-7.28 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 0 |
| assemble-7.29 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 1 |
| assemble-7.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello, world |
| assemble-7.30 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: that |
| assemble-7.31 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 16 |
| assemble-7.32 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: baker charlie |
| assemble-7.33 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: baker |
| assemble-7.35 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: {1 0} {0 1} |
| assemble-7.36 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: i |
| assemble-7.37 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 7 |
| assemble-7.38 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 25 |
| assemble-7.39 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 42 |
| assemble-7.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello, world |
| assemble-7.41 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: -42 |
| assemble-7.42 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 42 |
| assemble-7.43 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: can't use non-numeric floating-point... |
| assemble-7.43.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: domain error: argument not in valid ... |
| assemble-7.44 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 |
| assemble-7.45 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 1 |
| assemble-7.46 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: x |
| assemble-7.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 8 -13 14 6 |
| assemble-7.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 142857 |
| assemble-7.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 9 |
| assemble-7.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: 0 1 |
| assemble-7.9 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: test 7.3 |
| assemble-7.9a | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: extra characters after close-brace |
| assemble-7.9b | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {invalid command name "assemble"     wh... |
| assemble-8.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-8.10 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello, world |
| assemble-8.11 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello, world |
| assemble-8.12 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello, world |
| assemble-8.13 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello, world |
| assemble-8.14 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello, world |
| assemble-8.15 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello, world |
| assemble-8.16 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello, world |
| assemble-8.17 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello, world |
| assemble-8.18 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: test |
| assemble-8.19 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: test |
| assemble-8.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-8.20 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: test |
| assemble-8.21 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: test |
| assemble-8.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-8.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-8.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |
| assemble-8.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: able |
| assemble-8.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: able |
| assemble-8.8 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: charlie |
| assemble-8.9 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "set v0 literal0 set v1 literal1 set v2 literal2 set v... |
| assemble-9.1 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-9.2 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: wrong # args* |
| assemble-9.3 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: expected integer but got "rubbish" |
| assemble-9.4 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: operand does not fit in one byte |
| assemble-9.5 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/1: invalid command name "assemble" \| want: operand does not fit in one byte |
| assemble-9.6 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 1/0,2: invalid command name "assemble" \| want: hello |
| assemble-9.7 | `design`: the Tcl bytecode assembler; ztcl has its own bytecode | code 0/0,2: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} \| want: ... |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 4 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### assocd.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testgetassocdata | 4 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testsetassocdata | 4 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testdelassocdata | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### async.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testasync | 12 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### autoMkindex.test

| Test | Bucket | Result (start) |
|---|---|---|
| autoMkindex-1.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "auto_mkindex" \| want: 1 |
| autoMkindex-1.3 | `bug`: the setup or the cleanup of the test fails | cleanup: unknown namespace "tcl_autoMkindex_tmp" in namespace delete command |
| autoMkindex-2.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "auto_mkindex" \| want: 0 {} pub_one ::buried::pub_one... |
| autoMkindex-3.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "auto_mkindex_parser::slavehook" \| want: 1 |
| autoMkindex-3.2 | `bug`: the setup or the cleanup of the test fails | cleanup: unknown namespace "tcl_autoMkindex_tmp" in namespace delete command |
| autoMkindex-3.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "auto_mkindex" \| want: {set auto_index(::wok::command... |
| autoMkindex-4.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "auto_mkindex" \| want: {set auto_index(::college::tea... |
| autoMkindex-5.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "auto_mkindex" \| want: set auto_index(testProc) [list... |
| autoMkindex-5.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "auto_mkindex" \| want: 0 |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 1 | `tcl`: tclsh skips it too |

### basic.test

| Test | Bucket | Result (start) |
|---|---|---|
| basic-10.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: unknown namespace "::" in namespace delete command \| want: {::test_ns_basi... |
| basic-12.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 {} 1 {unknown command "x"} {} \| want: 1 {can only hide global namespace ... |
| basic-13.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: unknown hidden command "cmd" \| want: :: {} 1 {cannot expose to a namespace... |
| basic-15.2 | `bug`: the setup or the cleanup of the test fails | cleanup: unknown namespace "n" in namespace delete command |
| basic-18.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't rename to "george::martha": command already exists} \| want: 1 {ca... |
| basic-18.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: {p in ::} {} {q in ::} \| want: {p in ::} {} {q in ::test_ns_basic} |
| basic-46.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 { DONE } \| want: 1 {invoked "continue" outside of a loop     while execu... |
| basic-46.2 | `message`: an error where tclsh also gives one, with another message | code 1/1: hello invoked "break" outside of a loop \| want: hello invoked "break" outsid... |
| basic-46.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: invoked "break" outside of a loop \| want: invoked "break" outside of a loop ... |
| basic-46.4 | `message`: an error where tclsh also gives one, with another message | code 1/1: invoked "break" outside of a loop \| want: invoked "break" outside of a loop ... |
| basic-46.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: command returned bad code: 2     while executing "return -code retu... |
| basic-50.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 2 {} \| want: 0 {} |

| Skipped by | Tests | Bucket |
|---|---|---|
| emptyTest | 27 | `tcl`: tclsh skips it too |
| testcmdtoken | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| memory | 2 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testcreatecommand | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### binary.test

| Test | Bucket | Result (start) |
|---|---|---|
| binary-1.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: unknown or ambiguous subcommand "f": must be decode, encode, format, or scan ... |
| binary-13.13 | `bug`: 'binary': the result differs | code 0/0,2: ÿ \| want: ÿÿÿ |
| binary-15.1 | `bug`: 'binary': the result differs | code 0/1: yz \| want: cannot use "*" in format string with "x" |
| binary-16.1 | `bug`: 'binary': the result differs | code 0/0,2: z \| want: zoo |
| binary-16.4 | `bug`: 'binary': the result differs | code 0/0,2: fooz \| want: foozar |
| binary-16.5 | `bug`: 'binary': the result differs | code 0/0,2: fob \| want: fobzar |
| binary-17.3 | `bug`: 'binary': the result differs | code 1/0,2: missing count for "@" field specifier \| want: abobarblat |
| binary-19.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: unknown or ambiguous subcommand "s": must be decode, encode, format, or scan ... |
| binary-2.8 | `bug`: 'binary': the result differs | code 0/0,2: foox \| want: fooxr |
| binary-3.8 | `bug`: 'binary': the result differs | code 0/0,2: foox  \| want: foox r |
| binary-36.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: not enough arguments for all format specifiers \| want: bad field specifier "u" |
| binary-37.10 | `bug`: 'binary': the result differs | code 1/0,2: the count of a binary field is too large \| want: 0 |
| binary-37.11 | `bug`: 'binary': the result differs | code 1/0,2: the count of a binary field is too large \| want: 0 |
| binary-37.12 | `bug`: 'binary': the result differs | code 1/0,2: the count of a binary field is too large \| want: 0 |
| binary-37.13 | `bug`: 'binary': the result differs | code 1/0,2: the count of a binary field is too large \| want: 0 |
| binary-40.3 | `bug`: 'binary': the result differs | code 0/0,2: 1 NaN \| want: 1 -NaN* |
| binary-40.4 | `bug`: 'binary': the result differs | code 0/0,2: 1 NaN \| want: 1 -NaN* |
| binary-43.6 | `bug`: 'binary': the result differs | code 0/0,2: 1 -9223372036854775808 \| want: 1 9223372036854775808 |
| binary-43.7 | `bug`: 'binary': the result differs | code 0/0,2: 1 -9223372036854775808 \| want: 1 9223372036854775808 |
| binary-43.8 | `bug`: 'binary': the result differs | code 0/0,2: 2 -9223372036854775808 -9223372036854775808 \| want: 2 9223372036854775808 ... |
| binary-43.9 | `bug`: 'binary': the result differs | code 0/0,2: 2 -9223372036854775808 -9223372036854775808 \| want: 2 9223372036854775808 ... |
| binary-53.12 | `bug`: 'binary': the result differs | code 0/0,2: ÿ \| want: ÿÿÿ |
| binary-53.13 | `bug`: 'binary': the result differs | code 0/0,2: ÿ \| want: ÿÿÿ |
| binary-63.2 | `bug`: 'binary': the result differs | code 0/0,2: 0x7ff0000000000000 \| want: 0xfff0000000000000 |
| binary-63.3 | `bug`: 'binary': the result differs | code 1/0,2: expected floating-point number but got "NaN(3123456789aBc)" \| want: 0x7ff3... |
| binary-63.4 | `bug`: 'binary': the result differs | code 1/0,2: expected floating-point number but got "NaN( 3123456789aBc)" \| want: 0x7ff... |
| binary-64.2 | `bug`: 'binary': the result differs | code 0/0,2: NaN \| want: NaN(*123456789abc) |
| binary-73.35 | `bug`: 'binary': the result differs | code 0/0,2: 0 0 0 1 0 1 0 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 \| want: 0 1 0 1 0 1 0 1 0 1 0 ... |
| binary-73.37 | `bug`: 'binary': the result differs | code 1/0,2: invalid base64 character ":" at position 3 \| want: abc |
| binary-75.25 | `bug`: 'binary': the result differs | code 0/1: ABC \| want: invalid uuencode character "z" at position 5 |
| binary-75.7 | `bug`: 'binary': the result differs | code 0/0,2: 0 \| want: 1 |
| binary-75.8 | `bug`: 'binary': the result differs | code 0/0,2: 1 \| want: 2 |
| binary-75.9 | `bug`: 'binary': the result differs | code 0/0,2: 2 \| want: 3 |
| binary-76.1 | `bug`: 'binary': the result differs | code 1/0,2: couldn't open "/dev/null": no such file or directory \| want: 3 |

| Skipped by | Tests | Bucket |
|---|---|---|
| bigEndian | 76 | `platform`: a constraint of another platform or word size |
| testsetbytearraylength | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| win | 1 | `platform`: a constraint of another platform or word size |

### chan.test

| Test | Bucket | Result (start) |
|---|---|---|
| chan-15.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "truncate": must be close, configure, copy, e... |
| chan-15.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "truncate": must be close, configure, copy,... |

### chanio.test

| Test | Bucket | Result (start) |
|---|---|---|
| chan-io-1.6 | `bug`: channels: the result differs | code 0/0,2: a9 \| want: aM |
| chan-io-14.2 | `bug`: channels: the result differs | code 0/0,2: {} {} {} \| want: line line none |
| chan-io-14.3 | `bug`: channels: the result differs | cleanup: can not find channel named "file217" |
| chan-io-14.4 | `bug`: channels: the result differs | cleanup: can not find channel named "file218" |
| chan-io-14.5 | `bug`: the standard channels are not in the channel table | code 0/0,2: {can not find channel named "stdin"} {can not find channel named "stdin"} {... |
| chan-io-14.6 | `bug`: the standard channels are not in the channel table | code 0/0,2: {} {can not find channel named "stdout"} {} \| want: {} {} {can not find ch... |
| chan-io-14.7 | `bug`: the standard channels are not in the channel table | code 0/0,2: {} {can not find channel named "stderr"} {} \| want: {} {} {can not find ch... |
| chan-io-14.8 | `bug`: channels: the result differs | code 0/0,2:  \| want: hello |
| chan-io-2.2 | `bug`: channels: the result differs | code 0/0,2: {} {123456789012345  12} \| want: {123456789012345 } {123456789012345  12} |
| chan-io-2.4 | `bug`: channels: the result differs | code 0/0,2: {abcdefg hijklmnopqrstuvwxyz} {abcdefg hijklmnopqrstuvwxyz} \| want: {abcde... |
| chan-io-20.1 | `bug`: channels: the result differs | code 0/0,2: utf-8 \| want: ascii |
| chan-io-20.5 | `message`: an error where tclsh also gives one, with another message | code 1/1:  \| want: 777 |
| chan-io-27.4 | `bug`: channels: the result differs | code 0/0,2: 0 0 72 \| want: 0 60 72 |
| chan-io-27.5 | `bug`: channels: the result differs | code 0/0,2: 0 0 72 \| want: 0 60 72 |
| chan-io-28.2 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "share": must be alias, aliases, cancel, children, create, delet... |
| chan-io-29.20 | `bug`: channels: the result differs | code 0/0,2: 0 0 12600 \| want: 4096 12288 12600 |
| chan-io-29.27 | `bug`: channels: the result differs | code 0/0,2: 1 {error writing "file278": broken pipe} {posix epipe {broken pipe}} \| wan... |
| chan-io-29.35 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "share": must be alias, aliases, cancel, children, create, delet... |
| chan-io-3.2 | `bug`: channels: the result differs | code 0/0,2: {} {123456789012345  12} \| want: {123456789012345 } {123456789012345  12} |
| chan-io-3.4 | `bug`: channels: the result differs | code 0/0,2: {} !)!)!)!)!)!)!)!)!)!)!)!)!)!)!) \| want: !)!)!)!)!)!)!)!) !)!)!)!)!)!)!)!... |
| chan-io-3.5 | `bug`: channels: the result differs | code 0/0,2: {} !)!)!)!)!)!)!)!)!)!)!)!)!)!)!) \| want: !)!)!)!)!)!)!)!)! !)!)!)!)!)!)!)... |
| chan-io-3.6 | `bug`: channels: the result differs | code 0/0,2: {} 12345678901234'a \| want: 12345678901234' 12345678901234'a |
| chan-io-3.7 | `bug`: channels: the result differs | code 0/0,2: {} !)!)!)!)!)!)!)!)!)!)!)!)!)!)!) \| want: !)!)!)!)!)!)!)!)! !)!)!)!)!)!)!)... |
| chan-io-3.8 | `bug`: channels: the result differs | code 0/0,2: {abcdefg hijklmnopqrstuvwxyz} {abcdefg hijklmnopqrstuvwxyz} \| want: {abcde... |
| chan-io-30.21 | `bug`: channels: the result differs | code 0/0,2: 0 0 def 0 \| want: 1 1 {} 1 |
| chan-io-30.22 | `bug`: channels: the result differs | code 0/0,2: 0 0 def 0 \| want: 1 1 {} 1 |
| chan-io-31.11 | `bug`: channels: the result differs | code 0/0,2: hello 6 cr 0 0 7 cr 0 \| want: hello 6 cr 0 6 13 cr 0 |
| chan-io-31.13 | `bug`: channels: the result differs | code 0/0,2: binary \| want: lf |
| chan-io-31.5 | `bug`: channels: the result differs | code 0/0,2: 5 6 cr 0 there 12 cr 0 \| want: 21 21 cr 1 {} 21 cr 1 |
| chan-io-31.6 | `bug`: channels: the result differs | code 0/0,2: 5 6 crlf 0 there 12 crlf 0 \| want: 21 21 crlf 1 {} 21 crlf 1 |
| chan-io-34.12 | `bug`: channels: the result differs | code 1/0,2: bad origin "cur": must be start, current, or end \| want: 14 {xyz 123 xyzzy... |
| chan-io-34.19 | `bug`: channels: the result differs | code 0/0,2: 0 \| want: 54 |
| chan-io-34.8 | `message`: an error where tclsh also gives one, with another message | code 1/1: error during seek on "file457": input/output error \| want: error during seek... |
| chan-io-39.21 | `bug`: channels: the result differs | code 0/0,2: auto lf \| want: auto crlf |
| chan-io-39.23 | `bug`: channels: the result differs | code 0/0,2: {} lf \| want: {{}} auto |
| chan-io-39.24 | `bug`: channels: the result differs | code 0/0,2: D lf \| want: {{}} auto |
| chan-io-4.4 | `bug`: channels: the result differs | code 0/0,2: {} {1234567          A} \| want: {1234567         } {1234567          A} |
| chan-io-40.17 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "::env(HOME)": no such variable |
| chan-io-42.2 | `bug`: channels: the result differs | code 1/0,2: bad event name "r": must be readable or writable \| want: {first script} {n... |
| chan-io-42.3 | `bug`: channels: the result differs | code 1/0,2: bad event name "r": must be readable or writable \| want: 13 11 12 {} |
| chan-io-43.2 | `bug`: channels: the result differs | code 1/0,2: bad event name "r": must be readable or writable \| want: {} {} {} {chan re... |
| chan-io-49.1 | `bug`: channels: the result differs | code 0/0,2: 7 a 1 { } 2 b 3 { } 4 c 5 { } 6 0 { } 0 \| want: 7 a 1 { } 2 b 3 { } 4 c 5 ... |
| chan-io-49.2 | `bug`: channels: the result differs | code 0/0,2: 7 {a } 2 {b } 4 {c } 6 0 { } 7 1 \| want: 7 {a } 2 {b } 4 {c } 7 0 {} 7 1 |
| chan-io-49.3 | `bug`: channels: the result differs | code 0/0,2: 7 {a b} 3 { c } 6 0 { } 7 1 \| want: 7 {a b} 3 { c } 7 0 {} 7 1 |
| chan-io-5.2 | `bug`: channels: the result differs | code 0/0,2: {} 12345678901234567890 \| want: 1234567890123456 12345678901234567890 |
| chan-io-52.1 | `bug`: channels: the result differs | code 0/1: 256275 \| want: channel "*" is busy |
| chan-io-52.10 | `bug`: channels: the result differs | code 0/0,2: 3 \| want: 5 |
| chan-io-52.11 | `bug`: channels: the result differs | code 0/0,2: 5 \| want: 3 |
| chan-io-52.2 | `bug`: channels: the result differs | code 0/1: 256275 \| want: channel "*" is busy |
| chan-io-52.7 | `bug`: channels: the result differs | code 2/0,2: 0 0 \| want: 0 0 ok |
| chan-io-53.4 | `bug`: channels: the result differs | code 1/0,2: bad event name "read": must be readable or writable \| want: done |
| chan-io-53.7 | `bug`: channels: the result differs | cleanup: can not find channel named "file687" |
| chan-io-6.17 | `bug`: channels: the result differs | code 0/0,2: 0 {} -1 {} \| want: 1 { } -1 {} |
| chan-io-6.21 | `bug`: channels: the result differs | code 0/0,2: 4 abcd 4 efgh 4 ijkl 0 {} \| want: 9 {abcd efgh} 4 ijkl 5 { mnop} -1 {} |
| chan-io-6.23 | `bug`: channels: the result differs | code 0/0,2: 0 {} -1 {} \| want: 1 { } -1 {} |
| chan-io-6.29 | `bug`: channels: the result differs | code 0/0,2: 4 abcd 9 {efgh ijkl} 4 mnop \| want: 14 {abcd efgh ijkl} 4 mnop -1 {} |
| chan-io-6.4 | `bug`: channels: the result differs | code 0/0,2: 4 H´ \| want: 3 4 |
| chan-io-61.1 | `bug`: channels: the result differs | code 0/0,2: 77 {} 77 \| want: 77 = 23431 |
| chan-io-7.4 | `bug`: channels: the result differs | code 1/0,2: bad event name "read": must be readable or writable \| want: -1 {} 1 17 123... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testchannel | 354 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testfevent | 9 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| emptyTest | 8 | `tcl`: tclsh skips it too |
| testchannelevent | 7 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| asyncPipeChan | 3 | `tcl`: the test file sets the constraint false, or it is false in tclsh 8.6 on Linux |
| win | 2 | `platform`: a constraint of another platform or word size |
| extensive | 1 | `tcl`: tclsh skips it too |
| makeFileInHome | 1 | `platform`: a property of the host: a second device, a writable home, IPv6 on localhost, ... |
| nonPortable | 1 | `tcl`: tclsh skips it too |
| testbytestring | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testmainthread | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### clock.test

| Test | Bucket | Result (start) |
|---|---|---|
| clock-1.4 | `bug`: 'clock': the result differs | code 0/0,2: 1 {bad option "-oops": must be -format, -gmt, -locale or -timezone} {CLOCK ... |
| clock-10.10 | `bug`: 'clock': the result differs | code 0/0,2: 946684800 0 \| want: 0 0 |
| clock-13.2 | `bug`: 'clock': the result differs | code 0/0,2: 946857600 0 \| want: 0 0 |
| clock-13.3 | `bug`: 'clock': the result differs | code 0/0,2: 946857600 {CLOCK badInputString} \| want: {day of week is greater than 7} {... |
| clock-13.4 | `bug`: 'clock': the result differs | code 0/0,2: 946857600 {CLOCK badInputString} \| want: {day of week is greater than 7} {... |
| clock-15.2 | `bug`: 'clock': the result differs | code 0/0,2: 946684800 0 \| want: 0 0 |
| clock-15.3 | `bug`: 'clock': the result differs | code 0/0,2: 946684800 0 \| want: 0 0 |
| clock-16.10 | `bug`: 'clock': the result differs | code 0/0,2: 946684800 0 \| want: 0 0 |
| clock-16.11 | `bug`: 'clock': the result differs | code 0/0,2: 946684800 0 \| want: 0 0 |
| clock-18.2 | `bug`: 'clock': the result differs | code 0/0,2: 947116800 0 \| want: 0 0 |
| clock-18.3 | `bug`: 'clock': the result differs | code 0/0,2: 947116800 0 \| want: 0 0 |
| clock-18.4 | `bug`: 'clock': the result differs | code 0/0,2: 947116800 0 \| want: 0 0 |
| clock-20.2 | `bug`: 'clock': the result differs | code 0/0,2: 2678400 0 \| want: 0 0 |
| clock-20.3 | `bug`: 'clock': the result differs | code 0/0,2: 2678400 0 \| want: 0 0 |
| clock-20.4 | `bug`: 'clock': the result differs | code 0/0,2: 2678400 0 \| want: 0 0 |
| clock-21.6 | `bug`: 'clock': the result differs | code 0/0,2: 86400 0 \| want: 0 0 |
| clock-21.7 | `bug`: 'clock': the result differs | code 0/0,2: 86400 0 \| want: 0 0 |
| clock-21.8 | `bug`: 'clock': the result differs | code 0/0,2: 86400 0 \| want: 0 0 |
| clock-23.2 | `bug`: 'clock': the result differs | code 0/0,2: 604800 0 \| want: 0 0 |
| clock-25.2 | `bug`: 'clock': the result differs | code 0/0,2: 86400 0 \| want: 0 0 |
| clock-25.3 | `bug`: 'clock': the result differs | code 0/0,2: 86400 0 \| want: 0 0 |
| clock-25.4 | `bug`: 'clock': the result differs | code 0/0,2: 86400 0 \| want: 0 0 |
| clock-25.5 | `bug`: 'clock': the result differs | code 0/0,2: 86400 0 \| want: 0 0 |
| clock-25.6 | `bug`: 'clock': the result differs | code 0/0,2: 86400 0 \| want: 0 0 |
| clock-25.7 | `bug`: 'clock': the result differs | code 0/0,2: 86400 0 \| want: 0 0 |
| clock-27.2 | `bug`: 'clock': the result differs | code 0/0,2: -259200 0 \| want: 0 0 |
| clock-27.3 | `bug`: 'clock': the result differs | code 0/0,2: -259200 0 \| want: 0 0 |
| clock-27.4 | `bug`: 'clock': the result differs | code 0/0,2: -259200 0 \| want: 0 0 |
| clock-27.5 | `bug`: 'clock': the result differs | code 0/0,2: -259200 0 \| want: 0 0 |
| clock-27.6 | `bug`: 'clock': the result differs | code 0/0,2: -259200 0 \| want: 0 0 |
| clock-27.7 | `bug`: 'clock': the result differs | code 0/0,2: -259200 0 \| want: 0 0 |
| clock-27.8 | `bug`: 'clock': the result differs | code 0/0,2: -259200 0 \| want: 0 0 |
| clock-27.9 | `bug`: 'clock': the result differs | code 0/0,2: -259200 0 \| want: 0 0 |
| clock-28.1 | `bug`: 'clock': the result differs | code 0/0,2: 1234567890 \| want: 1234483200 |
| clock-32.1 | `bug`: 'clock': the result differs | code 0/0,2: formatting -6857222400: 1752-247 should be 1752-258 scanning 1752-258: -685... |
| clock-33.7 | `bug`: 'clock': the result differs | code 0/0,2: 1 {bad option "-": must be -milliseconds or -microseconds} \| want: 1 {ambi... |
| clock-34.10 | `bug`: 'clock': the result differs | code 0/0,2: Jan 01,0071 00:00 GMT \| want: Jan 01,1971 00:00 GMT |
| clock-34.11 | `bug`: 'clock': the result differs | code 0/0,2: Jan 01,0037 00:00 GMT \| want: Jan 01,2037 00:00 GMT |
| clock-34.13 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "19921023": syntax error \| want: Oct 23... |
| clock-34.15 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "23-Oct-1992": syntax error \| want: Oct... |
| clock-34.16 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "19921023T235959": syntax error \| want:... |
| clock-34.17 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "19921023 235959": syntax error \| want:... |
| clock-34.18 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "19921023T000000": syntax error \| want:... |
| clock-34.19 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "5 am": syntax error \| want: {Dec 31, 1... |
| clock-34.20 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "5:30 pm": syntax error \| want: Dec 31,... |
| clock-34.21 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "00:00-0800": syntax error \| want: Dec ... |
| clock-34.23 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "8:00:00 am": syntax error \| want: Dec ... |
| clock-34.24 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "8:00:00 pm": syntax error \| want: Dec ... |
| clock-34.25 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "00:00:30-0800": syntax error \| want: D... |
| clock-34.28 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "Monday": syntax error \| want: Jan 03, ... |
| clock-34.29 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "1/1": syntax error \| want: Jan 01, 199... |
| clock-34.31 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "19990101": syntax error \| want: Jan 01... |
| clock-34.37 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "20000112": syntax error \| want: Jan 12... |
| clock-34.38 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "20000112": syntax error \| want: Jan 19... |
| clock-34.39 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "20000112": syntax error \| want: Jan 13... |
| clock-34.4 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "Feb 14, 1992 12:20 PM": syntax error \|... |
| clock-34.40 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "20000112": syntax error \| want: Jan 20... |
| clock-34.41 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "monday": syntax error \| want: 1991-11-... |
| clock-34.42 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "2 monday": syntax error \| want: 1991-1... |
| clock-34.43 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "monday": syntax error \| want: 1991-11-... |
| clock-34.44 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "monday": syntax error \| want: 1991-11-... |
| clock-34.45 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "2 monday": syntax error \| want: 1991-1... |
| clock-34.46 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "monday": syntax error \| want: 1991-11-... |
| clock-34.47 | `bug`: 'clock': the result differs | code 0/0,2: -165600 \| want: 180000 |
| clock-34.48 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/1: unable to convert date-time string "10:00 11:00": syntax error \| want: unabl... |
| clock-34.49 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/1: unable to convert date-time string "1/1/2001 2/2/2002": syntax error \| want:... |
| clock-34.5 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "Feb 14, 1992 12:20 PM": syntax error \|... |
| clock-34.50 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/1: unable to convert date-time string "10:00 EST CST": syntax error \| want: una... |
| clock-34.51 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/1: unable to convert date-time string "Monday Tuesday": syntax error \| want: un... |
| clock-34.52 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/1: unable to convert date-time string "next January next March": syntax error \|... |
| clock-34.53 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "19921023T00:00:00": syntax error \| wan... |
| clock-34.59 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "31 Jan 14 23:59:59 -0100": syntax error... |
| clock-34.60 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "31 Jan 14 23:59:59 +0100": syntax error... |
| clock-34.61 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "23:59:59 -0100": syntax error \| want: ... |
| clock-34.62 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "23:59:59 +0100": syntax error \| want: ... |
| clock-34.63 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "Mon, 30 Jun 2014 23:59:59 CEST": syntax... |
| clock-34.64 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "Fri, 31 Jan 2014 23:59:59 CET": syntax ... |
| clock-34.67 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "10:59 pm CET": syntax error \| want: Ja... |
| clock-34.68 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "10:59 pm +0100": syntax error \| want: ... |
| clock-34.7 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "Oct 23,1992 15:00 GMT": syntax error \|... |
| clock-34.9 | `bug`: 'clock': the result differs | code 0/0,2: 1 {bad option "-bad": must be -base, -format, -gmt, -locale or -timezone} \... |
| clock-36.1 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "next june": syntax error \| want: 06.2001 |
| clock-36.2 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "next july": syntax error \| want: 07.2000 |
| clock-36.3 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "next may": syntax error \| want: 05.2001 |
| clock-38.1 | `bug`: 'clock': the result differs | code 0/0,2: 00:00:00 \| want: 01:00:00 |
| clock-38.2 | `bug`: 'clock': the result differs | code 0/0,2: 0 \| want: 1 |
| clock-42.1 | `bug`: 'clock': the result differs | code 0/0,2: +0000 \| want: -0500 |
| clock-44.1 | `bug`: 'clock': the result differs | code 1/0,2: time zone "US/East-Indiana" not found \| want: 12:34:56-0500 |
| clock-46.2 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "20040000": syntax error \| want: 107015... |
| clock-46.4 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "20041301": syntax error \| want: 110453... |
| clock-46.5 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "12:01 am": syntax error \| want: 60 43260 |
| clock-46.6 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "13:00 am": syntax error \| want: 3600 4... |
| clock-47.1 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "0012": syntax error \| want: 1795738320 |
| clock-47.2 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "0039": syntax error \| want: 1795739940 |
| clock-52.2 | `bug`: 'clock': the result differs | code 0/0,2: 02:59:59 01:59:59 03:00:00 02:00:00 02:59:59 01:59:59 03:00:00 02:00:00 \| ... |
| clock-52.3 | `bug`: 'clock': the result differs | code 0/0,2: 02:59:59 03:00:00 02:59:59 03:00:00 \| want: 01:59:59 03:00:00 02:59:59 02:... |
| clock-55.5 | `bug`: 'clock': the result differs | code 1/0,2: input string does not match supplied format \| want: -62135769600 |
| clock-55.6 | `bug`: 'clock': the result differs | code 1/0,2: input string does not match supplied format \| want: -62135769600 |
| clock-55.8 | `bug`: 'clock': the result differs | code 1/0,2: input string does not match supplied format \| want: -62135856000 |
| clock-55.9 | `bug`: 'clock': the result differs | code 1/0,2: input string does not match supplied format \| want: -62135856000 |
| clock-56.1 | `internals`: a variable inside the clock library of Tcl | setup: can't read "::tcl::clock::ZoneinfoPaths": no such variable |
| clock-56.2 | `internals`: a variable inside the clock library of Tcl | setup: can't read "::tcl::clock::ZoneinfoPaths": no such variable |
| clock-56.3 | `internals`: a variable inside the clock library of Tcl | setup: can't read "::tcl::clock::ZoneinfoPaths": no such variable |
| clock-56.4 | `internals`: a variable inside the clock library of Tcl | setup: can't read "::tcl::clock::ZoneinfoPaths": no such variable |
| clock-58.1 | `bug`: 'clock': the result differs | code 0/0,2:  1872-12-31 converts to 12/31/1872 and should be \u897f\u66a61872\u5e7412\u... |
| clock-59.1 | `feature`: a form of 'clock scan' that ztcl does not parse | code 0/0,2: pzone Z ps2 is {unable to convert date-time string "20000101 000000 Z": syn... |
| clock-59.2 | `bug`: 'clock': the result differs | code 1/0,2: time zone "Etc/GMT-2" not found \| want: 1 1 1 1 1 1 1 1 1 1 1 1 |
| clock-6.0 | `bug`: 'clock': the result differs | code 0/0,2: -9223372036854775807 \| want: -9223372036854775808 |
| clock-6.10 | `bug`: 'clock': the result differs | code 0/0,2: 0 9223372036854775807 \| want: 1 {integer value too large to represent} |
| clock-6.9 | `bug`: 'clock': the result differs | code 0/0,2: 0 -9223372036854775807 \| want: 1 {integer value too large to represent} |
| clock-61.1 | `bug`: 'clock': the result differs | code 0/1: -9223372036854775808 \| want: integer value too large to represent |
| clock-61.2 | `message`: an error where tclsh also gives one, with another message | code 1/1: expected integer but got "-0x8000000000000001" \| want: integer value too lar... |
| clock-62.1 | `bug`: 'clock': the result differs | setup: invalid command name "::tcl::clock::ClearCaches" |
| clock-63.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "::tcl::clock::ConvertLocalToUTC" \| want: key "localsec... |
| clock-66.1 | `bug`: 'clock': the result differs | setup: invalid command name "::tcl::clock::ClearCaches" |
| clock-67.4 | `bug`: 'clock': the result differs | code 0/0,2: 0 1 \| want: 1 1 |
| clock-67.5 | `bug`: 'clock': the result differs | code 1/0,2: input string does not match supplied format \| want: 1 |
| clock-7.6 | `bug`: 'clock': the result differs | code 0/0,2: 0 253402300800 {CLOCK badInputString} \| want: 1 {requested date too large ... |
| clock-7.7 | `bug`: 'clock': the result differs | code 0/0,2: 0 185331720384000 {CLOCK badInputString} \| want: 1 {requested date too lar... |
| clock-9.2 | `bug`: 'clock': the result differs | code 0/0,2: 946684800 \| want: 0 |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 3 | `internals`: a variable or a command inside the clock library of Tcl |
| win | 7 | `platform`: a constraint of another platform or word size |

### cmdAH.test

| Test | Bucket | Result (start) |
|---|---|---|
| cmdAH-1.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| cmdAH-1.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| cmdAH-19.10 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: ~nOsUcHuSeR \| want: * |
| cmdAH-19.11 | `feature`: 'file attributes' | cleanup: file attributes is not available |
| cmdAH-2.3 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "env(HOME)": no such variable |
| cmdAH-2.4 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "env(HOME)": no such variable |
| cmdAH-2.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: couldn't change working directory to "~~": no such file or directory \| want:... |
| cmdAH-2.6.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: couldn't change working directory to "": no such file or directory |
| cmdAH-20.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: file atime with a new time is not available \| want: wrong # args: should be ... |
| cmdAH-20.4 | `message`: an error where tclsh also gives one, with another message | code 1/1: file atime with a new time is not available \| want: expected integer but got... |
| cmdAH-20.5 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: file atime with a new time is not available \| want: 1 |
| cmdAH-23.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't set "x(atime)": variable isn't array} NONE \| want: 1 {can't set "... |
| cmdAH-24.1 | `feature`: 'file mtime' and 'file atime' with a new time | code 1/1: file mtime with a new time is not available \| want: wrong # args: should be ... |
| cmdAH-24.12 | `feature`: a form of 'clock scan' that ztcl does not parse | code 1/0,2: unable to convert date-time string "21:00:00 October 30 2004 GMT": syntax e... |
| cmdAH-24.13 | `feature`: 'file mtime' and 'file atime' with a new time | code 1/0,2: file mtime with a new time is not available \| want: 0 1 |
| cmdAH-24.7 | `feature`: 'file mtime' and 'file atime' with a new time | code 1/1: file mtime with a new time is not available \| want: expected integer but got... |
| cmdAH-24.8 | `feature`: 'file mtime' and 'file atime' with a new time | code 1/0,2: file mtime with a new time is not available \| want: 1 |
| cmdAH-24.9 | `feature`: 'file mtime' and 'file atime' with a new time | code 1/0,2: file mtime with a new time is not available \| want: 1 |
| cmdAH-25.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 \| want: 0 |
| cmdAH-26.1 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not readlink: links are not available in the root folder \| want: wrong... |
| cmdAH-28.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0o644 \| want: 0o765 |
| cmdAH-28.7 | `message`: an error where tclsh also gives one, with another message | code 1/1: can't set "x(atime)": variable isn't array \| want: can't set "x(dev)": varia... |
| cmdAH-29.4 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: link |
| cmdAH-29.4.1 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: link |
| cmdAH-30.8 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: . \| want: user "woohgy" doesn't exist |
| cmdAH-31.10 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: can not find channel named "file25" \| want:  |
| cmdAH-31.11 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "file" \| want: {} file25 |
| cmdAH-31.12 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "file" \| want: file25 stdout |
| cmdAH-31.13 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "close" \| want: stdout |
| cmdAH-31.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: stderr stdin stdout |
| cmdAH-31.6 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "file" \| want:  |
| cmdAH-31.8 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "file" \| want: file25 file25 |
| cmdAH-31.9 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "file" \| want: file25 stdout |
| cmdAH-32.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: file26 \| want: wrong # args: should be "file tempfile ?nameVar? ?template?" |
| cmdAH-32.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: foo produced /tcl_tmp3 \| want: ok |
| cmdAH-32.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: /dir.file/foo produced /tcl_tmp4 \| want: ok |
| cmdAH-4.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "encoding option ?arg ...?" \| want: wrong # args: sh... |
| cmdAH-4.2 | `message`: an error where tclsh also gives one, with another message | code 1/1: bad option "foo": must be convertfrom, convertto, dirs, names, or system \| w... |
| cmdAH-5.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 \| want: 0 |
| cmdAH-6.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: / \| want: wrong # args: should be "file volumes" |
| cmdAH-7.1 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: * |
| cmdAH-9.52 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: ~foo ~foo ~foo ~foo \| want: ./~foo ./~foo ./~foo ./~foo |

| Skipped by | Tests | Bucket |
|---|---|---|
| testsetplatform | 145 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| win | 22 | `platform`: a constraint of another platform or word size |
| nonPortable | 8 | `tcl`: tclsh skips it too |
| testchmod | 5 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| filetime64bit | 2 | `platform`: a property of the host: a second device, a writable home, IPv6 on localhost, ... |

### cmdIL.test

| Test | Bucket | Result (start) |
|---|---|---|
| cmdIL-3.15 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {comparison error} {comparison error     while executing "error "comparis... |
| cmdIL-4.36 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 256 32 257 \| want: 257 32 256 |
| info-20.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |

| Skipped by | Tests | Bucket |
|---|---|---|
| hasIsoLocale | 2 | `internals`: a C test command or package of the Tcl test binary |
| memory | 2 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testWithLimit | 1 | `internals`: a C test command or package of the Tcl test binary |
| testobj | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### cmdInfo.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testcmdinfo | 9 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testcmdtoken | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### cmdMZ.test

| Test | Bucket | Result (start) |
|---|---|---|
| cmdMZ-return-1.0 | `bug`: the result differs from tclsh 8.6.16 | code 2/1:  \| want: bad -options value:* |
| cmdMZ-return-2.10 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {-code 1 -errorcode NONE -errorinfo {     while executing "return -level ... |
| cmdMZ-return-2.14 | `bug`: the result differs from tclsh 8.6.16 | code 1/3: bad completion code "foo": must be ok, error, return, break, continue, or an ... |
| cmdMZ-return-2.18 | `feature`: 'info errorstack' | code 1/0,2: unknown or ambiguous subcommand "errorstack": must be args, body, cmdcount,... |
| cmdMZ-return-2.8 | `bug`: the result differs from tclsh 8.6.16 | code 1/-1: bad completion code "-1": must be ok, error, return, break, continue, or an ... |

| Skipped by | Tests | Bucket |
|---|---|---|
| Unix | 1 | `platform`: a constraint of another platform or word size |

### compExpr-old.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testmathfunctions | 5 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| expr:!ieeeFloatingPoint | 1 | `platform`: needs a machine without IEEE floats |
| longIs32bit | 1 | `platform`: a constraint of another platform or word size |

### compExpr.test

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 2 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testmathfunctions | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### compile.test

| Test | Bucket | Result (start) |
|---|---|---|
| compile-13.2 | `bug`: the recursion limit and its message | setup: the recursion limit of this interpreter is 600 |
| compile-13.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 1 1 1 \| want:  |
| compile-18.1 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: wrong # args: s... |
| compile-18.10 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::disassemble" \| want: * |
| compile-18.11 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: wrong # args: s... |
| compile-18.12 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: nosuchclass doe... |
| compile-18.13 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: "justanobject" ... |
| compile-18.14 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: unknown method ... |
| compile-18.15 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::disassemble" \| want: * |
| compile-18.16 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: wrong # args: s... |
| compile-18.17 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: nosuchobject do... |
| compile-18.18 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: unknown method ... |
| compile-18.19 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::disassemble" \| want: * |
| compile-18.2 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: bad type "?": m... |
| compile-18.21 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: wrong # args: s... |
| compile-18.22 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: bad type "?": m... |
| compile-18.23 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: wrong # args: s... |
| compile-18.24 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: can't interpret... |
| compile-18.25 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.26 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: wrong # args: s... |
| compile-18.27 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: "nosuchproc" is... |
| compile-18.28 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.28.1 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.28.2 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.28.3 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.28.4 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.29 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: wrong # args: s... |
| compile-18.3 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: wrong # args: s... |
| compile-18.30 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.31 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: wrong # args: s... |
| compile-18.32 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: nosuchclass doe... |
| compile-18.33 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: "justanobject" ... |
| compile-18.34 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: unknown method ... |
| compile-18.35 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.36 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: wrong # args: s... |
| compile-18.37 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: nosuchobject do... |
| compile-18.38 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: unknown method ... |
| compile-18.39 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.4 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: can't interpret... |
| compile-18.40 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: wrong # args: s... |
| compile-18.41 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: nosuchclass doe... |
| compile-18.42 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: "justanobject" ... |
| compile-18.43 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: "constructorles... |
| compile-18.44 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::disassemble" \| want: * |
| compile-18.45 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: wrong # args: s... |
| compile-18.46 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: nosuchobject do... |
| compile-18.47 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: "constructorles... |
| compile-18.48 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.5 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::disassemble" \| want: * |
| compile-18.50 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: wrong # args: s... |
| compile-18.51 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: nosuchclass doe... |
| compile-18.52 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: "justanobject" ... |
| compile-18.53 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: "constructorles... |
| compile-18.54 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::disassemble" \| want: * |
| compile-18.55 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: wrong # args: s... |
| compile-18.56 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: nosuchobject do... |
| compile-18.57 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::getbytecode" \| want: "constructorles... |
| compile-18.58 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::getbytecode" \| want: literals vari... |
| compile-18.6 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: wrong # args: s... |
| compile-18.7 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: "nosuchproc" is... |
| compile-18.8 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::disassemble" \| want: * |
| compile-18.9 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/1: invalid command name "tcl::unsupported::disassemble" \| want: wrong # args: s... |
| compile-20.1 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::disassemble" \| want:  |
| compile-20.2 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "tcl::unsupported::disassemble" \| want:  |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 9 | `tcl`: tclsh skips it too |
| memory | 2 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### config.test

| Test | Bucket | Result (start) |
|---|---|---|
| pkgconfig-1.1 | `feature`: 'tcl::pkgconfig' | code 1/0,2: invalid command name "::tcl::pkgconfig" \| want: 64bit bindir,install bindi... |
| pkgconfig-1.2 | `feature`: 'tcl::pkgconfig' | code 1/0,2: invalid command name "::tcl::pkgconfig" \| want: 0 |
| pkgconfig-1.3 | `feature`: 'tcl::pkgconfig' | code 1/0,2: invalid command name "::tcl::pkgconfig" \| want: 0 |
| pkgconfig-2.0 | `feature`: 'tcl::pkgconfig' | code 0/0,2: invalid command name "::tcl::pkgconfig" \| want: wrong # args: should be ":... |
| pkgconfig-2.1 | `feature`: 'tcl::pkgconfig' | code 0/0,2: invalid command name "::tcl::pkgconfig" \| want: bad subcommand "foo": must... |
| pkgconfig-2.2 | `feature`: 'tcl::pkgconfig' | code 0/0,2: invalid command name "::tcl::pkgconfig" \| want: wrong # args: should be ":... |
| pkgconfig-2.3 | `feature`: 'tcl::pkgconfig' | code 0/0,2: invalid command name "::tcl::pkgconfig" \| want: wrong # args: should be ":... |
| pkgconfig-2.4 | `feature`: 'tcl::pkgconfig' | code 0/0,2: invalid command name "::tcl::pkgconfig" \| want: key not known |
| pkgconfig-2.5 | `feature`: 'tcl::pkgconfig' | code 0/0,2: invalid command name "::tcl::pkgconfig" \| want: wrong # args: should be ":... |

### coroutine.test

| Test | Bucket | Result (start) |
|---|---|---|
| coroutine-10.1 | `bug`: coroutines: the result differs | code 1/0,2: namespace "tcl::unsupported" not found in "::" \| want: ok ok {abc ::cbody1... |
| coroutine-3.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| coroutine-3.5 | `bug`: coroutines: the result differs | code 0/0,2: ::foo \| want:  |
| coroutine-3.6 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| coroutine-3.7 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| coroutine-4.4 | `bug`: coroutines: the result differs | code 0/0,2: global \| want: local |
| coroutine-7.10 | `bug`: coroutines: the result differs | code 2/1: a OUT b 123 c \| want: yieldto called in deleted namespace |
| coroutine-7.11 | `bug`: coroutines: the result differs | code 2/1: a OUT b 123 c \| want: yieldto called in deleted namespace |
| coroutine-7.4 | `bug`: coroutines: the result differs | code 0/0,2:  \| want: b a |
| coroutine-7.5 | `bug`: coroutines: the result differs | code 0/0,2: 0 1 0 3 4 5 \| want: 0 1 2 3 4 5 |
| coroutine-7.8 | `bug`: coroutines: the result differs | code 2/1: a OUT b 123 c \| want: yieldto called in deleted namespace |
| coroutine-7.9 | `bug`: coroutines: the result differs | code 2/1: a OUT b 123 c \| want: yieldto called in deleted namespace |
| coroutine-8.0.0 | `feature`: 'tcl::unsupported::inject' and 'corotype' | code 1/0,2: invalid command name "tcl::unsupported::inject" \| want: inject-executed |
| coroutine-8.0.1 | `feature`: 'tcl::unsupported::inject' and 'corotype' | code 1/0,2: invalid command name "tcl::unsupported::inject" \| want: inject-executed 1 ... |
| coroutine-8.1.1 | `feature`: 'tcl::unsupported::inject' and 'corotype' | code 1/0,2: invalid command name "tcl::unsupported::inject" \| want:  |
| coroutine-8.1.2 | `bug`: coroutines: the result differs | code 1/0,2: interpreter named "child" already exists, cannot create \| want: inject-exe... |
| coroutine-9.1 | `feature`: 'tcl::unsupported::inject' and 'corotype' | code 1/0,2: invalid command name "::tcl::unsupported::corotype" \| want: {PHASE 1} yiel... |
| coroutine-9.2 | `feature`: 'tcl::unsupported::inject' and 'corotype' | code 1/1: invalid command name "::tcl::unsupported::corotype" \| want: can only get cor... |
| coroutine-9.3 | `feature`: 'tcl::unsupported::inject' and 'corotype' | code 1/1: invalid command name "::tcl::unsupported::corotype" \| want: can only get cor... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testnrelevels | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| memory | 1 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### dcall.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testdcall | 6 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### dict.test

| Test | Bucket | Result (start) |
|---|---|---|
| dict-14.12 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 test 1 {test     while executing "error test"     invoked from within "di... |
| dict-17.13 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 x {x     while executing "error x"     invoked from within "dict filter {... |
| dict-20.21 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: a b c d \| want:  a b c d  |
| dict-20.22 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: a b c d \| want:  a b c d  |
| dict-22.10 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: key "b" not known in dictionary \| want: 0 {} |
| dict-23.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.10 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.11 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.12 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.13 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.14 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.3 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "tcl::dict::lappend" \| want: bar baz |
| dict-23.4 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.5 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "tcl::dict::incr" \| want: bar 1 |
| dict-23.6 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.7 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.8 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-23.9 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-24.12 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 test 1 {test     while executing "error test"     invoked from within "di... |
| dict-24.20.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-24.21 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| dict-4.13a | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: NONE \| want: TCL VALUE DICTIONARY |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 2 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### dstring.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testdstring | 44 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### encoding.test

| Test | Bucket | Result (start) |
|---|---|---|
| encoding-24.3 | `bug`: encodings: the result differs | code 0/0,2: 9 { (\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000)} \| want: 3 {乎... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testencoding | 13 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| ucs2 | 2 | `platform`: a constraint of another platform or word size |
| testbytestring | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testgetdefenc | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| teststringbytes | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### env.test

| Test | Bucket | Result (start) |
|---|---|---|
| env-1.1 | `design`: the suite runs without the 'env' capability, so 'env' is ... | code 1/0,2: can't read "env(test)": no such variable \| want: garbage |
| env-1.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| env-2.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: NAME1=test string |
| env-2.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: NAME1=test string NAME2=more |
| env-2.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: NAME1=test string NAME2=more XYZZY=garbage |
| env-3.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: NAME1=test string NAME2=new value XYZZY=garbage |
| env-4.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: NAME1=test string XYZZY=garbage |
| env-4.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: \u00a7=\u00b6 |
| env-4.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: \u00a7=\u00a7 |
| env-4.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: \u00b6=\u00a7 |
| env-5.2 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: can't unset "env": no such variable \| want: 0 |
| env-5.3 | `design`: the suite runs without the 'env' capability, so 'env' is ... | code 1/0,2: can't read "env(THIS_SHOULD_EXIST)": no such element in array \| want: a 1 |
| env-5.4 | `design`: the suite runs without the 'env' capability, so 'env' is ... | code 1/0,2: can't read "env(THIS_SHOULD_EXIST)": no such element in array \| want: 1 a 1 |
| env-7.2 | `design`: the suite runs without the 'env' capability, so 'env' is ... | code 1/0,2: can't read "::env(PATH)": no such element in array \| want: ok |

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 4 | `platform`: a constraint of another platform or word size |

### error.test

| Test | Bucket | Result (start) |
|---|---|---|
| error-1.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: wrong # args: should be "string index string charIndex"     while executing... |
| error-19.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: wrong # args to on clause: must be "... on code variableList script" \| wan... |
| error-2.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: glorp2     while executing "error glorp2"     invoked from within "format [... |
| error-20.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: a b c \| want: bad completion code "34985723094872345": must be ok, error, re... |
| error-4.6 | `feature`: 'info errorstack' | code 1/0,2: unknown or ambiguous subcommand "errorstack": must be args, body, cmdcount,... |
| error-4.7 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: key "-errorstack" not known in dictionary \| want: INNER * CALL {g 1212} CA... |
| error-4.8 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: key "-errorstack" not known in dictionary \| want: INNER {error bar} CALL g... |
| error-6.10 | `feature`: 'info errorstack' | code 1/0,2: unknown or ambiguous subcommand "errorstack": must be args, body, cmdcount,... |
| error-7.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: namespace \| want: *BadProc* |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 8 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### eval.test

| Test | Bucket | Result (start) |
|---|---|---|
| eval-2.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: test error     while executing "error "test error""     invoked from within... |

### event.test

| Test | Bucket | Result (start) |
|---|---|---|
| event-7.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: hello     while executing "error hello"     ("after" script) \| want: hello  ... |
| event-7.7 | `bug`: the result differs from tclsh 8.6.16 | code 2/0,2: foo baz soom     (procedure "bgerror" line 1)     invoked from within "bger... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testfilehandler | 22 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testexithandler | 5 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testfilewait | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### exec.test

| Test | Bucket | Result (start) |
|---|---|---|
| exec-11.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: foo |
| exec-14.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: foo bar \| want: foo bar bar |
| exec-18.2 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: cat: '/foo[{blah': No such file or directory \| want: contents |
| exec-6.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: second msg \| want: second msg foo bar |

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 5 | `platform`: a constraint of another platform or word size |
| nonPortable | 4 | `tcl`: tclsh skips it too |

### execute.test

| Test | Bucket | Result (start) |
|---|---|---|
| execute-10.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 4 |
| execute-6.11 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "load" \| want: {This is a result: 1} {This is a resul... |
| execute-8.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: These differ: bar     while executing "error bar"     (procedure "foo" line... |
| execute-8.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: -code 1 -level 0 -errorcode NONE -errorinfo {FOO     while executing "error... |
| execute-8.6 | `bug`: the setup or the cleanup of the test fails | setup: can't find package tcltest 2.5 |
| execute-8.7 | `bug`: the setup or the cleanup of the test fails | setup: can't find package tcltest 2.5 |

| Skipped by | Tests | Bucket |
|---|---|---|
| testobj | 77 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| longIs32bit | 3 | `platform`: a constraint of another platform or word size |

### expr-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| expr-old-32.48 | `bug`: 'expr': the result differs | code 0/1: 0.8653658439782821 \| want: * |
| expr-old-32.50 | `bug`: 'expr': the result differs | code 0/0,2: 550 771 304 670 611 265 48 660 808 388 456 \| want: 97 834 948 36 12 51 766... |
| expr-old-34.3 | `bug`: 'expr': the result differs | code 0/0,2: 1 {can't use non-numeric string as operand of "hypot"} \| want: 1 {expected... |
| expr-old-36.7 | `bug`: 'expr': the result differs | code 0/0,2: 0 NaN \| want: 1 {domain error: argument not in valid range} |
| expr-old-37.18 | `bug`: 'expr': the result differs | code 1/0,2: empty expression in expression "" \| want: This is a result: 0.0 |
| expr-old-37.20 | `bug`: 'expr': the result differs | code 1/0,2: expected floating-point number but got "10000000000000000000000000000000000... |
| expr-old-37.22 | `bug`: 'expr': the result differs | code 1/0,2: expected floating-point number but got "17976931348623157000000000000000000... |
| expr-old-37.24 | `bug`: 'expr': the result differs | code 1/0,2: expected floating-point number but got "17976931348623165000000000000000000... |
| expr-old-37.25 | `bug`: 'expr': the result differs | code 0/0,2: 0 {This is a result: NaN} \| want: 1 {domain error: argument not in valid r... |
| expr-old-37.3 | `bug`: 'expr': the result differs | code 1/0,2: empty expression in expression "" \| want: This is a result: 0 |
| expr-old-38.2 | `bug`: 'expr': the result differs | code 1/0,2: empty expression in expression "" \| want: 0 |

| Skipped by | Tests | Bucket |
|---|---|---|
| longIs32bit | 10 | `platform`: a constraint of another platform or word size |
| expr:!ieeeFloatingPoint | 3 | `platform`: needs a machine without IEEE floats |
| testmathfunctions | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### expr.test

| Test | Bucket | Result (start) |
|---|---|---|
| expr-22.5 | `bug`: 'expr': the result differs | code 0/0,2: 0 NaN \| want: 1 {domain error: argument not in valid range} |
| expr-29.1 | `bug`: 'expr': the result differs | code 0/0,2: 0 0x0000000000000001 0 0x0000000000000000 0 0x0000000000000000 \| want: 0 0... |
| expr-29.2 | `bug`: 'expr': the result differs | code 0/0,2: 0 0x8000000000000001 0 0x8000000000000000 0 0x8000000000000000 \| want: 0 0... |
| expr-38.11 | `bug`: 'expr': the result differs | code 0/0,2: 0 \| want:   0x0 |
| expr-38.13 | `bug`: 'expr': the result differs | code 0/0,2: 0.0 \| want: 1e-324 |
| expr-39.1 | `bug`: 'expr': the result differs | code 0/0,2: 5 \| want: This is a result: 5 |
| expr-39.14 | `bug`: 'expr': the result differs | code 0/0,2: -2147483648 \| want: This is a result: -2147483648 |
| expr-39.17 | `bug`: 'expr': the result differs | code 0/0,2: 5.0 \| want: This is a result: 5.0 |
| expr-39.19 | `bug`: 'expr': the result differs | code 0/0,2: 1e+17 \| want: This is a result: 1e+17 |
| expr-39.2 | `bug`: 'expr': the result differs | code 0/0,2: 3 \| want: This is a result: 3 |
| expr-39.20 | `bug`: 'expr': the result differs | code 1/0,2: expected floating-point number but got "10000000000000000000000000000000000... |
| expr-39.21 | `bug`: 'expr': the result differs | code 0/0,2: 1.7976931348623157e+308 \| want: This is a result: 1.7976931348623157e+308 |
| expr-39.22 | `bug`: 'expr': the result differs | code 1/0,2: expected floating-point number but got "17976931348623157000000000000000000... |
| expr-39.23 | `bug`: 'expr': the result differs | code 0/0,2: Inf \| want: This is a result: Inf |
| expr-39.24 | `bug`: 'expr': the result differs | code 1/0,2: expected floating-point number but got "17976931348623165000000000000000000... |
| expr-39.25 | `bug`: 'expr': the result differs | code 0/0,2: 0 NaN \| want: 1 {domain error: argument not in valid range} |
| expr-39.4 | `bug`: 'expr': the result differs | code 0/0,2: 3 \| want: This is a result: 3 |
| expr-39.8 | `bug`: 'expr': the result differs | code 0/0,2: -2147483648 \| want: This is a result: -2147483648 |
| expr-45.8 | `bug`: 'expr': the result differs | code 0/0,2: 1 {can't use non-numeric floating-point value as operand of "entier"} \| wa... |
| expr-45.9 | `bug`: 'expr': the result differs | code 0/0,2: 1 {can't use non-numeric floating-point value as operand of "entier"} \| wa... |
| expr-47.2 | `bug`: 'expr': the result differs | code 0/0,2: 1 {can't use non-numeric string as operand of "isqrt"} \| want: 1 {expected... |
| expr-47.3 | `bug`: 'expr': the result differs | code 0/0,2: 1 {can't use non-numeric floating-point value as operand of "isqrt"} \| wan... |
| expr-50.1 | `bug`: 'expr': the result differs | code 0/0,2: 0 \| want: 1 |
| expr-52.1 | `bug`: 'expr': the result differs | code 1/0,2: invalid command name "::tcl::unsupported::representation" \| want: 0 0 1 1 |
| expr-8.17 | `bug`: 'expr': the result differs | code 0/0,2: 1 \| want: 0 |
| expr-8.22 | `bug`: 'expr': the result differs | code 0/1: 1 \| want: * |
| expr-8.23 | `bug`: 'expr': the result differs | code 0/1: 0 \| want: * |

| Skipped by | Tests | Bucket |
|---|---|---|
| longIs32bit | 18 | `platform`: a constraint of another platform or word size |
| testmathfunctions | 11 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| expr:!ieeeFloatingPoint | 5 | `platform`: needs a machine without IEEE floats |

### fCmd.test

| Test | Bucket | Result (start) |
|---|---|---|
| fCmd-10.10 | `message`: an error where tclsh also gives one, with another message | code 1/1: error copying "tf1": illegal operation on a directory \| want: can't overwrit... |
| fCmd-10.11 | `message`: an error where tclsh also gives one, with another message | code 1/1: error copying "tf1" to "": target file exists \| want: error copying "tf1" to... |
| fCmd-10.12 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "tf1" to "": target file exists \| want: error renaming "tf1" ... |
| fCmd-10.9 | `message`: an error where tclsh also gives one, with another message | code 1/1: can't create directory "td1": file already exists \| want: can't overwrite fi... |
| fCmd-11.4 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "::env(HOME)": no such variable |
| fCmd-12.1 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "::env(HOME)": no such variable |
| fCmd-12.2 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "::env(HOME)": no such variable |
| fCmd-12.8 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: 1 |
| fCmd-13.5 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "::env(HOME)": no such variable |
| fCmd-14.1 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "::env(HOME)": no such variable |
| fCmd-14.2 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "::env(HOME)": no such variable |
| fCmd-14.8 | `feature`: 'file attributes' | cleanup: file attributes is not available |
| fCmd-15.1 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "::env(HOME)": no such variable |
| fCmd-15.4 | `feature`: 'file attributes' | cleanup: file attributes is not available |
| fCmd-16.6 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "::env(HOME)": no such variable |
| fCmd-16.9 | `feature`: 'file attributes' | cleanup: file attributes is not available |
| fCmd-17.1 | `feature`: 'file attributes' | cleanup: file attributes is not available |
| fCmd-18.12 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: link |
| fCmd-18.13 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: link |
| fCmd-18.14 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: 1 0 |
| fCmd-18.15 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: 1 |
| fCmd-18.16 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: link |
| fCmd-19.2 | `feature`: 'file attributes' | cleanup: file attributes is not available |
| fCmd-20.1 | `feature`: 'file attributes' | cleanup: file attributes is not available |
| fCmd-21.12 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 1 1 \| want: 1 1 1 |
| fCmd-21.7.2 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: link |
| fCmd-21.8.2 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: link li... |
| fCmd-21.9 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: link |
| fCmd-26.1 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: 1 0 |
| fCmd-26.2 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: 1 0 |
| fCmd-26.3 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: 0 0 |
| fCmd-27.3 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: ?* |
| fCmd-27.4 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: * |
| fCmd-27.5 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want:  |
| fCmd-27.6 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want:  |
| fCmd-28.1 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not link: links are not available in the root folder \| want: wrong # a... |
| fCmd-28.10 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not link: links are not available in the root folder \| want: could not... |
| fCmd-28.10.1 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not link: links are not available in the root folder \| want: could not... |
| fCmd-28.11 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: abc.dir |
| fCmd-28.12 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: ok |
| fCmd-28.13 | `design`: 'file link' is outside the root folder model of the file ... | setup: could not link: links are not available in the root folder |
| fCmd-28.15.2 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: link ab... |
| fCmd-28.16 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: abc.fil... |
| fCmd-28.17 | `design`: 'file link' is outside the root folder model of the file ... | setup: could not link: links are not available in the root folder |
| fCmd-28.18 | `design`: 'file link' is outside the root folder model of the file ... | setup: could not link: links are not available in the root folder |
| fCmd-28.2 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not link: links are not available in the root folder \| want: wrong # a... |
| fCmd-28.20 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not link: links are not available in the root folder \| want: could not... |
| fCmd-28.21 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: d2 |
| fCmd-28.22 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: d2/d3 |
| fCmd-28.3 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not link: links are not available in the root folder \| want: bad optio... |
| fCmd-28.4 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not link: links are not available in the root folder \| want: bad optio... |
| fCmd-28.5 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not link: links are not available in the root folder \| want: could not... |
| fCmd-28.7 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not link: links are not available in the root folder \| want: could not... |
| fCmd-28.9 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: abc.file |
| fCmd-3.14 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "~_totally_bogus_user": no such file or directory \| want: use... |
| fCmd-3.15 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "/": permission denied \| want: error renaming "/" to "td1": f... |
| fCmd-3.16 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "tf3" to "td1": target file exists \| want: error renaming "tf... |
| fCmd-3.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "xyz": no such file or directory \| want: user "_totally_bogus... |
| fCmd-4.14 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: can't create directory "foo/tf1": p... |
| fCmd-4.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: user "_totally_bogus_user" doesn't exist |
| fCmd-4.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: can't create directory "": no such file or directory |
| fCmd-5.12 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: 0 0 {} |
| fCmd-5.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: user "_totally_bogus_user" doesn't exist |
| fCmd-5.7 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: couldn't open "~/tf1": no such file or directory \| want:  |
| fCmd-6.10 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "tf1" to "tf2": target file exists \| want: error renaming "tf... |
| fCmd-6.11 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "tf1" to "tf2": target file exists \| want: error renaming "tf... |
| fCmd-6.13 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "td1" to "td2": not a directory \| want: can't overwrite file ... |
| fCmd-6.14 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "tf1" to "td1": illegal operation on a directory \| want: can'... |
| fCmd-6.16 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "td2" to "td1": file already exists \| want: error renaming "t... |
| fCmd-6.17 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "/": permission denied \| want: error renaming "/" to "tf1": t... |
| fCmd-6.18 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "td2" to "td1": file already exists \| want: error renaming "t... |
| fCmd-6.24 | `feature`: 'file attributes' | cleanup: file attributes is not available |
| fCmd-6.25 | `feature`: 'file attributes' | cleanup: file attributes is not available |
| fCmd-6.30 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: *: permission denied |
| fCmd-7.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "--" \| want: no files matched glob patterns "-... |
| fCmd-8.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 \| want: 0 |
| fCmd-8.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: error copying "~" to "this/file/doesnt/exist": no such file or dire... |
| fCmd-9.1 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: error renaming "td1" to "td2/td1": ... |
| fCmd-9.13 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "td1" to "td2": file already exists \| want: error renaming "t... |
| fCmd-9.14 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: td1 {1 {error renaming "td1" to "td1": invalid argument}} \| want: td1 {1 {... |
| fCmd-9.14.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "../td1" to "../td1/foo": invalid argument \| want: error rena... |
| fCmd-9.15 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "td1" to "tf1": not a directory \| want: can't overwrite file ... |
| fCmd-9.16 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "tf1" to "td1": illegal operation on a directory \| want: can'... |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1 | `design`: the suite runs without the 'env' capability, so 'env(HOME)' is not set |
| testchmod | 19 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| win | 11 | `platform`: a constraint of another platform or word size |
| xdev | 6 | `platform`: a property of the host: a second device, a writable home, IPv6 on localhost, ... |
| dontCopyLinks | 3 | `design`: 'file link' is outside the root folder model of the file capability |
| notNetworkFilesystem | 3 | `tcl`: the test file sets the constraint false, or it is false in tclsh 8.6 on Linux |
| emptyTest | 2 | `tcl`: tclsh skips it too |
| knownBug | 1 | `tcl`: tclsh skips it too |
| nonPortable | 1 | `tcl`: tclsh skips it too |
| testsetplatform | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| winLessThan10 | 1 | `platform`: a constraint of another platform or word size |

### fileName.test

| Test | Bucket | Result (start) |
|---|---|---|
| fileName-20.10 | `bug`: file names and 'glob': the result differs | code 0/0,2:  \| want: ~/sub/fileName-20.10 |
| fileName-20.6 | `bug`: file names and 'glob': the result differs | setup: couldn't open "~/test": no such file or directory |
| fileName-20.8 | `bug`: file names and 'glob': the result differs | code 0/0,2: ~test \| want: ./~test |
| fileName-20.9 | `bug`: file names and 'glob': the result differs | setup: couldn't open "~/test": no such file or directory |
| filename-11.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "glob ?switches? name ?name ...?" \| want: no files m... |
| filename-11.14 | `bug`: file names and 'glob': the result differs | code 1/0,2: no files matched glob pattern "~/globTest" \| want: /tcl3842262/globTest |
| filename-11.15 | `bug`: file names and 'glob': the result differs | code 1/0,2: no files matched glob pattern "~\/globTest" \| want: /tcl3842262/globTest |
| filename-11.17.2 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: globTes... |
| filename-11.17.3 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: globTes... |
| filename-11.17.4 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: globTes... |
| filename-11.17.7 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: globTes... |
| filename-11.17.8 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: globTes... |
| filename-11.18 | `bug`: file names and 'glob': the result differs | code 0/0,2: globTest/a1 globTest/a2 globTest/a3 globTest/nonexistent {globTest/weird na... |
| filename-11.19 | `bug`: file names and 'glob': the result differs | code 0/0,2: globTest globTest \| want: globTest/a1 globTest/a2 globTest/a3 {globTest/we... |
| filename-11.20 | `bug`: file names and 'glob': the result differs | code 0/0,2: globTest/a1 globTest/a2 globTest/a3 globTest/nonexistent \| want: globTest/... |
| filename-11.21.1 | `bug`: file names and 'glob': the result differs | code 1/0,2: no files matched glob pattern "*" \| want: {[tcl].testremains} |
| filename-11.22 | `bug`: file names and 'glob': the result differs | code 0/0,2: glob\[\{Test/a1 glob\[\{Test/a2 glob\[\{Test/a3 glob\[\{Test/nonexistent gl... |
| filename-11.23 | `bug`: file names and 'glob': the result differs | code 1/0,2: unmatched open-brace in file name \| want: glob\[\{Test/a1 glob\[\{Test/a2 ... |
| filename-11.24 | `bug`: file names and 'glob': the result differs | code 1/0,2: unmatched open-brace in file name \| want: glob\[\{Test/a1 glob\[\{Test/a2 ... |
| filename-11.25 | `bug`: file names and 'glob': the result differs | code 0/0,2: glob\[\{Test/a1 glob\[\{Test/a2 glob\[\{Test/a3 glob\[\{Test/nonexistent \|... |
| filename-11.25.1 | `bug`: file names and 'glob': the result differs | code 0/0,2: glob\[\{Test/a1 glob\[\{Test/a2 glob\[\{Test/a3 glob\[\{Test/nonexistent gl... |
| filename-11.25.2 | `bug`: file names and 'glob': the result differs | code 0/0,2: glob\[\{Test/a1 glob\[\{Test/a2 glob\[\{Test/a3 glob\[\{Test/nonexistent gl... |
| filename-11.26 | `bug`: file names and 'glob': the result differs | code 1/0,2: unmatched open-brace in file name \| want: glob\[\{Test |
| filename-11.27 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: bad argument to "-types": abcde |
| filename-11.28 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: bad argument to "-types": z |
| filename-11.29 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: only one MacOS type or creator arg... |
| filename-11.3 | `bug`: file names and 'glob': the result differs | code 1/0,2: wrong # args: should be "glob ?switches? name ?name ...?" \| want:  |
| filename-11.30 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: only one MacOS type or creator arg... |
| filename-11.32 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: "-directory" cannot be used with "... |
| filename-11.36 | `bug`: file names and 'glob': the result differs | code 0/1: glob\[\{Test ~test.txt \| want: "-tails" must be used with either "-directory... |
| filename-11.37 | `bug`: file names and 'glob': the result differs | code 1/0,2: unmatched open-brace in file name \| want: glob\[\{Test |
| filename-11.38 | `bug`: file names and 'glob': the result differs | code 1/0,2: unmatched open-brace in file name \| want: glob\[\{Test |
| filename-11.39 | `bug`: file names and 'glob': the result differs | code 1/0,2: unmatched open-brace in file name \| want: glob\[\{Test |
| filename-11.4 | `bug`: file names and 'glob': the result differs | code 1/0,2: wrong # args: should be "glob ?switches? name ?name ...?" \| want:  |
| filename-11.43 | `message`: an error where tclsh also gives one, with another message | code 1/1: bad option "-t": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-11.44 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: "-directory" cannot be used with "... |
| filename-11.46 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: bad argument to "-types": abcde |
| filename-11.47 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: bad argument to "-types": abcde |
| filename-11.48 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: bad argument to "-types": abcde |
| filename-11.49 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: bad argument to "-types": abcde |
| filename-11.5 | `bug`: file names and 'glob': the result differs | code 0/1: all.tcl fileName.test httpTest.tcl httpTestScript.tcl httpd httpd11.tcl inter... |
| filename-11.50 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: "-path" may only be used once |
| filename-11.51 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "*" \| want: "-directory" may only be used once |
| filename-11.6 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "~xyqrszzz" \| want: user "xyqrszzz" doesn't exist |
| filename-12.1 | `bug`: file names and 'glob': the result differs | code 0/0,2: {} \| want: . |
| filename-12.1.2 | `bug`: file names and 'glob': the result differs | code 0/0,2: {} \| want: . |
| filename-12.1.3 | `bug`: file names and 'glob': the result differs | code 1/0,2: no files matched glob pattern "" \| want: . |
| filename-12.5 | `bug`: file names and 'glob': the result differs | code 1/0,2: no files matched glob pattern "globTest\/x1.c" \| want: globTest/x1.c |
| filename-12.6 | `bug`: file names and 'glob': the result differs | code 1/0,2: no files matched glob pattern "globTest\/\x1.c" \| want: globTest/x1.c |
| filename-13.1 | `bug`: file names and 'glob': the result differs | code 0/0,2: globTest \| want: globTest/ |
| filename-13.11 | `bug`: file names and 'glob': the result differs | code 0/0,2: globTest/x1.c globTest/x1.c globTest/z1.c globTest/z1.c \| want: globTest/x... |
| filename-13.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "globTest/{\}" \| want: unmatched open-brace in... |
| filename-13.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "globTest/}" \| want: unmatched close-brace in ... |
| filename-14.15 | `bug`: file names and 'glob': the result differs | code 0/0,2: globTest/a1 globTest/a2 globTest/a3 globTest/nonexistent {globTest/weird na... |
| filename-14.17 | `bug`: file names and 'glob': the result differs | code 1/0,2: no files matched glob pattern "~/z*" \| want: /tcl3842262/globTest/z1.c |
| filename-14.22 | `message`: an error where tclsh also gives one, with another message | code 1/1: no files matched glob pattern "goo/*" \| want: no files matched glob patterns... |
| filename-14.26 | `bug`: file names and 'glob': the result differs | code 0/0,2: globTest/a1 globTest/a2 globTest/a3 globTest/nonexistent {globTest/weird na... |
| filename-14.30 | `bug`: file names and 'glob': the result differs | code 0/0,2: globTest/a1 \| want: globTest/a1/ |
| filename-14.7 | `bug`: file names and 'glob': the result differs | code 0/0,2: globTest/a1 globTest/a2 globTest/a3 globTest/nonexistent {globTest/weird na... |
| filename-14.9 | `bug`: file names and 'glob': the result differs | code 0/0,2: globTest/.1 \| want: globTest/. globTest/.. globTest/.1 |
| filename-15.4.1 | `bug`: file names and 'glob': the result differs | code 0/0,2: 0 {} 0 {} \| want: 1 {user "wontexist" doesn't exist} 1 {user "blahxyz" doe... |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 5 | `feature`: 'info hostname', and '~' with no 'env(HOME)' |
| testsetplatform | 133 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| win | 35 | `platform`: a constraint of another platform or word size |
| nonPortable | 7 | `tcl`: tclsh skips it too |
| testtranslatefilename | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### fileSystem.test

| Test | Bucket | Result (start) |
|---|---|---|
| filesystem-1.30 | `bug`: file names and 'glob': the result differs | code 0/1: /~noonewiththisname \| want: user "noonewiththisname" doesn't exist |
| filesystem-1.30.2 | `bug`: file names and 'glob': the result differs | code 0/1: /~nonexistentuser@nonexistentdomain \| want: user "nonexistentuser@nonexisten... |
| filesystem-1.30.3 | `design`: the suite runs without the 'env' capability, so 'env' is ... | setup: can't read "::env(HOME)": no such variable |
| filesystem-1.34 | `bug`: file names and 'glob': the result differs | code 0/0,2: /foo/bar/anc/.tml \| want: ^(?:(?!/\./).)*$ |
| filesystem-1.35a | `bug`: file names and 'glob': the result differs | code 0/0,2: /ffo/bar/anc/foo/.tml \| want: ^(?:(?!/\./).)*$ |
| filesystem-1.36a | `bug`: file names and 'glob': the result differs | code 0/0,2: /foo/bar/anc/asdasd/.tml \| want: ^(?:(?!/\./).)*$ |
| filesystem-1.45 | `bug`: file names and 'glob': the result differs | code 1/0,2: couldn't access "/xxx/../../bar": permission denied \| want: ok |
| filesystem-1.47 | `bug`: file names and 'glob': the result differs | code 1/0,2: couldn't access "/..": permission denied \| want: ok |
| filesystem-1.48 | `bug`: file names and 'glob': the result differs | code 1/0,2: couldn't access "/../": permission denied \| want: ok |
| filesystem-1.51 | `bug`: file names and 'glob': the result differs | code 1/0,2: couldn't access "/../..": permission denied \| want: ok |
| filesystem-1.51.1 | `bug`: file names and 'glob': the result differs | code 1/0,2: couldn't access "/../../": permission denied \| want: ok |
| filesystem-1.53 | `bug`: file names and 'glob': the result differs | code 0/0,2: 1 \| want: 0 |
| filesystem-6.1 | `bug`: file names and 'glob': the result differs | code 0/1: file6 \| want: couldn't open "": no such file or directory |
| filesystem-6.11 | `bug`: file names and 'glob': the result differs | code 0/0,2: 1 \| want: 0 |
| filesystem-6.14 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not link: links are not available in the root folder \| want: could not... |
| filesystem-6.15 | `bug`: file names and 'glob': the result differs | code 0/1:  \| want: could not read "": no such file or directory |
| filesystem-6.16 | `bug`: file names and 'glob': the result differs | code 0/1: 1795775940 \| want: could not read "": no such file or directory |
| filesystem-6.17 | `feature`: 'file mtime' and 'file atime' with a new time | code 1/1: file mtime with a new time is not available \| want: could not read "": no su... |
| filesystem-6.18 | `bug`: file names and 'glob': the result differs | code 0/1:  \| want: can't create directory "": no such file or directory |
| filesystem-6.2 | `bug`: file names and 'glob': the result differs | code 0/1:  \| want: could not read "": no such file or directory |
| filesystem-6.20 | `bug`: file names and 'glob': the result differs | code 0/0,2: / \| want:  |
| filesystem-6.21 | `bug`: file names and 'glob': the result differs | code 0/0,2: 1 \| want: 0 |
| filesystem-6.23 | `bug`: file names and 'glob': the result differs | code 0/0,2: 1 \| want: 0 |
| filesystem-6.24 | `design`: 'file link' is outside the root folder model of the file ... | code 1/1: could not readlink: links are not available in the root folder \| want: could... |
| filesystem-6.25 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "" to "": target file exists \| want: error renaming "": no su... |
| filesystem-6.27 | `bug`: file names and 'glob': the result differs | code 0/1: / \| want: unrecognised path |
| filesystem-6.28 | `bug`: file names and 'glob': the result differs | code 0/1: 280 \| want: could not read "": no such file or directory |
| filesystem-6.3 | `bug`: file names and 'glob': the result differs | code 0/1: 1795775940 \| want: could not read "": no such file or directory |
| filesystem-6.30 | `bug`: file names and 'glob': the result differs | code 0/1: native root \| want: unrecognised path |
| filesystem-6.32 | `bug`: file names and 'glob': the result differs | code 0/1: directory \| want: could not read "": no such file or directory |
| filesystem-6.33 | `bug`: file names and 'glob': the result differs | code 0/0,2: 1 \| want: 0 |
| filesystem-6.34 | `bug`: file names and 'glob': the result differs | code 0/0,2: 1 {couldn't open "foo": permission denied} \| want: 1 {couldn't open "foo":... |
| filesystem-6.4 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: could not read "": no such file or ... |
| filesystem-6.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: error copying "" to "": target file exists \| want: error copying "": no such... |
| filesystem-6.6 | `bug`: file names and 'glob': the result differs | code 1/0,2: error deleting "": permission denied \| want:  |
| filesystem-6.8 | `bug`: file names and 'glob': the result differs | code 0/0,2: 1 \| want: 0 |
| filesystem-6.9 | `bug`: file names and 'glob': the result differs | code 0/0,2: 1 \| want: 0 |
| filesystem-9.7 | `bug`: file names and 'glob': the result differs | code 0/0,2: 1 0 ~testNotExist ~testNotExist 1 0 ~testNotExist 0 ~testNotExist \| want: ... |
| filesystem-9.8 | `bug`: file names and 'glob': the result differs | code 0/0,2: ~testNotExist ~testNotExist 0 ~testNotExist 0 ~testNotExist \| want: ~testN... |
| filesystem-9.9 | `bug`: file names and 'glob': the result differs | code 0/0,2: 0 1 0 1 1 \| want: 0 0 0 0 1 |

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 21 | `platform`: a constraint of another platform or word size |
| hasLinks | 16 | `design`: 'file link' is outside the root folder model of the file capability |
| testsimplefilesystem | 10 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testfilesystem | 9 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testsetplatform | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### fileSystemEncoding.test

| Test | Bucket | Result (start) |
|---|---|---|
| filesystemEncoding-1.0 | `bug`: the result differs from tclsh 8.6.16 | code 2/0,2: 1 1 \| want: 0 1 |

### for.test

| Test | Bucket | Result (start) |
|---|---|---|
| for-6.13 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: wrong # args: should be "set varName ?newValue?"     while executing "set" ... |
| for-6.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {wrong # args: should be "set varName ?newValue?"} {wrong # args: should ... |
| for-6.9 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: wrong # args: should be "set varName ?newValue?"     while executing "set" ... |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 24 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### foreach.test

| Test | Bucket | Result (start) |
|---|---|---|
| foreach-1.14 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't set "a": variable is array} {can't set "a": variable is array     ... |
| foreach-9.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |

### format.test

| Test | Bucket | Result (start) |
|---|---|---|
| format-19.4.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:                                                                              ... |
| format-20.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "tcl::unsupported::representation" \| want: value is a... |

| Skipped by | Tests | Bucket |
|---|---|---|
| longIs32bit | 7 | `platform`: a constraint of another platform or word size |
| wideBiggerThanInt | 2 | `platform`: a constraint of another platform or word size |

### get.test

| Test | Bucket | Result (start) |
|---|---|---|
| get-3.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 1 0 1 0 1 0 -1 1 {expected floating-point number but got "-+1.0"} 0 -1 1 ... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testgetint | 15 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testdoubleobj | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### history.test

| Test | Bucket | Result (start) |
|---|---|---|
| history-1.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: Another test \| want: set b [format {A test %s} string] |
| history-1.10 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: wrong # args: should be "::tcl::history::Find ?event?" \| want: wrong # arg... |
| history-1.5 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: unknown or ambiguous subcommand "e": must be add, change, clear, event, inf... |
| history-1.8 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: Another test \| want: set b [format {A test %s} string] |
| history-10.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "::tcl::unsupported::representation" \| want: 1 2 1 |
| history-10.2 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "::tcl::unsupported::representation" \| want: 1 2 1 |
| history-2.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 12345 |
| history-2.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: A test string |
| history-2.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: wrong # args: should be "::tcl::history::Find ?event?" \| want: wrong # arg... |
| history-3.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| history-3.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: bad argument "execGorp": should be "exec" |
| history-3.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| history-3.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: bad argument "a": should be "exec" |
| history-3.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 444 \| want: 555 |
| history-3.7 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 444 \| want: 555 |
| history-3.8 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| history-3.9 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: wrong # args: should be "*history add event \?exec\?" |
| history-4.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: unknown or ambiguous subcommand "n": must be add, change, clear, event, inf... |
| history-4.2 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: unknown or ambiguous subcommand "e": must be add, change, clear, event, inf... |
| history-4.3 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: unknown or ambiguous subcommand "n": must be add, change, clear, event, inf... |
| history-4.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: event "4" is too far in the past \| want: wrong # args: should be "*history... |
| history-5.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:     10 set a 666     11 set a 666     12 set a 666 \| want:      1  set a {... |
| history-5.2 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: unknown or ambiguous subcommand "i": must be add, change, clear, event, inf... |
| history-5.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: unknown or ambiguous subcommand "i": must be add, change, clear, event, inf... |
| history-5.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:     10 set a 666     11 set a 666     12 set a 666 \| want:      1  set a {... |
| history-6.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: unknown or ambiguous subcommand "n": must be add, change, clear, event, inf... |
| history-6.10 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| history-6.11 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: wrong # args: should be "*history keep \?count\?" |
| history-6.13 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 4 \| want: 5 |
| history-6.14 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| history-6.15 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: illegal keep count "-3" |
| history-6.16 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: illegal keep count "butter" |
| history-6.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: foo3 \| want: foo2 |
| history-6.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| history-6.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: foo1 \| want: event "-3" is too far in the past |
| history-6.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: foo3 \| want: foo2 |
| history-6.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: foo2 \| want:  |
| history-6.7 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: foo1 \| want:  |
| history-6.8 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: event "-4" is too far in the past \| want:  |
| history-7.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: foo3 \| want: Testing |
| history-7.2 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: unknown or ambiguous subcommand "next": must be add, change, clear, event, ... |
| history-7.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| history-7.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 16 \| want: wrong # args: should be "*history nextid" |
| history-8.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| history-8.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:      1 Testing \| want:      1  Testing |

### http.test

| Test | Bucket | Result (start) |
|---|---|---|
| http-1.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::config" \| want: -accept */* -pipeline 1 -postf... |
| http-1.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::config" \| want: http::ProxyRequired |
| http-1.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::config" \| want: -accept */* -pipeline 1 -postf... |
| http-1.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::config" \| want: Unknown option -junk, must be: -... |
| http-1.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "http::config" |
| http-2.1 | `feature`: the 'http' package | code 0/0,2: 1 \| want: 0 |
| http-3.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Unknown option flag, can be: -bi... |
| http-3.10 | `feature`: the 'http' package | cleanup: can't read "t": no such variable |
| http-3.11 | `feature`: the 'http' package | cleanup: can't read "t": no such variable |
| http-3.14 | `feature`: the 'http' package | cleanup: can't read "token": no such variable |
| http-3.15 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Unsupported URL: {invalid}:url |
| http-3.16 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Unsupported URL: http:relative/url |
| http-3.17 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Missing host part: /absolute/url |
| http-3.18 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Invalid port number: 123456789 |
| http-3.19 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Illegal characters in URL user |
| http-3.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Unsupported URL: http:junk |
| http-3.20 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Illegal encoding character usage... |
| http-3.21 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Illegal characters in URL path |
| http-3.22 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Illegal encoding character usage... |
| http-3.23 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Illegal characters in URL path |
| http-3.24 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: Illegal encoding character usage... |
| http-3.25 | `feature`: the 'http' package | cleanup: can't read "token": no such variable |
| http-3.26 | `feature`: the 'http' package | cleanup: can't read "token": no such variable |
| http-3.27 | `feature`: the 'http' package | cleanup: can't read "token": no such variable |
| http-3.28 | `feature`: the 'http' package | cleanup: can't read "token": no such variable |
| http-3.29 | `feature`: the 'http' package | code 0/0,2: 1 \| want: 0 |
| http-3.3 | `feature`: the 'http' package | cleanup: can't read "token": no such variable |
| http-3.30 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::geturl" \| want: 200 |
| http-3.31 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::geturl" \| want: 200 |
| http-3.32 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-3.33 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::geturl" \| want: test 4660 /test |
| http-3.4 | `feature`: the 'http' package | cleanup: can't read "token": no such variable |
| http-3.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::config" |
| http-3.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::config" |
| http-3.7 | `feature`: the 'http' package | cleanup: can't read "token": no such variable |
| http-3.8 | `feature`: the 'http' package | cleanup: can't read "token": no such variable |
| http-3.9 | `feature`: the 'http' package | cleanup: can't read "token": no such variable |
| http-4.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.10 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.11 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.12 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.13 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.14 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::geturl" \| want: connect failed connection refused |
| http-4.15 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "http::geturl" \| want: couldn't open socket* |
| http-4.16 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::geturl" \| want:  |
| http-4.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-4.9 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::cleanup" |
| http-5.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::formatQuery" \| want: name1=value1&name2=value%... |
| http-5.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::formatQuery" \| want: lines=line1%0D%0Aline2%0D... |
| http-5.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::formatQuery" \| want: name1=~bwelch&name2=%C2%A... |
| http-5.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::config" \| want: name1=~bwelch&name2=%A1%A2%A2 |
| http-6.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "http::config" |
| http-7.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::mapReply" \| want: abc%24%5B%5D%22%5C%28%29%7D%7B |
| http-7.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http::mapReply" \| want: %E2%88%88 |
| http-7.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "http::config" |
| http-7.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "http::config" |

| Skipped by | Tests | Bucket |
|---|---|---|
| http2.9.7 | 7 | `feature`: the 'http' package |
| http2.9.8 | 2 | `feature`: the 'http' package |
| knownBug | 1 | `tcl`: tclsh skips it too |
| nonPortable | 1 | `tcl`: tclsh skips it too |

### http11.test

| Test | Bucket | Result (start) |
|---|---|---|
| http11-1.0 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.1 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.10 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.11 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.12 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.13 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.2 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.3 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.4 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.5 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.6 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.7 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.8 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.9 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.0 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.1 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.10 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.11 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.12 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.2 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.3 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.4 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.4.1 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.5 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.6 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.7 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.8 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.9 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.0 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.1 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.2 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.3 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.4 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.5 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.6 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.7 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.8 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.9 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-4.0 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-4.1 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-4.2 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |
| http11-4.3 | `feature`: the 'http' package | setup: can't wait for variable "httpd_output": would wait forever |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 1 | `tcl`: tclsh skips it too |

### httpPipeline.test

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1996 | `feature`: the 'http' package |

### httpold.test

| Test | Bucket | Result (start) |
|---|---|---|
| httpold-1.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_config" \| want: -accept */* -proxyfilter httpPr... |
| httpold-1.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_config" \| want: httpProxyRequired |
| httpold-1.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_config" \| want: -accept */* -proxyfilter myFilt... |
| httpold-2.1 | `feature`: the 'http' package | code 0/0,2: 1 \| want: 0 |
| httpold-3.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: invalid command name "http_get" \| want: Unsupported URL: http:junk |
| httpold-3.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: <html><head><title>HTTP/1.0 TEST</... |
| httpold-3.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: <html><head><title>HTTP/1.0 TEST</... |
| httpold-3.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_config" \| want: <html><head><title>HTTP/1.0 TES... |
| httpold-3.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_config" \| want: <html><head><title>HTTP/1.0 TES... |
| httpold-3.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: <html><head><title>HTTP/1.0 TEST</... |
| httpold-3.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: <html><head><title>HTTP/1.0 TEST</... |
| httpold-3.9 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: HTTP/1.0 200 OK |
| httpold-4.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: 1 |
| httpold-4.10 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: 111 |
| httpold-4.11 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: reset |
| httpold-4.12 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: timeout |
| httpold-4.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: 0 |
| httpold-4.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: HTTP/1.0 200 Data follows |
| httpold-4.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: <html><head><title>HTTP/1.0 TEST</... |
| httpold-4.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: 1 |
| httpold-4.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: This is binary data  more more mor... |
| httpold-4.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: 111 111 |
| httpold-4.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: ok |
| httpold-4.9 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_get" \| want: HTTP/1.0 200 Data follows |
| httpold-5.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_formatQuery" \| want: name1=value1&name2=value+two |
| httpold-5.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_formatQuery" \| want: name1=%7ebwelch&name2=%a1%... |
| httpold-5.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_formatQuery" \| want: lines=line1%0d%0aline2%0d%... |
| httpold-6.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "http_config" \| want: <html><head><title>HTTP/1.0 TES... |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1 | `feature`: the 'http' package |

### incr-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| incr-old-2.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {expected integer but got "1a"} {expected integer but got "1a"     while ... |
| incr-old-2.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't set "x": variable is read-only} {can't set "x": variable is read-o... |

### incr.test

| Test | Bucket | Result (start) |
|---|---|---|
| incr-1.28 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't set "x": variable is read-only} {can't set "x": variable is read-o... |
| incr-2.28 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't set "x": variable is read-only} {can't set "x": variable is read-o... |
| incr-2.30 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {expected integer but got "1a"} {expected integer but got "1a"     while ... |
| incr-2.31 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {expected integer but got "1a"} {expected integer but got "1a"     while ... |

### indexObj.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testindexobj | 33 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testparseargs | 12 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### info.test

| Test | Bucket | Result (start) |
|---|---|---|
| info-21.2 | `message`: an error where tclsh also gives one, with another message | code 1/1: unknown or ambiguous subcommand "gorp": must be args, body, cmdcount, command... |
| info-21.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: unknown or ambiguous subcommand "c": must be args, body, cmdcount, commands, ... |
| info-21.4 | `message`: an error where tclsh also gives one, with another message | code 1/1: unknown or ambiguous subcommand "l": must be args, body, cmdcount, commands, ... |
| info-21.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: unknown or ambiguous subcommand "s": must be args, body, cmdcount, commands, ... |
| info-22.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-22.1 | `feature`: 'info frame' | code 0/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-22.2 | `feature`: 'info frame' | code 0/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-22.3 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-22.4 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-22.5 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-22.6 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-22.7 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-22.8 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-23.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-23.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-23.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-23.3 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-23.4 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-23.5 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-23.6 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.3 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.4 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.5 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.6.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.6.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.6.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.7 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.8 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-24.9 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-25.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-25.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-3.1 | `bug`: 'info': the result differs | code 0/0,2: 3 \| want: 4 |
| info-3.2 | `bug`: 'info': the result differs | code 0/0,2: 3 \| want: 4 |
| info-3.3 | `bug`: 'info': the result differs | code 0/0,2: 3 \| want: 4 |
| info-30.0 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-30.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.10 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-30.11 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-30.12 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-30.13 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-30.14 | `bug`: 'info': the result differs | code 1/0,2: interpreter named "sub" already exists, cannot create \| want:  type source... |
| info-30.15 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.16 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.17 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.18 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.19 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.20 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.21 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.22 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.23 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.24 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.25 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.26 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.27 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.28 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.29 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.3 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.30 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.31 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.32 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.33 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.34 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.35 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.36 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.37 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.38 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.39 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.4 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-30.40 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.41 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.42 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.43 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.44 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.45 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.46 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.47 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.48 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.5 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-30.6 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-30.7 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-30.8 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-30.9 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-31.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-31.1 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-31.1a | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-31.2 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-31.4 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-31.5 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-31.6 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-31.7 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-32.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.10 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.11 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.12 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.13 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.14 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.15 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.16 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.17 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.18 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.19 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.20 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.21 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.22 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.23 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.24 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.25 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.26 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.27 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.28 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.29 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.2a | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.3 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.30 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.31 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.32 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.33 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.34 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.35 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.3a | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.4 | `bug`: 'info': the result differs | code 1/0,2: dict element in quotes followed by ":" instead of space \| want: type sourc... |
| info-33.5 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.6 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.7 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.8 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-33.9 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-34.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-34.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-35.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-35.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-36.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-36.1.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-36.1.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-37.0 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-38.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-38.2 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | setup: bad option "debug": must be alias, aliases, cancel, children, create, delete, ev... |
| info-38.3 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-38.4 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | setup: bad option "debug": must be alias, aliases, cancel, children, create, delete, ev... |
| info-38.5 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-38.6 | `bug`: 'info': the result differs | setup: interpreter named "sub" already exists, cannot create |
| info-38.7 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-39.0 | `feature`: 'info frame' | cleanup: can't unset "res": no such variable |
| info-39.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-39.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| info-41.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 3 | `tcl`: tclsh skips it too |

### init.test

| Test | Bucket | Result (start) |
|---|---|---|
| init-0.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {} 1 NONE \| want: 0 {} 0 {} |
| init-0.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 0 0 \| want: 1 0 1 |
| init-1.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: foo::bar \| want: ::foo::bar |
| init-1.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: sub::nocolons nocolons \| want: ::sub::nocolons nocolons |
| init-1.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: foo::bar \| want: ::foo::bar |
| init-1.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: sub::foo::bar foo::bar \| want: ::sub::foo::bar ::foo::bar |
| init-1.7 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: :foo::::bar \| want: ::foo::bar |
| init-1.8 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: :foo \| want: foo |
| init-2.0 | `bug`: the setup or the cleanup of the test fails | cleanup: can't delete "parray": command doesn't exist |
| init-2.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "parray" \| want: wrong # args: should be "parray a ?pat... |
| init-2.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::safe::setLogCmd" \| want:  |
| init-2.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::safe::setLogCmd" \| want:  |
| init-2.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe:::setLogCmd" \| want:  |
| init-2.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe:::setLogCmd" \| want:  |
| init-2.6 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "setLogCmd" \| want:  |
| init-2.7 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "setLogCmd" \| want:  |
| init-2.8 | `bug`: the setup or the cleanup of the test fails | cleanup: can't delete "tcl::HistAdd": command doesn't exist |
| init-3.0 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "foo:::bar::blah" \| want: 1 |
| init-5.0 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 xxx {-code 1 -level 0 -errorcode NONE -errorinfo {xxx     while executing... |

### interp.test

| Test | Bucket | Result (start) |
|---|---|---|
| interp-1.2 | `message`: an error where tclsh also gives one, with another message | code 1/1: bad option "frobox": must be alias, aliases, cancel, children, create, delete... |
| interp-1.7 | `message`: an error where tclsh also gives one, with another message | code 1/1: bad option "hello": must be alias, aliases, cancel, children, create, delete,... |
| interp-1.8 | `message`: an error where tclsh also gives one, with another message | code 1/1: bad option "-froboz": must be alias, aliases, cancel, children, create, delet... |
| interp-1.9 | `message`: an error where tclsh also gives one, with another message | code 1/1: bad option "-froboz": must be alias, aliases, cancel, children, create, delet... |
| interp-11.4 | `bug`: 'interp': the result differs | code 1/0,2: target interpreter for alias "xcommand" in path "x1 x2 x3" is not my descen... |
| interp-13.4 | `bug`: 'interp': the result differs | code 0/0,2: 0 0 \| want: 1 {wrong # args: should be "a issafe"} |
| interp-14.11 | `bug`: 'interp': the result differs | setup: bad option "-199989160": must be -safe or -- |
| interp-14.4 | `bug`: 'interp': the result differs | code 0/0,2: 0 a a \| want: 1 {cannot define or rename alias "a": interpreter deleted} {} |
| interp-14.5 | `bug`: 'interp': the result differs | code 0/0,2: wrong # args: should be "setx x"     while executing "a 1 2" \| want: wrong... |
| interp-14.6 | `bug`: 'interp': the result differs | code 0/0,2: wrong # args: should be "setx x"     invoked from within "a 1 2"     invoke... |
| interp-14.7 | `bug`: 'interp': the result differs | code 0/0,2: wrong # args: should be "setx x"     invoked from within "a 1 2" \| want: w... |
| interp-15.1 | `bug`: the standard channels are not in the channel table | code 1/0,2: can not find channel named "stdout" \| want: 1 {can not find channel named ... |
| interp-15.2 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "share": must be alias, aliases, cancel, children, create, delet... |
| interp-15.3 | `bug`: the standard channels are not in the channel table | code 0/0,2: 0 {} \| want: 1 {can not find channel named "stdout"} |
| interp-15.4 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "share": must be alias, aliases, cancel, children, create, delet... |
| interp-15.5 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "share": must be alias, aliases, cancel, children, create, delet... |
| interp-15.6 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "share": must be alias, aliases, cancel, children, create, delet... |
| interp-15.7 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "transfer": must be alias, aliases, cancel, children, create, de... |
| interp-15.8 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "transfer": must be alias, aliases, cancel, children, create, de... |
| interp-17.1 | `bug`: 'interp': the result differs | code 0/0,2: 0 a \| want: 1 {cannot define or rename alias "a": would create a loop} |
| interp-17.2 | `bug`: 'interp': the result differs | code 0/0,2: 0 loop \| want: 1 {cannot define or rename alias "loop": would create a loop} |
| interp-17.3 | `bug`: 'interp': the result differs | code 0/0,2: 0 b \| want: 1 {cannot define or rename alias "b": would create a loop} |
| interp-17.4 | `bug`: 'interp': the result differs | code 0/0,2: 0 {} \| want: 1 {cannot define or rename alias "a": would create a loop} |
| interp-17.5 | `bug`: 'interp': the result differs | code 0/0,2: 0 {} \| want: 1 {cannot define or rename alias "l1": would create a loop} |
| interp-17.6 | `bug`: 'interp': the result differs | code 0/0,2: 0 {} \| want: 1 {cannot define or rename alias "b": would create a loop} |
| interp-18.10 | `bug`: 'interp': the result differs | code 0/0,2: 0 5 \| want: 1 {attempt to call eval in deleted interpreter} |
| interp-18.7 | `bug`: 'interp': the result differs | code 0/0,2: 0 {} \| want: 1 {attempt to call eval in deleted interpreter} |
| interp-18.8 | `bug`: 'interp': the result differs | code 0/0,2: 0 {} \| want: 1 {attempt to call eval in deleted interpreter} |
| interp-18.9 | `bug`: 'interp': the result differs | code 0/0,2: 0 5 \| want: 1 {attempt to call eval in deleted interpreter} |
| interp-19.2 | `bug`: 'interp': the result differs | code 0/0,2:  \| want: alias "foo" not found |
| interp-19.6 | `bug`: 'interp': the result differs | code 0/0,2: zop foo \| want: ::foo foo |
| interp-19.7 | `bug`: 'interp': the result differs | code 0/0,2: blotz \| want:  |
| interp-19.8 | `bug`: 'interp': the result differs | code 0/0,2: blotz blotz \| want: foo {} |
| interp-19.9 | `bug`: 'interp': the result differs | code 1/0,2: invalid command name "foo" \| want: 1156 |
| interp-20.23 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 1 {invalid command name "interp"} \| want: 1 {permission denied: safe inter... |
| interp-20.24 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 1 {invalid command name "interp"} \| want: 1 {permission denied: safe inter... |
| interp-20.28 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 0 {} 1 {invalid command name "interp"} \| want: 0 {} 1 {permission denied: ... |
| interp-20.29 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 0 {} 1 {invalid command name "interp"} \| want: 0 {} 1 {permission denied: ... |
| interp-20.30 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 0 {} 1 {invalid command name "interp"} \| want: 0 {} 1 {permission denied: ... |
| interp-20.32 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 1 {invalid command name "interp"} \| want: 1 {not allowed to invoke hidden ... |
| interp-20.33 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 1 {invalid command name "interp"} 0 {a b c} \| want: 1 {not allowed to invo... |
| interp-20.34 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 1 {invalid command name "interp"} 0 {a b c} \| want: 1 {not allowed to invo... |
| interp-20.38 | `bug`: 'interp': the result differs | code 0/0,2: 1 {unknown hidden command "-global"} \| want: 1 {can't read "z": no such va... |
| interp-20.39 | `bug`: 'interp': the result differs | code 0/0,2: 1 {unknown hidden command "-global"} \| want: 0 91 |
| interp-20.43 | `bug`: 'interp': the result differs | code 0/0,2: 1 {unknown hidden command "-global"} \| want: 1 {can't read "z": no such va... |
| interp-20.44 | `bug`: 'interp': the result differs | code 0/0,2: 1 {unknown hidden command "-global"} \| want: 0 91 |
| interp-20.45 | `bug`: 'interp': the result differs | code 0/0,2: 0 {} \| want: 1 {cannot use namespace qualifiers in hidden command token (r... |
| interp-20.46 | `bug`: 'interp': the result differs | code 0/0,2: 0 {} \| want: 1 {can only hide global namespace commands (use rename then h... |
| interp-20.47 | `bug`: 'interp': the result differs | code 0/0,2: 0 {} \| want: 1 {cannot use namespace qualifiers in hidden command token (r... |
| interp-20.48 | `bug`: 'interp': the result differs | code 0/0,2: 0 {} \| want: 1 {cannot use namespace qualifiers in hidden command token (r... |
| interp-20.49 | `bug`: 'interp': the result differs | code 1/0,2: unknown hidden command "-namespace" \| want: ::foo |
| interp-20.50.1 | `bug`: 'interp': the result differs | code 0/0: wrong # args: should be "coroutine name cmd ?arg ...?"     invoked from withi... |
| interp-21.5 | `bug`: 'interp': the result differs | code 0/0,2:  \| want: cd encoding exec exit fconfigure file glob load open pwd socket s... |
| interp-21.8 | `bug`: 'interp': the result differs | code 0/0,2:  \| want: cd encoding exec exit fconfigure file glob load open pwd socket s... |
| interp-22.5 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: invalid command name "interp" \| want: permission denied: safe interpreter ... |
| interp-23.1 | `bug`: 'interp': the result differs | code 0/0,2: {} bar {} {} bar {} bar \| want: {} bar {} bar bar {} {} |
| interp-23.2 | `bug`: 'interp': the result differs | code 0/0,2: {} bar {} {} bar {} bar \| want: {cd encoding exec exit fconfigure file glo... |
| interp-24.10 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 1 {invalid command name "interp"} 1 {invalid command name "interp"} \| want... |
| interp-24.12 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 1 {invalid command name "interp"} 1 {invalid command name "interp"} \| want... |
| interp-26.1 | `bug`: 'interp': the result differs | code 0/0,2: 1 0 1 0 1 1 1 \| want: -1 0 1 2 3 4 5 |
| interp-26.2 | `bug`: 'interp': the result differs | code 0/0,2: 1 {bad completion code "-1": must be ok, error, return, break, continue, or... |
| interp-26.3 | `bug`: 'interp': the result differs | code 0/0,2: 1 0 1 2 3 4 5 \| want: -1 0 1 2 3 4 5 |
| interp-26.5 | `bug`: 'interp': the result differs | code 2/0,2: 1 {bad completion code "-1": must be ok, error, return, break, continue, or... |
| interp-29.1.1 | `bug`: 'interp': the result differs | code 0/0,2: 0 600 \| want: 1 {wrong # args: should be "interp recursionlimit path ?newl... |
| interp-29.1.12 | `bug`: 'interp': the result differs | code 0/0,2: 1 {the recursion limit of this interpre} \| want: 1 {integer value too larg... |
| interp-29.1.3 | `bug`: 'interp': the result differs | code 0/0,2: 1 {could not find interpreter "foo"} \| want: 1 {wrong # args: should be "i... |
| interp-29.1.7 | `bug`: 'interp': the result differs | code 0/0,2: 1 {the recursion limit of this interpre} \| want: 1 {integer value too larg... |
| interp-29.1.8 | `bug`: 'interp': the result differs | code 0/0,2: 1 {wrong # args: should be "interp recursionlimit path ?newlimit?"} \| want... |
| interp-29.2.1 | `bug`: 'interp': the result differs | code 0/0,2: 600 \| want: 1000 |
| interp-29.2.2 | `bug`: 'interp': the result differs | code 0/0,2: 600 \| want: 1000 |
| interp-29.2.3 | `bug`: 'interp': the result differs | code 0/0,2: 600 \| want: 1000 |
| interp-29.3.10b | `bug`: the recursion limit and its message | code 0/0,2: 0 ok \| want: 1 {too many nested evaluations (infinite loop?)} |
| interp-29.3.11b | `bug`: the recursion limit and its message | code 0/0,2: 0 ok \| want: 1 {too many nested evaluations (infinite loop?)} |
| interp-29.3.4 | `bug`: 'interp': the result differs | code 0/0,2: 0 ok \| want: 1 {falling back due to new recursion limit} |
| interp-29.3.5 | `bug`: 'interp': the result differs | code 0/0,2: 0 ok \| want: 1 {falling back due to new recursion limit} |
| interp-29.3.7c | `bug`: the recursion limit and its message | code 0/0,2: 0 ok \| want: 1 {too many nested evaluations (infinite loop?)} |
| interp-29.3.8b | `bug`: the recursion limit and its message | code 0/0,2: 0 ok \| want: 1 {too many nested evaluations (infinite loop?)} |
| interp-29.4.1 | `bug`: 'interp': the result differs | code 0/0,2: 599 \| want: 50 |
| interp-29.4.2 | `bug`: 'interp': the result differs | code 0/0,2: 599 \| want: 50 |
| interp-29.5.1 | `bug`: the recursion limit and its message | code 1/0,2: the recursion limit of this interpreter is 600 \| want: 1 20000 |
| interp-29.5.2 | `bug`: the recursion limit and its message | code 1/0,2: the recursion limit of this interpreter is 600 \| want: 1 20000 |
| interp-29.5.3 | `bug`: the recursion limit and its message | code 1/0,2: the recursion limit of this interpreter is 600 \| want: 1 20000 |
| interp-29.5.4 | `bug`: the recursion limit and its message | code 1/0,2: the recursion limit of this interpreter is 600 \| want: 1 20000 |
| interp-29.6.1 | `bug`: 'interp': the result differs | code 0/0,2: 600 \| want: 1000 |
| interp-29.6.10 | `bug`: safe interpreters: hidden commands and their messages | code 1/0,2: interpreter named "child" already exists, cannot create \| want: 1 {permiss... |
| interp-29.6.2 | `bug`: 'interp': the result differs | code 0/0,2: 600 \| want: 1000 |
| interp-29.6.8 | `bug`: safe interpreters: hidden commands and their messages | code 0/0,2: 1 {invalid command name "interp"} \| want: 1 {permission denied: safe inter... |
| interp-29.6.9 | `bug`: safe interpreters: hidden commands and their messages | code 1/0,2: invalid command name "interp" \| want: 1 {permission denied: safe interpret... |
| interp-34.1 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invok... |
| interp-34.10 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, inv... |
| interp-34.11 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, inv... |
| interp-34.12 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, inv... |
| interp-34.13 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invok... |
| interp-34.14 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, inv... |
| interp-34.2 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invok... |
| interp-34.3 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invok... |
| interp-34.3.1 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invok... |
| interp-34.4 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, inv... |
| interp-34.5 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, inv... |
| interp-34.6 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, inv... |
| interp-34.7 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, inv... |
| interp-34.8 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-34.9 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, cancel, children, create, delet... |
| interp-35.1 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.10 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.11 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.12 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, cancel, children, create, delet... |
| interp-35.13 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, cancel, children, create, delet... |
| interp-35.14 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, cancel, children, create, delet... |
| interp-35.15 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.16 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.17 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.18 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.19 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.2 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.20 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.21 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.22 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, cancel, children, create, delet... |
| interp-35.23 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.24 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.3 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.4 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, cancel, children, create, delet... |
| interp-35.5 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, cancel, children, create, delet... |
| interp-35.6 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "limit": must be alias, aliases, cancel, children, create, delet... |
| interp-35.7 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.8 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-35.9 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "limit": must be alias, aliases, cancel, children, create, delete,... |
| interp-36.1 | `bug`: 'interp': the result differs | code 0/1: ::tcl::Bgerror \| want: wrong # args: should be "interp bgerror path ?cmdPref... |
| interp-36.3 | `bug`: 'interp': the result differs | setup: interpreter named "child" already exists, cannot create |
| interp-36.4 | `message`: an error where tclsh also gives one, with another message | code 1/1: unmatched open brace in list \| want: cmdPrefix must be list of length >= 1 |
| interp-38.1 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | setup: bad option "debug": must be alias, aliases, cancel, children, create, delete, ev... |
| interp-38.2 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "debug": must be alias, aliases, cancel, children, create, delet... |
| interp-38.3 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "debug": must be alias, aliases, cancel, children, create, delete,... |
| interp-38.4 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "debug": must be alias, aliases, cancel, children, create, delet... |
| interp-38.5 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "debug": must be alias, aliases, cancel, children, create, delet... |
| interp-38.6 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "debug": must be alias, aliases, cancel, children, create, delete,... |
| interp-38.7 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "debug": must be alias, aliases, cancel, children, create, delete,... |
| interp-38.8 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/1: bad option "debug": must be alias, aliases, cancel, children, create, delete,... |
| interp-7.6 | `bug`: 'interp': the result differs | code 0/1: foo bar \| want: wrong # args: should be "a aliases" |
| interp-8.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "interp alias childPath childCmd ?targetPath targetCm... |
| interp-9.4 | `bug`: 'interp': the result differs | code 0/0,2: GLOBAL NAMESPACE \| want: GLOBAL GLOBAL |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 7 | `tcl`: tclsh skips it too |
| testinterpdelete | 6 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### io.test

| Test | Bucket | Result (start) |
|---|---|---|
| io-1.6 | `bug`: channels: the result differs | code 0/0,2: a9 \| want: aM |
| io-12.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| io-12.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| io-13.8.1 | `bug`: channels: the result differs | code 0/0,2: {abcd } { def} \| want: {abcd } def |
| io-13.8.2 | `bug`: channels: the result differs | code 0/0,2: {abcd } { def} \| want: {abcd } def |
| io-13.8.3 | `bug`: channels: the result differs | code 0/0,2: {abcd } {  def} \| want: {abcd } { def} |
| io-14.2 | `bug`: channels: the result differs | code 0/0,2: {} {} {} \| want: line line none |
| io-14.3 | `bug`: channels: the result differs | code 1/0,2: child process exited abnormally \| want: { out } {err } |
| io-14.4 | `bug`: channels: the result differs | code 1/0,2: child process exited abnormally \| want: { close stdin stdout } {stderr } |
| io-14.5 | `bug`: the standard channels are not in the channel table | code 0/0,2: {can not find channel named "stdin"} {can not find channel named "stdin"} {... |
| io-14.6 | `bug`: the standard channels are not in the channel table | code 0/0,2: {} {can not find channel named "stdout"} {} \| want: {} {} {can not find ch... |
| io-14.7 | `bug`: the standard channels are not in the channel table | code 0/0,2: {} {can not find channel named "stderr"} {} \| want: {} {} {can not find ch... |
| io-14.8 | `bug`: channels: the result differs | code 0/0,2:  \| want: hello |
| io-2.2 | `bug`: channels: the result differs | code 0/0,2: {} {123456789012345  12} \| want: {123456789012345 } {123456789012345  12} |
| io-2.4 | `bug`: channels: the result differs | code 0/0,2: {abcdefg hijklmnopqrstuvwxyz} {abcdefg hijklmnopqrstuvwxyz} \| want: {abcde... |
| io-20.1 | `bug`: channels: the result differs | code 0/0,2: utf-8 \| want: ascii |
| io-20.5 | `bug`: channels: the result differs | code 0/0,2:  \| want: 777 |
| io-27.4 | `bug`: channels: the result differs | code 0/0,2: 0 0 72 \| want: 0 60 72 |
| io-27.5 | `bug`: channels: the result differs | code 0/0,2: 0 0 72 \| want: 0 60 72 |
| io-28.2 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "share": must be alias, aliases, cancel, children, create, delet... |
| io-29.20 | `bug`: channels: the result differs | code 0/0,2: 0 0 12600 \| want: 4096 12288 12600 |
| io-29.27 | `bug`: channels: the result differs | code 0/0,2: 1 {error writing "": broken pipe} {posix epipe {broken pipe}} \| want: 1 {e... |
| io-29.35 | `feature`: the 'interp' subcommands bgerror, cancel, debug, limit, s... | code 1/0,2: bad option "share": must be alias, aliases, cancel, children, create, delet... |
| io-29.36.2 | `bug`: channels: the result differs | code 0/0,2: {<1 line>} {<2 line>} <> {<3 line>} {<1 line>} {<2 line>} {<3 line>} {<1 li... |
| io-3.2 | `bug`: channels: the result differs | code 0/0,2: {} {123456789012345  12} \| want: {123456789012345 } {123456789012345  12} |
| io-3.4 | `bug`: channels: the result differs | code 0/0,2: {} !)!)!)!)!)!)!)!)!)!)!)!)!)!)!) \| want: !)!)!)!)!)!)!)!) !)!)!)!)!)!)!)!... |
| io-3.5 | `bug`: channels: the result differs | code 0/0,2: {} !)!)!)!)!)!)!)!)!)!)!)!)!)!)!) \| want: !)!)!)!)!)!)!)!)! !)!)!)!)!)!)!)... |
| io-3.6 | `bug`: channels: the result differs | code 0/0,2: {} 12345678901234'a \| want: 12345678901234' 12345678901234'a |
| io-3.7 | `bug`: channels: the result differs | code 0/0,2: {} !)!)!)!)!)!)!)!)!)!)!)!)!)!)!) \| want: !)!)!)!)!)!)!)!)! !)!)!)!)!)!)!)... |
| io-3.8 | `bug`: channels: the result differs | code 0/0,2: {abcdefg hijklmnopqrstuvwxyz} {abcdefg hijklmnopqrstuvwxyz} \| want: {abcde... |
| io-30.21 | `bug`: channels: the result differs | code 0/0,2: -1 0 def 0 \| want: 0 1 {} 1 |
| io-30.22 | `bug`: channels: the result differs | code 0/0,2: -1 0 def 0 \| want: 0 1 {} 1 |
| io-31.11 | `bug`: channels: the result differs | code 0/0,2: hello 6 cr 0 0 7 cr 0 \| want: hello 6 cr 0 6 13 cr 0 |
| io-31.13 | `bug`: channels: the result differs | code 0/0,2: binary \| want: lf |
| io-31.5 | `bug`: channels: the result differs | code 0/0,2: 5 6 cr 0 there 12 cr 0 \| want: 21 21 cr 1 {} 21 cr 1 |
| io-31.6 | `bug`: channels: the result differs | code 0/0,2: 5 6 crlf 0 there 12 crlf 0 \| want: 21 21 crlf 1 {} 21 crlf 1 |
| io-32.11.1 | `bug`: channels: the result differs | code 0/0,2: {hello } { hello } \| want: {hello } {hello } |
| io-32.11.2 | `bug`: channels: the result differs | code 0/0,2: {hello } { hello } \| want: {hello } {hello } |
| io-33.11 | `bug`: channels: the result differs | cleanup: can not find channel named "80" |
| io-33.12 | `bug`: channels: the result differs | cleanup: can not find channel named "80" |
| io-33.13 | `bug`: channels: the result differs | cleanup: can not find channel named "80" |
| io-34.12 | `bug`: channels: the result differs | code 1/0,2: bad origin "cur": must be start, current, or end \| want: 14 {xyz 123 xyzzy... |
| io-34.19 | `bug`: channels: the result differs | code 0/0,2: 0 \| want: 54 |
| io-34.8 | `bug`: channels: the result differs | code 0/0,2: 1 {error during seek on "": input/output error} \| want: 1 {error during se... |
| io-39.21 | `bug`: channels: the result differs | code 0/0,2: auto lf \| want: auto crlf |
| io-39.23 | `bug`: channels: the result differs | code 0/0,2: {} lf \| want: {{}} auto |
| io-39.24 | `bug`: channels: the result differs | code 0/0,2: D lf \| want: {{}} auto |
| io-4.4 | `bug`: channels: the result differs | code 0/0,2: {} {1234567          A} \| want: {1234567         } {1234567          A} |
| io-40.17 | `design`: the suite runs without the 'env' capability, so 'env' is ... | code 1/0,2: can't read "::env(HOME)": no such variable \| want: 1 {couldn't find HOME e... |
| io-42.2 | `bug`: channels: the result differs | code 1/0,2: bad event name "r": must be readable or writable \| want: {first script} {n... |
| io-42.3 | `bug`: channels: the result differs | code 1/0,2: bad event name "r": must be readable or writable \| want: 13 11 12 {} |
| io-43.2 | `bug`: channels: the result differs | code 1/0,2: bad event name "r": must be readable or writable \| want: {} {} {} {read f}... |
| io-49.1 | `bug`: channels: the result differs | code 0/0,2: 7 a 1 { } 2 b 3 { } 4 c 5 { } 6 0 { } 0 \| want: 7 a 1 { } 2 b 3 { } 4 c 5 ... |
| io-49.2 | `bug`: channels: the result differs | code 0/0,2: 7 {a } 2 {b } 4 {c } 6 0 { } 7 1 \| want: 7 {a } 2 {b } 4 {c } 7 0 {} 7 1 |
| io-49.3 | `bug`: channels: the result differs | code 0/0,2: 7 {a b} 3 { c } 6 0 { } 7 1 \| want: 7 {a b} 3 { c } 7 0 {} 7 1 |
| io-5.2 | `bug`: channels: the result differs | code 0/0,2: {} 12345678901234567890 \| want: 1234567890123456 12345678901234567890 |
| io-52.1 | `bug`: channels: the result differs | code 0/0,2: -1 \| want: 0 |
| io-52.10 | `bug`: channels: the result differs | code 0/0,2: 3 \| want: 5 |
| io-52.11 | `bug`: channels: the result differs | code 0/0,2: 5 \| want: 3 |
| io-52.2 | `bug`: channels: the result differs | code 0/0,2: -1 \| want: 0 |
| io-52.7 | `bug`: channels: the result differs | code 0/0,2: 0 0 \| want: 0 0 ok |
| io-53.13 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof... |
| io-53.14 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof... |
| io-53.15 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| io-53.16 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| io-53.17 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| io-53.4 | `bug`: channels: the result differs | code 1/0,2: bad event name "read": must be readable or writable \| want: done |
| io-53.7 | `bug`: channels: the result differs | code 1/0,2: illegal use of & in a command pipeline \| want: 3450 |
| io-6.17 | `bug`: channels: the result differs | code 0/0,2: 0 {} -1 {} \| want: 1 { } -1 {} |
| io-6.21 | `bug`: channels: the result differs | code 0/0,2: 4 abcd 4 efgh 4 ijkl 0 {} \| want: 9 {abcd efgh} 4 ijkl 5 { mnop} -1 {} |
| io-6.23 | `bug`: channels: the result differs | code 0/0,2: 0 {} -1 {} \| want: 1 { } -1 {} |
| io-6.29 | `bug`: channels: the result differs | code 0/0,2: 4 abcd 9 {efgh ijkl} 4 mnop \| want: 14 {abcd efgh ijkl} 4 mnop -1 {} |
| io-6.4 | `bug`: channels: the result differs | code 0/0,2: 4 H´ \| want: 3 4 |
| io-61.1 | `bug`: channels: the result differs | code 0/0,2: 77 {} 77 \| want: 77 = 23431 |
| io-7.4 | `bug`: channels: the result differs | code 1/0,2: bad event name "read": must be readable or writable \| want: -1 {} 1 17 123... |
| io-73.3 | `bug`: channels: the result differs | code 0/0,2: 1 1 {} 1 {} 1 \| want: 1 1 {more data} 0 {} 1 |
| io-73.4 | `bug`: channels: the result differs | code 0/0,2: 1 1 {} 1 \| want: 1 1 {more data } 1 |
| io-73.5 | `bug`: channels: the result differs | code 0/0,2: 1 1 {} 1 \| want: 1 1 more data 1 |
| io-75.2 | `bug`: channels: the result differs | code 0/0,2: A¢ \| want: A? |

| Skipped by | Tests | Bucket |
|---|---|---|
| testchannel | 354 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testfevent | 9 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| emptyTest | 8 | `tcl`: tclsh skips it too |
| testchannelevent | 7 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| nonPortable | 2 | `tcl`: tclsh skips it too |
| win | 2 | `platform`: a constraint of another platform or word size |
| extensive | 1 | `tcl`: tclsh skips it too |
| makeFileInHome | 1 | `platform`: a property of the host: a second device, a writable home, IPv6 on localhost, ... |
| testbytestring | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testmainthread | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testobj | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### ioCmd.test

| Test | Bucket | Result (start) |
|---|---|---|
| ioCmd-13.11 | `bug`: channels: the result differs | code 2/0,2: 34123456x \| want: 341234x6 |
| iocmd-11.1 | `bug`: channels: the result differs | code 0/0,2: 1 {can't write input to command: standard input was redirected} NONE \| wan... |
| iocmd-11.2 | `bug`: channels: the result differs | code 0/0,2: 1 {can't read output from command: standard output was redirected} NONE \| ... |
| iocmd-11.3 | `bug`: channels: the result differs | code 0/0,2: 1 {can't read output from command: standard output was redirected} NONE \| ... |
| iocmd-12.4 | `bug`: channels: the result differs | code 0/0,2: -1 \| want: 0 |
| iocmd-12.6 | `bug`: channels: the result differs | code 0/0,2: 1 unmatched open brace in list unmatched open brace in list     while execu... |
| iocmd-12.7 | `bug`: channels: the result differs | code 0/0,2: 1 {invalid access mode "FOO": must be APPEND, BINARY, CREAT, EXCL, NOCTTY, ... |
| iocmd-15.10 | `bug`: channels: the result differs | code 0/0,2: 1 {bad option "foo": should be -size or -command} \| want: 1 {bad option "f... |
| iocmd-15.3 | `bug`: channels: the result differs | code 0/0,2: 1 {can not find channel named "1"} \| want: 1 {wrong # args: should be "fco... |
| iocmd-15.4 | `bug`: channels: the result differs | code 0/0,2: 1 {can not find channel named "1"} \| want: 1 {wrong # args: should be "fco... |
| iocmd-15.5 | `bug`: channels: the result differs | code 0/0,2: 1 {can not find channel named "1"} \| want: 1 {wrong # args: should be "fco... |
| iocmd-15.8 | `bug`: channels: the result differs | code 0/0,2: 1 {error reading "file70": bad file number} \| want: 1 {channel "file70" wa... |
| iocmd-15.9 | `bug`: channels: the result differs | code 0/0,2: 0 0 \| want: 1 {channel "file69" wasn't opened for writing} |
| iocmd-21.0 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.10 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.11 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.12 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.13 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.14 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.15 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.16 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.17 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.18 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.19 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: {} 1 {unknown or ambiguous subcommand "create": must be close, configure, c... |
| iocmd-21.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.20 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-21.21 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-21.22 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-21.23 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-21.24 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-21.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-21.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-22.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-22.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-22.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-22.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-22.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-22.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-22.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-22.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-22.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-23.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-23.10 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-23.11 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-23.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-23.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-23.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-23.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-23.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-23.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-23.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-23.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-24.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.10 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.11 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.12 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.13 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.14 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-24.15 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-24.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-24.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-25.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-25.10 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-25.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-25.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-25.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-25.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-25.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-25.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-25.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-25.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-26.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-26.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-26.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-26.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-26.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-26.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-26.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-27.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-27.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-27.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-27.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-27.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-27.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.10 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.11 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.12 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.13 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.14 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.15 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.16 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.17 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.18 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.19.0 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.19.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.19.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-28.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.10 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.11 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-29.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-30.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-30.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-30.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-30.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-31.1 | `bug`: channels: the result differs | code 0/0,2: unknown or ambiguous subcommand "postevent": must be close, configure, copy... |
| iocmd-31.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-31.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-31.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-31.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-31.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-31.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-31.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-32.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-32.3.0 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-32.3.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "create": must be close, configure, copy, e... |
| iocmd-4.12 | `message`: the -errorcode differs | errorcode: NONE |
| iocmd-4.9 | `bug`: channels: the result differs | code 0/0,2: 1 {expected non-negative integer but got "foo"} NONE \| want: 1 {expected n... |
| iocmd-8.15.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: bad option "-blah": should be one of -blocking, -buffering, -buffersize, -enc... |
| iocmd-8.2 | `bug`: channels: the result differs | code 0/0,2: 1 {can not find channel named "a"} \| want: 1 {wrong # args: should be "fco... |
| iocmd-8.9 | `bug`: channels: the result differs | code 0/0,2: -blocking 1 -buffering none -buffersize 4040 -encoding binary -eofchar {} -... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testchannel | 99 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| nonPortable | 3 | `tcl`: tclsh skips it too |

### ioTrans.test

| Test | Bucket | Result (start) |
|---|---|---|
| iortrans-2.0 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.10 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.11 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.12 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.13 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.14 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.17 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.18 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.19 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-2.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.20 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 0/0,2: {} 1 {unknown or ambiguous subcommand "push": must be close, configure, cop... |
| iortrans-2.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 2/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-2.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-2.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, ... |
| iortrans-3.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-3.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-3.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-3.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-3.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-3.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-3.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-3.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-3.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.10 | `bug`: channels: the result differs | cleanup: can't read "chan": no such variable |
| iortrans-4.10.1 | `bug`: channels: the result differs | cleanup: can't read "chan": no such variable |
| iortrans-4.10.2 | `bug`: channels: the result differs | cleanup: can't read "chan": no such variable |
| iortrans-4.11 | `bug`: channels: the result differs | cleanup: can't read "chan": no such variable |
| iortrans-4.11.1 | `bug`: channels: the result differs | cleanup: can't read "chan": no such variable |
| iortrans-4.11.2 | `bug`: channels: the result differs | cleanup: can't read "chan": no such variable |
| iortrans-4.12 | `bug`: channels: the result differs | cleanup: can't read "chan": no such variable |
| iortrans-4.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.8.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.8.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-4.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-5.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-5.10 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-5.11 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-5.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-5.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-5.4 | `bug`: channels: the result differs | cleanup: can not find channel named "file75" |
| iortrans-5.5 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-5.6 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-5.7 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-5.8 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-5.9 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-6.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-6.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-7.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-7.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-7.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-7.4 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-8.1 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-8.2 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-8.3 | `feature`: 'chan create', 'chan push', 'chan pop', 'chan pipe', 'cha... | code 1/0,2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof... |
| iortrans-ea69b0258a9833cb | `bug`: channels: the result differs | cleanup: can't read "chan": no such variable |

| Skipped by | Tests | Bucket |
|---|---|---|
| testchannel | 37 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### iogt.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testchannel | 17 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### lindex.test

| Test | Bucket | Result (start) |
|---|---|---|
| lindex-10.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {unmatched open brace in list} \| want: 1 bad\ index\ \"\{\":\ must\ be\ ... |
| lindex-17.0 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: bad index "foo"* |
| lindex-2.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {unmatched open brace in list} \| want: 1 bad\ index\ \"\{\":\ must\ be\ ... |

### link.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testlink | 29 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### list.test

| Test | Bucket | Result (start) |
|---|---|---|
| list-1.26 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: #\{ #\{ \| want: \#\{ #\{ |

### listObj.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testobj | 4 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| emptyTest | 1 | `tcl`: tclsh skips it too |

### lmap.test

| Test | Bucket | Result (start) |
|---|---|---|
| lmap-1.15 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't set "a": variable is array} {can't set "a": variable is array     ... |

### load.test

| Test | Bucket | Result (start) |
|---|---|---|
| load-1.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "load" \| want: wrong # args: should be "load ?-global? ... |
| load-1.2 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "load" \| want: wrong # args: should be "load ?-global? ... |
| load-1.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "load" \| want: could not find interpreter "foobar" |
| load-1.4 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "load" \| want: must specify either file name or package... |
| load-1.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "load" \| want: must specify either file name or package... |
| load-1.6 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "load" \| want: package "Unknown" isn't loaded statically |
| load-1.7 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "load" \| want: bad option "-abc": must be -global, -laz... |
| load-1.8 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "load" \| want: couldn't figure out package name for -gl... |

| Skipped by | Tests | Bucket |
|---|---|---|
| pkga.soRequired | 12 | `internals`: a C test package of the Tcl build |
| teststaticpkg | 5 | `internals`: a C test command of the Tcl test binary |
| teststaticpkg_8.x | 5 | `internals`: a C test command of the Tcl test binary |

### lrange.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testpurebytesobj | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### lsearch.test

| Test | Bucket | Result (start) |
|---|---|---|
| lsearch-19.7 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 end \| want: 0 1 |
| lsearch-19.8 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: {0 end} \| want: {0 1} |

### lset.test

| Test | Bucket | Result (start) |
|---|---|---|
| lset-16.2 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: list index out of range \| want: {{test 1}} |
| lset-16.3 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: list index out of range \| want: {{{test 1}}} |
| lset-16.6 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: list index out of range \| want: {{test 1}} |
| lset-16.7 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: list index out of range \| want: {{{test 1}}} |
| lset-2.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {list element in braces followed by "1" instead of space} \| want: 1 {bad... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testobj | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### macOSXFCmd.test

| Skipped by | Tests | Bucket |
|---|---|---|
| macosxFileAttr | 14 | `platform`: a constraint of another platform or word size |

### main.test

| Test | Bucket | Result (start) |
|---|---|---|
| Tcl_Main-1.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: -script {} 0  \| want: /ztclsh -script 0  |
| Tcl_Main-1.7 | `bug`: the setup or the cleanup of the test fails | cleanup: couldn't read file "-encoding": no such file or directory |
| Tcl_Main-1.8 | `bug`: the setup or the cleanup of the test fails | cleanup: couldn't read file "-encoding": no such file or directory |
| Tcl_Main-1.9 | `bug`: the setup or the cleanup of the test fails | cleanup: couldn't read file "-enc": no such file or directory |
| Tcl_Main-3.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {child process exited abnormally} {ERROR } \| want: 1 {child process exit... |
| Tcl_Main-3.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 child process exited abnormally missing close-brace  \| want: 1 child pro... |
| Tcl_Main-5.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: can't set "tcl_interactive": variable must have boolean value  |
| Tcl_Main-5.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 {} \| want: 0 SUCCESS |
| Tcl_Main-5.7 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: bar foo  \| want: bar  |
| Tcl_Main-6.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: 1 %  |
| Tcl_Main-6.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: not reached  \| want: 1  |
| Tcl_Main-6.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: YES  \| want: 1 % YES  |
| Tcl_Main-6.6 | `bug`: the setup or the cleanup of the test fails | cleanup: can not find channel named "file45" |
| Tcl_Main-6.7 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: invalid command name "foo"  \| want: 1 % %  |
| Tcl_Main-9.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: This is   a test  \| want: 1 one two This is   a test one  |
| Tcl_Main-9.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: 1 foo % foo     while executing "error foo"     (script that gene... |
| Tcl_Main-9.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: 1 %  |
| Tcl_Main-9.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: 1 foo  |

| Skipped by | Tests | Bucket |
|---|---|---|
| Tcltest | 36 | `internals`: a C test command or package of the Tcl test binary |

### mathop.test

| Test | Bucket | Result (start) |
|---|---|---|
| mathop-24.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: {can't use non-numeric string as operand of "%" ARITH DOMAIN {non-numeric s... |
| mathop-25.30 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |

### misc.test

| Test | Bucket | Result (start) |
|---|---|---|
| misc-1.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 missing close-brace for variable name missing close-brace for variable na... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testhashsystemhash | 299 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### msgcat.test

| Test | Bucket | Result (start) |
|---|---|---|
| msgcat-0.0 | `feature`: the 'msgcat' package | setup: invalid command name "i" |
| msgcat-0.1 | `feature`: the 'msgcat' package | setup: invalid command name "i" |
| msgcat-0.2 | `feature`: the 'msgcat' package | setup: invalid command name "i" |
| msgcat-0.3 | `feature`: the 'msgcat' package | setup: invalid command name "i" |
| msgcat-0.4 | `feature`: the 'msgcat' package | setup: invalid command name "i" |
| msgcat-0.5 | `feature`: the 'msgcat' package | setup: invalid command name "i" |
| msgcat-0.6 | `feature`: the 'msgcat' package | setup: invalid command name "i" |
| msgcat-0.7 | `feature`: the 'msgcat' package | setup: invalid command name "i" |
| msgcat-1.12 | `feature`: the 'msgcat' package | code 0/1: /path/to/evil/code \| want: invalid newLocale value * |
| msgcat-1.13 | `feature`: the 'msgcat' package | code 0/1: looks/ok/../../../../but/is/path/to/evil/code \| want: invalid newLocale value * |
| msgcat-10.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "mcloadedlocales" \| want: wrong # args: should be "mclo... |
| msgcat-10.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "mcloadedlocales" \| want: unknown subcommand "junk": mu... |
| msgcat-10.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-10.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-11.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "mcforgetpackage" \| want: 1 0 |
| msgcat-11.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "mcpackagelocale" \| want: bar foo |
| msgcat-11.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "mcpackageconfig" \| want: 1 0 |
| msgcat-12.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "mcpackagelocale" \| want: wrong # args: should be "mcpa... |
| msgcat-12.10 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "mcforgetpackage" |
| msgcat-12.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "mcpackagelocale" \| want: unknown subcommand "junk": mu... |
| msgcat-12.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "mcforgetpackage" |
| msgcat-12.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "mcforgetpackage" |
| msgcat-12.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "mcforgetpackage" |
| msgcat-12.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "mcforgetpackage" |
| msgcat-12.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "mcforgetpackage" |
| msgcat-12.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "mcforgetpackage" |
| msgcat-12.9 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "mcforgetpackage" |
| msgcat-13.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "mcpackageconfig" \| want: wrong # args: should be "mcpa... |
| msgcat-13.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "mcpackageconfig" \| want: unknown subcommand "junk": mu... |
| msgcat-13.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "mcpackageconfig" \| want: bad option "junk": must be mc... |
| msgcat-13.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-13.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-14.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-14.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-14.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-14.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-14.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-14.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-2.3 | `feature`: the 'msgcat' package | code 0/0,2: con1baz \| want: con1bar |
| msgcat-2.6 | `feature`: the 'msgcat' package | code 0/0,2: con2baz \| want: con2bar |
| msgcat-4.4 | `feature`: the 'msgcat' package | setup: can't rename "msgcat::mcunknown": command doesn't exist |
| msgcat-4.5 | `feature`: the 'msgcat' package | setup: can't rename "msgcat::mcunknown": command doesn't exist |
| msgcat-4.6 | `feature`: the 'msgcat' package | setup: can't rename "msgcat::mcunknown": command doesn't exist |
| msgcat-5.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::msgcat::mcloadedlocales" |
| msgcat-5.10 | `feature`: the 'msgcat' package | setup: can't rename "msgcat::mcunknown": command doesn't exist |
| msgcat-5.11 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcloadedlocales" |
| msgcat-5.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::msgcat::mcloadedlocales" |
| msgcat-5.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::msgcat::mcloadedlocales" |
| msgcat-5.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "mcloadedlocales" |
| msgcat-5.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "mcloadedlocales" |
| msgcat-6.2 | `feature`: the 'msgcat' package | code 0/0,2: ov2_foo_bar \| want: ov2_foo |
| msgcat-6.3 | `feature`: the 'msgcat' package | code 0/0,2: ov3_foo_bar_baz \| want: ov3_foo |
| msgcat-6.7 | `feature`: the 'msgcat' package | code 0/0,2: ov3_foo_bar_baz \| want: ov3_foo_bar |
| msgcat-8.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::msgcat::mcflset" |
| msgcat-8.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::msgcat::mcflset" |
| msgcat-9.1 | `feature`: the 'msgcat' package | code 1/1: wrong # args: should be "::msgcat::mcexists ?-exactnamespace? ?-exactlocale? ... |
| msgcat-9.2 | `feature`: the 'msgcat' package | code 0/1: 0 \| want: unknown option "-unknown" |
| msgcat-9.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-9.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |
| msgcat-9.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "mcforgetpackage" |

### namespace-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| namespace-old-5.10 | `bug`: namespaces: the result differs | code 0/1:  \| want: namespace "xyzzy" not found in "::" |
| namespace-old-6.14 | `bug`: namespaces: the result differs | code 1/0,2: can't read "test_ns_cache_var": no such variable \| want: {cache1 version} ... |
| namespace-old-9.14 | `bug`: namespaces: the result differs | code 0/0,2: cmd2 1 {invalid command name "cmd1"} \| want: {} 1 {invalid command name "c... |
| namespace-old-9.18 | `bug`: namespaces: the result differs | code 0/0,2: cmd1 ::test_ns_import_use::cmd1 \| want: {} {} |
| namespace-old-9.19 | `bug`: namespaces: the result differs | code 0/0,2: {cmd1 cmd2} {ncmd ncmd1 ncmd2} {::test_ns_import_use::cmd1 ::test_ns_import... |

### namespace.test

| Test | Bucket | Result (start) |
|---|---|---|
| namespace-10.3 | `bug`: namespaces: the result differs | code 0/0,2: {::test_ns_import::cmd1 ::test_ns_import::cmd2 ::test_ns_import::p} {::test... |
| namespace-10.5 | `bug`: namespaces: the result differs | code 0/1:  \| want: * |
| namespace-10.9 | `bug`: namespaces: the result differs | code 0/1:  \| want: * |
| namespace-13.1 | `bug`: namespaces: the result differs | code 0/0,2: {::test_ns_import::cmd1 ::test_ns_import::cmd2 ::test_ns_import::p} {::test... |
| namespace-14.1 | `bug`: namespaces: the result differs | code 0/0,2: 10 30 20 {::test_ns_1 ::test_ns_2 ::test_ns_2: ::test_ns_7 ::test_ns_export... |
| namespace-14.13 | `bug`: namespaces: the result differs | code 0/1:  \| want: can't create namespace "": only global namespace can have empty name |
| namespace-14.2 | `bug`: namespaces: the result differs | code 0/0,2: 1 {can't read "::test_ns_777::v": no such variable} 0 {} \| want: 1 {can't ... |
| namespace-14.3 | `bug`: namespaces: the result differs | code 1/0,2: can't read "v": no such variable \| want: 10 20 |
| namespace-14.4 | `bug`: namespaces: the result differs | code 0/0,2: ::test_ns_1::test_ns_2::foo 0 {} \| want: ::test_ns_1::test_ns_2::foo 1 {na... |
| namespace-14.6 | `bug`: namespaces: the result differs | code 0/0,2: ::test_ns_1::test_ns_2::foo 0 {} \| want: ::test_ns_1::test_ns_2::foo 1 {na... |
| namespace-14.8 | `bug`: namespaces: the result differs | code 0/0,2:  \| want: ::test_ns_1::test_ns_2::foo |
| namespace-17.10 | `bug`: namespaces: the result differs | code 2/0,2: 0 \| want: 1 |
| namespace-17.7 | `bug`: namespaces: the result differs | code 1/0,2: can't read "x": no such variable \| want: 314159 |
| namespace-19.3 | `bug`: namespaces: the result differs | code 0/1:  \| want: namespace "test_ns_99" not found in "::test_ns_1" |
| namespace-20.3 | `bug`: namespaces: the result differs | code 0/0,2: ::test_ns_2: ::test_ns_1 \| want:  |
| namespace-21.4 | `bug`: namespaces: the result differs | code 0/0,2: ::test_ns_1::test_ns_2::test_ns_3 \| want:  |
| namespace-34.7 | `bug`: namespaces: the result differs | code 0/0,2: {} ::test_ns_3::v3 ::test_ns_2::v2 0 {} \| want: ::env ::test_ns_3::v3 ::te... |
| namespace-37.2 | `bug`: namespaces: the result differs | code 0/1:  \| want: namespace "::test_ns_1::test_ns_foo" not found |
| namespace-42.1 | `bug`: namespaces: the result differs | code 0/0,2: ns 1 {} ns \| want: ns 1 {} {} |
| namespace-42.10 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "::two" \| want: invalid command name *three* |
| namespace-42.2 | `bug`: namespaces: the result differs | code 0/0,2: foo 1 {} foo \| want: foo 1 {} {} |
| namespace-42.4 | `bug`: namespaces: the result differs | code 0/0,2: 1 {unknown or ambiguous subcommand "x": must be x1, or x2} \| want: 1 {unkn... |
| namespace-44.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "::::foobarconfigure" \| want: invalid command name "foo... |
| namespace-45.2 | `bug`: namespaces: the result differs | code 0/0,2: A x \| want: A ::ns::x |
| namespace-46.2 | `bug`: namespaces: the result differs | code 0/0,2: {unknown or ambiguous subcommand "?": must be x1, or x2} {unknown or ambigu... |
| namespace-46.3 | `bug`: namespaces: the result differs | code 0/0,2: 1 {wrong # args: should be "ns subcommand ?arg ...?"} 10 3010 3010 p \| wan... |
| namespace-46.6 | `bug`: namespaces: the result differs | code 1/0,2: invalid command name "foo" \| want:  |
| namespace-46.7 | `bug`: namespaces: the result differs | code 1/0,2: unknown namespace "ns" in namespace delete command \| want:  |
| namespace-46.8 | `bug`: namespaces: the result differs | code 0/0,2: 0 0 \| want: 1 0 |
| namespace-47.1 | `bug`: namespaces: the result differs | code 0/0,2: {0 2 0 2 0 2 0 2 0 {}} {::ns::Magic ::ns::a ::ns::b ::ns::bar ::ns::c} {{ma... |
| namespace-47.2 | `bug`: namespaces: the result differs | code 0/0,2: 1 foobar {foobar     while executing "error foobar"     (procedure "::ns::M... |
| namespace-47.3 | `bug`: namespaces: the result differs | code 0/0,2: 1 {unknown or ambiguous subcommand "spong": must be Magic, a, b, or c} 1 {}... |
| namespace-47.4 | `bug`: namespaces: the result differs | code 0/0,2: 1 {unknown subcommand handler returned bad code: break} {unknown subcommand... |
| namespace-47.5 | `bug`: namespaces: the result differs | code 0/0,2: {LOG foo bar} 1 {unknown subcommand "bar": namespace :: does not export any... |
| namespace-47.6 | `bug`: namespaces: the result differs | code 0/0,2: 1 {unmatched open brace in list} {unmatched open brace in list     while ex... |
| namespace-47.7 | `bug`: namespaces: the result differs | code 0/0,2: foo\|one two three \| want: ::foo\|one two three |
| namespace-47.8 | `bug`: namespaces: the result differs | code 0/0,2: boo\|foo\|one two three \| want: boo\|::foo\|one two three |
| namespace-48.1 | `bug`: namespaces: the result differs | code 0/0,2: {-map {} -namespace ::foo -parameters {} -prefixes 1 -subcommands x -unknow... |
| namespace-48.2 | `bug`: namespaces: the result differs | code 0/0,2: 1 1 1 1 0 0 1 1 \| want: 1 0 1 1 0 0 1 0 |
| namespace-48.3 | `bug`: namespaces: the result differs | code 0/0,2: ::foo 1 {"boo" is not an ensemble command} 1 {"spong" is not an ensemble co... |
| namespace-50.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "bb c d ?e? ?arg ...?" \| want: wrong # args: should ... |
| namespace-50.2 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "string is class ?-strict? ?-failindex var? str" \| w... |
| namespace-50.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "e f" \| want: wrong # args: should be "a b d f" |
| namespace-50.4 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "e f" \| want: wrong # args: should be "a b" |
| namespace-50.5 | `bug`: namespaces: the result differs | code 0/0,2: {wrong # args: should be "bar ev"} {wrong # args: should be "bingo xx"} {wr... |
| namespace-50.6 | `bug`: namespaces: the result differs | code 0/0,2: {wrong # args: should be "target x y"} {wrong # args: should be "target x y... |
| namespace-50.7 | `bug`: namespaces: the result differs | code 0/0,2: {wrong # args: should be "target x y"} {wrong # args: should be "target x y... |
| namespace-50.8 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "e a b subcommand ?arg ...?" \| want: wrong # args: s... |
| namespace-51.13 | `bug`: namespaces: the result differs | code 1/0,2: unknown namespace "::test_ns_2" in namespace delete command \| want: 2 {} {... |
| namespace-51.14 | `bug`: namespaces: the result differs | code 0/0,2: foo0 foo0 {::test_ns_3::foo2 foo0} foo0 foo0 \| want: foo0 {foo1 foo2 foo0}... |
| namespace-51.3 | `bug`: namespaces: the result differs | code 0/0,2: 1,2,global,::test_ns_1 1,2,global,::test_ns_1 global,2,global,::test_ns_1 \... |
| namespace-51.4 | `bug`: namespaces: the result differs | code 0/0,2: 1,2,global,::test_ns_1 1,2,global,::test_ns_1 global,2,global, \| want: glo... |
| namespace-51.7 | `bug`: namespaces: the result differs | code 0/0,2: ::test_ns_1 {} ::test_ns_1 \| want: ::test_ns_1 {} {} |
| namespace-51.8 | `bug`: namespaces: the result differs | code 0/0,2: {::test_ns_1 ::test_ns_2 ::test_ns_3} {} {::test_ns_1 ::test_ns_2 ::test_ns... |
| namespace-51.9 | `bug`: namespaces: the result differs | code 0/0,2: {::test_ns_1 ::test_ns_2 ::test_ns_3} {} {} {::test_ns_1 ::test_ns_2 ::test... |
| namespace-52.11 | `bug`: namespaces: the result differs | code 0/0,2: FAIL \| want: SUCCESS |
| namespace-52.7 | `bug`: namespaces: the result differs | code 1/0,2: invalid command name "dummy" \| want: MYUNKNOWN: dummy a b c |
| namespace-52.8 | `bug`: namespaces: the result differs | code 1/0,2: unknown namespace "::" in namespace delete command \| want: FINE |
| namespace-53.1 | `bug`: namespaces: the result differs | code 0/0,2: ns {1 bar} {} ns \| want: ns {1 bar} {} {} |
| namespace-53.10 | `bug`: namespaces: the result differs | code 0/0,2: 0 0 1 {wrong # args: should be "::ns::x::z1 a1"} 1 {wrong # args: should be... |
| namespace-53.11 | `bug`: namespaces: the result differs | code 0/0,2: 1 {wrong # args: should be "::ns::x::z2 a1 a2"} \| want: 1 {wrong # args: s... |
| namespace-53.2 | `bug`: namespaces: the result differs | code 0/0,2: foo {1 bar} {} foo \| want: foo {1 bar} {} {} |
| namespace-53.7 | `bug`: namespaces: the result differs | code 0/0,2: 1 {wrong # args: should be "ns p1 subcommand ?arg ...?"} 1 {wrong # args: s... |
| namespace-53.8 | `bug`: namespaces: the result differs | code 0/0,2: 0 {1 x2} {} 1 {unknown or ambiguous subcommand "x2": must be Magic, or x1} ... |
| namespace-53.9 | `bug`: namespaces: the result differs | code 0/0,2: 0 {1 x2} {} 1 {unknown or ambiguous subcommand "x2": must be Magic, or x1} ... |
| namespace-55.2 | `design`: inspects the bytecode of Tcl; ztcl has its own bytecode | code 1/0,2: invalid command name "::tcl::unsupported::disassemble" \| want: 1 1 1 * |
| namespace-56.6 | `bug`: namespaces: the result differs | code 2/0,2: 0 \| want: 2 |
| namespace-6.2 | `bug`: namespaces: the result differs | code 0/0,2: ::test_ns_1::::foo ::test_ns_2:::::foo \| want: ::test_ns_1::foo ::test_ns_... |
| namespace-7.7 | `bug`: namespaces: the result differs | setup: can't rename "tcl::info::commands": command doesn't exist |
| namespace-8.1 | `bug`: namespaces: the result differs | code 1/0,2: unknown namespace "::" in namespace delete command \| want: {::test_ns_1 27... |
| namespace-8.3 | `bug`: namespaces: the result differs | code 0/0,2: ::test_ns_1::test_ns_2 {} {} 0 {} {} \| want: ::test_ns_1::test_ns_2 {} {} ... |
| namespace-8.4 | `bug`: namespaces: the result differs | code 0/0,2: {::test_ns_import::cmd1 ::test_ns_import::cmd2 ::test_ns_import::p} {} {::t... |
| namespace-8.7 | `bug`: namespaces: the result differs | code 0/0,2: NONE \| want: baz |
| namespace-9.7 | `bug`: namespaces: the result differs | code 0/0,2: {cmd1: a b c} {cmd1: d e f} {} ::test_ns_export::cmd1 ::test_ns_export::cmd... |
| namespace-9.9 | `bug`: namespaces: the result differs | code 0/1: ::one::cmd \| want: import pattern * would create a loop* |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 1 | `tcl`: tclsh skips it too |
| memory | 1 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testevalobjv | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### notify.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testevent | 23 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### nre.test

| Test | Bucket | Result (start) |
|---|---|---|
| nre-4.2 | `bug`: the setup or the cleanup of the test fails | setup: "::dict" is not an ensemble command |

| Skipped by | Tests | Bucket |
|---|---|---|
| testnrelevels | 23 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### obj.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testobj | 84 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| longIs32bit | 5 | `platform`: a constraint of another platform or word size |

### oo.test

| Test | Bucket | Result (start) |
|---|---|---|
| oo-0.2 | `bug`: TclOO: the result differs | code 1/0,2: unknown namespace "::" in namespace delete command \| want:  |
| oo-0.9 | `bug`: TclOO: the result differs | code 0/0,2: TclOO 1.1.0 0 \| want: TclOO 1.1.0 1 |
| oo-1.21 | `feature`: the slot classes of TclOO ('oo::Slot') | code 1/0,2: ::oo::Slot does not refer to an object \| want: {} {::oo::Slot ::oo::class ... |
| oo-1.25 | `bug`: TclOO: the result differs | code 0/0,2: D D D \| want: D D D D D D |
| oo-14.2 | `bug`: TclOO: the result differs | code 0/0,2: 1 {unknown method "?": must be bar, boo or destroy} 0 {::fooTest in bar} 0 ... |
| oo-14.3 | `bug`: TclOO: the result differs | cleanup: mixin deletion failed to destroy dependent instance |
| oo-14.4 | `bug`: TclOO: the result differs | setup: can't create object "c": command already exists with that name |
| oo-15.1 | `bug`: TclOO: the result differs | code 1/0,2: can't create object "Aclass": command already exists with that name \| want... |
| oo-15.13.1 | `bug`: TclOO: the result differs | cleanup: invalid command name "Cls2" |
| oo-15.13.2 | `bug`: TclOO: the result differs | code 1/0,2: ::dupens refers to an existing namespace \| want: 0 ::Cls2 1 |
| oo-15.14 | `bug`: TclOO: the result differs | code 1/0,2: ::dupens refers to an existing namespace \| want: {} ::dupens::test-15.14 |
| oo-18.10 | `bug`: TclOO: the result differs | code 0/0,2: foobar     while executing "error foobar"     (in namespace eval "::oo::obj... |
| oo-18.11 | `bug`: TclOO: the result differs | code 0/0,2: foobar     while executing "error foobar"     (in namespace eval "::oo::obj... |
| oo-18.12 | `bug`: TclOO: the result differs | code 1/0,2: self may only be called from inside a method \| want: ::foo |
| oo-18.2 | `bug`: TclOO: the result differs | code 0/0,2: 1 foo {foo     while executing "error foo"     (in namespace eval "::oo::de... |
| oo-18.3b | `bug`: TclOO: the result differs | code 0/0,2: 1 bar {bar     while executing "error bar"     invoked from within "eval er... |
| oo-18.5 | `bug`: TclOO: the result differs | code 0/0,2: 1 foo {foo     while executing "error foo"     (in "my eval" script line 1)... |
| oo-18.6 | `bug`: TclOO: the result differs | code 0/0,2: foo     while executing "::error foo"     (in definition script for class "... |
| oo-18.7 | `bug`: TclOO: the result differs | code 0/0,2: 1 foo {foo     while executing "error foo"     (in definition script for ob... |
| oo-18.8 | `bug`: TclOO: the result differs | code 0/0,2: foobar     while executing "error foobar"     (in namespace eval "::oo::obj... |
| oo-18.9 | `bug`: TclOO: the result differs | code 0/0,2: err     while executing "error err"     (in definition script for class "::... |
| oo-19.4 | `bug`: TclOO: the result differs | code 0/0,2: {} 0 {} \| want: ::testoo19_4::foo 0 ::testoo19_4::foo |
| oo-2.7 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "::k::s create X j" \| want: wrong # args: should be ... |
| oo-2.8 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "::k::t create X j" \| want: wrong # args: should be ... |
| oo-20.3 | `bug`: TclOO: the result differs | code 0/1:  \| want: can't define "a(b)": name refers to an element in an array |
| oo-20.4 | `bug`: TclOO: the result differs | code 0/1:  \| want: can't define "a(b)": name refers to an element in an array |
| oo-22.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| oo-22.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| oo-22.3 | `bug`: TclOO: the result differs | code 1/0,2: invalid command name "my" \| want: {* method Work class ::A *} {* method Wo... |
| oo-22.4 | `bug`: TclOO: the result differs | code 1/0,2: invalid command name "my" \| want: {* method Work class ::B *} {* method Wo... |
| oo-22.5 | `bug`: TclOO: the result differs | code 1/0,2: invalid command name "my" \| want: {* method Work class ::B *} {* method Wo... |
| oo-22.6 | `bug`: TclOO: the result differs | code 1/0,2: invalid command name "my" \| want: {* method Work class ::A *} {* method Wo... |
| oo-23.1 | `bug`: TclOO: the result differs | code 1/0,2: ::oo::Obj461 does not refer to an object \| want: 1 1,2 1,2,3 1,2,3,4 1,x,3,4 |
| oo-24.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: unknown method "foo": must be destroy or dummy \| want: unknown method "foo":... |
| oo-24.2 | `message`: an error where tclsh also gives one, with another message | code 1/1: unknown method "foo": must be destroy, dummy or dummy2 \| want: unknown metho... |
| oo-27.18 | `bug`: TclOO: the result differs | code 0/1: 1,1 2,2 \| want: unknown method "-?": must be * |
| oo-3.4 | `bug`: TclOO: the result differs | code 0/0,2: 0 ok ::oo::Obj66::state ::oo::Obj66::localcmdexists {} \| want: 0 ok *::sta... |
| oo-3.4a | `bug`: TclOO: the result differs | code 0/0,2: 0 ok ::oo::Obj68::state ::oo::Obj68::localcmdexists {} \| want: 0 ok *::sta... |
| oo-3.5 | `bug`: TclOO: the result differs | code 0/0,2: 0 ok ::oo::Obj70::state ::oo::Obj70::localcmdexists {} \| want: 0 ok *::sta... |
| oo-3.5a | `bug`: TclOO: the result differs | code 1/0,2: can't read "result": no such variable \| want: ::obj ok localcmdexists ::ob... |
| oo-32.1 | `feature`: the slot classes of TclOO ('oo::Slot') | setup: class "oo::Slot" does not exist |
| oo-32.2 | `feature`: the slot classes of TclOO ('oo::Slot') | setup: class "oo::Slot" does not exist |
| oo-32.3 | `feature`: the slot classes of TclOO ('oo::Slot') | setup: class "oo::Slot" does not exist |
| oo-32.4 | `feature`: the slot classes of TclOO ('oo::Slot') | setup: class "oo::Slot" does not exist |
| oo-32.5 | `feature`: the slot classes of TclOO ('oo::Slot') | setup: class "oo::Slot" does not exist |
| oo-33.1 | `feature`: the slot classes of TclOO ('oo::Slot') | setup: class "oo::Slot" does not exist |
| oo-33.2 | `feature`: the slot classes of TclOO ('oo::Slot') | setup: class "oo::Slot" does not exist |
| oo-33.3 | `feature`: the slot classes of TclOO ('oo::Slot') | setup: class "oo::Slot" does not exist |
| oo-33.4 | `feature`: the slot classes of TclOO ('oo::Slot') | setup: class "oo::Slot" does not exist |
| oo-34.1 | `feature`: the slot classes of TclOO ('oo::Slot') | code 1/0,2: filter does not refer to an object \| want: ::oo::Slot ::oo::Slot ::oo::Slo... |
| oo-34.2 | `feature`: the slot classes of TclOO ('oo::Slot') | code 1/0,2: oo::Slot does not refer to an object \| want: ::oo::define::filter ::oo::de... |
| oo-34.3 | `bug`: TclOO: the result differs | code 1/0,2: oo::define::filter does not refer to an object \| want: {-append -clear -se... |
| oo-34.4 | `bug`: TclOO: the result differs | code 1/0,2: oo::define::mixin does not refer to an object \| want: {-append -clear -set... |
| oo-34.5 | `bug`: TclOO: the result differs | code 1/0,2: oo::define::superclass does not refer to an object \| want: {-append -clear... |
| oo-34.6 | `bug`: TclOO: the result differs | code 1/0,2: oo::define::variable does not refer to an object \| want: {-append -clear -... |
| oo-34.7 | `bug`: TclOO: the result differs | code 1/0,2: oo::objdefine::filter does not refer to an object \| want: {-append -clear ... |
| oo-34.8 | `bug`: TclOO: the result differs | code 1/0,2: oo::objdefine::mixin does not refer to an object \| want: {-append -clear -... |
| oo-34.9 | `bug`: TclOO: the result differs | code 1/0,2: oo::objdefine::variable does not refer to an object \| want: {-append -clea... |
| oo-35.2 | `bug`: TclOO: the result differs | code 1/0,2: unknown method "create": must be destroy or eat \| want: ::appleClass ::ora... |
| oo-35.5 | `bug`: TclOO: the result differs | code 1/0,2: can't create object "D": command already exists with that name \| want: {c ... |
| oo-35.7.1 | `bug`: TclOO: the result differs | code 0/0,2: can't delete "o": command doesn't exist invalid command name "::oo::Obj563"... |
| oo-35.7.2 | `bug`: TclOO: the result differs | code 0/0,2: Destroyed invalid command name "::oo::Obj568" \| want: Destroyed impossible... |
| oo-6.10 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "my handler a b c" \| want: wrong # args: should be "... |
| oo-6.11 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "my handler a b c" \| want: wrong # args: should be "... |
| oo-6.13 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "my handler a b c" \| want: wrong # args: should be "... |
| oo-6.14 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "my handler a b c" \| want: wrong # args: should be "... |
| oo-6.16 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "my handler a b c d" \| want: wrong # args: should be... |
| oo-6.17 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "my handler a b c d" \| want: wrong # args: should be... |
| oo-6.18 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "string length string" \| want: wrong # args: should ... |
| oo-6.8 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "my handler a b c" \| want: wrong # args: should be "... |
| oo-7.10 | `bug`: TclOO: the result differs | code 0/0,2: c2::m1 c2::destructor c2::m1 no-self c1::m1 /c2::m1 0 {c2::m1 c2::destructo... |
| oo-7.7 | `bug`: TclOO: the result differs | code 0/0,2: {unknown method "?": must be destroy or foo} foo! {foo!     while executing... |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 14 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| knownBug | 3 | `tcl`: tclsh skips it too |

### ooNext2.test

| Test | Bucket | Result (start) |
|---|---|---|
| oo-call-2.10 | `message`: an error where tclsh also gives one, with another message | code 1/1: a does not refer to an object \| want: wrong # args: should be "info class ca... |
| oo-call-2.8 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "info class subcommand ?arg ...?" \| want: wrong # ar... |
| oo-call-2.9 | `message`: an error where tclsh also gives one, with another message | code 1/1: a does not refer to an object \| want: wrong # args: should be "info class ca... |
| oo-call-3.3 | `bug`: TclOO: the result differs | code 2/0,2: {{{method <constructor> object method} {method <constructor> object method}... |
| oo-call-3.4 | `bug`: TclOO: the result differs | code 2/0,2: {{{method <destructor> object method} {method <destructor> object method}} ... |
| oo-nextto-2.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "::oo::Obj44 x y" \| want: wrong # args: should be "n... |
| oo-nextto-2.7 | `message`: an error where tclsh also gives one, with another message | code 1/1: method implementation by "B" not reachable from here \| want: method has no n... |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 5 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### opt.test

| Test | Bucket | Result (start) |
|---|---|---|
| opt-10.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptProc" \| want: ambigous option "-fL", choos... |
| opt-10.10 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "optTest"} \| want: 1 {too many arguments (unexpect... |
| opt-10.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptProc" \| want: 1 |
| opt-10.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptProc" \| want: 1 |
| opt-10.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptProc" \| want: ambigous option "-fLag1X", c... |
| opt-10.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "optTest"} \| want: 1 {no value given for parameter... |
| opt-10.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "optTest"} \| want: 1 {Usage information:     Var/F... |
| opt-10.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "optTest" \| want: save 1 tst 7 0 |
| opt-10.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "optTest" \| want: save 0 8 7 0 |
| opt-10.9 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "optTest" \| want: save 1 tst 7 1 |
| opt-11.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptKeyRegister" \| want: 1 {too many arguments... |
| opt-11.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptKeyRegister" \| want: a b c |
| opt-2.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptKeyRegister" \| want: testkey 1 {} 0 |
| opt-3.1 | `feature`: the 'opt' package | code 1/0,2: can't read "::tcl::OptDescN": no such variable \| want: 1 {} {} 0 1 |
| opt-3.2 | `feature`: the 'opt' package | code 1/0,2: can't read "::tcl::OptDescN": no such variable \| want: 1 0 |
| opt-4.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptProc" \| want:  |
| opt-5.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptProc" \| want: 0 1 1 1 |
| opt-6.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptKeyRegister" \| want: 1 {Usage information:... |
| opt-7.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::OptCheckType" \| want: 23 23.0 1 -blah {a b c}... |
| opt-8.1 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::Lempty" \| want: 1 |
| opt-8.10 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::Lvarpop" \| want: {b c 7 e} f |
| opt-8.11 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::Lassign" \| want: 3 a {b c 7 e} f 0 |
| opt-8.2 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::Lempty" \| want: 0 |
| opt-8.3 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::Lget" \| want: d |
| opt-8.4 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::Lvarset" \| want: a {b c D e} f |
| opt-8.5 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::Lvarset1" \| want: a b c {} {} {} X |
| opt-8.6 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::Lvarincr" \| want: a {b c 8 e} f |
| opt-8.7 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::Lvarincr" \| want: a {b c -2 e} f |
| opt-9.1 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::SetMax" \| want: 7 |
| opt-9.2 | `feature`: the 'opt' package | code 1/0,2: invalid command name "::tcl::SetMin" \| want: -7 |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1 | `feature`: the 'opt' package |

### package.test

| Test | Bucket | Result (start) |
|---|---|---|
| package-1.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "::pkg::create" \| want: wrong # args: should be "*" |
| package-1.10 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::pkg::create" \| want: package ifneeded foo 1.0 [lis... |
| package-1.11 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::pkg::create" \| want: package ifneeded foo 1.0 [lis... |
| package-1.12 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::pkg::create" \| want: package ifneeded foo 1.0 [lis... |
| package-1.13 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::pkg::create" \| want: package ifneeded foo 1.0 [lis... |
| package-1.14 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::pkg::create" \| want: package ifneeded foo 1.0 [lis... |
| package-1.15 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::pkg::create" \| want: package ifneeded foo 1.0 [lis... |
| package-1.16 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::pkg::create" \| want: package ifneeded foo 1.0 [lis... |
| package-1.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "::pkg::create" \| want: unknown option "bar": * |
| package-1.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "::pkg::create" \| want: value for "-load" missing: * |
| package-1.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "::pkg::create" \| want: value for "-name" missing: * |
| package-1.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "::pkg::create" \| want: value for "-version" missing: * |
| package-1.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "::pkg::create" \| want: at least one of -load and -sour... |
| package-1.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::pkg::create" \| want: package ifneeded foo 1.0 [lis... |
| package-1.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::pkg::create" \| want: package ifneeded foo 1.0 [lis... |
| package-1.9 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::pkg::create" \| want: package ifneeded foo 1.0 [lis... |
| package-11.0 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| package-11.132 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 \| want: 0 |
| package-11.26 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| package-11.27 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| package-11.98 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| package-11.99 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| package-13.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: stable \| want: latest |
| package-15.4 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: cannot change the preference to stable \| want: stable latest latest |
| package-3.10 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {attempt to provide package t 2.1 failed: ifneeded test} {ifneeded test  ... |
| package-3.15 | `bug`: the result differs from tclsh 8.6.16 | code 2/0,2: {a b} \| want: {a b} 0- |
| package-3.16 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {testing package unknown} {testing package unknown     while executing "e... |
| package-3.25 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {attempt to provide package t 2.1 failed: ifneeded test} {EI     invoked ... |
| package-3.26 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {attempt to provide package t 2.1 failed: ifneeded test} {EI     invoked ... |
| package-3.27 | `message`: an error where tclsh also gives one, with another message | code 1/1: attempt to provide package foo 1 failed: attempt to provide package foo 1 fai... |
| package-3.28 | `message`: an error where tclsh also gives one, with another message | code 1/1: attempt to provide package foo 1 failed: can't find package foo 2 \| want: ci... |
| package-3.29 | `message`: an error where tclsh also gives one, with another message | code 1/1: attempt to provide package foo 1 failed: attempt to provide package bar 1 fai... |
| package-3.30 | `message`: an error where tclsh also gives one, with another message | code 1/1: attempt to provide package foo 1 failed: conflicting versions provided for pa... |
| package-3.31 | `message`: an error where tclsh also gives one, with another message | code 1/1: attempt to provide package foo 1 failed: foo \| want: foo |
| package-3.32 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 \| want:  |
| package-3.37 | `message`: an error where tclsh also gives one, with another message | code 1/1: attempt to provide package foo 1 failed: package foo 1 not provided \| want: ... |
| package-3.40 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "break" \| want: bad return code:* |
| package-3.41 | `message`: an error where tclsh also gives one, with another message | code 1/1: wrong # args: should be "continue" \| want: bad return code:* |
| package-3.42 | `bug`: the result differs from tclsh 8.6.16 | code 2/1: ;# \| want: bad return code:* |
| package-3.43 | `bug`: the result differs from tclsh 8.6.16 | code 10/1: ;# \| want: bad return code:* |
| package-4.32 | `message`: an error where tclsh also gives one, with another message | code 1/1: attempt to provide package t 2.3 failed: synthetic error \| want: synthetic e... |
| package-4.55 | `message`: an error where tclsh also gives one, with another message | code 1/1: expected versionMin-versionMax but got "3.2-x.y" \| want: expected version nu... |
| package-4.56 | `message`: an error where tclsh also gives one, with another message | code 1/1: expected versionMin-versionMax but got "x.y-3.2" \| want: expected version nu... |
| package-9.24 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| package-9.25 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |

### parse.test

| Test | Bucket | Result (start) |
|---|---|---|
| parse-18.19 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 abc, \| want: 1 {extra characters after close-brace} |
| parse-19.1 | `bug`: the setup or the cleanup of the test fails | setup: invalid command name "load" |
| parse-19.2 | `bug`: the setup or the cleanup of the test fails | setup: invalid command name "load" |
| parse-8.12 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: ns \| want: global |
| parse-9.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't read "x": no such variable     while executing "set x"     invoked... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testparser | 117 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testparsevarname | 12 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testevalobjv | 10 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testparsevar | 5 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testbytestring | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| emptyTest | 2 | `tcl`: tclsh skips it too |
| testevent | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| memory | 1 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### parseExpr.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testexprparser | 215 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| expr:testexprparser && !ieeeFloatingPoint | 1 | `internals`: a C test command or package of the Tcl test binary |
| expr:testexprparser && ieeeFloatingPoint | 1 | `internals`: a C test command or package of the Tcl test binary |

### parseOld.test

| Test | Bucket | Result (start) |
|---|---|---|
| parseOld-10.14 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {missing )} {missing )     while executing "eval \$x[format "%01000d" 0](... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testbytestring | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### pkgMkIndex.test

| Test | Bucket | Result (start) |
|---|---|---|
| pkgMkIndex-1.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: {1 {invalid command name "pkg_mkIndex"}} / \| want: {1 {no files matched gl... |
| pkgMkIndex-11.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{fubar:1.0 {tclPkgSetup ... |
| pkgMkIndex-12.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{football:1.0 {tclPkgSet... |
| pkgMkIndex-13.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{spacename:1.0 {tclPkgSe... |
| pkgMkIndex-14.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "tcl::Pkg::CompareExtension" \| want: 1 |
| pkgMkIndex-14.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "tcl::Pkg::CompareExtension" \| want: 0 |
| pkgMkIndex-14.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "tcl::Pkg::CompareExtension" \| want: 1 |
| pkgMkIndex-14.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "tcl::Pkg::CompareExtension" \| want: 1 |
| pkgMkIndex-14.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "tcl::Pkg::CompareExtension" \| want: 0 |
| pkgMkIndex-14.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "tcl::Pkg::CompareExtension" \| want: 0 |
| pkgMkIndex-2.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{simple:1.0 {tclPkgSetup... |
| pkgMkIndex-2.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{simple:1.0 {source /pkg... |
| pkgMkIndex-2.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{simple:1.0 {source /pkg... |
| pkgMkIndex-2.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{simple:1.0 {source /pkg... |
| pkgMkIndex-3.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{global:1.0 {tclPkgSetup... |
| pkgMkIndex-4.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{pkg2:1.0 {tclPkgSetup {... |
| pkgMkIndex-4.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{pkg2:1.0 {source /pkg/p... |
| pkgMkIndex-5.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{std:1.0 {tclPkgSetup {s... |
| pkgMkIndex-6.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{pkg1:1.0 {tclPkgSetup {... |
| pkgMkIndex-6.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{pkg1:1.0 {source /pkg/p... |
| pkgMkIndex-7.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{pkg3:1.0 {tclPkgSetup {... |
| pkgMkIndex-7.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{pkg3:1.0 {source /pkg/p... |
| pkgMkIndex-8.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{pkg2:1.0 {tclPkgSetup {... |
| pkgMkIndex-8.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{pkg2:1.0 {source /pkg/p... |
| pkgMkIndex-9.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 0/0,2: 1 {invalid command name "pkg_mkIndex"} \| want: 0 {{circ1:1.0 {tclPkgSetup ... |

| Skipped by | Tests | Bucket |
|---|---|---|
| pkga.soRequired | 2 | `internals`: a C test package of the Tcl build |

### platform.test

| Test | Bucket | Result (start) |
|---|---|---|
| platform-1.0 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: ztcl \| want: Tcl |
| platform-1.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: byteOrder engine machine os osVersion platform pointerSize user wordSize \|... |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 2 | `feature`: the 'platform' package |
| testCPUID | 1 | `internals`: a C test command or package of the Tcl test binary |

### proc-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| proc-old-5.14 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: invoked "break" outside of a loop     while executing "tproc" \| want: invo... |
| proc-old-5.15 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: invoked "continue" outside of a loop     while executing "tproc" \| want: i... |
| proc-old-5.16 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {Nested error} {Nested error     while executing "error "Nested error""  ... |
| proc-old-7.11 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "normalizeMsg" \| want: 1 {couldn't open "_bad_file_na... |
| proc-old-7.12 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "normalizeMsg" \| want: 1 {couldn't open "_bad_file_na... |
| proc-old-7.13 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "normalizeMsg" \| want: 1 {couldn't open "_bad_file_na... |
| proc-old-7.14 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "normalizeMsg" \| want: 1 {couldn't open "_bad_file_na... |
| proc-old-7.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {bad completion code "-14": must be ok, error, return, break, continue, o... |

### proc.test

| Test | Bucket | Result (start) |
|---|---|---|
| proc-1.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: can't create procedure "test_ns_1::baz::p": unknown namespace |
| proc-3.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: {p in ::test_ns_1::baz} ::p \| want: {p in ::} ::p |
| proc-6.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 \| want: -5 |

| Skipped by | Tests | Bucket |
|---|---|---|
| procbodytest | 9 | `internals`: a C test command or package of the Tcl test binary |

### reg.test

| Test | Bucket | Result (start) |
|---|---|---|
| reg-10.15.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UEMPTYMATCH \| want: 0 {} |
| reg-10.15.execute | `bug`: regular expressions: the match differs | code 0/0,2: 1 {} \| want: 1 ^ |
| reg-11.1 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.1 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.2 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.2 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.3 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: REG_UNONPOSIX \| want: {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.3 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: REG_UNONPOSIX \| want: {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.4 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.4 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.5 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.5 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.6 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: REG_UNONPOSIX \| want: {REG_UNONPOSIX REG_ULOCALE} |
| reg-11.6 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: REG_UNONPOSIX \| want: {REG_UNONPOSIX REG_ULOCALE} |
| reg-13.33.execute | `bug`: regular expressions: the match differs | code 0/0,2: 0 {} \| want: 1 a�0x |
| reg-13.34.execute | `bug`: regular expressions: the match differs | code 0/0,2: 0 {} \| want: 1 a�0x |
| reg-13.6.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-15.13.execute | `bug`: regular expressions: the match differs | code 0/0,2: 0 {} \| want: 1 a81b |
| reg-16.3.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {} |
| reg-16.9.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {REG_UBRACES REG_UNONPOSIX REG_UUNSPEC} \| want: 0 {REG_UBOUNDS REG_UNONP... |
| reg-16.9.execute | `bug`: regular expressions: the match differs | code 0/0,2: 0 {} \| want: 1 abc |
| reg-17.1.compile | `feature`: the REG_U flags of 'regexp -about' | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-17.1.execute | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-19.4 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-19.4 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-19.5 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: {} \| want: REG_UUNPORT |
| reg-19.5 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: {} \| want: REG_UUNPORT |
| reg-2.1.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_BADRPT \| want: 1 REG_INVARG |
| reg-2.2.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_BADRPT \| want: 1 REG_INVARG |
| reg-2.3.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_BADRPT \| want: 1 REG_INVARG |
| reg-2.4.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_BADRPT \| want: 1 REG_INVARG |
| reg-2.5.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_BADRPT \| want: 1 REG_INVARG |
| reg-20.1 ARE.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 1 REG_BADRPT \| want: 1 REG_BADPAT |
| reg-20.1 BRE.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 1 REG_BADRPT \| want: 1 REG_BADPAT |
| reg-20.3 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UNONPOSIX |
| reg-20.3 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-20.3 BRE.execute | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-20.5.compile | `feature`: the REG_U flags of 'regexp -about' | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-20.5.execute | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-20.6.compile | `feature`: the REG_U flags of 'regexp -about' | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-20.6.execute | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-20.8 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-20.8 BRE.execute | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-21.35.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 3 {} \| want: 3 REG_UUNPORT |
| reg-21.35.execute | `bug`: regular expressions: the match differs | code 0/0,2: 1 { TO foo} foo foo {} \| want: 1 { TO foo} foo o {} |
| reg-23.3.execute | `bug`: regular expressions: the match differs | code 0/0,2: 1 ab \| want: 1 abc |
| reg-23.4.execute | `bug`: regular expressions: the match differs | code 0/0,2: 1 \| want: 0 |
| reg-23.6.execute | `bug`: regular expressions: the match differs | code 0/0,2: 0 {} \| want: 1 a |
| reg-29.1.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 0 {3 2} {} |
| reg-29.10.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 1 {2 4} {7 6} |
| reg-29.11.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 0 {2 3} {} |
| reg-29.12.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 1 {2 4} {5 4} |
| reg-29.13.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 1 {2 4} {6 5} |
| reg-29.14.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 1 {2 4} {6 5} |
| reg-29.15.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 1 {2 4} {7 6} |
| reg-29.16.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 1 {3 4} {2 4} |
| reg-29.17.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 0 {3 5} {} |
| reg-29.2.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 0 {1 2} {} |
| reg-29.3.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 0 {0 3} {} |
| reg-29.4.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 0 {3 4} {} |
| reg-29.5.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 1 {0 2} {0 2} |
| reg-29.6.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 1 {2 4} {2 4} |
| reg-29.7.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 0 {2 3} {} |
| reg-29.8.execute | `internals`: a C test command of the Tcl test binary, with no stand-in... | code 1/0,2: testregexp: REG_EXPECT has no stand-in \| want: 1 {2 4} {2 4} |
| reg-30.6 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-30.6 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-30.8.execute | `bug`: regular expressions: the match differs | code 0/0,2: 1 \| want: 0 |
| reg-30.9.execute | `bug`: regular expressions: the match differs | code 0/0,2: 0 {} \| want: 1 it0 |
| reg-32.1 | `bug`: regular expressions: the match differs | code 1/0,2: can't read "resvar": no such variable \| want: 0 7 |
| reg-32.2 | `bug`: regular expressions: the match differs | code 1/0,2: can't read "resvar": no such variable \| want: 0 7 |
| reg-32.3 | `bug`: regular expressions: the match differs | code 1/0,2: can't read "resvar": no such variable \| want: 0 7 |
| reg-32.3.1 | `bug`: regular expressions: the match differs | code 1/0,2: can't read "resvar": no such variable \| want: 0 -1 |
| reg-33.22 | `bug`: regular expressions: the match differs | code 0/0,2: 0 \| want: 1 |
| reg-6.5.compile | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-6.5.execute | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: quantifier operand invalid \| ... |
| reg-9.10 ARE.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_ECOLLATE \| want: 1 REG_ERANGE |
| reg-9.10 BRE.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_ECOLLATE \| want: 1 REG_ERANGE |
| reg-9.11 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_ULOCALE |
| reg-9.11 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_ULOCALE |
| reg-9.13 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: {} \| want: REG_ULOCALE |
| reg-9.13 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: {} \| want: REG_ULOCALE |
| reg-9.14 ARE.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_ECTYPE \| want: 1 REG_ERANGE |
| reg-9.14 BRE.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_ECTYPE \| want: 1 REG_ERANGE |
| reg-9.15 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-9.15 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-9.16 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-9.16 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 REG_UNONPOSIX \| want: 0 {REG_UNONPOSIX REG_ULOCALE} |
| reg-9.27 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-9.27 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-9.29 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-9.29 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-9.31 ARE.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_ERANGE \| want: 1 REG_ERANGE |
| reg-9.31 BRE.error | `bug`: regular expressions: the error class of a bad pattern | code 0/0,2: 0 REG_ERANGE \| want: 1 REG_ERANGE |
| reg-9.32 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-9.32 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-9.4 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 1/0,2: couldn't compile regular expression pattern: invalid collating element \| w... |
| reg-9.4 ARE.execute | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: invalid collating element \| w... |
| reg-9.4 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 1/0,2: couldn't compile regular expression pattern: invalid collating element \| w... |
| reg-9.4 BRE.execute | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: invalid collating element \| w... |
| reg-9.44.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {REG_UBBS REG_UNONPOSIX} \| want: 0 {REG_UBBS REG_UNONPOSIX REG_UUNPORT} |
| reg-9.5 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 1/0,2: couldn't compile regular expression pattern: invalid collating element \| w... |
| reg-9.5 ARE.execute | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: invalid collating element \| w... |
| reg-9.5 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 1/0,2: couldn't compile regular expression pattern: invalid collating element \| w... |
| reg-9.5 BRE.execute | `bug`: regular expressions: a valid pattern that ztcl does not c... | code 1/0,2: couldn't compile regular expression pattern: invalid collating element \| w... |
| reg-9.6 ARE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |
| reg-9.6 BRE.compile | `feature`: the REG_U flags of 'regexp -about' | code 0/0,2: 0 {} \| want: 0 REG_UUNPORT |

| Skipped by | Tests | Bucket |
|---|---|---|
| localeRegexp | 100 | `tcl`: the test file sets the constraint false, or it is false in tclsh 8.6 on Linux |
| knownBug | 9 | `tcl`: tclsh skips it too |
| nonPortable | 1 | `tcl`: tclsh skips it too |

### regexp.test

| Test | Bucket | Result (start) |
|---|---|---|
| regexp-22.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: 0 {REG_UBRACES REG_UUNSPEC} \| want: *too many colors* |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 3 | `tcl`: tclsh skips it too |

### regexpComp.test

| Test | Bucket | Result (start) |
|---|---|---|
| regexpComp-21.10 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 4 barfbarobarobar \| want: 3 barfbarobaro |
| regexpComp-21.11 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 bar \| want: 0 {} |

### registry.test

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 125 | `platform`: a constraint of another platform or word size |

### rename.test

| Test | Bucket | Result (start) |
|---|---|---|
| rename-5.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "tcl_wordBreakBefore" \| want:  |

| Skipped by | Tests | Bucket |
|---|---|---|
| testdel | 8 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### resolver.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testinterpresolver | 10 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### result.test

| Test | Bucket | Result (start) |
|---|---|---|
| result-6.3 | `internals`: the C API of Tcl | code 0/0,2: eek \| want: bad -errorcode value: expected a list but got "{}a" |
| result-6.4 | `internals`: the C API of Tcl | code 1/0,2: key "-errorcode" not known in dictionary \| want: {bad -errorstack value: e... |
| result-6.5 | `internals`: the C API of Tcl | code 1/0,2: key "-errorcode" not known in dictionary \| want: {forbidden odd-sized list... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testsaveresult | 11 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testsetobjerrorcode | 5 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testseterrorcode | 4 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testreturn | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### safe-stock.test

| Test | Bucket | Result (start) |
|---|---|---|
| safe-stock-7.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want: 2.* |
| safe-stock-7.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want: {$p(:0:)} {$p(:*:)} -- 1... |
| safe-stock-7.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want: {$p(:0:)} {$p(:*:)} -- 0... |
| safe-stock-9.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |

### safe.test

| Test | Bucket | Result (start) |
|---|---|---|
| safe-1.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "safe::interpConfigure" \| want: no value given for para... |
| safe-1.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "safe::interpCreate" \| want: Usage information:     Var... |
| safe-1.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "safe::interpInit" \| want: bad value "-noStatics" for p... |
| safe-11.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-11.1a | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-11.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-11.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-11.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-11.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-11.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-11.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-11.7.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-11.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-11.8.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-12.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-12.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-12.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-12.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-12.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-12.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-12.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.10 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.7.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-13.9 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-15.1 | `feature`: the 'safe' package | code 1/0,2: invalid command name "tcl::file::split" \| want: 1 {a b c} 1 {a b c} 1 {inv... |
| safe-15.2 | `feature`: the 'safe' package | code 1/0,2: invalid command name "tcl::file::split" \| want: 1 {a b c} 1 {a b c} 1 {inv... |
| safe-16.1 | `feature`: the 'safe' package | setup: can't read "env(HOME)": no such variable |
| safe-16.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-16.3 | `feature`: the 'safe' package | setup: can't read "env(HOME)": no such variable |
| safe-16.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-16.5 | `feature`: the 'safe' package | setup: can't read "env(HOME)": no such variable |
| safe-16.6 | `feature`: the 'safe' package | setup: can't read "env(HOME)": no such variable |
| safe-16.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-16.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-2.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-2.3 | `feature`: the 'safe' package | code 1/0,2: interpreter named "a" already exists, cannot create \| want: ::tcl::mathfun... |
| safe-3.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-3.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-3.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-3.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-4.1 | `feature`: the 'safe' package | code 1/0,2: interpreter named "a" already exists, cannot create \| want:  |
| safe-4.2 | `feature`: the 'safe' package | code 1/0,2: interpreter named "a" already exists, cannot create \| want:  |
| safe-4.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-4.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want:  |
| safe-5.1 | `feature`: the 'safe' package | code 0/0,2: 1 {invalid command name "report1"} 1 {invalid command name "report2"} \| wa... |
| safe-5.3 | `feature`: the 'safe' package | code 0/0,2: 1 {can't find package SafeTestPackage1} 1 {can't find package SafeTestPacka... |
| safe-5.4 | `feature`: the 'safe' package | code 0/0,2: 1 {can't find package SafeTestPackage1} 1 {can't find package SafeTestPacka... |
| safe-5.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "tcl::tm::path" |
| safe-5.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "tcl::tm::path" |
| safe-6.1 | `feature`: the 'safe' package | code 0/0,2: errorCode errorInfo tcl_patchLevel tcl_platform tcl_precision tcl_version \... |
| safe-6.3 | `feature`: the 'safe' package | code 0/0,2: byteOrder engine machine os osVersion platform pointerSize user wordSize \|... |
| safe-7.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::interpCreate" |
| safe-7.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want: {$p(:0:)} {$p(:*:)} {$p(... |
| safe-7.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want: {} {} ok {} 0 {} |
| safe-7.3.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want: {} {} ok ok {} 0 {} |
| safe-7.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want: {$p(:0:)} {$p(:*:)} -- 0... |
| safe-8.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-8.10 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want: ok |
| safe-8.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-8.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::setLogCmd" |
| safe-8.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::setLogCmd" |
| safe-8.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::setLogCmd" |
| safe-8.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::setLogCmd" |
| safe-8.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::setLogCmd" |
| safe-8.9 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want: ok |
| safe-9.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want: {} {arg1 arg2 a} |
| safe-9.10 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-9.11 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-9.12 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-9.13 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-9.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "safe::setLogCmd" |
| safe-9.20 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "tcl::tm::path" |
| safe-9.21 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "tcl::tm::path" |
| safe-9.22 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "tcl::tm::path" |
| safe-9.23 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "tcl::tm::path" |
| safe-9.24 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "tcl::tm::path" |
| safe-9.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "safe::interpCreate" \| want: conflicting values given f... |
| safe-9.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "safe::interpCreate" \| want:  |
| safe-9.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "safe::interpCreate" \| want: conflicting values given f... |
| safe-9.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-9.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-9.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |
| safe-9.9 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | cleanup: invalid command name "safe::interpDelete" |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1 | `feature`: the 'safe' package |
| TcltestPackage | 6 | `internals`: a C test command or package of the Tcl test binary |
| emptyTest | 2 | `tcl`: tclsh skips it too |

### scan.test

| Skipped by | Tests | Bucket |
|---|---|---|
| nonPortable | 1 | `tcl`: tclsh skips it too |

### set-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| set-old-10.9 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {illegal search identifier "s-1-b"} \| want: 1 {search identifier "s-1-b"... |
| set-old-7.14 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 0 1 0 1 \| want: 1 0 1 0 0 |
| set-old-7.15 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 0 0 1 1 1 0 1 \| want: 1 0 0 1 1 1 0 0 |
| set-old-7.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't unset "a(14)": no such variable} \| want: 1 {can't unset "a(14)": ... |
| set-old-7.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't unset "a(14)": no such variable} \| want: 1 {can't unset "a(14)": ... |
| set-old-8.35 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't array set "a": variable isn't array} \| want: 1 {can't set "a(a)":... |
| set-old-8.38.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 {} \| want: 1 {can't set "bogusnamespace::var": parent namespace doesn't ... |
| set-old-8.38.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 {} \| want: 1 {can't set "bogusnamespace::var": parent namespace doesn't ... |
| set-old-8.38.7 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 {} \| want: 1 {can't set "bogusnamespace::var(0)": parent namespace doesn... |
| set-old-8.49 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 9 entries in table \| want: 9 entries in table, 4 buckets number of buckets... |
| set-old-9.10 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 a 0 a \| want: 1 {couldn't find search "s-1-a"} 1 {couldn't find search "... |

### set.test

| Test | Bucket | Result (start) |
|---|---|---|
| set-2.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't set "x": variable is read-only} {can't set "x": variable is read-o... |
| set-4.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {can't set "x": variable is read-only} {can't set "x": variable is read-o... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testset2 | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### socket.test

| Test | Bucket | Result (start) |
|---|---|---|
| socket-14.11.0 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: socket is not connected |
| socket-14.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: couldn't open socket: the network policy does not allow the address "192.0.2.... |
| socket-14.8.0 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: ok |
| socket-14.8.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: {} {connection refused} {} \| want: {error reading "sock*": socket is not c... |
| socket-15.1.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: sock2843 \| want: couldn't open socket: connection refused |
| socket_inet-3.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: ready timed_out \| want: ready done |
| socket_inet6-3.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: ready timed_out \| want: ready done |

| Skipped by | Tests | Bucket |
|---|---|---|
| localhost_v6 | 9 | `platform`: a property of the host: a second device, a writable home, IPv6 on localhost, ... |
| nonPortable | 1 | `tcl`: tclsh skips it too |
| win | 1 | `platform`: a constraint of another platform or word size |

### source.test

| Test | Bucket | Result (start) |
|---|---|---|
| source-3.2 | `bug`: the result differs from tclsh 8.6.16 | code 2/3: Silly result \| want: Silly result |
| source-3.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 2 {Simulated error} {couldn't read file "/_non_existent_": no such file or ... |
| source-3.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 2 {} {couldn't read file "/_non_existent_": no such file or directory     w... |
| source-3.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 2 {} {couldn't read file "/_non_existent_": no such file or directory     w... |
| source-4.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |

### split.test

| Test | Bucket | Result (start) |
|---|---|---|
| split-1.15 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: a � \| want: a 💩 b |

### stack.test

| Test | Bucket | Result (start) |
|---|---|---|
| stack-2.1 | `bug`: the recursion limit and its message | code 0/0,2: invalid command name "notaknownproc" \| want: too many nested evaluations (... |
| stack-3.1 | `bug`: the recursion limit and its message | code 1/0,2: 1 1 the recursion limit of this interpreter is 600 \| want: 1 1 |

### string.test

| Test | Bucket | Result (start) |
|---|---|---|
| string-24.15.0 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "tcl::string::reverse" \| want: 030201 |
| string-24.15.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "tcl::string::reverse" \| want: 030201 |

| Skipped by | Tests | Bucket |
|---|---|---|
| testbytestring | 8 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| memory | 6 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testindexobj | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| utf16 | 2 | `design`: ztcl strings hold full code points, as in Tcl 9; Tcl 8.6 uses UTF-16 surrogates |

### stringComp.test

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 1 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### stringObj.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testobj | 75 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### subst.test

| Test | Bucket | Result (start) |
|---|---|---|
| subst-11.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: foo  \| want: extra characters after close-brace |
| subst-11.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: foo  \| want: extra characters after close-brace |

| Skipped by | Tests | Bucket |
|---|---|---|
| testbytestring | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### switch.test

| Test | Bucket | Result (start) |
|---|---|---|
| switch-13.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 - a {can't set "x(x)": variable isn't array} \| want: 1 - - {can't set "x... |
| switch-13.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 - - {can't set "y(y)": variable isn't array} \| want: 1 {{0 0}} - {can't ... |
| switch-4.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {Just a test} {Just a test     while executing "error "Just a test""     ... |
| switch-4.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 switch2 {switch2     while executing "error switch2"     invoked from wit... |

### tailcall.test

| Test | Bucket | Result (start) |
|---|---|---|
| tailcall-1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1::b \| 0:: *::a *::b \| {{1 ::b::moo} {2 ::a::xset}} \| want: 1::b \| 0:: ... |
| tailcall-11c | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: {0 2 3} {0 2 3} \| want: {0 3 2} {0 3 2} |
| tailcall-12.2 | `bug`: the result differs from tclsh 8.6.16 | output: 1: fred alpha 1: inside foo's alpha, v resolves to global level 1: foo's alpha ... |
| tailcall-12.3a0 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: 2 \| want: invalid command name "foo" |
| tailcall-12.3a1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: wrong # args: should be "tailcall command ?arg ...?" \| want:  |
| tailcall-12.3b0 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: 2 \| want: invalid command name "foo" |
| tailcall-12.3b1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: wrong # args: should be "tailcall command ?arg ...?" \| want:  |
| tailcall-14.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "p" \| want: namespace "::ns" not found |
| tailcall-14.1-bc | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "p" \| want: namespace "::ns" not found |

| Skipped by | Tests | Bucket |
|---|---|---|
| testnrelevels | 8 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### tcltest.test

| Test | Bucket | Result (start) |
|---|---|---|
| tcltest-1.1 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 0/0,2: 1 0 \| want: 1 1 |
| tcltest-1.2 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 0/0,2: 1 0 \| want: 1 1 |
| tcltest-2.0 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: invalid command name "i" \| want: 0 1 0 0 1 |
| tcltest-2.1 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-2.2 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-2.3 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-2.4 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-2.5 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-2.5a | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-2.6 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-2.6a | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-2.7 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 0/0,2: {} {} \| want: body {} |
| tcltest-2.8 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-3.1 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-3.2 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-3.3 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-3.4 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-3.5 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: invalid command name "match" \| want: foo bar |
| tcltest-4.1 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-4.2 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-4.3 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-4.4 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-4.5 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-4.6 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: invalid command name "skip" \| want: foo bar |
| tcltest-5.1 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-5.2 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-5.3 | `feature`: the real 'tcltest' package; the suite runs a stand-in | cleanup: can't unset "::tcltest::testConstraints(tcltestFakeConstraint)": no such variable |
| tcltest-6.1 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-6.2 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-6.3 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-6.4 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 1/0,2: interpreter named "::tcltest::test::i" already exists, cannot create \| wan... |
| tcltest-6.5 | `feature`: the real 'tcltest' package; the suite runs a stand-in | setup: invalid command name "errorChannel" |
| tcltest-6.6 | `feature`: the real 'tcltest' package; the suite runs a stand-in | setup: invalid command name "errorFile" |
| tcltest-6.7 | `feature`: the real 'tcltest' package; the suite runs a stand-in | setup: invalid command name "outputChannel" |
| tcltest-6.8 | `feature`: the real 'tcltest' package; the suite runs a stand-in | setup: invalid command name "outputFile" |
| tcltest-7.2 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 0/0,2: 0 0 \| want: 1 0 |
| tcltest-7.3 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 0/0,2: 0 0 \| want: 1 0 |
| tcltest-7.4 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 0/0,2: 0 0 \| want: 1 0 |
| tcltest-7.5 | `feature`: the real 'tcltest' package; the suite runs a stand-in | code 0/0,2: 0 0 \| want: 1 1 |
| tcltest-7.6 | `feature`: the real 'tcltest' package; the suite runs a stand-in | setup: can't read "::tcltest::debug": no such variable |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 116 | `feature`: the real 'tcltest' package; the suite runs a stand-in |
| expr:!singleTestInterp notWsl | 1 | `feature`: the real 'tcltest' package; the suite runs a stand-in |

### thread.test

| Skipped by | Tests | Bucket |
|---|---|---|
| drainEventQueue | 34 | `internals`: a C test command or package of the Tcl test binary |

### timer.test

| Test | Bucket | Result (start) |
|---|---|---|
| timer-10.1 | `bug`: the setup or the cleanup of the test fails | setup: import pattern "::after" tries to import from namespace "foo" into itself |

### tm.test

| Test | Bucket | Result (start) |
|---|---|---|
| tm-1.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: ::tcl::tm::path |
| tm-1.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "::tcl::tm::path" \| want: unknown or ambiguous subcomma... |
| tm-1.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::tm::path" \| want:  |
| tm-1.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/0,2: invalid command name "::tcl::tm::path" \| want:  |
| tm-1.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "::tcl::tm::path" \| want: wrong # args: should be "::tc... |
| tm-2.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: ::tcl::tm::roots |
| tm-2.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "::tcl::tm::roots" \| want: wrong # args: should be "::t... |
| tm-2.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | code 1/1: invalid command name "::tcl::tm::roots" \| want: wrong # args: should be "::t... |
| tm-3.1 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.10 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.11 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.12 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.13 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.2 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.3 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.4 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.5 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.6 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.7 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.8 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |
| tm-3.9 | `feature`: a library package of Tcl: safe, msgcat, http, the package... | setup: invalid command name "::tcl::tm::path" |

### trace.test

| Test | Bucket | Result (start) |
|---|---|---|
| trace-1.11 | `bug`: 'trace': the result differs | code 0/0,2: bar 0 \| want:  |
| trace-1.12 | `bug`: 'trace': the result differs | code 0/0,2: bar 0 \| want:  |
| trace-1.13 | `bug`: 'trace': the result differs | code 0/0,2: 0 {bar 0} \| want: 1 {can't read "x(bar)": no such variable} |
| trace-1.14 | `bug`: 'trace': the result differs | code 0/0,2: 0 {bar 0} \| want: 1 {can't read "x(bar)": no such variable} |
| trace-1.4 | `bug`: 'trace': the result differs | code 0/0,2: 1 {can't read "x(2)": no such variable} {} \| want: 1 {can't read "x(2)": n... |
| trace-12.1 | `bug`: 'trace': the result differs | code 0/0,2: 0 22 \| want: 1 {can't set "x": variable is array} |
| trace-12.2 | `bug`: 'trace': the result differs | code 0/0,2: 1 {can't read "x(0)": no such variable} \| want: 1 {can't read "x(0)": no s... |
| trace-12.8 | `bug`: 'trace': the result differs | code 0/0,2: 0 {} \| want: 1 {can't trace "x(0)": variable isn't array} |
| trace-16.10 | `bug`: 'trace': the result differs | code 0/0,2: 0 {} 1 {can't read "x": no such variable} 1 {can't read "y(0)": no such var... |
| trace-16.13 | `bug`: 'trace': the result differs | code 0/0,2: 0 {} 0 xyzzy 0 xyzzy 0 xyzzy \| want: 0 {} 1 {can't set "y": upvar refers t... |
| trace-16.14 | `bug`: 'trace': the result differs | code 0/0,2: 0 {} 0 xyzzy 0 xyzzy 0 xyzzy \| want: 0 {} 0 xyzzy 0 {} 0 xyzzy |
| trace-16.16 | `bug`: 'trace': the result differs | code 0/0,2: 1 {can't unset "x": no such variable} 1 {can't read "y(0)": no such element... |
| trace-16.19 | `bug`: 'trace': the result differs | code 0/0,2: 1 {can't unset "y(0)": no such variable} 0 xyzzy 0 {} 0 xyzzy \| want: 1 {c... |
| trace-16.2 | `bug`: 'trace': the result differs | code 0/0,2: 0 {} 1 {can't read "y(0)": no such element in array} 1 {can't read "y(0)": ... |
| trace-16.22 | `bug`: 'trace': the result differs | code 0/0,2: third 0 {} 1 {can't read "x": no such variable} 1 {can't read "y(0)": no su... |
| trace-16.6 | `bug`: 'trace': the result differs | code 0/0,2: 0 {} 0 xyzzy 0 xyzzy 0 xyzzy \| want: 0 {} 1 {can't set "y": upvar refers t... |
| trace-16.7 | `bug`: 'trace': the result differs | code 0/0,2: 0 {} 0 xyzzy 0 xyzzy 0 xyzzy \| want: 0 {} 0 xyzzy 1 {can't read "y(0)": no... |
| trace-16.8 | `bug`: 'trace': the result differs | code 0/0,2: unset 0 {} 1 {can't read "x": no such variable} 1 {can't read "y": no such ... |
| trace-16.9 | `bug`: 'trace': the result differs | code 0/0,2: 0 {} 1 {can't read "y(0)": no such element in array} 1 {can't read "y(0)": ... |
| trace-18.1 | `bug`: 'trace': the result differs | code 0/0,2: 0 {} \| want: 0 {a x y} |
| trace-18.4 | `bug`: 'trace': the result differs | code 0/0,2:  \| want: 1110 |
| trace-2.7 | `bug`: 'trace': the result differs | code 0/0,2: errorInfo {} write \| want: ::errorInfo {} write |
| trace-20.10 | `bug`: 'trace': the result differs | code 1/0,2: can't delete "someothername": command doesn't exist \| want: {} {} someothe... |
| trace-20.8 | `bug`: 'trace': the result differs | code 0/0,2: {} {{{rename delete} {traceDelete foo}}} \| want: {::foo ::bar rename} {} |
| trace-20.9 | `bug`: 'trace': the result differs | code 0/0,2: {} bar {} \| want: {} {} {} |
| trace-21.11 | `bug`: 'trace': the result differs | code 0/0,2: ::a ::a \| want: :: :: |
| trace-21.4 | `bug`: 'trace': the result differs | code 0/0,2: {foo {foo 3} enter} {foo {foo 3} 0 3 leave} \| want: {foo {foo 3} enter} {f... |
| trace-21.5 | `bug`: 'trace': the result differs | code 0/0,2: {foo {foo 3} enter} {foo {foo 3} 0 3 leave} \| want: {foo {foo 3} enter} {f... |
| trace-21.6 | `bug`: 'trace': the result differs | code 0/0,2:  \| want: {foo {set b 3} enterstep} {foo {set b 3} 0 3 leavestep} |
| trace-21.7 | `bug`: 'trace': the result differs | code 0/0,2:  \| want: {foo {set b 3} enterstep} |
| trace-21.8 | `bug`: 'trace': the result differs | code 0/0,2:  \| want: {foo {set b 3} 0 3 leavestep} |
| trace-23.1 | `bug`: 'trace': the result differs | code 0/0,2: {factorial 1} enter {factorial 1} 0 1 leave \| want: {factorial 1} enter {i... |
| trace-23.2 | `bug`: 'trace': the result differs | code 0/0,2: {factorial 2} enter {factorial 1} enter {factorial 1} 0 1 leave {factorial ... |
| trace-23.3 | `bug`: 'trace': the result differs | code 0/0,2: {factorial 3} enter {factorial 2} enter {factorial 1} enter {factorial 1} 0... |
| trace-24.3 | `bug`: 'trace': the result differs | code 1/0,2: wrong # args: should be "trace remove execution name opList command" \| wan... |
| trace-24.4 | `bug`: 'trace': the result differs | code 1/0,2: wrong # args: should be "trace remove execution name opList command" \| wan... |
| trace-24.5 | `bug`: 'trace': the result differs | code 0/0,2: {{foo 1} 0 1 leave} 0 {} \| want: {{set b 1} enterstep} 0 {} |
| trace-25.1 | `bug`: 'trace': the result differs | code 0/0,2: 1 {{foo 1} enter} 1 {unknown command "foo"} \| want: {invalid command name ... |
| trace-25.10 | `bug`: 'trace': the result differs | code 0/0,2: 1 {{foo 1} 0 1 leave} 1 {unknown command "foo"} \| want: 1 {{set b 1} 0 1 l... |
| trace-25.11 | `bug`: 'trace': the result differs | code 0/0,2: 1 {{foo 1} enter} 1 {unknown command "foo"} \| want: {invalid command name ... |
| trace-25.3 | `bug`: 'trace': the result differs | code 0/0,2: {can't delete "foo": command doesn't exist} {{foo 1} enter} 1 {unknown comm... |
| trace-25.5 | `bug`: 'trace': the result differs | code 0/0,2: 1   \| want: 1 traceExecute2 {set b 1} enterstep traceExecute {set b 1} ent... |
| trace-25.6 | `bug`: 'trace': the result differs | code 0/0,2: 1 tracePostExecute2 {foo 1} 0 leave tracePostExecute {foo 1} 0 leave  \| wa... |
| trace-25.7 | `bug`: 'trace': the result differs | code 0/0,2: 1   \| want: 1 tracePostExecute {set b 1} 0 leavestep tracePostExecute2 {se... |
| trace-25.8 | `bug`: 'trace': the result differs | code 0/0,2: {can't delete "foo": command doesn't exist} {{foo 1} enter} 1 {unknown comm... |
| trace-25.9 | `bug`: 'trace': the result differs | code 0/0,2: {can't delete "foo": command doesn't exist} {{foo 1} enter} 1 {unknown comm... |
| trace-28.1 | `bug`: 'trace': the result differs | code 0/0,2: foo foo enter foo foo 0 1 leave \| want: foo foo enter foo {set a 1} enters... |
| trace-28.2 | `bug`: 'trace': the result differs | code 0/0,2: {error error} {foo foo enter foo foo 0 error leave} \| want: {error error} ... |
| trace-28.3 | `bug`: 'trace': the result differs | code 0/0,2: {error error} {foo foo enter foo foo 0 error leave} \| want: {error error} ... |
| trace-28.4 | `bug`: 'trace': the result differs | code 0/0,2: {error error} {foo foo enter foo foo 0 error leave} \| want: {error error} ... |
| trace-28.5 | `bug`: 'trace': the result differs | code 0/0,2: foo {foo test-28.4} enter foo {foo test-28.4} 0 1 leave \| want: foo {foo t... |
| trace-28.6 | `bug`: 'trace': the result differs | code 0/0,2:  \| want: enter set b x=42/enterstep leave set b x=42/0/x=42/leavestep ente... |
| trace-34.1 | `bug`: 'trace': the result differs | code 0/0,2: foo \| want: {{lappend ::x foo} enterstep} done foo |
| trace-34.2 | `bug`: 'trace': the result differs | code 1/0,2: invalid command name "soom" \| want:  |
| trace-34.4 | `bug`: 'trace': the result differs | code 0/0,2: notrace \| want: ::foo::bar exists: ::foo::bar |
| trace-34.5 | `bug`: 'trace': the result differs | code 0/0,2: notrace \| want: ::foo::bar exists:  |
| trace-35.1 | `bug`: 'trace': the result differs | code 0/0,2: 1 {can't set "y": can't set "x": foo} {can't set "y": can't set "x": foo   ... |
| trace-37.2 | `bug`: 'trace': the result differs | code 0/0,2: - * \| want: -* * |
| trace-38.2 | `bug`: 'trace': the result differs | code 0/0,2: - * \| want: -* * |
| trace-39.1 | `bug`: 'trace': the result differs | code 1/0,2: unknown command "::tcl::string::equal" \| want: 3 \| 0 1 1 |
| trace-4.4 | `bug`: 'trace': the result differs | code 0/0,2:  \| want: x 1 unset 1 {can't read "x(1)": no such element in array} |
| trace-4.6 | `bug`: 'trace': the result differs | code 0/0,2:  \| want: x 1 unset 1 {can't read "x(1)": no such variable} |
| trace-5.6 | `bug`: 'trace': the result differs | code 0/0,2: x {} array \| want:  |
| trace-6.2 | `bug`: 'trace': the result differs | code 0/0,2: x 0 write x 0 read x 0 write x 0 unset \| want: x 0 read x 0 write x 0 read... |
| trace-7.3 | `bug`: 'trace': the result differs | code 0/0,2: A3 3 A2 2 A1 1 \| want: A3 A2 A1 3 2 1 |
| trace-8.4 | `bug`: 'trace': the result differs | code 0/0,2: 0 {} {} \| want: 0 {} 1 |

| Skipped by | Tests | Bucket |
|---|---|---|
| testcmdtrace | 11 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| memory | 3 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testevalobjv | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| emptyTest | 1 | `tcl`: tclsh skips it too |

### unixFCmd.test

| Test | Bucket | Result (start) |
|---|---|---|
| unixFCmd-1.1 | `feature`: 'file attributes' | cleanup: file attributes is not available |
| unixFCmd-1.2 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "td2" to "td1": target file exists \| want: error renaming "td... |
| unixFCmd-1.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: error renaming "td1" to "td1": invalid argument \| want: error renaming "td1"... |
| unixFCmd-1.7 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: *: permission denied |
| unixFCmd-12.1 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: could not read "foo.test": no such ... |
| unixFCmd-12.2 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: * |
| unixFCmd-13.1 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: could not read "foo.test": no such ... |
| unixFCmd-13.2 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: jcollins |
| unixFCmd-14.1 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: could not read "foo.test": no such ... |
| unixFCmd-14.2 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: * |
| unixFCmd-15.1 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: could not set group for file "foo.t... |
| unixFCmd-15.2 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: could not set group for file "foo.t... |
| unixFCmd-16.1 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: {} jcollins |
| unixFCmd-16.2 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: could not set owner for file "foo.t... |
| unixFCmd-16.3 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: could not set owner for file "foo.t... |
| unixFCmd-17.1 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: {} 0o000 |
| unixFCmd-17.11 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: 0o111 |
| unixFCmd-17.12 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: 0o000 0o777 |
| unixFCmd-17.2 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: could not set permissions for file ... |
| unixFCmd-17.3 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: unknown permission string format "foo" |
| unixFCmd-17.4 | `feature`: 'file attributes' | code 1/1: file attributes is not available \| want: unknown permission string format "-... |
| unixFCmd-17.5 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: 0o777 |
| unixFCmd-17.6 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: 0o442 |
| unixFCmd-17.7 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: 0o000 0o740 0o540 0o547 |
| unixFCmd-2.2.2 | `design`: 'file link' is outside the root folder model of the file ... | code 1/0,2: could not link: links are not available in the root folder \| want: link |
| unixFCmd-2.3 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: could not read "/dev/null": no such file or directory \| want:  |
| unixFCmd-2.4 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: error copying "tf1": permission denied \| want: fifo fifo |
| unixFCmd-2.5 | `feature`: 'file attributes' | code 1/0,2: file attributes is not available \| want: 0o472 |

| Skipped by | Tests | Bucket |
|---|---|---|
| emptyTest | 11 | `tcl`: tclsh skips it too |
| readonlyAttr | 4 | `platform`: a property of the host: a second device, a writable home, IPv6 on localhost, ... |
| nonPortable | 3 | `tcl`: tclsh skips it too |
| dontCopyLinks | 1 | `design`: 'file link' is outside the root folder model of the file capability |

### unixFile.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testfindexecutable | 7 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### unixForkEvent.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testfork | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### unixInit.test

| Test | Bucket | Result (start) |
|---|---|---|
| unixInit-1.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: Expected: '127.0.0.1 localhost 38441', Got '' \| want: OK |
| unixInit-3.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 \| want: 0 |
| unixInit-7.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0: couldn't open "/dev/null": no such file or directory \| want:  |

| Skipped by | Tests | Bucket |
|---|---|---|
| emptyTest | 2 | `tcl`: tclsh skips it too |

### unixNotfy.test

| Skipped by | Tests | Bucket |
|---|---|---|
| unthreaded | 2 | `tcl`: the test file sets the constraint false, or it is false in tclsh 8.6 on Linux |

### unload.test

| Test | Bucket | Result (start) |
|---|---|---|
| unload-1.1 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "unload" \| want: wrong # args: should be "unload ?-swit... |
| unload-1.2 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "unload" \| want: wrong # args: should be "unload ?-swit... |
| unload-1.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "unload" \| want: could not find interpreter "foobar" |
| unload-1.4 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "unload" \| want: must specify either file name or packa... |
| unload-1.5 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "unload" \| want: must specify either file name or packa... |
| unload-1.6 | `message`: an error where tclsh also gives one, with another message | code 1/1: invalid command name "unload" \| want: package "Unknown" is loaded statically... |
| unload-1.7 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "unload" \| want:  |

| Skipped by | Tests | Bucket |
|---|---|---|
| pkgua.soRequired | 20 | `internals`: a C test command or package of the Tcl test binary |

### uplevel.test

| Test | Bucket | Result (start) |
|---|---|---|
| uplevel-4.0.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: 222 \| want: bad level "1" |
| uplevel-4.0.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: 222 \| want: bad level "1" |
| uplevel-4.17 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "-0xffffffff" \| want:  |
| uplevel-4.18 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: bad level "#-0xffffffff" \| want:  |
| uplevel-4.19 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "-4294967295" \| want:  |
| uplevel-4.20 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: bad level "#-4294967295" \| want:  |
| uplevel-4.9 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "-0" \| want:  |
| uplevel-8.0 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: invalid command name "::tcl::unsupported::representation" \| want: 5 1 |

### upvar.test

| Test | Bucket | Result (start) |
|---|---|---|
| upvar-10.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| upvar-5.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: {x1 {} unset} {} \| want: {x1 {} unset} x1 |
| upvar-8.11 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: * |
| upvar-8.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: can't upvar from variable to itself |
| upvar-8.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: can't upvar from variable to itself |
| upvar-8.7 | `message`: an error where tclsh also gives one, with another message | code 1/1: variable "a" already exists \| want: variable "a" has traces: can't use for u... |
| upvar-8.8 | `bug`: the setup or the cleanup of the test fails | cleanup: can't unset "x": no such variable |
| upvar-8.9 | `message`: an error where tclsh also gives one, with another message | code 1/1: can't unset "::test_ns_1::a": no such variable \| want: bad variable name "a"... |
| upvar-NS-1.3 | `message`: an error where tclsh also gives one, with another message | code 1/1: can't read "w": no such variable \| want: namespace "test_ns_0" not found in ... |
| upvar-NS-1.4 | `message`: an error where tclsh also gives one, with another message | code 1/1: can't read "w": no such variable \| want: namespace "test_ns_0" not found in ... |
| upvar-NS-1.9 | `message`: an error where tclsh also gives one, with another message | code 1/1: can't read "w": no such variable \| want: namespace "test_ns_0" not found in ... |
| upvar-NS-3.1 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| upvar-NS-3.2 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| upvar-NS-3.3 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testupvar | 8 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### utf.test

| Test | Bucket | Result (start) |
|---|---|---|
| utf-10.45 | `bug`: encodings: the result differs | code 0/0,2: 225 \| want: 60 |
| utf-10.56 | `bug`: encodings: the result differs | code 0/0,2: 65533 \| want: 69632 |
| utf-10.57 | `bug`: encodings: the result differs | code 0/0,2: 65533 \| want: 69632 |
| utf-10.58 | `bug`: encodings: the result differs | code 0/0,2: 65533 \| want: 69632 |
| utf-10.60 | `bug`: encodings: the result differs | code 0/0,2: 65533 \| want: 1114111 |
| utf-10.61 | `bug`: encodings: the result differs | code 0/0,2: 65533 \| want: 1114111 |
| utf-10.62 | `bug`: encodings: the result differs | code 0/0,2: 65533 \| want: 1048575 |
| utf-11.4 | `bug`: encodings: the result differs | code 0/0,2: ǣGH \| want: ǢGH |
| utf-11.5 | `bug`: encodings: the result differs | code 0/0,2: აᲐ \| want: ᲐᲐ |
| utf-12.4 | `bug`: encodings: the result differs | code 0/0,2: Ǣgh \| want: ǣgh |
| utf-12.5 | `bug`: encodings: the result differs | code 0/0,2: აᲐ \| want: აა |
| utf-16.2 | `bug`: encodings: the result differs | code 0/0,2: ÿÿꞍǆ \| want: ÿÿɥǆ |
| utf-18.3 | `bug`: encodings: the result differs | code 0/0,2: ſ \| want: S |
| utf-21.11 | `bug`: encodings: the result differs | code 0/0,2: 0 \| want: 1 |
| utf-21.12 | `bug`: encodings: the result differs | code 0/0,2: 0 \| want: 1 |
| utf-21.2 | `bug`: encodings: the result differs | code 0/0,2: 1 0 \| want: 1 1 |
| utf-24.1 | `bug`: encodings: the result differs | code 0/0,2: 0 \| want: 1 |
| utf-24.2 | `bug`: encodings: the result differs | code 0/0,2: 0 0 \| want: 1 1 |

| Skipped by | Tests | Bucket |
|---|---|---|
| testutfnext | 152 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testutfprev | 103 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testbytestring | 26 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| ucs2 | 17 | `platform`: a constraint of another platform or word size |
| testnumutfchars | 15 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| utf16 | 15 | `design`: ztcl strings hold full code points, as in Tcl 9; Tcl 8.6 uses UTF-16 surrogates |
| testgetunichar | 12 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| teststringobj | 9 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| pre388 | 2 | `tcl`: the test file sets the constraint false, or it is false in tclsh 8.6 on Linux |
| pairsTo4bytes | 1 | `internals`: a C test command or package of the Tcl test binary |
| testfindfirst | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testfindlast | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### util.test

| Test | Bucket | Result (start) |
|---|---|---|
| util-14.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: NaN \| want: -NaN |
| util-14.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: NaN \| want: -NaN(3456789abcdef) |
| util-17.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0x43fffffffffffffc -3c00000000000004 0x43fffffffffffffc -3c00000000000004 0... |
| util-3.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: #\ \\\{\ \\ 1 \| want: \#\ \\\{\ \\ 1 |
| util-3.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: #\{ # a \| want: \#\{ # a |
| util-3.5.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2:  \| want: # |
| util-3.6 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: target interpreter for alias "x" in path "" is not my descendant \| want:  |
| util-4.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: a b\ c \| want: a b\  c |
| util-4.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: a b\ c \| want: a b\  c |
| util-4.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: a b\\ c \| want: a b\\  c |
| util-5.40 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 \| want: 0 |
| util-5.41 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| util-5.43 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| util-5.44 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 \| want: 1 |
| util-7.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 12 \| want: 12 6 |
| util-7.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: {0 8} 12 \| want: {1 {can't set "tcl_precision": can't modify precision fro... |
| util-8.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: target interpreter for alias "fooset" in path "" is not my descendant \| wa... |
| util-9.2.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: d \| want: * |
| util-9.2.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: d \| want: * |
| util-9.32 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: * |
| util-9.33 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: * |
| util-9.44 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: * |
| util-9.5.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: c \| want: * |

| Skipped by | Tests | Bucket |
|---|---|---|
| testdoubledigits | 126 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testdstring | 10 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testprint | 6 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testbytestring | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testconcatobj | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### var.test

| Test | Bucket | Result (start) |
|---|---|---|
| var-1.11 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: 314159 \| want: can't set "::test_ns_var::foo::bar": parent namespace doesn't... |
| var-1.12 | `bug`: the result differs from tclsh 8.6.16 | code 0/1: 1997 \| want: can't set "::test_ns_var::foo::": parent namespace doesn't exist |
| var-1.15 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 2 0 3 1 {can't set "foo(3)": variable isn't array} \| want: 0 2 1 {can't ... |
| var-1.16 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: can't read "result": no such variable \| want: 0 2 1 {can't set "foo": upva... |
| var-1.17 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: can't read "result": no such variable \| want: 0 2 1 {can't set "foo": upva... |
| var-1.18 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: can't read "result": no such variable \| want: 0 2 1 {can't set "foo": upva... |
| var-10.1 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: can't set "arr(x)": variable isn't array |
| var-10.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: can't set "arr(x)": variable isn't array |
| var-11.1 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: bad option "-dict": must be -ascii, -command, -decreasing, -dictionary, -in... |
| var-20.10 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: * |
| var-21.0 | `feature`: 'info frame' | code 1/0,2: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, comm... |
| var-3.10 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 0 1 \| want: 1 1 |
| var-3.11 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: bad variable name "foo(bar)": can't create a scalar variable that l... |
| var-3.9 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: can't create "test_ns_fred::lnk": parent namespace doesn't exist |
| var-7.14 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: can't define "arrayvar(1)": name refers to an element in an array |
| var-7.15 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: can't define "arrayvar(1)": name refers to an element in an array |
| var-7.16 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: wrong # args: should be "variable ?name value...? name ?value?" \| want:  |
| var-7.17 | `bug`: the result differs from tclsh 8.6.16 | code 1/0,2: wrong # args: should be "variable ?name value...? name ?value?" \| want:  |
| var-7.7 | `bug`: the result differs from tclsh 8.6.16 | code 0/1:  \| want: can't define "sev:::en": parent namespace doesn't exist |
| var-7.9 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: ::test_ns_var2::x 1 0 0 {1 {can't read "test_ns_var2::y": no such variable}... |
| var-8.2 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: {} {} \| want: {} {::test_ns_var::v {} unset} |

| Skipped by | Tests | Bucket |
|---|---|---|
| testsetnoerr | 12 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| memory | 3 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testgetvarfullname | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testupvar | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### while-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| while-old-4.6 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 1 {loop aborted} {loop aborted     while executing "error "loop aborted""  ... |

### while.test

| Test | Bucket | Result (start) |
|---|---|---|
| while-4.9 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: wrong # args: should be "set varName ?newValue?"     while executing "set" ... |

### winConsole.test

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 1 | `platform`: a constraint of another platform or word size |

### winDde.test

| Skipped by | Tests | Bucket |
|---|---|---|
| dde | 49 | `platform`: Windows only |
| win | 1 | `platform`: a constraint of another platform or word size |

### winFCmd.test

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 170 | `platform`: a constraint of another platform or word size |
| nt | 4 | `platform`: a constraint of another platform or word size |
| winVista | 3 | `platform`: Windows only |
| nonPortable | 1 | `tcl`: tclsh skips it too |

### winFile.test

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 11 | `platform`: a constraint of another platform or word size |

### winNotify.test

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 14 | `platform`: a constraint of another platform or word size |

### winPipe.test

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 56 | `platform`: a constraint of another platform or word size |

### winTime.test

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 2 | `platform`: a constraint of another platform or word size |
| testwinclock | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### word.test

| Test | Bucket | Result (start) |
|---|---|---|
| word-1.3 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 5 \| want: -1 |
| word-1.4 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 5 \| want: -1 |
| word-1.5 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 5 \| want: -1 |
| word-1.7 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 5 \| want: -1 |
| word-1.8 | `bug`: the result differs from tclsh 8.6.16 | code 0/0,2: 5 \| want: -1 |

### zlib.test

| Test | Bucket | Result (start) |
|---|---|---|
| zlib-15.1 | `bug`: the setup or the cleanup of the test fails | setup: invalid command name "zlib" |

| Skipped by | Tests | Bucket |
|---|---|---|
| zlib | 71 | `feature`: the 'zlib' command |
| knownBug | 1 | `tcl`: tclsh skips it too |
