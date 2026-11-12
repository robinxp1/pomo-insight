$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tests = @(
    @{ file = 'ParseScripts.ps1'; sta = $false },
    @{ file = 'CoreSmoke.ps1'; sta = $false },
    @{ file = 'ParseUi.ps1'; sta = $true },
    @{ file = 'UiSmoke.ps1'; sta = $false }
)
foreach ($test in $tests) {
    Write-Output ('=== ' + $test.file + ' ===')
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($test.sta) { $args += '-STA' }
    $args += @('-File', ('"' + (Join-Path $PSScriptRoot $test.file) + '"'))
    & $powershell @args
    if ($LASTEXITCODE -ne 0) { throw ('Test failed: ' + $test.file) }
}
Write-Output 'ALL_TESTS_OK'