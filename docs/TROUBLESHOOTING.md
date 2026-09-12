# 常见问题排查

## 脚本好像没有正常运行（没有任何反应）

先跑一次诊断脚本，它会把你机器上的真实情况全部打印出来，并保存成报告文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\Diagnose-CampusAutoLogin.ps1
```

报告保存在 `%LOCALAPPDATA%\CampusAutoLogin\diagnose-<时间>.txt`，重点看这几行：

| 报告内容 | 含义与处理 |
| --- | --- |
| `【4】运行状态与日志` 里没有 `state.json` | 脚本一次都没被执行过，问题在计划任务（见下一节） |
| `【3】凭据文件` 显示“没有找到凭据文件” | 还没保存过账号密码，运行 `Setup-DrcomAutoLogin.ps1` |
| `【3】凭据文件` 显示“解密失败” | 凭据是在别的 Windows 用户下保存的，需要重新保存 |
| `【2】Portal 连通性` 显示“访问 Portal 失败” | 当前没连上校园网，这是正常现象，连上后脚本会自动登录 |
| `【6】隐藏启动器` 提示 `wscript` 被禁用 | 用重新注册命令切到直接调用 PowerShell 的方式 |

## 计划任务没有执行

1. 确认任务存在：

```powershell
Get-ScheduledTask -TaskName CampusAutoLogin
```

2. 查看触发间隔和上一次运行结果：

```powershell
Get-ScheduledTask -TaskName CampusAutoLogin | Select-Object -ExpandProperty Triggers
Get-ScheduledTaskInfo -TaskName CampusAutoLogin
```

正常情况下应当看到 `LogonTrigger`、两条 `TimeTrigger`（各 1 分钟、错开 30 秒）、`EventTrigger` 三种触发器（共 4 条）。

3. 手动运行一次：

```powershell
Start-ScheduledTask -TaskName CampusAutoLogin
```

4. 观察是否真的被反复触发：`state.json` 里的 `RunCount` 会不断变大。

```powershell
Get-Content "$env:LOCALAPPDATA\CampusAutoLogin\state.json"
Get-Content "$env:LOCALAPPDATA\CampusAutoLogin\login.log" -Tail 100
```

5. 如果任务存在但从不运行：

   - 检查任务是不是被“已禁用”（任务计划程序里看状态）；
   - 检查安全软件是否拦截了 `wscript.exe` 或 `powershell.exe`；
   - 检查“任务计划程序”服务是否被禁用：`Get-Service Schedule`；
   - 重新注册一次（会自动切换运行方式并自检）：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-CampusAutoLoginTask.ps1
```

## 安装时提示 “The task XML contains a value which is incorrectly formatted or out of range”

这是 Windows 任务计划管理器对触发器的硬性限制，和账号密码、Portal 地址都没有关系：

| 报错片段 | 原因 | 正确写法 |
| --- | --- | --- |
| `(14,121):Interval:PT30S` | 重复间隔最小是 **1 分钟** | 写 `PT1M` |
| `(14,145):Duration:PT0S` | 表示“无限期重复”时必须**不写** `<Duration>` 元素 | 省略该元素 |
| `Duration:P10675199DT2H48M5.4775807S` | `TimeSpan.MaxValue` 这类超大值超出允许范围 | 省略该元素 |

1.0.0 之前的安装脚本正好踩中了这三条，所以会一路失败。新版 `Install-CampusAutoLoginTask.ps1` 已经按上面的规则生成 XML：
30 秒检查改用 **两条各 1 分钟、彼此错开 30 秒的触发器** 实现，“无限期”则直接省略 `<Duration>`。

如果你看到这个报错，说明本机脚本还是旧版本，拉取最新代码后重新安装即可：

```powershell
git pull
```

然后重新运行 `一键安装.cmd`（或 `Setup-DrcomAutoLogin.ps1`）。

安装结束时留意最后几行输出：

- `计划任务已注册：CampusAutoLogin（实际检查间隔约 30 秒）` —— 正常；
- `只能退而求其次：任务会每 60 秒检查一次` —— 你的系统连双触发器都不支持，功能正常，只是慢一点；
- `注意：系统要求必须指定重复持续时间，当前是 30 天` —— 任务会在 30 天后停止重复，请在到期前重新运行一次安装脚本。

想确认实际生效的间隔，可以运行 `Diagnose-CampusAutoLogin.ps1`，报告里会打印每条触发器的重复间隔和“有效检查间隔”。

## 每 30 秒会不会太频繁、会不会弹黑窗口

- 默认每 30 秒只发一次“查询在线状态”的请求，很轻量，不会触发限流（限流只针对登录请求）；
- 任务通过自动生成的 `run-hidden.vbs` 静默启动 PowerShell，运行时不会出现黑色命令行窗口；
- 如果系统禁用了 Windows 脚本宿主，安装脚本会在自检失败后自动改为直接调用 `powershell.exe -WindowStyle Hidden`；
- 不想这么频繁的话，把 `drcom-config.json` 里的 `CheckIntervalSeconds` 改成 `60` 或更大，然后重新运行安装脚本即可。

