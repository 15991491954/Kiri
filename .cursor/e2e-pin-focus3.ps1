$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;using System.Collections.Generic;using System.Runtime.InteropServices;using System.Text;
public static class C {
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
 public static string Title(IntPtr h){var s=new StringBuilder(512);GetWindowText(h,s,512);return s.ToString();}
 public static string EditText(IntPtr h){var e=FindWindowEx(h,IntPtr.Zero,"Edit",null);if(e==IntPtr.Zero)return "(no edit)";var s=new StringBuilder(4096);SendMessage(e,0x000D,(IntPtr)4096,s);return s.ToString();}
 public static string ClassOf(IntPtr h){var s=new StringBuilder(256);GetClassName(h,s,256);return s.ToString();}
 public static IntPtr At(int x,int y){var p=new P2();p.X=x;p.Y=y;return WindowFromPoint(p);}
}
"@
$note = Start-Process notepad -PassThru
Start-Sleep -Milliseconds 1500
$note.Refresh()
$h = $note.MainWindowHandle
[void][C]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 500
"NOTE=0x$($h.ToInt64().ToString('X')) FG=0x$(([C]::GetForegroundWindow()).ToInt64().ToString('X'))"
# Control 1: click inside the notepad client area.
$r = New-Object C+P2; $r.X = 100; $r.Y = 100
[C]::SetCursorPos(400, 400) | Out-Null; Start-Sleep -Milliseconds 150
$hitNote = [C]::At(400,400)
"CLICKTARGET_NOTE_CLASS=$([C]::ClassOf($hitNote))"
[C]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80; [C]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 400
"AFTER_NOTE_CLICK FG=0x$(([C]::GetForegroundWindow()).ToInt64().ToString('X'))"
[System.Windows.Forms.SendKeys]::SendWait("one")
Start-Sleep -Milliseconds 400
"TEXT1=$([C]::EditText($h))"
# Control 2: click on the empty desktop.
[C]::SetCursorPos(600, 1200) | Out-Null; Start-Sleep -Milliseconds 150
$hitDesk = [C]::At(600,1200)
"CLICKTARGET_DESK_CLASS=$([C]::ClassOf($hitDesk)) hwnd=0x$($hitDesk.ToInt64().ToString('X'))"
[void][C]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 300
[C]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80; [C]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 400
"AFTER_DESK_CLICK FG=0x$(([C]::GetForegroundWindow()).ToInt64().ToString('X'))"
[System.Windows.Forms.SendKeys]::SendWait("two")
Start-Sleep -Milliseconds 400
"TEXT2=$([C]::EditText($h))"
Stop-Process -Id $note.Id -Force
