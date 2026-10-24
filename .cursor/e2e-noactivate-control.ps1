$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;using System.Drawing;using System.Runtime.InteropServices;using System.Windows.Forms;
public class NoActivateForm : Form {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint flags);
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x0021) { m.Result = (IntPtr)3; return; } // WM_MOUSEACTIVATE -> MA_NOACTIVATE
    base.WndProc(ref m);
  }
  public NoActivateForm() {
    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar = false;
    TopMost = true;
    StartPosition = FormStartPosition.Manual;
    Bounds = new Rectangle(1500, 800, 240, 160);
    BackColor = Color.Magenta;
  }
}
public static class Probe {
  public static string Run() {
    var note = System.Diagnostics.Process.Start("notepad.exe");
    System.Threading.Thread.Sleep(1500);
    note.Refresh();
    IntPtr h = note.MainWindowHandle;
    NoActivateForm.SetForegroundWindow(h);
    System.Threading.Thread.Sleep(500);
    string before = "0x" + NoActivateForm.GetForegroundWindow().ToInt64().ToString("X");
    var form = new NoActivateForm();
    form.Show();
    System.Threading.Thread.Sleep(500);
    NoActivateForm.SetCursorPos(1620, 880);
    System.Threading.Thread.Sleep(200);
    NoActivateForm.mouse_event(2, 0, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(120);
    string during = "0x" + NoActivateForm.GetForegroundWindow().ToInt64().ToString("X");
    NoActivateForm.mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(400);
    string after = "0x" + NoActivateForm.GetForegroundWindow().ToInt64().ToString("X");
    form.Close();
    note.Kill();
    return "NOTE=0x" + h.ToInt64().ToString("X") + " BEFORE=" + before + " DURING=" + during + " AFTER=" + after;
  }
}
"@ -ReferencedAssemblies System.Windows.Forms, System.Drawing
[Probe]::Run()

