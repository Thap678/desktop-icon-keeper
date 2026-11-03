# 桌面图标位置保镖 · DesktopIconKeeper

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows)](#兼容性)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)](#兼容性)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)](#原理)

> 解决 **Windows 切换屏幕 / 改分辨率 / 改缩放（DPI）/ 远程桌面之后，桌面图标被打乱** 的问题。
>
> 思路很简单：**保存一份布局，显示配置一变就自动恢复。**

纯 PowerShell 单文件实现，双击 `.cmd` 即用：不需要安装、不联网、不写注册表、不修改系统设置。

---

## 一、为什么切换屏幕后图标会乱

Windows 会把桌面图标坐标按「显示配置」保存在注册表
`HKCU\Software\Microsoft\Windows\Shell\Bags\1\Desktop\IconLayouts`（Win10 1703 之后的二进制格式）。

当你切换屏幕时（换显示器、改分辨率、远程控制软件新建虚拟屏、模拟器/串流软件启停显示器、改缩放比例），
显示配置就变成了一个新「配置」：

- 新配置没有存过布局 → Windows 自己排一遍（按名字 / 网格重排）；
- 之后它还会把这次「自动排」的结果存下来，原来的排列就被覆盖了；
- 再从大屏切回小屏时，超出屏幕的图标会被强行拉回可见区域，坐标也就丢了。

如果装了 ToDesk、MuMu、GameViewer（UU 远程）这类会创建虚拟显示器的软件，
远程或模拟器一连接就会新增/移除显示器，于是特别容易出现「切一次乱一次」。

> **结论**：Windows **没有**官方开关或组策略能让它「记住布局」。
> 网上流传的注册表教程基本无效。真正可靠的办法是：**保存一份布局，在显示配置变化后自动恢复。**

## 二、这个脚本怎么解决

`DesktopIconKeeper.ps1` 直接操作桌面图标所在的 `SysListView32` 控件：

- 读取 / 写入每个图标的坐标（`LVM_GETITEMPOSITION` / `LVM_SETITEMPOSITION`，跨进程调用）；
- 用 **图标名字** 作为身份标识，与文件增删、排序、注册表内部格式无关；
- 以「显示配置」（每台显示器的物理矩形 + 有效 DPI + 是否主屏）为键保存多套布局；
- 常驻 `Watch` 监视显示配置，一旦变化（包括 explorer 重启），等系统稳定后自动恢复；
- 你手动调整图标后，它会自动学习并保存为新布局，不用每次手动点保存；
- 跨分辨率 / DPI 时按桌面尺寸等比缩放，并对齐当前网格。

## 三、快速开始

### 1. 下载

```powershell
git clone https://github.com/Thap678/desktop-icon-keeper.git
```

或者点本页右上角 **Code → Download ZIP** 解压。

> 建议放在一个**固定的、不会被移动或清理**的目录（例如 `D:\Tools\desktop-icon-keeper`）。
> 移动文件夹后开机自启会失效，重新双击 `安装.cmd` 即可。

### 2. 先整理好桌面图标

拖成你想要的排列。然后右键桌面 → 查看 → **取消勾选「自动排列图标」**
（「将图标与网格对齐」可以保持开启）。

> 开启「自动排列图标」时 Windows 会不停重排，任何脚本都救不了你。
> 运行 `查看状态.cmd` 时会检测并提示这一点。

### 3. 双击 `安装.cmd`

它会：保存当前布局 → 安装开机自启（隐藏启动器，不弹黑框）→ 立即启动后台监视。

### 4. 之后就不用管了

切换屏幕、插拔显示器、远程连接后，脚本会自动把图标摆回去。

## 四、文件说明

| 文件 | 作用 |
|---|---|
| `DesktopIconKeeper.ps1` | 主程序（所有逻辑都在这里） |
| `安装.cmd` | 保存当前布局 + 开机自启 + 启动监视 |
| `卸载.cmd` | 取消开机自启并结束后台监视（已保存的布局保留） |
| `保存当前布局.cmd` | 把当前排列存为首选布局（「锁定」当前排列） |
| `恢复布局.cmd` | 立即恢复首选布局 |
| `查看状态.cmd` | 查看显示配置、图标数量、已保存布局、后台状态 |
| `自检.cmd` | 自动做一次「移动 3 个图标 → 恢复」的测试，确认功能正常 |

## 五、命令行用法

```powershell
# 查看状态
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Status

# 保存 / 恢复 / 安装 / 卸载 / 自检 / 清空
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Save
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Restore
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Install
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Test
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopIconKeeper.ps1 -Action Reset
```

| 参数 | 说明 |
|---|---|
| `-Action <名称>` | `Status` / `Save` / `Restore` / `Watch` / `Install` / `Uninstall` / `Test` / `Reset`，默认 `Status` |
| `-PollMs <毫秒>` | 监视轮询间隔，默认 `1500` |
| `-NoLearn` | 关闭「手动调整后自动学习」，只按已保存的布局恢复 |

## 六、运行状态与文件位置

| 内容 | 位置 |
|---|---|
| 布局文件 | `%LOCALAPPDATA%\DesktopIconKeeper\layouts.json` |
| 运行日志 | `%LOCALAPPDATA%\DesktopIconKeeper\watch.log` |
| 开机启动 | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\DesktopIconKeeper.lnk` |
| 后台进程 | `powershell.exe -File DesktopIconKeeper.ps1 -Action Watch`（约 1% CPU） |

卸载：双击 `卸载.cmd`，或运行 `-Action Uninstall`。

## 七、注意事项

1. **不要开启「自动排列图标」** —— 见上文第 2 步。
2. 图标 **改名** 后旧名字匹配不上，需要重新 `保存当前布局` 一次。
3. 首次切换到一个新的分辨率 / 显示器配置时，会按比例缩放并贴边（可能与原排列略有差异），
   之后脚本会自动学习该配置的排列，下次就精确恢复。
4. 如果移动了本脚本所在文件夹，开机启动会失效，重新双击 `安装.cmd` 即可。
5. 本脚本只操作当前用户的桌面图标，不修改系统设置、不联网、**不写注册表**。

## 八、兼容性

- Windows 10 / Windows 11（桌面 `SysListView32` 的实现）；
- Windows PowerShell 5.1 或 PowerShell 7+，无需任何额外模块；
- 单屏 / 多屏、100%–200% 缩放均可；不需要管理员权限。

## 九、English summary

**DesktopIconKeeper** keeps your Windows desktop icon layout intact. It saves icon
coordinates (by name, via cross-process `LVM_GETITEMPOSITION` / `LVM_SETITEMPOSITION`)
per display configuration, then restores them automatically whenever the monitor
setup, resolution, DPI or Remote Desktop session changes. Single PowerShell file, no
dependencies, no network access, no registry writes.

## 十、许可证

[MIT](LICENSE)
