# Module ztcl::win

`ztcl::win` has the commands of Windows that need no window. This version has `ztcl::win::registry`, the registry of Windows, `ztcl::win::credential`, the generic credentials of the Credential Manager, and `ztcl::win::folder`, the known folders. The commands exist only on Windows, and each needs a capability that the embedder grants.

> [!NOTE]
> `ztcl::win::registry` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

```tcl
set k HKEY_CURRENT_USER/Software/MyApp
ztcl::win::registry set $k width 800 dword
ztcl::win::registry get $k width            ;# 800
ztcl::win::registry type $k width           ;# dword
```

```sh
ztcl --allow registry --registry-allow HKCU/Software/MyApp app.tcl
```

## Capability and the allow list

The command needs the capability `registry` (`--allow registry` in the runner, `Capability.registry` for an embedder). It reaches only the keys of the allow list and the keys below them:

| Embedder | Runner |
|---|---|
| `Interp.registry_allow`: a list of keys | `--registry-allow KEY,KEY` |

An empty list reaches no key, also for reads, because a key can hold a secret. A key of the list allows itself and each key below it: `HKCU/Software/MyApp` allows `HKCU/Software/MyApp/Window` and refuses `HKCU/Software/MyAppX`. The check compares the long form of the root and the parts of the path, with no regard to case. A child interp has the list of its parent.

The command does not exist without the capability, and it does not exist on Linux, macOS, or WebAssembly, even with the capability.

## Keys and values

A key is a root and a path, with `/` or `\` between the parts. In Tcl, `/` needs no escape.

| Root | Short form |
|---|---|
| `HKEY_CLASSES_ROOT` | `HKCR` |
| `HKEY_CURRENT_USER` | `HKCU` |
| `HKEY_LOCAL_MACHINE` | `HKLM` |
| `HKEY_USERS` | `HKU` |
| `HKEY_CURRENT_CONFIG` | `HKCC` |

A value has a name in its key. The name `""` is the default value of the key. The types are those of the `registry` package of Tcl:

| Type | Tcl value |
|---|---|
| `sz` | a string |
| `expand_sz` | a string, with each `%NAME%` as it is |
| `dword` | an integer from 0 to 4294967295 |
| `qword` | an integer of 64 bits |
| `multi_sz` | a list of strings |
| `binary` | a byte string: each byte is the character of its code |

`get` of a value of another type (for example `dword_big_endian` or `link`) gives its bytes as a byte string, and `type` gives the name of the type, or `none`.

## Commands

### get

```tcl
ztcl::win::registry get KEY NAME
```

Gives the value `NAME` of `KEY`. An absent key or value is an error with the code `ZTCL REGISTRY NOENT`.

### set

```tcl
ztcl::win::registry set KEY ?NAME VALUE ?TYPE??
```

Makes the key when it is absent, with each key above it. With a name and a value, sets the value. The default type is `sz`. Gives an empty string.

### type

```tcl
ztcl::win::registry type KEY NAME
```

Gives the type of a value: `sz`, `expand_sz`, `binary`, `dword`, `dword_big_endian`, `link`, `multi_sz`, `resource_list`, `full_resource_descriptor`, `resource_requirements_list`, `qword`, or `none`.

### delete

```tcl
ztcl::win::registry delete KEY ?NAME?
```

With a name, deletes the value: an absent value is no error, and an absent key is `ZTCL REGISTRY NOENT`. With no name, deletes the key and each key and value below it, and an absent key is no error. A root key is never deleted.

### keys and values

```tcl
ztcl::win::registry keys KEY ?PATTERN?
ztcl::win::registry values KEY ?PATTERN?
```

Give the names of the keys right below `KEY`, or of its values, in the order of the registry. `PATTERN` is a pattern of `string match` with no regard to case.

## Examples

These run on Windows with `--allow registry --registry-allow HKCU/Software/ztcl-example`.

```tcl
set k HKCU/Software/ztcl-example
ztcl::win::registry set $k/Window width 800 dword
ztcl::win::registry set $k/Window title {My app}
ztcl::win::registry set $k/Window recent {a.txt b.txt} multi_sz
puts [ztcl::win::registry get $k/Window width]                ;# 800
puts [lsort [ztcl::win::registry values $k/Window]]           ;# recent title width
puts [ztcl::win::registry keys $k]                            ;# Window
puts [lindex [ztcl::win::registry get $k/Window recent] 1]    ;# b.txt
ztcl::win::registry delete $k
```

Settings that keep their defaults when the key is absent:

```tcl
proc setting {name default} {
    set k HKCU/Software/ztcl-example
    if {[catch {ztcl::win::registry get $k $name} v]} { return $default }
    return $v
}
puts [setting width 640]    ;# 640 until a set
```

A key outside the list:

```tcl
catch {ztcl::win::registry get HKCU/Software/Microsoft x} msg opts
puts $msg                          ;# the embedder did not allow the key "HKCU/Software/Microsoft"
puts [dict get $opts -errorcode]   ;# ZTCL REGISTRY DENIED
```

## Errors

| Error text | `-errorcode` |
|---|---|
| `bad key "KEY": the root must be HKEY_CLASSES_ROOT, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, HKEY_USERS, or HKEY_CURRENT_CONFIG` | `ZTCL REGISTRY KEY` |
| `the embedder did not allow the key "KEY"` | `ZTCL REGISTRY DENIED` |
| `ztcl::win::registry does not delete a root key` | `ZTCL REGISTRY DENIED` |
| `could not open the key "KEY": no such key or value` | `ZTCL REGISTRY NOENT` |
| `could not read the value of "KEY": no such key or value` | `ZTCL REGISTRY NOENT` |
| `could not open the key "KEY": permission denied` (and the other actions) | `ZTCL REGISTRY ACCES` |
| `could not make the key "KEY": error N` (another code of Windows) | `ZTCL REGISTRY ERROR` |
| `bad type "T": must be binary, dword, expand_sz, multi_sz, qword, or sz` | `NONE` |
| `expected a dword from 0 to 4294967295 but got "N"` | `NONE` |
| `a byte string has characters below 256 only` | `NONE` |
| `bad option "X": must be delete, get, keys, set, type, or values` | `NONE` |
| `wrong # args: should be "ztcl::win::registry get key name"` (and the other forms) | `TCL WRONGARGS` |

