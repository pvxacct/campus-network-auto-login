<#
  算出「源码指纹」：把参与编译的源码文件按相对路径排序，逐个取 SHA256 再整体取一次 SHA256。

  参与文件：src\CampusNet\CampusNet.csproj、src 下全部 .cs、build\Build-CampusNet.ps1。
  用途：build-verify / create-release 判断「仓库里提交的 dist\CampusNet.exe 是不是这份源码构建的」。
  只比二进制会因为编译器版本差异误报（实测同样源码差 100 字节），比指纹才稳定。

  用法： powershell -ExecutionPolicy Bypass -File build\Get-SourceFingerprint.ps1 [-Repo <仓库根>]
  输出： 一行 64 位小写十六进制
#>
param(
    [string]$Repo = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
$root = (Get-Item -LiteralPath $Repo).FullName.TrimEnd('\')

$files = New-Object System.Collections.Generic.List[string]
$files.Add((Join-Path $root 'src\CampusNet\CampusNet.csproj'))
$files.Add((Join-Path $root 'build\Build-CampusNet.ps1'))
foreach ($item in (Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Filter '*.cs' | Sort-Object FullName)) {
    $files.Add($item.FullName)
}

$builder = New-Object System.Text.StringBuilder
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file)) { throw "缺少参与指纹计算的文件：$file" }
    $relative = $file.Substring($root.Length).TrimStart('\').Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$builder.Append($relative).Append(':').Append($hash).Append("`n")
}

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
    $digest = $sha.ComputeHash($bytes)
} finally {
    $sha.Dispose()
}
Write-Output (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
