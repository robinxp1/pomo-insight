$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root 'tests\smokedata'
if (Test-Path -LiteralPath $data) {
    $resolved = (Resolve-Path -LiteralPath $data).Path
    if ($resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
New-Item -ItemType Directory -Path $data -Force | Out-Null
$script = Join-Path $root 'PomoInsight.ps1'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$env:POMO_INSIGHT_MUTEX_NAME = 'Local\PomoInsight.SingleInstance.UiSmoke'
$args = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $script + '"'), '-DataDir', ('"' + $data + '"'), '-UiSmokeTest')
$p = Start-Process -FilePath $ps -ArgumentList $args -PassThru
$done = $p.WaitForExit(30000)
if (-not $done) {
    Stop-Process -Id $p.Id -Force
    Write-Output 'UI_SMOKE_TIMEOUT'
    exit 1
}
Write-Output ('UI_EXIT code=' + $p.ExitCode)
if (Test-Path -LiteralPath (Join-Path $data 'uismoke.ok')) {
    Write-Output ('OK ' + [System.IO.File]::ReadAllText((Join-Path $data 'uismoke.ok')))
} else {
    Write-Output 'NO_OK_MARKER'
}
if (Test-Path -LiteralPath (Join-Path $data 'uismoke.fail.txt')) {
    Write-Output ([System.IO.File]::ReadAllText((Join-Path $data 'uismoke.fail.txt')))
}
if (Test-Path -LiteralPath (Join-Path $data 'pomoinsight.log')) {
    Write-Output '--- LOG ---'
    Write-Output ([System.IO.File]::ReadAllText((Join-Path $data 'pomoinsight.log')))
}
if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $data 'uismoke.ok'))) { exit 1 }