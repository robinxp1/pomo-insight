$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\PomoInsight.Core.ps1')

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('PomoInsightTest-' + [guid]::NewGuid().ToString('N'))
Initialize-PomoInsightStorage -Root $testRoot
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Equal($actual, $expected, $label) {
    if ($actual -ne $expected) {
        $failures.Add(('FAIL {0}: expected [{1}], got [{2}]' -f $label, $expected, $actual))
    } else {
        Write-Output ('PASS ' + $label)
    }
}

$t0 = [DateTimeOffset]::Now.AddHours(-2)
$session = New-PomoInsightSession -Task '开发测试' -StartedAt $t0
$breakStart = $t0.AddMinutes(50)
$breakEnd = $t0.AddMinutes(60)
$break = [pscustomobject]@{
    startedAt = $breakStart.ToString('o')
    startedAtUnixMs = (Get-EpochMs -Value $breakStart)
    endedAt = $breakEnd.ToString('o')
    endedAtUnixMs = (Get-EpochMs -Value $breakEnd)
    durationSeconds = 600
    plannedMinutes = 10
    completed = $true
    source = 'test'
}
$session.breaks = @($break)
$session.breakCount = 1
$session = Complete-PomoInsightSession -Session $session -EndedAt $t0.AddMinutes(65) -Reason 'manual'
Save-PomoInsightSessions -Root $testRoot -Sessions @($session)

Assert-Equal $session.wallSeconds 3900 'wall seconds'
Assert-Equal $session.breakSeconds 600 'break seconds'
Assert-Equal $session.workSeconds 3300 'work seconds'
Assert-Equal $session.longestFocusSeconds 3000 'longest focus seconds'
Assert-Equal $session.durationMinutes 55 'duration minutes'

$summary = Get-PomoInsightSummary -Sessions (Get-PomoInsightSessions -Root $testRoot)
Assert-Equal $summary.totalSessions 1 'summary sessions'
Assert-Equal $summary.totalWorkMinutes 55 'summary work minutes'
Assert-Equal $summary.breakComplianceRate 100 'break compliance'

$jsonPath = Export-PomoInsightData -Root $testRoot -OutputDir (Join-Path $testRoot 'out') -Format json
$json = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
Assert-Equal @($json.sessions).Count 1 'json sessions'
Assert-Equal $json.sessions[0].workSeconds 3300 'json work seconds'
Assert-Equal $json.reminderModel.focusMinutes 50 'json reminder model'

$csvPath = Export-PomoInsightData -Root $testRoot -OutputDir (Join-Path $testRoot 'out') -Format csv
$csv = [System.IO.File]::ReadAllText($csvPath, [System.Text.Encoding]::UTF8)
if ($csv -match '开发测试' -and $csv -match 'workMinutes') { Write-Output 'PASS csv content' } else { $failures.Add('FAIL csv content') }

$briefPath = Export-PomoInsightAnalysisBrief -Root $testRoot -Directory (Join-Path $testRoot 'out')
if (Test-Path -LiteralPath $briefPath) { Write-Output 'PASS ai brief' } else { $failures.Add('FAIL ai brief') }

$customJson = Join-Path $testRoot 'chosen\custom.json'
$customJsonPath = Export-PomoInsightData -Root $testRoot -Format json -OutputPath $customJson
Assert-Equal $customJsonPath ([System.IO.Path]::GetFullPath($customJson)) 'explicit json path'
if (Test-Path -LiteralPath $customJson) { Write-Output 'PASS explicit json file' } else { $failures.Add('FAIL explicit json file') }

$customCsv = Join-Path $testRoot 'chosen\custom.csv'
$customCsvPath = Export-PomoInsightData -Root $testRoot -Format csv -OutputPath $customCsv
Assert-Equal $customCsvPath ([System.IO.Path]::GetFullPath($customCsv)) 'explicit csv path'
if (Test-Path -LiteralPath $customCsv) { Write-Output 'PASS explicit csv file' } else { $failures.Add('FAIL explicit csv file') }

$customBrief = Join-Path $testRoot 'chosen\custom.md'
$customBriefPath = Export-PomoInsightAnalysisBrief -Root $testRoot -OutputPath $customBrief
Assert-Equal $customBriefPath ([System.IO.Path]::GetFullPath($customBrief)) 'explicit brief path'
if (Test-Path -LiteralPath $customBrief) { Write-Output 'PASS explicit brief file' } else { $failures.Add('FAIL explicit brief file') }

$recent = @(Get-RecentTasks -Sessions (Get-PomoInsightSessions -Root $testRoot) -Limit 5)
Assert-Equal $recent[0] '开发测试' 'recent task'

$recoveryRoot = Join-Path $testRoot 'recovery'
Initialize-PomoInsightStorage -Root $recoveryRoot
$active = New-PomoInsightSession -Task '恢复测试' -StartedAt $t0
$active.lastHeartbeatAt = $t0.AddMinutes(25).ToString('o')
$active.lastHeartbeatAtUnixMs = (Get-EpochMs -Value $t0.AddMinutes(25))
Save-ActiveSession -Root $recoveryRoot -Session $active
$loaded = Get-ActiveSession -Root $recoveryRoot
$recovered = Recover-InterruptedSession -Root $recoveryRoot -Active $loaded
Assert-Equal $recovered.workSeconds 1500 'recovered work seconds'
Assert-Equal @(Get-PomoInsightSessions -Root $recoveryRoot).Count 1 'recovered session saved'
Assert-Equal (Get-ActiveSession -Root $recoveryRoot) $null 'active file removed'

