#Requires -Version 5.1
<#
.SYNOPSIS
    卸载校园网自动登录计划任务。

.DESCRIPTION
    默认只删除计划任务，保留 credential.xml 和日志。
    加上 -RemoveData 会同时删除本目录下的 credential.xml 和日志目录。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall-CampusAutoLoginTask.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall-CampusAutoLoginTask.ps1 -RemoveData
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'CampusAutoLogin',
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已删除计划任务：$TaskName" -ForegroundColor Green
} else {
    Write-Host "未找到计划任务：$TaskName" -ForegroundColor Yellow
}

if ($RemoveData) {
    $credentialPath = Join-Path $ScriptRoot 'credential.xml'
    if (Test-Path -LiteralPath $credentialPath) {
        Remove-Item -LiteralPath $credentialPath -Force
        Write-Host "已删除凭据文件：$credentialPath" -ForegroundColor Green
    }

    $logDir = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
    if (Test-Path -LiteralPath $logDir) {
        $resolved = (Resolve-Path -LiteralPath $logDir).Path
        $expected = [System.IO.Path]::GetFullPath($logDir)
        if ($resolved -eq $expected) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
            Write-Host "已删除日志目录：$resolved" -ForegroundColor Green
        } else {
            Write-Warning "日志目录路径校验失败，未删除：$resolved"
        }
    }
}

Write-Host ''
Write-Host '卸载完成。' -ForegroundColor Cyan
