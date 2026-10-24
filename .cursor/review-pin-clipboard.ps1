# End-to-end: F3 clipboard pins, drag, hover zoom, percentage badge, Escape.
# Runs the built app, drives real Win32 input, asserts the native pin windows.
# Not part of the product.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ClipE2E {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
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
  [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint affinity);
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
function Get-WindowsByClass([string]$cls) {
  $found = @(); $previous = [IntPtr]::Zero
  while ($true) {
    $h = [ClipE2E]::FindWindowEx([IntPtr]::Zero, $previous, $cls, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Pins { return @(Get-WindowsByClass "KiriPinWindow") }
function Get-Badges { return @(Get-WindowsByClass "KiriPinBadge") }
function Get-Rect($h) { $r = New-Object ClipE2E+RECT; [void][ClipE2E]::GetWindowRect($h, [ref]$r); return $r }
function Get-Style($h) { return ([ClipE2E]::GetWindowLongPtr($h, -16)).ToInt64() }
function Get-ExStyle($h) { return ([ClipE2E]::GetWindowLongPtr($h, -20)).ToInt64() }
function Wait-Pins([int]$count, [int]$timeoutMs = 20000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    $pins = Get-Pins
    if ($pins.Count -ge $count) { return $pins }
    Start-Sleep -Milliseconds 100
  }
  return (Get-Pins)
}
function Invoke-PastePin {
  $process = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
  $null = $process.WaitForExit(8000)
  Start-Sleep -Milliseconds 300
}
function Invoke-Clipboard([scriptblock]$action, [string]$what) {
  # The clipboard is shared: another process may hold it for a moment. Retry
  # instead of failing the whole run.
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
  $graphics.FillEllipse([System.Drawing.Brushes]::White, 20, 20, 90, 60)
  $graphics.Dispose()
  Invoke-Clipboard { [System.Windows.Forms.Clipboard]::SetImage($bitmap) } "an image"
  $bitmap.Dispose()
  Start-Sleep -Milliseconds 250
}
function Send-F3 {
  [ClipE2E]::keybd_event(0x72, 0x3D, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 50
  [ClipE2E]::keybd_event(0x72, 0x3D, 2, [UIntPtr]::Zero)
}
function Send-Escape {
  [ClipE2E]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [ClipE2E]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
}
function Send-Mouse([uint32]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
  [ClipE2E]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}
function Get-WorkingSetMb {
  $process = Get-Process kiri -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $process) { return 0 }
  return [math]::Round($process.PrivateMemorySize64 / 1MB, 1)
}

$warmNotepad = $null
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 5

  $warmNotepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1400
  $warmNotepad.Refresh()
  [void][ClipE2E]::SetForegroundWindow($warmNotepad.MainWindowHandle)
  Start-Sleep -Milliseconds 500
  $foregroundBefore = [ClipE2E]::GetForegroundWindow()
  $memoryBefore = Get-WorkingSetMb
  $webviewsBefore = @(Get-Process msedgewebview2 -ErrorAction SilentlyContinue).Count

  # --- 1. real F3 hotkey with a clipboard image --------------------------
  Set-ClipboardImage 400 300 ([System.Drawing.Color]::FromArgb(30, 90, 200))
  [void][ClipE2E]::SetCursorPos(1200, 700)
  Start-Sleep -Milliseconds 200
  Send-F3
  $pins = Wait-Pins 1 20000
  Check "the global F3 shortcut pins the clipboard image" ($pins.Count -eq 1) "count=$($pins.Count)"
  if ($pins.Count -eq 0) { throw "F3 did not create a pin; check the shortcut registration" }
  Check "the clipboard itself is untouched" ([System.Windows.Forms.Clipboard]::ContainsImage())

  $pin = $pins[0]
  $rect = Get-Rect $pin
  $pinWidth = $rect.Right - $rect.Left
  $pinHeight = $rect.Bottom - $rect.Top
  Check "the pin opens at native image size" (($pinWidth -eq 400) -and ($pinHeight -eq 300)) "size=${pinWidth}x${pinHeight}"
  Check "the pin window is visible" ([ClipE2E]::IsWindowVisible($pin))

  $style = Get-Style $pin
  $ex = Get-ExStyle $pin
  Check "the pin is borderless" ((($style -band 0x00C00000) -eq 0) -and (($style -band 0x00040000) -eq 0)) ("style=0x{0:X}" -f $style)
  Check "the pin is layered" ((($ex -band 0x00080000) -ne 0)) ("ex=0x{0:X}" -f $ex)
  Check "the pin is topmost" ((($ex -band 0x00000008) -ne 0)) ("ex=0x{0:X}" -f $ex)
  Check "the pin never activates" ((($ex -band 0x08000000) -ne 0)) ("ex=0x{0:X}" -f $ex)
  $affinity = 0
  [void][ClipE2E]::GetWindowDisplayAffinity($pin, [ref]$affinity)
  Check "the pin is excluded from Kiri's own screenshots" ($affinity -eq 0x11) ("affinity=0x{0:X}" -f $affinity)
  Check "pasting does not change the foreground window" ([ClipE2E]::GetForegroundWindow() -eq $foregroundBefore)

  $cx = [int](($rect.Left + $rect.Right) / 2)
  $cy = [int](($rect.Top + $rect.Bottom) / 2)
  [void][ClipE2E]::SetCursorPos($cx, $cy)
  Start-Sleep -Milliseconds 200
  $hit = [ClipE2E]::WindowFromPoint((New-Object ClipE2E+POINT($cx, $cy)))
  Check "the pin is above everything under the pointer" ($hit -eq $pin) "hit=$hit pin=$pin"

  # --- 2. drag ------------------------------------------------------------
  $before = Get-Rect $pin
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 60
  foreach ($step in @(@(40, 30), @(80, 60), @(120, 90))) {
    [void][ClipE2E]::SetCursorPos($cx + $step[0], $cy + $step[1])
    Send-Mouse 0x0001
    Start-Sleep -Milliseconds 45
  }
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 400
  $after = Get-Rect $pin
  Check "dragging moves the pin" (
    ($after.Left - $before.Left -eq 120) -and ($after.Top - $before.Top -eq 90)
  ) "delta=$($after.Left - $before.Left),$($after.Top - $before.Top)"

  # --- 3. wheel zoom and the percentage badge ---------------------------
  $before = Get-Rect $pin
  $cx = [int](($before.Left + $before.Right) / 2)
  $cy = [int](($before.Top + $before.Bottom) / 2)
  [void][ClipE2E]::SetCursorPos($cx, $cy)
  Start-Sleep -Milliseconds 150
  Send-Mouse 0x0800 0 0 120
  Start-Sleep -Milliseconds 700
  $after = Get-Rect $pin
  $w0 = $before.Right - $before.Left
  $h0 = $before.Bottom - $before.Top
  $w1 = $after.Right - $after.Left
  $h1 = $after.Bottom - $after.Top
  Check "wheel up enlarges the hovered pin" ($w1 -gt $w0) "width $w0 -> $w1"
  Check "zoom keeps the image aspect ratio" ([math]::Abs(($w1 / $h1) - ($w0 / $h0)) -lt 0.02) "ratio $([math]::Round($w1 / $h1,4)) vs $([math]::Round($w0 / $h0,4))"
  Check "one wheel notch is 10 percent" ([math]::Abs($w1 / $w0 - 1.1) -lt 0.02) "ratio=$([math]::Round($w1 / $w0,4))"

  $badges = @(Get-Badges | Where-Object { [ClipE2E]::IsWindowVisible($_) })
  Check "the zoom percentage badge is shown" ($badges.Count -ge 1) "visible=$($badges.Count)"
  if ($badges.Count -ge 1) {
    $badgeRect = Get-Rect $badges[0]
    $badgeEx = Get-ExStyle $badges[0]
    Check "the badge is topmost and click-through" ((($badgeEx -band 0x00000008) -ne 0) -and (($badgeEx -band 0x00000020) -ne 0)) ("ex=0x{0:X}" -f $badgeEx)
    $inside = ($badgeRect.Left -ge $after.Left) -and ($badgeRect.Top -ge $after.Top) -and
      ($badgeRect.Right -le $after.Right) -and ($badgeRect.Bottom -le $after.Bottom)
    Check "the badge sits inside the pin frame" $inside "badge=$($badgeRect.Left),$($badgeRect.Top) pin=$($after.Left),$($after.Top)"
  }
  Start-Sleep -Milliseconds 1300
  Check "the badge hides after the scroll stops" (@(Get-Badges | Where-Object { [ClipE2E]::IsWindowVisible($_) }).Count -eq 0)

  [uint32]$wheelDown = 4294967176
  Send-Mouse 0x0800 0 0 $wheelDown
  Start-Sleep -Milliseconds 600
  $restored = Get-Rect $pin
  Check "wheel down restores the previous size" ([math]::Abs(($restored.Right - $restored.Left) - $w0) -le 2) "width=$($restored.Right - $restored.Left) expected=$w0"

  # --- 4. several pins stay topmost and zoom independently ---------------
  # Open the second pin far from the first so "which pin is under the pointer"
  # is unambiguous: a clipboard pin is centred on the cursor.
  [void][ClipE2E]::SetCursorPos(2100, 500)
  Start-Sleep -Milliseconds 200
  Set-ClipboardImage 260 180 ([System.Drawing.Color]::FromArgb(200, 120, 30))
  Invoke-PastePin
  $pins = Wait-Pins 2
  Check "a second paste creates an independent pin" ($pins.Count -eq 2) "count=$($pins.Count)"
  $first = $pins[0]
  $second = $pins[1]
  foreach ($candidate in $pins) {
    $candidateRect = Get-Rect $candidate
    if (($candidateRect.Left -eq $restored.Left) -and ($candidateRect.Top -eq $restored.Top)) { $first = $candidate }
  }
  foreach ($candidate in $pins) { if ($candidate -ne $first) { $second = $candidate } }

  $firstRect = Get-Rect $first
  $secondRect = Get-Rect $second
  $overlaps = -not (
    ($secondRect.Right -le $firstRect.Left) -or ($secondRect.Left -ge $firstRect.Right) -or
    ($secondRect.Bottom -le $firstRect.Top) -or ($secondRect.Top -ge $firstRect.Bottom))
  Check "the two pins do not overlap" (-not $overlaps) "first=$($firstRect.Left),$($firstRect.Top) second=$($secondRect.Left),$($secondRect.Top)"
  [void][ClipE2E]::SetCursorPos([int](($firstRect.Left + $firstRect.Right) / 2), [int](($firstRect.Top + $firstRect.Bottom) / 2))
  Start-Sleep -Milliseconds 200
  $hitBefore = [ClipE2E]::WindowFromPoint((New-Object ClipE2E+POINT([int](($firstRect.Left + $firstRect.Right) / 2), [int](($firstRect.Top + $firstRect.Bottom) / 2))))
  Check "the point under the pointer belongs to the first pin" ($hitBefore -eq $first) "hit=$hitBefore first=$first second=$second"
  Send-Mouse 0x0800 0 0 120
  Start-Sleep -Milliseconds 700
  $firstAfter = Get-Rect $first
  $secondAfter = Get-Rect $second
  Check "the wheel only zooms the pin under the pointer" (
    (($firstAfter.Right - $firstAfter.Left) -gt ($firstRect.Right - $firstRect.Left)) -and
    (($secondAfter.Right - $secondAfter.Left) -eq ($secondRect.Right - $secondRect.Left))
  ) "hovered=$($firstRect.Right - $firstRect.Left)->$($firstAfter.Right - $firstAfter.Left) other=$($secondRect.Right - $secondRect.Left)->$($secondAfter.Right - $secondAfter.Left)"
  [uint32]$wheelDown2 = 4294967176
  Send-Mouse 0x0800 0 0 $wheelDown2
  Start-Sleep -Milliseconds 400

  Set-ClipboardImage 200 200 ([System.Drawing.Color]::FromArgb(20, 160, 90))
  Invoke-PastePin
  $pins = Wait-Pins 3
  Check "a third pin opens" ($pins.Count -eq 3) "count=$($pins.Count)"
  $topmostCount = @($pins | Where-Object { ((Get-ExStyle $_) -band 0x8) -ne 0 }).Count
  Check "all pins are topmost" ($topmostCount -eq $pins.Count) "topmost=${topmostCount}/$($pins.Count)"

  # --- 5. Escape closes only the hovered pin -----------------------------
  # Pins may overlap; the window that must close is whatever the pointer is
  # actually over, which `WindowFromPoint` resolves exactly like the product.
  $target = $pins[0]
  $targetRect = Get-Rect $target
  $tx = [int](($targetRect.Left + $targetRect.Right) / 2)
  $ty = [int](($targetRect.Top + $targetRect.Bottom) / 2)
  [void][ClipE2E]::SetCursorPos($tx, $ty)
  Start-Sleep -Milliseconds 200
  $underPointer = [ClipE2E]::WindowFromPoint((New-Object ClipE2E+POINT($tx, $ty)))
  if ($underPointer -ne [IntPtr]::Zero -and ($pins -contains $underPointer)) { $target = $underPointer }
  Check "the pointer resolves to a pin before Escape" ($pins -contains $underPointer) "hit=$underPointer"
  $foregroundBeforeEscape = [ClipE2E]::GetForegroundWindow()
  Send-Escape
  Start-Sleep -Milliseconds 600
  $remaining = Get-Pins
  Check "Escape closes only the pin under the pointer" (
    ($remaining.Count -eq 2) -and (-not ($remaining -contains $target)) -and -not ([ClipE2E]::IsWindow($target))
  ) "remaining=$($remaining.Count) targetAlive=$([ClipE2E]::IsWindow($target))"
  Check "closing a pin does not change the foreground window" ([ClipE2E]::GetForegroundWindow() -eq $foregroundBeforeEscape)

  # --- 6. clipboard text and copied image files --------------------------
  Invoke-Clipboard { [System.Windows.Forms.Clipboard]::SetText("Kiri pin text`r`n第二行：中文排版测试`r`nhttps://example.com/a/very/long/url/that/must/wrap/inside/the/card") } "text"
  Start-Sleep -Milliseconds 250
  Send-F3
  $pins = Wait-Pins 3 15000
  Check "F3 pins clipboard text as a card" ($pins.Count -eq 3) "count=$($pins.Count)"

  $temp = Join-Path $env:TEMP ("kiri-pin-review-{0}.png" -f ([guid]::NewGuid()))
  $bitmap = New-Object System.Drawing.Bitmap(240, 160)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(120, 40, 200))
  $graphics.Dispose()
  $bitmap.Save($temp, [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
  $files = New-Object System.Collections.Specialized.StringCollection
  [void]$files.Add($temp)
  Invoke-Clipboard { [System.Windows.Forms.Clipboard]::SetFileDropList($files) } "a file list"
  Start-Sleep -Milliseconds 250
  Invoke-PastePin
  $pins = Wait-Pins 4
  Check "a copied image file becomes a pin" ($pins.Count -eq 4) "count=$($pins.Count)"
  Remove-Item $temp -Force -ErrorAction SilentlyContinue

  # --- 7. cost and stacking against another app --------------------------
  $memoryAfter = Get-WorkingSetMb
  $webviewsAfter = @(Get-Process msedgewebview2 -ErrorAction SilentlyContinue).Count
  Check "pins add no WebView process" ($webviewsAfter -eq $webviewsBefore) "before=$webviewsBefore after=$webviewsAfter"
  Check "four pins stay within a modest memory budget" (($memoryAfter - $memoryBefore) -lt 120) "grew ${memoryBefore}MB -> ${memoryAfter}MB"

  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1000
  $pins = Get-Pins
  $sample = $pins[0]
  $sampleRect = Get-Rect $sample
  $sampleX = [int](($sampleRect.Left + $sampleRect.Right) / 2)
  $sampleY = [int](($sampleRect.Top + $sampleRect.Bottom) / 2)
  $hit = [ClipE2E]::WindowFromPoint((New-Object ClipE2E+POINT($sampleX, $sampleY)))
  Check "pins stay above a newly focused application" ($hit -eq $sample) "hit=$hit pin=$sample"
  $topmostCount = @($pins | Where-Object { ((Get-ExStyle $_) -band 0x8) -ne 0 }).Count
  Check "every pin is still topmost after the app switch" ($topmostCount -eq $pins.Count) "topmost=${topmostCount}/$($pins.Count)"
  $notepad | Stop-Process -Force
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  if ($warmNotepad) { $warmNotepad | Stop-Process -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 300
  $log = Join-Path $env:LOCALAPPDATA "io.yuxino.kiri\logs\kiri.log"
  if (Test-Path $log) {
    Write-Host "`n--- pin log lines ---"
    Select-String -Path $log -Pattern "\[pin\]" | Select-Object -Last 15 | ForEach-Object { $_.Line }
  }
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Test, $_.Detail) }
  exit 1
}
exit 0
