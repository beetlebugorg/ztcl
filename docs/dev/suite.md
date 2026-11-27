# Tcl 8.6.16 suite results

`tools/suite-run.sh` makes this page with `tools/suite-md.py`. Do not edit it by hand. Run on 2026-11-26 at commit `9c7e820`, with the suite runner `zig-out/bin/ztcl-suite` (ReleaseSafe) on all 152 test files. `docs/dev/suite-tests.tsv` has one line for each test.

A test is applicable when it is outside the buckets `design`, `platform`, `internals`, and `tcl`. The goal of issue 244 is a pass for each applicable test.

## Totals

| Run | Total | Pass | Fail | Skip | Unreached |
|---|---|---|---|---|---|
| Interpreter | 46,494 | 37,416 | 3,041 | 3,780 | 2,257 |
| JIT (`-j`) | 46,494 | 37,416 | 3,041 | 3,780 | 2,257 |

Unreached is the test count of `tools/suite-scope.tsv` minus the tests that ran: the file stopped before them.

## Buckets

The tests of the interpreter run that do not pass, by bucket.

| Bucket | Meaning | Tests |
|---|---|---|
| `bug` | A bug in ztcl | 0 |
| `feature` | A missing feature or option | 71 |
| `message` | An error message or -errorcode differs | 0 |
| `internals` | Needs Tcl internals (C test commands, memory debugging) | 2,478 |
| `design` | Absent by design | 0 |
| `platform` | Platform only | 661 |
| `tcl` | Skipped by tclsh too (knownBug, emptyTest, and others) | 139 |
| `untriaged` | Not triaged yet | 5,729 |

Applicable tests: 43,216. Pass rate of the applicable tests: 86.6 %.

## JIT differences

Each test has the same result in the two runs.

## Files

