# Compatibility with the Tcl 8.6.16 tests

This page lists each of the 152 test files of Tcl 8.6.16. `tools/suite-table.py` makes it from a run of `tools/suite.sh -a`. The repository has no copy of the tests.

## How to read the counts

- **Total** is the number of tests in the file. `tools/suite-count.tcl` counts the `test` calls in a safe tclsh, and a text search counts the test lines. The table uses the larger count, or the count of tests that ran if that is larger.
- **Pass** and **Fail** are results of ztcl with the stand-in `tools/tcltest.tcl`, on the suite runner.
- **Stand-in** is the part of Pass that needs a test command of `tools/suite_cmds.zig`. These commands call real ztcl code. They are only in the suite runner, and the library and the default runner do not have them.
- **Blocked** is Total minus Pass minus Fail. A blocked test did not run, so it is not a pass. A false constraint blocked it, or the file stopped before it (`unreached`).
- **Blocked by** gives the largest constraints and their counts. Tcl also skips some of these, for example `knownBug` and `emptyTest`.

## Scopes

- **In scope:** the language and the core commands.
- **Optional or host:** tests of commands that the default interpreter omits. `clock`, `package`, `interp`, channels, and `file` are optional capabilities that the suite turns on. `socket` is not built yet. `exec` is never added.
- **Cannot apply:** tests of the C API through the `test*` commands of the Tcl test binary, tests for Windows or macOS only, and tests of threads.

## Totals

| Scope | Files | Total | Pass | Stand-in | Fail | Blocked | Pass rate | Rate with no stand-in |
|---|---|---|---|---|---|---|---|---|
| In scope | 77 | 29990 | 26851 | 1733 | 1354 | 1785 | 89.5 % | 83.8 % |
| Optional or host | 49 | 15249 | 9648 | 0 | 1771 | 3830 | 63.3 % | 63.3 % |
| Cannot apply | 26 | 1178 | 4 | 0 | 283 | 891 | 0.3 % | 0.3 % |
| **All** | **152** | **46417** | **36503** | **1733** | **3408** | **6506** | **78.6 %** | **74.9 %** |

## In scope

