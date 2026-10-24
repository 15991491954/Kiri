# End-to-end check for Kiri native pin windows (Windows).
# Runs the real built app, drives the clipboard and real Win32 input, then
# asserts the pin window state. Cleans up the Kiri process it started.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Native {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder sb, int max);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
}
"@

$exe = Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe"
if (-not (Test-Path $exe)) { throw "Build the app first: $exe" }
$exe = (Resolve-Path $exe).Path

$results = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = "") {
  [void]$results.Add([pscustomobject]@{ Test = $name; Pass = $ok; Detail = $detail })
  $mark = if ($ok) { "PASS" } else { "FAIL" }
  Write-Host ("[{0}] {1} {2}" -f $mark, $name, $detail)
}

function Get-WindowsByClass([string]$cls) {
  $found = @()
  $previous = [IntPtr]::Zero
  while ($true) {
    $h = [Native]::FindWindowEx([IntPtr]::Zero, $previous, $cls, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h
    $previous = $h
  }
  return $found
}

function Get-Pins { return @(Get-WindowsByClass "KiriPinWindow") }
function Get-Badges { return @(Get-WindowsByClass "KiriPinBadge") }
function Get-Rect($h) { $r = New-Object Native+RECT; [void][Native]::GetWindowRect($h, [ref]$r); return $r }
function Get-Style($h) { return ([Native]::GetWindowLongPtr($h, -16)).ToInt64() }
function Get-ExStyle($h) { return ([Native]::GetWindowLongPtr($h, -20)).ToInt64() }

function Wait-Pins([int]$count, [int]$timeoutMs = 15000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    $pins = Get-Pins
    if ($pins.Count -ge $count) { return $pins }
    Start-Sleep -Milliseconds 100
  }
  return (Get-Pins)
}

function Invoke-PastePin {
  $alreadyRunning = @(Get-Process -Name kiri -ErrorAction SilentlyContinue).Count -gt 0
  $process = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
  if ($alreadyRunning) {
    # The second process hands the flag to the running instance and exits.
    $null = $process.WaitForExit(8000)
    Start-Sleep -Milliseconds 300
  }
}

