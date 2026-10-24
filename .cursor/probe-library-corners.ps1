$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CornerProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
$exe = (Resolve-Path "src-tauri\target\release\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 7
$h = [CornerProbe]::FindWindow($null, "Lumen")
if ($h -eq [IntPtr]::Zero) { $h = [CornerProbe]::FindWindow($null, "Lumen Library") }
if ($h -eq [IntPtr]::Zero) { "no window"; Get-Process kiri | Stop-Process -Force; exit 1 }
$r = New-Object CornerProbe+RECT; [void][CornerProbe]::GetWindowRect($h, [ref]$r)
$w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
"rect=$($r.Left),$($r.Top) ${w}x${ht}"
$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $ht))
$g.Dispose()
$bmp.Save((Join-Path (Get-Location) ".cursor\library-corners.png"), [System.Drawing.Imaging.ImageFormat]::Png)
1..8 | ForEach-Object {
  $p = $bmp.GetPixel($_, $_)
  "diag$_=R$($p.R),G$($p.G),B$($p.B),A$($p.A)"
}
$p2 = $bmp.GetPixel($w - 3, 3)
"topRight= R$($p2.R),G$($p2.G),B$($p2.B),A$($p2.A)"
$bmp.Dispose()
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
