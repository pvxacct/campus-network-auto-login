#Requires -Version 5.1
<#
.SYNOPSIS
    Dr.COM（哆点）校园网 Portal 自动登录脚本。

.DESCRIPTION
    运行流程：
      1. 读取 drcom-config.json 中的 Portal 配置；
      2. GET  /drcom/chkstatus 查询在线状态（result=1 在线，result=0 离线）；
      3. 离线时 POST /drcom/login 提交账号密码；
      4. 返回页包含 Dr.COMWebLoginID_3.htm 判定为登录成功；
      5. 失败时调用错误码接口，把 userid error2 之类的代码翻译成中文；
      6. 账号密码由 Save-DrcomCredential.ps1 使用 Windows DPAPI 加密保存；
      7. 每次运行结果都会写入 state.json，可用来确认脚本是否真的在运行。

.PARAMETER ConfigPath
    Portal 配置文件，默认脚本同目录下的 drcom-config.json。

.PARAMETER CredentialPath
    DPAPI 加密的凭据文件，默认 <数据目录>\credential.xml，也会兼容脚本目录下的旧文件。

.PARAMETER DataDir
    数据目录，默认 %LOCALAPPDATA%\CampusAutoLogin，用于存放凭据、日志与状态文件。

.PARAMETER LogPath
    日志文件，默认 <数据目录>\login.log。

.PARAMETER StatePath
    状态文件，默认 <数据目录>\state.json。

.PARAMETER CheckOnly
    只查询在线状态并打印，不执行登录、不写状态文件。

.PARAMETER Force
    即使 Portal 显示已在线，也执行一次登录请求。

.PARAMETER Relogin
    先注销当前会话，等待 ReloginWaitSec 秒后再登录。

.PARAMETER Quiet
    不向控制台输出（计划任务使用），仍然写日志与状态文件。

.PARAMETER RetryCount
    登录失败后的最大尝试次数，默认 3 次。

.PARAMETER RetryDelaySec
    每次重试之间的等待秒数，默认 8 秒。

.PARAMETER HeartbeatMinutes
    一切正常时日志的心跳间隔（分钟），默认 60；设为 0 表示不写心跳。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -Relogin

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$CredentialPath = '',
    [string]$DataDir = '',
    [string]$LogPath = '',
    [string]$StatePath = '',
    [switch]$CheckOnly,
    [switch]$Force,
    [switch]$Relogin,
    [switch]$Quiet,
    [int]$ReloginWaitSec = 5,
    [int]$RetryCount = 3,
    [int]$RetryDelaySec = 8,
    [int]$HeartbeatMinutes = 60,
    [int]$StatusTimeoutSec = 8,
    [int]$LoginTimeoutSec = 15
)

$ErrorActionPreference = 'Stop'

$script:QuietMode = [bool]$Quiet
$script:ScriptVersion = '1.1.0'

# ===================== 路径解析 =====================
$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    $ScriptRoot = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($DataDir)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $DataDir = $ScriptRoot
    } else {
        $DataDir = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
    }
}
if (-not (Test-Path -LiteralPath $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace($LogPath))    { $LogPath   = Join-Path $DataDir 'login.log' }
if ([string]::IsNullOrWhiteSpace($StatePath))  { $StatePath = Join-Path $DataDir 'state.json' }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ScriptRoot 'drcom-config.json' }

# 凭据文件：优先使用显式路径，其次数据目录，最后脚本目录（兼容旧版本）
if ([string]::IsNullOrWhiteSpace($CredentialPath)) {
    $dataCredential = Join-Path $DataDir 'credential.xml'
    $localCredential = Join-Path $ScriptRoot 'credential.xml'
    if (Test-Path -LiteralPath $dataCredential) {
        $CredentialPath = $dataCredential
    } elseif (Test-Path -LiteralPath $localCredential) {
        $CredentialPath = $localCredential
    } else {
        $CredentialPath = $dataCredential
    }
}

# 校园网 Portal 在校园内网，不走系统代理，避免 VPN / 代理软件导致请求失败
try { [System.Net.WebRequest]::DefaultWebProxy = $null } catch { }

