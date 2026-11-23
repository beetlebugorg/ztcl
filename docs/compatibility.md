# Compatibility with the Tcl 8.6.16 tests

This page lists each of the 152 test files of Tcl 8.6.16. `tools/suite-table.py` makes it from a run of `tools/suite.sh -a`. The repository has no copy of the tests.

## How to read the counts

- **Total** is the number of tests in the file. `tools/suite-count.tcl` counts the `test` calls in a safe tclsh, and a text search counts the test lines. The table uses the larger count, or the count of tests that ran if that is larger.
- **Pass** and **Fail** are results of ztcl with the stand-in `tools/tcltest.tcl`.
- **Blocked** is Total minus Pass minus Fail. A blocked test did not run, so it is not a pass. A false constraint blocked it, or the file stopped before it (`unreached`).
- **Blocked by** gives the largest constraints and their counts. Tcl also skips some of these, for example `knownBug` and `emptyTest`.

## Scopes

- **In scope:** the language and the core commands.
- **Needs a decision:** tests of commands that the sandbox omits today, such as `file`, `open`, `socket`, `exec`, `clock`, and `interp`.
- **Cannot apply:** tests of the C API through the `test*` commands of the Tcl test binary, tests for Windows or macOS only, and tests of threads.

## Totals

| Scope | Files | Total | Pass | Fail | Blocked | Pass rate |
|---|---|---|---|---|---|---|
| In scope | 77 | 29358 | 24931 | 1377 | 3050 | 84.9 % |
| Needs a decision | 49 | 15027 | 31 | 9173 | 5823 | 0.2 % |
| Cannot apply | 26 | 1178 | 4 | 283 | 891 | 0.3 % |
| **All** | **152** | **45563** | **24966** | **10833** | **9764** | **54.8 %** |

## In scope

