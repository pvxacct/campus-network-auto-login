# 校园网自动登录（Dr.COM / 哆点）

Windows 下的校园网 Portal 自动登录工具。**每 30 秒**检查一次在线状态，掉线后自动重新认证；支持开机自启、网络切换立即触发、后台静默运行（不会弹黑窗口），账号密码使用 Windows DPAPI 加密保存。

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://learn.microsoft.com/powershell/)
[![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D6)](https://www.microsoft.com/windows/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## 功能

- **掉线自动重连**：默认每 30 秒查询一次 Portal 在线状态，掉线后自动提交账号密码；
- **开机自启**：登录 Windows 后 15 秒自动开始检查，无需手动运行；
- **网络变化触发**：切换 Wi-Fi、插拔网线、网络配置文件变化时立即检查；
- **后台静默**：任务通过自动生成的隐藏启动器运行，不会每 30 秒闪一次黑窗口；
- **密码加密**：使用 Windows DPAPI 加密保存，只有当前 Windows 用户能解密，不入库、不明文落盘；
- **失败退避**：连续登录失败会自动进入冷却（2 分钟起，最多 30 分钟），不会反复撞 Portal；
- **防重入**：上一次检查没结束时，新的触发会被跳过，不会叠加执行；
- **可观测**：每次运行都会写入 `state.json`（运行次数、当前状态、最近结果），一眼就能看出脚本有没有在跑；
- **错误翻译**：调用 Portal 的错误码接口，把 `userid error2` 之类的代码翻译成可读提示；
- **一键安装 / 一键诊断**：双击 `一键安装.cmd` 即可完成；出问题跑一次诊断脚本生成报告。
- **一键暂停 / 恢复**：双击 `暂停-校园网自动登录.cmd` 随时停掉自动检查，双击 `恢复-校园网自动登录.cmd` 一键恢复并立即检查一次。
- **断网才触发**：平时只用本地方式判断能不能上网（**不发任何请求**），发现连不上网才去查 Portal、自动登录；登录请求还有每小时上限，避免账号被 Portal 风控。
- **登录侧保险**：登录前二次确认、两次登录至少间隔 60 秒、遇到限流或「账号已在线」冲突立刻冷却 30 分钟——不会因为一次误判就把你正在用的会话顶掉。

## 工作原理

```mermaid
flowchart TD
    A[计划任务触发<br/>登录时 / 每 30 秒 / 网络变化] --> B[静默启动器 run-hidden.vbs]
    B --> B2{本地判断能不能上网<br/>不发任何请求}
    B2 -- 能上网 --> B3[退出，不请求 Portal<br/>每 300 秒兜底巡检一次]
    B2 -- 连不上网 --> C[GET /drcom/chkstatus]
    C -- result = 1 --> D[已在线，退出]
    C -- 访问失败 --> E[不尝试登录，等下一次触发]
    C -- result = 0 --> F[POST /drcom/login]
    F --> G{解析返回页}
    G -- Dr.COMWebLoginID_3.htm --> H[等待 2 秒后复检]
    G -- Dr.COMWebLoginID_2.htm --> I[解析错误码并写日志]
    H -- result = 1 --> J[登录成功]
    H -- result = 0 --> I
```

> 本项目针对 **Dr.COM（哆点）ePortal** 适配。其他学校的 Portal 可参考 [`generic/`](generic/) 下的通用版本。

## 快速开始

### 1. 下载

```powershell
git clone https://github.com/pvxacct/campus-network-auto-login.git
cd campus-network-auto-login
```

或者直接点击 GitHub 页面右上角的 **Code → Download ZIP**，解压后进入目录。

> 如果本机 Git 报 `schannel: SEC_E_NO_CREDENTIALS`，可以改用 OpenSSL 后端：
>
> ```powershell
> git -c http.sslBackend=openssl -c http.sslVerify=false clone https://github.com/pvxacct/campus-network-auto-login.git
> ```
>
> 或者使用 SSH：
>
> ```powershell
> git clone git@github.com:pvxacct/campus-network-auto-login.git
> ```

### 2. 改 Portal 地址（非本项目学校才需要）

打开 `drcom-config.json`，把 `PortalHost` 改成你学校的 Portal 地址：

```json
{
  "PortalHost": "10.66.209.2",
  "EportalPort": 801,
  "StatusPath": "/drcom/chkstatus",
  "LoginPath": "/drcom/login",
  "CheckIntervalSeconds": 30
}
```

如果不知道地址和字段，请参考 [`docs/DRCOM-PROTOCOL.md`](docs/DRCOM-PROTOCOL.md)，用浏览器开发者工具抓一次登录请求。

### 3. 一键安装

**双击 `一键安装.cmd`**，在弹出的 UAC 窗口点“是”，然后按提示输入一次校园网账号密码。

脚本会自动完成：

1. 申请管理员权限（UAC 弹窗一次）；
2. 提示输入账号密码，用 DPAPI 加密保存到 `%LOCALAPPDATA%\CampusAutoLogin\credential.xml`；
3. 注册计划任务 `CampusAutoLogin`（登录时启动、每 30 秒检查、网络变化触发）；
4. **实际观察 80 秒**，确认任务真的被自动执行了（自检）；
5. 立即检查一次当前在线状态。

自检通过会显示：

```text
自检通过：80 秒内脚本被自动执行了 3 次（运行方式：vbs），任务已正常工作。
```

### 4. 确认一切正常（可选）

```powershell
# 只看状态，不做任何登录
powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -CheckOnly

# 看运行状态：RunCount 会随时间不断变大
Get-Content "$env:LOCALAPPDATA\CampusAutoLogin\state.json"

# 看日志
Get-Content "$env:LOCALAPPDATA\CampusAutoLogin\login.log" -Tail 30
```

## 手动安装（不用一键脚本）

```powershell
# 1) 保存账号密码（可以在普通权限下运行）
powershell -ExecutionPolicy Bypass -File .\Save-DrcomCredential.ps1

# 2) 注册计划任务（会自动申请管理员权限）
powershell -ExecutionPolicy Bypass -File .\Install-CampusAutoLoginTask.ps1

# 3) 立即检查一次
powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1
```

## 手动测试

```powershell
# 查询状态，掉线才登录
powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1

# 只查询状态，不登录
powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -CheckOnly

# 强制登录一次（不判断是否已在线）
powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -Force

# 先注销当前会话，等 5 秒后重新登录
powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -Relogin
```

## 出问题了先跑诊断

```powershell
powershell -ExecutionPolicy Bypass -File .\Diagnose-CampusAutoLogin.ps1
```

它会检查运行环境、Portal 连通性、凭据、日志、计划任务、隐藏启动器，并把结果保存成
`%LOCALAPPDATA%\CampusAutoLogin\diagnose-<时间>.txt`。

## 监控面板（可选）

不想每次都去翻 `state.json` 和日志？下载 Release 里的 **`campus-network-monitor-<版本>.zip`**，解压后双击
**`启动监控面板.vbs`**，就会打开一个小窗口，把所有状态一眼看完（v2 起改用 WPF 绘制，浅色现代界面、
圆角卡片、无边框标题栏）：

- **顶部横幅**用颜色直接给结论：绿＝正常在线，黄＝正在重连，橙＝冷却中（限流/重复认证冲突），红＝凭据问题或脚本没在跑；
- **指标卡片**分成「运行状态 / 计划任务与路径体检 / 网络 / 数据与统计」四张卡，显示最近触发时间、最近真实查询、在线状态、连续失败次数、冷却到点与原因、计划任务状态与返回码、下次运行时间、已安装脚本版本（低于 1.5.1 会标黄提示升级）；
- **路径体检**顺着「计划任务 → 隐藏启动器 → 主脚本」逐个检查，任意一环的文件或起始目录不见了，就会红字提示**僵尸任务（返回码 0x8007010B）**——上次 D 盘目录被删掉的那种故障，一眼可见；
- **延迟趋势**把到**网关**和 **Portal** 的延迟画成折线（丢包位置标红点），**连通状态**用一排小方块显示最近 60 次刷新的结论，颜色和顶部横幅一致；
- **网络区**显示本机 IP 与网卡（含速率）、默认网关、网络名称与类别、DNS 服务器，以及实时延迟与最近若干次的平均／最小／最大延迟、丢包率（`PingEnabled=false` 可关闭）；
- **日志区**显示 `login.log` 最近 200 行，警告橙色、错误红色，可勾选「只看警告和错误」；
- **按钮**：立即检查一次（只发一次状态查询，不登录、不写文件）、刷新、打开数据目录、复制诊断信息、关闭。

面板**只读**：不写任何文件、不注册任务、不常驻托盘；网络行为只有两项——默认每 10 秒一次 ICMP ping
（网关 + Portal，用来算延迟，不走 HTTP、不碰登录接口、不影响风控），以及手动点「立即检查一次」时向 Portal
发一次 `chkstatus` 只读查询。折线图和时间线的数据只存在内存里，面板一关就没了。它打包在单独的 zip 里，
和自动登录包互不依赖，可以放在任意目录。

详细说明见 [`monitor/README.md`](monitor/README.md)。

### 以后会和主包合并吗

会——这一版（`v1.8.0-pre.1`）先把面板重写好、把约定写清楚，真正合并留到后面的正式版本。约定是：

- 面板文件整体放在主包的 `monitor\` 目录下，入口固定为 `monitor\启动监控面板.vbs`；
- 面板不依赖自己的路径：Portal 地址按「计划任务动作链指向的主脚本目录 → 面板自己的 `monitor-config.json` → 内置默认值」解析，所以放在哪个目录都能用；
- 面板永远只读（不写文件、不注册任务），放进主包不会影响自动登录的任何行为；
- 合并时只需在主包的一键安装脚本末尾加一句可选的「是否打开监控面板」，面板代码不用改。

细则见 [`monitor/README.md`](monitor/README.md) 的「与主包合并的约定」。

## 配置说明

`drcom-config.json`：

| 字段 | 说明 |
| --- | --- |
| `PortalHost` | Portal 地址，例如 `10.66.209.2` |
| `EportalPort` | ePortal 端口，Dr.COM 常见为 `801` |
| `StatusPath` | 状态查询路径，默认 `/drcom/chkstatus` |
| `LoginPath` | 登录路径，默认 `/drcom/login` |
| `LogoutPath` | 注销路径，默认 `/drcom/logout` |
| `ErrorPromptPath` | 错误码翻译接口路径 |
| `CheckIntervalSeconds` | 计划任务检查间隔，默认 30 秒（改成 60 等数值后重新运行安装脚本） |
| `OnlineCheckIntervalSeconds` | 能上网时的**兜底巡检**间隔，默认 300 秒。平时脚本靠本地网络状态判断，只有连不上网才会去查 Portal；这个值决定“能上网时”每隔多久仍然查一次，防止系统联网状态判断滞后。设 `0` = 能上网时完全不查（请求最少），设负数 = 每次触发都查 |
| `LoginHourlyLimit` | 最近 1 小时内最多发起多少次登录请求，默认 12 次；超过就跳过登录并等下一个小时窗口，防止账号被风控。改成 `0` 表示不限制 |
| `LoginConfirmDelaySec` | 判定“离线”后先等几秒再复检，**两次都离线才登录**，默认 3 秒。避免抓到瞬时/陈旧的离线结果就把正在使用的会话顶掉 |
| `LoginMinIntervalSeconds` | 两次登录请求之间的硬性最小间隔，默认 60 秒。网络抖动、开机触发、网络变化事件连续触发时也不会连打登录 |
| `LoginCooldownMinutes` | Portal 明确限流（`error5 waitsec` / `Error code 205`）或「账号已在别处在线」冲突后的冷却时长，默认 30 分钟；冷却期间只查状态、不登录 |
| `StaticFields` | 登录时必须一起提交的固定字段 |

## 计划任务

安装后可在“任务计划程序”中看到 `CampusAutoLogin`：

| 项目 | 说明 |
| --- | --- |
| 触发器 | 登录 Windows 后 15 秒、两条错开的 1 分钟触发器（等效每 30 秒一次）、网络配置文件变化（Event ID 10000） |
| 运行方式 | 当前用户、普通权限（不需要管理员，不会弹 UAC） |
| 启动命令 | `wscript.exe //B //Nologo "%LOCALAPPDATA%\CampusAutoLogin\run-hidden.vbs"` |
| 并发策略 | `IgnoreNew`（上一次没跑完就跳过本次） |
| 电源策略 | 电池供电时也运行、不因为切换电源而停止、错过的触发会尽快补上 |

> Windows 的任务计划管理器对触发器写法有两条硬性限制：重复间隔**最小 1 分钟**（写 `PT30S` 会直接注册失败），表示“无限期重复”时必须**省略 `<Duration>` 元素**（写 `PT0S` 或超大数值都会被判为 out of range）。所以安装脚本默认用 **两条各 1 分钟、彼此错开 30 秒的触发器**来实现 30 秒检查，并在安装时打印实际生效的间隔。如果某台机器连这种写法都不接受，脚本会自动降级（先补 30 天时长，再退化成每分钟一次），并把结果打印出来。

> **注意：触发器频率 ≠ 实际请求频率。** 任务每 30 秒把脚本唤起一次，但脚本先做一次**纯本地**判断（读 Windows 的联网状态，不产生任何网络请求）：
>
> - 本机没有可用网络连接 → 直接退出；
> - Windows 认为现在能上网 → 说明校园网会话正常，直接退出（除非距上次查询已超过 `OnlineCheckIntervalSeconds`，默认 300 秒，此时做一次兜底巡检）；
> - **连不上网 → 才去查 Portal，必要时自动登录**。
>
> 所以“能上网”的平静期几乎不产生请求，而一旦掉线就会立刻被发现并重连。

常用命令：

```powershell
Start-ScheduledTask -TaskName CampusAutoLogin          # 立即运行一次
Get-ScheduledTaskInfo -TaskName CampusAutoLogin        # 看上次运行结果
Get-ScheduledTask -TaskName CampusAutoLogin | Select-Object -ExpandProperty Triggers
Unregister-ScheduledTask -TaskName CampusAutoLogin -Confirm:$false
```

### 暂停 / 恢复

不想让脚本继续跑（例如回家、换网络、想手动登录）时，直接双击：

| 双击这个文件 | 作用 |
| --- | --- |
| `暂停-校园网自动登录.cmd` | 暂停：计划任务变成“已禁用”，不再自动检查、不再自动登录 |
| `恢复-校园网自动登录.cmd` | 恢复：重新启用，并立刻触发一次检查（掉线会马上登录） |

两个文件都会自动弹出 UAC 授权窗口，点“是”即可，不需要手动开管理员 PowerShell。

暂停只是把计划任务禁用，**账号密码（DPAPI 加密）、日志、状态文件全部原样保留**，随时可以恢复；想彻底删除请用 `Uninstall-CampusAutoLoginTask.ps1`。

也可以直接看当前状态（不需要管理员权限）：

```powershell
powershell -ExecutionPolicy Bypass -File .\CampusAutoLoginTaskState.ps1 -Action Status
```

图形界面等效操作：打开“任务计划程序”，右键 `CampusAutoLogin` → “禁用” / “启用”。

## 目录结构

```text
.
├── 一键安装.cmd                        # 双击安装（自动申请管理员权限）
├── Setup-DrcomAutoLogin.ps1            # 一键安装主逻辑
├── DrcomAutoLogin.ps1                  # 主脚本（状态检查 + 自动登录）
├── Save-DrcomCredential.ps1            # 保存账号密码（DPAPI 加密）
├── Install-CampusAutoLoginTask.ps1     # 注册计划任务（每 30 秒、自检）
├── Uninstall-CampusAutoLoginTask.ps1   # 卸载计划任务
├── Diagnose-CampusAutoLogin.ps1        # 生成诊断报告
├── 暂停-校园网自动登录.cmd              # 双击暂停（自动申请管理员权限）
├── 恢复-校园网自动登录.cmd              # 双击恢复（自动申请管理员权限）
├── CampusAutoLoginTaskState.ps1        # 暂停 / 恢复 / 查看状态的实现
├── drcom-config.json                   # Portal 配置
├── CHANGELOG.md                        # 更新日志
├── monitor/                            # 只读监控面板（单独打包，见下面「监控面板」）
│   ├── CampusNetworkMonitor.ps1        # 面板本体（WPF，零依赖）
│   ├── 启动监控面板.vbs                 # 双击启动（完全无黑框，推荐）
│   ├── 启动监控面板.cmd                 # 双击启动（留一个命令行窗口）
│   ├── panel.ico                       # 窗口/任务栏图标（16–256 多尺寸）
│   ├── monitor-config.json             # 面板配置（可选）
│   └── README.md                       # 面板使用说明
├── docs/
│   ├── DRCOM-PROTOCOL.md               # 抓包与协议说明
│   └── TROUBLESHOOTING.md              # 常见问题
└── generic/
    ├── CampusAutoLogin.ps1             # 通用 Portal 版本
    ├── Save-CampusCredential.ps1       # 通用版凭据保存
    └── config.example.json             # 通用版配置示例
```

运行时产生的文件都在 `%LOCALAPPDATA%\CampusAutoLogin\`：

| 文件 | 内容 |
| --- | --- |
| `credential.xml` | DPAPI 加密的账号密码（只有当前 Windows 用户能解密） |
| `state.json` | 运行次数、当前在线状态、最近一次结果、连续失败次数 |
| `login.log` | 仅记录有意义的事件与每小时心跳（不会每 30 秒刷一条） |
| `run-hidden.vbs` | 自动生成的隐藏启动器 |
| `diagnose-*.txt` | 诊断报告 |

## 常见问题

### 1. 脚本好像没有正常运行

先运行 `Diagnose-CampusAutoLogin.ps1`。报告里若“没有 `state.json`”，说明任务没有真正跑起来；此时重新运行安装脚本，它会重新注册并自动自检。

### 2. `userid error2 -> 密码错误`

在部分 Dr.COM 部署中，`userid error2` 实际表示 **“账号已在线 / 重复认证”**，并不是密码错误。可以用一个明显错误的密码做对照测试：

- 如果错误密码和正确密码返回完全相同的 `userid error2`，说明该错误码是“已在线”；
- 如果只有正确密码返回其他错误，说明需要检查密码。

脚本只有确认掉线后才登录，并且遇到这个错误码会复检状态，确认在线就按成功处理。

### 3. 每 30 秒会不会太频繁

每 30 秒只有一次轻量的状态查询（浏览器打开 Portal 页面时也是这个查询），不会触发限流；限流只针对登录请求，脚本已经识别并自动等待重试。想更省一点就把 `CheckIntervalSeconds` 改成 `60`。

### 4. `error5 waitsec <3`

注销后 Portal 要求至少等待 3 秒才能重新登录。`-Relogin` 模式默认等待 5 秒。

### 5. 账号被 MAC 绑定

部分学校会把账号绑定到首次认证的 MAC 地址。如果换设备登录失败，请联系网络中心解绑，或使用原来那台设备执行脚本。

### 6. 需要验证码

纯脚本无法自动识别验证码。可以联系网络中心关闭验证码，或改造成半自动模式。

### 7. 提示“禁止运行脚本”

使用 `-ExecutionPolicy Bypass` 启动即可：

```powershell
powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1
```

### 8. 请求太多会不会被 Portal 风控

现在有两道保险：

- **断网才触发**：脚本每次先用**纯本地**方式判断能不能上网（读 Windows 网络状态，不发请求）。能上网就直接退出，连不上网才去查 Portal。能上网时只剩兜底巡检，默认 `OnlineCheckIntervalSeconds: 300`，约 288 次/天；改成 `0` 可以做到**能上网时一次都不查**。
- **登录请求限速**：`LoginHourlyLimit` 默认 12 次/小时，超过就跳过登录、等下一个小时窗口，日志里会写明原因。单次运行内也只登录 1 次（`-RetryCount` 默认 1），登录失败后按 2 → 30 分钟逐级退避。
- **登录前三道闸门**：先做一次“等 3 秒再复检”的二次确认（两次都离线才登录），再检查 60 秒最小登录间隔，最后检查每小时次数上限；任一道没过都不会发登录请求。
- **撞上限流就长冷却**：Portal 一旦明确说“太频繁”（`error5 waitsec` / `Error code 205`），或返回“账号已在别处在线”而本机复检仍不在线，脚本会立刻进入 30 分钟冷却，期间只查询状态、绝不再登录——这正是会把正在使用的会话顶掉的场景。

如果已经被风控，先双击 `暂停-校园网自动登录.cmd` 让脚本停下来，等账号恢复正常后，把 `drcom-config.json` 里的 `OnlineCheckIntervalSeconds` 调成 `300` 或更大再恢复。

如果症状是**被踢下线**（而不是提示“太频繁”），那多半是脚本在瞬时判离线时又提交了一次登录，把正在使用的会话顶掉了。v1.5.0 之后的默认值已经防住这种情况：`LoginConfirmDelaySec`（二次确认）、`LoginMinIntervalSeconds`（最小登录间隔）、`LoginCooldownMinutes`（限流/冲突冷却）。真要更保守，可以把 `LoginMinIntervalSeconds` 调到 `180`、`LoginCooldownMinutes` 调到 `60`。

更多问题见 [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)。

## 卸载

```powershell
# 只删任务，保留凭据和日志
powershell -ExecutionPolicy Bypass -File .\Uninstall-CampusAutoLoginTask.ps1

# 任务 + 凭据 + 日志 + 状态一起删
powershell -ExecutionPolicy Bypass -File .\Uninstall-CampusAutoLoginTask.ps1 -RemoveData
```

## 安全说明

- `credential.xml` 使用 Windows DPAPI 加密，与当前 Windows 用户绑定；
- 不要把它提交到 Git 或复制到其他电脑；
- `.gitignore` 已默认忽略 `credential.xml`、`*.log`、`work/`、`id_ed25519`、`*.pem`、`*.ppk`；
- 公开仓库中不要写入自己的学号、密码、Portal 内网地址等个人信息。

## 其他学校

如果不是 Dr.COM，或者登录接口不是 `/drcom/login`，可以使用 [`generic/CampusAutoLogin.ps1`](generic/CampusAutoLogin.ps1)：

1. 复制配置模板：

```powershell
Copy-Item .\generic\config.example.json .\generic\config.json
```

2. 用浏览器开发者工具抓取登录请求；
3. 把 URL、方法、字段名、密码加密方式填入 `generic/config.json`；
4. 保存账号密码：

```powershell
powershell -ExecutionPolicy Bypass -File .\generic\Save-CampusCredential.ps1
```

5. 手动测试：

```powershell
powershell -ExecutionPolicy Bypass -File .\generic\CampusAutoLogin.ps1
```

6. 注册计划任务：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-CampusAutoLoginTask.ps1 -ScriptPath .\generic\CampusAutoLogin.ps1 -ConfigPath .\generic\config.json
```

## 兼容性

- Windows 10 / Windows 11
- Windows PowerShell 5.1 及以上（不需要 PowerShell 7）
- 脚本文件使用 UTF-8 with BOM 保存，确保 Windows PowerShell 5.1 正确解析中文

## 更新日志

各版本的改动记录见 [CHANGELOG.md](CHANGELOG.md)，当前版本：**1.8.0-pre.1**（2026-09-13，预发布）。

## License

[MIT](LICENSE)

