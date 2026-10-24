param([string]$Out = "pin-printwindow.png")

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class PW {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);

  public static IntPtr FirstPin() {
    IntPtr found = IntPtr.Zero;
    EnumWindows((hwnd, _) => {
      var name = new StringBuilder(256);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == "KiriPinWindow") { found = hwnd; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@

$pin = [PW]::FirstPin()
if ($pin -eq [IntPtr]::Zero) { throw "no pin window" }
$r = New-Object PW+RECT
[PW]::GetWindowRect($pin, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
"pin=0x{0:X} visible={1} rect={2},{3} {4}x{5}" -f $pin.ToInt64(), [PW]::IsWindowVisible($pin), $r.Left, $r.Top, $w, $h

$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::Magenta)
$hdc = $g.GetHdc()
$ok = [PW]::PrintWindow($pin, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()
$bmp.Save((Join-Path $PSScriptRoot "..\.cursor\$Out"), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"PrintWindow=$ok"
