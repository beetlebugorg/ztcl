# Compatibility with the Tcl 8.6.16 tests

This page lists each of the 152 test files of Tcl 8.6.16. `tools/suite-table.py` makes it from a run of `tools/suite.sh -a`. The repository has no copy of the tests.

## How to read the counts

- **Total** is the number of tests in the file. `tools/suite-count.tcl` counts the `test` calls in a safe tclsh, and a text search counts the test lines. The table uses the larger count, or the count of tests that ran if that is larger.
- **Pass** and **Fail** are results of ztcl with the stand-in `tools/tcltest.tcl`.
- **Blocked** is Total minus Pass minus Fail. A blocked test did not run, so it is not a pass. A false constraint blocked it, or the file stopped before it.
- **Blocked by** gives the largest constraints and their counts. Tcl also skips some of these, for example `knownBug` and `emptyTest`.

## Scopes

- **In scope:** the language and the core commands.
- **Needs a decision:** tests of commands that the sandbox omits today, such as `file`, `open`, `socket`, `exec`, `clock`, and `interp`.
- **Cannot apply:** tests of the C API through the `test*` commands of the Tcl test binary, tests for Windows or macOS only, and tests of threads.

## Totals

| Scope | Files | Total | Pass | Fail | Blocked | Pass rate |
|---|---|---|---|---|---|---|
| In scope | 77 | 29358 | 23219 | 3084 | 3055 | 79.1 % |
| Needs a decision | 49 | 15027 | 26 | 9080 | 5921 | 0.2 % |
| Cannot apply | 26 | 1178 | 2 | 285 | 891 | 0.2 % |
| **All** | **152** | **45563** | **23247** | **12449** | **9867** | **51.0 %** |

## In scope

