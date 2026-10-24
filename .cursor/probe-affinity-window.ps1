# Checks whether Windows accepts EXCLUDEFROMCAPTURE on the main WebView window.
$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AffWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowDisplayAffinity(IntPtr h, uint affinity);
  [DllImport("user32.dll", SetLastError = true)] public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint affinity);
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
$app = Get-Process kiri | Select-Object -First 1
$window = [AffWin]::MainWindowOf($app.Id)
"hwnd=$window"
$ok = [AffWin]::SetWindowDisplayAffinity($window, 0x00000011)
"set ok=$ok err=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
$value = 0
$read = [AffWin]::GetWindowDisplayAffinity($window, [ref]$value)
"read ok=$read affinity=$value err=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
