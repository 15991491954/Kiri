$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AffinityProbe {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct WNDCLASSEX {
    public uint cbSize; public uint style; public IntPtr lpfnWndProc;
    public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance;
    public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
    public string lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern ushort RegisterClassExW(ref WNDCLASSEX wc);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr CreateWindowExW(uint exStyle, string cls, string title,
    uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
  [DllImport("user32.dll")] public static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
  [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowDisplayAffinity(IntPtr h, uint affinity);
  public delegate IntPtr Proc(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static ushort Register(Proc proc) {
    var wc = new WNDCLASSEX();
    wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
    wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc);
    wc.hInstance = Marshal.GetHINSTANCE(typeof(AffinityProbe).Module);
    wc.lpszClassName = "LumenAffinityProbe";
    return RegisterClassExW(ref wc);
  }
  public static IntPtr Create(uint exStyle) {
    return CreateWindowExW(exStyle, "LumenAffinityProbe", "probe", 0x80000000,
      100, 100, 200, 120, IntPtr.Zero, IntPtr.Zero,
      Marshal.GetHINSTANCE(typeof(AffinityProbe).Module), IntPtr.Zero);
  }
}
"@
$proc = [AffinityProbe+Proc]{ param($h, $m, $w, $l) [AffinityProbe]::DefWindowProcW($h, $m, $w, $l) }
[void][AffinityProbe]::Register($proc)
foreach ($case in @(
  @{ name = "plain"; ex = 0x00000000 },
  @{ name = "layered"; ex = 0x00080000 },
  @{ name = "transparent-layered"; ex = 0x00080000 })
) {
  $hwnd = [AffinityProbe]::Create([uint32]$case.ex)
  if ($case.name -ne "plain") { [void][AffinityProbe]::SetLayeredWindowAttributes($hwnd, 0, 255, 2) }
  $ok = [AffinityProbe]::SetWindowDisplayAffinity($hwnd, 0x00000011)
  $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  "{0}: ok={1} lastError={2}" -f $case.name, $ok, $code
  [void][AffinityProbe]::DestroyWindow($hwnd)
}
