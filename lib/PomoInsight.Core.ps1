#requires -Version 5.1

$script:PomoInsightVersion = '1.2.0'
$script:DefaultSettings = [ordered]@{
    focusMinutes    = 50
    breakMinutes    = 10
    snoozeMinutes   = 10
    maxFocusMinutes = 90
    eyeReminder     = $false
    autoStart       = $false
    alwaysOnTop     = $true
}

function Get-PomoInsightDefaultRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:POMO_INSIGHT_DATA_DIR)) { return $env:POMO_INSIGHT_DATA_DIR }
    return (Join-Path $env:LOCALAPPDATA 'PomoInsight')
}

function Get-PomoInsightConfigRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:POMO_INSIGHT_CONFIG_DIR)) { return $env:POMO_INSIGHT_CONFIG_DIR }
    return (Join-Path $env:LOCALAPPDATA 'PomoInsight')
}

function Get-PomoInsightDataLocationPath {
    return (Join-Path (Get-PomoInsightConfigRoot) 'data-location.json')
}

function Get-PomoInsightConfiguredRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:POMO_INSIGHT_DATA_DIR)) { return $env:POMO_INSIGHT_DATA_DIR }
    $config = Read-JsonFile -Path (Get-PomoInsightDataLocationPath) -Default $null
    if ($null -ne $config -and $null -ne $config.PSObject.Properties['dataDir']) {
        $dir = [string]$config.dataDir
        if (-not [string]::IsNullOrWhiteSpace($dir)) { return $dir }
    }
    return $null
}

function Get-PomoInsightDataRoot {
    $configured = Get-PomoInsightConfiguredRoot
    if (-not [string]::IsNullOrWhiteSpace($configured)) { return $configured }
    return Get-PomoInsightDefaultRoot
}

function Set-PomoInsightConfiguredRoot {
    param([Parameter(Mandatory = $true)][string]$Root)
    $configRoot = Get-PomoInsightConfigRoot
    Ensure-Directory -Path $configRoot
    $value = [pscustomobject]@{
        dataDir = [System.IO.Path]::GetFullPath($Root)
        updatedAt = [DateTimeOffset]::Now.ToString('o')
    }
    Write-JsonFile -Path (Get-PomoInsightDataLocationPath) -Value $value
}

function Copy-PomoInsightData {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    $sourcePath = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destPath = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ([string]::Equals($sourcePath, $destPath, [System.StringComparison]::OrdinalIgnoreCase)) { return 0 }
    Ensure-Directory -Path $destPath
    $count = 0
    foreach ($name in @('settings.json', 'sessions.json', 'active-session.json', 'pomoinsight.log')) {
        $src = Join-Path $sourcePath $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        [System.IO.File]::Copy($src, (Join-Path $destPath $name), $true)
        $count++
    }
    return $count
}

function Get-PomoInsightPath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Name)
    return (Join-Path $Root $Name)
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Write-TextFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [switch]$Bom
    )
    $dir = Split-Path -Parent $Path
    Ensure-Directory -Path $dir
    $tmp = "$Path.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($Bom.IsPresent)
    [System.IO.File]::WriteAllText($tmp, $Content, $encoding)
    if (Test-Path -LiteralPath $Path) {
        try { [System.IO.File]::Replace($tmp, $Path, $null) }
        catch {
            Remove-Item -LiteralPath $Path -Force
            [System.IO.File]::Move($tmp, $Path)
        }
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, $Default = $null)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        return ($raw | ConvertFrom-Json)
    } catch { return $Default }
}

function Write-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 40
    Write-TextFileAtomic -Path $Path -Content $json
}

function Initialize-PomoInsightStorage {
    param([Parameter(Mandatory = $true)][string]$Root)
    Ensure-Directory -Path $Root
    Ensure-Directory -Path (Join-Path $Root 'exports')
    $settingsPath = Get-PomoInsightPath -Root $Root -Name 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { Write-JsonFile -Path $settingsPath -Value ([pscustomobject]$script:DefaultSettings) }
    $sessionsPath = Get-PomoInsightPath -Root $Root -Name 'sessions.json'
    if (-not (Test-Path -LiteralPath $sessionsPath)) { Write-TextFileAtomic -Path $sessionsPath -Content '[]' }
}

function Get-PomoInsightSettings {
    param([Parameter(Mandatory = $true)][string]$Root)
    $saved = Read-JsonFile -Path (Get-PomoInsightPath -Root $Root -Name 'settings.json') -Default $null
    $settings = [ordered]@{}
    foreach ($key in $script:DefaultSettings.Keys) { $settings[$key] = $script:DefaultSettings[$key] }
    if ($null -ne $saved) {
        foreach ($key in $script:DefaultSettings.Keys) {
            if ($null -ne $saved.PSObject.Properties[$key]) { $settings[$key] = $saved.$key }
        }
    }
    $settings.focusMinutes = [Math]::Min(180, [Math]::Max(10, [int]$settings.focusMinutes))
    $settings.breakMinutes = [Math]::Min(60, [Math]::Max(1, [int]$settings.breakMinutes))
    $settings.snoozeMinutes = [Math]::Min(30, [Math]::Max(1, [int]$settings.snoozeMinutes))
    $settings.maxFocusMinutes = [Math]::Min(240, [Math]::Max([int]$settings.focusMinutes, [int]$settings.maxFocusMinutes))
    $settings.eyeReminder = [bool]$settings.eyeReminder
    $settings.autoStart = [bool]$settings.autoStart
    $settings.alwaysOnTop = [bool]$settings.alwaysOnTop
    return [pscustomobject]$settings
}

