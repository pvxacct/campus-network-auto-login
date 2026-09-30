# 校园网自动登录 2.2.0-pre.1（Dr.COM / 哆点）

Windows 下的校园网 Portal 自动登录工具。**一个单文件 exe 同时管两件事：自动登录 + 网络状态面板。**

运行要求：Windows 10/11 + .NET Framework 4.8。程序是单文件 EXE，不需要另装 .NET 运行时。

> **预发布**：本版是 `2.2.0-pre.1` Pre-release，重点是「提交登录之后不再空等」。默认参数与风控红线沿用 2.1.2，速度收益请以本机自然掉线的日志为准。

[![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D6)](https://www.microsoft.com/windows/)
[![.NET Framework](https://img.shields.io/badge/.NET%20Framework-4.8-512BD4)](https://dotnet.microsoft.com/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

## 快速开始

1. 到 [Releases](https://github.com/pvxacct/campus-network-auto-login/releases) 下载 **CampusNet-v2.2.0-pre.1.exe**，并核对页面上的 SHA256。
2. 双击运行。首次启动可能弹 SmartScreen（程序没有购买数字签名），点「更多信息 → 仍要运行」。
3. 在窗口里的「账号」卡片填校园网账号和密码，点 **保存账号密码**。密码用 Windows DPAPI 加密，只有当前 Windows 用户能解开。
4. 点 **安装**：程序把自己复制到 `%LOCALAPPDATA%\Programs\CampusNet\`、创建快捷方式、开启开机自启。
5. 关掉窗口就行，程序收进右下角托盘继续守着。要彻底退出：右键托盘图标 → **退出**（会二次确认）。

> 机器上若还留着 1.x 的 PowerShell 版，「程序」卡片会提示，点 **清理旧版残留** 一键删掉旧计划任务与脚本目录（只有这一步需要一次 UAC）。

## 这一版改了什么

2.1.2 的问题不是「登录慢」——实测 137 次登录请求的接口返回都在 0.4 秒内——而是**提交之后的等待方式**：等 Portal、等探测、再等下一轮，串行叠加，所以「提交 → 记录恢复」要 6~36 秒（中位 19.5 秒）；而且旧版部分路径只要 Portal 说会话在线就记为恢复成功，并不代表真的能上网。

2.2.0-pre.1 改成：

- **登录响应一到就开始 30 秒观察窗口**，不再先睡一觉再检查；
- **内容校验每 2 秒安排一轮**，每轮有截止时间，最多一个在途任务，慢轮次结束后再排下一轮；
- **Portal 查询独立调度**：观察开始后第 2、5、9、14、20、23 秒各一次，最多六次，错过档位就跳过、不集中补发；
- **内容校验成功立即确认恢复**，不等待慢 Portal；已被取消的目标标为「未完成」，不算失败、不算丢包；
- **Portal 会话在线不再等于联网恢复**：配置了 HTTP 内容目标时，必须真的取回预期内容或拿到预期状态码；只有 TCP/ICMP 的旧配置需「探测通过 + 会话在线」，并在日志里写明「未验证内容」；
- **所有重登入口统一过闸门**：凭据、暂停、最小间隔、每小时上限都检查通过才允许注销，不再先注销再发现被限频；
- **同一段故障最多自动注销重登一次**，真的恢复之后才重新开放；
- **热重载不再覆盖实时计数**：界面编辑走独立副本，保存重载后才生效，并取消上一次流程；
- 状态文件写入串行化，替换失败保留原文件；`--selftest` 不再启动真实登录、崩溃重启注册或守护进程。

## 主要特性

**平时几乎不打扰**

- 默认每 **20 秒** 做一次本地探测，全程**不发 Portal 请求**；在线时每 **120 秒** 只读核对一次会话；
- 判定「能不能上网」以**内容校验**为准——真的取回指定网页文本，或核对 204 状态码，TCP / ICMP 只做兜底。有的校园网关会替任意 TCP 连接代答握手（连不存在的地址也能 0 ms「连上」），只看握手会被骗；
- 内容目标任一成功即可返回，其余目标取消并标为「未完成」。

**掉线发现得快**

- 订阅系统网络变化事件（网线插拔 / WiFi 切换 / IP 变化），1 秒防抖后立刻复检，不必等下一个探测周期；
- 内容没过就按异常节奏复探（默认每 **5 秒**）；连续两轮拿不到内容才去核对 Portal，中间还有一次立即补测，单次抖动会被挡掉；
- 在线时每 120 秒只读核对一次 Portal 会话（`SessionCheckSeconds`），Portal 说不在线就直接进入登录流程——这是「被踢下线」最主要的发现途径。

**确认恢复不空等**

- 保留默认在线 20 秒、异常 5 秒、会话核对 120 秒的频率，以及登录前 1 秒二次确认；
- 登录响应返回后立刻开始 30 秒恢复观察：内容校验每 2 秒一轮，Portal 六个独立档位，各自最多一个在途任务；
- 内容验证成功即确认恢复；窗口结束后继续按异常频率监视，日志记录「提交 → 验证通过」的实际经过时间（单调时钟，不含休眠累加）。

**限制登录频率，避免误报恢复**

- 自动登录、残留会话重登、手动「立即重连」统一检查凭据、暂停和限频，通过后才允许注销；
- 默认两次登录至少间隔 **60 秒**、每小时最多 **12 次**；按每次 POST 计数，发送前先持久化。进程在持久化后被打断时，可能保守多占一次额度；
- Portal 业务提示保留原始 `Msg` / `msga` 便于排障，是否恢复仍由探测验证；
- 暂停、退出、配置重载会取消旧请求，旧结果不能覆盖新状态；登录请求禁止自动跳转，配置损坏时停止自动登录。

**看得见、量得出**

- 托盘图标颜色跟着状态变；面板上有 IP / 网关 / 网卡 / DNS / 延迟 / 丢包、最近 60 次探测的延迟柱状图、运行统计和实时日志；
- 界面「日志」卡片的「清除显示」只清空显示，不删本机日志文件；真正删除历史日志用 `--clear-log`。

## 探测目标格式

`ProbeTargets` 里的每一项按下面的格式写：

| 写法 | 含义 |
| --- | --- |
| `http:主机/路径\|期望文本` | 直连取回内容，HTTP 2xx **且**响应体含期望文本才算通过（也支持 `https:`） |
| `http:主机/路径\|204` | 期望状态码模式：拿到该状态码即通过 |
| `tcp:主机:端口` | 只需 TCP 能握手（兜底，易被代答网关骗过） |
| `icmp:主机` | Ping 通即可（兜底） |

默认四条：小米 204、百度 `robots.txt`、微软 `connecttest.txt` 三个内容校验目标，加 `tcp:223.5.5.5:443` 兜底。HTTP 请求不走系统代理、不跟随跳转，3xx 一律算失败。

## 命令行

```text
CampusNet.exe --tray                     后台托盘模式（开机自启用它）
CampusNet.exe --status                   打印一次当前状态后退出
CampusNet.exe --diagnose [--with-log]    诊断信息（加 --with-log 带日志尾部）
CampusNet.exe --once                     跑一轮检查后退出
CampusNet.exe --relogin                  注销后重新登录（等完整流程跑完再退出）
CampusNet.exe --run-seconds 25           前台运行指定秒数
CampusNet.exe --set-credentials <账号> [--password-stdin]
                                         保存账号；密码走标准输入，别写在命令行里
CampusNet.exe --install                  安装到 %LOCALAPPDATA%\Programs\CampusNet
CampusNet.exe --uninstall [--check-only] 卸载（--check-only 只打印计划，不删东西）
CampusNet.exe --cleanup-legacy           清理 1.x 残留（需要一次 UAC）
CampusNet.exe --clear-log                删除本机历史日志文件
CampusNet.exe --selftest                 界面自检（不登录、不启动守护）
CampusNet.exe --watchdog --check-only    只检查守护判定，不重启进程
CampusNet.exe --version
CampusNet.exe --data-dir <路径>          自定义数据目录（守护会一并透传）
```

退出码：`0` 成功 / `1` 失败 / `2` 配置或凭据有问题。

## 高级配置

`%LOCALAPPDATA%\CampusNet\config.json`（界面「高级设置」也能改，保存后立即生效）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `PortalHost` | `10.66.209.2` | Portal 地址（可带端口；写成 `https://…` 也可以） |
| `PortalScheme` | `http` | Portal 协议：`http` / `https` |
| `StatusPath` / `LoginPath` / `LogoutPath` | `/drcom/chkstatus` 等 | 接口路径 |
| `OnlineProbeSeconds` | `20` | 网络正常时的探测间隔 |
| `OfflineProbeSeconds` | `5` | 探测异常后的复检间隔 |
| `UpstreamProbeSeconds` | `300` | 全部本地探测失败、Portal 会话在线时的会话查询间隔；本地仍按异常频率检查 |
| `ProbeTargets` | 3 个内容校验目标 + 1 个 TCP 目标 | 判断「能不能上网」的目标（并行执行），格式见上文 |
| `ProbeTimeoutMs` / `HttpProbeTimeoutMs` | `1500` / `3000` | TCP·ICMP 与 HTTP 各自的单目标超时（毫秒） |
| `ConfirmAttempts` / `ConfirmGapMs` | `2` / `500` | 判定断网前的复检轮数与间隔 |
| `LoginConfirmDelaySec` | `1` | 登录前二次确认的等待秒数（确认前先做一次纯本地内容校验，本地能上网就直接跳过登录） |
| `LoginMinIntervalSeconds` | `60` | 两次登录之间的硬性最小间隔 |
| `LoginHourlyLimit` | `12` | 每小时登录次数上限 |
| `RetryCount` | `1` | 一次触发内最多提交几次登录；每次提交前都会重新检查最小间隔与每小时上限 |
| `SessionCheckSeconds` | `120` | 在线时只读核对 Portal 会话的间隔（`0` = 关闭） |
| `StuckReloginSeconds` | `60` | 本机连续不通但 Portal 说在线，超过这个秒数就自动注销重登（`0` = 关闭） |
| `StaticFields` | `0MKKey=123456` 等 | 登录表单固定字段（不同学校可能不同） |
| `ConfigVersion` | `9` | 配置结构版本，自动迁移：只改「等于旧默认值」的那一份，自己填过的值一律保留 |

## 已知限制

- 本工具只实现现有的明文表单协议；学校若要求 `en_md5=1` 的加密流程，仍需专门适配。单凭 `userid error2` 不能判定密码错误或加密模式。
- 「今日登录」「恢复耗时」两行界面统计在本版仍是占位，实际的提交/确认耗时看日志。
- 一直显示在线却上不了网、或者日志里反复出现「内容校验未通过」，见 [故障排查](docs/TROUBLESHOOTING.md)。

## 从 1.x 升级

- 1.x 的计划任务 `CampusAutoLogin`、脚本目录 `C:\CampusAutoLogin`、旧数据目录 `%LOCALAPPDATA%\CampusAutoLogin` 都可以由 2.x 的 **清理旧版残留** 处理（旧数据目录默认保留，可手动删除）。
- 账号密码不会自动迁移，重新输入一次即可。
- 1.x 的历史版本仍在 Releases 里，可以随时回退；1.x 的收官版本是 **1.9.0**（功能冻结，仍可下载）。

## 源码与构建

```
src/CampusNet/              C# 源码（App.xaml、MainWindow.xaml、Core/*.cs、UI/TrayIcon.cs、Assets/app.ico）
build/Build-CampusNet.ps1   一键编译：产出 dist\CampusNet.exe、SHA256 与源码指纹，并跑两套测试
build/Test-CampusNet.ps1    端到端测试：本地假 Portal 验证探测、登录、风控闸门、界面结构
build/Test-Recovery.ps1     恢复时延、取消、并发与请求数量回归
build/RecoveryTests/        net48 行为测试项目（C# 并发假 Portal）
build/FakePortal.ps1        测试用的假 Portal（只监听 127.0.0.1）
dist/CampusNet.exe          已编译好的单文件 exe（随仓库提交，也是发布附件）
docs/                       协议说明、故障排查、使用说明、恢复验证报告
```

构建要求：Windows + .NET 8 SDK + .NET Framework 4.8 引用程序集，目标框架 `net48`，零第三方 NuGet 依赖。

```powershell
powershell -ExecutionPolicy Bypass -File build\Build-CampusNet.ps1            # 编译 + 两套测试
powershell -ExecutionPolicy Bypass -File build\Build-CampusNet.ps1 -SkipTests # 只编译
```

## 文档

- [使用说明](docs/使用说明.md) — 面向使用者的一步步说明
- [故障排查](docs/TROUBLESHOOTING.md) — 连不上、被风控、杀软拦截等情况的处理
- [恢复优化与测试报告](docs/RECOVERY-VALIDATION.md) — 本版的实测数据、调度设计与测试结论
- [Dr.COM ePortal 协议说明](docs/DRCOM-PROTOCOL.md) — 抓包、接口、错误码与适配其他学校
- [更新日志](CHANGELOG.md)

## 许可

[MIT](LICENSE)
