#Requires -Version 5.1
<#
.SYNOPSIS
    校园网自动登录 - 只读监控面板（Windows 桌面窗口）。

.DESCRIPTION
    配合 campus-network-auto-login 使用，但完全独立运行：
      * 只读取 state.json、login.log 与计划任务状态；
      * 不创建、不修改任何文件；
      * 除了手动点击“立即检查一次”，不发出任何网络请求。

.PARAMETER DataDir
    数据目录，默认 %LOCALAPPDATA%\CampusAutoLogin。

.PARAMETER ConfigPath
    面板配置，默认脚本同目录的 monitor-config.json。

.PARAMETER DumpOnce
    不打开窗口，把当前状态打印到控制台后退出（供自动化测试使用）。

.PARAMETER SelfTest
    构建窗口、刷新一次后立即退出（GUI 冒烟测试）。

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

$script:MonitorVersion = '1.1.0'
$script:ExpectedAssistVersion = '1.7.0'
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

# WinForms 需要 STA 线程：PowerShell 7 默认是 MTA，这时用 Windows PowerShell 5.1 重新拉起自己
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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:LastCheckText = '还没有手动检查过。'
$script:UiError = ''

# ---- 窗口 ----
$form = New-Object System.Windows.Forms.Form
$form.Text = ('校园网监控面板 {0}（适配自动登录 {1}）' -f $script:MonitorVersion, $script:ExpectedAssistVersion)
$form.ClientSize = New-Object System.Drawing.Size(1060, 780)
$form.MinimumSize = New-Object System.Drawing.Size(880, 640)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = [System.Drawing.Color]::White

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = [System.Windows.Forms.DockStyle]::Fill
$root.ColumnCount = 1
$root.RowCount = 3
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$form.Controls.Add($root)

# ---- 顶部状态横幅 ----
$banner = New-Object System.Windows.Forms.Label
$banner.Dock = [System.Windows.Forms.DockStyle]::Fill
$banner.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$banner.Padding = New-Object System.Windows.Forms.Padding(14, 0, 14, 0)
$banner.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$banner.Text = '正在读取状态…'
$banner.BackColor = [System.Drawing.Color]::WhiteSmoke
[void]$root.Controls.Add($banner, 0, 0)

# ---- 按钮区 ----
$buttonBar = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonBar.Dock = [System.Windows.Forms.DockStyle]::Fill
$buttonBar.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 6)
$buttonBar.WrapContents = $false
[void]$root.Controls.Add($buttonBar, 0, 1)

function New-MonitorButton {
    param([string]$Text, [int]$Width = 132)

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = 30
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    return $button
}

$btnCheck = New-MonitorButton '立即检查一次' 132
$btnRefresh = New-MonitorButton '刷新' 90
$btnOpenDir = New-MonitorButton '打开数据目录' 132
$btnCopy = New-MonitorButton '复制诊断信息' 132
$btnClose = New-MonitorButton '关闭' 90
[void]$buttonBar.Controls.Add($btnCheck)
[void]$buttonBar.Controls.Add($btnRefresh)
[void]$buttonBar.Controls.Add($btnOpenDir)
[void]$buttonBar.Controls.Add($btnCopy)
[void]$buttonBar.Controls.Add($btnClose)

# ---- 内容区：上半指标，下半日志 ----
$content = New-Object System.Windows.Forms.SplitContainer
$content.Dock = [System.Windows.Forms.DockStyle]::Fill
$content.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$content.Panel1MinSize = 160
$content.Panel2MinSize = 150
try { $content.SplitterDistance = 400 } catch { }
[void]$root.Controls.Add($content, 0, 2)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = [System.Windows.Forms.DockStyle]::Fill
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.AllowUserToOrderColumns = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false
$grid.MultiSelect = $false
$grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
$grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.GridColor = [System.Drawing.Color]::Gainsboro
$grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
$grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::WhiteSmoke
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::WhiteSmoke
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::Black
$grid.RowTemplate.Height = 26
$colGroup = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colGroup.HeaderText = '分类'
$colGroup.Width = 64
$colGroup.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
$colLabel = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colLabel.HeaderText = '项目'
$colLabel.Width = 190
$colLabel.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
$colValue = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colValue.HeaderText = '值'
$colValue.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
$colValue.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
[void]$grid.Columns.Add($colGroup)
[void]$grid.Columns.Add($colLabel)
[void]$grid.Columns.Add($colValue)
$content.Panel1.Controls.Add($grid)

# ---- 日志区 ----
$logPanel = New-Object System.Windows.Forms.TableLayoutPanel
$logPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$logPanel.ColumnCount = 1
$logPanel.RowCount = 2
[void]$logPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
[void]$logPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$content.Panel2.Controls.Add($logPanel)

$logBar = New-Object System.Windows.Forms.FlowLayoutPanel
$logBar.Dock = [System.Windows.Forms.DockStyle]::Fill
$logBar.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 0)
$logBar.WrapContents = $false
[void]$logPanel.Controls.Add($logBar, 0, 0)

