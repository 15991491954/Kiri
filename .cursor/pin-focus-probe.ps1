# Focus probe: does a native pin steal the foreground window?
# Scenario A: Kiri already running in the tray (real F3 path).
# Scenario B: Kiri cold-starts with --paste-pin while another app is focused.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Probe {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, IntPtr t);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public static string Describe(IntPtr h) { var c=new StringBuilder(256); var t=new StringBuilder(256);
    GetClassNameW(h,c,256); GetWindowTextW(h,t,256);
    return "hwnd=" + h + " [" + c + "] " + t; }
}
"@

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path

function Get-Pins {
  $found = @()
  $previous = [IntPtr]::Zero
  while ($true) {
    $h = [Probe]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h
    $previous = $h
  }
  return $found
}

function Set-ClipboardImage([int]$width, [int]$height, $colour) {
  $bitmap = New-Object System.Drawing.Bitmap($width, $height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear($colour)
  $graphics.Dispose()
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
  $bitmap.Dispose()
  Start-Sleep -Milliseconds 250
}

function Start-Kiri([string[]]$arguments) {
  if ($arguments -and $arguments.Count -gt 0) {
    Start-Process -FilePath $exe -ArgumentList $arguments | Out-Null
  } else {
    Start-Process -FilePath $exe | Out-Null
  }
}

function Wait-Pins([int]$count, [int]$timeoutMs = 20000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    $pins = Get-Pins
    if ($pins.Count -ge $count) { return $pins }
    Start-Sleep -Milliseconds 100
  }
  return (Get-Pins)
}

try {
  Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Get-Process -Name notepad -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 400

  # --- Scenario A: warm Kiri, notepad focused -------------------------------
  Start-Kiri @()
  Start-Sleep -Seconds 4
  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1500
  $notepad.Refresh()
  [void][Probe]::SetForegroundWindow($notepad.MainWindowHandle)
  Start-Sleep -Milliseconds 400
  $before = [Probe]::GetForegroundWindow()
  Write-Host ("A before: " + [Probe]::Describe($before))
  Set-ClipboardImage 320 240 ([System.Drawing.Color]::FromArgb(10, 120, 200))
  Start-Kiri @("--paste-pin")
  $pins = Wait-Pins 1
  Start-Sleep -Milliseconds 400
  $after = [Probe]::GetForegroundWindow()
  Write-Host ("A after : " + [Probe]::Describe($after))
  Write-Host ("A pins  : " + $pins.Count + " unchanged=" + ($before -eq $after) +
    " notepad=" + ($after -eq $notepad.MainWindowHandle))
  $notepad | Stop-Process -Force
  Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600

  # --- Scenario B: cold Kiri with --paste-pin, notepad focused --------------
  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1500
  $notepad.Refresh()
  [void][Probe]::SetForegroundWindow($notepad.MainWindowHandle)
  Start-Sleep -Milliseconds 400
  $before = [Probe]::GetForegroundWindow()
  Write-Host ("B before: " + [Probe]::Describe($before))
  Set-ClipboardImage 300 200 ([System.Drawing.Color]::FromArgb(200, 60, 40))
  Start-Kiri @("--paste-pin")
  $pins = Wait-Pins 1 30000
  Start-Sleep -Milliseconds 400
  $after = [Probe]::GetForegroundWindow()
  Write-Host ("B after : " + [Probe]::Describe($after))
  Write-Host ("B pins  : " + $pins.Count + " unchanged=" + ($before -eq $after) +
    " notepad=" + ($after -eq $notepad.MainWindowHandle))
  $notepad | Stop-Process -Force
}
finally {
  Get-Process -Name notepad -ErrorAction SilentlyContinue | Stop-Process -Force
  Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
}
