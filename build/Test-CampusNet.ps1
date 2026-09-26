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
$script:lastRun = $null

function Write-Config {
    param(
        [string]$Path,
        [string]$PortalHost,
        [int]$OnlineProbe,
        [int]$OfflineProbe,
        [int]$SessionCheck = 120,
        [string[]]$Targets
    )
    $config = [ordered]@{
        ConfigVersion          = 10
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
        SessionCheckSeconds    = $SessionCheck
        StuckReloginSeconds    = 15
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

# 「断网」场景需要一个确定连不上的探测目标。以前这里写死 tcp:127.0.0.1:650xx，
# 而 Windows 的动态端口范围是 49152-65535：运行器上别的进程完全可能临时监听到同一个
# 端口（CI 上真的发生过一次），于是探测「通过」→ 程序判定在线 → 整个场景静默失效，
# 表现成「日志里没有登录记录」。现在改成先列一遍本机正在监听的端口，只挑没人听的那个。
# 用「谁在监听」而不是「连一次试试」：本机与 runner 上被拒绝的连接要等 SYN 重传（约 2 秒）
# 才返回，逐个端口试会白白拖慢整个用例集。
$script:listeningPorts = $null
function Get-ListeningTcpPorts {
    if ($null -ne $script:listeningPorts) { return $script:listeningPorts }
    $ports = New-Object 'System.Collections.Generic.HashSet[int]'
    try {
        foreach ($conn in (Get-NetTCPConnection -State Listen -ErrorAction Stop)) { [void]$ports.Add([int]$conn.LocalPort) }
    } catch {
    }
    if ($ports.Count -eq 0) {
        foreach ($line in (& netstat -ano -p TCP)) {
            if ($line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING') { [void]$ports.Add([int]$Matches[1]) }
        }
    }
    $script:listeningPorts = $ports
    return $ports
}
$script:offlineTargetPorts = @{}
function Get-OfflineLoopbackPort {
    param([int]$Preferred)
    if ($script:offlineTargetPorts.ContainsKey($Preferred)) { return $script:offlineTargetPorts[$Preferred] }
    $listening = Get-ListeningTcpPorts
    # 先试场景原本用的端口，再退到 1-64：低位端口 Windows 不会当动态端口分配出去。
    $candidates = @($Preferred) + (1..64)
    foreach ($candidate in $candidates) {
        if (-not $listening.Contains($candidate)) {
            $script:offlineTargetPorts[$Preferred] = $candidate
            return $candidate
        }
    }
    throw "找不到没人监听的回环端口，无法构造「断网」场景（候选：$($candidates -join ',')）。"
}
function Off-Target {
    param([int]$Preferred)
    return "tcp:127.0.0.1:$(Get-OfflineLoopbackPort -Preferred $Preferred)"
}

# 等假 Portal 真正开始监听再启动被测程序。固定 sleep 在冷启动的 runner 上不够：
# Portal 还没起来时程序每轮都只会报 unreachable，时间窗跑完都不会去登录（假失败）。
function Wait-PortalReady {
    param([string]$LogPath, [int]$TimeoutMs = 30000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $LogPath) {
            $first = @(Get-Content -LiteralPath $LogPath -TotalCount 1 -ErrorAction SilentlyContinue)[0]
            if ($first -and $first.StartsWith('START ')) { return }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "假 Portal 在 $TimeoutMs 毫秒内没有就绪：$LogPath"
}

# 断言失败时把「现场」一并写进 FAIL 行：CI 会把 FAIL 行做成注解，
# 这样下次不必只凭失败名字猜原因。
function Get-RunDiagnostic {
    $run = $script:lastRun
    if (-not $run) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    if ($run.Name) { $parts.Add('场景=' + $run.Name) }
    if ($null -ne $run.ExitCode) { $parts.Add('exit=' + $run.ExitCode) }
    if ($null -ne $run.Status) { $parts.Add('chkstatus=' + $run.Status + ' login=' + $run.Login) }
    if ($run.State) { $parts.Add('LastResult=' + $run.State.LastResult) }
    $requests = @($run.Requests)
    if ($requests.Count -gt 0) { $parts.Add('请求：' + (($requests | Select-Object -Last 4) -join ' / ')) }
    if ($run.Log) {
        $tail = ((@($run.Log -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 3) -join ' | ')
        $parts.Add('日志尾：' + $tail)
    }
    $text = $parts -join '；'
    if ($text.Length -gt 700) { $text = $text.Substring(0, 700) + '…' }
    return $text
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
        [int]$SessionCheck = 120
    )
    $dataDir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    $logPath = Join-Path $dataDir 'portal-requests.log'
    Write-Config -Path (Join-Path $dataDir 'config.json') -PortalHost $PortalHost -OnlineProbe $OnlineProbe `
        -OfflineProbe $OfflineProbe -SessionCheck $SessionCheck -Targets $Targets

    $portal = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $portalScript, '-Scenario', $Scenario, '-Port', $Port, '-LogPath', $logPath
    Wait-PortalReady -LogPath $logPath

    $exitCode = $null
    try {
        Set-TestCredentials -Dir $dataDir
        $output = & $Exe '--run-seconds' $Seconds '--data-dir' $dataDir 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
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
        $state = [pscustomobject]@{ LastResult = ''; LastError = ''; ConsecutiveFailures = 0; DayKey = ''; DayLoginSuccess = 0; DayLoginAttempts = 0 }
    }

    $logContent = ''
    $localLog = Join-Path $dataDir 'login.log'
    if (Test-Path -LiteralPath $localLog) { $logContent = Get-Content -LiteralPath $localLog -Raw -Encoding UTF8 }

    $run = [pscustomobject]@{
        Name = $Name; Status = $status; Login = $login; Logout = $logout
        Dir = $dataDir; LogPath = $logPath
        Requests = $requests; State = $state; Output = $output; Log = $logContent; ExitCode = $exitCode
    }
    $script:lastRun = $run
    return $run
}

function Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    if ($Condition) {
        $results.Add("PASS  $Name")
    } else {
        $script:failures++
        $diag = Get-RunDiagnostic
        if ($diag) { $Detail = $Detail + '｜现场：' + $diag }
        $results.Add("FAIL  $Name  -> $Detail")
    }
}

# 日志里两条记录相差多少秒（找不到任意一条返回 -1）
function Get-LogSecondsBetween {
    param([string]$Log, [string]$FromPattern, [string]$ToPattern)
    $a = [regex]::Match($Log, '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})[^\r\n]*' + $FromPattern)
    $b = [regex]::Match($Log, '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})[^\r\n]*' + $ToPattern)
    if (-not $a.Success -or -not $b.Success) { return -1 }
    $t1 = [datetime]::ParseExact($a.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null)
    $t2 = [datetime]::ParseExact($b.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null)
    return [math]::Round(($t2 - $t1).TotalSeconds, 0)
}

# 从假 Portal 的请求日志里取某一类请求的毫秒时间戳（每行形如 "GET /drcom/chkstatus @1727000000123"），
# 用来断言「两次核对之间隔了多久」这类节奏问题。
function Get-RequestTimes {
    param([string]$LogPath, [string]$Kind)
    $times = New-Object System.Collections.Generic.List[long]
    if (-not (Test-Path -LiteralPath $LogPath)) { return $times.ToArray() }
    foreach ($line in (Get-Content -LiteralPath $LogPath)) {
        if ($line -notmatch '^(GET|POST) ') { continue }
        if ($line -notmatch [regex]::Escape($Kind)) { continue }
        $m = [regex]::Match($line, '@(\d+)\s*$')
        if ($m.Success) { $times.Add([long]$m.Groups[1].Value) }
    }
    return $times.ToArray()
}

Write-Host "使用 exe：$Exe"
Write-Host "临时目录：$work"
Write-Host ''

# 场景 1：网络正常 → 完全不请求 Portal
$n = Invoke-Scenario -Name 's1-online' -Scenario 'online' -PortalHost "127.0.0.1:$Port" `
    -Targets @("tcp:127.0.0.1:$Port") -Seconds 10 -OnlineProbe 2
Assert '正常联网时不请求 Portal' ($n.Status -eq 0 -and $n.Login -eq 0) "chkstatus=$($n.Status) login=$($n.Login)"
Assert '启动时订阅了系统网络变化事件' ($n.Log -match '已订阅网络变化事件') '登录日志里没有订阅记录'

# 场景 2：断网 → 自动登录成功
# 「网络恢复」现在以本机内容校验为准（Portal 说在线不算数），所以探测目标要用内容校验目标：
# 假 Portal 只有在真的允许上网（login>=1）之后才回关键字。只连一个死端口的 TCP 目标无法表达
# 「恢复」，ConfirmRecovered 会一直判失败。
$n = Invoke-Scenario -Name 's2-offline-login' -Scenario 'offline-ok' -PortalHost "127.0.0.1:$Port" `
    -Targets @("http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test") -Seconds 14 -OnlineProbe 2 -OfflineProbe 2
Assert '断网后自动登录且只登录一次' ($n.Login -eq 1) "login=$($n.Login)"
Assert '登录成功后状态为 login-ok/online' ($n.State.LastResult -eq 'login-ok' -or $n.State.LastResult -eq 'online') "LastResult=$($n.State.LastResult)"

# 场景 3：第一次显示离线、复检已在线 → 不登录
$n = Invoke-Scenario -Name 's3-confirm' -Scenario 'confirm-online' -PortalHost "127.0.0.1:$Port" `
    -Targets @(Off-Target 65002) -Seconds 12 -OnlineProbe 2 -OfflineProbe 2
Assert '复检在线时不登录' ($n.Login -eq 0) "login=$($n.Login)"

# 场景 4：Portal 限流 → 本次不再重试，原因写进状态（不再有冷却）
# 删掉「最小间隔 / 每小时上限」之后，唯一还会拦住登录的就是 Portal 自己说的 waitsec；
# 这里把异常探测拉长到 8 秒，让用例在「暂停 3 秒」内跑完，不会被下一轮登录打断。
$n = Invoke-Scenario -Name 's4-ratelimit' -Scenario 'rate-limited' -PortalHost "127.0.0.1:$Port" `
    -Targets @(Off-Target 65003) -Seconds 6 -OnlineProbe 2 -OfflineProbe 8
Assert '限流后只登录一次' ($n.Login -eq 1) "login=$($n.Login)"
Assert '限流后结果记为 login-throttled' ($n.State.LastResult -eq 'login-throttled') "LastResult=$($n.State.LastResult)"
Assert '限流原因写入状态' ($n.State.LastError -match '限流') "LastError=$($n.State.LastError)"
Assert '按 Portal 给的 waitsec 秒数暂停' ($n.Log -match '暂停 3 秒') "日志=$($n.Log -replace [Environment]::NewLine, ' | ')"
Assert 'state.json 不再有冷却字段' (-not ($n.State.PSObject.Properties.Name -contains 'CooldownUntil') `
    -and -not ($n.State.PSObject.Properties.Name -contains 'CooldownReason')) "字段=$($n.State.PSObject.Properties.Name -join ',')"

# 场景 5：Portal 提示「账号已在别处在线 / 密码错误」→ 完全忽略，不记失败、不写「最近错误」
# 2.1.3-pre.1：首次提交被回 error2 且 3 秒短窗内本机仍上不了网 → 先注销、再重登一次；
# 第二次仍被回 error2 时不再第三次提交，等 30 秒密集复检窗口走完，本轮以 login-retry 收尾。
$n = Invoke-Scenario -Name 's5-conflict' -Scenario 'conflict' -PortalHost "127.0.0.1:$Port" `
    -Targets @(Off-Target 65004) -Seconds 45 -OnlineProbe 2 -OfflineProbe 20
Assert 'error2 后先注销再重登，共提交 2 次、不再有第三次' ($n.Login -eq 2 -and $n.Logout -eq 1) "login=$($n.Login) logout=$($n.Logout)"
Assert 'error2 不再记为登录失败' ($n.State.LastResult -eq 'login-retry') "LastResult=$($n.State.LastResult)"
Assert 'error2 不写「最近错误」' ([string]::IsNullOrEmpty($n.State.LastError)) "LastError=$($n.State.LastError)"
Assert 'error2 计入「已忽略提示」' ($n.State.IgnoredPrompts -ge 1) "IgnoredPrompts=$($n.State.IgnoredPrompts)"
Assert 'error2 的提示原文被记下' ($n.State.LastIgnoredPrompt -match 'error2|已在别处|密码') "LastIgnoredPrompt=$($n.State.LastIgnoredPrompt)"
Assert '日志里写明提示已忽略' ($n.Log -match '提示已忽略') '日志未出现「提示已忽略」'
Assert 'state.json 不再出现 login-conflict' ($n.State.LastResult -ne 'login-conflict') "LastResult=$($n.State.LastResult)"

# 场景 6：登录接口回了完全无法识别的响应 → 这才是真正的失败，照实记录
# 提交失败后要跑满 30 秒密集复检窗口才算「本轮结束」，所以给足运行时间；
# 异常探测 20 秒保证第二次登录不会在时间窗里出现，断言才稳。
$n = Invoke-Scenario -Name 's6-login-failed' -Scenario 'garbage' -PortalHost "127.0.0.1:$Port" `
    -Targets @(Off-Target 65005) -Seconds 40 -OnlineProbe 2 -OfflineProbe 20
Assert '无法识别的响应只提交一次登录' ($n.Login -eq 1) "login=$($n.Login)"
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
    $offlineTarget = Off-Target 65001
    $legacy = [ordered]@{
        PortalHost             = '127.0.0.1:65010'
        OnlineProbeSeconds     = $OnlineProbe
        OfflineProbeSeconds    = 2
        ConfirmAttempts        = 1
        ConfirmGapMs           = 200
        LoginCooldownMinutes   = 30
        ProbeTargets           = @($offlineTarget)
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
Assert 'pre.5 配置迁移后写入 ConfigVersion=10' ($migratedV3.ConfigVersion -eq 10) "ConfigVersion=$($migratedV3.ConfigVersion)"

$migrated = Invoke-ConfigMigration -Name 's8-migrate' -OnlineProbe 60
Assert '旧默认 60 秒迁移为 15 秒' ($migrated.OnlineProbeSeconds -eq 15) "OnlineProbeSeconds=$($migrated.OnlineProbeSeconds)"
Assert '迁移后写入 ConfigVersion=10' ($migrated.ConfigVersion -eq 10) "ConfigVersion=$($migrated.ConfigVersion)"
Assert '迁移后剔除 LoginCooldownMinutes' (-not ($migrated.PSObject.Properties.Name -contains 'LoginCooldownMinutes')) '仍存在该键'
Assert '迁移后保留自定义 ProbeTargets' (($migrated.ProbeTargets -join ',') -eq (Off-Target 65001)) "ProbeTargets=$($migrated.ProbeTargets -join ',')"

$custom = Invoke-ConfigMigration -Name 's8-custom' -OnlineProbe 45
Assert '自定义 45 秒不会被改写' ($custom.OnlineProbeSeconds -eq 45) "OnlineProbeSeconds=$($custom.OnlineProbeSeconds)"

# 场景 9：全新数据目录 → 默认配置就是「在线 20 秒 + 兜底 300 秒」
$freshDir = Join-Path $work 's9-default'
New-Item -ItemType Directory -Force -Path $freshDir | Out-Null
Set-TestCredentials -Dir $freshDir
& $Exe '--run-seconds' 4 '--data-dir' $freshDir | Out-String | Out-Null
$fresh = Get-Content -LiteralPath (Join-Path $freshDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert '新配置默认在线探测 15 秒' ($fresh.OnlineProbeSeconds -eq 15) "OnlineProbeSeconds=$($fresh.OnlineProbeSeconds)"
Assert '新配置默认兜底巡检 300 秒' ($fresh.UpstreamProbeSeconds -eq 300) "UpstreamProbeSeconds=$($fresh.UpstreamProbeSeconds)"
Assert '新配置默认带「204 内容校验」目标' ($fresh.ProbeTargets[0] -eq 'http:connect.rom.miui.com/generate_204|204') "ProbeTargets=$($fresh.ProbeTargets -join ',')"
Assert '新配置默认共 4 条探测目标' ($fresh.ProbeTargets.Count -eq 4) "Count=$($fresh.ProbeTargets.Count)"
Assert '新配置默认保留微软内容校验目标' (($fresh.ProbeTargets -join ' ') -match 'msftconnecttest') "ProbeTargets=$($fresh.ProbeTargets -join ',')"
Assert '新配置默认会话核对 120 秒' ($fresh.SessionCheckSeconds -eq 120) "SessionCheckSeconds=$($fresh.SessionCheckSeconds)"
Assert '新配置默认异常探测 3 秒' ($fresh.OfflineProbeSeconds -eq 3) "OfflineProbeSeconds=$($fresh.OfflineProbeSeconds)"
Assert '新配置默认残留重登 15 秒' ($fresh.StuckReloginSeconds -eq 15) "StuckReloginSeconds=$($fresh.StuckReloginSeconds)"
Assert '新配置写入 ConfigVersion=10' ($fresh.ConfigVersion -eq 10) "ConfigVersion=$($fresh.ConfigVersion)"
Assert '新配置默认登录前确认 1 秒' ($fresh.LoginConfirmDelaySec -eq 1) "LoginConfirmDelaySec=$($fresh.LoginConfirmDelaySec)"
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
Assert '定时核对的日志写明来源' ($n.Log -match '会话核对：') '日志里没有「会话核对：」'
Assert '定时核对在状态里记为 periodic' ($n.State.LastSessionCheckKind -eq 'periodic') "LastSessionCheckKind=$($n.State.LastSessionCheckKind)"

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

# 场景 14a：既要求内容、又只认 204 的目标拿到 200 + 劫持页 → 判失败并自动登录
#（以前写成 url|文本|204，解析器只认一个竖线，于是「期望 204」其实从未生效——本次修正并真正测到）
$n = Invoke-Scenario -Name 's14-expect-204' -Scenario 'offline-ok' -PortalHost "127.0.0.1:$Port" `
    -Targets @("http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test|204") -Seconds 45 -OnlineProbe 2 -OfflineProbe 20
Assert '期望 204 却拿到 200 时判定为不在线' ($n.Status -ge 1) "chkstatus=$($n.Status)"
Assert '期望 204 失败后会自动登录' ($n.Login -eq 1) "login=$($n.Login)"
# 这个目标要求「204 状态码 + 响应体含关键字」，而 204 按规范没有响应体 —— 本机内容校验永远不可能通过，
# 于是 Portal 说在线也**不能**算恢复（这正是 2.1.3-pre.1 把判定改成以本机内容为准的意义）。
Assert '本机内容始终不达标时不假报成功' ($n.State.LastResult -eq 'login-unconfirmed') "LastResult=$($n.State.LastResult)"

# 场景 14b：假 Portal 真的回 204（generate_204 的正常情形）→ 判定在线，一个 Portal 请求都不发
$n = Invoke-Scenario -Name 's14b-real-204' -Scenario 'content-204' -PortalHost "127.0.0.1:$Port" `
    -Targets @("http:127.0.0.1:$Port/connecttest.txt|204") -Seconds 10 -OnlineProbe 2
Assert '真的拿到 204 时判为在线' ($n.Status -eq 0 -and $n.Login -eq 0) "chkstatus=$($n.Status) login=$($n.Login)"
Assert '真 204 后状态为 online' ($n.State.LastResult -eq 'online') "LastResult=$($n.State.LastResult)"

# 场景 15：**残留会话**（2.1.3-pre.1 的核心提速路径，真机 6/6 样本）
# Portal 对每次登录都回「已在别处在线」（error2），本机却上不了网：3 秒短窗内没恢复就
# 立刻「注销 → 等 3 秒 → 重新登录」；第二次提交后本机内容校验通过即判成功。
$n = Invoke-Scenario -Name 's15-ghost-session' -Scenario 'ghost-session' -PortalHost "127.0.0.1:$Port" `
    -Targets @("http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test") -Seconds 20 -OnlineProbe 2 -OfflineProbe 2
Assert '残留会话：先注销再重新登录（共提交 2 次）' ($n.Login -eq 2 -and $n.Logout -eq 1) "login=$($n.Login) logout=$($n.Logout)"
Assert '残留会话：日志写明检测到残留会话' ($n.Log -match '检测到残留会话') '日志里没有「检测到残留会话」'
# 恢复那一刻写的是 login-ok；运行窗口还会再跑一轮探测，正常在线时状态会翻成 online，两者都算成功。
Assert '残留会话：注销重登后判为登录成功' ($n.State.LastResult -eq 'login-ok' -or $n.State.LastResult -eq 'online') "LastResult=$($n.State.LastResult)"
$ghostDelta = Get-LogSecondsBetween -Log $n.Log -FromPattern '第 1/1 次尝试登录' -ToPattern '自动登录成功'
Assert '残留会话：提交 → 确认 ≤ 10 秒' ($ghostDelta -ge 0 -and $ghostDelta -le 10) "提交到确认相隔 $ghostDelta 秒"
Assert '残留会话：今日提交 2 次、成功 1 次' ($n.State.DayLoginAttempts -eq 2 -and $n.State.DayLoginSuccess -eq 1) `
    "attempts=$($n.State.DayLoginAttempts) success=$($n.State.DayLoginSuccess)"

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
    -Targets @(Off-Target 65011) -Seconds 34 -OnlineProbe 2 -OfflineProbe 2
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
    Wait-PortalReady -LogPath $logPath
    $exitCode = $null
    try {
        if (-not $SkipCredentials) { Set-TestCredentials -Dir $dir }
        $output = & $Exe '--run-seconds' $Seconds '--data-dir' $dir 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
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
    $run = [pscustomobject]@{
        Name = $Name; Dir = $dir; Requests = $requests; State = $state; Log = $logContent; Output = $output
        Status = (@($requests | Where-Object { $_ -match 'chkstatus' }).Count)
        Login = (@($requests | Where-Object { $_ -match 'login' }).Count)
        ExitCode = $exitCode
    }
    $script:lastRun = $run
    return $run
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
        ConfigVersion       = 10
        PortalHost          = "127.0.0.1:$Port"
        EportalPort         = 801
        StatusPath          = '/drcom/chkstatus'
        LoginPath           = '/drcom/login'
        LogoutPath          = '/drcom/logout'
        ErrorPromptPath     = '/eportal/portal/err_code/loadErrorPrompt'
        OnlineProbeSeconds  = 15
        OfflineProbeSeconds = 2
        ProbeTimeoutMs      = 500
        HttpProbeTimeoutMs  = 1200
        ConfirmAttempts     = 2
        ConfirmGapMs        = 200
        ProbeTargets        = @($targets)
        SessionCheckSeconds = 120
        StuckReloginSeconds = 15
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
Wait-PortalReady -LogPath $bhLog
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
$ratio = [math]::Round($swFour.Elapsed.TotalSeconds / [math]::Max(0.01, $swOne.Elapsed.TotalSeconds), 2)
# 判定用「比值」而不是绝对秒数：CI runner 上进程启动 + 首次连通往往比本机慢一倍以上，
# 绝对差值会随机器负载漂移（2.0.0-pre.10 的 CI 就因此误报过一次）。
# 串行会接近 4 倍，并行应当明显低于 2.6 倍——判别力比绝对差值更强。
Assert '探测目标并行执行（4 条不比 1 条慢多少）' ($ratio -lt 2.6) `
    "1 条=$([math]::Round($swOne.Elapsed.TotalSeconds, 2))s，4 条=$([math]::Round($swFour.Elapsed.TotalSeconds, 2))s，差 $delta s，比值 $ratio（串行约 4 倍）"
Assert '黑洞目标如实报「不通」' ($outOne -match '不通' -or $outOne -match '失败') '诊断输出没有体现探测失败'

# 场景 23：pre.6 的复检参数（3 轮 / 1000 毫秒）迁移为 2 轮 / 500 毫秒，自定义值原样保留
function Invoke-ConfirmMigration {
    param([string]$Name, [int]$Attempts, [int]$Gap)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $offlineTarget = Off-Target 65013
    $legacy = [ordered]@{
        ConfigVersion        = 4
        PortalHost           = "127.0.0.1:$Port"
        OnlineProbeSeconds   = 20
        OfflineProbeSeconds  = 2
        ProbeTimeoutMs       = 500
        ConfirmAttempts      = $Attempts
        ConfirmGapMs         = $Gap
        ProbeTargets         = @($offlineTarget)
    }
    ($legacy | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
    Set-TestCredentials -Dir $dir
    & $Exe '--run-seconds' 4 '--data-dir' $dir | Out-String | Out-Null
    return (Get-Content -LiteralPath (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$confirmMigrated = Invoke-ConfirmMigration -Name 's23-migrate' -Attempts 3 -Gap 1000
Assert 'pre.6 的复检节奏迁移为 2 轮 / 500 毫秒' ($confirmMigrated.ConfirmAttempts -eq 2 -and $confirmMigrated.ConfirmGapMs -eq 500) `
    "Attempts=$($confirmMigrated.ConfirmAttempts) Gap=$($confirmMigrated.ConfirmGapMs)"
Assert '迁移后写入 ConfigVersion=10' ($confirmMigrated.ConfigVersion -eq 10) "ConfigVersion=$($confirmMigrated.ConfigVersion)"
$confirmCustom = Invoke-ConfirmMigration -Name 's23-custom' -Attempts 4 -Gap 1500
Assert '自定义复检参数不被改写' ($confirmCustom.ConfirmAttempts -eq 4 -and $confirmCustom.ConfirmGapMs -eq 1500) `
    "Attempts=$($confirmCustom.ConfirmAttempts) Gap=$($confirmCustom.ConfirmGapMs)"

# ------------------------------------------------------------------ pre.8：审查发现的 6 类问题

function New-RawConfig {
    param(
        [string]$PortalHost,
        [string[]]$Targets,
        [int]$RetryCount = 1,
        [int]$OnlineProbe = 15,
        [int]$OfflineProbe = 2,
        [int]$LoginTimeout = 5,
        [int]$StatusTimeout = 5
    )
    $cfg = [ordered]@{
        ConfigVersion           = 10
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
        SessionCheckSeconds     = 120
        StuckReloginSeconds     = 15
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
    Wait-PortalReady -LogPath $logPath
    $exitCode = $null
    try {
        Set-TestCredentials -Dir $dir -User $User -Password $Password
        $output = & $Exe '--run-seconds' $Seconds '--data-dir' $dir 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
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
    $state = if ($stateText) { $stateText | ConvertFrom-Json } else { [pscustomobject]@{ LastResult = ''; LastError = ''; DayKey = ''; DayLoginSuccess = 0; DayLoginAttempts = 0 } }
    $logText = ''
    $localLog = Join-Path $dir 'login.log'
    if (Test-Path -LiteralPath $localLog) { $logText = Get-Content -LiteralPath $localLog -Raw -Encoding UTF8 }
    $run = [pscustomobject]@{
        Name = $Name; Dir = $dir; LogPath = $logPath; Requests = $requests; State = $state; StateText = $stateText; Log = $logText; Output = $output
        Status = (@($requests | Where-Object { $_ -match 'chkstatus' }).Count)
        Login = (@($requests | Where-Object { $_ -match 'login' }).Count)
        ExitCode = $exitCode
    }
    $script:lastRun = $run
    return $run
}
Write-Host ''
# 场景 24：Portal 把提交的表单回显出来 → 密码与账号都不能落进日志 / state.json
# （「复制诊断信息」读的就是这两处，它们干净 = 剪贴板干净）
$n = Invoke-RawRun -Name 's24-redact' -Scenario 'echo-form' -Seconds 16 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" -Targets @(Off-Target 65014)) `
    -User 'sectestacct' -Password 'SecretPass123'
Assert '日志里不出现密码原文' ($n.Log -notmatch 'SecretPass123') '密码落进了 login.log'
Assert 'state.json 里不出现密码原文' ($n.StateText -notmatch 'SecretPass123') '密码落进了 state.json'
Assert '日志里 upass 的值被打码' ($n.Log -match 'upass=\*\*\*') 'upass 没有被替换成 ***'
Assert '日志里不出现完整账号' ($n.Log -notmatch 'sectestacct') '完整账号落进了 login.log'
Assert '日志里账号显示为掩码' ($n.Log -match 'sec\*{8}') '账号没有按掩码写入'
Assert 'state.json 里不出现完整账号' ($n.StateText -notmatch 'sectestacct') '完整账号落进了 state.json'

# 场景 25：删掉「最小间隔」之后，重试仍然不会秒级连打 —— 每一次提交都排在 30 秒密集复检窗口之后。
$n = Invoke-RawRun -Name 's25-retry-window' -Scenario 'garbage' -Seconds 20 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" -Targets @(Off-Target 65015) -RetryCount 3 -OfflineProbe 20)
Assert '复检窗口内不会连打重试（20 秒内只提交 1 次）' ($n.Login -eq 1) "login=$($n.Login)，RetryCount=3 也一样"
Assert '重试编号仍是第 1/3 次（RetryCount 上限没有被忽略）' ($n.Log -match '第 1/3 次尝试登录') '日志里没有第 1/3 次尝试记录'

# 场景 26：**没有最小间隔**了 —— 一次失败的恢复走完 30 秒窗口后，下一次提交不必再等 60 秒。
# 同时确认两个限速键从配置与状态里彻底删除。
$n = Invoke-RawRun -Name 's26-no-min-interval' -Scenario 'garbage' -Seconds 45 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" -Targets @(Off-Target 65016) -RetryCount 1 -OfflineProbe 5)
Assert '失败恢复后仍在时间窗内继续尝试（≥2 次提交）' ($n.Login -ge 2) "login=$($n.Login)"
$loginTimes = @(Get-RequestTimes -LogPath $n.LogPath -Kind 'login')
$loginGap = if ($loginTimes.Count -ge 2) { [math]::Round(($loginTimes[1] - $loginTimes[0]) / 1000.0, 1) } else { -1 }
Assert '两次提交之间不再有 60 秒最小间隔' ($loginGap -ge 0 -and $loginGap -lt 60) "两次提交相隔 $loginGap 秒"
$cfgText = Get-Content -LiteralPath (Join-Path $n.Dir 'config.json') -Raw -Encoding UTF8
Assert '配置里不再有 LoginMinIntervalSeconds' ($cfgText -notmatch 'LoginMinIntervalSeconds') '配置里还有最小间隔键'
Assert '配置里不再有 LoginHourlyLimit' ($cfgText -notmatch 'LoginHourlyLimit') '配置里还有每小时上限键'
Assert '状态里不再有 LoginWindowStart/Count' ($n.StateText -notmatch 'LoginWindow') '状态里还有小时窗口字段'
Assert '状态里出现今日计数三键' ($n.StateText -match 'DayKey' -and $n.StateText -match 'DayLoginAttempts' -and $n.StateText -match 'DayLoginSuccess') '状态里没有今日计数'

# 场景 27：守护的「卡死」阈值随配置放宽，不再把正在登录的进程杀掉
$dynDir = Join-Path $work 's27-watchdog-dynamic'
New-Item -ItemType Directory -Force -Path $dynDir | Out-Null
Set-Content -LiteralPath (Join-Path $dynDir 'config.json') `
    -Value (New-RawConfig -PortalHost '127.0.0.1:65099' -Targets @(Off-Target 65017) `
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
$dynStaleMatch = [regex]::Match($watchDyn.Text, '卡死阈值：(\d+) 秒')
$dynStale = if ($dynStaleMatch.Success) { [int]$dynStaleMatch.Groups[1].Value } else { 0 }
Assert '阈值随配置放大（大 RetryCount + 30 秒复检窗口 → 300 秒以上）' ($dynStale -ge 300 -and $dynStale -le 900) "阈值=$dynStale 秒"

# 场景 28：--uninstall --check-only 只打印计划，不删任何东西
$planDir = Join-Path $work 's28-uninstall-plan'
New-Item -ItemType Directory -Force -Path $planDir | Out-Null
$marker = Join-Path $planDir 'state.json'
Set-Content -LiteralPath $marker -Value '{ "LastResult": "online" }' -Encoding UTF8
$planOut = Join-Path $planDir 'uninstall-plan.txt'
# 计划文本随「本机有没有已安装的程序文件」而不同：CI 是干净机器（走便携分支），
# 开发机通常已经装过（走删除分支）。两条分支都要真跑一遍——
# 缺的那条用我们自己建的占位文件补上，检查完立刻删掉（绝不碰真实安装的文件）。
$installedExe = Join-Path $env:LOCALAPPDATA 'Programs\CampusNet\CampusNet.exe'
$installedDir = Split-Path -Parent $installedExe
$placeholderMade = $false
if (-not (Test-Path -LiteralPath $installedExe)) {
    $portableProc = Start-Process -FilePath $Exe -ArgumentList '--uninstall', '--check-only', '--data-dir', $planDir `
        -RedirectStandardOutput $planOut -Wait -PassThru
    $portableText = ''
    if (Test-Path -LiteralPath $planOut) { $portableText = Get-Content -LiteralPath $planOut -Raw -Encoding UTF8 }
    Assert '便携模式计划退出码为 0' ($portableProc.ExitCode -eq 0) "exit=$($portableProc.ExitCode)"
    Assert '便携模式计划写明无需删除' ($portableText -match '无需删除') '便携模式下没说清楚'
    New-Item -ItemType Directory -Force -Path $installedDir | Out-Null
    Set-Content -LiteralPath $installedExe -Value 'placeholder for uninstall-plan test' -Encoding ASCII
    $placeholderMade = $true
}
try {
    $planProc = Start-Process -FilePath $Exe -ArgumentList '--uninstall', '--check-only', '--data-dir', $planDir `
        -RedirectStandardOutput $planOut -Wait -PassThru
    $planText = ''
    if (Test-Path -LiteralPath $planOut) { $planText = Get-Content -LiteralPath $planOut -Raw -Encoding UTF8 }
    Assert '卸载计划退出码为 0' ($planProc.ExitCode -eq 0) "exit=$($planProc.ExitCode)"
    Assert '卸载计划含程序文件路径' ($planText -match 'CampusNet\.exe') '计划里没提到程序文件'
    Assert '卸载计划含当前 PID' ($planText -match 'PID') '计划里没有 PID'
    Assert '卸载计划说明重启兜底' ($planText -match '重启') '计划里没写重启兜底'
    Assert '--check-only 不删数据目录' (Test-Path -LiteralPath $marker) '数据文件被删了'
}
finally {
    if ($placeholderMade -and (Test-Path -LiteralPath $installedExe)) {
        Remove-Item -LiteralPath $installedExe -Force
        if ((Test-Path -LiteralPath $installedDir) -and -not (Get-ChildItem -LiteralPath $installedDir -Force)) {
            Remove-Item -LiteralPath $installedDir -Force
        }
    }
}

# 场景 30：v5 -> v6 迁移——会话核对间隔的旧默认值 300 秒缩短为 120 秒
function Invoke-SessionMigration {
    param([string]$Name, [int]$SessionCheck)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $offlineTarget = Off-Target 65015
    $legacy = [ordered]@{
        ConfigVersion        = 5
        PortalHost           = "127.0.0.1:$Port"
        OnlineProbeSeconds   = 20
        OfflineProbeSeconds  = 2
        ProbeTimeoutMs       = 500
        SessionCheckSeconds  = $SessionCheck
        UpstreamProbeSeconds = 300
        ProbeTargets         = @($offlineTarget)
    }
    ($legacy | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
    Set-TestCredentials -Dir $dir
    & $Exe '--run-seconds' 3 '--data-dir' $dir | Out-String | Out-Null
    return (Get-Content -LiteralPath (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$sessMigrated = Invoke-SessionMigration -Name 's30-session-migrate' -SessionCheck 300
Assert '旧默认会话核对 300 秒迁移为 120 秒' ($sessMigrated.SessionCheckSeconds -eq 120) "SessionCheckSeconds=$($sessMigrated.SessionCheckSeconds)"
Assert '会话核对迁移后写入 ConfigVersion=10' ($sessMigrated.ConfigVersion -eq 10) "ConfigVersion=$($sessMigrated.ConfigVersion)"
Assert '迁移不会动同为 300 的兜底巡检间隔' ($sessMigrated.UpstreamProbeSeconds -eq 300) "UpstreamProbeSeconds=$($sessMigrated.UpstreamProbeSeconds)"
$sessCustom = Invoke-SessionMigration -Name 's30-session-custom' -SessionCheck 240
Assert '自定义会话核对 240 秒不被改写' ($sessCustom.SessionCheckSeconds -eq 240) "SessionCheckSeconds=$($sessCustom.SessionCheckSeconds)"

# 场景 31：疑似掉线核对提速——两次核对间隔从 20 秒收到 10 秒（2.1.3-pre.1 的新常量）
# 内容校验目标被假 Portal 用「连得上但没有关键字」的响应骗过（等价于网关代答），
# 于是走「疑似掉线」路径：连续 1 轮就核对一次 Portal，之后每隔 SuspectVerifyMinSeconds 再核对一次。
$n = Invoke-Scenario -Name 's31-suspect-fast' -Scenario 'online-then-offline' -PortalHost "127.0.0.1:$Port" `
    -Targets @("tcp:127.0.0.1:$Port", "http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test") `
    -Seconds 40 -OnlineProbe 2 -OfflineProbe 2
Assert '疑似掉线时 40 秒内完成两次核对（旧常量 60 秒做不到）' ($n.Status -ge 2) "chkstatus=$($n.Status)"
Assert '疑似路径的日志写明来源' ($n.Log -match '疑似掉线核对：') '日志里没有「疑似掉线核对：」'
Assert '疑似核对在状态里记为 suspect' ($n.State.LastSessionCheckKind -eq 'suspect') "LastSessionCheckKind=$($n.State.LastSessionCheckKind)"
Assert '核对发现离线后自动登录' ($n.Login -ge 1) "login=$($n.Login)"

# 用假 Portal 的请求时间戳量两次核对的间隔：≥10 秒说明节流生效，明显小于 20 秒说明确实提速了。
$chkTimes = @(Get-RequestTimes -LogPath $n.LogPath -Kind 'chkstatus')
$chkGap = if ($chkTimes.Count -ge 2) { [math]::Round(($chkTimes[1] - $chkTimes[0]) / 1000.0, 1) } else { -1 }
Assert '两次疑似核对间隔 ≥10 秒且 <20 秒（20 → 10 秒已生效）' ($chkGap -ge 10 -and $chkGap -lt 20) `
    "间隔=$chkGap 秒（chkstatus=$($chkTimes.Count) 次）"

# 场景 32：--relogin 必须等「注销 + 重新登录」真正跑完
# 旧写法固定跑 25 秒，注销成功、等待 3 秒后就直接退出了，登录请求根本没提交。
$reloginDir = Join-Path $work 's32-relogin'
New-Item -ItemType Directory -Force -Path $reloginDir | Out-Null
Write-Config -Path (Join-Path $reloginDir 'config.json') -PortalHost "127.0.0.1:$Port" -OnlineProbe 2 `
    -OfflineProbe 2 -SessionCheck 120 -Targets @("tcp:127.0.0.1:$Port")
$reloginRequestLog = Join-Path $reloginDir 'portal-requests.log'
$reloginPortal = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $portalScript, '-Scenario', 'online', '-Port', $Port, '-LogPath', $reloginRequestLog
Wait-PortalReady -LogPath $reloginRequestLog
try {
    Set-TestCredentials -Dir $reloginDir
    $swRelogin = [System.Diagnostics.Stopwatch]::StartNew()
    $reloginOut = & $Exe '--relogin' '--data-dir' $reloginDir 2>&1 | Out-String
    $swRelogin.Stop()
}
finally {
    try { Stop-Process -Id $reloginPortal.Id -Force -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 200
}
$reloginRequests = @()
if (Test-Path -LiteralPath $reloginRequestLog) { $reloginRequests = Get-Content -LiteralPath $reloginRequestLog | Where-Object { $_ -match '^(GET|POST) ' } }
$reloginLogin = (@($reloginRequests | Where-Object { $_ -match 'login' }).Count)
$reloginLogout = (@($reloginRequests | Where-Object { $_ -match 'logout' }).Count)
Assert '--relogin 注销之后确实提交了登录' ($reloginLogout -ge 1 -and $reloginLogin -ge 1) "logout=$reloginLogout login=$reloginLogin"
Assert '--relogin 跑完就退出（不空等固定秒数）' ($swRelogin.Elapsed.TotalSeconds -lt 20) "耗时 $([math]::Round($swRelogin.Elapsed.TotalSeconds, 1)) 秒"
Assert '--relogin 输出带最终状态' ($reloginOut -match '状态：') '输出里没有状态行'

# 场景 29：界面布局扫描——任何 Grid 用到未声明的行/列都要失败。
# WPF 对越界行号不报错，而是把控件塞进最后一行：pre.7 的高级设置整行叠印就是这么来的。
# 2.1.0 起主窗口与「高级设置」独立窗口都要过这一关。
# 坑：XmlNamespaceManager 与 XmlNode 本身都是「可枚举」的（前者枚举前缀、后者枚举子节点），
# 所以只要穿过函数参数或管道就会被 PowerShell 拆成数组（实测报错
# "Cannot convert System.Object[] to type XmlNamespaceManager"）。全部在脚本作用域里直接持有。
$xamlPath = Join-Path $repo 'src\CampusNet\MainWindow.xaml'
$advancedXamlPath = Join-Path $repo 'src\CampusNet\AdvancedWindow.xaml'
$mainXamlText = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$advancedXamlText = Get-Content -LiteralPath $advancedXamlPath -Raw -Encoding UTF8
[xml]$xamlDoc = $mainXamlText
[xml]$advancedDoc = $advancedXamlText
$ns = New-Object System.Xml.XmlNamespaceManager($xamlDoc.NameTable)
$ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$ns.AddNamespace('xa', 'http://schemas.microsoft.com/winfx/2006/xaml')
$advancedNs = New-Object System.Xml.XmlNamespaceManager($advancedDoc.NameTable)
$advancedNs.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$advancedNs.AddNamespace('xa', 'http://schemas.microsoft.com/winfx/2006/xaml')

$overflow = New-Object System.Collections.Generic.List[string]
$scanTargets = @(
    @{ Doc = $xamlDoc; XmlNs = $ns; Label = '主窗口' },
    @{ Doc = $advancedDoc; XmlNs = $advancedNs; Label = '高级设置窗口' }
)
foreach ($scan in $scanTargets) {
    $doc = $scan.Doc
    $xmlNs = $scan.XmlNs
    $label = $scan.Label
    $index = 0
    foreach ($grid in $doc.SelectNodes('//x:Grid', $xmlNs)) {
        $index++
        $rows = $grid.SelectNodes('x:Grid.RowDefinitions/x:RowDefinition', $xmlNs).Count
        $cols = $grid.SelectNodes('x:Grid.ColumnDefinitions/x:ColumnDefinition', $xmlNs).Count
        foreach ($child in $grid.SelectNodes('*', $xmlNs)) {
            if ($child.LocalName -eq 'Grid.RowDefinitions' -or $child.LocalName -eq 'Grid.ColumnDefinitions') { continue }
            $row = $child.GetAttribute('Grid.Row')
            $col = $child.GetAttribute('Grid.Column')
            if ($row -ne '' -and [int]$row -ge $rows) {
                $overflow.Add("$label 第 $index 个 Grid 的 $($child.LocalName) 用到 Grid.Row=$row，只声明了 $rows 行")
            }
            if ($col -ne '' -and [int]$col -ge $cols) {
                $overflow.Add("$label 第 $index 个 Grid 的 $($child.LocalName) 用到 Grid.Column=$col，只声明了 $cols 列")
            }
        }
    }
}
Assert '界面 XAML 没有行列越界' ($overflow.Count -eq 0) ($overflow -join '；')

# 视觉规范：卡片内边距统一、日志区不再挤成一坨（2.0.0 的界面整理）
$appXamlPath = Join-Path $repo 'src\CampusNet\App.xaml'
[xml]$appDoc = Get-Content -LiteralPath $appXamlPath -Raw -Encoding UTF8
$xNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
$cardPadding = ''
foreach ($style in $appDoc.SelectNodes('//x:Style', $ns)) {
    if ($style.GetAttribute('Key', $xNs) -ne 'Card') { continue }
    foreach ($setter in $style.SelectNodes('x:Setter', $ns)) {
        if ($setter.GetAttribute('Property') -eq 'Padding') { $cardPadding = $setter.GetAttribute('Value') }
    }
}
Assert '卡片内边距统一为 16,14' ($cardPadding -eq '16,14') "Card Padding=$cardPadding"

# x:Name 属于 XAML 命名空间，跟元素本身的 presentation 命名空间不是同一个：这里必须单独建一个映射，
# 否则 XPath 匹配不到任何节点（会静默返回 $null，断言看起来像「界面没设高度」）。
$nsXaml = $ns
$logView = $xamlDoc.SelectSingleNode('//x:RichTextBox[@xa:Name="LogView"]', $nsXaml)
$logFixedHeight = if ($null -ne $logView) { $logView.GetAttribute('Height') } else { 'missing' }
$logMinHeight = if ($null -ne $logView -and $logView.GetAttribute('MinHeight')) { [int]$logView.GetAttribute('MinHeight') } else { 0 }
Assert '日志区没有固定高度（跟着窗口伸缩）' ([string]::IsNullOrEmpty($logFixedHeight)) "LogView Height=$logFixedHeight"
Assert '日志区最小高度 ≥ 160（窗口缩到最小时也有 8 行可读）' ($logMinHeight -ge 160) "LogView MinHeight=$logMinHeight"
Assert '日志区仍允许自身纵向滚动' ($null -ne $logView -and $logView.GetAttribute('VerticalScrollBarVisibility') -eq 'Auto') `
    "VerticalScrollBarVisibility=$($logView.GetAttribute('VerticalScrollBarVisibility'))"

# 运行统计只留「会变、看得懂」的项：2.1.1 删掉 4 行无效栏目。
# 「连续失败」在完全忽略 Portal 提示之后长期是 0；「探测方式」跟配置绑定、开通后永不变化；
# 「已忽略提示」与「最近结果 = 已忽略 Portal 提示」重复；「强制重登」几乎一直是「尚未发生」。
foreach ($removedStat in @('StatFail', 'StatProbeMode', 'StatIgnored', 'StatForced')) {
    Assert "运行统计不再有 $removedStat 这一行" ($mainXamlText -notmatch $removedStat) "MainWindow.xaml 里还有 $removedStat"
}
Assert '运行统计保留今日登录与恢复耗时' ($mainXamlText -match 'x:Name="StatDay"' -and $mainXamlText -match 'x:Name="StatRecovery"') `
    '找不到 StatDay / StatRecovery'
# 2.1.3-pre.1：这两行重新有数据源（今日登录 / 恢复耗时），不再是写死的占位横线。
$emDash = [string][char]0x2014
$statDayNode = $xamlDoc.SelectSingleNode('//x:TextBlock[@xa:Name="StatDay"]', $nsXaml)
$statRecoveryNode = $xamlDoc.SelectSingleNode('//x:TextBlock[@xa:Name="StatRecovery"]', $nsXaml)
$statDayText = if ($null -ne $statDayNode) { $statDayNode.GetAttribute('Text') } else { 'missing' }
$statRecoveryText = if ($null -ne $statRecoveryNode) { $statRecoveryNode.GetAttribute('Text') } else { 'missing' }
Assert '「上次恢复」「恢复耗时」不再写死占位横线' ($statDayText -ne $emDash -and $statRecoveryText -ne $emDash) `
    "StatDay=$statDayText StatRecovery=$statRecoveryText"
$mainCsText = Get-Content -LiteralPath (Join-Path $repo 'src\CampusNet\MainWindow.xaml.cs') -Raw -Encoding UTF8
Assert '「上次恢复」绑定恢复耗时样本' ($mainCsText -match 'StatDay\.Text') 'MainWindow.xaml.cs 里没有 StatDay.Text'
Assert '「恢复耗时」绑定中位样本数' ($mainCsText -match 'StatRecovery\.Text') 'MainWindow.xaml.cs 里没有 StatRecovery.Text'
Assert '「今日登录」卡片标签已改名' ($mainXamlText -match 'Text="今日登录"') 'MainWindow.xaml 里没有「今日登录」标签'
Assert '去掉「2.1.2 起不再统计」的旧提示' (-not ($mainXamlText -match '2\.1\.2 起不再统计')) 'MainWindow.xaml 里还留着旧提示'

# 账号 / 密码框的灰色占位提示（WPF 没有内置 placeholder）
Assert '账号与密码框都有占位提示' ($mainXamlText -match 'x:Name="UserNamePlaceholder"' -and $mainXamlText -match 'x:Name="PasswordPlaceholder"') `
    '找不到 UserNamePlaceholder / PasswordPlaceholder'
$appXamlText = Get-Content -LiteralPath $appXamlPath -Raw -Encoding UTF8
Assert '占位提示用的是统一灰字样式' ($appXamlText -match 'x:Key="Placeholder"') 'App.xaml 里没有 Placeholder 样式'

# 窗口不能小于「内容自然高度」：2.1.0 实测（UI Automation，100% DPI）780 才刚好放下；
# 2.1.1 把日志区最小高度提到 160 之后重新实测：780 时仍有 1 个控件在窗口外，800 起才干净，
# 所以取 820 留一点余量 —— 宁大勿小，免得又出现「控件被裁在窗口外」的老问题。
$winMinHeightText = $xamlDoc.DocumentElement.GetAttribute('MinHeight')
$winMinHeight = if ($winMinHeightText) { [int]$winMinHeightText } else { 0 }
Assert '主窗口 MinHeight ≥ 820（不低于内容自然高度，避免日志区被顶出窗口）' ($winMinHeight -ge 820) "MinHeight=$winMinHeightText"

# 除日志之外不允许滚动：主体内容整体是 Auto 行，窗口缩到 MinHeight 也不裁切。
# （2.0.0 曾为「高级设置最后一行被裁掉」把主体塞进 ScrollViewer；2.1.0 把高级设置
#   移进独立窗口后，主窗口不再需要任何外层滚动。）
$bodyScroller = $null
foreach ($scroller in $xamlDoc.SelectNodes('//x:ScrollViewer', $ns)) {
    if ($scroller.GetAttribute('Grid.Row') -eq '2') { $bodyScroller = $scroller }
}
Assert '主体内容不再包在 ScrollViewer 里（除日志外不滚动）' ($null -eq $bodyScroller) '主窗口主体外层仍有 ScrollViewer'

# 日志卡片头部（右侧按钮组）：必须有「跟随最新」勾选框和「清除显示」按钮
$followTail = $xamlDoc.SelectSingleNode('//x:CheckBox[@xa:Name="FollowTailCheck"]', $nsXaml)
Assert '日志头部有默认勾选的「跟随最新」' ($null -ne $followTail -and $followTail.GetAttribute('IsChecked') -eq 'True') `
    '找不到默认勾选的 FollowTailCheck'
Assert '日志头部有「清除显示」按钮' ($mainXamlText -match 'Content="清除显示"' -and $mainXamlText -match 'Click="ClearLog_Click"') `
    '找不到「清除显示」按钮'
Assert '「清除显示」按钮提示写明不会删文件' ($mainXamlText -match '不会删除本机的 login\.log') '按钮提示里没写明不删文件'

$mainCs = Get-Content -LiteralPath (Join-Path $repo 'src\CampusNet\MainWindow.xaml.cs') -Raw -Encoding UTF8
$lineHeightMatch = [regex]::Match($mainCs, 'LineHeight\s*=\s*(\d+)')
$logLineHeight = if ($lineHeightMatch.Success) { [int]$lineHeightMatch.Groups[1].Value } else { 0 }
Assert '日志行高 ≥ 18（原来 16 太挤）' ($logLineHeight -ge 18) "LineHeight=$logLineHeight"

# 「清除显示」只清空界面视图：不删文件、不截断 login.log（唯一会删日志的入口是 --clear-log）
$clearBody = [regex]::Match($mainCs, '(?s)private void ClearLog_Click.*?(?=private void FollowTail_Click)')
Assert '「清除显示」不调用 Logger.Clear（不删本机日志）' ($clearBody.Success -and $clearBody.Value -notmatch '_log\.Clear\(') `
    'ClearLog_Click 里出现了 _log.Clear('
Assert '「清除显示」把渲染游标推到文件末尾' ($clearBody.Success -and $clearBody.Value -match '_logCursor = _log\.Sequence') `
    'ClearLog_Click 没有推进渲染游标'
Assert '「清除显示」提示本机日志文件未删除' ($clearBody.Success -and $clearBody.Value -match '本机日志文件未删除') `
    'ClearLog_Click 没有给出「未删除」的提示'

# 「高级设置」独立窗口：10 个输入项两列 × 5 行，没有滚动条；主窗口里不再留高级设置输入框
Assert '主窗口「程序」卡片有高级设置按钮' ($mainXamlText -match 'x:Name="AdvancedButton"') '找不到 AdvancedButton'
$advancedBoxes = @($advancedDoc.SelectNodes('//x:TextBox', $advancedNs))
Assert '高级设置窗口有 8 个输入框（删掉两个限速项）' ($advancedBoxes.Count -eq 8) "TextBox=$($advancedBoxes.Count)"
Assert '高级设置窗口没有 ScrollViewer（内容固定不滚动）' ($advancedDoc.SelectNodes('//x:ScrollViewer', $advancedNs).Count -eq 0) `
    '高级设置窗口里出现了 ScrollViewer'
$advancedGrid = $advancedDoc.SelectSingleNode('//x:Grid', $advancedNs)
$advancedRows = $advancedGrid.SelectNodes('x:Grid.RowDefinitions/x:RowDefinition', $advancedNs).Count
$advancedCols = $advancedGrid.SelectNodes('x:Grid.ColumnDefinitions/x:ColumnDefinition', $advancedNs).Count
Assert '高级设置网格 4 行 × 两列输入框' ($advancedRows -ge 4 -and $advancedCols -ge 5) "行=$advancedRows 列=$advancedCols"
$advancedTagged = 0
foreach ($box in $advancedBoxes) { if ($box.GetAttribute('Tag')) { $advancedTagged++ } }
Assert '高级设置 7 个数值项都带 Tag（范围校验用）' ($advancedTagged -ge 7) "带 Tag 的输入框=$advancedTagged"
Assert '高级设置里不再有限速输入框' ($advancedXamlText -notmatch 'HourlyLimit' -and $advancedXamlText -notmatch 'MinInterval') `
    'AdvancedWindow.xaml 里还有限速输入框'
$mainTextBoxes = @($xamlDoc.SelectNodes('//x:TextBox', $ns))
Assert '主窗口只剩账号一个输入框（高级设置已搬走）' ($mainTextBoxes.Count -eq 1) "主窗口 TextBox=$($mainTextBoxes.Count)"

# 静态：仓库内所有 .ps1 都要能通过 PowerShell 解析器。
# 假 Portal 一旦有语法错，整套场景会静默变成「Portal 连不上」，很容易被误读成功能回归。
$scriptSyntaxErrors = New-Object System.Collections.Generic.List[string]
foreach ($psFile in (Get-ChildItem -LiteralPath (Join-Path $repo 'build') -Filter '*.ps1' -File)) {
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($psFile.FullName, [ref]$null, [ref]$parseErrors)
    foreach ($parseError in $parseErrors) { $scriptSyntaxErrors.Add($psFile.Name + ': ' + $parseError.Message) }
}
Assert '仓库内 .ps1 全部能通过语法解析' ($scriptSyntaxErrors.Count -eq 0) ($scriptSyntaxErrors -join '；')

# 场景 33：密集复检窗口的粒度 —— 1 秒一档共 30 档（取代 2.0.0 的 2/3/4/5/6/3 六档）。
# 假 Portal：登录接口回成功，但内容校验真的要等到登录后第 22 秒才通。
# 旧阶梯最大粒度 6 秒（+20 → +23），新窗口应该在 +22 秒档就确认。
$n = Invoke-RawRun -Name 's33-dense-window' -Scenario 'online-after-login-22' -Seconds 30 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" `
        -Targets @("http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test") -OfflineProbe 2)
Assert '密集窗口在第 +22 秒档确认恢复' ($n.Log -match '本地内容校验通过（\+2[23] 秒）') '日志里没有 +22 秒档确认的记录'
Assert '密集窗口场景只提交 1 次登录' ($n.Login -eq 1) "login=$($n.Login)"
Assert '密集窗口确认后状态为 login-ok' ($n.State.LastResult -eq 'login-ok') "LastResult=$($n.State.LastResult)"
$denseDelta = Get-LogSecondsBetween -Log $n.Log -FromPattern '次尝试登录' -ToPattern '自动登录成功'
Assert '提交 → 确认落在 21~26 秒' ($denseDelta -ge 21 -and $denseDelta -le 26) "提交到确认相隔 $denseDelta 秒"

# 场景 34：登录被回 error2 后，3 秒短窗的第一档（+1 秒）就靠本机内容校验确认恢复
$n = Invoke-RawRun -Name 's34-instant-content' -Scenario 'instant-content' -Seconds 12 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" `
        -Targets @("http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test") -OfflineProbe 2)
Assert '3 秒短窗第一档就命中（+1 秒）' ($n.Log -match '本地内容校验通过（\+1 秒）') '日志里没有 +1 秒命中的记录'
$instantDelta = Get-LogSecondsBetween -Log $n.Log -FromPattern '次尝试登录' -ToPattern '网络已恢复'
Assert '登录到确认恢复 ≤ 2 秒' ($instantDelta -ge 0 -and $instantDelta -le 2) `
    "登录到恢复相隔 $instantDelta 秒"
Assert '瞬时生效直接判为登录成功' ($n.State.LastResult -eq 'login-ok' -or $n.State.LastResult -eq 'online') `
    "LastResult=$($n.State.LastResult)"

# 场景 35：登录前先做一次纯本地内容校验——本地已经能上网就不登录，连 Portal 都少查一次
# 假 Portal：内容目标前 3 次回「没有关键字」（正好是首轮探测 + 断网复检 2 轮），
# 第 4 次（= 登录前那次本地校验）起才真的返回关键字。
$n = Invoke-RawRun -Name 's35-precheck-local' -Scenario 'content-from-4th' -Seconds 12 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" `
        -Targets @("http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test") -OfflineProbe 2)
Assert '登录前本地校验翻案：一次登录都不提交' ($n.Login -eq 0) "login=$($n.Login)"
Assert '登录前本地校验翻案：只查了一次状态' ($n.Status -eq 1) "chkstatus=$($n.Status)"
Assert '日志写明「登录前本地内容校验已能上网」' ($n.Log -match '登录前本地内容校验已能上网') '日志里没有这条记录'
Assert '翻案后状态为 online' ($n.State.LastResult -eq 'online') "LastResult=$($n.State.LastResult)"

# 场景 36：提交登录后的密集复检窗口——Portal 在第 13 秒才说在线，
# 1 秒一档应该在 +13 秒（最晚 +14 秒）确认；2.0.0 的六档阶梯要拖到 +20 秒。
$n = Invoke-RawRun -Name 's36-recovery-ladder' -Scenario 'online-after-login-13' -Seconds 25 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" `
        -Targets @("http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test") -OfflineProbe 2)
Assert '密集窗口在 +13~+14 秒档确认恢复' ($n.Log -match '本地内容校验通过（\+1[34] 秒）') '日志里没有 +13/+14 秒确认的记录'
Assert '阶梯场景只提交 1 次登录' ($n.Login -eq 1) "login=$($n.Login)"
Assert '阶梯确认后状态为 login-ok' ($n.State.LastResult -eq 'login-ok') "LastResult=$($n.State.LastResult)"
# 一次事故的只读复检预算：探测不通求证 1 次 + 登录前确认 1 次 + 密集窗口里每 3 档一次（最多 10 次）。
$ladderChecks = @(Get-RequestTimes -LogPath $n.LogPath -Kind 'chkstatus')
Assert '一次事故的只读 chkstatus 次数 ≤ 14' ($ladderChecks.Count -le 14) "chkstatus=$($ladderChecks.Count)"

# 场景 37：登录前确认延迟 3 秒 → 1 秒的一次性迁移（v6 → v7），自定义值原样保留
function Invoke-ConfirmDelayMigration {
    param([string]$Name, [int]$Delay)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $legacy = [ordered]@{
        ConfigVersion        = 6
        PortalHost           = '127.0.0.1:65010'
        OnlineProbeSeconds   = 20
        OfflineProbeSeconds  = 2
        ConfirmAttempts      = 2
        ConfirmGapMs         = 500
        LoginConfirmDelaySec = $Delay
        ProbeTargets         = @(Off-Target 65018)
    }
    ($legacy | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
    Set-TestCredentials -Dir $dir
    & $Exe '--run-seconds' 3 '--data-dir' $dir | Out-String | Out-Null
    return (Get-Content -LiteralPath (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$delayMigrated = Invoke-ConfirmDelayMigration -Name 's37-delay-migrate' -Delay 3
Assert '旧默认确认延迟 3 秒迁移为 1 秒' ($delayMigrated.LoginConfirmDelaySec -eq 1) "LoginConfirmDelaySec=$($delayMigrated.LoginConfirmDelaySec)"
Assert '确认延迟迁移后写入 ConfigVersion=10' ($delayMigrated.ConfigVersion -eq 10) "ConfigVersion=$($delayMigrated.ConfigVersion)"
$delayCustom = Invoke-ConfirmDelayMigration -Name 's37-delay-custom' -Delay 5
Assert '自定义确认延迟 5 秒不被改写' ($delayCustom.LoginConfirmDelaySec -eq 5) "LoginConfirmDelaySec=$($delayCustom.LoginConfirmDelaySec)"

# 场景 38：v8 → v9 → v10 的完整迁移链——2.1.0 / 2.1.1 的激进节奏先回滚、再收紧到新默认。
# 2.1.x 把在线 20 → 10、异常 5 → 3、会话核对 120 → 60；2.1.2 先回滚，2.1.3-pre.1 再收到 15/3。
# 只改「恰好等于旧默认值」的那一份，用户自己填过的值原样保留。
function Invoke-PacingMigration {
    param([string]$Name, [int]$Online, [int]$Offline, [int]$Session)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $legacy = [ordered]@{
        ConfigVersion       = 8
        PortalHost          = '127.0.0.1:65010'
        OnlineProbeSeconds  = $Online
        OfflineProbeSeconds = $Offline
        SessionCheckSeconds = $Session
        ProbeTargets        = @(Off-Target 65019)
    }
    ($legacy | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
    Set-TestCredentials -Dir $dir
    & $Exe '--run-seconds' 3 '--data-dir' $dir | Out-String | Out-Null
    return (Get-Content -LiteralPath (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$paced = Invoke-PacingMigration -Name 's38-pacing-migrate' -Online 10 -Offline 3 -Session 60
Assert '2.1.x 激进在线探测 10 秒回到 15 秒' ($paced.OnlineProbeSeconds -eq 15) "OnlineProbeSeconds=$($paced.OnlineProbeSeconds)"
Assert '2.1.x 激进异常探测 3 秒保持 3 秒' ($paced.OfflineProbeSeconds -eq 3) "OfflineProbeSeconds=$($paced.OfflineProbeSeconds)"
Assert '2.1.x 激进会话核对 60 秒回到 120 秒' ($paced.SessionCheckSeconds -eq 120) "SessionCheckSeconds=$($paced.SessionCheckSeconds)"
Assert '节奏迁移后写入 ConfigVersion=10' ($paced.ConfigVersion -eq 10) "ConfigVersion=$($paced.ConfigVersion)"
$pacedCustom = Invoke-PacingMigration -Name 's38-pacing-custom' -Online 45 -Offline 2 -Session 240
Assert '自定义节奏 45/2/240 一律不被改写' ($pacedCustom.OnlineProbeSeconds -eq 45 -and $pacedCustom.OfflineProbeSeconds -eq 2 `
    -and $pacedCustom.SessionCheckSeconds -eq 240 -and $pacedCustom.ConfigVersion -eq 10) `
    "Online=$($pacedCustom.OnlineProbeSeconds) Offline=$($pacedCustom.OfflineProbeSeconds) Session=$($pacedCustom.SessionCheckSeconds)"

# 场景 39：v9 → v10 收紧迁移——在线 20→15、异常 5→3、残留重登 60→15，会话核对保持 120。
# 只改「恰好等于旧默认值」的那一份；用户自己填过的值一律不动。
function Invoke-TightenMigration {
    param([string]$Name, [int]$Online, [int]$Offline, [int]$Stuck, [int]$Session)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $legacy = [ordered]@{
        ConfigVersion       = 9
        PortalHost          = '127.0.0.1:65010'
        OnlineProbeSeconds  = $Online
        OfflineProbeSeconds = $Offline
        SessionCheckSeconds = $Session
        StuckReloginSeconds = $Stuck
        ProbeTargets        = @(Off-Target 65022)
    }
    ($legacy | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
    Set-TestCredentials -Dir $dir
    & $Exe '--run-seconds' 3 '--data-dir' $dir | Out-String | Out-Null
    return (Get-Content -LiteralPath (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$tightened = Invoke-TightenMigration -Name 's39-tighten' -Online 20 -Offline 5 -Stuck 60 -Session 120
Assert '在线探测 20 秒收紧为 15 秒' ($tightened.OnlineProbeSeconds -eq 15) "OnlineProbeSeconds=$($tightened.OnlineProbeSeconds)"
Assert '异常探测 5 秒收紧为 3 秒' ($tightened.OfflineProbeSeconds -eq 3) "OfflineProbeSeconds=$($tightened.OfflineProbeSeconds)"
Assert '残留重登 60 秒收紧为 15 秒' ($tightened.StuckReloginSeconds -eq 15) "StuckReloginSeconds=$($tightened.StuckReloginSeconds)"
Assert '会话核对 120 秒保持不变' ($tightened.SessionCheckSeconds -eq 120) "SessionCheckSeconds=$($tightened.SessionCheckSeconds)"
Assert 'v10 迁移后写入 ConfigVersion=10' ($tightened.ConfigVersion -eq 10) "ConfigVersion=$($tightened.ConfigVersion)"
$tightCustom = Invoke-TightenMigration -Name 's39-tighten-custom' -Online 45 -Offline 2 -Stuck 45 -Session 240
Assert '自定义节奏 45/2/45/240 一律不被改写' ($tightCustom.OnlineProbeSeconds -eq 45 -and $tightCustom.OfflineProbeSeconds -eq 2 `
    -and $tightCustom.StuckReloginSeconds -eq 45 -and $tightCustom.SessionCheckSeconds -eq 240) `
    "Online=$($tightCustom.OnlineProbeSeconds) Offline=$($tightCustom.OfflineProbeSeconds) Stuck=$($tightCustom.StuckReloginSeconds) Session=$($tightCustom.SessionCheckSeconds)"

# 场景 40：今日登录计数 + 恢复耗时
# 磁盘上预置「昨天 5/7」和很大的累计值：跑一次成功的「残留会话」恢复后，
# 今日计数应从 0 重新数这一次（提交 2 / 成功 1），而累计类计数不许被旧快照拉回去。
$dayDir = Join-Path $work 's40-day-counter'
New-Item -ItemType Directory -Force -Path $dayDir | Out-Null
$yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
$seededState = [ordered]@{
    LastResult = 'online'; DayKey = $yesterday; DayLoginSuccess = 5; DayLoginAttempts = 7
    IgnoredPrompts = 99; RunCount = 1000
} | ConvertTo-Json
Set-Content -LiteralPath (Join-Path $dayDir 'state.json') -Value $seededState -Encoding UTF8
$n = Invoke-RawRun -Name 's40-day-counter' -Scenario 'ghost-session' -Seconds 16 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" `
        -Targets @("http:127.0.0.1:$Port/connecttest.txt|Microsoft Connect Test") -OfflineProbe 2)
Assert '跨零点归零：今日提交从 0 重新计数' `
    ($n.State.DayKey -eq (Get-Date).ToString('yyyy-MM-dd') -and $n.State.DayLoginAttempts -eq 2) `
    "DayKey=$($n.State.DayKey) attempts=$($n.State.DayLoginAttempts)"
Assert '今日成功计数记为 1' ($n.State.DayLoginSuccess -eq 1) "success=$($n.State.DayLoginSuccess)"
Assert '累计计数不被旧快照拉回（已忽略提示 / 累计检查）' ($n.State.IgnoredPrompts -ge 99 -and $n.State.RunCount -ge 1000) `
    "IgnoredPrompts=$($n.State.IgnoredPrompts) RunCount=$($n.State.RunCount)"
Assert '运行输出里带恢复耗时' ($n.Output -match '恢复耗时：最近 \d+ 秒') '运行输出里没有恢复耗时'
Assert '恢复耗时样本数 ≥ 1' ($n.Output -match '（[1-9]\d* 次样本）') "输出长度=$($n.Output.Length)"
$statusOut = & $Exe '--status' '--data-dir' $n.Dir 2>&1 | Out-String
Assert '--status 显示今日登录计数' ($statusOut -match '今日登录：确认成功 \d+ 次 / 提交 \d+ 次') '状态输出里没有今日登录行'
Assert '--status 不再显示「本小时登录」' ($statusOut -notmatch '本小时登录') '状态输出里还有本小时登录'
$diagOut = & $Exe '--diagnose' '--data-dir' $n.Dir 2>&1 | Out-String
Assert '--diagnose 显示今日登录行' ($diagOut -match '今日登录  ：') '诊断输出里没有今日登录行'
Assert '--diagnose 风控行改为登录节流' ($diagOut -match '登录节流  ：') '诊断输出里没有登录节流行'

# 场景 42：Portal 明确限流（waitsec 30）→ 状态 login-throttled，暂停期内一次都不再提交
$n = Invoke-RawRun -Name 's42-throttle-pause' -Scenario 'rate-limited-long' -Seconds 20 `
    -ConfigText (New-RawConfig -PortalHost "127.0.0.1:$Port" -Targets @(Off-Target 65021) -OfflineProbe 2)
Assert '限流后状态记为 login-throttled' ($n.State.LastResult -eq 'login-throttled') "LastResult=$($n.State.LastResult)"
Assert '按 Portal 给的秒数暂停（30 秒）' ($n.Log -match '暂停 30 秒') '日志里没有「暂停 30 秒」'
Assert '暂停期内不再提交登录（20 秒内只提交 1 次）' ($n.Login -eq 1) "login=$($n.Login)"

# 源码级护栏：2.1.3-pre.1 的口径必须留在源码里，防止以后被误改回旧行为
$engineCs = Get-Content -LiteralPath (Join-Path $repo 'src\CampusNet\Core\Engine.cs') -Raw -Encoding UTF8
Assert '疑似掉线连续 1 轮就核对' ($engineCs -match 'SuspectStreakForVerify = 1') 'SuspectStreakForVerify 不是 1'
Assert '疑似核对最小间隔收紧到 10 秒' ($engineCs -match 'SuspectVerifyMinSeconds = 10') 'SuspectVerifyMinSeconds 不是 10'
Assert '残留会话短窗 3 秒' ($engineCs -match 'RecoveryShortWatchSeconds = 3') 'RecoveryShortWatchSeconds 不是 3'
Assert '密集复检窗口 30 秒（1 秒一档）' ($engineCs -match 'RecoveryWatchSeconds = 30') 'RecoveryWatchSeconds 不是 30'
Assert '密集窗口每 3 档查一次 Portal' ($engineCs -match 'RecoveryStatusEveryRungs = 3') 'RecoveryStatusEveryRungs 不是 3'
Assert '不再有最小间隔等待期（_loginWaitUntil）' (-not ($engineCs -match '_loginWaitUntil')) 'Engine.cs 里还留着最小间隔等待期'
Assert '今日登录计数留在引擎里' ($engineCs -match 'DayLoginSuccess') 'Engine.cs 里没有今日登录计数'
Assert '恢复耗时样本留在引擎里' ($engineCs -match 'RecoveryMedianSeconds') 'Engine.cs 里没有恢复耗时样本'
$configCs = Get-Content -LiteralPath (Join-Path $repo 'src\CampusNet\Core\Config.cs') -Raw -Encoding UTF8
Assert '配置里删掉 LoginMinIntervalSeconds' (-not ($configCs -match 'LoginMinIntervalSeconds')) 'Config.cs 里还有最小间隔键'
Assert '配置里删掉 LoginHourlyLimit' (-not ($configCs -match 'LoginHourlyLimit')) 'Config.cs 里还有每小时上限键'
Assert 'ConfigVersion 升到 10' ($configCs -match 'CurrentConfigVersion = 10') 'CurrentConfigVersion 不是 10'
Assert '今日计数三键在状态模型里' (($configCs -match 'DayKey') -and ($configCs -match 'DayLoginAttempts') -and ($configCs -match 'DayLoginSuccess')) `
    'Config.cs 的状态模型里没有今日计数'
$networkCs = Get-Content -LiteralPath (Join-Path $repo 'src\CampusNet\Core\Network.cs') -Raw -Encoding UTF8
Assert 'Network.cs 提供 QuickContentCheck（短预算单轮校验）' ($networkCs -match 'public static bool QuickContentCheck') 'Network.cs 里没有 QuickContentCheck'

$results | ForEach-Object { Write-Host $_ }
Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures 个用例失败" -ForegroundColor Red
    exit 1
}
Write-Host '全部用例通过' -ForegroundColor Green
exit 0
