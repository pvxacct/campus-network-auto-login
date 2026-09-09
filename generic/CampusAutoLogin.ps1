#Requires -Version 5.1
<#
.SYNOPSIS
    校园网（Portal 认证）自动登录脚本。

.DESCRIPTION
    1. 先检测外网是否可达；
    2. 未连通时，向校园网认证接口提交账号密码；
    3. 支持 POST / GET、表单 / JSON、明文 / MD5 / SHA1 / Base64 密码变换；
    4. 账号密码使用 Windows DPAPI 加密保存，由 Save-CampusCredential.ps1 生成。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\CampusAutoLogin.ps1

.EXAMPLE
    .\CampusAutoLogin.ps1 -Force -DumpResponse
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$Force,
    [switch]$DumpResponse,
    [int]$RetryCount = 3,
    [int]$RetryDelaySec = 5
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptRoot 'config.json'
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # 旧系统可能不支持，忽略即可
}

$script:LogDir = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
$script:LogFile = Join-Path $script:LogDir 'login.log'
if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if ((Test-Path -LiteralPath $script:LogFile) -and (Get-Item -LiteralPath $script:LogFile).Length -gt 1MB) {
            Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.old') -Force
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch {
        # 日志失败不影响主流程
    }
    Write-Host $line
}

function Expand-Placeholder {
    param(
        [string]$Text,
        [hashtable]$Values
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $result = $Text
    foreach ($key in $Values.Keys) {
        $result = $result.Replace('{' + $key + '}', [string]$Values[$key])
    }
    return $result
}

function Get-HashString {
    param(
        [Parameter(Mandatory = $true)][string]$Algorithm,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $algo = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
    try {
        $bytes = $algo.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $algo.Dispose()
    }
}

function Convert-Password {
    param(
        [Parameter(Mandatory = $true)][string]$Plain,
        [string]$Transform = 'plain',
        [string]$SaltPrefix = '',
        [string]$SaltSuffix = ''
    )

    $value = $SaltPrefix + $Plain + $SaltSuffix
    switch ($Transform.ToLowerInvariant()) {
        'plain'      { return $Plain }
        'base64'     { return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($value)) }
        'md5'        { return (Get-HashString -Algorithm 'MD5' -Text $value).ToLowerInvariant() }
        'md5-upper'  { return (Get-HashString -Algorithm 'MD5' -Text $value).ToUpperInvariant() }
        'sha1'       { return (Get-HashString -Algorithm 'SHA1' -Text $value).ToLowerInvariant() }
        'sha1-upper' { return (Get-HashString -Algorithm 'SHA1' -Text $value).ToUpperInvariant() }
        default      { throw "不支持的 PasswordTransform：$Transform" }
    }
}

function Get-NetworkContext {
    $ctx = @{
        ip      = ''
        mac     = ''
        gateway = ''
    }

    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1

        if ($route) {
            $ctx.gateway = [string]$route.NextHop

            $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
                Select-Object -First 1
            if ($addr) { $ctx.ip = [string]$addr.IPAddress }

            $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
            if ($adapter) { $ctx.mac = ([string]$adapter.MacAddress).Replace('-', '') }
        }
    } catch {
        Write-Log "获取本机网络信息失败：$($_.Exception.Message)" 'WARN'
    }

    return $ctx
}

function Test-Internet {
    param(
        [object]$CheckUrls,
        [int]$TimeoutSec = 10
    )

    if ($null -eq $CheckUrls) { return $false }

    foreach ($check in $CheckUrls) {
        $url = [string]$check.Url
        $expect = [string]$check.Expect
        if ([string]::IsNullOrWhiteSpace($url)) { continue }

        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
            $ok = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300)
            if ($ok -and -not [string]::IsNullOrEmpty($expect)) {
                $ok = ([string]$resp.Content).Contains($expect)
            }
            if ($ok) { return $true }
        } catch {
            # 被 Portal 劫持或网络不通都会走这里，属于预期情况
        }
    }

    return $false
}

