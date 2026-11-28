# The command reference: ztcl::meter. The format is in
# docs/dev/reference-format.md.

command ztcl::meter {
    area ztcl
    since 1.0.0-beta.1
    capability meter
    flags {--allow meter,interp}
    setup {package require ztcl::json}
    synopsis {ztcl::meter SUBCOMMAND ?ARG ...?}
    summary {Counts the compute units, the time, the memory, and the I/O of threads and child interpreters.}
    description {
        The meters of a host that bills its customers for the scripts that it runs. A meter counts the compute units, the wall time, the CPU time, the memory, and the I/O of the threads and child interpreters that count in it, and `record` writes the counts as a line of JSON in a hash chain, with an optional Ed25519 signature. A compute unit is the same on each machine, with the JIT on or off, and at each isolation level. [Metering](metering/) is the guide.

        The command is not a package: it exists when the embedder turns on the capability `meter`, and it is absent otherwise. The same capability turns on the option `-meter` of `thread::create` and of `interp create`, which make the meter when it does not exist. The counts of time depend on the host, so the capability is off by default, as the clock is. All the threads of a thread group share the names of the meters.

        A subcommand has no short form. An error of the module has a code that starts with `ZTCL METER`: `NAME` for a name with no meter, `BUSY` for `run` in an interpreter that already counts in a meter, and `KEY` for a seed or a public key that is not 64 hex digits, or `-sign` with no key of the host. An unknown subcommand gives `TCL LOOKUP SUBCOMMAND` with no name after it ([issue 720](https://github.com/beetlebugorg/ztcl/issues/720)).

        The examples of this page run with `--allow meter,interp`, and the setup loads `ztcl::json` to read the records.
    }
    returns {The result of the subcommand.}
    page modules/meter/
    see {ztcl::gc {interp limits} {interp create}}
    example {ztcl::meter create demo -tenant acme} demo
    example {
        ztcl::meter create demo
        ztcl::meter run demo {set a 1; set b 2}
        dict get [ztcl::meter get demo] units
    } 2
    example {
        ztcl::meter create small -budget 100
        catch {ztcl::meter run small {while 1 {}}} msg
        set msg
    } {compute limit reached}
    error {ztcl::meter nope} {unknown or ambiguous subcommand "nope": must be create, delete, get, list, pubkey, record, reset, run, or verify} {TCL LOOKUP SUBCOMMAND}
    error {ztcl::meter cr x} {unknown or ambiguous subcommand "cr": must be create, delete, get, list, pubkey, record, reset, run, or verify} {TCL LOOKUP SUBCOMMAND}
    error {ztcl::meter} {wrong # args: should be "ztcl::meter subcommand ?arg ...?"} {TCL WRONGARGS}

    subcommand create {
        synopsis {ztcl::meter create NAME ?-budget UNITS? ?-tenant TEXT?}
        summary {Makes a meter, or sets the options of a meter, and gives its name.}
        description {Makes the meter NAME with each count at zero, or sets the options of the meter NAME when it exists. It gives NAME.}
        returns {NAME.}
        see {{ztcl::meter delete} {ztcl::meter list}}
        argument NAME {
            type string
            summary {The name of the meter.}
        }
        example {ztcl::meter create demo} demo
        example {
            interp create c -meter m9
            lsearch -inline [ztcl::meter list] m9
        } m9
        error {ztcl::meter create} {wrong # args: should be "ztcl::meter create name ?-budget units? ?-tenant text?"} {TCL WRONGARGS}
        error {ztcl::meter create d -bogus 1} {bad option "-bogus": must be -budget or -tenant} {TCL LOOKUP INDEX option}
        error {ztcl::meter create d -t x} {bad option "-t": must be -budget or -tenant} {TCL LOOKUP INDEX option}
        option -budget {
            value UNITS
            type {integer or empty}
            default {an empty string, no cap}
            summary {Caps the compute units of all the work of the meter.}
            description {
                The most compute units of the scripts, threads, and children of the meter, 0 or more. An empty UNITS removes the cap.

                A thread that starts with a meter that has a budget gets at most the units that are left, and the meter holds them until the thread ends, so two threads that run at the same time cannot spend more than the budget. At the end of its units a thread gets the compute-limit error, which no script can catch, and ends. A script of `run` gets the error `compute limit reached`, and the caller of `run` can catch it.
            }
            example {
                ztcl::meter create b -budget 1000
                ztcl::meter run b {set x 1}
                set m [ztcl::meter get b]
                list [dict get $m budget] [dict get $m left]
            } {1000 999}
            example {
                ztcl::meter create a -budget 50
                ztcl::meter create a -budget {}
                dict get [ztcl::meter get a] budget
            } {}
            error {ztcl::meter create d -budget x} {expected integer but got "x"} NONE
            error {ztcl::meter create d -budget -5} {bad budget "-5": must be 0 or more} NONE
            error {ztcl::meter create d -budget} {wrong # args: should be "ztcl::meter create name ?-budget units? ?-tenant text?"} {TCL WRONGARGS}
        }
        option -tenant {
            value TEXT
            type string
            default {an empty string}
            summary {Gives the tenant of the records of the meter.}
            description {The text of the field `tenant` of each record of the meter.}
            example {
                ztcl::meter create c -tenant t1
                ztcl::json get [ztcl::meter record c] tenant
            } t1
            noerrors {Each text is a valid tenant.}
        }
    }

    subcommand get {
        synopsis {ztcl::meter get NAME}
        summary {Gives the dict of the counts of a meter.}
        description {
            Gives a dict with these keys:

            - `name`: the name of the meter;
            - `units`: the compute units;
            - `wall_us`, `cpu_us`: the wall time of each thread and child, and the CPU time of each thread, in microseconds, added up;
            - `mem_peak`: the highest count of bytes of one thread or child;
            - `mem_avg`, `mem_byte_ms`: the bytes in use on average over `wall_us`, and the bytes in use times the milliseconds;
            - `threads`: a dict of the threads of each level, `interp` and `process`;
            - `io`: a dict of `file`, `socket`, and `pipe`, each a dict of the bytes of `read` and `write`;
            - `connections`: the sockets that a script opened;
            - `net`: a dict of host words, each a dict of `read`, `write`, and `connections`; after 256 hosts the bytes go to the word `other`;
            - `process`: a dict for the threads of the level `process`, of `messages`, `bytes`, `start_us`, `os_cpu_us`, and `os_mem_peak`;
            - `vm`: a dict of `guests`, `run_us`, and `mem_byte_ms` for the guests of `ztcl::vm`, each 0 in this version;
            - `budget`, `left`: the budget and the units left in it, or empty strings.

            The counts of a thread come in at its safe points, at the end of each script that `thread::send` runs in it, and at its end, so a read from another thread sees the counts of the last such point. A thread of the level `process` adds its counts at its end only. The wasm and WASI builds read no clock, so the counts of time are 0 there.
        }
        returns {A dict.}
        see {{ztcl::meter record} {ztcl::meter reset}}
        argument NAME {
            type string
            summary {The name of a meter.}
        }
        example {
            ztcl::meter create demo
            dict keys [ztcl::meter get demo]
        } {name units wall_us cpu_us mem_peak mem_avg mem_byte_ms threads io connections net process vm budget left}
        example {
            ztcl::meter create demo
            set m [ztcl::meter get demo]
            list [dict get $m threads] [dict get $m io file]
        } {{interp 0 process 0} {read 0 write 0}}
        example {
            interp create k -meter g
            k eval {set a 1; set b 2}
            dict get [ztcl::meter get g] units
        } 2
        error {ztcl::meter get nope} {no meter "nope"} {ZTCL METER NAME}
        error {ztcl::meter get} {wrong # args: should be "ztcl::meter get name"} {TCL WRONGARGS}
    }

    subcommand list {
        synopsis {ztcl::meter list}
        summary {Gives the names of the meters.}
        description {Gives the names of the meters, in the order that they were made.}
        returns {A list of names.}
        see {{ztcl::meter create}}
        example {ztcl::meter list} {}
        example {
            ztcl::meter create b
            ztcl::meter create a
            ztcl::meter list
        } {b a}
        error {ztcl::meter list x} {wrong # args: should be "ztcl::meter list"} {TCL WRONGARGS}
    }

    subcommand reset {
        synopsis {ztcl::meter reset NAME}
        summary {Sets each count of a meter to zero.}
        description {Sets each count of NAME to zero, and the start time of the next record to now. The sequence of the records goes on.}
        returns {An empty string.}
        see {{ztcl::meter get} {ztcl::meter record}}
        argument NAME {
            type string
            summary {The name of a meter.}
        }
        example {
            ztcl::meter create e
            ztcl::meter run e {set a 1}
            ztcl::meter record e
            ztcl::meter reset e
            list [dict get [ztcl::meter get e] units] [ztcl::json get [ztcl::meter record e] seq]
        } {0 2}
        error {ztcl::meter reset nope} {no meter "nope"} {ZTCL METER NAME}
        error {ztcl::meter reset} {wrong # args: should be "ztcl::meter reset name"} {TCL WRONGARGS}
    }

    subcommand delete {
        synopsis {ztcl::meter delete NAME}
        summary {Removes a meter.}
        description {Removes the name NAME. A thread that counts in the meter goes on to count in it until the thread ends.}
        returns {An empty string.}
        see {{ztcl::meter create}}
        argument NAME {
            type string
            summary {The name of a meter.}
        }
        example {
            ztcl::meter create a
            ztcl::meter create b
            ztcl::meter delete a
            ztcl::meter list
        } b
        error {ztcl::meter delete nope} {no meter "nope"} {ZTCL METER NAME}
        error {ztcl::meter delete a b} {wrong # args: should be "ztcl::meter delete name"} {TCL WRONGARGS}
    }

    subcommand run {
        synopsis {ztcl::meter run NAME SCRIPT}
        summary {Runs a script in the current interpreter and counts it in a meter.}
        description {Runs SCRIPT in the current interpreter, counts its use in NAME, and gives the result of SCRIPT. The budget of NAME caps the units of SCRIPT: at the end of the budget, SCRIPT gets the error `compute limit reached`, with `-errorcode NONE`, and the caller can catch it. An error of SCRIPT is the error of `run`.}
        returns {The result of SCRIPT.}
        see {{ztcl::meter get} {interp limits}}
        argument NAME {
            type string
            summary {The name of a meter.}
        }
        argument SCRIPT {
            type script
            summary {The script to run and count.}
        }
        example {
            ztcl::meter create f
            ztcl::meter run f {expr {6 * 7}}
        } 42
        example {
            ztcl::meter create loop
            ztcl::meter run loop {for {set i 0} {$i < 10} {incr i} {}}
            dict get [ztcl::meter get loop] units
        } 22
        example {
            ztcl::meter create i -budget 10
            catch {ztcl::meter run i {while 1 {}}}
            dict get [ztcl::meter get i] left
        } 0
        error {
            ztcl::meter create f
            ztcl::meter run f {error boom}
        } boom NONE
        error {
            ztcl::meter create none -budget 0
            ztcl::meter run none {set a 1}
        } {compute limit reached} NONE
        error {
            ztcl::meter create outer
            ztcl::meter run outer {ztcl::meter run outer {}}
        } {the interpreter already counts in a meter} {ZTCL METER BUSY}
        error {ztcl::meter run nope {}} {no meter "nope"} {ZTCL METER NAME}
        error {ztcl::meter run demo} {wrong # args: should be "ztcl::meter run name script"} {TCL WRONGARGS}
    }

    subcommand record {
        synopsis {ztcl::meter record NAME ?-tenant TEXT? ?-script TEXT? ?-sign? ?-key SEED?}
        summary {Gives the usage record of a meter: one line of JSON in a hash chain.}
        description {
            Gives one line of JSON with the fields `version`, `meter`, `tenant`, `seq`, `start_ms`, `end_ms`, the counts of `get`, and `prev`:

            - `seq` counts the records of the meter, from 1;
            - `start_ms` and `end_ms` are the start of the counts and now, in milliseconds since 1970;
            - `prev` is the SHA-256 of the previous record of the meter, as hex, or 64 zeros for the first, so a removed or changed record breaks the chain.

            With `-key` or `-sign`, the record ends with `key`, the hex public key, and `sig`, the hex Ed25519 signature. The signed text is the record with `,"sig":"..."` removed: everything before `,"sig"`, then a closing brace. A customer checks a record in any language: cut off the last field, add a closing brace, and check the signature with the public key of the host.
        }
        returns {A line of JSON.}
        see {{ztcl::meter verify} {ztcl::meter get} ztcl::json}
        argument NAME {
            type string
            summary {The name of a meter.}
        }
        example {
            ztcl::meter create c
            set r [ztcl::meter record c]
            list [ztcl::json get $r version] [ztcl::json get $r meter] [ztcl::json get $r seq] [ztcl::json get $r prev] [ztcl::json exists $r sig]
        } {1 c 1 0000000000000000000000000000000000000000000000000000000000000000 0}
        example {
            ztcl::meter create c2
            ztcl::meter record c2
            ztcl::json get [ztcl::meter record c2] seq
        } 2
        error {ztcl::meter record nope} {no meter "nope"} {ZTCL METER NAME}
        error {ztcl::meter record} {wrong # args: should be "ztcl::meter record name ?-tenant text? ?-script text? ?-sign? ?-key seed?"} {TCL WRONGARGS}
        error {
            ztcl::meter create c
            ztcl::meter record c -bogus 1
        } {bad option "-bogus": must be -key, -script, -sign, or -tenant} {TCL LOOKUP INDEX option}
        option -tenant {
            value TEXT
            type string
            summary {Gives the tenant of this record.}
            description {The field `tenant` of this record is TEXT, in place of the tenant of the meter. The meter keeps its tenant.}
            example {
                ztcl::meter create h -tenant acme
                set a [ztcl::json get [ztcl::meter record h -tenant x] tenant]
                list $a [ztcl::json get [ztcl::meter record h] tenant]
            } {x acme}
            noerrors {Each text is a valid tenant.}
        }
        option -script {
            value TEXT
            type string
            summary {Adds the SHA-256 of a script to the record.}
            description {The record has the field `script_sha256`, the hex SHA-256 of the UTF-8 bytes of TEXT, after `end_ms`.}
            example {
                ztcl::meter create d
                ztcl::json get [ztcl::meter record d -script {puts hi}] script_sha256
            } 3c7a71eb5dc3bdec4b2c935ae8e8fe52a9d6b2af64c1ac7c7319fb8d4750af8f
            noerrors {Each text has a hash.}
        }
        option -sign {
            type flag
            summary {Signs the record with the key of the host.}
            description {Signs with the Ed25519 key that the embedder sets in `Interp.meter_key`, so the script never has the key. The `ztcl` program sets no key.}
            example {
                ztcl::meter create s
                catch {ztcl::meter record s -sign} msg
                set msg
            } {the host gave no key: use -key, or set Interp.meter_key}
            error {
                ztcl::meter create s
                ztcl::meter record s -sign
            } {the host gave no key: use -key, or set Interp.meter_key} {ZTCL METER KEY}
        }
        option -key {
            value SEED
            type {64 hex digits}
            summary {Signs the record with the Ed25519 key of a seed.}
            description {Signs with the key pair of the 32-byte seed SEED, given as 64 hex digits. It serves tests and a host script that holds its own key.}
            example {
                ztcl::meter create k
                set seed [string repeat 0 63]1
                set r [ztcl::meter record k -key $seed]
                list [string equal [ztcl::json get $r key] [ztcl::meter pubkey $seed]] [ztcl::meter verify $r [ztcl::meter pubkey $seed]]
            } {1 1}
            error {
                ztcl::meter create k
                ztcl::meter record k -key xyz
            } {a seed is 64 hex digits} {ZTCL METER KEY}
        }
    }

    subcommand verify {
        synopsis {ztcl::meter verify RECORD PUBLICKEY}
        summary {Checks the signature of a record.}
        description {Gives 1 when the Ed25519 signature of the signed record RECORD matches the hex public key PUBLICKEY, else 0. A changed record or another key gives 0.}
        returns {1 or 0.}
        see {{ztcl::meter record} {ztcl::meter pubkey}}
        argument RECORD {
            type {line of JSON}
            summary {A record of `record -key` or `record -sign`.}
        }
        argument PUBLICKEY {
            type {64 hex digits}
            summary {The public key of the signer.}
        }
        example {
            ztcl::meter create v
            set seed [string repeat 0 63]1
            set r [ztcl::meter record v -key $seed]
            set other [ztcl::meter pubkey [string repeat 0 63]2]
            set bad [string map {{"units":} {"units":1}} $r]
            list [ztcl::meter verify $r [ztcl::meter pubkey $seed]] [ztcl::meter verify $r $other] [ztcl::meter verify $bad [ztcl::meter pubkey $seed]]
        } {1 0 0}
        error {ztcl::meter verify {{}} xyz} {a public key is 64 hex digits} {ZTCL METER KEY}
        error {ztcl::meter verify} {wrong # args: should be "ztcl::meter verify record publickey"} {TCL WRONGARGS}
    }

    subcommand pubkey {
        synopsis {ztcl::meter pubkey SEED}
        summary {Gives the hex public key of a seed.}
        description {Gives the hex Ed25519 public key of the 32-byte seed SEED, given as 64 hex digits.}
        returns {64 hex digits.}
        see {{ztcl::meter verify}}
        argument SEED {
            type {64 hex digits}
            summary {The seed of the key pair.}
        }
        example {ztcl::meter pubkey [string repeat 0 64]} 3b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da29
        error {ztcl::meter pubkey xyz} {a seed is 64 hex digits} {ZTCL METER KEY}
        error {ztcl::meter pubkey} {wrong # args: should be "ztcl::meter pubkey seed"} {TCL WRONGARGS}
    }
}
