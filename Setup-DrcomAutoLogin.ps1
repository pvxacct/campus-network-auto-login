#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Dr.COM 校园网自动登录一键安装。

.DESCRIPTION
    1. 提示输入一次校园网账号密码，用 DPAPI 加密保存；
    2. 注册计划任务（登录时启动、定时检查、网络变化时检查）；
    3. 立即执行一次状态检查。

.EXAMPLE
    右键“以管理员身份运行 PowerShell”，然后执行：
    powershell -ExecutionPolicy Bypass -File .\Setup-DrcomAutoLogin.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Setup-DrcomAutoLogin.ps1 -UserName 2025000000
#>
[CmdletBinding()]
param(
    [string]$UserName = '',
    [string]$TaskName = 'CampusAutoLogin',
    [int]$IntervalMinutes = 0
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) {
    $root = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
$saveScript = Join-Path $root 'Save-DrcomCredential.ps1'
$mainScript = Join-Path $root 'DrcomAutoLogin.ps1'
$taskScript = Join-Path $root 'Install-CampusAutoLoginTask.ps1'

foreach ($file in @($saveScript, $mainScript, $taskScript)) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "缺少文件：$file"
    }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  校园网自动登录一键安装（Dr.COM）' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '第 1 步：保存账号密码（Windows DPAPI 加密，不写明文）'
Write-Host ''

if ([string]::IsNullOrWhiteSpace($UserName)) {
    & $saveScript
} else {
    & $saveScript -UserName $UserName
}

Write-Host ''
Write-Host '第 2 步：注册计划任务'
Write-Host ''

& $taskScript -ScriptPath $mainScript -TaskName $TaskName -IntervalMinutes $IntervalMinutes

Write-Host ''
Write-Host '第 3 步：立即执行一次状态检查'
Write-Host ''

& $mainScript

Write-Host ''
Write-Host '安装完成。' -ForegroundColor Green
Write-Host '  - 登录 Windows 后会自动运行；'
Write-Host '  - 定时检查，掉线后自动重新登录；'
Write-Host '  - 切换 Wi-Fi / 插拔网线时也会触发检查；'
Write-Host "  - 日志：$env:LOCALAPPDATA\CampusAutoLogin\login.log"
Write-Host ''
Write-Host '如需强制验证一次完整登录，可执行：' -ForegroundColor Yellow
Write-Host '  powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -Relogin'
Write-Host ''
