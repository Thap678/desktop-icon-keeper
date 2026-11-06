<#
.SYNOPSIS
    桌面图标位置保镖 / Desktop Icon Keeper
    保存、恢复并自动看护 Windows 桌面图标的位置，防止切换屏幕（分辨率/显示器/远程桌面/
    扩展屏/DPI 变化）、开机、explorer 重启后图标被打乱。

.DESCRIPTION
      * Save      —— 把当前桌面图标的排列保存为「主布局」
      * Restore   —— 立刻按主布局恢复（同一屏幕精确还原，换了屏幕按相对布局自动排）
      * Preview   —— 不动桌面，用字符图预览主布局在另一块屏幕上会怎么排
      * Watch     —— 常驻监视：开机、显示配置变化、explorer 重启、系统乱排后自动恢复；
                     你手动拖动图标后自动学习
      * Install   —— 注册「登录即启动」的计划任务（失败时退回启动文件夹）并启动监视
      * Uninstall —— 取消自启动并结束后台进程
      * Test      —— 自检：移动 3 个图标 -> 恢复 -> 校验，并演算一次换屏
      * Status    —— 查看当前显示配置、主布局、运行状态
      * Reset     —— 删除已保存的布局

    原理：桌面图标是一个 SysListView32 控件。脚本跨进程发送 LVM_GETITEMPOSITION /
    LVM_SETITEMPOSITION 读写每个图标的坐标，以图标名称作为身份标识。
    布局同时记成「网格坐标」，换屏幕时用 src\LayoutEngine.cs 里的弹性间隙 + 推挤算法重新落位。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Save
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Preview -Cols 20 -Rows 8
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Save', 'Restore', 'Preview', 'Watch', 'Install', 'Uninstall', 'Test', 'Reset')]
    [string]$Action = 'Status',

    [int]$PollMs = 1500,

    [switch]$NoLearn,

    # 仅 Preview 用：目标屏幕的网格列数 / 行数（默认按 1920x1080、同缩放估算）
    [int]$Cols = 0,
    [int]$Rows = 0
)

$ErrorActionPreference = 'Stop'
$script:AppName    = 'DesktopIconKeeper'
$script:AppDir     = Join-Path $env:LOCALAPPDATA $script:AppName
$script:StatePath  = Join-Path $script:AppDir 'layouts.json'
$script:LogPath    = Join-Path $script:AppDir 'watch.log'
$script:VbsPath    = Join-Path $script:AppDir 'watcher.vbs'
$script:TaskName   = 'DesktopIconKeeper'
$script:NoLearn    = [bool]$NoLearn
$script:ScriptPath = $PSCommandPath
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Path }
$script:ScriptDir  = Split-Path -Parent $script:ScriptPath
$script:StaleDays  = 30

# ---------------------------------------------------------------------------
# 加载原生代码（编译结果缓存成 DLL，开机时不必每次调用编译器）
# ---------------------------------------------------------------------------
function Import-DikTypes {
    if ('DikNative' -as [type]) { return }
    $files = @(
        (Join-Path $script:ScriptDir 'src\Native.cs'),
        (Join-Path $script:ScriptDir 'src\LayoutEngine.cs')
    )
    foreach ($f in $files) { if (-not (Test-Path $f)) { throw "缺少源文件：$f（请保留整个文件夹，不要只拷贝 .ps1）" } }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $files) {
        $bytes = [System.IO.File]::ReadAllBytes($f)
        [void]$sb.Append([BitConverter]::ToString($sha.ComputeHash($bytes)))
    }
    [void]$sb.Append($PSVersionTable.PSVersion.ToString()).Append([Environment]::Version.ToString())
    $key = [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))).Replace('-', '').Substring(0, 16)
    $sha.Dispose()

    $binDir = Join-Path $script:AppDir 'bin'
    $prefix = 'DikNative-{0}{1}-' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor
    $dll = Join-Path $binDir ("{0}{1}.dll" -f $prefix, $key)
    if (Test-Path $dll) {
        try { Add-Type -Path $dll; return } catch { }
    }
    try {
        if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
        $tmp = Join-Path $binDir ("build-{0}-{1}.tmp.dll" -f $key, $PID)
        Add-Type -Path $files -OutputAssembly $tmp -OutputType Library
        Move-Item -Path $tmp -Destination $dll -Force
        # 只清理同一 PowerShell 版本的旧缓存（正在运行的进程锁着的会删不掉，忽略）
        Get-ChildItem -Path $binDir -Filter ($prefix + '*.dll') | Where-Object { $_.FullName -ne $dll } |
            ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { } }
        if (-not ('DikNative' -as [type])) { Add-Type -Path $dll }
    } catch {
        if (-not ('DikNative' -as [type])) { Add-Type -Path $files }
    }
}

