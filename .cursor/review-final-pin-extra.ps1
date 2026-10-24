# Review-pass extras: topmost toggle semantics and a 4K clipboard pin.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class X {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
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

  public static List<IntPtr> Pins() {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, _) => {
      var name = new StringBuilder(256);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == "KiriPinWindow" && IsWindowVisible(hwnd)) found.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@

$script:Pass = 0; $script:Fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
  if ($ok) { $script:Pass++; "[PASS] $name $detail" } else { $script:Fail++; "[FAIL] $name $detail" }
}
function Ex([IntPtr]$h) { [X]::GetWindowLongPtr($h, -20).ToInt64() }
function Top([IntPtr]$h) { ((Ex $h) -band 0x8) -ne 0 }
function Rect([IntPtr]$h) { $r = New-Object X+RECT; [void][X]::GetWindowRect($h, [ref]$r); return $r }
function Centre([IntPtr]$h) { $r = Rect $h; return @([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2)) }
function Send-F3 { [X]::keybd_event(0x72, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [X]::keybd_event(0x72, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 1600 }
function Set-Image([int]$w, [int]$h, [int]$r, [int]$g, [int]$b) {
  $bitmap = New-Object System.Drawing.Bitmap $w, $h
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::FromArgb(255, $r, $g, $b))
  $graphics.Dispose()
  [System.Windows.Forms.Clipboard]::SetImage($bitmap)
  $bitmap.Dispose()
}

# --- topmost toggle -------------------------------------------------------
Set-Image 360 240 30 120 60
[X]::SetCursorPos(500, 420) | Out-Null
Send-F3
$pins = @([X]::Pins())
Check "image pin exists for the toggle test" ($pins.Count -ge 1) "count=$($pins.Count)"
if ($pins.Count -lt 1) { "CHECKS pass=$($script:Pass) fail=$($script:Fail)"; exit 1 }
$pin = $pins[-1]
Check "a new pin starts topmost" (Top $pin)
[void][X]::SendMessage($pin, 0x0111, [IntPtr]3, [IntPtr]::Zero)
Start-Sleep -Milliseconds 600
Check "Keep on Top unchecks and drops the topmost band" (-not (Top $pin)) "ex=0x$((Ex $pin).ToString('X'))"
$note = Start-Process notepad -PassThru
Start-Sleep -Milliseconds 1200
$note.Refresh()
$noteH = $note.MainWindowHandle
$c = Centre $pin
[X]::SetWindowPos($noteH, [IntPtr]::Zero, $c[0] - 200, $c[1] - 150, 500, 400, 0x0040) | Out-Null
[void][X]::SetForegroundWindow($noteH)
Start-Sleep -Milliseconds 700
$hit = [X]::GetAncestor([X]::WindowFromPoint((New-Object X+POINT -Property @{X = $c[0]; Y = $c[1]})), 2)
Check "an unpinned pin may be covered by the active window" ($hit -ne $pin) "hit=0x$($hit.ToInt64().ToString('X')) pin=0x$($pin.ToInt64().ToString('X'))"
[void][X]::SendMessage($pin, 0x0111, [IntPtr]3, [IntPtr]::Zero)
Start-Sleep -Milliseconds 600
Check "Keep on Top re-checks and restores the band" (Top $pin)
[X]::SetForegroundWindow($noteH) | Out-Null
Start-Sleep -Milliseconds 600
$hit = [X]::GetAncestor([X]::WindowFromPoint((New-Object X+POINT -Property @{X = $c[0]; Y = $c[1]})), 2)
Check "a re-pinned pin is above the active window again" ($hit -eq $pin) "hit=0x$($hit.ToInt64().ToString('X')) pin=0x$($pin.ToInt64().ToString('X'))"
$note.CloseMainWindow() | Out-Null
Start-Sleep -Milliseconds 400

# --- 4K clipboard pin -----------------------------------------------------
foreach ($p in @([X]::Pins())) { [void][X]::SendMessage($p, 0x0111, [IntPtr]1, [IntPtr]::Zero); Start-Sleep -Milliseconds 120 }
Start-Sleep -Milliseconds 500
$before = @([X]::Pins())
Set-Image 3840 2160 180 60 60
[X]::SetCursorPos(960, 540) | Out-Null
Send-F3
$after = @([X]::Pins())
$fresh = @($after | Where-Object { $before -notcontains $_ })
Check "a 4K clipboard image opens one pin" ($fresh.Count -eq 1) "before=$($before.Count) after=$($after.Count)"
if ($fresh.Count -ne 1) { "CHECKS pass=$($script:Pass) fail=$($script:Fail)"; exit 1 }
$big = $fresh[0]
$b = Rect $big
$bw = $b.Right - $b.Left; $bh = $b.Bottom - $b.Top
Check "a 4K pin opens at 80% of the work area or less" ($bw -le 1728 -and $bh -le 1037) "size=${bw}x${bh}"
Check "a 4K pin keeps the 16:9 aspect" ([math]::Abs(($bw / $bh) - (16 / 9)) -lt 0.02) "ratio=$([math]::Round($bw / $bh, 3))"
$c = Centre $big
[X]::SetCursorPos($c[0], $c[1]) | Out-Null
Start-Sleep -Milliseconds 250
$start = Get-Date
for ($i = 0; $i -lt 12; $i++) {
  [X]::mouse_event(0x0800, 0, 0, [uint32]120, [UIntPtr]::Zero)
  $expected = [math]::Round(($i + 1) * 100 / 12)
  $deadline = (Get-Date).AddMilliseconds(900)
  do {
    Start-Sleep -Milliseconds 40
    $now = Rect $big
  } while (((($now.Right - $now.Left) - $bw) / $bw * 100) -lt $expected -and (Get-Date) -lt $deadline)
}
$elapsed = ((Get-Date) - $start).TotalMilliseconds
$r = Rect $big
$aw = $r.Right - $r.Left; $ah = $r.Bottom - $r.Top
Check "twelve wheel notches on a 4K pin stay responsive" ($elapsed -lt 4000) "elapsed_ms=$([math]::Round($elapsed))"
Check "a 4K pin zooms toward 1:1 and keeps its aspect" ([math]::Abs(($aw / $ah) - (16 / 9)) -lt 0.02 -and $aw -gt $bw) "size=${aw}x${ah}"
Check "a zoomed 4K pin stays topmost and visible" ((Top $big) -and [X]::IsWindowVisible($big))
foreach ($p in @([X]::Pins())) { [void][X]::SendMessage($p, 0x0111, [IntPtr]2, [IntPtr]::Zero); Start-Sleep -Milliseconds 120 }
Start-Sleep -Milliseconds 600
Check "the extras clean up every pin" (@([X]::Pins()).Count -eq 0) "left=$(@([X]::Pins()).Count)"
"CHECKS pass=$($script:Pass) fail=$($script:Fail)"