| File | Total | Pass | Fail | Blocked | Blocked by | Reason |
|---|---|---|---|---|---|---|
| `append.test` | 45 | 28 | 17 | 0 |  | language and core commands |
| `appendComp.test` | 48 | 28 | 15 | 5 | `expr:bug-3057639` 5 | language and core commands |
| `apply.test` | 42 | 22 | 16 | 4 | `memory` 3, `applylambda` 1 | language and core commands |
| `basic.test` | 146 | 43 | 21 | 82 | `testevalex` 43, `emptyTest` 27, `exec` 4 | core, partly through the C API |
| `binary.test` | 717 | 566 | 72 | 79 | `bigEndian` 76, `testsetbytearraylength` 2, `win` 1 | language and core commands |
| `case.test` | 15 | 0 | 15 | 0 |  | language and core commands |
| `cmdIL.test` | 146 | 122 | 18 | 6 | `hasIsoLocale` 2, `memory` 2, `testWithLimit` 1 | language and core commands |
| `cmdMZ.test` | 92 | 49 | 14 | 29 | `unixOrWin` 2, `Unix` 1, not reached 26 | language and core commands |
| `compExpr-old.test` | 190 | 181 | 2 | 7 | `testmathfunctions` 5, `expr:!ieeeFloatingPoint` 1, `longIs32bit` 1 | language and core commands |
| `compExpr.test` | 80 | 75 | 1 | 4 | `memory` 2, `testmathfunctions` 2 | language and core commands |
| `compile.test` | 171 | 63 | 74 | 34 | `testevalex` 22, `knownBug` 9, `memory` 2 | the compiler, through scripts |
| `concat.test` | 9 | 9 | 0 | 0 |  | language and core commands |
| `coroutine.test` | 59 | 0 | 56 | 3 | `testnrelevels` 2, `memory` 1 | coroutines |
| `dict.test` | 342 | 291 | 49 | 2 | `memory` 2 | language and core commands |
| `error.test` | 317 | 283 | 26 | 8 | `memory` 8 | language and core commands |
| `eval.test` | 12 | 11 | 1 | 0 |  | language and core commands |
| `execute.test` | 157 | 56 | 20 | 81 | `testobj` 77, `longIs32bit` 3, `testexprlongobj` 1 | the bytecode engine, through scripts |
| `expr-old.test` | 460 | 412 | 14 | 34 | `testexprlong` 16, `testexprdouble` 7, `expr:!ieeeFloatingPoint` 3 | language and core commands |
| `expr.test` | 14185 | 14080 | 56 | 49 | `testexprlongobj` 16, `testmathfunctions` 11, `longIs32bit` 8 | language and core commands |
| `for-old.test` | 9 | 9 | 0 | 0 |  | language and core commands |
| `for.test` | 88 | 60 | 4 | 24 | `memory` 24 | language and core commands |
| `foreach.test` | 43 | 38 | 5 | 0 |  | language and core commands |
| `format.test` | 266 | 225 | 32 | 9 | `longIs32bit` 7, `wideBiggerThanInt` 2 | language and core commands |
| `get.test` | 22 | 5 | 1 | 16 | `testgetint` 15, `testdoubleobj` 1 | language and core commands |
| `if-old.test` | 33 | 33 | 0 | 0 |  | language and core commands |
| `if.test` | 73 | 72 | 1 | 0 |  | language and core commands |
| `incr-old.test` | 14 | 12 | 2 | 0 |  | language and core commands |
| `incr.test` | 66 | 62 | 4 | 0 |  | language and core commands |
| `info.test` | 266 | 61 | 197 | 8 | `knownBug` 3, `testevalex` 2, not reached 3 | language and core commands |
| `join.test` | 10 | 7 | 3 | 0 |  | language and core commands |
| `lindex.test` | 83 | 37 | 9 | 37 | `testevalex` 37 | language and core commands |
| `linsert.test` | 28 | 27 | 1 | 0 |  | language and core commands |
| `list.test` | 78 | 77 | 1 | 0 |  | language and core commands |
| `listObj.test` | 47 | 35 | 7 | 5 | `testobj` 4, `emptyTest` 1 | lists, partly through the C API |
| `llength.test` | 6 | 5 | 1 | 0 |  | language and core commands |
| `lmap.test` | 66 | 55 | 11 | 0 |  | language and core commands |
| `lrange.test` | 34 | 30 | 2 | 2 | `testpurebytesobj` 2 | language and core commands |
| `lrepeat.test` | 12 | 5 | 7 | 0 |  | language and core commands |
| `lreplace.test` | 1787 | 1787 | 0 | 0 |  | language and core commands |
| `lsearch.test` | 118 | 109 | 9 | 0 |  | language and core commands |
| `lset.test` | 89 | 0 | 0 | 89 | `testevalex` 88, `testobj` 1 | language and core commands |
| `lsetComp.test` | 19 | 19 | 0 | 0 |  | language and core commands |
| `mathop.test` | 349 | 24 | 325 | 0 |  | language and core commands |
| `misc.test` | 301 | 1 | 0 | 300 | `testhashsystemhash` 299, not reached 1 | language and core commands |
| `namespace-old.test` | 126 | 102 | 24 | 0 |  | language and core commands |
| `namespace.test` | 313 | 161 | 149 | 3 | `knownBug` 1, `memory` 1, `testevalobjv` 1 | language and core commands |
| `nre.test` | 28 | 2 | 3 | 23 | `testnrelevels` 23 | non-recursive evaluation |
| `oo.test` | 306 | 0 | 288 | 18 | `memory` 14, `knownBug` 3, not reached 1 | TclOO |
| `ooNext2.test` | 62 | 0 | 57 | 5 | `memory` 5 | TclOO |
| `parse.test` | 271 | 65 | 25 | 181 | `testparser` 117, `testevalex` 29, `testparsevarname` 12 | the parser, partly through the C API |
| `parseExpr.test` | 284 | 13 | 54 | 217 | `testexprparser` 215 | the expression parser, partly through the C API |
| `parseOld.test` | 158 | 153 | 2 | 3 | `testbytestring` 3 | language and core commands |
| `proc-old.test` | 74 | 60 | 14 | 0 |  | language and core commands |
| `proc.test` | 38 | 20 | 17 | 1 | `memory` 1 | language and core commands |
| `reg.test` | 1141 | 25 | 9 | 1107 | `testregexp` 1099, `knownBug` 7, `nonPortable` 1 | regular expressions; most tests use `testregexp` |
| `regexp.test` | 244 | 207 | 32 | 5 | `knownBug` 3, `exec` 1, `macCrash` 1 | language and core commands |
| `regexpComp.test` | 179 | 151 | 26 | 2 | `exec` 1, `macCrash` 1 | language and core commands |
| `rename.test` | 19 | 8 | 3 | 8 | `testdel` 8 | language and core commands |
| `scan.test` | 181 | 145 | 35 | 1 | `nonPortable` 1 | language and core commands |
| `set-old.test` | 153 | 79 | 74 | 0 |  | language and core commands |
| `set.test` | 64 | 61 | 2 | 1 | `testset2` 1 | language and core commands |
| `split.test` | 17 | 14 | 3 | 0 |  | language and core commands |
| `string.test` | 634 | 455 | 169 | 10 | `testbytestring` 4, `memory` 3, `testevalex` 1 | language and core commands |
| `stringComp.test` | 279 | 249 | 29 | 1 | `memory` 1 | language and core commands |
| `subst.test` | 63 | 28 | 34 | 1 | `testbytestring` 1 | language and core commands |
| `switch.test` | 113 | 93 | 20 | 0 |  | language and core commands |
| `tailcall.test` | 37 | 3 | 26 | 8 | `testnrelevels` 8 | `tailcall` |
| `trace.test` | 295 | 1 | 277 | 17 | `testcmdtrace` 11, `memory` 3, `testevalobjv` 2 | `trace` |
| `unknown.test` | 7 | 1 | 6 | 0 |  | language and core commands |
| `uplevel.test` | 57 | 40 | 17 | 0 |  | language and core commands |
| `upvar.test` | 65 | 34 | 23 | 8 | `testupvar` 8 | language and core commands |
| `utf.test` | 498 | 102 | 42 | 354 | `testutfnext` 152, `testutfprev` 103, `testbytestring` 26 | characters, partly through the C API |
| `util.test` | 2291 | 1722 | 425 | 144 | `testdoubledigits` 126, `testdstring` 10, `testprint` 6 | number parsing and output, partly through the C API |
| `var.test` | 110 | 52 | 38 | 20 | `testsetnoerr` 12, `memory` 3, `testgetvarfullname` 3 | language and core commands |
| `while-old.test` | 15 | 14 | 1 | 0 |  | language and core commands |
| `while.test` | 46 | 45 | 1 | 0 |  | language and core commands |
| `word.test` | 50 | 0 | 50 | 0 |  | `tcl_endOfWord` and related procs |

