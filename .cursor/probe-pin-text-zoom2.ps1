$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PinZoomProbe2 {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-Pin { [PinZoomProbe2]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }
function Get-Rect2($h) { $r = New-Object PinZoomProbe2+RECT; [void][PinZoomProbe2]::GetWindowRect($h, [ref]$r); return $r }
function Get-Size($h) { $r = Get-Rect2 $h; return "$($r.Right - $r.Left)x$($r.Bottom - $r.Top)" }
function Wheel($x, $y, $delta) {
  [PinZoomProbe2]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 100
  $delta = [int]$delta
  $data = if ($delta -lt 0) { ([uint32]4294967295 - [uint32](-$delta - 1)) } else { [uint32]$delta }
  [PinZoomProbe2]::mouse_event(0x0800, 0, 0, $data, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 180
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
if ($pin -eq [IntPtr]::Zero) { "FAIL: no pin"; exit 1 }
$r = Get-Rect2 $pin
$base = Get-Size $pin
"start=$base"
$cx = [int](($r.Left + $r.Right) / 2); $cy = [int](($r.Top + $r.Bottom) / 2)
for ($i = 0; $i -lt 4; $i++) { Wheel $cx $cy 120 }
$grown = Get-Size $pin
"grown=$grown"
for ($i = 0; $i -lt 8; $i++) { Wheel $cx $cy (-120) }
"afterShrink=$(Get-Size $pin)"
for ($i = 1; $i -le 8; $i++) { Wheel $cx $cy 120; "up$i=$(Get-Size $pin)" }
[PinZoomProbe2]::SetCursorPos($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 200
[PinZoomProbe2]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
[PinZoomProbe2]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 300
"foregroundSelf=$((Get-ForegroundWindow) -eq $pin)"
[PinZoomProbe2]::keybd_event(0x1B, 1, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[PinZoomProbe2]::keybd_event(0x1B, 1, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 500
"afterEsc=$((Get-Pin) -eq [IntPtr]::Zero)"
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
