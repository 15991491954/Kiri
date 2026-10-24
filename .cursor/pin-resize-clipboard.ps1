# Verifies proportional pin resizing through a clipboard pin (no capture overlay).
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PinGrip {
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
    $h = [PinGrip]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Rect($h) { $r = New-Object PinGrip+RECT; [void][PinGrip]::GetWindowRect($h, [ref]$r); return $r }
function CursorAt([int]$px, [int]$py) {
  [PinGrip]::SetCursorPos($px, $py) | Out-Null
  Start-Sleep -Milliseconds 300
  $info = New-Object PinGrip+CURSORINFO
  $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][PinGrip+CURSORINFO])
  [void][PinGrip]::GetCursorInfo([ref]$info)
  return $info.hCursor
}

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 700
  # A 400x300 clipboard image gives the pin a known 4:3 photo.
  $bitmap = New-Object System.Drawing.Bitmap 400, 300
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(40, 90, 200))
  $graphics.Dispose()
  for ($attempt = 1; $attempt -le 8; $attempt++) {
    try { [System.Windows.Forms.Clipboard]::SetImage($bitmap); break }
    catch { Start-Sleep -Milliseconds 250 }
  }
  $bitmap.Dispose()

  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 5
  # Place the pin away from the screen edge: an edge resize needs room to grow.
  [PinGrip]::SetCursorPos(900, 560) | Out-Null
  Start-Sleep -Milliseconds 200
  $pasted = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
  if ($pasted) { $null = $pasted.WaitForExit(8000) }
  $deadline = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $deadline -and (Get-Pins).Count -eq 0) { Start-Sleep -Milliseconds 100 }
  $pins = Get-Pins
  Check "the clipboard pin opens" ($pins.Count -eq 1) "count=$($pins.Count)"
  if ($pins.Count -ne 1) { throw "no pin" }
  $pin = $pins[0]
  # FindWindowEx sees the window while it is still hidden behind its first
  # frame; wait until it is really on screen before measuring or clicking.
  $visibleDeadline = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $visibleDeadline -and -not [PinGrip]::IsWindowVisible($pin)) {
    Start-Sleep -Milliseconds 50
  }
  Start-Sleep -Milliseconds 700
  $start = Get-Rect $pin
  $startW = $start.Right - $start.Left
  $startH = $start.Bottom - $start.Top
  # The window is the photo plus the 12 DIP glow band on each side.
  Check "the pin photo keeps the source aspect ratio" (
    [math]::Abs((($startW - 24) / ($startH - 24)) - (400 / 300)) -le 0.02
  ) "window=$($startW)x$($startH) photo=$($startW - 24)x$($startH - 24)"

  $edgeX = $start.Right - 12 - 3
  $edgeY = [int](($start.Top + $start.Bottom) / 2)
  $cursor = CursorAt $edgeX $edgeY
  $weCursor = [PinGrip]::LoadCursorW([IntPtr]::Zero, [IntPtr]32644)
  Check "the right edge shows the horizontal resize cursor" ($cursor -eq $weCursor) "cursor=$cursor expected=$weCursor"

  [PinGrip]::SetCursorPos($edgeX, $edgeY) | Out-Null
  Start-Sleep -Milliseconds 200
  [PinGrip]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  foreach ($step in 1..10) {
    [PinGrip]::SetCursorPos($edgeX + 10 * $step, $edgeY) | Out-Null
    Start-Sleep -Milliseconds 35
  }
  [PinGrip]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 600
  $grown = Get-Rect $pin
  $grownW = $grown.Right - $grown.Left
  $grownH = $grown.Bottom - $grown.Top
  Check "dragging the right edge widens the pin" ($grownW -ge $startW + 80) "start=$startW end=$grownW"
  Check "the photo aspect ratio is preserved while widening" (
    [math]::Abs((($grownW - 24) / ($grownH - 24)) - (400 / 300)) -le 0.02
  ) "photo=$($grownW - 24)x$($grownH - 24)"
  Check "the photo grows proportionally" ([math]::Abs((($grownH - 24) - ($grownW - 24) * 0.75)) -le 3) "photoH=$($grownH - 24) expected=$([int](($grownW - 24) * 0.75))"

  $bottomX = [int](($grown.Left + $grown.Right) / 2)
  $bottomY = $grown.Bottom - 12 - 3
  [PinGrip]::SetCursorPos($bottomX, $bottomY) | Out-Null
  Start-Sleep -Milliseconds 250
  [PinGrip]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  foreach ($step in 1..8) {
    [PinGrip]::SetCursorPos($bottomX, $bottomY + 8 * $step) | Out-Null
    Start-Sleep -Milliseconds 35
  }
  [PinGrip]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 600
  $taller = Get-Rect $pin
  $tallW = $taller.Right - $taller.Left
  $tallH = $taller.Bottom - $taller.Top
  Check "dragging the bottom edge grows the pin" ($tallH -ge $grownH + 50) "start=$grownH end=$tallH"
  Check "the bottom-edge resize keeps the aspect ratio" (
    [math]::Abs((($tallW - 24) / ($tallH - 24)) - (400 / 300)) -le 0.02
  ) "photo=$($tallW - 24)x$($tallH - 24)"

  # A corner drag also stays proportional.
  $cornerX = $taller.Right - 12 - 4
  $cornerY = $taller.Bottom - 12 - 4
  [PinGrip]::SetCursorPos($cornerX, $cornerY) | Out-Null
  Start-Sleep -Milliseconds 200
  [PinGrip]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  foreach ($step in 1..8) {
    [PinGrip]::SetCursorPos($cornerX + 8 * $step, $cornerY + 8 * $step) | Out-Null
    Start-Sleep -Milliseconds 35
  }
  [PinGrip]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 600
  $corner = Get-Rect $pin
  $cornerW = $corner.Right - $corner.Left
  $cornerH = $corner.Bottom - $corner.Top
  Check "a corner drag grows both axes" ($cornerW -gt $tallW -and $cornerH -gt $tallH) "from=$tallW x $tallH to=$cornerW x $cornerH"
  Check "the corner drag keeps the aspect ratio" (
    [math]::Abs((($cornerW - 24) / ($cornerH - 24)) - (400 / 300)) -le 0.02
  ) "photo=$($cornerW - 24)x$($cornerH - 24)"

  [void][PinGrip]::SetCursorPos([int](($corner.Left + $corner.Right) / 2), [int](($corner.Top + $corner.Bottom) / 2))
  Start-Sleep -Milliseconds 200
  [PinGrip]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 50
  [PinGrip]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 600
  Check "Escape closes the resized pin" ((Get-Pins).Count -eq 0) "left=$((Get-Pins).Count)"
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
}
$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Test, $_.Detail) }
  exit 1
}
exit 0
