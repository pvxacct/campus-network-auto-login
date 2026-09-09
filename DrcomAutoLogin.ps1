#Requires -Version 5.1
<#
.SYNOPSIS
    Dr.COM（哆点）校园网自动登录脚本。

.DESCRIPTION
    认证流程：
      1. 读取 drcom-config.json 中的 Portal 配置；
      2. GET  /drcom/chkstatus  查询是否在线（result=1 在线，result=0 离线）；
      3. POST /drcom/login      提交账号密码；
      4. 返回页包含 Dr.COMWebLoginID_3.htm 表示登录成功；
      5. 失败时调用错误码接口，把 userid error2 之类的代码翻译成中文；
      6. 账号密码由 Save-DrcomCredential.ps1 使用 Windows DPAPI 加密保存。

.PARAMETER ConfigPath
    Portal 配置文件路径，默认脚本同目录下的 drcom-config.json。

.PARAMETER CredentialPath
    DPAPI 加密的凭据文件路径，默认脚本同目录下的 credential.xml。

.PARAMETER LogPath
    日志文件路径，默认 %LOCALAPPDATA%\CampusAutoLogin\login.log。

.PARAMETER Force
    即使 Portal 显示已在线，也执行一次登录请求。

.PARAMETER Relogin
    先注销当前会话，等待 ReloginWaitSec 秒后再登录。

.PARAMETER ReloginWaitSec
    注销后等待秒数，默认 5 秒（Portal 要求至少 3 秒）。

.PARAMETER RetryCount
    登录失败后的最大尝试次数，默认 3 次。

.PARAMETER RetryDelaySec
    每次重试之间的等待秒数，默认 10 秒。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -Relogin
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$CredentialPath = '',
    [string]$LogPath = '',
    [switch]$Force,
    [switch]$Relogin,
    [int]$ReloginWaitSec = 5,
    [int]$RetryCount = 3,
    [int]$RetryDelaySec = 10
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptRoot 'drcom-config.json'
}
if ([string]::IsNullOrEmpty($CredentialPath)) {
    $CredentialPath = Join-Path $ScriptRoot 'credential.xml'
}
if ([string]::IsNullOrEmpty($LogPath)) {
    $LogPath = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin\login.log'
}

# ===================== 读取配置 =====================
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
        # 日志失败不影响主流程
    }
    Write-Host $line
}

# ===================== Portal 接口 =====================
function Get-DrcomStatus {
    param([int]$TimeoutSec = 10)

    $callback = 'dr' + (Get-Random -Minimum 100 -Maximum 9999)
    $url = '{0}?callback={1}&v={1}&lang=zh&jsVersion=4.X' -f $StatusUrl, $callback

    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $text = [string]$resp.Content
        $match = [regex]::Match($text, '"result"\s*:\s*(-?\d+)')
        if ($match.Success) {
            return [pscustomobject]@{
                Online = ([int]$match.Groups[1].Value -eq 1)
                Text   = $text
            }
        }
        Write-Log "状态接口返回无法解析：$text" 'WARN'
    } catch {
        Write-Log "状态检测请求失败：$($_.Exception.Message)" 'WARN'
    }

    return [pscustomobject]@{
        Online = $false
        Text   = ''
    }
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
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$TimeoutSec = 15
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
            -TimeoutSec $TimeoutSec `
            -ErrorAction Stop
    } catch {
        return [pscustomobject]@{
            Success     = $false
            RateLimited = $false
            Message     = $_.Exception.Message
        }
    }

    $text = [string]$resp.Content

    if ($text -match 'Dr\.COMWebLoginID_3\.htm') {
        return [pscustomobject]@{
            Success     = $true
            RateLimited = $false
            Message     = '登录成功'
        }
    }

    if ($text -match 'Dr\.COMWebLoginID_2\.htm') {
        $msg = [regex]::Match($text, 'Msg=(\d+)').Groups[1].Value
        $msga = [regex]::Match($text, "msga='([^']*)'").Groups[1].Value
        $prompt = Get-DrcomErrorText -Code $msga
        return [pscustomobject]@{
            Success     = $false
            RateLimited = ($msga -match 'waitsec')
            Message     = ('Msg={0}, {1} -> {2}' -f $msg, $msga, $prompt)
        }
    }

    if ($text -match 'Error code:\s*205' -or $text -match 'waitsec') {
        return [pscustomobject]@{
            Success     = $false
            RateLimited = $true
            Message     = ('请求过于频繁：' + ($text -replace '\s+', ' '))
        }
    }

    $short = $text.Substring(0, [Math]::Min(200, $text.Length)) -replace '\s+', ' '
    return [pscustomobject]@{
        Success     = $false
        RateLimited = $false
        Message     = "未知响应：$short"
    }
}

# ===================== 主流程 =====================
if (-not (Test-Path -LiteralPath $CredentialPath)) {
    Write-Log "找不到凭据文件：$CredentialPath" 'ERROR'
    Write-Log '请先运行 Save-DrcomCredential.ps1 保存校园网账号密码。' 'ERROR'
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
    Write-Log "读取凭据失败（凭据文件与当前 Windows 用户绑定）：$($_.Exception.Message)" 'ERROR'
    exit 1
}

Write-Log "===== 开始检查（账号：$username）====="

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
if ($status.Online -and -not ($Force -or $Relogin)) {
    Write-Log 'Portal 状态：已在线，无需登录。'
    exit 0
}

if ($status.Online -and ($Force -or $Relogin)) {
    Write-Log 'Portal 状态：已在线，但指定了 -Force 或 -Relogin，继续执行登录。' 'WARN'
} else {
    Write-Log 'Portal 状态：未在线，开始自动登录。'
}

$success = $false
for ($i = 1; $i -le $RetryCount; $i++) {
    Write-Log "第 $i/$RetryCount 次尝试登录..."
    $result = Invoke-DrcomLogin -Username $username -Password $password

    if ($result.Success) {
        Write-Log "登录接口返回成功（第 $i 次尝试）。"
        Start-Sleep -Seconds 2
        $after = Get-DrcomStatus
        if ($after.Online) {
            Write-Log '复检结果：已在线，自动登录成功。'
            $success = $true
            break
        }
        Write-Log '登录接口返回成功，但复检仍未在线。' 'WARN'
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

if (-not $success) {
    Write-Log '自动登录失败。' 'ERROR'
    exit 1
}

exit 0
