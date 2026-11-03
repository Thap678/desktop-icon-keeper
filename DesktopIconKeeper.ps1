<#
.SYNOPSIS
    桌面图标位置保镖 / Desktop Icon Keeper
    保存、恢复并自动看护 Windows 桌面图标的位置，防止切换屏幕（分辨率/显示器/远程桌面/
    扩展屏/DPI 变化）后图标被打乱。

.DESCRIPTION
    Windows 在显示配置变化时会重新排版桌面图标，并可能覆盖原来的位置。本脚本：
      * Save      —— 把当前桌面图标的排列保存为“首选布局”
      * Restore   —— 立刻恢复首选布局
      * Watch     —— 常驻监视显示配置，一旦变化（含 explorer 重启）就自动恢复
      * Install   —— 把 Watch 加入开机启动（通过 Startup 文件夹中的隐藏启动器）
      * Uninstall —— 取消开机启动并结束后台进程
      * Test      —— 自动做一次“移动图标 -> 恢复”的自检
      * Status    —— 查看当前显示配置、已保存的布局、运行状态
      * Reset     —— 删除已保存的全部布局

    原理：桌面图标其实是一个 SysListView32 控件。脚本通过跨进程发送
    LVM_GETITEMPOSITION / LVM_SETITEMPOSITION 读写每个图标的坐标，
    以图标名称作为身份标识，因此与文件增删、排序、注册表中的
    IconLayouts 内部格式无关。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Save
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Install
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Save', 'Restore', 'Watch', 'Install', 'Uninstall', 'Test', 'Reset')]
    [string]$Action = 'Status',

    [int]$PollMs = 1500,

    [switch]$NoLearn
)

$ErrorActionPreference = 'Stop'
$script:AppName    = 'DesktopIconKeeper'
$script:AppDir     = Join-Path $env:LOCALAPPDATA $script:AppName
$script:StatePath  = Join-Path $script:AppDir 'layouts.json'
$script:LogPath    = Join-Path $script:AppDir 'watch.log'
$script:VbsPath    = Join-Path $script:AppDir 'watcher.vbs'
$script:NoLearn    = [bool]$NoLearn
$script:ScriptPath = $PSCommandPath
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Path }

