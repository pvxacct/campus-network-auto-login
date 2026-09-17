<#
  2.0 端到端测试：用本地假 Portal 验证“正常少触发、断网快触发”和风控闸门。
  用法： powershell -ExecutionPolicy Bypass -File build\Test-CampusNet.ps1
  参数： -Exe 指定待测 exe（默认用仓库 dist\CampusNet.exe）
#>
param(
    [string]$Exe = '',
    [int]$Port = 18099
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $repo 'dist\CampusNet.exe' }
if (-not (Test-Path -LiteralPath $Exe)) { throw "找不到待测程序：$Exe" }

$work = Join-Path $env:TEMP ('cn-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$portalScript = Join-Path $repo 'build\FakePortal.ps1'
$failures = 0
$results = New-Object System.Collections.Generic.List[string]

function Write-Config {
    param(
        [string]$Path,
        [string]$PortalHost,
        [int]$OnlineProbe,
        [int]$OfflineProbe,
        [int]$HourlyLimit,
        [int]$SessionCheck = 300,
        [string[]]$Targets
    )
    $config = [ordered]@{
        PortalHost             = $PortalHost
        EportalPort            = 801
        StatusPath             = '/drcom/chkstatus'
        LoginPath              = '/drcom/login'
        LogoutPath             = '/drcom/logout'
        ErrorPromptPath        = '/eportal/portal/err_code/loadErrorPrompt'
        OnlineProbeSeconds     = $OnlineProbe
        OfflineProbeSeconds    = $OfflineProbe
        ProbeTimeoutMs         = 500
        HttpProbeTimeoutMs     = 1200
        ConfirmAttempts        = 2
        ConfirmGapMs           = 200
        ProbeTargets           = @($Targets)
        LoginConfirmDelaySec   = 1
        LoginMinIntervalSeconds = 60
        LoginHourlyLimit       = $HourlyLimit
        SessionCheckSeconds    = $SessionCheck
        StuckReloginSeconds    = 60
        StatusTimeoutSec       = 5
        LoginTimeoutSec        = 5
        RetryCount             = 1
        StaticFields           = [ordered]@{ '0MKKey' = '123456'; 'R1' = '0'; 'R2' = '0'; 'para' = '00' }
    }
    ($config | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Path -Encoding UTF8
}

# 保存账号密码：密码走标准输入（命令行里传密码已经在 pre.7 被拒绝，避免落进命令历史）
function Set-TestCredentials {
    param([string]$Dir, [string]$User = 'testuser', [string]$Password = 'testpass')
    $Password | & $Exe '--set-credentials' $User '--password-stdin' '--data-dir' $Dir | Out-Null
}

function Invoke-Scenario {
    param(
        [string]$Name,
        [string]$Scenario,
        [string]$PortalHost,
        [string[]]$Targets,
        [int]$Seconds = 12,
        [int]$OnlineProbe = 3,
        [int]$OfflineProbe = 2,
        [int]$HourlyLimit = 12,
        [int]$SessionCheck = 300
    )
    $dataDir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    $logPath = Join-Path $dataDir 'portal-requests.log'
    Write-Config -Path (Join-Path $dataDir 'config.json') -PortalHost $PortalHost -OnlineProbe $OnlineProbe `
        -OfflineProbe $OfflineProbe -HourlyLimit $HourlyLimit -SessionCheck $SessionCheck -Targets $Targets

    $portal = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $portalScript, '-Scenario', $Scenario, '-Port', $Port, '-LogPath', $logPath
    Start-Sleep -Milliseconds 900

    try {
        Set-TestCredentials -Dir $dataDir
        $output = & $Exe '--run-seconds' $Seconds '--data-dir' $dataDir 2>&1 | Out-String
    }
    finally {
        try { Stop-Process -Id $portal.Id -Force -ErrorAction SilentlyContinue } catch { }
        Start-Sleep -Milliseconds 200
    }

    $requests = @()
    if (Test-Path -LiteralPath $logPath) { $requests = Get-Content -LiteralPath $logPath | Where-Object { $_ -match '^(GET|POST) ' } }
    $status = (@($requests | Where-Object { $_ -match 'chkstatus' }).Count)
    $login = (@($requests | Where-Object { $_ -match 'login' }).Count)
    $logout = (@($requests | Where-Object { $_ -match 'logout' }).Count)
    $stateFile = Join-Path $dataDir 'state.json'
    if (Test-Path -LiteralPath $stateFile) {
        $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $state = [pscustomobject]@{ LastResult = ''; LastError = ''; ConsecutiveFailures = 0; LoginWindowCount = 0 }
    }

    $logContent = ''
    $localLog = Join-Path $dataDir 'login.log'
    if (Test-Path -LiteralPath $localLog) { $logContent = Get-Content -LiteralPath $localLog -Raw -Encoding UTF8 }

    return [pscustomobject]@{
        Name = $Name; Status = $status; Login = $login; Logout = $logout
        Requests = $requests; State = $state; Output = $output; Log = $logContent
    }
}

function Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    if ($Condition) {
        $results.Add("PASS  $Name")
    } else {
        $script:failures++
        $results.Add("FAIL  $Name  -> $Detail")
    }
}

Write-Host "使用 exe：$Exe"
Write-Host "临时目录：$work"
Write-Host ''

# 场景 1：网络正常 → 完全不请求 Portal
$n = Invoke-Scenario -Name 's1-online' -Scenario 'online' -PortalHost "127.0.0.1:$Port" `
    -Targets @("tcp:127.0.0.1:$Port") -Seconds 10 -OnlineProbe 2
Assert '正常联网时不请求 Portal' ($n.Status -eq 0 -and $n.Login -eq 0) "chkstatus=$($n.Status) login=$($n.Login)"

# 场景 2：断网 → 自动登录成功
$n = Invoke-Scenario -Name 's2-offline-login' -Scenario 'offline-ok' -PortalHost "127.0.0.1:$Port" `
    -Targets @('tcp:127.0.0.1:65001') -Seconds 14 -OnlineProbe 2 -OfflineProbe 2
Assert '断网后自动登录且只登录一次' ($n.Login -eq 1) "login=$($n.Login)"
Assert '登录成功后状态为 login-ok/online' ($n.State.LastResult -eq 'login-ok' -or $n.State.LastResult -eq 'online') "LastResult=$($n.State.LastResult)"

# 场景 3：第一次显示离线、复检已在线 → 不登录
$n = Invoke-Scenario -Name 's3-confirm' -Scenario 'confirm-online' -PortalHost "127.0.0.1:$Port" `
    -Targets @('tcp:127.0.0.1:65002') -Seconds 12 -OnlineProbe 2 -OfflineProbe 2
Assert '复检在线时不登录' ($n.Login -eq 0) "login=$($n.Login)"

# 场景 4：Portal 限流 → 本次不再重试，原因写进状态（不再有冷却）
$n = Invoke-Scenario -Name 's4-ratelimit' -Scenario 'rate-limited' -PortalHost "127.0.0.1:$Port" `
    -Targets @('tcp:127.0.0.1:65003') -Seconds 14 -OnlineProbe 2 -OfflineProbe 2
Assert '限流后只登录一次' ($n.Login -eq 1) "login=$($n.Login)"
Assert '限流后结果记为 login-throttled' ($n.State.LastResult -eq 'login-throttled') "LastResult=$($n.State.LastResult)"
Assert '限流原因写入状态' ($n.State.LastError -match '限流') "LastError=$($n.State.LastError)"
Assert 'state.json 不再有冷却字段' (-not ($n.State.PSObject.Properties.Name -contains 'CooldownUntil') `
    -and -not ($n.State.PSObject.Properties.Name -contains 'CooldownReason')) "字段=$($n.State.PSObject.Properties.Name -join ',')"

# 场景 5：Portal 提示「账号已在别处在线 / 密码错误」→ 完全忽略，不记失败、不写「最近错误」
$n = Invoke-Scenario -Name 's5-conflict' -Scenario 'conflict' -PortalHost "127.0.0.1:$Port" `
    -Targets @('tcp:127.0.0.1:65004') -Seconds 30 -OnlineProbe 2 -OfflineProbe 2
Assert 'error2 后只登录一次' ($n.Login -eq 1) "login=$($n.Login)"
Assert 'error2 不再记为登录失败' ($n.State.LastResult -eq 'login-retry') "LastResult=$($n.State.LastResult)"
Assert 'error2 不写「最近错误」' ([string]::IsNullOrEmpty($n.State.LastError)) "LastError=$($n.State.LastError)"
Assert 'error2 计入「已忽略提示」' ($n.State.IgnoredPrompts -ge 1) "IgnoredPrompts=$($n.State.IgnoredPrompts)"
Assert 'error2 的提示原文被记下' ($n.State.LastIgnoredPrompt -match 'error2|已在别处|密码') "LastIgnoredPrompt=$($n.State.LastIgnoredPrompt)"
Assert '日志里写明提示已忽略' ($n.Log -match '提示已忽略') '日志未出现「提示已忽略」'
Assert 'state.json 不再出现 login-conflict' ($n.State.LastResult -ne 'login-conflict') "LastResult=$($n.State.LastResult)"

# 场景 6：登录接口回了完全无法识别的响应 → 这才是真正的失败，照实记录
$n = Invoke-Scenario -Name 's6-mininterval' -Scenario 'garbage' -PortalHost "127.0.0.1:$Port" `
    -Targets @('tcp:127.0.0.1:65005') -Seconds 16 -OnlineProbe 2 -OfflineProbe 1
Assert '失败后 60 秒内不重复登录' ($n.Login -eq 1) "login=$($n.Login)（16 秒内应只有 1 次）"
Assert '无法识别的登录响应记为 login-failed' ($n.State.LastResult -eq 'login-failed') "LastResult=$($n.State.LastResult)"
Assert '真正的失败原因写入状态' ($n.State.LastError -match '未知响应') "LastError=$($n.State.LastError)"

# 场景 7：探测恢复 → 立即回到正常状态
$n = Invoke-Scenario -Name 's7-recover' -Scenario 'online' -PortalHost "127.0.0.1:$Port" `
    -Targets @("tcp:127.0.0.1:$Port") -Seconds 8 -OnlineProbe 2
Assert '恢复后状态为 online' ($n.State.LastResult -eq 'online') "LastResult=$($n.State.LastResult)"

# 场景 8：旧配置一次性迁移（在线探测 60 秒 → 20 秒，剔除冷却项）
function Invoke-ConfigMigration {
    param([string]$Name, [int]$OnlineProbe)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $legacy = [ordered]@{
        PortalHost             = '127.0.0.1:65010'
        OnlineProbeSeconds     = $OnlineProbe
        OfflineProbeSeconds    = 2
        ConfirmAttempts        = 1
        ConfirmGapMs           = 200
        LoginCooldownMinutes   = 30
        ProbeTargets           = @('tcp:127.0.0.1:65001')
    }
    ($legacy | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
    Set-TestCredentials -Dir $dir
    & $Exe '--run-seconds' 4 '--data-dir' $dir | Out-String | Out-Null
    return (Get-Content -LiteralPath (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# 场景 8a：pre.2 的默认探测列表（纯 TCP）必须被换成带内容校验的新默认
function Invoke-TargetsMigration {
    param([string]$Name, [string[]]$Targets)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $legacy = [ordered]@{
        ConfigVersion          = 2
        PortalHost             = '127.0.0.1:65010'
        OnlineProbeSeconds     = 20
        OfflineProbeSeconds    = 2
        ConfirmAttempts        = 1
        ConfirmGapMs           = 200
        ProbeTargets           = @($Targets)
    }
    ($legacy | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
    Set-TestCredentials -Dir $dir
    & $Exe '--run-seconds' 4 '--data-dir' $dir | Out-String | Out-Null
    return (Get-Content -LiteralPath (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$legacyDefault = @('tcp:223.5.5.5:443', 'tcp:114.114.114.114:53', 'tcp:www.msftconnecttest.com:80')
$migratedTargets = Invoke-TargetsMigration -Name 's8-legacy-targets' -Targets $legacyDefault
Assert 'pre.2 默认探测列表被换成新的四条' ($migratedTargets.ProbeTargets[0] -eq 'http:connect.rom.miui.com/generate_204|204') "ProbeTargets=$($migratedTargets.ProbeTargets -join ',')"
Assert '迁移后探测目标共 4 项' ($migratedTargets.ProbeTargets.Count -eq 4) "Count=$($migratedTargets.ProbeTargets.Count)"

# 场景 8b：pre.3 ~ pre.5 的默认探测列表（只有微软一个内容校验目标）也要换成新的四条
$legacyV3 = @('http:www.msftconnecttest.com/connecttest.txt|Microsoft Connect Test', 'tcp:223.5.5.5:443', 'tcp:114.114.114.114:53')
$migratedV3 = Invoke-TargetsMigration -Name 's8-legacy-v3-targets' -Targets $legacyV3
Assert 'pre.5 默认探测列表被换成新的四条' ($migratedV3.ProbeTargets.Count -eq 4 -and $migratedV3.ProbeTargets[0] -eq 'http:connect.rom.miui.com/generate_204|204') "ProbeTargets=$($migratedV3.ProbeTargets -join ',')"
Assert 'pre.5 配置迁移后写入 ConfigVersion=5' ($migratedV3.ConfigVersion -eq 5) "ConfigVersion=$($migratedV3.ConfigVersion)"

$migrated = Invoke-ConfigMigration -Name 's8-migrate' -OnlineProbe 60
Assert '旧默认 60 秒迁移为 20 秒' ($migrated.OnlineProbeSeconds -eq 20) "OnlineProbeSeconds=$($migrated.OnlineProbeSeconds)"
Assert '迁移后写入 ConfigVersion=5' ($migrated.ConfigVersion -eq 5) "ConfigVersion=$($migrated.ConfigVersion)"
Assert '迁移后剔除 LoginCooldownMinutes' (-not ($migrated.PSObject.Properties.Name -contains 'LoginCooldownMinutes')) '仍存在该键'
Assert '迁移后保留自定义 ProbeTargets' (($migrated.ProbeTargets -join ',') -eq 'tcp:127.0.0.1:65001') "ProbeTargets=$($migrated.ProbeTargets -join ',')"

$custom = Invoke-ConfigMigration -Name 's8-custom' -OnlineProbe 45
Assert '自定义 45 秒不会被改写' ($custom.OnlineProbeSeconds -eq 45) "OnlineProbeSeconds=$($custom.OnlineProbeSeconds)"

# 场景 9：全新数据目录 → 默认配置就是「在线 20 秒 + 兜底 300 秒」
$freshDir = Join-Path $work 's9-default'
New-Item -ItemType Directory -Force -Path $freshDir | Out-Null
Set-TestCredentials -Dir $freshDir
& $Exe '--run-seconds' 4 '--data-dir' $freshDir | Out-String | Out-Null
$fresh = Get-Content -LiteralPath (Join-Path $freshDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert '新配置默认在线探测 20 秒' ($fresh.OnlineProbeSeconds -eq 20) "OnlineProbeSeconds=$($fresh.OnlineProbeSeconds)"
Assert '新配置默认兜底巡检 300 秒' ($fresh.UpstreamProbeSeconds -eq 300) "UpstreamProbeSeconds=$($fresh.UpstreamProbeSeconds)"
Assert '新配置默认带「204 内容校验」目标' ($fresh.ProbeTargets[0] -eq 'http:connect.rom.miui.com/generate_204|204') "ProbeTargets=$($fresh.ProbeTargets -join ',')"
Assert '新配置默认共 4 条探测目标' ($fresh.ProbeTargets.Count -eq 4) "Count=$($fresh.ProbeTargets.Count)"
Assert '新配置默认保留微软内容校验目标' (($fresh.ProbeTargets -join ' ') -match 'msftconnecttest') "ProbeTargets=$($fresh.ProbeTargets -join ',')"
Assert '新配置默认会话校验 300 秒' ($fresh.SessionCheckSeconds -eq 300) "SessionCheckSeconds=$($fresh.SessionCheckSeconds)"
Assert '新配置默认残留重登 60 秒' ($fresh.StuckReloginSeconds -eq 60) "StuckReloginSeconds=$($fresh.StuckReloginSeconds)"
Assert '新配置写入 ConfigVersion=5' ($fresh.ConfigVersion -eq 5) "ConfigVersion=$($fresh.ConfigVersion)"
Assert '新配置默认 HTTP 探测超时 3000 毫秒' ($fresh.HttpProbeTimeoutMs -eq 3000) "HttpProbeTimeoutMs=$($fresh.HttpProbeTimeoutMs)"
Assert '新配置默认复检 2 轮 / 500 毫秒' ($fresh.ConfirmAttempts -eq 2 -and $fresh.ConfirmGapMs -eq 500) "Attempts=$($fresh.ConfirmAttempts) Gap=$($fresh.ConfirmGapMs)"
Assert '新配置默认 Portal 协议为 http' ($fresh.PortalScheme -eq 'http') "PortalScheme=$($fresh.PortalScheme)"

# 场景 10：TCP 能连、内容校验失败（网关代答导致「假在线」）→ 必须查 Portal 并登录
$n = Invoke-Scenario -Name 's10-content-fail' -Scenario 'offline-ok' -PortalHost "127.0.0.1:$Port" `
    -Targets @("tcp:127.0.0.1:$Port", "http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test") `
    -Seconds 16 -OnlineProbe 2 -OfflineProbe 2
Assert '内容校验失败时会去核对 Portal' ($n.Status -ge 1) "chkstatus=$($n.Status)"
Assert '内容校验失败时会自动登录' ($n.Login -eq 1) "login=$($n.Login)"
Assert '补救后状态为 login-ok/online' ($n.State.LastResult -eq 'login-ok' -or $n.State.LastResult -eq 'online') "LastResult=$($n.State.LastResult)"
Assert '会话核对时间被记录' (-not [string]::IsNullOrEmpty($n.State.LastSessionCheck)) "LastSessionCheck=$($n.State.LastSessionCheck)"

# 场景 11：探测全通但 Portal 会话已离线 → 到会话校验间隔后自动登录
$n = Invoke-Scenario -Name 's11-session-check' -Scenario 'offline-ok' -PortalHost "127.0.0.1:$Port" `
    -Targets @("tcp:127.0.0.1:$Port") -Seconds 16 -OnlineProbe 2 -OfflineProbe 2 -SessionCheck 3
Assert '会话校验到点后自动登录' ($n.Login -eq 1) "login=$($n.Login)"
Assert '会话校验结果被记录' ($n.State.LastSessionResult -eq 'online' -or $n.State.LastSessionResult -eq 'offline') "LastSessionResult=$($n.State.LastSessionResult)"

# 场景 12：--clear-log 清空日志（只剩一行「日志已清空」）
$clearDir = Join-Path $work 's12-clearlog'
New-Item -ItemType Directory -Force -Path $clearDir | Out-Null
$logFile = Join-Path $clearDir 'login.log'
Set-Content -LiteralPath $logFile -Value @('2026-01-01 00:00:00 [INFO] 旧日志一', '2026-01-01 00:00:01 [WARN] 旧日志二') -Encoding UTF8
Set-Content -LiteralPath ($logFile + '.old') -Value '2026-01-01 00:00:00 [INFO] 更旧的日志' -Encoding UTF8
& $Exe '--clear-log' '--data-dir' $clearDir | Out-String | Out-Null
$afterClear = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
Assert '清空日志后只剩一行提示' ($afterClear.Count -eq 1 -and $afterClear[0] -match '日志已清空') "行数=$($afterClear.Count)"
Assert '清空日志后不留 login.log.old' (-not (Test-Path -LiteralPath ($logFile + '.old'))) '旧日志文件仍存在'

# 场景 13：内容校验目标真的拿到预期内容 → 一个 Portal 请求都不发
$n = Invoke-Scenario -Name 's13-content-pass' -Scenario 'content-ok' -PortalHost "127.0.0.1:$Port" `
    -Targets @("http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test") -Seconds 12 -OnlineProbe 2
Assert '内容校验通过时不请求 Portal' ($n.Status -eq 0 -and $n.Login -eq 0) "chkstatus=$($n.Status) login=$($n.Login)"
Assert '内容校验通过后状态为 online' ($n.State.LastResult -eq 'online') "LastResult=$($n.State.LastResult)"

# 场景 14a：既要求内容、又只认 204 的目标拿到 200 + 劫持页 → 判失败并自动恢复
#（以前写成 url|文本|204，解析器只认一个竖线，于是「期望 204」其实从未生效——本次修正并真正测到）
$n = Invoke-Scenario -Name 's14-expect-204' -Scenario 'offline-ok' -PortalHost "127.0.0.1:$Port" `
    -Targets @("http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test|204") -Seconds 16 -OnlineProbe 2 -OfflineProbe 2
Assert '期望 204 却拿到 200 时判定为不在线' ($n.Status -ge 1) "chkstatus=$($n.Status)"
Assert '期望 204 失败后会自动登录' ($n.Login -eq 1) "login=$($n.Login)"
Assert '恢复后状态为 login-ok' ($n.State.LastResult -eq 'login-ok') "LastResult=$($n.State.LastResult)"

# 场景 14b：假 Portal 真的回 204（generate_204 的正常情形）→ 判定在线，一个 Portal 请求都不发
$n = Invoke-Scenario -Name 's14b-real-204' -Scenario 'content-204' -PortalHost "127.0.0.1:$Port" `
    -Targets @("http:127.0.0.1:$Port/connecttest.txt|204") -Seconds 10 -OnlineProbe 2
Assert '真的拿到 204 时判为在线' ($n.Status -eq 0 -and $n.Login -eq 0) "chkstatus=$($n.Status) login=$($n.Login)"
Assert '真 204 后状态为 online' ($n.State.LastResult -eq 'online') "LastResult=$($n.State.LastResult)"

# 场景 15：登录接口回「已在别处在线」，但复检确认网络其实已恢复 → 直接算成功
$n = Invoke-Scenario -Name 's15-error2-recovered' -Scenario 'conflict-then-online' -PortalHost "127.0.0.1:$Port" `
    -Targets @('tcp:127.0.0.1:65007') -Seconds 20 -OnlineProbe 2 -OfflineProbe 2
Assert 'error2 后复检在线即算登录成功' ($n.State.LastResult -eq 'login-ok') "LastResult=$($n.State.LastResult)"
Assert 'error2 恢复场景只登录一次' ($n.Login -eq 1) "login=$($n.Login)"

# 场景 16：守护自检（--watchdog --check-only）的判定与退出码
# 以前「主程序在跑」时 0 和 1 都算通过——判定成 stale（引擎卡死）也能蒙混过关，这里逐项严格断言。
function Invoke-WatchdogCheck {
    param([string]$DataDir)
    $out = Join-Path $DataDir 'watchdog-out.txt'
    $p = Start-Process -FilePath $Exe -ArgumentList '--watchdog', '--check-only', '--data-dir', $DataDir `
        -RedirectStandardOutput $out -Wait -PassThru
    $text = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw -Encoding UTF8 } else { '' }
    return [pscustomobject]@{ Exit = $p.ExitCode; Text = $text }
}

function Write-TestState {
    param([string]$Dir, [int]$AgeSeconds)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $stamp = (Get-Date).AddSeconds(-$AgeSeconds).ToString('yyyy-MM-dd HH:mm:ss')
    $json = [ordered]@{ LastTrigger = $stamp; LastResult = 'online'; Online = $true } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $Dir 'state.json') -Value $json -Encoding UTF8
}

$watchFreshDir = Join-Path $work 's16-fresh'
$watchStaleDir = Join-Path $work 's16-stale'
$watchEmptyDir = Join-Path $work 's16-empty'
Write-TestState -Dir $watchFreshDir -AgeSeconds 5
Write-TestState -Dir $watchStaleDir -AgeSeconds 900
New-Item -ItemType Directory -Force -Path $watchEmptyDir | Out-Null

$mainRunning = @(Get-Process -Name 'CampusNet' -ErrorAction SilentlyContinue).Count -gt 0
$watchFresh = Invoke-WatchdogCheck -DataDir $watchFreshDir
$watchStale = Invoke-WatchdogCheck -DataDir $watchStaleDir
$watchEmpty = Invoke-WatchdogCheck -DataDir $watchEmptyDir
if ($mainRunning) {
    Assert '主程序在跑 + 心跳新鲜 → 判定 alive（退出码 0）' ($watchFresh.Exit -eq 0) "exit=$($watchFresh.Exit) out=$($watchFresh.Text)"
    Assert '主程序在跑 + 心跳过期 → 判定 stale（退出码 1）' ($watchStale.Exit -eq 1) "exit=$($watchStale.Exit) out=$($watchStale.Text)"
} else {
    Assert '主程序不在 → 判定 dead（退出码 2）' ($watchFresh.Exit -eq 2 -and $watchStale.Exit -eq 2) "fresh=$($watchFresh.Exit) stale=$($watchStale.Exit)"
}
$emptyExpected = if ($mainRunning) { 1 } else { 2 }
Assert '状态文件缺失时不冒充存活' ($watchEmpty.Exit -eq $emptyExpected) "exit=$($watchEmpty.Exit) out=$($watchEmpty.Text)"
Assert '守护自检不写状态文件' (-not (Test-Path -LiteralPath (Join-Path $watchEmptyDir 'state.json'))) '状态文件被写出来了'
# 自定义数据目录必须透传给「被拉起的主程序」，否则守护会用默认目录里的配置和账号
Assert '守护重启命令带 --data-dir' ($watchFresh.Text -match '--data-dir' -and $watchFresh.Text.Contains($watchFreshDir)) "out=$($watchFresh.Text)"

# 场景 17：常驻守护进程（--watchdog-loop）在不在跑，状态里要如实显示
$loopDir = Join-Path $work 's17-watchdog-loop'
New-Item -ItemType Directory -Force -Path $loopDir | Out-Null
$statusBefore = (& $Exe '--status' '--data-dir' $loopDir 2>&1 | Out-String)
$preexisting = $statusBefore -match '守护\s*：已开启'
if (-not $preexisting) {
    Assert '守护未启动时状态显示未开启' ($statusBefore -match '守护\s*：未开启') "输出=$($statusBefore -replace "`r?`n", ' | ')"
}
$loop = Start-Process -FilePath $Exe -ArgumentList '--watchdog-loop', '--data-dir', $loopDir -PassThru
Start-Sleep -Seconds 3
$statusRunning = (& $Exe '--status' '--data-dir' $loopDir 2>&1 | Out-String)
Assert '守护进程在跑时状态显示已开启' ($statusRunning -match '守护\s*：已开启') "输出=$($statusRunning -replace "`r?`n", ' | ')"
try { Stop-Process -Id $loop.Id -Force -ErrorAction SilentlyContinue } catch { }
Start-Sleep -Seconds 2
if (-not $preexisting) {
    $statusAfter = (& $Exe '--status' '--data-dir' $loopDir 2>&1 | Out-String)
    Assert '守护进程退出后状态回到未开启' ($statusAfter -match '守护\s*：未开启') "输出=$($statusAfter -replace "`r?`n", ' | ')"
}

# 场景 18：登录接口回成功、但状态接口随即不可达 → 必须算「待确认」，不能算登录成功
#（这是 pre.6 的严重误报：after.Online || !after.Reachable 会把「Portal 挂了 + 没联上网」记成 login-ok）
$n = Invoke-Scenario -Name 's18-unconfirmed' -Scenario 'drop-after-login' -PortalHost "127.0.0.1:$Port" `
    -Targets @('tcp:127.0.0.1:65011') -Seconds 34 -OnlineProbe 2 -OfflineProbe 2
Assert '状态接口不可达时不算登录成功' ($n.State.LastResult -eq 'login-unconfirmed') "LastResult=$($n.State.LastResult)"
Assert '待确认时不写「登录成功」时间' ([string]::IsNullOrEmpty($n.State.LastLoginSuccess)) "LastLoginSuccess=$($n.State.LastLoginSuccess)"
Assert '待确认时只提交一次登录' ($n.Login -eq 1) "login=$($n.Login)"
Assert '日志写明本次不记为登录成功' ($n.Log -match '不记为登录成功|状态接口不可达') '日志里没有相关说明'

# 场景 19：探测目标全部非法 → 判配置错误、停下、不登录（既不能当在线，也不能拿着坏配置打 Portal）
$n = Invoke-Scenario -Name 's19-bad-targets' -Scenario 'offline-ok' -PortalHost "127.0.0.1:$Port" `
    -Targets @('garbage', 'tcp:', 'http:') -Seconds 10 -OnlineProbe 2 -OfflineProbe 2
Assert '探测目标全非法时不请求 Portal' ($n.Status -eq 0 -and $n.Login -eq 0) "chkstatus=$($n.Status) login=$($n.Login)"
Assert '探测目标全非法时状态为 probe-config' ($n.State.LastResult -eq 'probe-config') "LastResult=$($n.State.LastResult)"
Assert '探测目标全非法时日志给出提示' ($n.Log -match '没有任何一条合法目标') '日志里没有相关说明'

# ------------------------------------------------------------------ 原始配置场景（自备 config.json）
function Invoke-RawScenario {
    param([string]$Name, [string]$Scenario, [string]$ConfigText, [int]$Seconds = 8, [switch]$SkipCredentials)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'config.json') -Value $ConfigText -Encoding UTF8
    $logPath = Join-Path $dir 'portal-requests.log'
    $portal = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $portalScript, '-Scenario', $Scenario, '-Port', $Port, '-LogPath', $logPath
    Start-Sleep -Milliseconds 900
    try {
        if (-not $SkipCredentials) { Set-TestCredentials -Dir $dir }
        $output = & $Exe '--run-seconds' $Seconds '--data-dir' $dir 2>&1 | Out-String
    }
    finally {
        try { Stop-Process -Id $portal.Id -Force -ErrorAction SilentlyContinue } catch { }
        Start-Sleep -Milliseconds 200
    }
    $requests = @()
    if (Test-Path -LiteralPath $logPath) { $requests = Get-Content -LiteralPath $logPath | Where-Object { $_ -match '^(GET|POST) ' } }
    $stateFile = Join-Path $dir 'state.json'
    if (Test-Path -LiteralPath $stateFile) {
        $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $state = [pscustomobject]@{ LastResult = ''; LastError = '' }
    }
    $logContent = ''
    $localLog = Join-Path $dir 'login.log'
    if (Test-Path -LiteralPath $localLog) { $logContent = Get-Content -LiteralPath $localLog -Raw -Encoding UTF8 }
    return [pscustomobject]@{
        Dir = $dir; Requests = $requests; State = $state; Log = $logContent; Output = $output
        Status = (@($requests | Where-Object { $_ -match 'chkstatus' }).Count)
        Login = (@($requests | Where-Object { $_ -match 'login' }).Count)
    }
}

# 场景 20：config.json 损坏 → 停止自动登录、提示用户、一个 Portal 请求都不发
$corruptConfig = '{ "PortalHost": "127.0.0.1:' + $Port + '", "ProbeTargets": ["tcp:127.0.0.1:65012"'
$n = Invoke-RawScenario -Name 's20-corrupt-config' -Scenario 'online' -ConfigText $corruptConfig -Seconds 8
Assert '配置损坏时不请求 Portal' ($n.Status -eq 0 -and $n.Login -eq 0) "chkstatus=$($n.Status) login=$($n.Login)"
Assert '配置损坏时状态为 config-invalid' ($n.State.LastResult -eq 'config-invalid') "LastResult=$($n.State.LastResult)"
Assert '配置损坏时日志写明原因' ($n.Log -match '配置文件无法解析') '日志里没有相关说明'
Assert '损坏的配置不会被默认配置悄悄覆盖' ((Get-Content -LiteralPath (Join-Path $n.Dir 'config.json') -Raw -Encoding UTF8) -match '127\.0\.0\.1') '配置文件被改写了'

# 场景 21：命令行里带明文密码 → 直接拒绝（密码会留在 PowerShell 历史 / 进程列表 / 审计日志里）
$cliDir = Join-Path $work 's21-cli-password'
New-Item -ItemType Directory -Force -Path $cliDir | Out-Null
$cliOut = & $Exe '--set-credentials' 'testuser' 'testpass' '--data-dir' $cliDir 2>&1 | Out-String
$cliCode = $LASTEXITCODE
Assert '命令行传明文密码被拒绝（退出码 2）' ($cliCode -eq 2) "exit=$cliCode out=$cliOut"
Assert '被拒绝时不写凭据文件' (-not (Test-Path -LiteralPath (Join-Path $cliDir 'credentials.dat'))) '凭据文件被写出来了'
Assert '拒绝时提示安全写法' ($cliOut -match 'password-stdin') "out=$cliOut"

# 场景 22：并行探测——4 个「连得上但永不回内容」的目标，耗时不能随条数线性增长
function New-BlackholeConfig {
    param([int]$TargetCount)
    $targets = @()
    for ($i = 0; $i -lt $TargetCount; $i++) { $targets += "http:127.0.0.1:$Port/blackhole$i" }
    $cfg = [ordered]@{
        PortalHost          = "127.0.0.1:$Port"
        EportalPort         = 801
        StatusPath          = '/drcom/chkstatus'
        LoginPath           = '/drcom/login'
        LogoutPath          = '/drcom/logout'
        ErrorPromptPath     = '/eportal/portal/err_code/loadErrorPrompt'
        OnlineProbeSeconds  = 20
        OfflineProbeSeconds = 2
        ProbeTimeoutMs      = 500
        HttpProbeTimeoutMs  = 1200
        ConfirmAttempts     = 2
        ConfirmGapMs        = 200
        ProbeTargets        = @($targets)
        LoginConfirmDelaySec = 1
        LoginMinIntervalSeconds = 60
        LoginHourlyLimit    = 12
        SessionCheckSeconds = 300
        StuckReloginSeconds = 60
        StatusTimeoutSec    = 5
        LoginTimeoutSec     = 5
        RetryCount          = 1
        StaticFields        = [ordered]@{ '0MKKey' = '123456' }
    }
    return ($cfg | ConvertTo-Json -Depth 5)
}

$oneDir = Join-Path $work 's22-parallel-1'
$fourDir = Join-Path $work 's22-parallel-4'
New-Item -ItemType Directory -Force -Path $oneDir, $fourDir | Out-Null
Set-Content -LiteralPath (Join-Path $oneDir 'config.json') -Value (New-BlackholeConfig -TargetCount 1) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $fourDir 'config.json') -Value (New-BlackholeConfig -TargetCount 4) -Encoding UTF8
$bhLog = Join-Path $work 's22-portal.log'
$bhPortal = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $portalScript, '-Scenario', 'blackhole', '-Port', $Port, '-LogPath', $bhLog
Start-Sleep -Milliseconds 900
try {
    $swOne = [System.Diagnostics.Stopwatch]::StartNew()
    $outOne = & $Exe '--diagnose' '--data-dir' $oneDir 2>&1 | Out-String
    $swOne.Stop()
    $swFour = [System.Diagnostics.Stopwatch]::StartNew()
    $outFour = & $Exe '--diagnose' '--data-dir' $fourDir 2>&1 | Out-String
    $swFour.Stop()
}
finally {
    try { Stop-Process -Id $bhPortal.Id -Force -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 200
}
$delta = [math]::Round($swFour.Elapsed.TotalSeconds - $swOne.Elapsed.TotalSeconds, 2)
Assert '探测目标并行执行（4 条不比 1 条慢多少）' ($delta -lt 1.0) `
    "1 条=$([math]::Round($swOne.Elapsed.TotalSeconds, 2))s，4 条=$([math]::Round($swFour.Elapsed.TotalSeconds, 2))s，差 $delta s（串行会差约 3.6s）"
Assert '黑洞目标如实报「不通」' ($outOne -match '不通' -or $outOne -match '失败') '诊断输出没有体现探测失败'

# 场景 23：pre.6 的复检参数（3 轮 / 1000 毫秒）迁移为 2 轮 / 500 毫秒，自定义值原样保留
function Invoke-ConfirmMigration {
    param([string]$Name, [int]$Attempts, [int]$Gap)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $legacy = [ordered]@{
        ConfigVersion        = 4
        PortalHost           = "127.0.0.1:$Port"
        OnlineProbeSeconds   = 20
        OfflineProbeSeconds  = 2
        ProbeTimeoutMs       = 500
        ConfirmAttempts      = $Attempts
        ConfirmGapMs         = $Gap
        ProbeTargets         = @("tcp:127.0.0.1:65013")
    }
    ($legacy | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
    Set-TestCredentials -Dir $dir
    & $Exe '--run-seconds' 4 '--data-dir' $dir | Out-String | Out-Null
    return (Get-Content -LiteralPath (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$confirmMigrated = Invoke-ConfirmMigration -Name 's23-migrate' -Attempts 3 -Gap 1000
Assert 'pre.6 的复检节奏迁移为 2 轮 / 500 毫秒' ($confirmMigrated.ConfirmAttempts -eq 2 -and $confirmMigrated.ConfirmGapMs -eq 500) `
    "Attempts=$($confirmMigrated.ConfirmAttempts) Gap=$($confirmMigrated.ConfirmGapMs)"
Assert '迁移后写入 ConfigVersion=5' ($confirmMigrated.ConfigVersion -eq 5) "ConfigVersion=$($confirmMigrated.ConfigVersion)"
$confirmCustom = Invoke-ConfirmMigration -Name 's23-custom' -Attempts 4 -Gap 1500
Assert '自定义复检参数不被改写' ($confirmCustom.ConfirmAttempts -eq 4 -and $confirmCustom.ConfirmGapMs -eq 1500) `
    "Attempts=$($confirmCustom.ConfirmAttempts) Gap=$($confirmCustom.ConfirmGapMs)"

# ------------------------------------------------------------------ pre.8：审查发现的 6 类问题

function New-RawConfig {
    param(
        [string]$PortalHost,
        [string[]]$Targets,
        [int]$RetryCount = 1,
        [int]$MinInterval = 60,
        [int]$HourlyLimit = 12,
        [int]$OnlineProbe = 20,
        [int]$OfflineProbe = 2,
        [int]$LoginTimeout = 5,
        [int]$StatusTimeout = 5
    )
    $cfg = [ordered]@{
        PortalHost              = $PortalHost
        EportalPort             = 801
        StatusPath              = '/drcom/chkstatus'
        LoginPath               = '/drcom/login'
        LogoutPath              = '/drcom/logout'
        ErrorPromptPath         = '/eportal/portal/err_code/loadErrorPrompt'
        OnlineProbeSeconds      = $OnlineProbe
        OfflineProbeSeconds     = $OfflineProbe
        ProbeTimeoutMs          = 500
        HttpProbeTimeoutMs      = 1200
        ConfirmAttempts         = 2
        ConfirmGapMs            = 200
        ProbeTargets            = @($Targets)
        LoginConfirmDelaySec    = 1
        LoginMinIntervalSeconds = $MinInterval
        LoginHourlyLimit        = $HourlyLimit
        SessionCheckSeconds     = 300
        StuckReloginSeconds     = 60
        StatusTimeoutSec        = $StatusTimeout
        LoginTimeoutSec         = $LoginTimeout
        RetryCount              = $RetryCount
        StaticFields            = [ordered]@{ '0MKKey' = '123456' }
    }
    return ($cfg | ConvertTo-Json -Depth 5)
}

function Invoke-RawRun {
    param([string]$Name, [string]$Scenario, [string]$ConfigText, [int]$Seconds = 10,
        [string]$User = 'testuser', [string]$Password = 'testpass')
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'config.json') -Value $ConfigText -Encoding UTF8
    $logPath = Join-Path $dir 'portal-requests.log'
    $portal = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $portalScript, '-Scenario', $Scenario, '-Port', $Port, '-LogPath', $logPath
    Start-Sleep -Milliseconds 900
    try {
        Set-TestCredentials -Dir $dir -User $User -Password $Password
        $output = & $Exe '--run-seconds' $Seconds '--data-dir' $dir 2>&1 | Out-String
    }
    finally {
        try { Stop-Process -Id $portal.Id -Force -ErrorAction SilentlyContinue } catch { }
        Start-Sleep -Milliseconds 200
    }
    $requests = @()
    if (Test-Path -LiteralPath $logPath) { $requests = Get-Content -LiteralPath $logPath | Where-Object { $_ -match '^(GET|POST) ' } }
    $stateText = ''
    $stateFile = Join-Path $dir 'state.json'
    if (Test-Path -LiteralPath $stateFile) { $stateText = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 }
    $state = if ($stateText) { $stateText | ConvertFrom-Json } else { [pscustomobject]@{ LastResult = ''; LastError = ''; LoginWindowCount = 0 } }
    $logText = ''
    $localLog = Join-Path $dir 'login.log'
    if (Test-Path -LiteralPath $localLog) { $logText = Get-Content -LiteralPath $localLog -Raw -Encoding UTF8 }
    return [pscustomobject]@{
        Dir = $dir; Requests = $requests; State = $state; StateText = $stateText; Log = $logText; Output = $output
        Status = (@($requests | Where-Object { $_ -match 'chkstatus' }).Count)
        Login = (@($requests | Where-Object { $_ -match 'login' }).Count)
    }
}
Write-Host ''
# 场景 24：Portal 把提交的表单回显出来 → 密码与账号都不能落进日志 / state.json
# （「复制诊断信息」读的就是这两处，它们干净 = 剪贴板干净）
$n = Invoke-RawRun -Name 's24-redact' -Scenario 'echo-form' -Seconds 12 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" -Targets @('tcp:127.0.0.1:65014')) `
    -User 'sectestacct' -Password 'SecretPass123'
Assert '日志里不出现密码原文' ($n.Log -notmatch 'SecretPass123') '密码落进了 login.log'
Assert 'state.json 里不出现密码原文' ($n.StateText -notmatch 'SecretPass123') '密码落进了 state.json'
Assert '日志里 upass 的值被打码' ($n.Log -match 'upass=\*\*\*') 'upass 没有被替换成 ***'
Assert '日志里不出现完整账号' ($n.Log -notmatch 'sectestacct') '完整账号落进了 login.log'
Assert '日志里账号显示为掩码' ($n.Log -match 'sec\*{8}') '账号没有按掩码写入'
Assert 'state.json 里不出现完整账号' ($n.StateText -notmatch 'sectestacct') '完整账号落进了 state.json'

# 场景 25：RetryCount=3 但最小间隔 60 秒 → 一次触发只提交 1 次，其余交给下一个周期
$n = Invoke-RawRun -Name 's25-retry-interval' -Scenario 'garbage' -Seconds 12 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" -Targets @('tcp:127.0.0.1:65015') -RetryCount 3 -MinInterval 60)
Assert '重试不再绕过最小间隔（只提交 1 次）' ($n.Login -eq 1) "login=$($n.Login)，RetryCount=3 时 60 秒内不该再提交"
Assert '日志写明按最小间隔停止重试' ($n.Log -match '最小间隔') '日志里没有最小间隔相关说明'

# 场景 26：最小间隔设为 0（测试专用）→ 3 次重试确实提交 3 次，且小时计数按请求累加
$n = Invoke-RawRun -Name 's26-retry-counted' -Scenario 'garbage' -Seconds 14 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" -Targets @('tcp:127.0.0.1:65016') -RetryCount 3 -MinInterval 0)
Assert '放开最小间隔后每轮 3 次重试都提交' ($n.Login -ge 3 -and ($n.Login % 3) -eq 0) "login=$($n.Login)，应为 3 的整数倍"
Assert '每小时计数与真正提交的次数一致' ($n.State.LoginWindowCount -eq $n.Login) "LoginWindowCount=$($n.State.LoginWindowCount) login=$($n.Login)"

# 场景 27：守护的「卡死」阈值随配置放宽，不再把正在登录的进程杀掉
$dynDir = Join-Path $work 's27-watchdog-dynamic'
New-Item -ItemType Directory -Force -Path $dynDir | Out-Null
Set-Content -LiteralPath (Join-Path $dynDir 'config.json') `
    -Value (New-RawConfig -PortalHost '127.0.0.1:65099' -Targets @('tcp:127.0.0.1:65017') `
        -RetryCount 6 -LoginTimeout 15 -StatusTimeout 8) -Encoding UTF8
Write-TestState -Dir $dynDir -AgeSeconds 200
$watchDyn = Invoke-WatchdogCheck -DataDir $dynDir
$watchSlowDir = Join-Path $work 's27-watchdog-default'
Write-TestState -Dir $watchSlowDir -AgeSeconds 200
$watchSlow = Invoke-WatchdogCheck -DataDir $watchSlowDir
if ($mainRunning) {
    Assert '大 RetryCount 下 200 秒心跳仍判 alive' ($watchDyn.Exit -eq 0) "exit=$($watchDyn.Exit)"
    Assert '默认配置下 200 秒心跳仍判 stale' ($watchSlow.Exit -eq 1) "exit=$($watchSlow.Exit)"
}
Assert '守护自检会打印卡死阈值' ($watchDyn.Text -match '卡死阈值') '自检输出里没有阈值'
Assert '阈值随配置放大（>180 秒）' ($watchDyn.Text -match '卡死阈值：2[0-9][0-9] 秒') '阈值没有随配置放大'

# 场景 28：--uninstall --check-only 只打印计划，不删任何东西
$planDir = Join-Path $work 's28-uninstall-plan'
New-Item -ItemType Directory -Force -Path $planDir | Out-Null
$marker = Join-Path $planDir 'state.json'
Set-Content -LiteralPath $marker -Value '{ "LastResult": "online" }' -Encoding UTF8
$planOut = Join-Path $planDir 'uninstall-plan.txt'
$planProc = Start-Process -FilePath $Exe -ArgumentList '--uninstall', '--check-only', '--data-dir', $planDir `
    -RedirectStandardOutput $planOut -Wait -PassThru
$planText = ''
if (Test-Path -LiteralPath $planOut) { $planText = Get-Content -LiteralPath $planOut -Raw -Encoding UTF8 }
Assert '卸载计划退出码为 0' ($planProc.ExitCode -eq 0) "exit=$($planProc.ExitCode)"
Assert '卸载计划含程序文件路径' ($planText -match 'CampusNet\.exe') '计划里没提到程序文件'
Assert '卸载计划含当前 PID' ($planText -match 'PID') '计划里没有 PID'
Assert '卸载计划说明重启兜底' ($planText -match '重启') '计划里没写重启兜底'
Assert '--check-only 不删数据目录' (Test-Path -LiteralPath $marker) '数据文件被删了'

# 场景 29：界面布局扫描——任何 Grid 用到未声明的行/列都要失败。
# WPF 对越界行号不报错，而是把控件塞进最后一行：pre.7 的高级设置整行叠印就是这么来的。
$xamlPath = Join-Path $repo 'src\CampusNet\MainWindow.xaml'
[xml]$xamlDoc = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$ns = New-Object System.Xml.XmlNamespaceManager($xamlDoc.NameTable)
$ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$overflow = New-Object System.Collections.Generic.List[string]
$gridIndex = 0
$maxRows = 0
foreach ($grid in $xamlDoc.SelectNodes('//x:Grid', $ns)) {
    $gridIndex++
    $rows = $grid.SelectNodes('x:Grid.RowDefinitions/x:RowDefinition', $ns).Count
    $cols = $grid.SelectNodes('x:Grid.ColumnDefinitions/x:ColumnDefinition', $ns).Count
    if ($rows -gt $maxRows) { $maxRows = $rows }
    foreach ($child in $grid.SelectNodes('*', $ns)) {
        if ($child.LocalName -eq 'Grid.RowDefinitions' -or $child.LocalName -eq 'Grid.ColumnDefinitions') { continue }
        $row = $child.GetAttribute('Grid.Row')
        $col = $child.GetAttribute('Grid.Column')
        if ($row -ne '' -and [int]$row -ge $rows) {
            $overflow.Add("第 $gridIndex 个 Grid 的 $($child.LocalName) 用到 Grid.Row=$row，只声明了 $rows 行")
        }
        if ($col -ne '' -and [int]$col -ge $cols) {
            $overflow.Add("第 $gridIndex 个 Grid 的 $($child.LocalName) 用到 Grid.Column=$col，只声明了 $cols 列")
        }
    }
}
Assert '界面 XAML 没有行列越界' ($overflow.Count -eq 0) ($overflow -join '；')
Assert '高级设置网格至少声明 10 行' ($maxRows -ge 10) "最多只声明了 $maxRows 行"

$results | ForEach-Object { Write-Host $_ }
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures 个用例失败" -ForegroundColor Red
    exit 1
}
Write-Host '全部用例通过' -ForegroundColor Green
exit 0
