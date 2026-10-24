$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PinEscProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-Pin { [PinEscProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
for ($i = 0; $i -lt 8; $i++) { try { [System.Windows.Forms.Clipboard]::SetText("Lumen pin escape probe"); break } catch { Start-Sleep -Milliseconds 250 } }
$exe = (Resolve-Path "src-tauri\target\release\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 5
$p = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
if ($p) { $null = $p.WaitForExit(8000) }
Start-Sleep -Seconds 2
$pin = Get-Pin
"pinFound=$($pin -ne [IntPtr]::Zero)"
$r = New-Object PinEscProbe+RECT; [void][PinEscProbe]::GetWindowRect($pin, [ref]$r)
$cx = [int](($r.Left + $r.Right) / 2); $cy = [int](($r.Top + $r.Bottom) / 2)
[PinEscProbe]::SetCursorPos($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 300
[PinEscProbe]::keybd_event(0x1B, 1, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 100
[PinEscProbe]::keybd_event(0x1B, 1, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 600
"closedByHoverEsc=$((Get-Pin) -eq [IntPtr]::Zero)"
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
