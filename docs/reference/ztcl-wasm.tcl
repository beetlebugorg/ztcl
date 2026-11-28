# The command reference: ztcl::wasm. The format is in
# docs/dev/reference-format.md.

command ztcl::wasm {
    area ztcl
    since 1.0.0-beta.1
    flags {--root . --allow channels,file}
    setup {
        package require ztcl::wasm
        # (func (export "add") (param i32 i32) (result i32))
        set m [ztcl::wasm new [binary decode hex 0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b]]
        set w [ztcl::wasm instantiate $m]
        # (memory (export "memory") 1 2), the bytes "hi" at 16, the globals "g" (mut i32 5) and "k" (i64 7), and (func (export "div") (param i32 i32) (result i32)) of i32.div_s
        set mem [ztcl::wasm new [binary decode hex 0061736d0100000001070160027f7f017f03020100050401010102060b027f0141050b7e0042070b071804066d656d6f7279020001670300016b03010364697600000a09010700200020016d0b0b09010041100b03686900]]
    }
    synopsis {ztcl::wasm SUBCOMMAND ?ARG ...?}
    summary {Runs WebAssembly modules in the sandbox and the limits of the interpreter.}
    description {
        The commands of a WebAssembly engine in ztcl: a validating decoder of the binary format and an interpreter, written in Zig from the WebAssembly specification. A program in C, Rust, Zig, Go (TinyGo), AssemblyScript, or another language that compiles to wasm runs in the sandbox and the limits of the interpreter. `new` and `load` decode and validate a module, `instantiate` links its imports to Tcl commands, to other instances, or to WASI preview 1, and `call` calls its exports with Tcl values.

        Load the module with `package require ztcl::wasm`. A module reaches only its linear memory and the imports that the script gives it, so the module needs no capability, except `file` for `load`, `package`, `run` of a file, and the folders of WASI. It is in the native `ztcl` programs, and `ztcl.wasm` has no `ztcl::wasm`. The engine reads core WebAssembly 2.0 and the extended constant expressions, and no SIMD, threads, exceptions, tail calls, multiple memories, or memory64.

        A module handle is `wasmmodN` and an instance handle is `wasmN`. A subcommand has no short form. The examples of this page run in an empty root folder with the capabilities `file` and `channels`, and the setup makes the module `$m` of the function `add`, its instance `$w`, and the module `$mem` of a memory, two globals, and the function `div`.

        The values: an `i32` is an integer from -2147483648 to 4294967295, an `i64` is an integer, `f32` and `f64` are floating-point numbers, an `externref` is an integer, and a `funcref` is the address of a function in the store; a null reference is an empty string. A result of `i32` or `i64` is signed.

        An error of the module has a code that starts with `ZTCL WASM`: `HANDLE`, `MALFORMED`, `INVALID`, `LINK`, `EXPORT`, `ARGS`, `VALUE`, `MEMORY`, `GLOBAL`, `LIMIT`, `PACKAGE`, `TRAP TEXT`, and `EXIT CODE`. A trap gives the message `wasm trap: TEXT`, with the texts of the spec tests, such as `integer divide by zero`.

        Each call and each pass of a loop of the wasm code uses one compute unit, and a copy or a fill of memory or of a table uses one unit for each 4,096 bytes or elements. The bytes of the modules, the memories, the tables, and the stack of the engine count toward the memory limit. The engine keeps up to 20,000 frames and 1,048,576 values, and a deeper recursion traps with `call stack exhausted`.
    }
    returns {The result of the subcommand.}
    cost {One compute unit for each call and each loop pass of the wasm code.}
    page modules/wasm/
    see {binary {interp limits}}
    example {
        list [ztcl::wasm call $w add 40 2] [ztcl::wasm exports $m]
    } {42 {add func {{i32 i32} i32}}}
    error {ztcl::wasm bogus} {unknown subcommand "bogus": must be call, delete, exports, global, imports, info, instantiate, jit, load, memory, new, package, or run} {TCL LOOKUP INDEX subcommand}
    error {ztcl::wasm n x} {unknown subcommand "n": must be call, delete, exports, global, imports, info, instantiate, jit, load, memory, new, package, or run} {TCL LOOKUP INDEX subcommand}
    error {ztcl::wasm} {wrong # args: should be "ztcl::wasm call|delete|exports|global|imports|info|instantiate|jit|load|memory|new|package|run ?arg ...?"} {TCL WRONGARGS}

    subcommand load {
        synopsis {ztcl::wasm load FILENAME}
        summary {Reads, decodes, and validates a module file, and gives a module handle.}
        description {Reads the file FILENAME, decodes and validates it as `new` does, and gives a module handle. It needs the capability `file`.}
        returns {A module handle.}
        see {{ztcl::wasm new} {ztcl::wasm run}}
        argument FILENAME {
            type path
            summary {The path of a `.wasm` file.}
        }
        example {
            set f [open add.wasm wb]
            puts -nonewline $f [binary decode hex 0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b]
            close $f
            set lm [ztcl::wasm load add.wasm]
            ztcl::wasm call [ztcl::wasm instantiate $lm] add 2 3
        } 5
        error {ztcl::wasm load x.wasm} {couldn't read file "x.wasm": no such file or directory} {POSIX ENOENT {no such file or directory}}
        error {
            set f [open bad.wasm wb]; puts -nonewline $f abc; close $f
            ztcl::wasm load bad.wasm
        } {malformed module: magic header not detected at byte 0} {ZTCL WASM MALFORMED}
        error {ztcl::wasm load} {wrong # args: should be "ztcl::wasm load fileName"} {TCL WRONGARGS}
    }

    subcommand new {
        synopsis {ztcl::wasm new BYTES}
        summary {Decodes and validates the bytes of a module, and gives a module handle.}
        description {Decodes the byte string BYTES, as from `binary decode` or a file read in binary, validates the module, and gives a module handle. A module that is not well formed gives `ZTCL WASM MALFORMED`, and a module that does not validate gives `ZTCL WASM INVALID`, each with the offset of the byte.}
        returns {A module handle.}
        see {{ztcl::wasm load} {ztcl::wasm instantiate} {binary decode}}
        argument BYTES {
            type {byte string}
            summary {The bytes of a module.}
        }
        example {string match wasmmod* $m} 1
        example {ztcl::wasm exports [ztcl::wasm new [binary decode hex 0061736d01000000]]} {}
        error {ztcl::wasm new xyz} {malformed module: magic header not detected at byte 0} {ZTCL WASM MALFORMED}
        error {ztcl::wasm new [binary decode hex 0061736d02000000]} {malformed module: unknown binary version at byte 4} {ZTCL WASM MALFORMED}
        error {ztcl::wasm new [binary decode hex 0061736d0100000001]} {malformed module: unexpected end at byte 9} {ZTCL WASM MALFORMED}
        error {ztcl::wasm new [binary decode hex 0061736d010000000105016000017f030201000a040102000b]} {invalid module: type mismatch at byte 24} {ZTCL WASM INVALID}
        error {ztcl::wasm new} {wrong # args: should be "ztcl::wasm new bytes"} {TCL WRONGARGS}
    }

    subcommand instantiate {
        synopsis {ztcl::wasm instantiate MODULE ?-imports DICT? ?-link DICT? ?-wasi DICT? ?-command NAME? ?-limit UNITS?}
        summary {Links the imports of a module, runs its start function, and gives an instance handle.}
        description {Makes an instance of MODULE with its own memory, tables, and globals. It links each import, runs the start function of the module, and gives the instance handle. An import with no value is an error with the code `ZTCL WASM LINK`. A module that imports from `wasi_snapshot_preview1` and exports `_initialize`, a WASI reactor, runs `_initialize` after the start function.}
        returns {An instance handle.}
        see {{ztcl::wasm call} {ztcl::wasm new} {ztcl::wasm delete}}
        argument MODULE {
            type handle
            summary {A module handle from `new` or `load`.}
        }
        example {string match wasm* $w} 1
        example {
            # (global (export "g") (mut i32) (i32.const 0)) and a start function that sets it to 9
            set sm [ztcl::wasm new [binary decode hex 0061736d01000000010401600000030201000606017f0141000b070501016703000801000a08010600410924000b]]
            ztcl::wasm global [ztcl::wasm instantiate $sm] g
        } 9
        error {
            # (import "env" "log" (func (param i32)))
            ztcl::wasm instantiate [ztcl::wasm new [binary decode hex 0061736d0100000001080260017f00600000020b0103656e76036c6f670000030201010707010372756e00010a08010600410710000b]]
        } {missing import "env" "log"} {ZTCL WASM LINK}
        error {ztcl::wasm instantiate $w} {can not find wasm module "wasm0"} {ZTCL WASM HANDLE}
        error {ztcl::wasm instantiate $m -bogus 1} {bad option "-bogus": must be -command, -imports, -limit, -link, or -wasi} {TCL LOOKUP INDEX option}
        error {ztcl::wasm instantiate} {wrong # args: should be "ztcl::wasm instantiate module ?-imports dict? ?-link dict? ?-wasi dict? ?-command name? ?-limit units?"} {TCL WRONGARGS}
        option -imports {
            value DICT
            type {dict of dicts}
            summary {Links imports to Tcl commands.}
            description {For each import module, a dict of the import names and Tcl command prefixes. A call of the import calls the prefix with the arguments as Tcl values, and the result of the command is the result of the import. The Tcl code can call the instance again. A prefix is looked up at the call, and an error of the command is an error of `call` with its message and code.}
            example {
                # (import "env" "log" (func (param i32))) and (func (export "run")) that calls it with 7
                set lm [ztcl::wasm new [binary decode hex 0061736d0100000001080260017f00600000020b0103656e76036c6f670000030201010707010372756e00010a08010600410710000b]]
                proc log {x} { puts "log $x" }
                ztcl::wasm call [ztcl::wasm instantiate $lm -imports {env {log log}}] run
            } {} -output "log 7\n"
            error {
                set lm [ztcl::wasm new [binary decode hex 0061736d0100000001080260017f00600000020b0103656e76036c6f670000030201010707010372756e00010a08010600410710000b]]
                proc bad {x} { error boom {} {MY ERROR} }
                ztcl::wasm call [ztcl::wasm instantiate $lm -imports {env {log bad}}] run
            } boom {MY ERROR}
            error {ztcl::wasm instantiate $m -imports env} {missing value to go with key} {TCL VALUE DICTIONARY}
        }
        option -link {
            value DICT
            type {dict of instance handles}
            summary {Links imports to the exports of other instances.}
            description {For each import module, an instance handle. An import gets the export of the same name from that instance: a function, a table, a memory, or a global.}
            example {
                # (import "env" "add" (func (param i32 i32) (result i32))) and (func (export "inc") (param i32) (result i32)) that adds 1
                set um [ztcl::wasm new [binary decode hex 0061736d01000000010c0260027f7f017f60017f017f020b0103656e760361646400000302010107070103696e6300010a0a0108002000410110000b]]
                ztcl::wasm call [ztcl::wasm instantiate $um -link [list env $w]] inc 41
            } 42
            error {
                set um [ztcl::wasm new [binary decode hex 0061736d01000000010c0260027f7f017f60017f017f020b0103656e760361646400000302010107070103696e6300010a0a0108002000410110000b]]
                ztcl::wasm instantiate $um -link {env nowasm}
            } {can not find wasm instance "nowasm"} {ZTCL WASM HANDLE}
        }
        option -wasi {
            value DICT
            type dict
            summary {Gives the module the imports of WASI preview 1.}
            description {The keys are `args`, `env`, `dirs`, and `stdin`, as the options of `run` of the same names. A call of `_start` that calls `proc_exit` is an error with the code `ZTCL WASM EXIT CODE`.}
            example {
                # (import "wasi_snapshot_preview1" "proc_exit") and a "_start" that exits with 3
                set em [ztcl::wasm new [binary decode hex 0061736d0100000001080260017f0060000002240116776173695f736e617073686f745f70726576696577310970726f635f657869740000030201010503010001071302066d656d6f72790200065f737461727400010a08010600410310000b]]
                set ew [ztcl::wasm instantiate $em -wasi {}]
                list [catch {ztcl::wasm call $ew _start} msg o] $msg [dict get $o -errorcode]
            } {1 {wasm exit 3} {ZTCL WASM EXIT 3}}
            error {ztcl::wasm instantiate $m -wasi {bogus 1}} {bad WASI option "bogus": must be args, dirs, env, or stdin} {TCL LOOKUP INDEX option}
        }
        option -command {
            value NAME
            type {command name}
            summary {Makes a command that calls the exports of the instance.}
            description {Makes the command `NAME FUNCTION ?ARG ...?`, the same as `ztcl::wasm call INSTANCE FUNCTION ?ARG ...?`. A command of that name is replaced. After `delete` of the instance the command stays, and a call of it is an error.}
            example {
                ztcl::wasm instantiate $m -command adder
                adder add 3 4
            } 7
            error {
                ztcl::wasm instantiate $m -command adder
                adder
            } {wrong # args: should be "adder func ?arg ...?"} {TCL WRONGARGS}
        }
        option -limit {
            value UNITS
            type integer
            summary {Gives the most compute units for the start function.}
            description {The start function stops with `ZTCL WASM LIMIT` after UNITS compute units.}
            example {string match wasm* [ztcl::wasm instantiate $m -limit 5]} 1
            error {
                # a start function that loops forever
                ztcl::wasm instantiate [ztcl::wasm new [binary decode hex 0061736d01000000010401600000030201000801000a0901070003400c000b0b]] -limit 50
            } {wasm trap: compute limit reached} {ZTCL WASM LIMIT}
            error {ztcl::wasm instantiate $m -limit} {wrong # args: should be "ztcl::wasm instantiate module ?-imports dict? ?-link dict? ?-wasi dict? ?-command name? ?-limit units?"} {TCL WRONGARGS}
        }
    }

    subcommand call {
        synopsis {ztcl::wasm call INSTANCE FUNCTION ?-limit UNITS? ?-raw? ?--? ?ARG ...?}
        summary {Calls an exported function and gives its result.}
        description {Calls the export FUNCTION of INSTANCE with the ARG values, one for each parameter. It gives the result, a list for more than one result, or an empty string for none. The options come after FUNCTION, and the first word that is not an option is the first ARG. A word of a dash and a letter that is no number, such as `-bogus`, is an unknown option and an error. A negative number, `-inf`, and `-nan` are arguments.}
        returns {The result, a list of the results, or an empty string.}
        see {{ztcl::wasm exports} {ztcl::wasm instantiate}}
        argument INSTANCE {
            type handle
            summary {An instance handle.}
        }
        argument FUNCTION {
            type string
            summary {The name of an exported function.}
        }
        argument ARG {
            type {wasm value}
            optional
            repeats
            summary {A value for a parameter.}
        }
        example {ztcl::wasm call $w add 40 2} 42
        example {ztcl::wasm call $w add 4294967295 1} 0
        example {
            set dw [ztcl::wasm instantiate $mem]
            ztcl::wasm call $dw div 7 2
        } 3
        example {
            # (func (export "two") (result i32 i32)) gives 1 and 2
            set mu [ztcl::wasm new [binary decode hex 0061736d01000000010f036000027f7f6000017c60017c017c0304030001020714030374776f00000468616c660001036e656700020a1a030600410141020b0b0044000000000000e03f0b050020009a0b]]
            ztcl::wasm call [ztcl::wasm instantiate $mu] two
        } {1 2}
        error {
            set dw [ztcl::wasm instantiate $mem]
            ztcl::wasm call $dw div 7 0
        } {wasm trap: integer divide by zero} {ZTCL WASM TRAP {integer divide by zero}}
        error {ztcl::wasm call $w add 1} {the function "add" has 2 parameters and got 1 arguments} {ZTCL WASM ARGS}
        error {ztcl::wasm call $w add -bogus 1 2} {bad option "-bogus": must be -limit, -raw, or --} {TCL LOOKUP INDEX option}
        error {ztcl::wasm call $w add 4294967296 1} {expected i32 but got "4294967296"} {ZTCL WASM VALUE}
        error {ztcl::wasm call $w add x 1} {expected integer but got "x"} {TCL VALUE NUMBER}
        error {ztcl::wasm call $w nope} {the instance has no export "nope"} {ZTCL WASM EXPORT}
        error {ztcl::wasm call $w -raw add 1 2} {the instance has no export "-raw"} {ZTCL WASM EXPORT}
        error {ztcl::wasm call $m add 1 2} {can not find wasm instance "wasmmod0"} {ZTCL WASM HANDLE}
        error {ztcl::wasm call $w} {wrong # args: should be "ztcl::wasm call instance function ?-limit units? ?-raw? ?--? ?arg ...?"} {TCL WRONGARGS}
        option -limit {
            value UNITS
            type integer
            summary {Gives the most compute units for the call.}
            description {The call stops after UNITS compute units with the error `wasm trap: compute limit reached` and the code `ZTCL WASM LIMIT`, which `catch` can catch. The units that the call used leave the limit of the interpreter.}
            example {
                # (func (export "spin")) loops forever
                set sm [ztcl::wasm new [binary decode hex 0061736d0100000001040160000003020100070801047370696e00000a0901070003400c000b0b]]
                set sw [ztcl::wasm instantiate $sm]
                list [catch {ztcl::wasm call $sw spin -limit 1000} msg] $msg
            } {1 {wasm trap: compute limit reached}}
            example {ztcl::wasm call $w add -limit 5 1 2} 3
            error {ztcl::wasm call $w add -limit 0 1 2} {wasm trap: compute limit reached} {ZTCL WASM LIMIT}
            error {ztcl::wasm call $w add -limit -1 1 2} {the limit must be 0 or more} {ZTCL WASM LIMIT}
            error {ztcl::wasm call $w add -limit x 1 2} {expected integer but got "x"} {TCL VALUE NUMBER}
            error {ztcl::wasm call $w add -limit} {missing value for option "-limit"} NONE
        }
        option -raw {
            type flag
            summary {Reads and gives each value as the unsigned integer of its bits.}
            description {Each ARG and each result is the unsigned integer of the bits of the value: an `f64` is its 64 bits, and an `i32` of -1 is 4294967295. It gives the exact bits of a NaN.}
            example {
                set mu [ztcl::wasm new [binary decode hex 0061736d01000000010f036000027f7f6000017c60017c017c0304030001020714030374776f00000468616c660001036e656700020a1a030600410141020b0b0044000000000000e03f0b050020009a0b]]
                set uw [ztcl::wasm instantiate $mu]
                list [ztcl::wasm call $uw half] [ztcl::wasm call $uw half -raw]
            } {0.5 4602678819172646912}
            example {
                set dw [ztcl::wasm instantiate $mem]
                ztcl::wasm call $dw div -raw -1 1
            } 4294967295
            noerrors {A flag has no value to check.}
        }
        option -- {
            type flag
            summary {Ends the options.}
            description {The next argument is the first ARG, also when it starts with `-`.}
            example {ztcl::wasm call $w add -- -1 -2} -3
            noerrors {A flag has no value to check.}
        }
    }

    subcommand package {
        synopsis {ztcl::wasm package FILENAME ?PREFIX? ?-wasi DICT?}
        summary {Loads a Tcl C package built for wasm32-wasi and runs its init function.}
        description {Loads a Tcl package in C that was built for `wasm32-wasi` with the stub library `libztclstubs.a` and the exports `ztcl_cext_*`, and runs its init function `Prefix_Init`. The commands of the package are commands of the interpreter, and the package runs in the limits of the interpreter. It needs the capability `file`. The package of SQLite (`tclsqlite3.c`) loads this way.}
        returns {The result of the init function.}
        see {load {ztcl::wasm run}}
        argument FILENAME {
            type path
            summary {The path of the `.wasm` file of the package.}
        }
        argument PREFIX {
            type string
            optional
            summary {The prefix of the init function, such as `Sqlite3`.}
        }
        example {
            set f [open add.wasm wb]
            puts -nonewline $f [binary decode hex 0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b]
            close $f
            catch {ztcl::wasm package add.wasm Add} msg
            set msg
        } {the module "add.wasm" has no export "ztcl_cext_reply" of a C package}
        error {ztcl::wasm package x.wasm} {couldn't read file "x.wasm": no such file or directory} {POSIX ENOENT {no such file or directory}}
        error {ztcl::wasm package} {wrong # args: should be "ztcl::wasm package fileName ?prefix? ?-wasi dict?"} {TCL WRONGARGS}
        option -wasi {
            value DICT
            type dict
            summary {Gives the package the folders and the other values of WASI.}
            description {The keys of the `-wasi` option of `instantiate`. With no `-wasi`, the package gets the imports of WASI with no folder. The options are checked before the file is read. A `-wasi` with no value is a wrong count of arguments.}
            example {
                set f [open add.wasm wb]
                puts -nonewline $f [binary decode hex 0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b]
                close $f
                catch {ztcl::wasm package add.wasm Add -wasi {dirs {. .}}} msg
                set msg
            } {the module "add.wasm" has no export "ztcl_cext_reply" of a C package}
            error {ztcl::wasm package x.wasm Add -wasi {bogus 1}} {bad WASI option "bogus": must be args, dirs, env, or stdin} {TCL LOOKUP INDEX option}
            error {ztcl::wasm package x.wasm Add -wasi} {wrong # args: should be "ztcl::wasm package fileName ?prefix? ?-wasi dict?"} {TCL WRONGARGS}
            error {ztcl::wasm package x.wasm Add -bogus 1} {bad option "-bogus": must be -wasi} {TCL LOOKUP INDEX option}
        }
    }

    subcommand run {
        synopsis {ztcl::wasm run MODULE|FILENAME ?-args LIST? ?-env DICT? ?-dirs DICT? ?-stdin TEXT? ?-imports DICT? ?-limit UNITS?}
        summary {Runs a WASI command and gives its exit code.}
        description {
            Instantiates a module handle or the module of a file with the imports of WASI preview 1, calls `_start`, and gives the exit code: the value of `proc_exit`, or 0 when `_start` returns. A plain `wasm32-wasi` program of C (`zig cc -target wasm32-wasi`), Zig, Rust, or TinyGo (`-target=wasip1`) runs.

            Each import goes through the capabilities of the interpreter. The standard output and error go to `puts -nonewline stdout` and `stderr`, so to the channel or to the callback of the embedder. `clock_time_get` needs the capability `clock`, and `random_get` needs `random`; without it a call gives `ENOTCAPABLE` (76). A clock subscription of `poll_oneoff` is due at once, sockets and links give `ENOTSUP`, and each call of a WASI function uses one compute unit.
        }
        returns {The exit code.}
        see {{ztcl::wasm instantiate} exec}
        argument MODULE|FILENAME {
            type {handle or path}
            summary {A module handle, or the path of a `.wasm` file.}
        }
        example {
            # fd_write of "hello\n" to stdout
            set hm [ztcl::wasm new [binary decode hex 0061736d01000000010c0260047f7f7f7f017f60000002230116776173695f736e617073686f745f70726576696577310866645f77726974650000030201010503010001071302066d656d6f72790200065f737461727400010a0f010d00410141004101411410001a0b0b19020041000b0808000000060000000041080b0668656c6c6f0a]]
            ztcl::wasm run $hm
        } 0 -output "hello\n"
        example {
            # proc_exit with 3
            set f [open exit3.wasm wb]
            puts -nonewline $f [binary decode hex 0061736d0100000001080260017f0060000002240116776173695f736e617073686f745f70726576696577310970726f635f657869740000030201010503010001071302066d656d6f72790200065f737461727400010a08010600410310000b]
            close $f
            ztcl::wasm run exit3.wasm
        } 3
        example {
            # proc_exit with the error number of clock_time_get
            ztcl::wasm run [ztcl::wasm new [binary decode hex 0061736d01000000010f0360017f0060037f7e7f017f600000024c0216776173695f736e617073686f745f70726576696577310970726f635f65786974000016776173695f736e617073686f745f70726576696577310e636c6f636b5f74696d655f6765740001030201020503010001071302066d656d6f72790200065f737461727400020a0e010c00410042014110100110000b]]
        } 76
        error {ztcl::wasm run $m} {the instance has no export "_start"} {ZTCL WASM EXPORT}
        error {ztcl::wasm run nosuch.wasm} {couldn't read file "nosuch.wasm": no such file or directory} {POSIX ENOENT {no such file or directory}}
        error {ztcl::wasm run $m -bogus 1} {bad option "-bogus": must be -args, -dirs, -env, -imports, -limit, or -stdin} {TCL LOOKUP INDEX option}
        error {ztcl::wasm run} {wrong # args: should be "ztcl::wasm run module|fileName ?-args list? ?-env dict? ?-dirs dict? ?-stdin text? ?-imports dict? ?-limit units?"} {TCL WRONGARGS}
        option -args {
            value LIST
            type list
            default {an empty list}
            summary {Gives the arguments of the program after its name.}
            description {The program gets the name of the module as its first argument, then the items of LIST.}
            example {
                # proc_exit with the count of arguments of args_sizes_get
                set am [ztcl::wasm new [binary decode hex 0061736d01000000010e0360017f0060027f7f017f600000024c0216776173695f736e617073686f745f70726576696577310970726f635f65786974000016776173695f736e617073686f745f70726576696577310e617267735f73697a65735f6765740001030201020503010001071302066d656d6f72790200065f737461727400020a120110004100410410011a410028020010000b]]
                list [ztcl::wasm run $am] [ztcl::wasm run $am -args {a b}]
            } {1 3}
            error {ztcl::wasm run $m -args} {wrong # args: should be "ztcl::wasm run module|fileName ?-args list? ?-env dict? ?-dirs dict? ?-stdin text? ?-imports dict? ?-limit units?"} {TCL WRONGARGS}
        }
        option -env {
            value DICT
            type dict
            default {an empty dict}
            summary {Gives the environment of the program.}
            description {The program sees only the names and values of DICT, and none of the environment of the host.}
            example {
                # proc_exit with the count of variables of environ_sizes_get
                set vm [ztcl::wasm new [binary decode hex 0061736d01000000010e0360017f0060027f7f017f600000024f0216776173695f736e617073686f745f70726576696577310970726f635f65786974000016776173695f736e617073686f745f707265766965773111656e7669726f6e5f73697a65735f6765740001030201020503010001071302066d656d6f72790200065f737461727400020a120110004100410410011a410028020010000b]]
                list [ztcl::wasm run $vm] [ztcl::wasm run $vm -env {A 1 B 2}]
            } {0 2}
            error {ztcl::wasm run $m -env A} {missing value to go with key} {TCL VALUE DICTIONARY}
        }
        option -dirs {
            value DICT
            type {dict of guest names and paths}
            summary {Gives the program preopened folders.}
            description {Each pair is a folder for the program: the guest name and a path of ztcl. It needs the capability `file`. The folder is inside the root folder of the interpreter, or a host path in host mode. A guest path stays inside its folder: `..` above the folder gives `ENOTCAPABLE`.}
            example {
                # proc_exit with the error number of fd_prestat_get of fd 3
                set pm [ztcl::wasm new [binary decode hex 0061736d01000000010e0360017f0060027f7f017f600000024c0216776173695f736e617073686f745f70726576696577310970726f635f65786974000016776173695f736e617073686f745f70726576696577310e66645f707265737461745f6765740001030201020503010001071302066d656d6f72790200065f737461727400020a0c010a0041034110100110000b]]
                list [ztcl::wasm run $pm] [ztcl::wasm run $pm -dirs {. .}]
            } {8 0}
            error {ztcl::wasm run $m -dirs x} {missing value to go with key} {TCL VALUE DICTIONARY}
        }
        option -stdin {
            value TEXT
            type string
            default {an empty string}
            summary {Gives the standard input of the program.}
            description {The program reads TEXT on its standard input, then the end of the file.}
            example {
                # proc_exit with the count of bytes of one fd_read of 8 bytes
                set im [ztcl::wasm new [binary decode hex 0061736d0100000001100360017f0060047f7f7f7f017f60000002450216776173695f736e617073686f745f70726576696577310970726f635f65786974000016776173695f736e617073686f745f70726576696577310766645f726561640001030201020503010001071302066d656d6f72790200065f737461727400020a16011400410041004101410810011a410828020010000b0b0e010041000b081000000008000000]]
                list [ztcl::wasm run $im] [ztcl::wasm run $im -stdin hello]
            } {0 5}
            error {ztcl::wasm run $m -stdin} {wrong # args: should be "ztcl::wasm run module|fileName ?-args list? ?-env dict? ?-dirs dict? ?-stdin text? ?-imports dict? ?-limit units?"} {TCL WRONGARGS}
        }
        option -imports {
            value DICT
            type {dict of dicts}
            summary {Links the imports that are not of WASI to Tcl commands.}
            description {The same as the `-imports` option of `instantiate`.}
            example {
                set lm [ztcl::wasm new [binary decode hex 0061736d0100000001080260017f00600000020b0103656e76036c6f670000030201010707010372756e00010a08010600410710000b]]
                catch {ztcl::wasm run $lm -imports {env {log puts}}} msg
                set msg
            } {the instance has no export "_start"}
            error {ztcl::wasm run $m -imports env} {missing value to go with key} {TCL VALUE DICTIONARY}
        }
        option -limit {
            value UNITS
            type integer
            summary {Gives the most compute units for the program.}
            description {The program stops after UNITS compute units with the error `wasm trap: compute limit reached` and the code `ZTCL WASM LIMIT`.}
            example {
                # a "_start" that loops forever
                set sm [ztcl::wasm new [binary decode hex 0061736d01000000010401600000030201000503010001071302066d656d6f72790200065f737461727400000a0901070003400c000b0b]]
                list [catch {ztcl::wasm run $sm -limit 100} msg] $msg
            } {1 {wasm trap: compute limit reached}}
            error {
                set sm [ztcl::wasm new [binary decode hex 0061736d01000000010401600000030201000503010001071302066d656d6f72790200065f737461727400000a0901070003400c000b0b]]
                ztcl::wasm run $sm -limit 100
            } {wasm trap: compute limit reached} {ZTCL WASM LIMIT}
        }
    }

    subcommand memory {
        synopsis {ztcl::wasm memory INSTANCE size}
        synopsis {ztcl::wasm memory INSTANCE grow PAGES}
        synopsis {ztcl::wasm memory INSTANCE read ADDRESS LENGTH}
        synopsis {ztcl::wasm memory INSTANCE write ADDRESS BYTES ?-text?}
        synopsis {ztcl::wasm memory INSTANCE string ADDRESS ?LENGTH?}
        summary {Reads, writes, and grows the linear memory of an instance.}
        description {
            Works on the memory that INSTANCE exports as `memory`, or on its first memory. A page is 65,536 bytes, and a range outside the memory is an error with the code `ZTCL WASM MEMORY`. The name of the subcommand is checked before the memory is looked up, so an unknown subcommand is the same error for an instance with no memory.

            - `size` gives the size in pages.
            - `grow` grows the memory by PAGES pages and gives the old size, or -1 past the maximum of the memory or at the memory limit.
            - `read` gives LENGTH bytes at ADDRESS as a byte string.
            - `write` writes the byte string BYTES at ADDRESS and gives the count of bytes. Each character is one byte, its low 8 bits.
            - `string` gives the UTF-8 text at ADDRESS, up to a zero byte, or up to LENGTH bytes.
        }
        returns {The size, the old size, the bytes, the count of bytes, or the text.}
        see {binary {ztcl::wasm global}}
        argument INSTANCE {
            type handle
            summary {An instance handle.}
        }
        example {
            set mw [ztcl::wasm instantiate $mem]
            list [ztcl::wasm memory $mw size] [ztcl::wasm memory $mw grow 1] [ztcl::wasm memory $mw grow 1] [ztcl::wasm memory $mw size]
        } {1 1 -1 2}
        example {
            set mw [ztcl::wasm instantiate $mem]
            list [ztcl::wasm memory $mw string 16] [ztcl::wasm memory $mw string 16 1] [binary encode hex [ztcl::wasm memory $mw read 16 4]]
        } {hi h 68690000}
        example {
            set mw [ztcl::wasm instantiate $mem]
            set n [ztcl::wasm memory $mw write 32 [binary decode hex 414243]]
            list $n [ztcl::wasm memory $mw string 32]
        } {3 ABC}
        error {
            set mw [ztcl::wasm instantiate $mem]
            ztcl::wasm memory $mw read 200000 4
        } {the range 200000 to 200004 is outside the memory of 65536 bytes} {ZTCL WASM MEMORY}
        error {
            set mw [ztcl::wasm instantiate $mem]
            ztcl::wasm memory $mw write 65535 ab
        } {the range 65535 to 65537 is outside the memory of 65536 bytes} {ZTCL WASM MEMORY}
        error {ztcl::wasm memory $w size} {the instance has no memory} {ZTCL WASM MEMORY}
        error {ztcl::wasm memory $w bogus} {unknown subcommand "bogus": must be grow, read, size, string, or write} {TCL LOOKUP INDEX subcommand}
        error {
            set mw [ztcl::wasm instantiate $mem]
            ztcl::wasm memory $mw read -1 4
        } {the range -1 to 3 is outside the memory of 65536 bytes} {ZTCL WASM MEMORY}
        error {ztcl::wasm memory $mem size} {can not find wasm instance "wasmmod1"} {ZTCL WASM HANDLE}
        error {
            set mw [ztcl::wasm instantiate $mem]
            ztcl::wasm memory $mw bogus
        } {unknown subcommand "bogus": must be grow, read, size, string, or write} {TCL LOOKUP INDEX subcommand}
        error {
            set mw [ztcl::wasm instantiate $mem]
            ztcl::wasm memory $mw s 16
        } {unknown subcommand "s": must be grow, read, size, string, or write} {TCL LOOKUP INDEX subcommand}
        error {ztcl::wasm memory $w} {wrong # args: should be "ztcl::wasm memory instance size|read|write|string|grow ?arg ...?"} {TCL WRONGARGS}
        error {
            set mw [ztcl::wasm instantiate $mem]
            ztcl::wasm memory $mw grow
        } {wrong # args: should be "ztcl::wasm memory instance grow pages"} {TCL WRONGARGS}
        error {
            set mw [ztcl::wasm instantiate $mem]
            ztcl::wasm memory $mw read 0 x
        } {expected integer but got "x"} {TCL VALUE NUMBER}
        option -text {
            type flag
            summary {Writes the UTF-8 bytes of a string.}
            description {`write` writes the UTF-8 bytes of the string BYTES, so a character can be more than one byte.}
            example {
                set mw [ztcl::wasm instantiate $mem]
                set n [ztcl::wasm memory $mw write 40 "hé" -text]
                list $n [binary encode hex [ztcl::wasm memory $mw read 40 3]]
            } {3 68c3a9}
            error {
                set mw [ztcl::wasm instantiate $mem]
                ztcl::wasm memory $mw write 0 ab -bogus
            } {bad option "-bogus": must be -text} {TCL LOOKUP INDEX option}
        }
    }

    subcommand global {
        synopsis {ztcl::wasm global INSTANCE NAME ?VALUE?}
        summary {Reads or sets an exported global.}
        description {Gives the value of the global that INSTANCE exports as NAME. With VALUE it sets a mutable global and gives the new value as the type of the global gives it.}
        returns {The value of the global.}
        see {{ztcl::wasm exports} {ztcl::wasm memory}}
        argument INSTANCE {
            type handle
            summary {An instance handle.}
        }
        argument NAME {
            type string
            summary {The name of an exported global.}
        }
        argument VALUE {
            type {wasm value}
            optional
            summary {The new value.}
        }
        example {
            set gw [ztcl::wasm instantiate $mem]
            list [ztcl::wasm global $gw g] [ztcl::wasm global $gw g 11] [ztcl::wasm global $gw k]
        } {5 11 7}
        example {
            set gw [ztcl::wasm instantiate $mem]
            ztcl::wasm global $gw g 4294967295
        } -1
        error {
            set gw [ztcl::wasm instantiate $mem]
            ztcl::wasm global $gw k 1
        } {the global "k" is immutable} {ZTCL WASM GLOBAL}
        error {
            set gw [ztcl::wasm instantiate $mem]
            ztcl::wasm global $gw div
        } {the export "div" is not a global} {ZTCL WASM EXPORT}
        error {ztcl::wasm global $w nope} {the instance has no export "nope"} {ZTCL WASM EXPORT}
        error {
            set gw [ztcl::wasm instantiate $mem]
            ztcl::wasm global $gw g x
        } {expected integer but got "x"} {TCL VALUE NUMBER}
        error {ztcl::wasm global $w} {wrong # args: should be "ztcl::wasm global instance name ?value?"} {TCL WRONGARGS}
    }

    subcommand exports {
        synopsis {ztcl::wasm exports MODULE|INSTANCE}
        summary {Gives the name, the kind, and the type of each export.}
        description {Gives a flat list of three items for each export: its name; its kind, `func`, `table`, `mem`, or `global`; and its type. The type of a function is the list of its parameter types and its result types, the type of a table or a memory is its minimum and its maximum, empty for no maximum, and the type of a global is its value type.}
        returns {A list of name, kind, and type for each export.}
        see {{ztcl::wasm imports} {ztcl::wasm info}}
        argument MODULE|INSTANCE {
            type handle
            summary {A module handle or an instance handle.}
        }
        example {list [ztcl::wasm exports $m] [ztcl::wasm exports $w]} {{add func {{i32 i32} i32}} {add func {{i32 i32} i32}}}
        example {ztcl::wasm exports $mem} {memory mem {1 2} g global i32 k global i64 div func {{i32 i32} i32}}
        example {
            # (table (export "t") 2 funcref)
            ztcl::wasm exports [ztcl::wasm new [binary decode hex 0061736d0100000004040170000207050101740100]]
        } {t table {2 {}}}
        error {ztcl::wasm exports nope} {can not find wasm instance "nope"} {ZTCL WASM HANDLE}
        error {ztcl::wasm exports} {wrong # args: should be "ztcl::wasm exports module|instance"} {TCL WRONGARGS}
    }

    subcommand imports {
        synopsis {ztcl::wasm imports MODULE}
        summary {Gives the module, the name, the kind, and the type of each import.}
        description {Gives a flat list of four items for each import of MODULE: the import module, the name, the kind, and the type, as `exports` gives them.}
        returns {A list of module, name, kind, and type for each import.}
        see {{ztcl::wasm exports} {ztcl::wasm instantiate}}
        argument MODULE {
            type handle
            summary {A module handle.}
        }
        example {
            set lm [ztcl::wasm new [binary decode hex 0061736d0100000001080260017f00600000020b0103656e76036c6f670000030201010707010372756e00010a08010600410710000b]]
            ztcl::wasm imports $lm
        } {env log func {i32 {}}}
        example {ztcl::wasm imports $m} {}
        error {ztcl::wasm imports $w} {can not find wasm module "wasm0"} {ZTCL WASM HANDLE}
        error {ztcl::wasm imports} {wrong # args: should be "ztcl::wasm imports module"} {TCL WRONGARGS}
    }

    subcommand info {
        synopsis {ztcl::wasm info MODULE}
        summary {Gives a dict of the counts and the features of a module.}
        description {Gives a dict with the counts `functions`, `imports`, `exports`, `memories`, `tables`, and `instructions`, and the list `features` of the features of WebAssembly 2.0 that the module uses.}
        returns {A dict.}
        see {{ztcl::wasm exports} {ztcl::wasm imports}}
        argument MODULE {
            type handle
            summary {A module handle.}
        }
        example {ztcl::wasm info $m} {functions 1 imports 0 exports 1 memories 0 tables 0 instructions 4 features {}}
        example {dict get [ztcl::wasm info $mem] memories} 1
        error {ztcl::wasm info $w} {can not find wasm module "wasm0"} {ZTCL WASM HANDLE}
        error {ztcl::wasm info} {wrong # args: should be "ztcl::wasm info module"} {TCL WRONGARGS}
    }

    subcommand delete {
        synopsis {ztcl::wasm delete ?HANDLE ...?}
        summary {Deletes modules and instances.}
        description {Deletes each module and instance of the HANDLE arguments, and with no HANDLE it does no work. An instance stays valid after `delete` of its module. The interpreter frees each module and instance that is left when it ends.}
        returns {An empty string.}
        see {{ztcl::wasm new} {ztcl::wasm instantiate}}
        argument HANDLE {
            type handle
            optional
            repeats
            summary {A module handle or an instance handle.}
        }
        example {
            set dm [ztcl::wasm new [binary decode hex 0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b]]
            set dw [ztcl::wasm instantiate $dm]
            ztcl::wasm delete $dm
            set r [ztcl::wasm call $dw add 1 2]
            ztcl::wasm delete $dw
            list $r [catch {ztcl::wasm call $dw add 1 2}]
        } {3 1}
        example {ztcl::wasm delete} {}
        error {ztcl::wasm delete nope} {can not find wasm instance "nope"} {ZTCL WASM HANDLE}
    }

    subcommand jit {
        synopsis {ztcl::wasm jit ?BOOLEAN?}
        summary {Reads or sets the use of the JIT tier.}
        description {On x86-64 Linux and macOS, the engine compiles a module to machine code at its first call, and the calls run in that code; elsewhere the interpreter of the engine runs. The JIT gives the same results, traps, compute units, and NaN bits as the interpreter. With BOOLEAN it turns the JIT on or off for the calls of the interpreter. It gives 1 when the JIT is on, so on a platform with no JIT it gives 0 also after `ztcl::wasm jit 1`.}
        returns {1 or 0.}
        see {{ztcl::wasm call}}
        argument BOOLEAN {
            type boolean
            optional
            summary {1 to use the JIT, 0 to use the interpreter.}
        }
        example {ztcl::wasm jit 0} 0
        example {string is boolean [ztcl::wasm jit]} 1
        error {ztcl::wasm jit x} {expected boolean value but got "x"} NONE
        error {ztcl::wasm jit 1 2} {wrong # args: should be "ztcl::wasm jit ?boolean?"} {TCL WRONGARGS}
    }
}