# ---------------------------------------------------------------------------
# 通用工具
# ---------------------------------------------------------------------------
function Write-DikLog {
    param([string]$Message, [switch]$Console)
    try {
        if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
        if (Test-Path $script:LogPath) {
            if ((Get-Item $script:LogPath).Length -gt 512KB) { Move-Item $script:LogPath "$($script:LogPath).old" -Force }
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
        Write-DikLog ('布局文件损坏，无法读取: ' + $_.Exception.Message)
        return $null
    }
}

function Save-DikState {
    param($Master)
    if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
    $state = [pscustomobject]@{
        Version   = 2
        UpdatedAt = (Get-Date).ToString('o')
        Master    = $Master
    }
    $json = $state | ConvertTo-Json -Depth 8
    # 先写临时文件再替换，避免写到一半被打断导致布局文件损坏
    $tmp = "$($script:StatePath).tmp"
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    if (Test-Path $script:StatePath) { Copy-Item $script:StatePath "$($script:StatePath).bak" -Force }
    Move-Item -Path $tmp -Destination $script:StatePath -Force
}

function Get-DikPhase {
    param([int[]]$Values, [int]$Pitch)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $counts = @{}
    foreach ($v in $Values) {
        $m = (($v % $Pitch) + $Pitch) % $Pitch
        if ($counts.ContainsKey($m)) { $counts[$m]++ } else { $counts[$m] = 1 }
    }
    $best = $null; $bestN = -1
    foreach ($k in $counts.Keys) { if ($counts[$k] -gt $bestN) { $best = $k; $bestN = $counts[$k] } }
    return [int]$best
}

function Get-DikNearestMonitor {
    param($Monitors, [double]$X, [double]$Y)
    $best = 0; $bestD = [double]::MaxValue
    for ($i = 0; $i -lt $Monitors.Count; $i++) {
        $m = $Monitors[$i]
        $dx = 0.0; $dy = 0.0
        if ($X -lt $m.L) { $dx = $m.L - $X } elseif ($X -ge $m.R) { $dx = $X - $m.R + 1 }
        if ($Y -lt $m.T) { $dy = $m.T - $Y } elseif ($Y -ge $m.B) { $dy = $Y - $m.B + 1 }
        $d = $dx * $dx + $dy * $dy
        if ($d -lt $bestD) { $best = $i; $bestD = $d }
    }
    return $best
}

# 给显示器算出网格（首格位置、列数、行数），给图标算出所在显示器与格子坐标
function Set-DikGrid {
    param($Monitors, $Icons, [int]$PitchX, [int]$PitchY)

    foreach ($ic in $Icons) {
        $ic.Mon = Get-DikNearestMonitor $Monitors ($ic.X + $PitchX / 2.0) ($ic.Y + $PitchY / 2.0)
    }
    $allX = @($Icons | ForEach-Object { [int]$_.X })
    $allY = @($Icons | ForEach-Object { [int]$_.Y })
    $gpx = Get-DikPhase $allX $PitchX
    $gpy = Get-DikPhase $allY $PitchY

    for ($i = 0; $i -lt $Monitors.Count; $i++) {
        $m = $Monitors[$i]
        $mine = @($Icons | Where-Object { $_.Mon -eq $i })
        $px = Get-DikPhase @($mine | ForEach-Object { [int]$_.X }) $PitchX
        $py = Get-DikPhase @($mine | ForEach-Object { [int]$_.Y }) $PitchY
        if ($null -eq $px) { $px = $gpx }
        if ($null -eq $py) { $py = $gpy }
        if ($null -eq $px) { $px = $m.WL + [int]($PitchX * 0.17) }
        if ($null -eq $py) { $py = $m.WT + 2 }
        $m.FirstX = [int]($m.WL + (((($px - $m.WL) % $PitchX) + $PitchX) % $PitchX))
        $m.FirstY = [int]($m.WT + (((($py - $m.WT) % $PitchY) + $PitchY) % $PitchY))
        $m.C = [int][Math]::Max(1, [Math]::Floor(($m.WR - $m.FirstX) / [double]$PitchX))
        $m.Rw = [int][Math]::Max(1, [Math]::Floor(($m.WB - $m.FirstY) / [double]$PitchY))
    }

    foreach ($ic in $Icons) {
        $m = $Monitors[$ic.Mon]
        $ic.Col = [int][Math]::Floor(($ic.X - $m.FirstX) / [double]$PitchX + 0.5)
        $ic.Row = [int][Math]::Floor(($ic.Y - $m.FirstY) / [double]$PitchY + 0.5)
    }
}

function New-DikMonitorObject {
    param($L, $T, $R, $B, $WL, $WT, $WR, $WB, $Dpi, $Primary)
    return [pscustomobject]@{
        Primary = [bool]$Primary
        L = [int]$L; T = [int]$T; R = [int]$R; B = [int]$B
        WL = [int]$WL; WT = [int]$WT; WR = [int]$WR; WB = [int]$WB
        Dpi = [int]$Dpi
        FirstX = 0; FirstY = 0; C = 1; Rw = 1
    }
}

function Get-DikSnapshot {
    param([IntPtr]$Lv = [IntPtr]::Zero)
    if ($Lv -eq [IntPtr]::Zero) { $Lv = [DikNative]::FindDesktopListView() }
    if ($Lv -eq [IntPtr]::Zero) { throw '找不到桌面图标列表：explorer.exe 可能没有运行。' }

    $raw     = [DikNative]::GetIcons($Lv)
    $origin  = [DikNative]::GetClientOrigin($Lv)
    $spacing = [DikNative]::GetItemSpacing($Lv)

    $mons = New-Object System.Collections.ArrayList
    foreach ($m in [DikNative]::GetMonitors()) {
        [void]$mons.Add((New-DikMonitorObject $m.Left $m.Top $m.Right $m.Bottom $m.WorkLeft $m.WorkTop $m.WorkRight $m.WorkBottom $m.Dpi $m.Primary))
    }
    $icons = New-Object System.Collections.ArrayList
    foreach ($i in $raw) {
        [void]$icons.Add([pscustomobject]@{
            Index = $i.Index; Name = $i.Name
            X = [int]($origin.X + $i.X); Y = [int]($origin.Y + $i.Y)
            Mon = 0; Col = 0; Row = 0
        })
    }
    $monArr = @($mons); $iconArr = @($icons)
    Set-DikGrid $monArr $iconArr $spacing.X $spacing.Y

    return [pscustomobject]@{
        Lv = $Lv
        Signature = [DikNative]::GetDisplaySignature()
        Dpi = [DikNative]::GetDpi($Lv)
        PitchX = $spacing.X; PitchY = $spacing.Y
        OriginX = $origin.X; OriginY = $origin.Y
        Monitors = $monArr
        Icons = $iconArr
    }
}

function Get-DikHash {
    param([IntPtr]$Lv)
    $sb = New-Object System.Text.StringBuilder
    foreach ($i in [DikNative]::GetIcons($Lv)) {
        [void]$sb.Append($i.Name).Append(':').Append($i.X).Append(',').Append($i.Y).Append(';')
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# 主布局（Master）：最近一次「用户意图」的完整快照，同时记像素坐标与网格坐标
# ---------------------------------------------------------------------------
function New-DikMaster {
    param($Snap, $Prev)
    $rev = 1
    if ($null -ne $Prev -and $null -ne $Prev.PSObject.Properties['Rev']) { $rev = [int]$Prev.Rev + 1 }
    $now = (Get-Date).ToString('o')

    $icons = @($Snap.Icons | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; X = $_.X; Y = $_.Y; Mon = $_.Mon; Col = $_.Col; Row = $_.Row }
    })

    # 同一显示配置下，暂时不在桌面上的图标保留一段时间（文件删了又建回来时能回到老位置）
    $missing = New-Object System.Collections.ArrayList
    if ($null -ne $Prev -and $Prev.Signature -eq $Snap.Signature -and [int]$Prev.PitchX -eq $Snap.PitchX -and [int]$Prev.PitchY -eq $Snap.PitchY) {
        $present = @{}
        foreach ($i in $Snap.Icons) { $present[$i.Name] = $true }
        $cutoff = (Get-Date).AddDays(-$script:StaleDays)
        $seenNames = @{}
        $candidates = @()
        foreach ($p in @($Prev.Icons)) { if ($null -ne $p) { $candidates += [pscustomobject]@{ I = $p; Seen = [string]$Prev.CapturedAt } } }
        if ($null -ne $Prev.PSObject.Properties['Missing']) {
            foreach ($p in @($Prev.Missing)) { if ($null -ne $p) { $candidates += [pscustomobject]@{ I = $p; Seen = [string]$p.LastSeen } } }
        }
        foreach ($c in $candidates) {
            $n = [string]$c.I.Name
            if ($present.ContainsKey($n) -or $seenNames.ContainsKey($n)) { continue }
            $seen = $null
            try { $seen = [datetime]::Parse($c.Seen) } catch { $seen = Get-Date }
            if ($seen -lt $cutoff) { continue }
            $seenNames[$n] = $true
            [void]$missing.Add([pscustomobject]@{ Name = $n; X = [int]$c.I.X; Y = [int]$c.I.Y; Mon = [int]$c.I.Mon; Col = [int]$c.I.Col; Row = [int]$c.I.Row; LastSeen = $c.Seen })
        }
    }

    return [pscustomobject]@{
        Rev = $rev
        Signature = $Snap.Signature
        CapturedAt = $now
        Dpi = $Snap.Dpi
        PitchX = $Snap.PitchX; PitchY = $Snap.PitchY
        Monitors = @($Snap.Monitors)
        IconCount = $icons.Count
        Icons = $icons
        Missing = @($missing)
    }
}

# 从 v1 的 layouts.json（Default 布局）迁移
function ConvertFrom-DikV1 {
    param($Default, $Snap)
    if ($null -eq $Default -or $null -eq $Default.Icons) { return $null }
    $mons = New-Object System.Collections.ArrayList
    $sig = [string]$Default.Signature
    $body = $sig.Substring([Math]::Max(0, $sig.IndexOf('|') + 1))
    foreach ($part in $body.Split(';')) {
        $f = $part.Split(',')
        if ($f.Count -lt 7) { continue }
        $L = [int]$f[0]; $T = [int]$f[1]; $R = [int]$f[2]; $B = [int]$f[3]
        $WL = $L; $WT = $T; $WR = $R; $WB = $B
        foreach ($cur in $Snap.Monitors) {
            if ($cur.L -eq $L -and $cur.T -eq $T -and $cur.R -eq $R -and $cur.B -eq $B) { $WL = $cur.WL; $WT = $cur.WT; $WR = $cur.WR; $WB = $cur.WB }
        }
        [void]$mons.Add((New-DikMonitorObject $L $T $R $B $WL $WT $WR $WB ([int]$f[4]) ($f[6] -eq 'P')))
    }
    if ($mons.Count -eq 0) { return $null }

    $ratio = 1.0
    if ($null -ne $Default.PSObject.Properties['Dpi'] -and [int]$Default.Dpi -gt 0) { $ratio = [int]$Default.Dpi / [double]$Snap.Dpi }
    $px = [int][Math]::Round($Snap.PitchX * $ratio); $py = [int][Math]::Round($Snap.PitchY * $ratio)

    $icons = @($Default.Icons | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; X = [int]$_.X; Y = [int]$_.Y; Mon = 0; Col = 0; Row = 0 }
    })
    $monArr = @($mons)
    Set-DikGrid $monArr $icons $px $py
    return [pscustomobject]@{
        Rev = 1; Signature = $sig; CapturedAt = [string]$Default.CapturedAt; Dpi = [int]$Default.Dpi
        PitchX = $px; PitchY = $py; Monitors = $monArr
        IconCount = $icons.Count; Icons = $icons; Missing = @()
    }
}

