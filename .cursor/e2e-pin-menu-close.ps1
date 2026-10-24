# Investigates how the pin context menu ends: outside click vs Escape.
param([string]$CloseWith = "click")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class C {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

  public static List<IntPtr> Visible(string cls) {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => {
      var name = new StringBuilder(256);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == cls && IsWindowVisible(hwnd)) found.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string Describe(IntPtr hwnd) {
    RECT r; GetWindowRect(hwnd, out r);
    return string.Format("{0},{1} {2}x{3}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
  }
}
"@

function Centre([IntPtr]$hwnd) {
  $r = New-Object C+RECT; [C]::GetWindowRect($hwnd, [ref]$r) | Out-Null
  return @([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
}

$pins = [C]::Visible("KiriPinWindow")
if ($pins.Count -eq 0) { "NO_PINS"; exit 1 }
$centre = Centre $pins[0]
[C]::SetCursorPos($centre[0], $centre[1]) | Out-Null
Start-Sleep -Milliseconds 200
[C]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[C]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 700
$menu = [C]::Visible("#32768")
"OPEN menu=$($menu.Count) $(if ($menu.Count) { [C]::Describe($menu[0]) })"

if ($CloseWith -eq "click") {
  [C]::SetCursorPos($centre[0] + 260, $centre[1] + 220) | Out-Null
  Start-Sleep -Milliseconds 200
  [C]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [C]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
} elseif ($CloseWith -eq "escape") {
  [C]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [C]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
}
Start-Sleep -Milliseconds 900
$after = [C]::Visible("#32768")
"AFTER_$($CloseWith.ToUpper()) menu=$($after.Count)"
"PINS=$(([C]::Visible('KiriPinWindow')).Count)"
if ($after.Count -gt 0) { "MENU_LEFT=$([C]::Describe($after[0]))" }