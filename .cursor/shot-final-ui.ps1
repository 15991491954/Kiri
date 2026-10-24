# Captures the final main window (library and settings) for visual review.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Shot {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static IntPtr MainWindowOf(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      var t = new System.Text.StringBuilder(256);
      GetWindowTextW(h, t, 256);
      if (t.ToString().StartsWith("Lumen")) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
function Capture([string]$name) {
  $app = Get-Process kiri | Select-Object -First 1
  $window = [Shot]::MainWindowOf($app.Id)
  [void][Shot]::SetForegroundWindow($window)
  Start-Sleep -Milliseconds 500
  $client = New-Object Shot+RECT
  [void][Shot]::GetClientRect($window, [ref]$client)
  $origin = New-Object Shot+POINT
  [void][Shot]::ClientToScreen($window, [ref]$origin)
  $width = $client.Right - $client.Left
  $height = $client.Bottom - $client.Top
  $bitmap = New-Object System.Drawing.Bitmap $width, $height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, (New-Object System.Drawing.Size $width, $height))
  $graphics.Dispose()
  $bitmap.Save((Join-Path (Get-Location) ".cursor\$name"), [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
  "captured $name ${width}x${height}"
}
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9334"
Start-Process -FilePath "src-tauri\target\debug\kiri.exe" | Out-Null
Start-Sleep -Seconds 6
Capture "ui-final-library.png"
node (Join-Path $PSScriptRoot "click-settings.mjs") 9334 | Out-Null
Start-Sleep -Milliseconds 900
Capture "ui-final-settings.png"
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
