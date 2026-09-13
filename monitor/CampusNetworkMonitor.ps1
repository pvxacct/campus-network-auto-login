#Requires -Version 5.1
<#
.SYNOPSIS
    校园网自动登录 - 只读监控面板（Windows 桌面窗口，WPF 浅色现代界面）。

.DESCRIPTION
    配合 campus-network-auto-login 使用，但完全独立运行：
      * 只读取 state.json、login.log 与计划任务状态；
      * 不创建、不修改任何文件；
      * 除了手动点击“立即检查一次”，不发出任何网络请求。

    界面用 WPF（Windows Presentation Foundation）绘制：圆角卡片、自绘标题栏、
    延迟迷你折线图与连通状态时间线。图表数据只存在内存里，退出即消失。

.PARAMETER DataDir
    数据目录，默认 %LOCALAPPDATA%\CampusAutoLogin。

.PARAMETER ConfigPath
    面板配置，默认脚本同目录的 monitor-config.json。

.PARAMETER DumpOnce
    不打开窗口，把当前状态打印到控制台后退出（供自动化测试使用）。

.PARAMETER SelfTest
    构建窗口、刷新一次后立即退出（GUI 冒烟测试，需要以 -STA 运行）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\CampusNetworkMonitor.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\CampusNetworkMonitor.ps1 -DumpOnce
#>
[CmdletBinding()]
param(
    [string]$DataDir = '',
    [string]$ConfigPath = '',
    [switch]$DumpOnce,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$script:MonitorVersion = '2.0.0'
$script:ExpectedAssistVersion = '1.8.0'
$script:TaskName = 'CampusAutoLogin'

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrEmpty($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }

# ===================== 配置 =====================
$script:Settings = [ordered]@{
    RefreshSeconds   = 5
    StatsWindowHours = 24
    PortalHost       = ''
    StatusPath       = '/drcom/chkstatus'
    StatusTimeoutSec = 8
    DataDir          = ''
    PingEnabled         = $true
    PingIntervalSeconds = 10
    PingTimeoutMs       = 1000
    PingTargets         = 'gateway,portal'
    LatencySamples      = 10
    NetworkInfoSeconds  = 20
    SparklinePoints     = 60
    TimelinePoints      = 60
}

if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptRoot 'monitor-config.json'
}
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfgJson = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $cfgJson.PSObject.Properties) {
            if ($script:Settings.Contains($prop.Name)) {
                if ($null -ne $prop.Value) { $script:Settings[$prop.Name] = $prop.Value }
            }
        }
    } catch {
        Write-Warning ("monitor-config.json 解析失败，使用默认配置：{0}" -f $_.Exception.Message)
    }
}

if ([string]::IsNullOrWhiteSpace($DataDir)) {
    $cfgDataDir = [string]$script:Settings.DataDir
    if (-not [string]::IsNullOrWhiteSpace($cfgDataDir)) {
        $DataDir = $cfgDataDir
    } elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $DataDir = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
    } else {
        $DataDir = $ScriptRoot
    }
}

$script:LogStatsWindowHours = [int]$script:Settings.StatsWindowHours
if ($script:LogStatsWindowHours -le 0) { $script:LogStatsWindowHours = 24 }

$script:PingEnabled = [bool]$script:Settings.PingEnabled

# 延迟探测的运行时状态（只在内存里，不落盘）
$script:Latency = [ordered]@{
    History  = @{}
    Pending  = @()
    Running  = $false
    LastRun  = $null
    Error    = ''
    Targets  = @()
}

# ===================== 基础工具 =====================
function ConvertTo-Text {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [string]$Value
}

function Format-Age {
    param($Time)
    if ($null -eq $Time) { return '（无记录）' }
    $span = (Get-Date) - $Time
    if ($span.TotalSeconds -lt 0) { $span = New-Object TimeSpan(0) }
    if ($span.TotalSeconds -lt 90) { return ('{0} 秒前' -f [int]$span.TotalSeconds) }
    if ($span.TotalMinutes -lt 90) { return ('{0} 分钟前' -f [int]$span.TotalMinutes) }
    return ('{0} 小时前' -f [int]$span.TotalHours)
}

function Format-AgeSpan {
    param($Time)
    if ($null -eq $Time) { return '（无记录）' }
    $span = (Get-Date) - $Time
    if ($span.TotalSeconds -lt 0) { $span = New-Object TimeSpan(0) }
    if ($span.TotalSeconds -lt 90) { return ('{0} 秒' -f [int]$span.TotalSeconds) }
    if ($span.TotalMinutes -lt 90) { return ('{0} 分钟' -f [int]$span.TotalMinutes) }
    return ('{0} 小时' -f [int]$span.TotalHours)
}

function ConvertTo-LocalTime {
    param($Value)
    $text = ConvertTo-Text $Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return [datetime]::Parse($text) } catch { return $null }
}

function Read-StateFile {
    param([string]$Path)

    $result = @{
        Exists        = $false
        Ok            = $false
        Data          = $null
        Raw           = ''
        Error         = ''
        Denied        = $false
        LastWriteTime = $null
    }

    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $result.Exists = $true
    try { $result.LastWriteTime = (Get-Item -LiteralPath $Path).LastWriteTime } catch { }
    try {
        $result.Raw = [string](Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
        $result.Data = $result.Raw | ConvertFrom-Json
        $result.Ok = $true
    } catch {
        $result.Error = $_.Exception.Message
        $inner = $_.Exception
        while ($null -ne $inner) {
            if ($inner -is [System.UnauthorizedAccessException]) { $result.Denied = $true; break }
            $inner = $inner.InnerException
        }
    }
    return $result
}

function Get-DataDirAccess {
    param([string]$DataDir)

    $result = [ordered]@{ Exists = $false; Readable = $false; Denied = $false; Error = '' }
    if (-not (Test-PathSafe $DataDir)) { return $result }
    $result.Exists = $true
    try {
        [void][System.IO.Directory]::GetFileSystemEntries($DataDir)
        $result.Readable = $true
    } catch {
        $result.Error = $_.Exception.Message
        $result.Denied = $true
    }
    return $result
}

function Test-PathSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [bool](Test-Path -LiteralPath $Path) } catch { return $false }
}

function Read-TextAuto {
    param([string]$Path)

    if (-not (Test-PathSafe $Path)) { return '' }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    } catch { return '' }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        try { return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) } catch { return '' }
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        try { return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) } catch { return '' }
    }
    try { return [System.Text.Encoding]::UTF8.GetString($bytes) } catch { return '' }
}

function Get-StateValue {
    param($State, [string]$Key, $Default = $null)
    if ($null -eq $State) { return $Default }
    if ($State -is [System.Collections.IDictionary]) {
        if ($State.Contains($Key)) { return $State[$Key] }
        return $Default
    }
    $prop = $State.PSObject.Properties[$Key]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    if ($Seconds -lt 60) { return ('{0} 秒' -f [int][Math]::Round($Seconds)) }
    if ($Seconds -lt 3600) { return ('{0} 分钟' -f [int][Math]::Floor($Seconds / 60)) }
    $hours = [int][Math]::Floor($Seconds / 3600)
    $minutes = [int][Math]::Floor(($Seconds % 3600) / 60)
    return ('{0} 小时 {1} 分钟' -f $hours, $minutes)
}

function Get-CooldownInfo {
    param($State)

    $until = ConvertTo-LocalTime (Get-StateValue $State 'CooldownUntil')
    $info = [ordered]@{
        Active           = $false
        Until            = $until
        RemainingSeconds = 0
        Reason           = (ConvertTo-Text (Get-StateValue $State 'CooldownReason'))
    }
    if ($null -ne $until) {
        $remaining = ($until - (Get-Date)).TotalSeconds
        if ($remaining -gt 0) {
            $info.Active = $true
            $info.RemainingSeconds = $remaining
        }
    }
    return $info
}

# ===================== 日志（只读末尾若干 KB） =====================
function Read-MonitorLog {
    param([string]$DataDir, [int]$MaxBytes = 524288)

    $entries = New-Object System.Collections.ArrayList
    # 先读轮转出去的旧日志，再读当前日志：两者都是按时间追加的，顺序天然正确
    $paths = @((Join-Path $DataDir 'login.log.old'), (Join-Path $DataDir 'login.log'))

    foreach ($path in $paths) {
        if (-not (Test-PathSafe $path)) { continue }

        $text = ''
        $truncated = $false
        try {
            # FileShare.ReadWrite：主脚本正在追加日志时也能安全读取
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $length = $stream.Length
                $start = 0
                if ($length -gt $MaxBytes) { $start = $length - $MaxBytes; $truncated = $true }
                $stream.Position = $start
                $size = [int]($length - $start)
                $buffer = New-Object byte[] $size
                $read = 0
                while ($read -lt $size) {
                    $got = $stream.Read($buffer, $read, $size - $read)
                    if ($got -le 0) { break }
                    $read += $got
                }
                $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            } finally { $stream.Dispose() }
        } catch { continue }

        $lines = $text -split "\r?\n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            # 截断读取时第一行可能只有后半截，丢掉
            if ($truncated -and $i -eq 0) { continue }
            $line = $lines[$i].TrimEnd()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $match = [regex]::Match($line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \[([A-Z]+)\]\s*(.*)$')
            $time = $null
            $level = 'INFO'
            $message = $line
            if ($match.Success) {
                $time = ConvertTo-LocalTime $match.Groups[1].Value
                $level = $match.Groups[2].Value
                $message = $match.Groups[3].Value
            }
            [void]$entries.Add([pscustomobject]@{
                Time    = $time
                Level   = $level
                Message = $message
                Raw     = $line
            })
        }
    }

    return @($entries)
}

function Get-MonitorLogStats {
    param($Entries, [int]$WindowHours)

    $stats = [ordered]@{
        WindowHours   = $WindowHours
        LoginAttempts = 0
        LoginSuccess  = 0
        LoginFailed   = 0
        Throttled     = 0
        Conflicts     = 0
        Offline       = 0
        Since         = (Get-Date).AddHours(-1 * [double]$WindowHours)
    }

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry.Time) { continue }
        if ($entry.Time -lt $stats.Since) { continue }
        $message = [string]$entry.Message
        if ($message -like '*准备自动登录。*' -or $message -like '*继续执行登录。*') { $stats.LoginAttempts++ }
        if ($message -like '*登录成功*') { $stats.LoginSuccess++ }
        if ($message -like '*自动登录失败*') { $stats.LoginFailed++ }
        # 「进入冷却」那一行只是同一事件的收尾说明，不重复计数
        if ($message -notlike '*进入冷却*') {
            if ($message -like '*Portal 明确限流*') { $stats.Throttled++ }
            if ($message -like '*判定为重复认证冲突*') { $stats.Conflicts++ }
        }
        if ($message -like '*Portal 状态：未在线*') { $stats.Offline++ }
    }
    return $stats
}

# ===================== 计划任务 =====================
function ConvertTo-TaskTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        $time = [datetime]$Value
    } catch { return $null }
    # 从未运行时 CIM 返回 1899-12-30，视为没有记录
    if ($time.Year -lt 1990) { return $null }
    return $time
}

