$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PinPrintProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-Pin { [PinPrintProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 900
$bmp = New-Object System.Drawing.Bitmap 400, 300
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::FromArgb(40, 140, 90)); $g.Dispose()
for ($i = 0; $i -lt 8; $i++) { try { [System.Windows.Forms.Clipboard]::SetImage($bmp); break } catch { Start-Sleep -Milliseconds 250 } }
$bmp.Dispose()
$exe = (Resolve-Path "src-tauri\target\release\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 6
$p = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
if ($p) { $null = $p.WaitForExit(8000) }
Start-Sleep -Seconds 3
$pin = Get-Pin
if ($pin -eq [IntPtr]::Zero) { "no pin"; exit 1 }
$r = New-Object PinPrintProbe+RECT; [void][PinPrintProbe]::GetWindowRect($pin, [ref]$r)
$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
$shot = New-Object System.Drawing.Bitmap $w, $h
$g2 = [System.Drawing.Graphics]::FromImage($shot)
$hdc = $g2.GetHdc()
$ok = [PinPrintProbe]::PrintWindow($pin, $hdc, 2)
$g2.ReleaseHdc($hdc); $g2.Dispose()
"printWindow=$ok size=${w}x${h}"
$shot.Save((Join-Path (Get-Location) ".cursor\pin-print-check.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$mid = [int]($h/2)
"center=" + $shot.GetPixel([int]($w/2), $mid).ToString()
"leftEdge=" + $shot.GetPixel(2, $mid).ToString()
"photoLeft=" + $shot.GetPixel(20, $mid).ToString()
$shot.Dispose()
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
