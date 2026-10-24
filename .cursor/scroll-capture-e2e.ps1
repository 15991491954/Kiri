# Verifies that scrolling capture starts on Windows: the control windows must
# receive EXCLUDEFROMCAPTURE (the previous build failed with error 8).
$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ScrollNative {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
"@
$results = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = "") {
  [void]$results.Add([pscustomobject]@{ Test = $name; Pass = $ok; Detail = $detail })
  Write-Host ("[{0}] {1} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $detail)
}
function Targets {
  try { return @(Invoke-RestMethod "http://127.0.0.1:9335/json" -TimeoutSec 2) } catch { return @() }
}
function Wait-Target([string]$pattern, [int]$timeoutMs = 15000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    $target = Targets | Where-Object { $_.type -eq "page" -and $_.url -match $pattern } | Select-Object -First 1
    if ($target) { return @($target)[0] }
    Start-Sleep -Milliseconds 200
  }
  return $null
}
function ClickByLabel($target, [string]$pattern) {
  $target = @($target)[0]
  $expression = "(() => { const b = [...document.querySelectorAll('button')].find(x => /$pattern/i.test(x.getAttribute('aria-label') || '') || /$pattern/i.test(x.getAttribute('title') || '')); if (!b) return { ok: false, labels: [...document.querySelectorAll('button')].map(x => x.getAttribute('aria-label') || x.getAttribute('title')).filter(Boolean) }; b.click(); return { ok: true }; })()"
  $body = @{ id = 1; method = "Runtime.evaluate"; params = @{ expression = $expression; returnByValue = $true } } | ConvertTo-Json -Depth 6 -Compress
  $socket = New-Object System.Net.WebSockets.ClientWebSocket
  $token = [System.Threading.CancellationToken]::None
  $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, $token).Wait()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $socket.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $token).Wait()
  $buffer = New-Object byte[] 65536
  $result = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $token).Result
  $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
  $socket.Dispose()
  return ($text | ConvertFrom-Json).result.result.value
}

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
$log = Join-Path $env:LOCALAPPDATA "io.yuxino.kiri\logs\kiri.log"
$before = 0
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 700
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9335"
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 5
  $before = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }

  $started = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
  if ($started) { $null = $started.WaitForExit(8000) }
  $overlays = @()
  $overlayDeadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $overlayDeadline) {
    $overlays = @(Targets | Where-Object { $_.type -eq "page" -and $_.url -match "window=overlay" })
    if ($overlays.Count -gt 0) { break }
    Start-Sleep -Milliseconds 200
  }
  Check "the capture overlay opens" ($overlays.Count -gt 0) "count=$($overlays.Count)"
  if ($overlays.Count -eq 0) { throw "no overlay" }
  Start-Sleep -Milliseconds 900

  $x = 520; $y = 300; $w = 520; $h = 420
  [ScrollNative]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 150
  [ScrollNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  foreach ($step in 1..10) {
    [ScrollNative]::SetCursorPos($x + [int]($w * $step / 10), $y + [int]($h * $step / 10)) | Out-Null
    [ScrollNative]::mouse_event(0x0001, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
  }
  [ScrollNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 700

  # A capture on a multi-display desktop opens one overlay per display; only
  # the owner of the drag selection renders the toolbar.
  $click = @{ ok = $false }
  foreach ($t in $overlays) {
    $click = ClickByLabel $t "scroll"
    if ($click.ok -eq $true) { break }
  }
  Check "the scrolling screenshot action is reachable" ($click.ok -eq $true) ($click | ConvertTo-Json -Compress)
  Start-Sleep -Milliseconds 2500

  $panel = Wait-Target "window=scroll-capture" 8000
  $region = Wait-Target "window=scroll-capture-region" 8000
  Check "the scrolling preview panel opens" ($null -ne $panel) ($panel.url)
  Check "the scrolling region window opens" ($null -ne $region) ($region.url)

  $tail = if (Test-Path $log) {
    $stream = [System.IO.File]::Open($log, "Open", "Read", "ReadWrite")
    $null = $stream.Seek($before, "Begin")
    $reader = New-Object System.IO.StreamReader($stream)
    $text = $reader.ReadToEnd()
    $reader.Dispose(); $stream.Dispose()
    $text
  } else { "" }
  Check "startup does not fail on capture exclusion" (-not ($tail -match "startup failed")) (
    ($tail -split "`n" | Select-String -Pattern "scroll" | Select-Object -Last 3 | ForEach-Object { $_.Line.Trim() }) -join " | ")

  # Cancel the session so no test capture is saved.
  [ScrollNative]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [ScrollNative]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 800
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
}
$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Test, $_.Detail) }
  exit 1
}
exit 0
