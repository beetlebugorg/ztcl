# References for the D-Bus client

[The task list](../dev/linux-tasks/README.md) of `ztcl::linux` uses these sources. ztcl has no code of any of them.

## The specification

freedesktop.org, "D-Bus Specification". https://dbus.freedesktop.org/doc/dbus-specification.html

**License:** the text of the specification. ztcl copies no text and no code from it.

**How ztcl uses it:** `src/dbus.zig` follows the sections "Type System" and "Marshaling (Wire Format)": the type codes, the rules of a valid signature, the alignment of each type from the start of the message, the length of an array without the padding before its first element, the dict entry, and the variant with its signature. The unit tests check byte strings that follow these rules.
