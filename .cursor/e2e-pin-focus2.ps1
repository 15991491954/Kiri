$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;using System.Collections.Generic;using System.Runtime.InteropServices;using System.Text;
public static class G {
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
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [StructLayout(LayoutKind.Sequential)] public struct R{public int L,T,Rr,B;}
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out R r);
 [StructLayout(LayoutKind.Sequential)] public struct GUI { public int cbSize; public uint flags; public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret; public R rcCaret; }
 [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread, ref GUI info);
 public static List<IntPtr> ByClass(string n){var l=new List<IntPtr>();EnumWindows((h,x)=>{var s=new StringBuilder(256);GetClassName(h,s,256);if(s.ToString()==n)l.Add(h);return true;},IntPtr.Zero);return l;}
 public static string Title(IntPtr h){var s=new StringBuilder(512);GetWindowText(h,s,512);return s.ToString();}
 public static string EditText(IntPtr h){var e=FindWindowEx(h,IntPtr.Zero,"Edit",null);if(e==IntPtr.Zero)return "(no edit)";var s=new StringBuilder(4096);SendMessage(e,0x000D,(IntPtr)4096,s);return s.ToString();}
 public static string Focus(uint thread){var g=new GUI();g.cbSize=Marshal.SizeOf(g);if(!GetGUIThreadInfo(thread,ref g))return "err"; return string.Format("active=0x{0:X} focus=0x{1:X}",g.hwndActive.ToInt64(),g.hwndFocus.ToInt64());}
}
"@
$note = Start-Process notepad -PassThru
Start-Sleep -Milliseconds 1500
$note.Refresh()
$h = $note.MainWindowHandle
[G]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 600
$thread = 0; [void][G]::GetWindowThreadProcessId($h, [ref]$thread)
"NOTE=0x$($h.ToInt64().ToString('X')) THREAD=$thread FG=0x$(([G]::GetForegroundWindow()).ToInt64().ToString('X'))"
"GUI_BEFORE=$([G]::Focus($thread))"
[System.Windows.Forms.SendKeys]::SendWait("AAA")
Start-Sleep -Milliseconds 500
"TEXT_BEFORE=$([G]::EditText($h)) TITLE=$([G]::Title($h))"
$pin = ([G]::ByClass("KiriPinWindow"))[0]
$r = New-Object G+R; [G]::GetWindowRect($pin, [ref]$r) | Out-Null
[G]::SetCursorPos([int](($r.L+$r.Rr)/2), [int](($r.T+$r.B)/2)) | Out-Null
Start-Sleep -Milliseconds 200
[G]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 100; [G]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 600
"FG_AFTER=0x$(([G]::GetForegroundWindow()).ToInt64().ToString('X')) GUI_AFTER=$([G]::Focus($thread))"
[System.Windows.Forms.SendKeys]::SendWait("BBB")
Start-Sleep -Milliseconds 600
"TEXT_AFTER=$([G]::EditText($h)) TITLE_AFTER=$([G]::Title($h))"
"FG_FINAL=0x$(([G]::GetForegroundWindow()).ToInt64().ToString('X'))"
Stop-Process -Id $note.Id -Force