## Needs a decision

| File | Total | Pass | Fail | Blocked | Blocked by | Reason |
|---|---|---|---|---|---|---|
| `aaa_exit.test` | 2 | 0 | 2 | 0 |  | `exit` |
| `autoMkindex.test` | 11 | 0 | 8 | 3 | not reached 3 | the library index, needs `file` |
| `chan.test` | 41 | 0 | 41 | 0 |  | `chan` |
| `chanio.test` | 471 | 0 | 0 | 471 | not reached 471 | channels |
| `clock.test` | 8532 | 4 | 7704 | 824 | `detroit` 796, `win` 1, not reached 27 | `clock` |
| `cmdAH.test` | 323 | 11 | 128 | 184 | `testsetplatform` 120, `win` 22, `nonPortable` 7, not reached 31 | mostly `file` and `encoding` |
| `config.test` | 9 | 0 | 9 | 0 |  | `tcl::pkgconfig` |
| `encoding.test` | 86 | 0 | 16 | 70 | `testencoding` 7, not reached 63 | `encoding` |
| `env.test` | 26 | 2 | 11 | 13 | `exec` 9, `win` 4 | `env`, the host environment |
| `event.test` | 66 | 0 | 34 | 32 | `testfilehandler` 22, `stdio` 6, `testfilewait` 2 | `after`, `vwait`, `update` |
| `exec.test` | 100 | 0 | 0 | 100 | `exec` 93, `win` 5, not reached 2 | `exec` |
| `fCmd.test` | 256 | 0 | 0 | 256 | not reached 256 | `file` |
| `fileName.test` | 300 | 1 | 78 | 221 | `testsetplatform` 133, `win` 26, `unixOrWin` 21, not reached 33 | `file`, `glob` |
| `fileSystem.test` | 137 | 0 | 0 | 137 | not reached 137 | `file` |
| `fileSystemEncoding.test` | 1 | 0 | 0 | 1 | not reached 1 | `file`, `encoding` |
| `history.test` | 62 | 0 | 0 | 62 | `history` 62 | `history` |
| `http.test` | 75 | 1 | 72 | 2 | `knownBug` 1, `nonPortable` 1 | `http`, `socket` |
| `http11.test` | 43 | 0 | 42 | 1 | `knownBug` 1 | `http`, `socket` |
| `httpPipeline.test` | 1996 | 0 | 0 | 1996 | not reached 1996 | `http`, `socket` |
| `httpold.test` | 32 | 0 | 0 | 32 | not reached 32 | `http`, `socket` |
| `init.test` | 24 | 0 | 10 | 14 | not reached 14 | library loading, `auto_load` |
| `interp.test` | 352 | 1 | 337 | 14 | `knownBug` 7, `testinterpdelete` 6, `unixOrWin` 1 | `interp` |
| `io.test` | 524 | 0 | 0 | 524 | not reached 524 | channels |
| `ioCmd.test` | 348 | 4 | 223 | 121 | `testchannel` 99, `fcopy` 10, `nonPortable` 3, not reached 3 | channels |
| `ioTrans.test` | 106 | 0 | 69 | 37 | `testchannel` 37 | channel transforms |
| `iogt.test` | 17 | 0 | 0 | 17 | not reached 17 | channel transforms |
| `load.test` | 30 | 0 | 8 | 22 | `teststaticpkg` 4, `teststaticpkg_8.x` 1, not reached 17 | `load` |
| `main.test` | 67 | 0 | 0 | 67 | not reached 67 | the `tclsh` main loop, `exec` |
| `msgcat.test` | 109 | 0 | 7 | 102 | not reached 102 | `msgcat` package |
| `opt.test` | 31 | 0 | 30 | 1 | not reached 1 | `tcl::OptProc` package |
| `package.test` | 180 | 0 | 0 | 180 | not reached 180 | `package` |
| `pid.test` | 5 | 0 | 0 | 5 | `pidDefined` 4, `unixOrWin` 1 | `pid` |
| `pkgMkIndex.test` | 27 | 0 | 17 | 10 | not reached 10 | package index, `file` |
| `platform.test` | 6 | 1 | 3 | 2 | `notValgrind` 1, `testCPUID` 1 | `platform` package |
| `pwd.test` | 3 | 0 | 3 | 0 |  | `pwd`, `cd` |
| `safe-stock.test` | 4 | 0 | 4 | 0 |  | `interp -safe` |
| `safe.test` | 102 | 0 | 94 | 8 | `emptyTest` 2, not reached 6 | `interp -safe` |
| `security.test` | 1 | 1 | 0 | 0 |  | `interp`, host access |
| `socket.test` | 98 | 0 | 0 | 98 | `socket` 37, not reached 61 | `socket` |
| `source.test` | 23 | 0 | 23 | 0 |  | `source` |
| `stack.test` | 3 | 0 | 3 | 0 |  | host stack limits, `exec` |
| `tcltest.test` | 159 | 0 | 0 | 159 | not reached 159 | the real `tcltest` package |
| `timer.test` | 54 | 0 | 48 | 6 | not reached 6 | `after` |
| `tm.test` | 21 | 0 | 19 | 2 | not reached 2 | Tcl modules, `file` |
| `unixFCmd.test` | 49 | 0 | 28 | 21 | `emptyTest` 11, `readonlyAttr` 4, `nonPortable` 3 | `file` |
| `unixFile.test` | 7 | 0 | 0 | 7 | `testfindexecutable` 2, not reached 5 | `file` |
| `unixInit.test` | 8 | 0 | 1 | 7 | `stdio` 5, `emptyTest` 2 | `exec` of tclsh |
| `unload.test` | 27 | 0 | 7 | 20 | not reached 20 | `unload` |
| `zlib.test` | 73 | 0 | 1 | 72 | `zlib` 70, `knownBug` 1, `tempNotWin` 1 | `zlib` |

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
| `obj.test` | 92 | 1 | 2 | 89 | `testobj` 84, `longIs32bit` 5 | C API |
| `registry.test` | 125 | 0 | 0 | 125 | `win` 125 | Windows only |
| `resolver.test` | 10 | 0 | 0 | 10 | `testinterpresolver` 10 | C API |
| `result.test` | 26 | 1 | 3 | 22 | `testsaveresult` 11, `testsetobjerrorcode` 5, `testseterrorcode` 4 | C API |
| `stringObj.test` | 75 | 0 | 0 | 75 | `testobj` 75 | C API |
| `thread.test` | 52 | 0 | 0 | 52 | `thread` 52 | threads |
| `unixForkEvent.test` | 1 | 0 | 0 | 1 | `testfork` 1 | needs fork |
| `unixNotfy.test` | 4 | 0 | 0 | 4 | `noTk` 4 | threads and the notifier |
| `winConsole.test` | 1 | 0 | 0 | 1 | `win` 1 | Windows only |
| `winDde.test` | 50 | 0 | 0 | 50 | `dde` 49, `win` 1 | Windows only |
| `winFCmd.test` | 178 | 0 | 0 | 178 | `win` 156, `nt` 4, `winVista` 3, not reached 12 | Windows only |
| `winFile.test` | 11 | 0 | 0 | 11 | `win` 11 | Windows only |
| `winNotify.test` | 14 | 0 | 0 | 14 | `win` 14 | Windows only |
| `winPipe.test` | 56 | 0 | 0 | 56 | `win` 56 | Windows only |
| `winTime.test` | 3 | 0 | 0 | 3 | `win` 2, `testwinclock` 1 | Windows only |
