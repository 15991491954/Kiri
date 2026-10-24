# Creates a clipboard pin and inspects the pixels around it for the shadow band.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class W2 {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);

  public static List<IntPtr> Windows(string className) {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => {
      var name = new StringBuilder(256);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == className) found.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@

$pinsBefore = @([W2]::Windows("KiriPinWindow"))
$bitmap = New-Object System.Drawing.Bitmap 320, 200
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.Clear([System.Drawing.Color]::FromArgb(255, 40, 120, 200))
$graphics.Dispose()
[System.Windows.Forms.Clipboard]::SetImage($bitmap)
$bitmap.Dispose()

[W2]::SetCursorPos(700, 500) | Out-Null
Start-Sleep -Milliseconds 300
[W2]::keybd_event(0x72, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[W2]::keybd_event(0x72, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 1500

$pins = @([W2]::Windows("KiriPinWindow") | Where-Object { $pinsBefore -notcontains $_ })
"NEW_PINS=$($pins.Count)"
foreach ($pin in $pins) {
  $rect = New-Object W2+RECT
  [W2]::GetWindowRect($pin, [ref]$rect) | Out-Null
  "PIN rect=$($rect.Left),$($rect.Top) $($rect.Right - $rect.Left)x$($rect.Bottom - $rect.Top) visible=$([W2]::IsWindowVisible($pin))"
  $left = $rect.Left - 6; $top = $rect.Top - 6
  $width = ($rect.Right - $rect.Left) + 12; $height = ($rect.Bottom - $rect.Top) + 12
  $shot = New-Object System.Drawing.Bitmap $width, $height
  $g = [System.Drawing.Graphics]::FromImage($shot)
  $g.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size $width, $height))
  $g.Dispose()
  $path = Join-Path $PSScriptRoot "pin-shadow-probe.png"
  $shot.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  "SHOT=$path SIZE=${width}x${height}"
  # Sample a horizontal line through the middle of the window, left edge inward.
  $mid = [int]($height / 2)
  $samples = @()
  foreach ($x in 0..([Math]::Min(30, $width - 1))) {
    $p = $shot.GetPixel($x, $mid)
    $samples += ("{0}:{1},{2},{3}" -f $x,$p.R,$p.G,$p.B); #,$($p.G),$($p.B)"
  }
  "ROW=$($samples -join ' ')"
  # Top edge downward.
  $midx = [int]($width / 2)
  $samples = @()
  foreach ($y in 0..([Math]::Min(30, $height - 1))) {
    $p = $shot.GetPixel($midx, $y)
    $samples += ("{0}:{1},{2},{3}" -f $y,$p.R,$p.G,$p.B); #,$($p.G),$($p.B)"
  }
  "COL=$($samples -join ' ')"
  $corner = $shot.GetPixel(6, 6)
  "WINDOW_CORNER=$($corner.R),$($corner.G),$($corner.B)"
  $shot.Dispose()
}

