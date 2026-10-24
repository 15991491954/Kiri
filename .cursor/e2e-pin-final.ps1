# End-to-end checks for the native pin feature (review pass 2).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -STA -File .cursor\e2e-pin-final.ps1 <stage>
param([string]$Stage = "info")

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class W {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
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
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetProcessWindowStation();

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

  public static List<IntPtr> ZOrder() {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => { found.Add(hwnd); return true; }, IntPtr.Zero);
    return found;
  }

  public static string ClassOf(IntPtr hwnd) {
    if (hwnd == IntPtr.Zero) return "(none)";
    var name = new StringBuilder(256);
    GetClassName(hwnd, name, name.Capacity);
    return name.ToString();
  }

  public static string Describe(IntPtr hwnd) {
    RECT r; GetWindowRect(hwnd, out r);
    uint pid; GetWindowThreadProcessId(hwnd, out pid);
    long style = (long)GetWindowLongPtr(hwnd, -20);
    long plain = (long)GetWindowLongPtr(hwnd, -16);
    return string.Format("hwnd=0x{0:X} pid={1} rect={2},{3} {4}x{5} visible={6} ex=0x{7:X} topmost={8} layered={9} toolwindow={10} noactivate={11} appwindow={12}",
      hwnd.ToInt64(), pid, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top,
      IsWindowVisible(hwnd), style,
      (style & 0x8) != 0, (style & 0x80000) != 0, (style & 0x80) != 0, (style & 0x8000000) != 0,
      (plain & 0x00040000) != 0);
  }
}
"@

function Get-Pins { [W]::Windows("KiriPinWindow") }
function Get-Badges { [W]::Windows("KiriPinBadge") }

function Get-Rect([IntPtr]$hwnd) {
  $rect = New-Object W+RECT
  [W]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
  return $rect
}

function Move-ToCentre([IntPtr]$hwnd) {
  $rect = Get-Rect $hwnd
  $x = [int](($rect.Left + $rect.Right) / 2)
  $y = [int](($rect.Top + $rect.Bottom) / 2)
  [W]::SetCursorPos($x, $y) | Out-Null
  return @($x, $y)
}

function New-Shot([IntPtr]$hwnd, [int]$mode = 2) {
  $rect = Get-Rect $hwnd
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  $bitmap = New-Object System.Drawing.Bitmap $width, $height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $hdc = $graphics.GetHdc()
  $ok = [W]::PrintWindow($hwnd, $hdc, $mode)
  $graphics.ReleaseHdc($hdc)
  $graphics.Dispose()
  return @($bitmap, $ok, $width, $height)
}

