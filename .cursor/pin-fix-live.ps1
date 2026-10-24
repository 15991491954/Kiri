# Live checks for the Windows pins with the shadow band: clipboard pin size,
# wheel zoom plus badge, drag, context menu, capture exclusion, and cost.
# Not part of the product.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class LivePin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
  public static string ClassOf(IntPtr h) {
    var name = new StringBuilder(256); GetClassName(h, name, name.Capacity); return name.ToString();
  }
  public static int Count(string cls) {
    int n = 0;
    EnumWindows((h, _) => { if (ClassOf(h) == cls) n++; return true; }, IntPtr.Zero);
    return n;
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
    $h = [LivePin]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Rect($h) { $r = New-Object LivePin+RECT; [void][LivePin]::GetWindowRect($h, [ref]$r); return $r }
function Size-Of($rect) { "$($rect.Right - $rect.Left)x$($rect.Bottom - $rect.Top)" }

try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 4

  # A 300x200 clipbaord image, then a clipboard pin.
  $bitmap = New-Object System.Drawing.Bitmap 300, 200
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(255, 250, 250, 250))
  $graphics.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 230, 120, 40))), 0, 0, 150, 200)
  $graphics.Dispose()
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)

  $paste = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
  if ($paste) { $null = $paste.WaitForExit(8000) }
  Start-Sleep -Milliseconds 1500
  $pins = Get-Pins
  Check "clipboard text/image pin opens" ($pins.Count -eq 1) "pins=$($pins.Count)"
  if ($pins.Count -eq 0) { throw "no pin" }
  $pin = $pins[0]
  $rect = Get-Rect $pin
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  $dpi = [LivePin]::GetDpiForWindow($pin)
  $scale = if ($dpi -gt 0) { $dpi / 96.0 } else { 1.0 }
  $expected = [int][math]::Round(16 * $scale) * 2
  Check "clipboard pin carries the shadow band" (
    [math]::Abs(($width - 300) - $expected) -le 2 -and [math]::Abs(($height - 200) - $expected) -le 2
  ) "pin=${width}x${height} image=300x200 dpi=$dpi band=$expected"

  # Wheel zoom keeps the pointer anchor and reports a percentage badge.
  $centreX = $rect.Left + [int]($width / 2)
  $centreY = $rect.Top + [int]($height / 2)
  [void][LivePin]::SetCursorPos($centreX, $centreY)
  Start-Sleep -Milliseconds 200
  $screen = [int]($centreX + ($centreY -shl 16))
  [void][LivePin]::SendMessage($pin, 0x020A, [IntPtr](120 -shl 16), [IntPtr]$screen)
  Start-Sleep -Milliseconds 500
  $zoomed = Get-Rect $pin
  $badges = [LivePin]::Count("KiriPinBadge")
  Check "wheel zoom enlarges the pin and shows the badge" (
    ($zoomed.Right - $zoomed.Left) -gt $width -and $badges -ge 1
  ) "before=${width} after=$((Size-Of $zoomed)) badges=$badges"
  [void][LivePin]::SendMessage($pin, 0x020A, [IntPtr](-120 -shl 16), [IntPtr]$screen)
  Start-Sleep -Milliseconds 500
  $restored = Get-Rect $pin
  Check "zooming back returns to the original size" (
    [math]::Abs(($restored.Right - $restored.Left) - $width) -le 2
  ) "size=$(Size-Of $restored)"

  # The pin itself must never appear in a screen capture.
  $grab = New-Object System.Drawing.Bitmap $width, $height
  $grabGraphics = [System.Drawing.Graphics]::FromImage($grab)
  $grabGraphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size $width, $height))
  $grabGraphics.Dispose()
  $probe = $grab.GetPixel([int]($width / 2), [int]($height / 2))
  $grab.Dispose()
  Check "the pin stays out of screen captures" (
    -not ($probe.R -gt 200 -and $probe.G -gt 90 -and $probe.G -lt 160 -and $probe.B -lt 90)
  ) "centre=$($probe.R),$($probe.G),$($probe.B)"

  # Drag moves the whole window (photo plus band) with the pointer.
  $before = Get-Rect $pin
  [void][LivePin]::SetCursorPos($centre[0], $centre[1])
  Start-Sleep -Milliseconds 150
  [LivePin]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  for ($step = 1; $step -le 10; $step++) {
    [void][LivePin]::SetCursorPos($centre[0] + $step * 6, $centre[1] + $step * 4)
    Start-Sleep -Milliseconds 20
  }
  [LivePin]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 400
  $after = Get-Rect $pin
  Check "dragging moves the pin and keeps its size" (
    ($after.Left - $before.Left) -ge 50 -and (Size-Of $after) -eq (Size-Of $before)
  ) "before=$($before.Left),$($before.Top) after=$($after.Left),$($after.Top)"

  # Cost of one idle clipboard pin.
  $process = Get-Process -Name kiri
  $cpuBefore = $process.TotalProcessorTime.TotalMilliseconds
  Start-Sleep -Seconds 5
  $process.Refresh()
  $idle = $process.TotalProcessorTime.TotalMilliseconds - $cpuBefore
  Check "an idle pin costs almost no CPU" ($idle -lt 250) (
    "pins=$((Get-Pins).Count) cpuMsOver5s=$([math]::Round($idle,1)) workingSetMb=$([math]::Round($process.WorkingSet64 / 1MB,1))")

  # Close through the native context-menu command and verify the badge goes too.
  [void][LivePin]::SendMessage($pin, 0x0111, [IntPtr]1, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 500
  Check "closing the last pin removes it and the badge" (
    (Get-Pins).Count -eq 0 -and ([LivePin]::Count("KiriPinBadge") -eq 0)
  ) "pins=$((Get-Pins).Count) badges=$([LivePin]::Count("KiriPinBadge"))"
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