function Invoke-CampusLogin {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [switch]$Dump
    )

    $ctx = Get-NetworkContext
    $values = @{
        username = $Username
        password = $Password
        ip       = $ctx.ip
        mac      = $ctx.mac
        gateway  = $ctx.gateway
    }

    $headers = @{}
    if ($Config.Headers) {
        foreach ($prop in $Config.Headers.PSObject.Properties) {
            $headers[$prop.Name] = Expand-Placeholder -Text ([string]$prop.Value) -Values $values
        }
    }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    if ($Config.PortalPageUrl) {
        $prelude = Expand-Placeholder -Text ([string]$Config.PortalPageUrl) -Values $values
        try {
            Invoke-WebRequest -Uri $prelude -WebSession $session -UseBasicParsing -TimeoutSec ([int]$Config.TimeoutSec) -Headers $headers -MaximumRedirection 5 | Out-Null
            Write-Log "已访问认证页：$prelude"
        } catch {
            Write-Log "访问认证页失败（继续尝试登录）：$($_.Exception.Message)" 'WARN'
        }
    }

    $fields = [ordered]@{}
    if ($Config.StaticFields) {
        foreach ($prop in $Config.StaticFields.PSObject.Properties) {
            $fields[$prop.Name] = Expand-Placeholder -Text ([string]$prop.Value) -Values $values
        }
    }

    $transformed = Convert-Password -Plain $Password `
        -Transform ([string]$Config.PasswordTransform) `
        -SaltPrefix ([string]$Config.PasswordSaltPrefix) `
        -SaltSuffix ([string]$Config.PasswordSaltSuffix)

    $fields[[string]$Config.UsernameField] = $Username
    $fields[[string]$Config.PasswordField] = $transformed

    $uri = Expand-Placeholder -Text ([string]$Config.LoginUrl) -Values $values

    $method = 'POST'
    if ($Config.Method) { $method = ([string]$Config.Method).ToUpperInvariant() }

    $contentType = 'application/x-www-form-urlencoded'
    if ($Config.ContentType) { $contentType = [string]$Config.ContentType }

    $params = @{
        Uri             = $uri
        Method          = $method
        WebSession      = $session
        UseBasicParsing = $true
        TimeoutSec      = [int]$Config.TimeoutSec
    }
    if ($headers.Count -gt 0) { $params.Headers = $headers }

    if ($method -eq 'GET') {
        $pairs = foreach ($entry in $fields.GetEnumerator()) {
            '{0}={1}' -f [uri]::EscapeDataString([string]$entry.Key), [uri]::EscapeDataString([string]$entry.Value)
        }
        $separator = '?'
        if ($uri.Contains('?')) { $separator = '&' }
        $params.Uri = $uri + $separator + ($pairs -join '&')
    } elseif ($contentType -match 'json') {
        $params.Body = ($fields | ConvertTo-Json -Compress)
        $params.ContentType = $contentType
    } else {
        $params.Body = $fields
        $params.ContentType = $contentType
    }

    Write-Log "提交登录请求：$method $($params.Uri)（字段：$($fields.Keys -join ', ')）"

    $resp = Invoke-WebRequest @params
    $bodyText = [string]$resp.Content

    Write-Log "登录接口返回 HTTP $($resp.StatusCode)，响应长度 $($bodyText.Length)"
    if ($Dump) { Write-Log "响应内容：$bodyText" }

    if ($Config.SuccessKeyword) {
        if ($bodyText.Contains([string]$Config.SuccessKeyword)) {
            Write-Log '响应命中 SuccessKeyword，判定登录请求成功。'
            return $true
        }
        Write-Log "响应未命中 SuccessKeyword：$($Config.SuccessKeyword)" 'WARN'
        return $false
    }

    return $true
}

# ------------------------- 主流程 -------------------------

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Log "找不到配置文件：$ConfigPath" 'ERROR'
    exit 1
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$timeout = 10
if ($Config.TimeoutSec) { $timeout = [int]$Config.TimeoutSec }

$credPath = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin\credential.xml'
if ($Config.CredentialPath) {
    $credPath = Expand-Placeholder -Text ([string]$Config.CredentialPath) -Values @{}
}

if (-not (Test-Path -LiteralPath $credPath)) {
    Write-Log "找不到凭据文件：$credPath" 'ERROR'
    Write-Log '请先运行 Save-CampusCredential.ps1 保存账号密码。' 'ERROR'
    exit 1
}

$cred = Import-Clixml -LiteralPath $credPath
$username = $cred.UserName
$password = $cred.GetNetworkCredential().Password

if (-not $Force) {
    Write-Log '正在检测网络连通性...'
    if (Test-Internet -CheckUrls $Config.CheckUrls -TimeoutSec $timeout) {
        Write-Log '网络已连通，无需登录。'
        exit 0
    }
    Write-Log '网络未连通，开始自动登录。'
}

$success = $false
for ($i = 1; $i -le $RetryCount; $i++) {
    try {
        $ok = Invoke-CampusLogin -Config $Config -Username $username -Password $password -Dump:$DumpResponse

        if ($ok) {
            $delay = 2
            if ($Config.VerifyDelaySec) { $delay = [int]$Config.VerifyDelaySec }
            Start-Sleep -Seconds $delay

            if (Test-Internet -CheckUrls $Config.CheckUrls -TimeoutSec $timeout) {
                Write-Log "登录成功（第 $i 次尝试）。"
                $success = $true
                break
            }

            Write-Log '登录接口已返回，但外网仍不可达。' 'WARN'
        }
    } catch {
        Write-Log "登录请求异常（第 $i 次尝试）：$($_.Exception.Message)" 'ERROR'
    }

    if ($i -lt $RetryCount) {
        Start-Sleep -Seconds $RetryDelaySec
    }
}

if (-not $success) {
    Write-Log '自动登录失败，请检查 config.json 中的接口地址和字段名。' 'ERROR'
    exit 1
}

exit 0
