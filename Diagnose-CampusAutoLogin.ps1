#Requires -Version 5.1
<#
.SYNOPSIS
    生成校园网自动登录的诊断报告，用来排查“脚本没有正常运行”。

.DESCRIPTION
    会检查并记录：
      1. 运行环境（用户、是否管理员、PowerShell 版本、时间）；
      2. Portal 配置与实时连通性（当前是否在线）；
      3. 凭据文件是否存在、能否解密；
      4. 日志与状态文件内容；
      5. 计划任务是否存在、触发间隔、最近一次运行时间与返回码；
      6. 隐藏启动器是否存在及内容。

    报告会保存到 <数据目录>\diagnose-<时间>.txt，出问题时把这个文件发出来即可。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnose-CampusAutoLogin.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'CampusAutoLogin',
    [string]$ConfigPath = '',
    [string]$DataDir = '',
    [int]$LogTailLines = 40
)

$ErrorActionPreference = 'Continue'

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrEmpty($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }

if ([string]::IsNullOrEmpty($ConfigPath)) { $ConfigPath = Join-Path $ScriptRoot 'drcom-config.json' }
if ([string]::IsNullOrWhiteSpace($DataDir)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $DataDir = $ScriptRoot
    } else {
        $DataDir = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
    }
}

$report = New-Object System.Collections.Generic.List[string]
function Add-Line {
    param([string]$Text = '')
    $report.Add($Text)
    Write-Host $Text
}

Add-Line '=================================================='
Add-Line '  校园网自动登录 诊断报告'
Add-Line '=================================================='
Add-Line ("生成时间：{0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Add-Line ("电脑名称：{0}    用户：{1}\{2}" -f $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME)
Add-Line ("PowerShell：{0}" -f $PSVersionTable.PSVersion.ToString())
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add-Line ("是否管理员：{0}（诊断不需要管理员权限）" -f $isAdmin)
} catch {
    Add-Line ("是否管理员：无法判断（{0}）" -f $_.Exception.Message)
}
Add-Line ("脚本目录：{0}" -f $ScriptRoot)
Add-Line ("数据目录：{0}" -f $DataDir)
Add-Line ''

# ---------- 1. 配置文件 ----------
Add-Line '【1】配置'
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-Line ("  配置文件：{0}" -f $ConfigPath)
        Add-Line ("  PortalHost：{0}" -f $cfg.PortalHost)
        Add-Line ("  检查间隔：{0} 秒" -f $(if ($cfg.CheckIntervalSeconds) { $cfg.CheckIntervalSeconds } elseif ($cfg.CheckIntervalMinutes) { [int]$cfg.CheckIntervalMinutes * 60 } else { 30 }))
    } catch {
        Add-Line ("  配置文件无法解析：{0}" -f $_.Exception.Message)
    }
} else {
    Add-Line ("  找不到配置文件：{0}" -f $ConfigPath)
}
Add-Line ''

# ---------- 2. Portal 连通性 ----------
Add-Line '【2】Portal 连通性'
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $portalHost = [string]$cfg.PortalHost
        $statusPath = '/drcom/chkstatus'
        if ($cfg.StatusPath) { $statusPath = [string]$cfg.StatusPath }
        $url = 'http://{0}{1}?callback=dr1&v=1&lang=zh&jsVersion=4.X' -f $portalHost, $statusPath
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        $sw.Stop()
        $text = [string]$resp.Content
        $match = [regex]::Match($text, '"result"\s*:\s*(-?\d+)')
        $online = $match.Success -and ([int]$match.Groups[1].Value -eq 1)
        Add-Line ("  {0} -> HTTP 200，耗时 {1} 毫秒" -f $url, $sw.ElapsedMilliseconds)
        Add-Line ("  当前状态：{0}" -f $(if ($online) { '已在线' } else { '未在线（需要登录）' }))
        $mac = [regex]::Match($text, '"olmac"\s*:\s*"([^"]*)"').Groups[1].Value
        $ip = [regex]::Match($text, '"v4ip"\s*:\s*"([^"]*)"').Groups[1].Value
        if ($mac) { Add-Line ("  在线终端 MAC：{0}    学校分配 IP：{1}" -f $mac, $ip) }
    } catch {
        Add-Line ("  访问 Portal 失败：{0}" -f $_.Exception.Message)
    }
} else {
    Add-Line '  跳过（没有配置文件）'
}
Add-Line ''

