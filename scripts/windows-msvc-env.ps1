# Load the Visual C++ build environment into the current PowerShell session.
#
# Rust's MSVC target invokes link.exe, which is only on PATH inside a
# "Developer PowerShell" or after vcvars64.bat has run. Dot-source this file to
# get the same variables in an ordinary PowerShell session:
#
#   . .\scripts\windows-msvc-env.ps1
#   cargo check --manifest-path src-tauri/Cargo.toml
#
# Or use scripts/cargo.ps1, which loads the environment for one command.
#
# Launch-VsDevShell.ps1 is preferred because it sets the environment directly in
# PowerShell; replaying vcvars output through cmd.exe is fragile for
# installations under "Program Files (x86)" and for partially repaired
# installations.

[CmdletBinding()]
param(
    [ValidateSet("x64", "x86", "arm64")]
    [string]$Architecture = "x64"
)

$ErrorActionPreference = "Stop"

# rustup installs its shims in %USERPROFILE%\.cargo\bin but does not always add
# that directory to PATH. Put it back for this session so `cargo` resolves
# without the caller typing the absolute path. This must run before the
# early-return below: an already-loaded MSVC environment still needs cargo.
if (-not (Get-Command cargo.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    $cargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
    if (Test-Path -LiteralPath (Join-Path $cargoBin "cargo.exe")) {
        $env:PATH = "$cargoBin;$env:PATH"
    }
}

# Dot-sourcing this file more than once (or starting from a Developer
# PowerShell) must be cheap and must not keep growing LIB/INCLUDE.
$existingLink = Get-Command link.exe -CommandType Application -ErrorAction SilentlyContinue
if ($existingLink -and $env:LIB -and $env:INCLUDE) {
    Write-Verbose "Visual C++ environment already loaded: $($existingLink.Source)"
    return
}

$vswhereCandidates = @()
foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, "C:\Program Files (x86)", "C:\Program Files")) {
    if ($root) {
        $vswhereCandidates += Join-Path $root "Microsoft Visual Studio\Installer\vswhere.exe"
    }
}
$vswhereCandidates = $vswhereCandidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ }

$vswhere = $vswhereCandidates | Select-Object -First 1
if (-not $vswhere) {
    throw "vswhere.exe was not found. Install Visual Studio Build Tools with the 'Desktop development with C++' workload."
}

$installation = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath |
    Select-Object -First 1
if (-not $installation) {
    throw "Visual Studio with the 'Desktop development with C++' workload was not found."
}

$vsArch = switch ($Architecture) {
    "x64" { "amd64" }
    "x86" { "x86" }
    "arm64" { "arm64" }
}
$hostArch = "amd64"

$launch = Join-Path $installation "Common7\Tools\Launch-VsDevShell.ps1"
if (Test-Path -LiteralPath $launch) {
    & $launch -VsInstallationPath $installation -SkipAutomaticLocation `
        -Arch $vsArch -HostArch $hostArch -VsWherePath $vswhere | Out-Null
}

if (-not (Get-Command link.exe -ErrorAction SilentlyContinue)) {
    $vcvarsName = switch ($Architecture) {
        "x64" { "vcvars64.bat" }
        "x86" { "vcvars32.bat" }
        "arm64" { "vcvarsarm64.bat" }
    }

    $vcvars = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find "VC\Auxiliary\Build\$vcvarsName" |
        Select-Object -First 1

    if (-not $vcvars -or -not (Test-Path -LiteralPath $vcvars)) {
        throw "The Visual C++ toolchain ($vcvarsName) was not found. Add the 'Desktop development with C++' workload in the Visual Studio Installer."
    }

    # Replay vcvars' environment from a temporary batch file. Quoting a .bat
    # path is reliable; embedding the vcvars path in a cmd /c string is not.
    $batch = @"
@echo off
call "$vcvars" >nul 2>&1
if errorlevel 1 exit /b 1
set
"@
    $batchPath = Join-Path ([System.IO.Path]::GetTempPath()) ("kiri-vcvars-{0}.bat" -f [guid]::NewGuid().ToString("N"))
    Set-Content -LiteralPath $batchPath -Value $batch -Encoding Oem
    try {
        $environment = & cmd.exe /d /c "`"$batchPath`""
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to load the Visual C++ environment from $vcvars."
        }
    } finally {
        Remove-Item -LiteralPath $batchPath -ErrorAction SilentlyContinue
    }

    foreach ($line in $environment) {
        if ($line -match '^([^=]+)=(.*)$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
        }
    }
}

$link = Get-Command link.exe -ErrorAction SilentlyContinue
if (-not $link) {
    throw "link.exe is still unavailable after loading the Visual C++ environment."
}

# vcvars prepends its directories on every call. Keep the first occurrence of
# each entry so repeated loads leave LIB/INCLUDE stable instead of growing.
foreach ($name in "LIB", "INCLUDE") {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not $value) { continue }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $kept = foreach ($entry in ($value -split ";")) {
        if ($entry -and $seen.Add($entry)) { $entry }
    }
    [Environment]::SetEnvironmentVariable($name, ($kept -join ";"))
}

Write-Verbose "Loaded $Architecture MSVC environment from $installation"
Write-Verbose "link.exe: $($link.Source)"
