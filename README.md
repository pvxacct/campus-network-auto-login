# 校园网自动登录 2.0（Dr.COM / 哆点）

Windows 下的校园网 Portal 自动登录工具。2.0 把「自动登录」和「网络监控面板」合并成**一个单文件 exe**：
双击就能用，没有 PowerShell 脚本、没有计划任务、不需要管理员权限、不需要安装任何运行时。

[![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D6)](https://www.microsoft.com/windows/)
[![.NET Framework](https://img.shields.io/badge/.NET%20Framework-4.8-512BD4)](https://dotnet.microsoft.com/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## 它解决什么问题

校园网账号隔几个小时会被踢下线，人不在电脑前就一直断网。2.0 的做法是：

- **网络正常时几乎不发请求**：只做本地探测（TCP 连接 + ICMP），**完全不碰 Portal**，不查状态、不登录；
- **断网时秒级重连**：探测失败 1 秒内连试多次，确认断开才去查 Portal 并自动登录；
- **不触发风控**：登录前二次确认、两次登录至少间隔 60 秒、每小时最多 12 次，遇到限流或「账号已在别处在线」立刻冷却 30 分钟；
- **看得见**：托盘图标颜色跟着状态变，仪表盘上有 IP／网关／DNS／延迟／丢包、运行统计和实时日志。

## 下载与首次使用

1. 到 [Releases](../../releases) 下载 `CampusNet.exe`（2.0 的发布只有这一个文件；源码在仓库 `main` 分支，详细说明见 [docs/使用说明.md](docs/使用说明.md)）。
2. 双击 `CampusNet.exe`。首次运行可能出现 Windows SmartScreen 提示（程序没有花钱买数字签名），
   点「更多信息 → 仍要运行」即可。
3. 在窗口右上「账号」卡片里填校园网账号和密码，点 **保存账号密码**。
   密码用 Windows DPAPI 加密，只有当前 Windows 用户能解密，不会明文落盘。
4. 点 **安装**：程序会把自己复制到 `%LOCALAPPDATA%\Programs\CampusNet\`、创建开始菜单快捷方式并开启开机自启。
5. 关闭窗口即可，程序会收进右下角托盘继续守护；要彻底退出请右键托盘图标 → 退出（会二次确认）。

> 如果机器上还留着 1.x 的 PowerShell 版，程序会在「程序」卡片里提示，点 **清理旧版残留** 一键删除
> 旧的计划任务与脚本目录（只有这一步需要一次 UAC 确认）。

## 界面说明

| 区域 | 内容 |
| --- | --- |
| 顶部状态横幅 | 在线 / 重连中 / 冷却中 / 已暂停 / 未配置，颜色一眼可辨 |
| 网络状态 | 本机 IP、网关、网卡、DNS、延迟、丢包，以及最近 60 次探测的延迟柱状图 |
| 账号 | 账号密码输入与保存（已保存的账号只显示前三位） |
| 运行统计 | 最近探测 / 最近登录时间、最近结果、本小时登录次数、连续失败、冷却、最近错误 |
| 程序 | 开机自启开关、安装 / 卸载、打开数据目录、清理旧版残留、高级设置 |
| 运行日志 | 最近 200 行，WARN / ERROR 着色，可只看异常 |
| 底部按钮 | 立即重连、暂停 30 分钟、恢复、刷新、复制诊断信息、关闭窗口 |

托盘图标右键菜单：打开面板、立即重连、暂停 30 分钟、恢复自动登录、退出。

## 工作原理

```
        ┌──────────── 常驻进程（托盘） ────────────┐
        │ 触发：网络变化事件 / 休眠唤醒 / 解锁 / 定时 │
        └───────────────────┬──────────────────────┘
                            ▼
              本地探测：TCP(223.5.5.5:443 等) + ICMP
                    ┌───────┴────────┐
                  能通              不通
                    │                │
             状态=在线，结束     1 秒内连试多次，仍不通
             （0 个 Portal 请求）        │
                                        ▼
                          GET /drcom/chkstatus（只有这时才查 Portal）
                            ┌───────────┴────────────┐
                         result=1                 result=0
                            │                        │
                    Portal 认为在线            等 3 秒二次确认
                    （记为上游异常，            仍离线 → POST /drcom/login
                      5 分钟后复查）                    │
                                                登录成功 → 复探确认
```

- 正常联网时**每小时最多 60 次本地探测**（默认每 60 秒一次），Portal 请求为 **0**；
- 异常时每 5 秒探测一次，尽快把网络拉回来；
- 网卡切换、插拔网线、休眠唤醒、解锁都会立即触发一次评估，不必等到下一个周期。

## 数据与隐私

所有数据都在 `%LOCALAPPDATA%\CampusNet\`：

| 文件 | 内容 |
| --- | --- |
| `credentials.dat` | 账号 + DPAPI 加密后的密码（只有当前 Windows 用户能解密） |
| `config.json` | Portal 地址、探测节奏、风控闸门等配置（首次运行自动生成） |
| `state.json` | 当前状态快照（在线与否、最近结果、冷却、累计检查次数） |
| `login.log` | 运行日志，超过 5 MB 自动滚动为 `login.log.old` |

程序不会上传任何数据，除校园网 Portal 外只做本地探测；Portal 请求显式绕过系统代理。

## 命令行（排障 / 自动化）

双击是普通用法，命令行参数用于排查和脚本化：

```
CampusNet.exe                 打开仪表盘并开始守护（也是双击的默认行为）
CampusNet.exe --tray          只进托盘，不弹窗口（开机自启用的就是它）
CampusNet.exe --status        打印当前状态一行行摘要
CampusNet.exe --diagnose      打印完整诊断信息（加 --with-log 附带日志尾部）
CampusNet.exe --relogin       立即注销并重新登录
CampusNet.exe --once          前台跑一轮检查后退出（用于验证）
CampusNet.exe --run-seconds N 前台跑 N 秒后退出
CampusNet.exe --install       安装到用户目录并开启开机自启
CampusNet.exe --uninstall     卸载（加 --delete-data 连数据一起删）
CampusNet.exe --set-credentials <账号> <密码>
CampusNet.exe --selftest      界面自检（构建窗口、刷新一次后退出）
CampusNet.exe --version
```

退出码：`0` 成功 / `1` 失败 / `2` 配置或凭据有问题。

## 高级配置

`%LOCALAPPDATA%\CampusNet\config.json`（界面「高级设置」也能改，改完立即生效）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `PortalHost` | `10.66.209.2` | Portal 地址（不带 `http://`，可带端口） |
| `StatusPath` / `LoginPath` / `LogoutPath` | `/drcom/chkstatus` 等 | 接口路径 |
| `OnlineProbeSeconds` | `60` | 网络正常时的探测间隔 |
| `OfflineProbeSeconds` | `5` | 探测异常后的复检间隔 |
| `ProbeTargets` | 3 个公网 TCP 目标 | 判断「能不能上网」的目标，可换成自己学校的 |
| `ConfirmAttempts` / `ConfirmGapMs` | `3` / `1000` | 判定断网前的连试次数与间隔 |
| `LoginConfirmDelaySec` | `3` | 登录前二次确认的等待秒数 |
| `LoginMinIntervalSeconds` | `60` | 两次登录之间的硬性最小间隔 |
| `LoginHourlyLimit` | `12` | 每小时登录次数上限 |
| `LoginCooldownMinutes` | `30` | 限流 / 冲突后的冷却时长 |
| `StaticFields` | `0MKKey=123456` 等 | 登录表单固定字段（不同学校可能不同） |

## 从 1.x 升级

- 1.x 的计划任务 `CampusAutoLogin`、脚本目录 `C:\CampusAutoLogin`、旧数据目录
  `%LOCALAPPDATA%\CampusAutoLogin` 都可以由 2.0 的「清理旧版残留」处理（旧数据目录默认保留，可手动删除）。
- 账号密码不会自动迁移，重新输入一次即可。
- 1.x 的历史版本仍在 Releases 里，可以随时回退；1.x 的收官版本是 **1.9.0**（功能冻结，仍可下载）。

## 源码与构建

```
src/CampusNet/           C# 源码（App.xaml、MainWindow.xaml、Core/*.cs、UI/TrayIcon.cs、Assets/app.ico）
build/Build-CampusNet.ps1  一键编译：产出 dist\CampusNet.exe 与 SHA256，并跑一遍端到端测试
build/Test-CampusNet.ps1   端到端测试：本地假 Portal 验证探测、登录、风控闸门
build/FakePortal.ps1       测试用的假 Portal（只监听 127.0.0.1）
dist/CampusNet.exe       已编译好的单文件 exe（随仓库提交，也是发布附件）
docs/                    协议说明、故障排查、使用说明
```

构建要求：Windows + .NET SDK（或 Visual Studio 的 MSBuild），目标框架 `net48`，零第三方 NuGet 依赖。

```powershell
powershell -ExecutionPolicy Bypass -File build\Build-CampusNet.ps1          # 编译 + 测试
powershell -ExecutionPolicy Bypass -File build\Build-CampusNet.ps1 -SkipTests
```

## 文档

- [使用说明](docs/使用说明.md) — 面向使用者的一步步图文说明
- [故障排查](docs/TROUBLESHOOTING.md) — 连不上、被风控、杀软拦截等情况的处理
- [Dr.COM ePortal 协议说明](docs/DRCOM-PROTOCOL.md) — 抓包、接口、错误码与适配其他学校
- [更新日志](CHANGELOG.md)

## 许可

[MIT](LICENSE)
