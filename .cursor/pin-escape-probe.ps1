param([string]$Scenario = "light")
# Escape probe: isolates whether the pin cap, a wheel burst, or a light run
# changes global Escape behaviour. Not part of the product.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class EscProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
}
"@

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
function Get-Pins {
  $found = @(); $previous = [IntPtr]::Zero
  while ($true) {
    $h = [EscProbe]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Send-Escape {
  [EscProbe]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [EscProbe]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
}
function Send-Mouse([uint32]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
  [EscProbe]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}
function Invoke-PastePin {
  $process = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
  $null = $process.WaitForExit(15000)
  Start-Sleep -Milliseconds 120
}
function Set-ClipboardImage([int]$width, [int]$height) {
  $bitmap = New-Object System.Drawing.Bitmap($width, $height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(20, 100, 200))
  $graphics.Dispose()
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
  $bitmap.Dispose()
  Start-Sleep -Milliseconds 150
}

try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 5
  Set-ClipboardImage 320 240
  [void][EscProbe]::SetCursorPos(1200, 700)

  $pastes = switch ($Scenario) {
    "light" { 3 }
    "cap" { 18 }
    "burst" { 1 }
    default { 1 }
  }
  for ($index = 0; $index -lt $pastes; $index++) { Invoke-PastePin }
  Start-Sleep -Milliseconds 600
  Write-Host "scenario=$Scenario pins=$((Get-Pins).Count)"
  if ($Scenario -eq "burst") {
    for ($step = 0; $step -lt 30; $step++) {
      Send-Mouse 0x0800 0 0 120
      Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 2000
  }
  [void][EscProbe]::SetCursorPos(1200, 700)
  Start-Sleep -Milliseconds 300
  $under = [EscProbe]::WindowFromPoint((New-Object EscProbe+POINT(1200, 700)))
  $before = (Get-Pins).Count
  Write-Host "before Escape pins=$before underPointerIsPin=$((Get-Pins) -contains $under)"
  Send-Escape
  Start-Sleep -Milliseconds 700
  $after = (Get-Pins).Count
  Write-Host "after Escape pins=$after closed=$($before - $after)"
  if ($Scenario -eq "burst") {
    # A second press isolates a one-off delivery problem from a dead hook.
    Send-Escape
    Start-Sleep -Milliseconds 700
    Write-Host "after second Escape pins=$((Get-Pins).Count)"
  }
}
finally {
  Start-Sleep -Milliseconds 200
  $log = Join-Path $env:LOCALAPPDATA "io.yuxino.kiri\logs\kiri.log"
  if (Test-Path $log) {
    Select-String -Path $log -Pattern "\[pin\]" | Select-Object -Last 6 | ForEach-Object { Write-Host $_.Line }
  }
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
}
