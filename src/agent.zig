//! The module `ztcl::agent` (ztcl#216): an LLM agent loop in an isolated
//! thread. The module is Tcl code (`agent.tcl`): the host drives the loop
//! and asks a thread with no capability for each next step, and the
//! thread builds the requests and reads the replies. The host posts each
//! request to its one endpoint with its own headers, so the key never
//! reaches the thread. `docs/dev/agent-sandbox.md` has the design and
//! the threat model.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const mods = @import("modules.zig");
const interp = @import("interp.zig");

pub const modules: []const mods.Module = &.{.{
    .name = "ztcl::agent",
    .version = "0.1",
    .needs = @backingInt(interp.Capability.thread),
    .script = @embedFile("agent.tcl"),
}};
