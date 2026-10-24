# End-to-end driver for the native Windows pin feature (review pass: requirements).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -STA -File .cursor\review2-e2e.ps1 <stage>
param([string]$Stage = "probe")

$ErrorActionPreference = "Stop"
$script:PinPattern = "Pin|" + [string][char]0x8D34 + [string][char]0x56FE + "|" +
  [string][char]0x7F6E + [string][char]0x9876 + "|" + [string][char]0x30D4 + [string][char]0x30F3
$script:Pass = 0
$script:Fail = 0
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class P {
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
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
  [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr hwnd, out uint affinity);

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
}
"@

function Check([string]$name, [bool]$ok, [string]$detail = "") {
  if ($ok) { $script:Pass++; "[PASS] $name $detail" } else { $script:Fail++; "[FAIL] $name $detail" }
}
function Get-Pins { @([P]::Windows("KiriPinWindow")) }
function Get-Badges { @([P]::Windows("KiriPinBadge")) }
function Get-VisibleBadges {
  @(Get-Badges | Where-Object { [P]::IsWindowVisible($_) })
}
function Get-KiriPid { (Get-Process kiri -ErrorAction Stop | Select-Object -First 1).Id }
function Get-Rect([IntPtr]$hwnd) {
  $r = New-Object P+RECT
  [void][P]::GetWindowRect($hwnd, [ref]$r)
  return $r
}
function Rect-Text([IntPtr]$hwnd) {
  $r = Get-Rect $hwnd
  return "$($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
}
function Center([IntPtr]$hwnd) {
  $r = Get-Rect $hwnd
  return @([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
}
function Ex-Style([IntPtr]$hwnd) { [P]::GetWindowLongPtr($hwnd, -20).ToInt64() }
function Style([IntPtr]$hwnd) { [P]::GetWindowLongPtr($hwnd, -16).ToInt64() }
function Is-Topmost([IntPtr]$hwnd) { ((Ex-Style $hwnd) -band 0x8) -ne 0 }
# PowerShell 5.1 parses hex literals with the top bit set as negative Int32, so
# a mask written as 0x80C00000 sign-extends and never matches a positive
# GWL_STYLE value. Build the masks from strings to keep every bit pattern exact.
function Mask([string]$hex) { [Convert]::ToInt64($hex, 16) }
function Has-CaptionOrBorder([IntPtr]$hwnd) {
  ((Style $hwnd) -band (Mask "80C00000")) -ne (Mask "80000000")
}
function Send-Key([byte]$vk) {
  [P]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [P]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
}
function Send-Hotkey([byte[]]$keys) {
  foreach ($key in $keys) { [P]::keybd_event($key, 0, 0, [UIntPtr]::Zero) }
  Start-Sleep -Milliseconds 60
  [byte[]]$reversed = $keys.Clone(); [array]::Reverse($reversed)
  foreach ($key in $reversed) { [P]::keybd_event($key, 0, 2, [UIntPtr]::Zero) }
}
function Send-Wheel([int]$notches) {
  $raw = [int64]$notches * 120
  if ($raw -lt 0) { $raw += 4294967296 }
  [P]::mouse_event(0x0800, 0, 0, [uint32]$raw, [UIntPtr]::Zero)
}
function Drag-By([int]$x1, [int]$y1, [int]$dx, [int]$dy, [int]$steps = 8) {
  [P]::SetCursorPos($x1, $y1) | Out-Null
  Start-Sleep -Milliseconds 150
  [P]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  for ($step = 1; $step -le $steps; $step++) {
    [P]::SetCursorPos($x1 + [int]($dx * $step / $steps), $y1 + [int]($dy * $step / $steps)) | Out-Null
    Start-Sleep -Milliseconds 25
  }
  Start-Sleep -Milliseconds 80
  [P]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 350
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
  @([P]::ProcessWindows([uint32]$pidKiri, $true) | Where-Object {
    if ([P]::ClassOf($_) -ne 'Tauri Window') { return $false }
    $r = Get-Rect $_
    ($r.Right - $r.Left) -ge 1000 -and ($r.Bottom - $r.Top) -ge 700
  })
}
function Get-Foreground { [P]::GetForegroundWindow() }
function Assets-Count {
  $path = Join-Path $env:APPDATA 'kiri\library.json'
  if (-not (Test-Path $path)) { return -1 }
  return (Select-String -Path $path -Pattern '"kind":' -AllMatches).Matches.Count
}
function Webview-Count { @(Get-Process msedgewebview2 -ErrorAction SilentlyContinue).Count }
function Send-F3 { Send-Key 0x72; Start-Sleep -Milliseconds 1500 }
function New-TestPng([string]$path, [int]$width, [int]$height, [int]$r, [int]$g, [int]$b) {
  $bitmap = New-Object System.Drawing.Bitmap $width, $height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(255, $r, $g, $b))
  $font = New-Object System.Drawing.Font "Segoe UI", 20
  $graphics.DrawString("Kiri", $font, [System.Drawing.Brushes]::White, 8, 8)
  $graphics.Dispose()
  $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
}
function Get-WorkingSet { (Get-Process kiri | Select-Object -First 1).WorkingSet64 }

switch ($Stage) {
  "probe" {
    "PINS=$((Get-Pins).Count) BADGES=$((Get-Badges).Count) KIRI_PID=$(Get-KiriPid)"
    "ASSETS=$(Assets-Count) WEBVIEW=$(Webview-Count) WS=$([math]::Round((Get-WorkingSet) / 1MB, 1))MB"
    foreach ($pin in Get-Pins) {
      "  PIN 0x$($pin.ToInt64().ToString('X')) $(Rect-Text $pin) ex=0x$((Ex-Style $pin).ToString('X'))"
    }
  }
  "shot-pin" {
    $pinsBefore = (Get-Pins).Count
    $assetsBefore = Assets-Count
    $fgBefore = Get-Foreground
    Send-Hotkey @(0x11, 0x10, 0x41)
    Start-Sleep -Milliseconds 2500
    $overlays = @(Get-Overlays)
    Check "capture overlay opens" ($overlays.Count -ge 1) "overlays=$($overlays.Count)"
    if ($overlays.Count -lt 1) { break }
    $target = $overlays | Where-Object { (Get-Rect $_).Left -eq 0 } | Select-Object -First 1
    if (-not $target) { $target = $overlays[0] }

    [P]::SetCursorPos(300, 260) | Out-Null
    Start-Sleep -Milliseconds 150
    [P]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    for ($step = 1; $step -le 10; $step++) {
      [P]::SetCursorPos(300 + $step * 52, 260 + $step * 36) | Out-Null
      Start-Sleep -Milliseconds 25
    }
    [P]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1000

    $button = Find-UiaButton $target $script:PinPattern
    Check "toolbar exposes the Pin action" ($null -ne $button)
    if (-not $button) { break }
    $invoke = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($invoke) { $invoke.Invoke() } else {
      $b = $button.Current.BoundingRectangle
      [P]::SetCursorPos([int]($b.Left + $b.Width / 2), [int]($b.Top + $b.Height / 2)) | Out-Null
      Start-Sleep -Milliseconds 120
      [P]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 60
      [P]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    }
    Start-Sleep -Milliseconds 2200
    $pins = @(Get-Pins)
    Check "screenshot creates one native pin" ($pins.Count -eq ($pinsBefore + 1)) "before=$pinsBefore after=$($pins.Count)"
    Check "overlay closes after pinning" (@(Get-Overlays).Count -eq 0)
    if ($pins.Count -eq ($pinsBefore + 1)) {
      $pin = $pins | Sort-Object { $_.ToInt64() } -Descending | Select-Object -First 1
      Check "pin lands on the captured rectangle" ((Rect-Text $pin) -eq "300,260 520x360") "pin=$(Rect-Text $pin) expected=300,260 520x360"
      Check "pin is borderless (popup, no caption/border)" (-not (Has-CaptionOrBorder $pin)) "style=0x$((Style $pin).ToString('X'))"
      Check "pin is layered, topmost, toolwindow" ((((Ex-Style $pin) -band 0x00080008) -eq 0x00080008) -and (((Ex-Style $pin) -band 0x80) -ne 0)) "ex=0x$((Ex-Style $pin).ToString('X'))"
      Check "pin is visible" ([P]::IsWindowVisible($pin))
      Check "pin did not change the foreground window" ((Get-Foreground) -eq $fgBefore) "fg=$(Get-Foreground) expected=$fgBefore"
      $c = Center $pin
      $hit = [P]::WindowFromPoint((New-Object P+POINT -Property @{X = $c[0]; Y = $c[1]}))
      Check "pin is the window under the pointer" ($hit -eq $pin) "hit=0x$($hit.ToInt64().ToString('X')) pin=0x$($pin.ToInt64().ToString('X'))"
      Check "screenshot pin is saved to the library once" ((Assets-Count) -eq ($assetsBefore + 1)) "before=$assetsBefore after=$(Assets-Count)"
    }
  }
  "second-pin" {
    $before = @(Get-Pins)
    $fgBefore = Get-Foreground
    $assetsBefore = Assets-Count
    [P]::SetCursorPos(1250, 760) | Out-Null
    Start-Sleep -Milliseconds 200
    $bitmap = New-Object System.Drawing.Bitmap 400, 300
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromArgb(255, 40, 120, 220))
    $font = New-Object System.Drawing.Font "Segoe UI", 24
    $graphics.DrawString("PIN", $font, [System.Drawing.Brushes]::White, 20, 20)
    $graphics.Dispose()
    [System.Windows.Forms.Clipboard]::SetImage($bitmap)
    $bitmap.Dispose()
    Send-F3
    $pins = @(Get-Pins)
    $fresh = @($pins | Where-Object { $before -notcontains $_ })
    Check "F3 pins the copied image" ($fresh.Count -eq 1) "new=$($fresh.Count)"
    Check "clipboard pin does not write the library" ((Assets-Count) -eq $assetsBefore) "before=$assetsBefore after=$(Assets-Count)"
    Check "clipboard pin opens at the image size" ($fresh.Count -eq 1 -and (Rect-Text $fresh[0]) -match "400x300") "pin=$(if ($fresh.Count -eq 1) { Rect-Text $fresh[0] } else { 'none' })"
    Check "clipboard pin takes no focus" ((Get-Foreground) -eq $fgBefore) "fg=$(Get-Foreground) expected=$fgBefore"
    if ($fresh.Count -eq 1) {
      $r = Get-Rect $fresh[0]
      Check "clipboard pin is centred on the pointer" ([math]::Abs((($r.Left + $r.Right) / 2) - 1250) -le 40 -and [math]::Abs((($r.Top + $r.Bottom) / 2) - 760) -le 40) "pin=$(Rect-Text $fresh[0]) cursor=1250,760"
    }
    "PINS=$($pins.Count)"
  }
  "drag" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 1) { Check "a pin exists to drag" $false; break }
    $pin = $pins[0]
    $c = Center $pin
    $before = Rect-Text $pin
    Drag-By $c[0] $c[1] 200 144 8
    $after = Rect-Text $pin
    $x0 = [int](($before -split ' ')[0].Split(',')[0])
    $y0 = [int](($before -split ' ')[0].Split(',')[1])
    $x1 = [int](($after -split ' ')[0].Split(',')[0])
    $y1 = [int](($after -split ' ')[0].Split(',')[1])
    $dx = $x1 - $x0
    $dy = $y1 - $y0
    Check "dragging the image moves the pin" ($dx -eq 200 -and $dy -eq 144) "before=$before after=$after delta=$dx,$dy"
    Check "dragging does not resize the pin" (($after -split ' ')[1] -eq ($before -split ' ')[1]) "before=$before after=$after"
  }
  "dragfast" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 1) { Check "a pin exists to drag" $false; break }
    $pin = $pins[0]
    $c = Center $pin
    $before = Rect-Text $pin
    [P]::SetCursorPos($c[0], $c[1]) | Out-Null
    Start-Sleep -Milliseconds 200
    [P]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [P]::SetCursorPos($c[0] - 260, $c[1] + 120) | Out-Null
    Start-Sleep -Milliseconds 300
    [P]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    $after = Rect-Text $pin
    $x0 = [int](($before -split ' ')[0].Split(',')[0]); $y0 = [int](($before -split ' ')[0].Split(',')[1])
    $x1 = [int](($after -split ' ')[0].Split(',')[0]); $y1 = [int](($after -split ' ')[0].Split(',')[1])
    Check "a fast flick still moves the pin" (($x1 - $x0) -eq -260 -and ($y1 - $y0) -eq 120) "before=$before after=$after delta=$($x1 - $x0),$($y1 - $y0)"
  }
  "topmost" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 1) { Check "pins exist" $false; break }
    $note = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1500
    $note.Refresh()
    $noteH = $note.MainWindowHandle
    # Cover every pin with the editor window and activate it.
    $left = ($pins | ForEach-Object { (Get-Rect $_).Left } | Measure-Object -Minimum).Minimum
    $top = ($pins | ForEach-Object { (Get-Rect $_).Top } | Measure-Object -Minimum).Minimum
    [P]::SetWindowPos($noteH, [IntPtr]::Zero, $left - 80, $top - 80, 900, 700, 0x0040) | Out-Null
    [P]::ShowWindow($noteH, 9) | Out-Null
    [P]::SetForegroundWindow($noteH) | Out-Null
    Start-Sleep -Milliseconds 900
    Check "another application becomes foreground" ((Get-Foreground) -eq $noteH)
    $allTop = $true
    foreach ($pin in $pins) {
      if (-not (Is-Topmost $pin)) { $allTop = $false }
      $c = Center $pin
      $hit = [P]::WindowFromPoint((New-Object P+POINT -Property @{X = $c[0]; Y = $c[1]}))
      Check "pin stays above the active application" ($hit -eq $pin) "pin=$(Rect-Text $pin) hit=0x$($hit.ToInt64().ToString('X'))"
    }
    Check "every pin keeps the topmost style" $allTop "count=$($pins.Count)"
    # Clicking one pin must not push the others behind the text editor.
    $c = Center $pins[0]
    [P]::SetCursorPos($c[0], $c[1]) | Out-Null
    Start-Sleep -Milliseconds 120
    [P]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [P]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    $stillTop = ($pins | Where-Object { -not (Is-Topmost $_) }).Count -eq 0
    Check "clicking a pin keeps every pin topmost" $stillTop
    Check "clicking a pin keeps the other application focused" ((Get-Foreground) -eq $noteH) "fg=$(Get-Foreground) expected=$noteH"
    "NOTEPAD=$($note.Id)"
  }
  "wheel" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 2) { Check "two pins exist" $false "count=$($pins.Count)"; break }
    $two = $pins | Select-Object -First 2
    $target = $two[0]
    $other = $two[1]
    $b0 = Get-Rect $target
    $o0 = Get-Rect $other
    $c = Center $target
    [P]::SetCursorPos($c[0], $c[1]) | Out-Null
    Start-Sleep -Milliseconds 300
    Send-Wheel 1
    Start-Sleep -Milliseconds 700
    $b1 = Get-Rect $target
    $o1 = Get-Rect $other
    $ratio = [math]::Round(($b1.Right - $b1.Left) / ($b0.Right - $b0.Left), 3)
    Check "the wheel zooms the pin under the pointer" ($ratio -eq 1.1) "ratio=$ratio"
    Check "the wheel leaves the other pin alone" (($o1.Right - $o1.Left) -eq ($o0.Right - $o0.Left) -and ($o1.Bottom - $o1.Top) -eq ($o0.Bottom - $o0.Top)) "other=$(($o1.Right - $o1.Left))x$(($o1.Bottom - $o1.Top)) before=$(($o0.Right - $o0.Left))x$(($o0.Bottom - $o0.Top))"
    $badges = @(Get-VisibleBadges)
    Check "a zoom percentage badge is shown" ($badges.Count -ge 1) "visible=$($badges.Count)"
    if ($badges.Count -ge 1) {
      $badge = $badges[0]
      $badgeRect = Get-Rect $badge
      $pinRect = Get-Rect $target
      Check "the badge is click-through and topmost" (((Ex-Style $badge) -band 0x00080020) -eq 0x00080020) "ex=0x$((Ex-Style $badge).ToString('X'))"
      Check "the badge sits inside the pin frame" ($badgeRect.Left -ge $pinRect.Left -and $badgeRect.Top -ge $pinRect.Top -and $badgeRect.Right -le $pinRect.Right -and $badgeRect.Bottom -le $pinRect.Bottom) "badge=$(Rect-Text $badge) pin=$(Rect-Text $target)"
      Check "the badge reports the applied percentage" ($badgeRect.Right -gt $badgeRect.Left -and $badgeRect.Bottom -gt $badgeRect.Top) "size=$($badgeRect.Right - $badgeRect.Left)x$($badgeRect.Bottom - $badgeRect.Top)"
    }
    Start-Sleep -Milliseconds 1400
    Check "the badge hides after the scroll stops" (@(Get-VisibleBadges).Count -eq 0)
    Send-Wheel -1
    Start-Sleep -Milliseconds 700
    $b2 = Get-Rect $target
    Check "wheeling back restores the previous size" ((($b2.Right - $b2.Left) -eq ($b0.Right - $b0.Left))) "now=$(($b2.Right - $b2.Left))x$(($b2.Bottom - $b2.Top)) before=$(($b0.Right - $b0.Left))x$(($b0.Bottom - $b0.Top))"
    $r = Get-Rect $target
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    $ax = 0.25; $ay = 0.75
    [P]::SetCursorPos([int]($r.Left + $ax * $w), [int]($r.Top + $ay * $h)) | Out-Null
    Start-Sleep -Milliseconds 300
    Send-Wheel 2
    Start-Sleep -Milliseconds 800
    $r2 = Get-Rect $target
    $aw = $r2.Right - $r2.Left; $ah = $r2.Bottom - $r2.Top
    $expectedLeft = [math]::Round($r.Left + $ax * ($w - $aw), 0)
    $expectedTop = [math]::Round($r.Top + $ay * ($h - $ah), 0)
    Check "zoom is anchored at the pointer" ([math]::Abs($r2.Left - $expectedLeft) -le 2 -and [math]::Abs($r2.Top - $expectedTop) -le 2) "actual=$($r2.Left),$($r2.Top) expected=$expectedLeft,$expectedTop size=${aw}x${ah}"
    Check "zoom keeps the image aspect ratio" ([math]::Abs(($aw / $ah) - ($w / $h)) -lt 0.02) "ratio=$([math]::Round($aw / $ah, 3)) expected=$([math]::Round($w / $h, 3))"
    Send-Wheel -2
    Start-Sleep -Milliseconds 800
  }
  "esc-hovered" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 2) { Check "two pins exist" $false "count=$($pins.Count)"; break }
    $fgBefore = Get-Foreground
    $target = $pins[0]
    $other = $pins[1]
    $c = Center $target
    [P]::SetCursorPos($c[0], $c[1]) | Out-Null
    Start-Sleep -Milliseconds 250
    Send-Key 0x1B
    Start-Sleep -Milliseconds 800
    $after = @(Get-Pins)
    Check "Escape closes the pin under the pointer" (($after -contains $target) -eq $false) "targetAlive=$($after -contains $target)"
    Check "Escape keeps the other pins" ($after -contains $other) "remaining=$($after.Count)"
    Check "Escape does not change the foreground window" ((Get-Foreground) -eq $fgBefore) "fg=$(Get-Foreground) expected=$fgBefore"
    # Escape over empty desktop must not close anything.
    $count = (Get-Pins).Count
    [P]::SetCursorPos(5, 5) | Out-Null
    Start-Sleep -Milliseconds 200
    Send-Key 0x1B
    Start-Sleep -Milliseconds 700
    Check "Escape away from pins closes nothing" ((Get-Pins).Count -eq $count) "before=$count after=$((Get-Pins).Count)"
  }
  "paste-text" {
    $before = @(Get-Pins)
    $assetsBefore = Assets-Count
    $webviewBefore = Webview-Count
    $fgBefore = Get-Foreground
    $text = "Kiri pin text " + [string][char]0x4E2D + [string][char]0x6587 + [string][char]0x6362 + [string][char]0x884C +
      [string][char]0x6D4B + [string][char]0x8BD5 + " - clipboard text becomes a bitmap card.`nSecond line with a long run: " +
      ("x" * 90)
    [System.Windows.Forms.Clipboard]::SetText($text)
    [P]::SetCursorPos(700, 420) | Out-Null
    Start-Sleep -Milliseconds 200
    Send-F3
    $fresh = @(Get-Pins | Where-Object { $before -notcontains $_ })
    Check "F3 pins clipboard text as a card" ($fresh.Count -eq 1) "new=$($fresh.Count)"
    Check "text pin does not write the library" ((Assets-Count) -eq $assetsBefore) "before=$assetsBefore after=$(Assets-Count)"
    Check "text pin does not create a WebView" ((Webview-Count) -eq $webviewBefore) "before=$webviewBefore after=$(Webview-Count)"
    Check "text pin takes no focus" ((Get-Foreground) -eq $fgBefore) "fg=$(Get-Foreground) expected=$fgBefore"
    if ($fresh.Count -eq 1) {
      $r = Get-Rect $fresh[0]
      $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
      Check "text card is bounded and readable size" ($w -ge 120 -and $w -le 520 -and $h -ge 40 -and $h -le 1224) "size=${w}x${h}"
      "TEXT_PIN=$(Rect-Text $fresh[0])"
    }
  }
  "paste-files" {
    $before = @(Get-Pins)
    $assetsBefore = Assets-Count
    $dir = Join-Path $env:TEMP "kiri-pin-e2e"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $a = Join-Path $dir "pin-a.png"; $b = Join-Path $dir "pin-b.png"
    New-TestPng $a 240 160 30 140 60
    New-TestPng $b 200 200 120 40 160
    $files = New-Object System.Collections.Specialized.StringCollection
    [void]$files.Add($a); [void]$files.Add($b)
    [System.Windows.Forms.Clipboard]::SetFileDropList($files)
    [P]::SetCursorPos(1000, 400) | Out-Null
    Start-Sleep -Milliseconds 200
    Send-F3
    $fresh = @(Get-Pins | Where-Object { $before -notcontains $_ })
    Check "F3 pins two copied image files" ($fresh.Count -eq 2) "new=$($fresh.Count)"
    Check "file pins do not write the library" ((Assets-Count) -eq $assetsBefore) "before=$assetsBefore after=$(Assets-Count)"
    if ($fresh.Count -eq 2) {
      $sizes = ($fresh | ForEach-Object { (Rect-Text $_) -split ' ' | Select-Object -Last 1 }) -join " "
      Check "file pins keep their pixel sizes" ($sizes -match "240x160" -and $sizes -match "200x200") "sizes=$sizes"
    }
  }
  "exclude" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 1) { Check "a pin exists" $false; break }
    $pin = $pins | Sort-Object { $r = Get-Rect $_; ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } -Descending | Select-Object -First 1
    $affinity = 0
    [void][P]::GetWindowDisplayAffinity($pin, [ref]$affinity)
    Check "pin is excluded from screen capture" ($affinity -eq 0x11) "affinity=0x$($affinity.ToString('X'))"
    $r = Get-Rect $pin
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    function Sample-Region {
      $bitmap = New-Object System.Drawing.Bitmap $w, $h
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      $graphics.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
      $graphics.Dispose()
      $values = @()
      foreach ($point in @(@([int]($w / 2), [int]($h / 2)), @([int]($w / 4), [int]($h / 2)), @([int]($w * 3 / 4), [int]($h / 2)), @(10, 10))) {
        $pixel = $bitmap.GetPixel($point[0], $point[1])
        $values += "$($pixel.R),$($pixel.G),$($pixel.B)"
      }
      $bitmap.Dispose()
      return ($values -join " | ")
    }
    $whilePinned = Sample-Region
    [void][P]::SendMessage($pin, 0x0111, [IntPtr]1, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 900
    $afterClose = Sample-Region
    Check "the pin does not appear in a screen capture" ($whilePinned -eq $afterClose) "pinned=[$whilePinned] revealed=[$afterClose]"
  }
  "cap" {
    $pins = @(Get-Pins)
    $assetsBefore = Assets-Count
    $bitmap = New-Object System.Drawing.Bitmap 200, 150
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromArgb(255, 90, 90, 90))
    $graphics.Dispose()
    [System.Windows.Forms.Clipboard]::SetImage($bitmap)
    $bitmap.Dispose()
    [P]::SetCursorPos(600, 500) | Out-Null
    $attempts = 0
    while ((Get-Pins).Count -lt 16 -and $attempts -lt 24) {
      Send-F3
      $attempts++
    }
    $filled = (Get-Pins).Count
    Check "sixteen pins coexist" ($filled -eq 16) "pins=$filled attempts=$attempts"
    $wsFull = [math]::Round((Get-WorkingSet) / 1MB, 1)
    Send-F3
    Start-Sleep -Milliseconds 500
    Check "the seventeenth pin is refused" ((Get-Pins).Count -eq 16) "pins=$((Get-Pins).Count)"
    Check "the refused paste is not written to the library" ((Assets-Count) -eq $assetsBefore) "before=$assetsBefore after=$(Assets-Count)"
    "WS_16_PINS=${wsFull}MB"
    "PINS=$((Get-Pins).Count)"
  }
  "memory" {
    $wsFull = [math]::Round((Get-WorkingSet) / 1MB, 1)
    foreach ($pin in @(Get-Pins)) { [void][P]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero); Start-Sleep -Milliseconds 150 }
    Start-Sleep -Milliseconds 1200
    $wsEmpty = [math]::Round((Get-WorkingSet) / 1MB, 1)
    Check "closing every pin leaves no window" ((Get-Pins).Count -eq 0) "left=$((Get-Pins).Count)"
    Check "closing every pin returns memory" ($wsEmpty -lt $wsFull) "full=${wsFull}MB empty=${wsEmpty}MB released=$([math]::Round($wsFull - $wsEmpty, 1))MB"
  }
  "idle-cpu" {
    $proc = Get-Process kiri | Select-Object -First 1
    $t0 = $proc.TotalProcessorTime
    $bits = @(Get-Pins).Count
    Start-Sleep -Seconds 10
    $proc.Refresh()
    $t1 = $proc.TotalProcessorTime
    $cpuMs = [math]::Round(($t1 - $t0).TotalMilliseconds, 1)
    Check "idle CPU stays near zero with pins open" ($cpuMs -lt 400) "pins=$bits cpu_ms_over_10s=$cpuMs"
  }
  "cleanup" {
    foreach ($pin in @(Get-Pins)) { [void][P]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero); Start-Sleep -Milliseconds 120 }
    Start-Sleep -Milliseconds 600
    Check "cleanup closes every pin" ((Get-Pins).Count -eq 0) "left=$((Get-Pins).Count)"
    Get-Process notepad -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.MainWindowTitle -eq "Untitled - Notepad" -or $_.MainWindowTitle -eq ([string][char]0x65E0 + [string][char]0x6807 + [string][char]0x9898 + " - " + [string][char]0x8BB0 + [string][char]0x4E8B + [string][char]0x672C)) { $_.CloseMainWindow() | Out-Null }
    }
  }
  default { "UNKNOWN_STAGE $Stage" }
}
"CHECKS pass=$($script:Pass) fail=$($script:Fail)"

