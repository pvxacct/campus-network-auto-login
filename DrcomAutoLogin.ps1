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
      7. 每次运行都会写 state.json（纯本地写入，不发请求），其中 RunCount / LastTrigger
         每次触发都会更新，可用来确认计划任务是否真的每 30 秒把脚本唤起来。

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
    单次运行内登录失败后的最大尝试次数，默认 1 次（下一次检查就在 30 秒后，不必在一次运行里连打）。

.PARAMETER RetryDelaySec
    每次重试之间的等待秒数，默认 8 秒。

.PARAMETER OnlineIntervalSeconds
    “已经能上网”时的兜底巡检间隔（秒），默认读 drcom-config.json 的 OnlineCheckIntervalSeconds，缺省 300。
    平时脚本只用本地方式判断能不能上网（不发请求）：能上网就直接退出，连不上网才去查 Portal、必要时登录。
    这个值决定“能上网时”每隔多久仍然去查一次 Portal，防止系统的联网状态判断滞后导致漏掉真正的掉线。
    设为 0 表示能上网时完全不查（请求最少）；设为负数表示每次触发都查（旧行为）。

.PARAMETER LoginHourlyLimit
    最近 1 小时内最多发起多少次登录请求，默认读 drcom-config.json 的 LoginHourlyLimit，缺省 12。
    超过上限时本次只跳过登录并记录日志，避免异常情况下反复撞 Portal 导致账号被风控；设为 0 表示不限制。

.PARAMETER LoginConfirmDelaySec
    登录前的二次确认等待秒数，默认读 drcom-config.json 的 LoginConfirmDelaySec，缺省 3。
    状态查询判定“离线”后，等这么多秒再复检一次，两次都离线才提交登录，
    避免抓到瞬时或陈旧的离线结果就去登录，把正在使用的会话顶掉。

.PARAMETER LoginMinIntervalSeconds
    两次登录请求之间的硬性最小间隔，默认读 drcom-config.json 的 LoginMinIntervalSeconds，缺省 60。
    无论计划任务被触发得多密集（定时、开机、网络变化事件），这个间隔内都不会提交第二次登录。

.PARAMETER LoginCooldownMinutes
    Portal 明确限流（error5 waitsec / Error code 205）或重复认证冲突后的冷却时长（分钟），
    默认读 drcom-config.json 的 LoginCooldownMinutes，缺省 30。冷却期间只查询状态、不登录。

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
    [int]$RetryCount = 1,
    [int]$RetryDelaySec = 8,
    [int]$OnlineIntervalSeconds = -1,
    [int]$LoginHourlyLimit = -1,
    [int]$LoginConfirmDelaySec = -1,
    [int]$LoginMinIntervalSeconds = -1,
    [int]$LoginCooldownMinutes = -1,
    [int]$HeartbeatMinutes = 60,
    [int]$StatusTimeoutSec = 8,
    [int]$LoginTimeoutSec = 15
)

$ErrorActionPreference = 'Stop'

$script:QuietMode = [bool]$Quiet
$script:ScriptVersion = '1.5.1'

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

function Get-CooldownRemaining {
    param([hashtable]$State)

    $until = Get-DrcomLastTime -State $State -Key 'CooldownUntil'
    if (-not $until) { return 0 }
    $left = ($until - (Get-Date)).TotalSeconds
    if ($left -le 0) { return 0 }
    return [int][Math]::Ceiling($left)
}

function Set-Cooldown {
    param([hashtable]$State, [int]$Minutes, [string]$Reason)

    if ($Minutes -le 0) { return }
    $until = (Get-Date).AddMinutes($Minutes)
    $State['CooldownUntil'] = $until.ToString('yyyy-MM-dd HH:mm:ss')
    $State['CooldownReason'] = $Reason
}

