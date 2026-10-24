# End-to-end stress: pin cap, burst zoom bounds, and close-all stability.
# Runs the built app and drives real Win32 input. Not part of the product.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PinStress {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
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
    $h = [PinStress]::FindWindowEx([IntPtr]::Zero, $previous, "KiriPinWindow", [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { break }
    $found += $h; $previous = $h
  }
  return $found
}
function Get-Rect($h) { $r = New-Object PinStress+RECT; [void][PinStress]::GetWindowRect($h, [ref]$r); return $r }
function Get-ExStyle($h) { return ([PinStress]::GetWindowLongPtr($h, -20)).ToInt64() }
function Send-Mouse([uint32]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
  [PinStress]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}
function Send-Escape {
  [PinStress]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [PinStress]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
}
function Invoke-PastePin {
  $process = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
  $null = $process.WaitForExit(15000)
  Start-Sleep -Milliseconds 120
}
function Set-ClipboardImage([int]$width, [int]$height) {
  for ($attempt = 1; $attempt -le 8; $attempt++) {
    try {
      $bitmap = New-Object System.Drawing.Bitmap($width, $height)
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      $graphics.Clear([System.Drawing.Color]::FromArgb(20, 100, 200))
      $graphics.Dispose()
      [System.Windows.Forms.Clipboard]::SetImage($bitmap)
      $bitmap.Dispose()
      Start-Sleep -Milliseconds 150
      return
    } catch {
      if ($attempt -eq 8) { throw }
      Start-Sleep -Milliseconds (120 * $attempt)
    }
  }
}

try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 5
  $process = Get-Process kiri -ErrorAction SilentlyContinue | Select-Object -First 1
  $startMemory = [math]::Round($process.PrivateMemorySize64 / 1MB, 1)

  # --- 1. the cap holds and the app keeps working -------------------------
  Set-ClipboardImage 320 240
  [void][PinStress]::SetCursorPos(1200, 700)
  for ($index = 0; $index -lt 18; $index++) {
    Invoke-PastePin
  }
  Start-Sleep -Milliseconds 800
  $pins = Get-Pins
  Check "eighteen pastes open exactly the sixteen-pin cap" ($pins.Count -eq 16) "count=$($pins.Count)"
  $process.Refresh()
  Check "the app is still running after cap refusals" (-not $process.HasExited)
  $topmost = @($pins | Where-Object { ((Get-ExStyle $_) -band 0x8) -ne 0 }).Count
  Check "all sixteen pins stay topmost" ($topmost -eq $pins.Count) "topmost=$topmost/$($pins.Count)"
  $memory = [math]::Round($process.PrivateMemorySize64 / 1MB, 1)
  Check "sixteen small pins stay inside the byte budget" (($memory - $startMemory) -lt 120) "grew ${startMemory}MB -> ${memory}MB"

  # --- 2. a wheel burst stays bounded and keeps the aspect ---------------
  # Resolve the pin under the pointer the way the product does: overlapping
  # cascades mean the lowest handle is not necessarily the visible one.
  [void][PinStress]::SetCursorPos(1200, 700)
  Start-Sleep -Milliseconds 250
  $pin = [PinStress]::WindowFromPoint((New-Object PinStress+POINT(1200, 700)))
  $rect = Get-Rect $pin
  $startWidth = $rect.Right - $rect.Left
  for ($step = 0; $step -lt 30; $step++) {
    Send-Mouse 0x0800 0 0 120
    Start-Sleep -Milliseconds 25
  }
  Start-Sleep -Milliseconds 1200
  $zoomed = Get-Rect $pin
  $width = $zoomed.Right - $zoomed.Left
  $height = $zoomed.Bottom - $zoomed.Top
  Check "the burst really zoomed the hovered pin" ($width -gt $startWidth) "width $startWidth -> $width"
  Check "a thirty-notch burst stays under the 8000px edge" ($width -le 8000 -and $height -le 8000) "size=${width}x${height}"
  Check "a burst keeps the image aspect ratio" ([math]::Abs(($width / $height) - 1.3333) -lt 0.02) "ratio=$([math]::Round($width / $height,4))"
  $process.Refresh()
  Check "the app survives a burst zoom" (-not $process.HasExited)

  [uint32]$wheelDown = 4294967176
  for ($step = 0; $step -lt 30; $step++) {
    Send-Mouse 0x0800 0 0 $wheelDown
    Start-Sleep -Milliseconds 25
  }
  Start-Sleep -Milliseconds 1200
  $restored = Get-Rect $pin
  Check "thirty notches down restore the original size" ([math]::Abs(($restored.Right - $restored.Left) - $startWidth) -le 4) "width=$($restored.Right - $restored.Left) expected=$startWidth"

  # --- 3. Escape closes the pin under the pointer, one press at a time ---
  $before = (Get-Pins).Count
  [void][PinStress]::SetCursorPos(1200, 700)
  Start-Sleep -Milliseconds 250
  Check "the pointer resolves to a pin before Escape" (
    ((Get-Pins) -contains [PinStress]::WindowFromPoint((New-Object PinStress+POINT(1200, 700))))
  )
  Send-Escape
  Start-Sleep -Milliseconds 500
  $after = (Get-Pins).Count
  Check "Escape closes exactly one of sixteen pins" ($after -eq $before - 1) "before=$before after=$after"

  # --- 4. closing every pin leaves the process alive and idle ------------
  # The cascade keeps (1200,700) inside every pin, so each press closes the
  # topmost one under the same pointer.
  for ($press = 0; $press -lt ($after + 3); $press++) {
    if ((Get-Pins).Count -eq 0) { break }
    [void][PinStress]::SetCursorPos(1200, 700)
    Start-Sleep -Milliseconds 60
    Send-Escape
    Start-Sleep -Milliseconds 120
  }
  Start-Sleep -Milliseconds 500
  Check "Escape cycles the remaining pins down to zero" ((Get-Pins).Count -eq 0) "remaining=$((Get-Pins).Count)"
  $process.Refresh()
  Check "the app stays alive with no pins left" (-not $process.HasExited)
  Start-Sleep -Milliseconds 300
  $idleMemory = [math]::Round($process.PrivateMemorySize64 / 1MB, 1)
  Check "closing pins releases their memory" (($idleMemory - $startMemory) -lt 40) "idle=${idleMemory}MB start=${startMemory}MB"
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 300
  $log = Join-Path $env:LOCALAPPDATA "io.yuxino.kiri\logs\kiri.log"
  if (Test-Path $log) {
    Write-Host "`n--- pin log lines ---"
    Select-String -Path $log -Pattern "\[pin\]" | Select-Object -Last 12 | ForEach-Object { $_.Line }
  }
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Test, $_.Detail) }
  exit 1
}
exit 0
