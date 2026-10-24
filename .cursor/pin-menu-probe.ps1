# QA probe: does a pin's native context menu dismiss on an outside click and on
# Escape, without closing the pin?

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class MenuProbe {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  public static int Menus() {
    int count = 0;
    EnumWindows((h, l) => {
      var name = new StringBuilder(64);
      GetClassName(h, name, 64);
      if (name.ToString() == "#32768" && IsWindowVisible(h)) count++;
      return true;
    }, IntPtr.Zero);
    return count;
  }
}
"@

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
function Send-Mouse([uint32]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
  [MenuProbe]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}
function Send-Escape {
  [MenuProbe]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 50
  [MenuProbe]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 500
}
function Get-Pin { return [MenuProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }

try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 4

  $bitmap = New-Object System.Drawing.Bitmap(400, 300)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::CadetBlue)
  $graphics.Dispose()
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
  $bitmap.Dispose()
  Start-Sleep -Milliseconds 300
  $paste = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
  $null = $paste.WaitForExit(8000)
  Start-Sleep -Milliseconds 700

  $pin = Get-Pin
  if ($pin -eq [IntPtr]::Zero) { "NO_PIN"; exit 1 }
  $rect = New-Object MenuProbe+RECT
  [void][MenuProbe]::GetWindowRect($pin, [ref]$rect)
  $cx = [int](($rect.Left + $rect.Right) / 2)
  $cy = [int](($rect.Top + $rect.Bottom) / 2)
  [void][MenuProbe]::SetCursorPos($cx, $cy)
  Start-Sleep -Milliseconds 200

  Send-Mouse 0x0008
  Start-Sleep -Milliseconds 80
  Send-Mouse 0x0010
  Start-Sleep -Milliseconds 800
  "MENU_AFTER_RIGHT_CLICK=$([MenuProbe]::Menus())"

  [void][MenuProbe]::SetCursorPos(120, 120)
  Start-Sleep -Milliseconds 200
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 100
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 1000
  "MENU_AFTER_OUTSIDE_CLICK=$([MenuProbe]::Menus()) PIN_ALIVE=$([MenuProbe]::IsWindow($pin))"

  Send-Escape
  "MENU_AFTER_ESCAPE=$([MenuProbe]::Menus()) PIN_ALIVE=$([MenuProbe]::IsWindow($pin))"

  [void][MenuProbe]::SetCursorPos($cx, $cy)
  Start-Sleep -Milliseconds 250
  Send-Escape
  "PIN_AFTER_ESCAPE_OVER_PIN=$([MenuProbe]::IsWindow($pin))"
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
}
