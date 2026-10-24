# QA probe: wheel-zoom fidelity at different synthetic input cadences.
# Not part of the product.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CadenceProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
function Get-Pin { return [CadenceProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }
function Get-Size($h) {
  $r = New-Object CadenceProbe+RECT
  [void][CadenceProbe]::GetWindowRect($h, [ref]$r)
  return @{ W = $r.Right - $r.Left; H = $r.Bottom - $r.Top; X = $r.Left; Y = $r.Top }
}
function Send-Notches([int]$count, [int]$gapMs) {
  for ($i = 0; $i -lt $count; $i++) {
    [CadenceProbe]::mouse_event(0x0800, 0, 0, 120, [UIntPtr]::Zero)
    if ($gapMs -gt 0) { Start-Sleep -Milliseconds $gapMs }
  }
}
function Applied([int]$width) { return [math]::Log($width / 400.0) / [math]::Log(1.1) }

try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 4

  $bitmap = New-Object System.Drawing.Bitmap(400, 300)
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
  $bitmap.Dispose()
  Start-Sleep -Milliseconds 300
  $paste = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
  $null = $paste.WaitForExit(8000)
  Start-Sleep -Milliseconds 700
  $pin = Get-Pin
  if ($pin -eq [IntPtr]::Zero) { "NO_PIN"; exit 1 }
  $size = Get-Size $pin
  [void][CadenceProbe]::SetCursorPos($size.X + 200, $size.Y + 150)
  Start-Sleep -Milliseconds 200
  "START width=$($size.W)"
  $previous = [double]0
  foreach ($gap in @(5, 10, 20)) {
    Send-Notches 30 $gap
    Start-Sleep -Milliseconds 1500
    $size = Get-Size $pin
    $total = Applied $size.W
    "GAP_${gap}ms width=$($size.W) applied_total=$([math]::Round($total, 2)) this_batch=$([math]::Round($total - $previous, 2)) H=$($size.H)"
    $previous = $total
  }
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
}
