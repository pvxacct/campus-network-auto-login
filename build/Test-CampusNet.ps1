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
        ConfirmAttempts        = 2
        ConfirmGapMs           = 200
        ProbeTargets           = @($Targets)
        LoginConfirmDelaySec   = 1
        LoginMinIntervalSeconds = 60
        LoginHourlyLimit       = $HourlyLimit
        SessionCheckSeconds    = $SessionCheck
        StatusTimeoutSec       = 5
        LoginTimeoutSec        = 5
        RetryCount             = 1
        StaticFields           = [ordered]@{ '0MKKey' = '123456'; 'R1' = '0'; 'R2' = '0'; 'para' = '00' }
    }
    ($config | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Path -Encoding UTF8
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
        & $Exe '--set-credentials' 'testuser' 'testpass' '--data-dir' $dataDir | Out-Null
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

    return [pscustomobject]@{
        Name = $Name; Status = $status; Login = $login; Logout = $logout
        Requests = $requests; State = $state; Output = $output
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

# 场景 5：Portal 提示「账号已在别处在线」→ 忽略该提示，按普通失败记录并按节奏继续
$n = Invoke-Scenario -Name 's5-conflict' -Scenario 'conflict' -PortalHost "127.0.0.1:$Port" `
    -Targets @('tcp:127.0.0.1:65004') -Seconds 14 -OnlineProbe 2 -OfflineProbe 2
Assert 'error2 后 16 秒内只登录一次' ($n.Login -eq 1) "login=$($n.Login)"
Assert 'error2 记为普通失败（login-failed）' ($n.State.LastResult -eq 'login-failed') "LastResult=$($n.State.LastResult)"
Assert 'error2 原因写入状态' ($n.State.LastError -match '已在别处') "LastError=$($n.State.LastError)"
Assert 'state.json 不再出现 login-conflict' ($n.State.LastResult -ne 'login-conflict') "LastResult=$($n.State.LastResult)"

# 场景 6：登录失败 + 最小间隔 → 短时间不重复登录
$n = Invoke-Scenario -Name 's6-mininterval' -Scenario 'login-fail' -PortalHost "127.0.0.1:$Port" `
    -Targets @('tcp:127.0.0.1:65005') -Seconds 16 -OnlineProbe 2 -OfflineProbe 1
Assert '失败后 60 秒内不重复登录' ($n.Login -eq 1) "login=$($n.Login)（16 秒内应只有 1 次）"

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
    & $Exe '--set-credentials' 'testuser' 'testpass' '--data-dir' $dir | Out-String | Out-Null
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
    & $Exe '--set-credentials' 'testuser' 'testpass' '--data-dir' $dir | Out-String | Out-Null
    & $Exe '--run-seconds' 4 '--data-dir' $dir | Out-String | Out-Null
    return (Get-Content -LiteralPath (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$legacyDefault = @('tcp:223.5.5.5:443', 'tcp:114.114.114.114:53', 'tcp:www.msftconnecttest.com:80')
$migratedTargets = Invoke-TargetsMigration -Name 's8-legacy-targets' -Targets $legacyDefault
Assert 'pre.2 默认探测列表被换成内容校验目标' ($migratedTargets.ProbeTargets[0] -like 'http:*|Microsoft Connect Test') "ProbeTargets=$($migratedTargets.ProbeTargets -join ',')"
Assert '迁移后探测目标共 3 项' ($migratedTargets.ProbeTargets.Count -eq 3) "Count=$($migratedTargets.ProbeTargets.Count)"

$migrated = Invoke-ConfigMigration -Name 's8-migrate' -OnlineProbe 60
Assert '旧默认 60 秒迁移为 20 秒' ($migrated.OnlineProbeSeconds -eq 20) "OnlineProbeSeconds=$($migrated.OnlineProbeSeconds)"
Assert '迁移后写入 ConfigVersion=3' ($migrated.ConfigVersion -eq 3) "ConfigVersion=$($migrated.ConfigVersion)"
Assert '迁移后剔除 LoginCooldownMinutes' (-not ($migrated.PSObject.Properties.Name -contains 'LoginCooldownMinutes')) '仍存在该键'
Assert '迁移后保留自定义 ProbeTargets' (($migrated.ProbeTargets -join ',') -eq 'tcp:127.0.0.1:65001') "ProbeTargets=$($migrated.ProbeTargets -join ',')"

$custom = Invoke-ConfigMigration -Name 's8-custom' -OnlineProbe 45
Assert '自定义 45 秒不会被改写' ($custom.OnlineProbeSeconds -eq 45) "OnlineProbeSeconds=$($custom.OnlineProbeSeconds)"

# 场景 9：全新数据目录 → 默认配置就是「在线 20 秒 + 兜底 300 秒」
$freshDir = Join-Path $work 's9-default'
New-Item -ItemType Directory -Force -Path $freshDir | Out-Null
& $Exe '--set-credentials' 'testuser' 'testpass' '--data-dir' $freshDir | Out-String | Out-Null
& $Exe '--run-seconds' 4 '--data-dir' $freshDir | Out-String | Out-Null
$fresh = Get-Content -LiteralPath (Join-Path $freshDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert '新配置默认在线探测 20 秒' ($fresh.OnlineProbeSeconds -eq 20) "OnlineProbeSeconds=$($fresh.OnlineProbeSeconds)"
Assert '新配置默认兜底巡检 300 秒' ($fresh.UpstreamProbeSeconds -eq 300) "UpstreamProbeSeconds=$($fresh.UpstreamProbeSeconds)"
Assert '新配置默认带内容校验目标' ($fresh.ProbeTargets[0] -like 'http:*|Microsoft Connect Test') "ProbeTargets=$($fresh.ProbeTargets -join ',')"
Assert '新配置默认会话校验 300 秒' ($fresh.SessionCheckSeconds -eq 300) "SessionCheckSeconds=$($fresh.SessionCheckSeconds)"

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

Write-Host ''
$results | ForEach-Object { Write-Host $_ }
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures 个用例失败" -ForegroundColor Red
    exit 1
}
Write-Host '全部用例通过' -ForegroundColor Green
exit 0
