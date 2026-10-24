Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class P { [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
 [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; } }
"@
$rects = @{ x=2050; y=600; w=300; h=200 }
$bmp = New-Object System.Drawing.Bitmap $rects.w, $rects.h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($rects.x, $rects.y, 0, 0, (New-Object System.Drawing.Size($rects.w, $rects.h)))
$g.Dispose()
$bmp.Save((Join-Path (Get-Location) ".cursor\pin-live.png"), [System.Drawing.Imaging.ImageFormat]::Png)
foreach ($pt in @(@(1,1), @(150,1), @(1,100), @(298,198), @(150,100))) {
  $c = $bmp.GetPixel($pt[0], $pt[1]); "PIXEL $($pt[0]),$($pt[1]) = $($c.R),$($c.G),$($c.B)"
}
$bmp.Dispose()