# ===================== 日志 =====================
function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        $dir = Split-Path -Path $LogPath -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.old') -Force
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        # 日志写入失败不影响主流程
    }
    if (-not $script:QuietMode) { Write-Host $line }
}

# ===================== 状态文件 =====================
function Read-DrcomState {
    $state = @{ RunCount = 0; ConsecutiveFailures = 0 }
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $obj = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
        } catch {
            # 状态文件损坏时按空状态处理
        }
    }
    if (-not $state.ContainsKey('RunCount')) { $state['RunCount'] = 0 }
    if (-not $state.ContainsKey('ConsecutiveFailures')) { $state['ConsecutiveFailures'] = 0 }
    return $state
}

function Save-DrcomState {
    param([hashtable]$State)

    $State['LastRun'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $State['Version'] = $script:ScriptVersion
    try {
        $json = $State | ConvertTo-Json -Depth 4
        $tmp = $StatePath + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $StatePath -Force
    } catch {
        Write-Log "写入状态文件失败：$($_.Exception.Message)" 'WARN'
    }
}

function Get-DrcomLastTime {
    param([hashtable]$State, [string]$Key)

    if (-not $State.ContainsKey($Key)) { return $null }
    $raw = [string]$State[$Key]
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return [datetime]::Parse($raw) } catch { return $null }
}

# ===================== Portal 接口 =====================
function Get-DrcomStatus {
    <#
      返回：
        Reachable = 能否访问到 Portal（false 表示网络本身不通，不应重试登录）
        Online    = 是否已认证在线
        Text      = 原始响应
        Error     = 失败原因
    #>
    $reply = @{ Reachable = $false; Online = $false; Text = ''; Error = '' }

    $callback = 'dr' + (Get-Random -Minimum 100 -Maximum 9999)
    $url = '{0}?callback={1}&v={1}&lang=zh&jsVersion=4.X' -f $StatusUrl, $callback

    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $StatusTimeoutSec -ErrorAction Stop
        $text = [string]$resp.Content
        $match = [regex]::Match($text, '"result"\s*:\s*(-?\d+)')
        if ($match.Success) {
            $reply.Reachable = $true
            $reply.Online = ([int]$match.Groups[1].Value -eq 1)
            $reply.Text = $text
        } else {
            $reply.Error = '状态接口返回无法解析：' + ($text -replace '\s+', ' ')
        }
    } catch {
        $reply.Error = $_.Exception.Message
    }

    return $reply
}

function Get-DrcomErrorText {
    param(
        [string]$Code,
        [int]$TimeoutSec = 8
    )

    if ([string]::IsNullOrWhiteSpace($Code)) { return '' }

    try {
        $url = '{0}?error_code={1}&callback=dr1&jsVersion=4.X&v=1&lang=zh' -f $ErrorUrl, [uri]::EscapeDataString($Code)
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $match = [regex]::Match([string]$resp.Content, '"error_prompt_zh"\s*:\s*"([^"]*)"')
        if ($match.Success) { return $match.Groups[1].Value }
    } catch {
        # 翻译失败时直接返回原始错误码
    }

    return $Code
}

function Invoke-DrcomLogout {
    param([int]$TimeoutSec = 10)

    $callback = 'dr' + (Get-Random -Minimum 100 -Maximum 9999)
    $url = '{0}?callback={1}&v={1}&lang=zh&jsVersion=4.X' -f $LogoutUrl, $callback

    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $match = [regex]::Match([string]$resp.Content, '"result"\s*:\s*(\d+)')
        if ($match.Success -and [int]$match.Groups[1].Value -eq 1) {
            return $true
        }
        Write-Log ('注销接口返回：' + [string]$resp.Content) 'WARN'
    } catch {
        Write-Log "注销请求失败：$($_.Exception.Message)" 'WARN'
    }

    return $false
}

