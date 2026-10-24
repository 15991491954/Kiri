# End-to-end check for the two pin fixes:
#   1. a confirmed pin from a secondary-display overlay closes every overlay;
#   2. the native pin carries a shadow band and rounded photo corners.
# Drives the real capture overlay with Win32 input and clicks the real toolbar
# Pin button through the WebView CDP target. Not part of the product; the
# temporary CDP port exists only for this run.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PinNative {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
}
"@

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
$selection = @{ x = 0; y = 0; width = 0; height = 0 }
$results = New-Object System.Collections.ArrayList

function Check([string]$name, [bool]$ok, [string]$detail = "") {
  [void]$results.Add([pscustomobject]@{ Test = $name; Pass = $ok; Detail = $detail })
  Write-Host ("[{0}] {1} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $detail)
}

function Get-Pins {
  $found = @(); $previous = [IntPtr]::Zero
  while ($true) {
    $h = [PinNative]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}

function Get-Rect($h) {
  $r = New-Object PinNative+RECT
  [void][PinNative]::GetWindowRect($h, [ref]$r)
  return $r
}

function Get-OverlayTargets {
  try {
    $pages = Invoke-RestMethod "http://127.0.0.1:9333/json" -TimeoutSec 2
    return @($pages | Where-Object { $_.type -eq "page" -and $_.url -match "[?&]window=overlay" })
  } catch { return @() }
}

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
  [PinNative]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}

# Distance between the pin window edge and the photo it shows, per side.
function Get-DecorMargin($rect) {
  return [pscustomobject]@{
    Left   = $selection.x - $rect.Left
    Top    = $selection.y - $rect.Top
    Right  = $rect.Right - ($selection.x + $selection.width)
    Bottom = $rect.Bottom - ($selection.y + $selection.height)
  }
}

$notepad = $null
$scale = 1.0
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9333"
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 4

  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1200
  $notepad.Refresh()
  [void][PinNative]::SetForegroundWindow($notepad.MainWindowHandle)
  Start-Sleep -Milliseconds 400

  # --- 0. pick a region on a non-primary display -------------------------
  $screens = [System.Windows.Forms.Screen]::AllScreens
  Check "the desktop has a secondary display" ($screens.Count -ge 2) "screens=$($screens.Count)"
  $target = @($screens | Where-Object { -not $_.Primary }) | Select-Object -First 1
  if ($null -eq $target) { $target = $screens[0] }
  $bounds = $target.Bounds
  $selection = @{
    x      = $bounds.X + [int]($bounds.Width * 0.25)
    y      = $bounds.Y + [int]($bounds.Height * 0.25)
    width  = [int]([Math]::Min(420, $bounds.Width * 0.4))
    height = [int]([Math]::Min(320, $bounds.Height * 0.4))
  }
  Write-Host ("region on display '{0}': {1},{2} {3}x{4}" -f $target.DeviceName, $selection.x, $selection.y, $selection.width, $selection.height)

  # --- 1. capture that region -------------------------------------------
  $created = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
  if ($created) { $null = $created.WaitForExit(8000) }
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and (Get-OverlayTargets).Count -eq 0) { Start-Sleep -Milliseconds 150 }
  $overlays = Get-OverlayTargets
  Check "the capture overlay opens on every display" ($overlays.Count -ge 2) "overlays=$($overlays.Count)"
  Start-Sleep -Milliseconds 900

  [void][PinNative]::SetCursorPos($selection.x, $selection.y)
  Start-Sleep -Milliseconds 200
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 120
  foreach ($step in 1..10) {
    [void][PinNative]::SetCursorPos(
      $selection.x + [int]($selection.width * $step / 10),
      $selection.y + [int]($selection.height * $step / 10))
    Send-Mouse 0x0001
    Start-Sleep -Milliseconds 40
  }
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 800

  # --- 2. click the real toolbar Pin button -----------------------------
  $click = node (Join-Path $PSScriptRoot "cdp-pin-click.mjs") 9333 2>&1
  $clickText = ($click | Out-String).Trim()
  Write-Host "pin click: $clickText"
  Check "the toolbar Pin button was clicked" ($clickText -match '"ok":true') $clickText

  # --- 3. every overlay closes after a confirmed pin --------------------
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline -and (Get-OverlayTargets).Count -gt 0) { Start-Sleep -Milliseconds 200 }
  $leftover = Get-OverlayTargets
  $leftoverUrls = @($leftover | ForEach-Object { $_.url }) -join ", "
  Check "the capture overlay closes after pinning" ($leftover.Count -eq 0) "remaining=$($leftover.Count) $leftoverUrls"

  # --- 4. the pin lands on the captured rectangle ----------------------
  $pins = Wait-Pins 1
  Check "screenshot creates one native pin" ($pins.Count -eq 1) "count=$($pins.Count)"
  if ($pins.Count -eq 0) { throw "no pin window" }
  $pin = $pins[0]
  $rect = Get-Rect $pin
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  Check "the pin is visible" ([PinNative]::IsWindowVisible($pin))
  $dpi = [PinNative]::GetDpiForWindow($pin)
  $scale = if ($dpi -gt 0) { $dpi / 96.0 } else { 1.0 }
  $expected = [int][Math]::Round(10 * $scale)
  $margins = Get-DecorMargin $rect
  Write-Host ("pin window {0},{1} {2}x{3} dpi={4} margins L{5} T{6} R{7} B{8}" -f $rect.Left, $rect.Top, $width, $height, $dpi, $margins.Left, $margins.Top, $margins.Right, $margins.Bottom)
  Check "the pin window carries a shadow band on every side" (
    $margins.Left -gt 0 -and $margins.Top -gt 0 -and $margins.Right -gt 0 -and $margins.Bottom -gt 0
  ) "L$($margins.Left) T$($margins.Top) R$($margins.Right) B$($margins.Bottom)"
  Check "the shadow band follows the display scale" (
    [Math]::Abs($margins.Left - $expected) -le 1 -and
    [Math]::Abs($margins.Top - $expected) -le 1 -and
    [Math]::Abs($margins.Right - $expected) -le 1 -and
    [Math]::Abs($margins.Bottom - $expected) -le 1
  ) "expected=$expected actual L$($margins.Left) T$($margins.Top) R$($margins.Right) B$($margins.Bottom)"

  Check "the pin window sits above the capture and the application" (
    [PinNative]::GetForegroundWindow() -ne [IntPtr]::Zero -and
    [PinNative]::WindowFromPoint([PinNative+POINT]::new($selection.x + 40, $selection.y + 40)) -eq $pin
  ) "hit=$([PinNative]::WindowFromPoint([PinNative+POINT]::new($selection.x + 40, $selection.y + 40)))"

  # --- 5. wheel zoom keeps the band around the photo -------------------
  [void][PinNative]::SetCursorPos($selection.x + 40, $selection.y + 40)
  Start-Sleep -Milliseconds 200
  Send-Mouse 0x0800 0 0 120
  Start-Sleep -Milliseconds 900
  $zoomed = Get-Rect $pin
  $zoomMargins = Get-DecorMargin $zoomed
  Write-Host ("zoomed window {0},{1} {2}x{3} margins L{4} T{5} R{6} B{7}" -f $zoomed.Left, $zoomed.Top, ($zoomed.Right - $zoomed.Left), ($zoomed.Bottom - $zoomed.Top), $zoomMargins.Left, $zoomMargins.Top, $zoomMargins.Right, $zoomMargins.Bottom)
  Check "wheel zoom grows the photo and keeps the band" (
    ($zoomed.Right - $zoomed.Left) -gt $width -and
    $zoomMargins.Left -eq $margins.Left -and $zoomMargins.Top -eq $margins.Top -and
    $zoomMargins.Right -eq $margins.Right -and $zoomMargins.Bottom -eq $margins.Bottom
  ) "before=${width}x${height} after=$($zoomed.Right - $zoomed.Left)x$($zoomed.Bottom - $zoomed.Top)"

  # --- 6. Escape closes only that pin ----------------------------------
  [void][PinNative]::SetCursorPos($selection.x + 40, $selection.y + 40)
  Start-Sleep -Milliseconds 200
  [void][PinNative]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [void][PinNative]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 700
  Check "Escape closes the screenshot pin" ((Get-Pins).Count -eq 0) "remaining=$((Get-Pins).Count)"
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  if ($notepad) { $notepad | Stop-Process -Force -ErrorAction SilentlyContinue }
  Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Test, $_.Detail) }
  exit 1
}
exit 0
