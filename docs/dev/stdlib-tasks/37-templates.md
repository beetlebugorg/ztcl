# Task 37: Templates that escape by default

Platform: shared.

## Goal

`ztcl::tmpl` of the design.

## Files

- `src/tmpl.zig` (new).

## Test sources

- The OWASP rules for HTML escapes in each context. A list of escape cases (attributes, URLs with `javascript:`, script text).

## Acceptance

```sh
CAP zig-out/bin/ztcl tests/stdlib/tmpl.test
```

Gates:

- Each case of the list gives escaped output.
- A template compiles once: the second render of a template uses no parse, as a step count shows.
- Size: the `tmpl` row of the design.