function Get-MonitorTask {
    param([string]$TaskName)

    $result = [ordered]@{
        Exists         = $false
        Error          = ''
        State          = ''
        LastRunTime    = $null
        LastTaskResult = $null
        NextRunTime    = $null
        Actions        = @()
        TriggerText    = ''
    }

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    } catch {
        $result.Error = $_.Exception.Message
        return $result
    }

    $result.Exists = $true
    $result.State = [string]$task.State
    $result.Actions = @($task.Actions)

    $parts = New-Object System.Collections.ArrayList
    foreach ($trigger in @($task.Triggers)) {
        $type = '触发器'
        try { $type = [string]$trigger.CimClass.CimClassName } catch { }
        $interval = ''
        if ($trigger.Repetition -and $trigger.Repetition.Interval) {
            $seconds = ConvertTo-DurationSeconds $trigger.Repetition.Interval
            if ($seconds -gt 0) { $interval = ('每 {0} 秒' -f [int]$seconds) }
        }
        if ([string]::IsNullOrWhiteSpace($interval)) { [void]$parts.Add($type) } else { [void]$parts.Add(('{0}（{1}）' -f $type, $interval)) }
    }
    $result.TriggerText = ($parts -join '、')

    try {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
        $result.LastRunTime = ConvertTo-TaskTime $info.LastRunTime
        $result.NextRunTime = ConvertTo-TaskTime $info.NextRunTime
        $result.LastTaskResult = $info.LastTaskResult
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function ConvertTo-DurationSeconds {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    $match = [regex]::Match($Text, '^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$')
    if (-not $match.Success) { return 0 }
    $seconds = 0.0
    if ($match.Groups[1].Success) { $seconds += [double]$match.Groups[1].Value * 86400 }
    if ($match.Groups[2].Success) { $seconds += [double]$match.Groups[2].Value * 3600 }
    if ($match.Groups[3].Success) { $seconds += [double]$match.Groups[3].Value * 60 }
    if ($match.Groups[4].Success) { $seconds += [double]$match.Groups[4].Value }
    return $seconds
}

function Format-TaskResult {
    param($Value)
    if ($null -eq $Value) { return '（无记录）' }
    try { $raw = [int64]$Value } catch { return [string]$Value }
    # 计划任务的返回码是 32 位无符号数，有的环境会读成负数，统一折算
    $code = $raw -band 0xFFFFFFFFL
    $hex = '0x{0:X}' -f $code
    if ($code -eq 0) { return ('{0}（成功）' -f $hex) }
    $known = @{
        0x8007010B = '起始目录不存在或被删除（僵尸任务）'
        0x41301     = '正在运行'
        0x41303     = '尚未运行过'
    }
    if ($known.ContainsKey([int64]$code)) { return ('{0}（{1}）' -f $hex, $known[[int64]$code]) }
    return $hex
}

# ===================== 路径体检（任务 → 隐藏启动器 → 主脚本） =====================
function Get-MonitorPathAudit {
    param($Task)

    $audit = [ordered]@{
        WorkingDirectory       = ''
        WorkingDirectoryExists = $null
        LauncherPath           = ''
        LauncherExists         = $null
        LauncherText           = ''
        ScriptPath             = ''
        ScriptExists           = $null
        ScriptVersion          = ''
        Zombie                 = $false
        Notes                  = @()
    }

    $notes = New-Object System.Collections.ArrayList

    if (-not $Task.Exists) {
        [void]$notes.Add('没有找到计划任务 CampusAutoLogin，自动登录还没安装或任务已被删除。')
        $audit.Notes = $notes.ToArray()
        return $audit
    }

    $action = $null
    foreach ($item in @($Task.Actions)) { if ($null -eq $action) { $action = $item } }
    if ($null -eq $action) {
        [void]$notes.Add('计划任务里没有任何动作，任务唤醒后什么也不会做。')
        $audit.Notes = $notes.ToArray()
        return $audit
    }

    $audit.WorkingDirectory = [string]$action.WorkingDirectory
    if ([string]::IsNullOrWhiteSpace($audit.WorkingDirectory)) {
        $audit.WorkingDirectoryExists = $null
    } else {
        $audit.WorkingDirectoryExists = Test-PathSafe $audit.WorkingDirectory
        if (-not $audit.WorkingDirectoryExists) {
            [void]$notes.Add(('起始目录不存在：{0}' -f $audit.WorkingDirectory))
        }
    }

    $arguments = [string]$action.Arguments
    $vbsMatch = [regex]::Match($arguments, '"([^"]+\.vbs)"')
    if (-not $vbsMatch.Success) { $vbsMatch = [regex]::Match($arguments, '([A-Za-z]:\\[^"]*?\.vbs)') }
    if ($vbsMatch.Success) {
        $audit.LauncherPath = $vbsMatch.Groups[1].Value
        $audit.LauncherExists = Test-PathSafe $audit.LauncherPath
        if ($audit.LauncherExists) {
            $audit.LauncherText = Read-TextAuto $audit.LauncherPath
            $psMatch = [regex]::Match($audit.LauncherText, '([A-Za-z]:\\[^"]*?\.ps1)')
            if ($psMatch.Success) { $audit.ScriptPath = $psMatch.Groups[1].Value }
        } else {
            [void]$notes.Add(('隐藏启动器不存在：{0}' -f $audit.LauncherPath))
        }
    } elseif ($arguments -match '\.ps1') {
        $psMatch = [regex]::Match($arguments, '"([^"]+\.ps1)"')
        if (-not $psMatch.Success) { $psMatch = [regex]::Match($arguments, '([A-Za-z]:\\[^"]*?\.ps1)') }
        if ($psMatch.Success) { $audit.ScriptPath = $psMatch.Groups[1].Value }
    }

    if (-not [string]::IsNullOrWhiteSpace($audit.ScriptPath)) {
        $audit.ScriptExists = Test-PathSafe $audit.ScriptPath
        if ($audit.ScriptExists) {
            try {
                $scriptText = [string](Get-Content -LiteralPath $audit.ScriptPath -Raw -Encoding UTF8)
                $verMatch = [regex]::Match($scriptText, "ScriptVersion\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'")
                if ($verMatch.Success) { $audit.ScriptVersion = $verMatch.Groups[1].Value }
            } catch { }
        } else {
            [void]$notes.Add(('主脚本不存在：{0}' -f $audit.ScriptPath))
        }
    } else {
        [void]$notes.Add('没能从计划任务里解析出主脚本路径（任务可能被改过）。')
    }

    $broken = ($audit.WorkingDirectoryExists -eq $false) -or ($audit.LauncherExists -eq $false) -or ($audit.ScriptExists -eq $false)
    if ($broken) {
        $audit.Zombie = $true
        [void]$notes.Add('僵尸任务：计划任务每次被唤醒都会立刻失败（返回码 0x8007010B），脚本根本不会运行。')
    }

    $audit.Notes = $notes.ToArray()
    return $audit
}

function Resolve-MonitorPortal {
    param($Audit)

    $result = [ordered]@{
        Host       = ''
        StatusPath = [string]$script:Settings.StatusPath
        Source     = ''
        Available  = $false
        Reason     = ''
    }
    if ([string]::IsNullOrWhiteSpace($result.StatusPath)) { $result.StatusPath = '/drcom/chkstatus' }

    # ① 计划任务指向的主脚本目录里的 drcom-config.json
    if (-not [string]::IsNullOrWhiteSpace($Audit.ScriptPath)) {
        $configPath = Join-Path (Split-Path -Parent $Audit.ScriptPath) 'drcom-config.json'
        if (Test-PathSafe $configPath) {
            try {
                $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $portalHost = [string](Get-StateValue $config 'PortalHost')
                $path = [string](Get-StateValue $config 'StatusPath')
                if (-not [string]::IsNullOrWhiteSpace($portalHost)) {
                    $result.Host = $portalHost
                    if (-not [string]::IsNullOrWhiteSpace($path)) { $result.StatusPath = $path }
                    $result.Source = '主脚本目录的 drcom-config.json'
                    $result.Available = $true
                    return $result
                }
            } catch { }
        }
    }

    # ② 面板自己的 monitor-config.json
    $mine = [string]$script:Settings.PortalHost
    if (-not [string]::IsNullOrWhiteSpace($mine)) {
        $result.Host = $mine
        $result.Source = '面板的 monitor-config.json'
        $result.Available = $true
        return $result
    }

    # ③ 内置默认值
    $result.Host = '10.66.209.2'
    $result.Source = '内置默认值'
    $result.Available = $true
    return $result
}

# ===================== 只读状态查询（点“立即检查一次”才会用到） =====================
function Get-NetworkInfoRaw {
    $info = [ordered]@{
        Adapter    = ''
        IPv4       = ''
        PrefixLen  = 0
        Gateway    = ''
        Dns        = ''
        SpeedText  = ''
        Profile    = ''
        Category   = ''
        Connectivity = ''
        Others     = @()
        Error      = ''
    }

    $primary = $null
    $candidates = New-Object System.Collections.ArrayList
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) { continue }

            $props = $null
            try { $props = $nic.GetIPProperties() } catch { continue }

            $addresses = @($props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
            $ipv4 = ''
            foreach ($address in $addresses) {
                $text = $address.Address.IPAddressToString
                if ($text -like '169.254.*') { continue }
                $ipv4 = $text
                break
            }
            $gateway = ''
            foreach ($gw in @($props.GatewayAddresses)) {
                if ($gw.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $gateway = $gw.Address.IPAddressToString; break }
            }
            if ([string]::IsNullOrWhiteSpace($ipv4)) { continue }

            $dnsList = New-Object System.Collections.ArrayList
            foreach ($dns in @($props.DnsAddresses)) {
                if ($dns.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { [void]$dnsList.Add($dns.IPAddressToString) }
            }

            $item = [pscustomobject]@{
                Name      = [string]$nic.Name
                IPv4      = $ipv4
                Gateway   = $gateway
                Dns       = ($dnsList -join '、')
                SpeedMbps = [int][Math]::Round([double]$nic.Speed / 1000000)
                HasGateway = (-not [string]::IsNullOrWhiteSpace($gateway))
            }
            [void]$candidates.Add($item)
            if ($null -eq $primary -and $item.HasGateway) { $primary = $item }
        }
    } catch {
        $info.Error = $_.Exception.Message
    }

    if ($null -eq $primary) {
        foreach ($item in $candidates) { if ($null -eq $primary) { $primary = $item } }
    }
    if ($null -ne $primary) {
        $info.Adapter = $primary.Name
        $info.IPv4 = $primary.IPv4
        $info.Gateway = $primary.Gateway
        $info.Dns = $primary.Dns
        if ($primary.SpeedMbps -gt 0) { $info.SpeedText = ('{0} Mbps' -f $primary.SpeedMbps) }
    }
    $others = New-Object System.Collections.ArrayList
    foreach ($item in $candidates) {
        if ($null -ne $primary -and $item.Name -eq $primary.Name) { continue }
        [void]$others.Add(('{0} {1}' -f $item.IPv4, $item.Name))
    }
    $info.Others = $others.ToArray()

    # 网络名称 / 类别（普通权限下有时读不到，读不到就空着）
    try {
        $profile = Get-NetConnectionProfile -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $profile) {
            $info.Profile = [string]$profile.Name
            $info.Category = [string]$profile.NetworkCategory
            $info.Connectivity = [string]$profile.IPv4Connectivity
        }
    } catch { }

    return $info
}

