param([string]$Mode = "probe")
$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ProbeNative {
  [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-WindowsByClass([string]$cls) {
  $found = @(); $previous = [IntPtr]::Zero
  while ($true) {
    $h = [ProbeNative]::FindWindowEx([IntPtr]::Zero, $previous, $cls, $null)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return ,$found
}
$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
Write-Host "STEP 0 exe=$exe"
Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Write-Host "STEP 1 start app"
$app = Start-Process -FilePath $exe -PassThru
Write-Host "STEP 2 app pid=$($app.Id)"
Start-Sleep -Seconds 4

Write-Host "STEP 3 clipboard image"
$bitmap = New-Object System.Drawing.Bitmap(400, 300)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.Clear([System.Drawing.Color]::FromArgb(30, 90, 200))
$graphics.Dispose()
[System.Windows.Forms.Clipboard]::SetImage($bitmap)
$bitmap.Dispose()
Write-Host "STEP 4 clipboard set"

$second = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
Write-Host "STEP 5 second pid=$($second.Id)"
$null = $second.WaitForExit(8000)
Write-Host "STEP 6 second exited=$($second.HasExited)"
Start-Sleep -Seconds 2

$pins = Get-WindowsByClass "KiriPinWindow"
Write-Host "STEP 7 pins=$($pins.Count)"
foreach ($pin in $pins) {
  $r = New-Object ProbeNative+RECT
  [void][ProbeNative]::GetWindowRect($pin, [ref]$r)
  $ex = ([ProbeNative]::GetWindowLongPtr($pin, -20)).ToInt64()
  Write-Host ("  pin hwnd={0} rect={1},{2},{3},{4} ex=0x{5:X} visible={6}" -f $pin, $r.Left, $r.Top, ($r.Right-$r.Left), ($r.Bottom-$r.Top), $ex, [ProbeNative]::IsWindowVisible($pin))
}
Write-Host "STEP 8 done"
