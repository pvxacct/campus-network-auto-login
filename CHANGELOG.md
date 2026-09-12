# 更新日志

本项目所有值得记录的改动都会写在这里。
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)，日期格式为 `YYYY-MM-DD`。

## [1.2.0] - 2026-09-12

这一版新增“暂停 / 恢复”入口，想临时停掉自动登录时双击一下就行，不用再翻“任务计划程序”。

### 新增

- `暂停-校园网自动登录.cmd`：双击即可暂停。把计划任务设为“已禁用”，不再自动检查、不再自动登录，自动申请管理员权限。
- `恢复-校园网自动登录.cmd`：双击即可恢复。重新启用计划任务，并在恢复后立刻触发一次检查，如果此时是掉线状态会马上登录。
- `CampusAutoLoginTaskState.ps1`：上面两个入口共用的实现，支持 `-Action Pause|Resume|Status`。
  `Status` 不需要管理员权限，会打印任务状态、检查间隔、最近运行时间与返回码、`state.json` 摘要和最近日志。

### 说明

- 暂停只是禁用计划任务：**凭据（DPAPI 加密）、日志、状态文件全部原样保留**，随时可以恢复；想彻底删除请用 `Uninstall-CampusAutoLoginTask.ps1`。
- 两个 `.cmd` 会自动弹出 UAC 授权窗口；如果被组策略拦下，也可以手动执行
  `powershell -ExecutionPolicy Bypass -File .\CampusAutoLoginTaskState.ps1 -Action Pause`（需要管理员权限）。
- 图形界面等效操作：任务计划程序里右键 `CampusAutoLogin` → “禁用” / “启用”。
- 这一版只增加文件，没有改变计划任务的注册写法，升级后**不需要**重新运行安装脚本。

## [1.1.0] - 2026-09-12

这一版解决了“注册计划任务被 Windows 拒绝”和“脚本看起来根本没在跑”两个主要问题，检查频率改为每 30 秒。

### 修复

- **计划任务注册被系统拒绝**（`The task XML contains a value which is incorrectly formatted or out of range`）。Windows 的任务计划有两条硬性限制：重复间隔最小 1 分钟（`PT30S` 会被拒绝），表示“无限期重复”时必须省略 `<Duration>` 元素（`PT0S` 和 `TimeSpan.MaxValue` 都会被判为超出范围）。现在改为用**两条各 1 分钟、彼此错开 30 秒的触发器**实现 30 秒检查，并保留“补 30 天时长 → 退化成每分钟一次”的降级链。
- **注册完无法确认任务是否真的在跑**。安装脚本现在会读回已注册的触发器、核对真实生效的间隔，再手动启动任务并统计“计划任务自动触发”的次数（默认观察 100 秒）。
- **`-RateLimited $false` 被当成“开关已打开”**。PowerShell 的 `[switch]` 参数即使传 `$false` 也算“存在”，导致限流标记恒为真；已改为 `[bool]` 参数。
- **安装脚本静默失败**。旧版要求用户自己开一个管理员 PowerShell，而 `#Requires -RunAsAdministrator` 会让窗口一闪而过，结果是既没有任务也没有日志。现在统一走自动 UAC 提权。

### 新增

- `Diagnose-CampusAutoLogin.ps1`：一键生成诊断报告（运行环境、Portal 连通性、凭据、日志、计划任务、隐藏启动器），并打印每条触发器的间隔和实际生效的检查间隔。
- `一键安装.cmd`：双击即可安装，自动申请管理员权限。
- 运行状态文件 `state.json`（`RunCount`、`Online`、`LastResult`、`ConsecutiveFailures`、`LastHeartbeat` 等），可用来确认脚本确实在被反复执行。
- 新参数：`-Quiet`、`-CheckOnly`、`-Force`、`-Relogin`、`-DataDir`、`-RetryCount`、`-RetryDelaySec`、`-HeartbeatMinutes`。
- 连续失败退避：连续失败 3 次后按 2 → 30 分钟逐步拉长重试间隔。
- 互斥锁 + 任务级 `IgnoreNew`，避免上一次还没跑完就被下一次叠加。

### 变更

- 检查间隔默认 **每 30 秒**（可通过 `drcom-config.json` 的 `CheckIntervalSeconds` 调整，改完重新运行一次安装脚本）。
- Portal 不可达时只记录状态，不再盲目尝试登录。
- 强制绕过系统代理：内网 Portal 走直连。
- 凭据、日志、状态统一放在 `%LOCALAPPDATA%\CampusAutoLogin`（仍兼容脚本目录下的旧凭据文件，仓库目录可以随意移动）。
- 日志只在状态变化或每小时心跳时写入，不再每 30 秒刷一条。
- 安装自检的观察时长由 80 秒调整为 100 秒。

## [1.0.0] - 2026-09-09

首个公开版本。

### 新增

- `DrcomAutoLogin.ps1`：Dr.COM（哆点）Portal 自动登录，支持 `chkstatus` 在线检测、`login` 提交、`logout` 注销，并把 `userid error2`、`error5 waitsec` 之类的错误码翻译成中文。
- `Save-DrcomCredential.ps1`：用 Windows DPAPI 加密保存账号密码，不以明文落盘。
- `Install-CampusAutoLoginTask.ps1` / `Uninstall-CampusAutoLoginTask.ps1`：注册与卸载计划任务（登录后启动、网络变化触发）。
- `Setup-DrcomAutoLogin.ps1`：一键安装（保存凭据 + 注册任务）。
- `generic/`：给其他学校用的通用版脚本与配置示例。
- `docs/DRCOM-PROTOCOL.md`、`docs/TROUBLESHOOTING.md`：协议说明与常见问题排查。

## 版本对照

| 版本 | 提交 | 日期 |
| --- | --- | --- |
| 1.1.0 | `3c91cb9` | 2026-09-12 |
| 1.0.0 | `075140a` | 2026-09-09 |

1.0.0 与 1.1.0 之间的过程性提交（`5d58cec`、`b4538f0`、`c06986f`、`c30b53f`、`3a1c4a9`）已并入 1.1.0。

## 升级方法

```powershell
cd <你的仓库目录>
git pull
```

升级后必须重新运行一次安装脚本（双击 `一键安装.cmd`，或执行 `Install-CampusAutoLoginTask.ps1`）。
触发器写法、检查间隔、脚本路径有变化时，只替换文件是不会生效的——计划任务里保存的是注册那一刻的内容。