# ---------- 3. 凭据 ----------
Add-Line '【3】凭据文件'
$credentialCandidates = @((Join-Path $DataDir 'credential.xml'), (Join-Path $ScriptRoot 'credential.xml'))
$credentialFound = $false
foreach ($candidate in $credentialCandidates) {
    if (Test-Path -LiteralPath $candidate) {
        $credentialFound = $true
        Add-Line ("  找到：{0}（{1} 字节，修改时间 {2}）" -f $candidate, (Get-Item -LiteralPath $candidate).Length, (Get-Item -LiteralPath $candidate).LastWriteTime)
        try {
            $cred = Import-Clixml -LiteralPath $candidate
            $plain = $cred.GetNetworkCredential().Password
            Add-Line ("  解密结果：账号 '{0}'，密码长度 {1}（只显示长度，不显示内容）" -f $cred.UserName, $plain.Length)
        } catch {
            Add-Line ("  解密失败（多半是换过 Windows 用户）：{0}" -f $_.Exception.Message)
        }
    }
}
if (-not $credentialFound) {
    Add-Line '  没有找到凭据文件，脚本只会检查状态、不会登录。'
    Add-Line '  请运行：powershell -ExecutionPolicy Bypass -File .\Setup-DrcomAutoLogin.ps1'
}
Add-Line ''

# ---------- 4. 状态与日志 ----------
Add-Line '【4】运行状态与日志'
$statePath = Join-Path $DataDir 'state.json'
if (Test-Path -LiteralPath $statePath) {
    Add-Line ("  state.json（{0}）：" -f (Get-Item -LiteralPath $statePath).LastWriteTime)
    Add-Line ('  ' + (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8).Trim())
} else {
    Add-Line '  还没有 state.json：脚本一次都没有被成功执行过。'
}

$logPath = Join-Path $DataDir 'login.log'
if (Test-Path -LiteralPath $logPath) {
    Add-Line ("  日志最后 {0} 行（{1}）：" -f $LogTailLines, $logPath)
    foreach ($line in (Get-Content -LiteralPath $logPath -Tail $LogTailLines -Encoding UTF8)) {
        Add-Line ('  ' + $line)
    }
} else {
    Add-Line '  还没有 login.log：脚本一次都没有被成功执行过。'
}
Add-Line ''

# ---------- 5. 触发闸门与冷却 ----------
Add-Line '【5】触发闸门与冷却'

try {
    $nlm = New-Object -ComObject Microsoft.Windows.NetworkListManager
    $onlineNow = [bool]$nlm.IsConnectedToInternet
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($nlm) } catch { }
    Add-Line ("  现在能否上网：{0}" -f $(if ($onlineNow) { '能（脚本会跳过 Portal 查询，只做兜底巡检）' } else { '不能（脚本会去查 Portal 并自动登录）' }))
} catch {
    Add-Line '  现在能否上网：读不到系统状态（会退化成都市按“有网”处理 + 兜底巡检）'
}

$gateState = $null
if (Test-Path -LiteralPath $statePath) {
    try { $gateState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}

if ($gateState) {
    $methodText = [string]$gateState.Connectivity
    switch ($methodText) {
        'nlm'      { $methodText = 'nlm（系统网络列表 COM，正常）' }
        'cim'      { $methodText = 'cim（Get-NetConnectionProfile，正常）' }
        'fallback' { $methodText = 'fallback（读不到系统联网状态，退化为按兜底间隔查询）' }
        ''         { $methodText = '（还没记录）' }
    }
    Add-Line ("  本地联网判断：{0}" -f $methodText)
    if ($gateState.LastProbe)  { Add-Line ("  最近一次真实查询：{0}" -f $gateState.LastProbe) }
    if ($gateState.LastResult) { Add-Line ("  最近一次结果：{0}" -f $gateState.LastResult) }
    if ($gateState.ConsecutiveFailures) { Add-Line ("  连续失败次数：{0}" -f $gateState.ConsecutiveFailures) }

    $cooldownUntil = $null
    if ($gateState.CooldownUntil) {
        try { $cooldownUntil = [datetime]::Parse([string]$gateState.CooldownUntil) } catch { }
    }
    if ($cooldownUntil -and $cooldownUntil -gt (Get-Date)) {
        $leftMin = [int][Math]::Ceiling(($cooldownUntil - (Get-Date)).TotalMinutes)
        Add-Line ("  冷却中：是（{0}），约 {1} 分钟后恢复" -f $gateState.CooldownReason, $leftMin)
    } elseif ($cooldownUntil) {
        Add-Line ("  冷却中：否（上次原因：{0}，已于 {1} 结束）" -f $gateState.CooldownReason, $gateState.CooldownUntil)
    } else {
        Add-Line '  冷却中：否'
    }
} else {
    Add-Line '  还没有 state.json，无法判断闸门与冷却状态。'
}
Add-Line ''

# ---------- 6. 计划任务 ----------
Add-Line '【6】计划任务'

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

try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Add-Line ("  任务名：{0}    状态：{1}" -f $task.TaskName, $task.State)
    $count = 0
    foreach ($trigger in $task.Triggers) {
        $count++
        $type = '未知触发器'
        try { $type = $trigger.CimClass.CimClassName } catch { }

        $interval = ''
        if ($trigger.Repetition -and $trigger.Repetition.Interval) {
            $seconds = ConvertTo-DurationSeconds $trigger.Repetition.Interval
            if ($seconds -gt 0) { $interval = ("，重复间隔 {0} 秒" -f [int]$seconds) }
        }

        $duration = ''
        if ($trigger.Repetition -and $trigger.Repetition.Duration) {
            $durationSeconds = ConvertTo-DurationSeconds $trigger.Repetition.Duration
            if ($durationSeconds -gt 0 -and $durationSeconds -lt (86400 * 300)) {
                $duration = ("，只在 {0} 天内重复" -f [int]($durationSeconds / 86400))
            }
        }

        Add-Line ("  触发器 {0}：{1}{2}{3}" -f $count, $type, $interval, $duration)
    }
    if ($count -eq 0) { Add-Line '  没有配置任何触发器。' }

    # 有效检查间隔：两条错开的 1 分钟触发器 = 每 30 秒
    $repeatIntervals = @()
    foreach ($trigger in $task.Triggers) {
        if ($trigger.Repetition -and $trigger.Repetition.Interval) {
            $repeatIntervals += (ConvertTo-DurationSeconds $trigger.Repetition.Interval)
        }
    }
    if ($repeatIntervals.Count -eq 2 -and $repeatIntervals[0] -eq $repeatIntervals[1]) {
        Add-Line ("  有效检查间隔：约 {0} 秒（两条错开的 1 分钟触发器）" -f [int]($repeatIntervals[0] / 2))
    } elseif ($repeatIntervals.Count -eq 1) {
        Add-Line ("  有效检查间隔：约 {0} 秒" -f [int]$repeatIntervals[0])
    }

    foreach ($action in $task.Actions) {
        Add-Line ("  执行：{0} {1}" -f $action.Execute, $action.Arguments)
    }

    try {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
        Add-Line ("  最近一次运行：{0}" -f $info.LastRunTime)
        Add-Line ("  下一次运行：{0}" -f $info.NextRunTime)
        Add-Line ("  最近返回码：{0}（0 表示成功）" -f $info.LastTaskResult)
    } catch {
        Add-Line ("  读取任务运行记录失败：{0}" -f $_.Exception.Message)
    }
} catch {
    Add-Line ("  没有找到计划任务 {0}：{1}" -f $TaskName, $_.Exception.Message)
    Add-Line '  请运行：powershell -ExecutionPolicy Bypass -File .\Install-CampusAutoLoginTask.ps1'
}
Add-Line ''

