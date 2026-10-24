# Repeatable end-to-end check for the capture -> Pin button flow.
# Usage: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .cursor\pin-stall-e2e.ps1 [-Runs 5]
param([int]$Runs = 5)

$ErrorActionPreference = "Stop"
$pinWord = 'Pin|' + [string][char]0x56FA + [string][char]0x5B9A + '|' + [string][char]0x7F6E + [string][char]0x9876
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
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);

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

  public static bool IsTopmost(IntPtr hwnd) {
    long style = (long)GetWindowLongPtr(hwnd, -20);
    return (style & 0x8) != 0;
  }

  public static string Rect(IntPtr hwnd) {
    RECT r; GetWindowRect(hwnd, out r);
    return string.Format("{0},{1} {2}x{3}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
  }
}
"@

function Get-Pins { @([P]::Windows("KiriPinWindow")) }
function Get-Overlays {
  @([P]::Windows("Tauri Window") | Where-Object {
    $r = New-Object P+RECT
    [P]::GetWindowRect($_, [ref]$r) | Out-Null
    ($r.Right - $r.Left) -ge 800 -and [P]::IsWindowVisible($_) -and [P]::IsTopmost($_)
  })
}
function Get-Rect([IntPtr]$hwnd) {
  $r = New-Object P+RECT
  [P]::GetWindowRect($hwnd, [ref]$r) | Out-Null
  return $r
}
function Get-OverlayAt([int]$x, [int]$y) {
  foreach ($window in Get-Overlays) {
    $r = Get-Rect $window
    if ($x -ge $r.Left -and $x -le $r.Right -and $y -ge $r.Top -and $y -le $r.Bottom) { return $window }
  }
  return $null
}
function Send-CaptureShortcut {
  foreach ($vk in @(0x11, 0x10, 0x41)) { [P]::keybd_event($vk, 0, 0, [UIntPtr]::Zero) }
  Start-Sleep -Milliseconds 50
  [P]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero)
  [P]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)
  [P]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
}
function Drag-Region([int]$x1, [int]$y1, [int]$x2, [int]$y2) {
  [P]::SetCursorPos($x1, $y1) | Out-Null
  Start-Sleep -Milliseconds 120
  [P]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  for ($step = 1; $step -le 10; $step++) {
    $x = [int]($x1 + ($x2 - $x1) * $step / 10)
    $y = [int]($y1 + ($y2 - $y1) * $step / 10)
    [P]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 20
  }
  [P]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}
function Find-PinButton([IntPtr]$hwnd) {
  # English "Pin ..." and Simplified Chinese "固定..." without relying on the
  # script file's encoding.
  $pinWord = 'Pin|' + [string][char]0x56FA + [string][char]0x5B9A + '|' + [string][char]0x7F6E + [string][char]0x9876
  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
  for ($attempt = 0; $attempt -lt 10; $attempt++) {
    # WebView2 can answer the handle with no UIA provider for the first few
    # hundred milliseconds after the window appears.
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if ($root) {
      foreach ($button in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
        if ($button.Current.Name -match $pinWord) { return $button }
      }
    }
    Start-Sleep -Milliseconds 250
  }
  return $null
}
function Invoke-Button($button) {
  $bounds = $button.Current.BoundingRectangle
  $x = [int]($bounds.Left + $bounds.Width / 2)
  $y = [int]($bounds.Top + $bounds.Height / 2)
  [P]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 120
  [P]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [P]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  return "$x,$y"
}
function Close-Pin([IntPtr]$hwnd) {
  [void][P]::SendMessage($hwnd, 0x0111, [IntPtr]1, [IntPtr]::Zero)
}

$results = @()
for ($run = 1; $run -le $Runs; $run++) {
  # Start clean.
  foreach ($pin in Get-Pins) { Close-Pin $pin | Out-Null }
  Start-Sleep -Milliseconds 300
  if ((Get-Overlays).Count -gt 0) { [System.Windows.Forms.SendKeys]::SendWait("{ESC}"); Start-Sleep -Milliseconds 500 }

  $pinsBefore = (Get-Pins).Count
  $started = Get-Date
  Send-CaptureShortcut
  $overlay = $null
  for ($i = 0; $i -lt 60; $i++) {
    if ((Get-Overlays).Count -gt 0) { break }
    Start-Sleep -Milliseconds 100
  }
  if ((Get-Overlays).Count -eq 0) {
    $results += "RUN=$run RESULT=NO_OVERLAY"
    continue
  }
  # The overlay HWND appears before its WebView has loaded and focused; a drag
  # sent too early lands on a not-yet-interactive page and selects nothing.
  Start-Sleep -Milliseconds 1400
  $overlayCount = (Get-Overlays).Count
  Drag-Region 380 380 (380 + 340) (380 + 240)
  Start-Sleep -Milliseconds 700
  $overlay = Get-OverlayAt 400 400
  if (-not $overlay) {
    $results += "RUN=$run RESULT=NO_OVERLAY_AT_DRAG"
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
    Start-Sleep -Milliseconds 500
    continue
  }
  $button = Find-PinButton $overlay
  if (-not $button) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($overlay)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $results += ("RUN={0} RESULT=NO_PIN_BUTTON overlay=0x{1:X} uia={2}" -f $run, $overlay.ToInt64(), $all.Count)
    for ($i = 0; $i -lt [Math]::Min($all.Count, 60); $i++) {
      $e = $all.Item($i)
      if ($e.Current.ControlType.ProgrammaticName -eq "ControlType.Button") {
        $name = $e.Current.Name
        $matchPin = ($name -match $pinWord)
        $codes = ''
        if ($name.Length -gt 0 -and $name.Length -lt 8) {
          $codes = (([int[]][char[]]$name) | ForEach-Object { $_.ToString('X4') }) -join ' '
        }
        $results += ("  BTN name='" + $name + "' pin=" + $matchPin + " codes=" + $codes)
      }
    }
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
    Start-Sleep -Milliseconds 500
    continue
  }
  $clicked = Invoke-Button $button
  $deadline = (Get-Date).AddSeconds(5)
  $overlaysLeft = -1
  $pinsAfter = -1
  while ((Get-Date) -lt $deadline) {
    $overlaysLeft = (Get-Overlays).Count
    $pinsAfter = (Get-Pins).Count
    if ($overlaysLeft -eq 0 -and $pinsAfter -gt $pinsBefore) { break }
    Start-Sleep -Milliseconds 100
  }
  $elapsed = [math]::Round(((Get-Date) - $started).TotalMilliseconds)
  $closeMs = [math]::Round(((Get-Date) - $started).TotalMilliseconds)
  $results += ("RUN={0} OVERLAYS_AT_START={1} CLICK={2} OVERLAYS_LEFT={3} PINS_BEFORE={4} PINS_AFTER={5} ELAPSED_MS={6}" -f `
    $run, $overlayCount, $clicked, $overlaysLeft, $pinsBefore, $pinsAfter, $elapsed)
  if ($overlaysLeft -gt 0) {
    # Leave the run's evidence in place instead of hiding a stuck overlay.
    $results += "RUN=$run STUCK_OVERLAYS"
    break
  }
  Start-Sleep -Milliseconds 400
}

$results | ForEach-Object { Write-Output $_ }
foreach ($pin in Get-Pins) { Close-Pin $pin | Out-Null }
Start-Sleep -Milliseconds 400
Write-Output ("FINAL_PINS={0} FINAL_OVERLAYS={1}" -f (Get-Pins).Count, (Get-Overlays).Count)
