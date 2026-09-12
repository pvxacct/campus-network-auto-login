# 校园网监控面板

这是一个**独立运行、完全只读**的 Windows 桌面小窗口，用来随时看一眼「校园网自动登录」到底在做什么。
它配合 [campus-network-auto-login](https://github.com/pvxacct/campus-network-auto-login) 使用，
但和自动登录包**分开打包**，可以放在任何地方，删掉自动登录包也不影响它启动。

## 它做什么、不做什么

- ✅ 读取 `%LOCALAPPDATA%\CampusAutoLogin` 里的 `state.json` 与 `login.log`（只读日志末尾 512 KB）；
- ✅ 读取计划任务 `CampusAutoLogin` 的状态、上次运行时间、返回码、下次运行时间；
- ✅ 顺藤摸瓜检查「计划任务 → 隐藏启动器 → 主脚本」三个文件是否都还在；
- ✅ 从日志里统计最近 24 小时的登录次数、成功/失败、限流、重复认证冲突与掉线次数；
- ❌ 不创建、不修改、不删除任何文件；
- ❌ 不注册计划任务、不写启动项、不常驻托盘；
- ❌ 全程不发任何网络请求——**只有**你手动点「立即检查一次」时，才向 Portal 发一次只读的
  `GET /drcom/chkstatus`（相当于问一句“现在在线吗”，不会登录、不会写状态文件）。

## 运行要求

- Windows 10 / 11，系统自带的 Windows PowerShell 5.1（不需要额外安装任何东西）；
- 普通权限即可，不需要管理员；
- 如果自动登录装在别的 Windows 用户下，面板读不到数据目录，需要用 `-DataDir` 指过去。

## 怎么用

1. 解压压缩包，得到一个文件夹；
2. 双击 **`启动监控面板.vbs`**（推荐，完全没有黑框），或者双击 `启动监控面板.cmd`（会留一个命令行窗口）；
3. 窗口每 5 秒自动刷新一次，看完直接点「关闭」。

也可以命令行启动，方便排查问题：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CampusNetworkMonitor.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\CampusNetworkMonitor.ps1 -DumpOnce     # 不开窗口，打印一次状态
powershell -NoProfile -ExecutionPolicy Bypass -File .\CampusNetworkMonitor.ps1 -SelfTest     # 冒烟测试：建窗口、刷新一次、退出
powershell -NoProfile -ExecutionPolicy Bypass -File .\CampusNetworkMonitor.ps1 -DataDir "D:\somewhere\CampusAutoLogin"
```

## 窗口里有什么

| 区域 | 内容 |
| --- | --- |
| 顶部横幅 | 一句话结论，颜色区分：灰=没装/未知，红=有问题，橙=冷却中，黄=正在重连，绿=一切正常 |
| 指标区 | 最近触发时间、最近真实查询、在线状态、最近结果、连续失败次数、冷却到点与原因、本地判断方式、计划任务状态与返回码、下次运行、数据目录、`state.json` 修改时间、已安装脚本版本 |
| 路径体检 | 「计划任务 → 隐藏启动器 → 主脚本」三步逐个检查，任何一步的文件或起始目录不见了就红字提示「僵尸任务」 |
| 日志区 | `login.log` 的最近 200 行，等宽字体，警告橙色、错误红色，可勾选「只看警告和错误」 |
| 按钮 | 立即检查一次 / 刷新 / 打开数据目录 / 复制诊断信息 / 关闭 |

最后，如果你想联网检查一下：点「立即检查一次」——它只发一次状态查询，按钮随后禁用 5 秒防止手快连点。

## 配置（`monitor-config.json`）

文件是可选的，缺省或删掉都能跑。所有键都有默认值：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `RefreshSeconds` | `5` | 界面自动刷新间隔（秒） |
| `StatsWindowHours` | `24` | 统计窗口小时数 |
| `PortalHost` | `""` | Portal 地址，留空则自动解析（见下） |
| `StatusPath` | `/drcom/chkstatus` | 状态查询路径 |
| `StatusTimeoutSec` | `8` | 「立即检查一次」的超时秒数 |
| `DataDir` | `""` | 数据目录，留空则用 `%LOCALAPPDATA%\CampusAutoLogin` |

Portal 地址的解析顺序：

1. 计划任务指向的主脚本所在目录里的 `drcom-config.json`（也就是自动登录真正在用的那个地址）；
2. 面板自己的 `monitor-config.json` 里的 `PortalHost`；
3. 内置默认值 `10.66.209.2`。

## 常见问题

**横幅显示「脚本未在运行」？** `state.json` 超过 180 秒没更新，说明计划任务没在跑。看「路径体检」那一行：
如果是红色的「僵尸任务」，说明安装目录被删/被移走了，把文件夹放回原位或者重新运行一次一键安装即可。

**指标区显示「没有找到计划任务」？** 自动登录还没安装，或者装在了另一个 Windows 用户下。

**日志是空的？** 还没生成 `login.log`（脚本只在真的要检查/登录时才写日志），等它跑一次就好了。

## 版本

面板自身版本 `1.0.0`，随自动登录 `v1.6.0` 一起发布，窗口标题会同时显示两者。
默认约定：主脚本版本低于 `1.5.1` 时，「已安装脚本版本」会标黄提醒升级。
