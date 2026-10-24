# QA probe: what does each capture overlay render after a synthetic drag?
# Not part of the product.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ProbeNative {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$exe = (Resolve-Path (Join-Path $PSScriptRoot "..\src-tauri\target\debug\kiri.exe")).Path
function Send-Mouse([uint32]$flags, [int]$dx = 0, [int]$dy = 0, [uint32]$data = 0) {
  [ProbeNative]::mouse_event($flags, $dx, $dy, $data, [UIntPtr]::Zero)
}
function Get-Windows {
  $list = New-Object System.Collections.ArrayList
  $callback = [ProbeNative+EnumProc]{
    param($h, $l)
    $cls = New-Object System.Text.StringBuilder 128
    [void][ProbeNative]::GetClassName($h, $cls, 128)
    $title = New-Object System.Text.StringBuilder 256
    [void][ProbeNative]::GetWindowText($h, $title, 256)
    $r = New-Object ProbeNative+RECT
    [void][ProbeNative]::GetWindowRect($h, [ref]$r)
    [void]$list.Add([pscustomobject]@{
      Handle = $h; Class = $cls.ToString(); Title = $title.ToString();
      Visible = [ProbeNative]::IsWindowVisible($h);
      Rect = ("{0},{1} {2}x{3}" -f $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
    })
    return $true
  }
  [void][ProbeNative]::EnumWindows($callback, [IntPtr]::Zero)
  return $list
}

try {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9333"
  Start-Process -FilePath $exe | Out-Null
  Start-Sleep -Seconds 4

  $note = Start-Process notepad -PassThru
  Start-Sleep -Milliseconds 1200
  $note.Refresh()
  [void][ProbeNative]::SetForegroundWindow($note.MainWindowHandle)
  Start-Sleep -Milliseconds 400

  $created = Start-Process -FilePath $exe -ArgumentList "--capture" -PassThru
  if ($created) { $null = $created.WaitForExit(8000) }
  Start-Sleep -Seconds 2

  echo "=== overlay-ish windows (before drag) ==="
  Get-Windows | Where-Object { $_.Title -match "Kiri|kiri" -or $_.Class -match "Tauri|WebView|Kiri" } |
    Select-Object Handle, Class, Title, Visible, Rect | Format-Table -AutoSize | Out-String | Write-Host

  echo "=== DOM before drag ==="
  node (Join-Path $PSScriptRoot "cdp-all-overlays.mjs") 9333

  $selection = @{ x = 600; y = 350; width = 400; height = 400 }
  [void][ProbeNative]::SetCursorPos($selection.x, $selection.y)
  Start-Sleep -Milliseconds 200
  Send-Mouse 0x0002
  Start-Sleep -Milliseconds 120
  foreach ($step in 1..10) {
    [void][ProbeNative]::SetCursorPos(
      $selection.x + [int]($selection.width * $step / 10),
      $selection.y + [int]($selection.height * $step / 10))
    Send-Mouse 0x0001
    Start-Sleep -Milliseconds 50
  }
  Send-Mouse 0x0004
  Start-Sleep -Milliseconds 900

  echo "=== DOM after drag ==="
  node (Join-Path $PSScriptRoot "cdp-all-overlays.mjs") 9333
}
finally {
  Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
  if ($note) { $note | Stop-Process -Force -ErrorAction SilentlyContinue }
  Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
}
