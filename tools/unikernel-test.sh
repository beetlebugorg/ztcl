#!/bin/sh
# Runs the thread tests with each thread in the ztcl unikernel
# (thread::create -isolation vm, ztcl#471): the files that need no
# channels, sockets, or processes. Build first with `zig build` and
# `zig build unikernel`. It skips with the reason when the host has no
# access to /dev/kvm or /dev/vhost-vsock.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for d in /dev/kvm /dev/vhost-vsock; do
    if [ ! -r $d ] || [ ! -w $d ]; then
        echo "skip: no read and write access to $d"
        exit 0
    fi
done
if [ ! -x "$here/../zig-out/bin/ztcl-unikernel" ]; then
    echo "no zig-out/bin/ztcl-unikernel: run zig build unikernel" >&2
    exit 1
fi
exec "$here/thread-tests.sh" -x "--allow vm" -p prelude/vm.tcl commands.tcl steps.tcl sync.tcl tsv.tcl owned.tcl tpool.tcl
