Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class U {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr lParam);
  public static List<IntPtr> Top() {
    var found = new List<IntPtr>();
    EnumWindows((h, _) => { found.Add(h); return true; }, IntPtr.Zero);
    return found;
  }
  public static List<IntPtr> Children(IntPtr parent) {
    var found = new List<IntPtr>();
    EnumChildWindows(parent, (h, _) => { found.Add(h); return true; }, IntPtr.Zero);
    return found;
  }
  public static string ClassOf(IntPtr h) { var b = new StringBuilder(256); GetClassName(h, b, b.Capacity); return b.ToString(); }
  public static string TitleOf(IntPtr h) { var b = new StringBuilder(256); GetWindowText(h, b, b.Capacity); return b.ToString(); }
  public static string Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return string.Format("{0},{1} {2}x{3}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top); }
  public static bool Topmost(IntPtr h) { long s = (long)GetWindowLongPtr(h, -20); return (s & 0x8) != 0; }
}
"@
foreach ($h in [U]::Top()) {
  if (-not [U]::IsWindowVisible($h)) { continue }
  if ([U]::TitleOf($h) -eq "kiri" -or [U]::ClassOf($h) -eq "Tauri Window") {
    Write-Output ("TOP hwnd=0x{0:X} class={1} title={2} rect={3} topmost={4}" -f $h.ToInt64(), [U]::ClassOf($h), [U]::TitleOf($h), [U]::Rect($h), [U]::Topmost($h))
    foreach ($c in [U]::Children($h)) {
      Write-Output ("  CHILD hwnd=0x{0:X} class={1} rect={2}" -f $c.ToInt64(), [U]::ClassOf($c), [U]::Rect($c))
    }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    if ($root) {
      Write-Output ("  UIA root name='{0}' class='{1}' children={2}" -f $root.Current.Name, $root.Current.ClassName, $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition).Count)
      $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      Write-Output ("  UIA descendants={0}" -f $all.Count)
      $limit = [Math]::Min($all.Count, 40)
      for ($i = 0; $i -lt $limit; $i++) {
        try {
          $e = $all.Item($i)
          Write-Output ("    [{0}] type={1} name='{2}' class='{3}' enabled={4} bounds={5}" -f $i, $e.Current.ControlType.ProgrammaticName, $e.Current.Name, $e.Current.ClassName, $e.Current.IsEnabled, $e.Current.BoundingRectangle)
        } catch { }
      }
    } else { Write-Output "  UIA root=null" }
  }
}
