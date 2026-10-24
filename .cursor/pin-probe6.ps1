$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Probe6 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="FindWindowExW")] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll", CharSet=CharSet.Ansi, EntryPoint="FindWindowExA")] public static extern IntPtr FindWindowExA(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="FindWindowW")] public static extern IntPtr FindWindowW(string cls, string title);
  public static IntPtr Found;
  public static uint Pid;
  public static void Scan() {
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      var cls = new StringBuilder(256); GetClassNameW(h, cls, 256);
      if (cls.ToString() == "KiriPinWindow") { Found = h; Pid = pid; }
      return true;
    }, IntPtr.Zero);
  }
}
"@
$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
$app = Start-Process -FilePath $exe -PassThru
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
[Probe6]::Scan()
Write-Host "enum pin=$([Probe6]::Found) pid=$([Probe6]::Pid) app=$($app.Id)"
Write-Host "FindWindowExW=$([Probe6]::FindWindowExW([IntPtr]::Zero, [IntPtr]::Zero, 'KiriPinWindow', $null))"
Write-Host "FindWindowExA=$([Probe6]::FindWindowExA([IntPtr]::Zero, [IntPtr]::Zero, 'KiriPinWindow', $null))"
Write-Host "FindWindowW=$([Probe6]::FindWindowW('KiriPinWindow', $null))"
Write-Host "FindWindowExW-Tauri=$([Probe6]::FindWindowExW([IntPtr]::Zero, [IntPtr]::Zero, 'Tauri Window', $null))"
Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
