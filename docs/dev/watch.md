# Plan: a file watcher for scripts (`ztcl::watch`)

A script with the `file` capability asks for the changes below a folder of its root. dockyard uses it to load the files of a project again when the agent program writes them (step 2 of the dockyard spec).

## Commands

```tcl
set w [ztcl::watch add ?-recursive? path]
ztcl::watch changes $w      ;# {{modified /src/app.tcl} {created /src/new.tcl} ...}
ztcl::watch remove $w
ztcl::watch fd $w           ;# for an embedder loop: a descriptor that is readable when changes wait
```

- `path` is a path of the script below the root folder, as for `file`. A path outside the root is an error.
- `changes` does not block. It gives the changes since the last call as a list of pairs: the kind (`created`, `modified`, `deleted`, or `moved`) and the path of the script. Two changes of one file in one call give one pair.
- `-recursive` watches each folder below `path`, and the folders that appear later.
- A watcher keeps at most 4,096 changes. More changes give one pair `{overflow /}`, and the script reads the folder again.
- A child interp gets the command only with `file`. The command is absent without `file`, and a test proves it.

## Platforms

| Platform | Form | First PR |
|---|---|---|
| Linux | inotify with `IN_CLOEXEC` and `IN_NONBLOCK`, one watch for each folder, the root folder descriptor for the path check | Done (step 2) |
| macOS | kqueue with `EVFILT_VNODE` on each folder and file, or FSEvents through the CoreServices framework | Error "ztcl::watch is not available on macOS yet" |
| Windows | `ReadDirectoryChangesW` with an overlapped read on the folder handle and a completion port, the subtree for `-recursive` (`src/watch_windows.zig`) | Done (ztcl#255) |
| WASI, the web | No watch API | The command is absent |

## Event loop

`changes` works with no event loop: an embedder such as ztk calls it from a timer. `fd` gives the inotify descriptor, so a loop that waits on descriptors can wait for it. A `fileevent` form comes with the channel form in a later step.

## Steps

1. This plan.
2. Linux: `src/watch.zig`, a register hook next to `filecmd.register`, the tests (create, modify, delete, move, recursive, overflow, outside the root, absent without `file`), and a section in `docs/embedding.md`.
3. macOS and Windows.
