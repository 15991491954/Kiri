# Extended end-to-end checks for native pinned images (review pass).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -STA -File .cursor\e2e-pin-review.ps1 <stage>
param([string]$Stage = "focus")

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
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

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

  public static string Describe(IntPtr hwnd) {
    RECT r; GetWindowRect(hwnd, out r);
    uint pid; GetWindowThreadProcessId(hwnd, out pid);
    long style = (long)GetWindowLongPtr(hwnd, -20);
    long plain = (long)GetWindowLongPtr(hwnd, -16);
    return string.Format("hwnd=0x{0:X} pid={1} rect={2},{3} {4}x{5} visible={6} ex=0x{7:X} style=0x{8:X} topmost={9} layered={10} toolwindow={11} noactivate={12} caption={13}",
      hwnd.ToInt64(), pid, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top,
      IsWindowVisible(hwnd), style, plain,
      (style & 0x8) != 0, (style & 0x80000) != 0, (style & 0x80) != 0, (style & 0x8000000) != 0,
      (plain & 0x00C00000) != 0);
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

function Move-Cursor([IntPtr]$hwnd) {
  $rect = Get-Rect $hwnd
  $x = [int](($rect.Left + $rect.Right) / 2)
  $y = [int](($rect.Top + $rect.Bottom) / 2)
  [W]::SetCursorPos($x, $y) | Out-Null
  return @($x, $y)
}

switch ($Stage) {
  "focus" {
    # A pin click must not take focus from the application the user is in.
    $notepad = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1500
    $notepad.Refresh()
    $note = $notepad.MainWindowHandle
    [W]::SetForegroundWindow($note) | Out-Null
    Start-Sleep -Milliseconds 400
    $pin = (Get-Pins)[0]
    Move-Cursor $pin | Out-Null
    Start-Sleep -Milliseconds 200
    $before = [W]::GetForegroundWindow()
    "BEFORE fg=0x$($before.ToInt64().ToString('X')) class=$([W]::ClassOf($before)) note=0x$($note.ToInt64().ToString('X'))"
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    foreach ($delay in @(60, 200, 600)) {
      Start-Sleep -Milliseconds $delay
      $fg = [W]::GetForegroundWindow()
      "AFTER+$delay fg=0x$($fg.ToInt64().ToString('X')) class=$([W]::ClassOf($fg)) stillNotepad=$($fg -eq $note)"
    }
    "PINS=$((Get-Pins).Count)"
    Stop-Process -Id $notepad.Id -Force
  }
  "focuscheck" {
    # Control: does the simulated click itself clear the foreground?
    $notepad = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1500
    $notepad.Refresh()
    $note = $notepad.MainWindowHandle
    [W]::SetForegroundWindow($note) | Out-Null
    Start-Sleep -Milliseconds 400
    "CONTROL_BEFORE fg=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X')) class=$([W]::ClassOf([W]::GetForegroundWindow()))"
    [W]::SetCursorPos(80, 500) | Out-Null
    Start-Sleep -Milliseconds 150
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    "CONTROL_AFTER fg=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X')) class=$([W]::ClassOf([W]::GetForegroundWindow()))"
    [W]::SetForegroundWindow($note) | Out-Null
    Start-Sleep -Milliseconds 400
    $pin = (Get-Pins)[0]
    Move-Cursor $pin | Out-Null
    Start-Sleep -Milliseconds 200
    "PIN_BEFORE fg=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X')) class=$([W]::ClassOf([W]::GetForegroundWindow()))"
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    "PIN_AFTER fg=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X')) class=$([W]::ClassOf([W]::GetForegroundWindow()))"
    Stop-Process -Id $notepad.Id -Force
  }
  "focussteps" {
    $notepad = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1500
    $notepad.Refresh()
    $note = $notepad.MainWindowHandle
    [W]::SetForegroundWindow($note) | Out-Null
    Start-Sleep -Milliseconds 400
    $pin = (Get-Pins)[0]
    Move-Cursor $pin | Out-Null
    Start-Sleep -Milliseconds 200
    "STEP hover fg=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X'))"
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    "STEP down fg=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X'))"
    Start-Sleep -Milliseconds 120
    "STEP down+140 fg=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X'))"
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    "STEP up fg=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X'))"
    Start-Sleep -Milliseconds 400
    "STEP up+430 fg=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X'))"
    [W]::SetForegroundWindow($note) | Out-Null
    Start-Sleep -Milliseconds 300
    "STEP reacquire fg=0x$(([W]::GetForegroundWindow()).ToInt64().ToString('X')) note=0x$($note.ToInt64().ToString('X'))"
    Stop-Process -Id $notepad.Id -Force
  }
  "menu" {
    # Opening the native context menu and pressing Escape must dismiss the
    # menu, not close the pin underneath it.
    $pin = (Get-Pins)[0]
    $before = (Get-Pins).Count
    $coords = Move-Cursor $pin
    Start-Sleep -Milliseconds 150
    [W]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [W]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
    Start-Sleep -Milliseconds 600
    $after = (Get-Pins).Count
    "PINS_BEFORE=$before PINS_AFTER=$after"
    # Dismiss a menu left open so later stages start from a clean desktop.
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
    Start-Sleep -Milliseconds 300
  }
  "unpin" {
    # An explicitly unpinned pin must stay out of the band on its own, and a
    # later drag must not silently put it back on top.
    $pin = (Get-Pins)[0]
    [void][W]::SendMessage($pin, 0x0111, [IntPtr]3, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    "AFTER_UNPIN $([W]::Describe($pin))"
    $coords = Move-Cursor $pin
    Start-Sleep -Milliseconds 150
    [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    for ($step = 1; $step -le 10; $step++) {
      [W]::SetCursorPos($coords[0] - $step * 4, $coords[1] + $step * 4) | Out-Null
      Start-Sleep -Milliseconds 15
    }
    [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    "AFTER_DRAG $([W]::Describe($pin))"
    [void][W]::SendMessage($pin, 0x0111, [IntPtr]3, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    "RESTORED $([W]::Describe($pin))"
  }
  "badge" {
    $pin = (Get-Pins)[0]
    $coords = Move-Cursor $pin
    Start-Sleep -Milliseconds 150
    $screen = [int]($coords[0] + ($coords[1] -shl 16))
    [void][W]::SendMessage($pin, 0x020A, [IntPtr](120 -shl 16), [IntPtr]$screen)
    Start-Sleep -Milliseconds 400
    foreach ($badge in Get-Badges) { "SHOWN $([W]::Describe($badge))" }
    Start-Sleep -Milliseconds 1400
    foreach ($badge in Get-Badges) { "AFTER_TIMEOUT $([W]::Describe($badge))" }
    [void][W]::SendMessage($pin, 0x020A, [IntPtr](-120 -shl 16), [IntPtr]$screen)
    Start-Sleep -Milliseconds 300
  }
  "exclude" {
    # Pins set WDA_EXCLUDEFROMCAPTURE: a desktop capture must not contain them.
    $pin = (Get-Pins)[0]
    $rect = Get-Rect $pin
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size $width, $height))
    $graphics.Dispose()
    # The pinned test image is orange inside blue; a visible pin would show
    # those strong colours at the centre.
    $centre = $bitmap.GetPixel([int]($width / 2), [int]($height / 2))
    $bitmap.Dispose()
    "CENTRE_RGB=$($centre.R),$($centre.G),$($centre.B) PIN_EXCLUDED=$(-not ($centre.R -gt 200 -and $centre.G -gt 100 -and $centre.B -lt 80))"
  }
  "print" {
    # Reads the pin's own layered content for a visual check.
    $pin = (Get-Pins)[0]
    $rect = Get-Rect $pin
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $hdc = $graphics.GetHdc()
    $ok = [W]::PrintWindow($pin, $hdc, 2)
    $graphics.ReleaseHdc($hdc)
    $graphics.Dispose()
    $path = Join-Path $PSScriptRoot "pin-printwindow.png"
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    "PRINTWINDOW=$ok PATH=$path"
  }
  "measure" {
    $process = Get-Process -Name kiri
    $before = $process.TotalProcessorTime.TotalMilliseconds
    Start-Sleep -Seconds 5
    $process.Refresh()
    $cpu = $process.TotalProcessorTime.TotalMilliseconds - $before
    "PINS=$((Get-Pins).Count) WORKING_SET_MB=$([math]::Round($process.WorkingSet64 / 1MB, 1)) PRIVATE_MB=$([math]::Round($process.PrivateMemorySize64 / 1MB, 1)) CPU_MS_OVER_5S=$([math]::Round($cpu, 1))"
  }
  "close-all" {
    foreach ($pin in Get-Pins) {
      [void][W]::SendMessage($pin, 0x0111, [IntPtr]1, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 150
    }
    "PINS_LEFT=$((Get-Pins).Count) BADGES_LEFT=$((Get-Badges).Count)"
  }
}
