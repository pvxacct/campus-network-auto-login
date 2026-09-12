#Requires -Version 5.1
<#
.SYNOPSIS
    暂停 / 恢复 / 查看“校园网自动登录”计划任务。

.DESCRIPTION
    暂停（Pause）：禁用计划任务，停止每 30 秒的自动检查；
                    凭据、日志、状态文件都原样保留。
    恢复（Resume）：重新启用计划任务，并立即触发一次检查（掉线会马上登录）。
    状态（Status）：打印任务当前状态、最近一次运行时间与返回码。

    暂停和恢复需要管理员权限，脚本会自动弹出 UAC 授权窗口。

.PARAMETER Action
    要执行的动作：Pause / Resume / Status，默认 Status。

.PARAMETER TaskName
    计划任务名称，默认 CampusAutoLogin。

.PARAMETER NoElevate
    不自动申请管理员权限（脚本内部递归调用时使用）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\CampusAutoLoginTaskState.ps1 -Action Pause

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\CampusAutoLoginTaskState.ps1 -Action Resume
#>
[CmdletBinding()]
param(
    [ValidateSet('Pause', 'Resume', 'Status')]
    [string]$Action = 'Status',
    [string]$TaskName = 'CampusAutoLogin',
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $DataDir = $PSScriptRoot
} else {
    $DataDir = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ===================== 需要管理员权限的动作 =====================
if ($Action -ne 'Status' -and -not (Test-Admin)) {
    if ($NoElevate) { throw '暂停或恢复计划任务需要管理员权限，请用管理员身份重新运行。' }

    Write-Host '暂停或恢复计划任务需要管理员权限，正在弹出 UAC 授权窗口，请点击“是”。' -ForegroundColor Yellow
    $elevateExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $elevateExe)) { $elevateExe = 'powershell.exe' }

    $myPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrEmpty($myPath)) { $myPath = Join-Path $PSScriptRoot 'CampusAutoLoginTaskState.ps1' }

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
        '-File', ('"{0}"' -f $myPath),
        '-Action', $Action,
        '-TaskName', ('"{0}"' -f $TaskName),
        '-NoElevate'
    )

    Start-Process -FilePath $elevateExe -ArgumentList $argList -Verb RunAs
    exit 0
}

# ===================== 工具函数 =====================

function ConvertTo-DurationSeconds {
    param($Value)

    if ($null -eq $Value) { return 0 }
    if ($Value -is [TimeSpan]) { return [double]$Value.TotalSeconds }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return 0 }

    $match = [regex]::Match($text, '^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$')
    if (-not $match.Success) { return 0 }

    $seconds = 0.0
    if ($match.Groups[1].Success) { $seconds += [double]$match.Groups[1].Value * 86400 }
    if ($match.Groups[2].Success) { $seconds += [double]$match.Groups[2].Value * 3600 }
    if ($match.Groups[3].Success) { $seconds += [double]$match.Groups[3].Value * 60 }
    if ($match.Groups[4].Success) { $seconds += [double]$match.Groups[4].Value }
    return $seconds
}

function Get-IntervalSummary {
    param($Task)

    $repeatIntervals = @()
    foreach ($trigger in $Task.Triggers) {
        if ($trigger.Repetition -and $trigger.Repetition.Interval) {
            $seconds = ConvertTo-DurationSeconds $trigger.Repetition.Interval
            if ($seconds -gt 0) { $repeatIntervals += $seconds }
        }
    }

    if ($repeatIntervals.Count -eq 2 -and $repeatIntervals[0] -eq $repeatIntervals[1]) {
        return ("约 {0} 秒（两条错开的 1 分钟触发器）" -f [int]($repeatIntervals[0] / 2))
    }
    if ($repeatIntervals.Count -ge 1) {
        return ("约 {0} 秒" -f [int]$repeatIntervals[0])
    }
    return '未知（没有读到重复间隔）'
}

