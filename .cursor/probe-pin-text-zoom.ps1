$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PinZoomProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-Pin { [PinZoomProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }
function Get-Badge { [PinZoomProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinBadge", [IntPtr]::Zero) }
function Get-Rect2($h) { $r = New-Object PinZoomProbe+RECT; [void][PinZoomProbe]::GetWindowRect($h, [ref]$r); return $r }
function Get-Size($h) { $r = Get-Rect2 $h; return "$($r.Right - $r.Left)x$($r.Bottom - $r.Top)" }
function Wheel($x, $y, $delta) {
  [PinZoomProbe]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 120
  $delta = [int]$delta
  $data = if ($delta -lt 0) { ([uint32]4294967295 - [uint32](-$delta - 1)) } else { [uint32]$delta }
  [PinZoomProbe]::mouse_event(0x0800, 0, 0, $data, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 220
}

Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
$text = "Lumen quick note 0123456789`r`nSecond line: resize me with the wheel." * 2
for ($i = 0; $i -lt 8; $i++) { try { [System.Windows.Forms.Clipboard]::SetText($text); break } catch { Start-Sleep -Milliseconds 250 } }
$exe = (Resolve-Path "src-tauri\target\release\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 5
$p = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
if ($p) { $null = $p.WaitForExit(8000) }
Start-Sleep -Seconds 2
$pin = Get-Pin
if ($pin -eq [IntPtr]::Zero) { "FAIL: no pin window"; exit 1 }
$r = Get-Rect2 $pin
"start=$($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
$cx = [int](($r.Left + $r.Right) / 2); $cy = [int](($r.Top + $r.Bottom) / 2)
Wheel $cx $cy 120
Wheel $cx $cy 120
Wheel $cx $cy 120
$grown = Get-Size $pin
"grown=$grown badge=$((Get-Badge) -ne [IntPtr]::Zero)"
for ($i = 0; $i -lt 6; $i++) { Wheel $cx $cy (-120) }
$back = Get-Size $pin
"shrunk=$back"
Wheel $cx $cy 120
$oneUp = Get-Size $pin
Wheel $cx $cy (-120)
$oneDown = Get-Size $pin
"roundTrip 1up=$oneUp 1down=$oneDown"
[PinZoomProbe]::keybd_event(0x1B, 1, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60
[PinZoomProbe]::keybd_event(0x1B, 1, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 400
"afterEsc=$((Get-Pin) -eq [IntPtr]::Zero)"
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force

