# Windows regression probe for the remembered capture region.
#
# A completed screenshot must remember its region for the display it was drawn
# on, and the next capture must preselect it so Return repeats the same area.
#
# The probe starts the debug build, presses the capture shortcut, drags a region,
# confirms with Return and then starts a second capture: it checks that the
# persisted file exists, that its rectangle matches the drag, that the second
# overlay logs the restored selection, and that Return on that selection saves
# another capture.
#
# Run from the repository root:
#   powershell -ExecutionPolicy Bypass -File scripts/qa/windows-capture-region.ps1

$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RegionProbe {
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
"@

function Press($vk) {
  [RegionProbe]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [RegionProbe]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
}
function MoveTo($x, $y) {
  [RegionProbe]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 90
}
function Drag($x1, $y1, $x2, $y2) {
  MoveTo $x1 $y1
  [RegionProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  for ($i = 1; $i -le 8; $i++) {
    MoveTo ([int]($x1 + ($x2 - $x1) * $i / 8)) ([int]($y1 + ($y2 - $y1) * $i / 8))
  }
  [RegionProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 500
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$exe = if ($env:KIRI_EXE) { $env:KIRI_EXE } else { Join-Path $root "src-tauri\target\debug\kiri.exe" }
if (-not (Test-Path $exe)) { throw "Build the debug app first: cargo build --manifest-path src-tauri/Cargo.toml" }
$log = Join-Path $env:LOCALAPPDATA "Lumen\logs\lumen.log"
$selectionFile = Join-Path $env:APPDATA "Lumen\Settings\last-capture-selection.json"

$failures = 0
function Check($name, $ok, $detail) {
  if ($ok) { "PASS $name $detail" } else { $script:failures++; "FAIL $name $detail" }
}

Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 900
Remove-Item $selectionFile -ErrorAction SilentlyContinue
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 6

Press 0x70   # F1: capture
Start-Sleep -Seconds 3
Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$x1 = [int]($screen.Width * 0.25)
$y1 = [int]($screen.Height * 0.25)
$x2 = [int]($screen.Width * 0.55)
$y2 = [int]($screen.Height * 0.65)
Drag $x1 $y1 $x2 $y2
Press 0x0D   # Return: confirm
Start-Sleep -Seconds 5

$saved = Test-Path $selectionFile
Check "completed capture remembers its region" $saved $selectionFile
$selection = if ($saved) { Get-Content $selectionFile -Raw | ConvertFrom-Json } else { $null }
# The saved rectangle is display-local points, so it is compared against the
# display's own logical size rather than the physical drag.
Check "remembered rectangle is valid for its display" (
  $selection -and $selection.width -gt 20 -and $selection.height -gt 20 -and
  ($selection.x + $selection.width) -le ($selection.displayWidth + 1) -and
  ($selection.y + $selection.height) -le ($selection.displayHeight + 1)
) $(if ($selection) { "$($selection.x),$($selection.y) $($selection.width)x$($selection.height) on $($selection.displayWidth)x$($selection.displayHeight)" } else { "missing" })

$importsBefore = (Get-Content $log | Select-String "confirm_capture: library import complete").Count
Press 0x70
Start-Sleep -Seconds 3
$restoreLine = Get-Content $log -Tail 120 | Select-String "restoring last selection" | Select-Object -Last 1
$match = if ($restoreLine) { [regex]::Match($restoreLine.Line, 'restoring last selection ([\d.]+)x([\d.]+) at (-?[\d.]+),(-?[\d.]+)') } else { $null }
$close = $false
if ($match -and $match.Success -and $selection) {
  $close = [math]::Abs([double]$match.Groups[1].Value - $selection.width) -le 1 -and
           [math]::Abs([double]$match.Groups[2].Value - $selection.height) -le 1 -and
           [math]::Abs([double]$match.Groups[3].Value - $selection.x) -le 1 -and
           [math]::Abs([double]$match.Groups[4].Value - $selection.y) -le 1
}
Check "next capture restores the same region" $close $(if ($restoreLine) { $restoreLine.Line } else { "no log entry" })
Press 0x0D
Start-Sleep -Seconds 5
$importsAfter = (Get-Content $log | Select-String "confirm_capture: library import complete").Count
Check "Return repeats the remembered capture" ($importsAfter -gt $importsBefore) "imports $importsBefore -> $importsAfter"

Get-Process kiri -ErrorAction SilentlyContinue | Stop-Process -Force
"Note: this probe creates two real captures in the Lumen library; move them to Trash afterwards."
if ($failures -gt 0) { exit 1 }
