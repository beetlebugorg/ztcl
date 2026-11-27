//! The library packages of Tcl that ztcl has as embedded Tcl scripts,
//! such as `http`.
//!
//! Each entry is a name, a version, and the text of a script that
//! defines the commands and provides the package. `package require`
//! looks in this table when no `package ifneeded` script of the name
//! fits: it adds an `ifneeded` script for each version of the table
//! that has none yet, and then picks a version as it does for any
//! `ifneeded` script. So `package versions` and `package ifneeded`
//! show the versions after the first `require`, and a script of the
//! user for the same version stays in place. The table needs the full
//! `package` command (capability `package`). The scripts are text in
//! the binary, and no file is read.
//!
//! SPDX-License-Identifier: BSD-2-Clause

pub const Lib = struct {
    name: []const u8,
    version: []const u8,
    script: []const u8,
};

pub const table = [_]Lib{
    .{ .name = "http", .version = "2.9.8", .script = @embedFile("lib/http.tcl") },
    .{ .name = "http", .version = "1.0", .script = @embedFile("lib/http1.tcl") },
};
