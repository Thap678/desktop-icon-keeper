<#
  相对布局引擎的单元测试（不依赖 Pester，不碰真实桌面）
  运行：powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\LayoutEngine.Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\LayoutEngine.cs'
if (-not ('DikLayout' -as [type])) { Add-Type -Path $src }

$script:fail = 0
$script:pass = 0
function Check([string]$name, $actual, $expected) {
    $a = ($actual | ForEach-Object { $_ }) -join ','
    $e = ($expected | ForEach-Object { $_ }) -join ','
    if ($a -eq $e) { $script:pass++; Write-Host "  ok   $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL $name`n       期望 $e`n       实际 $a" -ForegroundColor Red }
}
function Map([int[]]$used, [int]$s, [int]$d) { return [DikLayout]::ElasticMap($used, $s, $d) }

function Arrange([int[]]$cols, [int[]]$rows, [int]$sc, [int]$sr, [int]$dc, [int]$dr) {
    $n = $cols.Count
    $oc = New-Object int[] $n; $or = New-Object int[] $n; $cl = New-Object int[] $n
    [DikLayout]::MapGrid($cols, $rows, $sc, $sr, $dc, $dr, $oc, $or, $cl)
    $p = New-Object DikPlacer($dc, $dr)
    $fc = New-Object int[] $n; $fr = New-Object int[] $n
    $p.PlaceClusters($oc, $or, $cl, $fc, $fr)
    $cells = for ($i = 0; $i -lt $n; $i++) { '{0}:{1}' -f $fc[$i], $fr[$i] }
    return [pscustomobject]@{ C = $fc; R = $fr; Cells = $cells; Placer = $p }
}

Write-Host 'ElasticMap' -ForegroundColor Cyan
# 真实桌面：三组列 0-3 / 6-8 / 11-14，27 列 → 20 列：右侧空地吸收，原样不动
Check '贴左布局缩小不变'     (Map @(0,1,2,3,6,7,8,11,12,13,14) 27 20) @(0,1,2,3,6,7,8,11,12,13,14)
Check '贴左布局放大不变'     (Map @(0,1,2,3,6,7,8) 27 40) @(0,1,2,3,6,7,8)
Check '贴右布局缩小仍贴右'   (Map @(25,26) 27 20) @(18,19)
Check '贴右布局放大仍贴右'   (Map @(25,26) 27 35) @(33,34)
Check '两侧贴边缩小'         (Map @(0,1,25,26) 27 20) @(0,1,18,19)
Check '两侧贴边放大'         (Map @(0,1,25,26) 27 35) @(0,1,33,34)
Check '居中缩小仍居中'       (Map @(12,13,14) 27 21) @(9,10,11)
Check '居中放大仍居中'       (Map @(12,13,14) 27 33) @(15,16,17)
Check '偏左按比例拉伸'       (Map @(8) 21 31) @(12)
Check '组间至少留 1 格'      (Map @(0,3,6) 7 5) @(0,2,4)
Check '空间不够才压到 0'     (Map @(0,3,6) 7 3) @(0,1,2)
Check '溢出时紧凑排列'       (Map @(0,1,2,3,4) 5 3) @(0,1,2,3,4)

Write-Host 'Clusters' -ForegroundColor Cyan
Check '8 邻接连通'           ([DikLayout]::Clusters(@(0,1,3,4,4), @(0,1,0,0,5))) @(0,0,1,1,2)

Write-Host 'MapGrid + DikPlacer' -ForegroundColor Cyan
# 一整列 10 个图标 + 右边隔一列的 3 个；新屏幕只有 8 行
$cols = @(0,0,0,0,0,0,0,0,0,0, 2,2,2); $rows = @(0,1,2,3,4,5,6,7,8,9, 0,1,2)
$r = Arrange $cols $rows 27 11 27 8
Check '太高的列折行，右侧整体右推并保留间隔' $r.Cells @('0:0','0:1','0:2','0:3','0:4','0:5','0:6','0:7','1:0','1:1','3:0','3:1','3:2')

# 溢出的图标先填进簇内空洞，其余图标一个都不动
$cols = @(0,0,0,0,0,0,0,0,0,0, 1,1,1,1,1); $rows = @(0,1,2,3,4,5,6,7,8,9, 0,1,2,3,4)
$r = Arrange $cols $rows 27 11 27 8
Check '溢出先填簇内空洞' $r.Cells @('0:0','0:1','0:2','0:3','0:4','0:5','0:6','0:7','1:5','1:6','1:0','1:1','1:2','1:3','1:4')

# 底部贴边的一簇在矮屏幕上仍贴底；顶部的不动
$r = Arrange @(0,0, 5,5) @(0,1, 9,10) 10 11 10 8
Check '贴底的簇仍贴底' $r.Cells @('0:0','0:1','5:6','5:7')

# 两簇被映射到同一位置时，后放的整簇被推开而不是叠在一起
$p = New-Object DikPlacer(10, 5)
$c = [int[]]@(0,0,1, 0,0); $rr = [int[]]@(0,1,0, 0,1); $k = [int[]]@(0,0,0, 1,1)
$fc = New-Object int[] 5; $fr = New-Object int[] 5
$p.PlaceClusters($c, $rr, $k, $fc, $fr)
$cells = for ($i = 0; $i -lt 5; $i++) { '{0}:{1}' -f $fc[$i], $fr[$i] }
Check '整簇推挤' $cells @('0:0','0:1','1:0','2:0','2:1')

# 屏幕满了：剩下的放不进去时计数而不是死循环
$p = New-Object DikPlacer(2, 1)
$fc = New-Object int[] 3; $fr = New-Object int[] 3
$p.PlaceClusters([int[]]@(0,1,0), [int[]]@(0,0,0), [int[]]@(0,1,2), $fc, $fr)
Check '网格满时记录冲突' $p.Collisions 1

# 新屏幕又窄又矮：所有图标都要在屏幕内且互不重叠
$cols = 0..59 | ForEach-Object { [int][Math]::Floor($_ / 10) * 2 }
$rows = 0..59 | ForEach-Object { [int]($_ % 10) }
$r = Arrange $cols $rows 27 11 9 7
$inside = 0; for ($i = 0; $i -lt 60; $i++) { if ($r.C[$i] -ge 0 -and $r.C[$i] -lt 9 -and $r.R[$i] -ge 0 -and $r.R[$i] -lt 7) { $inside++ } }
Check '小屏幕全部在界内' $inside 60
Check '小屏幕没有重叠'   (@($r.Cells | Sort-Object -Unique).Count) 60

Write-Host ''
Write-Host ("通过 {0}，失败 {1}" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