function Get-DikMaster {
    param($Snap)
    $state = Get-DikState
    if ($null -eq $state) { return $null }
    if ($null -ne $state.PSObject.Properties['Version'] -and [int]$state.Version -ge 2) { return $state.Master }
    if ($null -ne $state.PSObject.Properties['Default'] -and $null -ne $Snap) {
        $m = ConvertFrom-DikV1 $state.Default $Snap
        if ($null -ne $m) {
            Save-DikState $m
            Write-DikLog '已把旧版布局文件迁移到 v2（网格 + 相对布局）。'
        }
        return $m
    }
    return $null
}

function Save-DikLayout {
    param([switch]$Quiet, $Snap = $null)
    if ($null -eq $Snap) { $Snap = Get-DikSnapshot }
    $prev = Get-DikMaster $Snap
    $master = New-DikMaster $Snap $prev
    Save-DikState $master
    if (-not $Quiet) {
        Write-Host ("已保存当前布局：{0} 个图标，显示配置 {1}" -f $master.IconCount, $master.Signature)
        Write-Host ("布局文件：{0}" -f $script:StatePath)
    }
    return $master
}

# ---------------------------------------------------------------------------
# 规划：算出每个当前图标应该去的位置
# ---------------------------------------------------------------------------
function Get-DikMonitorMap {
    param($Src, $Dst)
    $map = New-Object int[] $Src.Count
    $used = @{}
    for ($i = 0; $i -lt $Src.Count; $i++) {
        $map[$i] = -1
        for ($j = 0; $j -lt $Dst.Count; $j++) {
            if ($used.ContainsKey($j)) { continue }
            $a = $Src[$i]; $b = $Dst[$j]
            if ($a.L -eq $b.L -and $a.T -eq $b.T -and $a.R -eq $b.R -and $a.B -eq $b.B) { $map[$i] = $j; $used[$j] = $true; break }
        }
    }
    $sp = 0; for ($i = 0; $i -lt $Src.Count; $i++) { if ($Src[$i].Primary) { $sp = $i } }
    $dp = 0; for ($j = 0; $j -lt $Dst.Count; $j++) { if ($Dst[$j].Primary) { $dp = $j } }
    if ($map[$sp] -lt 0) { $map[$sp] = $dp; $used[$dp] = $true }

    $s0 = $Src[$sp]; $d0 = $Dst[$dp]
    for ($i = 0; $i -lt $Src.Count; $i++) {
        if ($map[$i] -ge 0) { continue }
        $vx = (($Src[$i].L + $Src[$i].R) - ($s0.L + $s0.R)) / [double][Math]::Max(1, $s0.R - $s0.L)
        $vy = (($Src[$i].T + $Src[$i].B) - ($s0.T + $s0.B)) / [double][Math]::Max(1, $s0.B - $s0.T)
        $best = -1; $bestD = [double]::MaxValue
        for ($j = 0; $j -lt $Dst.Count; $j++) {
            if ($used.ContainsKey($j)) { continue }
            $wx = (($Dst[$j].L + $Dst[$j].R) - ($d0.L + $d0.R)) / [double][Math]::Max(1, $d0.R - $d0.L)
            $wy = (($Dst[$j].T + $Dst[$j].B) - ($d0.T + $d0.B)) / [double][Math]::Max(1, $d0.B - $d0.T)
            $d = ($vx - $wx) * ($vx - $wx) + ($vy - $wy) * ($vy - $wy)
            if ($d -lt $bestD) { $best = $j; $bestD = $d }
        }
        if ($best -lt 0) { $best = $dp } else { $used[$best] = $true }
        $map[$i] = $best
    }
    return ,$map
}

