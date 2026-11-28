# Converted by tools/refdoc.tcl convert from ztcl.txt.

command ztcl::meter {
    area ztcl
    since TODO
    synopsis {ztcl::meter subcommand ?arg ...?}
    summary {Counts the compute units, the time, the memory, and the I/O of threads and child interpreters, for a host that bills its customers.}
    description {Counts the compute units, the time, the memory, and the I/O of threads and child interpreters, for a host that bills its customers. A compute unit is the same on each machine and with the JIT on or off. A record is a line of JSON in a hash chain, with an optional Ed25519 signature.}
    capability {meter}
    page {modules/meter.md}
    flags {--allow meter}
    example {ztcl::meter create demo -tenant acme} demo
    example {ztcl::meter run demo {set a 1; set b 2}; dict get [ztcl::meter get demo] units} 2
    example {ztcl::meter create small -budget 100} small
    example {catch {ztcl::meter run small {while 1 {}}} msg; set msg} {compute limit reached}
    error {ztcl::meter get nope} {no meter "nope"} {ZTCL METER NAME}
    subcommand create {
        synopsis {ztcl::meter create NAME ?-budget UNITS? ?-tenant TEXT?}
        summary {Makes the meter NAME, or sets the options of the meter NAME.}
        description {Makes the meter NAME, or sets the options of the meter NAME. A budget caps the compute units of all the threads of the meter.}
    }
    subcommand get {
        synopsis {ztcl::meter get NAME}
        summary {The dict of the counts of NAME.}
        description {The dict of the counts of NAME.}
    }
    subcommand list {
        synopsis {ztcl::meter list}
        summary {The names of the meters.}
        description {The names of the meters.}
    }
    subcommand reset {
        synopsis {ztcl::meter reset NAME}
        summary {Sets each count of NAME to zero.}
        description {Sets each count of NAME to zero.}
    }
    subcommand delete {
        synopsis {ztcl::meter delete NAME}
        summary {Removes NAME.}
        description {Removes NAME. A thread that counts in it goes on to count in it until it ends.}
    }
    subcommand run {
        synopsis {ztcl::meter run NAME SCRIPT}
        summary {Runs SCRIPT in the current interpreter and counts it in NAME.}
        description {Runs SCRIPT in the current interpreter and counts it in NAME. The budget of NAME caps the units of SCRIPT.}
    }
    subcommand record {
        synopsis {ztcl::meter record NAME ?-tenant TEXT? ?-script TEXT? ?-sign? ?-key SEED?}
        summary {The usage record of NAME: one line of JSON with the SHA-256 of the record before it.}
        description {The usage record of NAME: one line of JSON with the SHA-256 of the record before it. `-key` signs with the Ed25519 key of a 64-digit hex seed, and `-sign` with the key of the host.}
    }
    subcommand verify {
        synopsis {ztcl::meter verify RECORD PUBLICKEY}
        summary {1 when the signature of RECORD matches the hex public key, else 0.}
        description {1 when the signature of RECORD matches the hex public key, else 0.}
    }
    subcommand pubkey {
        synopsis {ztcl::meter pubkey SEED}
        summary {The hex public key of a hex seed.}
        description {The hex public key of a hex seed.}
    }
}
