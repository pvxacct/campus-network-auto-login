#Requires -Version 5.1
<#
.SYNOPSIS
    保存校园网账号密码（Windows DPAPI 加密）。

.DESCRIPTION
    使用 Export-Clixml 保存 PSCredential，密码由 Windows DPAPI 加密，
    只有当前 Windows 用户能解密，不会以明文写入磁盘。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Save-DrcomCredential.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Save-DrcomCredential.ps1 -UserName 2025000000
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [string]$UserName = ''
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrEmpty($Path)) {
    $Path = Join-Path $ScriptRoot 'credential.xml'
}

$dir = Split-Path -Path $Path -Parent
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($UserName)) {
    $cred = Get-Credential -Message '请输入校园网账号和密码'
} else {
    Write-Host ''
    Write-Host "账号：$UserName" -ForegroundColor Cyan
    $secure = Read-Host -Prompt '请输入校园网密码' -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential($UserName, $secure)
}

if ($null -eq $cred) {
    Write-Error '未输入凭据，已取消。'
    exit 1
}

if ($cred.Password.Length -eq 0) {
    Write-Error '密码不能为空，已取消。'
    exit 1
}

$cred | Export-Clixml -LiteralPath $Path -Force

Write-Host ''
Write-Host '凭据已加密保存到：' -ForegroundColor Green
Write-Host "  $Path"
Write-Host ''
Write-Host '提示：该文件与当前 Windows 用户绑定，换用户或换电脑需要重新保存。' -ForegroundColor Yellow