function Save-PomoInsightSettings {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$Settings)
    Write-JsonFile -Path (Get-PomoInsightPath -Root $Root -Name 'settings.json') -Value $Settings
}

function Get-PomoInsightSessions {
    param([Parameter(Mandatory = $true)][string]$Root)
    $data = Read-JsonFile -Path (Get-PomoInsightPath -Root $Root -Name 'sessions.json') -Default @()
    if ($null -eq $data) { return @() }
    return @($data)
}

function Save-PomoInsightSessions {
    param([Parameter(Mandatory = $true)][string]$Root, [AllowEmptyCollection()][object[]]$Sessions = @())
    Write-JsonFile -Path (Get-PomoInsightPath -Root $Root -Name 'sessions.json') -Value @($Sessions)
}

function ConvertTo-DateTimeOffsetValue {
    param($Value, [long]$UnixMs = 0)
    if ($UnixMs -gt 0) { return [DateTimeOffset]::FromUnixTimeMilliseconds($UnixMs).ToLocalTime() }
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]::new($Value) }
    try { return [DateTimeOffset]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) }
    catch { return $null }
}

function Get-EpochMs {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$Value)
    return [long]$Value.ToUnixTimeMilliseconds()
}

function New-PomoInsightSession {
    param([Parameter(Mandatory = $true)][string]$Task, [Parameter(Mandatory = $true)][DateTimeOffset]$StartedAt)
    $id = '{0}-{1}' -f $StartedAt.ToString('yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $session = [pscustomobject]@{
        schemaVersion = 1
        id = $id
        task = $Task.Trim()
        startedAt = $StartedAt.ToString('o')
        startedAtUnixMs = (Get-EpochMs -Value $StartedAt)
        endedAt = $null
        endedAtUnixMs = $null
        localDate = $StartedAt.ToString('yyyy-MM-dd')
        endLocalDate = $null
        dayOfWeek = $StartedAt.DayOfWeek.ToString()
        startHour = [int]$StartedAt.Hour
        endHour = $null
        wallSeconds = 0
        breakSeconds = 0
        workSeconds = 0
        durationMinutes = 0
        breakCount = 0
        reminderCount = 0
        snoozeCount = 0
        timerGapCount = 0
        timerGapSeconds = 0
        timerGaps = @()
        longestFocusSeconds = 0
        endReason = $null
        completed = $false
        lastHeartbeatAt = $StartedAt.ToString('o')
        lastHeartbeatAtUnixMs = (Get-EpochMs -Value $StartedAt)
        breaks = @()
        events = @()
        appVersion = $script:PomoInsightVersion
        timezone = [System.TimeZoneInfo]::Local.Id
    }
    Add-SessionEvent -Session $session -Type 'start' -At $StartedAt | Out-Null
    return $session
}

function Add-SessionEvent {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$Type,
        [DateTimeOffset]$At = [DateTimeOffset]::Now,
        [Nullable[int]]$Minutes = $null,
        [string]$Note = ''
    )
    $event = [pscustomobject]@{ at = $At.ToString('o'); atUnixMs = (Get-EpochMs -Value $At); type = $Type; minutes = $Minutes; note = $Note }
    $Session.events = @($Session.events) + $event
    if ($Type -eq 'reminder') { $Session.reminderCount = [int]$Session.reminderCount + 1 }
    if ($Type -eq 'snooze') { $Session.snoozeCount = [int]$Session.snoozeCount + 1 }
    return $Session
}

