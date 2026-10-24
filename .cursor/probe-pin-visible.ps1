$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PinStateProbe {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
  [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
  [DllImport("user32.dll")] public static extern uint GetWindowDisplayAffinity(IntPtr h, out uint affinity);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Get-Pin { [PinStateProbe]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, "KiriPinWindow", [IntPtr]::Zero) }
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 900
for ($i = 0; $i -lt 8; $i++) { try { [System.Windows.Forms.Clipboard]::SetText("lumen visibility probe"); break } catch { Start-Sleep -Milliseconds 250 } }
$exe = (Resolve-Path "src-tauri\target\release\kiri.exe").Path
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 6
$p = Start-Process -FilePath $exe -ArgumentList "--paste-pin" -PassThru
if ($p) { $null = $p.WaitForExit(8000) }
Start-Sleep -Seconds 3
$pin = Get-Pin
"pinFound=$($pin -ne [IntPtr]::Zero)"
if ($pin -ne [IntPtr]::Zero) {
  $r = New-Object PinStateProbe+RECT; [void][PinStateProbe]::GetWindowRect($pin, [ref]$r)
  "visible=$([PinStateProbe]::IsWindowVisible($pin)) rect=$($r.Left),$($r.Top) $($r.Right-$r.Left)x$($r.Bottom-$r.Top)"
  $ex = [PinStateProbe]::GetWindowLongPtr($pin, -20)
  "exstyle=$([Convert]::ToString($ex.ToInt64(), 16))"
  $k = [uint32]0; $a = [byte]0; $f = [uint32]0
  "layeredAttrs=$([PinStateProbe]::GetLayeredWindowAttributes($pin, [ref]$k, [ref]$a, [ref]$f)) key=$k alpha=$a flags=$f"
  $aff = [uint32]0
  "affinityCall=$([PinStateProbe]::GetWindowDisplayAffinity($pin, [ref]$aff)) affinity=$aff"
}
Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
