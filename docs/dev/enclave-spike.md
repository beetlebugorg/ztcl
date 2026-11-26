# The spike of the VBS enclave (ztcl#180)

The results of the spike of [enclave.md](enclave.md), on the Windows test machine of the project: Windows 11 Home 25H2, build 26200, with VBS and memory integrity on, Secure Boot off, and test signing off.

## Build

`pwsh enclave/windows/build.ps1` builds two files into `zig-out/enclave`:

- `ztcl-enclave.dll`, the enclave image (1,159,680 bytes). `zig build enclave-core` builds the interpreter with no capability for the target `x86_64-uefi`, a static library of COFF objects with compiler-rt and no import. The target `x86_64-freestanding` gives an ELF object, which `link.exe` refuses. `link.exe` of MSVC 14.44 links that library with `enclave/windows/shim.c`, the enclave CRT, `vertdll.lib`, `bcrypt.lib`, and `ucrt.lib` of `ucrt_enclave`, and `veiid.exe` binds the imports.
- `ztcl-enclave-host.exe`, the host test (`enclave/windows/host.c`).

The image imports only `vertdll.dll` and `ucrtbase_enclave.dll`. Its load configuration has the enclave configuration: the policy `IMAGE_ENCLAVE_POLICY_STRICT_MEMORY` (2), an enclave size of 256 MiB, the flag `IMAGE_ENCLAVE_FLAG_PRIMARY_IMAGE`, and two enclave import descriptors from `veiid.exe`.

## Run with no signature

| Step | Result |
|---|---|
| `IsEnclaveTypeSupported(ENCLAVE_TYPE_VBS)` | 1 |
| `CreateEnclave` (256 MiB, `ENCLAVE_TYPE_VBS`, flags 0) | ok |
| `LoadEnclaveImageW(L"ztcl-enclave.dll")` | error 577, `ERROR_INVALID_IMAGE_HASH`: "Windows cannot verify the digital signature for this file." |

So Windows 11 Home makes VBS enclaves, and the next step needs a signed image.

## Run with a self-signed signature

The user said yes to the certificate and to test signing (2026-11-26). The certificate, `CN=ztcl enclave development`, is in the store `Cert:\CurrentUser\My`, with the EKUs `1.3.6.1.5.5.7.3.3` (code signing), `1.3.6.1.4.1.311.76.57.1.15` (enclave), and `1.3.6.1.4.1.311.97.4120.180.209.2026` (author). It signs the image:

```
signtool sign /ph /fd SHA256 /sha1 <thumbprint> ztcl-enclave.dll
```

`signtool` signs it, with the warning "VBS enclave support is changing and updating your VBS enclave may cause you to lose support on older OSes" and a link to the page of Microsoft on the change.

| Step | Test signing off |
|---|---|
| `CreateEnclave` | ok |
| `LoadEnclaveImageW` | error 577, `ERROR_INVALID_IMAGE_HASH`, as with no signature |

So a self-signed enclave needs test signing, as the guide of Microsoft says.

## Next

1. Test signing on: `bcdedit /set testsigning on` in a prompt of an administrator, then a restart. The session of the spike has no administrator rights, so the user runs it. Then record the output `42`, the sizes of the sealed blob and the report, the unsealed output, and the result of `EnclaveVerifyAttestationReport`.
2. Test signing off again after the spike (`bcdedit /set testsigning off` and a restart), and the certificate out of the store.
