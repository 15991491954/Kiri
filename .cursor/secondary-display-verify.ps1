$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class KiriSecondaryVerify {
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)]
  public struct CURSORINFO {
    public int cbSize; public int flags; public IntPtr hCursor; public POINT ptScreenPos;
  }
  [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO info);
  [DllImport("user32.dll")] public static extern IntPtr LoadCursor(IntPtr instance, IntPtr name);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  public const uint LEFTDOWN = 0x0002;
  public const uint LEFTUP = 0x0004;
  public static string CursorName() {
    var info = new CURSORINFO();
    info.cbSize = Marshal.SizeOf<CURSORINFO>();
    if (!GetCursorInfo(ref info)) return "READ_FAILED";
    foreach (var pair in new [] {
      new { Name = "ARROW", Id = 32512 }, new { Name = "IBEAM", Id = 32513 },
      new { Name = "CROSS", Id = 32515 }, new { Name = "SIZEALL", Id = 32646 },
      new { Name = "SIZENWSE", Id = 32642 }, new { Name = "SIZENESW", Id = 32643 },
      new { Name = "SIZEWE", Id = 32644 }, new { Name = "SIZENS", Id = 32645 },
    }) {
      if (LoadCursor(IntPtr.Zero, (IntPtr)pair.Id) == info.hCursor) return pair.Name;
    }
    return "OTHER";
  }
  public static void Drag(int x1, int y1, int x2, int y2) {
    SetCursorPos(x1, y1); System.Threading.Thread.Sleep(250);
    mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
    for (int step = 1; step <= 12; step++) {
      SetCursorPos(x1 + (x2 - x1) * step / 12, y1 + (y2 - y1) * step / 12);
      System.Threading.Thread.Sleep(25);
    }
    mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
  }
  public static string At(int x, int y) {
    SetCursorPos(x, y); System.Threading.Thread.Sleep(350); return CursorName();
  }
}
"@

$exe = Join-Path (Get-Location) "src-tauri\target\debug\kiri.exe"
$modeFile = Join-Path $env:APPDATA "io.yuxino.kiri\capture-mode.json"
$hadMode = Test-Path $modeFile
$previousMode = if ($hadMode) { Get-Content $modeFile -Raw } else { $null }
if ($hadMode) { Remove-Item $modeFile -Force }

$p = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
Start-Sleep -Seconds 3

# Secondary display spans x = 2560..5120.
Write-Output ("secondary-blank-cursor=" + [KiriSecondaryVerify]::At(2900, 320))
[KiriSecondaryVerify]::Drag(2700, 200, 3300, 650)
Start-Sleep -Milliseconds 500
Write-Output ("secondary-top-left=" + [KiriSecondaryVerify]::At(2700, 200))
Write-Output ("secondary-bottom-right=" + [KiriSecondaryVerify]::At(3300, 650))
Write-Output ("secondary-top-edge=" + [KiriSecondaryVerify]::At(3000, 200))
Write-Output ("secondary-inside=" + [KiriSecondaryVerify]::At(3000, 400))
Write-Output ("secondary-outside=" + [KiriSecondaryVerify]::At(3600, 900))

[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep -Seconds 2

if ($p.HasExited -eq $false) { $p.WaitForExit(4000) | Out-Null }
if ($hadMode) { Set-Content -Path $modeFile -Value $previousMode -NoNewline }
else { Remove-Item $modeFile -Force -ErrorAction SilentlyContinue }
