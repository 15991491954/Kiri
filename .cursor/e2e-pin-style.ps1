# Structural and visual checks for a native pin window.
#   style  : plain/ex styles, window vs client size (a border would add non-client area)
#   screen : pixels sampled from a normal screen grab at the pin and badge rectangles
param([string]$Stage = "style")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class P {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint command);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hwnd);

  public static List<IntPtr> Windows(string className) {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => {
      var name = new StringBuilder(256);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == className && IsWindowVisible(hwnd)) found.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@

function Show([IntPtr]$hwnd, [string]$tag) {
  $w = New-Object P+RECT; [P]::GetWindowRect($hwnd, [ref]$w) | Out-Null
  $c = New-Object P+RECT; [P]::GetClientRect($hwnd, [ref]$c) | Out-Null
  $plain = [int64][P]::GetWindowLongPtr($hwnd, -16)
  $ex = [int64][P]::GetWindowLongPtr($hwnd, -20)
  $width = $w.Right - $w.Left; $height = $w.Bottom - $w.Top
  "  ${tag}WINDOW=$($w.Left),$($w.Top) ${width}x${height}"
  "  ${tag}CLIENT=$($c.Right - $c.Left)x$($c.Bottom - $c.Top) NONCLIENT=$(($width - ($c.Right - $c.Left))),$(($height - ($c.Bottom - $c.Top)))"
  "  ${tag}STYLE=0x$($plain.ToString('X')) POPUP=$([bool]($plain -band 0x80000000)) CAPTION=$([bool]($plain -band 0x00C00000)) THICKFRAME=$([bool]($plain -band 0x00040000)) DLGFRAME=$([bool]($plain -band 0x00400000))"
  "  ${tag}EXSTYLE=0x$($ex.ToString('X')) TOPMOST=$([bool]($ex -band 0x8)) LAYERED=$([bool]($ex -band 0x80000)) TOOLWINDOW=$([bool]($ex -band 0x80)) NOACTIVATE=$([bool]($ex -band 0x8000000)) APPWINDOW=$([bool]($ex -band 0x40000))"
  "  ${tag}TITLE_LENGTH=$([P]::GetWindowTextLength($hwnd)) OWNER=0x$(([P]::GetWindow($hwnd, 4)).ToInt64().ToString('X'))"
}

$pins = [P]::Windows("KiriPinWindow")
"PINS=$($pins.Count)"
$index = 0
foreach ($pin in $pins) { Show $pin "PIN[$index] "; $index++ }

$badges = [P]::Windows("KiriPinBadge")
"BADGES=$($badges.Count)"
foreach ($badge in $badges) { Show $badge "BADGE " }

if ($Stage -eq "screen") {
  $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bitmap = New-Object System.Drawing.Bitmap 400, 300
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $pin = $pins[0]
  $rect = New-Object P+RECT; [P]::GetWindowRect($pin, [ref]$rect) | Out-Null
  $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size 400, 300))
  $graphics.Dispose()
  $colours = @{}
  for ($y = 0; $y -lt 300; $y += 10) {
    for ($x = 0; $x -lt 400; $x += 10) {
      $pixel = $bitmap.GetPixel($x, $y)
      $key = "$($pixel.R),$($pixel.G),$($pixel.B)"
      $colours[$key] = 1 + ($colours[$key] -as [int])
    }
  }
  "SCREEN_GRAB_DISTINCT_COLOURS=$($colours.Count)"
  "SCREEN_GRAB_SAMPLES=$(([int](300/10) + 1) * ([int](400/10) + 1))"
  $colours.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "  $($_.Name) x$($_.Value)" }
  $bitmap.Dispose()
}
