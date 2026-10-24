# Verifies proportional pin resizing by dragging an edge, plus the resize cursor.
$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PinResize {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO info);
  [DllImport("user32.dll")] public static extern IntPtr LoadCursorW(IntPtr instance, IntPtr name);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO {
    public int cbSize; public int flags; public IntPtr hCursor; public int x; public int y;
  }
}
"@
$results = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = "") {
  [void]$results.Add([pscustomobject]@{ Test = $name; Pass = $ok; Detail = $detail })
  Write-Host ("[{0}] {1} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $detail)
}
function Get-Pins {
  $found = @(); $previous = [IntPtr]::Zero
  while ($true) {
    $h = [PinResize]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Rect($h) { $r = New-Object PinResize+RECT; [void][PinResize]::GetWindowRect($h, [ref]$r); return $r }
function Targets {
  try { return @(Invoke-RestMethod "http://127.0.0.1:9336/json" -TimeoutSec 2) } catch { return @() }
}
function Wait-Overlay([int]$timeoutMs = 15000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    $pages = @(Targets | Where-Object { $_.type -eq "page" -and $_.url -match "window=overlay" })
    if ($pages.Count -gt 0) { return $pages }
    Start-Sleep -Milliseconds 200
  }
  return @()
}
function Click-Pin($target) {
  $expression = "(() => { const b = [...document.querySelectorAll('button')].find(x => /pin screenshot|pin on top|置붿截뿯嚽|붿뿯嚽/i.test(x.getAttribute('aria-label') || '')); if (!b) return { ok: false }; b.click(); return { ok: true }; })()"
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
  return ($text | ConvertFrom-Json).result.result.value.ok
}

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 700
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9336"
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 5
  $started = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
  if ($started) { $null = $started.WaitForExit(8000) }
  $overlays = Wait-Overlay
  Check "the capture overlay opens" ($overlays.Count -gt 0) "count=$($overlays.Count)"
  Start-Sleep -Milliseconds 900

  # A non-square selection proves the aspect ratio is preserved. CDP input is
  # used because it targets the renderer directly, independent of OS input
  # focus; the resize gesture below still uses real Win32 mouse input.
  $x = 600; $y = 350; $w = 400; $h = 300
  $select = & node (Join-Path $PSScriptRoot "cdp-select-and-pin.mjs") 9336 $x $y $w $h 2>&1 | Out-String
  $selected = $select -match '"ok":true'
  Check "the toolbar pin action is reachable" $selected $select.Trim()
  $deadline = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $deadline -and (Get-Pins).Count -eq 0) { Start-Sleep -Milliseconds 100 }
  $pins = Get-Pins
  Check "the pin opens" ($pins.Count -eq 1) "count=$($pins.Count)"
  if ($pins.Count -ne 1) { throw "no pin" }
  $pin = $pins[0]
  $start = Get-Rect $pin
  $startW = $start.Right - $start.Left
  $startH = $start.Bottom - $start.Top
  $startRatio = [math]::Round($startW / $startH, 3)

  # The glow band is 12 DIP per side; grab just inside the right edge.
  $edgeX = $start.Right - 12 - 3
  $edgeY = [int](($start.Top + $start.Bottom) / 2)
  [PinResize]::SetCursorPos($edgeX, $edgeY) | Out-Null
  Start-Sleep -Milliseconds 350
  $info = New-Object PinResize+CURSORINFO
  $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][PinResize+CURSORINFO])
  [void][PinResize]::GetCursorInfo([ref]$info)
  $weCursor = [PinResize]::LoadCursorW([IntPtr]::Zero, [IntPtr]32644)
  Check "the right edge shows the horizontal resize cursor" ($info.hCursor -eq $weCursor) "cursor=$($info.hCursor) expected=$weCursor"

  [PinResize]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  foreach ($step in 1..10) {
    [PinResize]::SetCursorPos($edgeX + 10 * $step, $edgeY) | Out-Null
    Start-Sleep -Milliseconds 35
  }
  [PinResize]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 600
  $grown = Get-Rect $pin
  $grownW = $grown.Right - $grown.Left
  $grownH = $grown.Bottom - $grown.Top
  $grownRatio = [math]::Round($grownW / $grownH, 3)
  Check "dragging the right edge widens the pin" ($grownW -ge $startW + 80) "start=$startW end=$grownW"
  Check "the resized pin keeps the photo aspect ratio" ([math]::Abs($grownRatio - $startRatio) -le 0.02) "startRatio=$startRatio endRatio=$grownRatio"
  Check "the resized pin grows both axes proportionally" ([math]::Abs(($grownH - $startH) - [int](100 * ($startH - 24) / ($startW - 24))) -le 4) "start=$startW x $startH end=$grownW x $grownH"

  # A bottom-edge drag keeps the same rule.
  $bottomX = [int](($grown.Left + $grown.Right) / 2)
  $bottomY = $grown.Bottom - 12 - 3
  [PinResize]::SetCursorPos($bottomX, $bottomY) | Out-Null
  Start-Sleep -Milliseconds 250
  [PinResize]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  foreach ($step in 1..8) {
    [PinResize]::SetCursorPos($bottomX, $bottomY + 8 * $step) | Out-Null
    Start-Sleep -Milliseconds 35
  }
  [PinResize]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 600
  $taller = Get-Rect $pin
  $tallW = $taller.Right - $taller.Left
  $tallH = $taller.Bottom - $taller.Top
  Check "dragging the bottom edge grows the pin" ($tallH -ge $grownH + 60) "start=$grownH end=$tallH"
  Check "the bottom-edge resize keeps the aspect ratio" ([math]::Abs([math]::Round($tallW / $tallH, 3) - $startRatio) -le 0.02) "ratio=$([math]::Round($tallW / $tallH, 3))"

  [void][PinResize]::SetCursorPos([int](($taller.Left + $taller.Right) / 2), [int](($taller.Top + $taller.Bottom) / 2))
  Start-Sleep -Milliseconds 200
  [PinResize]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 50
  [PinResize]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 600
  Check "Escape closes the resized pin" ((Get-Pins).Count -eq 0) "left=$((Get-Pins).Count)"
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
