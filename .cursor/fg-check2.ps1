Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public static class Q {
  public delegate bool E(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(E e, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
  public struct RECT { public int Left, Top, Right, Bottom; }
  public static List<IntPtr> Pins() { var l = new List<IntPtr>(); EnumWindows((h,x)=>{ var s=new StringBuilder(128); GetClassName(h,s,128); if(s.ToString()=="KiriPinWindow") l.Add(h); return true; }, IntPtr.Zero); return l; }
}
"@
$p = Start-Process notepad -PassThru
Start-Sleep -Milliseconds 1200
$p.Refresh(); $n = $p.MainWindowHandle
[Q]::SetForegroundWindow($n) | Out-Null
Start-Sleep -Milliseconds 400
$pin = [Q]::Pins()[0]
$ex = [Q]::GetWindowLongPtr($pin, -20).ToInt64()
"EX_BEFORE=0x$($ex.ToString('X'))"
[Q]::SetWindowLongPtr($pin, -20, [IntPtr]($ex -bor 0x08000000)) | Out-Null
$ex2 = [Q]::GetWindowLongPtr($pin, -20).ToInt64()
"EX_AFTER=0x$($ex2.ToString('X')) NOACTIVATE=$((($ex2 -band 0x08000000) -ne 0))"
$r = New-Object Q+RECT
[Q]::GetWindowRect($pin, [ref]$r) | Out-Null
[Q]::SetCursorPos([int](($r.Left+$r.Right)/2), [int](($r.Top+$r.Bottom)/2)) | Out-Null
Start-Sleep -Milliseconds 300
"FG_BEFORE=0x$(([Q]::GetForegroundWindow()).ToInt64().ToString('X'))"
[Q]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
[Q]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 600
"FG_AFTER=0x$(([Q]::GetForegroundWindow()).ToInt64().ToString('X')) NOTEPAD=0x$($n.ToInt64().ToString('X'))"
Stop-Process -Id $p.Id -Force
