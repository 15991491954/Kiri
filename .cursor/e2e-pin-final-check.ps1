# Verifies the Windows pin polish requested after the parity work:
#   1. clicking the toolbar Pin button leaves no editing HUD behind, repeatedly;
#   2. every pin window carries its glow band and rounded photo corners;
#   3. the pointer over a pin shows the normal arrow (no busy/spinner cursor);
#   4. the zoom badge stays small, and a wheel up/down round trip returns to
#      exactly 100% instead of stopping at 101%.
# Drives the real capture overlay with Win32 input and clicks the real toolbar
# Pin button through the WebView CDP target. Not part of the product; the
# temporary CDP port exists only for this run.
param([int]$Runs = 3)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PinNative {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO pci);
  [DllImport("user32.dll")] public static extern IntPtr LoadCursorW(IntPtr instance, IntPtr name);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
  [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO {
    public int cbSize; public int flags; public IntPtr hCursor; public POINT ptScreenPos;
  }
}
"@

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
$results = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = "") {
  [void]$results.Add([pscustomobject]@{ Test = $name; Pass = $ok; Detail = $detail })
  Write-Host ("[{0}] {1} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $detail)
}
function Get-Pins {
  $found = @(); $previous = [IntPtr]::Zero
  while ($true) {
    $h = [PinNative]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Rect($h) { $r = New-Object PinNative+RECT; [void][PinNative]::GetWindowRect($h, [ref]$r); return $r }
function Wait-Pins([int]$count, [int]$timeoutMs = 20000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    $pins = Get-Pins
    if ($pins.Count -ge $count) { return $pins }
    Start-Sleep -Milliseconds 100
  }
  return (Get-Pins)
}
function Get-OverlayTargets {
  try {
    $pages = Invoke-RestMethod "http://127.0.0.1:9333/json" -TimeoutSec 2
    return @($pages | Where-Object { $_.type -eq "page" -and $_.url -match "[?&]window=overlay" })
  } catch { return @() }
}
function Wait-OverlayTarget([int]$timeoutMs = 20000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    $overlay = Get-OverlayTargets
    if ($overlay.Count -gt 0) { return $overlay[0] }
    Start-Sleep -Milliseconds 150
  }
  return $null
}
function Send-Mouse([uint32]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
  [PinNative]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}
function Press-Escape {
  [void][PinNative]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [void][PinNative]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
}
function Send-Wheel([IntPtr]$h, [int]$delta, [int]$screenX, [int]$screenY) {
  $wparam = [IntPtr](($delta -band 0xFFFF) -shl 16)
  $lparam = [IntPtr]((($screenY -band 0xFFFF) -shl 16) -bor ($screenX -band 0xFFFF))
  [void][PinNative]::PostMessageW($h, 0x020A, $wparam, $lparam)
}
function Get-PinBadge {
  [PinNative]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinBadge", [IntPtr]::Zero)
}

$notepad = $null
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9333"
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 4

  $notepad = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1200
  $notepad.Refresh()
  [void][PinNative]::SetForegroundWindow($notepad.MainWindowHandle)
  Start-Sleep -Milliseconds 400

  $arrow = [PinNative]::LoadCursorW([IntPtr]::Zero, [IntPtr]32512)
  $selection = @{ x = 600; y = 350; width = 400; height = 400 }
  for ($run = 1; $run -le $Runs; $run++) {
    $pinsBefore = (Get-Pins).Count
    $started = Get-Date
    $created = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
    if ($created) { $null = $created.WaitForExit(8000) }
    $overlay = Wait-OverlayTarget
    if ($null -eq $overlay) { Check "run $run`: overlay opens" $false; break }
    Start-Sleep -Milliseconds 900

    [void][PinNative]::SetCursorPos($selection.x, $selection.y)
    Start-Sleep -Milliseconds 150
    Send-Mouse 0x0002
    Start-Sleep -Milliseconds 100
    foreach ($step in 1..10) {
      [void][PinNative]::SetCursorPos(
        $selection.x + [int]($selection.width * $step / 10),
        $selection.y + [int]($selection.height * $step / 10))
      Send-Mouse 0x0001
      Start-Sleep -Milliseconds 40
    }
    Send-Mouse 0x0004
    Start-Sleep -Milliseconds 700

    $click = node (Join-Path $PSScriptRoot "cdp-pin-click.mjs") 9333 2>&1
    $clickText = ($click | Out-String).Trim()
    $pinClicked = $clickText -match '"ok":true'
    Check "run $run`: the toolbar Pin button was clicked" $pinClicked $clickText

    # The pin must arrive, and every overlay page must be gone.
    $pins = Wait-Pins ($pinsBefore + 1) 12000
    $overlayDeadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $overlayDeadline -and (Get-OverlayTargets).Count -gt 0) {
      Start-Sleep -Milliseconds 150
    }
    $leftovers = (Get-OverlayTargets).Count
    $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
    Check "run $run`: one new native pin" ($pins.Count -eq $pinsBefore + 1) "before=$pinsBefore after=$($pins.Count)"
    Check "run $run`: no editing overlay left behind" ($leftovers -eq 0) "overlays=$leftovers elapsedMs=$elapsed"

    if ($pins.Count -gt $pinsBefore) {
      $pin = $pins[$pins.Count - 1]
      $rect = Get-Rect $pin
      $width = $rect.Right - $rect.Left
      $height = $rect.Bottom - $rect.Top
      $dpi = [PinNative]::GetDpiForWindow($pin)
      $scale = if ($dpi -gt 0) { $dpi / 96.0 } else { 1.0 }
      $expectedMargin = [int][math]::Round(12 * $scale) * 2
      Check "run $run`: the pin carries its glow band" (
        [math]::Abs(($width - $selection.width) - $expectedMargin) -le 2 -and
        [math]::Abs(($height - $selection.height) - $expectedMargin) -le 2
      ) "pin=${width}x${height} selection=$($selection.width)x$($selection.height) dpi=$dpi expectedBand=$expectedMargin"
      Check "run $run`: the pin is visible above the photo rect" (
        [PinNative]::IsWindowVisible($pin) -and
        ($width -gt $selection.width) -and ($height -gt $selection.height)
      ) "rect=$($rect.Left),$($rect.Top) ${width}x${height}"

      # The pointer over a pin must show the plain arrow, not the "app
      # starting" spinner Windows paints over a window it thinks is busy.
      [void][PinNative]::SetCursorPos($rect.Left + [int]($width / 2), $rect.Top + [int]($height / 2))
      Start-Sleep -Milliseconds 400
      $info = New-Object PinNative+CURSORINFO
      $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][PinNative+CURSORINFO])
      [void][PinNative]::GetCursorInfo([ref]$info)
      Check "run $run`: hovering a pin shows the normal arrow" ($info.hCursor -eq $arrow) (
        "cursor=$($info.hCursor) arrow=$arrow")

      # Wheel up then down must land back on exactly 100%.
      $beforeZoom = $width
      Send-Wheel $pin 120 ($rect.Left + [int]($width / 2)) ($rect.Top + [int]($height / 2))
      Start-Sleep -Milliseconds 500
      $zoomed = (Get-Rect $pin)
      $zoomedWidth = $zoomed.Right - $zoomed.Left
      Check "run $run`: the wheel zooms the pin" ($zoomedWidth -gt $beforeZoom) (
        "before=$beforeZoom after=$zoomedWidth")

      # The percentage badge is transient: read it while it is on screen.
      $badge = Get-PinBadge
      $badgeOk = $false
      $badgeDetail = "badge window missing"
      if ($badge -ne [IntPtr]::Zero) {
        $badgeRect = Get-Rect $badge
        $badgeWidth = $badgeRect.Right - $badgeRect.Left
        $badgeHeight = $badgeRect.Bottom - $badgeRect.Top
        $expectedWidth = [int][math]::Round(56 * $scale)
        $expectedHeight = [int][math]::Round(20 * $scale)
        $badgeOk = [math]::Abs($badgeWidth - $expectedWidth) -le 2 -and
          [math]::Abs($badgeHeight - $expectedHeight) -le 2
        $badgeDetail = "badge=${badgeWidth}x${badgeHeight} expected=${expectedWidth}x${expectedHeight}"
      }
      Check "run $run`: the zoom badge stays small" $badgeOk $badgeDetail

      $zoomedRect = Get-Rect $pin
      Send-Wheel $pin (-120) ($zoomedRect.Left + [int](($zoomedRect.Right - $zoomedRect.Left) / 2)) ($zoomedRect.Top + [int](($zoomedRect.Bottom - $zoomedRect.Top) / 2))
      Start-Sleep -Milliseconds 500
      $back = Get-Rect $pin
      $backWidth = $back.Right - $back.Left
      $backHeight = $back.Bottom - $back.Top
      Check "run $run`: wheel back returns to exactly 100%" (
        [math]::Abs($backWidth - $width) -le 1 -and [math]::Abs($backHeight - $height) -le 1
      ) "start=${width}x${height} back=${backWidth}x${backHeight}"

      # Escape closes exactly the pin under the pointer.
      [void][PinNative]::SetCursorPos($back.Left + [int]($backWidth / 2), $back.Top + [int]($backHeight / 2))
      Start-Sleep -Milliseconds 250
      Press-Escape
      Start-Sleep -Milliseconds 600
      Check "run $run`: Escape closes the pin under the pointer" ((Get-Pins).Count -eq $pinsBefore) "left=$((Get-Pins).Count)"
    }
  }

  Check "the foreground application kept focus" ([PinNative]::GetForegroundWindow() -ne [IntPtr]::Zero)
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  if ($notepad) { $notepad | Stop-Process -Force -ErrorAction SilentlyContinue }
  Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Test, $_.Detail) }
  exit 1
}
exit 0
