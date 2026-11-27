# The prelude of tools/thread-tests.sh -p prelude/vm.tcl: each thread::create
# with no -isolation option runs its thread in the ztcl unikernel
# (-isolation vm, ztcl#471). The pools of tpool keep their threads.
# SPDX-License-Identifier: BSD-2-Clause
rename thread::create ::thread::create_interp
proc thread::create {args} {
    if {"-isolation" ni $args} {set args [linsert $args 0 -isolation vm -guest unikernel]}
    tailcall ::thread::create_interp {*}$args
}
