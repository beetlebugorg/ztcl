# Module ztcl::mac

`ztcl::mac` has the direct APIs of macOS that need no window. Each command has its own capability and its own allow list, so an embedder gives a script only the parts and the names that it needs.

| Command | Capability | Allow list | Reaches |
|---|---|---|---|
| `ztcl::mac::keychain` | `keychain` | `Interp.keychain_allow`, runner flag `--keychain-allow S,S` | the generic passwords of the login keychain of the services of the list |
| `ztcl::mac::defaults` | `defaults` | `Interp.defaults_allow`, runner flag `--defaults-allow D,D` | the string values of the user defaults of the domains of the list |

A command is absent without its capability. A child interp gets the capability and the list of its parent. An empty list reaches no name. A name of a list matches only the same name, with the same case.

```sh
ztcl --allow keychain,defaults --keychain-allow org.example.notes --defaults-allow org.example.notes notes.tcl
```

The commands load CoreFoundation and Security with `dlopen` at the first call, so a build of ztcl for macOS needs no SDK. On another platform each command checks its arguments and its list, then gives `ZTCL MAC UNAVAILABLE`.

## keychain

```tcl
ztcl::mac::keychain get SERVICE ACCOUNT
ztcl::mac::keychain set SERVICE ACCOUNT SECRET
ztcl::mac::keychain delete SERVICE ACCOUNT
```

An item is a generic password (`kSecClassGenericPassword`) of the login keychain, with the attributes `kSecAttrService` and `kSecAttrAccount`.

- `get` gives the secret of the item. The secret is the stored bytes as a string, so a secret that `set` stored gives back its text.
- `set` stores the UTF-8 of `SECRET`: it updates the item when it exists, and adds it otherwise. It gives an empty string.
- `delete` removes the item and gives an empty string. A missing item is no error.

```tcl
ztcl::mac::keychain set org.example.notes alice "correct horse battery staple"
set token [ztcl::mac::keychain get org.example.notes alice]
ztcl::mac::keychain delete org.example.notes alice
```

macOS ties each item to the code signature of the program that made it. A read by another program, or by a new build with another signature, can show a dialog of the system that asks the user to allow it. The command waits for the answer.

## defaults

```tcl
ztcl::mac::defaults get DOMAIN KEY
ztcl::mac::defaults set DOMAIN KEY VALUE
ztcl::mac::defaults delete DOMAIN KEY
```

The commands use `CFPreferencesCopyAppValue`, `CFPreferencesSetAppValue`, and `CFPreferencesAppSynchronize` with the domain as the application id, so they read and write what `defaults read DOMAIN KEY` shows.

- `get` gives the string value of the key, or an empty string when the key has no value or a value of another type.
- `set` writes a string value and gives an empty string.
- `delete` removes the key and gives an empty string.

```tcl
ztcl::mac::defaults set org.example.notes theme dark
puts [ztcl::mac::defaults get org.example.notes theme]   ;# dark
ztcl::mac::defaults delete org.example.notes theme
```

## Errors

| `-errorcode` | Message |
|---|---|
| `TCL WRONGARGS` | `wrong # args: should be "ztcl::mac::keychain get\|set\|delete service account ?secret?"`, and the same for `defaults` with `domain key ?value?` |
| `NONE` | `bad option "read": must be delete, get, or set` |
| `ZTCL MAC DENIED` | `the keychain service "org.example.other" is not in the allow list` |
| `ZTCL MAC DENIED` | `the defaults domain "org.example.other" is not in the allow list` |
| `ZTCL MAC NOTFOUND` | `no keychain item for "org.example.notes" and "bob"`: a `get` of a missing item |
| `ZTCL MAC KEYCHAIN N` | `the keychain gave the error N`, with the `OSStatus` of Security, such as -25293 for an authorization failure, or -128 when the user cancels the dialog |
| `ZTCL MAC DEFAULTS` | `could not write the defaults of "org.example.notes"` |
| `ZTCL MAC LOAD` | `could not load the Security framework`, or `could not load CoreFoundation` |
| `ZTCL MAC UNAVAILABLE` | `ztcl::mac::keychain is only on macOS`, and the same for `defaults` |

```tcl
if {[catch {ztcl::mac::keychain get org.example.notes alice} secret]} {
    if {[lindex $::errorCode 2] eq "NOTFOUND"} { set secret "" } else { error $secret }
}
```

## Security

- `keychain` gives a script the secrets of the services of its list: give it only the names of your own app, and never a list of names that a script chooses.
- A secret is a Tcl string in the interp. It stays in memory until the interp frees the value, and a script can print it or send it.
- The keychain of a desktop can show a dialog of the system for a read. A test that calls the keychain runs only where no user is at the screen: the tests of ztcl call the system only with `ZTCL_TEST_MAC=1`, which CI sets.
- `defaults` writes the preference files of the user, which other programs read. List only the domains of your app.
