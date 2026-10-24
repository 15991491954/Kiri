$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DragProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-Pin {
  $h = [IntPtr]::Zero
  $found = [DragProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero)
  return $found
}
function Get-Rect2($h) { $r = New-Object DragProbe+RECT; [void][DragProbe]::GetWindowRect($h, [ref]$r); return $r }

Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 700
$bmp = New-Object System.Drawing.Bitmap 400, 300
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::FromArgb(30, 120, 60)); $g.Dispose()
for ($i = 0; $i -lt 8; $i++) { try { [System.Windows.Forms.Clipboard]::SetImage($bmp); break } catch { Start-Sleep -Milliseconds 250 } }
$bmp.Dispose()
$exe = (Resolve-Path "src-tauri\target\debug\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 5
$p = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
if ($p) { $null = $p.WaitForExit(8000) }
Start-Sleep -Seconds 2
$pin = Get-Pin
"pin=$pin"
$r = Get-Rect2 $pin
"start=$($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
$cx = [int](($r.Left + $r.Right) / 2); $cy = [int](($r.Top + $r.Bottom) / 2)
[DragProbe]::SetCursorPos($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 250
[DragProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
foreach ($s in 1..10) { [DragProbe]::SetCursorPos($cx + 4 * $s, $cy + 3 * $s) | Out-Null; Start-Sleep -Milliseconds 40 }
[DragProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 500
$m = Get-Rect2 $pin
"centerDrag=$($m.Left),$($m.Top) moved=$($m.Left - $r.Left),$($m.Top - $r.Top)"
$ex = $m.Right - 12 - 3; $ey = [int](($m.Top + $m.Bottom) / 2)
[DragProbe]::SetCursorPos($ex, $ey) | Out-Null
Start-Sleep -Milliseconds 250
[DragProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
foreach ($s in 1..10) { [DragProbe]::SetCursorPos($ex + 10 * $s, $ey) | Out-Null; Start-Sleep -Milliseconds 40 }
[DragProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 500
$n = Get-Rect2 $pin
"edgeDrag=$($n.Left),$($n.Top) size=$($n.Right - $n.Left)x$($n.Bottom - $n.Top) deltaW=$($n.Right - $n.Left - ($m.Right - $m.Left))"
[DragProbe]::keybd_event(0x1B, 1, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [DragProbe]::keybd_event(0x1B, 1, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 500
"afterEsc=$(Get-Pin)"
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