switch ($Stage) {
  "info" {
    $pins = Get-Pins
    "PINS=$($pins.Count)"
    $pins | ForEach-Object { [W]::Describe($_) }
    "BADGES=$((Get-Badges).Count)"
    "FG=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X')) class=$([W]::ClassOf([W]::GetForegroundWindow()))"
    "SCREENS="
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
      "  $($_.DeviceName) bounds=$($_.Bounds) working=$($_.WorkingArea) primary=$($_.Primary)"
    }
    Get-Process kiri | ForEach-Object {
      "PROC id=$($_.Id) ws_mb=$([math]::Round($_.WorkingSet64/1MB,1)) private_mb=$([math]::Round($_.PrivateMemorySize64/1MB,1)) handles=$($_.HandleCount) threads=$($_.Threads.Count)"
    }
  }
  "visual" {
    $pins = Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending
    $index = 0
    foreach ($pin in $pins) {
      $shot = New-Shot $pin 2
      $bitmap = $shot[0]
      $path = Join-Path $PSScriptRoot ("pin-visual-{0}.png" -f $index)
      $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
      # Sample the outermost pixels: a border would make the edge uniform near-black.
      $edge = @()
      $w = $bitmap.Width; $h = $bitmap.Height
      foreach ($point in @(@(0,0), @(($w - 1),0), @(0,($h - 1)), @(($w - 1),($h - 1)), @([int]($w/2),0), @([int]($w/2),($h - 1)), @(0,[int]($h/2)), @(($w - 1),[int]($h/2)))) {
        $pixel = $bitmap.GetPixel($point[0], $point[1])
        $edge += "$($pixel.R),$($pixel.G),$($pixel.B),$($pixel.A)"
      }
      $centre = $bitmap.GetPixel([int]($w/2), [int]($h/2))
      "PIN[$index] $([W]::Describe($pin))"
      "  PRINTWINDOW=$($shot[1]) SIZE=${w}x${h} PATH=$path"
      "  EDGE=$($edge -join ' | ')"
      "  CENTRE=$($centre.R),$($centre.G),$($centre.B),$($centre.A)"
      $bitmap.Dispose()
      $index++
    }
  }
  "drag" {
    # EnumWindows is top-down, so the first pin is the one a click lands on.
    # Measuring any other sibling would report a zero delta.
    $pin = (Get-Pins)[0]
    $before = Get-Rect $pin
    $coords = Move-ToCentre $pin
    Start-Sleep -Milliseconds 150
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    for ($step = 1; $step -le 8; $step++) {
      [W]::SetCursorPos($coords[0] + $step * 5, $coords[1] + $step * 4) | Out-Null
      Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 120
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 350
    $after = Get-Rect $pin
    "BEFORE=$($before.Left),$($before.Top) $($before.Right-$before.Left)x$($before.Bottom-$before.Top)"
    "AFTER =$($after.Left),$($after.Top) $($after.Right-$after.Left)x$($after.Bottom-$after.Top)"
    "DELTA =$($after.Left-$before.Left),$($after.Top-$before.Top) EXPECTED=40,32"
    "SIZE_UNCHANGED=$(($after.Right-$after.Left) -eq ($before.Right-$before.Left) -and ($after.Bottom-$after.Top) -eq ($before.Bottom-$before.Top))"
  }
  "wheel" {
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
    $before = Get-Rect $pin
    $coords = Move-ToCentre $pin
    Start-Sleep -Milliseconds 150
    "BEFORE=$($before.Left),$($before.Top) $($before.Right-$before.Left)x$($before.Bottom-$before.Top)"
    [W]::mouse_event(0x0800, 0, 0, 120, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $after = Get-Rect $pin
    "AFTER_UP=$($after.Left),$($after.Top) $($after.Right-$after.Left)x$($after.Bottom-$after.Top)"
    $badges = Get-Badges
    "BADGES=$($badges.Count) visible=$(($badges | Where-Object { [W]::Describe($_) -match 'visible=True' }).Count)"
    $badges | ForEach-Object { "  BADGE $([W]::Describe($_))" }
    $shot = New-Shot $badges[0] 2
    if ($shot[1]) { $path = Join-Path $PSScriptRoot "pin-badge.png"; $shot[0].Save($path, [System.Drawing.Imaging.ImageFormat]::Png); "  BADGE_PATH=$path" }
    $shot[0].Dispose()
    $ratio = [math]::Round((($after.Right-$after.Left) / ($before.Right-$before.Left)), 4)
    "RATIO=$ratio EXPECTED=1.1"
    Start-Sleep -Milliseconds 1200
    $hidden = (Get-Badges | Where-Object { ([W]::Describe($_)) -match 'visible=True' }).Count
    "BADGE_VISIBLE_AFTER_1.6S=$hidden"
    # A wheel-down notch must be a signed -120. Passing the 16-bit pattern
    # 65416 sends +65416, which Windows splits into many zoom-in notches.
    [W]::mouse_event(0x0800, 0, 0, [uint32]4294967176, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $down = Get-Rect $pin
    "AFTER_DOWN=$($down.Left),$($down.Top) $($down.Right-$down.Left)x$($down.Bottom-$down.Top)"
    "DOWN_RATIO=$([math]::Round((($down.Right-$down.Left) / ($after.Right-$after.Left)), 4)) EXPECTED=0.9091"
  }
  "topmost" {
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
    $rect = Get-Rect $pin
    $coords = Move-ToCentre $pin
    $point = New-Object W+POINT
    $point.X = $coords[0]; $point.Y = $coords[1]
    "HIT_BEFORE=0x$(([W]::WindowFromPoint($point)).ToInt64().ToString('X')) pin=0x$($pin.ToInt64().ToString('X'))"
    $notepad = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1200
    $notepad.Refresh()
    $note = $notepad.MainWindowHandle
    [W]::SetWindowPos($note, [IntPtr]::Zero, $rect.Left - 40, $rect.Top - 40, ($rect.Right-$rect.Left) + 80, ($rect.Bottom-$rect.Top) + 80, 0x0040) | Out-Null
    [W]::SetForegroundWindow($note) | Out-Null
    Start-Sleep -Milliseconds 500
    $hit = [W]::WindowFromPoint($point)
    "NOTEPAD=0x$($note.ToInt64().ToString('X')) FG=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X'))"
    "HIT_AFTER=0x$($hit.ToInt64().ToString('X')) class=$([W]::ClassOf($hit)) pinOnTop=$($hit -eq $pin)"
    # Click the pin while another app owns the foreground: focus must not move.
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $fg = [W]::GetForegroundWindow()
    "FG_AFTER_PIN_CLICK=0x$($fg.ToInt64().ToString('X')) stillNotepad=$($fg -eq $note)"
    Stop-Process -Id $notepad.Id -Force
  }
  "escape" {
    $pins = Get-Pins
    if ($pins.Count -lt 2) { "NEED_TWO_PINS count=$($pins.Count)"; break }
    # Sort by area: close the smallest while the cursor is over it.
    $target = ($pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) })[0]
    $other = $pins | Where-Object { $_ -ne $target } | Select-Object -First 1
    Move-ToCentre $target | Out-Null
    Start-Sleep -Milliseconds 200
    "TARGET=$([W]::Describe($target))"
    "OTHER =$([W]::Describe($other))"
    # Two key-downs without a key-up: the second must be treated as auto-repeat.
    [W]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [W]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    [W]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    $afterPins = Get-Pins
    "PINS_AFTER=$($afterPins.Count) TARGET_DESTROYED=$(-not ($afterPins -contains $target)) OTHER_ALIVE=$($afterPins -contains $other)"
    # Esc with the cursor over empty desktop must not close a pin.
    [W]::SetCursorPos(1200, 700) | Out-Null
    Start-Sleep -Milliseconds 150
    [W]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [W]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    "PINS_AFTER_EMPTY_ESC=$((Get-Pins).Count)"
  }
  "paste-image" {
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap 300, 200
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromArgb(255, 200, 60, 60))
    $graphics.FillEllipse([System.Drawing.Brushes]::Gold, 60, 40, 120, 80)
    $graphics.Dispose()
    [System.Windows.Forms.Clipboard]::SetImage($bitmap)
    $bitmap.Dispose()
    [W]::SetCursorPos(2200, 700) | Out-Null
    Start-Sleep -Milliseconds 250
    "CLIP_HAS_IMAGE=$([System.Windows.Forms.Clipboard]::ContainsImage())"
    [W]::keybd_event(0x72, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [W]::keybd_event(0x72, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1200
    $pins = Get-Pins
    "PINS=$($pins.Count)"
    $pins | ForEach-Object { [W]::Describe($_) }
    "CLIP_STILL_HAS_IMAGE=$([System.Windows.Forms.Clipboard]::ContainsImage())"
  }
  "paste-text" {
    [System.Windows.Forms.Clipboard]::SetText("Kiri pin review`r`n第二行文本 with mixed content.")
    [W]::SetCursorPos(2000, 900) | Out-Null
    Start-Sleep -Milliseconds 250
    [W]::keybd_event(0x72, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [W]::keybd_event(0x72, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1200
    $pins = Get-Pins
    "PINS=$($pins.Count)"
    $pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } | ForEach-Object { [W]::Describe($_) }
  }
  "paste-files" {
    $dir = Join-Path $env:TEMP "kiri-pin-qa"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $names = @()
    foreach ($index in 1..2) {
      $path = Join-Path $dir ("qa-{0}.png" -f $index)
      $bitmap = New-Object System.Drawing.Bitmap (120 + $index * 20), 100
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
    [W]::SetCursorPos(2300, 300) | Out-Null
    Start-Sleep -Milliseconds 250
    [W]::keybd_event(0x72, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [W]::keybd_event(0x72, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1500
    $pins = Get-Pins
    "PINS=$($pins.Count) FILES=$($names.Count)"
    $pins | ForEach-Object { [W]::Describe($_) }
    "FILES=" + ($names -join ";")
  }
  "dragfast" {
    $pin = (Get-Pins)[0]
    $before = Get-Rect $pin
    $coords = Move-ToCentre $pin
    Start-Sleep -Milliseconds 150
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    # One large jump out of the pin: only the low-level hook can follow this.
    [W]::SetCursorPos($coords[0] - 220, $coords[1] + 140) | Out-Null
    Start-Sleep -Milliseconds 200
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $after = Get-Rect $pin
    "BEFORE=$($before.Left),$($before.Top) AFTER=$($after.Left),$($after.Top)"
    "DELTA =$($after.Left-$before.Left),$($after.Top-$before.Top) EXPECTED=-220,140"
  }
  "textwrap" {
    $before = @(Get-Pins)
    $long = ("abcdefghij0123456789" * 15)
    [System.Windows.Forms.Clipboard]::SetText($long)
    [W]::SetCursorPos(1800, 500) | Out-Null
    Start-Sleep -Milliseconds 250
    [W]::keybd_event(0x72, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [W]::keybd_event(0x72, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1500
    $fresh = @(Get-Pins | Where-Object { $before -notcontains $_ })
    "NEW_PINS=$($fresh.Count)"
    foreach ($pin in $fresh) {
      $shot = New-Shot $pin 2
      $path = Join-Path $PSScriptRoot "pin-textwrap.png"
      $shot[0].Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
      "TEXT_PIN $([W]::Describe($pin)) PATH=$path"
      $shot[0].Dispose()
    }
    "CHARS=$($long.Length)"
  }
  "menu" {
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
    $coords = Move-ToCentre $pin
    Start-Sleep -Milliseconds 200
    [W]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [W]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 600
    $menus = [W]::Windows("#32768")
    "MENU_OPEN=$($menus.Count)"
    # Click somewhere else: a foreground-capable menu must dismiss itself.
    [W]::SetCursorPos(1200, 800) | Out-Null
    Start-Sleep -Milliseconds 150
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 800
    "MENU_AFTER_OUTSIDE_CLICK=$(([W]::Windows('#32768')).Count)"
    "PINS_AFTER_MENU=$((Get-Pins).Count)"
    # Close any menu still open so later stages start clean.
    if (([W]::Windows("#32768")).Count -gt 0) {
      [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
      Start-Sleep -Milliseconds 400
    }
  }
  "close-all" {
    $pins = Get-Pins
    foreach ($pin in $pins) { [void][W]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero); Start-Sleep -Milliseconds 200 }
    Start-Sleep -Milliseconds 400
    "PINS_LEFT=$((Get-Pins).Count) BADGES_LEFT=$((Get-Badges).Count)"
    $process = Get-Process kiri
    $before = $process.TotalProcessorTime.TotalMilliseconds
    Start-Sleep -Seconds 5
    $process.Refresh()
    $cpu = $process.TotalProcessorTime.TotalMilliseconds - $before
    "IDLE_CPU_MS_OVER_5S=$([math]::Round($cpu,1)) WS_MB=$([math]::Round($process.WorkingSet64/1MB,1)) HANDLES=$($process.HandleCount)"
  }
}
