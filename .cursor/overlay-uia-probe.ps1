Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class V {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public static List<IntPtr> Top() { var f = new List<IntPtr>(); EnumWindows((h, _) => { f.Add(h); return true; }, IntPtr.Zero); return f; }
  public static string ClassOf(IntPtr h) { var b = new StringBuilder(256); GetClassName(h, b, b.Capacity); return b.ToString(); }
  public static string Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return string.Format("{0},{1} {2}x{3}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top); }
  public static bool Topmost(IntPtr h) { long s = (long)GetWindowLongPtr(h, -20); return (s & 0x8) != 0; }
}
"@
function Get-Overlays {
  @([V]::Top() | Where-Object {
    if ([V]::ClassOf($_) -ne "Tauri Window" -or -not [V]::IsWindowVisible($_) -or -not [V]::Topmost($_)) { return $false }
    $r = New-Object V+RECT
    [V]::GetWindowRect($_, [ref]$r) | Out-Null
    ($r.Right - $r.Left) -ge 800
  })
}
foreach ($vk in @(0x11, 0x10, 0x41)) { [V]::keybd_event($vk, 0, 0, [UIntPtr]::Zero) }
Start-Sleep -Milliseconds 50
[V]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero)
[V]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)
[V]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
$deadline = (Get-Date).AddSeconds(6)
while ((Get-Date) -lt $deadline -and (Get-Overlays).Count -eq 0) { Start-Sleep -Milliseconds 100 }
Start-Sleep -Milliseconds 1500
$overlays = Get-Overlays
Write-Output ("OVERLAYS={0}" -f $overlays.Count)
foreach ($o in $overlays) { Write-Output ("  overlay=0x{0:X} rect={1}" -f $o.ToInt64(), [V]::Rect($o)) }
$target = $null
foreach ($o in $overlays) {
  $r = New-Object V+RECT
  [V]::GetWindowRect($o, [ref]$r) | Out-Null
  if (400 -ge $r.Left -and 400 -le $r.Right) { $target = $o }
}
Write-Output ("TARGET=0x{0:X} FG=0x{1:X}" -f $target.ToInt64(), ([V]::GetForegroundWindow()).ToInt64())
[V]::SetCursorPos(380, 380) | Out-Null
Start-Sleep -Milliseconds 150
[V]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 100
for ($step = 1; $step -le 10; $step++) {
  [V]::SetCursorPos((380 + $step * 34), (380 + $step * 24)) | Out-Null
  Start-Sleep -Milliseconds 25
}
[V]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 1000
$root = [System.Windows.Automation.AutomationElement]::FromHandle($target)
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
Write-Output ("UIA_DESCENDANTS={0}" -f $all.Count)
$buttons = 0
for ($i = 0; $i -lt $all.Count; $i++) {
  $e = $all.Item($i)
  if ($e.Current.ControlType.ProgrammaticName -eq "ControlType.Button") {
    $buttons++
    Write-Output ("  BUTTON name='{0}' class='{1}' enabled={2} bounds={3}" -f $e.Current.Name, $e.Current.ClassName, $e.Current.IsEnabled, $e.Current.BoundingRectangle)
  }
}
Write-Output ("UIA_BUTTONS={0}" -f $buttons)
[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep -Milliseconds 600
Write-Output ("OVERLAYS_AFTER_ESC={0}" -f (Get-Overlays).Count)
