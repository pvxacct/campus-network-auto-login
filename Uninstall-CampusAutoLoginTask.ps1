#Requires -Version 5.1
<#
.SYNOPSIS
    卸载校园网自动登录计划任务。

.DESCRIPTION
    默认只删除计划任务和隐藏启动器，保留凭据、日志与状态文件。
    加上 -RemoveData 会一并删除凭据文件、日志和状态文件。

.PARAMETER RemoveData
    连同凭据、日志、状态文件一起删除。

.PARAMETER NoElevate
    不自动申请管理员权限（脚本内部递归调用时使用）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall-CampusAutoLoginTask.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall-CampusAutoLoginTask.ps1 -RemoveData
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'CampusAutoLogin',
    [string]$DataDir = '',
    [switch]$RemoveData,
    [switch]$NoElevate
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

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    if ($NoElevate) { throw '卸载计划任务需要管理员权限，请用管理员身份重新运行。' }

    Write-Host '卸载计划任务需要管理员权限，正在弹出 UAC 授权窗口...' -ForegroundColor Yellow
    $elevateExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $elevateExe)) { $elevateExe = 'powershell.exe' }

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
        '-File', ('"{0}"' -f $MyInvocation.MyCommand.Path),
        '-TaskName', ('"{0}"' -f $TaskName),
        '-DataDir', ('"{0}"' -f $DataDir)
    )
    if ($RemoveData) { $argList += '-RemoveData' }

    Start-Process -FilePath $elevateExe -ArgumentList $argList -Verb RunAs
    exit 0
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已删除计划任务：$TaskName" -ForegroundColor Green
} else {
    Write-Host "未找到计划任务：$TaskName" -ForegroundColor Yellow
}

$launcherPath = Join-Path $DataDir 'run-hidden.vbs'
if (Test-Path -LiteralPath $launcherPath) {
    Remove-Item -LiteralPath $launcherPath -Force
    Write-Host "已删除隐藏启动器：$launcherPath" -ForegroundColor Green
}

if ($RemoveData) {
    $credentialPath = Join-Path $DataDir 'credential.xml'
    if (Test-Path -LiteralPath $credentialPath) {
        Remove-Item -LiteralPath $credentialPath -Force
        Write-Host "已删除凭据文件：$credentialPath" -ForegroundColor Green
    }

    foreach ($name in @('login.log', 'login.log.old', 'state.json')) {
        $file = Join-Path $DataDir $name
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file -Force
            Write-Host "已删除：$file" -ForegroundColor Green
        }
    }
} else {
    Write-Host '凭据、日志与状态文件已保留（如需一并删除，请加 -RemoveData）。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '卸载完成。' -ForegroundColor Cyan
Write-Host ''

