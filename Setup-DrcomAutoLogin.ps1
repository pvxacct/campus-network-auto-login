#Requires -Version 5.1
<#
.SYNOPSIS
    Dr.COM 校园网自动登录一键安装（自动申请管理员权限）。

.DESCRIPTION
    依次完成：
      1. 自动以管理员身份重新启动自己（会弹出一次 UAC 确认窗口）；
      2. 提示输入一次校园网账号密码，用 Windows DPAPI 加密保存；
      3. 注册计划任务（默认每 30 秒检查一次，后台静默运行、开机自启）；
      4. 实际观察一段时间，确认任务真的会自己跑起来；
      5. 立即检查一次当前在线状态。

.PARAMETER UserName
    校园网账号。不指定时会提示输入。

.PARAMETER Reconfigure
    已经保存过凭据时，强制重新输入并覆盖。

.PARAMETER IntervalSeconds
    检查间隔（秒）。不指定时读取 drcom-config.json 的 CheckIntervalSeconds，缺省 30 秒。

.PARAMETER VerifySeconds
    安装后的自检观察时长（秒），默认 80；设为 0 跳过自检。

.PARAMETER NoElevate
    不自动申请管理员权限（脚本内部递归调用时使用）。

.EXAMPLE
    右键 Install.cmd 以管理员身份运行；或在 PowerShell 中执行：
    powershell -ExecutionPolicy Bypass -File .\Setup-DrcomAutoLogin.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Setup-DrcomAutoLogin.ps1 -UserName 2025000000
#>
[CmdletBinding()]
param(
    [string]$UserName = '',
    [string]$TaskName = 'CampusAutoLogin',
    [int]$IntervalSeconds = 0,
    [int]$VerifySeconds = 80,
    [switch]$Reconfigure,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) {
    $root = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrEmpty($root)) { $root = (Get-Location).Path }

$saveScript = Join-Path $root 'Save-DrcomCredential.ps1'
$mainScript = Join-Path $root 'DrcomAutoLogin.ps1'
$taskScript = Join-Path $root 'Install-CampusAutoLoginTask.ps1'

foreach ($file in @($saveScript, $mainScript, $taskScript)) {
    if (-not (Test-Path -LiteralPath $file)) { throw "缺少文件：$file" }
}

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $dataDir = $root
} else {
    $dataDir = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
}
$credentialPath = Join-Path $dataDir 'credential.xml'

# ===================== 自动提权 =====================
function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    if ($NoElevate) { throw '安装需要管理员权限，请右键以管理员身份运行。' }

    Write-Host ''
    Write-Host '安装需要管理员权限，正在弹出 UAC 授权窗口，请点击“是”。' -ForegroundColor Yellow
    $elevateExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $elevateExe)) { $elevateExe = 'powershell.exe' }

    $myPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrEmpty($myPath)) { $myPath = Join-Path $root 'Setup-DrcomAutoLogin.ps1' }

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-NoExit',
        '-File', ('"{0}"' -f $myPath),
        '-TaskName', ('"{0}"' -f $TaskName),
        '-IntervalSeconds', $IntervalSeconds,
        '-VerifySeconds', $VerifySeconds
    )
    if (-not [string]::IsNullOrWhiteSpace($UserName)) { $argList += @('-UserName', ('"{0}"' -f $UserName)) }
    if ($Reconfigure) { $argList += '-Reconfigure' }

    Start-Process -FilePath $elevateExe -ArgumentList $argList -Verb RunAs
    exit 0
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  校园网自动登录一键安装（Dr.COM）' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# 间隔先看命令行参数，再看配置文件，最后用 30 秒兜底（实际生效值由安装脚本打印）
$intervalDisplay = $IntervalSeconds
if ($intervalDisplay -le 0) {
    $intervalDisplay = 30
    $configFile = Join-Path $root 'drcom-config.json'
    if (Test-Path -LiteralPath $configFile) {
        try {
            $configJson = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($configJson.CheckIntervalSeconds) {
                $intervalDisplay = [int]$configJson.CheckIntervalSeconds
            } elseif ($configJson.CheckIntervalMinutes) {
                $intervalDisplay = [int]$configJson.CheckIntervalMinutes * 60
            }
        } catch {
            Write-Warning "读取 drcom-config.json 失败，使用默认间隔 30 秒：$($_.Exception.Message)"
        }
    }
}

Write-Host ("  检查间隔：每 {0} 秒" -f $intervalDisplay)
Write-Host ("  数据目录：{0}" -f $dataDir)
Write-Host ''

# ===================== 第 1 步：保存账号密码 =====================
Write-Host '第 1 步：保存校园网账号密码（DPAPI 加密，不写明文）' -ForegroundColor Cyan
Write-Host ''

if ((Test-Path -LiteralPath $credentialPath) -and -not $Reconfigure) {
    Write-Host ("已经存在凭据文件：{0}" -f $credentialPath)
    Write-Host '如需重新输入，请加 -Reconfigure 参数再运行一次。' -ForegroundColor Yellow
} else {
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        & $saveScript -DataDir $dataDir
    } else {
        & $saveScript -DataDir $dataDir -UserName $UserName
    }
    if (-not (Test-Path -LiteralPath $credentialPath)) {
        throw '凭据没有保存成功，安装中止。'
    }
}

# ===================== 第 2 步：注册计划任务 =====================
Write-Host ''
Write-Host '第 2 步：注册计划任务（每 30 秒检查一次、后台静默、开机自启）' -ForegroundColor Cyan

& $taskScript -ScriptPath $mainScript -TaskName $TaskName -IntervalSeconds $IntervalSeconds -VerifySeconds $VerifySeconds -NoElevate

# ===================== 第 3 步：立即检查一次 =====================
Write-Host ''
Write-Host '第 3 步：立即检查一次当前在线状态' -ForegroundColor Cyan
Write-Host ''

& $mainScript

Write-Host ''
Write-Host '安装完成。' -ForegroundColor Green
Write-Host '  - 登录 Windows 后会自动启动；'
Write-Host '  - 每 30 秒检查一次，掉线后自动重新登录；'
Write-Host '  - 切换 Wi-Fi / 插拔网线时也会触发检查；'
Write-Host ("  - 日志：{0}\login.log" -f $dataDir)
Write-Host ("  - 状态：{0}\state.json" -f $dataDir)
Write-Host ''
Write-Host '想强制验证一次完整登录（会先注销再登录），可执行：' -ForegroundColor Yellow
Write-Host '  powershell -ExecutionPolicy Bypass -File .\DrcomAutoLogin.ps1 -Relogin'
Write-Host ''

