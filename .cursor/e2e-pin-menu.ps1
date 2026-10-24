# Checks that a pin's native context menu is dismissed by an outside click.
# Complements e2e-pin-final.ps1, whose "#32768" count also includes hidden
# menu windows and therefore cannot prove dismissal.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class M {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);

  public static List<IntPtr> Visible(string className) {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => {
      var name = new StringBuilder(256);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == className && IsWindowVisible(hwnd)) found.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string Describe(IntPtr hwnd) {
    RECT r; GetWindowRect(hwnd, out r);
    return string.Format("0x{0:X} {1},{2} {3}x{4}", hwnd.ToInt64(), r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
  }
}
"@

function Get-Centre([IntPtr]$hwnd) {
  $rect = New-Object M+RECT
  [M]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
  return @([int](($rect.Left + $rect.Right) / 2), [int](($rect.Top + $rect.Bottom) / 2))
}

$pins = [M]::Visible("KiriPinWindow")
if ($pins.Count -eq 0) { "NO_PINS"; exit 1 }
$pin = $pins[0]
$centre = Get-Centre $pin
[M]::SetCursorPos($centre[0], $centre[1]) | Out-Null
Start-Sleep -Milliseconds 200
[M]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[M]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 700
$open = [M]::Visible("#32768")
"VISIBLE_MENUS_AFTER_RIGHT_CLICK=$($open.Count)"
$open | ForEach-Object { "  MENU $([M]::Describe($_))" }
[M]::SetCursorPos(1200, 800) | Out-Null
Start-Sleep -Milliseconds 200
[M]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[M]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 900
$after = [M]::Visible("#32768")
"VISIBLE_MENUS_AFTER_OUTSIDE_CLICK=$($after.Count)"
$after | ForEach-Object { "  MENU $([M]::Describe($_))" }
"PINS_AFTER=$(([M]::Visible('KiriPinWindow')).Count)"
