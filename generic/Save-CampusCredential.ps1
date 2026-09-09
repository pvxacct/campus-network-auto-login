#Requires -Version 5.1
<#
.SYNOPSIS
    加密保存校园网账号密码。

.DESCRIPTION
    使用 Windows DPAPI 加密（Export-Clixml），只有当前 Windows 用户能解密。
    密码不会以明文写入磁盘。
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $env:LOCALAPPDATA 'CampusAutoLogin\credential.xml')
)

$ErrorActionPreference = 'Stop'

$dir = Split-Path -Path $Path -Parent
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$cred = Get-Credential -Message '请输入校园网账号和密码（用户名直接填账号即可）'
if ($null -eq $cred) {
    Write-Error '未输入凭据，已取消。'
    exit 1
}

if ($cred.Password.Length -eq 0) {
    Write-Error '密码不能为空，已取消。'
    exit 1
}

$cred | Export-Clixml -LiteralPath $Path -Force

Write-Host ''
Write-Host "凭据已加密保存到：" -ForegroundColor Green
Write-Host "  $Path"
Write-Host ''
Write-Host '注意：该文件与当前 Windows 用户绑定，换用户或换电脑需要重新保存。' -ForegroundColor Yellow
