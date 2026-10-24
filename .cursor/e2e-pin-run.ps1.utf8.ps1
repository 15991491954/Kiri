# End-to-end driver for the native pin feature (review pass 4).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -STA -File .cursor\e2e-pin-run.ps1 <stage>
param([string]$Stage = "probe")

$ErrorActionPreference = "Stop"
# Built from code points so the pattern never depends on this file's encoding.
$script:PinPattern = "Pin|" + [string][char]0x8D34 + [string][char]0x56FE + "|" +
  [string][char]0x7F6E + [string][char]0x9876 + "|" +
  [string][char]0x30D4 + [string][char]0x30F3
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
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hwnd, int x, int y, int w, int h, bool repaint);

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
    long plain = (long)GetWindowLongPtr(hwnd, -16);
    return string.Format("hwnd=0x{0:X} pid={1} rect={2},{3} {4}x{5} visible={6} ex=0x{7:X} topmost={8} layered={9} toolwindow={10} noactivate={11}",
      hwnd.ToInt64(), pid, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top,
      IsWindowVisible(hwnd), style,
      (style & 0x8) != 0, (style & 0x80000) != 0, (style & 0x80) != 0, (style & 0x8000000) != 0);
  }
}
"@

function Get-Pins { @([Q]::Windows("KiriPinWindow")) }
function Get-Badges { @([Q]::Windows("KiriPinBadge")) }
function Get-KiriPid { (Get-Process kiri -ErrorAction Stop | Select-Object -First 1).Id }
function Get-Rect([IntPtr]$hwnd) {
  $rect = New-Object Q+RECT
  [Q]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
  return $rect
}
function Get-Size([IntPtr]$hwnd) {
  $r = Get-Rect $hwnd
  return "$($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
}
function Get-LargestPin {
  (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
}
function Get-SmallestPin {
  (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) })[0]
}
function Send-Key([byte]$vk) {
  [Q]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [Q]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
}
function Send-Hotkey([byte[]]$keys) {
  foreach ($key in $keys) { [Q]::keybd_event($key, 0, 0, [UIntPtr]::Zero) }
  Start-Sleep -Milliseconds 60
  [byte[]]$reversed = $keys.Clone(); [array]::Reverse($reversed)
  foreach ($key in $reversed) { [Q]::keybd_event($key, 0, 2, [UIntPtr]::Zero) }
}
function Send-Wheel([int]$notches) {
  $raw = [int64]$notches * 120
  if ($raw -lt 0) { $raw += 4294967296 }
  [Q]::mouse_event(0x0800, 0, 0, [uint32]$raw, [UIntPtr]::Zero)
}
function Click-At([int]$x, [int]$y) {
  [Q]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 150
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
function Get-Overlays {
  $pidKiri = Get-KiriPid
  @([Q]::ProcessWindows([uint32]$pidKiri, $true) | Where-Object {
    if ([Q]::ClassOf($_) -ne 'Tauri Window') { return $false }
    if ([Q]::TitleOf($_) -ne 'kiri') { return $false }
    $r = Get-Rect $_
    ($r.Right - $r.Left) -ge 1000 -and ($r.Bottom - $r.Top) -ge 700
  })
}

switch ($Stage) {
  "probe" {
    "PINS=$((Get-Pins).Count) BADGES_VISIBLE=$((Get-Badges | Where-Object { [Q]::Describe($_) -match 'visible=True' }).Count)"
    foreach ($overlay in Get-Overlays) {
      "OVERLAY $([Q]::Describe($overlay)) title=$([Q]::TitleOf($overlay))"
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($overlay)
      if (-not $root) { "  UIA=unavailable"; continue }
      $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
      $buttons = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition))
      "  UIA_BUTTONS=$($buttons.Count)"
      foreach ($button in $buttons) {
        $b = $button.Current.BoundingRectangle
        "    name='$($button.Current.Name)' bounds=$([int]$b.Left),$([int]$b.Top) $([int]$b.Width)x$([int]$b.Height)"
      }
    }
  }
  "capture-pin" {
    $before = (Get-Pins).Count
    Send-Hotkey @(0x11, 0x10, 0x41)
    Start-Sleep -Milliseconds 2500
    $overlays = @(Get-Overlays)
    "OVERLAYS=$($overlays.Count)"
    foreach ($overlay in $overlays) { "  $([Q]::Describe($overlay))" }
    $target = $overlays | Where-Object { (Get-Rect $_).Left -eq 0 } | Select-Object -First 1
    if (-not $target) { $target = $overlays[0] }
    # Drag a 520x360 region starting at 300,260.
    [Q]::SetCursorPos(300, 260) | Out-Null
    Start-Sleep -Milliseconds 150
    [Q]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    for ($step = 1; $step -le 10; $step++) {
      [Q]::SetCursorPos(300 + $step * 52, 260 + $step * 36) | Out-Null
      Start-Sleep -Milliseconds 25
    }
    [Q]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 900
$button = Find-UiaButton $target $script:PinPattern
    if (-not $button) {
      "UIA_PIN_BUTTON=missing"
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($target)
      $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
      $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) | ForEach-Object {
        $b = $_.Current.BoundingRectangle
        "  BUTTON name='$($_.Current.Name)' bounds=$([int]$b.Left),$([int]$b.Top) $([int]$b.Width)x$([int]$b.Height)"
      }
      break
    }
    $bounds = $button.Current.BoundingRectangle
    "UIA_PIN_BUTTON=found name='$($button.Current.Name)' bounds=$([int]$bounds.Left),$([int]$bounds.Top) $([int]$bounds.Width)x$([int]$bounds.Height)"
    $invoke = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($invoke) { $invoke.Invoke(); "UIA_INVOKE=ok" }
    else {
      Click-At ([int]($bounds.Left + $bounds.Width / 2)) ([int]($bounds.Top + $bounds.Height / 2))
      "CLICKED=$([int]($bounds.Left + $bounds.Width / 2)),$([int]($bounds.Top + $bounds.Height / 2))"
    }
    Start-Sleep -Milliseconds 2000
    $pins = Get-Pins
    "PINS_BEFORE=$before PINS_AFTER=$($pins.Count)"
    $pins | ForEach-Object { "  $([Q]::Describe($_))" }
    "OVERLAYS_LEFT=$(@(Get-Overlays).Count)"
  }
  "cancel-overlay" {
    Send-Key 0x1B
    Start-Sleep -Milliseconds 900
    "OVERLAYS_LEFT=$(@(Get-Overlays).Count)"
  }
  "drag" {
    $pin = (Get-Pins)[0]
    $before = Get-Rect $pin
    $cx = [int](($before.Left + $before.Right) / 2)
    $cy = [int](($before.Top + $before.Bottom) / 2)
    [Q]::SetCursorPos($cx, $cy) | Out-Null
    Start-Sleep -Milliseconds 200
    [Q]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    for ($step = 1; $step -le 8; $step++) {
      [Q]::SetCursorPos($cx + $step * 25, $cy + $step * 18) | Out-Null
      Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 120
    [Q]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $after = Get-Rect $pin
    "BEFORE=$($before.Left),$($before.Top) $(Get-Size $pin)"
    "AFTER =$($after.Left),$($after.Top) $(Get-Size $pin)"
    "DELTA =$($after.Left-$before.Left),$($after.Top-$before.Top) EXPECTED=200,144"
    "SIZE_UNCHANGED=$(($after.Right-$after.Left) -eq ($before.Right-$before.Left) -and ($after.Bottom-$before.Top) -eq ($before.Bottom-$before.Top))"
  }
  "dragfast" {
    $pin = (Get-Pins)[0]
    $before = Get-Rect $pin
    $cx = [int](($before.Left + $before.Right) / 2)
    $cy = [int](($before.Top + $before.Bottom) / 2)
    [Q]::SetCursorPos($cx, $cy) | Out-Null
    Start-Sleep -Milliseconds 200
    [Q]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Q]::SetCursorPos($cx - 260, $cy + 120) | Out-Null
    Start-Sleep -Milliseconds 300
    [Q]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $after = Get-Rect $pin
    "BEFORE=$($before.Left),$($before.Top) AFTER=$($after.Left),$($after.Top)"
    "DELTA =$($after.Left-$before.Left),$($after.Top-$before.Top) EXPECTED=-260,120"
  }
  "wheel" {
    $pin = Get-LargestPin
    $before = Get-Rect $pin
    $cx = [int](($before.Left + $before.Right) / 2)
    $cy = [int](($before.Top + $before.Bottom) / 2)
    [Q]::SetCursorPos($cx, $cy) | Out-Null
    Start-Sleep -Milliseconds 250
    "BEFORE=$($before.Left),$($before.Top) $(Get-Size $pin)"
    Send-Wheel 1
    Start-Sleep -Milliseconds 500
    $after = Get-Rect $pin
    "AFTER_UP=$($after.Left),$($after.Top) $(Get-Size $pin)"
    "RATIO=$([math]::Round(($after.Right-$after.Left) / ($before.Right-$before.Left), 4)) EXPECTED=1.1"
    $badges = @(Get-Badges | Where-Object { [Q]::Describe($_) -match 'visible=True' })
    "BADGE_VISIBLE=$($badges.Count)"
    foreach ($badge in $badges) { "  BADGE $([Q]::Describe($badge))" }
    Start-Sleep -Milliseconds 1300
    "BADGE_VISIBLE_AFTER_1.6S=$(@(Get-Badges | Where-Object { [Q]::Describe($_) -match 'visible=True' }).Count)"
    Send-Wheel -1
    Start-Sleep -Milliseconds 500
    $down = Get-Rect $pin
    "AFTER_DOWN=$(Get-Size $pin) DOWN_RATIO=$([math]::Round(($down.Right-$down.Left) / ($after.Right-$after.Left), 4)) EXPECTED=0.9091"
    "RESTORED=$(($down.Right-$down.Left) -eq ($before.Right-$before.Left))"
  }
  "anchor" {
    $pin = Get-LargestPin
    $before = Get-Rect $pin
    $w = $before.Right - $before.Left
    $h = $before.Bottom - $before.Top
    $anchorX = 0.25; $anchorY = 0.75
    $cx = [int]($before.Left + $anchorX * $w)
    $cy = [int]($before.Top + $anchorY * $h)
    [Q]::SetCursorPos($cx, $cy) | Out-Null
    Start-Sleep -Milliseconds 250
    Send-Wheel 2
    Start-Sleep -Milliseconds 600
    $after = Get-Rect $pin
    $aw = $after.Right - $after.Left
    $ah = $after.Bottom - $after.Top
    $expectedLeft = [math]::Round($before.Left + $anchorX * ($w - $aw), 2)
    $expectedTop = [math]::Round($before.Top + $anchorY * ($h - $ah), 2)
    "BEFORE=$($before.Left),$($before.Top) ${w}x${h}"
    "AFTER =$($after.Left),$($after.Top) ${aw}x${ah}"
    "EXPECTED_ORIGIN=$expectedLeft,$expectedTop DRIFT_X=$([math]::Round($after.Left - $expectedLeft, 2)) DRIFT_Y=$([math]::Round($after.Top - $expectedTop, 2))"
    "RATIO=$([math]::Round($aw / $w, 4)) (two notches: 1.21)"
    Send-Wheel -2
    Start-Sleep -Milliseconds 600
    $back = Get-Rect $pin
    "RESTORED_SIZE=$(($back.Right - $back.Left) -eq $w -and ($back.Bottom - $back.Top) -eq $h)"
  }
  "topmost-multi" {
    $pins = Get-Pins
    "PINS=$($pins.Count)"
    $note = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1300
    $note.Refresh()
    $noteH = $note.MainWindowHandle
    foreach ($pin in $pins) {
      $r = Get-Rect $pin
      [Q]::SetWindowPos($noteH, [IntPtr]::Zero, $r.Left - 60, $r.Top - 60, ($r.Right - $r.Left) + 120, ($r.Bottom - $r.Top) + 120, 0x0040) | Out-Null
      [Q]::SetForegroundWindow($noteH) | Out-Null
      Start-Sleep -Milliseconds 400
      $point = New-Object Q+POINT
      $point.X = [int](($r.Left + $r.Right) / 2)
      $point.Y = [int](($r.Top + $r.Bottom) / 2)
      $hit = [Q]::WindowFromPoint($point)
      "PIN=0x$($pin.ToInt64().ToString('X')) VISIBLE_ABOVE_NOTE=$($hit -eq $pin) HIT_CLASS=$([Q]::ClassOf($hit))"
    }
    $first = $pins[0]
    $r = Get-Rect $first
    Click-At ([int](($r.Left + $r.Right) / 2)) ([int](($r.Top + $r.Bottom) / 2))
    Start-Sleep -Milliseconds 400
    $fg = [Q]::GetForegroundWindow()
    "FG_AFTER_PIN_CLICK=0x$($fg.ToInt64().ToString('X')) STILL_NOTEPAD=$($fg -eq $noteH)"
    Stop-Process -Id $note.Id -Force -ErrorAction SilentlyContinue
  }
  "escape-multi" {
    $pins = Get-Pins
    "PINS_BEFORE=$($pins.Count)"
    if ($pins.Count -lt 2) { "NEED_TWO_PINS"; break }
    $target = $pins[0]
    $other = $pins[1]
    $r = Get-Rect $target
    [Q]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2)) | Out-Null
    Start-Sleep -Milliseconds 250
    [Q]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Q]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    [Q]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    $afterPins = Get-Pins
    "PINS_AFTER=$($afterPins.Count) TARGET_CLOSED=$(-not ($afterPins -contains $target)) OTHER_ALIVE=$($afterPins -contains $other)"
    [Q]::SetCursorPos(1200, 1320) | Out-Null
    Start-Sleep -Milliseconds 200
    Send-Key 0x1B
    Start-Sleep -Milliseconds 600
    "PINS_AFTER_EMPTY_ESC=$((Get-Pins).Count)"
  }
  "paste-image" {
    $bitmap = New-Object System.Drawing.Bitmap 320, 220
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromArgb(255, 200, 60, 60))
    $graphics.FillEllipse([System.Drawing.Brushes]::Gold, 60, 40, 140, 100)
    $graphics.Dispose()
    [System.Windows.Forms.Clipboard]::SetImage($bitmap)
    $bitmap.Dispose()
    $before = (Get-Pins).Count
    [Q]::SetCursorPos(1400, 700) | Out-Null
    Start-Sleep -Milliseconds 250
    Send-Key 0x72
    Start-Sleep -Milliseconds 1500
    $pins = Get-Pins
    "PINS_BEFORE=$before PINS_AFTER=$($pins.Count)"
    $pins | Where-Object { (Get-Rect $_).Left -gt 1200 } | ForEach-Object { "  NEW $([Q]::Describe($_))" }
    "CLIP_STILL_HAS_IMAGE=$([System.Windows.Forms.Clipboard]::ContainsImage())"
  }
  "paste-text" {
    $clipText = "Kiri pin review line two with mixed content " + [string][char]0x8D34 + [string][char]0x56FE
    [System.Windows.Forms.Clipboard]::SetText($clipText)
    $before = (Get-Pins).Count
    [Q]::SetCursorPos(1400, 1000) | Out-Null
    Start-Sleep -Milliseconds 250
    Send-Key 0x72
    Start-Sleep -Milliseconds 1500
    "PINS_BEFORE=$before PINS_AFTER=$((Get-Pins).Count)"
    (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } | Select-Object -First 1) |
      ForEach-Object { "  SMALLEST $([Q]::Describe($_)) title=$([Q]::TitleOf($_))" }
  }
  "paste-files" {
    $dir = Join-Path $env:TEMP "kiri-pin-qa"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $names = @()
    foreach ($index in 1..2) {
      $path = Join-Path $dir ("qa-{0}.png" -f $index)
      $bitmap = New-Object System.Drawing.Bitmap (140 + $index * 30), 120
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      $graphics.Clear($(if ($index -eq 1) { [System.Drawing.Color]::Teal } else { [System.Drawing.Color]::Purple }))
      $graphics.Dispose()
      $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
      $bitmap.Dispose()
      $names += $path
    }
    $collection = New-Object System.Collections.Specialized.StringCollection
    $names | ForEach-Object { [void]$collection.Add($_) }
    [System.Windows.Forms.Clipboard]::SetFileDropList($collection)
    $before = (Get-Pins).Count
    [Q]::SetCursorPos(1400, 300) | Out-Null
    Start-Sleep -Milliseconds 250
    Send-Key 0x72
    Start-Sleep -Milliseconds 1800
    "PINS_BEFORE=$before PINS_AFTER=$((Get-Pins).Count) FILES=$($names.Count)"
    (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } | Select-Object -First 3) | ForEach-Object {
      "  $([Q]::Describe($_))"
    }
  }
  "menu" {
    $pin = Get-LargestPin
    $r = Get-Rect $pin
    [Q]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2)) | Out-Null
    Start-Sleep -Milliseconds 250
    [Q]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [Q]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 800
    "MENU_OPEN=$(([Q]::Windows('#32768')).Count)"
    [Q]::SetCursorPos(1200, 1320) | Out-Null
    Start-Sleep -Milliseconds 200
    [Q]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [Q]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 900
    "MENU_AFTER_OUTSIDE_CLICK=$(([Q]::Windows('#32768')).Count)"
    "PINS_ALIVE=$((Get-Pins).Count)"
  }
  "exclude-capture" {
    $pin = Get-LargestPin
    $r = Get-Rect $pin
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    $bitmap = New-Object System.Drawing.Bitmap $w, $h
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $graphics.Dispose()
    $sample = @()
    foreach ($point in @(@([int]($w / 2), [int]($h / 2)), @([int]($w / 4), [int]($h / 2)), @([int]($w * 3 / 4), [int]($h / 2)))) {
      $pixel = $bitmap.GetPixel($point[0], $point[1])
      $sample += "$($pixel.R),$($pixel.G),$($pixel.B)"
    }
    $path = Join-Path $PSScriptRoot "pin-exclude-capture.png"
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    "PIN=$([Q]::Describe($pin))"
    "SCREEN_SAMPLES=$($sample -join ' | ') PATH=$path"
  }
  "visual" {
    $pins = Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending
    $index = 0
    foreach ($pin in $pins) {
      $rect = Get-Rect $pin
      $w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
      $bitmap = New-Object System.Drawing.Bitmap $w, $h
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      $hdc = $graphics.GetHdc()
      $ok = [Q]::PrintWindow($pin, $hdc, 2)
      $graphics.ReleaseHdc($hdc)
      $graphics.Dispose()
      $path = Join-Path $PSScriptRoot ("pin-visual-{0}.png" -f $index)
      $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
      $edge = @()
      foreach ($point in @(@(0,0), @(($w - 1),0), @(0,($h - 1)), @(($w - 1),($h - 1)), @([int]($w/2),0), @([int]($w/2),($h - 1)), @(0,[int]($h/2)), @(($w - 1),[int]($h/2)))) {
        $pixel = $bitmap.GetPixel($point[0], $point[1])
        $edge += "$($pixel.R),$($pixel.G),$($pixel.B),$($pixel.A)"
      }
      "PIN[$index] $([Q]::Describe($pin))"
      "  PRINTWINDOW=$ok PATH=$path"
      "  EDGE=$($edge -join ' | ')"
      $bitmap.Dispose()
      $index++
    }
  }
  "paste-second-display" {
    $bitmap = New-Object System.Drawing.Bitmap 400, 300
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromArgb(255, 40, 120, 220))
    $graphics.Dispose()
    [System.Windows.Forms.Clipboard]::SetImage($bitmap)
    $bitmap.Dispose()
    $before = (Get-Pins)
    [Q]::SetCursorPos(3800, 700) | Out-Null
    Start-Sleep -Milliseconds 250
    Send-Key 0x72
    Start-Sleep -Milliseconds 1600
    $fresh = @(Get-Pins | Where-Object { $before -notcontains $_ })
    "NEW_PINS=$($fresh.Count)"
    foreach ($pin in $fresh) { "  $([Q]::Describe($pin)) ON_SECOND_DISPLAY=$((Get-Rect $pin).Left -ge 2560)" }
  }  "styles" {
    foreach ($pin in Get-Pins) {
      $plain = [Q]::GetWindowLongPtr($pin, -16).ToInt64()
      $ex = [Q]::GetWindowLongPtr($pin, -20).ToInt64()
      $caption = ($plain -band 0x00C00000) -ne 0
      $border = ($plain -band 0x00800000) -ne 0
      $thick = ($plain -band 0x00040000) -ne 0
      $popup = ($plain -band 0x80000000) -ne 0
      "PIN=0x$($pin.ToInt64().ToString('X')) STYLE=0x$($plain.ToString('X')) EX=0x$($ex.ToString('X')) POPUP=$popup CAPTION=$caption BORDER=$border RESIZABLE=$thick"
    }
  }  "exclude-verify" {
    Add-Type -Name Aff -Namespace Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr hwnd, out uint affinity);'
    foreach ($pin in Get-Pins) {
      $value = 0
      [void][Win.Aff]::GetWindowDisplayAffinity($pin, [ref]$value)
      "PIN=0x$($pin.ToInt64().ToString('X')) AFFINITY=0x$($value.ToString('X')) (0x11 means excluded from capture)"
    }
    $pin = Get-LargestPin
    $rect = Get-Rect $pin
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    function Sample-Region([int]$x, [int]$y, [int]$width, [int]$height) {
      $bitmap = New-Object System.Drawing.Bitmap $width, $height
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      $graphics.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $width, $height))
      $graphics.Dispose()
      $values = @()
      foreach ($point in @(@([int]($width / 2), [int]($height / 2)), @([int]($width / 4), [int]($height / 2)), @([int]($width * 3 / 4), [int]($height / 2)), @(10, 10))) {
        $pixel = $bitmap.GetPixel($point[0], $point[1])
        $values += "$($pixel.R),$($pixel.G),$($pixel.B)"
      }
      $bitmap.Dispose()
      return ($values -join " | ")
    }
    $before = Sample-Region $rect.Left $rect.Top $w $h
    [void][Q]::SendMessage($pin, 0x0111, [IntPtr]1, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 800
    $after = Sample-Region $rect.Left $rect.Top $w $h
    "WHILE_PINNED=$before"
    "AFTER_CLOSE =$after"
    "PIN_ABSENT_FROM_CAPTURE=$($before -eq $after)"
  }  "cleanup" {
    foreach ($pin in Get-Pins) {
      [void][Q]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 200
    }
    Start-Sleep -Milliseconds 500
    "PINS_LEFT=$((Get-Pins).Count) BADGES_LEFT=$((Get-Badges).Count)"
  }
  "close-one" {
    $pin = Get-SmallestPin
    [void][Q]::SendMessage($pin, 0x0111, [IntPtr]1, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    "PINS_LEFT=$((Get-Pins).Count) TARGET_CLOSED=$(-not ((Get-Pins) -contains $pin))"
  }
  "idle" {
    $process = Get-Process kiri | Select-Object -First 1
    $before = $process.TotalProcessorTime.TotalMilliseconds
    Start-Sleep -Seconds 6
    $process.Refresh()
    $cpu = $process.TotalProcessorTime.TotalMilliseconds - $before
    "IDLE_CPU_MS_OVER_6S=$([math]::Round($cpu,1)) WS_MB=$([math]::Round($process.WorkingSet64/1MB,1)) PRIVATE_MB=$([math]::Round($process.PrivateMemorySize64/1MB,1)) HANDLES=$($process.HandleCount) PINS=$((Get-Pins).Count)"
  }
}