| File | Scope | Total | Pass | Fail | Skip | Unreached | JIT pass | JIT fail | JIT skip |
|---|---|---|---|---|---|---|---|---|---|
| aaa_exit.test | decide | 2 | 2 | 0 | 0 | 0 | 2 | 0 | 0 |
| append.test | in | 45 | 42 | 3 | 0 | 0 | 42 | 3 | 0 |
| appendComp.test | in | 48 | 40 | 3 | 5 | 0 | 40 | 3 | 5 |
| apply.test | in | 42 | 33 | 5 | 4 | 0 | 33 | 5 | 4 |
| assemble.test | na | 284 | 0 | 280 | 4 | 0 | 0 | 280 | 4 |
| assocd.test | na | 11 | 0 | 0 | 11 | 0 | 0 | 0 | 11 |
| async.test | na | 12 | 0 | 0 | 12 | 0 | 0 | 0 | 12 |
| autoMkindex.test | decide | 11 | 1 | 9 | 1 | 0 | 1 | 9 | 1 |
| basic.test | in | 146 | 100 | 12 | 34 | 0 | 100 | 12 | 34 |
| binary.test | in | 717 | 602 | 36 | 79 | 0 | 602 | 36 | 79 |
| case.test | in | 15 | 15 | 0 | 0 | 0 | 15 | 0 | 0 |
| chan.test | decide | 41 | 14 | 27 | 0 | 0 | 14 | 27 | 0 |
| chanio.test | decide | 471 | 229 | 130 | 83 | 29 | 229 | 130 | 83 |
| clock.test | decide | 8,532 | 8,390 | 132 | 7 | 3 | 8,390 | 132 | 7 |
| cmdAH.test | decide | 323 | 91 | 54 | 178 | 0 | 91 | 54 | 178 |
| cmdIL.test | in | 146 | 128 | 12 | 6 | 0 | 128 | 12 | 6 |
| cmdInfo.test | na | 12 | 0 | 0 | 12 | 0 | 0 | 0 | 12 |
| cmdMZ.test | in | 92 | 82 | 9 | 1 | 0 | 82 | 9 | 1 |
| compExpr-old.test | in | 190 | 183 | 0 | 7 | 0 | 183 | 0 | 7 |
| compExpr.test | in | 80 | 76 | 0 | 4 | 0 | 76 | 0 | 4 |
| compile.test | in | 171 | 96 | 64 | 11 | 0 | 96 | 64 | 11 |
| concat.test | in | 9 | 9 | 0 | 0 | 0 | 9 | 0 | 0 |
| config.test | decide | 9 | 0 | 9 | 0 | 0 | 0 | 9 | 0 |
| coroutine.test | in | 59 | 37 | 19 | 3 | 0 | 37 | 19 | 3 |
| dcall.test | na | 6 | 0 | 0 | 6 | 0 | 0 | 0 | 6 |
| dict.test | in | 342 | 311 | 29 | 2 | 0 | 311 | 29 | 2 |
| dstring.test | na | 44 | 0 | 0 | 44 | 0 | 0 | 0 | 44 |
| encoding.test | decide | 86 | 11 | 40 | 12 | 23 | 11 | 40 | 12 |
| env.test | decide | 26 | 8 | 14 | 4 | 0 | 8 | 14 | 4 |
| error.test | in | 317 | 300 | 9 | 8 | 0 | 300 | 9 | 8 |
| eval.test | in | 12 | 11 | 1 | 0 | 0 | 11 | 1 | 0 |
| event.test | decide | 66 | 35 | 2 | 29 | 0 | 35 | 2 | 29 |
| exec.test | decide | 100 | 87 | 4 | 9 | 0 | 87 | 4 | 9 |
| execute.test | in | 157 | 71 | 6 | 80 | 0 | 71 | 6 | 80 |
| expr-old.test | in | 460 | 432 | 12 | 16 | 0 | 432 | 12 | 16 |
| expr.test | in | 14,185 | 14,124 | 27 | 34 | 0 | 14,124 | 27 | 34 |
| fCmd.test | decide | 256 | 124 | 83 | 48 | 1 | 124 | 83 | 48 |
| fileName.test | decide | 300 | 50 | 69 | 176 | 5 | 50 | 69 | 176 |
| fileSystem.test | decide | 137 | 37 | 41 | 59 | 0 | 37 | 41 | 59 |
| fileSystemEncoding.test | decide | 1 | 0 | 1 | 0 | 0 | 0 | 1 | 0 |
| for-old.test | in | 9 | 9 | 0 | 0 | 0 | 9 | 0 | 0 |
| for.test | in | 88 | 61 | 3 | 24 | 0 | 61 | 3 | 24 |
| foreach.test | in | 43 | 41 | 2 | 0 | 0 | 41 | 2 | 0 |
| format.test | in | 266 | 255 | 2 | 9 | 0 | 255 | 2 | 9 |
| get.test | in | 22 | 5 | 1 | 16 | 0 | 5 | 1 | 16 |
| history.test | decide | 62 | 0 | 0 | 62 | 0 | 0 | 0 | 62 |
| http.test | decide | 75 | 2 | 62 | 11 | 0 | 2 | 62 | 11 |
| http11.test | decide | 43 | 0 | 42 | 1 | 0 | 0 | 42 | 1 |
| httpPipeline.test | decide | 1,996 | 0 | 0 | 0 | 1,996 | 0 | 0 | 0 |
| httpold.test | decide | 32 | 3 | 28 | 0 | 1 | 3 | 28 | 0 |
| if-old.test | in | 33 | 33 | 0 | 0 | 0 | 33 | 0 | 0 |
| if.test | in | 73 | 73 | 0 | 0 | 0 | 73 | 0 | 0 |
| incr-old.test | in | 14 | 12 | 2 | 0 | 0 | 12 | 2 | 0 |
| incr.test | in | 66 | 62 | 4 | 0 | 0 | 62 | 4 | 0 |
| indexObj.test | na | 45 | 0 | 0 | 45 | 0 | 0 | 0 | 45 |
| info.test | in | 266 | 97 | 166 | 3 | 0 | 97 | 166 | 3 |
| init.test | decide | 24 | 0 | 10 | 0 | 14 | 0 | 10 | 0 |
| interp.test | decide | 352 | 198 | 141 | 13 | 0 | 198 | 141 | 13 |
| io.test | decide | 524 | 239 | 144 | 83 | 58 | 239 | 144 | 83 |
| ioCmd.test | decide | 348 | 78 | 168 | 102 | 0 | 78 | 168 | 102 |
| ioTrans.test | decide | 106 | 2 | 67 | 37 | 0 | 2 | 67 | 37 |
| iogt.test | decide | 17 | 0 | 0 | 17 | 0 | 0 | 0 | 17 |
| join.test | in | 10 | 10 | 0 | 0 | 0 | 10 | 0 | 0 |
| lindex.test | in | 83 | 80 | 3 | 0 | 0 | 80 | 3 | 0 |
| link.test | na | 29 | 0 | 0 | 29 | 0 | 0 | 0 | 29 |
| linsert.test | in | 28 | 28 | 0 | 0 | 0 | 28 | 0 | 0 |
| list.test | in | 78 | 77 | 1 | 0 | 0 | 77 | 1 | 0 |
| listObj.test | in | 47 | 42 | 0 | 5 | 0 | 42 | 0 | 5 |
| llength.test | in | 6 | 6 | 0 | 0 | 0 | 6 | 0 | 0 |
| lmap.test | in | 66 | 62 | 4 | 0 | 0 | 62 | 4 | 0 |
| load.test | decide | 30 | 0 | 8 | 22 | 0 | 0 | 8 | 22 |
| lrange.test | in | 34 | 32 | 0 | 2 | 0 | 32 | 0 | 2 |
| lrepeat.test | in | 12 | 5 | 7 | 0 | 0 | 5 | 7 | 0 |
| lreplace.test | in | 1,787 | 1,787 | 0 | 0 | 0 | 1,787 | 0 | 0 |
| lsearch.test | in | 118 | 111 | 7 | 0 | 0 | 111 | 7 | 0 |
| lset.test | in | 89 | 83 | 5 | 1 | 0 | 83 | 5 | 1 |
| lsetComp.test | in | 19 | 19 | 0 | 0 | 0 | 19 | 0 | 0 |
| macOSXFCmd.test | na | 14 | 0 | 0 | 14 | 0 | 0 | 0 | 14 |
| macOSXLoad.test | na | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| main.test | decide | 67 | 12 | 19 | 36 | 0 | 12 | 19 | 36 |
| mathop.test | in | 349 | 347 | 2 | 0 | 0 | 347 | 2 | 0 |
| misc.test | in | 301 | 1 | 1 | 299 | 0 | 1 | 1 | 299 |
| msgcat.test | decide | 109 | 3 | 100 | 0 | 6 | 3 | 100 | 0 |
| namespace-old.test | in | 126 | 114 | 12 | 0 | 0 | 114 | 12 | 0 |
| namespace.test | in | 313 | 235 | 75 | 3 | 0 | 235 | 75 | 3 |
| notify.test | na | 23 | 0 | 0 | 23 | 0 | 0 | 0 | 23 |
| nre.test | in | 28 | 4 | 1 | 23 | 0 | 4 | 1 | 23 |
| obj.test | na | 92 | 3 | 0 | 89 | 0 | 3 | 0 | 89 |
| oo.test | in | 306 | 214 | 74 | 17 | 1 | 214 | 74 | 17 |
| ooNext2.test | in | 62 | 50 | 7 | 5 | 0 | 50 | 7 | 5 |
| opt.test | decide | 31 | 0 | 30 | 0 | 1 | 0 | 30 | 0 |
| package.test | decide | 402 | 352 | 50 | 0 | 0 | 352 | 50 | 0 |
| parse.test | in | 271 | 114 | 5 | 152 | 0 | 114 | 5 | 152 |
| parseExpr.test | in | 284 | 13 | 54 | 217 | 0 | 13 | 54 | 217 |
| parseOld.test | in | 158 | 154 | 1 | 3 | 0 | 154 | 1 | 3 |
| pid.test | decide | 5 | 5 | 0 | 0 | 0 | 5 | 0 | 0 |
| pkgMkIndex.test | decide | 27 | 0 | 25 | 2 | 0 | 0 | 25 | 2 |
| platform.test | decide | 6 | 1 | 2 | 1 | 2 | 1 | 2 | 1 |
| proc-old.test | in | 74 | 64 | 10 | 0 | 0 | 64 | 10 | 0 |
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
| safe.test | decide | 102 | 1 | 92 | 8 | 1 | 1 | 92 | 8 |
| scan.test | in | 181 | 162 | 18 | 1 | 0 | 162 | 18 | 1 |
| security.test | decide | 1 | 1 | 0 | 0 | 0 | 1 | 0 | 0 |
| set-old.test | in | 153 | 142 | 11 | 0 | 0 | 142 | 11 | 0 |
| set.test | in | 64 | 61 | 2 | 1 | 0 | 61 | 2 | 1 |
| socket.test | decide | 175 | 157 | 7 | 11 | 0 | 157 | 7 | 11 |
| source.test | decide | 23 | 13 | 10 | 0 | 0 | 13 | 10 | 0 |
| split.test | in | 17 | 16 | 1 | 0 | 0 | 16 | 1 | 0 |
| stack.test | decide | 3 | 1 | 2 | 0 | 0 | 1 | 2 | 0 |
| string.test | in | 1,266 | 1,240 | 8 | 18 | 0 | 1,240 | 8 | 18 |
| stringComp.test | in | 279 | 278 | 0 | 1 | 0 | 278 | 0 | 1 |
| stringObj.test | na | 75 | 0 | 0 | 75 | 0 | 0 | 0 | 75 |
| subst.test | in | 63 | 60 | 2 | 1 | 0 | 60 | 2 | 1 |
| switch.test | in | 113 | 106 | 7 | 0 | 0 | 106 | 7 | 0 |
| tailcall.test | in | 37 | 20 | 9 | 8 | 0 | 20 | 9 | 8 |
| tcltest.test | decide | 159 | 2 | 40 | 1 | 116 | 2 | 40 | 1 |
| thread.test | decide | 52 | 18 | 0 | 34 | 0 | 18 | 0 | 34 |
| timer.test | decide | 54 | 53 | 1 | 0 | 0 | 53 | 1 | 0 |
| tm.test | decide | 21 | 0 | 21 | 0 | 0 | 0 | 21 | 0 |
| trace.test | in | 295 | 212 | 66 | 17 | 0 | 212 | 66 | 17 |
| unixFCmd.test | decide | 49 | 2 | 28 | 19 | 0 | 2 | 28 | 19 |
| unixFile.test | decide | 7 | 0 | 0 | 7 | 0 | 0 | 0 | 7 |
| unixForkEvent.test | na | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 1 |
| unixInit.test | decide | 8 | 2 | 4 | 2 | 0 | 2 | 4 | 2 |
| unixNotfy.test | decide | 4 | 2 | 0 | 2 | 0 | 2 | 0 | 2 |
| unknown.test | in | 7 | 7 | 0 | 0 | 0 | 7 | 0 | 0 |
| unload.test | decide | 27 | 0 | 7 | 20 | 0 | 0 | 7 | 20 |
| uplevel.test | in | 57 | 49 | 8 | 0 | 0 | 49 | 8 | 0 |
| upvar.test | in | 65 | 43 | 14 | 8 | 0 | 43 | 14 | 8 |
| utf.test | in | 498 | 123 | 21 | 354 | 0 | 123 | 21 | 354 |
| util.test | in | 2,291 | 2,124 | 23 | 144 | 0 | 2,124 | 23 | 144 |
| var.test | in | 110 | 66 | 24 | 20 | 0 | 66 | 24 | 20 |
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
| append-10.1 | `untriaged` | code 0: {#} 1 2 3 |
| append-10.3 | `untriaged` | code 0: {#} 1 2 3 |
| append-9.0 | `untriaged` | code 0: 1 {can't read "myvar(key)": no such variable} |

### appendComp.test

| Test | Bucket | Result (start) |
|---|---|---|
| appendComp-10.1 | `untriaged` | code 0: {#} 1 2 3 |
| appendComp-10.3 | `untriaged` | code 0: {#} 1 2 3 |
| appendComp-9.0 | `untriaged` | code 0: 1 {can't read "::myvar(key)": BOOM. no such variable} |

| Skipped by | Tests | Bucket |
|---|---|---|
| expr:bug-3057639 | 5 | `untriaged` |

### apply.test

| Test | Bucket | Result (start) |
|---|---|---|
| apply-3.3 | `untriaged` | code 1: namespace "NONEXIST::FOR::SURE" not found |
| apply-3.4 | `untriaged` | code 1: namespace "NONEXIST::FOR::SURE" not found |
| apply-4.3 | `untriaged` | code 1: wrong # args: should be "::apply lambdaExpr x" |
| apply-4.4 | `untriaged` | code 1: wrong # args: should be "::apply lambdaExpr x" |
| apply-4.5 | `untriaged` | code 1: wrong # args: should be "::apply lambdaExpr self x" |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 3 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| applylambda | 1 | `untriaged` |

### assemble.test

| Test | Bucket | Result (start) |
|---|---|---|
| assemble-1.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-1.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-1.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-1.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-10.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-10.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-10.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-10.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-10.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-10.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-10.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-11.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-11.10 | `untriaged` | code 1: invalid command name "-body" |
| assemble-11.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-11.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-11.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-11.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-11.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-11.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-11.8 | `untriaged` | code 1: invalid command name "-body" |
| assemble-11.9 | `untriaged` | code 1: invalid command name "-body" |
| assemble-12.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-12.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-12.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-12.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-12.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-12.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-13.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-13.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-13.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-13.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-13.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-13.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-13.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-13.8 | `untriaged` | code 1: invalid command name "-body" |
| assemble-13.9 | `untriaged` | code 1: invalid command name "-body" |
| assemble-14.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-14.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-14.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-14.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-14.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-14.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-14.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-15.1 | `untriaged` | code 1: invalid command name "assemble" |
| assemble-15.2 | `untriaged` | code 1: invalid command name "assemble" |
| assemble-15.3 | `untriaged` | code 0: 1 {invalid command name "assemble"} {TCL LOOKUP COMMAND assemble} |
| assemble-15.4 | `untriaged` | code 1: invalid command name "assemble" |
| assemble-15.5 | `untriaged` | code 1: invalid command name "assemble" |
| assemble-15.6 | `untriaged` | code 1: invalid command name "assemble" |
| assemble-15.7 | `untriaged` | code 1: invalid command name "assemble" |
| assemble-15.8 | `untriaged` | code 1: invalid command name "assemble" |
| assemble-15.9 | `untriaged` | code 1: invalid command name "assemble" |
| assemble-16.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-16.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-16.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-16.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-16.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-16.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.10 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.11 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.12 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.13 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.14 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.15 | `untriaged` | code 1: invalid command name "-setup" |
| assemble-17.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.8 | `untriaged` | code 1: invalid command name "-body" |
| assemble-17.9 | `untriaged` | code 1: invalid command name "-body" |
| assemble-18.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-18.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-18.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-18.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-18.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-18.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-18.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-18.8 | `untriaged` | code 1: invalid command name "-body" |
| assemble-19.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-19.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-19.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-19.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-19.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-19.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-19.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-19.8 | `untriaged` | code 1: invalid command name "-body" |
| assemble-2.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-2.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-2.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-20.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-20.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-20.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-20.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-20.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-20.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-20.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-21.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-21.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-21.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-21.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-21.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-21.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-21.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-22.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-22.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-22.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-22.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-22.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-22.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-22.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-22.8 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.10 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.11 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.8 | `untriaged` | code 1: invalid command name "-body" |
| assemble-23.9 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.10 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.11 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.12 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.8 | `untriaged` | code 1: invalid command name "-body" |
| assemble-24.9 | `untriaged` | code 1: invalid command name "-body" |
| assemble-25.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-25.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-25.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-25.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-25.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-25.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-26.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-26.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-26.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-26.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-26.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-26.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-26.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-27.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-27.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-27.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-27.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-27.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-27.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-27.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-28.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-28.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-28.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-28.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-28.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-28.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-29.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-29.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-29.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-29.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-29.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-29.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-29.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-3.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-3.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-30.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-30.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-30.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-30.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-30.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-30.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-31.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-31.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-31.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-31.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-31.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-31.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-31.7 | `untriaged` | code 1: invalid command name "-setup" |
| assemble-4.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-4.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-40.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-40.2 | `untriaged` | code 0: 1 {invalid command name "assemble"} {invalid command name "assemble"     while ... |
| assemble-41.1 | `untriaged` | code 0: invalid command name "assemble"     while executing "assemble {   load y   jump... |
| assemble-41.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-41.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-5.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-5.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-5.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-5.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-50.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-52.1 | `untriaged` | code 1: invalid command name "::tcl::unsupported::assemble" |
| assemble-6.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-6.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-6.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-6.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7,34 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.10 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.11 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.12 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.13 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.13a | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.13b | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.14 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.15 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.16 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.17 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.18 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.19 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.20 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.21 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.22 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.23 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.24 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.25 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.26 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.27 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.28 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.29 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.30 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.31 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.32 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.33 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.35 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.36 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.37 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.38 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.39 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.41 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.42 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.43 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.43.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.44 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.45 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.46 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.8 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.9 | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.9a | `untriaged` | code 1: invalid command name "-body" |
| assemble-7.9b | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.10 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.11 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.12 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.13 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.14 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.15 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.16 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.17 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.18 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.19 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.20 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.21 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.7 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.8 | `untriaged` | code 1: invalid command name "-body" |
| assemble-8.9 | `untriaged` | code 1: invalid command name "-body" |
| assemble-9.1 | `untriaged` | code 1: invalid command name "-body" |
| assemble-9.2 | `untriaged` | code 1: invalid command name "-body" |
| assemble-9.3 | `untriaged` | code 1: invalid command name "-body" |
| assemble-9.4 | `untriaged` | code 1: invalid command name "-body" |
| assemble-9.5 | `untriaged` | code 1: invalid command name "-body" |
| assemble-9.6 | `untriaged` | code 1: invalid command name "-body" |
| assemble-9.7 | `untriaged` | code 1: invalid command name "-body" |

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
| autoMkindex-1.2 | `untriaged` | code 1: invalid command name "auto_mkindex" |
| autoMkindex-1.3 | `untriaged` | cleanup: unknown namespace "tcl_autoMkindex_tmp" in namespace delete command |
| autoMkindex-2.1 | `untriaged` | code 1: invalid command name "auto_mkindex" |
| autoMkindex-3.1 | `untriaged` | code 1: invalid command name "auto_mkindex_parser::slavehook" |
| autoMkindex-3.2 | `untriaged` | cleanup: unknown namespace "tcl_autoMkindex_tmp" in namespace delete command |
| autoMkindex-3.4 | `untriaged` | code 1: invalid command name "auto_mkindex" |
| autoMkindex-4.1 | `untriaged` | code 1: invalid command name "auto_mkindex" |
| autoMkindex-5.1 | `untriaged` | code 1: invalid command name "auto_mkindex" |
| autoMkindex-5.2 | `untriaged` | code 1: invalid command name "auto_mkindex" |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 1 | `tcl`: tclsh skips it too |

### basic.test

| Test | Bucket | Result (start) |
|---|---|---|
| basic-10.1 | `untriaged` | code 1: unknown namespace "::" in namespace delete command |
| basic-12.1 | `untriaged` | code 0: 0 {} 1 {unknown command "x"} {} |
| basic-13.1 | `untriaged` | code 1: unknown hidden command "cmd" |
| basic-15.2 | `untriaged` | cleanup: unknown namespace "n" in namespace delete command |
| basic-18.5 | `untriaged` | code 0: 1 {can't rename to "george::martha": command already exists} |
| basic-18.6 | `untriaged` | code 0: {p in ::} {} {q in ::} |
| basic-46.1 | `untriaged` | code 0: 1 { DONE } |
| basic-46.2 | `untriaged` | code 1: hello invoked "break" outside of a loop |
| basic-46.3 | `untriaged` | code 1: invoked "break" outside of a loop |
| basic-46.4 | `untriaged` | code 1: invoked "break" outside of a loop |
| basic-46.5 | `untriaged` | code 1: command returned bad code: 2 |
| basic-50.1 | `untriaged` | code 0: 2 {} |

| Skipped by | Tests | Bucket |
|---|---|---|
| emptyTest | 27 | `tcl`: tclsh skips it too |
| testcmdtoken | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| memory | 2 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testcreatecommand | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### binary.test

| Test | Bucket | Result (start) |
|---|---|---|
| binary-1.3 | `untriaged` | code 1: unknown or ambiguous subcommand "f": must be decode, encode, format, or scan |
| binary-13.13 | `untriaged` | code 0: ÿ |
| binary-15.1 | `untriaged` | code 0: yz |
| binary-16.1 | `untriaged` | code 0: z |
| binary-16.4 | `untriaged` | code 0: fooz |
| binary-16.5 | `untriaged` | code 0: fob |
| binary-17.3 | `untriaged` | code 1: missing count for "@" field specifier |
| binary-19.1 | `untriaged` | code 1: unknown or ambiguous subcommand "s": must be decode, encode, format, or scan |
| binary-2.8 | `untriaged` | code 0: foox |
| binary-3.8 | `untriaged` | code 0: foox  |
| binary-36.1 | `untriaged` | code 1: not enough arguments for all format specifiers |
| binary-37.10 | `untriaged` | code 1: the count of a binary field is too large |
| binary-37.11 | `untriaged` | code 1: the count of a binary field is too large |
| binary-37.12 | `untriaged` | code 1: the count of a binary field is too large |
| binary-37.13 | `untriaged` | code 1: the count of a binary field is too large |
| binary-40.3 | `untriaged` | code 0: 1 NaN |
| binary-40.4 | `untriaged` | code 0: 1 NaN |
| binary-43.6 | `untriaged` | code 0: 1 -9223372036854775808 |
| binary-43.7 | `untriaged` | code 0: 1 -9223372036854775808 |
| binary-43.8 | `untriaged` | code 0: 2 -9223372036854775808 -9223372036854775808 |
| binary-43.9 | `untriaged` | code 0: 2 -9223372036854775808 -9223372036854775808 |
| binary-46.4 | `untriaged` | code 1: unknown encoding "iso8859-15" |
| binary-46.5 | `untriaged` | code 1: unknown encoding "iso8859-15" |
| binary-53.12 | `untriaged` | code 0: ÿ |
| binary-53.13 | `untriaged` | code 0: ÿ |
| binary-63.2 | `untriaged` | code 0: 0x7ff0000000000000 |
| binary-63.3 | `untriaged` | code 1: expected floating-point number but got "NaN(3123456789aBc)" |
| binary-63.4 | `untriaged` | code 1: expected floating-point number but got "NaN( 3123456789aBc)" |
| binary-64.2 | `untriaged` | code 0: NaN |
| binary-73.35 | `untriaged` | code 0: 0 0 0 1 0 1 0 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 |
| binary-73.37 | `untriaged` | code 1: invalid base64 character ":" at position 3 |
| binary-75.25 | `untriaged` | code 0: ABC |
| binary-75.7 | `untriaged` | code 0: 0 |
| binary-75.8 | `untriaged` | code 0: 1 |
| binary-75.9 | `untriaged` | code 0: 2 |
| binary-76.1 | `untriaged` | code 1: couldn't open "/dev/null": no such file or directory |

| Skipped by | Tests | Bucket |
|---|---|---|
| bigEndian | 76 | `platform`: a constraint of another platform or word size |
| testsetbytearraylength | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| win | 1 | `platform`: a constraint of another platform or word size |

### chan.test

| Test | Bucket | Result (start) |
|---|---|---|
| chan-10.1 | `untriaged` | code 0: stderr stdin stdout |
| chan-11.1 | `untriaged` | code 1: wrong # args: should be "puts ?-nonewline? ?channelId? string" |
| chan-12.1 | `untriaged` | code 1: wrong # args: should be "read channelId ?numChars?" or "read ?-nonewline? chann... |
| chan-13.1 | `untriaged` | code 1: wrong # args: should be "seek channelId offset ?origin?" |
| chan-14.1 | `untriaged` | code 1: wrong # args: should be "tell channelId" |
| chan-15.1 | `untriaged` | code 1: unknown or ambiguous subcommand "truncate": must be close, configure, copy, eof... |
| chan-15.2 | `untriaged` | code 1: unknown or ambiguous subcommand "truncate": must be close, configure, copy, eof... |
| chan-16.10 | `untriaged` | code 1: can not find channel named "stdin" |
| chan-16.11 | `untriaged` | code 1: can not find channel named "stdout" |
| chan-16.4 | `untriaged` | code 1: can not find channel named "stdout" |
| chan-16.5 | `untriaged` | code 1: can not find channel named "stdout" |
| chan-16.6 | `untriaged` | code 1: can not find channel named "stdin" |
| chan-17.1 | `untriaged` | code 1: unknown or ambiguous subcommand "pipe": must be close, configure, copy, eof, fl... |
| chan-17.2 | `untriaged` | code 1: unknown or ambiguous subcommand "pipe": must be close, configure, copy, eof, fl... |
| chan-17.3 | `untriaged` | cleanup: can't read "pw": no such variable |
| chan-17.4 | `untriaged` | cleanup: can't read "::pw": no such variable |
| chan-2.1 | `untriaged` | code 1: wrong # args: should be "fblocked channelId" |
| chan-3.1 | `untriaged` | code 1: wrong # args: should be "close channelId ?direction?" |
| chan-4.1 | `untriaged` | code 1: wrong # args: should be "fconfigure channelId ?-option value ...?" |
| chan-4.2 | `untriaged` | code 0:  |
| chan-4.3 | `untriaged` | code 0:  |
| chan-4.5 | `untriaged` | code 0:  |
| chan-5.1 | `untriaged` | code 1: wrong # args: should be "fcopy input output ?-size size? ?-command callback?" |
| chan-6.1 | `untriaged` | code 1: wrong # args: should be "eof channelId" |
| chan-7.1 | `untriaged` | code 1: wrong # args: should be "fileevent channelId event ?script?" |
| chan-8.1 | `untriaged` | code 1: wrong # args: should be "flush channelId" |
| chan-9.1 | `untriaged` | code 1: wrong # args: should be "gets channelId ?varName?" |

### chanio.test

| Test | Bucket | Result (start) |
|---|---|---|
| chan-io-1.6 | `untriaged` | code 0: a9 |
| chan-io-1.7 | `untriaged` | code 1: unknown encoding "shiftjis" |
| chan-io-1.8 | `untriaged` | code 1: unknown encoding "iso2022-jp" |
| chan-io-1.9 | `untriaged` | code 1: unknown encoding "iso2022-jp" |
| chan-io-11.4 | `untriaged` | code 0: {abcdefghijklmnopqrstuvwxyz } 1 {} 1 |
| chan-io-13.11 | `untriaged` | code 0: abcd defgh |
| chan-io-13.12 | `untriaged` | code 0:    ab  def    |
| chan-io-14.2 | `untriaged` | code 0: {} {} {} |
| chan-io-14.3 | `untriaged` | cleanup: can not find channel named "file193" |
| chan-io-14.4 | `untriaged` | cleanup: can not find channel named "file194" |
| chan-io-14.5 | `untriaged` | code 1: can not find channel named "stdin" |
| chan-io-14.6 | `untriaged` | code 1: can not find channel named "stdout" |
| chan-io-14.7 | `untriaged` | code 1: can not find channel named "stderr" |
| chan-io-14.8 | `untriaged` | code 0:  |
| chan-io-19.1 | `untriaged` | code 1: can not find channel named "stdin" |
| chan-io-2.2 | `untriaged` | code 0: {} {123456789012345  12} |
| chan-io-2.4 | `untriaged` | code 0: {abcdefg hijklmnopqrstuvwxyz} {abcdefg hijklmnopqrstuvwxyz} |
| chan-io-20.1 | `untriaged` | code 0: utf-8 |
| chan-io-20.3 | `untriaged` | code 0: {} {auto lf} |
| chan-io-20.5 | `untriaged` | code 1:  |
| chan-io-27.4 | `untriaged` | code 0: 0 0 72 |
| chan-io-27.5 | `untriaged` | code 0: 0 0 72 |
| chan-io-28.2 | `untriaged` | code 1: bad option "share": must be alias, aliases, children, create, delete, eval, exi... |
| chan-io-29.1 | `untriaged` | code 1: can not find channel named "stdin" |
| chan-io-29.20 | `untriaged` | code 0: 0 0 12600 |
| chan-io-29.27 | `untriaged` | code 0: 1 {error writing "file254": broken pipe} {posix epipe {broken pipe}} |
| chan-io-29.35 | `untriaged` | code 1: bad option "share": must be alias, aliases, children, create, delete, eval, exi... |
| chan-io-29.9 | `untriaged` | code 1: can not find channel named "stdin" |
| chan-io-3.1 | `untriaged` | code 1: unknown encoding "ascii" |
| chan-io-3.2 | `untriaged` | code 1: unknown encoding "ascii" |
| chan-io-3.3 | `untriaged` | code 1: unknown encoding "ascii" |
| chan-io-3.4 | `untriaged` | code 1: unknown encoding "jis0208" |
| chan-io-3.5 | `untriaged` | code 1: unknown encoding "jis0208" |
| chan-io-3.6 | `untriaged` | code 1: unknown encoding "shiftjis" |
| chan-io-3.7 | `untriaged` | code 1: unknown encoding "jis0208" |
| chan-io-3.8 | `untriaged` | code 1: unknown encoding "ascii" |
| chan-io-30.16 | `untriaged` | code 0: hello there and here  |
| chan-io-30.18 | `untriaged` | code 0: abc def 0 ghi 0 qrs 0 |
| chan-io-30.19 | `untriaged` | code 0: abc def 0 ghi 0 qrs 0 |
| chan-io-30.21 | `untriaged` | code 0: 0 0 def 0 |
| chan-io-30.22 | `untriaged` | code 0: 0 0 def 0 |
| chan-io-30.23 | `untriaged` | code 0: 17 1 |
| chan-io-30.24 | `untriaged` | code 0: 17 1 |
| chan-io-30.25 | `untriaged` | code 0: 17 1 |
| chan-io-30.26 | `untriaged` | code 0: 17 1 |
| chan-io-30.27 | `untriaged` | code 0: 17 1 |
| chan-io-30.28 | `untriaged` | code 0: 17 1 |
| chan-io-31.11 | `untriaged` | code 0: hello 6 cr 0 0 7 cr 0 |
| chan-io-31.13 | `untriaged` | code 0: binary |
| chan-io-31.18 | `untriaged` | code 0: hello there and here 0  0 |
| chan-io-31.20 | `untriaged` | code 0: abc def 0 qrs 0 |
| chan-io-31.21 | `untriaged` | code 0: abc def 0 qrs 0 |
| chan-io-31.25 | `untriaged` | code 0: abc def 0 qrs 0 |
| chan-io-31.26 | `untriaged` | code 0: abc def 0 qrs 0 |
| chan-io-31.27 | `untriaged` | code 0: abc def 0 qrs 0 |
| chan-io-31.28 | `untriaged` | code 0: abc def 0 qrs 0 |
| chan-io-31.29 | `untriaged` | code 0: abc def 0 qrs 0 |
| chan-io-31.30 | `untriaged` | code 0: abc def 0 qrs 0 |
| chan-io-31.5 | `untriaged` | code 0: 5 6 cr 0 there 12 cr 0 |
| chan-io-31.6 | `untriaged` | code 0: 5 6 crlf 0 there 12 crlf 0 |
| chan-io-32.1 | `untriaged` | code 1: can not find channel named "stdout" |
| chan-io-32.2 | `untriaged` | code 1: can not find channel named "stdin" |
| chan-io-34.12 | `untriaged` | code 1: bad origin "cur": must be start, current, or end |
| chan-io-34.19 | `untriaged` | code 0: 0 |
| chan-io-34.8 | `untriaged` | code 1: error during seek on "file431": input/output error |
| chan-io-35.10 | `untriaged` | code 0: 10 8 1 |
| chan-io-35.11 | `untriaged` | code 0: 10 8 1 |
| chan-io-35.12 | `untriaged` | code 0: 17 17 1 |
| chan-io-35.13 | `untriaged` | code 0: 17 17 1 |
| chan-io-35.14 | `untriaged` | code 0: 17 17 1 |
| chan-io-35.15 | `untriaged` | code 0: 17 17 1 |
| chan-io-35.16 | `untriaged` | code 0: 21 17 1 |
| chan-io-35.17 | `untriaged` | code 0: 21 17 1 |
| chan-io-35.6 | `untriaged` | code 0: 8 8 1 |
| chan-io-35.7 | `untriaged` | code 0: 8 8 1 |
| chan-io-35.8 | `untriaged` | code 0: 8 8 1 |
| chan-io-35.9 | `untriaged` | code 0: 8 8 1 |
| chan-io-38.3 | `untriaged` | code 1: error reading "file495": illegal operation on a directory |
| chan-io-39.14 | `untriaged` | code 0: ç¦ |
| chan-io-39.21 | `untriaged` | code 0: auto lf |
| chan-io-39.22 | `untriaged` | code 0: {} {} {} |
| chan-io-39.22a | `untriaged` | code 0: {} {} {0 {}} |
| chan-io-39.23 | `untriaged` | code 0: {} lf |
| chan-io-39.24 | `untriaged` | code 0: {} lf |
| chan-io-4.4 | `untriaged` | code 0: {} {1234567          A} |
| chan-io-40.17 | `untriaged` | setup: can't read "::env(HOME)": no such variable |
| chan-io-41.1 | `untriaged` | code 1: wrong # args: should be "fileevent channelId event ?script?" |
| chan-io-41.2 | `untriaged` | code 1: wrong # args: should be "fileevent channelId event ?script?" |
| chan-io-42.2 | `untriaged` | code 1: bad event name "r": must be readable or writable |
| chan-io-42.3 | `untriaged` | code 1: bad event name "r": must be readable or writable |
| chan-io-43.2 | `untriaged` | code 1: bad event name "r": must be readable or writable |
| chan-io-48.10 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| chan-io-48.11 | `untriaged` | code 0: 3 {abc def } |
| chan-io-48.12 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| chan-io-48.13 | `untriaged` | code 0: 3 {abc def } |
| chan-io-48.14 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| chan-io-48.15 | `untriaged` | code 0: 3 {abc def } |
| chan-io-48.4 | `untriaged` | code 0: 3 {abc def } |
| chan-io-48.5 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| chan-io-48.6 | `untriaged` | code 0: 3 {abc def } |
| chan-io-48.7 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| chan-io-48.8 | `untriaged` | code 0: 3 {abc def } |
| chan-io-48.9 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| chan-io-49.1 | `untriaged` | code 0: 7 a 1 { } 2 b 3 { } 4 c 5 { } 6 0 { } 0 |
| chan-io-49.2 | `untriaged` | code 0: 7 {a } 2 {b } 4 {c } 6 0 { } 7 1 |
| chan-io-49.3 | `untriaged` | code 0: 7 {a b} 3 { c } 6 0 { } 7 1 |
| chan-io-5.2 | `untriaged` | code 0: {} 12345678901234567890 |
| chan-io-5.4 | `untriaged` | code 1: unknown encoding "ascii" |
| chan-io-52.1 | `untriaged` | code 1: fcopy -command is not available |
| chan-io-52.2 | `untriaged` | code 1: fcopy -command is not available |
| chan-io-52.3 | `untriaged` | code 1: error reading "file606": illegal operation on a directory |
| chan-io-52.4 | `untriaged` | code 1: error reading "file608": illegal operation on a directory |
| chan-io-52.5 | `untriaged` | code 1: error reading "file610": illegal operation on a directory |
| chan-io-52.5a | `untriaged` | code 1: error reading "file612": illegal operation on a directory |
| chan-io-52.5b | `untriaged` | code 1: error reading "file614": illegal operation on a directory |
| chan-io-52.6 | `untriaged` | code 1: error reading "file616": illegal operation on a directory |
| chan-io-52.7 | `untriaged` | code 1: error reading "file618": illegal operation on a directory |
| chan-io-52.8 | `untriaged` | code 0: 0 0 |
| chan-io-6.17 | `untriaged` | code 0: 0 {} -1 {} |
| chan-io-6.21 | `untriaged` | code 0: 4 abcd 4 efgh 4 ijkl 0 {} |
| chan-io-6.23 | `untriaged` | code 0: 0 {} -1 {} |
| chan-io-6.29 | `untriaged` | code 0: 4 abcd 9 {efgh ijkl} 4 mnop |
| chan-io-6.4 | `untriaged` | code 0: 4 H´ |
| chan-io-6.5 | `untriaged` | code 1: unknown encoding "shiftjis" |
| chan-io-6.55 | `untriaged` | code 1: unknown encoding "iso2022-jp" |
| chan-io-6.8 | `untriaged` | code 0: 12 abcdefghijk 6 wombat |
| chan-io-6.9 | `untriaged` | code 0: 11 abcdefghijk 7 wombat |
| chan-io-7.1 | `untriaged` | code 1: unknown encoding "shiftjis" |
| chan-io-7.2 | `untriaged` | code 1: unknown encoding "shiftjis" |
| chan-io-7.4 | `untriaged` | code 1: unknown encoding "shiftjis" |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 29 | `untriaged` |
| testchannel | 44 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testfevent | 9 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| emptyTest | 8 | `tcl`: tclsh skips it too |
| nonBlockFiles | 8 | `untriaged` |
| testchannelevent | 6 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| asyncPipeChan | 3 | `untriaged` |
| win | 2 | `platform`: a constraint of another platform or word size |
| extensive | 1 | `tcl`: tclsh skips it too |
| makeFileInHome | 1 | `untriaged` |
| nonPortable | 1 | `tcl`: tclsh skips it too |

### clock.test

| Test | Bucket | Result (start) |
|---|---|---|
| clock-1.4 | `untriaged` | code 0: 1 {bad option "-oops": must be -format, -gmt, -locale or -timezone} {CLOCK badO... |
| clock-10.10 | `untriaged` | code 0: 946684800 0 |
| clock-13.2 | `untriaged` | code 0: 946857600 0 |
| clock-13.3 | `untriaged` | code 0: 946857600 {CLOCK badInputString} |
| clock-13.4 | `untriaged` | code 0: 946857600 {CLOCK badInputString} |
| clock-15.2 | `untriaged` | code 0: 946684800 0 |
| clock-15.3 | `untriaged` | code 0: 946684800 0 |
| clock-16.10 | `untriaged` | code 0: 946684800 0 |
| clock-16.11 | `untriaged` | code 0: 946684800 0 |
| clock-18.2 | `untriaged` | code 0: 947116800 0 |
| clock-18.3 | `untriaged` | code 0: 947116800 0 |
| clock-18.4 | `untriaged` | code 0: 947116800 0 |
| clock-20.2 | `untriaged` | code 0: 2678400 0 |
| clock-20.3 | `untriaged` | code 0: 2678400 0 |
| clock-20.4 | `untriaged` | code 0: 2678400 0 |
| clock-21.6 | `untriaged` | code 0: 86400 0 |
| clock-21.7 | `untriaged` | code 0: 86400 0 |
| clock-21.8 | `untriaged` | code 0: 86400 0 |
| clock-23.2 | `untriaged` | code 0: 604800 0 |
| clock-25.2 | `untriaged` | code 0: 86400 0 |
| clock-25.3 | `untriaged` | code 0: 86400 0 |
| clock-25.4 | `untriaged` | code 0: 86400 0 |
| clock-25.5 | `untriaged` | code 0: 86400 0 |
| clock-25.6 | `untriaged` | code 0: 86400 0 |
| clock-25.7 | `untriaged` | code 0: 86400 0 |
| clock-27.2 | `untriaged` | code 0: -259200 0 |
| clock-27.3 | `untriaged` | code 0: -259200 0 |
| clock-27.4 | `untriaged` | code 0: -259200 0 |
| clock-27.5 | `untriaged` | code 0: -259200 0 |
| clock-27.6 | `untriaged` | code 0: -259200 0 |
| clock-27.7 | `untriaged` | code 0: -259200 0 |
| clock-27.8 | `untriaged` | code 0: -259200 0 |
| clock-27.9 | `untriaged` | code 0: -259200 0 |
| clock-28.1 | `untriaged` | code 0: 1234567890 |
| clock-32.1 | `untriaged` | code 0: formatting -6857222400: 1752-247 should be 1752-258 scanning 1752-258: -6857222... |
| clock-33.7 | `untriaged` | code 0: 1 {bad option "-": must be -milliseconds or -microseconds} |
| clock-34.10 | `untriaged` | code 0: Jan 01,0071 00:00 GMT |
| clock-34.11 | `untriaged` | code 0: Jan 01,0037 00:00 GMT |
| clock-34.12 | `untriaged` | code 1: unable to convert date-time string "Oct 23, 1992 -1 day": syntax error |
| clock-34.13 | `untriaged` | code 1: unable to convert date-time string "19921023": syntax error |
| clock-34.15 | `untriaged` | code 1: unable to convert date-time string "23-Oct-1992": syntax error |
| clock-34.16 | `untriaged` | code 1: unable to convert date-time string "19921023T235959": syntax error |
| clock-34.17 | `untriaged` | code 1: unable to convert date-time string "19921023 235959": syntax error |
| clock-34.18 | `untriaged` | code 1: unable to convert date-time string "19921023T000000": syntax error |
| clock-34.19 | `untriaged` | code 1: unable to convert date-time string "5 am": syntax error |
| clock-34.20 | `untriaged` | code 1: unable to convert date-time string "5:30 pm": syntax error |
| clock-34.21 | `untriaged` | code 1: unable to convert date-time string "00:00-0800": syntax error |
| clock-34.23 | `untriaged` | code 1: unable to convert date-time string "8:00:00 am": syntax error |
| clock-34.24 | `untriaged` | code 1: unable to convert date-time string "8:00:00 pm": syntax error |
| clock-34.25 | `untriaged` | code 1: unable to convert date-time string "00:00:30-0800": syntax error |
| clock-34.28 | `untriaged` | code 1: unable to convert date-time string "Monday": syntax error |
| clock-34.29 | `untriaged` | code 1: unable to convert date-time string "1/1": syntax error |
| clock-34.3 | `untriaged` | code 1: unable to convert date-time string "14 Feb 92": syntax error |
| clock-34.31 | `untriaged` | code 1: unable to convert date-time string "19990101": syntax error |
| clock-34.32 | `untriaged` | code 1: unable to convert date-time string "now + 1 minute": syntax error |
| clock-34.33 | `untriaged` | code 1: unable to convert date-time string "now +1 minute": syntax error |
| clock-34.34 | `untriaged` | code 1: unable to convert date-time string "now 1 minute": syntax error |
| clock-34.35 | `untriaged` | code 1: unable to convert date-time string "now - 1 minute": syntax error |
| clock-34.36 | `untriaged` | code 1: unable to convert date-time string "now -1 minute": syntax error |
| clock-34.37 | `untriaged` | code 1: unable to convert date-time string "20000112": syntax error |
| clock-34.38 | `untriaged` | code 1: unable to convert date-time string "20000112": syntax error |
| clock-34.39 | `untriaged` | code 1: unable to convert date-time string "20000112": syntax error |
| clock-34.4 | `untriaged` | code 1: unable to convert date-time string "Feb 14, 1992 12:20 PM": syntax error |
| clock-34.40 | `untriaged` | code 1: unable to convert date-time string "20000112": syntax error |
| clock-34.41 | `untriaged` | code 1: unable to convert date-time string "monday": syntax error |
| clock-34.42 | `untriaged` | code 1: unable to convert date-time string "2 monday": syntax error |
| clock-34.43 | `untriaged` | code 1: unable to convert date-time string "monday 1 week ago": syntax error |
| clock-34.44 | `untriaged` | code 1: unable to convert date-time string "monday": syntax error |
| clock-34.45 | `untriaged` | code 1: unable to convert date-time string "2 monday": syntax error |
| clock-34.46 | `untriaged` | code 1: unable to convert date-time string "monday 1 week ago": syntax error |
| clock-34.47 | `untriaged` | code 1: unable to convert date-time string "2 days 2 hours ago": syntax error |
| clock-34.48 | `untriaged` | code 1: unable to convert date-time string "10:00 11:00": syntax error |
| clock-34.49 | `untriaged` | code 1: unable to convert date-time string "1/1/2001 2/2/2002": syntax error |
| clock-34.5 | `untriaged` | code 1: unable to convert date-time string "Feb 14, 1992 12:20 PM": syntax error |
| clock-34.50 | `untriaged` | code 1: unable to convert date-time string "10:00 EST CST": syntax error |
| clock-34.51 | `untriaged` | code 1: unable to convert date-time string "Monday Tuesday": syntax error |
| clock-34.52 | `untriaged` | code 1: unable to convert date-time string "next January next March": syntax error |
| clock-34.53 | `untriaged` | code 1: unable to convert date-time string "19921023T00:00:00": syntax error |
| clock-34.54 | `untriaged` | code 1: unable to convert date-time string "1992-10-23T00:00:00": syntax error |
| clock-34.59 | `untriaged` | code 1: unable to convert date-time string "31 Jan 14 23:59:59 -0100": syntax error |
| clock-34.6 | `untriaged` | code 1: unable to convert date-time string "Oct 23,1992 15:00": syntax error |
| clock-34.60 | `untriaged` | code 1: unable to convert date-time string "31 Jan 14 23:59:59 +0100": syntax error |
| clock-34.61 | `untriaged` | code 1: unable to convert date-time string "23:59:59 -0100": syntax error |
| clock-34.62 | `untriaged` | code 1: unable to convert date-time string "23:59:59 +0100": syntax error |
| clock-34.63 | `untriaged` | code 1: unable to convert date-time string "Mon, 30 Jun 2014 23:59:59 CEST": syntax error |
| clock-34.64 | `untriaged` | code 1: unable to convert date-time string "Fri, 31 Jan 2014 23:59:59 CET": syntax error |
| clock-34.65 | `untriaged` | code 1: unable to convert date-time string "23:59:59 +15 day": syntax error |
| clock-34.66 | `untriaged` | code 1: unable to convert date-time string "23:59:59 -15 day": syntax error |
| clock-34.67 | `untriaged` | code 1: unable to convert date-time string "10:59 pm CET": syntax error |
| clock-34.68 | `untriaged` | code 1: unable to convert date-time string "10:59 pm +0100": syntax error |
| clock-34.7 | `untriaged` | code 1: unable to convert date-time string "Oct 23,1992 15:00 GMT": syntax error |
| clock-34.8 | `untriaged` | code 1: unable to convert date-time string "Oct 23,1992 15:00": syntax error |
| clock-34.9 | `untriaged` | code 0: 1 {bad option "-bad": must be -base, -format, -gmt, -locale or -timezone} |
| clock-36.1 | `untriaged` | code 1: unable to convert date-time string "june 1, 2000": syntax error |
| clock-36.2 | `untriaged` | code 1: unable to convert date-time string "june 1, 2000": syntax error |
| clock-36.3 | `untriaged` | code 1: unable to convert date-time string "june 1, 2000": syntax error |
| clock-38.1 | `untriaged` | code 0: 00:00:00 |
| clock-38.2 | `untriaged` | code 0: 0 |
| clock-42.1 | `untriaged` | code 0: +0000 |
| clock-44.1 | `untriaged` | code 1: time zone "US/East-Indiana" not found |
| clock-46.2 | `untriaged` | code 1: unable to convert date-time string "20040000": syntax error |
| clock-46.4 | `untriaged` | code 1: unable to convert date-time string "20041301": syntax error |
| clock-46.5 | `untriaged` | code 1: unable to convert date-time string "12:01 am": syntax error |
| clock-46.6 | `untriaged` | code 1: unable to convert date-time string "13:00 am": syntax error |
| clock-47.1 | `untriaged` | code 1: unable to convert date-time string "0012": syntax error |
| clock-47.2 | `untriaged` | code 1: unable to convert date-time string "0039": syntax error |
| clock-52.2 | `untriaged` | code 0: 02:59:59 01:59:59 03:00:00 02:00:00 02:59:59 01:59:59 03:00:00 02:00:00 |
| clock-52.3 | `untriaged` | code 0: 02:59:59 03:00:00 02:59:59 03:00:00 |
| clock-55.5 | `untriaged` | code 1: input string does not match supplied format |
| clock-55.6 | `untriaged` | code 1: input string does not match supplied format |
| clock-55.8 | `untriaged` | code 1: input string does not match supplied format |
| clock-55.9 | `untriaged` | code 1: input string does not match supplied format |
| clock-56.1 | `untriaged` | setup: can't read "::tcl::clock::ZoneinfoPaths": no such variable |
| clock-56.2 | `untriaged` | setup: can't read "::tcl::clock::ZoneinfoPaths": no such variable |
| clock-56.3 | `untriaged` | setup: can't read "::tcl::clock::ZoneinfoPaths": no such variable |
| clock-56.4 | `untriaged` | setup: can't read "::tcl::clock::ZoneinfoPaths": no such variable |
| clock-58.1 | `untriaged` | code 0:  1872-12-31 converts to 12/31/1872 and should be \u00e8\u00a5\u00bf\u00e6\u009a... |
| clock-59.1 | `untriaged` | code 0: pzone Z ps2 is {unable to convert date-time string "20000101 000000 Z": syntax ... |
| clock-59.2 | `untriaged` | code 1: time zone "Etc/GMT-2" not found |
| clock-6.0 | `untriaged` | code 0: -9223372036854775807 |
| clock-6.10 | `untriaged` | code 0: 0 9223372036854775807 |
| clock-6.9 | `untriaged` | code 0: 0 -9223372036854775807 |
| clock-61.1 | `untriaged` | code 0: -9223372036854775808 |
| clock-61.2 | `untriaged` | code 1: expected integer but got "-0x8000000000000001" |
| clock-62.1 | `untriaged` | setup: invalid command name "::tcl::clock::ClearCaches" |
| clock-63.1 | `untriaged` | code 1: invalid command name "::tcl::clock::ConvertLocalToUTC" |
| clock-66.1 | `untriaged` | setup: invalid command name "::tcl::clock::ClearCaches" |
| clock-67.4 | `untriaged` | code 0: 0 1 |
| clock-67.5 | `untriaged` | code 1: input string does not match supplied format |
| clock-7.6 | `untriaged` | code 0: 0 253402300800 {CLOCK badInputString} |
| clock-7.7 | `untriaged` | code 0: 0 185331720384000 {CLOCK badInputString} |
| clock-9.2 | `untriaged` | code 0: 946684800 |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 3 | `untriaged` |
| win | 7 | `platform`: a constraint of another platform or word size |

### cmdAH.test

| Test | Bucket | Result (start) |
|---|---|---|
| cmdAH-1.4 | `untriaged` | code 0: 0 |
| cmdAH-1.5 | `untriaged` | code 0: 0 |
| cmdAH-16.1 | `untriaged` | code 1: invalid command name "-returnCodes" |
| cmdAH-16.2 | `untriaged` | code 1: invalid command name "-constraints" |
| cmdAH-16.3 | `untriaged` | code 1: invalid command name "-constraints" |
| cmdAH-17.1 | `untriaged` | code 1: invalid command name "-returnCodes" |
| cmdAH-17.2 | `untriaged` | code 1: invalid command name "-constraints" |
| cmdAH-17.3 | `untriaged` | code 1: invalid command name "-constraints" |
| cmdAH-19.10 | `untriaged` | code 0: ~nOsUcHuSeR |
| cmdAH-19.11 | `untriaged` | cleanup: file attributes is not available |
| cmdAH-2.3 | `untriaged` | setup: can't read "env(HOME)": no such variable |
| cmdAH-2.4 | `untriaged` | setup: can't read "env(HOME)": no such variable |
| cmdAH-2.5 | `untriaged` | code 1: couldn't change working directory to "~~": no such file or directory |
| cmdAH-2.6.1 | `untriaged` | code 0:  |
| cmdAH-20.1 | `untriaged` | code 1: file atime with a new time is not available |
| cmdAH-20.4 | `untriaged` | code 1: file atime with a new time is not available |
| cmdAH-20.5 | `untriaged` | code 1: file atime with a new time is not available |
| cmdAH-23.6 | `untriaged` | code 0: 1 {can't set "x(atime)": variable isn't array} NONE |
| cmdAH-24.1 | `untriaged` | code 1: file mtime with a new time is not available |
| cmdAH-24.12 | `untriaged` | code 1: unable to convert date-time string "21:00:00 October 30 2004 GMT": syntax error |
| cmdAH-24.13 | `untriaged` | code 1: file mtime with a new time is not available |
| cmdAH-24.7 | `untriaged` | code 1: file mtime with a new time is not available |
| cmdAH-24.8 | `untriaged` | code 1: file mtime with a new time is not available |
| cmdAH-24.9 | `untriaged` | code 1: file mtime with a new time is not available |
| cmdAH-25.3 | `untriaged` | code 0: 1 |
| cmdAH-26.1 | `untriaged` | code 1: could not readlink: links are not available in the root folder |
| cmdAH-28.5 | `untriaged` | code 0: 0o644 |
| cmdAH-28.7 | `untriaged` | code 1: can't set "x(atime)": variable isn't array |
| cmdAH-29.4 | `untriaged` | code 1: could not link: links are not available in the root folder |
| cmdAH-29.4.1 | `untriaged` | code 1: could not link: links are not available in the root folder |
| cmdAH-30.8 | `untriaged` | code 0: . |
| cmdAH-31.1 | `untriaged` | code 0:  |
| cmdAH-31.10 | `untriaged` | code 1: can not find channel named "file25" |
| cmdAH-31.11 | `untriaged` | code 1: invalid command name "file" |
| cmdAH-31.12 | `untriaged` | code 1: invalid command name "file" |
| cmdAH-31.13 | `untriaged` | code 1: invalid command name "close" |
| cmdAH-31.2 | `untriaged` | code 0:  |
| cmdAH-31.4 | `untriaged` | code 0:  |
| cmdAH-31.6 | `untriaged` | code 1: invalid command name "file" |
| cmdAH-31.8 | `untriaged` | code 1: invalid command name "file" |
| cmdAH-31.9 | `untriaged` | code 1: invalid command name "file" |
| cmdAH-32.1 | `untriaged` | code 0: file26 |
| cmdAH-32.4 | `untriaged` | code 0: foo produced /tcl_tmp3 |
| cmdAH-32.5 | `untriaged` | code 0: /dir.file/foo produced /tcl_tmp4 |
| cmdAH-4.1 | `untriaged` | code 1: wrong # args: should be "encoding option ?arg ...?" |
| cmdAH-4.10 | `untriaged` | code 1: unknown encoding "jis0208" |
| cmdAH-4.2 | `untriaged` | code 1: bad option "foo": must be convertfrom, convertto, dirs, names, or system |
| cmdAH-4.5 | `untriaged` | code 1: unknown encoding "jis0208" |
| cmdAH-4.6 | `untriaged` | code 1: unknown encoding "jis0208" |
| cmdAH-4.9 | `untriaged` | code 1: unknown encoding "jis0208" |
| cmdAH-5.4 | `untriaged` | code 0: 1 |
| cmdAH-6.1 | `untriaged` | code 0: / |
| cmdAH-7.1 | `untriaged` | code 1: file attributes is not available |
| cmdAH-9.52 | `untriaged` | code 0: ~foo ~foo ~foo ~foo |

| Skipped by | Tests | Bucket |
|---|---|---|
| testsetplatform | 145 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| win | 22 | `platform`: a constraint of another platform or word size |
| nonPortable | 8 | `tcl`: tclsh skips it too |
| filetime64bit | 2 | `untriaged` |
| testchmod | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### cmdIL.test

| Test | Bucket | Result (start) |
|---|---|---|
| cmdIL-1.41 | `untriaged` | code 1: when used with "-stride", the leading "-index" value must be within the group |
| cmdIL-1.42 | `untriaged` | code 1: when used with "-stride", the leading "-index" value must be within the group |
| cmdIL-3.15 | `untriaged` | code 0: 1 {comparison error} {comparison error     while executing "error "comparison e... |
| cmdIL-3.5.1 | `untriaged` | code 1: element 1+3 missing from sublist "1 . c" |
| cmdIL-3.5.2 | `untriaged` | code 1: element -1-1 missing from sublist "1 . c" |
| cmdIL-3.5.3 | `untriaged` | code 1: element -2 missing from sublist "1 . c" |
| cmdIL-3.5.4 | `untriaged` | code 1: element end-4 missing from sublist "1 . c" |
| cmdIL-3.5.7 | `untriaged` | code 1: element end--1 missing from sublist "1 . c" |
| cmdIL-3.5.8 | `untriaged` | code 1: element end+1 missing from sublist "1 . c" |
| cmdIL-3.5.9 | `untriaged` | code 1: element end+2 missing from sublist "1 . c" |
| cmdIL-4.36 | `untriaged` | code 0: 256 32 257 |
| info-20.6 | `untriaged` | code 0: 0 |

| Skipped by | Tests | Bucket |
|---|---|---|
| hasIsoLocale | 2 | `untriaged` |
| memory | 2 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testWithLimit | 1 | `untriaged` |
| testobj | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### cmdInfo.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testcmdinfo | 9 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testcmdtoken | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### cmdMZ.test

| Test | Bucket | Result (start) |
|---|---|---|
| cmdMZ-4.13 | `untriaged` | code 0: a {} {} b qw� {} N wq |
| cmdMZ-return-1.0 | `untriaged` | code 2:  |
| cmdMZ-return-2.1 | `untriaged` | code 0: 2 {-code 0 -level 1} |
| cmdMZ-return-2.10 | `untriaged` | code 0: 1 {-code 1 -errorcode NONE -errorinfo {     while executing "return -level 0 -c... |
| cmdMZ-return-2.14 | `untriaged` | code 1: bad completion code "foo": must be ok, error, return, break, continue, or an in... |
| cmdMZ-return-2.18 | `untriaged` | code 1: unknown or ambiguous subcommand "errorstack": must be args, body, cmdcount, com... |
| cmdMZ-return-2.2 | `untriaged` | code 0: 2 {-code 2 -level 1} |
| cmdMZ-return-2.3 | `untriaged` | code 0: 2 {-code 2 -level 10} |
| cmdMZ-return-2.8 | `untriaged` | code 1: bad completion code "-1": must be ok, error, return, break, continue, or an int... |

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
| compile-13.2 | `untriaged` | setup: the recursion limit of this interpreter is 600 |
| compile-13.3 | `untriaged` | code 0: 1 1 1 1 |
| compile-18.1 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.10 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.11 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.12 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.13 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.14 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.15 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.16 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.17 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.18 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.19 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.2 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.21 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.22 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.23 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.24 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.25 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.26 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.27 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.28 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.28.1 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.28.2 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.28.3 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.28.4 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.29 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.3 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.30 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.31 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.32 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.33 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.34 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.35 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.36 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.37 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.38 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.39 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.4 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.40 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.41 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.42 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.43 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.44 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.45 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.46 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.47 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.48 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.5 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.50 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.51 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.52 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.53 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.54 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.55 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.56 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.57 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.58 | `untriaged` | code 1: invalid command name "tcl::unsupported::getbytecode" |
| compile-18.6 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.7 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.8 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-18.9 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-20.1 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |
| compile-20.2 | `untriaged` | code 1: invalid command name "tcl::unsupported::disassemble" |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 9 | `tcl`: tclsh skips it too |
| memory | 2 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### config.test

| Test | Bucket | Result (start) |
|---|---|---|
| pkgconfig-1.1 | `untriaged` | code 1: invalid command name "::tcl::pkgconfig" |
| pkgconfig-1.2 | `untriaged` | code 1: invalid command name "::tcl::pkgconfig" |
| pkgconfig-1.3 | `untriaged` | code 1: invalid command name "::tcl::pkgconfig" |
| pkgconfig-2.0 | `untriaged` | code 0: invalid command name "::tcl::pkgconfig" |
| pkgconfig-2.1 | `untriaged` | code 0: invalid command name "::tcl::pkgconfig" |
| pkgconfig-2.2 | `untriaged` | code 0: invalid command name "::tcl::pkgconfig" |
| pkgconfig-2.3 | `untriaged` | code 0: invalid command name "::tcl::pkgconfig" |
| pkgconfig-2.4 | `untriaged` | code 0: invalid command name "::tcl::pkgconfig" |
| pkgconfig-2.5 | `untriaged` | code 0: invalid command name "::tcl::pkgconfig" |

### coroutine.test

| Test | Bucket | Result (start) |
|---|---|---|
| coroutine-10.1 | `untriaged` | code 1: namespace "tcl::unsupported" not found in "::" |
| coroutine-3.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| coroutine-3.5 | `untriaged` | code 0: ::foo |
| coroutine-3.6 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| coroutine-3.7 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| coroutine-4.4 | `untriaged` | code 0: global |
| coroutine-7.10 | `untriaged` | code 2: a OUT b 123 c |
| coroutine-7.11 | `untriaged` | code 2: a OUT b 123 c |
| coroutine-7.4 | `untriaged` | code 0:  |
| coroutine-7.5 | `untriaged` | code 0: 0 1 0 3 4 5 |
| coroutine-7.8 | `untriaged` | code 2: a OUT b 123 c |
| coroutine-7.9 | `untriaged` | code 2: a OUT b 123 c |
| coroutine-8.0.0 | `untriaged` | code 1: invalid command name "tcl::unsupported::inject" |
| coroutine-8.0.1 | `untriaged` | code 1: invalid command name "tcl::unsupported::inject" |
| coroutine-8.1.1 | `untriaged` | code 1: invalid command name "tcl::unsupported::inject" |
| coroutine-8.1.2 | `untriaged` | code 1: interpreter named "child" already exists, cannot create |
| coroutine-9.1 | `untriaged` | code 1: invalid command name "::tcl::unsupported::corotype" |
| coroutine-9.2 | `untriaged` | code 1: invalid command name "::tcl::unsupported::corotype" |
| coroutine-9.3 | `untriaged` | code 1: invalid command name "::tcl::unsupported::corotype" |

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
| dict-10.1 | `untriaged` | code 1: unknown or ambiguous subcommand "info": must be append, create, exists, filter,... |
| dict-10.2 | `untriaged` | code 1: unknown or ambiguous subcommand "info": must be append, create, exists, filter,... |
| dict-10.3 | `untriaged` | code 1: unknown or ambiguous subcommand "info": must be append, create, exists, filter,... |
| dict-10.4 | `untriaged` | code 1: unknown or ambiguous subcommand "info": must be append, create, exists, filter,... |
| dict-11.13 | `untriaged` | code 1: wrong # args: should be "dict incr dictVarName key ?value ...?" |
| dict-11.14 | `untriaged` | code 1: wrong # args: should be "dict incr dictVarName key ?value ...?" |
| dict-14.12 | `untriaged` | code 0: 1 test 1 {test     while executing "error test"     invoked from within "dict f... |
| dict-17.13 | `untriaged` | code 0: 1 x {x     while executing "error x"     invoked from within "dict filter {a b}... |
| dict-20.21 | `untriaged` | code 0: a b c d |
| dict-20.22 | `untriaged` | code 0: a b c d |
| dict-22.10 | `untriaged` | code 1: key "b" not known in dictionary |
| dict-23.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.10 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.11 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.12 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.13 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.14 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.3 | `untriaged` | code 1: invalid command name "tcl::dict::lappend" |
| dict-23.4 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.5 | `untriaged` | code 1: invalid command name "tcl::dict::incr" |
| dict-23.6 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.7 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.8 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-23.9 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-24.12 | `untriaged` | code 0: 1 test 1 {test     while executing "error test"     invoked from within "dict m... |
| dict-24.20.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-24.21 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| dict-4.13a | `untriaged` | code 0: NONE |

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
| encoding-1.3 | `untriaged` | code 1: unknown encoding "jis0208" |
| encoding-10.1 | `untriaged` | code 1: unknown encoding "shiftjis" |
| encoding-11.2 | `untriaged` | code 1: unknown encoding "jis0201" |
| encoding-11.3 | `untriaged` | code 1: unknown encoding "jis0208" |
| encoding-11.4 | `untriaged` | code 1: unknown encoding "shiftjis" |
| encoding-11.5 | `untriaged` | code 1: unknown encoding "iso2022" |
| encoding-11.5.1 | `untriaged` | code 1: unknown encoding "iso2022-jp" |
| encoding-12.1 | `untriaged` | code 1: unknown encoding "iso8859-3" |
| encoding-12.2 | `untriaged` | code 1: unknown encoding "iso8859-3" |
| encoding-12.3 | `untriaged` | code 1: unknown encoding "shiftjis" |
| encoding-12.4 | `untriaged` | code 1: unknown encoding "jis0208" |
| encoding-12.5 | `untriaged` | code 1: unknown encoding "symbol" |
| encoding-13.1 | `untriaged` | code 1: unknown encoding "iso2022" |
| encoding-15.10 | `untriaged` | code 0: 2 5 efbfbdc3a9 |
| encoding-15.11 | `untriaged` | code 0: 2 5 efbfbdc3a9 |
| encoding-15.12 | `untriaged` | code 0: 2 4 efbfbd59 |
| encoding-15.13 | `untriaged` | code 0: 2 4 efbfbd59 |
| encoding-15.14 | `untriaged` | code 0: 1 3 efbfbd |
| encoding-15.15 | `untriaged` | code 0: 1 3 efbfbd |
| encoding-15.4 | `untriaged` | code 0: 6 í ½í¸ |
| encoding-15.5 | `untriaged` | code 0: 4 😂 |
| encoding-15.6 | `untriaged` | code 0: 12 efbfbdefbfbdefbfbdefbfbd |
| encoding-15.7 | `untriaged` | code 0: 3 9 efbfbdefbfbdefbfbd |
| encoding-15.8 | `untriaged` | code 0: 3 8 efbfbdefbfbdc3a9 |
| encoding-15.9 | `untriaged` | code 0: 3 7 efbfbdefbfbd58 |
| encoding-16.3 | `untriaged` | code 0: ��� ED |
| encoding-16.4 | `untriaged` | code 0: 䅁 |
| encoding-17.2 | `untriaged` | code 0: ýÿ |
| encoding-17.3 | `untriaged` | code 0: ýÿ |
| encoding-18.1 | `untriaged` | code 0: 1 {unknown encoding "jis0208"} |
| encoding-2.1 | `untriaged` | code 1: unknown encoding "jis0208" |
| encoding-28.0 | `untriaged` | code 2: 6 |
| encoding-3.1 | `untriaged` | code 1: unknown encoding "shiftjis" |
| encoding-3.2 | `untriaged` | code 0:  |
| encoding-5.1 | `untriaged` | code 1: unknown encoding "jis0208" |
| encoding-7.1 | `untriaged` | code 1: unknown encoding "jis0208" |
| encoding-7.2 | `untriaged` | code 1: unknown encoding "jis0208" |
| encoding-8.1 | `untriaged` | code 1: unknown encoding "shiftjis" |
| encoding-9.1 | `untriaged` | code 1: unknown encoding "jis0208" |
| encoding-9.2 | `untriaged` | code 1: unknown encoding "jis0208" |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 23 | `untriaged` |
| testencoding | 8 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| ucs2 | 2 | `platform`: a constraint of another platform or word size |
| testbytestring | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| teststringbytes | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### env.test

| Test | Bucket | Result (start) |
|---|---|---|
| env-1.1 | `untriaged` | code 1: can't read "env(test)": no such variable |
| env-1.3 | `untriaged` | code 0: 0 |
| env-2.2 | `untriaged` | code 0:  |
| env-2.3 | `untriaged` | code 0:  |
| env-2.4 | `untriaged` | code 0:  |
| env-3.1 | `untriaged` | code 0:  |
| env-4.1 | `untriaged` | code 0:  |
| env-4.3 | `untriaged` | code 0:  |
| env-4.4 | `untriaged` | code 0:  |
| env-4.5 | `untriaged` | code 0:  |
| env-5.2 | `untriaged` | code 1: can't unset "env": no such variable |
| env-5.3 | `untriaged` | code 1: can't read "env(THIS_SHOULD_EXIST)": no such element in array |
| env-5.4 | `untriaged` | code 1: can't read "env(THIS_SHOULD_EXIST)": no such element in array |
| env-7.2 | `untriaged` | code 1: can't read "::env(PATH)": no such element in array |

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 4 | `platform`: a constraint of another platform or word size |

### error.test

| Test | Bucket | Result (start) |
|---|---|---|
| error-1.3 | `untriaged` | code 0: wrong # args: should be "string index string charIndex"     while executing "st... |
| error-19.1 | `untriaged` | code 1: wrong # args to on clause: must be "... on code variableList script" |
| error-2.6 | `untriaged` | code 0: glorp2     while executing "error glorp2"     invoked from within "format [erro... |
| error-20.2 | `untriaged` | code 0: a b c |
| error-4.6 | `untriaged` | code 1: unknown or ambiguous subcommand "errorstack": must be args, body, cmdcount, com... |
| error-4.7 | `untriaged` | code 1: key "-errorstack" not known in dictionary |
| error-4.8 | `untriaged` | code 1: key "-errorstack" not known in dictionary |
| error-6.10 | `untriaged` | code 1: unknown or ambiguous subcommand "errorstack": must be args, body, cmdcount, com... |
| error-7.1 | `untriaged` | code 0: namespace |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 8 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### eval.test

| Test | Bucket | Result (start) |
|---|---|---|
| eval-2.5 | `untriaged` | code 0: test error     while executing "error "test error""     invoked from within "ev... |

### event.test

| Test | Bucket | Result (start) |
|---|---|---|
| event-7.5 | `untriaged` | code 0: hello     while executing "error hello"     ("after" script) |
| event-7.7 | `untriaged` | code 2: foo baz soom     (procedure "bgerror" line 1)     invoked from within "bgerror ... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testfilehandler | 22 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testexithandler | 5 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testfilewait | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### exec.test

| Test | Bucket | Result (start) |
|---|---|---|
| exec-11.5 | `untriaged` | code 0:  |
| exec-14.5 | `untriaged` | code 0: foo bar |
| exec-18.2 | `untriaged` | code 1: cat: '/foo[{blah': No such file or directory |
| exec-6.3 | `untriaged` | code 0: second msg |

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 5 | `platform`: a constraint of another platform or word size |
| nonPortable | 4 | `tcl`: tclsh skips it too |

### execute.test

| Test | Bucket | Result (start) |
|---|---|---|
| execute-10.3 | `untriaged` | code 0: 0 |
| execute-6.11 | `untriaged` | code 1: invalid command name "load" |
| execute-8.4 | `untriaged` | code 0: These differ: bar     while executing "error bar"     (procedure "foo" line 2) ... |
| execute-8.5 | `untriaged` | code 0: -code 1 -level 0 -errorcode NONE -errorinfo {FOO     while executing "error FOO... |
| execute-8.6 | `untriaged` | setup: can't find package tcltest 2.5 |
| execute-8.7 | `untriaged` | setup: can't find package tcltest 2.5 |

| Skipped by | Tests | Bucket |
|---|---|---|
| testobj | 77 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| longIs32bit | 3 | `platform`: a constraint of another platform or word size |

### expr-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| expr-old-32.48 | `untriaged` | code 0: 0.8653658439782821 |
| expr-old-32.50 | `untriaged` | code 0: 550 771 304 670 611 265 48 660 808 388 456 |
| expr-old-34.3 | `untriaged` | code 0: 1 {can't use non-numeric string as operand of "hypot"} |
| expr-old-36.1 | `untriaged` | code 1: invalid number "0o289" in expression "0o289" |
| expr-old-36.7 | `untriaged` | code 0: 0 NaN |
| expr-old-37.18 | `untriaged` | code 1: empty expression in expression "" |
| expr-old-37.20 | `untriaged` | code 1: expected floating-point number but got "100000000000000000000000000000000000000" |
| expr-old-37.22 | `untriaged` | code 1: expected floating-point number but got "179769313486231570000000000000000000000... |
| expr-old-37.24 | `untriaged` | code 1: expected floating-point number but got "179769313486231650000000000000000000000... |
| expr-old-37.25 | `untriaged` | code 0: 0 {This is a result: NaN} |
| expr-old-37.3 | `untriaged` | code 1: empty expression in expression "" |
| expr-old-38.2 | `untriaged` | code 1: empty expression in expression "" |

| Skipped by | Tests | Bucket |
|---|---|---|
| longIs32bit | 10 | `platform`: a constraint of another platform or word size |
| expr:!ieeeFloatingPoint | 3 | `platform`: needs a machine without IEEE floats |
| testmathfunctions | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### expr.test

| Test | Bucket | Result (start) |
|---|---|---|
| expr-22.5 | `untriaged` | code 0: 0 NaN |
| expr-29.1 | `untriaged` | code 0: 0 0x0000000000000001 0 0x0000000000000000 0 0x0000000000000000 |
| expr-29.2 | `untriaged` | code 0: 0 0x8000000000000001 0 0x8000000000000000 0 0x8000000000000000 |
| expr-38.11 | `untriaged` | code 0: 0 |
| expr-38.13 | `untriaged` | code 0: 0.0 |
| expr-39.1 | `untriaged` | code 0: 5 |
| expr-39.14 | `untriaged` | code 0: -2147483648 |
| expr-39.17 | `untriaged` | code 0: 5.0 |
| expr-39.19 | `untriaged` | code 0: 1e+17 |
| expr-39.2 | `untriaged` | code 0: 3 |
| expr-39.20 | `untriaged` | code 1: expected floating-point number but got "100000000000000000000000000000000000000" |
| expr-39.21 | `untriaged` | code 0: 1.7976931348623157e+308 |
| expr-39.22 | `untriaged` | code 1: expected floating-point number but got "179769313486231570000000000000000000000... |
| expr-39.23 | `untriaged` | code 0: Inf |
| expr-39.24 | `untriaged` | code 1: expected floating-point number but got "179769313486231650000000000000000000000... |
| expr-39.25 | `untriaged` | code 0: 0 NaN |
| expr-39.4 | `untriaged` | code 0: 3 |
| expr-39.8 | `untriaged` | code 0: -2147483648 |
| expr-45.8 | `untriaged` | code 0: 1 {can't use non-numeric floating-point value as operand of "entier"} |
| expr-45.9 | `untriaged` | code 0: 1 {can't use non-numeric floating-point value as operand of "entier"} |
| expr-47.2 | `untriaged` | code 0: 1 {can't use non-numeric string as operand of "isqrt"} |
| expr-47.3 | `untriaged` | code 0: 1 {can't use non-numeric floating-point value as operand of "isqrt"} |
| expr-50.1 | `untriaged` | code 0: 0 |
| expr-52.1 | `untriaged` | code 1: invalid command name "::tcl::unsupported::representation" |
| expr-8.17 | `untriaged` | code 0: 1 |
| expr-8.22 | `untriaged` | code 0: 1 |
| expr-8.23 | `untriaged` | code 0: 0 |

| Skipped by | Tests | Bucket |
|---|---|---|
| longIs32bit | 18 | `platform`: a constraint of another platform or word size |
| testmathfunctions | 11 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| expr:!ieeeFloatingPoint | 5 | `platform`: needs a machine without IEEE floats |

### fCmd.test

| Test | Bucket | Result (start) |
|---|---|---|
| fCmd-10.10 | `untriaged` | code 1: error copying "tf1": illegal operation on a directory |
| fCmd-10.11 | `untriaged` | code 1: error copying "tf1" to "": target file exists |
| fCmd-10.12 | `untriaged` | code 1: error renaming "tf1" to "": target file exists |
| fCmd-10.9 | `untriaged` | code 1: can't create directory "td1": file already exists |
| fCmd-11.4 | `untriaged` | setup: can't read "::env(HOME)": no such variable |
| fCmd-12.1 | `untriaged` | setup: can't read "::env(HOME)": no such variable |
| fCmd-12.2 | `untriaged` | setup: can't read "::env(HOME)": no such variable |
| fCmd-12.8 | `untriaged` | code 1: file attributes is not available |
| fCmd-13.5 | `untriaged` | setup: can't read "::env(HOME)": no such variable |
| fCmd-14.1 | `untriaged` | setup: can't read "::env(HOME)": no such variable |
| fCmd-14.2 | `untriaged` | setup: can't read "::env(HOME)": no such variable |
| fCmd-14.8 | `untriaged` | cleanup: file attributes is not available |
| fCmd-15.1 | `untriaged` | setup: can't read "::env(HOME)": no such variable |
| fCmd-15.4 | `untriaged` | cleanup: file attributes is not available |
| fCmd-16.6 | `untriaged` | setup: can't read "::env(HOME)": no such variable |
| fCmd-16.9 | `untriaged` | cleanup: file attributes is not available |
| fCmd-17.1 | `untriaged` | cleanup: file attributes is not available |
| fCmd-18.12 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-18.13 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-18.14 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-18.15 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-18.16 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-19.2 | `untriaged` | cleanup: file attributes is not available |
| fCmd-20.1 | `untriaged` | cleanup: file attributes is not available |
| fCmd-21.12 | `untriaged` | code 0: 0 1 1 |
| fCmd-21.7.2 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-21.8.2 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-21.9 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-26.1 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-26.2 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-26.3 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-27.3 | `untriaged` | code 1: file attributes is not available |
| fCmd-27.4 | `untriaged` | code 1: file attributes is not available |
| fCmd-27.5 | `untriaged` | code 1: file attributes is not available |
| fCmd-27.6 | `untriaged` | code 1: file attributes is not available |
| fCmd-28.1 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.10 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.10.1 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.11 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.12 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.13 | `untriaged` | setup: could not link: links are not available in the root folder |
| fCmd-28.15.2 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.16 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.17 | `untriaged` | setup: could not link: links are not available in the root folder |
| fCmd-28.18 | `untriaged` | setup: could not link: links are not available in the root folder |
| fCmd-28.2 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.20 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.21 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.22 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.3 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.4 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.5 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.7 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-28.9 | `untriaged` | code 1: could not link: links are not available in the root folder |
| fCmd-3.14 | `untriaged` | code 1: error renaming "~_totally_bogus_user": no such file or directory |
| fCmd-3.15 | `untriaged` | code 1: error renaming "/": permission denied |
| fCmd-3.16 | `untriaged` | code 1: error renaming "tf3" to "td1": target file exists |
| fCmd-3.3 | `untriaged` | code 1: error renaming "xyz": no such file or directory |
| fCmd-4.14 | `untriaged` | code 1: file attributes is not available |
| fCmd-4.4 | `untriaged` | code 0:  |
| fCmd-4.5 | `untriaged` | code 0:  |
| fCmd-5.12 | `untriaged` | code 1: file attributes is not available |
| fCmd-5.6 | `untriaged` | code 0:  |
| fCmd-5.7 | `untriaged` | code 1: couldn't open "~/tf1": no such file or directory |
| fCmd-6.10 | `untriaged` | code 1: error renaming "tf1" to "tf2": target file exists |
| fCmd-6.11 | `untriaged` | code 1: error renaming "tf1" to "tf2": target file exists |
| fCmd-6.13 | `untriaged` | code 1: error renaming "td1" to "td2": not a directory |
| fCmd-6.14 | `untriaged` | code 1: error renaming "tf1" to "td1": illegal operation on a directory |
| fCmd-6.16 | `untriaged` | code 1: error renaming "td2" to "td1": file already exists |
| fCmd-6.17 | `untriaged` | code 1: error renaming "/": permission denied |
| fCmd-6.18 | `untriaged` | code 1: error renaming "td2" to "td1": file already exists |
| fCmd-6.24 | `untriaged` | cleanup: file attributes is not available |
| fCmd-6.25 | `untriaged` | cleanup: file attributes is not available |
| fCmd-6.30 | `untriaged` | code 1: file attributes is not available |
| fCmd-7.5 | `untriaged` | code 1: no files matched glob pattern "--" |
| fCmd-8.2 | `untriaged` | code 0: 1 |
| fCmd-8.3 | `untriaged` | code 0:  |
| fCmd-9.1 | `untriaged` | code 1: file attributes is not available |
| fCmd-9.13 | `untriaged` | code 1: error renaming "td1" to "td2": file already exists |
| fCmd-9.14 | `untriaged` | code 0: td1 {1 {error renaming "td1" to "td1": invalid argument}} |
| fCmd-9.14.3 | `untriaged` | code 1: error renaming "../td1" to "../td1/foo": invalid argument |
| fCmd-9.15 | `untriaged` | code 1: error renaming "td1" to "tf1": not a directory |
| fCmd-9.16 | `untriaged` | code 1: error renaming "tf1" to "td1": illegal operation on a directory |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1 | `untriaged` |
| testchmod | 19 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| win | 11 | `platform`: a constraint of another platform or word size |
| xdev | 6 | `untriaged` |
| dontCopyLinks | 3 | `untriaged` |
| notNetworkFilesystem | 3 | `untriaged` |
| emptyTest | 2 | `tcl`: tclsh skips it too |
| knownBug | 1 | `tcl`: tclsh skips it too |
| nonPortable | 1 | `tcl`: tclsh skips it too |
| testsetplatform | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| winLessThan10 | 1 | `platform`: a constraint of another platform or word size |

### fileName.test

| Test | Bucket | Result (start) |
|---|---|---|
| fileName-20.10 | `untriaged` | code 0:  |
| fileName-20.6 | `untriaged` | setup: couldn't open "~/test": no such file or directory |
| fileName-20.8 | `untriaged` | code 0: ~test |
| fileName-20.9 | `untriaged` | setup: couldn't open "~/test": no such file or directory |
| filename-11.1 | `untriaged` | code 1: wrong # args: should be "glob ?switches? name ?name ...?" |
| filename-11.14 | `untriaged` | code 1: no files matched glob pattern "~/globTest" |
| filename-11.15 | `untriaged` | code 1: no files matched glob pattern "~\/globTest" |
| filename-11.17.2 | `untriaged` | code 1: could not link: links are not available in the root folder |
| filename-11.17.3 | `untriaged` | code 1: could not link: links are not available in the root folder |
| filename-11.17.4 | `untriaged` | code 1: could not link: links are not available in the root folder |
| filename-11.17.7 | `untriaged` | code 1: could not link: links are not available in the root folder |
| filename-11.17.8 | `untriaged` | code 1: could not link: links are not available in the root folder |
| filename-11.18 | `untriaged` | code 0: globTest/a1 globTest/a2 globTest/a3 globTest/nonexistent {globTest/weird name.c... |
| filename-11.19 | `untriaged` | code 0: globTest globTest |
| filename-11.20 | `untriaged` | code 1: bad option "-type": must be -directory, -join, -nocomplain, -path, -tails, -typ... |
| filename-11.21 | `untriaged` | code 1: bad option "-type": must be -directory, -join, -nocomplain, -path, -tails, -typ... |
| filename-11.21.1 | `untriaged` | code 1: no files matched glob pattern "*" |
| filename-11.22 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-11.23 | `untriaged` | code 1: unmatched open-brace in file name |
| filename-11.24 | `untriaged` | code 1: unmatched open-brace in file name |
| filename-11.25 | `untriaged` | code 1: bad option "-type": must be -directory, -join, -nocomplain, -path, -tails, -typ... |
| filename-11.25.1 | `untriaged` | code 1: bad option "-type": must be -directory, -join, -nocomplain, -path, -tails, -typ... |
| filename-11.25.2 | `untriaged` | code 1: bad option "-type": must be -directory, -join, -nocomplain, -path, -tails, -typ... |
| filename-11.26 | `untriaged` | code 1: bad option "-type": must be -directory, -join, -nocomplain, -path, -tails, -typ... |
| filename-11.27 | `untriaged` | code 1: no files matched glob pattern "*" |
| filename-11.28 | `untriaged` | code 1: no files matched glob pattern "*" |
| filename-11.29 | `untriaged` | code 1: no files matched glob pattern "*" |
| filename-11.3 | `untriaged` | code 1: bad option "-nocomplai": must be -directory, -join, -nocomplain, -path, -tails,... |
| filename-11.30 | `untriaged` | code 1: no files matched glob pattern "*" |
| filename-11.32 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-11.34 | `untriaged` | code 1: bad option "-direct": must be -directory, -join, -nocomplain, -path, -tails, -t... |
| filename-11.36 | `untriaged` | code 0: glob\[\{Test ~test.txt |
| filename-11.37 | `untriaged` | code 1: bad option "-type": must be -directory, -join, -nocomplain, -path, -tails, -typ... |
| filename-11.38 | `untriaged` | code 1: unmatched open-brace in file name |
| filename-11.39 | `untriaged` | code 1: unmatched open-brace in file name |
| filename-11.4 | `untriaged` | code 1: wrong # args: should be "glob ?switches? name ?name ...?" |
| filename-11.40 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-11.41 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-11.42 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-11.43 | `untriaged` | code 1: bad option "-t": must be -directory, -join, -nocomplain, -path, -tails, -types,... |
| filename-11.44 | `untriaged` | code 1: no files matched glob pattern "*" |
| filename-11.45 | `untriaged` | code 0: {} {all.tcl httpTest.tcl httpTestScript.tcl httpd httpd11.tcl internals.tcl pkg... |
| filename-11.46 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-11.47 | `untriaged` | code 1: no files matched glob pattern "*" |
| filename-11.48 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-11.49 | `untriaged` | code 1: no files matched glob pattern "*" |
| filename-11.5 | `untriaged` | code 0: all.tcl httpTest.tcl httpTestScript.tcl httpd httpd11.tcl internals.tcl pkgInde... |
| filename-11.50 | `untriaged` | code 1: no files matched glob pattern "*" |
| filename-11.51 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-11.6 | `untriaged` | code 1: no files matched glob pattern "~xyqrszzz" |
| filename-12.1 | `untriaged` | code 0: {} |
| filename-12.1.2 | `untriaged` | code 0: {} |
| filename-12.1.3 | `untriaged` | code 1: no files matched glob pattern "" |
| filename-12.5 | `untriaged` | code 1: no files matched glob pattern "globTest\/x1.c" |
| filename-12.6 | `untriaged` | code 1: no files matched glob pattern "globTest\/\x1.c" |
| filename-12.8 | `untriaged` | code 1: bad option "-type": must be -directory, -join, -nocomplain, -path, -tails, -typ... |
| filename-13.1 | `untriaged` | code 0: globTest |
| filename-13.11 | `untriaged` | code 0: globTest/x1.c globTest/x1.c globTest/z1.c globTest/z1.c |
| filename-13.3 | `untriaged` | code 1: no files matched glob pattern "globTest/{\}" |
| filename-13.5 | `untriaged` | code 1: no files matched glob pattern "globTest/}" |
| filename-14.15 | `untriaged` | code 0: globTest/a1 globTest/a2 globTest/a3 globTest/nonexistent {globTest/weird name.c... |
| filename-14.17 | `untriaged` | code 1: no files matched glob pattern "~/z*" |
| filename-14.22 | `untriaged` | code 1: no files matched glob pattern "goo/*" |
| filename-14.25 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-14.26 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filename-14.30 | `untriaged` | code 0: globTest/a1 |
| filename-14.7 | `untriaged` | code 0: globTest/a1 globTest/a2 globTest/a3 globTest/nonexistent {globTest/weird name.c... |
| filename-14.9 | `untriaged` | code 0: globTest/.1 |
| filename-15.4.1 | `untriaged` | code 0: 0 {} 0 {} |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 5 | `untriaged` |
| testsetplatform | 133 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| win | 35 | `platform`: a constraint of another platform or word size |
| nonPortable | 7 | `tcl`: tclsh skips it too |
| testtranslatefilename | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### fileSystem.test

| Test | Bucket | Result (start) |
|---|---|---|
| filesystem-1.12 | `untriaged` | code 1: bad option "-type": must be -directory, -join, -nocomplain, -path, -tails, -typ... |
| filesystem-1.30 | `untriaged` | code 0: /~noonewiththisname |
| filesystem-1.30.2 | `untriaged` | code 0: /~nonexistentuser@nonexistentdomain |
| filesystem-1.30.3 | `untriaged` | setup: can't read "::env(HOME)": no such variable |
| filesystem-1.34 | `untriaged` | code 0: /foo/bar/anc/.tml |
| filesystem-1.35a | `untriaged` | code 0: /ffo/bar/anc/foo/.tml |
| filesystem-1.36a | `untriaged` | code 0: /foo/bar/anc/asdasd/.tml |
| filesystem-1.45 | `untriaged` | code 1: couldn't access "/xxx/../../bar": permission denied |
| filesystem-1.47 | `untriaged` | code 1: couldn't access "/..": permission denied |
| filesystem-1.48 | `untriaged` | code 1: couldn't access "/../": permission denied |
| filesystem-1.51 | `untriaged` | code 1: couldn't access "/../..": permission denied |
| filesystem-1.51.1 | `untriaged` | code 1: couldn't access "/../../": permission denied |
| filesystem-1.53 | `untriaged` | code 1: bad option "-dir": must be -directory, -join, -nocomplain, -path, -tails, -type... |
| filesystem-6.1 | `untriaged` | code 0: file6 |
| filesystem-6.11 | `untriaged` | code 0: 1 |
| filesystem-6.14 | `untriaged` | code 1: could not link: links are not available in the root folder |
| filesystem-6.15 | `untriaged` | code 0:  |
| filesystem-6.16 | `untriaged` | code 0: 1795742250 |
| filesystem-6.17 | `untriaged` | code 1: file mtime with a new time is not available |
| filesystem-6.18 | `untriaged` | code 0:  |
| filesystem-6.2 | `untriaged` | code 0:  |
| filesystem-6.20 | `untriaged` | code 0: / |
| filesystem-6.21 | `untriaged` | code 0: 1 |
| filesystem-6.23 | `untriaged` | code 0: 1 |
| filesystem-6.24 | `untriaged` | code 1: could not readlink: links are not available in the root folder |
| filesystem-6.25 | `untriaged` | code 1: error renaming "" to "": target file exists |
| filesystem-6.27 | `untriaged` | code 0: / |
| filesystem-6.28 | `untriaged` | code 0: 260 |
| filesystem-6.3 | `untriaged` | code 0: 1795742250 |
| filesystem-6.30 | `untriaged` | code 0: native root |
| filesystem-6.32 | `untriaged` | code 0: directory |
| filesystem-6.33 | `untriaged` | code 0: 1 |
| filesystem-6.34 | `untriaged` | code 0: 1 {couldn't open "foo": permission denied} |
| filesystem-6.4 | `untriaged` | code 1: file attributes is not available |
| filesystem-6.5 | `untriaged` | code 1: error copying "" to "": target file exists |
| filesystem-6.6 | `untriaged` | code 1: error deleting "": permission denied |
| filesystem-6.8 | `untriaged` | code 0: 1 |
| filesystem-6.9 | `untriaged` | code 0: 1 |
| filesystem-9.7 | `untriaged` | code 0: 1 0 ~testNotExist ~testNotExist 1 0 ~testNotExist 0 ~testNotExist |
| filesystem-9.8 | `untriaged` | code 0: ~testNotExist ~testNotExist 0 ~testNotExist 0 ~testNotExist |
| filesystem-9.9 | `untriaged` | code 0: 0 1 0 1 1 |

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 21 | `platform`: a constraint of another platform or word size |
| hasLinks | 16 | `untriaged` |
| testsimplefilesystem | 10 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testfilesystem | 9 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testsetplatform | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### fileSystemEncoding.test

| Test | Bucket | Result (start) |
|---|---|---|
| filesystemEncoding-1.0 | `untriaged` | code 2: 1 1 |

### for.test

| Test | Bucket | Result (start) |
|---|---|---|
| for-6.13 | `untriaged` | code 0: wrong # args: should be "set varName ?newValue?"     while executing "set"     ... |
| for-6.6 | `untriaged` | code 0: 1 {wrong # args: should be "set varName ?newValue?"} {wrong # args: should be "... |
| for-6.9 | `untriaged` | code 0: wrong # args: should be "set varName ?newValue?"     while executing "set"     ... |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 24 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### foreach.test

| Test | Bucket | Result (start) |
|---|---|---|
| foreach-1.14 | `untriaged` | code 0: 1 {can't set "a": variable is array} {can't set "a": variable is array     whil... |
| foreach-9.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |

### format.test

| Test | Bucket | Result (start) |
|---|---|---|
| format-19.4.2 | `untriaged` | code 0:                                                                                ... |
| format-20.1 | `untriaged` | code 1: invalid command name "tcl::unsupported::representation" |

| Skipped by | Tests | Bucket |
|---|---|---|
| longIs32bit | 7 | `platform`: a constraint of another platform or word size |
| wideBiggerThanInt | 2 | `platform`: a constraint of another platform or word size |

### get.test

| Test | Bucket | Result (start) |
|---|---|---|
| get-3.2 | `untriaged` | code 0: 0 1 0 1 0 1 0 -1 1 {expected floating-point number but got "-+1.0"} 0 -1 1 {exp... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testgetint | 15 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testdoubleobj | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### history.test

| Skipped by | Tests | Bucket |
|---|---|---|
| history | 62 | `feature`: the 'history' command |

### http.test

| Test | Bucket | Result (start) |
|---|---|---|
| http-1.1 | `untriaged` | code 1: invalid command name "http::config" |
| http-1.2 | `untriaged` | code 1: invalid command name "http::config" |
| http-1.4 | `untriaged` | code 1: invalid command name "http::config" |
| http-1.5 | `untriaged` | code 1: invalid command name "http::config" |
| http-1.6 | `untriaged` | setup: invalid command name "http::config" |
| http-2.1 | `untriaged` | code 0: 1 |
| http-3.1 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.10 | `untriaged` | cleanup: can't read "t": no such variable |
| http-3.11 | `untriaged` | cleanup: can't read "t": no such variable |
| http-3.14 | `untriaged` | cleanup: can't read "token": no such variable |
| http-3.15 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.16 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.17 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.18 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.19 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.2 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.20 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.21 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.22 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.23 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.24 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.25 | `untriaged` | cleanup: can't read "token": no such variable |
| http-3.26 | `untriaged` | cleanup: can't read "token": no such variable |
| http-3.27 | `untriaged` | cleanup: can't read "token": no such variable |
| http-3.28 | `untriaged` | cleanup: can't read "token": no such variable |
| http-3.29 | `untriaged` | code 0: 1 |
| http-3.3 | `untriaged` | cleanup: can't read "token": no such variable |
| http-3.30 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.31 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.32 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-3.33 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-3.4 | `untriaged` | cleanup: can't read "token": no such variable |
| http-3.5 | `untriaged` | cleanup: invalid command name "http::config" |
| http-3.6 | `untriaged` | cleanup: invalid command name "http::config" |
| http-3.7 | `untriaged` | cleanup: can't read "token": no such variable |
| http-3.8 | `untriaged` | cleanup: can't read "token": no such variable |
| http-3.9 | `untriaged` | cleanup: can't read "token": no such variable |
| http-4.1 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.10 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.11 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.12 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.13 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.14 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-4.15 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-4.16 | `untriaged` | code 1: invalid command name "http::geturl" |
| http-4.2 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.3 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.4 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.5 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.6 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.7 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.8 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-4.9 | `untriaged` | cleanup: invalid command name "http::cleanup" |
| http-5.1 | `untriaged` | code 1: invalid command name "http::formatQuery" |
| http-5.3 | `untriaged` | code 1: invalid command name "http::formatQuery" |
| http-5.4 | `untriaged` | code 1: invalid command name "http::formatQuery" |
| http-5.5 | `untriaged` | code 1: invalid command name "http::config" |
| http-6.1 | `untriaged` | cleanup: invalid command name "http::config" |
| http-7.1 | `untriaged` | code 1: invalid command name "http::mapReply" |
| http-7.2 | `untriaged` | code 1: invalid command name "http::mapReply" |
| http-7.3 | `untriaged` | setup: invalid command name "http::config" |
| http-7.4 | `untriaged` | setup: invalid command name "http::config" |

| Skipped by | Tests | Bucket |
|---|---|---|
| http2.9.7 | 7 | `feature`: the 'http' package |
| http2.9.8 | 2 | `feature`: the 'http' package |
| knownBug | 1 | `tcl`: tclsh skips it too |
| nonPortable | 1 | `tcl`: tclsh skips it too |

### http11.test

| Test | Bucket | Result (start) |
|---|---|---|
| http11-1.0 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.1 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.10 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.11 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.12 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.13 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.2 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.3 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.4 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.5 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.6 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.7 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.8 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-1.9 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.0 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.1 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.10 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.11 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.12 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.2 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.3 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.4 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.4.1 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.5 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.6 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.7 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.8 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-2.9 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.0 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.1 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.2 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.3 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.4 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.5 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.6 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.7 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.8 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-3.9 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-4.0 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-4.1 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-4.2 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |
| http11-4.3 | `untriaged` | setup: can't wait for variable "httpd_output": would wait forever |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 1 | `tcl`: tclsh skips it too |

### httpPipeline.test

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1996 | `untriaged` |

### httpold.test

| Test | Bucket | Result (start) |
|---|---|---|
| httpold-1.1 | `untriaged` | code 1: invalid command name "http_config" |
| httpold-1.2 | `untriaged` | code 1: invalid command name "http_config" |
| httpold-1.4 | `untriaged` | code 1: invalid command name "http_config" |
| httpold-2.1 | `untriaged` | code 0: 1 |
| httpold-3.2 | `untriaged` | code 0: invalid command name "http_get" |
| httpold-3.3 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-3.4 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-3.5 | `untriaged` | code 1: invalid command name "http_config" |
| httpold-3.6 | `untriaged` | code 1: invalid command name "http_config" |
| httpold-3.7 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-3.8 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-3.9 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.1 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.10 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.11 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.12 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.2 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.3 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.4 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.5 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.6 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.7 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.8 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-4.9 | `untriaged` | code 1: invalid command name "http_get" |
| httpold-5.1 | `untriaged` | code 1: invalid command name "http_formatQuery" |
| httpold-5.2 | `untriaged` | code 1: invalid command name "http_formatQuery" |
| httpold-5.3 | `untriaged` | code 1: invalid command name "http_formatQuery" |
| httpold-6.1 | `untriaged` | code 1: invalid command name "http_config" |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1 | `untriaged` |

### incr-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| incr-old-2.5 | `untriaged` | code 0: 1 {expected integer but got "1a"} {expected integer but got "1a"     while exec... |
| incr-old-2.6 | `untriaged` | code 0: 1 {can't set "x": variable is read-only} {can't set "x": variable is read-only ... |

### incr.test

| Test | Bucket | Result (start) |
|---|---|---|
| incr-1.28 | `untriaged` | code 0: 1 {can't set "x": variable is read-only} {can't set "x": variable is read-only ... |
| incr-2.28 | `untriaged` | code 0: 1 {can't set "x": variable is read-only} {can't set "x": variable is read-only ... |
| incr-2.30 | `untriaged` | code 0: 1 {expected integer but got "1a"} {expected integer but got "1a"     while exec... |
| incr-2.31 | `untriaged` | code 0: 1 {expected integer but got "1a"} {expected integer but got "1a"     while exec... |

### indexObj.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testindexobj | 33 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testparseargs | 12 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### info.test

| Test | Bucket | Result (start) |
|---|---|---|
| info-14.3 | `untriaged` | code 1: can't read "::tcl_patchLevel": no such variable |
| info-16.2 | `untriaged` | code 0:  |
| info-16.3 | `untriaged` | code 0: /gorp.info {} |
| info-16.4 | `untriaged` | code 0:  |
| info-16.5 | `untriaged` | code 0:  |
| info-16.6 | `untriaged` | code 0: {} newname.txt {} |
| info-16.7 | `untriaged` | code 0: /gorp.info newname.txt {} |
| info-16.8 | `untriaged` | code 0: {/gorp.info foo.bar} {} |
| info-18.3 | `untriaged` | code 1: can't read "::tcl_version": no such variable |
| info-19.7 | `untriaged` | code 0: 0 |
| info-19.8 | `untriaged` | code 0:  |
| info-19.9 | `untriaged` | code 0:  |
| info-21.2 | `untriaged` | code 1: unknown or ambiguous subcommand "gorp": must be args, body, cmdcount, commands,... |
| info-21.3 | `untriaged` | code 1: unknown or ambiguous subcommand "c": must be args, body, cmdcount, commands, co... |
| info-21.4 | `untriaged` | code 1: unknown or ambiguous subcommand "l": must be args, body, cmdcount, commands, co... |
| info-21.5 | `untriaged` | code 1: unknown or ambiguous subcommand "s": must be args, body, cmdcount, commands, co... |
| info-22.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-22.1 | `untriaged` | code 0: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-22.2 | `untriaged` | code 0: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-22.3 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-22.4 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-22.5 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-22.6 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-22.7 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-22.8 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-23.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-23.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-23.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-23.3 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-23.4 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-23.5 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-23.6 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.3 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.4 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.5 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.6.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.6.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.6.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.7 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.8 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-24.9 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-25.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-25.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-3.1 | `untriaged` | code 0: 3 |
| info-3.2 | `untriaged` | code 0: 3 |
| info-3.3 | `untriaged` | code 0: 3 |
| info-30.0 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-30.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.10 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-30.11 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-30.12 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-30.13 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-30.14 | `untriaged` | code 1: interpreter named "sub" already exists, cannot create |
| info-30.15 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.16 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.17 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.18 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.19 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.20 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.21 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.22 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.23 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.24 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.25 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.26 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.27 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.28 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.29 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.3 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.30 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.31 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.32 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.33 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.34 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.35 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.36 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.37 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.38 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.39 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.4 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-30.40 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.41 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.42 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.43 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.44 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.45 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.46 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.47 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.48 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.5 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-30.6 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-30.7 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-30.8 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-30.9 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-31.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-31.1 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-31.1a | `untriaged` | cleanup: can't unset "res": no such variable |
| info-31.2 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-31.4 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-31.5 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-31.6 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-31.7 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-32.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.10 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.11 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.12 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.13 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.14 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.15 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.16 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.17 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.18 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.19 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.20 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.21 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.22 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.23 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.24 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.25 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.26 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.27 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.28 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.29 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.2a | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.3 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.30 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.31 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.32 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.33 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.34 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.35 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.3a | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.4 | `untriaged` | code 1: dict element in quotes followed by ":" instead of space |
| info-33.5 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.6 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.7 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.8 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-33.9 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-34.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-34.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-35.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-35.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-36.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-36.1.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-36.1.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-37.0 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-38.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-38.2 | `untriaged` | setup: bad option "debug": must be alias, aliases, children, create, delete, eval, exis... |
| info-38.3 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-38.4 | `untriaged` | setup: bad option "debug": must be alias, aliases, children, create, delete, eval, exis... |
| info-38.5 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-38.6 | `untriaged` | setup: interpreter named "sub" already exists, cannot create |
| info-38.7 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-39.0 | `untriaged` | cleanup: can't unset "res": no such variable |
| info-39.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-39.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-41.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| info-8.4 | `untriaged` | code 0: x {} {} {} {} |
| info-8.5 | `untriaged` | code 1: invalid command name "-setup" |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 3 | `tcl`: tclsh skips it too |

### init.test

| Test | Bucket | Result (start) |
|---|---|---|
| init-0.1 | `untriaged` | code 0: 1 {} 1 NONE |
| init-0.2 | `untriaged` | code 0: 1 0 0 |
| init-1.1 | `untriaged` | code 1: invalid command name "auto_qualify" |
| init-1.2 | `untriaged` | code 1: invalid command name "auto_qualify" |
| init-1.3 | `untriaged` | code 1: invalid command name "auto_qualify" |
| init-1.4 | `untriaged` | code 1: invalid command name "auto_qualify" |
| init-1.5 | `untriaged` | code 1: invalid command name "auto_qualify" |
| init-1.6 | `untriaged` | code 1: invalid command name "auto_qualify" |
| init-1.7 | `untriaged` | code 1: invalid command name "auto_qualify" |
| init-1.8 | `untriaged` | code 1: invalid command name "auto_qualify" |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 14 | `untriaged` |

### interp.test

| Test | Bucket | Result (start) |
|---|---|---|
| interp-1.2 | `untriaged` | code 1: bad option "frobox": must be alias, aliases, children, create, delete, eval, ex... |
| interp-1.7 | `untriaged` | code 1: bad option "hello": must be alias, aliases, children, create, delete, eval, exi... |
| interp-1.8 | `untriaged` | code 1: bad option "-froboz": must be alias, aliases, children, create, delete, eval, e... |
| interp-1.9 | `untriaged` | code 1: bad option "-froboz": must be alias, aliases, children, create, delete, eval, e... |
| interp-11.4 | `untriaged` | code 1: target interpreter for alias "xcommand" in path "x1 x2 x3" is not my descendant |
| interp-13.4 | `untriaged` | code 0: 0 0 |
| interp-14.11 | `untriaged` | setup: bad option "-199990189": must be -safe or -- |
| interp-14.4 | `untriaged` | code 0: 0 a a |
| interp-14.5 | `untriaged` | code 0: wrong # args: should be "setx x"     while executing "a 1 2" |
| interp-14.6 | `untriaged` | code 0: wrong # args: should be "setx x"     invoked from within "a 1 2"     invoked fr... |
| interp-14.7 | `untriaged` | code 0: wrong # args: should be "setx x"     invoked from within "a 1 2" |
| interp-15.1 | `untriaged` | code 1: can not find channel named "stdout" |
| interp-15.2 | `untriaged` | code 1: bad option "share": must be alias, aliases, children, create, delete, eval, exi... |
| interp-15.3 | `untriaged` | code 0: 0 {} |
| interp-15.4 | `untriaged` | code 1: bad option "share": must be alias, aliases, children, create, delete, eval, exi... |
| interp-15.5 | `untriaged` | code 1: bad option "share": must be alias, aliases, children, create, delete, eval, exi... |
| interp-15.6 | `untriaged` | code 1: bad option "share": must be alias, aliases, children, create, delete, eval, exi... |
| interp-15.7 | `untriaged` | code 1: bad option "transfer": must be alias, aliases, children, create, delete, eval, ... |
| interp-15.8 | `untriaged` | code 1: bad option "transfer": must be alias, aliases, children, create, delete, eval, ... |
| interp-17.1 | `untriaged` | code 0: 0 a |
| interp-17.2 | `untriaged` | code 0: 0 loop |
| interp-17.3 | `untriaged` | code 0: 0 b |
| interp-17.4 | `untriaged` | code 0: 0 {} |
| interp-17.5 | `untriaged` | code 0: 0 {} |
| interp-17.6 | `untriaged` | code 0: 0 {} |
| interp-18.10 | `untriaged` | code 0: 0 5 |
| interp-18.7 | `untriaged` | code 0: 0 {} |
| interp-18.8 | `untriaged` | code 0: 0 {} |
| interp-18.9 | `untriaged` | code 0: 0 5 |
| interp-19.2 | `untriaged` | code 0:  |
| interp-19.6 | `untriaged` | code 0: zop foo |
| interp-19.7 | `untriaged` | code 0: blotz |
| interp-19.8 | `untriaged` | code 0: blotz blotz |
| interp-19.9 | `untriaged` | code 1: invalid command name "foo" |
| interp-20.23 | `untriaged` | code 0: 1 {invalid command name "interp"} |
| interp-20.24 | `untriaged` | code 0: 1 {invalid command name "interp"} |
| interp-20.28 | `untriaged` | code 0: 0 {} 1 {invalid command name "interp"} |
| interp-20.29 | `untriaged` | code 0: 0 {} 1 {invalid command name "interp"} |
| interp-20.30 | `untriaged` | code 0: 0 {} 1 {invalid command name "interp"} |
| interp-20.32 | `untriaged` | code 0: 1 {invalid command name "interp"} |
| interp-20.33 | `untriaged` | code 0: 1 {invalid command name "interp"} 0 {a b c} |
| interp-20.34 | `untriaged` | code 0: 1 {invalid command name "interp"} 0 {a b c} |
| interp-20.38 | `untriaged` | code 0: 1 {unknown hidden command "-global"} |
| interp-20.39 | `untriaged` | code 0: 1 {unknown hidden command "-global"} |
| interp-20.43 | `untriaged` | code 0: 1 {unknown hidden command "-global"} |
| interp-20.44 | `untriaged` | code 0: 1 {unknown hidden command "-global"} |
| interp-20.45 | `untriaged` | code 0: 0 {} |
| interp-20.46 | `untriaged` | code 0: 0 {} |
| interp-20.47 | `untriaged` | code 0: 0 {} |
| interp-20.48 | `untriaged` | code 0: 0 {} |
| interp-20.49 | `untriaged` | code 1: unknown hidden command "-namespace" |
| interp-20.50.1 | `untriaged` | code 0: wrong # args: should be "coroutine name cmd ?arg ...?"     invoked from within ... |
| interp-21.5 | `untriaged` | code 0:  |
| interp-21.8 | `untriaged` | code 0:  |
| interp-22.5 | `untriaged` | code 0: invalid command name "interp" |
| interp-23.1 | `untriaged` | code 0: {} bar {} {} bar {} bar |
| interp-23.2 | `untriaged` | code 0: {} bar {} {} bar {} bar |
| interp-24.10 | `untriaged` | code 0: 1 {invalid command name "interp"} 1 {invalid command name "interp"} |
| interp-24.12 | `untriaged` | code 0: 1 {invalid command name "interp"} 1 {invalid command name "interp"} |
| interp-26.1 | `untriaged` | code 0: 1 0 1 1 1 1 1 |
| interp-26.2 | `untriaged` | code 0: 1 {bad completion code "-1": must be ok, error, return, break, continue, or an ... |
| interp-26.3 | `untriaged` | code 0: 1 0 1 2 3 4 5 |
| interp-26.5 | `untriaged` | code 2: 1 {bad completion code "-1": must be ok, error, return, break, continue, or an ... |
| interp-29.1.1 | `untriaged` | code 0: 0 600 |
| interp-29.1.12 | `untriaged` | code 0: 1 {the recursion limit of this interpre} |
| interp-29.1.3 | `untriaged` | code 0: 1 {could not find interpreter "foo"} |
| interp-29.1.7 | `untriaged` | code 0: 1 {the recursion limit of this interpre} |
| interp-29.1.8 | `untriaged` | code 0: 1 {wrong # args: should be "interp recursionlimit path ?newlimit?"} |
| interp-29.2.1 | `untriaged` | code 0: 600 |
| interp-29.2.2 | `untriaged` | code 0: 600 |
| interp-29.2.3 | `untriaged` | code 0: 600 |
| interp-29.3.10b | `untriaged` | code 0: 0 ok |
| interp-29.3.11b | `untriaged` | code 0: 0 ok |
| interp-29.3.4 | `untriaged` | code 0: 0 ok |
| interp-29.3.5 | `untriaged` | code 0: 0 ok |
| interp-29.3.7c | `untriaged` | code 0: 0 ok |
| interp-29.3.8b | `untriaged` | code 0: 0 ok |
| interp-29.4.1 | `untriaged` | code 0: 599 |
| interp-29.4.2 | `untriaged` | code 0: 599 |
| interp-29.5.1 | `untriaged` | code 1: the recursion limit of this interpreter is 600 |
| interp-29.5.2 | `untriaged` | code 1: the recursion limit of this interpreter is 600 |
| interp-29.5.3 | `untriaged` | code 1: the recursion limit of this interpreter is 600 |
| interp-29.5.4 | `untriaged` | code 1: the recursion limit of this interpreter is 600 |
| interp-29.6.1 | `untriaged` | code 0: 600 |
| interp-29.6.10 | `untriaged` | code 1: interpreter named "child" already exists, cannot create |
| interp-29.6.2 | `untriaged` | code 0: 600 |
| interp-29.6.8 | `untriaged` | code 0: 1 {invalid command name "interp"} |
| interp-29.6.9 | `untriaged` | code 1: invalid command name "interp" |
| interp-34.1 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.10 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.11 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.12 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.13 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.14 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.2 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.3 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.3.1 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.4 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.5 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.6 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.7 | `untriaged` | code 1: bad option "limit": must be alias, aliases, eval, expose, hide, hidden, invokeh... |
| interp-34.8 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-34.9 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.1 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.10 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.11 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.12 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.13 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.14 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.15 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.16 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.17 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.18 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.19 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.2 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.20 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.21 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.22 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.23 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.24 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.3 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.4 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.5 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.6 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.7 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.8 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-35.9 | `untriaged` | code 1: bad option "limit": must be alias, aliases, children, create, delete, eval, exi... |
| interp-36.1 | `untriaged` | code 0: ::tcl::Bgerror |
| interp-36.3 | `untriaged` | setup: interpreter named "child" already exists, cannot create |
| interp-36.4 | `untriaged` | code 1: unmatched open brace in list |
| interp-38.1 | `untriaged` | setup: bad option "debug": must be alias, aliases, children, create, delete, eval, exis... |
| interp-38.2 | `untriaged` | code 1: bad option "debug": must be alias, aliases, children, create, delete, eval, exi... |
| interp-38.3 | `untriaged` | code 1: bad option "debug": must be alias, aliases, children, create, delete, eval, exi... |
| interp-38.4 | `untriaged` | code 1: bad option "debug": must be alias, aliases, children, create, delete, eval, exi... |
| interp-38.5 | `untriaged` | code 1: bad option "debug": must be alias, aliases, children, create, delete, eval, exi... |
| interp-38.6 | `untriaged` | code 1: bad option "debug": must be alias, aliases, children, create, delete, eval, exi... |
| interp-38.7 | `untriaged` | code 1: bad option "debug": must be alias, aliases, children, create, delete, eval, exi... |
| interp-38.8 | `untriaged` | code 1: bad option "debug": must be alias, aliases, children, create, delete, eval, exi... |
| interp-7.6 | `untriaged` | code 0: bar foo |
| interp-8.3 | `untriaged` | code 1: wrong # args: should be "interp alias childPath childCmd ?targetPath targetCmd ... |
| interp-9.4 | `untriaged` | code 0: GLOBAL NAMESPACE |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 7 | `tcl`: tclsh skips it too |
| testinterpdelete | 6 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### io.test

| Test | Bucket | Result (start) |
|---|---|---|
| io-1.6 | `untriaged` | code 0: a9 |
| io-1.7 | `untriaged` | code 1: unknown encoding "shiftjis" |
| io-1.8 | `untriaged` | code 1: unknown encoding "iso2022-jp" |
| io-1.9 | `untriaged` | code 1: unknown encoding "iso2022-jp" |
| io-11.4 | `untriaged` | code 0: {abcdefghijklmnopqrstuvwxyz } 1 {} 1 |
| io-12.6 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| io-12.7 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| io-13.11 | `untriaged` | code 0: abcd defgh |
| io-13.12 | `untriaged` | code 0:    ab  def    |
| io-13.8.1 | `untriaged` | code 0: {abcd } { def} |
| io-13.8.2 | `untriaged` | code 0: {abcd } { def} |
| io-13.8.3 | `untriaged` | code 0: {abcd } {  def} |
| io-14.2 | `untriaged` | code 0: {} {} {} |
| io-14.3 | `untriaged` | code 1: child process exited abnormally |
| io-14.4 | `untriaged` | code 1: child process exited abnormally |
| io-14.5 | `untriaged` | code 1: can not find channel named "stdin" |
| io-14.6 | `untriaged` | code 1: interpreter named "z" already exists, cannot create |
| io-14.7 | `untriaged` | code 1: interpreter named "z" already exists, cannot create |
| io-14.8 | `untriaged` | code 0:  |
| io-19.1 | `untriaged` | code 1: can not find channel named "stdin" |
| io-2.2 | `untriaged` | code 0: {} {123456789012345  12} |
| io-2.4 | `untriaged` | code 0: {abcdefg hijklmnopqrstuvwxyz} {abcdefg hijklmnopqrstuvwxyz} |
| io-20.1 | `untriaged` | code 0: utf-8 |
| io-20.3 | `untriaged` | code 0: {} {auto lf} |
| io-20.5 | `untriaged` | code 0:  |
| io-27.4 | `untriaged` | code 0: 0 0 72 |
| io-27.5 | `untriaged` | code 0: 0 0 72 |
| io-28.2 | `untriaged` | code 1: bad option "share": must be alias, aliases, children, create, delete, eval, exi... |
| io-29.1 | `untriaged` | code 0: 1 {can not find channel named "stdin"} |
| io-29.20 | `untriaged` | code 0: 0 0 12600 |
| io-29.27 | `untriaged` | code 0: 1 {error writing "": broken pipe} {posix epipe {broken pipe}} |
| io-29.35 | `untriaged` | code 1: bad option "share": must be alias, aliases, children, create, delete, eval, exi... |
| io-29.36.2 | `untriaged` | code 0: {<1 line>} {<2 line>} <> {<3 line>} {<1 line>} {<2 line>} {<3 line>} {<1 line>}... |
| io-29.9 | `untriaged` | code 0: 1 {can not find channel named "stdin"} |
| io-3.1 | `untriaged` | code 1: unknown encoding "ascii" |
| io-3.2 | `untriaged` | code 1: unknown encoding "ascii" |
| io-3.3 | `untriaged` | code 1: unknown encoding "ascii" |
| io-3.4 | `untriaged` | code 1: unknown encoding "jis0208" |
| io-3.5 | `untriaged` | code 1: unknown encoding "jis0208" |
| io-3.6 | `untriaged` | code 1: unknown encoding "shiftjis" |
| io-3.7 | `untriaged` | code 1: unknown encoding "jis0208" |
| io-3.8 | `untriaged` | code 1: unknown encoding "ascii" |
| io-30.16 | `untriaged` | code 0: hello there and here  |
| io-30.18 | `untriaged` | code 0: abc def 0 ghi 0 qrs 0 |
| io-30.19 | `untriaged` | code 0: abc def 0 ghi 0 qrs 0 |
| io-30.21 | `untriaged` | code 0: -1 0 def 0 |
| io-30.22 | `untriaged` | code 0: -1 0 def 0 |
| io-30.23 | `untriaged` | code 0: 17 1 |
| io-30.24 | `untriaged` | code 0: 17 1 |
| io-30.25 | `untriaged` | code 0: 17 1 |
| io-30.26 | `untriaged` | code 0: 17 1 |
| io-30.27 | `untriaged` | code 0: 17 1 |
| io-30.28 | `untriaged` | code 0: 17 1 |
| io-31.11 | `untriaged` | code 0: hello 6 cr 0 0 7 cr 0 |
| io-31.13 | `untriaged` | code 0: binary |
| io-31.18 | `untriaged` | code 0: hello there and here 0  0 |
| io-31.20 | `untriaged` | code 0: abc def 0 qrs 0 |
| io-31.21 | `untriaged` | code 0: abc def 0 qrs 0 |
| io-31.25 | `untriaged` | code 0: abc def 0 qrs 0 |
| io-31.26 | `untriaged` | code 0: abc def 0 qrs 0 |
| io-31.27 | `untriaged` | code 0: abc def 0 qrs 0 |
| io-31.28 | `untriaged` | code 0: abc def 0 qrs 0 |
| io-31.29 | `untriaged` | code 0: abc def 0 qrs 0 |
| io-31.30 | `untriaged` | code 0: abc def 0 qrs 0 |
| io-31.5 | `untriaged` | code 0: 5 6 cr 0 there 12 cr 0 |
| io-31.6 | `untriaged` | code 0: 5 6 crlf 0 there 12 crlf 0 |
| io-32.1 | `untriaged` | code 0: 1 {can not find channel named "stdout"} |
| io-32.11.1 | `untriaged` | code 0: {hello } { hello } |
| io-32.11.2 | `untriaged` | code 0: {hello } { hello } |
| io-32.2 | `untriaged` | code 1: can not find channel named "stdin" |
| io-33.11 | `untriaged` | cleanup: can not find channel named "80" |
| io-33.12 | `untriaged` | cleanup: can not find channel named "80" |
| io-33.13 | `untriaged` | cleanup: can not find channel named "80" |
| io-34.12 | `untriaged` | code 1: bad origin "cur": must be start, current, or end |
| io-34.19 | `untriaged` | code 0: 0 |
| io-34.8 | `untriaged` | code 0: 1 {error during seek on "": input/output error} |
| io-35.10 | `untriaged` | code 0: 10 8 1 |
| io-35.11 | `untriaged` | code 0: 10 8 1 |
| io-35.12 | `untriaged` | code 0: 17 17 1 |
| io-35.13 | `untriaged` | code 0: 17 17 1 |
| io-35.14 | `untriaged` | code 0: 17 17 1 |
| io-35.15 | `untriaged` | code 0: 17 17 1 |
| io-35.16 | `untriaged` | code 0: 21 17 1 |
| io-35.17 | `untriaged` | code 0: 21 17 1 |
| io-35.18a | `untriaged` | code 0: 8 8 1 13 |
| io-35.18b | `untriaged` | code 0: 1 1 1 13 |
| io-35.19 | `untriaged` | code 0: 17 17 1 13 |
| io-35.20 | `untriaged` | code 0: 9 9 1 13 |
| io-35.6 | `untriaged` | code 0: 8 8 1 |
| io-35.7 | `untriaged` | code 0: 8 8 1 |
| io-35.8 | `untriaged` | code 0: 8 8 1 |
| io-35.9 | `untriaged` | code 0: 8 8 1 |
| io-38.3 | `untriaged` | code 1: error reading "file527": illegal operation on a directory |
| io-39.14 | `untriaged` | code 0: ç¦ |
| io-39.21 | `untriaged` | code 0: auto lf |
| io-39.22 | `untriaged` | code 0: {} {} {} |
| io-39.22a | `untriaged` | code 0: {} {} {0 {}} |
| io-39.23 | `untriaged` | code 0: {} lf |
| io-39.24 | `untriaged` | code 0: {} lf |
| io-4.4 | `untriaged` | code 0: {} {1234567          A} |
| io-40.17 | `untriaged` | code 1: can't read "::env(HOME)": no such variable |
| io-42.2 | `untriaged` | code 1: bad event name "r": must be readable or writable |
| io-42.3 | `untriaged` | code 1: bad event name "r": must be readable or writable |
| io-43.2 | `untriaged` | code 1: bad event name "r": must be readable or writable |
| io-48.10 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| io-48.11 | `untriaged` | code 0: 3 {abc def } |
| io-48.12 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| io-48.13 | `untriaged` | code 0: 3 {abc def } |
| io-48.14 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| io-48.15 | `untriaged` | code 0: 3 {abc def } |
| io-48.4 | `untriaged` | code 0: 3 {abc def } |
| io-48.5 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| io-48.6 | `untriaged` | code 0: 3 {abc def } |
| io-48.7 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| io-48.8 | `untriaged` | code 0: 3 {abc def } |
| io-48.9 | `untriaged` | code 0: 5 {abc def foo bar {}} |
| io-49.1 | `untriaged` | code 0: 7 a 1 { } 2 b 3 { } 4 c 5 { } 6 0 { } 0 |
| io-49.2 | `untriaged` | code 0: 7 {a } 2 {b } 4 {c } 6 0 { } 7 1 |
| io-49.3 | `untriaged` | code 0: 7 {a b} 3 { c } 6 0 { } 7 1 |
| io-5.2 | `untriaged` | code 0: {} 12345678901234567890 |
| io-5.4 | `untriaged` | code 1: unknown encoding "ascii" |
| io-52.1 | `untriaged` | code 1: fcopy -command is not available |
| io-52.2 | `untriaged` | code 1: fcopy -command is not available |
| io-52.3 | `untriaged` | code 1: error reading "file639": illegal operation on a directory |
| io-52.4 | `untriaged` | code 1: error reading "file641": illegal operation on a directory |
| io-52.4.1 | `untriaged` | code 1: error reading "file643": illegal operation on a directory |
| io-52.5 | `untriaged` | code 1: error reading "file645": illegal operation on a directory |
| io-52.5a | `untriaged` | code 1: error reading "file647": illegal operation on a directory |
| io-52.5b | `untriaged` | code 1: error reading "file649": illegal operation on a directory |
| io-52.6 | `untriaged` | code 1: error reading "file651": illegal operation on a directory |
| io-52.7 | `untriaged` | code 1: error reading "file653": illegal operation on a directory |
| io-52.8 | `untriaged` | code 0: 0 0 |
| io-6.17 | `untriaged` | code 0: 0 {} -1 {} |
| io-6.21 | `untriaged` | code 0: 4 abcd 4 efgh 4 ijkl 0 {} |
| io-6.23 | `untriaged` | code 0: 0 {} -1 {} |
| io-6.29 | `untriaged` | code 0: 4 abcd 9 {efgh ijkl} 4 mnop |
| io-6.4 | `untriaged` | code 0: 4 H´ |
| io-6.5 | `untriaged` | code 1: unknown encoding "shiftjis" |
| io-6.55 | `untriaged` | code 1: unknown encoding "iso2022-jp" |
| io-6.8 | `untriaged` | code 0: 12 abcdefghijk 6 wombat |
| io-6.9 | `untriaged` | code 0: 11 abcdefghijk 7 wombat |
| io-7.1 | `untriaged` | code 1: unknown encoding "shiftjis" |
| io-7.2 | `untriaged` | code 1: unknown encoding "shiftjis" |
| io-7.4 | `untriaged` | code 1: unknown encoding "shiftjis" |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 58 | `untriaged` |
| testchannel | 44 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testfevent | 9 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| emptyTest | 8 | `tcl`: tclsh skips it too |
| nonBlockFiles | 8 | `untriaged` |
| testchannelevent | 6 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| asyncPipeClose | 3 | `untriaged` |
| win | 2 | `platform`: a constraint of another platform or word size |
| extensive | 1 | `tcl`: tclsh skips it too |
| makeFileInHome | 1 | `untriaged` |
| nonPortable | 1 | `tcl`: tclsh skips it too |

### ioCmd.test

| Test | Bucket | Result (start) |
|---|---|---|
| ioCmd-13.11 | `untriaged` | code 2: 34123456x |
| iocmd-1.5 | `untriaged` | code 0: 1 {can not find channel named "stdin"} |
| iocmd-10.4 | `untriaged` | code 0: 1 {can not find channel named "stdout"} |
| iocmd-10.5 | `untriaged` | code 1: can not find channel named "stdin" |
| iocmd-11.1 | `untriaged` | code 0: 1 {can't write input to command: standard input was redirected} NONE |
| iocmd-11.2 | `untriaged` | code 0: 1 {can't read output from command: standard output was redirected} NONE |
| iocmd-11.3 | `untriaged` | code 0: 1 {can't read output from command: standard output was redirected} NONE |
| iocmd-12.11 | `untriaged` | code 0: É |
| iocmd-12.4 | `untriaged` | code 0: -1 |
| iocmd-12.6 | `untriaged` | code 0: 1 unmatched open brace in list unmatched open brace in list     while executing... |
| iocmd-12.7 | `untriaged` | code 0: 1 {invalid access mode "FOO": must be APPEND, BINARY, CREAT, EXCL, NOCTTY, NONB... |
| iocmd-14.5 | `untriaged` | code 0: 1 {can not find channel named "stdout"} |
| iocmd-14.6 | `untriaged` | code 0: 1 {can not find channel named "stdin"} |
| iocmd-14.7 | `untriaged` | code 0: 1 {can not find channel named "stdout"} |
| iocmd-14.8 | `untriaged` | code 0: 1 {can not find channel named "stderr"} |
| iocmd-15.10 | `untriaged` | code 0: 1 {fcopy -command is not available} |
| iocmd-15.12 | `untriaged` | code 0: 1 {fcopy -command is not available} |
| iocmd-15.3 | `untriaged` | code 0: 1 {can not find channel named "1"} |
| iocmd-15.4 | `untriaged` | code 0: 1 {can not find channel named "1"} |
| iocmd-15.5 | `untriaged` | code 0: 1 {can not find channel named "1"} |
| iocmd-15.8 | `untriaged` | code 0: 1 {error reading "file70": bad file number} |
| iocmd-15.9 | `untriaged` | code 0: 0 0 |
| iocmd-2.4 | `untriaged` | code 0: 1 {can not find channel named "stdin"} |
| iocmd-21.0 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.1 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.10 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.11 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.12 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.13 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.14 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.15 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.16 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.17 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.18 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.19 | `untriaged` | code 0: {file18 file19} 1 {unknown or ambiguous subcommand "create": must be close, con... |
| iocmd-21.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.20 | `untriaged` | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-21.21 | `untriaged` | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-21.22 | `untriaged` | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-21.23 | `untriaged` | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-21.24 | `untriaged` | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-21.3 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.4 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.5 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.6 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.7 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.8 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-21.9 | `untriaged` | code 0: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-22.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-22.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-22.3 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-22.4 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-22.5 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-22.6 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-22.7 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-22.8 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-22.9 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-23.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-23.10 | `untriaged` | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-23.11 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-23.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-23.3 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-23.4 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-23.5 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-23.6 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-23.7 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-23.8 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-23.9 | `untriaged` | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-24.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.10 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.11 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.12 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.13 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.14 | `untriaged` | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-24.15 | `untriaged` | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-24.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.3 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.4 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.5 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.6 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.7 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.8 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-24.9 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-25.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-25.10 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-25.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-25.3 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-25.4 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-25.5 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-25.6 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-25.7 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-25.8 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-25.9 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-26.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-26.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-26.3 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-26.4 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-26.5 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-26.6 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-26.7 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-27.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-27.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-27.3 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-27.4 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-27.5 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-27.6 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.10 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.11 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.12 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.13 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.14 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.15 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.16 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.17 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.18 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.19.0 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.19.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.19.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.3 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.4 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.5 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.6 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.7 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.8 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-28.9 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.10 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.11 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.3 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.4 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.5 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.6 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.7 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.8 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-29.9 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-3.4 | `untriaged` | code 0: 1 {can not find channel named "stdout"} |
| iocmd-30.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-30.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-30.3 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-30.4 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-31.1 | `untriaged` | code 0: unknown or ambiguous subcommand "postevent": must be close, configure, copy, eo... |
| iocmd-31.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-31.3 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-31.4 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-31.5 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-31.6 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-31.7 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-31.8 | `untriaged` | setup: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, f... |
| iocmd-32.2 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-32.3.0 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-32.3.1 | `untriaged` | code 1: unknown or ambiguous subcommand "create": must be close, configure, copy, eof, ... |
| iocmd-4.12 | `untriaged` | code 1: expected non-negative integer but got "12z" |
| iocmd-4.6 | `untriaged` | code 0: 1 {can not find channel named "stdout"} |
| iocmd-4.7 | `untriaged` | code 0: 1 {can not find channel named "stdout"} |
| iocmd-4.9 | `untriaged` | code 0: 1 {can not find channel named "stdin"} {TCL LOOKUP CHANNEL stdin} |
| iocmd-5.3 | `untriaged` | code 1: can not find channel named "stdin" |
| iocmd-5.4 | `untriaged` | code 1: can not find channel named "stdin" |
| iocmd-8.14 | `untriaged` | code 0:  |
| iocmd-8.15.1 | `untriaged` | code 1: bad option "-blah": should be one of -blocking, -buffering, -buffersize, -encod... |
| iocmd-8.2 | `untriaged` | code 0: 1 {can not find channel named "a"} |
| iocmd-8.5 | `untriaged` | code 0: 0 {} |
| iocmd-8.6 | `untriaged` | code 0: 0 {} |
| iocmd-8.7 | `untriaged` | code 1: unknown encoding "unicode" |
| iocmd-8.8 | `untriaged` | code 1: unknown encoding "unicode" |
| iocmd-8.9 | `untriaged` | code 0: -blocking 1 -buffering none -buffersize 4040 -encoding binary -eofchar {} -tran... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testchannel | 99 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| nonPortable | 3 | `tcl`: tclsh skips it too |

### ioTrans.test

| Test | Bucket | Result (start) |
|---|---|---|
| iortrans-2.0 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.1 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.10 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.11 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.12 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.13 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.14 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.17 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.18 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.19 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.2 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.20 | `untriaged` | code 0: {} 1 {unknown or ambiguous subcommand "push": must be close, configure, copy, e... |
| iortrans-2.3 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.4 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.5 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.6 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.7 | `untriaged` | code 2: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.8 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-2.9 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-3.1 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-3.2 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-3.3 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-3.4 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-3.5 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-3.6 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-3.7 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-3.8 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-3.9 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.1 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.10 | `untriaged` | cleanup: can't read "chan": no such variable |
| iortrans-4.10.1 | `untriaged` | cleanup: can't read "chan": no such variable |
| iortrans-4.10.2 | `untriaged` | cleanup: can't read "chan": no such variable |
| iortrans-4.11 | `untriaged` | cleanup: can't read "chan": no such variable |
| iortrans-4.11.1 | `untriaged` | cleanup: can't read "chan": no such variable |
| iortrans-4.11.2 | `untriaged` | cleanup: can't read "chan": no such variable |
| iortrans-4.12 | `untriaged` | cleanup: can't read "chan": no such variable |
| iortrans-4.2 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.3 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.4 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.5 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.6 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.7 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.8 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.8.1 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.8.2 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-4.9 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-5.1 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-5.10 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-5.11 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-5.2 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-5.3 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-5.4 | `untriaged` | cleanup: can not find channel named "file75" |
| iortrans-5.5 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-5.6 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-5.7 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-5.8 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-5.9 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-6.1 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-6.2 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-7.1 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-7.2 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-7.3 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-7.4 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-8.1 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-8.2 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-8.3 | `untriaged` | code 1: unknown or ambiguous subcommand "push": must be close, configure, copy, eof, fl... |
| iortrans-ea69b0258a9833cb | `untriaged` | cleanup: can't read "chan": no such variable |

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
| lindex-10.4 | `untriaged` | code 0: 1 {unmatched open brace in list} |
| lindex-17.0 | `untriaged` | code 0:  |
| lindex-2.4 | `untriaged` | code 0: 1 {unmatched open brace in list} |

### link.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testlink | 29 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### list.test

| Test | Bucket | Result (start) |
|---|---|---|
| list-1.26 | `untriaged` | code 0: #\{ #\{ |

### listObj.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testobj | 4 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| emptyTest | 1 | `tcl`: tclsh skips it too |

### lmap.test

| Test | Bucket | Result (start) |
|---|---|---|
| lmap-1.15 | `untriaged` | code 0: 1 {can't set "a": variable is array} {can't set "a": variable is array     whil... |
| lmap-1.16 | `untriaged` | code 1: foreach varlist is empty |
| lmap-4.16 | `untriaged` | code 1: foreach varlist is empty |
| lmap-7.5 | `untriaged` | code 1: foreach varlist is empty |

### load.test

| Test | Bucket | Result (start) |
|---|---|---|
| load-1.1 | `untriaged` | code 1: invalid command name "load" |
| load-1.2 | `untriaged` | code 1: invalid command name "load" |
| load-1.3 | `untriaged` | code 1: invalid command name "load" |
| load-1.4 | `untriaged` | code 1: invalid command name "load" |
| load-1.5 | `untriaged` | code 1: invalid command name "load" |
| load-1.6 | `untriaged` | code 1: invalid command name "load" |
| load-1.7 | `untriaged` | code 1: invalid command name "load" |
| load-1.8 | `untriaged` | code 1: invalid command name "load" |

| Skipped by | Tests | Bucket |
|---|---|---|
| pkga.soRequired | 12 | `internals`: a C test package of the Tcl build |
| teststaticpkg | 5 | `internals`: a C test command of the Tcl test binary |
| teststaticpkg_8.x | 5 | `internals`: a C test command of the Tcl test binary |

### lrange.test

| Skipped by | Tests | Bucket |
|---|---|---|
| testpurebytesobj | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### lrepeat.test

| Test | Bucket | Result (start) |
|---|---|---|
| lrepeat-1.1 | `untriaged` | code 1: invalid command name "-body" |
| lrepeat-1.2 | `untriaged` | code 1: invalid command name "-body" |
| lrepeat-1.3 | `untriaged` | code 1: invalid command name "-body" |
| lrepeat-1.4 | `untriaged` | code 1: invalid command name "-body" |
| lrepeat-1.5 | `untriaged` | code 1: invalid command name "-body" |
| lrepeat-1.6 | `untriaged` | code 1: invalid command name "-body" |
| lrepeat-1.7 | `untriaged` | code 1: invalid command name "-body" |

### lsearch.test

| Test | Bucket | Result (start) |
|---|---|---|
| lsearch-17.12 | `untriaged` | code 1: element -2 missing from sublist "a" |
| lsearch-17.13 | `untriaged` | code 1: element -1-1 missing from sublist "a" |
| lsearch-17.14 | `untriaged` | code 1: element end--1 missing from sublist "a" |
| lsearch-17.15 | `untriaged` | code 1: element end+1 missing from sublist "a" |
| lsearch-17.16 | `untriaged` | code 1: element end+2 missing from sublist "a" |
| lsearch-19.7 | `untriaged` | code 0: 0 end |
| lsearch-19.8 | `untriaged` | code 0: {0 end} |

### lset.test

| Test | Bucket | Result (start) |
|---|---|---|
| lset-16.2 | `untriaged` | code 1: list index out of range |
| lset-16.3 | `untriaged` | code 1: list index out of range |
| lset-16.6 | `untriaged` | code 1: list index out of range |
| lset-16.7 | `untriaged` | code 1: list index out of range |
| lset-2.2 | `untriaged` | code 0: 1 {list element in braces followed by "1" instead of space} |

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
| Tcl_Main-1.2 | `untriaged` | code 0: -script {} 0  |
| Tcl_Main-1.7 | `untriaged` | cleanup: couldn't read file "-encoding": no such file or directory |
| Tcl_Main-1.8 | `untriaged` | cleanup: couldn't read file "-encoding": no such file or directory |
| Tcl_Main-1.9 | `untriaged` | cleanup: couldn't read file "-enc": no such file or directory |
| Tcl_Main-3.2 | `untriaged` | code 0: 1 {child process exited abnormally} {ERROR } |
| Tcl_Main-3.4 | `untriaged` | code 0: 1 child process exited abnormally missing close-brace  |
| Tcl_Main-5.1 | `untriaged` | code 0:  |
| Tcl_Main-5.2 | `untriaged` | code 0: 0 {} |
| Tcl_Main-5.3 | `untriaged` | code 0: timeout |
| Tcl_Main-5.7 | `untriaged` | code 0: bar foo  |
| Tcl_Main-6.1 | `untriaged` | code 0:  |
| Tcl_Main-6.3 | `untriaged` | code 0: not reached  |
| Tcl_Main-6.4 | `untriaged` | code 0: YES  |
| Tcl_Main-6.6 | `untriaged` | cleanup: can not find channel named "file45" |
| Tcl_Main-6.7 | `untriaged` | code 0: invalid command name "foo"  |
| Tcl_Main-9.1 | `untriaged` | code 0: This is   a test  |
| Tcl_Main-9.2 | `untriaged` | code 0:  |
| Tcl_Main-9.3 | `untriaged` | code 0:  |
| Tcl_Main-9.4 | `untriaged` | code 0:  |

| Skipped by | Tests | Bucket |
|---|---|---|
| Tcltest | 36 | `untriaged` |

### mathop.test

| Test | Bucket | Result (start) |
|---|---|---|
| mathop-24.3 | `untriaged` | code 0: {can't use non-numeric string as operand of "%" ARITH DOMAIN {non-numeric strin... |
| mathop-25.30 | `untriaged` | code 0: 0 |

### misc.test

| Test | Bucket | Result (start) |
|---|---|---|
| misc-1.2 | `untriaged` | code 0: 1 missing close-brace for variable name missing close-brace for variable name  ... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testhashsystemhash | 299 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### msgcat.test

| Test | Bucket | Result (start) |
|---|---|---|
| msgcat-0.0 | `untriaged` | setup: invalid command name "i" |
| msgcat-0.1 | `untriaged` | setup: invalid command name "i" |
| msgcat-0.2 | `untriaged` | setup: invalid command name "i" |
| msgcat-0.3 | `untriaged` | setup: invalid command name "i" |
| msgcat-0.4 | `untriaged` | setup: invalid command name "i" |
| msgcat-0.5 | `untriaged` | setup: invalid command name "i" |
| msgcat-0.6 | `untriaged` | setup: invalid command name "i" |
| msgcat-0.7 | `untriaged` | setup: invalid command name "i" |
| msgcat-1.10 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-1.11 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-1.12 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-1.13 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-1.3 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-1.4 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-1.5 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-1.6 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-1.7 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-1.8 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-1.9 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-10.1 | `untriaged` | code 1: invalid command name "mcloadedlocales" |
| msgcat-10.2 | `untriaged` | code 1: invalid command name "mcloadedlocales" |
| msgcat-10.3 | `untriaged` | setup: invalid command name "mcforgetpackage" |
| msgcat-10.4 | `untriaged` | setup: invalid command name "mcforgetpackage" |
| msgcat-11.1 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-11.2 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-11.3 | `untriaged` | code 1: invalid command name "mcpackageconfig" |
| msgcat-12.1 | `untriaged` | code 1: invalid command name "mcpackagelocale" |
| msgcat-12.10 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-12.2 | `untriaged` | code 1: invalid command name "mcpackagelocale" |
| msgcat-12.3 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-12.4 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-12.5 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-12.6 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-12.7 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-12.8 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-12.9 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-13.1 | `untriaged` | code 1: invalid command name "mcpackageconfig" |
| msgcat-13.2 | `untriaged` | code 1: invalid command name "mcpackageconfig" |
| msgcat-13.3 | `untriaged` | code 1: invalid command name "mcpackageconfig" |
| msgcat-13.4 | `untriaged` | setup: invalid command name "mcforgetpackage" |
| msgcat-13.5 | `untriaged` | setup: invalid command name "mcforgetpackage" |
| msgcat-2.3 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-2.4 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-2.5 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-2.6 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-2.7 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-3.10 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.11 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.12 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.13 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.14 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.15 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.16 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.2 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.3 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.4 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.5 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.6 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.7 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.8 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-3.9 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-4.2 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-4.3 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-4.4 | `untriaged` | setup: can't rename "msgcat::mcunknown": command doesn't exist |
| msgcat-4.5 | `untriaged` | setup: can't rename "msgcat::mcunknown": command doesn't exist |
| msgcat-4.6 | `untriaged` | setup: can't rename "msgcat::mcunknown": command doesn't exist |
| msgcat-5.1 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-5.10 | `untriaged` | setup: can't rename "msgcat::mcunknown": command doesn't exist |
| msgcat-5.11 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-5.2 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-5.3 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-5.4 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-5.5 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-5.6 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-5.7 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-5.8 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-5.9 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.1 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.10 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.11 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.12 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.2 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.3 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.4 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.5 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.6 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.7 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.8 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-6.9 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-7.1 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-7.2 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-7.3 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-7.4 | `untriaged` | setup: invalid command name "mcset" |
| msgcat-8.1 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-8.2 | `untriaged` | setup: invalid command name "mclocale" |
| msgcat-9.1 | `untriaged` | code 1: invalid command name "mcexists" |
| msgcat-9.2 | `untriaged` | code 1: invalid command name "mcexists" |
| msgcat-9.3 | `untriaged` | setup: invalid command name "mcforgetpackage" |
| msgcat-9.4 | `untriaged` | setup: invalid command name "mcforgetpackage" |
| msgcat-9.5 | `untriaged` | setup: invalid command name "mcforgetpackage" |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 6 | `untriaged` |

### namespace-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| namespace-old-1.11 | `untriaged` | code 0:  |
| namespace-old-1.15 | `untriaged` | code 0:  |
| namespace-old-1.16 | `untriaged` | code 0: test_ns_simple::test_ns_x test_ns_simple::test_ns_y |
| namespace-old-2.3 | `untriaged` | code 0: test_ns_simple::test_ns_x test_ns_simple::test_ns_y |
| namespace-old-2.4 | `untriaged` | code 0:  |
| namespace-old-5.10 | `untriaged` | code 0:  |
| namespace-old-6.14 | `untriaged` | code 1: can't read "test_ns_cache_var": no such variable |
| namespace-old-7.2 | `untriaged` | code 0: 0 0 |
| namespace-old-7.5 | `untriaged` | code 0: 0 0 |
| namespace-old-9.14 | `untriaged` | code 0: cmd2 1 {invalid command name "cmd1"} |
| namespace-old-9.18 | `untriaged` | code 0: cmd1 ::test_ns_import_use::cmd1 |
| namespace-old-9.19 | `untriaged` | code 0: {cmd1 cmd2} {ncmd ncmd1 ncmd2} {::test_ns_import_use::cmd1 ::test_ns_import_use... |

### namespace.test

| Test | Bucket | Result (start) |
|---|---|---|
| namespace-10.3 | `untriaged` | code 0: {::test_ns_import::cmd1 ::test_ns_import::cmd2 ::test_ns_import::p} {::test_ns_... |
| namespace-10.5 | `untriaged` | code 0:  |
| namespace-10.9 | `untriaged` | code 0:  |
| namespace-13.1 | `untriaged` | code 0: {::test_ns_import::cmd1 ::test_ns_import::cmd2 ::test_ns_import::p} {::test_ns_... |
| namespace-14.1 | `untriaged` | code 0: 10 30 20 {::test_ns_1 ::test_ns_2 ::test_ns_2: ::test_ns_7 ::test_ns_export ::t... |
| namespace-14.13 | `untriaged` | code 0:  |
| namespace-14.2 | `untriaged` | code 0: 1 {can't read "::test_ns_777::v": no such variable} 0 {} |
| namespace-14.3 | `untriaged` | code 1: can't read "v": no such variable |
| namespace-14.4 | `untriaged` | code 0: ::test_ns_1::test_ns_2::foo 0 {} |
| namespace-14.6 | `untriaged` | code 0: ::test_ns_1::test_ns_2::foo 0 {} |
| namespace-14.8 | `untriaged` | code 0:  |
| namespace-17.10 | `untriaged` | code 2: 0 |
| namespace-17.7 | `untriaged` | code 1: can't read "x": no such variable |
| namespace-19.3 | `untriaged` | code 0:  |
| namespace-20.3 | `untriaged` | code 0: ::test_ns_2: ::test_ns_1 |
| namespace-21.4 | `untriaged` | code 0: ::test_ns_1::test_ns_2::test_ns_3 |
| namespace-34.7 | `untriaged` | code 0: {} ::test_ns_3::v3 ::test_ns_2::v2 0 {} |
| namespace-37.2 | `untriaged` | code 0:  |
| namespace-42.1 | `untriaged` | code 0: ns 1 {} ns |
| namespace-42.10 | `untriaged` | code 1: invalid command name "::two" |
| namespace-42.2 | `untriaged` | code 0: foo 1 {} foo |
| namespace-42.4 | `untriaged` | code 0: 1 {unknown or ambiguous subcommand "x": must be x1, or x2} |
| namespace-44.5 | `untriaged` | code 1: invalid command name "::::foobarconfigure" |
| namespace-45.2 | `untriaged` | code 0: A x |
| namespace-46.2 | `untriaged` | code 0: {unknown or ambiguous subcommand "?": must be x1, or x2} {unknown or ambiguous ... |
| namespace-46.3 | `untriaged` | code 0: 1 {wrong # args: should be "ns subcommand ?arg ...?"} 10 3010 3010 p |
| namespace-46.6 | `untriaged` | code 1: invalid command name "foo" |
| namespace-46.7 | `untriaged` | code 1: unknown namespace "ns" in namespace delete command |
| namespace-46.8 | `untriaged` | code 0: 0 0 |
| namespace-47.1 | `untriaged` | code 0: {0 2 0 2 0 2 0 2 0 {}} {::ns::Magic ::ns::a ::ns::b ::ns::bar ::ns::c} {{making... |
| namespace-47.2 | `untriaged` | code 0: 1 foobar {foobar     while executing "error foobar"     (procedure "::ns::Magic... |
| namespace-47.3 | `untriaged` | code 0: 1 {unknown or ambiguous subcommand "spong": must be Magic, a, b, or c} 1 {} |
| namespace-47.4 | `untriaged` | code 0: 1 {unknown subcommand handler returned bad code: break} {unknown subcommand han... |
| namespace-47.5 | `untriaged` | code 0: {LOG foo bar} 1 {unknown subcommand "bar": namespace :: does not export any com... |
| namespace-47.6 | `untriaged` | code 0: 1 {unmatched open brace in list} {unmatched open brace in list     while execut... |
| namespace-47.7 | `untriaged` | code 0: foo\|one two three |
| namespace-47.8 | `untriaged` | code 0: boo\|foo\|one two three |
| namespace-48.1 | `untriaged` | code 0: {-map {} -namespace ::foo -parameters {} -prefixes 1 -subcommands x -unknown ::... |
| namespace-48.2 | `untriaged` | code 0: 1 1 1 1 0 0 1 1 |
| namespace-48.3 | `untriaged` | code 0: ::foo 1 {"boo" is not an ensemble command} 1 {"spong" is not an ensemble command} |
| namespace-50.1 | `untriaged` | code 1: wrong # args: should be "bb c d ?e? ?arg ...?" |
| namespace-50.2 | `untriaged` | code 1: wrong # args: should be "string is class ?-strict? ?-failindex var? str" |
| namespace-50.3 | `untriaged` | code 1: wrong # args: should be "e f" |
| namespace-50.4 | `untriaged` | code 1: wrong # args: should be "e f" |
| namespace-50.5 | `untriaged` | code 0: {wrong # args: should be "bar ev"} {wrong # args: should be "bingo xx"} {wrong ... |
| namespace-50.6 | `untriaged` | code 0: {wrong # args: should be "target x y"} {wrong # args: should be "target x y"} {... |
| namespace-50.7 | `untriaged` | code 0: {wrong # args: should be "target x y"} {wrong # args: should be "target x y"} {... |
| namespace-50.8 | `untriaged` | code 1: wrong # args: should be "e a b subcommand ?arg ...?" |
| namespace-51.13 | `untriaged` | code 1: unknown namespace "::test_ns_2" in namespace delete command |
| namespace-51.14 | `untriaged` | code 0: foo0 foo0 {::test_ns_3::foo2 foo0} foo0 foo0 |
| namespace-51.3 | `untriaged` | code 0: 1,2,global,::test_ns_1 1,2,global,::test_ns_1 global,2,global,::test_ns_1 |
| namespace-51.4 | `untriaged` | code 0: 1,2,global,::test_ns_1 1,2,global,::test_ns_1 global,2,global, |
| namespace-51.7 | `untriaged` | code 0: ::test_ns_1 {} ::test_ns_1 |
| namespace-51.8 | `untriaged` | code 0: {::test_ns_1 ::test_ns_2 ::test_ns_3} {} {::test_ns_1 ::test_ns_2 ::test_ns_3} |
| namespace-51.9 | `untriaged` | code 0: {::test_ns_1 ::test_ns_2 ::test_ns_3} {} {} {::test_ns_1 ::test_ns_2 ::test_ns_3} |
| namespace-52.11 | `untriaged` | code 0: FAIL |
| namespace-52.7 | `untriaged` | code 1: invalid command name "dummy" |
| namespace-52.8 | `untriaged` | code 1: unknown namespace "::" in namespace delete command |
| namespace-53.1 | `untriaged` | code 0: ns {1 bar} {} ns |
| namespace-53.10 | `untriaged` | code 0: 0 0 1 {wrong # args: should be "::ns::x::z1 a1"} 1 {wrong # args: should be "::... |
| namespace-53.11 | `untriaged` | code 0: 1 {wrong # args: should be "::ns::x::z2 a1 a2"} |
| namespace-53.2 | `untriaged` | code 0: foo {1 bar} {} foo |
| namespace-53.7 | `untriaged` | code 0: 1 {wrong # args: should be "ns p1 subcommand ?arg ...?"} 1 {wrong # args: shoul... |
| namespace-53.8 | `untriaged` | code 0: 0 {1 x2} {} 1 {unknown or ambiguous subcommand "x2": must be Magic, or x1} p1 1... |
| namespace-53.9 | `untriaged` | code 0: 0 {1 x2} {} 1 {unknown or ambiguous subcommand "x2": must be Magic, or x1} {p1 ... |
| namespace-55.2 | `untriaged` | code 1: invalid command name "::tcl::unsupported::disassemble" |
| namespace-56.6 | `untriaged` | code 2: 0 |
| namespace-6.2 | `untriaged` | code 0: ::test_ns_1::::foo ::test_ns_2:::::foo |
| namespace-7.7 | `untriaged` | setup: can't rename "tcl::info::commands": command doesn't exist |
| namespace-8.1 | `untriaged` | code 1: unknown namespace "::" in namespace delete command |
| namespace-8.3 | `untriaged` | code 0: ::test_ns_1::test_ns_2 {} {} 0 {} {} |
| namespace-8.4 | `untriaged` | code 0: {::test_ns_import::cmd1 ::test_ns_import::cmd2 ::test_ns_import::p} {} {::test_... |
| namespace-8.7 | `untriaged` | code 0: NONE |
| namespace-9.7 | `untriaged` | code 0: {cmd1: a b c} {cmd1: d e f} {} ::test_ns_export::cmd1 ::test_ns_export::cmd1 {c... |
| namespace-9.9 | `untriaged` | code 0: ::one::cmd |

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
| nre-4.2 | `untriaged` | setup: "::dict" is not an ensemble command |

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
| oo-0.2 | `untriaged` | code 1: unknown namespace "::" in namespace delete command |
| oo-0.6 | `untriaged` | code 1: namespace "oo" not found in "::" |
| oo-0.7 | `untriaged` | code 1: namespace "oo" not found in "::" |
| oo-1.21 | `untriaged` | code 1: ::oo::Slot does not refer to an object |
| oo-1.25 | `untriaged` | code 0: D D D |
| oo-14.2 | `untriaged` | code 0: 1 {unknown method "?": must be bar, boo or destroy} 0 {::fooTest in bar} 0 {::f... |
| oo-14.3 | `untriaged` | cleanup: mixin deletion failed to destroy dependent instance |
| oo-14.4 | `untriaged` | setup: can't create object "c": command already exists with that name |
| oo-15.1 | `untriaged` | code 1: can't create object "Aclass": command already exists with that name |
| oo-15.13.1 | `untriaged` | cleanup: invalid command name "Cls2" |
| oo-15.13.2 | `untriaged` | code 1: ::dupens refers to an existing namespace |
| oo-15.14 | `untriaged` | code 1: ::dupens refers to an existing namespace |
| oo-18.10 | `untriaged` | code 0: foobar     while executing "error foobar"     (in namespace eval "::oo::objdefi... |
| oo-18.11 | `untriaged` | code 0: foobar     while executing "error foobar"     (in namespace eval "::oo::objdefi... |
| oo-18.12 | `untriaged` | code 1: self may only be called from inside a method |
| oo-18.2 | `untriaged` | code 0: 1 foo {foo     while executing "error foo"     (in namespace eval "::oo::define... |
| oo-18.3b | `untriaged` | code 0: 1 bar {bar     while executing "error bar"     invoked from within "eval error ... |
| oo-18.5 | `untriaged` | code 0: 1 foo {foo     while executing "error foo"     (in "my eval" script line 1)    ... |
| oo-18.6 | `untriaged` | code 0: foo     while executing "::error foo"     (in definition script for class "::ab... |
| oo-18.7 | `untriaged` | code 0: 1 foo {foo     while executing "error foo"     (in definition script for object... |
| oo-18.8 | `untriaged` | code 0: foobar     while executing "error foobar"     (in namespace eval "::oo::objdefi... |
| oo-18.9 | `untriaged` | code 0: err     while executing "error err"     (in definition script for class "::now_... |
| oo-19.4 | `untriaged` | code 0: {} 0 {} |
| oo-2.7 | `untriaged` | code 1: wrong # args: should be "::k::s create X j" |
| oo-2.8 | `untriaged` | code 1: wrong # args: should be "::k::t create X j" |
| oo-20.3 | `untriaged` | code 0:  |
| oo-20.4 | `untriaged` | code 0:  |
| oo-22.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| oo-22.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| oo-22.3 | `untriaged` | code 1: invalid command name "my" |
| oo-22.4 | `untriaged` | code 1: invalid command name "my" |
| oo-22.5 | `untriaged` | code 1: invalid command name "my" |
| oo-22.6 | `untriaged` | code 1: invalid command name "my" |
| oo-23.1 | `untriaged` | code 1: ::oo::Obj461 does not refer to an object |
| oo-24.1 | `untriaged` | code 1: unknown method "foo": must be destroy or dummy |
| oo-24.2 | `untriaged` | code 1: unknown method "foo": must be destroy, dummy or dummy2 |
| oo-27.18 | `untriaged` | code 0: 1,1 2,2 |
| oo-27.6 | `untriaged` | code 0: {3 2 y! {}} {x! y!} {} |
| oo-3.4 | `untriaged` | code 0: 0 ok ::oo::Obj66::state ::oo::Obj66::localcmdexists {} |
| oo-3.4a | `untriaged` | code 0: 0 ok ::oo::Obj68::state ::oo::Obj68::localcmdexists {} |
| oo-3.5 | `untriaged` | code 0: 0 ok ::oo::Obj70::state ::oo::Obj70::localcmdexists {} |
| oo-3.5a | `untriaged` | code 1: can't read "result": no such variable |
| oo-32.1 | `untriaged` | setup: class "oo::Slot" does not exist |
| oo-32.2 | `untriaged` | setup: class "oo::Slot" does not exist |
| oo-32.3 | `untriaged` | setup: class "oo::Slot" does not exist |
| oo-32.4 | `untriaged` | setup: class "oo::Slot" does not exist |
| oo-32.5 | `untriaged` | setup: class "oo::Slot" does not exist |
| oo-33.1 | `untriaged` | setup: class "oo::Slot" does not exist |
| oo-33.2 | `untriaged` | setup: class "oo::Slot" does not exist |
| oo-33.3 | `untriaged` | setup: class "oo::Slot" does not exist |
| oo-33.4 | `untriaged` | setup: class "oo::Slot" does not exist |
| oo-34.1 | `untriaged` | code 1: filter does not refer to an object |
| oo-34.2 | `untriaged` | code 1: oo::Slot does not refer to an object |
| oo-34.3 | `untriaged` | code 1: oo::define::filter does not refer to an object |
| oo-34.4 | `untriaged` | code 1: oo::define::mixin does not refer to an object |
| oo-34.5 | `untriaged` | code 1: oo::define::superclass does not refer to an object |
| oo-34.6 | `untriaged` | code 1: oo::define::variable does not refer to an object |
| oo-34.7 | `untriaged` | code 1: oo::objdefine::filter does not refer to an object |
| oo-34.8 | `untriaged` | code 1: oo::objdefine::mixin does not refer to an object |
| oo-34.9 | `untriaged` | code 1: oo::objdefine::variable does not refer to an object |
| oo-35.2 | `untriaged` | code 1: unknown method "create": must be destroy or eat |
| oo-35.5 | `untriaged` | code 1: can't create object "D": command already exists with that name |
| oo-35.7.1 | `untriaged` | code 0: can't delete "o": command doesn't exist invalid command name "::oo::Obj563" |
| oo-35.7.2 | `untriaged` | code 0: Destroyed invalid command name "::oo::Obj568" |
| oo-6.10 | `untriaged` | code 1: wrong # args: should be "my handler a b c" |
| oo-6.11 | `untriaged` | code 1: wrong # args: should be "my handler a b c" |
| oo-6.13 | `untriaged` | code 1: wrong # args: should be "my handler a b c" |
| oo-6.14 | `untriaged` | code 1: wrong # args: should be "my handler a b c" |
| oo-6.16 | `untriaged` | code 1: wrong # args: should be "my handler a b c d" |
| oo-6.17 | `untriaged` | code 1: wrong # args: should be "my handler a b c d" |
| oo-6.18 | `untriaged` | code 1: wrong # args: should be "string length string" |
| oo-6.8 | `untriaged` | code 1: wrong # args: should be "my handler a b c" |
| oo-7.10 | `untriaged` | code 0: c2::m1 c2::destructor c2::m1 no-self c1::m1 /c2::m1 0 {c2::m1 c2::destructor c2... |
| oo-7.7 | `untriaged` | code 0: {unknown method "?": must be destroy or foo} foo! {foo!     while executing "er... |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1 | `untriaged` |
| memory | 14 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| knownBug | 3 | `tcl`: tclsh skips it too |

### ooNext2.test

| Test | Bucket | Result (start) |
|---|---|---|
| oo-call-2.10 | `untriaged` | code 1: a does not refer to an object |
| oo-call-2.8 | `untriaged` | code 1: wrong # args: should be "info class subcommand ?arg ...?" |
| oo-call-2.9 | `untriaged` | code 1: a does not refer to an object |
| oo-call-3.3 | `untriaged` | code 2: {{{method <constructor> object method} {method <constructor> object method}} 0}... |
| oo-call-3.4 | `untriaged` | code 2: {{{method <destructor> object method} {method <destructor> object method}} 0} {... |
| oo-nextto-2.5 | `untriaged` | code 1: wrong # args: should be "::oo::Obj44 x y" |
| oo-nextto-2.7 | `untriaged` | code 1: method implementation by "B" not reachable from here |

| Skipped by | Tests | Bucket |
|---|---|---|
| memory | 5 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |

### opt.test

| Test | Bucket | Result (start) |
|---|---|---|
| opt-10.1 | `untriaged` | code 1: invalid command name "::tcl::OptProc" |
| opt-10.10 | `untriaged` | code 0: 1 {invalid command name "optTest"} |
| opt-10.2 | `untriaged` | code 1: invalid command name "::tcl::OptProc" |
| opt-10.3 | `untriaged` | code 1: invalid command name "::tcl::OptProc" |
| opt-10.4 | `untriaged` | code 1: invalid command name "::tcl::OptProc" |
| opt-10.5 | `untriaged` | code 0: 1 {invalid command name "optTest"} |
| opt-10.6 | `untriaged` | code 0: 1 {invalid command name "optTest"} |
| opt-10.7 | `untriaged` | code 1: invalid command name "optTest" |
| opt-10.8 | `untriaged` | code 1: invalid command name "optTest" |
| opt-10.9 | `untriaged` | code 1: invalid command name "optTest" |
| opt-11.1 | `untriaged` | code 1: invalid command name "::tcl::OptKeyRegister" |
| opt-11.2 | `untriaged` | code 1: invalid command name "::tcl::OptKeyRegister" |
| opt-2.1 | `untriaged` | code 1: invalid command name "::tcl::OptKeyRegister" |
| opt-3.1 | `untriaged` | code 1: can't read "::tcl::OptDescN": no such variable |
| opt-3.2 | `untriaged` | code 1: can't read "::tcl::OptDescN": no such variable |
| opt-4.1 | `untriaged` | code 1: invalid command name "::tcl::OptProc" |
| opt-5.1 | `untriaged` | code 1: invalid command name "::tcl::OptProc" |
| opt-6.1 | `untriaged` | code 1: invalid command name "::tcl::OptKeyRegister" |
| opt-7.1 | `untriaged` | code 1: invalid command name "::tcl::OptCheckType" |
| opt-8.1 | `untriaged` | code 1: invalid command name "::tcl::Lempty" |
| opt-8.10 | `untriaged` | code 1: invalid command name "::tcl::Lvarpop" |
| opt-8.11 | `untriaged` | code 1: invalid command name "::tcl::Lassign" |
| opt-8.2 | `untriaged` | code 1: invalid command name "::tcl::Lempty" |
| opt-8.3 | `untriaged` | code 1: invalid command name "::tcl::Lget" |
| opt-8.4 | `untriaged` | code 1: invalid command name "::tcl::Lvarset" |
| opt-8.5 | `untriaged` | code 1: invalid command name "::tcl::Lvarset1" |
| opt-8.6 | `untriaged` | code 1: invalid command name "::tcl::Lvarincr" |
| opt-8.7 | `untriaged` | code 1: invalid command name "::tcl::Lvarincr" |
| opt-9.1 | `untriaged` | code 1: invalid command name "::tcl::SetMax" |
| opt-9.2 | `untriaged` | code 1: invalid command name "::tcl::SetMin" |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1 | `untriaged` |

### package.test

| Test | Bucket | Result (start) |
|---|---|---|
| package-1.1 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.10 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.11 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.12 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.13 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.14 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.15 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.16 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.2 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.3 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.4 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.5 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.6 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.7 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.8 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-1.9 | `untriaged` | code 1: invalid command name "::pkg::create" |
| package-11.0 | `untriaged` | code 0: 0 |
| package-11.132 | `untriaged` | code 0: 1 |
| package-11.26 | `untriaged` | code 0: 0 |
| package-11.27 | `untriaged` | code 0: 0 |
| package-11.98 | `untriaged` | code 0: 0 |
| package-11.99 | `untriaged` | code 0: 0 |
| package-13.1 | `untriaged` | code 0: stable |
| package-15.4 | `untriaged` | code 1: cannot change the preference to stable |
| package-3.10 | `untriaged` | code 0: 1 {attempt to provide package t 2.1 failed: ifneeded test} {ifneeded test     w... |
| package-3.15 | `untriaged` | code 2: {a b} |
| package-3.16 | `untriaged` | code 0: 1 {testing package unknown} {testing package unknown     while executing "error... |
| package-3.17 | `untriaged` | code 0: 1 {can't find package t 1.5} {t 1.5-1.5} |
| package-3.24 | `untriaged` | code 1: version conflict for package "t": have 2.3, need 2.2 |
| package-3.25 | `untriaged` | code 0: 1 {attempt to provide package t 2.1 failed: ifneeded test} {EI     invoked from... |
| package-3.26 | `untriaged` | code 0: 1 {attempt to provide package t 2.1 failed: ifneeded test} {EI     invoked from... |
| package-3.27 | `untriaged` | code 1: attempt to provide package foo 1 failed: attempt to provide package foo 1 faile... |
| package-3.28 | `untriaged` | code 1: attempt to provide package foo 1 failed: can't find package foo 2 |
| package-3.29 | `untriaged` | code 1: attempt to provide package foo 1 failed: attempt to provide package bar 1 faile... |
| package-3.30 | `untriaged` | code 1: attempt to provide package foo 1 failed: conflicting versions provided for pack... |
| package-3.31 | `untriaged` | code 1: attempt to provide package foo 1 failed: foo |
| package-3.32 | `untriaged` | code 0: 1 |
| package-3.37 | `untriaged` | code 1: attempt to provide package foo 1 failed: package foo 1 not provided |
| package-3.40 | `untriaged` | code 1: wrong # args: should be "break" |
| package-3.41 | `untriaged` | code 1: wrong # args: should be "continue" |
| package-3.42 | `untriaged` | code 2: ;# |
| package-3.43 | `untriaged` | code 10: ;# |
| package-3.44 | `untriaged` | code 1: version conflict for package "demo": have 1.2.3, need 1.2 |
| package-3.8 | `untriaged` | code 1: can't find package t 1.3 |
| package-4.32 | `untriaged` | code 1: attempt to provide package t 2.3 failed: synthetic error |
| package-4.55 | `untriaged` | code 1: expected versionMin-versionMax but got "3.2-x.y" |
| package-4.56 | `untriaged` | code 1: expected versionMin-versionMax but got "x.y-3.2" |
| package-8.7 | `untriaged` | code 1: version conflict for package "t": have 2.4, need 2.3 |
| package-9.24 | `untriaged` | code 0: 0 |
| package-9.25 | `untriaged` | code 0: 0 |

### parse.test

| Test | Bucket | Result (start) |
|---|---|---|
| parse-18.19 | `untriaged` | code 0: 0 abc, |
| parse-19.1 | `untriaged` | setup: invalid command name "load" |
| parse-19.2 | `untriaged` | setup: invalid command name "load" |
| parse-8.12 | `untriaged` | code 1: invalid command name "noSuchCommand" |
| parse-9.1 | `untriaged` | code 0: 1 {can't read "x": no such variable     while executing "set x"     invoked fro... |

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

| Test | Bucket | Result (start) |
|---|---|---|
| parseExpr-21.15 | `untriaged` | code 1: invalid character "~" in expression "0~0" |
| parseExpr-21.16 | `untriaged` | code 1: invalid character ")" in expression "()" |
| parseExpr-21.17 | `untriaged` | code 1: missing operand at _@_ in expression "(_@_" |
| parseExpr-21.18 | `untriaged` | code 1: invalid character ")" in expression "a(0,)" |
| parseExpr-21.2 | `untriaged` | code 1: invalid character "=" in expression "=" |
| parseExpr-21.20 | `untriaged` | code 1: invalid character ")" in expression ")" |
| parseExpr-21.21 | `untriaged` | code 1: invalid character "," in expression "a(,0)" |
| parseExpr-21.22 | `untriaged` | code 1: invalid character "\|" in expression "0&\|0" |
| parseExpr-21.23 | `untriaged` | code 1: invalid character "^" in expression "0^^0" |
| parseExpr-21.24 | `untriaged` | code 1: invalid character "&" in expression "0\|&0" |
| parseExpr-21.25 | `untriaged` | code 1: invalid character "," in expression "a(1+,0)" |
| parseExpr-21.27 | `untriaged` | code 1: missing operator ":" in expression "0?0" |
| parseExpr-21.28 | `untriaged` | code 1: invalid character ":" in expression "0:0" |
| parseExpr-21.29 | `untriaged` | code 1: invalid character ")" in expression "0)" |
| parseExpr-21.3 | `untriaged` | code 1: invalid bareword "x" in expression "x" |
| parseExpr-21.30 | `untriaged` | code 1: invalid character "," in expression "0," |
| parseExpr-21.31 | `untriaged` | code 1: invalid character "," in expression "0,0" |
| parseExpr-21.32 | `untriaged` | code 1: unbalanced open paren in expression "(0,0)" |
| parseExpr-21.33 | `untriaged` | code 1: missing close paren in expression "a(0:0,0)" |
| parseExpr-21.34 | `untriaged` | code 1: invalid character "@" in expression ""abcdefghijklmnopqrstuvwxyz"@0" |
| parseExpr-21.35 | `untriaged` | code 1: invalid character "@" in expression "0@"abcdefghijklmnopqrstuvwxyz"" |
| parseExpr-21.36 | `untriaged` | code 1: invalid character "@" in expression ""abcdefghijklmnopqrstuvwxyz"@"abcdefghijkl... |
| parseExpr-21.37 | `untriaged` | code 1: invalid character "@" in expression ""§§§§§§§§§§§§§§§§§§§§§§§§§" @ 0" |
| parseExpr-21.38 | `untriaged` | code 1: invalid character "@" in expression "0 @ "§§§§§§§§§§§§§§§§§§§§§§§§§"" |
| parseExpr-21.39 | `untriaged` | code 1: invalid character "@" in expression ""§§§§§§§§§§§§§§§§§§§§§§§§§" @ "§§§§§§§§§§§... |
| parseExpr-21.4 | `untriaged` | code 1: invalid bareword "abcdefghijklmnopqrstuvwxyz" in expression "abcdefghijklmnopqr... |
| parseExpr-21.40 | `untriaged` | code 0: invalid character "@" in expression ""abcdefghijklmnopqrstuvwxyz"@0"     while ... |
| parseExpr-21.41 | `untriaged` | code 0: invalid character "@" in expression ""§§§§§§§§§§§§§§§§§§§§§§§§§" @ 0"     while... |
| parseExpr-21.42 | `untriaged` | code 1: missing " in expression "123456789012345678901234567890*"abcdefghijklmnopqrstuv... |
| parseExpr-21.43 | `untriaged` | code 1: missing close-brace for variable name in expression "12345678901234567890123456... |
| parseExpr-21.44 | `untriaged` | code 1: missing ) in expression "123456789012345678901234567890*"foo$bar(abcdefghijklmn... |
| parseExpr-21.45 | `untriaged` | code 1: extra characters after close-brace in expression "12345678901234567890123456789... |
| parseExpr-21.46 | `untriaged` | code 1: extra characters after close-quote in expression "12345678901234567890123456789... |
| parseExpr-21.47 | `untriaged` | code 1: missing close-bracket in expression "123456789012345678901234567890*"foo$bar([a... |
| parseExpr-21.48 | `untriaged` | code 1: missing close-brace in expression "123456789012345678901234567890*"foo$bar([{ab... |
| parseExpr-21.49 | `untriaged` | code 1: missing close-brace in expression "123456789012345678901234567890*{abcdefghijkl... |
| parseExpr-21.5 | `untriaged` | code 1: invalid character "[" in expression "[][]" |
| parseExpr-21.50 | `untriaged` | code 1: missing " in expression "123456789012345678901234567890*$foo(["abcdefghijklmnop... |
| parseExpr-21.51 | `untriaged` | code 1: missing close-brace for variable name in expression "12345678901234567890123456... |
| parseExpr-21.52 | `untriaged` | code 1: missing ) in expression "123456789012345678901234567890*$bar(abcdefghijklmnopqr... |
| parseExpr-21.53 | `untriaged` | code 1: extra characters after close-brace in expression "12345678901234567890123456789... |
| parseExpr-21.54 | `untriaged` | code 1: extra characters after close-quote in expression "12345678901234567890123456789... |
| parseExpr-21.55 | `untriaged` | code 1: missing close-bracket in expression "123456789012345678901234567890*$bar([abcde... |
| parseExpr-21.56 | `untriaged` | code 1: missing close-brace in expression "123456789012345678901234567890*$bar([{abcdef... |
| parseExpr-21.57 | `untriaged` | code 1: missing " in expression "123456789012345678901234567890*["abcdefghijklmnopqrstu... |
| parseExpr-21.58 | `untriaged` | code 1: missing close-brace for variable name in expression "12345678901234567890123456... |
| parseExpr-21.59 | `untriaged` | code 1: missing ) in expression "123456789012345678901234567890*[$bar(abcdefghijklmnopq... |
| parseExpr-21.6 | `untriaged` | code 1: invalid character "0" in expression "0 0" |
| parseExpr-21.60 | `untriaged` | code 1: extra characters after close-brace in expression "12345678901234567890123456789... |
| parseExpr-21.61 | `untriaged` | code 1: extra characters after close-quote in expression "12345678901234567890123456789... |
| parseExpr-21.62 | `untriaged` | code 1: missing close-bracket in expression "123456789012345678901234567890*[abcdefghij... |
| parseExpr-21.63 | `untriaged` | code 1: missing close-brace in expression "123456789012345678901234567890*[{abcdefghijk... |
| parseExpr-21.7 | `untriaged` | code 1: invalid number "0o8" in expression "0o8" |
| parseExpr-21.8 | `untriaged` | code 1: invalid number "0o8" in expression "0o8x" |

| Skipped by | Tests | Bucket |
|---|---|---|
| testexprparser | 215 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| expr:testexprparser && !ieeeFloatingPoint | 1 | `untriaged` |
| expr:testexprparser && ieeeFloatingPoint | 1 | `untriaged` |

### parseOld.test

| Test | Bucket | Result (start) |
|---|---|---|
| parseOld-10.14 | `untriaged` | code 0: 1 {missing )} {missing )     while executing "eval \$x[format "%01000d" 0]("} |

| Skipped by | Tests | Bucket |
|---|---|---|
| testbytestring | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### pkgMkIndex.test

| Test | Bucket | Result (start) |
|---|---|---|
| pkgMkIndex-1.1 | `untriaged` | code 0: {1 {invalid command name "pkg_mkIndex"}} / |
| pkgMkIndex-11.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-12.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-13.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-14.1 | `untriaged` | code 1: invalid command name "tcl::Pkg::CompareExtension" |
| pkgMkIndex-14.2 | `untriaged` | code 1: invalid command name "tcl::Pkg::CompareExtension" |
| pkgMkIndex-14.3 | `untriaged` | code 1: invalid command name "tcl::Pkg::CompareExtension" |
| pkgMkIndex-14.4 | `untriaged` | code 1: invalid command name "tcl::Pkg::CompareExtension" |
| pkgMkIndex-14.5 | `untriaged` | code 1: invalid command name "tcl::Pkg::CompareExtension" |
| pkgMkIndex-14.6 | `untriaged` | code 1: invalid command name "tcl::Pkg::CompareExtension" |
| pkgMkIndex-2.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-2.2 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-2.3 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-2.4 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-3.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-4.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-4.2 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-5.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-6.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-6.2 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-7.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-7.2 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-8.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-8.2 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |
| pkgMkIndex-9.1 | `untriaged` | code 0: 1 {invalid command name "pkg_mkIndex"} |

| Skipped by | Tests | Bucket |
|---|---|---|
| pkga.soRequired | 2 | `internals`: a C test package of the Tcl build |

### platform.test

| Test | Bucket | Result (start) |
|---|---|---|
| platform-1.0 | `untriaged` | code 0: ztcl |
| platform-1.1 | `untriaged` | code 0: byteOrder engine machine os osVersion platform pointerSize user wordSize |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 2 | `untriaged` |
| testCPUID | 1 | `untriaged` |

### proc-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| proc-old-5.14 | `untriaged` | code 0: invoked "break" outside of a loop     while executing "tproc" |
| proc-old-5.15 | `untriaged` | code 0: invoked "continue" outside of a loop     while executing "tproc" |
| proc-old-5.16 | `untriaged` | code 0: 1 {Nested error} {Nested error     while executing "error "Nested error""     i... |
| proc-old-7.11 | `untriaged` | code 1: invalid command name "normalizeMsg" |
| proc-old-7.12 | `untriaged` | code 1: invalid command name "normalizeMsg" |
| proc-old-7.13 | `untriaged` | code 1: invalid command name "normalizeMsg" |
| proc-old-7.14 | `untriaged` | code 1: invalid command name "normalizeMsg" |
| proc-old-7.4 | `untriaged` | code 0: 3 {} |
| proc-old-7.5 | `untriaged` | code 0: 4 {} |
| proc-old-7.6 | `untriaged` | code 0: 1 {bad completion code "-14": must be ok, error, return, break, continue, or an... |

### proc.test

| Test | Bucket | Result (start) |
|---|---|---|
| proc-1.2 | `untriaged` | code 0:  |
| proc-3.4 | `untriaged` | code 0: {p in ::test_ns_1::baz} ::p |
| proc-6.1 | `untriaged` | code 0: 1 |

| Skipped by | Tests | Bucket |
|---|---|---|
| procbodytest | 9 | `untriaged` |

### reg.test

| Test | Bucket | Result (start) |
|---|---|---|
| reg-10.15.compile | `untriaged` | code 0: 0 REG_UEMPTYMATCH |
| reg-10.15.execute | `untriaged` | code 0: 1 {} |
| reg-11.1 ARE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-11.1 BRE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-11.2 ARE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-11.2 BRE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-11.3 ARE.compile | `untriaged` | code 0: REG_UNONPOSIX |
| reg-11.3 BRE.compile | `untriaged` | code 0: REG_UNONPOSIX |
| reg-11.4 ARE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-11.4 BRE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-11.5 ARE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-11.5 BRE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-11.6 ARE.compile | `untriaged` | code 0: REG_UNONPOSIX |
| reg-11.6 BRE.compile | `untriaged` | code 0: REG_UNONPOSIX |
| reg-13.33.execute | `untriaged` | code 0: 0 {} |
| reg-13.34.execute | `untriaged` | code 0: 0 {} |
| reg-13.6.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-15.13.execute | `untriaged` | code 0: 0 {} |
| reg-16.3.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-16.9.compile | `untriaged` | code 0: 0 {REG_UBRACES REG_UNONPOSIX REG_UUNSPEC} |
| reg-16.9.execute | `untriaged` | code 0: 0 {} |
| reg-17.1.compile | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-17.1.execute | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-19.4 ARE.compile | `untriaged` | code 0: 0 {} |
| reg-19.4 BRE.compile | `untriaged` | code 0: 0 {} |
| reg-19.5 ARE.compile | `untriaged` | code 0: {} |
| reg-19.5 BRE.compile | `untriaged` | code 0: {} |
| reg-2.1.error | `untriaged` | code 0: 0 REG_BADRPT |
| reg-2.2.error | `untriaged` | code 0: 0 REG_BADRPT |
| reg-2.3.error | `untriaged` | code 0: 0 REG_BADRPT |
| reg-2.4.error | `untriaged` | code 0: 0 REG_BADRPT |
| reg-2.5.error | `untriaged` | code 0: 0 REG_BADRPT |
| reg-20.1 ARE.error | `untriaged` | code 0: 1 REG_BADRPT |
| reg-20.1 BRE.error | `untriaged` | code 0: 1 REG_BADRPT |
| reg-20.3 ARE.compile | `untriaged` | code 0: 0 {} |
| reg-20.3 BRE.compile | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-20.3 BRE.execute | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-20.5.compile | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-20.5.execute | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-20.6.compile | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-20.6.execute | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-20.8 BRE.compile | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-20.8 BRE.execute | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-21.35.compile | `untriaged` | code 0: 3 {} |
| reg-21.35.execute | `untriaged` | code 0: 1 { TO foo} foo foo {} |
| reg-23.3.execute | `untriaged` | code 0: 1 ab |
| reg-23.4.execute | `untriaged` | code 0: 1 |
| reg-23.6.execute | `untriaged` | code 0: 0 {} |
| reg-29.1.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.10.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.11.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.12.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.13.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.14.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.15.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.16.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.17.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.2.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.3.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.4.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.5.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.6.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.7.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-29.8.execute | `untriaged` | code 1: testregexp: REG_EXPECT has no stand-in |
| reg-30.6 ARE.compile | `untriaged` | code 0: 0 {} |
| reg-30.6 BRE.compile | `untriaged` | code 0: 0 {} |
| reg-30.8.execute | `untriaged` | code 0: 1 |
| reg-30.9.execute | `untriaged` | code 0: 0 {} |
| reg-32.1 | `untriaged` | code 1: can't read "resvar": no such variable |
| reg-32.2 | `untriaged` | code 1: can't read "resvar": no such variable |
| reg-32.3 | `untriaged` | code 1: can't read "resvar": no such variable |
| reg-32.3.1 | `untriaged` | code 1: can't read "resvar": no such variable |
| reg-33.22 | `untriaged` | code 0: 0 |
| reg-6.5.compile | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-6.5.execute | `untriaged` | code 1: couldn't compile regular expression pattern: quantifier operand invalid |
| reg-9.10 ARE.error | `untriaged` | code 0: 0 REG_ECOLLATE |
| reg-9.10 BRE.error | `untriaged` | code 0: 0 REG_ECOLLATE |
| reg-9.11 ARE.compile | `untriaged` | code 0: 0 {} |
| reg-9.11 BRE.compile | `untriaged` | code 0: 0 {} |
| reg-9.13 ARE.compile | `untriaged` | code 0: {} |
| reg-9.13 BRE.compile | `untriaged` | code 0: {} |
| reg-9.14 ARE.error | `untriaged` | code 0: 0 REG_ECTYPE |
| reg-9.14 BRE.error | `untriaged` | code 0: 0 REG_ECTYPE |
| reg-9.15 ARE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-9.15 BRE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-9.16 ARE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-9.16 BRE.compile | `untriaged` | code 0: 0 REG_UNONPOSIX |
| reg-9.27 ARE.compile | `untriaged` | code 0: 0 {} |
| reg-9.27 BRE.compile | `untriaged` | code 0: 0 {} |
| reg-9.29 ARE.compile | `untriaged` | code 0: 0 {} |
| reg-9.29 BRE.compile | `untriaged` | code 0: 0 {} |
| reg-9.31 ARE.error | `untriaged` | code 0: 0 REG_ERANGE |
| reg-9.31 BRE.error | `untriaged` | code 0: 0 REG_ERANGE |
| reg-9.32 ARE.compile | `untriaged` | code 0: 0 {} |
| reg-9.32 BRE.compile | `untriaged` | code 0: 0 {} |
| reg-9.4 ARE.compile | `untriaged` | code 1: couldn't compile regular expression pattern: invalid collating element |
| reg-9.4 ARE.execute | `untriaged` | code 1: couldn't compile regular expression pattern: invalid collating element |
| reg-9.4 BRE.compile | `untriaged` | code 1: couldn't compile regular expression pattern: invalid collating element |
| reg-9.4 BRE.execute | `untriaged` | code 1: couldn't compile regular expression pattern: invalid collating element |
| reg-9.44.compile | `untriaged` | code 0: 0 {REG_UBBS REG_UNONPOSIX} |
| reg-9.5 ARE.compile | `untriaged` | code 1: couldn't compile regular expression pattern: invalid collating element |
| reg-9.5 ARE.execute | `untriaged` | code 1: couldn't compile regular expression pattern: invalid collating element |
| reg-9.5 BRE.compile | `untriaged` | code 1: couldn't compile regular expression pattern: invalid collating element |
| reg-9.5 BRE.execute | `untriaged` | code 1: couldn't compile regular expression pattern: invalid collating element |
| reg-9.6 ARE.compile | `untriaged` | code 0: 0 {} |
| reg-9.6 BRE.compile | `untriaged` | code 0: 0 {} |

| Skipped by | Tests | Bucket |
|---|---|---|
| localeRegexp | 100 | `untriaged` |
| knownBug | 9 | `tcl`: tclsh skips it too |
| nonPortable | 1 | `tcl`: tclsh skips it too |

### regexp.test

| Test | Bucket | Result (start) |
|---|---|---|
| regexp-22.5 | `untriaged` | code 0: 0 {REG_UBRACES REG_UUNSPEC} |

| Skipped by | Tests | Bucket |
|---|---|---|
| knownBug | 3 | `tcl`: tclsh skips it too |

### regexpComp.test

| Test | Bucket | Result (start) |
|---|---|---|
| regexpComp-21.10 | `untriaged` | code 0: 4 barfbarobarobar |
| regexpComp-21.11 | `untriaged` | code 0: 1 bar |

### registry.test

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 125 | `platform`: a constraint of another platform or word size |

### rename.test

| Test | Bucket | Result (start) |
|---|---|---|
| rename-5.1 | `untriaged` | code 1: wrong # args: should be "proc name args body" |

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
| result-6.3 | `untriaged` | code 0: eek |
| result-6.4 | `untriaged` | code 1: key "-errorcode" not known in dictionary |
| result-6.5 | `untriaged` | code 1: key "-errorcode" not known in dictionary |

| Skipped by | Tests | Bucket |
|---|---|---|
| testsaveresult | 11 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testsetobjerrorcode | 5 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testseterrorcode | 4 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testreturn | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### safe-stock.test

| Test | Bucket | Result (start) |
|---|---|---|
| safe-stock-7.1 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-stock-7.2 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-stock-7.4 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-stock-9.8 | `untriaged` | setup: invalid command name "safe::interpCreate" |

### safe.test

| Test | Bucket | Result (start) |
|---|---|---|
| safe-1.1 | `untriaged` | code 1: invalid command name "safe::interpConfigure" |
| safe-1.2 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-1.3 | `untriaged` | code 1: invalid command name "safe::interpInit" |
| safe-11.1 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-11.1a | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-11.2 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-11.3 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-11.4 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-11.5 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-11.6 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-11.7 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-11.7.1 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-11.8 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-11.8.1 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-12.1 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-12.2 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-12.3 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-12.4 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-12.5 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-12.6 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-12.7 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.1 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.10 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.2 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.3 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.4 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.5 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.6 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.7 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.7.1 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.8 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-13.9 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-15.1 | `untriaged` | code 1: invalid command name "tcl::file::split" |
| safe-15.2 | `untriaged` | code 1: invalid command name "tcl::file::split" |
| safe-16.1 | `untriaged` | setup: can't read "env(HOME)": no such variable |
| safe-16.2 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-16.3 | `untriaged` | setup: can't read "env(HOME)": no such variable |
| safe-16.4 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-16.5 | `untriaged` | setup: can't read "env(HOME)": no such variable |
| safe-16.6 | `untriaged` | setup: can't read "env(HOME)": no such variable |
| safe-16.7 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-16.8 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-2.2 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-2.3 | `untriaged` | code 1: interpreter named "a" already exists, cannot create |
| safe-3.1 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-3.2 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-3.3 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-3.4 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-4.1 | `untriaged` | code 1: interpreter named "a" already exists, cannot create |
| safe-4.2 | `untriaged` | code 1: interpreter named "a" already exists, cannot create |
| safe-4.5 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-4.6 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-5.1 | `untriaged` | cleanup: invalid command name "auto_reset" |
| safe-5.2 | `untriaged` | cleanup: invalid command name "auto_reset" |
| safe-5.3 | `untriaged` | code 0: 1 {can't find package SafeTestPackage1} 1 {can't find package SafeTestPackage2}... |
| safe-5.4 | `untriaged` | code 0: 1 {can't find package SafeTestPackage1} 1 {can't find package SafeTestPackage2}... |
| safe-5.5 | `untriaged` | setup: invalid command name "tcl::tm::path" |
| safe-5.6 | `untriaged` | setup: invalid command name "tcl::tm::path" |
| safe-6.1 | `untriaged` | code 0: errorCode errorInfo tcl_patchLevel tcl_platform tcl_precision tcl_version |
| safe-6.3 | `untriaged` | code 0: byteOrder engine machine os osVersion platform pointerSize user wordSize |
| safe-7.1 | `untriaged` | setup: invalid command name "safe::interpCreate" |
| safe-7.2 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-7.3 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-7.3.1 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-7.4 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-8.1 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-8.10 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-8.2 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-8.3 | `untriaged` | setup: invalid command name "safe::setLogCmd" |
| safe-8.4 | `untriaged` | setup: invalid command name "safe::setLogCmd" |
| safe-8.5 | `untriaged` | setup: invalid command name "safe::setLogCmd" |
| safe-8.6 | `untriaged` | setup: invalid command name "safe::setLogCmd" |
| safe-8.7 | `untriaged` | setup: invalid command name "safe::setLogCmd" |
| safe-8.9 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-9.1 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-9.10 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-9.11 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-9.12 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-9.13 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-9.2 | `untriaged` | setup: invalid command name "safe::setLogCmd" |
| safe-9.20 | `untriaged` | setup: invalid command name "tcl::tm::path" |
| safe-9.21 | `untriaged` | setup: invalid command name "tcl::tm::path" |
| safe-9.22 | `untriaged` | setup: invalid command name "tcl::tm::path" |
| safe-9.23 | `untriaged` | setup: invalid command name "tcl::tm::path" |
| safe-9.24 | `untriaged` | setup: invalid command name "tcl::tm::path" |
| safe-9.3 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-9.4 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-9.5 | `untriaged` | code 1: invalid command name "safe::interpCreate" |
| safe-9.6 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-9.7 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-9.8 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |
| safe-9.9 | `untriaged` | cleanup: invalid command name "safe::interpDelete" |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 1 | `untriaged` |
| TcltestPackage | 6 | `untriaged` |
| emptyTest | 2 | `tcl`: tclsh skips it too |

### scan.test

| Test | Bucket | Result (start) |
|---|---|---|
| scan-13.5 | `untriaged` | code 1: "%n$" argument index out of range |
| scan-13.6 | `untriaged` | code 0: 6 {"%n$" argument index out of range} |
| scan-13.7 | `untriaged` | code 1: "%n$" argument index out of range |
| scan-13.8 | `untriaged` | code 1: "%n$" argument index out of range |
| scan-14.1 | `untriaged` | code 2:  |
| scan-14.2 | `untriaged` | code 2:  |
| scan-4.15 | `untriaged` | code 0: 0 {} |
| scan-4.40.3 | `untriaged` | code 0: 2 9 0 0 |
| scan-4.41 | `untriaged` | code 0: 4 10 8 16 2 |
| scan-4.44 | `untriaged` | code 0: 0 {} |
| scan-4.45 | `untriaged` | code 0: 1 0 8 |
| scan-4.46 | `untriaged` | code 0: 1 0 8 |
| scan-4.55 | `untriaged` | code 0: 0 {} |
| scan-4.60 | `untriaged` | code 0: 1 {can't set "z": variable is array} abc {} |
| scan-5.17 | `untriaged` | code 0: 3 81985529216486895 81985529216486895 81985529216486895 |
| scan-5.18 | `untriaged` | code 0: 1 -81985529216486895 |
| scan-5.19 | `untriaged` | code 0: 1 81985529216486895 |
| scan-7.6 | `untriaged` | code 0: 4 abc dÇ fghijk dum |

| Skipped by | Tests | Bucket |
|---|---|---|
| nonPortable | 1 | `tcl`: tclsh skips it too |

### set-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| set-old-10.9 | `untriaged` | code 0: 1 {illegal search identifier "s-1-b"} |
| set-old-7.14 | `untriaged` | code 0: 1 0 1 0 1 |
| set-old-7.15 | `untriaged` | code 0: 1 0 0 1 1 1 0 1 |
| set-old-7.4 | `untriaged` | code 0: 1 {can't unset "a(14)": no such variable} |
| set-old-7.5 | `untriaged` | code 0: 1 {can't unset "a(14)": no such variable} |
| set-old-8.35 | `untriaged` | code 0: 1 {can't array set "a": variable isn't array} |
| set-old-8.38.5 | `untriaged` | code 0: 0 {} |
| set-old-8.38.6 | `untriaged` | code 0: 0 {} |
| set-old-8.38.7 | `untriaged` | code 0: 0 {} |
| set-old-8.49 | `untriaged` | code 0: 9 entries in table |
| set-old-9.10 | `untriaged` | code 0: 0 a 0 a |

### set.test

| Test | Bucket | Result (start) |
|---|---|---|
| set-2.4 | `untriaged` | code 0: 1 {can't set "x": variable is read-only} {can't set "x": variable is read-only ... |
| set-4.4 | `untriaged` | code 0: 1 {can't set "x": variable is read-only} {can't set "x": variable is read-only ... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testset2 | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### socket.test

| Test | Bucket | Result (start) |
|---|---|---|
| socket-14.11.0 | `untriaged` | code 0:  |
| socket-14.5 | `untriaged` | code 1: couldn't open socket: the network policy does not allow the address "192.0.2.42" |
| socket-14.8.0 | `untriaged` | code 0:  |
| socket-14.8.2 | `untriaged` | code 0: {} {connection refused} {} |
| socket-15.1.6 | `untriaged` | code 0: sock2842 |
| socket_inet-3.2 | `untriaged` | code 0: ready timed_out |
| socket_inet6-3.2 | `untriaged` | code 0: ready timed_out |

| Skipped by | Tests | Bucket |
|---|---|---|
| localhost_v6 | 9 | `untriaged` |
| nonPortable | 1 | `tcl`: tclsh skips it too |
| win | 1 | `platform`: a constraint of another platform or word size |

### source.test

| Test | Bucket | Result (start) |
|---|---|---|
| source-2.7 | `untriaged` | code 1: invalid command name "﻿set" |
| source-3.2 | `untriaged` | code 2: Silly result |
| source-3.3 | `untriaged` | code 0: 2 {Simulated error} {invalid command name "﻿set"     while executing "﻿set y ne... |
| source-3.4 | `untriaged` | code 0: 2 {} {invalid command name "﻿set"     while executing "﻿set y new-y"     (file ... |
| source-3.5 | `untriaged` | code 0: 2 {} {invalid command name "﻿set"     while executing "﻿set y new-y"     (file ... |
| source-4.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| source-7.2 | `untriaged` | setup: unknown encoding "unicode" |
| source-7.3 | `untriaged` | code 1: couldn't read file "no_file": no such file or directory |
| source-7.4 | `untriaged` | code 0:  |
| source-7.6 | `untriaged` | code 0: foo |

### split.test

| Test | Bucket | Result (start) |
|---|---|---|
| split-1.15 | `untriaged` | code 0: a � � � |

### stack.test

| Test | Bucket | Result (start) |
|---|---|---|
| stack-2.1 | `untriaged` | code 0: invalid command name "notaknownproc" |
| stack-3.1 | `untriaged` | code 1: 1 1 the recursion limit of this interpreter is 600 |

### string.test

| Test | Bucket | Result (start) |
|---|---|---|
| string-21.23.0 | `untriaged` | code 0: Hello world! |
| string-21.23.1 | `untriaged` | code 0: Hello world! |
| string-21.24.0 | `untriaged` | code 0: Hello world!�� |
| string-21.24.1 | `untriaged` | code 0: Hello world!�� |
| string-21.25.0 | `untriaged` | code 0: ��Hello world! |
| string-21.25.1 | `untriaged` | code 0: ��Hello world! |
| string-24.15.0 | `untriaged` | code 1: invalid command name "tcl::string::reverse" |
| string-24.15.1 | `untriaged` | code 1: invalid command name "tcl::string::reverse" |

| Skipped by | Tests | Bucket |
|---|---|---|
| testbytestring | 8 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| memory | 6 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testindexobj | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| utf16 | 2 | `untriaged` |

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
| subst-11.4 | `untriaged` | code 0: foo  |
| subst-11.5 | `untriaged` | code 0: foo  |

| Skipped by | Tests | Bucket |
|---|---|---|
| testbytestring | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### switch.test

| Test | Bucket | Result (start) |
|---|---|---|
| switch-13.5 | `untriaged` | code 0: 1 - a {can't set "x(x)": variable isn't array} |
| switch-13.6 | `untriaged` | code 0: 1 - - {can't set "y(y)": variable isn't array} |
| switch-4.1 | `untriaged` | code 0: 1 {Just a test} {Just a test     while executing "error "Just a test""     invo... |
| switch-4.5 | `untriaged` | code 0: 1 switch2 {switch2     while executing "error switch2"     invoked from within ... |
| switch-9.2 | `untriaged` | code 1: wrong # args: should be "switch ?-option ...? string ?pattern body ...? ?defaul... |
| switch-9.3 | `untriaged` | code 1: wrong # args: should be "switch ?-option ...? string ?pattern body ...? ?defaul... |
| switch-9.4 | `untriaged` | code 1: wrong # args: should be "switch ?-option ...? string ?pattern body ...? ?defaul... |

### tailcall.test

| Test | Bucket | Result (start) |
|---|---|---|
| tailcall-1 | `untriaged` | code 0: 1::b \| 0:: *::a *::b \| {{1 ::b::moo} {2 ::a::xset}} |
| tailcall-11c | `untriaged` | code 0: {0 2 3} {0 2 3} |
| tailcall-12.2 | `untriaged` | output: 1: fred alpha 1: inside foo's alpha, v resolves to global level 1: foo's alpha ... |
| tailcall-12.3a0 | `untriaged` | code 0: 2 |
| tailcall-12.3a1 | `untriaged` | code 1: wrong # args: should be "tailcall command ?arg ...?" |
| tailcall-12.3b0 | `untriaged` | code 0: 2 |
| tailcall-12.3b1 | `untriaged` | code 1: wrong # args: should be "tailcall command ?arg ...?" |
| tailcall-14.1 | `untriaged` | code 1: invalid command name "p" |
| tailcall-14.1-bc | `untriaged` | code 1: invalid command name "p" |

| Skipped by | Tests | Bucket |
|---|---|---|
| testnrelevels | 8 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### tcltest.test

| Test | Bucket | Result (start) |
|---|---|---|
| tcltest-1.1 | `untriaged` | code 0: 1 0 |
| tcltest-1.2 | `untriaged` | code 0: 1 0 |
| tcltest-2.0 | `untriaged` | code 1: invalid command name "i" |
| tcltest-2.1 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-2.2 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-2.3 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-2.4 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-2.5 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-2.5a | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-2.6 | `untriaged` | code 1: invalid command name "-constraints" |
| tcltest-2.6a | `untriaged` | code 1: invalid command name "-constraints" |
| tcltest-2.7 | `untriaged` | code 1: invalid command name "-body" |
| tcltest-2.8 | `untriaged` | code 1: invalid command name "-constraints" |
| tcltest-3.1 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-3.2 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-3.3 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-3.4 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-3.5 | `untriaged` | code 1: invalid command name "-body" |
| tcltest-4.1 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-4.2 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-4.3 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-4.4 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-4.5 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-4.6 | `untriaged` | code 1: invalid command name "-body" |
| tcltest-5.1 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-5.2 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-5.3 | `untriaged` | code 1: invalid command name "-body" |
| tcltest-6.1 | `untriaged` | code 1: invalid command name "-constraints" |
| tcltest-6.2 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-6.3 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-6.4 | `untriaged` | code 1: interpreter named "::tcltest::test::i" already exists, cannot create |
| tcltest-6.5 | `untriaged` | code 1: invalid command name "-setup" |
| tcltest-6.6 | `untriaged` | code 1: invalid command name "-setup" |
| tcltest-6.7 | `untriaged` | code 1: invalid command name "-setup" |
| tcltest-6.8 | `untriaged` | code 1: invalid command name "-setup" |
| tcltest-7.2 | `untriaged` | code 0: 0 0 |
| tcltest-7.3 | `untriaged` | code 0: 0 0 |
| tcltest-7.4 | `untriaged` | code 0: 0 0 |
| tcltest-7.5 | `untriaged` | code 0: 0 0 |
| tcltest-7.6 | `untriaged` | code 1: invalid command name "-setup" |

| Skipped by | Tests | Bucket |
|---|---|---|
| (file stopped early, status 0) | 116 | `untriaged` |
| expr:!singleTestInterp notWsl | 1 | `untriaged` |

### thread.test

| Skipped by | Tests | Bucket |
|---|---|---|
| drainEventQueue | 34 | `untriaged` |

### timer.test

| Test | Bucket | Result (start) |
|---|---|---|
| timer-10.1 | `untriaged` | setup: import pattern "::after" tries to import from namespace "foo" into itself |

### tm.test

| Test | Bucket | Result (start) |
|---|---|---|
| tm-1.1 | `untriaged` | code 0:  |
| tm-1.2 | `untriaged` | code 1: invalid command name "::tcl::tm::path" |
| tm-1.3 | `untriaged` | code 1: invalid command name "::tcl::tm::path" |
| tm-1.4 | `untriaged` | code 1: invalid command name "::tcl::tm::path" |
| tm-1.5 | `untriaged` | code 1: invalid command name "::tcl::tm::path" |
| tm-2.1 | `untriaged` | code 0:  |
| tm-2.2 | `untriaged` | code 1: invalid command name "::tcl::tm::roots" |
| tm-2.3 | `untriaged` | code 1: invalid command name "::tcl::tm::roots" |
| tm-3.1 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.10 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.11 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.12 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.13 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.2 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.3 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.4 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.5 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.6 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.7 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.8 | `untriaged` | setup: invalid command name "::tcl::tm::path" |
| tm-3.9 | `untriaged` | setup: invalid command name "::tcl::tm::path" |

### trace.test

| Test | Bucket | Result (start) |
|---|---|---|
| trace-1.11 | `untriaged` | code 0: bar 0 |
| trace-1.12 | `untriaged` | code 0: bar 0 |
| trace-1.13 | `untriaged` | code 0: 0 {bar 0} |
| trace-1.14 | `untriaged` | code 0: 0 {bar 0} |
| trace-1.4 | `untriaged` | code 0: 1 {can't read "x(2)": no such variable} {} |
| trace-12.1 | `untriaged` | code 0: 0 22 |
| trace-12.2 | `untriaged` | code 0: 1 {can't read "x(0)": no such variable} |
| trace-12.8 | `untriaged` | code 0: 0 {} |
| trace-16.10 | `untriaged` | code 0: 0 {} 1 {can't read "x": no such variable} 1 {can't read "y(0)": no such variable} |
| trace-16.13 | `untriaged` | code 0: 0 {} 0 xyzzy 0 xyzzy 0 xyzzy |
| trace-16.14 | `untriaged` | code 0: 0 {} 0 xyzzy 0 xyzzy 0 xyzzy |
| trace-16.16 | `untriaged` | code 0: 1 {can't unset "x": no such variable} 1 {can't read "y(0)": no such element in ... |
| trace-16.19 | `untriaged` | code 0: 1 {can't unset "y(0)": no such variable} 0 xyzzy 0 {} 0 xyzzy |
| trace-16.2 | `untriaged` | code 0: 0 {} 1 {can't read "y(0)": no such element in array} 1 {can't read "y(0)": no s... |
| trace-16.22 | `untriaged` | code 0: third 0 {} 1 {can't read "x": no such variable} 1 {can't read "y(0)": no such v... |
| trace-16.6 | `untriaged` | code 0: 0 {} 0 xyzzy 0 xyzzy 0 xyzzy |
| trace-16.7 | `untriaged` | code 0: 0 {} 0 xyzzy 0 xyzzy 0 xyzzy |
| trace-16.8 | `untriaged` | code 0: unset 0 {} 1 {can't read "x": no such variable} 1 {can't read "y": no such vari... |
| trace-16.9 | `untriaged` | code 0: 0 {} 1 {can't read "y(0)": no such element in array} 1 {can't read "y(0)": no s... |
| trace-18.1 | `untriaged` | code 0: 0 {} |
| trace-18.4 | `untriaged` | code 0:  |
| trace-2.7 | `untriaged` | code 0: errorInfo {} write |
| trace-20.10 | `untriaged` | code 1: can't delete "someothername": command doesn't exist |
| trace-20.8 | `untriaged` | code 0: {} {{{rename delete} {traceDelete foo}}} |
| trace-20.9 | `untriaged` | code 0: {} bar {} |
| trace-21.11 | `untriaged` | code 0: ::a ::a |
| trace-21.4 | `untriaged` | code 0: {foo {foo 3} enter} {foo {foo 3} 0 3 leave} |
| trace-21.5 | `untriaged` | code 0: {foo {foo 3} enter} {foo {foo 3} 0 3 leave} |
| trace-21.6 | `untriaged` | code 0:  |
| trace-21.7 | `untriaged` | code 0:  |
| trace-21.8 | `untriaged` | code 0:  |
| trace-23.1 | `untriaged` | code 0: {factorial 1} enter {factorial 1} 0 1 leave |
| trace-23.2 | `untriaged` | code 0: {factorial 2} enter {factorial 1} enter {factorial 1} 0 1 leave {factorial 2} 0... |
| trace-23.3 | `untriaged` | code 0: {factorial 3} enter {factorial 2} enter {factorial 1} enter {factorial 1} 0 1 l... |
| trace-24.3 | `untriaged` | code 1: wrong # args: should be "trace remove execution name opList command" |
| trace-24.4 | `untriaged` | code 1: wrong # args: should be "trace remove execution name opList command" |
| trace-24.5 | `untriaged` | code 0: {{foo 1} 0 1 leave} 0 {} |
| trace-25.1 | `untriaged` | code 0: 1 {{foo 1} enter} 1 {unknown command "foo"} |
| trace-25.10 | `untriaged` | code 0: 1 {{foo 1} 0 1 leave} 1 {unknown command "foo"} |
| trace-25.11 | `untriaged` | code 0: 1 {{foo 1} enter} 1 {unknown command "foo"} |
| trace-25.3 | `untriaged` | code 0: {can't delete "foo": command doesn't exist} {{foo 1} enter} 1 {unknown command ... |
| trace-25.5 | `untriaged` | code 0: 1   |
| trace-25.6 | `untriaged` | code 0: 1 tracePostExecute2 {foo 1} 0 leave tracePostExecute {foo 1} 0 leave  |
| trace-25.7 | `untriaged` | code 0: 1   |
| trace-25.8 | `untriaged` | code 0: {can't delete "foo": command doesn't exist} {{foo 1} enter} 1 {unknown command ... |
| trace-25.9 | `untriaged` | code 0: {can't delete "foo": command doesn't exist} {{foo 1} enter} 1 {unknown command ... |
| trace-28.1 | `untriaged` | code 0: foo foo enter foo foo 0 1 leave |
| trace-28.2 | `untriaged` | code 0: {error error} {foo foo enter foo foo 0 error leave} |
| trace-28.3 | `untriaged` | code 0: {error error} {foo foo enter foo foo 0 error leave} |
| trace-28.4 | `untriaged` | code 0: {error error} {foo foo enter foo foo 0 error leave} |
| trace-28.5 | `untriaged` | code 0: foo {foo test-28.4} enter foo {foo test-28.4} 0 1 leave |
| trace-28.6 | `untriaged` | code 0:  |
| trace-34.1 | `untriaged` | code 0: foo |
| trace-34.2 | `untriaged` | code 1: invalid command name "soom" |
| trace-34.4 | `untriaged` | code 0: notrace |
| trace-34.5 | `untriaged` | code 0: notrace |
| trace-35.1 | `untriaged` | code 0: 1 {can't set "y": can't set "x": foo} {can't set "y": can't set "x": foo     wh... |
| trace-37.2 | `untriaged` | code 0: - * |
| trace-38.2 | `untriaged` | code 0: - * |
| trace-39.1 | `untriaged` | code 1: unknown command "::tcl::string::equal" |
| trace-4.4 | `untriaged` | code 0:  |
| trace-4.6 | `untriaged` | code 0:  |
| trace-5.6 | `untriaged` | code 0: x {} array |
| trace-6.2 | `untriaged` | code 0: x 0 write x 0 read x 0 write x 0 unset |
| trace-7.3 | `untriaged` | code 0: A3 3 A2 2 A1 1 |
| trace-8.4 | `untriaged` | code 0: 0 {} {} |

| Skipped by | Tests | Bucket |
|---|---|---|
| testcmdtrace | 11 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| memory | 3 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testevalobjv | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| emptyTest | 1 | `tcl`: tclsh skips it too |

### unixFCmd.test

| Test | Bucket | Result (start) |
|---|---|---|
| unixFCmd-1.1 | `untriaged` | cleanup: file attributes is not available |
| unixFCmd-1.2 | `untriaged` | code 1: error renaming "td2" to "td1": target file exists |
| unixFCmd-1.3 | `untriaged` | code 1: error renaming "td1" to "td1": invalid argument |
| unixFCmd-1.7 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-12.1 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-12.2 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-13.1 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-13.2 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-14.1 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-14.2 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-15.1 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-15.2 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-16.1 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-16.2 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-16.3 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-17.1 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-17.11 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-17.12 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-17.2 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-17.3 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-17.4 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-17.5 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-17.6 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-17.7 | `untriaged` | code 1: file attributes is not available |
| unixFCmd-2.2.2 | `untriaged` | code 1: could not link: links are not available in the root folder |
| unixFCmd-2.3 | `untriaged` | code 1: could not read "/dev/null": no such file or directory |
| unixFCmd-2.4 | `untriaged` | code 1: error copying "tf1": permission denied |
| unixFCmd-2.5 | `untriaged` | code 1: file attributes is not available |

| Skipped by | Tests | Bucket |
|---|---|---|
| emptyTest | 11 | `tcl`: tclsh skips it too |
| readonlyAttr | 4 | `untriaged` |
| nonPortable | 3 | `tcl`: tclsh skips it too |
| dontCopyLinks | 1 | `untriaged` |

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
| unixInit-1.2 | `untriaged` | code 0: Expected: '127.0.0.1 localhost 39839', Got '' |
| unixInit-3.2 | `untriaged` | code 0: 1 |
| unixInit-4.1 | `untriaged` | code 1: can't read "tcl_pkgPath": no such variable |
| unixInit-7.1 | `untriaged` | code 1: couldn't open "/dev/null": no such file or directory |

| Skipped by | Tests | Bucket |
|---|---|---|
| emptyTest | 2 | `tcl`: tclsh skips it too |

### unixNotfy.test

| Skipped by | Tests | Bucket |
|---|---|---|
| unthreaded | 2 | `untriaged` |

### unload.test

| Test | Bucket | Result (start) |
|---|---|---|
| unload-1.1 | `untriaged` | code 1: invalid command name "unload" |
| unload-1.2 | `untriaged` | code 1: invalid command name "unload" |
| unload-1.3 | `untriaged` | code 1: invalid command name "unload" |
| unload-1.4 | `untriaged` | code 1: invalid command name "unload" |
| unload-1.5 | `untriaged` | code 1: invalid command name "unload" |
| unload-1.6 | `untriaged` | code 1: invalid command name "unload" |
| unload-1.7 | `untriaged` | code 1: invalid command name "unload" |

| Skipped by | Tests | Bucket |
|---|---|---|
| pkgua.soRequired | 20 | `untriaged` |

### uplevel.test

| Test | Bucket | Result (start) |
|---|---|---|
| uplevel-4.0.1 | `untriaged` | code 0: 222 |
| uplevel-4.0.2 | `untriaged` | code 0: 222 |
| uplevel-4.17 | `untriaged` | code 1: invalid command name "-0xffffffff" |
| uplevel-4.18 | `untriaged` | code 1: bad level "#-0xffffffff" |
| uplevel-4.19 | `untriaged` | code 1: invalid command name "-4294967295" |
| uplevel-4.20 | `untriaged` | code 1: bad level "#-4294967295" |
| uplevel-4.9 | `untriaged` | code 1: invalid command name "-0" |
| uplevel-8.0 | `untriaged` | code 1: invalid command name "::tcl::unsupported::representation" |

### upvar.test

| Test | Bucket | Result (start) |
|---|---|---|
| upvar-10.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| upvar-5.3 | `untriaged` | code 0: {x1 {} unset} {} |
| upvar-8.11 | `untriaged` | code 0:  |
| upvar-8.4 | `untriaged` | code 0:  |
| upvar-8.5 | `untriaged` | code 0:  |
| upvar-8.7 | `untriaged` | code 1: variable "a" already exists |
| upvar-8.8 | `untriaged` | cleanup: can't unset "x": no such variable |
| upvar-8.9 | `untriaged` | code 1: can't unset "::test_ns_1::a": no such variable |
| upvar-NS-1.3 | `untriaged` | code 1: can't read "w": no such variable |
| upvar-NS-1.4 | `untriaged` | code 1: can't read "w": no such variable |
| upvar-NS-1.9 | `untriaged` | code 1: can't read "w": no such variable |
| upvar-NS-3.1 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| upvar-NS-3.2 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| upvar-NS-3.3 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |

| Skipped by | Tests | Bucket |
|---|---|---|
| testupvar | 8 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### utf.test

| Test | Bucket | Result (start) |
|---|---|---|
| utf-10.45 | `untriaged` | code 0: 225 |
| utf-10.56 | `untriaged` | code 0: 65533 |
| utf-10.57 | `untriaged` | code 0: 65533 |
| utf-10.58 | `untriaged` | code 0: 65533 |
| utf-10.60 | `untriaged` | code 0: 65533 |
| utf-10.61 | `untriaged` | code 0: 65533 |
| utf-10.62 | `untriaged` | code 0: 65533 |
| utf-11.4 | `untriaged` | code 0: ǣGH |
| utf-11.5 | `untriaged` | code 0: აᲐ |
| utf-11.6 | `untriaged` | code 0: 𐐨 |
| utf-12.4 | `untriaged` | code 0: Ǣgh |
| utf-12.5 | `untriaged` | code 0: აᲐ |
| utf-12.7 | `untriaged` | code 0: 𐐀 |
| utf-13.8 | `untriaged` | code 0: 𐐨𐐀 |
| utf-16.2 | `untriaged` | code 0: ÿÿꞍǆ |
| utf-18.3 | `untriaged` | code 0: ſ |
| utf-21.11 | `untriaged` | code 0: 0 |
| utf-21.12 | `untriaged` | code 0: 0 |
| utf-21.2 | `untriaged` | code 0: 1 0 |
| utf-24.1 | `untriaged` | code 0: 0 |
| utf-24.2 | `untriaged` | code 0: 0 0 |

| Skipped by | Tests | Bucket |
|---|---|---|
| testutfnext | 152 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testutfprev | 103 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testbytestring | 26 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| ucs2 | 17 | `platform`: a constraint of another platform or word size |
| testnumutfchars | 15 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| utf16 | 15 | `untriaged` |
| testgetunichar | 12 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| teststringobj | 9 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| pre388 | 2 | `untriaged` |
| pairsTo4bytes | 1 | `untriaged` |
| testfindfirst | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testfindlast | 1 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### util.test

| Test | Bucket | Result (start) |
|---|---|---|
| util-14.1 | `untriaged` | code 0: NaN |
| util-14.2 | `untriaged` | code 0: NaN |
| util-17.1 | `untriaged` | code 0: 0x43fffffffffffffc -3c00000000000004 0x43fffffffffffffc -3c00000000000004 0x43f... |
| util-3.1 | `untriaged` | code 0: #\ \\\{\ \\ 1 |
| util-3.3 | `untriaged` | code 0: #\{ # a |
| util-3.5.1 | `untriaged` | code 0:  |
| util-3.6 | `untriaged` | code 1: target interpreter for alias "x" in path "" is not my descendant |
| util-4.1 | `untriaged` | code 0: a b\ c |
| util-4.2 | `untriaged` | code 0: a b\ c |
| util-4.3 | `untriaged` | code 0: a b\\ c |
| util-5.40 | `untriaged` | code 0: 1 |
| util-5.41 | `untriaged` | code 0: 0 |
| util-5.43 | `untriaged` | code 0: 0 |
| util-5.44 | `untriaged` | code 0: 0 |
| util-7.2 | `untriaged` | code 0: 0 12 |
| util-7.3 | `untriaged` | code 0: {0 8} 12 |
| util-8.1 | `untriaged` | code 1: target interpreter for alias "fooset" in path "" is not my descendant |
| util-9.2.1 | `untriaged` | code 0: d |
| util-9.2.2 | `untriaged` | code 0: d |
| util-9.32 | `untriaged` | code 0:  |
| util-9.33 | `untriaged` | code 0:  |
| util-9.44 | `untriaged` | code 0:  |
| util-9.5.2 | `untriaged` | code 0: c |

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
| var-1.11 | `untriaged` | code 0: 314159 |
| var-1.12 | `untriaged` | code 0: 1997 |
| var-1.15 | `untriaged` | code 0: 0 2 0 3 1 {can't set "foo(3)": variable isn't array} |
| var-1.16 | `untriaged` | code 1: can't read "result": no such variable |
| var-1.17 | `untriaged` | code 1: can't read "result": no such variable |
| var-1.18 | `untriaged` | code 1: can't read "result": no such variable |
| var-10.1 | `untriaged` | code 0:  |
| var-10.2 | `untriaged` | code 0:  |
| var-11.1 | `untriaged` | code 1: bad option "-dict": must be -ascii, -command, -decreasing, -dictionary, -increa... |
| var-20.10 | `untriaged` | code 0:  |
| var-21.0 | `untriaged` | code 1: unknown or ambiguous subcommand "frame": must be args, body, cmdcount, commands... |
| var-3.10 | `untriaged` | code 0: 0 1 |
| var-3.11 | `untriaged` | code 0:  |
| var-3.9 | `untriaged` | code 0:  |
| var-7.1 | `untriaged` | code 0: test_ns_var::one 1 |
| var-7.14 | `untriaged` | code 0:  |
| var-7.15 | `untriaged` | code 0:  |
| var-7.16 | `untriaged` | code 1: wrong # args: should be "variable ?name value...? name ?value?" |
| var-7.17 | `untriaged` | code 1: wrong # args: should be "variable ?name value...? name ?value?" |
| var-7.3 | `untriaged` | code 0: {test_ns_var::one test_ns_var::two} 2 |
| var-7.4 | `untriaged` | code 0: {test_ns_var::four test_ns_var::one test_ns_var::three test_ns_var::two} 7 |
| var-7.7 | `untriaged` | code 0:  |
| var-7.9 | `untriaged` | code 0: test_ns_var2::x 1 0 0 {1 {can't read "test_ns_var2::y": no such variable}} test... |
| var-8.2 | `untriaged` | code 0: {} {} |

| Skipped by | Tests | Bucket |
|---|---|---|
| testsetnoerr | 12 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| memory | 3 | `internals`: the memory debugging of a Tcl build with TCL_MEM_DEBUG |
| testgetvarfullname | 3 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |
| testupvar | 2 | `internals`: a C test command of the Tcl test binary, with no stand-in yet |

### while-old.test

| Test | Bucket | Result (start) |
|---|---|---|
| while-old-4.6 | `untriaged` | code 0: 1 {loop aborted} {loop aborted     while executing "error "loop aborted""     i... |

### while.test

| Test | Bucket | Result (start) |
|---|---|---|
| while-4.9 | `untriaged` | code 0: wrong # args: should be "set varName ?newValue?"     while executing "set"     ... |

### winConsole.test

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 1 | `platform`: a constraint of another platform or word size |

### winDde.test

| Skipped by | Tests | Bucket |
|---|---|---|
| dde | 49 | `untriaged` |
| win | 1 | `platform`: a constraint of another platform or word size |

### winFCmd.test

| Skipped by | Tests | Bucket |
|---|---|---|
| win | 170 | `platform`: a constraint of another platform or word size |
| nt | 4 | `platform`: a constraint of another platform or word size |
| winVista | 3 | `untriaged` |
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
| word-1.3 | `untriaged` | code 0: 5 |
| word-1.4 | `untriaged` | code 0: 5 |
| word-1.5 | `untriaged` | code 0: 5 |
| word-1.7 | `untriaged` | code 0: 5 |
| word-1.8 | `untriaged` | code 0: 5 |

### zlib.test

| Test | Bucket | Result (start) |
|---|---|---|
| zlib-15.1 | `untriaged` | setup: invalid command name "zlib" |

| Skipped by | Tests | Bucket |
|---|---|---|
| zlib | 71 | `untriaged` |
| knownBug | 1 | `tcl`: tclsh skips it too |