$chkProblems = New-Object System.Windows.Forms.CheckBox
$chkProblems.Text = '只看警告和错误'
$chkProblems.AutoSize = $true
$chkProblems.Margin = New-Object System.Windows.Forms.Padding(0, 3, 16, 0)
[void]$logBar.Controls.Add($chkProblems)

$logHint = New-Object System.Windows.Forms.Label
$logHint.Text = '只读显示 login.log 的末尾内容，最近 200 行。'
$logHint.AutoSize = $true
$logHint.ForeColor = [System.Drawing.Color]::Gray
$logHint.Margin = New-Object System.Windows.Forms.Padding(0, 7, 0, 0)
[void]$logBar.Controls.Add($logHint)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$logBox.ReadOnly = $true
$logBox.WordWrap = $false
$logBox.DetectUrls = $false
$logBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.BackColor = [System.Drawing.Color]::White
$logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
[void]$logPanel.Controls.Add($logBox, 0, 1)

$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 15000

# ---- 刷新逻辑 ----
function Get-BannerTint {
    param([string]$Kind)

    switch ($Kind) {
        'red'    { return [System.Drawing.Color]::FromArgb(253, 236, 236) }
        'orange' { return [System.Drawing.Color]::FromArgb(255, 244, 229) }
        'green'  { return [System.Drawing.Color]::FromArgb(234, 247, 239) }
        'yellow' { return [System.Drawing.Color]::FromArgb(255, 251, 230) }
        default  { return [System.Drawing.Color]::FromArgb(242, 242, 242) }
    }
}

function Update-MonitorGrid {
    param($Snapshot)

    $grid.SuspendLayout()
    try {
        $grid.Rows.Clear()
        foreach ($row in (Get-MonitorMetricRows -Snapshot $Snapshot)) {
            $index = $grid.Rows.Add($row.Group, $row.Label, $row.Value)
            $cell = $grid.Rows[$index].Cells[2]
            $cell.Style.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
            if (-not [string]::IsNullOrWhiteSpace([string]$row.Color)) {
                $color = [System.Drawing.ColorTranslator]::FromHtml([string]$row.Color)
                $cell.Style.ForeColor = $color
                $cell.Style.SelectionForeColor = $color
            }
        }
    } finally { $grid.ResumeLayout() }
}

function Update-MonitorLog {
    param($Snapshot)

    $entries = Get-MonitorLogTail -Entries $Snapshot.LogEntries -Count 200 -OnlyProblems:([bool]$chkProblems.Checked)
    $logBox.SuspendLayout()
    try {
        $logBox.Clear()
        if (@($entries).Count -eq 0) {
            $logBox.SelectionColor = [System.Drawing.Color]::Gray
            $logBox.AppendText('（没有日志内容）')
        } else {
            foreach ($entry in @($entries)) {
                $color = [System.Drawing.Color]::FromArgb(60, 60, 60)
                if ($entry.Level -eq 'WARN') { $color = [System.Drawing.Color]::FromArgb(176, 104, 0) }
                elseif ($entry.Level -eq 'ERROR') { $color = [System.Drawing.Color]::FromArgb(192, 0, 0) }
                $logBox.SelectionStart = $logBox.TextLength
                $logBox.SelectionLength = 0
                $logBox.SelectionColor = $color
                $logBox.AppendText([string]$entry.Raw + "`r`n")
            }
        }
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.SelectionLength = 0
        $logBox.ScrollToCaret()
    } finally { $logBox.ResumeLayout() }
}

function Update-MonitorUi {
    try {
        $script:Snapshot = Get-MonitorSnapshot -DataDir $DataDir
        $snapshot = $script:Snapshot

        $banner.Text = $snapshot.Banner.Text
        $banner.ForeColor = [System.Drawing.ColorTranslator]::FromHtml([string]$snapshot.Banner.Color)
        $banner.BackColor = Get-BannerTint $snapshot.Banner.Kind

        Update-MonitorGrid -Snapshot $snapshot
        Update-MonitorLog -Snapshot $snapshot

        if ($snapshot.Portal.Available) {
            $btnCheck.Enabled = $true
            $tip.SetToolTip($btnCheck, ('向 {0} 发一次只读的状态查询（chkstatus），不会登录、不会写任何文件。' -f $snapshot.Portal.Host))
        } else {
            $btnCheck.Enabled = $false
            $tip.SetToolTip($btnCheck, ('没有可用的 Portal 地址，无法查询：{0}' -f $snapshot.Portal.Reason))
        }
        $script:UiError = ''
    } catch {
        $script:UiError = $_.Exception.Message
        $banner.ForeColor = [System.Drawing.Color]::FromArgb(192, 0, 0)
        $banner.BackColor = [System.Drawing.Color]::FromArgb(253, 236, 236)
        $banner.Text = ('刷新状态失败：{0}' -f $_.Exception.Message)
    }
}