function Show-TaskStatus {
    param($Task, [string]$TaskName)

    $stateText = [string]$Task.State
    switch ($stateText) {
        'Disabled' { $stateText = 'Disabled（已暂停，不会自动检查）' }
        'Ready'    { $stateText = 'Ready（已启用，等待下一次检查）' }
        'Running'  { $stateText = 'Running（正在执行一次检查）' }
        'Queued'   { $stateText = 'Queued（排队等待执行）' }
    }

    Write-Host '【计划任务】'
    Write-Host ("  任务名称：{0}" -f $Task.TaskName)
    Write-Host ("  当前状态：{0}" -f $stateText)
    Write-Host ("  检查间隔：{0}" -f (Get-IntervalSummary $Task))

    try {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
        Write-Host ("  最近运行：{0}" -f $info.LastRunTime)
        Write-Host ("  下次运行：{0}" -f $info.NextRunTime)
        Write-Host ("  最近返回码：{0}（0 = 成功）" -f $info.LastTaskResult)
    } catch {
        Write-Host ("  读取任务运行记录失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Show-RuntimeState {
    param([string]$DataDir)

    Write-Host ''
    Write-Host '【运行状态】'

    $statePath = Join-Path $DataDir 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        Write-Host '  还没有 state.json：脚本可能一次都没有成功运行过。'
        return
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ("  累计运行次数：{0}" -f $state.RunCount)
        if ($null -ne $state.Online) {
            Write-Host ("  当前在线状态：{0}" -f $(if ($state.Online) { '在线' } else { '不在线' }))
        }
        Write-Host ("  最近一次结果：{0}" -f $state.LastResult)
        Write-Host ("  连续失败次数：{0}" -f $state.ConsecutiveFailures)
        if ($state.LastRun) { Write-Host ("  最近一次执行：{0}" -f $state.LastRun) }
    } catch {
        Write-Host ("  解析 state.json 失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Show-LogTail {
    param([string]$DataDir)

    Write-Host ''
    Write-Host '【最近日志】'

    $logPath = Join-Path $DataDir 'login.log'
    if (-not (Test-Path -LiteralPath $logPath)) {
        Write-Host '  还没有 login.log：脚本可能一次都没有成功运行过。'
        return
    }

    Write-Host ("  {0}" -f $logPath)
    foreach ($line in (Get-Content -LiteralPath $logPath -Tail 8 -Encoding UTF8)) {
        Write-Host ('  ' + $line)
    }
}

# ===================== 读取计划任务 =====================
try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
} catch {
    Write-Host ''
    Write-Host ("没有找到计划任务「{0}」。" -f $TaskName) -ForegroundColor Red
    Write-Host '请先双击运行“一键安装.cmd”完成安装，再使用暂停 / 恢复。'
    exit 1
}

Write-Host ''
Write-Host '========================================'
Write-Host ("  校园网自动登录 - {0}" -f $Action)
Write-Host '========================================'
Write-Host ''

switch ($Action) {
    'Pause' {
        if ([string]$task.State -eq 'Disabled') {
            Write-Host '当前已经是暂停状态，无需重复操作。' -ForegroundColor Yellow
        } else {
            Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
            Write-Host '已暂停：不会再自动检查网络，也不会自动登录。' -ForegroundColor Green
        }
        Write-Host ''
        Write-Host '账号密码（DPAPI 加密）、日志和状态文件都原样保留，没有删除任何东西。'
        Write-Host '想恢复时，双击运行“恢复-校园网自动登录.cmd”即可（会自动申请管理员权限）。'
    }
    'Resume' {
        if ([string]$task.State -eq 'Disabled') {
            Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
            Write-Host '已恢复：自动检查已经重新开启。' -ForegroundColor Green
        } else {
            Write-Host '当前已经是启用状态，无需重复操作。' -ForegroundColor Yellow
        }

        try {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Write-Host '已立刻触发一次检查（如果是掉线状态，会马上尝试登录）。'
        } catch {
            Write-Host ("立即触发失败（不影响已恢复的定时检查）：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host '即使不手动触发，最长 1 分钟内也会自动检查一次。'
        Write-Host '想再次暂停时，双击运行“暂停-校园网自动登录.cmd”。'
    }
    default {
        Show-TaskStatus -Task $task -TaskName $TaskName
        Show-RuntimeState -DataDir $DataDir
        Show-LogTail -DataDir $DataDir
        Write-Host ''
        Write-Host '提示：暂停请双击“暂停-校园网自动登录.cmd”，恢复请双击“恢复-校园网自动登录.cmd”。'
    }
}

Write-Host ''
Write-Host '----------------------------------------'
if ($Action -ne 'Status') {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Show-TaskStatus -Task $task -TaskName $TaskName
}
Write-Host ''

exit 0
