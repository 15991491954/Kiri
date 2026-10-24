# End-to-end checks for native pinned images.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .cursor\e2e-pin.ps1 <stage>
param([string]$Stage = "image")

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class Win {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  public static List<IntPtr> Windows(string className) {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => {
      var name = new StringBuilder(256);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == className) found.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string Describe(IntPtr hwnd) {
    RECT r; GetWindowRect(hwnd, out r);
    uint pid; GetWindowThreadProcessId(hwnd, out pid);
    long style = (long)GetWindowLongPtr(hwnd, -20);
    return string.Format("hwnd=0x{0:X} pid={1} rect={2},{3} {4}x{5} visible={6} ex=0x{7:X} topmost={8} layered={9} toolwindow={10}",
      hwnd.ToInt64(), pid, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top,
      IsWindowVisible(hwnd), style,
      (style & 0x8) != 0, (style & 0x80000) != 0, (style & 0x80) != 0);
  }
}
"@

$exe = Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe"
$exe = (Resolve-Path $exe).Path

function Get-Pins { [Win]::Windows("KiriPinWindow") }

function Start-Kiri([string]$arguments) {
  $running = Get-Process -Name kiri -ErrorAction SilentlyContinue
  if (-not $running) {
    Start-Process -FilePath $exe -ArgumentList $arguments | Out-Null
    Start-Sleep -Milliseconds 2500
  } else {
    Start-Process -FilePath $exe -ArgumentList $arguments | Out-Null
    Start-Sleep -Milliseconds 1500
  }
}

function Set-ImageClipboard([int]$width, [int]$height) {
  $bitmap = New-Object System.Drawing.Bitmap $width, $height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(255, 32, 140, 220))
  $graphics.FillRectangle([System.Drawing.Brushes]::Orange, 40, 40, $width - 80, $height - 80)
  $graphics.DrawString("Kiri pin test", (New-Object System.Drawing.Font("Segoe UI", 20)), [System.Drawing.Brushes]::White, 60, 60)
  $graphics.Dispose()
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
  return $bitmap
}

