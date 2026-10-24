Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class F {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
$p = Start-Process notepad -PassThru
Start-Sleep -Milliseconds 1200
$p.Refresh()
$n = $p.MainWindowHandle
[F]::SetForegroundWindow($n) | Out-Null
Start-Sleep -Milliseconds 500
"FG1=0x$(([F]::GetForegroundWindow()).ToInt64().ToString('X')) NOTEPAD=0x$($n.ToInt64().ToString('X'))"
Add-Type @"
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public static class P {
  public delegate bool E(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(E e, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int Left, Top, Right, Bottom; }
  public static List<IntPtr> Pins() { var l = new List<IntPtr>(); EnumWindows((h,x)=>{ var s=new StringBuilder(128); GetClassName(h,s,128); if(s.ToString()=="KiriPinWindow") l.Add(h); return true; }, IntPtr.Zero); return l; }
}
"@
$pin = [P]::Pins()[0]
$r = New-Object P+RECT
[P]::GetWindowRect($pin, [ref]$r) | Out-Null
[F]::SetCursorPos([int](($r.Left+$r.Right)/2), [int](($r.Top+$r.Bottom)/2)) | Out-Null
Start-Sleep -Milliseconds 300
"FG2=0x$(([F]::GetForegroundWindow()).ToInt64().ToString('X'))"
[F]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
[F]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 600
"FG3=0x$(([F]::GetForegroundWindow()).ToInt64().ToString('X')) NOTEPAD_VISIBLE=$([F]::IsWindowVisible($n)) NOTEPAD_ICONIC=$([F]::IsIconic($n)) ALIVE=$(-not $p.HasExited)"
Stop-Process -Id $p.Id -Force