# ---------- 6. 隐藏启动器 ----------
Add-Line '【7】隐藏启动器'
$launcherPath = Join-Path $DataDir 'run-hidden.vbs'
if (Test-Path -LiteralPath $launcherPath) {
    Add-Line ("  存在：{0}" -f $launcherPath)
    foreach ($line in (Get-Content -LiteralPath $launcherPath)) { Add-Line ('  ' + $line) }
    Add-Line ''
    try {
        $probe = Join-Path $DataDir 'wsh-probe.txt'
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force }
        $probeScript = Join-Path $DataDir 'wsh-probe.vbs'
        $probeLines = @(
            'Dim fso, f',
            'Set fso = CreateObject("Scripting.FileSystemObject")',
            ('Set f = fso.CreateTextFile("{0}", True)' -f $probe),
            'f.WriteLine "ok"',
            'f.Close'
        )
        [System.IO.File]::WriteAllText($probeScript, ($probeLines -join "`r`n"), [System.Text.Encoding]::Unicode)
        & (Join-Path $env:SystemRoot 'System32\wscript.exe') //B //Nologo $probeScript | Out-Null
        Start-Sleep -Milliseconds 800
        if (Test-Path -LiteralPath $probe) {
            Add-Line '  Windows 脚本宿主（wscript）可以正常执行。'
            Remove-Item -LiteralPath $probe -Force
        } else {
            Add-Line '  [警告] Windows 脚本宿主（wscript）似乎被禁用或被安全软件拦截。'
            Add-Line '  这种情况下请用 -ActionKind 为直接调用 PowerShell 的方式重新注册任务（安装脚本会在自检失败时自动处理）。'
        }
        if (Test-Path -LiteralPath $probeScript) { Remove-Item -LiteralPath $probeScript -Force }
    } catch {
        Add-Line ("  检测 Windows 脚本宿主失败：{0}" -f $_.Exception.Message)
    }
} else {
    Add-Line '  还没有生成隐藏启动器（重新运行安装脚本会生成）。'
}
Add-Line ''

Add-Line '=================================================='
Add-Line '  报告结束'
Add-Line '=================================================='

if (-not (Test-Path -LiteralPath $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}
$reportPath = Join-Path $DataDir ('diagnose-{0}.txt' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
[System.IO.File]::WriteAllText($reportPath, (($report -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

Write-Host ''
Write-Host ("诊断报告已保存：{0}" -f $reportPath) -ForegroundColor Green
Write-Host '把这个文件的内容发出来即可定位问题。' -ForegroundColor Green
Write-Host ''

