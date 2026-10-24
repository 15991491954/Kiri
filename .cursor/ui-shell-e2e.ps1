# Verifies the undecorated main window and its macOS-style chrome.
# Drives the real window with Win32 input and clicks the real traffic lights
# through the WebView CDP target. Not part of the product.
$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ShellProbe {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static IntPtr MainWindow(uint processId) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != processId || !IsWindowVisible(h)) return true;
      var title = new System.Text.StringBuilder(256);
      GetWindowTextW(h, title, 256);
      if (title.ToString().StartsWith("Lumen")) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@

$results = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = "") {
  [void]$results.Add([pscustomobject]@{ Test = $name; Pass = $ok; Detail = $detail })
  Write-Host ("[{0}] {1} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $detail)
}
function Target() {
  $deadline = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $deadline) {
    try {
      $pages = Invoke-RestMethod "http://127.0.0.1:9334/json" -TimeoutSec 2
      $page = @($pages | Where-Object { $_.type -eq "page" -and $_.url -notmatch "window=overlay" }) | Select-Object -First 1
      if ($page) { return $page }
    } catch { }
    Start-Sleep -Milliseconds 200
  }
  return $null
}
function Evaluate($page, [string]$expression) {
  $body = @{ id = 1; method = "Runtime.evaluate"; params = @{ expression = $expression; returnByValue = $true; awaitPromise = $true } } | ConvertTo-Json -Depth 6 -Compress
  $socket = New-Object System.Net.WebSockets.ClientWebSocket
  $token = [System.Threading.CancellationToken]::None
  $socket.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $token).Wait()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $socket.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $token).Wait()
  $buffer = New-Object byte[] 65536
  $segment = [ArraySegment[byte]]::new($buffer)
  $result = $socket.ReceiveAsync($segment, $token).Result
  $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
  $socket.Dispose()
  return ($text | ConvertFrom-Json).result.result.value
}
function ClickLight($page, [int]$index) {
  $expression = "(() => { const lights = [...document.querySelectorAll('.kiri-window-light')]; if (lights.length < 3) return { ok: false, count: lights.length }; lights[$index].click(); return { ok: true }; })()"
  return Evaluate $page $expression
}

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9334"
  $app = Start-Process -FilePath $exe -PassThru
  Start-Sleep -Seconds 5
  $page = Target
  Check "the library window renders its React shell" ($null -ne $page) "target=$($page.title)"
  if ($null -eq $page) { throw "no library target" }

  $window = [ShellProbe]::MainWindow($app.Id)
  Check "the main window is visible" ($window -ne [IntPtr]::Zero) "hwnd=$window"
  if ($window -eq [IntPtr]::Zero) { throw "no main window" }

  # A native caption would shrink the client area by the title-bar height; the
  # undecorated window keeps the full configured 1000x680 client.
  $client = New-Object ShellProbe+RECT
  [void][ShellProbe]::GetClientRect($window, [ref]$client)
  $origin = New-Object ShellProbe+POINT
  [void][ShellProbe]::ClientToScreen($window, [ref]$origin)
  Check "the client area is the configured size" (
    ($client.Right - $client.Left) -eq 1000 -and ($client.Bottom - $client.Top) -eq 680
  ) "client=$($client.Right)x$($client.Bottom)"
  $outer = New-Object ShellProbe+RECT
  [void][ShellProbe]::GetWindowRect($window, [ref]$outer)
  Check "no native title bar is drawn above the toolbar" (
    ($origin.Y - $outer.Top) -le 12
  ) "clientOffsetY=$($origin.Y - $outer.Top)"

  # Drag the title bar: the custom bar must move the window. A press on an
  # inactive window is consumed by activation, so press once to activate and
  # then perform the drag.
  [void][ShellProbe]::ShowWindow($window, 9)
  $deadline = (Get-Date).AddSeconds(3)
  while ((Get-Date) -lt $deadline -and [ShellProbe]::IsIconic($window)) { Start-Sleep -Milliseconds 100 }
  Start-Sleep -Milliseconds 400
  [void][ShellProbe]::SetForegroundWindow($window)
  Start-Sleep -Milliseconds 400
  $outer = New-Object ShellProbe+RECT
  [void][ShellProbe]::GetWindowRect($window, [ref]$outer)
  $clientOrigin = New-Object ShellProbe+POINT
  [void][ShellProbe]::ClientToScreen($window, [ref]$clientOrigin)
  $startX = $clientOrigin.X + 500
  $startY = $clientOrigin.Y + 12
  [void][ShellProbe]::SetCursorPos($startX, $startY)
  Start-Sleep -Milliseconds 250
  [ShellProbe]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [ShellProbe]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 450
  [void][ShellProbe]::GetWindowRect($window, [ref]$outer)
  [void][ShellProbe]::SetCursorPos($startX, $startY)
  Start-Sleep -Milliseconds 300
  # The WebView renderer can still be resuming after a minimize/restore; retry
  # the gesture a few times before judging it.
  $ok = $false
  $detail = ""
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $before = New-Object ShellProbe+RECT
    [void][ShellProbe]::GetWindowRect($window, [ref]$before)
    $point = New-Object ShellProbe+POINT
    [void][ShellProbe]::ClientToScreen($window, [ref]$point)
    $dragX = $point.X + 500
    $dragY = $point.Y + 12
    [void][ShellProbe]::SetCursorPos($dragX, $dragY)
    Start-Sleep -Milliseconds 300
    [ShellProbe]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 150
    foreach ($step in 1..8) {
      [void][ShellProbe]::SetCursorPos($dragX + 8 * $step, $dragY + 5 * $step)
      Start-Sleep -Milliseconds 45
    }
    [ShellProbe]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    $after = New-Object ShellProbe+RECT
    [void][ShellProbe]::GetWindowRect($window, [ref]$after)
    $dx = $after.Left - $before.Left
    $dy = $after.Top - $before.Top
    $detail = "attempt=$attempt from=$($before.Left),$($before.Top) delta=$dx,$dy"
    if ([math]::Abs($dx - 64) -le 6 -and [math]::Abs($dy - 40) -le 6) { $ok = $true; break }
    Start-Sleep -Milliseconds 400
  }
  Check "the title bar drag moves the window" $ok $detail

  # Traffic lights: close is index 0, minimize 1, zoom 2.
  $zoom = ClickLight $page 2
  Check "the zoom traffic light is reachable" ($zoom.ok -eq $true) ($zoom | ConvertTo-Json -Compress)
  Start-Sleep -Milliseconds 800
  Check "zoom maximizes the window" ([ShellProbe]::IsZoomed($window)) ""
  $restore = ClickLight $page 2
  Check "the zoom traffic light restores the window" ($restore.ok -eq $true) ($restore | ConvertTo-Json -Compress)
  Start-Sleep -Milliseconds 800
  Check "restore returns the window to its size" (-not [ShellProbe]::IsZoomed($window)) ""
  $minimize = ClickLight $page 1
  Check "the minimize traffic light is reachable" ($minimize.ok -eq $true) ($minimize | ConvertTo-Json -Compress)
  $iconicDeadline = (Get-Date).AddSeconds(2)
  while ((Get-Date) -lt $iconicDeadline -and -not [ShellProbe]::IsIconic($window)) {
    Start-Sleep -Milliseconds 100
  }
  Check "minimize hides the window" ([ShellProbe]::IsIconic($window)) ""
  [void][ShellProbe]::ShowWindow($window, 9)
  Start-Sleep -Milliseconds 700


  # The shortcut defaults are F1/F2/F3, as the settings surface reports them.
  $settings = & node (Join-Path $PSScriptRoot "probe-shortcuts.mjs") 9334 2>&1 | Out-String
  Write-Host "shortcut probe: $settings"
  Check "F1/F2/F3 are the declared defaults" (
    $settings -match '"capture":"F1"' -and $settings -match '"pastePin":"F2"' -and $settings -match '"record":"F3"'
  ) $settings
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0}/{1} checks passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Test, $_.Detail) }
  exit 1
}
exit 0
