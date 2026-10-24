$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ArrowProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-Pin { [ArrowProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }
function Get-Rect2($h) { $r = New-Object ArrowProbe+RECT; [void][ArrowProbe]::GetWindowRect($h, [ref]$r); return $r }
function Tap([byte]$vk) { [ArrowProbe]::keybd_event($vk,1,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [ArrowProbe]::keybd_event($vk,1,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80 }
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 900
for ($i = 0; $i -lt 8; $i++) { try { [System.Windows.Forms.Clipboard]::SetText("arrow probe text"); break } catch { Start-Sleep -Milliseconds 250 } }
$exe = (Resolve-Path "src-tauri\target\release\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 6
$p = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
if ($p) { $null = $p.WaitForExit(8000) }
Start-Sleep -Seconds 2
$pin = Get-Pin
if ($pin -eq [IntPtr]::Zero) { "FAIL no pin"; exit 1 }
$r = Get-Rect2 $pin
"start=$($r.Left),$($r.Top)"
$cx = [int](($r.Left + $r.Right) / 2); $cy = [int](($r.Top + $r.Bottom) / 2)
[ArrowProbe]::SetCursorPos($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 300
[ArrowProbe]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80; [ArrowProbe]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 400
1..5 | ForEach-Object { Tap 0x27 }
Start-Sleep -Milliseconds 300
$m = Get-Rect2 $pin
"afterRight=$($m.Left),$($m.Top) dx=$($m.Left - $r.Left)"
1..3 | ForEach-Object { Tap 0x28 }
Start-Sleep -Milliseconds 300
$n = Get-Rect2 $pin
"afterDown=$($n.Left),$($n.Top) dy=$($n.Top - $m.Top)"
# drag by +120,+80
[ArrowProbe]::SetCursorPos([int](($n.Left + $n.Right)/2), [int](($n.Top + $n.Bottom)/2)) | Out-Null
Start-Sleep -Milliseconds 200
[ArrowProbe]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 120
foreach ($s in 1..10) { [ArrowProbe]::SetCursorPos([int](($n.Left + $n.Right)/2) + 12*$s, [int](($n.Top + $n.Bottom)/2) + 8*$s); Start-Sleep -Milliseconds 40 }
[ArrowProbe]::mouse_event(4,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 500
$d = Get-Rect2 $pin
"afterDrag=$($d.Left),$($d.Top) moved=$($d.Left - $n.Left),$($d.Top - $n.Top)"
# click to select, then Escape
$dx = [int](($d.Left + $d.Right)/2); $dy = [int](($d.Top + $d.Bottom)/2)
[ArrowProbe]::SetCursorPos($dx, $dy) | Out-Null
Start-Sleep -Milliseconds 200
[ArrowProbe]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80; [ArrowProbe]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 300
Tap 0x1B
Start-Sleep -Milliseconds 600
"closedAfterDragEsc=$((Get-Pin) -eq [IntPtr]::Zero)"
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
