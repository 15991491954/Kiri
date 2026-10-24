$ErrorActionPreference = "Stop"
$errors = $null
$tokens = $null
$target = Join-Path $PSScriptRoot "pin-shot-e2e.ps1"
[void][System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
if ($errors.Count -eq 0) {
  "PARSE_OK"
} else {
  foreach ($error in $errors) {
    "{0}:{1} {2}" -f $error.Extent.StartLineNumber, $error.Extent.StartColumnNumber, $error.Message
  }
  exit 1
}