function Get-DikPlan {
    param($Master, $Snap)

    $srcMons = @($Master.Monitors)
    $dstMons = @($Snap.Monitors)
    $monMap = Get-DikMonitorMap $srcMons $dstMons

    $exact = ($Master.Signature -eq $Snap.Signature) -and ([int]$Master.PitchX -eq $Snap.PitchX) -and ([int]$Master.PitchY -eq $Snap.PitchY)
    if ($exact) {
        for ($i = 0; $i -lt $srcMons.Count; $i++) {
            $a = $srcMons[$i]; $b = $dstMons[$monMap[$i]]
            if ($a.WL -ne $b.WL -or $a.WT -ne $b.WT -or $a.WR -ne $b.WR -or $a.WB -ne $b.WB) { $exact = $false }
        }
    }

    # 名字 -> 主布局条目队列（同名按出现顺序）；正式条目在前，暂缺条目在后
    $pool = @{}
    $entries = @()
    foreach ($e in @($Master.Icons)) { if ($null -ne $e) { $entries += [pscustomobject]@{ E = $e; Missing = $false } } }
    if ($null -ne $Master.PSObject.Properties['Missing']) {
        foreach ($e in @($Master.Missing)) { if ($null -ne $e) { $entries += [pscustomobject]@{ E = $e; Missing = $true } } }
    }
    foreach ($x in $entries) {
        $k = [string]$x.E.Name
        if (-not $pool.ContainsKey($k)) { $pool[$k] = New-Object System.Collections.Queue }
        $pool[$k].Enqueue($x)
    }

    $matched = New-Object System.Collections.ArrayList
    $newIcons = New-Object System.Collections.ArrayList
    foreach ($c in $Snap.Icons) {
        $k = [string]$c.Name
        if ($pool.ContainsKey($k) -and $pool[$k].Count -gt 0) {
            $x = $pool[$k].Dequeue()
            [void]$matched.Add([pscustomobject]@{ Cur = $c; Src = $x.E; Missing = $x.Missing })
        } else {
            [void]$newIcons.Add($c)
        }
    }
    $stale = 0
    foreach ($q in $pool.Values) { foreach ($x in $q) { if (-not $x.Missing) { $stale++ } } }

    $placers = @()
    foreach ($m in $dstMons) { $placers += New-Object DikPlacer($m.C, $m.Rw) }

    $targets = @{}
    $px = [int]$Snap.PitchX; $py = [int]$Snap.PitchY
    $setCell = {
        param($cur, [int]$mi, [int]$col, [int]$row)
        $m = $dstMons[$mi]
        $targets[$cur.Index] = [pscustomobject]@{
            Index = $cur.Index; Name = $cur.Name; Mon = $mi; Col = $col; Row = $row
            X = [int]($m.FirstX + $col * $px); Y = [int]($m.FirstY + $row * $py)
        }
    }

    if ($exact) {
        foreach ($p in $matched) {
            if ($p.Missing) { continue }
            $mi = $monMap[[int]$p.Src.Mon]
            $placers[$mi].Occupy([int]$p.Src.Col, [int]$p.Src.Row)
            $targets[$p.Cur.Index] = [pscustomobject]@{
                Index = $p.Cur.Index; Name = $p.Cur.Name; Mon = $mi; Col = [int]$p.Src.Col; Row = [int]$p.Src.Row
                X = [int]$p.Src.X; Y = [int]$p.Src.Y
            }
        }
        foreach ($p in $matched) {
            if (-not $p.Missing) { continue }
            $mi = $monMap[[int]$p.Src.Mon]
            $oc = 0; $orow = 0
            $placers[$mi].PlaceSingle([int]$p.Src.Col, [int]$p.Src.Row, [ref]$oc, [ref]$orow)
            & $setCell $p.Cur $mi $oc $orow
        }
    } else {
        # 每块目标屏幕：把映射到它的源屏幕逐个（主屏优先）做相对布局 + 推挤
        $order = @(0..($srcMons.Count - 1) | Sort-Object { if ($srcMons[$_].Primary) { 0 } else { 1 } }, { $_ })
        foreach ($si in $order) {
            $mi = $monMap[$si]
            $group = @($matched | Where-Object { [int]$_.Src.Mon -eq $si })
            if ($group.Count -eq 0) { continue }
            $n = $group.Count
            $gc = New-Object int[] $n; $gr = New-Object int[] $n
            for ($i = 0; $i -lt $n; $i++) { $gc[$i] = [int]$group[$i].Src.Col; $gr[$i] = [int]$group[$i].Src.Row }
            $ic = New-Object int[] $n; $ir = New-Object int[] $n; $cl = New-Object int[] $n
            [DikLayout]::MapGrid($gc, $gr, [int]$srcMons[$si].C, [int]$srcMons[$si].Rw, [int]$dstMons[$mi].C, [int]$dstMons[$mi].Rw, $ic, $ir, $cl)
            $fc = New-Object int[] $n; $fr = New-Object int[] $n
            $placers[$mi].PlaceClusters($ic, $ir, $cl, $fc, $fr)
            for ($i = 0; $i -lt $n; $i++) { & $setCell $group[$i].Cur $mi $fc[$i] $fr[$i] }
        }
    }

    # 新图标：Windows 放的位置空着就留着，否则挪到最近的空格，避免和恢复的图标叠在一起
    foreach ($c in $newIcons) {
        $oc = 0; $orow = 0
        $placers[[int]$c.Mon].PlaceSingle([int]$c.Col, [int]$c.Row, [ref]$oc, [ref]$orow)
        & $setCell $c ([int]$c.Mon) $oc $orow
    }

    $collisions = 0
    foreach ($p in $placers) { $collisions += $p.Collisions }

    return [pscustomobject]@{
        Mode = $(if ($exact) { 'exact' } else { 'relative' })
        Targets = $targets
        Matched = $matched.Count
        New = $newIcons.Count
        Stale = $stale
        Collisions = $collisions
    }
}

function Invoke-DikApply {
    param($Snap, $Plan)
    $todo = @()
    foreach ($c in $Snap.Icons) {
        $t = $Plan.Targets[$c.Index]
        if ($null -eq $t) { continue }
        if ($t.X -ne $c.X -or $t.Y -ne $c.Y) { $todo += $t }
    }
    $res = [pscustomobject]@{ Moved = $todo.Count; Mismatch = 0 }
    if ($todo.Count -eq 0) { return $res }

    $idx = [int[]]@($todo | ForEach-Object { $_.Index })
    $xs  = [int[]]@($todo | ForEach-Object { $_.X - $Snap.OriginX })
    $ys  = [int[]]@($todo | ForEach-Object { $_.Y - $Snap.OriginY })
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        [DikNative]::SetIconPositions($Snap.Lv, $idx, $xs, $ys)
        Start-Sleep -Milliseconds 350
        $after = [DikNative]::GetIcons($Snap.Lv)
        $bad = 0
        for ($i = 0; $i -lt $idx.Length; $i++) {
            if ($idx[$i] -ge $after.Count) { $bad++; continue }
            $a = $after[$idx[$i]]
            if ([Math]::Abs($a.X - $xs[$i]) -gt 2 -or [Math]::Abs($a.Y - $ys[$i]) -gt 2) { $bad++ }
        }
        $res.Mismatch = $bad
        if ($bad -eq 0) { break }
    }
    return $res
}

function Restore-DikLayout {
    param([switch]$Quiet, $Snap = $null)
    $result = [pscustomobject]@{ Success = $false; Mode = ''; Moved = 0; Matched = 0; New = 0; Stale = 0; Mismatch = 0; Message = '' }

    try { if ($null -eq $Snap) { $Snap = Get-DikSnapshot } } catch { $result.Message = $_.Exception.Message; return $result }
    if (([DikNative]::GetStyle($Snap.Lv) -band 0x100) -ne 0) {
        $result.Message = '桌面开启了「自动排列图标」，无法恢复。请右键桌面 -> 查看 -> 取消「自动排列图标」。'
        if (-not $Quiet) { Write-Host $result.Message -ForegroundColor Magenta }
        return $result
    }
    $master = Get-DikMaster $Snap
    if ($null -eq $master) {
        $result.Message = '还没有保存过布局，请先整理好图标并运行 -Action Save。'
        if (-not $Quiet) { Write-Host $result.Message }
        return $result
    }

    $plan = Get-DikPlan $master $Snap
    $apply = Invoke-DikApply $Snap $plan
    $result.Success = $true
    $result.Mode = $plan.Mode
    $result.Moved = $apply.Moved
    $result.Matched = $plan.Matched
    $result.New = $plan.New
    $result.Stale = $plan.Stale
    $result.Mismatch = $apply.Mismatch

    if ($apply.Moved -eq 0) {
        $msg = '布局本来就是对的（{0} 个图标），无需移动' -f $plan.Matched
    } else {
        $msg = '已移动 {0} 个图标' -f $apply.Moved
    }
    if ($plan.Mode -eq 'relative') { $msg += '（新的显示配置：按相对布局自动排）' }
    if ($plan.New -gt 0) { $msg += '；{0} 个新图标就近安放' -f $plan.New }
    if ($plan.Stale -gt 0) { $msg += '；{0} 个已保存图标在桌面已不存在' -f $plan.Stale }
    if ($plan.Collisions -gt 0) { $msg += '；屏幕放不下，{0} 个图标只能重叠' -f $plan.Collisions }
    if ($apply.Mismatch -gt 0) { $msg += '；{0} 个图标未能精确到位' -f $apply.Mismatch }
    $result.Message = $msg
    if (-not $Quiet) { Write-Host $msg }
    return $result
}

