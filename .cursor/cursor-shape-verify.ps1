$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class KiriCursorVerify {
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
    int id = info.flags == 0 ? 0 : 0;
    foreach (var pair in new [] {
      new { Name = "ARROW", Id = 32512 }, new { Name = "IBEAM", Id = 32513 },
      new { Name = "CROSS", Id = 32515 }, new { Name = "SIZEALL", Id = 32646 },
      new { Name = "SIZENWSE", Id = 32642 }, new { Name = "SIZENESW", Id = 32643 },
      new { Name = "SIZEWE", Id = 32644 }, new { Name = "SIZENS", Id = 32645 },
      new { Name = "HAND", Id = 32649 },
    }) {
      var handle = LoadCursor(IntPtr.Zero, (IntPtr)pair.Id);
      if (handle == info.hCursor) return pair.Name;
    }
    return "OTHER(0x" + info.hCursor.ToInt64().ToString("X") + ")";
  }
  public static void Drag(int x1, int y1, int x2, int y2) {
    SetCursorPos(x1, y1);
    System.Threading.Thread.Sleep(250);
    mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
    for (int step = 1; step <= 10; step++) {
      SetCursorPos(x1 + (x2 - x1) * step / 10, y1 + (y2 - y1) * step / 10);
      System.Threading.Thread.Sleep(30);
    }
    mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
  }
  public static string At(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(350);
    return CursorName();
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

Write-Output ("blank-screen-cursor=" + [KiriCursorVerify]::At(300, 300))
[KiriCursorVerify]::Drag(150, 120, 750, 620)
Start-Sleep -Milliseconds 500
Write-Output ("top-left-handle=" + [KiriCursorVerify]::At(150, 120))
Write-Output ("bottom-right-handle=" + [KiriCursorVerify]::At(750, 620))
Write-Output ("top-edge-centre=" + [KiriCursorVerify]::At(450, 120))
Write-Output ("left-edge-centre=" + [KiriCursorVerify]::At(150, 370))
Write-Output ("region-inside=" + [KiriCursorVerify]::At(450, 370))
Write-Output ("outside-region=" + [KiriCursorVerify]::At(1200, 900))

[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep -Seconds 2

if ($p.HasExited -eq $false) { $p.WaitForExit(4000) | Out-Null }
if ($hadMode) { Set-Content -Path $modeFile -Value $previousMode -NoNewline }
else { Remove-Item $modeFile -Force -ErrorAction SilentlyContinue }
