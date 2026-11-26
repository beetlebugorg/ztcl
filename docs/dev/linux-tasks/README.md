# Tasks for ztcl::linux

Issue #110 has the goal: `ztcl::linux::*`, calls to the desktop portals and a small D-Bus call API on Linux, with no window. ztk issue 53 is the parent. Do the tasks in the order of their numbers. One task is one branch and one review.

## The model

- The commands reach the host, so they are a capability: `linux`, off by default. The runner turns it on with `--allow linux`. A child interp gets it only from a parent that has it.
- The D-Bus client is new code in `src/dbus.zig`, on the Zig standard library only: the wire format of the D-Bus specification, a Unix socket to the session bus (`DBUS_SESSION_BUS_ADDRESS`, then `$XDG_RUNTIME_DIR/bus`), and the `EXTERNAL` authentication with the user id.
- A call waits for its reply with a time limit (5,000 ms by default, `-timeout MS`). A portal request waits for its `Response` signal with the same limit, so a call that the user leaves open stops with an error.
- On a platform other than Linux, each command gives the error `ztcl::linux is only on Linux`.
- The tests do not use the bus of the user. They start `dbus-daemon --session --print-address` in a temporary folder when the program is on the `PATH`, and skip otherwise. A unit test of the wire format runs everywhere.

## Commands

| Command | Result |
|---|---|
| `ztcl::linux::dbus call ?-system? ?-timeout MS? dest path interface method ?-signature SIG? ?arg ...?` | The reply as a Tcl list, with the D-Bus types in the rules of task 01. |
| `ztcl::linux::settings read namespace key` | The value from `org.freedesktop.portal.Settings.Read`, for example the color scheme. |
| `ztcl::linux::screenshot ?-interactive? ?-parent HANDLE?` | The path of the image from `org.freedesktop.portal.Screenshot`. ztk gives `-parent` for a portal dialog over a window. |

## Tasks

| Task | Result |
|---|---|
| 01 | `src/dbus.zig`: the marshaling and unmarshaling of the basic types, arrays, structs, dicts, and variants, with tests against byte strings from the specification. The type rules: integers and doubles map to Tcl numbers, a string to a string, an array to a list, a dict to a dict, and a variant to a list of its signature and its value. |
| 02 | The connection: the address, the authentication, `Hello`, and one method call with its reply. The capability `linux`, and a test that proves that it is absent by default. |
| 03 | `ztcl::linux::dbus call`, the time limit, and the error of a D-Bus error reply (`-errorcode {DBUS name}`). |
| 04 | The portal request: the `Request` object, its `Response` signal, `settings read`, and `screenshot`. |
| 05 | Docs: a page `docs/linux.md`, the capability in `docs/limits.md` and AGENTS.md rule 3, and the commands in `docs/language.md`. |

## Rules for each task

1. Read AGENTS.md, WRITING.md, and `docs/dev/design.md` first. Run each build and test under the memory cap.
2. Credit the D-Bus specification in `docs/references/`. Copy no code from libdbus, sd-bus, or another implementation.
3. A message from the bus is untrusted data. The parser checks each length and each alignment against the bytes that it has, and the memory limit counts each value that it makes.
4. A call uses one compute unit, and the wait for a reply uses no compute units.