function Set-ClipboardImage([int]$width, [int]$height, [System.Drawing.Color]$colour) {
  $bitmap = New-Object System.Drawing.Bitmap($width, $height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear($colour)
  $graphics.FillEllipse([System.Drawing.Brushes]::White, 10, 10, 60, 60)
  $graphics.Dispose()
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
  $bitmap.Dispose()
  Start-Sleep -Milliseconds 250
}

function Send-Escape {
  [Native]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [Native]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
}

function Send-Mouse([uint32]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
  [Native]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}

try {
  Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 400

  # Warm start: creating the hidden library window during app startup is what
  # may move the foreground on a cold launch. That is not a pin action, so the
  # focus assertions below must measure an already-running Kiri with an
  # unrelated application in front, which is the real F3 flow.
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 4
  $warmNotepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1500
  $warmNotepad.Refresh()
  [void][Native]::SetForegroundWindow($warmNotepad.MainWindowHandle)
  Start-Sleep -Milliseconds 400

  # --- 1. clipboard image -> F3 pin ---------------------------------------
  Set-ClipboardImage 400 300 ([System.Drawing.Color]::FromArgb(30, 90, 200))
  $foregroundBefore = [Native]::GetForegroundWindow()
  Invoke-PastePin
  $pins = Wait-Pins 1 40000
  Check "clipboard image creates one pin" ($pins.Count -eq 1) "count=$($pins.Count)"
  if ($pins.Count -eq 0) { throw "no pin appeared; check %LOCALAPPDATA%\io.yuxino.kiri\logs\kiri.log" }

  $pin = $pins[0]
  $rect = Get-Rect $pin
  $pinWidth = $rect.Right - $rect.Left
  $pinHeight = $rect.Bottom - $rect.Top
  Check "pin opens at the image scale" (($pinWidth -eq 400) -and ($pinHeight -eq 300)) "size=${pinWidth}x${pinHeight}"
  Check "pin window is visible" ([Native]::IsWindowVisible($pin))

  $style = Get-Style $pin
  $ex = Get-ExStyle $pin
  $noBorder = (($style -band 0x00C00000) -eq 0) -and (($style -band 0x00040000) -eq 0)
  Check "pin has no border" $noBorder ("style=0x{0:X}" -f $style)
  Check "pin is layered" (($ex -band 0x00080000) -ne 0) ("ex=0x{0:X}" -f $ex)
  Check "pin is topmost" (($ex -band 0x00000008) -ne 0) ("ex=0x{0:X}" -f $ex)
  Check "pin is a tool window" (($ex -band 0x00000080) -ne 0) ("ex=0x{0:X}" -f $ex)
  Check "pin does not activate" (($ex -band 0x08000000) -ne 0) ("ex=0x{0:X}" -f $ex)
  Check "paste does not change the foreground window" ([Native]::GetForegroundWindow() -eq $foregroundBefore)

  $centerX = [int](($rect.Left + $rect.Right) / 2)
  $centerY = [int](($rect.Top + $rect.Bottom) / 2)
  [void][Native]::SetCursorPos($centerX, $centerY)
  Start-Sleep -Milliseconds 150
  $hit = [Native]::WindowFromPoint((New-Object Native+POINT($centerX, $centerY)))
  Check "pin is above everything under the pointer" ($hit -eq $pin) "hit=$hit"

  # --- 2. drag the image ------------------------------------------------
  $before = Get-Rect $pin
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 60
  foreach ($step in @(@(40, 30), @(80, 60), @(120, 90))) {
    [void][Native]::SetCursorPos($centerX + $step[0], $centerY + $step[1])
    Send-Mouse 0x0001
    Start-Sleep -Milliseconds 40
  }
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 400
  $after = Get-Rect $pin
  $deltaX = $after.Left - $before.Left
  $deltaY = $after.Top - $before.Top
  Check "dragging the image moves the window" (($deltaX -eq 120) -and ($deltaY -eq 90)) "delta=${deltaX},${deltaY}"

  # --- 3. wheel zoom and percentage badge -------------------------------
  $before = Get-Rect $pin
  $centerX = [int](($before.Left + $before.Right) / 2)
  $centerY = [int](($before.Top + $before.Bottom) / 2)
  [void][Native]::SetCursorPos($centerX, $centerY)
  Start-Sleep -Milliseconds 120
  Send-Mouse 0x0800 0 0 120
  Start-Sleep -Milliseconds 700
  $after = Get-Rect $pin
  $w0 = $before.Right - $before.Left
  $h0 = $before.Bottom - $before.Top
  $w1 = $after.Right - $after.Left
  $h1 = $after.Bottom - $after.Top
  Check "wheel up enlarges the hovered pin" ($w1 -gt $w0) "width $w0 -> $w1"
  $ratioBefore = $w0 / $h0
  $ratioAfter = $w1 / $h1
  Check "zoom keeps the image aspect ratio" ([math]::Abs($ratioAfter - $ratioBefore) -lt 0.02) "ratio $([math]::Round($ratioAfter,4)) vs $([math]::Round($ratioBefore,4))"

  $badges = @(Get-Badges | Where-Object { [Native]::IsWindowVisible($_) })
  Check "zoom shows the percentage badge" ($badges.Count -ge 1) "visible=$($badges.Count)"
  if ($badges.Count -ge 1) {
    $badge = $badges[0]
    $badgeRect = Get-Rect $badge
    $badgeEx = Get-ExStyle $badge
    $badgeTopmost = (($badgeEx -band 0x00000008) -ne 0) -and (($badgeEx -band 0x00000020) -ne 0)
    Check "badge is topmost and click-through" $badgeTopmost ("ex=0x{0:X}" -f $badgeEx)
    $inside = ($badgeRect.Left -ge $after.Left) -and ($badgeRect.Top -ge $after.Top) -and
      ($badgeRect.Right -le $after.Right) -and ($badgeRect.Bottom -le $after.Bottom)
    Check "badge sits inside the pin frame" $inside "badge=$($badgeRect.Left),$($badgeRect.Top) pin=$($after.Left),$($after.Top)"
  }
  Start-Sleep -Milliseconds 1300
  $badgesAfter = @(Get-Badges | Where-Object { [Native]::IsWindowVisible($_) })
  Check "badge hides after the scroll stops" ($badgesAfter.Count -eq 0) "visible=$($badgesAfter.Count)"

  [uint32]$wheelDown = 4294967176
  Send-Mouse 0x0800 0 0 $wheelDown
  Start-Sleep -Milliseconds 600
  $restored = Get-Rect $pin
  $restoredWidth = $restored.Right - $restored.Left
  Check "wheel down restores the previous size" ([math]::Abs($restoredWidth - $w0) -le 2) "width=${restoredWidth} expected=${w0}"

  # --- 4. second pin, siblings and Escape -------------------------------
  Set-ClipboardImage 260 180 ([System.Drawing.Color]::FromArgb(200, 120, 30))
  Invoke-PastePin
  $pins = Wait-Pins 2
  Check "a second paste creates an independent pin" ($pins.Count -eq 2) "count=$($pins.Count)"
  $topmostCount = @($pins | Where-Object { ((Get-ExStyle $_) -band 0x8) -ne 0 }).Count
  Check "both pins stay topmost" ($topmostCount -eq 2) "topmost=${topmostCount}/$($pins.Count)"

  Set-ClipboardImage 200 200 ([System.Drawing.Color]::FromArgb(20, 160, 90))
  Invoke-PastePin
  $pins = Wait-Pins 3
  Check "a third pin opens" ($pins.Count -eq 3) "count=$($pins.Count)"

  $target = $pins[0]
  $targetRect = Get-Rect $target
  [void][Native]::SetCursorPos([int](($targetRect.Left + $targetRect.Right) / 2), [int](($targetRect.Top + $targetRect.Bottom) / 2))
  Start-Sleep -Milliseconds 150
  $foregroundBeforeEscape = [Native]::GetForegroundWindow()
  Send-Escape
  Start-Sleep -Milliseconds 600
  $remaining = Get-Pins
  $escaped = ($remaining.Count -eq 2) -and (-not ($remaining -contains $target))
  Check "Escape closes only the pin under the pointer" $escaped "remaining=$($remaining.Count) targetAlive=$([Native]::IsWindow($target))"

  # --- 5. keyboard focus is untouched -----------------------------------
  Check "closing a pin does not change the foreground window" ([Native]::GetForegroundWindow() -eq $foregroundBeforeEscape)

  # --- 6. text clipboard ------------------------------------------------
  [System.Windows.Forms.Clipboard]::SetText("Kiri pin text`r`n第二行：中文排版测试`r`nhttps://example.com/a/very/long/url/that/must/wrap/inside/the/card")
  Start-Sleep -Milliseconds 250
  Invoke-PastePin
  $pins = Wait-Pins 3
  Check "clipboard text becomes a pin card" ($pins.Count -eq 3) "count=$($pins.Count)"

  # --- 7. copied image file ---------------------------------------------
  $temp = Join-Path $env:TEMP ("kiri-pin-e2e-{0}.png" -f ([guid]::NewGuid()))
  $bitmap = New-Object System.Drawing.Bitmap(240, 160)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(120, 40, 200))
  $graphics.Dispose()
  $bitmap.Save($temp, [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
  $files = New-Object System.Collections.Specialized.StringCollection
  [void]$files.Add($temp)
  [System.Windows.Forms.Clipboard]::SetFileDropList($files)
  Start-Sleep -Milliseconds 250
  Invoke-PastePin
  $pins = Wait-Pins 4
  Check "a copied image file becomes a pin" ($pins.Count -eq 4) "count=$($pins.Count)"
  Remove-Item $temp -Force -ErrorAction SilentlyContinue

  # --- 8. pins stay above another foreground application ----------------
  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 900
  $pins = Get-Pins
  $sample = $pins[0]
  $sampleRect = Get-Rect $sample
  $sampleX = [int](($sampleRect.Left + $sampleRect.Right) / 2)
  $sampleY = [int](($sampleRect.Top + $sampleRect.Bottom) / 2)
  $hit = [Native]::WindowFromPoint((New-Object Native+POINT($sampleX, $sampleY)))
  Check "pins remain above a newly focused application" ($hit -eq $sample) "hit=$hit pin=$sample"
  $topmostCount = @($pins | Where-Object { ((Get-ExStyle $_) -band 0x8) -ne 0 }).Count
  Check "every pin is still topmost after the app switch" ($topmostCount -eq $pins.Count) "topmost=${topmostCount}/$($pins.Count)"
  $notepad | Stop-Process -Force
}
finally {
  Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  if ($warmNotepad) { $warmNotepad | Stop-Process -Force }
  Start-Sleep -Milliseconds 300
  $log = Join-Path $env:LOCALAPPDATA "io.yuxino.kiri\logs\kiri.log"
  if (Test-Path $log) {
    Write-Host "`n--- pin log lines ---"
    Select-String -Path $log -Pattern "\[pin\]" | Select-Object -Last 20 | ForEach-Object { $_.Line }
  }
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
  Write-Host "Failed checks:"
  $failed | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Test, $_.Detail) }
  exit 1
}
exit 0
