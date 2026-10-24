# QA probe: does the wheel zoom lose notches when they are sent rapidly?
# Not part of the product.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ZoomProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
function Send-Wheel([int]$notches) {
  for ($i = 0; $i -lt $notches; $i++) {
    [ZoomProbe]::mouse_event(0x0800, 0, 0, 120, [UIntPtr]::Zero)
  }
}
function Get-Pin {
  $h = [ZoomProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero)
  return $h
}
function Get-Size($h) {
  $r = New-Object ZoomProbe+RECT
  [void][ZoomProbe]::GetWindowRect($h, [ref]$r)
  return @{ W = $r.Right - $r.Left; H = $r.Bottom - $r.Top; X = $r.Left; Y = $r.Top }
}

try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 4

  $bitmap = New-Object System.Drawing.Bitmap(400, 300)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(255, 40, 120, 200))
  $graphics.Dispose()
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
  $bitmap.Dispose()
  Start-Sleep -Milliseconds 300

  $paste = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
  $null = $paste.WaitForExit(8000)
  Start-Sleep -Milliseconds 700
  $pin = Get-Pin
  if ($pin -eq [IntPtr]::Zero) { "NO_PIN"; exit 1 }
  $size = Get-Size $pin
  "START=$($size.W)x$($size.H)"

  [void][ZoomProbe]::SetCursorPos($size.X + [int]($size.W / 2), $size.Y + [int]($size.H / 2))
  Start-Sleep -Milliseconds 200

  # Ten notches with 80 ms between them: the reference response.
  for ($i = 1; $i -le 10; $i++) {
    Send-Wheel 1
    Start-Sleep -Milliseconds 80
  }
  Start-Sleep -Milliseconds 600
  $spaced = Get-Size $pin
  "SPACED_10=$($spaced.W)x$($spaced.H) expected≈$([int](400 * [math]::Pow(1.1, 10)))"

  # Thirty notches fired as fast as the process can send them.
  Send-Wheel 30
  Start-Sleep -Milliseconds 1800
  $rapid = Get-Size $pin
  "RAPID_30=$($rapid.W)x$($rapid.H) expected≈6532 (32 MP cap) or 8000 (edge cap)"
  "ALIVE=$([ZoomProbe]::IsWindow($pin))"
  if ($rapid.W -lt 6000) {
    # Send another ten slowly: if the pin keeps growing, rapid input was lost.
    for ($i = 1; $i -le 10; $i++) { Send-Wheel 1; Start-Sleep -Milliseconds 100 }
    Start-Sleep -Milliseconds 900
    $after = Get-Size $pin
    "AFTER_10_MORE=$($after.W)x$($after.H)"
  }
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
}
