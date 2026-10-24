$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class EscProbe3 {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-Pin { [EscProbe3]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 1000
for ($i = 0; $i -lt 8; $i++) { try { [System.Windows.Forms.Clipboard]::SetText("lumen esc probe three"); break } catch { Start-Sleep -Milliseconds 250 } }
$exe = (Resolve-Path "src-tauri\target\debug\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 6
$p = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
if ($p) { $null = $p.WaitForExit(8000) }
Start-Sleep -Seconds 3
$pin = Get-Pin
"pin=$($pin -ne [IntPtr]::Zero)"
$r = New-Object EscProbe3+RECT; [void][EscProbe3]::GetWindowRect($pin, [ref]$r)
[EscProbe3]::SetCursorPos([int](($r.Left+$r.Right)/2), [int](($r.Top+$r.Bottom)/2)) | Out-Null
Start-Sleep -Milliseconds 500
1..3 | ForEach-Object {
  [EscProbe3]::keybd_event(0x1B, 1, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  [EscProbe3]::keybd_event(0x1B, 1, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 800
  "attempt$_ closed=$((Get-Pin) -eq [IntPtr]::Zero)"
}
Start-Sleep -Milliseconds 500
"final=$((Get-Pin) -eq [IntPtr]::Zero)"
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
