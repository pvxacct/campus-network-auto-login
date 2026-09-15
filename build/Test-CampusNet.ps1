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
        [int]$HourlyLimit = 12
    )
    $dataDir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    $logPath = Join-Path $dataDir 'portal-requests.log'
    Write-Config -Path (Join-Path $dataDir 'config.json') -PortalHost $PortalHost -OnlineProbe $OnlineProbe `
        -OfflineProbe $OfflineProbe -HourlyLimit $HourlyLimit -Targets $Targets

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

# 场景 5：重复认证冲突 → 只记原因，不进入冷却
$n = Invoke-Scenario -Name 's5-conflict' -Scenario 'conflict' -PortalHost "127.0.0.1:$Port" `
    -Targets @('tcp:127.0.0.1:65004') -Seconds 14 -OnlineProbe 2 -OfflineProbe 2
Assert '冲突后只登录一次' ($n.Login -eq 1) "login=$($n.Login)"
Assert '冲突后结果记为 login-conflict' ($n.State.LastResult -eq 'login-conflict') "LastResult=$($n.State.LastResult)"
Assert '冲突原因写入状态' ($n.State.LastError -match '已在别处') "LastError=$($n.State.LastError)"

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

$migrated = Invoke-ConfigMigration -Name 's8-migrate' -OnlineProbe 60
Assert '旧默认 60 秒迁移为 20 秒' ($migrated.OnlineProbeSeconds -eq 20) "OnlineProbeSeconds=$($migrated.OnlineProbeSeconds)"
Assert '迁移后写入 ConfigVersion=2' ($migrated.ConfigVersion -eq 2) "ConfigVersion=$($migrated.ConfigVersion)"
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

Write-Host ''
$results | ForEach-Object { Write-Host $_ }
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures 个用例失败" -ForegroundColor Red
    exit 1
}
Write-Host '全部用例通过' -ForegroundColor Green
exit 0
