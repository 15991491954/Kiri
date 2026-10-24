# Diagnostic: start the debug app with CDP, open the capture overlay, dump its DOM.
$ErrorActionPreference = "Stop"
$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9333"
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 5
  Write-Output "=== targets before capture ==="
  node (Join-Path $PSScriptRoot "cdp-dump.mjs") 9333 2>&1 | Out-String
  $created = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
  if ($created) { $null = $created.WaitForExit(10000) }
  Start-Sleep -Seconds 2
  Write-Output "=== targets after capture ==="
  node (Join-Path $PSScriptRoot "cdp-dump.mjs") 9333 2>&1 | Out-String
  Start-Sleep -Seconds 3
  Write-Output "=== overlay dump after 3s ==="
  node (Join-Path $PSScriptRoot "cdp-dump.mjs") 9333 2>&1 | Out-String
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
}
