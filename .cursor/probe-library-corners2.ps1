$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CornerProbe2 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
$exe = (Resolve-Path "src-tauri\target\release\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 7
$proc = Get-Process kiri | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { "no window"; Get-Process kiri | Stop-Process -Force; exit 1 }
$h = $proc.MainWindowHandle
"title=$($proc.MainWindowTitle) hwnd=$h"
$r = New-Object CornerProbe2+RECT; [void][CornerProbe2]::GetWindowRect($h, [ref]$r)
$w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
"rect=$($r.Left),$($r.Top) ${w}x${ht}"
$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $ht))
$g.Dispose()
$bmp.Save((Join-Path (Get-Location) ".cursor\library-corners.png"), [System.Drawing.Imaging.ImageFormat]::Png)
1..8 | ForEach-Object { $p = $bmp.GetPixel($_, $_); "diag$_=R$($p.R),G$($p.G),B$($p.B)" }
$p2 = $bmp.GetPixel($w - 3, 3); "topRight= R$($p2.R),G$($p2.G),B$($p2.B)"
$bmp.Dispose()
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
