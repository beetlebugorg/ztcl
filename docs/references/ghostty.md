# References for `ztcl::vt`

## libghostty-vt

The terminal library of Ghostty, tag `vt-1.0.2` of https://github.com/ghostty-org/ghostty (commit `573c4a21e02311ae87844af26b6a7a179f82858e`). The user approved it as a dependency on 2026-11-26.

**License:** MIT, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. The text is in `licenses/ghostty-MIT.txt`.

**How ztcl uses it:** `build.zig.zon` pins the source archive of the tag, and the Zig build compiles the Zig module `ghostty-vt` from source into each program, with `-Dsimd=false` and the feature `kitty_graphics` off. With these options the module has no C code, no C++ code, and no libc. The build makes no shared library. `src/vt.zig` calls `Terminal`, its stream, `PageList`, and `RenderState`. ztcl copies no code from Ghostty.

## uucode

The Unicode tables of libghostty-vt, version 0.2.0 by Jacob Sandlund. https://github.com/jacobsandlund/uucode

**License:** MIT. The text is in `licenses/uucode-MIT.txt`. That file names two more license files, for the Unicode data and for the UTF-8 decoder of Bjoern Hoehrmann. The package archive that the build fetches has no copy of them.

**How ztcl uses it:** libghostty-vt imports it for the width and the grapheme breaks of code points.
