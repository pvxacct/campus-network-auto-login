#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    注册校园网自动登录计划任务。

.DESCRIPTION
    触发时机：
      1. 用户登录时；
      2. 注册后每 N 分钟检查一次（默认读取 drcom-config.json 的 CheckIntervalMinutes）；
      3. 网络配置文件变化时（Wi-Fi 切换、插拔网线）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-CampusAutoLoginTask.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-CampusAutoLoginTask.ps1 -IntervalMinutes 5
#>
[CmdletBinding()]
param(
    [string]$ScriptPath = '',
    [string]$ConfigPath = '',
    [string]$TaskName = 'CampusAutoLogin',
    [int]$IntervalMinutes = 0,
    [switch]$RunAsSystem
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrEmpty($ScriptPath)) {
    $ScriptPath = Join-Path $ScriptRoot 'DrcomAutoLogin.ps1'
}
if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptRoot 'drcom-config.json'
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "找不到主脚本：$ScriptPath"
}

if ($IntervalMinutes -le 0) {
    $IntervalMinutes = 2
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.CheckIntervalMinutes) {
                $IntervalMinutes = [int]$cfg.CheckIntervalMinutes
            }
        } catch {
            Write-Warning "读取配置失败，使用默认间隔 2 分钟：$($_.Exception.Message)"
        }
    }
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ScriptPath)

$triggers = @()
$triggers += New-ScheduledTaskTrigger -AtLogOn
$triggers += New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

# 网络变化触发：Event ID 10000 = NetworkProfile 已连接
try {
    $cimClass = Get-CimClass -Namespace 'root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
    $networkTrigger = New-CimInstance -CimClass $cimClass -ClientOnly
    $networkTrigger.Enabled = $true
    $networkTrigger.Subscription = @'
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">
    <Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10000]]</Select>
  </Query>
</QueryList>
'@
    $triggers += $networkTrigger
    Write-Host '已添加“网络变化”触发器。'
} catch {
    Write-Warning "添加网络变化触发器失败（不影响其他触发器）：$($_.Exception.Message)"
}

if ($RunAsSystem) {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
} else {
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
}

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $triggers `
    -Principal $principal `
    -Settings $settings `
    -Description '检测到校园网未认证时自动登录' `
    -Force | Out-Null

Write-Host ''
Write-Host "计划任务已创建：$TaskName" -ForegroundColor Green
Write-Host "  主脚本：$ScriptPath"
Write-Host "  间隔：每 $IntervalMinutes 分钟"
Write-Host ''
Write-Host '立即运行一次：Start-ScheduledTask -TaskName ' -NoNewline
Write-Host $TaskName
Write-Host '删除任务：Unregister-ScheduledTask -TaskName ' -NoNewline
Write-Host $TaskName -Confirm:$false