| File | Total | Pass | Stand-in | Fail | Blocked | Blocked by | Reason |
|---|---|---|---|---|---|---|---|
| `append.test` | 45 | 42 | 0 | 3 | 0 |  | language and core commands |
| `appendComp.test` | 48 | 40 | 0 | 3 | 5 | `expr:bug-3057639` 5 | language and core commands |
| `apply.test` | 42 | 33 | 0 | 5 | 4 | `memory` 3, `applylambda` 1 | language and core commands |
| `basic.test` | 146 | 99 | 43 | 8 | 39 | `emptyTest` 27, `exec` 4, `testcmdtoken` 3 | core, partly through the C API |
| `binary.test` | 717 | 602 | 0 | 36 | 79 | `bigEndian` 76, `testsetbytearraylength` 2, `win` 1 | language and core commands |
| `case.test` | 15 | 15 | 0 | 0 | 0 |  | language and core commands |
| `cmdIL.test` | 146 | 128 | 0 | 12 | 6 | `hasIsoLocale` 2, `memory` 2, `testWithLimit` 1 | language and core commands |
| `cmdMZ.test` | 92 | 56 | 0 | 35 | 1 | `Unix` 1 | language and core commands |
| `compExpr-old.test` | 190 | 183 | 0 | 0 | 7 | `testmathfunctions` 5, `expr:!ieeeFloatingPoint` 1, `longIs32bit` 1 | language and core commands |
| `compExpr.test` | 80 | 76 | 0 | 0 | 4 | `memory` 2, `testmathfunctions` 2 | language and core commands |
| `compile.test` | 171 | 95 | 22 | 64 | 12 | `knownBug` 9, `memory` 2, `exec` 1 | the compiler, through scripts |
| `concat.test` | 9 | 9 | 0 | 0 | 0 |  | language and core commands |
| `coroutine.test` | 59 | 37 | 0 | 19 | 3 | `testnrelevels` 2, `memory` 1 | coroutines |
| `dict.test` | 342 | 311 | 0 | 29 | 2 | `memory` 2 | language and core commands |
| `error.test` | 317 | 300 | 0 | 9 | 8 | `memory` 8 | language and core commands |
| `eval.test` | 12 | 11 | 0 | 1 | 0 |  | language and core commands |
| `execute.test` | 157 | 71 | 0 | 6 | 80 | `testobj` 77, `longIs32bit` 3 | the bytecode engine, through scripts |
| `expr-old.test` | 460 | 432 | 11 | 12 | 16 | `longIs32bit` 10, `expr:!ieeeFloatingPoint` 3, `testmathfunctions` 3 | language and core commands |
| `expr.test` | 14185 | 14124 | 2 | 27 | 34 | `longIs32bit` 18, `testmathfunctions` 11, `expr:!ieeeFloatingPoint` 5 | language and core commands |
| `for-old.test` | 9 | 9 | 0 | 0 | 0 |  | language and core commands |
| `for.test` | 88 | 61 | 0 | 3 | 24 | `memory` 24 | language and core commands |
| `foreach.test` | 43 | 41 | 0 | 2 | 0 |  | language and core commands |
| `format.test` | 266 | 233 | 0 | 24 | 9 | `longIs32bit` 7, `wideBiggerThanInt` 2 | language and core commands |
| `get.test` | 22 | 5 | 0 | 1 | 16 | `testgetint` 15, `testdoubleobj` 1 | language and core commands |
| `if-old.test` | 33 | 33 | 0 | 0 | 0 |  | language and core commands |
| `if.test` | 73 | 73 | 0 | 0 | 0 |  | language and core commands |
| `incr-old.test` | 14 | 12 | 0 | 2 | 0 |  | language and core commands |
| `incr.test` | 66 | 62 | 0 | 4 | 0 |  | language and core commands |
| `info.test` | 266 | 97 | 0 | 166 | 3 | `knownBug` 3 | language and core commands |
| `join.test` | 10 | 10 | 0 | 0 | 0 |  | language and core commands |
| `lindex.test` | 83 | 80 | 36 | 3 | 0 |  | language and core commands |
| `linsert.test` | 28 | 28 | 0 | 0 | 0 |  | language and core commands |
| `list.test` | 78 | 77 | 0 | 1 | 0 |  | language and core commands |
| `listObj.test` | 47 | 42 | 0 | 0 | 5 | `testobj` 4, `emptyTest` 1 | lists, partly through the C API |
| `llength.test` | 6 | 6 | 0 | 0 | 0 |  | language and core commands |
| `lmap.test` | 66 | 62 | 0 | 4 | 0 |  | language and core commands |
| `lrange.test` | 34 | 32 | 0 | 0 | 2 | `testpurebytesobj` 2 | language and core commands |
| `lrepeat.test` | 12 | 5 | 0 | 7 | 0 |  | language and core commands |
| `lreplace.test` | 1787 | 1787 | 0 | 0 | 0 |  | language and core commands |
| `lsearch.test` | 118 | 111 | 0 | 7 | 0 |  | language and core commands |
| `lset.test` | 89 | 83 | 83 | 5 | 1 | `testobj` 1 | language and core commands |
| `lsetComp.test` | 19 | 19 | 0 | 0 | 0 |  | language and core commands |
| `mathop.test` | 349 | 347 | 0 | 2 | 0 |  | language and core commands |
| `misc.test` | 301 | 1 | 0 | 1 | 299 | `testhashsystemhash` 299 | language and core commands |
| `namespace-old.test` | 126 | 114 | 0 | 12 | 0 |  | language and core commands |
| `namespace.test` | 313 | 233 | 0 | 77 | 3 | `knownBug` 1, `memory` 1, `testevalobjv` 1 | language and core commands |
| `nre.test` | 28 | 4 | 0 | 1 | 23 | `testnrelevels` 23 | non-recursive evaluation |
| `oo.test` | 306 | 0 | 0 | 288 | 18 | `memory` 14, `knownBug` 3, unreached 1 | TclOO |
| `ooNext2.test` | 62 | 0 | 0 | 57 | 5 | `memory` 5 | TclOO |
| `parse.test` | 271 | 110 | 26 | 9 | 152 | `testparser` 117, `testparsevarname` 12, `testevalobjv` 10 | the parser, partly through the C API |
| `parseExpr.test` | 284 | 13 | 0 | 54 | 217 | `testexprparser` 215 | the expression parser, partly through the C API |
| `parseOld.test` | 158 | 153 | 0 | 2 | 3 | `testbytestring` 3 | language and core commands |
| `proc-old.test` | 74 | 64 | 0 | 10 | 0 |  | language and core commands |
| `proc.test` | 38 | 26 | 0 | 3 | 9 | `procbodytest` 9 | language and core commands |
| `reg.test` | 1141 | 925 | 892 | 106 | 110 | `localeRegexp` 100, `knownBug` 9, `nonPortable` 1 | regular expressions; most tests use `testregexp` |
| `regexp.test` | 244 | 239 | 0 | 1 | 4 | `knownBug` 3, `exec` 1 | language and core commands |
| `regexpComp.test` | 179 | 176 | 0 | 2 | 1 | `exec` 1 | language and core commands |
| `rename.test` | 19 | 10 | 0 | 1 | 8 | `testdel` 8 | language and core commands |
| `scan.test` | 181 | 162 | 0 | 18 | 1 | `nonPortable` 1 | language and core commands |
| `set-old.test` | 153 | 142 | 0 | 11 | 0 |  | language and core commands |
| `set.test` | 64 | 61 | 0 | 2 | 1 | `testset2` 1 | language and core commands |
| `split.test` | 17 | 16 | 0 | 1 | 0 |  | language and core commands |
| `string.test` | 1266 | 1236 | 618 | 12 | 18 | `testbytestring` 8, `memory` 6, `testindexobj` 2 | language and core commands |
| `stringComp.test` | 279 | 278 | 0 | 0 | 1 | `memory` 1 | language and core commands |
| `subst.test` | 63 | 57 | 0 | 5 | 1 | `testbytestring` 1 | language and core commands |
| `switch.test` | 113 | 106 | 0 | 7 | 0 |  | language and core commands |
| `tailcall.test` | 37 | 20 | 0 | 9 | 8 | `testnrelevels` 8 | `tailcall` |
| `trace.test` | 295 | 212 | 0 | 66 | 17 | `testcmdtrace` 11, `memory` 3, `testevalobjv` 2 | `trace` |
| `unknown.test` | 7 | 7 | 0 | 0 | 0 |  | language and core commands |
| `uplevel.test` | 57 | 49 | 0 | 8 | 0 |  | language and core commands |
| `upvar.test` | 65 | 43 | 0 | 14 | 8 | `testupvar` 8 | language and core commands |
| `utf.test` | 498 | 123 | 0 | 21 | 354 | `testutfnext` 152, `testutfprev` 103, `testbytestring` 26 | characters, partly through the C API |
| `util.test` | 2291 | 2123 | 0 | 24 | 144 | `testdoubledigits` 126, `testdstring` 10, `testprint` 6 | number parsing and output, partly through the C API |
| `var.test` | 110 | 65 | 0 | 25 | 20 | `testsetnoerr` 12, `memory` 3, `testgetvarfullname` 3 | language and core commands |
| `while-old.test` | 15 | 14 | 0 | 1 | 0 |  | language and core commands |
| `while.test` | 46 | 45 | 0 | 1 | 0 |  | language and core commands |
| `word.test` | 50 | 45 | 0 | 5 | 0 |  | `tcl_endOfWord` and related procs |

