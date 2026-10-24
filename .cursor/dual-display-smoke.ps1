$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class KiriWin {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static List<string> Describe(uint targetPid) {
    var lines = new List<string>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != targetPid || !IsWindowVisible(h)) return true;
      var title = new StringBuilder(256); GetWindowText(h, title, 256);
      var cls = new StringBuilder(256); GetClassName(h, cls, 256);
      RECT r; GetWindowRect(h, out r);
      lines.Add(string.Format("hwnd={0} title='{1}' class='{2}' rect=({3},{4})-({5},{6}) size={7}x{8}",
        h, title, cls, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top));
      return true;
    }, IntPtr.Zero);
    return lines;
  }
}
"@

function Capture-Monitor([System.Windows.Forms.Screen]$screen, [string]$path) {
  $b = $screen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

$exe = Join-Path (Get-Location) "src-tauri\target\debug\kiri.exe"
$modeFile = Join-Path $env:APPDATA "io.yuxino.kiri\capture-mode.json"
$hadMode = Test-Path $modeFile
$previousMode = if ($hadMode) { Get-Content $modeFile -Raw } else { $null }
if ($hadMode) { Remove-Item $modeFile -Force }

$p = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
Start-Sleep -Seconds 6

$primary = [System.Windows.Forms.Screen]::AllScreens | Where-Object Primary
$secondary = [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary }

Write-Output "=== overlay windows ==="
$windows = [KiriWin]::Describe([uint32]$p.Id)
$windows | ForEach-Object { Write-Output $_ }

Write-Output "=== screenshots ==="
$p1 = Join-Path $env:TEMP "kiri-dual-primary.png"
$p2 = Join-Path $env:TEMP "kiri-dual-secondary.png"
Capture-Monitor $primary $p1
Capture-Monitor $secondary $p2
Write-Output "primary=$p1"
Write-Output "secondary=$p2"

Write-Output "=== escape ==="
$fg = [KiriWin]::GetForegroundWindow()
Write-Output "foreground=$fg"
[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep -Seconds 2
Write-Output "=== windows after escape ==="
[KiriWin]::Describe([uint32]$p.Id) | ForEach-Object { Write-Output $_ }
Write-Output "running=$(-not $p.HasExited)"

if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
if ($hadMode) { Set-Content -Path $modeFile -Value $previousMode -NoNewline }
else { Remove-Item $modeFile -Force -ErrorAction SilentlyContinue }
