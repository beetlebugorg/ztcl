# Module web

The commands `web::` give a script in the browser the Web APIs of the page through one bridge. The bridge calls a member of an API only when the table of the Web IDL of the specs lists it, and it converts each value by the type in the table.

> [!NOTE]
> `web::` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

```tcl
set serial [web::root navigator.serial]
web::release $serial
```

```js
import { Interp } from "./ztcl.mjs";
import * as web from "./ztcl-web.mjs";
const tcl = await Interp.create("ztcl-host.wasm", { allow: ["web:serial"], web });
```

## Synopsis

```tcl
web::root name
web::get obj attr
web::set obj attr value
web::call obj method ?arg ...?
web::release obj
```

| Command | Result |
|---|---|
| `web::root name` | The handle of a root object, for example `navigator.serial`. |
| `web::get obj attr` | The value of an attribute. |
| `web::set obj attr value` | Sets an attribute and gives an empty string. |
| `web::call obj method ?arg ...?` | Calls a method and gives its value. |
| `web::release obj` | Ends the handle. |

An object of the page is a handle `webN`. The same object gives the same handle. A handle stays until `web::release` or the end of the interpreter.

## Values

| Web IDL type | Tcl value |
|---|---|
| `DOMString`, `USVString`, an enum | a string; an enum value must be one of the enum |
| `boolean` | 0 or 1 (an argument can be any Tcl boolean) |
| an integer type, `double` | a number; an integer argument must be in the range of its type |
| `sequence<T>` | a list |
| a dictionary | a dict of the members; a required member must be in the dict |
| an interface | a handle |
| `BufferSource`, `ArrayBuffer`, `Uint8Array` | a byte array: a string of the characters U+0000 to U+00FF |
| `undefined`, `null` | an empty string |

## Groups

Each interface of the table is in a group. The page grants a group with `allow`, for example `allow: ["web:serial"]`. A member of a group that the page did not grant gives the error `web: the group "serial" is not allowed`. The permission prompts and the user-gesture rules of the browser apply after the grant.

| Group | Roots | Interfaces |
|---|---|---|
| `serial` | `navigator.serial` | `Serial`, `SerialPort` |

## Errors

- A member out of the table: `web: the interface "Serial" has no method "eval"`.
- An error of the browser, such as a `DOMException`: `web: NotFoundError: No port selected by the user.`
- A method that gives a promise: `web: the method "getPorts" gives a promise: use -command`. A call into wasm cannot wait for a promise.
- An attribute of an event handler, such as `onconnect`, gives an error for `web::get` and `web::set`.

## Capability

The commands exist only in `ztcl-host.wasm`, and only with a group of `web:` in `allow`. `ztcl.wasm` has no bridge. The page imports the bridge `web/ztcl-web.mjs`, which imports the table `web/webidl-table.mjs`, and gives it as the option `web`. `ztcl.mjs` does not import the bridge, so a page without a grant loads neither file. Each command costs one compute unit. The option `webRoot` of `Interp.create` sets the global object of the paths of `web::root` (`globalThis` by default).