## Cost

Each command is one compute unit, like a core command. `keys` and `values` read each name of the key in that unit.

## Security

- The registry holds the settings of the user and of the system. A key such as `HKCU/Software/Microsoft/Windows/CurrentVersion/Run` starts a program at the next login, so a key of the allow list gives a script that power over its part of the registry. List only the keys of your app.
- Without the allow list the command reaches no key. There is no form that allows the whole registry.
- `HKEY_LOCAL_MACHINE` and the keys of other users need the rights of an administrator, and Windows refuses them for a normal user with `ZTCL REGISTRY ACCES`.
- `delete` of a key removes each key below it, with no undo.

## credential

```tcl
ztcl::win::credential get SERVICE ACCOUNT
ztcl::win::credential set SERVICE ACCOUNT SECRET
ztcl::win::credential delete SERVICE ACCOUNT
```

```sh
ztcl --allow credential --credential-allow org.example.notes notes.tcl
```

The peer of `ztcl::mac::keychain` (capability `credential`, list `Interp.credential_allow` or `--credential-allow S,S`). An item is a generic credential of the user (`CRED_TYPE_GENERIC`) with the target name `SERVICE/ACCOUNT` and the user name `ACCOUNT`, kept on this computer (`CRED_PERSIST_LOCAL_MACHINE`). The Credential Manager of the control panel shows it under "Windows Credentials".

- `get` gives the secret, and a missing item gives `ZTCL WIN NOTFOUND`.
- `set` stores the UTF-8 of `SECRET`, at most 2,560 bytes, and replaces an item that exists. It gives an empty string.
- `delete` removes the item and gives an empty string. A missing item is no error.
- A service is a name with no `/`. A service outside the list gives `ZTCL WIN DENIED`, a longer secret `ZTCL WIN LENGTH`, and an error of the store `ZTCL WIN CREDENTIAL code`. On another platform the command checks its arguments and its list, then gives `ZTCL WIN UNAVAILABLE`.

## folder

```tcl
ztcl::win::folder documents   ;# C:/Users/me/Documents
```

`ztcl::win::folder NAME` (capability `env`) gives the path of a known folder from `SHGetKnownFolderPath`, with `/` between the parts, so a folder that the user moved gives its new place. The names are `appdata` (the roaming one), `desktop`, `documents`, `downloads`, `localappdata`, `music`, `pictures`, `profile`, `programdata`, `programfiles`, and `videos`. The command reads the path and makes no change. A folder that this user lacks gives `ZTCL WIN FOLDER`. On another platform the command gives `ZTCL WIN UNAVAILABLE`.
