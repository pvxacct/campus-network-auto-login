# 常见问题排查

## 脚本无法运行

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

脚本正常模式不会在已在线时重复登录，所以不影响使用。

## `error5 waitsec <3`

注销后不足 3 秒就重新登录。使用 `-Relogin` 时脚本默认等待 5 秒：

```powershell
powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -Relogin
```

## `Error code: 205 System Error1(-98)`

通常是请求过于频繁或参数异常：

- 降低检查频率；
- 等待 30 秒后重试；
- 检查 `drcom-config.json` 中的字段是否完整。

## 凭据无法解密

报错：`读取凭据失败（凭据文件与当前 Windows 用户绑定）`

原因：

- `credential.xml` 是在另一个 Windows 用户下生成的；
- 或者从另一台电脑复制过来的。

解决：重新运行保存脚本，输入一次密码：

```powershell
powershell -ExecutionPolicy Bypass -File .\Save-DrcomCredential.ps1
```

## 计划任务没有执行

1. 确认任务存在：

```powershell
Get-ScheduledTask -TaskName CampusAutoLogin
```

2. 查看上次运行结果：

```powershell
Get-ScheduledTask -TaskName CampusAutoLogin | Get-ScheduledTaskInfo
```

3. 手动运行一次：

```powershell
Start-ScheduledTask -TaskName CampusAutoLogin
```

4. 查看日志：

```powershell
Get-Content "$env:LOCALAPPDATA\CampusAutoLogin\login.log" -Tail 100
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

`-RemoveData` 会同时删除 `credential.xml` 和日志目录。
