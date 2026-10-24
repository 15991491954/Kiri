$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Probe4 {
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="FindWindowExW")] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll", CharSet=CharSet.Ansi, EntryPoint="FindWindowExA")] public static extern IntPtr FindWindowExA(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
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
Start-Sleep -Milliseconds 600
$w = [Probe4]::FindWindowExW([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", $null)
$a = [Probe4]::FindWindowExA([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", $null)
Write-Host "FindWindowExW=$w FindWindowExA=$a"
if ($w -ne [IntPtr]::Zero) {
  $r = New-Object Probe4+RECT
  [void][Probe4]::GetWindowRect($w, [ref]$r)
  $ex = ([Probe4]::GetWindowLongPtr($w, -20)).ToInt64()
  $cls = New-Object System.Text.StringBuilder 128
  [void][Probe4]::GetClassNameW($w, $cls, 128)
  $title = New-Object System.Text.StringBuilder 256
  [void][Probe4]::GetWindowTextW($w, $title, 256)
  Write-Host ("class={0} title={1} rect={2},{3},{4}x{5} ex=0x{6:X} vis={7}" -f $cls, $title, $r.Left, $r.Top, ($r.Right-$r.Left), ($r.Bottom-$r.Top), $ex, [Probe4]::IsWindowVisible($w))
}
Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