# ---------------------------------------------------------------------------
# 区分「用户拖动」和「系统乱排」
# ---------------------------------------------------------------------------
function Compare-DikSnap {
    param($Old, $New)
    $keyed = {
        param($icons)
        $t = @{}; $seen = @{}
        foreach ($i in $icons) {
            $n = [string]$i.Name
            if ($seen.ContainsKey($n)) { $seen[$n]++ } else { $seen[$n] = 0 }
            $t[$n + [char]1 + $seen[$n]] = $i
        }
        return $t
    }
    $a = & $keyed $Old.Icons
    $b = & $keyed $New.Icons
    $moved = 0; $added = 0; $removed = 0
    $deltas = @{}
    foreach ($k in $b.Keys) {
        if (-not $a.ContainsKey($k)) { $added++; continue }
        $dx = $b[$k].X - $a[$k].X; $dy = $b[$k].Y - $a[$k].Y
        if ($dx -ne 0 -or $dy -ne 0) {
            $moved++
            $dk = "$dx,$dy"
            if ($deltas.ContainsKey($dk)) { $deltas[$dk]++ } else { $deltas[$dk] = 1 }
        }
    }
    foreach ($k in $a.Keys) { if (-not $b.ContainsKey($k)) { $removed++ } }
    $dominant = 0
    foreach ($v in $deltas.Values) { if ($v -gt $dominant) { $dominant = $v } }

    $kind = 'none'
    if ($moved -eq 0) {
        if ($added -gt 0 -or $removed -gt 0) { $kind = 'membership' }
    } elseif ($moved -le 3 -or $dominant -ge [Math]::Ceiling($moved * 0.7)) {
        $kind = 'user'      # 少量图标，或一批图标同方向同距离（框选后一起拖）
    } elseif ($moved -ge [Math]::Max(4, [Math]::Ceiling($New.Icons.Count * 0.25))) {
        $kind = 'shuffle'   # 大量图标各自乱动：系统重排
    } else {
        $kind = 'user'
    }
    return [pscustomobject]@{ Kind = $kind; Moved = $moved; Added = $added; Removed = $removed; Distinct = $deltas.Count }
}

function Test-WatcherRunning {
    try {
        $m = New-Object System.Threading.Mutex($false, 'Local\DesktopIconKeeper.Watcher')
        try {
            $acquired = $false
            try { $acquired = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
            if ($acquired) { $m.ReleaseMutex() }
            return (-not $acquired)
        } finally { $m.Dispose() }
    } catch { return $false }
}

# 等桌面就绪：ListView 存在、图标位置连续两次读取一致
function Wait-DikDesktopReady {
    param([int]$TimeoutSec = 120)
    $start = Get-Date
    $deadline = $start.AddSeconds($TimeoutSec)
    $prev = $null; $stable = 0; $lv = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline) {
        $lv = [DikNative]::FindDesktopListView()
        if ($lv -ne [IntPtr]::Zero) {
            try { $h = Get-DikHash $lv } catch { $h = $null }
            # 刚开机时桌面可能先是空的再陆续加载图标；空桌面要多等一会儿才算就绪
            $emptyOk = ((Get-Date) - $start).TotalSeconds -gt 20
            if ($null -ne $h -and ($h -ne '' -or $emptyOk) -and $h -eq $prev) {
                $stable++
                if ($stable -ge 2) { return $lv }
            } else { $stable = 0 }
            $prev = $h
        }
        Start-Sleep -Milliseconds 1000
    }
    return $lv
}