# ===================== 本地网络状态（不发任何请求） =====================
function Test-LocalConnectivity {
    <#
      纯本地判断，不会向 Portal 或外网发出任何请求：
        HasAdapter  = 是否有已连接的网络适配器
        HasInternet = Windows 认为当前能否访问外网（能上网说明校园网会话正常）
        Method      = 判断方式：nlm = 系统网络列表 COM；cim = Get-NetConnectionProfile；
                      fallback = 都读不到，按“有网”处理（退化成 Portal 兜底巡检）
    #>
    $info = @{ HasAdapter = $true; HasInternet = $true; Method = 'nlm' }

    try {
        $info.HasAdapter = [bool][System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    } catch {
        $info.HasAdapter = $true
    }

    try {
        $nlm = New-Object -ComObject Microsoft.Windows.NetworkListManager
        $info.HasInternet = [bool]$nlm.IsConnectedToInternet
        try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($nlm) } catch { }
    } catch {
        # 备用方案：网络连接配置文件里是否有 Internet 连通性
        try {
            $online = $false
            foreach ($profile in (Get-NetConnectionProfile -ErrorAction Stop)) {
                if ($profile.IPv4Connectivity -eq 'Internet' -or $profile.IPv6Connectivity -eq 'Internet') {
                    $online = $true
                    break
                }
            }
            $info.HasInternet = $online
            $info.Method = 'cim'
        } catch {
            # 实在判断不了就不要激进跳过，交给 Portal 兜底巡检
            $info.HasInternet = $true
            $info.Method = 'fallback'
        }
    }

    return $info
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

    # 能上网时的兜底巡检间隔：平时靠本地网络状态判断，只有连不上网才真的去查 Portal
    if ($OnlineIntervalSeconds -lt 0) {
        if ($null -ne $Config.OnlineCheckIntervalSeconds) {
            $OnlineIntervalSeconds = [int]$Config.OnlineCheckIntervalSeconds
        } else {
            $OnlineIntervalSeconds = 300
        }
    }

    # 最近 1 小时内允许的登录请求次数上限，防止异常情况下把账号撞进风控
    if ($LoginHourlyLimit -lt 0) {
        if ($null -ne $Config.LoginHourlyLimit) {
            $LoginHourlyLimit = [int]$Config.LoginHourlyLimit
        } else {
            $LoginHourlyLimit = 12
        }
    }
    if ($LoginHourlyLimit -lt 0) { $LoginHourlyLimit = 0 }

    # 登录前二次确认的等待秒数
    if ($LoginConfirmDelaySec -lt 0) {
        if ($null -ne $Config.LoginConfirmDelaySec) {
            $LoginConfirmDelaySec = [int]$Config.LoginConfirmDelaySec
        } else {
            $LoginConfirmDelaySec = 3
        }
    }
    if ($LoginConfirmDelaySec -lt 0) { $LoginConfirmDelaySec = 0 }

    # 两次登录请求之间的硬性最小间隔
    if ($LoginMinIntervalSeconds -lt 0) {
        if ($null -ne $Config.LoginMinIntervalSeconds) {
            $LoginMinIntervalSeconds = [int]$Config.LoginMinIntervalSeconds
        } else {
            $LoginMinIntervalSeconds = 60
        }
    }
    if ($LoginMinIntervalSeconds -lt 0) { $LoginMinIntervalSeconds = 0 }

    # 明确限流 / 重复认证冲突后的冷却时长
    if ($LoginCooldownMinutes -lt 0) {
        if ($null -ne $Config.LoginCooldownMinutes) {
            $LoginCooldownMinutes = [int]$Config.LoginCooldownMinutes
        } else {
            $LoginCooldownMinutes = 30
        }
    }
    if ($LoginCooldownMinutes -lt 0) { $LoginCooldownMinutes = 0 }

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

    # 触发闸门：计划任务仍然每 30 秒把脚本唤起，但会先在本地判断要不要真的动手。
    #   1) 本机没有可用网络连接   -> 直接退出，不发任何请求；
    #   2) Windows 认为现在能上网 -> 说明校园网会话正常，直接退出，不发任何请求
    #      （除非到了兜底巡检时间，避免系统的联网状态判断滞后导致漏掉真正的掉线）；
    #   3) 连不上网               -> 往下走，查 Portal，必要时自动登录。
    if (-not ($Force -or $Relogin)) {
        $lastProbe = Get-DrcomLastTime -State $state -Key 'LastProbe'

        # 兜底巡检：OnlineIntervalSeconds = 0 表示有网时完全不查；>0 表示每 N 秒查一次；<0 表示每次触发都查
        $probeDue = $true
        if ($OnlineIntervalSeconds -eq 0) {
            $probeDue = $false
        } elseif (($OnlineIntervalSeconds -gt 0) -and $lastProbe) {
            if (((Get-Date) - $lastProbe).TotalSeconds -lt $OnlineIntervalSeconds) { $probeDue = $false }
        }

        $conn = Test-LocalConnectivity
        $state['Connectivity'] = $conn.Method

        # 只写本地状态文件（不产生任何网络请求），让安装自检和诊断脚本能确认
        # “计划任务确实每 30 秒把脚本唤起来了”。之前这里直接 exit，state.json 会长时间不动，
        # 看起来像脚本没在运行。
        $state['RunCount'] = [int]$state['RunCount'] + 1
        $state['LastTrigger'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

        if (-not $conn.HasAdapter) {
            $state['LastResult'] = 'no-adapter'
            Save-DrcomState -State $state
            exit 0
        }
        if ($conn.HasInternet -and -not $probeDue) {
            # 冷却信息比“能上网”更有价值，不要覆盖掉
            if ([string]$state['LastResult'] -ne 'cooldown') { $state['LastResult'] = 'online-skip' }
            Save-DrcomState -State $state
            exit 0
        }
    }

    $state['RunCount'] = [int]$state['RunCount'] + 1
    $state['LastProbe'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $state['LastTrigger'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

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
        # 只在“状态变化”时记一条，避免一直连不上网时每 30 秒刷屏
        if ([string]$state['LastResult'] -ne 'unreachable') {
            Write-Log "Portal 无法访问，本次不尝试登录：$($status.Error)" 'WARN'
        }
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
            if ($OnlineIntervalSeconds -gt 0) {
                $probeText = ("能上网时每 {0} 秒兜底查询一次" -f $OnlineIntervalSeconds)
            } elseif ($OnlineIntervalSeconds -eq 0) {
                $probeText = '能上网时完全不查，只有连不上网络时才自动登录'
            } else {
                $probeText = ("每次触发都查询（每 {0} 秒）" -f $IntervalSeconds)
            }
            Write-Log ("运行正常：Portal 在线（累计执行 {0} 次；任务每 {1} 秒触发，{2}）。" -f $state['RunCount'], $IntervalSeconds, $probeText)
            $state['LastHeartbeat'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }

        Save-DrcomState -State $state
        exit 0
    }

    $failures = [int]$state['ConsecutiveFailures']
    $lastAttempt = Get-DrcomLastTime -State $state -Key 'LastLoginAttempt'

    # ---------- 闸门 1：冷却（Portal 限流 / 重复认证冲突 / 连续失败退避） ----------
    $cooldownLeft = Get-CooldownRemaining -State $state
    if ($cooldownLeft -le 0) {
        # 没有显式冷却时，用连续失败次数推导一个退避冷却
        if ($failures -ge 3 -and $lastAttempt) {
            $backoffMin = [int][Math]::Min([Math]::Pow(2, $failures - 2), 30)
            if (((Get-Date) - $lastAttempt).TotalMinutes -lt $backoffMin) {
                Set-Cooldown -State $state -Minutes $backoffMin -Reason ("连续失败 {0} 次" -f $failures)
                $cooldownLeft = Get-CooldownRemaining -State $state
            }
        }
    }
    if ($cooldownLeft -gt 0) {
        if ([string]$state['LastResult'] -ne 'cooldown') {
            Write-Log ("进入冷却（{0}），约 {1} 分钟后自动恢复；期间只检查状态、不登录。" -f $state['CooldownReason'], [int][Math]::Ceiling($cooldownLeft / 60)) 'WARN'
        }
        $state['Online'] = $false
        $state['LastResult'] = 'cooldown'
        $state['LastError'] = [string]$state['CooldownReason']
        Save-DrcomState -State $state
        exit 1
    }

    # ---------- 闸门 2：两次登录请求之间的硬性最小间隔 ----------
    # 网络抖动、开机触发、网络变化事件连续触发时，也不要在短时间内连打登录。
    if ($LoginMinIntervalSeconds -gt 0) {
        $reference = $lastAttempt
        $lastSuccess = Get-DrcomLastTime -State $state -Key 'LastLoginSuccess'
        if ($lastSuccess -and ((-not $reference) -or ($lastSuccess -gt $reference))) {
            $reference = $lastSuccess
        }
        if ($reference) {
            $elapsed = ((Get-Date) - $reference).TotalSeconds
            if ($elapsed -lt $LoginMinIntervalSeconds) {
                $waitSec = [int][Math]::Ceiling($LoginMinIntervalSeconds - $elapsed)
                if ([string]$state['LastResult'] -ne 'login-wait') {
                    Write-Log ("距上一次登录不到 {0} 秒（还差约 {1} 秒），本次不登录。" -f $LoginMinIntervalSeconds, $waitSec) 'WARN'
                }
                $state['Online'] = $false
                $state['LastResult'] = 'login-wait'
                Save-DrcomState -State $state
                exit 1
            }
        }
    }

    # ---------- 闸门 3：最近 1 小时的登录次数上限 ----------
    $windowStart = Get-DrcomLastTime -State $state -Key 'LoginWindowStart'
    $windowCount = 0
    if ($state.ContainsKey('LoginWindowCount')) { $windowCount = [int]$state['LoginWindowCount'] }
    if ($LoginHourlyLimit -gt 0) {
        if ((-not $windowStart) -or (((Get-Date) - $windowStart).TotalHours -ge 1)) {
            $windowStart = Get-Date
            $windowCount = 0
        }
        if ($windowCount -ge $LoginHourlyLimit) {
            $waitMin = [int][Math]::Ceiling(60 - ((Get-Date) - $windowStart).TotalMinutes)
            if ($waitMin -lt 1) { $waitMin = 1 }
            Write-Log ("最近 1 小时已发起 {0} 次登录（上限 {1} 次），为避免账号被风控，本次不登录，约 {2} 分钟后自动恢复。" -f $windowCount, $LoginHourlyLimit, $waitMin) 'WARN'
            $state['Online'] = $false
            $state['LastResult'] = 'login-throttled'
            $state['LastError'] = '触发登录频率上限，已主动跳过'
            Save-DrcomState -State $state
            exit 1
        }
    }

    # ---------- 闸门 4：登录前二次确认 ----------
    # 第一次查询显示离线时，等几秒再看一眼；只有两次都离线才真的提交登录，
    # 避免抓到瞬时 / 陈旧的离线结果，把正在使用的会话顶掉。
    if ((-not ($Force -or $Relogin)) -and $LoginConfirmDelaySec -gt 0) {
        Start-Sleep -Seconds $LoginConfirmDelaySec
        $confirm = Get-DrcomStatus
        if (-not $confirm.Reachable) {
            Write-Log "复检时 Portal 不可达，本次不登录：$($confirm.Error)" 'WARN'
            $state['Online'] = $false
            $state['LastResult'] = 'unreachable'
            $state['LastError'] = $confirm.Error
            Save-DrcomState -State $state
            exit 0
        }
        if ($confirm.Online) {
            Write-Log ("第一次查询显示离线，{0} 秒后复检已在线，本次不登录。" -f $LoginConfirmDelaySec)
            $state['Online'] = $true
            $state['LastResult'] = 'online'
            $state['LastError'] = ''
            $state['ConsecutiveFailures'] = 0
            $state['LastHeartbeat'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Save-DrcomState -State $state
            exit 0
        }
    }

    # 真正要提交登录了，这时才计数
    if ($status.Online) {
        Write-Log 'Portal 状态：已在线，但因为指定了 -Force / -Relogin，继续执行登录。' 'WARN'
    } else {
        Write-Log 'Portal 状态：未在线，准备自动登录。'
    }

    if ($LoginHourlyLimit -gt 0) {
        if (-not $windowStart) { $windowStart = Get-Date }
        $state['LoginWindowStart'] = $windowStart.ToString('yyyy-MM-dd HH:mm:ss')
        $state['LoginWindowCount'] = $windowCount + 1
    }
    $state['LastLoginAttempt'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $success = $false
    $lastMessage = ''
    $cooldownReason = ''
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
            # 本地复检仍不在线，说明会话被别处占着，继续登录只会互相顶掉
            $cooldownReason = '重复认证冲突（Portal 提示账号已在别处在线，本机复检仍不在线）'
            Write-Log "复检仍未在线，判定为重复认证冲突，不再反复登录。" 'WARN'
            break
        } elseif ($result.RateLimited) {
            # Portal 明确说“太频繁”，立刻收手，而不是等 30 秒又去撞
            $cooldownReason = 'Portal 明确限流（请求过于频繁）'
            Write-Log "Portal 明确限流：$($result.Message)，不再重试。" 'WARN'
            break
        } else {
            Write-Log "登录失败（第 $i 次尝试）：$($result.Message)" 'ERROR'
        }

        if ($i -lt $RetryCount) {
            $delay = $RetryDelaySec
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

    # Portal 明确限流或重复认证冲突：进入长冷却，期间只查状态、不再登录
    if ($cooldownReason -and $LoginCooldownMinutes -gt 0) {
        Set-Cooldown -State $state -Minutes $LoginCooldownMinutes -Reason $cooldownReason
        $state['Online'] = $false
        $state['LastResult'] = 'cooldown'
        $state['LastError'] = $lastMessage
        $state['ConsecutiveFailures'] = $failures + 1
        Save-DrcomState -State $state
        Write-Log ("进入冷却：{0}；约 {1} 分钟后自动恢复（期间只检查状态、不登录）。" -f $cooldownReason, $LoginCooldownMinutes) 'WARN'
        exit 1
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
