param([string]$Path = ".cursor\review-pin-extra.ps1")
$tokens = $null
$errors = $null
$resolved = (Resolve-Path $Path).Path
[void][System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors)
if ($errors.Count -eq 0) { Write-Host "PARSE_OK"; exit 0 }
foreach ($error in $errors) {
  Write-Host ("{0}:{1} {2}" -f $error.Extent.StartLineNumber, $error.Extent.StartColumnNumber, $error.Message)
}
exit 1