## Optional or host

| File | Total | Pass | Stand-in | Fail | Blocked | Blocked by | Reason |
|---|---|---|---|---|---|---|---|
| `aaa_exit.test` | 2 | 0 | 0 | 2 | 0 |  | `exit` |
| `autoMkindex.test` | 11 | 1 | 0 | 9 | 1 | `knownBug` 1 | the library index, needs `file` |
| `chan.test` | 41 | 4 | 0 | 37 | 0 |  | `chan` |
| `chanio.test` | 471 | 178 | 0 | 106 | 187 | `stdio` 56, `testchannel` 31, `fileevent` 25, unreached 29 | channels |
| `clock.test` | 8532 | 8384 | 0 | 138 | 10 | `win` 7, unreached 3 | `clock` |
| `cmdAH.test` | 323 | 81 | 0 | 64 | 178 | `testsetplatform` 145, `win` 22, `nonPortable` 8 | mostly `file` and `encoding` |
| `config.test` | 9 | 0 | 0 | 9 | 0 |  | `tcl::pkgconfig` |
| `encoding.test` | 86 | 4 | 0 | 47 | 35 | `testencoding` 8, `ucs2` 2, `testbytestring` 1, unreached 23 | `encoding` |
| `env.test` | 26 | 3 | 0 | 10 | 13 | `exec` 9, `win` 4 | `env`, the host environment |
| `event.test` | 66 | 0 | 0 | 34 | 32 | `testfilehandler` 22, `stdio` 6, `testfilewait` 2 | `after`, `vwait`, `update` |
| `exec.test` | 100 | 0 | 0 | 0 | 100 | `exec` 95, `win` 5 | `exec` |
| `fCmd.test` | 256 | 120 | 0 | 85 | 51 | `testchmod` 19, `win` 11, `xdev` 6, unreached 1 | `file` |
| `fileName.test` | 300 | 50 | 0 | 69 | 181 | `testsetplatform` 133, `win` 35, `nonPortable` 7, unreached 5 | `file`, `glob` |
| `fileSystem.test` | 137 | 37 | 0 | 41 | 59 | `win` 21, `hasLinks` 16, `testsimplefilesystem` 10 | `file` |
| `fileSystemEncoding.test` | 1 | 0 | 0 | 1 | 0 |  | `file`, `encoding` |
| `history.test` | 62 | 0 | 0 | 0 | 62 | `history` 62 | `history` |
| `http.test` | 75 | 2 | 0 | 62 | 11 | `http2.9.7` 7, `http2.9.8` 2, `knownBug` 1 | `http`, `socket` |
| `http11.test` | 43 | 0 | 0 | 42 | 1 | `knownBug` 1 | `http`, `socket` |
| `httpPipeline.test` | 1996 | 0 | 0 | 0 | 1996 | unreached 1996 | `http`, `socket` |
| `httpold.test` | 32 | 0 | 0 | 0 | 32 | unreached 32 | `http`, `socket` |
| `init.test` | 24 | 0 | 0 | 10 | 14 | unreached 14 | library loading, `auto_load` |
| `interp.test` | 352 | 150 | 0 | 189 | 13 | `knownBug` 7, `testinterpdelete` 6 | optional capability `interp` |
| `io.test` | 524 | 184 | 0 | 118 | 222 | `stdio` 59, `testchannel` 31, `fileevent` 25, unreached 58 | channels |
| `ioCmd.test` | 348 | 71 | 0 | 170 | 107 | `testchannel` 99, `nonPortable` 3, `unixExecs` 3 | channels |
| `ioTrans.test` | 106 | 2 | 0 | 67 | 37 | `testchannel` 37 | channel transforms |
| `iogt.test` | 17 | 0 | 0 | 0 | 17 | `testchannel` 17 | channel transforms |
| `load.test` | 30 | 0 | 0 | 8 | 22 | `pkga.soRequired` 12, `teststaticpkg` 5, `teststaticpkg_8.x` 5 | `load` |
| `main.test` | 67 | 0 | 0 | 0 | 67 | `stdio` 1, unreached 66 | the `tclsh` main loop, `exec` |
| `msgcat.test` | 109 | 3 | 0 | 100 | 6 | unreached 6 | `msgcat` package |
| `opt.test` | 31 | 0 | 0 | 30 | 1 | unreached 1 | `tcl::OptProc` package |
| `package.test` | 402 | 352 | 0 | 50 | 0 |  | optional capability `package` |
| `pid.test` | 5 | 0 | 0 | 0 | 5 | `pidDefined` 4, `unixExecs` 1 | `pid` |
| `pkgMkIndex.test` | 27 | 0 | 0 | 25 | 2 | `exec` 2 | package index, `file` |
| `platform.test` | 6 | 1 | 0 | 2 | 3 | `testCPUID` 1, unreached 2 | `platform` package |
| `pwd.test` | 3 | 3 | 0 | 0 | 0 |  | `pwd`, `cd` |
| `safe-stock.test` | 4 | 0 | 0 | 4 | 0 |  | `interp -safe` |
| `safe.test` | 102 | 1 | 0 | 90 | 11 | `TcltestPackage` 6, `emptyTest` 2, unreached 3 | `interp -safe` |
| `security.test` | 1 | 1 | 0 | 0 | 0 |  | `interp`, host access |
| `socket.test` | 98 | 0 | 0 | 0 | 98 | `socket` 37, unreached 61 | `socket` |
| `source.test` | 23 | 13 | 0 | 10 | 0 |  | `source` |
| `stack.test` | 3 | 0 | 0 | 3 | 0 |  | host stack limits, `exec` |
| `tcltest.test` | 159 | 1 | 0 | 35 | 123 | `exec` 3, `unixExecs` 3, `expr:!singleTestInterp notWsl` 1, unreached 116 | the real `tcltest` package |
| `timer.test` | 54 | 0 | 0 | 48 | 6 | unreached 6 | `after` |
| `tm.test` | 21 | 0 | 0 | 21 | 0 |  | Tcl modules, `file` |
| `unixFCmd.test` | 49 | 2 | 0 | 26 | 21 | `emptyTest` 11, `readonlyAttr` 4, `nonPortable` 3 | `file` |
| `unixFile.test` | 7 | 0 | 0 | 0 | 7 | `testfindexecutable` 7 | `file` |
| `unixInit.test` | 8 | 0 | 0 | 1 | 7 | `stdio` 5, `emptyTest` 2 | `exec` of tclsh |
| `unload.test` | 27 | 0 | 0 | 7 | 20 | `pkgua.soRequired` 20 | `unload` |
| `zlib.test` | 73 | 0 | 0 | 1 | 72 | `zlib` 71, `knownBug` 1 | `zlib` |

