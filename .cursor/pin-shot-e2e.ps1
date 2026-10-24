# End-to-end check for the screenshot -> Pin flow on Windows.
# Drives the real capture overlay with Win32 input, clicks the real toolbar
# Pin button through the WebView CDP target, then asserts the native pin.
# Not part of the product; the temporary CDP port exists only for this run.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ShotNative {
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
    $h = [ShotNative]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Rect($h) { $r = New-Object ShotNative+RECT; [void][ShotNative]::GetWindowRect($h, [ref]$r); return $r }
function Wait-Pins([int]$count, [int]$timeoutMs = 20000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    $pins = Get-Pins
    if ($pins.Count -ge $count) { return $pins }
    Start-Sleep -Milliseconds 100
  }
  return (Get-Pins)
}
function Wait-OverlayTarget([int]$timeoutMs = 20000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    try {
      $pages = Invoke-RestMethod "http://127.0.0.1:9333/json" -TimeoutSec 2
      $overlay = @($pages | Where-Object { $_.type -eq "page" -and $_.url -match "[?&]window=overlay" })
      if ($overlay.Count -gt 0) { return $overlay[0] }
    } catch { }
    Start-Sleep -Milliseconds 150
  }
  return $null
}
function Send-Mouse([uint32]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
  [ShotNative]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}

$notepad = $null
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9333"
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 4

  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1200
  $notepad.Refresh()
  [void][ShotNative]::SetForegroundWindow($notepad.MainWindowHandle)
  Start-Sleep -Milliseconds 500
  $foregroundBefore = [ShotNative]::GetForegroundWindow()

  # --- 1. capture a real region ------------------------------------------
  $created = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
  if ($created) { $null = $created.WaitForExit(8000) }
  $overlay = Wait-OverlayTarget
  Check "the capture overlay opens" ($null -ne $overlay) "target=$($overlay.title)"
  if ($null -eq $overlay) { throw "no overlay target" }
  Start-Sleep -Milliseconds 900

  $selection = @{ x = 600; y = 350; width = 400; height = 400 }
  [void][ShotNative]::SetCursorPos($selection.x, $selection.y)
  Start-Sleep -Milliseconds 150
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 100
  foreach ($step in 1..10) {
    [void][ShotNative]::SetCursorPos(
      $selection.x + [int]($selection.width * $step / 10),
      $selection.y + [int]($selection.height * $step / 10))
    Send-Mouse 0x0001
    Start-Sleep -Milliseconds 40
  }
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 700

  # --- 2. click the real toolbar Pin button ------------------------------
  $click = node (Join-Path $PSScriptRoot "cdp-pin-click.mjs") 9333 2>&1
  $clickText = ($click | Out-String).Trim()
  Write-Host "pin click: $clickText"
  Check "the toolbar Pin button was clicked" ($clickText -match '"ok":true') $clickText

  # --- 3. the native pin lands on the captured rectangle ------------------
  $pins = Wait-Pins 1
  Check "screenshot creates one native pin" ($pins.Count -eq 1) "count=$($pins.Count)"
  if ($pins.Count -gt 0) {
    $pin = $pins[0]
    $rect = Get-Rect $pin
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    Check "pin matches the captured rectangle" (
      [math]::Abs($rect.Left - $selection.x) -le 2 -and
      [math]::Abs($rect.Top - $selection.y) -le 2 -and
      [math]::Abs($width - $selection.width) -le 2 -and
      [math]::Abs($height - $selection.height) -le 2
    ) "pin=$($rect.Left),$($rect.Top) ${width}x${height}"
    Check "pin is visible" ([ShotNative]::IsWindowVisible($pin))

    # --- 4. focus returns to the original application --------------------
    [void][ShotNative]::SetCursorPos($selection.x + 200, $selection.y + 200)
    Start-Sleep -Milliseconds 250
    Check "the pin does not change the foreground window" ([ShotNative]::GetForegroundWindow() -eq $foregroundBefore) (
      "fg=$([ShotNative]::GetForegroundWindow()) expected=$foregroundBefore")
    $hit = [ShotNative]::WindowFromPoint([ShotNative+POINT]::new($selection.x + 200, $selection.y + 200))
    Check "the pin is above the application under the pointer" ($hit -eq $pin) "hit=$hit pin=$pin"

    # --- 5. Escape closes only that pin ---------------------------------
    [void][ShotNative]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [void][ShotNative]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    Check "Escape closes the screenshot pin" ((Get-Pins).Count -eq 0) "remaining=$((Get-Pins).Count)"
    Check "Escape leaves the foreground application alone" ([ShotNative]::GetForegroundWindow() -eq $foregroundBefore)
  }
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
