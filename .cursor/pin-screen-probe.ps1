Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class E {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);
  [DllImport("user32.dll")] public static extern long GetWindowLongPtr(IntPtr hwnd, int index);
  public static string Describe(IntPtr h) {
    var n = new StringBuilder(256); GetClassName(h, n, 256);
    RECT r; GetWindowRect(h, out r);
    int cloaked = 0; DwmGetWindowAttribute(h, 14, out cloaked, 4);
    long style = GetWindowLongPtr(h, -16);
    return string.Format("{0} rect={1},{2} {3}x{4} vis={5} ws_visible={6} cloaked={7} ex=0x{8:X}",
      n, r.Left, r.Top, r.Right-r.Left, r.Bottom-r.Top, IsWindowVisible(h), (style & 0x10000000) != 0, cloaked, GetWindowLongPtr(h, -20));
  }
}
"@
[E]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$bmp = New-Object System.Drawing.Bitmap 2560, 1440
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size(2560, 1440)))
$g.Dispose()
$bmp.Save((Join-Path (Get-Location) ".cursor\desktop-full.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$hits = 0
for ($y = 0; $y -lt 1440; $y += 4) { for ($x = 0; $x -lt 2560; $x += 4) {
  $c = $bmp.GetPixel($x, $y); if ($c.R -gt 150 -and $c.G -lt 110 -and $c.B -lt 110) { $hits++; if ($hits -le 3) { "REDISH at $x,$y = $($c.R),$($c.G),$($c.B)" } }
} }
"RED_PIXELS=$hits"
$bmp.Dispose()
$p = New-Object E+POINT; $p.X = 2200; $p.Y = 700
"AT_2200_700=" + [E]::Describe([E]::WindowFromPoint($p))
"FG=" + [E]::Describe([E]::GetForegroundWindow())
