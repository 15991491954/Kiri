param([int]$Round = 1)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class S {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  public static List<string> Dump(uint processId) {
    var lines = new List<string>();
    EnumWindows((hwnd, _) => {
      uint pid; GetWindowThreadProcessId(hwnd, out pid);
      if (pid != processId) return true;
      var cls = new StringBuilder(256); GetClassName(hwnd, cls, cls.Capacity);
      var title = new StringBuilder(256); GetWindowText(hwnd, title, title.Capacity);
      RECT r; GetWindowRect(hwnd, out r);
      lines.Add(string.Format("hwnd=0x{0:X} class={1} title={2} rect={3},{4} {5}x{6} visible={7}",
        hwnd.ToInt64(), cls, title, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, IsWindowVisible(hwnd)));
      return true;
    }, IntPtr.Zero);
    return lines;
  }
}
"@
function Get-KiriPid { (Get-Process kiri -ErrorAction Stop | Select-Object -First 1).Id }
function Click-Real([int]$x, [int]$y) {
  [S]::SetCursorPos($x, $y) | Out-Null; Start-Sleep -Milliseconds 150
  [S]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 90
  [S]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}
function Drag-Real([int]$x1, [int]$y1, [int]$x2, [int]$y2) {
  [S]::SetCursorPos($x1, $y1) | Out-Null; Start-Sleep -Milliseconds 150
  [S]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 90
  for ($step = 1; $step -le 12; $step++) {
    [S]::SetCursorPos([int]($x1 + ($x2 - $x1) * $step / 12), [int]($y1 + ($y2 - $y1) * $step / 12)) | Out-Null
    Start-Sleep -Milliseconds 18
  }
  Start-Sleep -Milliseconds 90
  [S]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}
function Find-PinButton([IntPtr]$hwnd) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  if (-not $root) { return $null }
  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
  foreach ($button in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
    if ($button.Current.Name -match "Pin Screenshot on Top|置顶截图|ピン|Anheften|Épingler|고정") { return $button }
  }
  return $null
}
$kiri = Get-KiriPid
"SNAPSHOT_BEFORE"
[S]::Dump([uint32]$kiri) | ForEach-Object { "  $_" }
[S]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero); [S]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero); [S]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[S]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero); [S]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero); [S]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 2300
"SNAPSHOT_AFTER_CAPTURE"
[S]::Dump([uint32]$kiri) | ForEach-Object { "  $_" }
$overlay = ([S]::Dump([uint32]$kiri) | Where-Object { $_ -match 'class=Tauri Window' } | Select-Object -First 1)
Drag-Real 360 300 820 640
Start-Sleep -Milliseconds 900
# Find the overlay handle again, then the button.
$handleLine = [S]::Dump([uint32]$kiri) | Where-Object { $_ -match 'class=Tauri Window' } | Select-Object -First 1
$handleHex = ([regex]'hwnd=0x([0-9A-F]+)').Match($handleLine).Groups[1].Value
$handle = [IntPtr][Convert]::ToInt64($handleHex, 16)
$button = Find-PinButton $handle
if ($button) {
  $b = $button.Current.BoundingRectangle
  "PIN_BUTTON=$($button.Current.Name) at $([int]($b.Left + $b.Width / 2)),$([int]($b.Top + $b.Height / 2))"
  Click-Real ([int]($b.Left + $b.Width / 2)) ([int]($b.Top + $b.Height / 2))
} else { "PIN_BUTTON=missing" }
Start-Sleep -Milliseconds 2600
"SNAPSHOT_AFTER_PIN"
[S]::Dump([uint32]$kiri) | ForEach-Object { "  $_" }
