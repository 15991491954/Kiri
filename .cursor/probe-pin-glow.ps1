$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class GlowProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-Pin { [GlowProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
$bmp = New-Object System.Drawing.Bitmap 400, 300
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::FromArgb(40, 140, 90)); $g.Dispose()
for ($i = 0; $i -lt 8; $i++) { try { [System.Windows.Forms.Clipboard]::SetImage($bmp); break } catch { Start-Sleep -Milliseconds 250 } }
$bmp.Dispose()
$exe = (Resolve-Path "src-tauri\target\debug\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 6
$p = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
if ($p) { $null = $p.WaitForExit(8000) }
Start-Sleep -Seconds 3
$pin = Get-Pin
if ($pin -eq [IntPtr]::Zero) { "FAIL: no pin"; exit 1 }
$r = New-Object GlowProbe+RECT; [void][GlowProbe]::GetWindowRect($pin, [ref]$r)
"rect=$($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
$shot = New-Object System.Drawing.Bitmap $w, $h
$sg = [System.Drawing.Graphics]::FromImage($shot)
$sg.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
$sg.Dispose()
$shot.Save((Join-Path (Get-Location) ".cursor\pin-glow-check.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$mid = [int]($h / 2)
1..6 | ForEach-Object {
  $px = $shot.GetPixel($_, $mid)
  "edgeX$_=R$($px.R),G$($px.G),B$($px.B),A$($px.A)"
}
$photo = $shot.GetPixel(30, $mid)
"photo= R$($photo.R),G$($photo.G),B$($photo.B)"
$shot.Dispose()
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
