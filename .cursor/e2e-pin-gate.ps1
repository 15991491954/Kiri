# Reproduces the reported "clicked Pin, still editing" case with a REAL mouse
# click that lands on top of an existing pin, and checks the two paths that can
# leave the editing HUD behind:
#   A. the toolbar Pin button sits under a live pin (hit test / capture gate);
#   B. a text annotation is still being edited when Pin is clicked.
# Not part of the product.

param([int]$Runs = 3)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class G {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint map);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
  public static string ClassOf(IntPtr h) { var b = new StringBuilder(256); GetClassName(h, b, b.Capacity); return b.ToString(); }
  public static long ExStyle(IntPtr h) { return GetWindowLongPtr(h, -20).ToInt64(); }
}
"@

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
$results = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = "") {
  [void]$results.Add([pscustomobject]@{ Test = $name; Pass = $ok; Detail = $detail })
  Write-Host ("[{0}] {1} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $detail)
}
function Get-Pins {
  $found = @(); $previous = [IntPtr]::Zero
  while ($true) {
    $h = [G]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Rect($h) { $r = New-Object G+RECT; [void][G]::GetWindowRect($h, [ref]$r); return $r }
function Get-OverlayTargets {
  try {
    $pages = Invoke-RestMethod "http://127.0.0.1:9333/json" -TimeoutSec 2
    return @($pages | Where-Object { $_.type -eq "page" -and $_.url -match "[?&]window=overlay" })
  } catch { return @() }
}
function Wait-OverlayGone([int]$timeoutMs = 8000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    if ((Get-OverlayTargets).Count -eq 0) { return $true }
    Start-Sleep -Milliseconds 120
  }
  return ((Get-OverlayTargets).Count -eq 0)
}
function Send-Mouse([uint32]$flags, [uint32]$data = 0) { [G]::mouse_event($flags, 0, 0, $data, [UIntPtr]::Zero) }
function Click-At([int]$x, [int]$y) {
  [void][G]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 120
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 60
  Send-Mouse 0x0004
}
function Press-Key([int]$vk) {
  $scan = [byte][G]::MapVirtualKey([uint32]$vk, 0)
  [void][G]::keybd_event([byte]$vk, $scan, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [void][G]::keybd_event([byte]$vk, $scan, 2, [UIntPtr]::Zero)
}
function Drag-On-Screen([int]$x1, [int]$y1, [int]$x2, [int]$y2) {
  [void][G]::SetCursorPos($x1, $y1)
  Start-Sleep -Milliseconds 150
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 80
  foreach ($step in 1..12) {
    [void][G]::SetCursorPos(
      $x1 + [int](($x2 - $x1) * $step / 12),
      $y1 + [int](($y2 - $y1) * $step / 12))
    Send-Mouse 0x0001
    Start-Sleep -Milliseconds 35
  }
  Start-Sleep -Milliseconds 60
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 250
}
function New-ClipboardPin([int]$x, [int]$y) {
  $before = (Get-Pins).Count
  $bitmap = New-Object System.Drawing.Bitmap 320, 200
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(255, 40, 120, 200))
  $graphics.Dispose()
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
  $bitmap.Dispose()
  [void][G]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 250
  Press-Key 0x72   # F3
  $deadline = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $deadline -and (Get-Pins).Count -le $before) { Start-Sleep -Milliseconds 120 }
  return (Get-Pins)
}
function Close-Pins {
  foreach ($pin in (Get-Pins)) {
    $r = Get-Rect $pin
    $cx = $r.Left + [int](($r.Right - $r.Left) / 2)
    $cy = $r.Top + [int](($r.Bottom - $r.Top) / 2)
    [void][G]::SetCursorPos($cx, $cy)
    Start-Sleep -Milliseconds 250
    Press-Key 0x1B
    Start-Sleep -Milliseconds 300
  }
  Start-Sleep -Milliseconds 300
}
function Start-Capture {
  $created = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
  if ($created) { $null = $created.WaitForExit(8000) }
  # The overlay loads its frozen capture and geometry first; a drag before that
  # is ignored and looks like "the toolbar never appeared".
  Start-Sleep -Milliseconds 1600
}
function Probe-Point { (node (Join-Path $PSScriptRoot "cdp-pin-point.mjs") 9333 2>&1 | Out-String).Trim() | ConvertFrom-Json }

try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9333"
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 4

  # ---------------------------------------------------------------- scenario A
  # A live pin is parked exactly where the toolbar button appears, so the click
  # below is a real mouse click on the pin's photo if hit testing is wrong. The
  # capture gate must let it reach the overlay instead.
  $selection = @{ x = 380; y = 260; width = 320; height = 260 }
  $pinPoint = $null
  for ($attempt = 1; $attempt -le 5 -and $null -eq $pinPoint; $attempt++) {
    Close-Pins | Out-Null
    $pins = New-ClipboardPin 700 480
    $pinRect = Get-Rect $pins[$pins.Count - 1]
    Start-Capture
    Drag-On-Screen $selection.x $selection.y ($selection.x + $selection.width) ($selection.y + $selection.height)
    Start-Sleep -Milliseconds 500
    $point = Probe-Point
    if (-not $point.ok) { Press-Key 0x1B; Start-Sleep -Milliseconds 400; continue }
    $insidePin = ($point.screenX -ge $pinRect.Left) -and ($point.screenX -le $pinRect.Right) -and
      ($point.screenY -ge $pinRect.Top) -and ($point.screenY -le $pinRect.Bottom)
    if (-not $insidePin) {
      # Move the pin under the button, then repeat the identical selection: the
      # toolbar lands on the same pixels, so the pin covers it now.
      Press-Key 0x1B
      Start-Sleep -Milliseconds 500
      $cx = [int](($pinRect.Left + $pinRect.Right) / 2)
      $cy = [int](($pinRect.Top + $pinRect.Bottom) / 2)
      Drag-On-Screen $cx $cy ([int]$point.screenX) ([int]$point.screenY)
      Start-Sleep -Milliseconds 400
      Start-Capture
      Drag-On-Screen $selection.x $selection.y ($selection.x + $selection.width) ($selection.y + $selection.height)
      Start-Sleep -Milliseconds 500
      $point = Probe-Point
      if (-not $point.ok) { Press-Key 0x1B; Start-Sleep -Milliseconds 400; continue }
      $pinRect = Get-Rect (Get-Pins)[0]
      $insidePin = ($point.screenX -ge $pinRect.Left) -and ($point.screenX -le $pinRect.Right) -and
        ($point.screenY -ge $pinRect.Top) -and ($point.screenY -le $pinRect.Bottom)
    }
    if (-not $insidePin) { Press-Key 0x1B; Start-Sleep -Milliseconds 400; continue }
    $pinPoint = $point
  }

  $parkedDetail = "not reached"
  if ($null -ne $pinPoint) { $parkedDetail = "button=$([int]$pinPoint.screenX),$([int]$pinPoint.screenY)" }
  Check "scenario A: a pin was parked under the toolbar button" ($null -ne $pinPoint) $parkedDetail

  for ($run = 1; $run -le $Runs -and $null -ne $pinPoint; $run++) {
    $pinsBefore = (Get-Pins).Count
    $px = [int]$pinPoint.screenX
    $py = [int]$pinPoint.screenY
    [void][G]::SetCursorPos($px, $py)
    Start-Sleep -Milliseconds 200
    $probePoint = New-Object G+POINT($px, $py)
    $topClass = [G]::ClassOf([G]::WindowFromPoint($probePoint))
    Check "run $run`: the pin does not swallow the toolbar click" ($topClass -ne "KiriPinWindow") "top=$topClass at $px,$py"

    Click-At $px $py
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and (Get-Pins).Count -le $pinsBefore) { Start-Sleep -Milliseconds 120 }
    $pinsAfter = (Get-Pins).Count
    $gone = Wait-OverlayGone 8000
    Check "run $run`: clicking Pin over a pin opens one pin" ($pinsAfter -eq $pinsBefore + 1) "before=$pinsBefore after=$pinsAfter"
    Check "run $run`: the editing HUD is gone after the click" $gone "overlays=$((Get-OverlayTargets).Count)"

    # Leave exactly one pin for the next run so the button stays covered.
    $all = @(Get-Pins)
    if ($all.Count -gt 1) {
      foreach ($extra in $all[0..($all.Count - 2)]) {
        $r = Get-Rect $extra
        [void][G]::SetCursorPos(($r.Left + 10), ($r.Top + 10))
        Start-Sleep -Milliseconds 200
        Press-Key 0x1B
        Start-Sleep -Milliseconds 250
      }
    }
    if ($run -lt $Runs) {
      Start-Capture
      Drag-On-Screen $selection.x $selection.y ($selection.x + $selection.width) ($selection.y + $selection.height)
      Start-Sleep -Milliseconds 500
      $point = Probe-Point
      if ($point.ok) { $pinPoint = $point } else { Press-Key 0x1B }
    } else {
      Start-Capture
      Drag-On-Screen $selection.x $selection.y ($selection.x + $selection.width) ($selection.y + $selection.height)
      Start-Sleep -Milliseconds 400
      Press-Key 0x1B
      Start-Sleep -Milliseconds 400
    }
  }

  # ---------------------------------------------------------------- scenario B
  # A text box is still open when Pin is clicked. The confirmation must commit
  # it, close the HUD, and open the pin.
  Close-Pins | Out-Null
  # A capture left open by the previous run must finish closing first, or the
  # new --capture request is refused and the drag lands on a dying overlay.
  Press-Key 0x1B
  [void](Wait-OverlayGone 8000)
  Start-Sleep -Milliseconds 500
  $before = (Get-Pins).Count
  Start-Capture
  Drag-On-Screen 420 300 820 640
  Start-Sleep -Milliseconds 500
  $textScript = Join-Path $PSScriptRoot "pin-gate-text.mjs"
  $toolResult = (node $textScript 9333 2>&1 | Out-String).Trim()
  Check "scenario B: the text tool opened an editor" ($toolResult -match '"editable":true') $toolResult
  Start-Sleep -Milliseconds 400
  foreach ($vk in @(0x4B, 0x49, 0x52, 0x49)) { Press-Key $vk }
  Start-Sleep -Milliseconds 500
  $click = (node (Join-Path $PSScriptRoot "cdp-pin-click.mjs") 9333 2>&1 | Out-String).Trim()
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline -and (Get-Pins).Count -le $before) { Start-Sleep -Milliseconds 120 }
  $pinsNow = (Get-Pins).Count
  $goneB = Wait-OverlayGone 8000
  Check "scenario B: clicking Pin while editing text opens one pin" ($pinsNow -eq $before + 1) "before=$before after=$pinsNow click=$click"
  Check "scenario B: the editing HUD is gone after the click" $goneB "overlays=$((Get-OverlayTargets).Count)"
  # ---------------------------------------------------------------- scenario C
  # The capture gate must not strand pins below other windows: every pin returns
  # to the topmost band once the session ends, and stays above other apps.
  Close-Pins | Out-Null
  Press-Key 0x1B
  [void](Wait-OverlayGone 8000)
  Start-Sleep -Milliseconds 400
  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1500
  $notepad.Refresh()
  [void][G]::SetForegroundWindow($notepad.MainWindowHandle)
  Start-Sleep -Milliseconds 500
  $noteRect = Get-Rect $notepad.MainWindowHandle
  $noteCentre = New-Object G+POINT(([int](($noteRect.Left + $noteRect.Right) / 2)), ([int](($noteRect.Top + $noteRect.Bottom) / 2)))
  $pins = New-ClipboardPin $noteCentre.X $noteCentre.Y
  $pin = $pins[$pins.Count - 1]
  $pinRect = Get-Rect $pin
  $pinCentre = New-Object G+POINT(([int](($pinRect.Left + $pinRect.Right) / 2)), ([int](($pinRect.Top + $pinRect.Bottom) / 2)))
  Start-Sleep -Milliseconds 400
  Check "scenario C: a new pin is above the app it was pasted over" ([G]::ClassOf([G]::WindowFromPoint($pinCentre)) -eq "KiriPinWindow") "top=$([G]::ClassOf([G]::WindowFromPoint($pinCentre)))"
  Check "scenario C: the pin carries the topmost band style" (([G]::ExStyle($pin) -band 0x8) -ne 0) "exstyle=$([G]::ExStyle($pin))"

  Start-Capture
  Check "scenario C: the capture gate moves pins out of the toolbar's way" ([G]::ClassOf([G]::WindowFromPoint($pinCentre)) -ne "KiriPinWindow") "top=$([G]::ClassOf([G]::WindowFromPoint($pinCentre)))"
  Press-Key 0x1B
  [void](Wait-OverlayGone 8000)
  Start-Sleep -Milliseconds 800
  Check "scenario C: the pin is back on top after the capture ends" (
    ([G]::ClassOf([G]::WindowFromPoint($pinCentre)) -eq "KiriPinWindow") -and (([G]::ExStyle($pin) -band 0x8) -ne 0)
  ) "top=$([G]::ClassOf([G]::WindowFromPoint($pinCentre))) exstyle=$([G]::ExStyle($pin))"
  $notepad | Stop-Process -Force -ErrorAction SilentlyContinue
  Close-Pins | Out-Null
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
