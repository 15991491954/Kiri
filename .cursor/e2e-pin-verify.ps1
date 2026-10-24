# End-to-end verification for the native pin feature (review pass).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -STA -File .cursor\e2e-pin-verify.ps1 <stage>
param([string]$Stage = "info")

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes

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
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder name, int max);
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
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern int GetWindowBand(IntPtr hwnd, out int band);
  [DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, ref int value, uint flags);

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

  public static int ZIndexRelative(IntPtr target, IntPtr reference) {
    // Walk the z-order from the top and return the index of each.
    var list = new List<IntPtr>();
    EnumWindows((hwnd, _) => { list.Add(hwnd); return true; }, IntPtr.Zero);
    int a = list.IndexOf(target), b = list.IndexOf(reference);
    if (a < 0 || b < 0) return -1;
    return a - b;
  }
}
"@

$KiriExe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path

function Get-Pins { [W]::Windows("KiriPinWindow") }
function Get-Badges { [W]::Windows("KiriPinBadge") }
function Get-KiriPid { (Get-Process kiri -ErrorAction Stop | Select-Object -First 1).Id }

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

function Send-Key([byte]$vk, [bool]$up = $false) {
  [W]::keybd_event($vk, 0, $(if ($up) { 2 } else { 0 }), [UIntPtr]::Zero)
}

function Send-Wheel([int]$notches) {
  # mouse_event takes the signed wheel delta in the high word of a DWORD;
  # PowerShell cannot cast a negative Int32 to UInt32, so add 2^32 explicitly.
  $raw = [int64]$notches * 120
  if ($raw -lt 0) { $raw += 4294967296 }
  [W]::mouse_event(0x0800, 0, 0, [uint32]$raw, [UIntPtr]::Zero)
}

function Press-F3 {
  Send-Key 0x72
  Start-Sleep -Milliseconds 60
  Send-Key 0x72 $true
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

function Find-UiaButton([IntPtr]$hwnd, [string]$pattern) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  if (-not $root) { return $null }
  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
  $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
  foreach ($button in $buttons) {
    $name = $button.Current.Name
    if ($name -match $pattern) { return $button }
  }
  return $null
}

