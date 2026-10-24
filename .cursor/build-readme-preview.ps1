# Builds the README preview from a live 1600x1080 window capture.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Preview {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static IntPtr MainWindowOf(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      var t = new System.Text.StringBuilder(256);
      GetWindowTextW(h, t, 256);
      if (t.ToString().StartsWith("Lumen")) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@

Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 700
Start-Process -FilePath "src-tauri\target\debug\kiri.exe" | Out-Null
Start-Sleep -Seconds 6
$app = Get-Process kiri | Select-Object -First 1
$window = [Preview]::MainWindowOf($app.Id)
[void][Preview]::SetForegroundWindow($window)
Start-Sleep -Milliseconds 400
# 1600x1080 client: the frame adds 8 px on the left, right and bottom edges.
[void][Preview]::SetWindowPos($window, [IntPtr]::Zero, 60, 40, 2024, 1316, 0x0004)
Start-Sleep -Milliseconds 900
[void][Preview]::SetForegroundWindow($window)
Start-Sleep -Milliseconds 400

$client = New-Object Preview+RECT
[void][Preview]::GetClientRect($window, [ref]$client)
$origin = New-Object Preview+POINT
[void][Preview]::ClientToScreen($window, [ref]$origin)
$width = $client.Right - $client.Left
$height = $client.Bottom - $client.Top
$shot = New-Object System.Drawing.Bitmap $width, $height
$shotGraphics = [System.Drawing.Graphics]::FromImage($shot)
$shotGraphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, (New-Object System.Drawing.Size $width, $height))
$shotGraphics.Dispose()

$canvas = New-Object System.Drawing.Bitmap 2880, 1918
$graphics = [System.Drawing.Graphics]::FromImage($canvas)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$background = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
  (New-Object System.Drawing.Rectangle 0, 0, 2880, 1918),
  [System.Drawing.Color]::FromArgb(240, 243, 248),
  [System.Drawing.Color]::FromArgb(219, 225, 235),
  90)
$graphics.FillRectangle($background, 0, 0, 2880, 1918)

$left = [int]((2880 - $width) / 2)
$top = [int]((1918 - $height) / 2)
$radius = 18
$shadowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$shadowPath.AddArc($left - 22, $top - 14, $radius * 2, $radius * 2, 180, 90)
$shadowPath.AddArc($left + $width - 22 - $radius * 2, $top - 14, $radius * 2, $radius * 2, 270, 90)
$shadowPath.AddArc($left + $width - 22 - $radius * 2, $top + $height - 14 - $radius * 2, $radius * 2, $radius * 2, 0, 90)
$shadowPath.AddArc($left - 22, $top + $height - 14 - $radius * 2, $radius * 2, $radius * 2, 90, 90)
$shadowPath.CloseFigure()
$shadowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(46, 20, 28, 44))
$graphics.FillPath($shadowBrush, $shadowPath)

$clipPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$clipPath.AddArc($left, $top, $radius * 2, $radius * 2, 180, 90)
$clipPath.AddArc($left + $width - $radius * 2, $top, $radius * 2, $radius * 2, 270, 90)
$clipPath.AddArc($left + $width - $radius * 2, $top + $height - $radius * 2, $radius * 2, $radius * 2, 0, 90)
$clipPath.AddArc($left, $top + $height - $radius * 2, $radius * 2, $radius * 2, 90, 90)
$clipPath.CloseFigure()
$graphics.SetClip($clipPath)
$graphics.DrawImage($shot, $left, $top, $width, $height)
$graphics.ResetClip()
$border = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(60, 0, 0, 0)), 2
$graphics.DrawPath($border, $clipPath)

$target = Join-Path (Get-Location) "docs\assets\readme-preview.png"
$canvas.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
$border.Dispose(); $clipPath.Dispose(); $shadowPath.Dispose(); $shadowBrush.Dispose(); $background.Dispose()
$graphics.Dispose(); $canvas.Dispose(); $shot.Dispose()
"preview written ${width}x${height} -> 2880x1918"
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