# ---------------------------------------------------------------------------
# 原生代码（Win32 / DPI / 桌面 ListView 跨进程访问）
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class DikIcon {
    public int Index;
    public string Name;
    public int X;
    public int Y;
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

    /// 找到桌面图标的 SysListView32。找不到返回 IntPtr.Zero。
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
            IntPtr lv = FindListViewIn(h);
            if (lv != IntPtr.Zero) return lv;
        }
        return IntPtr.Zero;
    }

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
        int dpi = (int)GetDpiForWindow(lv);
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
        try {
            remote = VirtualAllocEx(proc, IntPtr.Zero, new IntPtr(8192), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (remote == IntPtr.Zero) throw new Exception("VirtualAllocEx 失败，错误码 " + Marshal.GetLastWin32Error());

            IntPtr remoteItem = remote;
            IntPtr remoteText = new IntPtr(remote.ToInt64() + 256);
            IntPtr remotePoint = new IntPtr(remote.ToInt64() + 2048);
            int itemSize = Marshal.SizeOf(typeof(LVITEM));
            int count = GetIconCount(lv);

            for (int i = 0; i < count; i++) {
                LVITEM item = new LVITEM();
                item.mask = LVIF_TEXT;
                item.iItem = i;
                item.iSubItem = 0;
                item.pszText = remoteText;
                item.cchTextMax = 260;

                IntPtr local = Marshal.AllocHGlobal(itemSize);
                Marshal.StructureToPtr(item, local, false);
                IntPtr written;
                WriteProcessMemory(proc, remoteItem, local, new IntPtr(itemSize), out written);
                Marshal.FreeHGlobal(local);

                Send(lv, LVM_GETITEMTEXTW, new IntPtr(i), remoteItem);

                byte[] textBytes = new byte[520];
                IntPtr read;
                ReadProcessMemory(proc, remoteText, Marshal.UnsafeAddrOfPinnedArrayElement(textBytes, 0), new IntPtr(520), out read);
                int z = 0;
                while (z + 1 < textBytes.Length && !(textBytes[z] == 0 && textBytes[z + 1] == 0)) z += 2;

                Send(lv, LVM_GETITEMPOSITION, new IntPtr(i), remotePoint);
                byte[] pointBytes = new byte[8];
                ReadProcessMemory(proc, remotePoint, Marshal.UnsafeAddrOfPinnedArrayElement(pointBytes, 0), new IntPtr(8), out read);

                DikIcon icon = new DikIcon();
                icon.Index = i;
                icon.Name = Encoding.Unicode.GetString(textBytes, 0, z);
                icon.X = BitConverter.ToInt32(pointBytes, 0);
                icon.Y = BitConverter.ToInt32(pointBytes, 4);
                list.Add(icon);
            }
        } finally {
            if (remote != IntPtr.Zero) VirtualFreeEx(proc, remote, IntPtr.Zero, MEM_RELEASE);
            CloseHandle(proc);
        }
        return list;
    }

    /// 批量设置图标位置（相对 ListView 客户区的物理像素坐标）
    public static void SetIconPositions(IntPtr lv, int[] indexes, int[] xs, int[] ys) {
        Send(lv, WM_SETREDRAW, IntPtr.Zero, IntPtr.Zero);
        for (int i = 0; i < indexes.Length; i++) {
            long packed = (((long)(ys[i] & 0xFFFF)) << 16) + (long)(xs[i] & 0xFFFF);
            Send(lv, LVM_SETITEMPOSITION, new IntPtr(indexes[i]), new IntPtr(packed));
        }
        Send(lv, WM_SETREDRAW, new IntPtr(1), IntPtr.Zero);
        InvalidateRect(lv, IntPtr.Zero, true);
    }

    /// 当前显示配置的签名：每台显示器的物理矩形 + 有效 DPI + 是否主屏
    public static string GetDisplaySignature() {
        List<string> parts = new List<string>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data) {
            MONITORINFOEX mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            uint dpiX = 96, dpiY = 96;
            try { GetDpiForMonitor(hMon, 0, out dpiX, out dpiY); } catch (Exception) { dpiX = 96; dpiY = 96; }
            if (GetMonitorInfo(hMon, ref mi)) {
                string prim = ((mi.dwFlags & 1) != 0) ? "P" : "S";
                parts.Add(mi.rcMonitor.Left + "," + mi.rcMonitor.Top + "," + mi.rcMonitor.Right + "," + mi.rcMonitor.Bottom + "," + dpiX + "," + dpiY + "," + prim);
            } else {
                parts.Add(rc.Left + "," + rc.Top + "," + rc.Right + "," + rc.Bottom + "," + dpiX + "," + dpiY + ",?");
            }
            return true;
        }, IntPtr.Zero);
        parts.Sort(StringComparer.Ordinal);
        return "M" + parts.Count + "|" + string.Join(";", parts.ToArray());
    }

    /// 人类可读的显示器信息
    public static List<string> GetDisplayInfo() {
        List<string> lines = new List<string>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data) {
            MONITORINFOEX mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            uint dpiX = 96, dpiY = 96;
            try { GetDpiForMonitor(hMon, 0, out dpiX, out dpiY); } catch (Exception) { dpiX = 96; dpiY = 96; }
            if (GetMonitorInfo(hMon, ref mi)) {
                string prim = ((mi.dwFlags & 1) != 0) ? "主屏" : "副屏";
                lines.Add(string.Format("{0} {1}  区域=({2},{3})-({4},{5}) 尺寸={6}x{7} DPI={8} 缩放={9:0.#}%",
                    mi.szDevice, prim, mi.rcMonitor.Left, mi.rcMonitor.Top, mi.rcMonitor.Right, mi.rcMonitor.Bottom,
                    mi.rcMonitor.Right - mi.rcMonitor.Left, mi.rcMonitor.Bottom - mi.rcMonitor.Top,
                    dpiX, dpiX / 96.0 * 100.0));
            }
            return true;
        }, IntPtr.Zero);
        return lines;
    }
}
'@

# ---------------------------------------------------------------------------
# 通用工具函数
# ---------------------------------------------------------------------------
function Write-DikLog {
    param([string]$Message, [switch]$Console)
    try {
        if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
        if (Test-Path $script:LogPath) {
            $len = (Get-Item $script:LogPath).Length
            if ($len -gt 512KB) {
                Move-Item $script:LogPath "$($script:LogPath).old" -Force
            }
        }
        $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
        if ($Console) { Write-Host $line }
    } catch { }
}

