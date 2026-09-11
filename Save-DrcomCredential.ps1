#Requires -Version 5.1
<#
.SYNOPSIS
    保存校园网账号密码（Windows DPAPI 加密）。

.DESCRIPTION
    使用 Export-Clixml 保存 PSCredential，密码由 Windows DPAPI 加密，
    只有当前 Windows 用户能解密，不会以明文写入磁盘，也不会提交到 Git。

    默认保存位置：%LOCALAPPDATA%\CampusAutoLogin\credential.xml
    （DrcomAutoLogin.ps1 也会优先读取这个位置，仓库目录可以随便移动。）

.PARAMETER UserName
    校园网账号。不指定时会弹出输入框让你填写账号和密码。

.PARAMETER Path
    凭据文件路径，默认 <数据目录>\credential.xml。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Save-DrcomCredential.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Save-DrcomCredential.ps1 -UserName 2025000000
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [string]$DataDir = '',
    [string]$UserName = '',
    [System.Security.SecureString]$Password
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrEmpty($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($DataDir)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $DataDir = $ScriptRoot
    } else {
        $DataDir = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
    }
}
if ([string]::IsNullOrEmpty($Path)) { $Path = Join-Path $DataDir 'credential.xml' }

$dir = Split-Path -Path $Path -Parent
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

if ($Password -and -not [string]::IsNullOrWhiteSpace($UserName)) {
    $cred = New-Object System.Management.Automation.PSCredential($UserName, $Password)
} elseif (-not [string]::IsNullOrWhiteSpace($UserName)) {
    Write-Host ''
    Write-Host ("账号：{0}" -f $UserName) -ForegroundColor Cyan
    $secure = Read-Host -Prompt '请输入校园网密码' -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential($UserName, $secure)
} else {
    Write-Host ''
    Write-Host '请在弹出的窗口里填写校园网账号和密码。' -ForegroundColor Cyan
    $cred = Get-Credential -Message '请输入校园网账号和密码'
}

if ($null -eq $cred) {
    Write-Error '未输入凭据，已取消。'
    exit 1
}
if ($cred.Password.Length -eq 0) {
    Write-Error '密码不能为空，已取消。'
    exit 1
}
if ([string]::IsNullOrWhiteSpace($cred.UserName)) {
    Write-Error '账号不能为空，已取消。'
    exit 1
}

$cred | Export-Clixml -LiteralPath $Path -Force

# 立刻回读一次，确认加密文件确实可用（避免以后计划任务里才发现读不出来）
try {
    $verify = Import-Clixml -LiteralPath $Path
    $plain = $verify.GetNetworkCredential().Password
    if ([string]::IsNullOrEmpty($plain)) { throw '回读到的密码为空' }
} catch {
    Write-Error ("凭据文件回读失败，请重试：{0}" -f $_.Exception.Message)
    exit 1
}

Write-Host ''
Write-Host '凭据已加密保存到：' -ForegroundColor Green
Write-Host ("  {0}" -f $Path)
Write-Host ("  账号：{0}" -f $cred.UserName)
Write-Host ''
Write-Host '提示：该文件与当前 Windows 用户绑定，换用户或换电脑需要重新保存。' -ForegroundColor Yellow
Write-Host ''
Write-Host '接下来注册计划任务（需要管理员权限）：' -ForegroundColor Cyan
Write-Host '  powershell -ExecutionPolicy Bypass -File .\Install-CampusAutoLoginTask.ps1'
Write-Host ''