function Invoke-DrcomLogin {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $body = [ordered]@{
        DDDDD = $Username
        upass = $Password
    }
    foreach ($key in $StaticFields.Keys) {
        $body[$key] = $StaticFields[$key]
    }

    $headers = @{
        'Referer'    = 'http://{0}/' -f $PortalHost
        'User-Agent' = $UserAgent
    }

    try {
        $resp = Invoke-WebRequest -Uri $LoginUrl `
            -Method POST `
            -Body $body `
            -ContentType 'application/x-www-form-urlencoded' `
            -Headers $headers `
            -UseBasicParsing `
            -TimeoutSec $LoginTimeoutSec `
            -ErrorAction Stop
    } catch {
        return New-LoginResult -Message $_.Exception.Message
    }

    $text = [string]$resp.Content

    if ($text -match 'Dr\.COMWebLoginID_3\.htm') {
        return New-LoginResult -Success $true -Message '登录成功'
    }

    if ($text -match 'Dr\.COMWebLoginID_2\.htm') {
        $msg = [regex]::Match($text, 'Msg=(\d+)').Groups[1].Value
        $msga = [regex]::Match($text, "msga='([^']*)'").Groups[1].Value
        $prompt = Get-DrcomErrorText -Code $msga
        $already = ($msga -match 'userid\s*error2')
        return New-LoginResult -Message ('Msg={0}, {1} -> {2}' -f $msg, $msga, $prompt) `
            -RateLimited ($msga -match 'waitsec') `
            -AlreadyOnline $already
    }

    if ($text -match 'Error code:\s*205' -or $text -match 'waitsec') {
        return New-LoginResult -Message ('请求过于频繁：' + ($text -replace '\s+', ' ')) -RateLimited $true
    }

    $short = $text.Substring(0, [Math]::Min(200, $text.Length)) -replace '\s+', ' '
    return New-LoginResult -Message "未知响应：$short"
}

function New-LoginResult {
    param(
        [bool]$Success = $false,
        [bool]$RateLimited = $false,
        [bool]$AlreadyOnline = $false,
        [string]$Message = ''
    )

    return [pscustomobject]@{
        Success       = $Success
        RateLimited   = $RateLimited
        AlreadyOnline = $AlreadyOnline
        Message       = $Message
    }
}

# ===================== 主流程 =====================
$mutexOwned = $false
$mutex = $null

# 同一时间只允许一个实例，避免计划任务触发过于密集时互相打断
if (-not $CheckOnly) {
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\CampusAutoLoginDrcom')
        try {
            $mutexOwned = $mutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $mutexOwned = $true
        }
    } catch {
        $mutex = $null
        $mutexOwned = $false
    }

    if (($null -ne $mutex) -and (-not $mutexOwned)) {
        Write-Log '上一次检查尚未结束，跳过本次触发。' 'WARN'
        exit 0
    }
}

try {
    # ---------- 读取配置 ----------
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "找不到配置文件：$ConfigPath"
    }

    $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $PortalHost = [string]$Config.PortalHost
    if ([string]::IsNullOrWhiteSpace($PortalHost)) {
        throw 'drcom-config.json 中的 PortalHost 不能为空。'
    }

    $EportalPort = 801
    if ($Config.EportalPort) { $EportalPort = [int]$Config.EportalPort }

    $StatusPath = '/drcom/chkstatus'
    if ($Config.StatusPath) { $StatusPath = [string]$Config.StatusPath }

    $LoginPath = '/drcom/login'
    if ($Config.LoginPath) { $LoginPath = [string]$Config.LoginPath }

    $LogoutPath = '/drcom/logout'
    if ($Config.LogoutPath) { $LogoutPath = [string]$Config.LogoutPath }

    $ErrorPromptPath = '/eportal/portal/err_code/loadErrorPrompt'
    if ($Config.ErrorPromptPath) { $ErrorPromptPath = [string]$Config.ErrorPromptPath }

    $UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
    if ($Config.UserAgent) { $UserAgent = [string]$Config.UserAgent }

    $IntervalSeconds = 30
    if ($Config.CheckIntervalSeconds) {
        $IntervalSeconds = [int]$Config.CheckIntervalSeconds
    } elseif ($Config.CheckIntervalMinutes) {
        $IntervalSeconds = [int]$Config.CheckIntervalMinutes * 60
    }

    $StatusUrl = 'http://{0}{1}' -f $PortalHost, $StatusPath
    $LoginUrl  = 'http://{0}{1}' -f $PortalHost, $LoginPath
    $LogoutUrl = 'http://{0}{1}' -f $PortalHost, $LogoutPath
    $ErrorUrl  = 'http://{0}:{1}{2}' -f $PortalHost, $EportalPort, $ErrorPromptPath

    $StaticFields = [ordered]@{}
    if ($Config.StaticFields) {
        foreach ($prop in $Config.StaticFields.PSObject.Properties) {
            $StaticFields[$prop.Name] = [string]$prop.Value
        }
    }

    # ---------- 只查询状态 ----------
    if ($CheckOnly) {
        $probe = Get-DrcomStatus
        if (-not $probe.Reachable) {
            Write-Host ('Portal 无法访问：' + $probe.Error) -ForegroundColor Red
            exit 2
        }
        if ($probe.Online) {
            Write-Host '当前状态：已在线。' -ForegroundColor Green
            Write-Host $probe.Text
        } else {
            Write-Host '当前状态：未在线（需要登录）。' -ForegroundColor Yellow
            Write-Host $probe.Text
        }
        exit 0
    }

    # ---------- 读取凭据与状态 ----------
    $state = Read-DrcomState
    $state['RunCount'] = [int]$state['RunCount'] + 1

    if (-not (Test-Path -LiteralPath $CredentialPath)) {
        Write-Log "找不到凭据文件：$CredentialPath" 'ERROR'
        Write-Log '请先运行 Setup-DrcomAutoLogin.ps1（或 Save-DrcomCredential.ps1）保存校园网账号密码。' 'ERROR'
        $state['LastResult'] = 'no-credential'
        $state['LastError'] = '凭据文件不存在'
        Save-DrcomState -State $state
        exit 1
    }

    try {
        $cred = Import-Clixml -LiteralPath $CredentialPath
        $username = $cred.UserName
        $password = $null
        try {
            $password = $cred.GetNetworkCredential().Password
        } catch {
            if ($cred.Password -is [System.Security.SecureString]) {
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
                try {
                    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                } finally {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            } else {
                $password = [string]$cred.Password
            }
        }
        if ([string]::IsNullOrEmpty($password)) {
            throw '凭据文件中的密码为空或无法解密。'
        }
    } catch {
        Write-Log "读取凭据失败（凭据文件与当前 Windows 用户绑定，换用户后需要重新保存）：$($_.Exception.Message)" 'ERROR'
        $state['LastResult'] = 'bad-credential'
        $state['LastError'] = $_.Exception.Message
        Save-DrcomState -State $state
        exit 1
    }

    if (-not $Quiet) {
        Write-Log "===== 开始检查（账号：$username）====="
    }

    $wasOnline = $false
    if ($state.ContainsKey('Online')) { $wasOnline = [bool]$state['Online'] }

    if ($Relogin) {
        Write-Log '指定了 -Relogin：先注销当前会话，再重新登录。'
        if (Invoke-DrcomLogout) {
            Write-Log "注销成功，等待 $ReloginWaitSec 秒后重新登录（Portal 要求至少 3 秒）。"
            Start-Sleep -Seconds $ReloginWaitSec
        } else {
            Write-Log '注销未成功，继续尝试直接登录。' 'WARN'
        }
    }

    $status = Get-DrcomStatus

    # Portal 本身不可达（比如还没连上校园网）：不尝试登录，等下一次触发
    if (-not $status.Reachable) {
        Write-Log "Portal 无法访问，本次不尝试登录：$($status.Error)" 'WARN'
        $state['Online'] = $false
        $state['LastResult'] = 'unreachable'
        $state['LastError'] = $status.Error
        Save-DrcomState -State $state
        exit 0
    }

    if ($status.Online -and -not ($Force -or $Relogin)) {
        $state['Online'] = $true
        $state['LastResult'] = 'online'
        $state['LastError'] = ''
        $state['ConsecutiveFailures'] = 0

        $lastBeat = Get-DrcomLastTime -State $state -Key 'LastHeartbeat'
        $beatDue = $true
        if ($HeartbeatMinutes -gt 0 -and $lastBeat -and ((Get-Date) - $lastBeat).TotalMinutes -lt $HeartbeatMinutes) {
            $beatDue = $false
        }

        if (-not $wasOnline) {
            Write-Log 'Portal 状态：已在线（连接已恢复）。'
            $state['LastHeartbeat'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        } elseif ($beatDue) {
            Write-Log ("运行正常：Portal 在线（累计执行 {0} 次，检查间隔约 {1} 秒）。" -f $state['RunCount'], $IntervalSeconds)
            $state['LastHeartbeat'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }

        Save-DrcomState -State $state
        exit 0
    }

    # 连续失败退避：账号被 MAC 绑定等情况下不要每 30 秒都去撞 Portal
    $failures = [int]$state['ConsecutiveFailures']
    $lastAttempt = Get-DrcomLastTime -State $state -Key 'LastLoginAttempt'
    if ($failures -ge 3) {
        $backoffMin = [Math]::Min([Math]::Pow(2, $failures - 2), 30)
        if ($lastAttempt -and ((Get-Date) - $lastAttempt).TotalMinutes -lt $backoffMin) {
            Write-Log ("已连续失败 {0} 次，进入冷却（约 {1} 分钟后重试），本次只检查不登录。" -f $failures, $backoffMin) 'WARN'
            $state['Online'] = $false
            $state['LastResult'] = 'backoff'
            Save-DrcomState -State $state
            exit 1
        }
    }

    if ($status.Online) {
        Write-Log 'Portal 状态：已在线，但因为指定了 -Force / -Relogin，继续执行登录。' 'WARN'
    } else {
        Write-Log 'Portal 状态：未在线，开始自动登录。'
    }

    $state['LastLoginAttempt'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $success = $false
    $lastMessage = ''
    for ($i = 1; $i -le $RetryCount; $i++) {
        Write-Log "第 $i/$RetryCount 次尝试登录..."
        $result = Invoke-DrcomLogin -Username $username -Password $password
        $lastMessage = $result.Message

        if ($result.Success) {
            Write-Log "登录接口返回成功（第 $i 次尝试）。"
            Start-Sleep -Seconds 2
            $after = Get-DrcomStatus
            if ($after.Online) {
                Write-Log '复检结果：已在线，自动登录成功。'
                $success = $true
                break
            }
            if (-not $after.Reachable) {
                Write-Log '登录接口返回成功，但复检时 Portal 不可达，按成功处理。' 'WARN'
                $success = $true
                break
            }
            Write-Log '登录接口返回成功，但复检仍未在线。' 'WARN'
        } elseif ($result.AlreadyOnline) {
            Write-Log "Portal 提示账号已在别处在线：$($result.Message)，复检状态。" 'WARN'
            Start-Sleep -Seconds 2
            $after = Get-DrcomStatus
            if ($after.Reachable -and $after.Online) {
                Write-Log '复检结果：已在线，视为登录成功。'
                $success = $true
                break
            }
        } else {
            Write-Log "登录失败（第 $i 次尝试）：$($result.Message)" 'ERROR'
        }

        if ($i -lt $RetryCount) {
            $delay = $RetryDelaySec
            if ($result.RateLimited) {
                $delay = [Math]::Max($RetryDelaySec, 15)
                Write-Log "Portal 触发了频率限制，等待 $delay 秒后重试。"
            }
            Start-Sleep -Seconds $delay
        }
    }

    if ($success) {
        $state['Online'] = $true
        $state['LastResult'] = 'login-ok'
        $state['LastError'] = ''
        $state['ConsecutiveFailures'] = 0
        $state['LastLoginSuccess'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $state['LastHeartbeat'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Save-DrcomState -State $state
        exit 0
    }

    $state['Online'] = $false
    $state['LastResult'] = 'login-failed'
    $state['LastError'] = $lastMessage
    $state['ConsecutiveFailures'] = $failures + 1
    Save-DrcomState -State $state

    Write-Log ("自动登录失败（已连续失败 {0} 次）。" -f $state['ConsecutiveFailures']) 'ERROR'
    exit 1
} finally {
    if ($mutexOwned -and $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($mutex) {
        try { $mutex.Dispose() } catch { }
    }
}
