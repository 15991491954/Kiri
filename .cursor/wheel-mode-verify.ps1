$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class KiriWheelVerify {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  public const uint WHEEL = 0x0800;
  public static void Wheel(int x, int y, int delta) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(250);
    mouse_event(WHEEL, 0, 0, unchecked((uint)delta), UIntPtr.Zero);
  }
}
"@

function Read-Mode([string]$path) {
  if (Test-Path $path) { return ((Get-Content $path -Raw) -replace '\s+', ' ') }
  return "MISSING"
}

$exe = Join-Path (Get-Location) "src-tauri\target\debug\kiri.exe"
$modeFile = Join-Path $env:APPDATA "io.yuxino.kiri\capture-mode.json"
$hadMode = Test-Path $modeFile
$previousMode = if ($hadMode) { Get-Content $modeFile -Raw } else { $null }
if ($hadMode) { Remove-Item $modeFile -Force }

$p = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
Start-Sleep -Seconds 3

Write-Output ("initial-mode=" + (Read-Mode $modeFile))
[KiriWheelVerify]::Wheel(600, 700, -120)
Start-Sleep -Milliseconds 800
Write-Output ("after-wheel-down=" + (Read-Mode $modeFile))
[KiriWheelVerify]::Wheel(600, 700, -120)
Start-Sleep -Milliseconds 800
Write-Output ("after-second-wheel-down=" + (Read-Mode $modeFile))

[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep -Seconds 2
if ($p.HasExited -eq $false) { $p.WaitForExit(4000) | Out-Null }
if ($hadMode) { Set-Content -Path $modeFile -Value $previousMode -NoNewline }
else { Remove-Item $modeFile -Force -ErrorAction SilentlyContinue }