function Get-NetworkInfo {
    param([switch]$NoCache)

    $ttl = [double]$script:Settings.NetworkInfoSeconds
    if ($ttl -lt 5) { $ttl = 5 }
    if (-not $NoCache -and $null -ne $script:NetworkCache -and $null -ne $script:NetworkCacheTime) {
        if (((Get-Date) - $script:NetworkCacheTime).TotalSeconds -lt $ttl) { return $script:NetworkCache }
    }
    $script:NetworkCache = Get-NetworkInfoRaw
    $script:NetworkCacheTime = Get-Date
    return $script:NetworkCache
}

# ===================== 延迟探测（ICMP ping，不碰 Portal 的登录接口） =====================
function Get-PingStatusText {
    param($Status)

    switch ([string]$Status) {
        'Success'                    { return '正常' }
        'TimedOut'                   { return '无响应（超时）' }
        'DestinationHostUnreachable' { return '目标不可达' }
        'DestinationNetUnreachable'  { return '网络不可达' }
        'DestinationPortUnreachable' { return '端口不可达' }
        'DestinationProhibited'      { return '被目标拒绝' }
        'TtlExpired'                 { return 'TTL 过期' }
        'BadDestination'             { return '地址无效' }
        default {
            if ([string]::IsNullOrWhiteSpace([string]$Status)) { return '无响应' }
            return [string]$Status
        }
    }
}

function Get-LatencyTargets {
    param($Network, $Portal)

    $targets = New-Object System.Collections.ArrayList
    $mode = [string]$script:Settings.PingTargets
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'gateway,portal' }

    if ($mode -match 'gateway' -and $null -ne $Network -and -not [string]::IsNullOrWhiteSpace($Network.Gateway)) {
        [void]$targets.Add([pscustomobject]@{ Label = '网关'; Host = [string]$Network.Gateway })
    }
    if ($mode -match 'portal' -and $null -ne $Portal -and $Portal.Available -and -not [string]::IsNullOrWhiteSpace($Portal.Host)) {
        $portalHost = [string]$Portal.Host
        if ($portalHost -notmatch ':' -or $portalHost -match '^\[.*\]$') {
            [void]$targets.Add([pscustomobject]@{ Label = 'Portal'; Host = $portalHost })
        }
    }
    return $targets.ToArray()
}

function Add-LatencySample {
    # 参数不能叫 $Host：那是 PowerShell 的只读自动变量
    param([string]$Label, [string]$TargetHost, [bool]$Ok, [int]$RttMs)

    if ([string]::IsNullOrWhiteSpace($Label)) { return }
    if (-not $script:Latency.History.ContainsKey($Label)) {
        $script:Latency.History[$Label] = [ordered]@{
            Host    = $TargetHost
            Samples = (New-Object System.Collections.ArrayList)
        }
    }
    $entry = $script:Latency.History[$Label]
    if (-not [string]::IsNullOrWhiteSpace($TargetHost)) { $entry.Host = $TargetHost }
    [void]$entry.Samples.Add([pscustomobject]@{ Time = (Get-Date); Ok = $Ok; RttMs = $RttMs })

    $limit = [int]$script:Settings.LatencySamples
    if ($limit -lt 3) { $limit = 3 }
    while ($entry.Samples.Count -gt $limit) { $entry.Samples.RemoveAt(0) }
}

function Get-LatencySummary {
    $list = New-Object System.Collections.ArrayList
    foreach ($label in $script:Latency.History.Keys) {
        $entry = $script:Latency.History[$label]
        $samples = @($entry.Samples)
        if ($samples.Count -eq 0) { continue }
        $okSamples = @($samples | Where-Object { $_.Ok })
        $rtts = @($okSamples | ForEach-Object { [int]$_.RttMs })
        $summary = [ordered]@{
            Label     = $label
            Host      = $entry.Host
            Total     = $samples.Count
            OkCount   = $okSamples.Count
            LostCount = $samples.Count - $okSamples.Count
            Current   = -1
            Min       = 0
            Max       = 0
            Avg       = 0
            Ok        = $false
        }
        $last = $samples[$samples.Count - 1]
        if ($last.Ok) { $summary.Current = [int]$last.RttMs; $summary.Ok = $true }
        if ($rtts.Count -gt 0) {
            $summary.Min = ($rtts | Measure-Object -Minimum).Minimum
            $summary.Max = ($rtts | Measure-Object -Maximum).Maximum
            $summary.Avg = [int][Math]::Round((($rtts | Measure-Object -Average).Average))
        }
        [void]$list.Add([pscustomobject]$summary)
    }
    return @($list | Sort-Object -Property @{ Expression = { if ($_.Label -eq '网关') { 0 } else { 1 } } })
}

function Format-LatencyCurrent {
    param($Summary)

    if (-not $script:PingEnabled) { return '已关闭（PingEnabled=false）' }
    $items = @($Summary)
    if ($items.Count -eq 0) { return '（还没有采样）' }
    $parts = New-Object System.Collections.ArrayList
    foreach ($item in $items) {
        if ($item.Ok) { [void]$parts.Add(('{0} {1}：{2} ms' -f $item.Label, $item.Host, $item.Current)) }
        else { [void]$parts.Add(('{0} {1}：无响应' -f $item.Label, $item.Host)) }
    }
    return ($parts -join '｜')
}

function Format-LatencyStats {
    param($Summary)

    $items = @($Summary)
    if ($items.Count -eq 0) { return '（还没有采样）' }
    $parts = New-Object System.Collections.ArrayList
    foreach ($item in $items) {
        $loss = [int][Math]::Round(100.0 * $item.LostCount / [Math]::Max(1, $item.Total))
        if ($item.OkCount -gt 0) {
            [void]$parts.Add(('{0}：平均 {1} ms／最小 {2}／最大 {3}，丢包 {4}%（{5}/{6}）' -f $item.Label, $item.Avg, $item.Min, $item.Max, $loss, $item.LostCount, $item.Total))
        } else {
            [void]$parts.Add(('{0}：全部无响应，丢包 100%（{1}/{2}）' -f $item.Label, $item.LostCount, $item.Total))
        }
    }
    return ($parts -join '｜')
}

function Invoke-LatencyProbeSync {
    param($Targets, [int]$TimeoutMs)

    if (-not $script:PingEnabled) { return }
    if ($TimeoutMs -le 0) { $TimeoutMs = 1000 }
    foreach ($target in @($Targets)) {
        $ok = $false
        $rtt = -1
        try {
            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                $reply = $ping.Send($target.Host, $TimeoutMs)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $ok = $true
                    $rtt = [int]$reply.RoundtripTime
                }
            } finally { $ping.Dispose() }
        } catch { }
        Add-LatencySample -Label $target.Label -TargetHost $target.Host -Ok $ok -RttMs $rtt
    }
    $script:Latency.LastRun = Get-Date
}

function Start-LatencyProbe {
    param($Targets, [int]$TimeoutMs)

    if (-not $script:PingEnabled) { return }
    if ($script:Latency.Running) { return }
    if ($TimeoutMs -le 0) { $TimeoutMs = 1000 }

    $pending = New-Object System.Collections.ArrayList
    foreach ($target in @($Targets)) {
        try {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $task = $ping.SendPingAsync($target.Host, $TimeoutMs)
            [void]$pending.Add([pscustomobject]@{
                Label     = $target.Label
                Host      = $target.Host
                Ping      = $ping
                Task      = $task
                StartedAt = (Get-Date)
            })
        } catch {
            Add-LatencySample -Label $target.Label -TargetHost $target.Host -Ok $false -RttMs -1
        }
    }
    $script:Latency.Pending = $pending.ToArray()
    $script:Latency.Running = ($pending.Count -gt 0)
    $script:Latency.Error = ''
}

function Complete-LatencyProbe {
    if (-not $script:Latency.Running) { return }

    $timeout = [double]$script:Settings.PingTimeoutMs
    if ($timeout -le 0) { $timeout = 1000 }

    $stillPending = New-Object System.Collections.ArrayList
    foreach ($item in @($script:Latency.Pending)) {
        $elapsed = ((Get-Date) - $item.StartedAt).TotalMilliseconds
        if ($item.Task.IsCompleted) {
            $ok = $false
            $rtt = -1
            if ($item.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                try {
                    $reply = $item.Task.Result
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $ok = $true
                        $rtt = [int]$reply.RoundtripTime
                    }
                } catch { }
            }
            Add-LatencySample -Label $item.Label -TargetHost $item.Host -Ok $ok -RttMs $rtt
            try { $item.Ping.Dispose() } catch { }
        } elseif ($elapsed -gt ($timeout + 5000)) {
            Add-LatencySample -Label $item.Label -TargetHost $item.Host -Ok $false -RttMs -1
            try { $item.Ping.Dispose() } catch { }
        } else {
            [void]$stillPending.Add($item)
        }
    }
    $script:Latency.Pending = $stillPending.ToArray()
    if ($stillPending.Count -eq 0) {
        $script:Latency.Running = $false
        $script:Latency.LastRun = Get-Date
    }
}
function Invoke-MonitorStatusCheck {
    # 注意：PowerShell 里 $Host 是只读的自动变量，不能用作参数名
    param([string]$PortalHost, [string]$StatusPath, [int]$TimeoutSec)

    $result = [ordered]@{ Ok = $false; Online = $null; Message = ''; ElapsedMs = 0; Url = '' }
    if ([string]::IsNullOrWhiteSpace($PortalHost)) {
        $result.Message = '没有可用的 Portal 地址。'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = '/drcom/chkstatus' }
    if ($TimeoutSec -le 0) { $TimeoutSec = 8 }

    $url = 'http://{0}{1}?callback=dr1&v=1&lang=zh&jsVersion=4.X' -f $PortalHost, $StatusPath
    $result.Url = $url
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        try { [System.Net.WebRequest]::DefaultWebProxy = $null } catch { }
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $text = [string]$response.Content
        $match = [regex]::Match($text, '"result"\s*:\s*(-?\d+)')
        if ($match.Success) {
            $code = [int]$match.Groups[1].Value
            $result.Ok = $true
            $result.Online = ($code -eq 1)
            if ($code -eq 1) { $result.Message = 'Portal 返回 result=1：当前在线。' }
            else { $result.Message = ('Portal 返回 result={0}：当前离线。' -f $code) }
        } else {
            $preview = $text
            if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) + '…' }
            $result.Message = ('没有解析到 result 字段，返回内容：{0}' -f $preview)
        }
    } catch {
        $result.Message = ('查询失败：{0}' -f $_.Exception.Message)
    }
    $watch.Stop()
    $result.ElapsedMs = $watch.ElapsedMilliseconds
    return $result
}

# ===================== 汇总快照 =====================
function Compare-MonitorVersion {
    param([string]$Left, [string]$Right)
    try { $a = [version]$Left } catch { return 0 }
    try { $b = [version]$Right } catch { return 0 }
    return $a.CompareTo($b)
}

