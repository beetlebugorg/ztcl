# Task 01: Eisel-Lemire on the parsed mantissa

## Goal

Canada spends 33 % of a parse in `std.fmt.parseFloat`. The parser has the mantissa and the exponent already, and `parseFloat` reads the text again. Run the Eisel-Lemire step directly on the mantissa.

## Files

- `src/json/number.zig` (new): the table of the powers of five, made at compile time, and `eiselLemire(mantissa, exp10, negative) ?f64`.
- `src/json/build.zig`: the number path calls it before `parseFloat`.
- `docs/references/stdlib.md`: the paper of Lemire and the method of the table.

## Rules

- Only a mantissa of 19 digits or fewer with no lost digit uses the new path. A null result goes to `parseFloat`.
- Each result is bit-identical to `parseFloat` of the text.

## Acceptance

- A unit test compares random decimal numbers and the exponent edges with `parseFloat`, bit for bit.
- canada: at least 25 % fewer instructions for one parse.
