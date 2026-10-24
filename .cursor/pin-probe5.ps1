$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Probe5 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static List<string> WindowsOf(uint processId) {
    var found = new List<string>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == processId) {
        var cls = new StringBuilder(256); GetClassNameW(h, cls, 256);
        var title = new StringBuilder(256); GetWindowTextW(h, title, 256);
        RECT r; GetWindowRect(h, out r);
        long ex = GetWindowLongPtr(h, -20).ToInt64();
        long style = GetWindowLongPtr(h, -16).ToInt64();
        found.Add(string.Format("[{0}] class='{1}' title='{2}' rect={3},{4},{5}x{6} style=0x{7:X} ex=0x{8:X} vis={9}",
          h, cls.ToString(), title.ToString(), r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, style, ex, IsWindowVisible(h)));
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
$app = Start-Process -FilePath $exe -PassThru
Write-Host "app pid=$($app.Id)"
Start-Sleep -Seconds 4
$bitmap = New-Object System.Drawing.Bitmap(400, 300)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.Clear([System.Drawing.Color]::FromArgb(30, 90, 200))
$graphics.Dispose()
[System.Windows.Forms.Clipboard]::SetImage($bitmap)
$bitmap.Dispose()
$second = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
$null = $second.WaitForExit(8000)
Start-Sleep -Milliseconds 800
[Probe5]::WindowsOf([uint32]$app.Id) | ForEach-Object { Write-Host $_ }
Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
