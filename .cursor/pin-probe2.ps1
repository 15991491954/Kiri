$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Probe2 {
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
    $h = [Probe2]::FindWindowEx([IntPtr]::Zero, $previous, $cls, $null)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return ,$found
}
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
Write-Host "clipboard set"
$second = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
$null = $second.WaitForExit(8000)
Write-Host "second exited=$($second.HasExited)"
for ($i = 0; $i -lt 30; $i++) {
  $alive = [bool](Get-Process -Id $app.Id -ErrorAction SilentlyContinue)
  $pins = Get-WindowsByClass "KiriPinWindow"
  $badges = Get-WindowsByClass "KiriPinBadge"
  $detail = ""
  foreach ($pin in $pins) {
    $r = New-Object Probe2+RECT
    [void][Probe2]::GetWindowRect($pin, [ref]$r)
    $ex = ([Probe2]::GetWindowLongPtr($pin, -20)).ToInt64()
    $detail += (" pin={0} rect={1},{2},{3}x{4} ex=0x{5:X} vis={6}" -f $pin, $r.Left, $r.Top, ($r.Right-$r.Left), ($r.Bottom-$r.Top), $ex, [Probe2]::IsWindowVisible($pin))
  }
  Write-Host ("t={0}ms alive={1} pins={2} badges={3}{4}" -f ($i*200), $alive, $pins.Count, $badges.Count, $detail)
  Start-Sleep -Milliseconds 200
}
Write-Host "now=$(Get-Date -Format o)"