function Get-SessionBreakSeconds {
    param($Session, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $total = 0.0
    foreach ($br in @($Session.breaks)) {
        if ($null -eq $br) { continue }
        $bStart = ConvertTo-DateTimeOffsetValue -Value $br.startedAt -UnixMs ([long]$br.startedAtUnixMs)
        if ($null -eq $bStart) { continue }
        $bEnd = ConvertTo-DateTimeOffsetValue -Value $br.endedAt -UnixMs ([long]$br.endedAtUnixMs)
        if ($null -eq $bEnd) { $bEnd = $Now }
        $sec = ($bEnd - $bStart).TotalSeconds
        if ($sec -gt 0) { $total += $sec }
    }
    return [Math]::Max(0.0, $total)
}

function Get-SessionWallSeconds {
    param($Session, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $start = ConvertTo-DateTimeOffsetValue -Value $Session.startedAt -UnixMs ([long]$Session.startedAtUnixMs)
    if ($null -eq $start) { return 0.0 }
    $end = ConvertTo-DateTimeOffsetValue -Value $Session.endedAt -UnixMs ([long]$Session.endedAtUnixMs)
    if ($null -eq $end) { $end = $Now }
    return [Math]::Max(0.0, ($end - $start).TotalSeconds)
}

function Get-SessionGapSeconds {
    param($Session)
    if ($null -eq $Session) { return 0.0 }
    if ($null -eq $Session.PSObject.Properties['timerGapSeconds']) { return 0.0 }
    return [Math]::Max(0.0, [double]$Session.timerGapSeconds)
}

function Get-SessionWorkSeconds {
    param($Session, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $wall = Get-SessionWallSeconds -Session $Session -Now $Now
    $brk = Get-SessionBreakSeconds -Session $Session -Now $Now
    $gap = Get-SessionGapSeconds -Session $Session
    return [Math]::Max(0.0, $wall - $brk - $gap)
}

function Get-LongestFocusSeconds {
    param($Session, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $start = ConvertTo-DateTimeOffsetValue -Value $Session.startedAt -UnixMs ([long]$Session.startedAtUnixMs)
    if ($null -eq $start) { return 0.0 }
    $end = ConvertTo-DateTimeOffsetValue -Value $Session.endedAt -UnixMs ([long]$Session.endedAtUnixMs)
    if ($null -eq $end) { $end = $Now }
    $excluded = New-Object System.Collections.Generic.List[object]
    foreach ($br in @($Session.breaks)) {
        if ($null -eq $br) { continue }
        $bStart = ConvertTo-DateTimeOffsetValue -Value $br.startedAt -UnixMs ([long]$br.startedAtUnixMs)
        if ($null -eq $bStart) { continue }
        $bEnd = ConvertTo-DateTimeOffsetValue -Value $br.endedAt -UnixMs ([long]$br.endedAtUnixMs)
        if ($null -eq $bEnd) { $bEnd = $Now }
        $excluded.Add([pscustomobject]@{ start = $bStart; end = $bEnd })
    }
    if ($null -ne $Session.PSObject.Properties['timerGaps']) {
        foreach ($gap in @($Session.timerGaps)) {
            if ($null -eq $gap) { continue }
            $gStart = ConvertTo-DateTimeOffsetValue -Value $gap.startedAt -UnixMs ([long]$gap.startedAtUnixMs)
            if ($null -eq $gStart) { continue }
            $gEnd = ConvertTo-DateTimeOffsetValue -Value $gap.endedAt -UnixMs ([long]$gap.endedAtUnixMs)
            if ($null -eq $gEnd) { continue }
            $excluded.Add([pscustomobject]@{ start = $gStart; end = $gEnd })
        }
    }
    $cursor = $start
    $max = 0.0
    foreach ($item in ($excluded | Sort-Object { $_.start })) {
        if ($item.start -gt $cursor) {
            $seg = ($item.start - $cursor).TotalSeconds
            if ($seg -gt $max) { $max = $seg }
        }
        if ($item.end -gt $cursor) { $cursor = $item.end }
    }
    if ($end -gt $cursor) {
        $seg = ($end - $cursor).TotalSeconds
        if ($seg -gt $max) { $max = $seg }
    }
    $max = [Math]::Max(0.0, $max)
    $workLimit = Get-SessionWorkSeconds -Session $Session -Now $Now
    if ($max -gt $workLimit) { $max = $workLimit }
    return $max
}
function Update-PomoInsightSessionMetrics {
    param([Parameter(Mandatory = $true)]$Session, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $wall = Get-SessionWallSeconds -Session $Session -Now $Now
    $brk = Get-SessionBreakSeconds -Session $Session -Now $Now
    $gap = Get-SessionGapSeconds -Session $Session
    $work = [Math]::Max(0.0, $wall - $brk - $gap)
    $Session.wallSeconds = [int][Math]::Round($wall)
    $Session.breakSeconds = [int][Math]::Round($brk)
    $Session.workSeconds = [int][Math]::Round($work)
    $Session.durationMinutes = [Math]::Round($work / 60.0, 1)
    $Session.breakCount = @($Session.breaks).Count
    $Session.longestFocusSeconds = [int][Math]::Round((Get-LongestFocusSeconds -Session $Session -Now $Now))
    return $Session
}

function Complete-PomoInsightSession {
    param([Parameter(Mandatory = $true)]$Session, [Parameter(Mandatory = $true)][DateTimeOffset]$EndedAt, [string]$Reason = 'manual')
    $breaks = @($Session.breaks)
    for ($i = 0; $i -lt $breaks.Count; $i++) {
        $br = $breaks[$i]
        if ($null -ne $br -and [string]::IsNullOrWhiteSpace([string]$br.endedAt)) {
            $bStart = ConvertTo-DateTimeOffsetValue -Value $br.startedAt -UnixMs ([long]$br.startedAtUnixMs)
            $br.endedAt = $EndedAt.ToString('o')
            $br.endedAtUnixMs = (Get-EpochMs -Value $EndedAt)
            if ($null -ne $bStart) { $br.durationSeconds = [int][Math]::Round(($EndedAt - $bStart).TotalSeconds) }
            $br.completed = $true
        }
    }
    $Session.breaks = @($breaks)
    $Session.endedAt = $EndedAt.ToString('o')
    $Session.endedAtUnixMs = (Get-EpochMs -Value $EndedAt)
    $Session.endLocalDate = $EndedAt.ToString('yyyy-MM-dd')
    $Session.endHour = [int]$EndedAt.Hour
    Update-PomoInsightSessionMetrics -Session $Session -Now $EndedAt | Out-Null
    $Session.endReason = $Reason
    $Session.completed = $true
    Add-SessionEvent -Session $Session -Type 'end' -At $EndedAt -Note $Reason | Out-Null
    return $Session
}

function Set-PomoInsightSessionSchedule {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][DateTimeOffset]$StartedAt,
        [Parameter(Mandatory = $true)][DateTimeOffset]$EndedAt,
        [string]$Reason = 'edited'
    )
    if ($EndedAt -le $StartedAt) { throw '结束时间必须晚于开始时间' }
    $taskText = $Task.Trim()
    if ([string]::IsNullOrWhiteSpace($taskText)) { throw '请填写工作内容' }
    $Session.task = $taskText
    $Session.startedAt = $StartedAt.ToString('o')
    $Session.startedAtUnixMs = (Get-EpochMs -Value $StartedAt)
    $Session.localDate = $StartedAt.ToString('yyyy-MM-dd')
    $Session.dayOfWeek = $StartedAt.DayOfWeek.ToString()
    $Session.startHour = [int]$StartedAt.Hour
    $Session.endedAt = $EndedAt.ToString('o')
    $Session.endedAtUnixMs = (Get-EpochMs -Value $EndedAt)
    $Session.endLocalDate = $EndedAt.ToString('yyyy-MM-dd')
    $Session.endHour = [int]$EndedAt.Hour

    $breaks = New-Object System.Collections.Generic.List[object]
    foreach ($br in @($Session.breaks)) {
        if ($null -eq $br) { continue }
        $bStart = ConvertTo-DateTimeOffsetValue -Value $br.startedAt -UnixMs ([long]$br.startedAtUnixMs)
        if ($null -eq $bStart) { continue }
        $bEnd = ConvertTo-DateTimeOffsetValue -Value $br.endedAt -UnixMs ([long]$br.endedAtUnixMs)
        if ($null -eq $bEnd) { $bEnd = $EndedAt }
        if ($bEnd -le $StartedAt -or $bStart -ge $EndedAt) { continue }
        if ($bStart -lt $StartedAt) { $bStart = $StartedAt }
        if ($bEnd -gt $EndedAt) { $bEnd = $EndedAt }
        $br.startedAt = $bStart.ToString('o')
        $br.startedAtUnixMs = (Get-EpochMs -Value $bStart)
        $br.endedAt = $bEnd.ToString('o')
        $br.endedAtUnixMs = (Get-EpochMs -Value $bEnd)
        $br.durationSeconds = [int][Math]::Round(($bEnd - $bStart).TotalSeconds)
        $br.completed = $true
        $breaks.Add($br)
    }
    $Session.breaks = $breaks.ToArray()

    $gaps = New-Object System.Collections.Generic.List[object]
    $gapSeconds = 0.0
    foreach ($gapItem in @($Session.timerGaps)) {
        if ($null -eq $gapItem) { continue }
        $gStart = ConvertTo-DateTimeOffsetValue -Value $gapItem.startedAt -UnixMs ([long]$gapItem.startedAtUnixMs)
        if ($null -eq $gStart) { continue }
        $gEnd = ConvertTo-DateTimeOffsetValue -Value $gapItem.endedAt -UnixMs ([long]$gapItem.endedAtUnixMs)
        if ($null -eq $gEnd) { continue }
        if ($gEnd -le $StartedAt -or $gStart -ge $EndedAt) { continue }
        if ($gStart -lt $StartedAt) { $gStart = $StartedAt }
        if ($gEnd -gt $EndedAt) { $gEnd = $EndedAt }
        $gapItem.startedAt = $gStart.ToString('o')
        $gapItem.startedAtUnixMs = (Get-EpochMs -Value $gStart)
        $gapItem.endedAt = $gEnd.ToString('o')
        $gapItem.endedAtUnixMs = (Get-EpochMs -Value $gEnd)
        $gapItem.durationSeconds = [int][Math]::Round(($gEnd - $gStart).TotalSeconds)
        $gapSeconds += ($gEnd - $gStart).TotalSeconds
        $gaps.Add($gapItem)
    }
    $Session.timerGaps = $gaps.ToArray()
    $Session.timerGapCount = $gaps.Count
    $Session.timerGapSeconds = [int][Math]::Round($gapSeconds)

    Update-PomoInsightSessionMetrics -Session $Session -Now $EndedAt | Out-Null
    $Session.completed = $true
    $Session.endReason = $Reason
    Add-SessionEvent -Session $Session -Type 'edit' -At ([DateTimeOffset]::Now) -Note $Reason | Out-Null
    return $Session
}

function Save-ActiveSession {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$Session)
    Write-JsonFile -Path (Get-PomoInsightPath -Root $Root -Name 'active-session.json') -Value $Session
}

function Get-ActiveSession {
    param([Parameter(Mandatory = $true)][string]$Root)
    return (Read-JsonFile -Path (Get-PomoInsightPath -Root $Root -Name 'active-session.json') -Default $null)
}

function Remove-ActiveSession {
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Get-PomoInsightPath -Root $Root -Name 'active-session.json'
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Recover-InterruptedSession {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$Active)
    $started = ConvertTo-DateTimeOffsetValue -Value $Active.startedAt -UnixMs ([long]$Active.startedAtUnixMs)
    $heartbeat = ConvertTo-DateTimeOffsetValue -Value $Active.lastHeartbeatAt -UnixMs ([long]$Active.lastHeartbeatAtUnixMs)
    if ($null -eq $started) { return $null }
    if ($null -eq $heartbeat -or $heartbeat -lt $started) { $heartbeat = $started }
    $now = [DateTimeOffset]::Now
    if ($heartbeat -gt $now) { $heartbeat = $now }
    Complete-PomoInsightSession -Session $Active -EndedAt $heartbeat -Reason 'recovered' | Out-Null
    $sessions = @(Get-PomoInsightSessions -Root $Root) + $Active
    Save-PomoInsightSessions -Root $Root -Sessions @($sessions)
    Remove-ActiveSession -Root $Root
    return $Active
}

function Get-RecentTasks {
    param([AllowEmptyCollection()][object[]]$Sessions = @(), [int]$Limit = 6)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $tasks = New-Object 'System.Collections.Generic.List[string]'
    $ordered = @($Sessions) | Sort-Object { [long]$_.startedAtUnixMs } -Descending
    foreach ($session in $ordered) {
        if ($null -eq $session -or [string]::IsNullOrWhiteSpace([string]$session.task)) { continue }
        $task = ([string]$session.task).Trim()
        if ($seen.Add($task)) { $tasks.Add($task) }
        if ($tasks.Count -ge $Limit) { break }
    }
    return @($tasks)
}

function Get-TodaySummary {
    param([AllowEmptyCollection()][object[]]$Sessions = @(), [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $today = $Now.ToString('yyyy-MM-dd')
    $items = @($Sessions | Where-Object { $null -ne $_ -and [string]$_.localDate -eq $today })
    $work = 0.0
    $brk = 0.0
    $gap = 0.0
    foreach ($item in $items) {
        $work += [double]$item.workSeconds
        $brk += [double]$item.breakSeconds
        $gap += Get-SessionGapSeconds -Session $item
    }
    $breakSum = ($items | ForEach-Object { [int]$_.breakCount } | Measure-Object -Sum).Sum
    if ($null -eq $breakSum) { $breakSum = 0 }
    $gapCount = ($items | ForEach-Object { [int]$_.timerGapCount } | Measure-Object -Sum).Sum
    if ($null -eq $gapCount) { $gapCount = 0 }
    return [pscustomobject]@{ date = $today; sessions = $items.Count; workSeconds = [int][Math]::Round($work); breakSeconds = [int][Math]::Round($brk); breakCount = [int]$breakSum; timerGapSeconds = [int][Math]::Round($gap); timerGapCount = [int]$gapCount }
}

function Get-TodayGapSummary {
    param([AllowEmptyCollection()][object[]]$Sessions = @(), $ActiveSession = $null, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $today = $Now.ToString('yyyy-MM-dd')
    $intervals = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Sessions)) {
        if ($null -eq $item -or -not [bool]$item.completed) { continue }
        if ([string]$item.localDate -ne $today) { continue }
        $start = ConvertTo-DateTimeOffsetValue -Value $item.startedAt -UnixMs ([long]$item.startedAtUnixMs)
        $end = ConvertTo-DateTimeOffsetValue -Value $item.endedAt -UnixMs ([long]$item.endedAtUnixMs)
        if ($null -eq $start -or $null -eq $end -or $end -le $start) { continue }
        $intervals.Add([pscustomobject]@{ start = $start; end = $end; task = [string]$item.task })
    }
    if ($null -ne $ActiveSession -and [string]$ActiveSession.localDate -eq $today) {
        $start = ConvertTo-DateTimeOffsetValue -Value $ActiveSession.startedAt -UnixMs ([long]$ActiveSession.startedAtUnixMs)
        if ($null -ne $start -and $Now -gt $start) {
            $intervals.Add([pscustomobject]@{ start = $start; end = $Now; task = [string]$ActiveSession.task })
        }
    }
    $gapSeconds = 0.0
    $gapCount = 0
    if ($intervals.Count -gt 1) {
        $cursor = $null
        foreach ($item in @($intervals | Sort-Object { $_.start })) {
            if ($null -eq $cursor) { $cursor = $item.end; continue }
            if ($item.start -gt $cursor) {
                $gapSeconds += ($item.start - $cursor).TotalSeconds
                $gapCount++
            }
            if ($item.end -gt $cursor) { $cursor = $item.end }
        }
    }
    return [pscustomobject]@{ date = $today; gapSeconds = [int][Math]::Round($gapSeconds); gapCount = $gapCount }
}

function Get-PomoInsightSummary {
    param([AllowEmptyCollection()][object[]]$Sessions = @())
    $all = @($Sessions | Where-Object { $null -ne $_ -and [bool]$_.completed })
    if ($all.Count -eq 0) {
        return [pscustomobject]@{ totalSessions = 0; totalWorkMinutes = 0; totalBreakMinutes = 0; averageWorkMinutes = 0; longestSessionMinutes = 0; breakComplianceRate = 0; totalSnoozes = 0; activeDays = 0; byDay = @(); byHour = @(); byTask = @(); byWeekday = @() }
    }
    $totalWork = 0.0
    $totalBreak = 0.0
    $snoozes = 0
    $withBreak = 0
    $longest = 0.0
    $dayMap = @{}
    $hourMap = @{}
    $taskMap = @{}
    $weekdayMap = @{}
    foreach ($session in $all) {
        $workSec = [double]$session.workSeconds
        $breakSec = [double]$session.breakSeconds
        $totalWork += $workSec
        $totalBreak += $breakSec
        $snoozes += [int]$session.snoozeCount
        if ([int]$session.breakCount -gt 0) { $withBreak++ }
        if ($workSec -gt $longest) { $longest = $workSec }

        $day = [string]$session.localDate
        if (-not $dayMap.ContainsKey($day)) { $dayMap[$day] = [pscustomobject]@{ date = $day; workMinutes = 0.0; breakMinutes = 0.0; sessions = 0; firstStartUnixMs = $null; lastEndUnixMs = $null } }
        $dayMap[$day].workMinutes += $workSec / 60.0
        $dayMap[$day].breakMinutes += $breakSec / 60.0
        $dayMap[$day].sessions++
        if ($null -eq $dayMap[$day].firstStartUnixMs -or [long]$session.startedAtUnixMs -lt [long]$dayMap[$day].firstStartUnixMs) { $dayMap[$day].firstStartUnixMs = [long]$session.startedAtUnixMs }
        if ($null -eq $dayMap[$day].lastEndUnixMs -or [long]$session.endedAtUnixMs -gt [long]$dayMap[$day].lastEndUnixMs) { $dayMap[$day].lastEndUnixMs = [long]$session.endedAtUnixMs }

        $hour = ('{0:D2}:00' -f [int]$session.startHour)
        if (-not $hourMap.ContainsKey($hour)) { $hourMap[$hour] = [pscustomobject]@{ hour = $hour; workMinutes = 0.0; sessions = 0 } }
        $hourMap[$hour].workMinutes += $workSec / 60.0
        $hourMap[$hour].sessions++

        $task = [string]$session.task
        if (-not $taskMap.ContainsKey($task)) { $taskMap[$task] = [pscustomobject]@{ task = $task; workMinutes = 0.0; sessions = 0 } }
        $taskMap[$task].workMinutes += $workSec / 60.0
        $taskMap[$task].sessions++

        $weekday = [string]$session.dayOfWeek
        if (-not $weekdayMap.ContainsKey($weekday)) { $weekdayMap[$weekday] = [pscustomobject]@{ weekday = $weekday; workMinutes = 0.0; sessions = 0 } }
        $weekdayMap[$weekday].workMinutes += $workSec / 60.0
        $weekdayMap[$weekday].sessions++
    }
    $byDay = @($dayMap.Values | Sort-Object date)
    foreach ($d in $byDay) { $d.workMinutes = [Math]::Round($d.workMinutes, 1); $d.breakMinutes = [Math]::Round($d.breakMinutes, 1) }
    $byHour = @($hourMap.Values | Sort-Object hour)
    foreach ($h in $byHour) { $h.workMinutes = [Math]::Round($h.workMinutes, 1) }
    $byTask = @($taskMap.Values | Sort-Object workMinutes -Descending)
    foreach ($t in $byTask) { $t.workMinutes = [Math]::Round($t.workMinutes, 1) }
    $byWeekday = @($weekdayMap.Values)
    foreach ($w in $byWeekday) { $w.workMinutes = [Math]::Round($w.workMinutes, 1) }
    return [pscustomobject]@{
        totalSessions = $all.Count; totalWorkMinutes = [Math]::Round($totalWork / 60.0, 1); totalBreakMinutes = [Math]::Round($totalBreak / 60.0, 1)
        averageWorkMinutes = [Math]::Round(($totalWork / 60.0) / $all.Count, 1); longestSessionMinutes = [Math]::Round($longest / 60.0, 1)
        breakComplianceRate = [Math]::Round(($withBreak / [double]$all.Count) * 100.0, 1); totalSnoozes = $snoozes; activeDays = $byDay.Count
        byDay = $byDay; byHour = $byHour; byTask = $byTask; byWeekday = $byWeekday
    }
}

function Export-PomoInsightData {
    param([Parameter(Mandatory = $true)][string]$Root, [string]$OutputDir, [ValidateSet('json', 'csv')][string]$Format = 'json', [string]$OutputPath = '')
    $settings = Get-PomoInsightSettings -Root $Root
    $sessions = @(Get-PomoInsightSessions -Root $Root)
    $summary = Get-PomoInsightSummary -Sessions $sessions
    $stamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')
    $path = $OutputPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PomoInsight Exports' }
        Ensure-Directory -Path $OutputDir
        $extension = if ($Format -eq 'json') { 'json' } else { 'csv' }
        $path = Join-Path $OutputDir ("PomoInsight_{0}.{1}" -f $stamp, $extension)
    } else {
        $path = [System.IO.Path]::GetFullPath($path)
        $parent = Split-Path -Parent $path
        if (-not [string]::IsNullOrWhiteSpace($parent)) { Ensure-Directory -Path $parent }
    }

    if ($Format -eq 'json') {
        $export = [ordered]@{
            schemaVersion = 1
            generatedAt = [DateTimeOffset]::Now.ToString('o')
            generatedBy = "PomoInsight $script:PomoInsightVersion"
            privacy = 'Local-only export. The app contains no network code.'
            reminderModel = [ordered]@{
                name = 'Flow-aware configurable work/break schedule'
                focusMinutes = $settings.focusMinutes
                breakMinutes = $settings.breakMinutes
                snoozeMinutes = $settings.snoozeMinutes
                maxFocusMinutes = $settings.maxFocusMinutes
                eyeReminderEnabled = $settings.eyeReminder
                designNotes = @(
                    'The first break is a soft prompt, not a forced stop, to protect flow.',
                    'Snoozing is allowed in steps up to the 90-minute guardrail.',
                    'After the guardrail the prompt becomes firmer and snoozes shorten to 5 minutes.',
                    'Break duration is tracked separately from wall-clock session duration.',
                    'No single work-break ratio is proven universal; the schedule is adjustable.'
                    'Presets such as 25/5, 50/10 and 52/17 are starting points, not medical prescriptions.'
                )
                sources = @(
                    'Luger T, et al. Work-break schedules for preventing musculoskeletal symptoms and disorders in healthy workers. Cochrane Database Syst Rev. 2019. doi:10.1002/14651858.CD012886.pub2',
                    '20-20-20 rule: an effective method for coping with computer vision syndrome. J Pak Med Assoc. 2025. doi:10.47391/jpma.30263',
                    'DeskTime. Does the 52-17 rule really hold up? 2024/2025. https://desktime.com/blog/52-17-updated/'
                )
            }
            settings = $settings
            summary = $summary
            sessions = $sessions
        }
        Write-JsonFile -Path $path -Value $export
        return $path
    }

    $rows = @()
    foreach ($session in $sessions) {
        $rows += [pscustomobject]@{
            id = [string]$session.id
            task = [string]$session.task
            localDate = [string]$session.localDate
            dayOfWeek = [string]$session.dayOfWeek
            startHour = [int]$session.startHour
            startedAt = [string]$session.startedAt
            endedAt = [string]$session.endedAt
            wallMinutes = [Math]::Round(([double]$session.wallSeconds) / 60.0, 1)
            workMinutes = [Math]::Round(([double]$session.workSeconds) / 60.0, 1)
            breakMinutes = [Math]::Round(([double]$session.breakSeconds) / 60.0, 1)
            breakCount = [int]$session.breakCount
            reminderCount = [int]$session.reminderCount
            snoozeCount = [int]$session.snoozeCount
            timerGapMinutes = [Math]::Round(([double]$session.timerGapSeconds) / 60.0, 1)
            longestFocusMinutes = [Math]::Round(([double]$session.longestFocusSeconds) / 60.0, 1)
            endReason = [string]$session.endReason
            breaksJson = (ConvertTo-Json -InputObject @($session.breaks) -Compress -Depth 10)
            eventsJson = (ConvertTo-Json -InputObject @($session.events) -Compress -Depth 10)
        }
    }
    $columns = @('id','task','localDate','dayOfWeek','startHour','startedAt','endedAt','wallMinutes','workMinutes','breakMinutes','breakCount','reminderCount','snoozeCount','timerGapMinutes','longestFocusMinutes','endReason','breaksJson','eventsJson')
    $lines = @((($columns | ForEach-Object { '"' + $_ + '"' }) -join ','))
    if ($rows.Count -gt 0) {
        $converted = @($rows | ConvertTo-Csv -NoTypeInformation)
        if ($converted.Count -gt 1) { $lines += $converted[1..($converted.Count - 1)] }
    }
    Write-TextFileAtomic -Path $path -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine) -Bom
    return $path
}

function Export-PomoInsightAnalysisBrief {
    param([Parameter(Mandatory = $true)][string]$Root, [string]$Directory = '', [string]$Stamp = (Get-Date -Format 'yyyyMMdd-HHmmss'), [string]$OutputPath = '')
    $settings = Get-PomoInsightSettings -Root $Root
    $path = $OutputPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PomoInsight Exports' }
        Ensure-Directory -Path $Directory
        $path = Join-Path $Directory ("PomoInsight_AI_Brief_{0}.md" -f $Stamp)
    } else {
        $path = [System.IO.Path]::GetFullPath($path)
        $parent = Split-Path -Parent $path
        if (-not [string]::IsNullOrWhiteSpace($parent)) { Ensure-Directory -Path $parent }
    }
    $brief = @"
# PomoInsight 工作习惯分析说明

这是 PomoInsight 导出的本地工作记录，可直接上传给 AI 分析。

## 关键字段
- startedAt / endedAt：本地时区的 ISO 8601 时间。
- wallSeconds：从开始到结束的墙钟时长。
- breakSeconds：会话中已记录的休息总时长。
- workSeconds：墙钟时长减去休息时长，是本工具口径下的实际工作时间。
- longestFocusSeconds：会话内最长的一段连续专注。
- breaks[]：每次休息的开始、结束、计划时长和实际时长。
- events[]：开始、提醒、延后、休息、结束等行为事件，适合分析中断和自控模式。
- reminderCount / snoozeCount：休息提醒次数和“再工作一会儿”的次数。
- timerGapSeconds / timerGapCount / timerGaps[]：超过 2 分钟的计时空洞（多为休眠/待机），已从实际工作时长和最长连续专注中扣除，并同步顺延下一次提醒。
- endReason：manual 手动结束、app_exit 退出、recovered 异常恢复、shutdown 系统关闭。

## 建议分析问题
1. 我一天中效率最高的时段是什么？不同任务的时长分布如何？
2. 我的专注段多长最容易连续？50 分钟提醒是否经常被延后？
3. 哪些工作日或任务更容易出现超长会话、少休息或频繁切换？
4. 根据我的实际记录，建议把专注/休息节律改成什么？
5. 给我一个下周可执行、不会破坏心流的休息计划。

## 当前提醒模型
当前设置：$(if ($null -ne $settings) { $settings.focusMinutes }) 分钟软提醒、$(if ($null -ne $settings) { $settings.breakMinutes }) 分钟休息、每次可延后 $(if ($null -ne $settings) { $settings.snoozeMinutes }) 分钟，最长连续专注 $(if ($null -ne $settings) { $settings.maxFocusMinutes }) 分钟后转为强提醒。休息为正向计时，超时也会被记录。
快捷预设（25/5、50/10、52/17）只是起点；该模型是可调整的启发式，不是唯一正确的医学结论。
"@
    Write-TextFileAtomic -Path $path -Content $brief
    return $path
}

