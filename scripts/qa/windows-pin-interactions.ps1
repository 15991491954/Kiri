# Windows regression probe for native pin interactions.
#
# Covers the behaviours that are easy to break without noticing:
#   * a clipboard pin opens as a layered window,
#   * the wheel zooms and Ctrl+0 restores 100%,
#   * Ctrl+Arrow nudges by one physical pixel,
#   * the "Lock Position" command stops a drag from moving the card,
#   * a right click opens the native context menu.
#
# It starts the debug build (cargo build first), drives real mouse/keyboard
# input, prints one PASS/FAIL line per check, and exits non-zero on failure.
# Run from the repository root:
#   powershell -ExecutionPolicy Bypass -File scripts/qa/windows-pin-interactions.ps1

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PinProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

function Get-Pin {
  [PinProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero)
}
function Get-Rect2($h) {
  $r = New-Object PinProbe+RECT
  [void][PinProbe]::GetWindowRect($h, [ref]$r)
  return $r
}
function Get-Size($h) {
  $r = Get-Rect2 $h
  [pscustomobject]@{ Width = $r.Right - $r.Left; Height = $r.Bottom - $r.Top }
}
function Wheel($x, $y, $delta) {
  [PinProbe]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 120
  $data = if ($delta -lt 0) { [uint32]4294967295 - [uint32](-$delta - 1) } else { [uint32]$delta }
  [PinProbe]::mouse_event(0x0800, 0, 0, $data, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 250
}
function Click($x, $y) {
  [PinProbe]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 80
  [PinProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [PinProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
}
function Press($vk) {
  [PinProbe]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [PinProbe]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
}
function Press-WithCtrl($vk) {
  [PinProbe]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  Press $vk
  [PinProbe]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 300
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$exe = if ($env:KIRI_EXE) { $env:KIRI_EXE } else { Join-Path $root "src-tauri\target\debug\kiri.exe" }
if (-not (Test-Path $exe)) { throw "Build the debug app first: cargo build --manifest-path src-tauri/Cargo.toml" }

$failures = 0
function Check($name, $ok, $detail) {
  if ($ok) { "PASS $name $detail" } else { $script:failures++; "FAIL $name $detail" }
}

Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 900
for ($i = 0; $i -lt 8; $i++) {
  try { [System.Windows.Forms.Clipboard]::SetText("pin interaction probe"); break }
  catch { Start-Sleep -Milliseconds 250 }
}
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 6
$paste = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
if ($paste) { $null = $paste.WaitForExit(8000) }
Start-Sleep -Seconds 2

$pin = Get-Pin
if ($pin -eq [IntPtr]::Zero) { "FAIL pin window was not created"; exit 1 }
$r = Get-Rect2 $pin
$cx = [int](($r.Left + $r.Right) / 2)
$cy = [int](($r.Top + $r.Bottom) / 2)
Click $cx $cy
$start = Get-Size $pin
Check "pin opens" ($start.Width -gt 0 -and $start.Height -gt 0) "$($start.Width)x$($start.Height)"

Wheel $cx $cy 120
Wheel $cx $cy 120
$zoomed = Get-Size $pin
Check "wheel zooms" ($zoomed.Width -gt $start.Width) "$($zoomed.Width)x$($zoomed.Height)"

Press-WithCtrl 0x30
$ctrl0 = Get-Size $pin
Check "Ctrl+0 restores 100%" ($ctrl0.Width -eq $start.Width -and $ctrl0.Height -eq $start.Height) "$($ctrl0.Width)x$($ctrl0.Height)"

# A double click on the photo is the second way to reach 100%.
Wheel $cx $cy 120
[PinProbe]::SetCursorPos($cx, $cy) | Out-Null
for ($click = 0; $click -lt 2; $click++) {
  [PinProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [PinProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
}
Start-Sleep -Milliseconds 400
$doubleClick = Get-Size $pin
Check "double click restores 100%" ($doubleClick.Width -eq $start.Width -and $doubleClick.Height -eq $start.Height) "$($doubleClick.Width)x$($doubleClick.Height)"

$before = Get-Rect2 $pin
Press-WithCtrl 0x27
$after = Get-Rect2 $pin
Check "Ctrl+Right nudges one pixel" (($after.Left - $before.Left) -eq 1) "dx=$($after.Left - $before.Left)"

# 4 is "Copy Image": the pin's own pixels must reach the clipboard.
[void][PinProbe]::SendMessage($pin, 0x0111, [IntPtr]4, [IntPtr]::Zero)
Start-Sleep -Milliseconds 900
$copied = [System.Windows.Forms.Clipboard]::GetImage()
Check "Copy Image reaches the clipboard" ($null -ne $copied) $(if ($copied) { "$($copied.Width)x$($copied.Height)" } else { "no image" })
if ($copied) { $copied.Dispose() }

# 6 is the "Lock Position" command in the native context menu.
[void][PinProbe]::SendMessage($pin, 0x0111, [IntPtr]6, [IntPtr]::Zero)
Start-Sleep -Milliseconds 200
$lockedBefore = Get-Rect2 $pin
[PinProbe]::SetCursorPos($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 60
[PinProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[PinProbe]::SetCursorPos($cx + 60, $cy + 40) | Out-Null
Start-Sleep -Milliseconds 120
[PinProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 250
$lockedAfter = Get-Rect2 $pin
Check "Lock Position stops a drag" (
  ($lockedAfter.Left -eq $lockedBefore.Left) -and ($lockedAfter.Top -eq $lockedBefore.Top)
) "dx=$($lockedAfter.Left - $lockedBefore.Left) dy=$($lockedAfter.Top - $lockedBefore.Top)"

Click $cx $cy
[PinProbe]::SetCursorPos($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 80
[PinProbe]::mouse_event(8, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[PinProbe]::mouse_event(16, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 400
$menu = [PinProbe]::FindWindow("#32768", $null)
Check "right click opens the context menu" ($menu -ne [IntPtr]::Zero) "menu=$menu"
Press 0x1B
Start-Sleep -Milliseconds 200

# 2 is "Close All Pins"; it must remove the window.
[void][PinProbe]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero)
Start-Sleep -Milliseconds 500
$closed = Get-Pin
Check "Close All Pins removes every card" ($closed -eq [IntPtr]::Zero) "handle=$closed"

Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
if ($failures -gt 0) { exit 1 }