# ---------------------------------------------------------------------------
# Watch：常驻监视
# ---------------------------------------------------------------------------
function Invoke-DikWatch {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DesktopIconKeeper.Watcher')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { Write-DikLog '已有另一个监视进程在运行，本进程退出。'; return }

        $uptime = ''
        try { $uptime = ' 开机已 {0:0} 秒' -f ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds } catch { }
        Write-DikLog ("监视进程启动（PID {0}）{1}，等待桌面就绪……" -f $PID, $uptime)

        $lv = Wait-DikDesktopReady 180
        if ($lv -eq [IntPtr]::Zero) { Write-DikLog '等了 3 分钟仍找不到桌面，继续在后台等待。' }

        $restoreTimes = New-Object System.Collections.Generic.List[datetime]
        $doRestore = {
            param([string]$Why)
            $now = Get-Date
            $recent = @($restoreTimes | Where-Object { ($now - $_).TotalSeconds -lt 120 })
            if ($recent.Count -ge 4) {
                Write-DikLog ("[{0}] 2 分钟内已经恢复了 {1} 次，可能有别的程序在反复重排，暂停自动恢复。" -f $Why, $recent.Count)
                return $false
            }
            $restoreTimes.Add($now)
            try {
                $r = Restore-DikLayout -Quiet
                Write-DikLog ("[{0}] {1}" -f $Why, $r.Message)
                return $r.Success
            } catch {
                Write-DikLog ("[{0}] 恢复失败: {1}" -f $Why, $_.Exception.Message)
                return $false
            }
        }

        # 第一次运行：没有布局就把当前排列存成基础布局；有布局就立刻按它恢复一次（开机即复位）
        if ($lv -ne [IntPtr]::Zero) {
            $snap0 = $null
            try { $snap0 = Get-DikSnapshot $lv } catch { }
            if ($null -ne $snap0 -and $null -eq (Get-DikMaster $snap0)) {
                try { Save-DikLayout -Quiet -Snap $snap0 | Out-Null; Write-DikLog '首次运行：已把当前图标排列保存为主布局。' } catch { Write-DikLog ('首次保存失败: ' + $_.Exception.Message) }
            } elseif ($null -ne $snap0) {
                [void](& $doRestore '启动')
            }
        }

        $lastLv    = [DikNative]::FindDesktopListView()
        $activeSig = [DikNative]::GetDisplaySignature()
        $prevSig   = $activeSig
        $sigStable = 0
        $lastSnap  = $null
        try { if ($lastLv -ne [IntPtr]::Zero) { $lastSnap = Get-DikSnapshot $lastLv } } catch { }
        $lastHash  = ''
        try { if ($lastLv -ne [IntPtr]::Zero) { $lastHash = Get-DikHash $lastLv } } catch { }
        $pendHash  = $null
        $pendCount = 0
        Write-DikLog ("监视中。显示配置: {0} 图标数: {1}" -f $activeSig, $(if ($null -ne $lastSnap) { $lastSnap.Icons.Count } else { 0 }))

        while ($true) {
            Start-Sleep -Milliseconds $PollMs
            try {
                $lv = [DikNative]::FindDesktopListView()
                if ($lv -eq [IntPtr]::Zero) { continue }

                # explorer 重启导致桌面窗口重建
                if ($lv -ne $lastLv) {
                    Write-DikLog '检测到 explorer 桌面窗口重建，等待桌面就绪后恢复。'
                    $lv = Wait-DikDesktopReady 60
                    [void](& $doRestore 'explorer 重启')
                    $lastLv = $lv
                    $activeSig = [DikNative]::GetDisplaySignature(); $prevSig = $activeSig; $sigStable = 0
                    $lastSnap = Get-DikSnapshot $lv; $lastHash = Get-DikHash $lv; $pendHash = $null
                    continue
                }

                # 显示配置变化：等签名稳定、图标不再被系统挪动后再恢复
                $sig = [DikNative]::GetDisplaySignature()
                if ($sig -ne $prevSig) { $prevSig = $sig; $sigStable = 0; continue }
                $sigStable++
                if ($sig -ne $activeSig) {
                    if ($sigStable -lt 2) { continue }
                    Write-DikLog ("检测到显示配置变化: {0}" -f $sig)
                    $lv = Wait-DikDesktopReady 15
                    [void](& $doRestore '显示配置变化')
                    $activeSig = [DikNative]::GetDisplaySignature(); $prevSig = $activeSig; $sigStable = 0
                    $lastLv = $lv
                    $lastSnap = Get-DikSnapshot $lv; $lastHash = Get-DikHash $lv; $pendHash = $null
                    continue
                }

                # 图标位置变化：等它稳定两轮，再判断是用户拖的还是系统乱排的
                $hash = Get-DikHash $lv
                if ($hash -eq $lastHash) { $pendHash = $null; continue }
                if ($hash -ne $pendHash) { $pendHash = $hash; $pendCount = 1; continue }
                $pendCount++
                if ($pendCount -lt 2) { continue }

                $snap = Get-DikSnapshot $lv
                if ($null -eq $lastSnap) { $lastSnap = $snap }
                $cmp = Compare-DikSnap $lastSnap $snap
                $master = Get-DikMaster $snap
                $onMasterConfig = ($null -ne $master -and $master.Signature -eq $snap.Signature)

                switch ($cmp.Kind) {
                    'shuffle' {
                        Write-DikLog ("检测到系统打乱了 {0} 个图标（{1} 种不同位移），自动恢复。" -f $cmp.Moved, $cmp.Distinct)
                        [void](& $doRestore '系统重排')
                        $snap = Get-DikSnapshot $lv
                    }
                    'user' {
                        if ($script:NoLearn) {
                            Write-DikLog ("检测到手动移动了 {0} 个图标（-NoLearn：不学习）。" -f $cmp.Moved)
                        } else {
                            Save-DikLayout -Quiet -Snap $snap | Out-Null
                            Write-DikLog ("已学习：手动移动了 {0} 个图标，保存为主布局。" -f $cmp.Moved)
                        }
                    }
                    'membership' {
                        if ($onMasterConfig -and -not $script:NoLearn) {
                            # 新图标可能落在了已保存位置上：先把它们挪到空位，再记下来
                            if ($cmp.Added -gt 0) {
                                $plan = Get-DikPlan $master $snap
                                $ap = Invoke-DikApply $snap $plan
                                if ($ap.Moved -gt 0) { $snap = Get-DikSnapshot $lv }
                            }
                            Save-DikLayout -Quiet -Snap $snap | Out-Null
                            Write-DikLog ("桌面图标增减（+{0} / -{1}），已更新主布局。" -f $cmp.Added, $cmp.Removed)
                        }
                    }
                }
                $lastSnap = $snap
                $lastHash = Get-DikHash $lv
                $pendHash = $null
            } catch {
                Write-DikLog ('监视循环出错（继续运行）: ' + $_.Exception.Message)
                Start-Sleep -Seconds 2
            }
        }
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Preview：字符图预览换屏效果
# ---------------------------------------------------------------------------
function Get-DikMarks {
    param([int[]]$ClusterIds)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    return [char[]]@($ClusterIds | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function Show-DikPreview {
    $snap = $null
    try { $snap = Get-DikSnapshot } catch { }
    $master = Get-DikMaster $snap
    if ($null -eq $master) { Write-Host '还没有保存过布局。'; return }

    $srcMons = @($master.Monitors)
    $sp = 0; for ($i = 0; $i -lt $srcMons.Count; $i++) { if ($srcMons[$i].Primary) { $sp = $i } }
    $s0 = $srcMons[$sp]
    $px = [int]$master.PitchX; $py = [int]$master.PitchY

    $tc = $Cols; $tr = $Rows
    $taskbar = [Math]::Max(0, ($s0.B - $s0.T) - ($s0.WB - $s0.WT))
    if ($tc -le 0) { $tc = [int][Math]::Max(1, [Math]::Floor((1920 - ($s0.FirstX - $s0.WL)) / [double]$px)) }
    if ($tr -le 0) { $tr = [int][Math]::Max(1, [Math]::Floor((1080 - $taskbar - ($s0.FirstY - $s0.WT)) / [double]$py)) }

    # 源布局：每块源屏幕各画一张，字母 = 簇
    $marksByName = @{}
    $clusterBase = 0
    for ($si = 0; $si -lt $srcMons.Count; $si++) {
        $mine = @($master.Icons | Where-Object { [int]$_.Mon -eq $si })
        if ($mine.Count -eq 0) { continue }
        $c = [int[]]@($mine | ForEach-Object { [int]$_.Col }); $r = [int[]]@($mine | ForEach-Object { [int]$_.Row })
        $ids = [DikLayout]::Clusters($c, $r)
        $marks = Get-DikMarks @($ids | ForEach-Object { $_ + $clusterBase })
        $clusterBase += (($ids | Measure-Object -Maximum).Maximum + 1)
        for ($i = 0; $i -lt $mine.Count; $i++) { $marksByName["$si|$i"] = $marks[$i] }
        $m = $srcMons[$si]
        Write-Host ("主布局 · 屏幕 {0}{1}：{2} 列 x {3} 行，{4} 个图标（同一字母 = 同一簇）" -f ($si + 1), $(if ($m.Primary) { '（主屏）' } else { '' }), $m.C, $m.Rw, $mine.Count) -ForegroundColor Yellow
        Write-Host ([DikLayout]::Render([int]$m.C, [int]$m.Rw, $c, $r, $marks))
    }

    # 目标：一块 tc x tr 的屏幕，所有源屏幕都折叠到它上面
    $fakeMon = New-DikMonitorObject 0 0 ($s0.FirstX + $tc * $px) ($s0.FirstY + $tr * $py) 0 0 ($s0.FirstX + $tc * $px) ($s0.FirstY + $tr * $py) $master.Dpi $true
    $fakeMon.FirstX = $s0.FirstX - $s0.WL; $fakeMon.FirstY = $s0.FirstY - $s0.WT; $fakeMon.C = $tc; $fakeMon.Rw = $tr
    $fakeIcons = @()
    $k = 0
    $cursor = @{}
    foreach ($e in @($master.Icons)) {
        $si = [int]$e.Mon
        if (-not $cursor.ContainsKey($si)) { $cursor[$si] = 0 }
        $fakeIcons += [pscustomobject]@{ Index = $k; Name = $e.Name; X = 0; Y = 0; Mon = 0; Col = 0; Row = 0; Mark = $marksByName["$si|$($cursor[$si])"] }
        $cursor[$si]++; $k++
    }
    $fakeSnap = [pscustomobject]@{ Signature = 'preview'; PitchX = $px; PitchY = $py; Dpi = $master.Dpi; Monitors = @($fakeMon); Icons = $fakeIcons }
    $previewMaster = $master.PSObject.Copy()
    $previewMaster.Missing = @()
    $plan = Get-DikPlan $previewMaster $fakeSnap

    $c = [int[]]@($fakeIcons | ForEach-Object { $plan.Targets[$_.Index].Col })
    $r = [int[]]@($fakeIcons | ForEach-Object { $plan.Targets[$_.Index].Row })
    $marks = [char[]]@($fakeIcons | ForEach-Object { $_.Mark })
    Write-Host ''
    Write-Host ("换到 {0} 列 x {1} 行的屏幕后：" -f $tc, $tr) -ForegroundColor Yellow
    Write-Host ([DikLayout]::Render($tc, $tr, $c, $r, $marks))
    if ($plan.Collisions -gt 0) { Write-Host ("屏幕格子不够，{0} 个图标只能重叠。" -f $plan.Collisions) -ForegroundColor Magenta }
    Write-Host ''
    Write-Host '提示：-Cols / -Rows 指定目标网格大小，例如 -Action Preview -Cols 14 -Rows 6'
}

# ---------------------------------------------------------------------------
# Status / Test / Install / Uninstall
# ---------------------------------------------------------------------------
function Get-StartupShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'DesktopIconKeeper.lnk')
}

function Get-DikTask {
    try { return (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop) } catch { return $null }
}

function Show-DikStatus {
    Write-Host '===== 桌面图标保镖 / DesktopIconKeeper =====' -ForegroundColor Cyan
    $ok = [DikNative]::EnableDpiAwareness()
    Write-Host ("DPI 感知: {0}" -f $(if ($ok -eq 1) { 'per-monitor 已启用' } else { '未启用（坐标可能按 96DPI 换算）' }))

    Write-Host ''
    Write-Host '当前显示配置:' -ForegroundColor Yellow
    $snap = $null
    try { $snap = Get-DikSnapshot } catch { Write-Host ('  [错误] ' + $_.Exception.Message) -ForegroundColor Red }
    if ($null -ne $snap) {
        for ($i = 0; $i -lt $snap.Monitors.Count; $i++) {
            $m = $snap.Monitors[$i]
            Write-Host ("  屏幕 {0}{1}  {2}x{3} @ ({4},{5})  DPI={6}（{7:0}%）  图标网格 {8} 列 x {9} 行" -f ($i + 1), $(if ($m.Primary) { '（主屏）' } else { '' }),
                ($m.R - $m.L), ($m.B - $m.T), $m.L, $m.T, $m.Dpi, ($m.Dpi / 96.0 * 100), $m.C, $m.Rw)
        }
        Write-Host ("  签名: {0}" -f $snap.Signature)
        Write-Host ("  桌面图标: {0} 个，格子 {1}x{2} 像素" -f $snap.Icons.Count, $snap.PitchX, $snap.PitchY)
        if (([DikNative]::GetStyle($snap.Lv) -band 0x100) -ne 0) {
            Write-Host '  [注意] 「自动排列图标」处于开启状态：请右键桌面 -> 查看 -> 取消勾选，否则无法恢复位置。' -ForegroundColor Magenta
        }
    }

    Write-Host ''
    Write-Host '主布局:' -ForegroundColor Yellow
    $master = Get-DikMaster $snap
    if ($null -eq $master) {
        Write-Host '  （还没有保存过布局，请先整理图标后运行 保存当前布局.cmd）'
    } else {
        Write-Host ("  {0} 个图标，第 {1} 版，保存于 {2}" -f $master.IconCount, $master.Rev, $master.CapturedAt)
        Write-Host ("  记录时的显示配置: {0}" -f $master.Signature)
        if ($null -ne $snap) {
            $plan = Get-DikPlan $master $snap
            $diff = 0
            foreach ($c in $snap.Icons) { $t = $plan.Targets[$c.Index]; if ($null -ne $t -and ($t.X -ne $c.X -or $t.Y -ne $c.Y)) { $diff++ } }
            $modeText = $(if ($plan.Mode -eq 'exact') { '同一显示配置，精确还原' } else { '不同显示配置，按相对布局自动排' })
            Write-Host ("  对当前屏幕: {0}；现在有 {1} 个图标不在应有位置" -f $modeText, $diff)
        }
        if ($null -ne $master.PSObject.Properties['Missing'] -and @($master.Missing).Count -gt 0) {
            Write-Host ("  暂时不在桌面上、仍记着位置的图标: {0} 个（{1} 天后遗忘）" -f @($master.Missing).Count, $script:StaleDays)
        }
        Write-Host ("  布局文件: {0}" -f $script:StatePath)
    }

    Write-Host ''
    Write-Host '后台状态:' -ForegroundColor Yellow
    Write-Host ("  监视进程运行中: {0}" -f (Test-WatcherRunning))
    $task = Get-DikTask
    if ($null -ne $task) { Write-Host ("  自启动: 计划任务「{0}」（登录即启动），状态 {1}" -f $script:TaskName, $task.State) }
    elseif (Test-Path (Get-StartupShortcutPath)) { Write-Host '  自启动: 启动文件夹快捷方式（旧方式，开机后会被系统延迟几分钟；建议重新运行 安装.cmd）' -ForegroundColor Magenta }
    else { Write-Host '  自启动: 未安装' }
    Write-Host ("  脚本路径: {0}" -f $script:ScriptPath)
    Write-Host ("  日志路径: {0}" -f $script:LogPath)
    if (Test-Path $script:LogPath) {
        Write-Host '  最近日志:'
        Get-Content $script:LogPath -Tail 6 -Encoding UTF8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

function Invoke-DikTest {
    Write-Host '开始自检：保存当前布局 -> 移动 3 个图标 -> 恢复 -> 校验 -> 演算换屏' -ForegroundColor Cyan
    if (Test-WatcherRunning) {
        Write-Host '[注意] 后台监视进程正在运行；自检会在 1 秒内恢复，一般不会被它误学习。' -ForegroundColor Yellow
    }
    $snap = Get-DikSnapshot
    if ($snap.Icons.Count -eq 0) { throw '桌面上没有图标，无法自检。' }
    $master = Save-DikLayout -Quiet -Snap $snap
    Write-Host ("基线: {0} 个图标，显示配置 {1}" -f $master.IconCount, $master.Signature)

    # 在第一个图标所在屏幕的右下角找 3 个空格
    $mi = [int]$snap.Icons[0].Mon
    $m = $snap.Monitors[$mi]
    $occ = New-Object DikPlacer($m.C, $m.Rw)
    foreach ($i in $snap.Icons) { if ($i.Mon -eq $mi) { $occ.Occupy($i.Col, $i.Row) } }
    $free = @()
    for ($col = $m.C - 1; $col -ge 0 -and $free.Count -lt 3; $col--) {
        for ($row = $m.Rw - 1; $row -ge 0 -and $free.Count -lt 3; $row--) {
            if ($occ.IsFree($col, $row)) { $free += , @($col, $row) }
        }
    }
    $pick = @($snap.Icons | Where-Object { $_.Mon -eq $mi } | Select-Object -First $free.Count)
    $idx = [int[]]@($pick | ForEach-Object { $_.Index })
    $xs = New-Object int[] $pick.Count; $ys = New-Object int[] $pick.Count
    for ($k = 0; $k -lt $pick.Count; $k++) {
        $xs[$k] = $m.FirstX + $free[$k][0] * $snap.PitchX - $snap.OriginX
        $ys[$k] = $m.FirstY + $free[$k][1] * $snap.PitchY - $snap.OriginY
    }
    [DikNative]::SetIconPositions($snap.Lv, $idx, $xs, $ys)
    Start-Sleep -Milliseconds 300
    $after = [DikNative]::GetIcons($snap.Lv)
    $movedOk = 0
    for ($k = 0; $k -lt $idx.Length; $k++) { if ($after[$idx[$k]].X -eq $xs[$k] -and $after[$idx[$k]].Y -eq $ys[$k]) { $movedOk++ } }
    Write-Host ("移动测试: {0}/{1} 个图标成功移动" -f $movedOk, $idx.Length)

    $r = Restore-DikLayout -Quiet
    Write-Host ('恢复: ' + $r.Message)
    Start-Sleep -Milliseconds 300
    $final = Get-DikSnapshot $snap.Lv
    $bad = 0
    foreach ($b in $snap.Icons) {
        $a = $final.Icons[$b.Index]
        if ($null -eq $a -or $a.Name -ne $b.Name -or $a.X -ne $b.X -or $a.Y -ne $b.Y) { $bad++ }
    }

    # 演算：同一布局放到一块更小的屏幕上（不动桌面），检查不越界、不重叠
    $tc = [int][Math]::Max(4, [Math]::Floor($m.C * 0.6)); $tr = [int][Math]::Max(3, [Math]::Floor($m.Rw * 0.7))
    $fake = New-DikMonitorObject 0 0 1 1 0 0 1 1 $snap.Dpi $true
    $fake.C = $tc; $fake.Rw = $tr
    $fakeIcons = @(); $k = 0
    foreach ($e in $master.Icons) { $fakeIcons += [pscustomobject]@{ Index = $k; Name = $e.Name; X = 0; Y = 0; Mon = 0; Col = 0; Row = 0 }; $k++ }
    $plan = Get-DikPlan $master ([pscustomobject]@{ Signature = 'test'; PitchX = $snap.PitchX; PitchY = $snap.PitchY; Monitors = @($fake); Icons = $fakeIcons })
    $cells = @{}; $outside = 0; $dup = 0
    foreach ($t in $plan.Targets.Values) {
        if ($t.Col -lt 0 -or $t.Row -lt 0 -or $t.Col -ge $tc -or $t.Row -ge $tr) { $outside++ }
        $key = "$($t.Col),$($t.Row)"
        if ($cells.ContainsKey($key)) { $dup++ } else { $cells[$key] = 1 }
    }
    $capacity = $tc * $tr
    $simOk = ($outside -eq 0) -and ($dup -eq $plan.Collisions) -and ($plan.Collisions -eq [Math]::Max(0, $fakeIcons.Count - $capacity))
    Write-Host ("换屏演算: {0} 列 x {1} 行，{2} 个图标，越界 {3}，重叠 {4}（容量 {5}）" -f $tc, $tr, $fakeIcons.Count, $outside, $dup, $capacity)

    if ($movedOk -eq $idx.Length -and $bad -eq 0 -and $r.Success -and $simOk) {
        Write-Host '自检结果: 通过 ✔' -ForegroundColor Green
        return $true
    }
    Write-Host ("自检结果: 未完全通过（移动 {0}/{1}，恢复后不一致 {2} 个，换屏演算 {3}）" -f $movedOk, $idx.Length, $bad, $(if ($simOk) { '正常' } else { '异常' })) -ForegroundColor Red
    return $false
}

function Stop-DikWatchers {
    $stopped = 0
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($p.ProcessId -eq $PID) { continue }
            $cmd = [string]$p.CommandLine
            if ($cmd -and ($cmd -match 'DesktopIconKeeper') -and ($cmd -match 'Action\s+Watch')) {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { }
            }
        }
    } catch { }
    if ($stopped -gt 0) { Start-Sleep -Milliseconds 500 }
    return $stopped
}

function Install-DikKeeper {
    if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }

    $snap = Get-DikSnapshot
    if ($null -eq (Get-DikMaster $snap)) {
        Write-Host '尚未保存过布局，先把当前排列保存为主布局。' -ForegroundColor Yellow
        Save-DikLayout -Quiet -Snap $snap | Out-Null
    }

    $vbs = @'
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{SCRIPT}"" -Action Watch", 0, False
'@
    $vbs = $vbs.Replace('{SCRIPT}', $script:ScriptPath)
    # 必须用 Unicode(UTF-16) 保存：脚本路径可能含中文，ANSI 会乱码导致启动失败
    Set-Content -Path $script:VbsPath -Value $vbs -Encoding Unicode
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'

    # 计划任务「登录时」触发，不受启动文件夹的延迟影响；不需要管理员权限
    $taskOk = $false
    try {
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $act  = New-ScheduledTaskAction -Execute $wscript -Argument ('"' + $script:VbsPath + '"')
        $trg  = New-ScheduledTaskTrigger -AtLogOn -User $user
        $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
        $prn  = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $script:TaskName -Action $act -Trigger $trg -Settings $set -Principal $prn -Description '桌面图标位置保镖：登录后立即启动，自动恢复桌面图标布局' -Force -ErrorAction Stop | Out-Null
        $taskOk = $true
    } catch {
        Write-Host ('注册计划任务失败，改用启动文件夹（开机后启动会慢一些）：' + $_.Exception.Message) -ForegroundColor Yellow
    }

    $lnkPath = Get-StartupShortcutPath
    if ($taskOk) {
        if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force }
        Write-Host '自启动已安装：计划任务「DesktopIconKeeper」，登录即启动。' -ForegroundColor Green
    } else {
        $ws = New-Object -ComObject WScript.Shell
        $shortcut = $ws.CreateShortcut($lnkPath)
        $shortcut.TargetPath = $wscript
        $shortcut.Arguments = '"' + $script:VbsPath + '"'
        $shortcut.WorkingDirectory = $script:AppDir
        $shortcut.WindowStyle = 7
        $shortcut.Description = '桌面图标位置保镖 - 自动恢复桌面图标布局'
        $shortcut.Save()
        Write-Host ("自启动已安装：{0}" -f $lnkPath) -ForegroundColor Green
    }

    # 换成新版本：结束旧的监视进程再启动
    $old = Stop-DikWatchers
    if ($old -gt 0) { Write-Host ("已结束旧的监视进程 {0} 个。" -f $old) }
    Start-Process -FilePath $wscript -ArgumentList ('"' + $script:VbsPath + '"') -WindowStyle Hidden
    $running = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-WatcherRunning) { $running = $true; break }
    }
    if ($running) { Write-Host '监视进程: 已启动（后台隐藏运行）' }
    else { Write-Host '监视进程: 未能自动启动，请手动运行 -Action Watch 查看原因。' -ForegroundColor Yellow }
    Write-DikLog ('已安装自启动（{0}）并启动监视进程。' -f $(if ($taskOk) { '计划任务' } else { '启动文件夹' }))
}

