param([string]$DataRoot = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$project = Join-Path $PSScriptRoot 'RecoveryTests\RecoveryTests.csproj'
& dotnet build $project -c Release --nologo
if ($LASTEXITCODE -ne 0) { throw '恢复测试编译失败' }
$previous = $env:CAMPUS_TEST_ROOT
try {
    if ($DataRoot) { $env:CAMPUS_TEST_ROOT = $DataRoot }
    & (Join-Path $PSScriptRoot 'RecoveryTests\bin\Release\net48\RecoveryTests.exe')
    if ($LASTEXITCODE -ne 0) { throw '恢复行为测试失败' }
} finally {
    $env:CAMPUS_TEST_ROOT = $previous
}