| File | Total | Pass | Fail | Blocked | Blocked by | Reason |
|---|---|---|---|---|---|---|
| `append.test` | 45 | 42 | 3 | 0 |  | language and core commands |
| `appendComp.test` | 48 | 39 | 4 | 5 | `expr:bug-3057639` 5 | language and core commands |
| `apply.test` | 42 | 33 | 5 | 4 | `memory` 3, `applylambda` 1 | language and core commands |
| `basic.test` | 146 | 49 | 15 | 82 | `testevalex` 43, `emptyTest` 27, `exec` 4 | core, partly through the C API |
| `binary.test` | 717 | 602 | 36 | 79 | `bigEndian` 76, `testsetbytearraylength` 2, `win` 1 | language and core commands |
| `case.test` | 15 | 15 | 0 | 0 |  | language and core commands |
| `cmdIL.test` | 146 | 128 | 12 | 6 | `hasIsoLocale` 2, `memory` 2, `testWithLimit` 1 | language and core commands |
| `cmdMZ.test` | 92 | 49 | 16 | 27 | `Unix` 1, unreached 26 | language and core commands |
| `compExpr-old.test` | 190 | 183 | 0 | 7 | `testmathfunctions` 5, `expr:!ieeeFloatingPoint` 1, `longIs32bit` 1 | language and core commands |
| `compExpr.test` | 80 | 76 | 0 | 4 | `memory` 2, `testmathfunctions` 2 | language and core commands |
| `compile.test` | 171 | 71 | 66 | 34 | `testevalex` 22, `knownBug` 9, `memory` 2 | the compiler, through scripts |
| `concat.test` | 9 | 9 | 0 | 0 |  | language and core commands |
| `coroutine.test` | 59 | 0 | 56 | 3 | `testnrelevels` 2, `memory` 1 | coroutines |
| `dict.test` | 342 | 311 | 29 | 2 | `memory` 2 | language and core commands |
| `error.test` | 317 | 300 | 9 | 8 | `memory` 8 | language and core commands |
| `eval.test` | 12 | 11 | 1 | 0 |  | language and core commands |
| `execute.test` | 157 | 63 | 13 | 81 | `testobj` 77, `longIs32bit` 3, `testexprlongobj` 1 | the bytecode engine, through scripts |
| `expr-old.test` | 460 | 421 | 5 | 34 | `testexprlong` 16, `testexprdouble` 7, `expr:!ieeeFloatingPoint` 3 | language and core commands |
| `expr.test` | 14185 | 14121 | 15 | 49 | `testexprlongobj` 16, `testmathfunctions` 11, `longIs32bit` 8 | language and core commands |
| `for-old.test` | 9 | 9 | 0 | 0 |  | language and core commands |
| `for.test` | 88 | 60 | 4 | 24 | `memory` 24 | language and core commands |
| `foreach.test` | 43 | 41 | 2 | 0 |  | language and core commands |
| `format.test` | 266 | 225 | 32 | 9 | `longIs32bit` 7, `wideBiggerThanInt` 2 | language and core commands |
| `get.test` | 22 | 5 | 1 | 16 | `testgetint` 15, `testdoubleobj` 1 | language and core commands |
| `if-old.test` | 33 | 33 | 0 | 0 |  | language and core commands |
| `if.test` | 73 | 73 | 0 | 0 |  | language and core commands |
| `incr-old.test` | 14 | 12 | 2 | 0 |  | language and core commands |
| `incr.test` | 66 | 62 | 4 | 0 |  | language and core commands |
| `info.test` | 266 | 97 | 161 | 8 | `knownBug` 3, `testevalex` 2, unreached 3 | language and core commands |
| `join.test` | 10 | 10 | 0 | 0 |  | language and core commands |
| `lindex.test` | 83 | 44 | 2 | 37 | `testevalex` 37 | language and core commands |
| `linsert.test` | 28 | 28 | 0 | 0 |  | language and core commands |
| `list.test` | 78 | 77 | 1 | 0 |  | language and core commands |
| `listObj.test` | 47 | 42 | 0 | 5 | `testobj` 4, `emptyTest` 1 | lists, partly through the C API |
| `llength.test` | 6 | 6 | 0 | 0 |  | language and core commands |
| `lmap.test` | 66 | 60 | 6 | 0 |  | language and core commands |
| `lrange.test` | 34 | 32 | 0 | 2 | `testpurebytesobj` 2 | language and core commands |
| `lrepeat.test` | 12 | 5 | 7 | 0 |  | language and core commands |
| `lreplace.test` | 1787 | 1787 | 0 | 0 |  | language and core commands |
| `lsearch.test` | 118 | 111 | 7 | 0 |  | language and core commands |
| `lset.test` | 89 | 0 | 0 | 89 | `testevalex` 88, `testobj` 1 | language and core commands |
| `lsetComp.test` | 19 | 19 | 0 | 0 |  | language and core commands |
| `mathop.test` | 349 | 347 | 2 | 0 |  | language and core commands |
| `misc.test` | 301 | 1 | 1 | 299 | `testhashsystemhash` 299 | language and core commands |
| `namespace-old.test` | 126 | 114 | 12 | 0 |  | language and core commands |
| `namespace.test` | 313 | 230 | 80 | 3 | `knownBug` 1, `memory` 1, `testevalobjv` 1 | language and core commands |
| `nre.test` | 28 | 2 | 3 | 23 | `testnrelevels` 23 | non-recursive evaluation |
| `oo.test` | 306 | 0 | 288 | 18 | `memory` 14, `knownBug` 3, unreached 1 | TclOO |
| `ooNext2.test` | 62 | 0 | 57 | 5 | `memory` 5 | TclOO |
| `parse.test` | 271 | 84 | 6 | 181 | `testparser` 117, `testevalex` 29, `testparsevarname` 12 | the parser, partly through the C API |
| `parseExpr.test` | 284 | 13 | 54 | 217 | `testexprparser` 215 | the expression parser, partly through the C API |
| `parseOld.test` | 158 | 153 | 2 | 3 | `testbytestring` 3 | language and core commands |
| `proc-old.test` | 74 | 64 | 10 | 0 |  | language and core commands |
| `proc.test` | 38 | 25 | 12 | 1 | `memory` 1 | language and core commands |
| `reg.test` | 1141 | 25 | 9 | 1107 | `testregexp` 1099, `knownBug` 7, `nonPortable` 1 | regular expressions; most tests use `testregexp` |
| `regexp.test` | 244 | 209 | 31 | 4 | `knownBug` 3, `exec` 1 | language and core commands |
| `regexpComp.test` | 179 | 153 | 25 | 1 | `exec` 1 | language and core commands |
| `rename.test` | 19 | 10 | 1 | 8 | `testdel` 8 | language and core commands |
| `scan.test` | 181 | 145 | 35 | 1 | `nonPortable` 1 | language and core commands |
| `set-old.test` | 153 | 142 | 11 | 0 |  | language and core commands |
| `set.test` | 64 | 61 | 2 | 1 | `testset2` 1 | language and core commands |
| `split.test` | 17 | 16 | 1 | 0 |  | language and core commands |
| `string.test` | 634 | 618 | 6 | 10 | `testbytestring` 4, `memory` 3, `testevalex` 1 | language and core commands |
| `stringComp.test` | 279 | 278 | 0 | 1 | `memory` 1 | language and core commands |
| `subst.test` | 63 | 56 | 6 | 1 | `testbytestring` 1 | language and core commands |
| `switch.test` | 113 | 105 | 8 | 0 |  | language and core commands |
| `tailcall.test` | 37 | 3 | 26 | 8 | `testnrelevels` 8 | `tailcall` |
| `trace.test` | 295 | 209 | 69 | 17 | `testcmdtrace` 11, `memory` 3, `testevalobjv` 2 | `trace` |
| `unknown.test` | 7 | 7 | 0 | 0 |  | language and core commands |
| `uplevel.test` | 57 | 49 | 8 | 0 |  | language and core commands |
| `upvar.test` | 65 | 42 | 15 | 8 | `testupvar` 8 | language and core commands |
| `utf.test` | 498 | 118 | 26 | 354 | `testutfnext` 152, `testutfprev` 103, `testbytestring` 26 | characters, partly through the C API |
| `util.test` | 2291 | 2123 | 24 | 144 | `testdoubledigits` 126, `testdstring` 10, `testprint` 6 | number parsing and output, partly through the C API |
| `var.test` | 110 | 64 | 26 | 20 | `testsetnoerr` 12, `memory` 3, `testgetvarfullname` 3 | language and core commands |
| `while-old.test` | 15 | 14 | 1 | 0 |  | language and core commands |
| `while.test` | 46 | 45 | 1 | 0 |  | language and core commands |
| `word.test` | 50 | 45 | 5 | 0 |  | `tcl_endOfWord` and related procs |