function Uninstall-DikKeeper {
    $removed = $false
    if ($null -ne (Get-DikTask)) {
        try { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop; $removed = $true; Write-Host '已删除计划任务。' } catch { Write-Host ('删除计划任务失败: ' + $_.Exception.Message) -ForegroundColor Yellow }
    }
    $lnkPath = Get-StartupShortcutPath
    if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; $removed = $true; Write-Host ("已删除启动文件夹快捷方式: {0}" -f $lnkPath) }
    if (-not $removed) { Write-Host '自启动本来就没有安装。' }
    Write-Host ("已结束监视进程: {0} 个" -f (Stop-DikWatchers))
    Write-DikLog '已卸载自启动。'
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
try {
    if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
    Import-DikTypes
    if ($Action -ne 'Status' -and $Action -ne 'Uninstall' -and $Action -ne 'Reset') { [void][DikNative]::EnableDpiAwareness() }

    switch ($Action) {
        'Status'    { Show-DikStatus }
        'Save'      { [void](Save-DikLayout) }
        'Restore'   { $r = Restore-DikLayout; if (-not $r.Success) { exit 2 } }
        'Preview'   { Show-DikPreview }
        'Watch'     { Invoke-DikWatch }
        'Test'      { $ok = Invoke-DikTest; if (-not $ok) { exit 3 } }
        'Install'   { Install-DikKeeper }
        'Uninstall' { Uninstall-DikKeeper }
        'Reset'     {
            if (Test-Path $script:StatePath) { Remove-Item $script:StatePath -Force; Write-Host '已删除保存的布局。' }
            else { Write-Host '没有保存过布局。' }
        }
    }
} catch {
    Write-Host ('[错误] ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    exit 1
}