function Get-MonitorSnapshot {
    param([string]$DataDir)

    $now = Get-Date
    $statePath = Join-Path $DataDir 'state.json'
    $stateInfo = Read-StateFile -Path $statePath
    $dirAccess = Get-DataDirAccess -DataDir $DataDir
    $state = $stateInfo.Data
    $lastResult = ConvertTo-Text (Get-StateValue $state 'LastResult')
    $cooldown = Get-CooldownInfo $state
    $task = Get-MonitorTask -TaskName $script:TaskName
    $audit = Get-MonitorPathAudit -Task $task
    $portal = Resolve-MonitorPortal -Audit $audit
    $network = Get-NetworkInfo
    $entries = Read-MonitorLog -DataDir $DataDir
    $stats = Get-MonitorLogStats -Entries $entries -WindowHours $script:LogStatsWindowHours

    $lastTrigger = ConvertTo-LocalTime (Get-StateValue $state 'LastTrigger')
    $lastProbe = ConvertTo-LocalTime (Get-StateValue $state 'LastProbe')
    $lastLoginSuccess = ConvertTo-LocalTime (Get-StateValue $state 'LastLoginSuccess')
    $lastHeartbeat = ConvertTo-LocalTime (Get-StateValue $state 'LastHeartbeat')

    $onlineValue = Get-StateValue $state 'Online'
    $onlineText = '未知'
    if ($null -ne $onlineValue) {
        if ([bool]$onlineValue) { $onlineText = '在线' } else { $onlineText = '离线' }
    }

    $failures = 0
    $failureValue = Get-StateValue $state 'ConsecutiveFailures'
    if ($null -ne $failureValue) { try { $failures = [int]$failureValue } catch { $failures = 0 } }

    $installedVersion = $audit.ScriptVersion
    $versionOutdated = $false
    if (-not [string]::IsNullOrWhiteSpace($installedVersion)) {
        if ((Compare-MonitorVersion $installedVersion '1.5.1') -lt 0) { $versionOutdated = $true }
    }

    # ---- 顶部横幅：按优先级取第一条命中 ----
    $banner = [ordered]@{ Kind = 'gray'; Color = '#666666'; Text = '' }
    if ($dirAccess.Denied -or $stateInfo.Denied) {
        $banner.Kind = 'red'; $banner.Color = '#C00000'
        $banner.Text = '读不到数据目录（权限不足）：请用安装自动登录时的那个 Windows 用户打开面板，不要换用户或换权限运行。'
    } elseif (-not $stateInfo.Exists -and -not $dirAccess.Exists) {
        $banner.Text = '未检测到自动登录：还没有生成 state.json，自动登录可能没装或被删掉了。'
    } elseif (-not $stateInfo.Exists) {
        $banner.Kind = 'red'; $banner.Color = '#C00000'
        $banner.Text = '数据目录里没有 state.json：自动登录可能没装好，或者计划任务从未成功运行过。'
    } elseif (-not $stateInfo.Ok) {
        $banner.Kind = 'red'; $banner.Color = '#C00000'
        $banner.Text = ('state.json 损坏，读不出内容：{0}' -f $stateInfo.Error)
    } elseif ($null -ne $stateInfo.LastWriteTime -and ($now - $stateInfo.LastWriteTime).TotalSeconds -gt 180) {
        $banner.Kind = 'red'; $banner.Color = '#C00000'
        $banner.Text = ('脚本未在运行：state.json 已经 {0} 没更新（任务被禁用？脚本被删？）' -f (Format-AgeSpan $stateInfo.LastWriteTime))
    } elseif ($cooldown.Active) {
        $banner.Kind = 'orange'; $banner.Color = '#C87800'
        $banner.Text = ('冷却中：还剩 {0}，原因：{1}' -f (Format-Duration $cooldown.RemainingSeconds), $cooldown.Reason)
    } elseif ($lastResult -eq 'no-credential' -or $lastResult -eq 'bad-credential') {
        $banner.Kind = 'red'; $banner.Color = '#C00000'
        $banner.Text = '凭据缺失或无法解密：请重新运行安装脚本保存校园网账号密码。'
    } elseif ($lastResult -eq 'online' -or $lastResult -eq 'online-skip' -or $lastResult -eq 'login-ok') {
        $banner.Kind = 'green'; $banner.Color = '#0E7A3C'
        $banner.Text = '正常（在线）：校园网连接正常，脚本正在按 30 秒的节奏守着。'
    } elseif ($lastResult -eq 'unreachable' -or $lastResult -eq 'login-wait' -or $lastResult -eq 'login-throttled' -or $lastResult -eq 'login-failed' -or $lastResult -eq 'no-adapter') {
        $banner.Kind = 'yellow'; $banner.Color = '#8C7A00'
        $banner.Text = ('正在重连：最近结果「{0}」，脚本会在断网时自动登录。' -f (Get-ResultText $lastResult))
    } else {
        $banner.Text = '状态未知：还没有读到最近一次检查的结果。'
    }

    return [ordered]@{
        Now               = $now
        DataDir           = $DataDir
        StatePath         = $statePath
        StateExists       = $stateInfo.Exists
        StateOk           = $stateInfo.Ok
        StateError        = $stateInfo.Error
        StateMtime        = $stateInfo.LastWriteTime
        StateVersion      = (ConvertTo-Text (Get-StateValue $state 'Version'))
        LastResult        = $lastResult
        LastError         = (ConvertTo-Text (Get-StateValue $state 'LastError'))
        LastTrigger       = $lastTrigger
        LastProbe         = $lastProbe
        LastLoginSuccess  = $lastLoginSuccess
        LastHeartbeat     = $lastHeartbeat
        Connectivity      = (ConvertTo-Text (Get-StateValue $state 'Connectivity'))
        OnlineText        = $onlineText
        Failures          = $failures
        Cooldown          = $cooldown
        Task              = $task
        Audit             = $audit
        Portal            = $portal
        Network           = $network
        Latency           = (Get-LatencySummary)
        Stats             = $stats
        LogEntries        = $entries
        InstalledVersion  = $installedVersion
        VersionOutdated   = $versionOutdated
        Banner            = $banner
    }
}

# ===================== 中文映射与指标行 =====================
function Get-ResultText {
    param([string]$Result)

    if ([string]::IsNullOrWhiteSpace($Result)) { return '（无记录）' }
    $map = @{
        'online'          = '在线'
        'online-skip'     = '在线（本地判断跳过查询）'
        'login-ok'        = '刚完成自动登录'
        'login-wait'      = '等待复检，暂不登录'
        'login-throttled' = '被 Portal 限流，本次不登录'
        'login-failed'    = '自动登录失败'
        'cooldown'        = '冷却中（只查状态不登录）'
        'unreachable'     = '连不上 Portal'
        'no-adapter'      = '没有可用的网络连接'
        'no-credential'   = '缺少账号密码'
        'bad-credential'  = '账号密码无法解密'
        'offline'         = '离线'
    }
    if ($map.ContainsKey($Result)) { return $map[$Result] }
    return $Result
}

function Get-ConnectivityText {
    param([string]$Value)

    switch ($Value) {
        'nlm'      { return 'NetworkListManager（COM）' }
        'cim'      { return 'Get-NetConnectionProfile' }
        'fallback' { return '兜底巡检（读不到系统网络状态）' }
        default {
            if ([string]::IsNullOrWhiteSpace($Value)) { return '（无记录）' }
            return $Value
        }
    }
}