switch ($Stage) {
  "image" {
    $bitmap = Set-ImageClipboard 480 320
    Start-Kiri "--paste-pin"
    Start-Sleep -Milliseconds 800
    $pins = Get-Pins
    "PINS=$($pins.Count)"
    foreach ($pin in $pins) { [Win]::Describe($pin) }
    [void]$bitmap
  }
  "text" {
    [System.Windows.Forms.Clipboard]::SetText("Kiri clipboard text pin`r`n第二行文本 with mixed content.")
    Start-Kiri "--paste-pin"
    Start-Sleep -Milliseconds 800
    $pins = Get-Pins
    "PINS=$($pins.Count)"
    foreach ($pin in $pins) { [Win]::Describe($pin) }
  }
  "files" {
    $stamp = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $first = Join-Path $env:TEMP "kiri-pin-$stamp-a.png"
    $second = Join-Path $env:TEMP "kiri-pin-$stamp-b.png"
    foreach ($path in @($first, $second)) {
      $bmp = New-Object System.Drawing.Bitmap 240, 160
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.Clear([System.Drawing.Color]::FromArgb(255, 90, 200, 120))
      $g.Dispose()
      $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
    }
    $files = New-Object System.Collections.Specialized.StringCollection
    [void]$files.Add($first)
    [void]$files.Add($second)
    [System.Windows.Forms.Clipboard]::SetFileDropList($files)
    Start-Kiri "--paste-pin"
    Start-Sleep -Milliseconds 800
    $pins = Get-Pins
    "PINS=$($pins.Count)"
    foreach ($pin in $pins) { [Win]::Describe($pin) }
  }
  "commands" {
    foreach ($name in @("KiriPinWindow", "KiriPinBadge", "KiriPinHost")) {
      $list = [Win]::Windows($name)
      "$name=$($list.Count)"
    }
    $running = Get-Process -Name kiri -ErrorAction SilentlyContinue
    "KIRI_PROCESSES=$(@($running).Count)"
  }
  "drag" {
    $pin = (Get-Pins)[0]
    $rect = New-Object Win+RECT
    [Win]::GetWindowRect($pin, [ref]$rect) | Out-Null
    $startX = [int](($rect.Left + $rect.Right) / 2)
    $startY = [int](($rect.Top + $rect.Bottom) / 2)
    [Win]::SetCursorPos($startX, $startY) | Out-Null
    Start-Sleep -Milliseconds 150
    [Win]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    for ($step = 1; $step -le 20; $step++) {
      [Win]::SetCursorPos($startX - $step * 6, $startY + $step * 4) | Out-Null
      Start-Sleep -Milliseconds 12
    }
    [Win]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $after = New-Object Win+RECT
    [Win]::GetWindowRect($pin, [ref]$after) | Out-Null
    "BEFORE=$($rect.Left),$($rect.Top) AFTER=$($after.Left),$($after.Top)"
  }
  "wheel" {
    $pin = (Get-Pins)[0]
    $rect = New-Object Win+RECT
    [Win]::GetWindowRect($pin, [ref]$rect) | Out-Null
    $startX = [int](($rect.Left + $rect.Right) / 2)
    $startY = [int](($rect.Top + $rect.Bottom) / 2)
    $screen = [int]($startX + ($startY -shl 16))
    [Win]::SetCursorPos($startX, $startY) | Out-Null
    Start-Sleep -Milliseconds 150
    [void][Win]::SendMessage($pin, 0x020A, [IntPtr](120 -shl 16), [IntPtr]$screen)
    Start-Sleep -Milliseconds 700
    $after = New-Object Win+RECT
    [Win]::GetWindowRect($pin, [ref]$after) | Out-Null
    "BEFORE=$($rect.Right - $rect.Left)x$($rect.Bottom - $rect.Top) AFTER=$($after.Right - $after.Left)x$($after.Bottom - $after.Top)"
    foreach ($badge in [Win]::Windows("KiriPinBadge")) { [Win]::Describe($badge) }
    # Zoom back to 100% for the next stage.
    [void][Win]::SendMessage($pin, 0x020A, [IntPtr](-120 -shl 16), [IntPtr]$screen)
    Start-Sleep -Milliseconds 500
  }
  "topmost" {
    $pin = (Get-Pins)[0]
    $rect = New-Object Win+RECT
    [Win]::GetWindowRect($pin, [ref]$rect) | Out-Null
    $startX = [int](($rect.Left + $rect.Right) / 2)
    $startY = [int](($rect.Top + $rect.Bottom) / 2)
    $shell = New-Object -ComObject Shell.Application
    $shell.MinimizeAll()
    Start-Sleep -Milliseconds 800
    [Win]::SetCursorPos($startX, $startY) | Out-Null
    Start-Sleep -Milliseconds 300
    $under = [Win]::WindowFromPoint((New-Object Win+POINT -Property @{X = $startX; Y = $startY}))
    "PIN=0x$($pin.ToInt64().ToString('X')) UNDER_CURSOR=0x$($under.ToInt64().ToString('X')) MATCH=$($pin -eq $under)"
    [Win]::Describe($pin)
    $shell.UndoMinimizeAll()
  }
  "escape" {
    $pin = (Get-Pins)[0]
    $rect = New-Object Win+RECT
    [Win]::GetWindowRect($pin, [ref]$rect) | Out-Null
    $startX = [int](($rect.Left + $rect.Right) / 2)
    $startY = [int](($rect.Top + $rect.Bottom) / 2)
    [Win]::SetCursorPos($startX, $startY) | Out-Null
    Start-Sleep -Milliseconds 200
    $before = (Get-Pins).Count
    [Win]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [Win]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    $after = (Get-Pins).Count
    "PINS_BEFORE=$before PINS_AFTER=$after"
  }
  "close-all" {
    foreach ($pin in Get-Pins) {
      $rect = New-Object Win+RECT
      [Win]::GetWindowRect($pin, [ref]$rect) | Out-Null
      [Win]::SetCursorPos([int](($rect.Left + $rect.Right) / 2), [int](($rect.Top + $rect.Bottom) / 2)) | Out-Null
      Start-Sleep -Milliseconds 100
      [Win]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 60
      [Win]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 300
    }
    "PINS_LEFT=$((Get-Pins).Count)"
  }
  "quit" {
    Get-Process -Name kiri -ErrorAction SilentlyContinue | Stop-Process -Force
    "STOPPED"
  }
}