## Needs a decision

| File | Total | Pass | Fail | Blocked | Blocked by | Reason |
|---|---|---|---|---|---|---|
| `aaa_exit.test` | 2 | 0 | 2 | 0 |  | `exit` |
| `autoMkindex.test` | 11 | 0 | 8 | 3 | unreached 3 | the library index, needs `file` |
| `chan.test` | 41 | 0 | 41 | 0 |  | `chan` |
| `chanio.test` | 471 | 0 | 0 | 471 | unreached 471 | channels |
| `clock.test` | 8532 | 4 | 7704 | 824 | `detroit` 796, `win` 1, unreached 27 | `clock` |
| `cmdAH.test` | 323 | 11 | 129 | 183 | `testsetplatform` 120, `win` 22, `nonPortable` 7, unreached 31 | mostly `file` and `encoding` |
| `config.test` | 9 | 0 | 9 | 0 |  | `tcl::pkgconfig` |
| `encoding.test` | 86 | 4 | 47 | 35 | `testencoding` 8, `ucs2` 2, `testbytestring` 1, unreached 23 | `encoding` |
| `env.test` | 26 | 3 | 10 | 13 | `exec` 9, `win` 4 | `env`, the host environment |
| `event.test` | 66 | 0 | 34 | 32 | `testfilehandler` 22, `stdio` 6, `testfilewait` 2 | `after`, `vwait`, `update` |
| `exec.test` | 100 | 0 | 0 | 100 | `exec` 93, `win` 5, unreached 2 | `exec` |
| `fCmd.test` | 256 | 0 | 0 | 256 | unreached 256 | `file` |
| `fileName.test` | 300 | 1 | 99 | 200 | `testsetplatform` 133, `win` 26, `nonPortable` 7, unreached 33 | `file`, `glob` |
| `fileSystem.test` | 137 | 0 | 0 | 137 | unreached 137 | `file` |
| `fileSystemEncoding.test` | 1 | 0 | 0 | 1 | unreached 1 | `file`, `encoding` |
| `history.test` | 62 | 0 | 0 | 62 | `history` 62 | `history` |
| `http.test` | 75 | 1 | 72 | 2 | `knownBug` 1, `nonPortable` 1 | `http`, `socket` |
| `http11.test` | 43 | 0 | 42 | 1 | `knownBug` 1 | `http`, `socket` |
| `httpPipeline.test` | 1996 | 0 | 0 | 1996 | unreached 1996 | `http`, `socket` |
| `httpold.test` | 32 | 0 | 0 | 32 | unreached 32 | `http`, `socket` |
| `init.test` | 24 | 0 | 10 | 14 | unreached 14 | library loading, `auto_load` |
| `interp.test` | 352 | 1 | 338 | 13 | `knownBug` 7, `testinterpdelete` 6 | `interp` |
| `io.test` | 524 | 0 | 0 | 524 | unreached 524 | channels |
| `ioCmd.test` | 348 | 4 | 223 | 121 | `testchannel` 99, `fcopy` 10, `nonPortable` 3, unreached 3 | channels |
| `ioTrans.test` | 106 | 0 | 69 | 37 | `testchannel` 37 | channel transforms |
| `iogt.test` | 17 | 0 | 0 | 17 | unreached 17 | channel transforms |
| `load.test` | 30 | 0 | 8 | 22 | `teststaticpkg` 4, `teststaticpkg_8.x` 1, unreached 17 | `load` |
| `main.test` | 67 | 0 | 0 | 67 | unreached 67 | the `tclsh` main loop, `exec` |
| `msgcat.test` | 109 | 0 | 47 | 62 | unreached 62 | `msgcat` package |
| `opt.test` | 31 | 0 | 30 | 1 | unreached 1 | `tcl::OptProc` package |
| `package.test` | 180 | 0 | 0 | 180 | unreached 180 | `package` |
| `pid.test` | 5 | 0 | 0 | 5 | `pidDefined` 4, `unixExecs` 1 | `pid` |
| `pkgMkIndex.test` | 27 | 0 | 17 | 10 | unreached 10 | package index, `file` |
| `platform.test` | 6 | 1 | 3 | 2 | `notValgrind` 1, `testCPUID` 1 | `platform` package |
| `pwd.test` | 3 | 0 | 3 | 0 |  | `pwd`, `cd` |
| `safe-stock.test` | 4 | 0 | 4 | 0 |  | `interp -safe` |
| `safe.test` | 102 | 0 | 94 | 8 | `emptyTest` 2, unreached 6 | `interp -safe` |
| `security.test` | 1 | 1 | 0 | 0 |  | `interp`, host access |
| `socket.test` | 98 | 0 | 0 | 98 | `socket` 37, unreached 61 | `socket` |
| `source.test` | 23 | 0 | 23 | 0 |  | `source` |
| `stack.test` | 3 | 0 | 3 | 0 |  | host stack limits, `exec` |
| `tcltest.test` | 159 | 0 | 0 | 159 | unreached 159 | the real `tcltest` package |
| `timer.test` | 54 | 0 | 48 | 6 | unreached 6 | `after` |
| `tm.test` | 21 | 0 | 19 | 2 | unreached 2 | Tcl modules, `file` |
| `unixFCmd.test` | 49 | 0 | 28 | 21 | `emptyTest` 11, `readonlyAttr` 4, `nonPortable` 3 | `file` |
| `unixFile.test` | 7 | 0 | 0 | 7 | `testfindexecutable` 2, unreached 5 | `file` |
| `unixInit.test` | 8 | 0 | 1 | 7 | `stdio` 5, `emptyTest` 2 | `exec` of tclsh |
| `unload.test` | 27 | 0 | 7 | 20 | unreached 20 | `unload` |
| `zlib.test` | 73 | 0 | 1 | 72 | `zlib` 71, `knownBug` 1 | `zlib` |

