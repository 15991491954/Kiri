$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ResetProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-Pin { [ResetProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }
function Get-Rect2($h) { $r = New-Object ResetProbe+RECT; [void][ResetProbe]::GetWindowRect($h, [ref]$r); return $r }
function Size($h) { $r = Get-Rect2 $h; "$($r.Right - $r.Left)x$($r.Bottom - $r.Top)" }
function Wheel($x,$y,$d){ [ResetProbe]::SetCursorPos($x,$y)|Out-Null; Start-Sleep -Milliseconds 120; $data=if($d -lt 0){[uint32]4294967295 - [uint32](-$d-1)}else{[uint32]$d}; [ResetProbe]::mouse_event(0x0800,0,0,$data,[UIntPtr]::Zero); Start-Sleep -Milliseconds 200 }
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 900
for ($i=0;$i -lt 8;$i++){ try { [System.Windows.Forms.Clipboard]::SetText("double click reset probe"); break } catch { Start-Sleep -Milliseconds 250 } }
$exe=(Resolve-Path "src-tauri\target\debug\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 6
$p=Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
if($p){ $null=$p.WaitForExit(8000) }
Start-Sleep -Seconds 2
$pin=Get-Pin
if($pin -eq [IntPtr]::Zero){ "no pin"; exit 1 }
$start=Size $pin
$r=Get-Rect2 $pin; $cx=[int](($r.Left+$r.Right)/2); $cy=[int](($r.Top+$r.Bottom)/2)
Wheel $cx $cy 120; Wheel $cx $cy 120
$zoomed=Size $pin
[ResetProbe]::SetCursorPos($cx,$cy)|Out-Null
Start-Sleep -Milliseconds 200
[ResetProbe]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 30; [ResetProbe]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[ResetProbe]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 30; [ResetProbe]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 500
$reset=Size $pin
"start=$start zoomed=$zoomed afterDoubleClick=$reset"
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
