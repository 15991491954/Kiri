# QA probe: are rapid synthetic wheel notches dropped by the input path itself?
# Drives Notepad's edit control and reads its first visible line.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class WheelRef {
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

function Wheel([int]$count) {
  for ($i = 0; $i -lt $count; $i++) { [WheelRef]::mouse_event(0x0800, 0, 0, 4294967176, [UIntPtr]::Zero) }
}
function FirstLine($edit) { return [WheelRef]::SendMessage($edit, 0x00CE, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64() }

$notepad = $null
try {
  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1500
  $notepad.Refresh()
  [void][WheelRef]::SetForegroundWindow($notepad.MainWindowHandle)
  Start-Sleep -Milliseconds 400
  $edit = [WheelRef]::FindWindowEx($notepad.MainWindowHandle, [IntPtr]::Zero, "Edit", [IntPtr]::Zero)
  if ($edit -eq [IntPtr]::Zero) { "NO_EDIT"; exit 1 }

  $lines = (1..400 | ForEach-Object { "line $_" }) -join "`r`n"
  [System.Windows.Forms.Clipboard]::SetText($lines)
  [void][WheelRef]::SendMessage($edit, 0x0301, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_PASTE
  Start-Sleep -Milliseconds 500
  $rect = New-Object WheelRef+RECT
  [void][WheelRef]::GetWindowRect($edit, [ref]$rect)
  [void][WheelRef]::SetCursorPos([int](($rect.Left + $rect.Right) / 2), [int](($rect.Top + $rect.Bottom) / 2))
  Start-Sleep -Milliseconds 200

  $before = FirstLine $edit
  Wheel 30
  Start-Sleep -Milliseconds 1200
  $after = FirstLine $edit
  "RAPID_30 firstLine $before -> $after (delta $($after - $before))"

  $before = FirstLine $edit
  for ($i = 0; $i -lt 30; $i++) { [WheelRef]::mouse_event(0x0800, 0, 0, 4294967176, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80 }
  Start-Sleep -Milliseconds 800
  $after = FirstLine $edit
  "SPACED_30 firstLine $before -> $after (delta $($after - $before))"
}
finally {
  if ($notepad) { $notepad | Stop-Process -Force -ErrorAction SilentlyContinue }
}
