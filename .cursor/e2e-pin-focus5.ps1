$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;using System.Collections.Generic;using System.Runtime.InteropServices;using System.Text;
public static class Q {
 public delegate bool E(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(E p, IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int c);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int SendMessage(IntPtr h, uint m, IntPtr w, StringBuilder l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
 [StructLayout(LayoutKind.Sequential)] public struct R{public int L,T,Rr,B;}
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out R r);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [StructLayout(LayoutKind.Sequential)] public struct GUI { public uint cbSize; public uint flags; public IntPtr hwndActive; public IntPtr hwndFocus; public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret; public R rcCaret; }
 [DllImport("user32.dll", SetLastError=true)] public static extern bool GetGUIThreadInfo(uint thread, ref GUI info);
 public static List<IntPtr> ByClass(string n){var l=new List<IntPtr>();EnumWindows((h,x)=>{var s=new StringBuilder(256);GetClassName(h,s,256);if(s.ToString()==n)l.Add(h);return true;},IntPtr.Zero);return l;}
 public static string Focus(uint thread){var g=new GUI();g.cbSize=(uint)Marshal.SizeOf(g);if(!GetGUIThreadInfo(thread,ref g))return "err "+Marshal.GetLastWin32Error();return string.Format("active=0x{0:X} focus=0x{1:X}",g.hwndActive.ToInt64(),g.hwndFocus.ToInt64());}
 public static string EditText(IntPtr h){var e=FindWindowEx(h,IntPtr.Zero,"Edit",null);if(e==IntPtr.Zero)return "(no edit)";var s=new StringBuilder(4096);SendMessage(e,0x000D,(IntPtr)4096,s);return s.ToString();}
}
"@
$note = Start-Process notepad -PassThru
Start-Sleep -Milliseconds 1500
$note.Refresh()
$h = $note.MainWindowHandle
[void][Q]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 500
$thread = 0; [void][Q]::GetWindowThreadProcessId($h, [ref]$thread)
"THREAD=$thread FG=0x$(([Q]::GetForegroundWindow()).ToInt64().ToString('X')) GUI=$([Q]::Focus($thread))"
[System.Windows.Forms.SendKeys]::SendWait("abc")
Start-Sleep -Milliseconds 400
"TEXT1=$([Q]::EditText($h))"
$pin = ([Q]::ByClass("KiriPinWindow"))[0]
$r = New-Object Q+R; [Q]::GetWindowRect($pin, [ref]$r) | Out-Null
[Q]::SetCursorPos([int](($r.L+$r.Rr)/2), [int](($r.T+$r.B)/2)) | Out-Null
Start-Sleep -Milliseconds 250
"GUI_PRE=$([Q]::Focus($thread)) FG_PRE=0x$(([Q]::GetForegroundWindow()).ToInt64().ToString('X'))"
[Q]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
for ($i=0; $i -lt 6; $i++) { Start-Sleep -Milliseconds 40; "D$i FG=0x$(([Q]::GetForegroundWindow()).ToInt64().ToString('X')) GUI=$([Q]::Focus($thread))" }
[Q]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
for ($i=0; $i -lt 4; $i++) { Start-Sleep -Milliseconds 60; "U$i FG=0x$(([Q]::GetForegroundWindow()).ToInt64().ToString('X')) GUI=$([Q]::Focus($thread))" }
[System.Windows.Forms.SendKeys]::SendWait("xyz")
Start-Sleep -Milliseconds 500
"TEXT2=$([Q]::EditText($h))"
Stop-Process -Id $note.Id -Force