function Get-PomoInsightStartupShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'PomoInsight.lnk')
}

function Test-PomoInsightAutoStart {
    return (Test-Path -LiteralPath (Get-PomoInsightStartupShortcutPath))
}

function Set-PomoInsightAutoStart {
    param([Parameter(Mandatory = $true)][bool]$Enabled, [Parameter(Mandatory = $true)][string]$ScriptPath)
    $lnkPath = Get-PomoInsightStartupShortcutPath
    if (-not $Enabled) {
        if (Test-Path -LiteralPath $lnkPath) { Remove-Item -LiteralPath $lnkPath -Force }
        return $false
    }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell)) { $powershell = 'powershell.exe' }
    $startup = [Environment]::GetFolderPath('Startup')
    Ensure-Directory -Path $startup
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnkPath)
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "{0}"' -f $ScriptPath
    $shortcut.WorkingDirectory = Split-Path -Parent $ScriptPath
    $shortcut.WindowStyle = 7
    $shortcut.Description = '番茄洞察 · 工作节奏追踪器'
    $iconPath = Join-Path (Split-Path -Parent $ScriptPath) 'assets\pomo-insight.ico'
    if (Test-Path -LiteralPath $iconPath) {
        $shortcut.IconLocation = ($iconPath + ',0')
    }
    $shortcut.Save()
    return $true
}

function Format-DurationShort {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    if ($ts.TotalHours -ge 1) { return ('{0}h {1:D2}m' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes) }
    if ($ts.TotalSeconds -lt 60) { return ('{0}s' -f [int]$ts.TotalSeconds) }
    return ('{0}m' -f [int][Math]::Floor($ts.TotalMinutes))
}

function Format-Clock {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds([Math]::Floor($Seconds))
    return ('{0:D2}:{1:D2}:{2:D2}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Write-PomoInsightLog {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Message)
    try {
        Ensure-Directory -Path $Root
        $line = '[{0}] {1}{2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
        [System.IO.File]::AppendAllText((Join-Path $Root 'pomoinsight.log'), $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
