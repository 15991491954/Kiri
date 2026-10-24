$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;using System.Collections.Generic;using System.Runtime.InteropServices;using System.Text;
public static class K {
 public delegate bool E(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(E p, IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int c);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int SendMessage(IntPtr h, uint m, IntPtr w, StringBuilder l);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
 [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(P2 p);
 [StructLayout(LayoutKind.Sequential)] public struct P2 { public int X, Y; }
 [StructLayout(LayoutKind.Sequential)] public struct R{public int L,T,Rr,B;}
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out R r);
 public static List<IntPtr> ByClass(string n){var l=new List<IntPtr>();EnumWindows((h,x)=>{var s=new StringBuilder(256);GetClassName(h,s,256);if(s.ToString()==n)l.Add(h);return true;},IntPtr.Zero);return l;}
 public static string ClassOf(IntPtr h){var s=new StringBuilder(256);GetClassName(h,s,256);return s.ToString();}
 public static string EditText(IntPtr h){var e=FindWindowEx(h,IntPtr.Zero,"Edit",null);if(e==IntPtr.Zero)return "(no edit)";var s=new StringBuilder(4096);SendMessage(e,0x000D,(IntPtr)4096,s);return s.ToString();}
}
"@
$note = Start-Process notepad -PassThru
Start-Sleep -Milliseconds 1500
$note.Refresh()
$h = $note.MainWindowHandle
[void][K]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 500
"NOTE=0x$($h.ToInt64().ToString('X')) FG=0x$(([K]::GetForegroundWindow()).ToInt64().ToString('X'))"
# Control: click inside the Notepad window.
[K]::SetCursorPos(300, 300) | Out-Null
Start-Sleep -Milliseconds 200
"CTRL_HIT_CLASS=$([K]::ClassOf([K]::WindowFromPoint((New-Object K+P2 -Property @{X=300;Y=300}))))"
[K]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80; [K]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 400
"AFTER_CTRL_CLICK FG=0x$(([K]::GetForegroundWindow()).ToInt64().ToString('X'))"
[System.Windows.Forms.SendKeys]::SendWait("one")
Start-Sleep -Milliseconds 400
"CTRL_TEXT=$([K]::EditText($h))"
# Real test: click the pin.
[void][K]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 400
$pin = ([K]::ByClass("KiriPinWindow"))[0]
$r = New-Object K+R; [K]::GetWindowRect($pin, [ref]$r) | Out-Null
$cx = [int](($r.L+$r.Rr)/2); $cy = [int](($r.T+$r.B)/2)
[K]::SetCursorPos($cx,$cy) | Out-Null
Start-Sleep -Milliseconds 250
"PIN_HIT_CLASS=$([K]::ClassOf([K]::WindowFromPoint((New-Object K+P2 -Property @{X=$cx;Y=$cy}))))"
"FG_BEFORE_PIN_CLICK=0x$(([K]::GetForegroundWindow()).ToInt64().ToString('X'))"
[K]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 100; [K]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 400
"FG_AFTER_PIN_CLICK=0x$(([K]::GetForegroundWindow()).ToInt64().ToString('X'))"
[System.Windows.Forms.SendKeys]::SendWait("two")
Start-Sleep -Milliseconds 500
"PIN_TEXT=$([K]::EditText($h))"
"FG_FINAL=0x$(([K]::GetForegroundWindow()).ToInt64().ToString('X'))"
Stop-Process -Id $note.Id -Force
