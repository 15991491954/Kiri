param()
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;using System.Collections.Generic;using System.Runtime.InteropServices;using System.Text;
public static class F {
 public delegate bool E(IntPtr h, IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct P2 { public int X, Y; }
 [DllImport("user32.dll")] public static extern bool EnumWindows(E p, IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int c);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
 [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h,int i);
 [StructLayout(LayoutKind.Sequential)] public struct R{public int L,T,Rr,B;}
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out R r);
 public static List<IntPtr> ByClass(string n){var l=new List<IntPtr>();EnumWindows((h,x)=>{var s=new StringBuilder(256);GetClassName(h,s,256);if(s.ToString()==n)l.Add(h);return true;},IntPtr.Zero);return l;}
 public static string Title(IntPtr h){var s=new StringBuilder(512);GetWindowText(h,s,512);return s.ToString();}
}
"@
$note = Start-Process notepad -PassThru
Start-Sleep -Milliseconds 1200
$note.Refresh()
$h = $note.MainWindowHandle
[F]::ShowWindow($h, 9) | Out-Null
[F]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 500
"TITLE_BEFORE=$([F]::Title($h)) FG=$([F]::GetForegroundWindow().ToInt64().ToString('X'))"
[System.Windows.Forms.SendKeys]::SendWait("before")
Start-Sleep -Milliseconds 400
"TITLE_AFTER_TYPE=$([F]::Title($h))"
$pins = [F]::ByClass("KiriPinWindow")
$pin = $pins[0]
$r = New-Object F+R; [F]::GetWindowRect($pin, [ref]$r) | Out-Null
$cx = [int](($r.L + $r.Rr)/2); $cy = [int](($r.T + $r.B)/2)
[F]::SetCursorPos($cx,$cy) | Out-Null
Start-Sleep -Milliseconds 200
[F]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
[F]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 500
for ($i=0; $i -lt 4; $i++) { "FG_AFTER_CLICK_$i=$([F]::GetForegroundWindow().ToInt64().ToString('X'))" ; Start-Sleep -Milliseconds 250 }
[System.Windows.Forms.SendKeys]::SendWait("after")
Start-Sleep -Milliseconds 500
"TITLE_AFTER_PIN_CLICK_TYPE=$([F]::Title($h))"
$fg = [F]::GetForegroundWindow()
"FG_FINAL=0x$($fg.ToInt64().ToString('X')) CLASS=$((New-Object System.Text.StringBuilder 256 | ForEach-Object { [void][F]::GetClassName($fg,$_,256); $_.ToString() })) NOTE=$($fg -eq $h)"
Stop-Process -Id $note.Id -Force
