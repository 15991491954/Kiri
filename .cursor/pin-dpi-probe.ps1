Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class D {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
  public static List<IntPtr> Pins() {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => { var n = new StringBuilder(256); GetClassName(hwnd, n, 256); if (n.ToString() == "KiriPinWindow") found.Add(hwnd); return true; }, IntPtr.Zero);
    return found;
  }
}
"@
[D]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
foreach ($pin in [D]::Pins()) {
  $r = New-Object D+RECT; [D]::GetWindowRect($pin, [ref]$r) | Out-Null
  $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  $mx = [int]($w / 2); $my = [int]($h / 2)
  "PIN rect=$($r.Left),$($r.Top) ${w}x${h} dpi=$([D]::GetDpiForWindow($pin))"
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
  $g.Dispose()
  foreach ($pt in @(@(1,1), @($mx,1), @(1,$my), @(($w-2),($h-2)), @($mx,$my))) {
    $c = $bmp.GetPixel($pt[0], $pt[1]); "  PIXEL $($pt[0]),$($pt[1]) = $($c.R),$($c.G),$($c.B)"
  }
  $bmp.Save((Join-Path (Get-Location) ".cursor\pin-live.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}
