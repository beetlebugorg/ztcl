# libztcl: ztcl as libtcl8.6

libztcl is a shared library with the C API of Tcl 8.6. A program or an extension that you build for Tcl 8.6 builds against libztcl and runs its Tcl on ztcl. A program that already links libtcl8.6 also runs on libztcl with no new build.

libztcl is experimental. It does not have each function of Tcl 8.6 yet. A call of a missing function writes the name of the function to the standard error and stops the program. [What is different](#what-is-different) has the list.

## Compile against ztcl

```sh
zig build libztcl -Doptimize=ReleaseFast --prefix "$HOME/ztcl"
export PKG_CONFIG_PATH="$HOME/ztcl/lib/pkgconfig"
cc app.c $(pkg-config --cflags --libs tcl) -Wl,-rpath,"$HOME/ztcl/lib"
```

The release archives `libztcl-VERSION-TARGET.tar.gz` have the same files. Extract an archive and use its folder as the prefix.

## The development kit

`zig build libztcl --prefix PREFIX` installs these files:

| File | What it is |
|---|---|
| `lib/libtcl8.6.so` (Linux), `lib/libtcl8.6.dylib` (macOS) | The library. The SONAME is `libtcl8.6.so`. The install name is `@rpath/libtcl8.6.dylib`. |
| `lib/libtclstub8.6.a` | The stub library for extensions built with `-DUSE_TCL_STUBS`. |
| `include/tcl8.6/` and `include/` | The public headers of Tcl 8.6.16: `tcl.h`, `tclDecls.h`, `tclPlatDecls.h`, `tclTomMath.h`, and `tclTomMathDecls.h`. Some systems put them in `include/tcl8.6` and others in `include`, so the kit has them in both. |
| `lib/tclConfig.sh` | The variables of Tcl for TEA: `configure --with-tcl=PREFIX/lib`. |
| `lib/pkgconfig/tcl.pc`, `lib/pkgconfig/ztcl.pc` | The files of `pkg-config`. The two give the same flags. |
| `share/doc/libztcl/tcl-license.txt` | The license of the headers. |

The headers are the files of Tcl 8.6.16 with no change. They have the license of Tcl (BSD style). The other files of the kit are new code of ztcl.

The `.pc` files find the prefix from their own folder, so you can move the kit. `tclConfig.sh` uses the folder in `TCL_BIN_DIR` when it is set, as TEA sets it. Else it uses the prefix of `-Dkit-prefix` (default `/usr/local`).

## Embed Tcl in a program

Use the API of Tcl 8.6 and link `-ltcl8.6`:

```c
#include <tcl.h>

int main(int argc, char **argv) {
    Tcl_FindExecutable(argv[0]);
    Tcl_Interp *interp = Tcl_CreateInterp();
    Tcl_Init(interp);
    int code = Tcl_Eval(interp, "puts [expr {6 * 7}]");
    Tcl_DeleteInterp(interp);
    return code;
}
```

An interp of `Tcl_CreateInterp` has the full power of the user, as in Tcl: files, `exec`, sockets, and the environment. It has no memory limit and no compute limit.

To run a program that links libtcl8.6 on libztcl, set the library path:

```sh
LD_LIBRARY_PATH="$HOME/ztcl/lib" /usr/bin/tclsh8.6 script.tcl
```

## Build an extension

A stubs extension links `libtclstub8.6.a` and calls `Tcl_InitStubs` in its init function:

```sh
cc -shared -fPIC -DUSE_TCL_STUBS -I"$HOME/ztcl/include/tcl8.6" ext.c -o ext.so -L"$HOME/ztcl/lib" -ltclstub8.6
```

A TEA extension reads `lib/tclConfig.sh`: give `./configure --with-tcl="$HOME/ztcl/lib"`. The test `tools/libztcl/kit.sh` builds an extension with the variables of that file, as TEA does. The extension loads with `load` in a program on libztcl, in the `ztcl` runner (with the capability `cext`), and in the tclsh of Tcl 8.6. The stub library of the kit works with the libtcl8.6 of Tcl too.

## What is different

The headers of Tcl describe the ABI of libztcl, with these differences:

- The fields `result` and `freeProc` of `Tcl_Interp` are legacy fields. libztcl sets `result` to an empty string. Use `Tcl_GetStringResult`.
- The bignum functions of `tclTomMath.h` (`TclBN_*`) are not in libztcl yet, and `Tcl_TomMath_InitStubs` gives an error.
- The functions of TclOO (`tclOO.h`) and the private headers (`tclInt.h`, `tclPort.h`) are not in the kit.
- `Tcl_Mutex`, `Tcl_Condition`, and the thread data of Tcl for servers are not complete yet.
- There is no Windows build yet, and no arm64 Linux build: Zig 0.17 has no `VaList` with LLVM on those targets.

[docs/dev/libztcl.md](dev/libztcl.md) has the internals, the list of missing functions, and the programs that were tested.