# ---- 按钮与定时器 ----
$btnCheck.Add_Click({
    $snapshot = $script:Snapshot
    if (-not $snapshot.Portal.Available) {
        [void][System.Windows.Forms.MessageBox]::Show('没有可用的 Portal 地址，无法查询。', '立即检查一次', 'OK', 'Warning')
        return
    }

    $btnCheck.Enabled = $false
    $btnCheck.Text = '检查中…'
    $buttonBar.Refresh()

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
    [void][System.Windows.Forms.MessageBox]::Show($script:LastCheckText, '立即检查一次', 'OK', 'Information')

    # 按钮禁用 5 秒，避免手快连点、对 Portal 造成无谓的压力
    $disableTimer.Interval = 5000
    $disableTimer.Start()
})

$btnRefresh.Add_Click({ Update-MonitorUi })

$btnOpenDir.Add_Click({
    try {
        if (Test-PathSafe $DataDir) {
            Start-Process -FilePath $DataDir | Out-Null
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(('目录不存在：{0}' -f $DataDir), '打开数据目录', 'OK', 'Warning')
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(('打开失败：{0}' -f $_.Exception.Message), '打开数据目录', 'OK', 'Warning')
    }
})

$btnCopy.Add_Click({
    try {
        $text = Format-MonitorText -Snapshot $script:Snapshot -LogLines 30
        if (-not [string]::IsNullOrWhiteSpace($script:LastCheckText)) {
            $text = $text + "`r`n" + ('【手动检查】{0}' -f $script:LastCheckText)
        }
        [System.Windows.Forms.Clipboard]::SetText($text)
        [void][System.Windows.Forms.MessageBox]::Show('诊断信息已复制到剪贴板，可以直接粘贴给别人。', '复制诊断信息', 'OK', 'Information')
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(('复制失败：{0}' -f $_.Exception.Message), '复制诊断信息', 'OK', 'Warning')
    }
})

$btnClose.Add_Click({ $form.Close() })

$chkProblems.Add_CheckedChanged({ Update-MonitorLog -Snapshot $script:Snapshot })

$disableTimer = New-Object System.Windows.Forms.Timer
$disableTimer.Interval = 5000
$disableTimer.Add_Tick({
    $disableTimer.Stop()
    $btnCheck.Text = '立即检查一次'
    $btnCheck.Enabled = $true
})

$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshSeconds = [double]$script:Settings.RefreshSeconds
if ($refreshSeconds -lt 1) { $refreshSeconds = 5 }
$refreshTimer.Interval = [int]($refreshSeconds * 1000)
$refreshTimer.Add_Tick({ Update-MonitorUi })

# 延迟探测单独一个更慢的节奏：只发 ICMP，不碰 Portal 的登录接口
$pingTimer = New-Object System.Windows.Forms.Timer
$pingSeconds = [double]$script:Settings.PingIntervalSeconds
if ($pingSeconds -lt 3) { $pingSeconds = 10 }
$pingTimer.Interval = [int]($pingSeconds * 1000)
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
})

$form.Add_Shown({
    try { $content.SplitterDistance = [int]($content.Height * 0.55) } catch { }
    Update-MonitorUi
    $refreshTimer.Start()
    try {
        $targets = Get-LatencyTargets -Network (Get-NetworkInfo -NoCache) -Portal $script:Snapshot.Portal
        if (@($targets).Count -gt 0) { Start-LatencyProbe -Targets $targets -TimeoutMs ([int][double]$script:Settings.PingTimeoutMs) }
    } catch { }
    $pingTimer.Start()
})

$form.Add_FormClosing({
    try { $refreshTimer.Stop() } catch { }
    try { $disableTimer.Stop() } catch { }
    try { $pingTimer.Stop() } catch { }
})

# ---- 显示窗口 ----
if ($SelfTest) {
    try {
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        # 顺带跑一次真实的延迟探测，确保这条链路在冒烟测试里也被覆盖
        try {
            $targets = Get-LatencyTargets -Network (Get-NetworkInfo -NoCache) -Portal $script:Snapshot.Portal
            Invoke-LatencyProbeSync -Targets $targets -TimeoutMs ([int][double]$script:Settings.PingTimeoutMs)
        } catch { }
        Update-MonitorUi
        [System.Windows.Forms.Application]::DoEvents()
        $form.Close()
        $form.Dispose()
        Write-Host ('[SelfTest] 监控面板构建与刷新成功。')
        if (-not [string]::IsNullOrWhiteSpace($script:UiError)) {
            Write-Host ('[SelfTest] 注意：刷新时报错 {0}' -f $script:UiError)
            exit 2
        }
        Write-Host ('[SelfTest] 数据目录：{0}' -f $DataDir)
        Write-Host ('[SelfTest] 状态：{0}' -f $script:Snapshot.Banner.Text)
        exit 0
    } catch {
        Write-Host ('[SelfTest] 失败：{0}' -f $_.Exception.Message)
        exit 1
    }
}

[void]$form.ShowDialog()
$form.Dispose()
exit 0
