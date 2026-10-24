# Real-mouse end-to-end loop: capture, drag a region, click the pin button with a
# physical mouse event sequence, then report overlay/pin state.
param([int]$Rounds = 3)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class P {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

  public static List<IntPtr> ByClass(string className) {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => {
      var name = new StringBuilder(256);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == className && IsWindowVisible(hwnd)) found.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static List<IntPtr> WindowsOf(uint processId, string className) {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => {
      uint pid; GetWindowThreadProcessId(hwnd, out pid);
      if (pid != processId || !IsWindowVisible(hwnd)) return true;
      var name = new StringBuilder(256);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == className) found.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string RectOf(IntPtr hwnd) {
    RECT r; GetWindowRect(hwnd, out r);
    return string.Format("{0},{1} {2}x{3}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
  }
}
"@

function Get-KiriPid { (Get-Process kiri -ErrorAction Stop | Select-Object -First 1).Id }
function Click-Real([int]$x, [int]$y) {
  [P]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 150
  [P]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 90
  [P]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}
function Drag-Real([int]$x1, [int]$y1, [int]$x2, [int]$y2) {
  [P]::SetCursorPos($x1, $y1) | Out-Null
  Start-Sleep -Milliseconds 150
  [P]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 90
  for ($step = 1; $step -le 12; $step++) {
    $x = [int]($x1 + ($x2 - $x1) * $step / 12)
    $y = [int]($y1 + ($y2 - $y1) * $step / 12)
    [P]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 18
  }
  Start-Sleep -Milliseconds 90
  [P]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
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
function Send-CaptureShortcut {
  [P]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
  [P]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
  [P]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [P]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero)
  [P]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)
  [P]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
}

$kiri = Get-KiriPid
foreach ($pin in [P]::ByClass("KiriPinWindow")) {
  [void][P]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero)
}
Start-Sleep -Milliseconds 500
"PINS_AT_START=$(([P]::ByClass('KiriPinWindow')).Count)"

for ($round = 1; $round -le $Rounds; $round++) {
  $pinsBefore = ([P]::ByClass("KiriPinWindow")).Count
  Send-CaptureShortcut
  Start-Sleep -Milliseconds 2200
  $overlays = @([P]::WindowsOf([uint32]$kiri, "Tauri Window"))
  "ROUND=$round OVERLAYS=$($overlays.Count)"
  if ($overlays.Count -eq 0) { "ROUND=$round RESULT=no-overlay"; continue }
  $primary = $overlays | Where-Object { ([P]::RectOf($_)).StartsWith("0,0 ") } | Select-Object -First 1
  if (-not $primary) { $primary = $overlays[0] }
  "ROUND=$round PRIMARY=$([P]::RectOf($primary))"
  $raw = [P]::RectOf($primary)
  $originX = [int](($raw -split ' ')[0] -split ',')[0]
  $originY = [int](($raw -split ' ')[0] -split ',')[1]
  Drag-Real ($originX + 360) ($originY + 300) ($originX + 820) ($originY + 640)
  Start-Sleep -Milliseconds 800
  $button = Find-PinButton $primary
  if (-not $button) { "ROUND=$round RESULT=pin-button-missing"; continue }
  $b = $button.Current.BoundingRectangle
  Click-Real ([int]($b.Left + $b.Width / 2)) ([int]($b.Top + $b.Height / 2))
  Start-Sleep -Milliseconds 2600
  $overlaysAfter = @([P]::WindowsOf([uint32]$kiri, "Tauri Window")).Count
  $pinsAfter = ([P]::ByClass("KiriPinWindow")).Count
  "ROUND=$round RESULT overlays_after=$overlaysAfter pins_before=$pinsBefore pins_after=$pinsAfter"
  # Leave the screen clean for the next round.
  foreach ($pin in [P]::ByClass("KiriPinWindow")) {
    [void][P]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero)
  }
  Start-Sleep -Milliseconds 400
}
