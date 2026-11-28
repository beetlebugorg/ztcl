# Install

The latest release is on the [releases page](https://github.com/beetlebugorg/ztcl/releases). Some features of these docs are on `main` only: the interactive shell, `ztcl::json`, the JIT on x86-64 Windows and arm64 Linux, the JIT on by default, threads in WebAssembly, `ztcl::vm`, isolated threads, `ztcl::tls`, Tcl 9.1, `ztcl debug`, and libztcl. [Build from source](#build-from-source) to get them now. The [changelog](../CHANGELOG.md) lists them under "Unreleased".

[Targets](targets.md) lists the platforms of ztcl and the features of each.

## Homebrew

```sh
brew install beetlebugorg/tap/ztcl
ztcl --compute 1000000 script.tcl
```

The formula works on macOS and Linux.

## Arch Linux

`packaging/arch/ztcl-git` has a PKGBUILD. It builds `main` with the `zig` package of Arch (0.17), runs a short check, and installs `/usr/bin/ztcl`.

```sh
git clone https://github.com/beetlebugorg/ztcl
cd ztcl/packaging/arch/ztcl-git && makepkg -si
```

The package is not on the AUR yet ([#169](https://github.com/beetlebugorg/ztcl/issues/169)).

## Release binaries

Each release has an archive for Linux (x86-64 and arm64, static with musl), macOS (x86-64 and arm64), and Windows (x86-64), and a WebAssembly archive. `SHA256SUMS` has the checksum of each file.

```sh
curl -LO https://github.com/beetlebugorg/ztcl/releases/download/v1.0.0-beta.1/ztcl-1.0.0-beta.1-x86_64-linux-musl.tar.gz
tar xzf ztcl-1.0.0-beta.1-x86_64-linux-musl.tar.gz
./ztcl-1.0.0-beta.1-x86_64-linux-musl/ztcl script.tcl
```

## npm

The package [`@beetlebug/ztcl`](https://www.npmjs.com/package/@beetlebug/ztcl) has the WebAssembly build, the JS module, the worker, and the TypeScript types. It works with a bundler, in Node.js 22.3 or later, and from a CDN with no build step.

```sh
npm install @beetlebug/ztcl
```

```js
import { Interp } from "@beetlebug/ztcl";

const tcl = await Interp.create({ computeLimit: 1_000_000, memLimit: 64 << 20 });
console.log(tcl.eval("expr {6 * 7}").result); // 42
```

[WebAssembly](webassembly.md) has the API.

## Build from source

Install [Zig 0.17.0](https://ziglang.org/download/). The build needs no other tool and no C library.

```sh
git clone https://github.com/beetlebugorg/ztcl
cd ztcl
zig build -Doptimize=ReleaseFast        # makes zig-out/bin/ztcl
zig build test                          # runs the unit tests
zig build wasm                          # makes zig-out/lib/ztcl.wasm
```

Add `-Dtarget=aarch64-macos`, `-Dtarget=x86_64-windows`, or another target to cross-compile.

## Use as a Zig package

```sh
zig fetch --save git+https://github.com/beetlebugorg/ztcl
```

[Embed in Zig](embedding.md) has the `build.zig` lines and the API.
