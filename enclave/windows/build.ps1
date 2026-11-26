# Builds ztcl-enclave.dll and ztcl-enclave-host.exe into zig-out/enclave
# (ztcl#180). The DLL is not signed: see docs/dev/enclave.md, "Signing".
#
# Usage: pwsh enclave/windows/build.ps1 [-Zig zig] [-Debug]
#
# SPDX-License-Identifier: BSD-2-Clause

param(
    [string]$Zig = "zig",
    [switch]$Debug
)
$ErrorActionPreference = "Stop"

$root = Resolve-Path "$PSScriptRoot/../.."
$out = Join-Path $root "zig-out/enclave"
New-Item -ItemType Directory -Force $out | Out-Null

# The tools: the newest MSVC with the enclave CRT and the newest SDK.
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$msvc = $null
foreach ($vs in & $vswhere -products * -property installationPath) {
    foreach ($v in Get-ChildItem "$vs/VC/Tools/MSVC" -Directory | Sort-Object Name -Descending) {
        if (Test-Path "$($v.FullName)/lib/x64/enclave/libcmt.lib") { $msvc = $v.FullName; break }
    }
    if ($msvc) { break }
}
if (-not $msvc) { throw "no MSVC with the enclave CRT (lib/x64/enclave)" }
$kits = "${env:ProgramFiles(x86)}/Windows Kits/10"
$sdk = (Get-ChildItem "$kits/Lib" -Directory | Where-Object { Test-Path "$($_.FullName)/ucrt_enclave/x64/ucrt.lib" } | Sort-Object Name -Descending | Select-Object -First 1).Name
if (-not $sdk) { throw "no Windows SDK with ucrt_enclave" }
$bin = "$msvc/bin/Hostx64/x64"
$inc = @("$msvc/include", "$kits/Include/$sdk/um", "$kits/Include/$sdk/shared", "$kits/Include/$sdk/ucrt") | ForEach-Object { "/I$_" }
$um = "$kits/Lib/$sdk/um/x64"
Write-Host "MSVC $msvc"
Write-Host "SDK $sdk"

# The core of ztcl: zig-out/lib/ztcl-enclave-core.lib.
Push-Location $root
& $Zig build enclave-core
if ($LASTEXITCODE -ne 0) { throw "zig build enclave-core" }
Pop-Location

Push-Location $out
try {
    $def = @()
    if ($Debug) { $def = @("/DZTCL_ENCLAVE_DEBUG") }
    & "$bin/cl.exe" /nologo /c /O2 /W4 /GS /guard:cf /Gy /Zi @inc @def "$PSScriptRoot/shim.c" /Fo"shim.obj"
    if ($LASTEXITCODE -ne 0) { throw "cl shim.c" }
    & "$bin/link.exe" /nologo /DLL /ENCLAVE /INCREMENTAL:NO /INTEGRITYCHECK /GUARD:MIXED /NODEFAULTLIB /DEBUG `
        /DEF:"$PSScriptRoot/ztcl-enclave.def" /OUT:ztcl-enclave.dll `
        shim.obj "$root/zig-out/lib/ztcl-enclave-core.lib" `
        "$msvc/lib/x64/enclave/libcmt.lib" "$msvc/lib/x64/enclave/libvcruntime.lib" `
        "$um/vertdll.lib" "$um/bcrypt.lib" "$kits/Lib/$sdk/ucrt_enclave/x64/ucrt.lib"
    if ($LASTEXITCODE -ne 0) { throw "link ztcl-enclave.dll" }
    # veiid binds the import ids of the enclave image.
    & "$kits/bin/$sdk/x64/veiid.exe" ztcl-enclave.dll
    if ($LASTEXITCODE -ne 0) { throw "veiid ztcl-enclave.dll" }

    & "$bin/cl.exe" /nologo /O2 /W4 @inc "$PSScriptRoot/host.c" /Fe"ztcl-enclave-host.exe" `
        /link /LIBPATH:"$msvc/lib/x64" /LIBPATH:"$um" /LIBPATH:"$kits/Lib/$sdk/ucrt/x64" onecore.lib
    if ($LASTEXITCODE -ne 0) { throw "cl host.c" }
}
finally {
    Pop-Location
}
Write-Host "built $out/ztcl-enclave.dll and $out/ztcl-enclave-host.exe"
