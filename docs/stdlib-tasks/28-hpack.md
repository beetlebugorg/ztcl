# Task 28: HPACK

Platform: shared.

## Goal

HPACK of RFC 7541: the static table, the dynamic table with its limit, integers, strings, and the Huffman code.

## Files

- `src/h2/hpack.zig` (new).

## Test sources

- RFC 7541 appendix C. The `hpack-test-case` corpus (encode with ztcl, decode with each other stack in the corpus, and the reverse).

## Acceptance

```sh
CAP zig build test
CAP zig build hpack-test -- path/to/hpack-test-case
CAP zig build hpack-fuzz -- --seconds 600
```

Gates:

- Each example of appendix C matches byte for byte.
- Each story of the corpus decodes to its headers.
- A header block that decodes above the header list limit gives an error before the allocation.
