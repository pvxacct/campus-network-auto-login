<#
  一键编译 2.0 单文件 exe。
  产物：dist\CampusNet.exe（仓库内提交的可执行文件）+ dist\CampusNet.exe.sha256
        + dist\CampusNet.exe.src.sha256（源码指纹，供 CI 判断产物是否与源码对应）

  需要 .NET SDK（本机已带 9.0.304，GitHub Actions 的 windows-latest 也自带）。
  用法： powershell -ExecutionPolicy Bypass -File build\Build-CampusNet.ps1 [-SkipTests]
#>
param(
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repo 'src\CampusNet\CampusNet.csproj'
$distDir = Join-Path $repo 'dist'
$exe = Join-Path $distDir 'CampusNet.exe'

Write-Host '== 编译 ==' -ForegroundColor Cyan
& dotnet build $project -c Release --nologo
if ($LASTEXITCODE -ne 0) { throw '编译失败。' }

$built = Join-Path $repo 'src\CampusNet\bin\Release\net48\CampusNet.exe'
if (-not (Test-Path -LiteralPath $built)) { throw "找不到编译产物：$built" }
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
Copy-Item -LiteralPath $built -Destination $exe -Force

$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$exe.sha256", "$hash  CampusNet.exe`r`n", (New-Object System.Text.UTF8Encoding($false)))

# 源码指纹：CI 用它判断「改了源码有没有忘记重新生成 dist 产物」。
# 只比二进制会因为编译器版本差异误报（同样源码不同 SDK 能差几十字节），比指纹才稳定。
$fingerprint = (& (Join-Path $PSScriptRoot 'Get-SourceFingerprint.ps1') -Repo $repo | Out-String).Trim()
if ($fingerprint -notmatch '^[0-9a-f]{64}$') { throw "源码指纹计算失败：$fingerprint" }
[System.IO.File]::WriteAllText("$exe.src.sha256", "$fingerprint  sources`r`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ('产物：{0}（{1:N0} 字节）' -f $exe, (Get-Item -LiteralPath $exe).Length)
Write-Host ('SHA256：{0}' -f $hash)
Write-Host ('源码指纹：{0}' -f $fingerprint)

Write-Host ''
Write-Host '== 版本自检 ==' -ForegroundColor Cyan
$version = (& $exe --version | Out-String).Trim()
if ($version -ne '2.0.0-pre.9') { throw "版本号不符合预期：$version" }
Write-Host "版本：$version"

if (-not $SkipTests) {
    Write-Host ''
    Write-Host '== 端到端测试 ==' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'build\Test-CampusNet.ps1') -Exe $exe
    if ($LASTEXITCODE -ne 0) { throw '端到端测试未通过。' }
}

Write-Host ''
Write-Host '完成。' -ForegroundColor Green
