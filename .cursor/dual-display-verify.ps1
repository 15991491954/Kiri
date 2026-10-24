$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class KiriVerifyWin {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static List<string> Describe(uint targetPid) {
    var lines = new List<string>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != targetPid || !IsWindowVisible(h)) return true;
      var title = new StringBuilder(256); GetWindowText(h, title, 256);
      var cls = new StringBuilder(256); GetClassName(h, cls, 256);
      RECT r; GetWindowRect(h, out r);
      if (r.Right - r.Left <= 0 || r.Bottom - r.Top <= 0) return true;
      lines.Add(string.Format("hwnd={0} title='{1}' class='{2}' rect=({3},{4})-({5},{6}) size={7}x{8}",
        h, title, cls, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top));
      return true;
    }, IntPtr.Zero);
    return lines;
  }
}
"@

$exe = Join-Path (Get-Location) "src-tauri\target\debug\kiri.exe"
$modeFile = Join-Path $env:APPDATA "io.yuxino.kiri\capture-mode.json"
$hadMode = Test-Path $modeFile
$previousMode = if ($hadMode) { Get-Content $modeFile -Raw } else { $null }
if ($hadMode) { Remove-Item $modeFile -Force }

$existing = @(Get-Process kiri -ErrorAction SilentlyContinue)
if ($existing.Count -eq 0) {
  Write-Output "NO_RUNNING_KIRI"
  exit 2
}
$pid0 = $existing[0].Id

$p = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
Start-Sleep -Seconds 3

Write-Output "=== windows of running Kiri pid=$pid0 ==="
[KiriVerifyWin]::Describe([uint32]$pid0) | ForEach-Object { Write-Output $_ }
Write-Output "=== foreground ==="
[KiriVerifyWin]::GetForegroundWindow()

Write-Output "=== switching to Record with key 2 ==="
[System.Windows.Forms.SendKeys]::SendWait("2")
Start-Sleep -Milliseconds 900
if (Test-Path $modeFile) { Write-Output ("capture-mode=" + (Get-Content $modeFile -Raw)) } else { Write-Output "capture-mode=MISSING" }

Write-Output "=== escape ==="
[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep -Seconds 2
Write-Output "=== windows after escape ==="
[KiriVerifyWin]::Describe([uint32]$pid0) | ForEach-Object { Write-Output $_ }
Write-Output "kiri-still-running=$(-not $existing[0].HasExited)"
$forwarder = if (-not $p.HasExited) { $p.WaitForExit(4000) | Out-Null; $p.HasExited } else { $true }
Write-Output "forwarder-exited=$forwarder"

if ($hadMode) { Set-Content -Path $modeFile -Value $previousMode -NoNewline }
else { Remove-Item $modeFile -Force -ErrorAction SilentlyContinue }