function Get-DikState {
    if (-not (Test-Path $script:StatePath)) { return $null }
    try {
        return (Get-Content -Path $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-DikState {
    param($State)
    if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
    $json = $State | ConvertTo-Json -Depth 12
    Set-Content -Path $script:StatePath -Value $json -Encoding UTF8
}

function Get-DikProfileTable {
    param($State)
    $table = @{}
    if ($null -eq $State) { return $table }
    if ($null -ne $State.PSObject.Properties['Profiles'] -and $null -ne $State.Profiles) {
        foreach ($p in $State.Profiles.PSObject.Properties) {
            $table[$p.Name] = $p.Value
        }
    }
    return $table
}

function Get-CurrentLayout {
    $lv = [DikNative]::FindDesktopListView()
    if ($lv -eq [IntPtr]::Zero) { throw '找不到桌面图标列表：explorer.exe 可能没有运行。' }

    $icons  = [DikNative]::GetIcons($lv)
    $origin = [DikNative]::GetClientOrigin($lv)
    $client = [DikNative]::GetClientSize($lv)
    $dpi    = [DikNative]::GetDpi($lv)
    $scale  = $dpi / 96.0

    $arr = New-Object System.Collections.ArrayList
    foreach ($i in $icons) {
        [void]$arr.Add([pscustomobject]@{
            Name = $i.Name
            X    = [int]($origin.X + $i.X)
            Y    = [int]($origin.Y + $i.Y)
        })
    }

    return [pscustomobject]@{
        Signature = [DikNative]::GetDisplaySignature()
        Dpi       = $dpi
        Scale     = $scale
        OriginX   = $origin.X
        OriginY   = $origin.Y
        ClientW   = $client.X
        ClientH   = $client.Y
        IconCount = $icons.Count
        CapturedAt = (Get-Date).ToString('o')
        Icons     = @($arr)
    }
}

function Save-DikLayout {
    param([switch]$Quiet)
    $layout = Get-CurrentLayout
    $state  = Get-DikState
    $profiles = Get-DikProfileTable $state

    $profiles[$layout.Signature] = $layout

    # 只保留最近 20 套配置，避免文件无限增长
    if ($profiles.Count -gt 20) {
        $ordered = $profiles.GetEnumerator() | Sort-Object { $_.Value.CapturedAt }
        $drop = $profiles.Count - 20
        foreach ($e in $ordered) {
            if ($drop -le 0) { break }
            $profiles.Remove($e.Key)
            $drop--
        }
    }

    $newState = [pscustomobject]@{
        Version   = 1
        UpdatedAt = (Get-Date).ToString('o')
        Default   = $layout
        Profiles  = $profiles
    }
    Save-DikState $newState
    if (-not $Quiet) {
        Write-Host ("已保存当前布局：{0} 个图标，显示配置 {1}" -f $layout.IconCount, $layout.Signature)
        Write-Host ("布局文件：{0}" -f $script:StatePath)
    }
    return $layout
}

function Restore-DikLayout {
    param([switch]$Quiet)

    $result = [pscustomobject]@{
        Success   = $false
        Restored  = 0
        Unmatched = 0
        Stale     = 0
        Mismatch  = 0
        UsedDefault = $false
        Message   = ''
    }

    $lv = [DikNative]::FindDesktopListView()
    if ($lv -eq [IntPtr]::Zero) {
        $result.Message = '找不到桌面图标列表：explorer.exe 可能没有运行。'
        return $result
    }

    $state = Get-DikState
    if ($null -eq $state) {
        $result.Message = '还没有保存过布局，请先整理好图标并运行 -Action Save。'
        return $result
    }

    $sig = [DikNative]::GetDisplaySignature()
    $profiles = Get-DikProfileTable $state
    $saved = $null
    if ($profiles.ContainsKey($sig)) {
        $saved = $profiles[$sig]
    } elseif ($null -ne $state.Default) {
        $saved = $state.Default
        $result.UsedDefault = $true
    }
    if ($null -eq $saved -or $null -eq $saved.Icons) {
        $result.Message = '没有可用的布局数据。'
        return $result
    }

    $dpi = [DikNative]::GetDpi($lv)
    $savedDpi = 96
    if ($null -ne $saved.PSObject.Properties['Dpi'] -and [int]$saved.Dpi -gt 0) { $savedDpi = [int]$saved.Dpi }

    $savedOriginX = 0.0
    $savedOriginY = 0.0
    if ($null -ne $saved.PSObject.Properties['OriginX']) { $savedOriginX = [double]$saved.OriginX }
    if ($null -ne $saved.PSObject.Properties['OriginY']) { $savedOriginY = [double]$saved.OriginY }

    $client = [DikNative]::GetClientSize($lv)

    # 跨分辨率/跨 DPI 时按桌面可用尺寸等比缩放；新布局带 ClientW/H，老布局退回按 DPI 比例
    $dpiFactor = $dpi / [double]$savedDpi
    $scaleX = $dpiFactor
    $scaleY = $dpiFactor
    if ($null -ne $saved.PSObject.Properties['ClientW'] -and [int]$saved.ClientW -gt 0 -and [int]$saved.ClientH -gt 0) {
        $scaleX = $client.X / [double]$saved.ClientW
        $scaleY = $client.Y / [double]$saved.ClientH
    }

    $cell   = [DikNative]::GetItemSpacing($lv)
    $maxX = $client.X - $cell.X
    $maxY = $client.Y - $cell.Y
    if ($maxX -lt 0) { $maxX = 0 }
    if ($maxY -lt 0) { $maxY = 0 }

    # 名称 -> 已保存位置队列（同名图标按出现顺序匹配）
    $map = @{}
    foreach ($s in $saved.Icons) {
        $key = [string]$s.Name
        if (-not $map.ContainsKey($key)) { $map[$key] = New-Object System.Collections.Queue }
        $map[$key].Enqueue($s)
    }

    $current = [DikNative]::GetIcons($lv)

    # 跨 DPI/跨分辨率恢复时，先把目标坐标吸附到当前桌面网格，避免被“对齐到网格”二次挪动
    $gridX = [Math]::Max(1, [int]$cell.X)
    $gridY = [Math]::Max(1, [int]$cell.Y)
    $gridOriginX = 0.0
    $gridOriginY = 0.0
    if ($current.Count -gt 0) {
        $gridOriginX = [double](($current | Measure-Object -Property X -Minimum).Minimum)
        $gridOriginY = [double](($current | Measure-Object -Property Y -Minimum).Minimum)
    }
    $needSnap = ([Math]::Abs($scaleX - 1.0) -gt 0.001) -or ([Math]::Abs($scaleY - 1.0) -gt 0.001)

    $indexes = New-Object System.Collections.Generic.List[int]
    $xs      = New-Object System.Collections.Generic.List[int]
    $ys      = New-Object System.Collections.Generic.List[int]

    foreach ($c in $current) {
        $key = [string]$c.Name
        if ($map.ContainsKey($key) -and $map[$key].Count -gt 0) {
            $s = $map[$key].Dequeue()

            $x = ([double]$s.X - $savedOriginX) * $scaleX
            $y = ([double]$s.Y - $savedOriginY) * $scaleY
            $x = [int][Math]::Round($x)
            $y = [int][Math]::Round($y)

            if ($needSnap) {
                $x = [int]([Math]::Round((($x - $gridOriginX) / [double]$gridX)) * $gridX + $gridOriginX)
                $y = [int]([Math]::Round((($y - $gridOriginY) / [double]$gridY)) * $gridY + $gridOriginY)
            }

            if ($x -lt 0) { $x = 0 }
            if ($y -lt 0) { $y = 0 }
            if ($x -gt $maxX) { $x = $maxX }
            if ($y -gt $maxY) { $y = $maxY }

            $indexes.Add([int]$c.Index)
            $xs.Add($x)
            $ys.Add($y)
        } else {
            $result.Unmatched++
        }
    }

    $stale = 0
    foreach ($q in $map.Values) { $stale += $q.Count }
    $result.Stale = $stale

    if ($indexes.Count -eq 0) {
        $result.Message = '当前桌面没有任何图标能匹配到已保存的布局。'
        return $result
    }

    $idxArr = $indexes.ToArray()
    $xArr   = $xs.ToArray()
    $yArr   = $ys.ToArray()

    [DikNative]::SetIconPositions($lv, $idxArr, $xArr, $yArr)
    Start-Sleep -Milliseconds 350

    # 校验，必要时重试一次
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $after = [DikNative]::GetIcons($lv)
        $byIndex = @{}
        foreach ($a in $after) { $byIndex[$a.Index] = $a }

        $bad = 0
        for ($i = 0; $i -lt $idxArr.Length; $i++) {
            $a = $byIndex[$idxArr[$i]]
            if ($null -eq $a) { $bad++; continue }
            if ([Math]::Abs($a.X - $xArr[$i]) -gt 2 -or [Math]::Abs($a.Y - $yArr[$i]) -gt 2) { $bad++ }
        }
        $result.Mismatch = $bad
        if ($bad -eq 0 -or $attempt -eq 1) { break }
        [DikNative]::SetIconPositions($lv, $idxArr, $xArr, $yArr)
        Start-Sleep -Milliseconds 400
    }

    $result.Restored = $indexes.Count
    $result.Success = $true
    $msg = '已恢复 {0} 个图标的位置' -f $result.Restored
    if ($result.UsedDefault) { $msg += '（当前显示配置没有专属布局，按屏幕比例缩放并贴边）' }
    if ($result.Unmatched -gt 0) { $msg += '；{0} 个新图标未参与恢复' -f $result.Unmatched }
    if ($result.Stale -gt 0) { $msg += '；{0} 个已保存图标在桌面已不存在' -f $result.Stale }
    if ($result.Mismatch -gt 0 -and -not $needSnap) { $msg += '；{0} 个图标未能精确到位' -f $result.Mismatch }
    $result.Message = $msg
    if (-not $Quiet) { Write-Host $msg }
    return $result
}

function Get-DikLayoutHash {
    try {
        $lv = [DikNative]::FindDesktopListView()
        if ($lv -eq [IntPtr]::Zero) { return '' }
        $icons = [DikNative]::GetIcons($lv)
        $sb = New-Object System.Text.StringBuilder
        foreach ($i in $icons) {
            [void]$sb.Append($i.Name).Append(':').Append($i.X).Append(',').Append($i.Y).Append(';')
        }
        return $sb.ToString()
    } catch {
        return ''
    }
}

function Test-WatcherRunning {
    try {
        $m = New-Object System.Threading.Mutex($false, 'Local\DesktopIconKeeper.Watcher')
        try {
            $acquired = $m.WaitOne(0)
            if ($acquired) { $m.ReleaseMutex() }
            return (-not $acquired)
        } finally { $m.Dispose() }
    } catch { return $false }
}

function Get-StartupShortcutPath {
    $startup = [Environment]::GetFolderPath('Startup')
    return (Join-Path $startup 'DesktopIconKeeper.lnk')
}

function Test-StartupInstalled {
    return (Test-Path (Get-StartupShortcutPath))
}

# ---------------------------------------------------------------------------
# 各动作
# ---------------------------------------------------------------------------
function Show-DikStatus {
    Write-Host '===== 桌面图标保镖 / DesktopIconKeeper =====' -ForegroundColor Cyan
    $ok = [DikNative]::EnableDpiAwareness()
    Write-Host ("DPI 感知: {0}" -f $(if ($ok -eq 1) { 'per-monitor 已启用' } else { '未启用（坐标可能按 96DPI 换算）' }))

    Write-Host ''
    Write-Host '当前显示配置:' -ForegroundColor Yellow
    foreach ($line in [DikNative]::GetDisplayInfo()) { Write-Host "  $line" }
    Write-Host ("  签名: {0}" -f [DikNative]::GetDisplaySignature())

    $lv = [DikNative]::FindDesktopListView()
    if ($lv -eq [IntPtr]::Zero) {
        Write-Host '  [错误] 找不到桌面图标列表，explorer.exe 可能未运行。' -ForegroundColor Red
    } else {
        $style = [DikNative]::GetStyle($lv)
        Write-Host ("  桌面 ListView: 0x{0:X}  图标数: {1}  样式: 0x{2:X8}" -f $lv.ToInt64(), [DikNative]::GetIconCount($lv), $style)
        if (($style -band 0x100) -ne 0) {
            Write-Host '  [注意] 检测到 LVS_AUTOARRANGE（自动排列图标）处于开启状态，请右键桌面 -> 查看 -> 取消“自动排列图标”，否则恢复位置可能无效。' -ForegroundColor Magenta
        }
    }

    Write-Host ''
    Write-Host '显示配置与已保存布局:' -ForegroundColor Yellow
    $state = Get-DikState
    if ($null -eq $state) {
        Write-Host '  （还没有保存过布局，请先整理图标后运行 -Action Save）'
    } else {
        Write-Host ("  布局文件: {0}" -f $script:StatePath)
        Write-Host ("  最后更新: {0}" -f $state.UpdatedAt)
        $profiles = Get-DikProfileTable $state
        foreach ($key in $profiles.Keys) {
            $p = $profiles[$key]
            $mark = ''
            if ($null -ne $state.Default -and $p.CapturedAt -eq $state.Default.CapturedAt) { $mark = ' (默认)' }
            Write-Host ("  - {0}  {1} 个图标  保存于 {2}{3}" -f $key, $p.IconCount, $p.CapturedAt, $mark)
        }
        if ($null -ne $state.Default) {
            Write-Host ("  默认布局: {0} 个图标，保存于 {1}" -f $state.Default.IconCount, $state.Default.CapturedAt)
        }
    }

    Write-Host ''
    Write-Host '后台状态:' -ForegroundColor Yellow
    Write-Host ("  监视进程运行中: {0}" -f (Test-WatcherRunning))
    Write-Host ("  开机启动已安装: {0}" -f (Test-StartupInstalled))
    Write-Host ("  脚本路径: {0}" -f $script:ScriptPath)
    Write-Host ("  日志路径: {0}" -f $script:LogPath)
}

function Invoke-DikWatch {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DesktopIconKeeper.Watcher')
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
        if (-not $acquired) {
            Write-DikLog '已有另一个监视进程在运行，本进程退出。'
            return
        }

        # 没有保存过任何布局时，先把当前排列记为基线
        if ($null -eq (Get-DikState)) {
            try {
                Save-DikLayout -Quiet | Out-Null
                Write-DikLog '首次运行：已把当前图标排列保存为基础布局。'
            } catch {
                Write-DikLog ("首次保存布局失败: " + $_.Exception.Message)
            }
        }

        $activeSig = [DikNative]::GetDisplaySignature()
        $prevSig   = $activeSig
        $stable    = 0
        $lv        = [DikNative]::FindDesktopListView()
        $lastLv    = $lv
        $suppressUntil = Get-Date
        $lastSavedHash = Get-DikLayoutHash
        $lastLearnCheck = Get-Date
        $learnSeen = 0

        Write-DikLog ("监视启动。显示配置: " + $activeSig + " 图标数: " + $(if ($lv -ne [IntPtr]::Zero) { [DikNative]::GetIconCount($lv) } else { 0 }))

        while ($true) {
            Start-Sleep -Milliseconds $PollMs

            $sig = [DikNative]::GetDisplaySignature()
            $lv  = [DikNative]::FindDesktopListView()
            if ($lv -eq [IntPtr]::Zero) { continue }

            # explorer 重启导致桌面窗口重建
            if ($lv -ne $lastLv) {
                Write-DikLog '检测到 explorer 桌面窗口重建，等待稳定后恢复布局。'
                Start-Sleep -Seconds 3
                try { $r = Restore-DikLayout -Quiet; Write-DikLog ("恢复结果: " + $r.Message) } catch { Write-DikLog ("恢复失败: " + $_.Exception.Message) }
                $lastLv = [DikNative]::FindDesktopListView()
                $activeSig = [DikNative]::GetDisplaySignature()
                $prevSig = $activeSig
                $stable = 0
                $suppressUntil = (Get-Date).AddSeconds(8)
                $lastSavedHash = Get-DikLayoutHash
                continue
            }

            if ($sig -ne $prevSig) {
                $prevSig = $sig
                $stable = 0
                continue
            }

            $stable++

            # 显示配置变化：等稳定一会儿再恢复
            if ($sig -ne $activeSig -and $stable -ge 2) {
                Write-DikLog ("检测到显示配置变化: " + $sig)
                Start-Sleep -Milliseconds 1200
                try {
                    $r = Restore-DikLayout -Quiet
                    Write-DikLog ("恢复结果: " + $r.Message)
                } catch {
                    Write-DikLog ("恢复失败: " + $_.Exception.Message)
                }
                $activeSig = [DikNative]::GetDisplaySignature()
                $prevSig = $activeSig
                $stable = 0
                $suppressUntil = (Get-Date).AddSeconds(8)
                $lastSavedHash = Get-DikLayoutHash
                $learnSeen = 0
                continue
            }

            # 自动学习：显示配置稳定后，如果用户手动挪动了图标，把新排列存为首选
            if ($script:NoLearn) { continue }
            if ((Get-Date) -lt $suppressUntil) { continue }
            if ($stable -lt 2) { continue }
            if (((Get-Date) - $lastLearnCheck).TotalSeconds -lt 3) { continue }
            $lastLearnCheck = Get-Date

            $hash = Get-DikLayoutHash
            if ($hash -eq '' -or $hash -eq $lastSavedHash) {
                $learnSeen = 0
                continue
            }
            $learnSeen++
            if ($learnSeen -ge 2) {
                try {
                    Save-DikLayout -Quiet | Out-Null
                    $lastSavedHash = $hash
                    Write-DikLog '已学习当前图标排列并保存为首选布局。'
                } catch {
                    Write-DikLog ("学习布局失败: " + $_.Exception.Message)
                }
                $learnSeen = 0
            }
        }
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Invoke-DikTest {
    Write-Host '开始自检：保存当前布局 -> 移动 3 个图标 -> 恢复 -> 校验' -ForegroundColor Cyan
    if (Test-WatcherRunning) {
        Write-Host '[注意] 后台监视进程正在运行，自检已暂停不动它的逻辑，但建议先 Uninstall/结束它以免干扰。' -ForegroundColor Yellow
    }

    $baseline = Save-DikLayout -Quiet
    Write-Host ("基线: {0} 个图标，显示配置 {1}" -f $baseline.IconCount, $baseline.Signature)

    $lv = [DikNative]::FindDesktopListView()
    if ($lv -eq [IntPtr]::Zero) { throw '找不到桌面图标列表。' }
    $icons = [DikNative]::GetIcons($lv)
    if ($icons.Count -eq 0) { throw '桌面上没有图标，无法自检。' }

    $cell = [DikNative]::GetItemSpacing($lv)
    $client = [DikNative]::GetClientSize($lv)

    # 找一个右上/右下角“空网格”作为测试落点（贴合桌面网格，避免被吸附影响校验）
    $xsAll = @($icons | ForEach-Object { $_.X } | Sort-Object -Unique)
    $ysAll = @($icons | ForEach-Object { $_.Y } | Sort-Object -Unique)
    $pitchX = $cell.X; $pitchY = $cell.Y
    if ($xsAll.Count -ge 2) { $pitchX = [Math]::Min(($xsAll[1] - $xsAll[0]), $cell.X) }
    if ($ysAll.Count -ge 2) { $pitchY = [Math]::Min(($ysAll[1] - $ysAll[0]), $cell.Y) }
    if ($pitchX -le 0) { $pitchX = $cell.X }
    if ($pitchY -le 0) { $pitchY = $cell.Y }
    $originX = $xsAll[0]
    $originY = $ysAll[0]
    $maxCol = [Math]::Floor(($client.X - $cell.X - $originX) / $pitchX)
    if ($maxCol -lt 0) { $maxCol = 0 }
    $maxRow = [Math]::Floor(($client.Y - $cell.Y - $originY) / $pitchY)
    if ($maxRow -lt 0) { $maxRow = 0 }
    $targetX = [int]($originX + $maxCol * $pitchX)
    $targetY = [int]($originY + $maxRow * $pitchY)

    $pick = @($icons | Select-Object -First 3)
    $idx = New-Object System.Collections.Generic.List[int]
    $xs  = New-Object System.Collections.Generic.List[int]
    $ys  = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $pick.Count; $i++) {
        $idx.Add([int]$pick[$i].Index)
        $xs.Add([Math]::Max(0, $targetX - $i * [int]$pitchX))
        $ys.Add($targetY)
    }

    [DikNative]::SetIconPositions($lv, $idx.ToArray(), $xs.ToArray(), $ys.ToArray())
    Start-Sleep -Milliseconds 400
    $moved = [DikNative]::GetIcons($lv)
    $movedCount = 0
    for ($i = 0; $i -lt $idx.Count; $i++) {
        $m = $moved[$idx[$i]]
        if ($null -ne $m -and ([Math]::Abs($m.X - $xs[$i]) -le 2) -and ([Math]::Abs($m.Y - $ys[$i]) -le 2)) { $movedCount++ }
    }
    Write-Host ("移动测试: {0}/{1} 个图标成功移动" -f $movedCount, $idx.Count)

    $restore = Restore-DikLayout -Quiet
    Write-Host ("恢复: " + $restore.Message)

    Start-Sleep -Milliseconds 300
    $after = [DikNative]::GetIcons($lv)
    $byIndex = @{}
    foreach ($a in $after) { $byIndex[$a.Index] = $a }
    $origin = [DikNative]::GetClientOrigin($lv)
    $bad = 0
    foreach ($b in $baseline.Icons) {
        $match = $null
        foreach ($a in $after) {
            if ($a.Name -eq $b.Name -and ($origin.X + $a.X) -eq $b.X -and ($origin.Y + $a.Y) -eq $b.Y) { $match = $a; break }
        }
        if ($null -eq $match) { $bad++ }
    }

    if ($movedCount -eq $idx.Count -and $bad -eq 0 -and $restore.Success) {
        Write-Host '自检结果: 通过 ✔  （移动与恢复均正常）' -ForegroundColor Green
        return $true
    }
    Write-Host ("自检结果: 未完全通过（移动 {0}/{1}，恢复后不一致 {2} 个）" -f $movedCount, $idx.Count, $bad) -ForegroundColor Red
    return $false
}

function Install-DikKeeper {
    if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }

    if ($null -eq (Get-DikState)) {
        Write-Host '尚未保存过布局，先把当前排列保存为基础布局。' -ForegroundColor Yellow
        Save-DikLayout -Quiet | Out-Null
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $psExe)) { $psExe = 'powershell.exe' }

    $vbs = @'
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{SCRIPT}"" -Action Watch", 0, False
'@
    $vbs = $vbs.Replace('{SCRIPT}', $script:ScriptPath)
    # 必须用 Unicode(UTF-16) 保存：脚本路径可能含中文，ANSI 会乱码导致启动失败
    Set-Content -Path $script:VbsPath -Value $vbs -Encoding Unicode

    $lnkPath = Get-StartupShortcutPath
    $ws = New-Object -ComObject WScript.Shell
    $shortcut = $ws.CreateShortcut($lnkPath)
    $shortcut.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
    $shortcut.Arguments = '"' + $script:VbsPath + '"'
    $shortcut.WorkingDirectory = $script:AppDir
    $shortcut.WindowStyle = 7
    $shortcut.Description = '桌面图标位置保镖 - 自动恢复桌面图标布局'
    $shortcut.Save()

    Write-Host '开机启动已安装：' -ForegroundColor Green
    Write-Host ("  快捷方式: {0}" -f $lnkPath)
    Write-Host ("  启动脚本: {0}" -f $script:VbsPath)

    $running = Test-WatcherRunning
    if (-not $running) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $script:VbsPath + '"') -WindowStyle Hidden
        for ($i = 0; $i -lt 16; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-WatcherRunning) { $running = $true; break }
        }
        if ($running) {
            Write-Host '监视进程: 已启动（后台隐藏运行）'
        } else {
            Write-Host '监视进程: 未能自动启动，请手动运行 -Action Watch 查看原因。' -ForegroundColor Yellow
        }
    } else {
        Write-Host '监视进程已经在运行。'
    }
    Write-DikLog '已安装开机启动并启动监视进程。'
}