switch ($Stage) {
  "info" {
    $pidKiri = Get-KiriPid
    "KIRI_PID=$pidKiri"
    "PINS=$((Get-Pins).Count) BADGES=$((Get-Badges).Count)"
    Get-Pins | ForEach-Object { [W]::Describe($_) }
    Get-Badges | ForEach-Object { [W]::Describe($_) }
    "FG=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X')) class=$([W]::ClassOf([W]::GetForegroundWindow()))"
    "KIRI_WINDOWS="
    [W]::ProcessWindows([uint32]$pidKiri, $true) | ForEach-Object {
      "  0x$($_.ToInt64().ToString('X')) class=$([W]::ClassOf($_)) title=$([W]::TitleOf($_)) rect=$((Get-Rect $_).Left),$((Get-Rect $_).Top)"
    }
    Get-Process kiri | ForEach-Object {
      "PROC id=$($_.Id) ws_mb=$([math]::Round($_.WorkingSet64/1MB,1)) private_mb=$([math]::Round($_.PrivateMemorySize64/1MB,1)) handles=$($_.HandleCount) threads=$($_.Threads.Count)"
    }
  }
  "paste-image" {
    $bitmap = New-Object System.Drawing.Bitmap 480, 320
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromArgb(255, 32, 140, 220))
    $graphics.FillRectangle([System.Drawing.Brushes]::Orange, 40, 40, 400, 240)
    $graphics.Dispose()
    [System.Windows.Forms.Clipboard]::SetImage($bitmap)
    $bitmap.Dispose()
    [W]::SetCursorPos(1200, 700) | Out-Null
    Start-Sleep -Milliseconds 250
    Press-F3
    Start-Sleep -Milliseconds 1200
    $pins = Get-Pins
    "PINS=$($pins.Count) CLIP_IMAGE=$([System.Windows.Forms.Clipboard]::ContainsImage())"
    $pins | ForEach-Object { [W]::Describe($_) }
    "CURSOR=1200,700 (pin should be centred there)"
    $pins | ForEach-Object {
      $r = Get-Rect $_
      "  EXPECTED_CENTRE_X=$([int](($r.Left + $r.Right) / 2)) EXPECTED_CENTRE_Y=$([int](($r.Top + $r.Bottom) / 2))"
    }
  }
  "paste-text" {
    [System.Windows.Forms.Clipboard]::SetText("Kiri pin review`r`n绗簩琛屾枃鏈?with mixed content.")
    [W]::SetCursorPos(2000, 900) | Out-Null
    Start-Sleep -Milliseconds 250
    Press-F3
    Start-Sleep -Milliseconds 1200
    $pins = Get-Pins
    "PINS=$($pins.Count)"
    $pins | ForEach-Object { [W]::Describe($_) }
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
    Press-F3
    Start-Sleep -Milliseconds 1500
    $pins = Get-Pins
    "PINS=$($pins.Count) FILES=$($names.Count)"
    $pins | ForEach-Object { [W]::Describe($_) }
  }
  "drag" {
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
    $before = Get-Rect $pin
    $coords = Move-ToCentre $pin
    $fgBefore = [W]::GetForegroundWindow()
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
    "DELTA =$($after.Left-$before.Left),$($after.Top-$before.Top)"
    "SIZE_UNCHANGED=$(($after.Right-$after.Left) -eq ($before.Right-$before.Left) -and ($after.Bottom-$after.Top) -eq ($before.Bottom-$before.Top))"
    "FOCUS_UNCHANGED=$([W]::GetForegroundWindow() -eq $fgBefore)"
  }
  "wheel" {
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
    $before = Get-Rect $pin
    $coords = Move-ToCentre $pin
    Start-Sleep -Milliseconds 200
    "BEFORE=$($before.Left),$($before.Top) $($before.Right-$before.Left)x$($before.Bottom-$before.Top)"
    # Wheel up: one notch towards the pointer's quadrant (cursor is centred).
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    Send-Wheel 1
    Start-Sleep -Milliseconds 400
    $after = Get-Rect $pin
    "AFTER_UP=$($after.Left),$($after.Top) $($after.Right-$after.Left)x$($after.Bottom-$after.Top) ELAPSED_MS=$($clock.ElapsedMilliseconds)"
    $badges = Get-Badges
    "BADGES=$($badges.Count) visible=$(($badges | Where-Object { [W]::Describe($_) -match 'visible=True' }).Count)"
    $badges | ForEach-Object { "  BADGE $([W]::Describe($_))" }
    if ($badges.Count -gt 0) {
      $shot = New-Shot $badges[0] 2
      if ($shot[1]) {
        $path = Join-Path $PSScriptRoot "verify-badge.png"
        $shot[0].Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        "  BADGE_PATH=$path"
      }
      $shot[0].Dispose()
    }
    $ratio = [math]::Round((($after.Right-$after.Left) / ($before.Right-$before.Left)), 4)
    "RATIO=$ratio EXPECTED=1.1"
    "ASPECT_BEFORE=$([math]::Round(($before.Right-$before.Left) / ($before.Bottom-$before.Top), 6)) AFTER=$([math]::Round(($after.Right-$after.Left) / ($after.Bottom-$after.Top), 6))"
    Start-Sleep -Milliseconds 1200
    "BADGE_VISIBLE_AFTER_1.6S=$(($badges | Where-Object { [W]::Describe($_) -match 'visible=True' }).Count)"
    Send-Wheel -1
    Start-Sleep -Milliseconds 400
    $back = Get-Rect $pin
    "AFTER_DOWN=$($back.Right-$back.Left)x$($back.Bottom-$back.Top) RESTORED=$(($back.Right-$back.Left) -eq ($before.Right-$before.Left))"
  }
  "zoom-drag" {
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
    $before = Get-Rect $pin
    $coords = Move-ToCentre $pin
    Start-Sleep -Milliseconds 200
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    Send-Wheel 1
    Start-Sleep -Milliseconds 250
    $zoomed = Get-Rect $pin
    "ZOOMED_WHILE_HELD=$($zoomed.Right-$zoomed.Left)x$($zoomed.Bottom-$zoomed.Top)"
    [W]::SetCursorPos($coords[0] + 30, $coords[1] + 20) | Out-Null
    Start-Sleep -Milliseconds 200
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $after = Get-Rect $pin
    "AFTER_DRAG=$($after.Right-$after.Left)x$($after.Bottom-$after.Top)"
    "SIZE_KEPT=$((($after.Right-$after.Left) -eq ($zoomed.Right-$zoomed.Left)) -and (($after.Bottom-$after.Top) -eq ($zoomed.Bottom-$zoomed.Top)))"
    "BEFORE_SIZE=$($before.Right-$before.Left)x$($before.Bottom-$before.Top)"
  }
  "focus" {
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
    $coords = Move-ToCentre $pin
    Start-Sleep -Milliseconds 250
    $fg = [W]::GetForegroundWindow()
    "FG_BEFORE=0x$($fg.ToInt64().ToString('X')) class=$([W]::ClassOf($fg)) title=$([W]::TitleOf($fg))"
    "PIN=0x$($pin.ToInt64().ToString('X'))"
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    $fgAfter = [W]::GetForegroundWindow()
    "FG_AFTER_CLICK=0x$($fgAfter.ToInt64().ToString('X')) class=$([W]::ClassOf($fgAfter)) title=$([W]::TitleOf($fgAfter))"
    "PIN_ACTIVATED=$($fgAfter -eq $pin)"
    # Read SPI_GETMOUSEWHEELROUTING so the activate-on-click tradeoff is explicit.
    $routing = 0
    $ok = [W]::SystemParametersInfo(0x104E, 0, [ref]$routing, 0)
    "WHEEL_ROUTING_ON_HOVER=$routing SPI_OK=$ok"
    # The menu is dismissed by clicking the pin itself in other tests: also
    # check a plain click cannot raise an unpinned pin.
    "Z_ABOVE_OTHERS=$([W]::ZIndexRelative($pin, $fgAfter))"
  }
  "wheel-steps" {
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
    $coords = Move-ToCentre $pin
    Start-Sleep -Milliseconds 250
    $point = New-Object W+POINT
    $point.X = $coords[0]; $point.Y = $coords[1]
    "HIT=0x$(([W]::WindowFromPoint($point)).ToInt64().ToString('X')) pin=0x$($pin.ToInt64().ToString('X'))"
    $steps = @(@(@('up', 1), @('down', -1), @('down', -1), @('up', 1)))
    foreach ($step in $steps) {
      Send-Wheel $step[1]
      Start-Sleep -Milliseconds 500
      $r = Get-Rect $pin
      "AFTER_$($step[0])_$($step[1]) = $($r.Right-$r.Left)x$($r.Bottom-$r.Top) at $($r.Left),$($r.Top)"
    }
  }
  "wheel-focus" {
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) })[0]
    $coords = Move-ToCentre $pin
    Start-Sleep -Milliseconds 200
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $fg = [W]::GetForegroundWindow()
    "FG=0x$($fg.ToInt64().ToString('X')) class=$([W]::ClassOf($fg)) PIN_FOCUSED=$($fg -eq $pin)"
    foreach ($step in @(@(@('up', 1), @('up', 1), @('down', -1), @('down', -1), @('down', -1)))) {
      Send-Wheel $step[1]
      Start-Sleep -Milliseconds 450
      $r = Get-Rect $pin
      "AFTER_$($step[0])_$($step[1]) = $($r.Right-$r.Left)x$($r.Bottom-$r.Top)"
    }
    $badges = Get-Badges
    "BADGES=$($badges.Count) visible=$(($badges | Where-Object { [W]::Describe($_) -match 'visible=True' }).Count)"
  }
  "wheel-route" {
    $note = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1200
    $note.Refresh()
    $noteH = $note.MainWindowHandle
    [W]::SetForegroundWindow($noteH) | Out-Null
    Start-Sleep -Milliseconds 400
    "FG=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X')) NOTEPAD=0x$($noteH.ToInt64().ToString('X')) FOCUS_WORKS=$([W]::GetForegroundWindow() -eq $noteH)"
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
    $before = Get-Rect $pin
    $coords = Move-ToCentre $pin
    Start-Sleep -Milliseconds 250
    $point = New-Object W+POINT
    $point.X = $coords[0]; $point.Y = $coords[1]
    "HIT=0x$(([W]::WindowFromPoint($point)).ToInt64().ToString('X')) pin=0x$($pin.ToInt64().ToString('X'))"
    "SIZE_BEFORE=$($before.Right-$before.Left)x$($before.Bottom-$before.Top)"
    Send-Wheel 1
    Start-Sleep -Milliseconds 500
    $r = Get-Rect $pin
    "SIZE_AFTER_HOVER_WHEEL=$($r.Right-$r.Left)x$($r.Bottom-$r.Top) (routing must deliver it)"
    "BADGE_VISIBLE=$(($(Get-Badges) | Where-Object { [W]::Describe($_) -match 'visible=True' }).Count)"
    "FG_AFTER_HOVER_WHEEL=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X'))"
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    "FG_AFTER_CLICK=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X')) PIN_ACTIVATED=$(([W]::GetForegroundWindow()) -eq $pin)"
    Send-Wheel 1
    Start-Sleep -Milliseconds 500
    $r2 = Get-Rect $pin
    "SIZE_AFTER_FOCUSED_WHEEL=$($r2.Right-$r2.Left)x$($r2.Bottom-$r2.Top)"
    Stop-Process -Id $note.Id -Force -ErrorAction SilentlyContinue
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
    Start-Sleep -Milliseconds 600
    $hit = [W]::WindowFromPoint($point)
    "NOTEPAD=0x$($note.ToInt64().ToString('X')) FG=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X'))"
    "HIT_AFTER=0x$($hit.ToInt64().ToString('X')) class=$([W]::ClassOf($hit)) pinOnTop=$($hit -eq $pin)"
    [W]::SetCursorPos($coords[0], $coords[1]) | Out-Null
    Start-Sleep -Milliseconds 100
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $fg = [W]::GetForegroundWindow()
    "FG_AFTER_PIN_CLICK=0x$($fg.ToInt64().ToString('X')) stillNotepad=$($fg -eq $note)"
    Stop-Process -Id $notepad.Id -Force
  }
  "escape" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 2) { "NEED_TWO_PINS count=$($pins.Count)"; break }
    $target = ($pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) })[0]
    $other = $pins | Where-Object { $_ -ne $target } | Select-Object -First 1
    Move-ToCentre $target | Out-Null
    Start-Sleep -Milliseconds 250
    "TARGET=$([W]::Describe($target))"
    "OTHER =$([W]::Describe($other))"
    Send-Key 0x1B
    Start-Sleep -Milliseconds 60
    # Auto-repeat while still held must not close a second pin.
    Send-Key 0x1B
    Start-Sleep -Milliseconds 200
    Send-Key 0x1B $true
    Start-Sleep -Milliseconds 600
    $afterPins = @(Get-Pins)
    "PINS_AFTER=$($afterPins.Count) TARGET_DESTROYED=$(-not ($afterPins -contains $target)) OTHER_ALIVE=$($afterPins -contains $other)"
    [W]::SetCursorPos(1200, 700) | Out-Null
    Start-Sleep -Milliseconds 200
    Send-Key 0x1B
    Start-Sleep -Milliseconds 60
    Send-Key 0x1B $true
    Start-Sleep -Milliseconds 500
    "PINS_AFTER_EMPTY_ESC=$((Get-Pins).Count)"
  }
  "menu" {
    $pin = (Get-Pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending)[0]
    Move-ToCentre $pin | Out-Null
    Start-Sleep -Milliseconds 250
    [W]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [W]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    "MENU_OPEN=$(([W]::Windows('#32768')).Count)"
    [W]::SetCursorPos(1200, 800) | Out-Null
    Start-Sleep -Milliseconds 200
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 900
    "MENU_AFTER_OUTSIDE_CLICK=$(([W]::Windows('#32768')).Count)"
    "PINS_AFTER_MENU=$((Get-Pins).Count)"
    if (([W]::Windows("#32768")).Count -gt 0) {
      Send-Key 0x1B
      Start-Sleep -Milliseconds 60
      Send-Key 0x1B $true
      Start-Sleep -Milliseconds 500
    }
  }
  "close-all" {
    $pins = Get-Pins
    foreach ($pin in $pins) { [void][W]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero); Start-Sleep -Milliseconds 200 }
    Start-Sleep -Milliseconds 500
    "PINS_LEFT=$((Get-Pins).Count) BADGES_LEFT=$((Get-Badges).Count)"
    $process = Get-Process kiri
    $before = $process.TotalProcessorTime.TotalMilliseconds
    Start-Sleep -Seconds 5
    $process.Refresh()
    $cpu = $process.TotalProcessorTime.TotalMilliseconds - $before
    "IDLE_CPU_MS_OVER_5S=$([math]::Round($cpu,1)) WS_MB=$([math]::Round($process.WorkingSet64/1MB,1)) HANDLES=$($process.HandleCount) THREADS=$($process.Threads.Count)"
  }
  "capture" {
    # F1 flow: global shortcut, drag a region, invoke the toolbar pin button.
    $pidKiri = Get-KiriPid
    $before = @([W]::ProcessWindows([uint32]$pidKiri, $true)).Count
    Send-Key 0x11
    Send-Key 0x10
    Send-Key 0x41
    Start-Sleep -Milliseconds 60
    Send-Key 0x41 $true
    Send-Key 0x10 $true
    Send-Key 0x11 $true
    Start-Sleep -Milliseconds 1800
    $windows = @([W]::ProcessWindows([uint32]$pidKiri, $true))
    "KIRI_VISIBLE_WINDOWS=$($windows.Count) (was $before)"
    $windows | ForEach-Object { "  0x$($_.ToInt64().ToString('X')) class=$([W]::ClassOf($_)) title=$([W]::TitleOf($_)) $([W]::Describe($_))" }
    # Drag the capture region.
    [W]::SetCursorPos(300, 300) | Out-Null
    Start-Sleep -Milliseconds 120
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    for ($step = 1; $step -le 12; $step++) {
      [W]::SetCursorPos(300 + $step * 45, 300 + $step * 30) | Out-Null
      Start-Sleep -Milliseconds 20
    }
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 900
    $overlay = ([W]::ProcessWindows([uint32]$pidKiri, $true) | Where-Object { [W]::ClassOf($_) -eq 'Chrome_WidgetWin_1' } | Select-Object -First 1)
    "OVERLAY=0x$($overlay.ToInt64().ToString('X')) class=$([W]::ClassOf($overlay))"
    $button = Find-UiaButton $overlay "Pin|缃《|銉斻兂|Pin|Anheften|脡pingler|瓿犾爼"
    if (-not $button) {
      "UIA_PIN_BUTTON=missing"
      # Dump button names to make the localization / tree issue visible.
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($overlay)
      $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
      $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) | ForEach-Object { "  BUTTON name=$($_.Current.Name)" }
      break
    }
    "UIA_PIN_BUTTON=found name=$($button.Current.Name)"
    $bounds = $button.Current.BoundingRectangle
    "BOUNDS=$($bounds.Left),$($bounds.Top) $($bounds.Width)x$($bounds.Height)"
    $invoke = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($invoke) {
      $invoke.Invoke()
      "UIA_INVOKE=ok"
    } else {
      [W]::SetCursorPos([int]($bounds.Left + $bounds.Width / 2), [int]($bounds.Top + $bounds.Height / 2)) | Out-Null
      Start-Sleep -Milliseconds 120
      [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 80
      [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
      "CLICKED=$([int]($bounds.Left + $bounds.Width / 2)),$([int]($bounds.Top + $bounds.Height / 2))"
    }
    Start-Sleep -Milliseconds 1500
    $pins = @(Get-Pins)
    "PINS=$($pins.Count)"
    $pins | ForEach-Object { [W]::Describe($_) }
    "CLIP_IMAGE=$([System.Windows.Forms.Clipboard]::ContainsImage())"
    "KIRI_VISIBLE_WINDOWS_AFTER=$(@([W]::ProcessWindows([uint32]$pidKiri, $true)).Count)"
  }
}


