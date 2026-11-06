# 桌面布局助手 · DesktopIconKeeper

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows)](#兼容性)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)](#兼容性)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)](#原理)

> 解决 **Windows 切换屏幕 / 改分辨率 / 改缩放（DPI）/ 远程桌面 / 开机之后，桌面图标被打乱** 的问题。
>
> 同一块屏幕：**精确还原**；换到一块没见过的屏幕：**按相对位置自动排**，不用重新整理。

纯 PowerShell + 内嵌 C#，双击 `.cmd` 即用：不需要管理员、不联网、不写注册表、不修改系统设置。

---

## 一、为什么切换屏幕后图标会乱

Windows 会把桌面图标坐标按「显示配置」保存在注册表
`HKCU\Software\Microsoft\Windows\Shell\Bags\1\Desktop\IconLayouts`。

当你切换屏幕时（换显示器、改分辨率、远程控制软件新建虚拟屏、模拟器/串流软件启停显示器、改缩放比例），
显示配置就变成了一个新「配置」：

- 新配置没有存过布局 → Windows 自己排一遍（按名字 / 网格重排）；
- 之后它还会把这次「自动排」的结果存下来，原来的排列就被覆盖了；
- 再从大屏切回小屏时，超出屏幕的图标会被强行拉回可见区域，坐标也就丢了。

ToDesk、MuMu、GameViewer（UU 远程）这类会创建虚拟显示器的软件，远程或模拟器一连接就会新增/移除显示器，
于是特别容易「切一次乱一次」。

> Windows **没有**官方开关能让它「记住布局」。可靠的办法是：**记住你的布局，系统一打乱就自动摆回去。**

## 二、它怎么工作

### 1. 主布局

你最后一次整理好的排列就是「主布局」。它同时记下：

- 每个图标的**像素坐标**（同一块屏幕时精确还原）；
- 每个图标所在的**网格坐标**（第几列、第几行，换屏幕时用来按相对位置重排）。

### 2. 换到新屏幕：相对布局 + 自动靠拢 + 推挤

不再按像素等比缩放（那样会让图标挤成一团或散得很开），而是在网格上做三件事
（实现见 [`src/LayoutEngine.cs`](src/LayoutEngine.cs)）：

1. **弹性间隙**：把有图标的列/行之间的空白当成弹簧。
   - 屏幕变小 → 先压缩最大的那片空地，组与组之间的小间隔尽量保留；
   - 屏幕变大 → 只拉伸大空地，于是**贴左的留在左边、贴右的留在右边、居中的保持居中**。
2. **溢出处理**：某一组图标比新屏幕还高时，放得下的**原地不动**，只把底部放不下的几个挪走——
   先填进这组自己范围内的空洞（自动靠拢），还不够就在它右边加一列，右边的组整体往右推。
3. **推挤**：大组先落位；后面的组如果落点被占，**整组平移**到最近的空位；
   整组实在放不下才拆开，每个图标找最近的空格。最后保证不越界、不重叠。

不改桌面就能先看效果：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Preview -Cols 20 -Rows 8
```

```
主布局 · 屏幕 1（主屏）：27 列 x 11 行          换到 20 列 x 8 行的屏幕后：
+---------------------------+                  +--------------------+
|AAAA.......................|                  |AAAAA.......CCCC....|
|AAAA.......................|                  |AAAAA.......CCCC....|
|AAAA.......CCCC............|                  |AAAAA..BBB..CCCC....|
|AAAA.......CCCC............|                  |AAAA...BB....CCC....|
|AAAA..BBB..CCCC............|                  |AAAA...BB....CCC....|
|AAA...BB....CCC............|                  |AAAA...BB....CCC....|
|AAA...BB....CCC............|                  |AAAA...BB....CCC....|
|AAA...BB....CCC............|                  |AAAA...BB....CCC....|
|AAA...BB....CCC............|                  +--------------------+
|AAA...BB....CCC............|
|...........................|                  （同一字母 = 同一组；A 组只挪了底部 6 个，
+---------------------------+                    3 个填进自己的空洞，3 个放到新加的一列）
```

多显示器时，主屏对主屏，副屏按相对方位（左/右/上/下）对应；新配置里少了的屏幕，
它上面的图标并到主屏上，同样按整组推挤落位。

### 3. 后台监视（Watch）

| 情况 | 处理 |
|---|---|
| 开机 / 登录 | 计划任务登录即启动，等桌面图标加载稳定后**立刻按主布局校正一次** |
| 显示配置变化 | 等签名稳定、系统不再挪图标后恢复 |
| explorer 重启 | 等桌面重建完成后恢复 |
| 大量图标各自乱动（系统重排） | 自动恢复（2 分钟内最多 4 次，防止和别的程序互相打架） |
| 你拖动了少量图标，或框选一批一起拖 | 学习为新的主布局 |
| 新建 / 删除文件 | 新图标若压在别的图标位置上就挪到最近空格；删掉的图标位置保留 30 天 |

## 三、快速开始

1. **下载**：`git clone https://github.com/Thap678/desktop-icon-keeper.git`，或 **Code → Download ZIP**。
   放在一个**固定的**目录里（例如 `D:\Tools\desktop-icon-keeper`），整个文件夹都要保留（`src\` 里是核心代码）。
2. **整理好桌面图标**，右键桌面 → 查看 → **取消勾选「自动排列图标」**（「将图标与网格对齐」保持开启）。
3. **双击 `安装.cmd`**：保存当前布局 → 注册登录自启动 → 启动后台监视。
4. 之后就不用管了。

> 从旧版升级：直接再双击一次 `安装.cmd`。旧的布局文件会自动迁移，旧的启动文件夹快捷方式会被换成计划任务，
> 旧的监视进程会被结束并换成新的。

## 四、文件说明

| 文件 | 作用 |
|---|---|
| `DesktopIconKeeper.ps1` | 主程序：保存 / 恢复 / 监视 / 安装 |
| `src/Native.cs` | 桌面 ListView 跨进程读写、显示器与 DPI 信息 |
| `src/LayoutEngine.cs` | 相对布局引擎（弹性间隙、溢出处理、推挤） |
| `tests/LayoutEngine.Tests.ps1` | 布局引擎单元测试（不碰真实桌面） |
| `安装.cmd` | 保存当前布局 + 登录自启动 + 启动监视 |
| `卸载.cmd` | 取消自启动并结束后台监视（已保存的布局保留） |
| `保存当前布局.cmd` | 把当前排列存为主布局 |
| `恢复布局.cmd` | 立即按主布局恢复 |
| `查看状态.cmd` | 显示配置、网格大小、主布局、后台状态、最近日志 |
| `自检.cmd` | 「移动 3 个图标 → 恢复」+ 一次换屏演算 |

## 五、命令行用法

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Status
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Save
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Restore
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Preview -Cols 20 -Rows 8
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Install
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Test
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Reset
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\LayoutEngine.Tests.ps1
```

| 参数 | 说明 |
|---|---|
| `-Action <名称>` | `Status` / `Save` / `Restore` / `Preview` / `Watch` / `Install` / `Uninstall` / `Test` / `Reset`，默认 `Status` |
| `-PollMs <毫秒>` | 监视轮询间隔，默认 `1500` |
| `-NoLearn` | 不学习手动调整，只按已保存的主布局恢复 |
| `-Cols` / `-Rows` | 仅 `Preview`：目标屏幕网格的列数 / 行数（默认按 1920×1080、同缩放估算） |

## 六、运行状态与文件位置

| 内容 | 位置 |
|---|---|
| 布局文件 | `%LOCALAPPDATA%\DesktopIconKeeper\layouts.json`（上一版备份 `layouts.json.bak`） |
| 运行日志 | `%LOCALAPPDATA%\DesktopIconKeeper\watch.log` |
| 编译缓存 | `%LOCALAPPDATA%\DesktopIconKeeper\bin\DikNative-*.dll`（源码变了会自动重新编译） |
| 自启动 | 计划任务 `DesktopIconKeeper`（登录时触发，普通用户权限）；注册失败时退回启动文件夹 |
| 后台进程 | `powershell.exe -File DesktopIconKeeper.ps1 -Action Watch` |

## 七、注意事项

1. **不要开启「自动排列图标」**。
2. 图标 **改名** 后旧名字匹配不上，会被当成新图标就近安放；拖到想要的位置即可被学习。
3. 用「排序方式 → 名称」等**一次性重排全部图标**的操作，会被当成「系统打乱」而自动撤销。
   如果确实想要这个排列，排好后双击 `保存当前布局.cmd`。
4. 主布局永远是你**最近一次**整理的结果。在小屏幕上手动调整过之后，回到大屏幕时会按小屏幕的排列重新展开
   （贴边、分组、间隔都保持），而不是回到更早的大屏排列。
5. 移动了本文件夹后自启动会失效，重新双击 `安装.cmd` 即可。

## 八、兼容性

- Windows 10 / Windows 11；Windows PowerShell 5.1 或 PowerShell 7+，无需额外模块；
- 单屏 / 多屏、100%–200% 缩放；不需要管理员权限。

## 九、English summary

**DesktopIconKeeper** keeps your Windows desktop icon layout intact. It reads and writes icon positions
via cross-process `LVM_GETITEMPOSITION` / `LVM_SETITEMPOSITION`, keyed by icon name. On the same display
configuration it restores pixel-exact positions; on a new screen it re-lays the icons on the new grid
using an elastic-gap mapping (edge-anchored groups stay on their edge, spacing between groups is
preserved), minimal-disturbance overflow handling, and cluster-level push/collision resolution.
A logon scheduled task starts the watcher immediately at sign-in; it corrects the layout at startup,
after display changes, explorer restarts and system-wide reshuffles, while learning genuine manual moves.

## 十、许可证

[MIT](LICENSE)