## Cannot apply

| File | Total | Pass | Stand-in | Fail | Blocked | Blocked by | Reason |
|---|---|---|---|---|---|---|---|
| `assemble.test` | 284 | 0 | 0 | 280 | 4 | `memory` 4 | Tcl bytecode assembler; ztcl has its own bytecode |
| `assocd.test` | 11 | 0 | 0 | 0 | 11 | `testgetassocdata` 4, `testsetassocdata` 4, `testdelassocdata` 3 | C API |
| `async.test` | 12 | 0 | 0 | 0 | 12 | `testasync` 12 | C API |
| `cmdInfo.test` | 12 | 0 | 0 | 0 | 12 | `testcmdinfo` 9, `testcmdtoken` 3 | C API |
| `dcall.test` | 6 | 0 | 0 | 0 | 6 | `testdcall` 6 | C API |
| `dstring.test` | 44 | 0 | 0 | 0 | 44 | `testdstring` 44 | C API |
| `indexObj.test` | 45 | 0 | 0 | 0 | 45 | `testindexobj` 33, `testparseargs` 12 | C API |
| `link.test` | 29 | 0 | 0 | 0 | 29 | `testlink` 29 | C API |
| `macOSXFCmd.test` | 14 | 0 | 0 | 0 | 14 | `macosxFileAttr` 14 | macOS only |
| `macOSXLoad.test` | 0 | 0 | 0 | 0 | 0 |  | macOS only |
| `notify.test` | 23 | 0 | 0 | 0 | 23 | `testevent` 23 | C API |
| `obj.test` | 92 | 3 | 0 | 0 | 89 | `testobj` 84, `longIs32bit` 5 | C API |
| `registry.test` | 125 | 0 | 0 | 0 | 125 | `win` 125 | Windows only |
| `resolver.test` | 10 | 0 | 0 | 0 | 10 | `testinterpresolver` 10 | C API |
| `result.test` | 26 | 1 | 0 | 3 | 22 | `testsaveresult` 11, `testsetobjerrorcode` 5, `testseterrorcode` 4 | C API |
| `stringObj.test` | 75 | 0 | 0 | 0 | 75 | `testobj` 75 | C API |
| `thread.test` | 52 | 0 | 0 | 0 | 52 | `thread` 52 | threads |
| `unixForkEvent.test` | 1 | 0 | 0 | 0 | 1 | `testfork` 1 | needs fork |
| `unixNotfy.test` | 4 | 0 | 0 | 0 | 4 | `thread` 2, `unthreaded` 2 | threads and the notifier |
| `winConsole.test` | 1 | 0 | 0 | 0 | 1 | `win` 1 | Windows only |
| `winDde.test` | 50 | 0 | 0 | 0 | 50 | `dde` 49, `win` 1 | Windows only |
| `winFCmd.test` | 178 | 0 | 0 | 0 | 178 | `win` 168, `nt` 4, `winVista` 3, unreached 2 | Windows only |
| `winFile.test` | 11 | 0 | 0 | 0 | 11 | `win` 11 | Windows only |
| `winNotify.test` | 14 | 0 | 0 | 0 | 14 | `win` 14 | Windows only |
| `winPipe.test` | 56 | 0 | 0 | 0 | 56 | `win` 56 | Windows only |
| `winTime.test` | 3 | 0 | 0 | 0 | 3 | `win` 2, `testwinclock` 1 | Windows only |
