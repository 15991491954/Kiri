# Run cargo with the Visual C++ environment loaded for this process only.
#
#   .\scripts\cargo.ps1 check --manifest-path src-tauri/Cargo.toml
#   .\scripts\cargo.ps1 test --manifest-path src-tauri/Cargo.toml -- --nocapture
#
# For an interactive session that keeps the environment between commands,
# dot-source scripts/windows-msvc-env.ps1 instead.
#
# Arguments are passed through unchanged ($args), so cargo switches such as
# --manifest-path and `--` filters are not parsed as PowerShell parameters.

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "windows-msvc-env.ps1")

# Cargo writes warnings to stderr. With $ErrorActionPreference = "Stop",
# Windows PowerShell turns the first one into a terminating NativeCommandError
# and kills the build, so switch back to Continue for the cargo process only.
$ErrorActionPreference = "Continue"

& cargo @args
exit $LASTEXITCODE
