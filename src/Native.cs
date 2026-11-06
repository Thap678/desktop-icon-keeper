// 桌面图标保镖 —— 原生部分：Win32 / DPI / 桌面 ListView 跨进程访问 / 显示器信息
// 注意：需要能被 Windows PowerShell 5.1 自带的 C# 5 编译器编译（不要用 $"" / out var / ?. 等新语法）
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class DikIcon {
    public int Index;
    public string Name;
    public int X;   // 相对 ListView 客户区的物理像素
    public int Y;
}

public sealed class DikMonitor {
    public string Device;
    public bool Primary;
    public int Left, Top, Right, Bottom;          // 显示器矩形（屏幕坐标，物理像素）
    public int WorkLeft, WorkTop, WorkRight, WorkBottom; // 工作区（去掉任务栏）
    public int Dpi;
}

public static class DikNative {
    const uint LVM_FIRST = 0x1000;
    const uint LVM_GETITEMCOUNT = LVM_FIRST + 4;
    const uint LVM_SETITEMPOSITION = LVM_FIRST + 15;
    const uint LVM_GETITEMPOSITION = LVM_FIRST + 16;
    const uint LVM_GETITEMSPACING = LVM_FIRST + 53;
    const uint LVM_GETITEMTEXTW = LVM_FIRST + 115;
    const uint LVIF_TEXT = 0x0001;
    const uint WM_SETREDRAW = 0x000B;
    const int GWL_STYLE = -16;
    const uint PROCESS_VM_OPERATION = 0x0008;
    const uint PROCESS_VM_READ = 0x0010;
    const uint PROCESS_VM_WRITE = 0x0020;
    const uint PROCESS_QUERY_INFORMATION = 0x0400;
    const uint MEM_COMMIT = 0x1000;
    const uint MEM_RESERVE = 0x2000;
    const uint PAGE_READWRITE = 0x04;
    const uint MEM_RELEASE = 0x8000;
    const uint SMTO_ABORTIFHUNG = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct LVITEM {
        public uint mask;
        public int iItem;
        public int iSubItem;
        public uint state;
        public uint stateMask;
        public IntPtr pszText;
        public int cchTextMax;
        public int iImage;
        public IntPtr lParam;
        public int iIndent;
        public int iGroupId;
        public uint cColumns;
        public IntPtr puColumns;
        public IntPtr piColFmt;
        public int iGroup;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int nMax);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);

    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX mi);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr hmon, int dpiType, out uint dpiX, out uint dpiY);
    [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr VirtualAllocEx(IntPtr proc, IntPtr addr, IntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool VirtualFreeEx(IntPtr proc, IntPtr addr, IntPtr size, uint type);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteProcessMemory(IntPtr proc, IntPtr addr, IntPtr buf, IntPtr size, out IntPtr written);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr proc, IntPtr addr, IntPtr buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    static IntPtr Send(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam) {
        IntPtr result;
        SendMessageTimeout(hWnd, msg, wParam, lParam, SMTO_ABORTIFHUNG, 3000, out result);
        return result;
    }

    static string ClassName(IntPtr hWnd) {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(hWnd, sb, 256);
        return sb.ToString();
    }

    static IntPtr FindListViewIn(IntPtr parent) {
        IntPtr defView = IntPtr.Zero;
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) {
            if (ClassName(h) == "SHELLDLL_DefView") { defView = h; return false; }
            return true;
        }, IntPtr.Zero);
        if (defView == IntPtr.Zero) return IntPtr.Zero;
        IntPtr listView = IntPtr.Zero;
        EnumChildWindows(defView, delegate(IntPtr h, IntPtr l) {
            if (ClassName(h) == "SysListView32") { listView = h; return false; }
            return true;
        }, IntPtr.Zero);
        return listView;
    }

    /// 找到桌面图标的 SysListView32（Progman 或 WorkerW 下）。找不到返回 IntPtr.Zero。
    public static IntPtr FindDesktopListView() {
        List<IntPtr> tops = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { tops.Add(h); return true; }, IntPtr.Zero);
        foreach (IntPtr h in tops) {
            if (ClassName(h) == "Progman") {
                IntPtr lv = FindListViewIn(h);
                if (lv != IntPtr.Zero) return lv;
            }
        }
        foreach (IntPtr h in tops) {
            if (ClassName(h) != "WorkerW") continue;
            IntPtr lv = FindListViewIn(h);
            if (lv != IntPtr.Zero) return lv;
        }
        return IntPtr.Zero;
    }

    public static bool IsAlive(IntPtr hWnd) { return hWnd != IntPtr.Zero && IsWindow(hWnd); }

    /// 让当前进程变成 per-monitor DPI aware，返回 1=成功 0=可能仍是 DPI unaware
    public static int EnableDpiAwareness() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return 1; } catch (Exception) { }
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-3))) return 1; } catch (Exception) { }
        try { if (SetProcessDpiAwareness(2) == 0) return 1; } catch (Exception) { }
        try { if (SetProcessDPIAware()) return 1; } catch (Exception) { }
        return 0;
    }

    public static int GetIconCount(IntPtr lv) {
        return (int)Send(lv, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero);
    }

    public static long GetStyle(IntPtr lv) {
        return GetWindowLongPtr(lv, GWL_STYLE).ToInt64();
    }

    public static int GetDpi(IntPtr lv) {
        int dpi = 0;
        try { dpi = (int)GetDpiForWindow(lv); } catch (Exception) { dpi = 0; }
        if (dpi <= 0) dpi = 96;
        return dpi;
    }

    public static POINT GetClientOrigin(IntPtr lv) {
        POINT p = new POINT();
        p.X = 0; p.Y = 0;
        ClientToScreen(lv, ref p);
        return p;
    }

    public static POINT GetClientSize(IntPtr lv) {
        RECT r = new RECT();
        GetClientRect(lv, out r);
        POINT p = new POINT();
        p.X = r.Right - r.Left;
        p.Y = r.Bottom - r.Top;
        return p;
    }

    /// 图标网格间距（大图标视图下的格子宽高，物理像素）
    public static POINT GetItemSpacing(IntPtr lv) {
        long v = Send(lv, LVM_GETITEMSPACING, IntPtr.Zero, IntPtr.Zero).ToInt64();
        POINT p = new POINT();
        p.X = (int)(v & 0xFFFF);
        p.Y = (int)((v >> 16) & 0xFFFF);
        if (p.X <= 0) p.X = 75;
        if (p.Y <= 0) p.Y = 75;
        return p;
    }

    /// 读取全部桌面图标（名称 + 相对 ListView 客户区的物理像素坐标）
    public static List<DikIcon> GetIcons(IntPtr lv) {
        List<DikIcon> list = new List<DikIcon>();
        if (lv == IntPtr.Zero) return list;

        uint pid;
        GetWindowThreadProcessId(lv, out pid);
        IntPtr proc = OpenProcess(PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_QUERY_INFORMATION, false, pid);
        if (proc == IntPtr.Zero) throw new Exception("无法打开 explorer 进程，错误码 " + Marshal.GetLastWin32Error());

        IntPtr remote = IntPtr.Zero;
        IntPtr local = IntPtr.Zero;
        try {
            remote = VirtualAllocEx(proc, IntPtr.Zero, new IntPtr(8192), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (remote == IntPtr.Zero) throw new Exception("VirtualAllocEx 失败，错误码 " + Marshal.GetLastWin32Error());

            IntPtr remoteItem = remote;
            IntPtr remoteText = new IntPtr(remote.ToInt64() + 256);
            IntPtr remotePoint = new IntPtr(remote.ToInt64() + 2048);
            int itemSize = Marshal.SizeOf(typeof(LVITEM));
            local = Marshal.AllocHGlobal(itemSize);
            int count = GetIconCount(lv);
            byte[] textBytes = new byte[520];
            byte[] pointBytes = new byte[8];
            GCHandle th = GCHandle.Alloc(textBytes, GCHandleType.Pinned);
            GCHandle ph = GCHandle.Alloc(pointBytes, GCHandleType.Pinned);
            try {
                for (int i = 0; i < count; i++) {
                    LVITEM item = new LVITEM();
                    item.mask = LVIF_TEXT;
                    item.iItem = i;
                    item.iSubItem = 0;
                    item.pszText = remoteText;
                    item.cchTextMax = 260;

                    Marshal.StructureToPtr(item, local, false);
                    IntPtr written;
                    WriteProcessMemory(proc, remoteItem, local, new IntPtr(itemSize), out written);
                    Array.Clear(textBytes, 0, textBytes.Length);
                    Send(lv, LVM_GETITEMTEXTW, new IntPtr(i), remoteItem);

                    IntPtr read;
                    ReadProcessMemory(proc, remoteText, th.AddrOfPinnedObject(), new IntPtr(520), out read);
                    int z = 0;
                    while (z + 1 < textBytes.Length && !(textBytes[z] == 0 && textBytes[z + 1] == 0)) z += 2;

                    Send(lv, LVM_GETITEMPOSITION, new IntPtr(i), remotePoint);
                    ReadProcessMemory(proc, remotePoint, ph.AddrOfPinnedObject(), new IntPtr(8), out read);

                    DikIcon icon = new DikIcon();
                    icon.Index = i;
                    icon.Name = Encoding.Unicode.GetString(textBytes, 0, z);
                    icon.X = BitConverter.ToInt32(pointBytes, 0);
                    icon.Y = BitConverter.ToInt32(pointBytes, 4);
                    list.Add(icon);
                }
            } finally {
                th.Free();
                ph.Free();
            }
        } finally {
            if (local != IntPtr.Zero) Marshal.FreeHGlobal(local);
            if (remote != IntPtr.Zero) VirtualFreeEx(proc, remote, IntPtr.Zero, MEM_RELEASE);
            CloseHandle(proc);
        }
        return list;
    }

    /// 批量设置图标位置（相对 ListView 客户区的物理像素坐标）
    public static void SetIconPositions(IntPtr lv, int[] indexes, int[] xs, int[] ys) {
        Send(lv, WM_SETREDRAW, IntPtr.Zero, IntPtr.Zero);
        try {
            for (int i = 0; i < indexes.Length; i++) {
                long packed = (((long)(ys[i] & 0xFFFF)) << 16) + (long)(xs[i] & 0xFFFF);
                Send(lv, LVM_SETITEMPOSITION, new IntPtr(indexes[i]), new IntPtr(packed));
            }
        } finally {
            Send(lv, WM_SETREDRAW, new IntPtr(1), IntPtr.Zero);
            InvalidateRect(lv, IntPtr.Zero, true);
        }
    }

    /// 全部显示器（含工作区与有效 DPI）
    public static List<DikMonitor> GetMonitors() {
        List<DikMonitor> list = new List<DikMonitor>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data) {
            MONITORINFOEX mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            uint dpiX = 96, dpiY = 96;
            try { GetDpiForMonitor(hMon, 0, out dpiX, out dpiY); } catch (Exception) { dpiX = 96; dpiY = 96; }
            DikMonitor m = new DikMonitor();
            if (GetMonitorInfo(hMon, ref mi)) {
                m.Device = mi.szDevice;
                m.Primary = (mi.dwFlags & 1) != 0;
                m.Left = mi.rcMonitor.Left; m.Top = mi.rcMonitor.Top; m.Right = mi.rcMonitor.Right; m.Bottom = mi.rcMonitor.Bottom;
                m.WorkLeft = mi.rcWork.Left; m.WorkTop = mi.rcWork.Top; m.WorkRight = mi.rcWork.Right; m.WorkBottom = mi.rcWork.Bottom;
            } else {
                m.Device = "?";
                m.Left = rc.Left; m.Top = rc.Top; m.Right = rc.Right; m.Bottom = rc.Bottom;
                m.WorkLeft = rc.Left; m.WorkTop = rc.Top; m.WorkRight = rc.Right; m.WorkBottom = rc.Bottom;
            }
            m.Dpi = (int)dpiX;
            list.Add(m);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /// 当前显示配置的签名：每台显示器的物理矩形 + 有效 DPI + 是否主屏（与 v1 格式兼容）
    public static string GetDisplaySignature() {
        List<string> parts = new List<string>();
        foreach (DikMonitor m in GetMonitors()) {
            parts.Add(m.Left + "," + m.Top + "," + m.Right + "," + m.Bottom + "," + m.Dpi + "," + m.Dpi + "," + (m.Primary ? "P" : "S"));
        }
        parts.Sort(StringComparer.Ordinal);
        return "M" + parts.Count + "|" + string.Join(";", parts.ToArray());
    }
}