function Get-MonitorMetricRows {
    param($Snapshot)

    $rows = New-Object System.Collections.ArrayList
    $stateMtime = $Snapshot.StateMtime
    $stateMtimeText = '（无记录）'
    if ($null -ne $stateMtime) { $stateMtimeText = ('{0}（{1}）' -f $stateMtime.ToString('yyyy-MM-dd HH:mm:ss'), (Format-Age $stateMtime)) }

    $triggerText = '（无记录）'
    if ($null -ne $Snapshot.LastTrigger) { $triggerText = ('{0}（{1}）' -f $Snapshot.LastTrigger.ToString('yyyy-MM-dd HH:mm:ss'), (Format-Age $Snapshot.LastTrigger)) }

    $probeText = '（无记录）'
    if ($null -ne $Snapshot.LastProbe) { $probeText = ('{0}（{1}）' -f $Snapshot.LastProbe.ToString('yyyy-MM-dd HH:mm:ss'), (Format-Age $Snapshot.LastProbe)) }

    $successText = '（无记录）'
    if ($null -ne $Snapshot.LastLoginSuccess) { $successText = ('{0}（{1}）' -f $Snapshot.LastLoginSuccess.ToString('yyyy-MM-dd HH:mm:ss'), (Format-Age $Snapshot.LastLoginSuccess)) }

    $resultText = Get-ResultText $Snapshot.LastResult
    if (-not [string]::IsNullOrWhiteSpace($Snapshot.LastError)) {
        $resultText = ('{0}｜{1}' -f $resultText, $Snapshot.LastError)
    }

    $cooldownText = '没有冷却'
    $cooldownColor = $null
    if ($Snapshot.Cooldown.Active) {
        $cooldownText = ('冷却到 {0}（还剩 {1}）；原因：{2}' -f $Snapshot.Cooldown.Until.ToString('HH:mm:ss'), (Format-Duration $Snapshot.Cooldown.RemainingSeconds), $Snapshot.Cooldown.Reason)
        $cooldownColor = '#C87800'
    }

    $taskText = '没有找到计划任务'
    $taskColor = '#C00000'
    if ($Snapshot.Task.Exists) {
        $taskText = ('{0}｜上次返回码 {1}｜触发器：{2}' -f $Snapshot.Task.State, (Format-TaskResult $Snapshot.Task.LastTaskResult), $Snapshot.Task.TriggerText)
        $taskColor = $null
        if ($null -ne $Snapshot.Task.LastTaskResult) {
            try { if ([int64]$Snapshot.Task.LastTaskResult -ne 0) { $taskColor = '#C87800' } } catch { }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Snapshot.Task.Error)) {
        $taskText = ('{0}｜{1}' -f $taskText, $Snapshot.Task.Error)
    }

    $nextRunText = '（无记录）'
    if ($null -ne $Snapshot.Task.NextRunTime) { $nextRunText = $Snapshot.Task.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') }
    $lastRunText = '（无记录）'
    if ($null -ne $Snapshot.Task.LastRunTime) { $lastRunText = ('{0}（{1}）' -f $Snapshot.Task.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss'), (Format-Age $Snapshot.Task.LastRunTime)) }

    $versionText = '（读不到主脚本）'
    $versionColor = $null
    if (-not [string]::IsNullOrWhiteSpace($Snapshot.InstalledVersion)) {
        $versionText = $Snapshot.InstalledVersion
        if ($Snapshot.VersionOutdated) {
            $versionText = ('{0}（低于 1.5.1，建议重新运行安装脚本升级）' -f $Snapshot.InstalledVersion)
            $versionColor = '#C87800'
        }
    }

    $audit = $Snapshot.Audit
    $wdText = '（任务里没有起始目录）'
    $wdColor = $null
    if (-not [string]::IsNullOrWhiteSpace($audit.WorkingDirectory)) {
        $wdText = $audit.WorkingDirectory
        if ($audit.WorkingDirectoryExists -eq $false) { $wdText = ('{0}（不存在）' -f $wdText); $wdColor = '#C00000' }
    }

    $vbsText = '（任务里没有隐藏启动器）'
    $vbsColor = $null
    if (-not [string]::IsNullOrWhiteSpace($audit.LauncherPath)) {
        $vbsText = $audit.LauncherPath
        if ($audit.LauncherExists -eq $false) { $vbsText = ('{0}（不存在）' -f $vbsText); $vbsColor = '#C00000' }
    }

    $ps1Text = '（解析不出主脚本）'
    $ps1Color = $null
    if (-not [string]::IsNullOrWhiteSpace($audit.ScriptPath)) {
        $ps1Text = $audit.ScriptPath
        if ($audit.ScriptExists -eq $false) { $ps1Text = ('{0}（不存在）' -f $ps1Text); $ps1Color = '#C00000' }
    }

    $stats = $Snapshot.Stats
    $statsText = ('最近 {0} 小时：登录 {1} 次｜成功 {2}｜失败 {3}｜Portal 限流 {4}｜重复认证冲突 {5}｜掉线 {6}' -f `
        $stats.WindowHours, $stats.LoginAttempts, $stats.LoginSuccess, $stats.LoginFailed, $stats.Throttled, $stats.Conflicts, $stats.Offline)

    $network = $Snapshot.Network
    $ipText = '（读不到网卡信息）'
    if ($null -ne $network -and -not [string]::IsNullOrWhiteSpace($network.IPv4)) {
        $ipText = $network.IPv4
        if (-not [string]::IsNullOrWhiteSpace($network.Adapter)) { $ipText = ('{0}｜{1}' -f $network.IPv4, $network.Adapter) }
        if (-not [string]::IsNullOrWhiteSpace($network.SpeedText)) { $ipText = ('{0}（{1}）' -f $ipText, $network.SpeedText) }
        if ($network.Others.Count -gt 0) { $ipText = ('{0}；其它：{1}' -f $ipText, ($network.Others -join '，')) }
    }

    $gatewayText = '（没有默认网关）'
    if ($null -ne $network -and -not [string]::IsNullOrWhiteSpace($network.Gateway)) { $gatewayText = $network.Gateway }

    $profileText = '（读不到网络名称，普通权限下可能取不到）'
    if ($null -ne $network -and -not [string]::IsNullOrWhiteSpace($network.Profile)) {
        $profileText = $network.Profile
        $extras = @()
        if (-not [string]::IsNullOrWhiteSpace($network.Category)) { $extras += $network.Category }
        if (-not [string]::IsNullOrWhiteSpace($network.Connectivity)) { $extras += $network.Connectivity }
        if ($extras.Count -gt 0) { $profileText = ('{0}（{1}）' -f $profileText, ($extras -join '，')) }
    }

    $dnsText = '（无记录）'
    if ($null -ne $network -and -not [string]::IsNullOrWhiteSpace($network.Dns)) { $dnsText = $network.Dns }

    $latency = @($Snapshot.Latency)
    $latencyText = Format-LatencyCurrent -Summary $latency
    if ($script:Latency.Running) { $latencyText = $latencyText + '（正在探测…）' }
    $latencyStatsText = Format-LatencyStats -Summary $latency
    if (-not $script:PingEnabled) { $latencyStatsText = '延迟探测已关闭（monitor-config.json 里把 PingEnabled 设回 true 即可打开）' }

    $add = {
        param([string]$Group, [string]$Label, [string]$Value, $Color)
        [void]$rows.Add([pscustomobject]@{ Group = $Group; Label = $Label; Value = $Value; Color = $Color })
    }

    & $add '运行' '最近触发时间' $triggerText $null
    & $add '运行' '最近真实查询' $probeText $null
    & $add '运行' '最近登录成功' $successText $null
    & $add '运行' '在线状态' $Snapshot.OnlineText $null
    & $add '运行' '最近结果' $resultText $null
    & $add '运行' '连续失败次数' ([string]$Snapshot.Failures) $(if ($Snapshot.Failures -gt 0) { '#C87800' } else { $null })
    & $add '运行' '冷却' $cooldownText $cooldownColor
    & $add '运行' '本地判断方式' (Get-ConnectivityText $Snapshot.Connectivity) $null
    & $add '任务' '计划任务' $taskText $taskColor
    & $add '任务' '上次运行' $lastRunText $null
    & $add '任务' '下次运行' $nextRunText $null
    & $add '任务' '路径体检·起始目录' $wdText $wdColor
    & $add '任务' '路径体检·隐藏启动器' $vbsText $vbsColor
    & $add '任务' '路径体检·主脚本' $ps1Text $ps1Color
    & $add '任务' '已安装脚本版本' $versionText $versionColor
    & $add '网络' '本机地址' $ipText $null
    & $add '网络' '默认网关' $gatewayText $null
    & $add '网络' '网络类型' $profileText $null
    & $add '网络' 'DNS 服务器' $dnsText $null
    & $add '网络' '网络延迟' $latencyText $(if ($latency.Count -gt 0 -and -not $latency[0].Ok) { '#C87800' } else { $null })
    & $add '网络' '延迟统计' $latencyStatsText $null
    & $add '数据' '数据目录' $Snapshot.DataDir $null
    & $add '数据' 'state.json 修改时间' $stateMtimeText $null
    & $add '数据' '统计' $statsText $null
    & $add '数据' 'Portal 地址' ('{0}（来源：{1}）' -f $Snapshot.Portal.Host, $Snapshot.Portal.Source) $null

    return $rows.ToArray()
}

function Get-MonitorLogTail {
    param($Entries, [int]$Count = 200, [switch]$OnlyProblems)

    $list = @($Entries)
    if ($OnlyProblems) {
        $list = @($list | Where-Object { $_.Level -eq 'WARN' -or $_.Level -eq 'ERROR' })
    }
    if ($list.Count -gt $Count) {
        $list = @($list[($list.Count - $Count)..($list.Count - 1)])
    }
    return $list
}

function Format-MonitorText {
    param($Snapshot, [int]$LogLines = 0, [switch]$OnlyProblems)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(('校园网监控面板 {0}（适配自动登录 {1}）' -f $script:MonitorVersion, $script:ExpectedAssistVersion))
    [void]$lines.Add(('生成时间：{0}' -f $Snapshot.Now.ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$lines.Add(('【状态】{0}' -f $Snapshot.Banner.Text))
    [void]$lines.Add('')
    foreach ($row in (Get-MonitorMetricRows -Snapshot $Snapshot)) {
        [void]$lines.Add(('{0}：{1}' -f $row.Label, $row.Value))
    }
    if ($LogLines -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add(('---------- 最近 {0} 行日志 ----------' -f $LogLines))
        foreach ($entry in (Get-MonitorLogTail -Entries $Snapshot.LogEntries -Count $LogLines -OnlyProblems:$OnlyProblems)) {
            [void]$lines.Add([string]$entry.Raw)
        }
    }
    if ($Snapshot.Audit.Notes.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('---------- 提示 ----------')
        foreach ($note in $Snapshot.Audit.Notes) { [void]$lines.Add(('* ' + [string]$note)) }
    }
    return ($lines -join "`r`n")
}

# ===================== 入口 =====================
# -DumpOnce 是先探一次延迟，这样命令行输出里也有 IP 与延迟信息
if ($DumpOnce) {
    if ($script:PingEnabled) {
        $latencyTargets = Get-LatencyTargets -Network (Get-NetworkInfo -NoCache) -Portal (Resolve-MonitorPortal -Audit (Get-MonitorPathAudit -Task (Get-MonitorTask -TaskName $script:TaskName)))
        Invoke-LatencyProbeSync -Targets $latencyTargets -TimeoutMs ([int][double]$script:Settings.PingTimeoutMs)
    }
}

$script:Snapshot = Get-MonitorSnapshot -DataDir $DataDir

if ($DumpOnce) {
    Write-Output (Format-MonitorText -Snapshot $script:Snapshot -LogLines 3)
    exit 0
}

# WPF 需要 STA 线程：PowerShell 7 默认是 MTA，这时用 Windows PowerShell 5.1 重新拉起自己
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $MyInvocation.MyCommand.Path
    if (-not [string]::IsNullOrWhiteSpace($DataDir)) { $argLine += (' -DataDir "{0}"' -f $DataDir) }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $argLine += (' -ConfigPath "{0}"' -f $ConfigPath) }
    if ($SelfTest) { $argLine += ' -SelfTest' }
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine | Out-Null } catch {
        Write-Warning ('当前线程不是 STA，重新启动失败：{0}' -f $_.Exception.Message)
    }
    exit 0
}

# ===================== WPF 初始化 =====================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# 高分屏下文字更清晰；窗口圆角交给桌面窗口管理器（拿不到就按系统默认来）
if (-not ('CampusPanel.Native' -as [type])) {
    try {
        Add-Type -Namespace CampusPanel -Name Native -MemberDefinition '
        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
' -ErrorAction Stop
    } catch { }
}
try { [void][CampusPanel.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }

# ---- 浅色主题配色 ----
$script:StatusStyle = @{
    gray   = @{ Bg = '#F3F4F6'; Border = '#E5E7EB'; Text = '#4B5563'; Dot = '#9CA3AF' }
    green  = @{ Bg = '#ECFDF5'; Border = '#A7F3D0'; Text = '#047857'; Dot = '#16A34A' }
    yellow = @{ Bg = '#FFFBEB'; Border = '#FDE68A'; Text = '#B45309'; Dot = '#D97706' }
    orange = @{ Bg = '#FFF7ED'; Border = '#FED7AA'; Text = '#C2410C'; Dot = '#EA580C' }
    red    = @{ Bg = '#FEF2F2'; Border = '#FECACA'; Text = '#B91C1C'; Dot = '#DC2626' }
}
$script:SeriesColor = @{ '网关' = '#2563EB'; 'Portal' = '#7C3AED' }
$script:GroupTitle = @{
    '运行' = '运行状态'
    '任务' = '计划任务与路径体检'
    '网络' = '网络'
    '数据' = '数据与统计'
}
$script:BrushCache = @{}

function Get-Brush {
    param([string]$Value, [string]$Fallback = '#6B7280')

    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = $Fallback }
    if ($script:BrushCache.ContainsKey($Value)) { return $script:BrushCache[$Value] }
    $brush = $null
    try { $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Value) } catch { $brush = $null }
    if ($null -eq $brush) { $brush = [System.Windows.Media.Brushes]::Gray }
    $script:BrushCache[$Value] = $brush
    return $brush
}

function Get-StatusStyle {
    param($Kind)

    $key = [string]$Kind
    if ([string]::IsNullOrWhiteSpace($key) -or -not $script:StatusStyle.ContainsKey($key)) { $key = 'gray' }
    return $script:StatusStyle[$key]
}

# ---- 界面：内嵌 XAML（浅色现代风，零第三方依赖）----
$script:XamlHead = '
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="校园网监控面板"
        Width="1160" Height="840" MinWidth="900" MinHeight="620"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        Background="#F5F6F8"
        FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
        <Style x:Key="BaseButton" TargetType="Button">
            <Setter Property="Height" Value="30"/>
            <Setter Property="MinWidth" Value="84"/>
            <Setter Property="Padding" Value="14,0"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Foreground" Value="#374151"/>
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#D1D5DB"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#F3F4F6"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#E5E7EB"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Height" Value="30"/>
            <Setter Property="MinWidth" Value="84"/>
            <Setter Property="Padding" Value="14,0"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" CornerRadius="8" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#1D4ED8"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#1E40AF"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="IconButton" TargetType="Button">
            <Setter Property="Width" Value="40"/>
            <Setter Property="Height" Value="30"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Foreground" Value="#6B7280"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" CornerRadius="6" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#F3F4F6"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
'

$script:XamlTail = '
    <Border x:Name="RootBorder" Background="#F5F6F8" BorderBrush="#DDE1E6" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="42"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="1.35*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1">
                <Grid x:Name="TitleBar" Background="Transparent">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="14,0,0,0">
                        <Border Width="22" Height="22" CornerRadius="6" Background="#2563EB">
                            <TextBlock Text="网" FontSize="12" FontWeight="SemiBold" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock x:Name="TitleText" Text="校园网监控面板" FontSize="13" FontWeight="SemiBold" Foreground="#111827" Margin="10,0,0,0" VerticalAlignment="Center"/>
                        <TextBlock x:Name="TitleVersion" Text="" FontSize="11.5" Foreground="#6B7280" Margin="8,1,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <Button x:Name="BtnMin" Content="—" Style="{StaticResource IconButton}"/>
                        <Button x:Name="BtnMax" Content="□" Style="{StaticResource IconButton}"/>
                        <Button x:Name="BtnClose" Content="✕" Style="{StaticResource IconButton}"/>
                    </StackPanel>
                </Grid>
            </Border>

            <Border x:Name="Banner" Grid.Row="1" Margin="14,12,14,0" Padding="16,14" CornerRadius="12" BorderThickness="1" Background="#F3F4F6" BorderBrush="#E5E7EB">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Border x:Name="BannerDot" Grid.Column="0" Width="10" Height="10" CornerRadius="5" Background="#9CA3AF" VerticalAlignment="Top" Margin="2,5,12,0"/>
                    <StackPanel Grid.Column="1">
                        <TextBlock x:Name="BannerText" Text="正在读取状态…" FontSize="14.5" FontWeight="SemiBold" Foreground="#4B5563" TextWrapping="Wrap"/>
                        <TextBlock x:Name="BannerSub" Text="" FontSize="11.5" Foreground="#6B7280" Margin="0,5,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <TextBlock x:Name="BannerRight" Grid.Column="2" Text="" FontSize="11.5" Foreground="#6B7280" Margin="12,4,0,0" VerticalAlignment="Top"/>
                </Grid>
            </Border>

            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="14,12,2,0">
                <WrapPanel x:Name="CardHost" Orientation="Horizontal"/>
            </ScrollViewer>

            <Grid Grid.Row="3" Margin="14,12,14,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Grid.Column="0" Margin="0,0,12,0" Padding="14,12" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1" CornerRadius="12">
                    <StackPanel>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="延迟趋势" FontSize="13" FontWeight="SemiBold" Foreground="#111827"/>
                            <TextBlock x:Name="SparkText" Grid.Column="1" Text="" FontSize="11.5" Foreground="#6B7280" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
                        </Grid>
                        <Canvas x:Name="SparkCanvas" Height="58" Margin="0,8,0,0" ClipToBounds="True"/>
                    </StackPanel>
                </Border>
                <Border Grid.Column="1" Padding="14,12" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1" CornerRadius="12">
                    <StackPanel>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="连通状态" FontSize="13" FontWeight="SemiBold" Foreground="#111827"/>
                            <TextBlock x:Name="TimelineText" Grid.Column="1" Text="" FontSize="11.5" Foreground="#6B7280" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
                        </Grid>
                        <WrapPanel x:Name="TimelineHost" Margin="0,11,0,0"/>
                    </StackPanel>
                </Border>
            </Grid>

            <Grid Grid.Row="4" Margin="14,12,14,0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0" Margin="2,0,2,8">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <CheckBox x:Name="ChkProblems" Grid.Column="0" Content="只看警告和错误" FontSize="12.5" Foreground="#374151" VerticalAlignment="Center"/>
                    <TextBlock x:Name="LogHint" Grid.Column="1" Text="只读显示 login.log 末尾 200 行" FontSize="11.5" Foreground="#6B7280" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <Border Grid.Row="1" Padding="8,6" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1" CornerRadius="12">
                    <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
                        <ItemsControl x:Name="LogHost"/>
                    </ScrollViewer>
                </Border>
            </Grid>

            <Border Grid.Row="5" Margin="0,12,0,0" Padding="14,10" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="0,1,0,0">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Orientation="Horizontal">
                        <Button x:Name="BtnCheck" Content="立即检查一次" Style="{StaticResource PrimaryButton}" MinWidth="120"/>
                        <Button x:Name="BtnRefresh" Content="刷新" Style="{StaticResource BaseButton}"/>
                        <Button x:Name="BtnOpenDir" Content="打开数据目录" Style="{StaticResource BaseButton}"/>
                        <Button x:Name="BtnCopy" Content="复制诊断信息" Style="{StaticResource BaseButton}"/>
                        <Button x:Name="BtnExit" Content="关闭" Style="{StaticResource BaseButton}"/>
                    </StackPanel>
                    <TextBlock x:Name="FootText" Grid.Column="1" Text="" FontSize="11.5" Foreground="#6B7280" VerticalAlignment="Center" Margin="14,0,10,0" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="FootRight" Grid.Column="2" Text="" FontSize="11.5" Foreground="#6B7280" VerticalAlignment="Center"/>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
'

# ---- 创建窗口并取回控件 ----
$window = [Windows.Markup.XamlReader]::Parse(($script:XamlHead + $script:XamlTail))
$window.Title = ('校园网监控面板 {0}（适配自动登录 {1}）' -f $script:MonitorVersion, $script:ExpectedAssistVersion)
try {
    $iconPath = Join-Path $ScriptRoot 'panel.ico'
    if (Test-Path -LiteralPath $iconPath) {
        $iconImage = New-Object System.Windows.Media.Imaging.BitmapImage
        $iconImage.BeginInit()
        $iconImage.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $iconImage.UriSource = New-Object System.Uri($iconPath)
        $iconImage.EndInit()
        $window.Icon = $iconImage
    }
} catch { }

$script:Ui = @{}
foreach ($name in @('RootBorder', 'TitleBar', 'TitleVersion', 'BtnMin', 'BtnMax', 'BtnClose', 'Banner', 'BannerDot', 'BannerText', 'BannerSub', 'BannerRight', 'CardHost', 'SparkCanvas', 'SparkText', 'TimelineHost', 'TimelineText', 'ChkProblems', 'LogHint', 'LogScroll', 'LogHost', 'BtnCheck', 'BtnRefresh', 'BtnOpenDir', 'BtnCopy', 'BtnExit', 'FootText', 'FootRight')) {
    $script:Ui[$name] = $window.FindName($name)
}
$script:Ui['TitleVersion'].Text = ('{0} · 适配自动登录 {1}' -f $script:MonitorVersion, $script:ExpectedAssistVersion)

$script:LastCheckText = '还没有手动检查过。'
$script:UiError = ''
$script:Trend = @{}
$script:Timeline = New-Object System.Collections.ArrayList
$script:CardWidth = 500.0

# ---- 指标卡片 ----
function New-MonitorCard {
    param([string]$Title, $Rows, [double]$Width)

    $card = New-Object System.Windows.Controls.Border
    $card.Width = $Width
    $card.Margin = New-Object System.Windows.Thickness(0, 0, 12, 12)
    $card.Padding = New-Object System.Windows.Thickness(16, 13, 16, 13)
    $card.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $card.Background = Get-Brush '#FFFFFF'
    $card.BorderBrush = Get-Brush '#E5E7EB'
    $card.BorderThickness = New-Object System.Windows.Thickness(1)

    $stack = New-Object System.Windows.Controls.StackPanel
    $head = New-Object System.Windows.Controls.TextBlock
    $head.Text = $Title
    $head.FontSize = 13
    $head.FontWeight = [System.Windows.FontWeights]::SemiBold
    $head.Foreground = Get-Brush '#111827'
    $head.Margin = New-Object System.Windows.Thickness(0, 0, 0, 7)
    [void]$stack.Children.Add($head)

    foreach ($row in @($Rows)) {
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)

        $columnLabel = New-Object System.Windows.Controls.ColumnDefinition
        $columnLabel.Width = New-Object System.Windows.GridLength(116)
        $columnValue = New-Object System.Windows.Controls.ColumnDefinition
        $columnValue.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        [void]$grid.ColumnDefinitions.Add($columnLabel)
        [void]$grid.ColumnDefinitions.Add($columnValue)

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = [string]$row.Label
        $label.FontSize = 12
        $label.Foreground = Get-Brush '#6B7280'
        $label.TextWrapping = [System.Windows.TextWrapping]::Wrap
        [System.Windows.Controls.Grid]::SetColumn($label, 0)

        $value = New-Object System.Windows.Controls.TextBlock
        $value.Text = [string]$row.Value
        $value.FontSize = 12.5
        $value.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $value.Foreground = Get-Brush ([string]$row.Color) '#111827'
        [System.Windows.Controls.Grid]::SetColumn($value, 1)

        [void]$grid.Children.Add($label)
        [void]$grid.Children.Add($value)
        [void]$stack.Children.Add($grid)
    }

    $card.Child = $stack
    return $card
}

function Update-MonitorCards {
    param($Snapshot, [double]$Width)

    # 变量不能叫 $host：那是 PowerShell 的只读自动变量
    $panel = $script:Ui['CardHost']
    $panel.Children.Clear()

    $groups = [ordered]@{}
    foreach ($row in (Get-MonitorMetricRows -Snapshot $Snapshot)) {
        $groupName = [string]$row.Group
        if (-not $groups.Contains($groupName)) { $groups[$groupName] = (New-Object System.Collections.ArrayList) }
        [void]$groups[$groupName].Add($row)
    }
    foreach ($groupName in $groups.Keys) {
        $title = $groupName
        if ($script:GroupTitle.ContainsKey($groupName)) { $title = $script:GroupTitle[$groupName] }
        [void]$panel.Children.Add((New-MonitorCard -Title $title -Rows $groups[$groupName].ToArray() -Width $Width))
    }
}

# ---- 连通状态时间线 ----
function Update-MonitorTimeline {
    param([string]$Kind)

    $limit = [int]$script:Settings.TimelinePoints
    if ($limit -lt 10) { $limit = 10 }
    [void]$script:Timeline.Add([string]$Kind)
    while ($script:Timeline.Count -gt $limit) { $script:Timeline.RemoveAt(0) }

    # 变量不能叫 $host：那是 PowerShell 的只读自动变量
    $panel = $script:Ui['TimelineHost']
    $panel.Children.Clear()
    $counts = @{}
    $index = 0
    foreach ($item in $script:Timeline) {
        $style = Get-StatusStyle $item
        $cell = New-Object System.Windows.Controls.Border
        $cell.Width = 13
        $cell.Height = 13
        $cell.CornerRadius = New-Object System.Windows.CornerRadius(3)
        $cell.Margin = New-Object System.Windows.Thickness(0, 0, 3, 3)
        $cell.Background = Get-Brush $style.Dot
        $cell.ToolTip = ('第 {0} 格（从左到右由早到晚）' -f ($index + 1))
        [void]$panel.Children.Add($cell)
        if ($counts.ContainsKey($item)) { $counts[$item] = $counts[$item] + 1 } else { $counts[$item] = 1 }
        $index++
    }

    $normal = 0
    if ($counts.ContainsKey('green')) { $normal = $counts['green'] }
    $refreshSeconds = [int][double]$script:Settings.RefreshSeconds
    if ($refreshSeconds -lt 1) { $refreshSeconds = 5 }
    $script:Ui['TimelineText'].Text = ('最近 {0} 次刷新：正常 {1} 次｜每格 {2} 秒' -f $script:Timeline.Count, $normal, $refreshSeconds)
}

# ---- 延迟趋势：只存在内存里，面板退出即消失，不落盘 ----
function Update-TrendBuffer {
    param($Summary)

    $limit = [int]$script:Settings.SparklinePoints
    if ($limit -lt 10) { $limit = 10 }
    foreach ($item in @($Summary)) {
        $label = [string]$item.Label
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        if (-not $script:Trend.ContainsKey($label)) { $script:Trend[$label] = New-Object System.Collections.ArrayList }
        $list = $script:Trend[$label]
        [void]$list.Add([pscustomobject]@{ Ok = [bool]$item.Ok; Rtt = [int]$item.Current })
        while ($list.Count -gt $limit) { $list.RemoveAt(0) }
    }
}

function Update-MonitorSparkline {
    param($Summary)

    $canvas = $script:Ui['SparkCanvas']
    $canvas.Children.Clear()

    $width = [double]$canvas.ActualWidth
    if ($width -le 40) { $width = 460.0 }
    $height = 58.0

    $series = New-Object System.Collections.ArrayList
    foreach ($item in @($Summary)) {
        $label = [string]$item.Label
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        if (-not $script:Trend.ContainsKey($label)) { continue }
        $points = @($script:Trend[$label])
        if ($points.Count -eq 0) { continue }
        [void]$series.Add([pscustomobject]@{
            Label   = $label
            Host    = [string]$item.Host
            Points  = $points
            Current = [int]$item.Current
            Ok      = [bool]$item.Ok
        })
    }

    if ($series.Count -eq 0) {
        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = '（还没有延迟采样）'
        $hint.FontSize = 11.5
        $hint.Foreground = Get-Brush '#9CA3AF'
        [System.Windows.Controls.Canvas]::SetTop($hint, 18)
        [void]$canvas.Children.Add($hint)
        Set-MonitorSparkLegend -Series @()
        return
    }

    foreach ($ratio in @(0.25, 0.75)) {
        $guide = New-Object System.Windows.Shapes.Line
        $guide.X1 = 0
        $guide.X2 = [Math]::Round($width, 1)
        $guide.Y1 = [Math]::Round($height * $ratio, 1)
        $guide.Y2 = $guide.Y1
        $guide.Stroke = Get-Brush '#F1F3F5'
        $guide.StrokeThickness = 1
        [void]$canvas.Children.Add($guide)
    }

    $peak = 60
    foreach ($item in $series) {
        foreach ($point in $item.Points) {
            if ($point.Ok -and [int]$point.Rtt -gt $peak) { $peak = [int]$point.Rtt }
        }
    }
    $peak = [int][Math]::Ceiling($peak * 1.15)

    $columns = [int]$script:Settings.SparklinePoints
    if ($columns -lt 10) { $columns = 10 }

    foreach ($item in $series) {
        $color = '#2563EB'
        if ($script:SeriesColor.ContainsKey($item.Label)) { $color = $script:SeriesColor[$item.Label] }
        $brush = Get-Brush $color

        $points = @($item.Points)
        $offset = $columns - $points.Count
        $segments = New-Object System.Collections.ArrayList
        $segment = New-Object System.Collections.ArrayList
        $lastX = 0.0
        $lastY = 0.0
        $hasLast = $false

        for ($i = 0; $i -lt $points.Count; $i++) {
            $x = 0.0
            if ($columns -gt 1) { $x = [Math]::Round($width * ($offset + $i) / ($columns - 1), 1) }

            if (-not $points[$i].Ok) {
                if ($segment.Count -gt 0) {
                    [void]$segments.Add($segment.ToArray())
                    $segment = New-Object System.Collections.ArrayList
                }
                $lost = New-Object System.Windows.Shapes.Ellipse
                $lost.Width = 4
                $lost.Height = 4
                $lost.Fill = Get-Brush '#EF4444'
                $lost.Opacity = 0.8
                [System.Windows.Controls.Canvas]::SetLeft($lost, [Math]::Round($x - 2, 1))
                [System.Windows.Controls.Canvas]::SetTop($lost, $height - 6)
                [void]$canvas.Children.Add($lost)
                continue
            }

            $y = $height - 6 - ([double][int]$points[$i].Rtt / $peak) * ($height - 14)
            $y = [Math]::Round($y, 1)
            [void]$segment.Add((New-Object System.Windows.Point($x, $y)))
            $lastX = $x
            $lastY = $y
            $hasLast = $true
        }
        if ($segment.Count -gt 0) { [void]$segments.Add($segment.ToArray()) }

        foreach ($one in $segments) {
            $group = @($one)
            if ($group.Count -eq 1) {
                $single = New-Object System.Windows.Shapes.Ellipse
                $single.Width = 5
                $single.Height = 5
                $single.Fill = $brush
                [System.Windows.Controls.Canvas]::SetLeft($single, [Math]::Round($group[0].X - 2.5, 1))
                [System.Windows.Controls.Canvas]::SetTop($single, [Math]::Round($group[0].Y - 2.5, 1))
                [void]$canvas.Children.Add($single)
                continue
            }

            $polyline = New-Object System.Windows.Shapes.Polyline
            $polyline.Stroke = $brush
            $polyline.StrokeThickness = 2
            $polyline.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
            $polyline.Points = New-Object System.Windows.Media.PointCollection
            foreach ($point in $group) { [void]$polyline.Points.Add($point) }
            [void]$canvas.Children.Add($polyline)
        }

        if ($hasLast) {
            $halo = New-Object System.Windows.Shapes.Ellipse
            $halo.Width = 9
            $halo.Height = 9
            $halo.Fill = $brush
            $halo.Opacity = 0.18
            [System.Windows.Controls.Canvas]::SetLeft($halo, [Math]::Round($lastX - 4.5, 1))
            [System.Windows.Controls.Canvas]::SetTop($halo, [Math]::Round($lastY - 4.5, 1))
            [void]$canvas.Children.Add($halo)

            $dot = New-Object System.Windows.Shapes.Ellipse
            $dot.Width = 5
            $dot.Height = 5
            $dot.Fill = $brush
            [System.Windows.Controls.Canvas]::SetLeft($dot, [Math]::Round($lastX - 2.5, 1))
            [System.Windows.Controls.Canvas]::SetTop($dot, [Math]::Round($lastY - 2.5, 1))
            [void]$canvas.Children.Add($dot)
        }
    }

    Set-MonitorSparkLegend -Series $series
}

# 折线图右上角的图例：每个目标一个圆点加当前延迟
function Set-MonitorSparkLegend {
    param($Series)

    $block = $script:Ui['SparkText']
    $block.Inlines.Clear()

    if (@($Series).Count -eq 0) {
        $pingSeconds = [int][double]$script:Settings.PingIntervalSeconds
        if ($pingSeconds -lt 3) { $pingSeconds = 10 }
        $note = New-Object System.Windows.Documents.Run(('每 {0} 秒 ICMP 探测一次' -f $pingSeconds))
        $note.Foreground = Get-Brush '#9CA3AF'
        [void]$block.Inlines.Add($note)
        return
    }

    $first = $true
    foreach ($item in @($Series)) {
        if (-not $first) {
            $gap = New-Object System.Windows.Documents.Run('    ')
            [void]$block.Inlines.Add($gap)
        }
        $first = $false

        $color = '#2563EB'
        if ($script:SeriesColor.ContainsKey($item.Label)) { $color = $script:SeriesColor[$item.Label] }

        $dot = New-Object System.Windows.Documents.Run('● ')
        $dot.Foreground = Get-Brush $color
        [void]$block.Inlines.Add($dot)

        $text = ('{0} 无响应' -f $item.Label)
        if ($item.Ok) { $text = ('{0} {1} ms' -f $item.Label, $item.Current) }
        $run = New-Object System.Windows.Documents.Run($text)
        $run.Foreground = Get-Brush '#374151'
        [void]$block.Inlines.Add($run)
    }
}

# ---- 日志区 ----
function Update-MonitorLogView {
    param($Snapshot)

    # 变量不能叫 $host：那是 PowerShell 的只读自动变量
    $panel = $script:Ui['LogHost']
    $panel.Items.Clear()
    $onlyProblems = [bool]$script:Ui['ChkProblems'].IsChecked
    $entries = @(Get-MonitorLogTail -Entries $Snapshot.LogEntries -Count 200 -OnlyProblems:$onlyProblems)

    if ($entries.Count -eq 0) {
        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = '（没有日志内容）'
        $hint.FontSize = 12
        $hint.Foreground = Get-Brush '#9CA3AF'
        [void]$panel.Items.Add($hint)
    } else {
        $mono = New-Object System.Windows.Media.FontFamily('Consolas, Cascadia Mono, Microsoft YaHei UI')
        foreach ($entry in $entries) {
            $line = New-Object System.Windows.Controls.TextBlock
            $line.Text = [string]$entry.Raw
            $line.FontFamily = $mono
            $line.FontSize = 12
            $line.TextWrapping = [System.Windows.TextWrapping]::NoWrap
            $line.Foreground = Get-Brush '#3C3C3C'
            if ($entry.Level -eq 'WARN') { $line.Foreground = Get-Brush '#B06800' }
            elseif ($entry.Level -eq 'ERROR') { $line.Foreground = Get-Brush '#C00000' }
            [void]$panel.Items.Add($line)
        }
    }
    try { $script:Ui['LogScroll'].ScrollToEnd() } catch { }
}

# ---- 状态横幅下面那行小字 ----
function Get-MonitorBannerSub {
    param($Snapshot)

    $parts = New-Object System.Collections.ArrayList
    if ($Snapshot.Task.Exists) {
        [void]$parts.Add(('计划任务：{0}｜上次返回码 {1}' -f $Snapshot.Task.State, (Format-TaskResult $Snapshot.Task.LastTaskResult)))
    } else {
        [void]$parts.Add('计划任务：没有找到')
    }
    [void]$parts.Add(('最近查询：{0}' -f (Format-Age $Snapshot.LastProbe)))
    [void]$parts.Add(('最近触发：{0}' -f (Format-Age $Snapshot.LastTrigger)))
    [void]$parts.Add(('在线状态：{0}' -f $Snapshot.OnlineText))
    if ($Snapshot.Cooldown.Active) {
        [void]$parts.Add(('冷却到 {0}（{1}）' -f $Snapshot.Cooldown.Until.ToString('HH:mm:ss'), $Snapshot.Cooldown.Reason))
    }
    if ($Snapshot.VersionOutdated) {
        [void]$parts.Add(('已安装脚本 {0}，建议重新运行安装脚本升级' -f $Snapshot.InstalledVersion))
    }
    return ($parts -join '｜')
}

# ---- 统一刷新 ----
function Update-MonitorUi {
    try {
        $script:Snapshot = Get-MonitorSnapshot -DataDir $DataDir
        $snapshot = $script:Snapshot
        $style = Get-StatusStyle $snapshot.Banner.Kind

        $script:Ui['Banner'].Background = Get-Brush $style.Bg
        $script:Ui['Banner'].BorderBrush = Get-Brush $style.Border
        $script:Ui['BannerDot'].Background = Get-Brush $style.Dot
        $script:Ui['BannerText'].Foreground = Get-Brush $style.Text
        $script:Ui['BannerText'].Text = $snapshot.Banner.Text
        $script:Ui['BannerSub'].Text = (Get-MonitorBannerSub -Snapshot $snapshot)
        $script:Ui['BannerRight'].Text = ('刷新于 {0}' -f $snapshot.Now.ToString('HH:mm:ss'))

        Update-MonitorCards -Snapshot $snapshot -Width $script:CardWidth
        Update-MonitorSparkline -Summary $snapshot.Latency
        Update-MonitorTimeline -Kind $snapshot.Banner.Kind
        Update-MonitorLogView -Snapshot $snapshot

        $check = $script:Ui['BtnCheck']
        if ($snapshot.Portal.Available) {
            $check.IsEnabled = $true
            $check.ToolTip = ('向 {0} 发一次只读的状态查询（chkstatus），不会登录、不会写任何文件。' -f $snapshot.Portal.Host)
        } else {
            $check.IsEnabled = $false
            $check.ToolTip = ('没有可用的 Portal 地址，无法查询：{0}' -f $snapshot.Portal.Reason)
        }
        if ([string]$check.Content -ne '检查中…') { $check.Content = '立即检查一次' }

        $stateText = 'state.json 不存在'
        if ($snapshot.StateExists) { $stateText = ('state.json {0}更新' -f (Format-Age $snapshot.StateMtime)) }
        $script:Ui['FootText'].Text = ('数据目录：{0}｜{1}｜Portal：{2}' -f $snapshot.DataDir, $stateText, $snapshot.Portal.Host)
        $script:Ui['FootRight'].Text = ('面板 {0}｜自动登录 {1}' -f $script:MonitorVersion, $script:ExpectedAssistVersion)
        $script:UiError = ''
    } catch {
        $script:UiError = $_.Exception.Message
        $script:Ui['Banner'].Background = Get-Brush '#FEF2F2'
        $script:Ui['Banner'].BorderBrush = Get-Brush '#FECACA'
        $script:Ui['BannerDot'].Background = Get-Brush '#DC2626'
        $script:Ui['BannerText'].Foreground = Get-Brush '#B91C1C'
        $script:Ui['BannerText'].Text = ('刷新状态失败：{0}' -f $_.Exception.Message)
    }
}

# ---- 定时器与事件 ----
$refreshSeconds = [double]$script:Settings.RefreshSeconds
if ($refreshSeconds -lt 1) { $refreshSeconds = 5 }
$pingSeconds = [double]$script:Settings.PingIntervalSeconds
if ($pingSeconds -lt 3) { $pingSeconds = 10 }

$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds($refreshSeconds)

$pingTimer = New-Object System.Windows.Threading.DispatcherTimer
$pingTimer.Interval = [TimeSpan]::FromSeconds($pingSeconds)

$disableTimer = New-Object System.Windows.Threading.DispatcherTimer
$disableTimer.Interval = [TimeSpan]::FromSeconds(5)

function Invoke-MonitorRender {
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [action]{}) } catch { }
}

$refreshTimer.Add_Tick({ try { Update-MonitorUi } catch { } })

# 延迟探测单独一个更慢的节奏：只发 ICMP，不碰 Portal 的登录接口
$pingTimer.Add_Tick({
    try {
        if ($script:Latency.Running) { Complete-LatencyProbe }
        else {
            $targets = Get-LatencyTargets -Network (Get-NetworkInfo) -Portal $script:Snapshot.Portal
            if (@($targets).Count -gt 0) { Start-LatencyProbe -Targets $targets -TimeoutMs ([int][double]$script:Settings.PingTimeoutMs) }
        }
    } catch {
        $script:Latency.Error = $_.Exception.Message
        $script:Latency.Running = $false
    }
    if (-not $script:Latency.Running) {
        Update-TrendBuffer -Summary (Get-LatencySummary)
        try { Update-MonitorSparkline -Summary (Get-LatencySummary) } catch { }
    }
})

$disableTimer.Add_Tick({
    $disableTimer.Stop()
    $script:Ui['BtnCheck'].Content = '立即检查一次'
    $script:Ui['BtnCheck'].IsEnabled = $true
})

$script:Ui['BtnCheck'].Add_Click({
    $snapshot = $script:Snapshot
    if ($null -eq $snapshot -or -not $snapshot.Portal.Available) {
        [void][System.Windows.MessageBox]::Show('没有可用的 Portal 地址，无法查询。', '立即检查一次', 'OK', 'Warning')
        return
    }

    $button = $script:Ui['BtnCheck']
    $button.IsEnabled = $false
    $button.Content = '检查中…'
    Invoke-MonitorRender

    $result = $null
    try {
        $result = Invoke-MonitorStatusCheck -PortalHost $snapshot.Portal.Host -StatusPath $snapshot.Portal.StatusPath -TimeoutSec ([int][double]$script:Settings.StatusTimeoutSec)
    } catch {
        $result = $null
    }

    if ($null -eq $result) {
        $script:LastCheckText = '查询失败：脚本内部出错。'
    } else {
        $script:LastCheckText = ('{0}（地址：{1}，耗时 {2} 毫秒）' -f $result.Message, $result.Url, $result.ElapsedMs)
    }
    [void][System.Windows.MessageBox]::Show($script:LastCheckText, '立即检查一次', 'OK', 'Information')

    # 按钮禁用 5 秒，避免手快连点、对 Portal 造成无谓的压力
    $disableTimer.Interval = [TimeSpan]::FromSeconds(5)
    $disableTimer.Start()
})

$script:Ui['BtnRefresh'].Add_Click({ Update-MonitorUi })
$script:Ui['ChkProblems'].Add_Click({ Update-MonitorLogView -Snapshot $script:Snapshot })

$script:Ui['BtnOpenDir'].Add_Click({
    try {
        if (Test-PathSafe $DataDir) { Start-Process -FilePath $DataDir | Out-Null }
        else { [void][System.Windows.MessageBox]::Show(('目录不存在：{0}' -f $DataDir), '打开数据目录', 'OK', 'Warning') }
    } catch {
        [void][System.Windows.MessageBox]::Show(('打开失败：{0}' -f $_.Exception.Message), '打开数据目录', 'OK', 'Warning')
    }
})

$script:Ui['BtnCopy'].Add_Click({
    try {
        $text = Format-MonitorText -Snapshot $script:Snapshot -LogLines 30
        if (-not [string]::IsNullOrWhiteSpace($script:LastCheckText)) {
            $text = $text + "`r`n" + ('【手动检查】{0}' -f $script:LastCheckText)
        }
        [System.Windows.Clipboard]::SetText($text)
        [void][System.Windows.MessageBox]::Show('诊断信息已复制到剪贴板，可以直接粘贴给别人。', '复制诊断信息', 'OK', 'Information')
    } catch {
        [void][System.Windows.MessageBox]::Show(('复制失败：{0}' -f $_.Exception.Message), '复制诊断信息', 'OK', 'Warning')
    }
})

$script:Ui['BtnExit'].Add_Click({ $window.Close() })
$script:Ui['BtnClose'].Add_Click({ $window.Close() })
$script:Ui['BtnMin'].Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
$script:Ui['BtnMax'].Add_Click({
    if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) { $window.WindowState = [System.Windows.WindowState]::Normal }
    else { $window.WindowState = [System.Windows.WindowState]::Maximized }
})

$script:Ui['TitleBar'].Add_MouseLeftButtonDown({
    param($sender, $eventArgs)

    if ($eventArgs.ClickCount -eq 2) {
        if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) { $window.WindowState = [System.Windows.WindowState]::Normal }
        else { $window.WindowState = [System.Windows.WindowState]::Maximized }
        return
    }
    try { $window.DragMove() } catch { }
})

$window.Add_SizeChanged({
    try {
        # 预留两边的留白、卡片间距和滚动条宽度，正好排成两列
        $width = [Math]::Max(360, [int](($window.ActualWidth - 64) / 2))
        if ($width -ne [int]$script:CardWidth) {
            $script:CardWidth = [double]$width
            foreach ($child in $script:Ui['CardHost'].Children) { $child.Width = $script:CardWidth }
        }
        if ($null -ne $script:Snapshot) { Update-MonitorSparkline -Summary $script:Snapshot.Latency }
    } catch { }
})

$window.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $round = 2
        [void][CampusPanel.Native]::DwmSetWindowAttribute($helper.Handle, 33, [ref]$round, 4)
    } catch { }
})

$window.Add_Loaded({
    try { $script:CardWidth = [Math]::Max(360.0, [double][int](($window.ActualWidth - 64) / 2)) } catch { }
    Update-MonitorUi
    $refreshTimer.Start()
    try {
        $targets = Get-LatencyTargets -Network (Get-NetworkInfo -NoCache) -Portal $script:Snapshot.Portal
        if (@($targets).Count -gt 0) { Start-LatencyProbe -Targets $targets -TimeoutMs ([int][double]$script:Settings.PingTimeoutMs) }
    } catch { }
    $pingTimer.Start()
})

$window.Add_Closing({
    try { $refreshTimer.Stop() } catch { }
    try { $disableTimer.Stop() } catch { }
    try { $pingTimer.Stop() } catch { }
})

# ---- 显示窗口 ----
if ($SelfTest) {
    try {
        $window.Show()
        Invoke-MonitorRender
        # 顺带跑一次真实的延迟探测，确保这条链路在冒烟测试里也被覆盖
        try {
            $targets = Get-LatencyTargets -Network (Get-NetworkInfo -NoCache) -Portal $script:Snapshot.Portal
            Invoke-LatencyProbeSync -Targets $targets -TimeoutMs ([int][double]$script:Settings.PingTimeoutMs)
            Update-TrendBuffer -Summary (Get-LatencySummary)
        } catch { }
        Update-MonitorUi
        Invoke-MonitorRender
        $window.Close()
        Write-Host ('[SelfTest] 监控面板（WPF）构建与刷新成功。')
        if (-not [string]::IsNullOrWhiteSpace($script:UiError)) {
            Write-Host ('[SelfTest] 注意：刷新时报错 {0}' -f $script:UiError)
            exit 2
        }
        Write-Host ('[SelfTest] 数据目录：{0}' -f $DataDir)
        Write-Host ('[SelfTest] 状态：{0}' -f $script:Snapshot.Banner.Text)
        Write-Host ('[SelfTest] 指标卡片：{0} 个｜时间线：{1} 格｜日志：{2} 行｜折线图元：{3} 个' -f $script:Ui['CardHost'].Children.Count, $script:Timeline.Count, $script:Ui['LogHost'].Items.Count, $script:Ui['SparkCanvas'].Children.Count)
        exit 0
    } catch {
        Write-Host ('[SelfTest] 失败：{0}' -f $_.Exception.Message)
        exit 1
    }
}

[void]$window.ShowDialog()
$window.Close()
exit 0

