# End-to-end: real global capture shortcut -> real toolbar Pin click -> native pin.
# Drives the built app with real Win32 input and asserts the native pin window.
# Not part of the product.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ShotE2E {
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
function Get-Pins {
  $found = @(); $previous = [IntPtr]::Zero
  while ($true) {
    $h = [ShotE2E]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Badges {
  $found = @(); $previous = [IntPtr]::Zero
  while ($true) {
    $h = [ShotE2E]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinBadge", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Rect($h) { $r = New-Object ShotE2E+RECT; [void][ShotE2E]::GetWindowRect($h, [ref]$r); return $r }
function Get-ExStyle($h) { return ([ShotE2E]::GetWindowLongPtr($h, -20)).ToInt64() }
function Get-Style($h) { return ([ShotE2E]::GetWindowLongPtr($h, -16)).ToInt64() }
function Wait-Pins([int]$count, [int]$timeoutMs = 20000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    $pins = Get-Pins
    if ($pins.Count -ge $count) { return $pins }
    Start-Sleep -Milliseconds 100
  }
  return (Get-Pins)
}
function Send-Mouse([uint32]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
  [ShotE2E]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}
function Send-Escape {
  [ShotE2E]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [ShotE2E]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
}
function Send-CaptureHotkey {
  [ShotE2E]::keybd_event(0x11, 0x1D, 0, [UIntPtr]::Zero)
  [ShotE2E]::keybd_event(0x10, 0x2A, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [ShotE2E]::keybd_event(0x41, 0x1E, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [ShotE2E]::keybd_event(0x41, 0x1E, 2, [UIntPtr]::Zero)
  [ShotE2E]::keybd_event(0x10, 0x2A, 2, [UIntPtr]::Zero)
  [ShotE2E]::keybd_event(0x11, 0x1D, 2, [UIntPtr]::Zero)
}
function Find-PinButton([int]$timeoutMs) {
  $output = node (Join-Path $PSScriptRoot "cdp-overlay-pin.mjs") 9333 $timeoutMs 2>&1
  $text = ($output | Out-String).Trim()
  Write-Host "  pin button probe: $text"
  try { return ($text | ConvertFrom-Json) } catch { return $null }
}

$notepad = $null
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9333"
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 5

  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1200
  $notepad.Refresh()
  [void][ShotE2E]::SetForegroundWindow($notepad.MainWindowHandle)
  Start-Sleep -Milliseconds 600
  $foregroundBefore = [ShotE2E]::GetForegroundWindow()
  $webviewsBefore = @(Get-Process msedgewebview2 -ErrorAction SilentlyContinue).Count

  # --- 1. real global capture shortcut -----------------------------------
  [void][ShotE2E]::SetCursorPos(600, 350)
  Start-Sleep -Milliseconds 200
  Send-CaptureHotkey
  $probe = Find-PinButton 6000
  $hotkeyWorked = $null -ne $probe -and $probe.overlays.Count -gt 0
  if (-not $hotkeyWorked) {
    $created = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
    if ($created) { $null = $created.WaitForExit(8000) }
  }
  Check "Ctrl+Shift+A opens the capture overlay" $hotkeyWorked ("overlays=" + (@($probe.overlays).Count))

  # --- 2. real region drag ------------------------------------------------
  $selection = @{ x = 600; y = 350; width = 400; height = 400 }
  Start-Sleep -Milliseconds 900
  [void][ShotE2E]::SetCursorPos($selection.x, $selection.y)
  Start-Sleep -Milliseconds 200
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 120
  foreach ($step in 1..10) {
    [void][ShotE2E]::SetCursorPos(
      $selection.x + [int]($selection.width * $step / 10),
      $selection.y + [int]($selection.height * $step / 10))
    Send-Mouse 0x0001
    Start-Sleep -Milliseconds 45
  }
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 900

  # --- 3. locate and click the real toolbar Pin button -------------------
  $button = Find-PinButton 12000
  $found = $null -ne $button -and $button.found -eq $true
  Check "the annotation toolbar exposes the Pin button" $found ($(if ($found) { "label=$($button.label)" } else { "probe=$($button | ConvertTo-Json -Compress)" }))
  if (-not $found) { throw "Pin button not found; cannot continue the screenshot -> pin flow" }

  $dpr = if ($button.dpr) { $button.dpr } else { 1 }
  $clickX = [int]($button.screenX + ($button.rect.x + $button.rect.width / 2) * $dpr)
  $clickY = [int]($button.screenY + ($button.rect.y + $button.rect.height / 2) * $dpr)
  [void][ShotE2E]::SetCursorPos($clickX, $clickY)
  Start-Sleep -Milliseconds 250
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 80
  Send-Mouse 0x0004
  $pins = Wait-Pins 1 15000
  $realClick = $pins.Count -eq 1
  Check "a real click on the Pin button creates the pin" $realClick "pins=$($pins.Count) click=$clickX,$clickY"
  if (-not $realClick) { throw "the toolbar click did not create a pin" }

  # --- 4. the pin matches the captured rectangle -------------------------
  $pin = $pins[0]
  $rect = Get-Rect $pin
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  Check "the pin matches the captured rectangle" (
    [math]::Abs($rect.Left - $selection.x) -le 2 -and
    [math]::Abs($rect.Top - $selection.y) -le 2 -and
    [math]::Abs($width - $selection.width) -le 2 -and
    [math]::Abs($height - $selection.height) -le 2
  ) "pin=$($rect.Left),$($rect.Top) ${width}x${height}"
  Check "the pin is visible" ([ShotE2E]::IsWindowVisible($pin))

  $style = Get-Style $pin
  $ex = Get-ExStyle $pin
  Check "the pin is borderless" ((($style -band 0x00C00000) -eq 0) -and (($style -band 0x00040000) -eq 0)) ("style=0x{0:X}" -f $style)
  Check "the pin is layered (per-pixel alpha)" ((($ex -band 0x00080000) -ne 0)) ("ex=0x{0:X}" -f $ex)
  Check "the pin is topmost" ((($ex -band 0x00000008) -ne 0)) ("ex=0x{0:X}" -f $ex)
  Check "the pin never activates (no focus steal)" ((($ex -band 0x08000000) -ne 0)) ("ex=0x{0:X}" -f $ex)
  $affinity = 0
  [void][ShotE2E]::GetWindowDisplayAffinity($pin, [ref]$affinity)
  Check "the pin is excluded from Kiri's own screenshots" ($affinity -eq 0x11) ("affinity=0x{0:X}" -f $affinity)

  $webviewsAfter = @(Get-Process msedgewebview2 -ErrorAction SilentlyContinue).Count
  Check "a pin adds no WebView process" ($webviewsAfter -eq $webviewsBefore) "before=$webviewsBefore after=$webviewsAfter"

  # --- 5. focus and stacking ---------------------------------------------
  $cx = [int](($rect.Left + $rect.Right) / 2)
  $cy = [int](($rect.Top + $rect.Bottom) / 2)
  [void][ShotE2E]::SetCursorPos($cx, $cy)
  Start-Sleep -Milliseconds 300
  Check "the capture returns focus to the original app" ([ShotE2E]::GetForegroundWindow() -eq $foregroundBefore) ("fg=$([ShotE2E]::GetForegroundWindow()) expected=$foregroundBefore")
  $hit = [ShotE2E]::WindowFromPoint((New-Object ShotE2E+POINT($cx, $cy)))
  Check "the pin is above everything under the pointer" ($hit -eq $pin) "hit=$hit pin=$pin"

  # --- 6. wheel zoom and the percentage badge ----------------------------
  $before = Get-Rect $pin
  $w0 = $before.Right - $before.Left
  $h0 = $before.Bottom - $before.Top
  Send-Mouse 0x0800 0 0 120
  Start-Sleep -Milliseconds 700
  $after = Get-Rect $pin
  $w1 = $after.Right - $after.Left
  $h1 = $after.Bottom - $after.Top
  Check "wheel up enlarges the hovered pin" ($w1 -gt $w0) "width $w0 -> $w1"
  Check "zoom keeps the image aspect ratio" ([math]::Abs(($w1 / $h1) - ($w0 / $h0)) -lt 0.02) "ratio $([math]::Round($w1 / $h1,4)) vs $([math]::Round($w0 / $h0,4))"

  $badges = @(Get-Badges | Where-Object { [ShotE2E]::IsWindowVisible($_) })
  Check "the zoom percentage badge is shown" ($badges.Count -ge 1) "visible=$($badges.Count)"
  if ($badges.Count -ge 1) {
    $badgeRect = Get-Rect $badges[0]
    $inside = ($badgeRect.Left -ge $after.Left) -and ($badgeRect.Top -ge $after.Top) -and
      ($badgeRect.Right -le $after.Right) -and ($badgeRect.Bottom -le $after.Bottom)
    Check "the badge sits inside the pin frame" $inside "badge=$($badgeRect.Left),$($badgeRect.Top) pin=$($after.Left),$($after.Top)"
  }
  Start-Sleep -Milliseconds 1300
  Check "the badge hides after the scroll stops" (@(Get-Badges | Where-Object { [ShotE2E]::IsWindowVisible($_) }).Count -eq 0)
  [uint32]$wheelDown = 4294967176
  Send-Mouse 0x0800 0 0 $wheelDown
  Start-Sleep -Milliseconds 600
  $restored = Get-Rect $pin
  Check "wheel down restores the previous size" ([math]::Abs(($restored.Right - $restored.Left) - $w0) -le 2) "width=$($restored.Right - $restored.Left) expected=$w0"

  # --- 7. drag the pinned image -----------------------------------------
  $beforeDrag = Get-Rect $pin
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 60
  foreach ($step in @(@(40, 30), @(80, 60), @(120, 90))) {
    [void][ShotE2E]::SetCursorPos($cx + $step[0], $cy + $step[1])
    Send-Mouse 0x0001
    Start-Sleep -Milliseconds 45
  }
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 400
  $afterDrag = Get-Rect $pin
  Check "dragging moves the pinned image" (
    ($afterDrag.Left - $beforeDrag.Left -eq 120) -and ($afterDrag.Top - $beforeDrag.Top -eq 90)
  ) "delta=$($afterDrag.Left - $beforeDrag.Left),$($afterDrag.Top - $beforeDrag.Top)"

  # --- 8. Escape closes only the pin under the pointer -------------------
  $pinRect = Get-Rect $pin
  [void][ShotE2E]::SetCursorPos([int](($pinRect.Left + $pinRect.Right) / 2), [int](($pinRect.Top + $pinRect.Bottom) / 2))
  Start-Sleep -Milliseconds 250
  Send-Escape
  Start-Sleep -Milliseconds 700
  Check "Escape closes the pin under the pointer" ((Get-Pins).Count -eq 0) "remaining=$((Get-Pins).Count)"
  Check "Escape leaves the foreground app alone" ([ShotE2E]::GetForegroundWindow() -eq $foregroundBefore)
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  if ($notepad) { $notepad | Stop-Process -Force -ErrorAction SilentlyContinue }
  Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
  $log = Join-Path $env:LOCALAPPDATA "io.yuxino.kiri\logs\kiri.log"
  if (Test-Path $log) {
    Write-Host "`n--- pin log lines ---"
    Select-String -Path $log -Pattern "\[pin\]" | Select-Object -Last 12 | ForEach-Object { $_.Line }
  }
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Test, $_.Detail) }
  exit 1
}
exit 0