## Cannot apply

| File | Total | Pass | Fail | Blocked | Blocked by | Reason |
|---|---|---|---|---|---|---|
| `assemble.test` | 284 | 0 | 280 | 4 | `memory` 4 | Tcl bytecode assembler; ztcl has its own bytecode |
| `assocd.test` | 11 | 0 | 0 | 11 | `testgetassocdata` 4, `testsetassocdata` 4, `testdelassocdata` 3 | C API |
| `async.test` | 12 | 0 | 0 | 12 | `testasync` 12 | C API |
| `cmdInfo.test` | 12 | 0 | 0 | 12 | `testcmdinfo` 9, `testcmdtoken` 3 | C API |
| `dcall.test` | 6 | 0 | 0 | 6 | `testdcall` 6 | C API |
| `dstring.test` | 44 | 0 | 0 | 44 | `testdstring` 44 | C API |
| `indexObj.test` | 45 | 0 | 0 | 45 | `testindexobj` 33, `testparseargs` 12 | C API |
| `link.test` | 29 | 0 | 0 | 29 | `testlink` 29 | C API |
| `macOSXFCmd.test` | 14 | 0 | 0 | 14 | `macosxFileAttr` 14 | macOS only |
| `macOSXLoad.test` | 0 | 0 | 0 | 0 |  | macOS only |
| `notify.test` | 23 | 0 | 0 | 23 | `testevent` 23 | C API |
| `obj.test` | 92 | 3 | 0 | 89 | `testobj` 84, `longIs32bit` 5 | C API |
| `registry.test` | 125 | 0 | 0 | 125 | `win` 125 | Windows only |
| `resolver.test` | 10 | 0 | 0 | 10 | `testinterpresolver` 10 | C API |
| `result.test` | 26 | 1 | 3 | 22 | `testsaveresult` 11, `testsetobjerrorcode` 5, `testseterrorcode` 4 | C API |
| `stringObj.test` | 75 | 0 | 0 | 75 | `testobj` 75 | C API |
| `thread.test` | 52 | 0 | 0 | 52 | `thread` 52 | threads |
| `unixForkEvent.test` | 1 | 0 | 0 | 1 | `testfork` 1 | needs fork |
| `unixNotfy.test` | 4 | 0 | 0 | 4 | `noTk` 4 | threads and the notifier |
| `winConsole.test` | 1 | 0 | 0 | 1 | `win` 1 | Windows only |
| `winDde.test` | 50 | 0 | 0 | 50 | `dde` 49, `win` 1 | Windows only |
| `winFCmd.test` | 178 | 0 | 0 | 178 | `win` 156, `nt` 4, `winVista` 3, unreached 12 | Windows only |
| `winFile.test` | 11 | 0 | 0 | 11 | `win` 11 | Windows only |
| `winNotify.test` | 14 | 0 | 0 | 14 | `win` 14 | Windows only |
| `winPipe.test` | 56 | 0 | 0 | 56 | `win` 56 | Windows only |
| `winTime.test` | 3 | 0 | 0 | 3 | `win` 2, `testwinclock` 1 | Windows only |