## 脚本无法运行（提示禁止运行脚本）

报错：`无法加载文件，因为在此系统上禁止运行脚本`

使用 `-ExecutionPolicy Bypass` 启动：

```powershell
powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1
```

或者只给当前用户放开：

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## 中文乱码或语法错误

Windows PowerShell 5.1 默认按 ANSI 读取无 BOM 的 `.ps1` 文件，中文会乱码。本项目所有脚本均保存为 **UTF-8 with BOM**。

如果你自己修改脚本后出现乱码，用下面的命令重新保存为 BOM：

```powershell
$utf8bom = New-Object System.Text.UTF8Encoding($true)
$text = [System.IO.File]::ReadAllText('.\DrcomAutoLogin.ps1', [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText('.\DrcomAutoLogin.ps1', $text, $utf8bom)
```

## `userid error2 -> 密码错误`

不一定是真的密码错误。部分 Dr.COM 部署在“账号已在线”时也返回这个错误码。

排查步骤：

1. 查询状态：

```powershell
Invoke-WebRequest 'http://10.66.209.2/drcom/chkstatus?callback=dr1&v=1&lang=zh&jsVersion=4.X' -UseBasicParsing
```

看 `result` 是否为 1。

2. 用一个明显错误的密码做对照测试；
3. 如果错误密码也返回 `userid error2`，说明是“已在线”而不是密码错误。

脚本正常模式不会在已在线时重复登录；即使遇到这个错误码，也会先复检状态，确认在线就按成功处理。

## `error5 waitsec <3`

注销后不足 3 秒就重新登录。使用 `-Relogin` 时脚本默认等待 5 秒：

```powershell
powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -Relogin
```

## `Error code: 205 System Error1(-98)`

通常是请求过于频繁或参数异常：

- 调大 `CheckIntervalSeconds`；
- 脚本已经识别限流并会自动等待后重试；
- 检查 `drcom-config.json` 中的字段是否完整。

## 登录一直失败会不会反复撞 Portal

不会，现在有三道限制：

- **失败退避**：统计连续失败次数，连续失败 3 次后进入冷却（2 分钟起，最多 30 分钟），冷却期间只查询状态、不提交登录请求；
- **单次运行只登录 1 次**：下一次检查就在 30 秒后，没必要在一次运行里连打三次（`-RetryCount` 默认 1）；
- **每小时登录上限**：`LoginHourlyLimit` 默认 12 次，超出就跳过登录、等下一个小时窗口，日志会写明“最近 1 小时已发起 N 次登录（上限 M 次）”。

v1.5.0 起还多了三道登录前的闸门，任何一道没过都不会发出登录请求：

| 闸门 | 配置项 | 默认 | 作用 |
| --- | --- | --- | --- |
| 冷却 | `LoginCooldownMinutes` | 30 分钟 | 明确限流或「已在线」冲突后，冷却期内绝不登录 |
| 最小登录间隔 | `LoginMinIntervalSeconds` | 60 秒 | 两次登录之间硬性间隔，事件密集触发也不会连打 |
| 二次确认 | `LoginConfirmDelaySec` | 3 秒 | 判定离线后等 3 秒复检，两次都离线才登录 |

## 被踢下线（用着用着就掉线）

如果“掉线”是**装上脚本之后才开始变频繁**的，那基本可以确定是脚本反复提交登录，把正在使用的会话顶掉了：
Portal 的在线状态偶尔会短暂返回“离线”，脚本一看到就登录，登录又会让旧会话失效，于是变成“一登录就掉线”的循环。

v1.5.0 的默认值已经堵住这条路径：

| 行为 | 现在的做法 |
| --- | --- |
| 抓到一次“离线”就登录 | 等 3 秒再复检，**两次都离线才登录**（`LoginConfirmDelaySec`） |
| 短时间内反复登录 | 两次登录至少间隔 60 秒（`LoginMinIntervalSeconds`） |
| Portal 说太频繁还继续撞 | 立刻冷却 30 分钟（`LoginCooldownMinutes`） |
| 提示“账号已在别处在线”但本机还是没网 | 判定为重复认证冲突，同样冷却 30 分钟 |

想更保守就调大：`LoginMinIntervalSeconds: 180`、`LoginCooldownMinutes: 60`。想确认当前状态，跑一次 `Diagnose-CampusAutoLogin.ps1`，看【5】触发闸门与冷却：里面会写明“冷却中：是/否、原因、还剩几分钟”。

## 查询太频繁被 Portal 风控（账号被限制 / 提示操作过于频繁）

先双击 `暂停-校园网自动登录.cmd` 把脚本停下来，等账号恢复正常。