$gapRoot = Join-Path $testRoot 'gap'
Initialize-PomoInsightStorage -Root $gapRoot
$gapStart = [DateTimeOffset]::Now.AddHours(-1)
$gapSession = New-PomoInsightSession -Task '休眠测试' -StartedAt $gapStart
$gapFrom = $gapStart.AddMinutes(5)
$gapTo = $gapStart.AddMinutes(15)
$gapSession.timerGaps = @([pscustomobject]@{
    startedAt = $gapFrom.ToString('o')
    startedAtUnixMs = (Get-EpochMs -Value $gapFrom)
    endedAt = $gapTo.ToString('o')
    endedAtUnixMs = (Get-EpochMs -Value $gapTo)
    durationSeconds = 600
    reason = 'timer_gap'
})
$gapSession.timerGapSeconds = 600
$gapSession.timerGapCount = 1
$gapSession = Complete-PomoInsightSession -Session $gapSession -EndedAt $gapStart.AddMinutes(30) -Reason 'manual'
Save-PomoInsightSessions -Root $gapRoot -Sessions @($gapSession)
Assert-Equal $gapSession.wallSeconds 1800 'gap wall seconds'
Assert-Equal $gapSession.timerGapSeconds 600 'gap seconds'
Assert-Equal $gapSession.workSeconds 1200 'gap deducted from work'
Assert-Equal $gapSession.longestFocusSeconds 900 'gap excluded from longest focus'
$gapJsonPath = Export-PomoInsightData -Root $gapRoot -OutputDir (Join-Path $gapRoot 'out') -Format json
$gapJson = [System.IO.File]::ReadAllText($gapJsonPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
Assert-Equal $gapJson.sessions[0].timerGapSeconds 600 'json timer gap seconds'
Assert-Equal $gapJson.sessions[0].timerGapCount 1 'json timer gap count'
Assert-Equal @($gapJson.sessions[0].timerGaps).Count 1 'json timer gap interval'
$gapCsvPath = Export-PomoInsightData -Root $gapRoot -OutputDir (Join-Path $gapRoot 'out') -Format csv
$gapCsv = [System.IO.File]::ReadAllText($gapCsvPath, [System.Text.Encoding]::UTF8)
if ($gapCsv -match 'timerGapMinutes') { Write-Output 'PASS csv timer gap column' } else { $failures.Add('FAIL csv timer gap column') }
$legacy = [pscustomobject]@{ startedAt = $gapStart.ToString('o'); startedAtUnixMs = (Get-EpochMs -Value $gapStart) }
Assert-Equal (Get-SessionGapSeconds -Session $legacy) 0 'legacy session gap fallback'

$settings = Get-PomoInsightSettings -Root $testRoot
$settings.focusMinutes = 60
$settings.breakMinutes = 12
Save-PomoInsightSettings -Root $testRoot -Settings $settings
$reloaded = Get-PomoInsightSettings -Root $testRoot
Assert-Equal $reloaded.focusMinutes 60 'settings focus'
Assert-Equal $reloaded.breakMinutes 12 'settings break'

$oldDataDir = $env:POMO_INSIGHT_DATA_DIR
$oldConfigDir = $env:POMO_INSIGHT_CONFIG_DIR
try {
    $env:POMO_INSIGHT_DATA_DIR = $null
    $env:POMO_INSIGHT_CONFIG_DIR = (Join-Path $testRoot 'config')
    $configuredRoot = Join-Path $testRoot 'configured-data'
    Set-PomoInsightConfiguredRoot -Root $configuredRoot
    Assert-Equal (Get-PomoInsightDataRoot) ([System.IO.Path]::GetFullPath($configuredRoot)) 'configured data root'
    Assert-Equal (Get-PomoInsightDataLocationPath) (Join-Path $env:POMO_INSIGHT_CONFIG_DIR 'data-location.json') 'data location pointer path'
    $copied = Copy-PomoInsightData -Source $testRoot -Destination $configuredRoot
    if ($copied -ge 2 -and (Test-Path -LiteralPath (Join-Path $configuredRoot 'sessions.json')) -and (Test-Path -LiteralPath (Join-Path $configuredRoot 'settings.json'))) {
        Write-Output 'PASS data migration copy'
    } else {
        $failures.Add('FAIL data migration copy')
    }
    Initialize-PomoInsightStorage -Root $configuredRoot
    Assert-Equal @(Get-PomoInsightSessions -Root $configuredRoot).Count 1 'copied sessions count'
} finally {
    $env:POMO_INSIGHT_DATA_DIR = $oldDataDir
    $env:POMO_INSIGHT_CONFIG_DIR = $oldConfigDir
}

if ($testRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Output $failure }
    exit 1
}
Write-Output 'CORE_SMOKE_OK'