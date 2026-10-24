Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class F {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern long GetWindowLongPtr(IntPtr hwnd, int index);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
  public static List<IntPtr> Pins() { var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => { var n = new StringBuilder(256); GetClassName(hwnd, n, 256); if (n.ToString() == "KiriPinWindow") found.Add(hwnd); return true; }, IntPtr.Zero); return found; }
  public static string Hit(int x, int y) { var p = new POINT(); p.X = x; p.Y = y; var h = WindowFromPoint(p); var n = new StringBuilder(256); GetClassName(h, n, 256); return n.ToString(); }
}
"@
foreach ($pin in [F]::Pins()) {
  $r = New-Object F+RECT; [F]::GetWindowRect($pin, [ref]$r) | Out-Null
  $style = [F]::GetWindowLongPtr($pin, -16); $ex = [F]::GetWindowLongPtr($pin, -20)
  "PIN $($r.Left),$($r.Top) $($r.Right-$r.Left)x$($r.Bottom-$r.Top) style=0x$($style.ToString('X')) ex=0x$($ex.ToString('X'))"
  "  caption=$([bool]($style -band 0x00C00000)) border=$([bool]($style -band 0x00800000)) thickframe=$([bool]($style -band 0x00040000)) popup=$([bool]($style -band 0x80000000))"
  foreach ($pt in @(@($r.Left,$r.Top), @(($r.Right-1),$r.Top), @($r.Left,($r.Bottom-1)), @(($r.Right-1),($r.Bottom-1)), @(($r.Left+150),($r.Top+100)), @(($r.Left-1),$r.Top), @($r.Right,$r.Top))) {
    "  HIT $($pt[0]),$($pt[1]) = $([F]::Hit($pt[0], $pt[1]))"
  }
}
