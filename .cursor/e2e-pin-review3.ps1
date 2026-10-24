# End-to-end checks for the native pin review (pass 3).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -STA -File .cursor\e2e-pin-review3.ps1 <stage>
param([string]$Stage = "anchor")

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class Q {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

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

  public static List<IntPtr> ProcessWindows(uint processId, bool visibleOnly) {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => {
      uint pid; GetWindowThreadProcessId(hwnd, out pid);
      if (pid == processId && (!visibleOnly || IsWindowVisible(hwnd))) found.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string ClassOf(IntPtr hwnd) {
    if (hwnd == IntPtr.Zero) return "(none)";
    var name = new StringBuilder(256);
    GetClassName(hwnd, name, name.Capacity);
    return name.ToString();
  }

  public static string TitleOf(IntPtr hwnd) {
    var name = new StringBuilder(512);
    GetWindowText(hwnd, name, name.Capacity);
    return name.ToString();
  }

  public static string Describe(IntPtr hwnd) {
    RECT r; GetWindowRect(hwnd, out r);
    uint pid; GetWindowThreadProcessId(hwnd, out pid);
    long style = (long)GetWindowLongPtr(hwnd, -20);
    return string.Format("hwnd=0x{0:X} pid={1} rect={2},{3} {4}x{5} visible={6} ex=0x{7:X} topmost={8} layered={9} toolwindow={10} noactivate={11}",
      hwnd.ToInt64(), pid, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top,
      IsWindowVisible(hwnd), style,
      (style & 0x8) != 0, (style & 0x80000) != 0, (style & 0x80) != 0, (style & 0x8000000) != 0);
  }
}
"@

function Get-Pins { [Q]::Windows("KiriPinWindow") }
function Get-Badges { [Q]::Windows("KiriPinBadge") }
function Get-KiriPid { (Get-Process kiri -ErrorAction Stop | Select-Object -First 1).Id }

function Get-Rect([IntPtr]$hwnd) {
  $rect = New-Object Q+RECT
  [Q]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
  return $rect
}
function Get-LargestPin {
  (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
}
function Send-Key([byte]$vk, [bool]$up = $false) {
  [Q]::keybd_event($vk, 0, $(if ($up) { 2 } else { 0 }), [UIntPtr]::Zero)
}
function Send-Wheel([int]$notches) {
  $raw = [int64]$notches * 120
  if ($raw -lt 0) { $raw += 4294967296 }
  [Q]::mouse_event(0x0800, 0, 0, [uint32]$raw, [UIntPtr]::Zero)
}
function Click-At([int]$x, [int]$y) {
  [Q]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 120
  [Q]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [Q]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}
function Find-UiaButton([IntPtr]$hwnd, [string]$pattern) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  if (-not $root) { return $null }
  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
  foreach ($button in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
    if ($button.Current.Name -match $pattern) { return $button }
  }
  return $null
}

switch ($Stage) {
  "anchor" {
    $pin = Get-LargestPin
    $before = Get-Rect $pin
    $w = $before.Right - $before.Left
    $h = $before.Bottom - $before.Top
    # 25% from the left, 75% from the top.
    $anchorX = 0.25; $anchorY = 0.75
    $cx = [int]($before.Left + $anchorX * $w)
    $cy = [int]($before.Top + $anchorY * $h)
    [Q]::SetCursorPos($cx, $cy) | Out-Null
    Start-Sleep -Milliseconds 200
    Send-Wheel 2
    Start-Sleep -Milliseconds 500
    $after = Get-Rect $pin
    $aw = $after.Right - $after.Left
    $ah = $after.Bottom - $after.Top
    $expectedLeft = [math]::Round($before.Left + $anchorX * ($w - $aw), 2)
    $expectedTop = [math]::Round($before.Top + $anchorY * ($h - $ah), 2)
    "BEFORE=$($before.Left),$($before.Top) ${w}x${h}"
    "AFTER =$($after.Left),$($after.Top) ${aw}x${ah}"
    "EXPECTED_ORIGIN=$expectedLeft,$expectedTop DRIFT_X=$([math]::Round($after.Left - $expectedLeft, 2)) DRIFT_Y=$([math]::Round($after.Top - $expectedTop, 2))"
    "RATIO=$([math]::Round($aw / $w, 4)) (two notches: 1.21)"
    "BADGE_VISIBLE=$((Get-Badges | Where-Object { [Q]::Describe($_) -match 'visible=True' }).Count)"
    # Restore 100% by zooming out the same number of notches.
    Send-Wheel -2
    Start-Sleep -Milliseconds 500
    $back = Get-Rect $pin
    "RESTORED_SIZE=$(($back.Right - $back.Left) -eq $w -and ($back.Bottom - $back.Top) -eq $h)"
  }
  "topmost-multi" {
    $pins = @(Get-Pins)
    "PINS=$($pins.Count)"
    $note = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1300
    $note.Refresh()
    $noteH = $note.MainWindowHandle
    $first = $pins[0]
    $r = Get-Rect $first
    # Cover the whole pin with notepad, then focus notepad.
    [Q]::SetWindowPos($noteH, [IntPtr]::Zero, $r.Left - 60, $r.Top - 60, ($r.Right - $r.Left) + 120, ($r.Bottom - $r.Top) + 120, 0x0040) | Out-Null
    [Q]::SetForegroundWindow($noteH) | Out-Null
    Start-Sleep -Milliseconds 700
    "FG=0x$(([Q]::GetForegroundWindow()).ToInt64().ToString('X')) NOTEPAD=0x$($noteH.ToInt64().ToString('X'))"
    foreach ($pin in $pins) {
      $pr = Get-Rect $pin
      $point = New-Object Q+POINT
      $point.X = [int](($pr.Left + $pr.Right) / 2)
      $point.Y = [int](($pr.Top + $pr.Bottom) / 2)
      $hit = [Q]::WindowFromPoint($point)
      "PIN=0x$($pin.ToInt64().ToString('X')) VISIBLE_ABOVE_NOTE=$($hit -eq $pin) HIT_CLASS=$([Q]::ClassOf($hit))"
    }
    Click-At ([int](($r.Left + $r.Right) / 2)) ([int](($r.Top + $r.Bottom) / 2))
    Start-Sleep -Milliseconds 400
    $fg = [Q]::GetForegroundWindow()
    "FG_AFTER_PIN_CLICK=0x$($fg.ToInt64().ToString('X')) STILL_NOTEPAD=$($fg -eq $noteH)"
    Stop-Process -Id $note.Id -Force -ErrorAction SilentlyContinue
  }
  "escape-multi" {
    $pins = @(Get-Pins)
    "PINS_BEFORE=$($pins.Count)"
    if ($pins.Count -lt 2) { "NEED_TWO_PINS"; break }
    $target = $pins[0]
    $other = $pins[1]
    $r = Get-Rect $target
    [Q]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2)) | Out-Null
    Start-Sleep -Milliseconds 250
    Send-Key 0x1B
    Start-Sleep -Milliseconds 60
    Send-Key 0x1B
    Start-Sleep -Milliseconds 200
    Send-Key 0x1B $true
    Start-Sleep -Milliseconds 600
    $afterPins = @(Get-Pins)
    "PINS_AFTER=$($afterPins.Count) TARGET_CLOSED=$(-not ($afterPins -contains $target)) OTHER_ALIVE=$($afterPins -contains $other)"
    [Q]::SetCursorPos(1200, 700) | Out-Null
    Start-Sleep -Milliseconds 200
    Send-Key 0x1B
    Start-Sleep -Milliseconds 60
    Send-Key 0x1B $true
    Start-Sleep -Milliseconds 500
    "PINS_AFTER_EMPTY_ESC=$((Get-Pins).Count)"
  }
  "menu" {
    $pin = Get-LargestPin
    $r = Get-Rect $pin
    [Q]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2)) | Out-Null
    Start-Sleep -Milliseconds 200
    [Q]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [Q]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    "MENU_OPEN=$(([Q]::Windows('#32768')).Count)"
    [Q]::SetCursorPos(1200, 800) | Out-Null
    Start-Sleep -Milliseconds 200
    [Q]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [Q]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 900
    "MENU_AFTER_OUTSIDE_CLICK=$(([Q]::Windows('#32768')).Count)"
    "PIN_ALIVE=$([Q]::Windows('KiriPinWindow').Count -gt 0)"
  }
  "exclude-capture" {
    # The pin is excluded from every screen capture API, including BitBlt.
    $pin = Get-LargestPin
    $r = Get-Rect $pin
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    $bitmap = New-Object System.Drawing.Bitmap $w, $h
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $graphics.Dispose()
    # The text card body is (32,32,32); the desktop behind it is not.
    $sample = @()
    foreach ($point in @(@([int]($w/2), [int]($h/2)), @([int]($w/4), [int]($h/2)), @([int]($w*3/4), [int]($h/2)))) {
      $pixel = $bitmap.GetPixel($point[0], $point[1])
      $sample += "$($pixel.R),$($pixel.G),$($pixel.B)"
    }
    $path = Join-Path $PSScriptRoot "pin-exclude-capture.png"
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    "PIN=$([Q]::Describe($pin))"
    "SCREEN_SAMPLES=$($sample -join ' | ') (card body would be 32,32,32) PATH=$path"
  }
  "capture-pin" {
    $pidKiri = Get-KiriPid
    $pinsBefore = @(Get-Pins).Count
    # Shift+Ctrl+A: the currently configured capture shortcut.
    Send-Key 0x11
    Send-Key 0x10
    Send-Key 0x41
    Start-Sleep -Milliseconds 60
    Send-Key 0x41 $true
    Send-Key 0x10 $true
    Send-Key 0x11 $true
    Start-Sleep -Milliseconds 2000
    $windows = @([Q]::ProcessWindows([uint32]$pidKiri, $true))
    "KIRI_WINDOWS=$($windows.Count)"
    $windows | ForEach-Object { "  class=$([Q]::ClassOf($_)) title=$([Q]::TitleOf($_)) $([Q]::Describe($_))" }
    [Q]::SetCursorPos(400, 400) | Out-Null
    Start-Sleep -Milliseconds 150
    [Q]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    for ($step = 1; $step -le 10; $step++) {
      [Q]::SetCursorPos(400 + $step * 40, 400 + $step * 28) | Out-Null
      Start-Sleep -Milliseconds 20
    }
    [Q]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 900
    $overlay = ([Q]::ProcessWindows([uint32]$pidKiri, $true) | Where-Object { [Q]::ClassOf($_) -eq 'Chrome_WidgetWin_1' } | Select-Object -First 1)
    "OVERLAY=$([Q]::Describe($overlay))"
    $button = Find-UiaButton $overlay "Pin|置顶|ピン|Anheften|Épingler|고정"
    if (-not $button) {
      "UIA_PIN_BUTTON=missing"
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($overlay)
      $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
      $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) | ForEach-Object { "  BUTTON name=$($_.Current.Name)" }
      break
    }
    $bounds = $button.Current.BoundingRectangle
    "UIA_PIN_BUTTON=found name=$($button.Current.Name) bounds=$($bounds.Left),$($bounds.Top) $($bounds.Width)x$($bounds.Height)"
    $invoke = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($invoke) { $invoke.Invoke(); "UIA_INVOKE=ok" }
    else {
      Click-At ([int]($bounds.Left + $bounds.Width / 2)) ([int]($bounds.Top + $bounds.Height / 2))
      "CLICKED=$([int]($bounds.Left + $bounds.Width / 2)),$([int]($bounds.Top + $bounds.Height / 2))"
    }
    Start-Sleep -Milliseconds 1800
    $pins = @(Get-Pins)
    "PINS_BEFORE=$pinsBefore PINS_AFTER=$($pins.Count)"
    $pins | ForEach-Object { [Q]::Describe($_) }
    "KIRI_WINDOWS_AFTER=$(@([Q]::ProcessWindows([uint32]$pidKiri, $true)).Count)"
  }
  "cleanup" {
    foreach ($pin in Get-Pins) {
      [void][Q]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 150
    }
    Start-Sleep -Milliseconds 400
    "PINS_LEFT=$((Get-Pins).Count) BADGES_LEFT=$((Get-Badges).Count)"
  }
}
