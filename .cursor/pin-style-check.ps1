# Verifies the borderless assertion with exact 64-bit masks.
# PowerShell 5.1 parses 0x80C00000 as a negative Int32, which sign-extends in a
# -band with a positive GWL_STYLE and produces a false failure.
$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class S {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
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
$style = [Convert]::ToInt64("80C00000", 16)
$popup = [Convert]::ToInt64("80000000", 16)
$caption = [Convert]::ToInt64("00C00000", 16)
$frame = [Convert]::ToInt64("00040000", 16)
foreach ($pin in [S]::Windows("KiriPinWindow")) {
  $value = [S]::GetWindowLongPtr($pin, -16).ToInt64()
  $ok = (($value -band $style) -eq $popup) -and (($value -band $caption) -eq 0) -and (($value -band $frame) -eq 0)
  "[$(if ($ok) { 'PASS' } else { 'FAIL' })] borderless style=0x$($value.ToString('X')) popup=$([bool](($value -band $popup) -eq $popup)) caption=$([bool](($value -band $caption) -ne 0)) frame=$([bool](($value -band $frame) -ne 0))"
}
