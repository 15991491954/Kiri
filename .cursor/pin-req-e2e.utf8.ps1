# Requirement-level end-to-end driver for native Windows pins.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -STA -File .cursor\pin-req-e2e.ps1 <stage>
# Every stage leaves the app in a usable state; "cleanup" closes all pins.
param([string]$Stage = "help")

$ErrorActionPreference = "Stop"
$script:Pass = 0
$script:Fail = 0
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class R {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr hwnd, out uint affinity);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr monitor, IntPtr info);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flags);

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
  public static string ClassOf(IntPtr hwnd) {
    if (hwnd == IntPtr.Zero) return "(none)";
    var name = new StringBuilder(256);
    GetClassName(hwnd, name, name.Capacity);
    return name.ToString();
  }
  public static void GuiCounts(uint pid, out uint gdi, out uint user) {
    var process = OpenProcess(0x0400, false, pid);
    gdi = GetGuiResources(process, 0);
    user = GetGuiResources(process, 1);
  }
  public static string Version() { return "R1"; }
}
"@

function Check([string]$name, [bool]$ok, [string]$detail = "") {
  if ($ok) { $script:Pass++; "[PASS] $name $detail" } else { $script:Fail++; "[FAIL] $name $detail" }
}
function Get-Pins { @([R]::Windows("KiriPinWindow")) }
function Get-Badges { @([R]::Windows("KiriPinBadge")) }
function Get-Menus { @([R]::Windows("#32768") | Where-Object { [R]::IsWindowVisible($_) }) }
function Get-KiriPid { (Get-Process kiri -ErrorAction Stop | Select-Object -First 1).Id }
function Get-Rect([IntPtr]$hwnd) { $r = New-Object R+RECT; [void][R]::GetWindowRect($hwnd, [ref]$r); return $r }
function Rect-Text([IntPtr]$hwnd) { $r = Get-Rect $hwnd; return "$($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)" }
function Center([IntPtr]$hwnd) { $r = Get-Rect $hwnd; return @([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2)) }
function Ex-Style([IntPtr]$hwnd) { [R]::GetWindowLongPtr($hwnd, -20).ToInt64() }
function Style([IntPtr]$hwnd) { [R]::GetWindowLongPtr($hwnd, -16).ToInt64() }
function Mask([string]$hex) { [Convert]::ToInt64($hex, 16) }
function Is-Topmost([IntPtr]$hwnd) { ((Ex-Style $hwnd) -band 0x8) -ne 0 }
function Is-ToolWindow([IntPtr]$hwnd) { ((Ex-Style $hwnd) -band (Mask "00000080")) -ne 0 }
function Is-AppWindow([IntPtr]$hwnd) { ((Ex-Style $hwnd) -band (Mask "00040000")) -ne 0 }
function Send-Wheel([int]$notches) {
  $raw = [int64]$notches * 120
  if ($raw -lt 0) { $raw += 4294967296 }
  [R]::mouse_event(0x0800, 0, 0, [uint32]$raw, [UIntPtr]::Zero)
}
function Click([int]$x, [int]$y, [bool]$right = $false) {
  [R]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 140
  $down = if ($right) { 0x0008 } else { 0x0002 }
  $up = if ($right) { 0x0010 } else { 0x0004 }
  [R]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [R]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 250
}
function Drag-By([int]$x1, [int]$y1, [int]$dx, [int]$dy, [int]$steps = 6) {
  [R]::SetCursorPos($x1, $y1) | Out-Null
  Start-Sleep -Milliseconds 160
  [R]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 90
  for ($step = 1; $step -le $steps; $step++) {
    [R]::SetCursorPos($x1 + [int]($dx * $step / $steps), $y1 + [int]($dy * $step / $steps)) | Out-Null
    Start-Sleep -Milliseconds 30
  }
  Start-Sleep -Milliseconds 90
  [R]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 400
}
function Send-Key([byte]$vk) {
  [R]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [R]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
}
function Send-Hotkey([byte[]]$keys) {
  foreach ($key in $keys) { [R]::keybd_event($key, 0, 0, [UIntPtr]::Zero) }
  Start-Sleep -Milliseconds 70
  [byte[]]$reversed = $keys.Clone(); [array]::Reverse($reversed)
  foreach ($key in $reversed) { [R]::keybd_event($key, 0, 2, [UIntPtr]::Zero) }
}
function Set-ClipboardImage([int]$width, [int]$height, [int]$r, [int]$g, [int]$b) {
  $bitmap = New-Object System.Drawing.Bitmap $width, $height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(255, $r, $g, $b))
  $graphics.Dispose()
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
  $bitmap.Dispose()
}
function New-Pin([int]$cursorX, [int]$cursorY, [int]$width, [int]$height, [int]$r, [int]$g, [int]$b) {
  $before = @(Get-Pins)
  Set-ClipboardImage $width $height $r $g $b
  [R]::SetCursorPos($cursorX, $cursorY) | Out-Null
  Start-Sleep -Milliseconds 180
  Send-Key 0x72
  Start-Sleep -Milliseconds 1200
  $fresh = @(Get-Pins | Where-Object { $before -notcontains $_ })
  if ($fresh.Count -ne 1) { return $null }
  return $fresh[0]
}
function Sample-Center([IntPtr]$hwnd) {
  $r = Get-Rect $hwnd
  $x = [int](($r.Left + $r.Right) / 2); $y = [int](($r.Top + $r.Bottom) / 2)
  $bitmap = New-Object System.Drawing.Bitmap 1, 1
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size 1, 1))
  $graphics.Dispose()
  $pixel = $bitmap.GetPixel(0, 0)
  $bitmap.Dispose()
  return @($pixel.R, $pixel.G, $pixel.B, $x, $y)
}
function Assets {
  $path = Join-Path $env:APPDATA 'kiri\library.json'
  if (-not (Test-Path $path)) { return @() }
  return @(Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

switch ($Stage) {
  "probe" {
    $pins = @(Get-Pins)
    "PINS=$($pins.Count) BADGES=$((Get-Badges).Count) MENUS=$((Get-Menus).Count)"
    foreach ($pin in $pins) { "  PIN $(Rect-Text $pin) topmost=$(Is-Topmost $pin)" }
  }
  "esc-hold" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 2) { Check "two pins exist for the repeat test" $false "count=$($pins.Count)"; break }
    $target = $pins[0]; $other = $pins[1]
    $c = Center $target
    [R]::SetCursorPos($c[0], $c[1]) | Out-Null
    Start-Sleep -Milliseconds 250
    # A held key repeats keydown without a keyup; the hook must close one pin only.
    for ($repeat = 0; $repeat -lt 6; $repeat++) {
      [R]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 70
    }
    [R]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    $after = @(Get-Pins)
    Check "auto-repeated Escape closes exactly one pin" ($after.Count -eq ($pins.Count - 1)) "before=$($pins.Count) after=$($after.Count)"
    Check "auto-repeated Escape closes the pin under the pointer" (($after -contains $target) -eq $false)
    Check "auto-repeated Escape keeps the other pin" ($after -contains $other)
  }
  "menu-esc" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 1) { Check "a pin exists" $false; break }
    $target = $pins[0]
    $c = Center $target
    Click $c[0] $c[1] $true
    Start-Sleep -Milliseconds 400
    $menus = @(Get-Menus)
    Check "right click opens the context menu" ($menus.Count -eq 1) "menus=$($menus.Count)"
    Send-Key 0x1B
    Start-Sleep -Milliseconds 500
    Check "Escape dismisses the menu" (@(Get-Menus).Count -eq 0)
    Check "Escape on the menu leaves the pin open" ([R]::IsWindow($target) -and (@(Get-Pins) -contains $target))
    $c = Center $target
    [R]::SetCursorPos($c[0], $c[1]) | Out-Null
    Start-Sleep -Milliseconds 200
    Send-Key 0x1B
    Start-Sleep -Milliseconds 700
    Check "a second Escape closes the pin" (-not (@(Get-Pins) -contains $target)) "left=$((Get-Pins).Count)"
  }
  "menu-outside" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 1) { Check "a pin exists" $false; break }
    $target = $pins[0]
    $c = Center $target
    Click $c[0] $c[1] $true
    Start-Sleep -Milliseconds 400
    Check "right click opens the context menu" (@(Get-Menus).Count -eq 1)
    Click 5 5 $false
    Start-Sleep -Milliseconds 500
    Check "clicking outside dismisses the menu" (@(Get-Menus).Count -eq 0)
    Check "clicking outside leaves the pin open" (@(Get-Pins) -contains $target)
  }
  "bounds" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 1) { Check "a pin exists" $false; break }
    $pin = $pins[0]
    $c = Center $pin
    Drag-By $c[0] $c[1] -4000 -3000 5
    $r = Get-Rect $pin
    $screenW = [R]::GetSystemMetrics(0); $screenH = [R]::GetSystemMetrics(1)
    $visibleX = [math]::Min($r.Right, $screenW) - [math]::Max($r.Left, 0)
    $visibleY = [math]::Min($r.Bottom, $screenH) - [math]::Max($r.Top, 0)
    Check "a pin dragged far off screen leaves a strip to grab" ($visibleX -ge 40 -and $visibleY -ge 40) "rect=$(Rect-Text $pin) visible=${visibleX}x${visibleY}"
    Check "the pin is still in the topmost band after the drag" (Is-Topmost $pin)
    # Put it back on screen for later stages.
    $r = Get-Rect $pin
    Drag-By ([int](($r.Left + $r.Right) / 2)) ([int](($r.Top + $r.Bottom) / 2)) 700 400 5
  }
  "zoom-limits" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 1) { Check "a pin exists" $false; break }
    $pin = $pins[0]
    $start = Get-Rect $pin
    $c = Center $pin
    [R]::SetCursorPos($c[0], $c[1]) | Out-Null
    Start-Sleep -Milliseconds 250
    for ($step = 0; $step -lt 40; $step++) { Send-Wheel 1; Start-Sleep -Milliseconds 40 }
    Start-Sleep -Milliseconds 900
    $max = Get-Rect $pin
    $maxW = $max.Right - $max.Left; $maxH = $max.Bottom - $max.Top
    $pixels = [int64]$maxW * [int64]$maxH
    Check "runaway zoom stops at the 32 MP display budget" ($pixels -le 32000000) "size=${maxW}x${maxH} pixels=$pixels"
    Check "runaway zoom stops before the 8000 pixel edge" ($maxW -le 8000 -and $maxH -le 8000) "size=${maxW}x${maxH}"
    Check "the pin survives the zoom ceiling" ((@(Get-Pins) -contains $pin) -and [R]::IsWindow($pin))
    Check "zooming keeps the pin topmost" (Is-Topmost $pin)
    for ($step = 0; $step -lt 4; $step++) { Send-Wheel 1; Start-Sleep -Milliseconds 50 }
    Start-Sleep -Milliseconds 800
    $same = Get-Rect $pin
    Check "zooming past the ceiling does not move or resize the pin" (
      $same.Left -eq $max.Left -and $same.Top -eq $max.Top -and
      ($same.Right - $same.Left) -eq $maxW -and ($same.Bottom - $same.Top) -eq $maxH
    ) "before=$(Rect-Text $pin) then=$($same.Left),$($same.Top) $($maxW)x$($maxH)"
    $c = Center $pin
    [R]::SetCursorPos($c[0], $c[1]) | Out-Null
    Start-Sleep -Milliseconds 200
    for ($step = 0; $step -lt 70; $step++) { Send-Wheel -1; Start-Sleep -Milliseconds 35 }
    Start-Sleep -Milliseconds 900
    $small = Get-Rect $pin
    $smallW = $small.Right - $small.Left; $smallH = $small.Bottom - $small.Top
    Check "zooming out stops at the usable minimum" ($smallW -ge 80 -and $smallH -ge 60 -and $smallH -le 400) "size=${smallW}x${smallH}"
    Check "the pin survives the zoom floor" ((@(Get-Pins) -contains $pin) -and [R]::IsWindow($pin))
    # Return to a normal size for later stages.
    $c = Center $pin
    [R]::SetCursorPos($c[0], $c[1]) | Out-Null
    for ($step = 0; $step -lt 20; $step++) { Send-Wheel 1; Start-Sleep -Milliseconds 35 }
    Start-Sleep -Milliseconds 700
  }
  "exclude-color" {
    $pin = New-Pin 900 520 320 240 255 0 255
    if (-not $pin) { Check "a magenta pin opens" $false; break }
    $sample = Sample-Center $pin
    Check "the pin occupies the sampled point" (
      ([R]::WindowFromPoint((New-Object R+POINT -Property @{X = $sample[3]; Y = $sample[4]}))) -eq $pin
    )
    $magenta = ($sample[0] -ge 240 -and $sample[1] -le 40 -and $sample[2] -ge 240)
    Check "the pin is invisible to a desktop capture" (-not $magenta) "sampled=$($sample[0]),$($sample[1]),$($sample[2])"
    $affinity = 0
    [void][R]::GetWindowDisplayAffinity($pin, [ref]$affinity)
    Check "the pin reports WDA_EXCLUDEFROMCAPTURE" ($affinity -eq 0x11) "affinity=0x$($affinity.ToString('X'))"
    "MAGENTA_PIN=$(Rect-Text $pin)"
  }
  "kiri-capture" {
    $pins = @(Get-Pins)
    $magentaPin = $pins | Where-Object {
      $s = Sample-Center $_
      ($s[0] -ge 240 -and $s[1] -le 40 -and $s[2] -ge 240)
    } | Select-Object -First 1
    if (-not $magentaPin) {
      $magentaPin = New-Pin 900 520 320 240 255 0 255
    }
    if (-not $magentaPin) { Check "a magenta pin exists" $false; break }
    $assetsBefore = (Assets).Count
    $r = Get-Rect $magentaPin
    Send-Hotkey @(0x11, 0x10, 0x41)
    Start-Sleep -Milliseconds 2500
    $c = Center $magentaPin
    [R]::SetCursorPos($r.Left - 30, $r.Top - 30) | Out-Null
    Start-Sleep -Milliseconds 150
    [R]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    for ($step = 1; $step -le 8; $step++) {
      [R]::SetCursorPos(
        [int]($r.Left - 30 + ($r.Right - $r.Left + 60) * $step / 8),
        [int]($r.Top - 30 + ($r.Bottom - $r.Top + 60) * $step / 8)) | Out-Null
      Start-Sleep -Milliseconds 25
    }
    [R]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 900
    Send-Key 0x0D
    Start-Sleep -Milliseconds 3000
    $assets = Assets
    Check "the capture is saved to the library" ($assets.Count -eq ($assetsBefore + 1)) "before=$assetsBefore after=$($assets.Count)"
    $newest = $assets | Sort-Object { [int64]$_.createdAt } -Descending | Select-Object -First 1
    $path = Join-Path $env:APPDATA ("kiri\Assets\" + $newest.filename)
    Check "the saved capture exists on disk" (Test-Path $path) "path=$path"
    if (Test-Path $path) {
      $bitmap = New-Object System.Drawing.Bitmap $path
      $magentaCount = 0
      $stepX = [math]::Max(1, [int]($bitmap.Width / 60))
      $stepY = [math]::Max(1, [int]($bitmap.Height / 60))
      for ($y = 0; $y -lt $bitmap.Height; $y += $stepY) {
        for ($x = 0; $x -lt $bitmap.Width; $x += $stepX) {
          $pixel = $bitmap.GetPixel($x, $y)
          if ($pixel.R -ge 240 -and $pixel.G -le 40 -and $pixel.B -ge 240) { $magentaCount++ }
        }
      }
      $bitmap.Dispose()
      Check "the Kiri screenshot does not contain the pin" ($magentaCount -eq 0) "magenta_samples=$magentaCount size=$($newest.pixelWidth)x$($newest.pixelHeight)"
      "CAPTURE=$path"
      "CAPTURE_ID=$($newest.id)"
    }
  }
  "gdi-cycle" {
    $pidKiri = Get-KiriPid
    $gdi0 = 0; $user0 = 0
    [R]::GuiCounts([uint32]$pidKiri, [ref]$gdi0, [ref]$user0)
    # Close everything so the baseline is the empty state.
    foreach ($pin in @(Get-Pins)) {
      [void][R]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 900
    $gdiEmpty = 0; $userEmpty = 0
    [R]::GuiCounts([uint32]$pidKiri, [ref]$gdiEmpty, [ref]$userEmpty)
    $attempts = 0
    while ((Get-Pins).Count -lt 16 -and $attempts -lt 22) { Send-Key 0x72; Start-Sleep -Milliseconds 900; $attempts++ }
    $filled = (Get-Pins).Count
    $gdiFull = 0; $userFull = 0
    [R]::GuiCounts([uint32]$pidKiri, [ref]$gdiFull, [ref]$userFull)
    Check "sixteen pins coexist" ($filled -eq 16) "pins=$filled attempts=$attempts"
    $ws = [math]::Round((Get-Process kiri | Select-Object -First 1).WorkingSet64 / 1MB, 1)
    foreach ($pin in @(Get-Pins)) {
      [void][R]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 1200
    $gdiAfter = 0; $userAfter = 0
    [R]::GuiCounts([uint32]$pidKiri, [ref]$gdiAfter, [ref]$userAfter)
    Check "closing every pin leaves no pin window" ((Get-Pins).Count -eq 0) "left=$((Get-Pins).Count)"
    Check "no GDI object is leaked per pin" ($gdiAfter -le ($gdiEmpty + 8)) "empty=$gdiEmpty full=$gdiFull after=$gdiAfter"
    Check "no USER object is leaked per pin" ($userAfter -le ($userEmpty + 8)) "empty=$userEmpty full=$userFull after=$userAfter"
    "WS_16_PINS=${ws}MB GDI empty=$gdiEmpty full=$gdiFull after=$gdiAfter USER empty=$userEmpty full=$userFull after=$userAfter"
  }
  "idle-cpu" {
    $proc = Get-Process kiri | Select-Object -First 1
    $count = (Get-Pins).Count
    $t0 = $proc.TotalProcessorTime
    Start-Sleep -Seconds 8
    $proc.Refresh()
    $cpuMs = [math]::Round(($proc.TotalProcessorTime - $t0).TotalMilliseconds, 1)
    Check "idle CPU stays near zero with pins open" ($cpuMs -lt 320) "pins=$count cpu_ms_over_8s=$cpuMs"
  }
  "created" {
    $pins = @(Get-Pins)
    if ($pins.Count -lt 1) { Check "a pin exists" $false; break }
    $pin = $pins[0]
    Check "the pin is a borderless popup" (
      (((Style $pin) -band (Mask "80C00000")) -eq (Mask "80000000")) -and
      (((Style $pin) -band (Mask "00040000")) -eq 0)
    ) "style=0x$((Style $pin).ToString('X'))"
    Check "the pin is a tool window with no taskbar entry" (Is-ToolWindow $pin) "ex=0x$((Ex-Style $pin).ToString('X'))"
    Check "the pin is not an application window" (-not (Is-AppWindow $pin))
    Check "the pin is topmost" (Is-Topmost $pin)
  }
  "cleanup" {
    foreach ($pin in @(Get-Pins)) {
      [void][R]::SendMessage($pin, 0x0111, [IntPtr]2, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 800
    Check "cleanup closes every pin" ((Get-Pins).Count -eq 0) "left=$((Get-Pins).Count)"
    Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -ne "" } | ForEach-Object { $_.CloseMainWindow() | Out-Null }
  }
  default { "UNKNOWN_STAGE $Stage" }
}
"CHECKS pass=$($script:Pass) fail=$($script:Fail)"

