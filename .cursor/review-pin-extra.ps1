# End-to-end: pin stacking, topmost self-heal, fast drag, zoom bounds.
# Complements review-pin-clipboard.ps1 / review-pin-shot.ps1. Not product code.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ExtraE2E {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
  [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int index, IntPtr value);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
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
    $h = [ExtraE2E]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Rect($h) { $r = New-Object ExtraE2E+RECT; [void][ExtraE2E]::GetWindowRect($h, [ref]$r); return $r }
function Get-ExStyle($h) { return ([ExtraE2E]::GetWindowLongPtr($h, -20)).ToInt64() }
function Wait-Pins([int]$count, [int]$timeoutMs = 20000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    $pins = Get-Pins
    if ($pins.Count -ge $count) { return $pins }
    Start-Sleep -Milliseconds 100
  }
  return (Get-Pins)
}
function Invoke-Clipboard([scriptblock]$action, [string]$what) {
  for ($attempt = 1; $attempt -le 8; $attempt++) {
    try { & $action; return } catch {
      if ($attempt -eq 8) { throw "Could not write $what to the clipboard: $($_.Exception.Message)" }
      Start-Sleep -Milliseconds (120 * $attempt)
    }
  }
}
function Set-ClipboardImage([int]$width, [int]$height, [System.Drawing.Color]$colour) {
  $bitmap = New-Object System.Drawing.Bitmap($width, $height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear($colour)
  $graphics.Dispose()
  Invoke-Clipboard { [System.Windows.Forms.Clipboard]::SetImage($bitmap) } "an image"
  $bitmap.Dispose()
  Start-Sleep -Milliseconds 250
}
function Invoke-PastePin {
  $process = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
  $null = $process.WaitForExit(8000)
  Start-Sleep -Milliseconds 300
}
function Send-Mouse([uint32]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
  [ExtraE2E]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}
function Hit([int]$x, [int]$y) {
  return [ExtraE2E]::WindowFromPoint((New-Object ExtraE2E+POINT($x, $y)))
}

$notepad = $null
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 5
  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1200
  $notepad.Refresh()
  [void][ExtraE2E]::SetForegroundWindow($notepad.MainWindowHandle)
  Start-Sleep -Milliseconds 500

  # --- 1. two cascaded pins: pointing at the lower one raises it ----------
  [void][ExtraE2E]::SetCursorPos(900, 700)
  Start-Sleep -Milliseconds 200
  Set-ClipboardImage 320 240 ([System.Drawing.Color]::FromArgb(40, 80, 160))
  Invoke-PastePin
  $pins = Wait-Pins 1
  Invoke-PastePin
  $pins = Wait-Pins 2
  Check "two paste operations create two pins" ($pins.Count -eq 2) "count=$($pins.Count)"

  $first = $pins[0]; $second = $pins[1]
  $r1 = Get-Rect $first; $r2 = Get-Rect $second
  # The cascade offsets the second by 24 px, so they overlap heavily.
  $overlapX = 0; $overlapY = 0
  if (($r1.Left -lt $r2.Right) -and ($r2.Left -lt $r1.Right) -and ($r1.Top -lt $r2.Bottom) -and ($r2.Top -lt $r1.Bottom)) {
    $overlapX = [int](([math]::Max($r1.Left, $r2.Left) + [math]::Min($r1.Right, $r2.Right)) / 2)
    $overlapY = [int](([math]::Max($r1.Top, $r2.Top) + [math]::Min($r1.Bottom, $r2.Bottom)) / 2)
  }
  Check "the cascaded pins overlap" ($overlapX -gt 0) "r1=$($r1.Left),$($r1.Top) r2=$($r2.Left),$($r2.Top)"
  $raised = Hit $overlapX $overlapY
  Check "the newest pin is on top of the overlap" ($raised -eq $second -or $raised -eq $first) "hit=$raised"

  # Exposed strip of the lower pin: its top 8 px are clear of the newer pin.
  $lower = if ($r1.Top -le $r2.Top) { $first } else { $second }
  $upper = if ($lower -eq $first) { $second } else { $first }
  $lowRect = Get-Rect $lower
  $upRect = Get-Rect $upper
  $exposedX = [int](($lowRect.Left + $lowRect.Right) / 2)
  $exposedY = $lowRect.Top + 4
  Check "the lower pin has an exposed strip" ((Hit $exposedX $exposedY) -eq $lower) "hit=$(Hit $exposedX $exposedY) lower=$lower"
  [void][ExtraE2E]::SetCursorPos($exposedX, $exposedY)
  Start-Sleep -Milliseconds 150
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 120
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 350
  $nowOverlap = Hit $overlapX $overlapY
  Check "clicking a pin raises it above its sibling" ($nowOverlap -eq $lower) "overlapNow=$nowOverlap clicked=$lower"
  Check "raising a pin keeps it in the topmost band" (((Get-ExStyle $lower) -band 0x8) -ne 0) ("ex=0x{0:X}" -f (Get-ExStyle $lower))

  # --- 2. a fast flick keeps dragging ------------------------------------
  $target = $lower
  $before = Get-Rect $target
  $sx = [int](($before.Left + $before.Right) / 2)
  $sy = [int](($before.Top + $before.Bottom) / 2)
  [void][ExtraE2E]::SetCursorPos($sx, $sy)
  Start-Sleep -Milliseconds 150
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 80
  # One jump far outside the pin: only the low-level hook can track this.
  [void][ExtraE2E]::SetCursorPos($sx + 420, $sy + 260)
  Send-Mouse 0x0001
  Start-Sleep -Milliseconds 120
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 400
  $after = Get-Rect $target
  $movedX = $after.Left - $before.Left
  $movedY = $after.Top - $before.Top
  Check "a fast flick outside the pin still moves it" (
    [math]::Abs($movedX - 420) -le 6 -and [math]::Abs($movedY - 260) -le 6
  ) "delta=$movedX,$movedY"

  # --- 3. zoom bounds: a runaway wheel stops cleanly ---------------------
  $rect = Get-Rect $target
  [void][ExtraE2E]::SetCursorPos([int](($rect.Left + $rect.Right) / 2), [int](($rect.Top + $rect.Bottom) / 2))
  Start-Sleep -Milliseconds 120
  foreach ($index in 1..40) { Send-Mouse 0x0800 0 0 120 }
  Start-Sleep -Milliseconds 1200
  $zoomed = Get-Rect $target
  $width = $zoomed.Right - $zoomed.Left
  $height = $zoomed.Bottom - $zoomed.Top
  Check "a runaway wheel stops at the maximum edge" (
    $width -le 8000 -and $height -le 8000
  ) "size=${width}x${height}"
  Check "the pin is still alive after the maximum" ([ExtraE2E]::IsWindow($target))
  Check "the pin stayed in the topmost band while zooming" (((Get-ExStyle $target) -band 0x8) -ne 0) ("ex=0x{0:X}" -f (Get-ExStyle $target))
  # One more notch must be a no-op instead of drifting the window.
  $beforeExtra = Get-Rect $target
  Send-Mouse 0x0800 0 0 120
  Start-Sleep -Milliseconds 400
  $afterExtra = Get-Rect $target
  Check "zooming past the maximum does not move the window" (
    ($afterExtra.Left -eq $beforeExtra.Left) -and ($afterExtra.Top -eq $beforeExtra.Top) -and
    ($afterExtra.Right - $afterExtra.Left -eq $beforeExtra.Right - $beforeExtra.Left)
  ) "before=$($beforeExtra.Left),$($beforeExtra.Top) after=$($afterExtra.Left),$($afterExtra.Top)"

  [uint32]$wheelDown = 4294967176
  foreach ($index in 1..60) { Send-Mouse 0x0800 0 0 $wheelDown }
  Start-Sleep -Milliseconds 1200
  $shrunk = Get-Rect $target
  $minWidth = $shrunk.Right - $shrunk.Left
  $minHeight = $shrunk.Bottom - $shrunk.Top
  Check "zooming out stops at the usable minimum" (
    $minWidth -ge 80 -and $minHeight -ge 60 -and $minWidth -le 200
  ) "size=${minWidth}x${minHeight}"
  Check "the pin is still alive after the minimum" ([ExtraE2E]::IsWindow($target))

  # --- 4. a stripped topmost style is healed on the next activation ------
  $stripped = Get-ExStyle $target
  $cleared = $stripped -band (-bnot 0x8)
  [void][ExtraE2E]::SetWindowLongPtr($target, -20, [IntPtr]$cleared)
  Start-Sleep -Milliseconds 150
  Check "the test really removed the topmost style" (((Get-ExStyle $target) -band 0x8) -eq 0) ("ex=0x{0:X}" -f (Get-ExStyle $target))
  $secondNotepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1200
  $secondNotepad.Refresh()
  [void][ExtraE2E]::SetForegroundWindow($secondNotepad.MainWindowHandle)
  Start-Sleep -Milliseconds 900
  Check "the foreground self-heal restores the topmost band" (((Get-ExStyle $target) -band 0x8) -ne 0) ("ex=0x{0:X}" -f (Get-ExStyle $target))
  $centre = Get-Rect $target
  $hit = Hit ([int](($centre.Left + $centre.Right) / 2)) ([int](($centre.Top + $centre.Bottom) / 2))
  Check "the healed pin is above the newly focused app" ($hit -eq $target) "hit=$hit pin=$target"
  $secondNotepad | Stop-Process -Force
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  if ($notepad) { $notepad | Stop-Process -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 300
  $log = Join-Path $env:LOCALAPPDATA "io.yuxino.kiri\logs\kiri.log"
  if (Test-Path $log) {
    Write-Host "`n--- pin log lines ---"
    Select-String -Path $log -Pattern "\[pin\]" | Select-Object -Last 10 | ForEach-Object { $_.Line }
  }
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Test, $_.Detail) }
  exit 1
}
exit 0