然后确认脚本是最新版本，并从配置上把请求量再压低。`drcom-config.json` 里两个开关：

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `OnlineCheckIntervalSeconds` | `300` | 能上网时的**兜底巡检**间隔。平时靠本地网络状态判断，只有连不上网才查 Portal；这个值决定“能上网时”多久仍然查一次。设 `0` = 能上网时完全不查 |
| `LoginHourlyLimit` | `12` | 最近 1 小时允许的登录请求次数上限，超出就跳过登录 |

被风控过的账号建议先放宽成 `OnlineCheckIntervalSeconds: 0`、`LoginHourlyLimit: 6`。改完保存即可，**不需要重新运行安装脚本**（这两个值由主脚本每次运行时读取）。

对比一下查询量：

| `OnlineCheckIntervalSeconds` | 在线稳定时每天查询次数 |
| --- | --- |
| `30`（v1.2.0 及更早的行为） | 约 2880 次 |
| `120`（v1.3.0 的行为） | 约 720 次 |
| `300`（当前默认） | 约 288 次 |
| `0` | 能上网时 **0 次**，只有断网才请求 |

注意：**只要检测到连不上网，就会立刻去查 Portal 并登录**（每 30 秒重试一次，受 `LoginHourlyLimit` 限制），所以自动重连速度不受影响。

## 脚本好像“不工作了”（不登录了）

从 v1.4.0 起脚本改成“**连不上网才动手**”，所以如果当前能正常上网，脚本本来就什么都不做、也不会写日志——这是预期行为。

想确认它到底有没有在工作，打开 `%LOCALAPPDATA%\CampusAutoLogin\state.json` 看两个字段：

| 字段 | 含义 |
| --- | --- |
| `LastProbe` | 最近一次真的去查 Portal 的时间 |
| `Connectivity` | 判断“能不能上网”用的是哪种方式：`nlm`（系统网络列表，正常）、`cim`（网络连接配置文件，正常）、`fallback`（两种都读不到，退化成都市按“有网”处理 + 兜底巡检） |

如果 `Connectivity` 长时间是 `fallback`，说明这台机器读不到系统联网状态，脚本会退化成“每 `OnlineCheckIntervalSeconds` 秒查一次 Portal”，功能仍然正常，只是请求多一些。这种情况可以把该值设小一点，或者运行 `Diagnose-CampusAutoLogin.ps1` 看详细报告。

## 凭据无法解密

报错：`读取凭据失败（凭据文件与当前 Windows 用户绑定）`

原因：

- `credential.xml` 是在另一个 Windows 用户下生成的；
- 或者从另一台电脑复制过来的。

解决：重新运行保存脚本，输入一次密码：

```powershell
powershell -ExecutionPolicy Bypass -File .\Save-DrcomCredential.ps1
```

## 账号一直显示在线

如果有路由器、手机或另一台电脑保存了密码并自动重连，账号会一直被它们占着。表现：

- 注销后几秒内 `result` 又变成 1；
- 登录请求返回 `userid error2`。

解决：

- 找到那台设备，关闭它的 Portal 自动登录 / 哆点客户端自动重连；
- 或者接受现状：只要账号在线，脚本不需要登录；
- 真正掉线时脚本会自动接管。

## 需要验证码

纯脚本无法自动识别验证码。可选方案：

- 联系网络中心关闭验证码；
- 使用半自动模式，验证码出现时手动输入；
- 使用支持验证码识别的第三方工具（不推荐，存在安全风险）。

## MAC 绑定

部分学校把账号绑定到首次认证的 MAC。换设备或换网卡后可能无法登录。

解决：

- 使用原来那台设备；
- 或联系网络中心解绑。

## 如何完全卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall-CampusAutoLoginTask.ps1 -RemoveData
```

不加 `-RemoveData` 时只删除计划任务和隐藏启动器，凭据、日志、状态文件会保留。

## 如何临时暂停 / 恢复自动登录

不需要卸载，也不用手动敲命令，双击两个 `.cmd` 就行：

| 双击这个文件 | 作用 |
| --- | --- |
| `暂停-校园网自动登录.cmd` | 计划任务变成“已禁用”，不再自动检查、不再自动登录 |
| `恢复-校园网自动登录.cmd` | 重新启用，并立刻触发一次检查（掉线会马上登录） |

两个文件都会自动弹出 UAC 授权窗口，点“是”即可。暂停后账号密码（DPAPI 加密）、日志、状态文件全部原样保留，随时可以恢复。

命令行等效写法（暂停 / 恢复需要管理员权限，查看状态不需要）：

```powershell
powershell -ExecutionPolicy Bypass -File .\CampusAutoLoginTaskState.ps1 -Action Status   # 看当前状态
powershell -ExecutionPolicy Bypass -File .\CampusAutoLoginTaskState.ps1 -Action Pause    # 暂停
powershell -ExecutionPolicy Bypass -File .\CampusAutoLoginTaskState.ps1 -Action Resume   # 恢复
```

图形界面等效操作：任务计划程序（`taskschd.msc`）里找到 `CampusAutoLogin`，右键 → “禁用” / “启用”。

如果双击后提示“没有找到计划任务”，说明本机还没有安装，先运行一次 `一键安装.cmd`。