function Uninstall-DikKeeper {
    $lnkPath = Get-StartupShortcutPath
    if (Test-Path $lnkPath) {
        Remove-Item $lnkPath -Force
        Write-Host ("已删除开机启动: {0}" -f $lnkPath)
    } else {
        Write-Host '开机启动本来就没有安装。'
    }

    $stopped = 0
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            $cmd = [string]$p.CommandLine
            if ($cmd -and ($cmd -match 'DesktopIconKeeper') -and ($cmd -match 'Action\s+Watch')) {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { }
            }
        }
    } catch { }
    Write-Host ("已结束监视进程: {0} 个" -f $stopped)
    Write-DikLog '已卸载开机启动。'
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
try {
    if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }

    switch ($Action) {
        'Status'    { Show-DikStatus }
        'Save'      { [void][DikNative]::EnableDpiAwareness(); [void](Save-DikLayout) }
        'Restore'   { [void][DikNative]::EnableDpiAwareness(); $r = Restore-DikLayout; if (-not $r.Success) { exit 2 } }
        'Watch'     { [void][DikNative]::EnableDpiAwareness(); Invoke-DikWatch }
        'Test'      { [void][DikNative]::EnableDpiAwareness(); $ok = Invoke-DikTest; if (-not $ok) { exit 3 } }
        'Install'   { [void][DikNative]::EnableDpiAwareness(); Install-DikKeeper }
        'Uninstall' { Uninstall-DikKeeper }
        'Reset'     {
            if (Test-Path $script:StatePath) {
                Remove-Item $script:StatePath -Force
                Write-Host '已删除保存的布局。'
            } else {
                Write-Host '没有保存过布局。'
            }
        }
    }
} catch {
    Write-Host ('[错误] ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    exit 1
}
