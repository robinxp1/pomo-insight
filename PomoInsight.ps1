#requires -Version 5.1
param([string]$DataDir = '', [switch]$UiSmokeTest)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetCurrentProcess();
[DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(IntPtr hProcess);
'@ -Name NativeMemory -Namespace PomoInsightNative

Add-Type -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll", SetLastError = true)]
public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
'@ -Name NativeWindow -Namespace PomoInsightNative

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PomoInsightNative {
    public static class NativeCursor {
        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X; public int Y; }
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT point);
        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    }
    public static class NativeIcon {
        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr hIcon);
    }
}
'@

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:AppRoot 'lib\PomoInsight.Core.ps1')

$script:PortableMode = Test-Path -LiteralPath (Join-Path $script:AppRoot 'portable.dat')
if ($script:PortableMode -and [string]::IsNullOrWhiteSpace($env:POMO_INSIGHT_CONFIG_DIR)) {
    $env:POMO_INSIGHT_CONFIG_DIR = Join-Path $script:AppRoot 'data'
}
if (-not [string]::IsNullOrWhiteSpace($DataDir)) {
    $script:DataRoot = $DataDir
} elseif ($script:PortableMode) {
    $configured = Get-PomoInsightConfiguredRoot
    if (-not [string]::IsNullOrWhiteSpace($configured)) { $script:DataRoot = $configured }
    else { $script:DataRoot = Join-Path $script:AppRoot 'data' }
} else {
    $script:DataRoot = Get-PomoInsightDataRoot
}
Initialize-PomoInsightStorage -Root $script:DataRoot
$script:Settings = Get-PomoInsightSettings -Root $script:DataRoot
$script:Settings.autoStart = Test-PomoInsightAutoStart

$script:MutexName = 'Local\PomoInsight.SingleInstance'
if (-not [string]::IsNullOrWhiteSpace($env:POMO_INSIGHT_MUTEX_NAME)) { $script:MutexName = $env:POMO_INSIGHT_MUTEX_NAME }
$script:Mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
if (-not $script:Mutex.WaitOne(0)) { exit 0 }

$script:RecoveryMessage = $null
$activeDisk = Get-ActiveSession -Root $script:DataRoot
if ($null -ne $activeDisk) {
    try {
        $recovered = Recover-InterruptedSession -Root $script:DataRoot -Active $activeDisk
        if ($null -ne $recovered) {
            $mins = [int][Math]::Round(([double]$recovered.workSeconds) / 60.0)
            $script:RecoveryMessage = '已恢复并保存上次未结束的记录：{0} 分钟' -f $mins
            Write-PomoInsightLog -Root $script:DataRoot -Message ("Recovered interrupted session {0} ({1} min)" -f $recovered.id, $mins)
        }
    } catch {
        Write-PomoInsightLog -Root $script:DataRoot -Message ("Recovery failed: " + $_.Exception.Message)
    }
}
$script:Sessions = @(Get-PomoInsightSessions -Root $script:DataRoot)

$script:ActiveSession = $null
$script:InBreak = $false
$script:BreakStartedAt = $null
$script:BreakPlannedEnd = $null
$script:FocusSegmentStart = $null
$script:NextReminderAt = $null
$script:NextEyeReminderAt = $null
$script:ReminderMode = $null
$script:ReminderVisible = $false
$script:IsStrongReminder = $false
$script:SettingsOpen = $false
$script:Expanded = $false
$script:LastHeartbeatWrite = [DateTimeOffset]::MinValue
$script:StatusResetAt = [DateTimeOffset]::MinValue
$script:EyeAutoCloseAt = $null
$script:Exiting = $false
$script:ExitPromptOpen = $false
$script:LastTickLog = [DateTimeOffset]::MinValue
$script:LastTickAt = [DateTimeOffset]::Now
$script:LastInteractionAt = [DateTimeOffset]::Now.AddSeconds(-200)
$script:LastMemoryTrim = [DateTimeOffset]::MinValue
$script:WindowAnchor = 'right'
$script:DockedEdge = $null
$script:EdgeHidden = $false
$script:EdgePeekWidth = 22
$script:EdgeHideTimer = $null
$script:SlideTickHandler = $null
$script:SlideActive = $false
$script:SlideHandlerRegistered = $false
$script:EdgeRevealBlockedUntil = [DateTimeOffset]::MinValue
$script:EdgeHideBlockedUntil = [DateTimeOffset]::MinValue
$script:IsDragging = $false
$script:MiniTimerWindow = $null
$script:MiniTimerVisible = $false
$script:MiniTimerText = $null
$script:MiniTimerDot = $null
$script:BreakPrivacyAt = $null
$script:BreakPrivacyHidden = $false
$script:LastCursorX = $null
$script:LastCursorY = $null
$script:RecentTasksPopup = $null
$script:RecentTasksPopupShell = $null
$script:PresetDescriptionText = $null
$script:HistoryPopupFilter = $null
$script:CompactExpandButton = $null
$script:SuppressHistoryPopupOnce = $false
$script:MonitorArea = $null
$script:MonitorScreen = $null
$script:TrayIcon = $null
$script:TrayMenu = $null
$script:TrayIconBitmap = $null
$script:TrayIconHandle = [IntPtr]::Zero
$script:TrayIconImage = $null
$script:LastExportDirectory = $null

function Register-Interaction {
    $script:LastInteractionAt = [DateTimeOffset]::Now
}

function Trim-WorkingSet {
    if ($null -ne $script:ActiveSession) { return }
    try {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [void][PomoInsightNative.NativeMemory]::EmptyWorkingSet([PomoInsightNative.NativeMemory]::GetCurrentProcess())
        $script:LastMemoryTrim = [DateTimeOffset]::Now
    } catch { }
}

function New-Brush {
    param([Parameter(Mandatory = $true)][string]$Hex)
    $converter = New-Object System.Windows.Media.BrushConverter
    return $converter.ConvertFromString($Hex)
}

function Get-MainWindowHandle {
    if ($null -eq $script:Window) { return [IntPtr]::Zero }
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window
        return $helper.Handle
    } catch {
        return [IntPtr]::Zero
    }
}

function Get-WindowDpiScale {
    $scaleX = 1.0
    $scaleY = 1.0
    try {
        $source = [System.Windows.PresentationSource]::FromVisual($script:Window)
        if ($null -ne $source -and $null -ne $source.CompositionTarget) {
            $matrix = $source.CompositionTarget.TransformToDevice
            if ($matrix.M11 -gt 0) { $scaleX = [double]$matrix.M11 }
            if ($matrix.M22 -gt 0) { $scaleY = [double]$matrix.M22 }
        }
    } catch { }
    return [pscustomobject]@{ X = $scaleX; Y = $scaleY }
}

function Get-MonitorWorkAreaFromWindow {
    param([switch]$Primary)
    try {
        $screen = $null
        if (-not $Primary) {
            $left = [double]$script:Window.Left
            $top = [double]$script:Window.Top
            $width = if ([double]$script:Window.Width -gt 0) { [double]$script:Window.Width } else { [double]$script:Window.ActualWidth }
            $height = if ([double]$script:Window.Height -gt 0) { [double]$script:Window.Height } else { [double]$script:Window.ActualHeight }
            if (-not [double]::IsNaN($left) -and -not [double]::IsNaN($top) -and $width -gt 0 -and $height -gt 0) {
                $scaleForPoint = Get-WindowDpiScale
                $centerX = [int][Math]::Round(($left + ($width / 2.0)) * $scaleForPoint.X)
                $centerY = [int][Math]::Round(($top + ($height / 2.0)) * $scaleForPoint.Y)
                try { $screen = [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new($centerX, $centerY)) } catch { }
            }
            $handle = Get-MainWindowHandle
            if ($null -eq $screen -and $handle -ne [IntPtr]::Zero) { $screen = [System.Windows.Forms.Screen]::FromHandle($handle) }
        }
        if ($null -eq $screen) { $screen = [System.Windows.Forms.Screen]::PrimaryScreen }
        $script:MonitorScreen = $screen
        if ($null -eq $screen) { return [System.Windows.SystemParameters]::WorkArea }
        return Convert-ScreenWorkAreaToBounds -Screen $screen
    } catch {
        return [System.Windows.SystemParameters]::WorkArea
    }
}

function Convert-ScreenWorkAreaToBounds {
    param([Parameter(Mandatory = $true)]$Screen)
    $working = $Screen.WorkingArea
    $scale = Get-WindowDpiScale
    $left = [double]$working.Left / $scale.X
    $top = [double]$working.Top / $scale.Y
    $right = [double]$working.Right / $scale.X
    $bottom = [double]$working.Bottom / $scale.Y
    return [pscustomobject]@{
        Left = $left
        Top = $top
        Right = $right
        Bottom = $bottom
        Width = $right - $left
        Height = $bottom - $top
    }
}

function Get-InternalMonitorEdges {
    param($Screen = $script:MonitorScreen)
    $edges = @()
    if ($null -eq $Screen) { return $edges }
    $bounds = $Screen.Bounds
    foreach ($other in [System.Windows.Forms.Screen]::AllScreens) {
        if ($null -eq $other -or $other.DeviceName -eq $Screen.DeviceName) { continue }
        $otherBounds = $other.Bounds
        $verticalOverlap = ($otherBounds.Bottom -gt $bounds.Top) -and ($otherBounds.Top -lt $bounds.Bottom)
        $horizontalOverlap = ($otherBounds.Right -gt $bounds.Left) -and ($otherBounds.Left -lt $bounds.Right)
        if ($verticalOverlap -and [Math]::Abs($otherBounds.Right - $bounds.Left) -le 2) { $edges += 'left' }
        if ($verticalOverlap -and [Math]::Abs($otherBounds.Left - $bounds.Right) -le 2) { $edges += 'right' }
        if ($horizontalOverlap -and [Math]::Abs($otherBounds.Bottom - $bounds.Top) -le 2) { $edges += 'top' }
        if ($horizontalOverlap -and [Math]::Abs($otherBounds.Top - $bounds.Bottom) -le 2) { $edges += 'bottom' }
    }
    return @($edges | Select-Object -Unique)
}

function Test-InternalDockEdge {
    param([string]$Edge)
    if ([string]::IsNullOrWhiteSpace($Edge)) { return $false }
    return @(Get-InternalMonitorEdges -Screen $script:MonitorScreen) -contains $Edge
}

function Get-WorkAreaRect {
    if ($null -eq $script:MonitorArea) {
        $script:MonitorArea = Get-MonitorWorkAreaFromWindow -Primary
    }
    return $script:MonitorArea
}

function Update-MonitorAreaFromWindow {
    $script:MonitorArea = Get-MonitorWorkAreaFromWindow
    return $script:MonitorArea
}

function Get-DockedLeft {
    param([Parameter(Mandatory = $true)]$Area, [Parameter(Mandatory = $true)][string]$Edge, [bool]$Hidden = $false)
    if ($Edge -eq 'left') {
        if ($Hidden) { return [Math]::Round($Area.Left - $script:Window.Width + $script:EdgePeekWidth) }
        return [Math]::Round($Area.Left - 6)
    }
    if ($Hidden) { return [Math]::Round($Area.Right - $script:EdgePeekWidth) }
    return [Math]::Round($Area.Right - $script:Window.Width + 6)
}

function Get-DockedTop {
    param([Parameter(Mandatory = $true)]$Area, [Parameter(Mandatory = $true)][string]$Edge, [bool]$Hidden = $false)
    if ($Edge -eq 'top') {
        if ($Hidden) { return [Math]::Round($Area.Top - $script:Window.Height + $script:EdgePeekWidth) }
        return [Math]::Round($Area.Top - 6)
    }
    if ($Edge -eq 'bottom') { return [Math]::Round($Area.Bottom - $script:Window.Height + 6) }
    return $null
}

function Test-HideableEdge {
    if ($script:DockedEdge -ne 'left' -and $script:DockedEdge -ne 'right' -and $script:DockedEdge -ne 'top') { return $false }
    return -not (Test-InternalDockEdge -Edge $script:DockedEdge)
}

function Get-CursorPosition {
    try {
        $point = New-Object 'PomoInsightNative.NativeCursor+POINT'
        if ([PomoInsightNative.NativeCursor]::GetCursorPos([ref]$point)) {
            return [pscustomobject]@{ X = [int]$point.X; Y = [int]$point.Y }
        }
    } catch { }
    return $null
}

function Test-CursorInsideMainWindow {
    if ($null -eq $script:Window) { return $false }
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($script:Window)
        $handle = $helper.Handle
        if ($handle -eq [IntPtr]::Zero) { return [bool]$script:Window.IsMouseOver }
        $rect = New-Object 'PomoInsightNative.NativeCursor+RECT'
        if (-not [PomoInsightNative.NativeCursor]::GetWindowRect($handle, [ref]$rect)) { return [bool]$script:Window.IsMouseOver }
        $cursor = Get-CursorPosition
        if ($null -eq $cursor) { return [bool]$script:Window.IsMouseOver }
        return ($cursor.X -ge $rect.Left -and $cursor.X -lt $rect.Right -and $cursor.Y -ge $rect.Top -and $cursor.Y -lt $rect.Bottom)
    } catch {
        return [bool]$script:Window.IsMouseOver
    }
}

function Update-CursorBaseline {
    $position = Get-CursorPosition
    if ($null -eq $position) { return $false }
    $moved = $false
    if ($null -ne $script:LastCursorX -and $null -ne $script:LastCursorY) {
        $moved = ([Math]::Abs([int]$position.X - [int]$script:LastCursorX) -ge 2) -or
                 ([Math]::Abs([int]$position.Y - [int]$script:LastCursorY) -ge 2)
    }
    $script:LastCursorX = [int]$position.X
    $script:LastCursorY = [int]$position.Y
    return $moved
}

function Reset-CursorBaseline {
    $position = Get-CursorPosition
    if ($null -ne $position) {
        $script:LastCursorX = [int]$position.X
        $script:LastCursorY = [int]$position.Y
    }
}

function Get-MainWindowWidth {
    if ($script:Expanded) { return 390 }
    return 360
}

function Get-MainWindowHeight {
    if ($script:Expanded) { return 650 }
    if ($null -ne $script:ActiveSession) { return 128 }
    return 66
}

function Get-DockedLeft {
    param([Parameter(Mandatory = $true)]$Area, [Parameter(Mandatory = $true)][string]$Edge, [bool]$Hidden = $false)
    if ($Edge -eq 'left') {
        if ($Hidden) { return [Math]::Round($Area.Left - $script:Window.Width + $script:EdgePeekWidth) }
        return [Math]::Round($Area.Left - 6)
    }
    if ($Hidden) { return [Math]::Round($Area.Right - $script:EdgePeekWidth) }
    return [Math]::Round($Area.Right - $script:Window.Width + 6)
}

function Position-MainWindow {
    param([switch]$Initial)
    Stop-MainWindowLeftSlide
    if (-not $script:EdgeHidden -and $script:MiniTimerVisible) { Hide-MiniTimer }
    $area = if ($Initial) { Get-MonitorWorkAreaFromWindow -Primary } else { Get-WorkAreaRect }
    $script:MonitorArea = $area
    $oldWidth = [double]$script:Window.Width
    $oldHeight = [double]$script:Window.Height
    $oldLeft = [double]$script:Window.Left
    $oldTop = [double]$script:Window.Top
    $oldRight = $oldLeft + $oldWidth
    $oldBottom = $oldTop + $oldHeight
    $script:Window.Width = Get-MainWindowWidth
    $script:Window.Height = Get-MainWindowHeight
    if ($Initial -or $oldWidth -le 0 -or [double]::IsNaN($oldLeft) -or [double]::IsNaN($oldTop)) {
        $script:WindowAnchor = 'right'
        $script:DockedEdge = 'right'
        $script:EdgeHidden = $false
        $script:Window.Left = Get-DockedLeft -Area $area -Edge 'right' -Hidden $false
        $script:Window.Top = [Math]::Round($area.Top + (($area.Height - $script:Window.Height) / 2.0))
        return
    }

    if ($script:DockedEdge -eq 'left' -or $script:DockedEdge -eq 'right') {
        $script:Window.Left = Get-DockedLeft -Area $area -Edge $script:DockedEdge -Hidden $script:EdgeHidden
    } elseif ($script:WindowAnchor -eq 'left') {
        $script:Window.Left = $oldLeft
    } else {
        $script:Window.Left = $oldRight - $script:Window.Width
    }

    if ($script:DockedEdge -eq 'top' -or $script:DockedEdge -eq 'bottom') {
        $script:Window.Top = Get-DockedTop -Area $area -Edge $script:DockedEdge -Hidden $script:EdgeHidden
    } else {
        $script:Window.Top = $oldTop
    }

    if ($script:DockedEdge -eq 'top' -or $script:DockedEdge -eq 'bottom') {
        $minLeft = $area.Left - 6
        $maxLeft = $area.Right - $script:Window.Width + 6
        $script:Window.Left = [Math]::Max($minLeft, [Math]::Min($maxLeft, $script:Window.Left))
        $script:Window.Top = Get-DockedTop -Area $area -Edge $script:DockedEdge -Hidden $script:EdgeHidden
    } elseif ($script:DockedEdge -eq 'left' -or $script:DockedEdge -eq 'right') {
        $minTop = $area.Top
        $maxTop = $area.Bottom - $script:Window.Height
        $script:Window.Top = [Math]::Max($minTop, [Math]::Min($maxTop, $script:Window.Top))
    } elseif (-not $script:EdgeHidden) {
        $minLeft = $area.Left - 6
        $maxLeft = $area.Right - $script:Window.Width + 6
        $script:Window.Left = [Math]::Max($minLeft, [Math]::Min($maxLeft, $script:Window.Left))
        $minTop = $area.Top
        $maxTop = $area.Bottom - $script:Window.Height
        $script:Window.Top = [Math]::Max($minTop, [Math]::Min($maxTop, $script:Window.Top))
    }
}

function Position-ReminderWindow {
    $area = Get-WorkAreaRect
    $script:ReminderWindow.Left = [Math]::Round($area.Right - $script:ReminderWindow.Width - 10)
    $script:ReminderWindow.Top = [Math]::Round($area.Bottom - $script:ReminderWindow.Height - 10)
}

function Position-MiniTimerWindow {
    $area = Get-WorkAreaRect
    $script:MiniTimerWindow.Left = [Math]::Round($area.Left + (($area.Width - $script:MiniTimerWindow.Width) / 2.0))
    $script:MiniTimerWindow.Top = [Math]::Round($area.Top)
}

function Set-MiniTimerClickThrough {
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:MiniTimerWindow
        $handle = $helper.Handle
        if ($handle -eq [IntPtr]::Zero) { return }
        $style = [PomoInsightNative.NativeWindow]::GetWindowLong($handle, -20)
        $style = $style -bor 0x20 -bor 0x80 -bor 0x08000000
        [void][PomoInsightNative.NativeWindow]::SetWindowLong($handle, -20, $style)
    } catch { }
}

function Update-MiniTimer {
    param([double]$Seconds, [bool]$InBreak = $false)
    if ($null -eq $script:MiniTimerWindow) { return }
    $script:MiniTimerText.Text = Format-Clock -Seconds $Seconds
    $script:MiniTimerDot.Fill = if ($InBreak) { $script:WarnBrush } else { $script:AccentBrush }
}

function Update-MiniTimerFromSession {
    if ($null -eq $script:ActiveSession) { return }
    $now = [DateTimeOffset]::Now
    if ($script:InBreak) {
        $elapsed = 0.0
        if ($null -ne $script:BreakStartedAt) { $elapsed = [Math]::Max(0.0, ($now - $script:BreakStartedAt).TotalSeconds) }
        else { $elapsed = Get-SessionBreakSeconds -Session $script:ActiveSession -Now $now }
        Update-MiniTimer -Seconds $elapsed -InBreak $true
    } else {
        Update-MiniTimer -Seconds (Get-SessionWorkSeconds -Session $script:ActiveSession -Now $now)
    }
}

function Show-MiniTimer {
    if ($script:BreakPrivacyHidden) {
        Hide-MiniTimer
        return
    }
    if ($null -eq $script:ActiveSession -or $null -eq $script:DockedEdge -or -not $script:EdgeHidden) {
        Hide-MiniTimer
        return
    }
    Update-MiniTimerFromSession
    Position-MiniTimerWindow
    if (-not $script:MiniTimerVisible) {
        $script:MiniTimerWindow.ShowActivated = $false
        $script:MiniTimerWindow.Show()
        $script:MiniTimerVisible = $true
        Set-MiniTimerClickThrough
    }
}

function Hide-MiniTimer {
    if ($null -ne $script:MiniTimerWindow -and $script:MiniTimerVisible) { $script:MiniTimerWindow.Hide() }
    $script:MiniTimerVisible = $false
}

function Set-EdgePeekPlacement {
    if ($script:DockedEdge -eq 'left') {
        $script:EdgePeek.Width = 4
        $script:EdgePeek.Height = [double]::NaN
        $script:EdgePeek.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $script:EdgePeek.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
        $script:EdgePeek.Margin = New-Object System.Windows.Thickness(0, 22, 4, 22)
    } elseif ($script:DockedEdge -eq 'right') {
        $script:EdgePeek.Width = 4
        $script:EdgePeek.Height = [double]::NaN
        $script:EdgePeek.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $script:EdgePeek.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
        $script:EdgePeek.Margin = New-Object System.Windows.Thickness(4, 22, 0, 22)
    } else {
        $script:EdgePeek.Width = [double]::NaN
        $script:EdgePeek.Height = 4
        $script:EdgePeek.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
        $script:EdgePeek.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
        $script:EdgePeek.Margin = New-Object System.Windows.Thickness(22, 0, 22, 4)
    }
}

function Update-MainWindowBaseVisibility {
    if ($null -eq $script:CompactView -or $null -eq $script:ExpandedView) { return }
    if ($script:EdgeHidden) {
        # Keep the compact tree measured while parked off-screen, otherwise the
        # first reveal frame pays a full re-layout and the slide visibly jumps.
        $script:ExpandedView.Visibility = [System.Windows.Visibility]::Collapsed
        $script:CompactView.Visibility = [System.Windows.Visibility]::Visible
        $script:CompactView.Opacity = 0
        $script:CompactView.IsHitTestVisible = $false
        return
    }
    $script:CompactView.Opacity = 1
    $script:CompactView.IsHitTestVisible = $true
    if ($script:Expanded) {
        $script:CompactView.Visibility = [System.Windows.Visibility]::Collapsed
        $script:ExpandedView.Visibility = [System.Windows.Visibility]::Visible
    } else {
        $script:CompactView.Visibility = [System.Windows.Visibility]::Visible
        $script:ExpandedView.Visibility = [System.Windows.Visibility]::Collapsed
    }
}

function Show-EdgePeek {
    Set-EdgePeekPlacement
    $script:EdgePeek.Visibility = [System.Windows.Visibility]::Visible
    Update-MainWindowBaseVisibility
}

function Hide-EdgePeek {
    $script:EdgePeek.Visibility = [System.Windows.Visibility]::Collapsed
    Update-MainWindowBaseVisibility
}

function Stop-MainWindowLeftSlide {
    $script:SlideActive = $false
    if ($null -ne $script:SuspendedShellEffect) {
        try { $script:WindowShell.Effect = $script:SuspendedShellEffect } catch { }
        $script:SuspendedShellEffect = $null
    }
}

function Update-MainWindowLeftSlideTick {
    if (-not $script:SlideActive) { return }
    $ms = $script:SlideWatch.Elapsed.TotalMilliseconds
    if (-not $script:SlideStarted) {
        $script:SlideStarted = $true
        $script:SlideLastMs = $ms
        return
    }
    $dt = $ms - $script:SlideLastMs
    $script:SlideLastMs = $ms
    if ($dt -le 0) { return }
    # A stalled frame must not eat a whole chunk of the slide, otherwise the
    # window visibly teleports. Cap the step and let the slide take longer.
    if ($dt -gt 26) { $dt = 26 }
    $script:SlideElapsed += $dt
    $progress = [Math]::Min(1.0, $script:SlideElapsed / $script:SlideDuration)
    $eased = 0.5 - (0.5 * [Math]::Cos([Math]::PI * $progress))
    try { $script:Window.Left = $script:SlideFrom + (($script:SlideTo - $script:SlideFrom) * $eased) } catch { }
    if ($progress -ge 1) {
        Stop-MainWindowLeftSlide
        try { $script:Window.Left = $script:SlideTo } catch { }
    }
}

function Set-MainWindowLeftAnimated {
    param([double]$Target, [int]$DurationMs = 280)
    if ($null -eq $script:Window) { return }
    Stop-MainWindowLeftSlide
    $script:Window.BeginAnimation([System.Windows.Window]::LeftProperty, $null)
    $current = [double]$script:Window.Left
    if ($script:UiSmokeTest) {
        $script:Window.Left = $Target
        return
    }
    if ([double]::IsNaN($current) -or [Math]::Abs($current - $Target) -lt 1) {
        $script:Window.Left = $Target
        return
    }
    $script:SlideFrom = $current
    $script:SlideTo = $Target
    $script:SlideDuration = [Math]::Max(90.0, [double]$DurationMs)
    $script:SlideElapsed = 0.0
    $script:SlideStarted = $false
    $script:SlideActive = $true
    $script:SlideWatch = [System.Diagnostics.Stopwatch]::StartNew()
    # The layered window re-rasterises its drop shadow on every content change,
    # which stalls frames mid-slide. Drop it for the duration of the slide.
    if ($null -ne $script:WindowShell -and $null -ne $script:WindowShell.Effect) {
        $script:SuspendedShellEffect = $script:WindowShell.Effect
        $script:WindowShell.Effect = $null
    }
    if (-not $script:SlideHandlerRegistered) {
        $script:SlideHandlerRegistered = $true
        $script:SlideTickHandler = { Update-MainWindowLeftSlideTick }
        [System.Windows.Media.CompositionTarget]::add_Rendering($script:SlideTickHandler)
    }
}

function Hide-MainWindowToEdge {
    if ($null -eq $script:ActiveSession -or $script:BreakPrivacyHidden) { return }
    if (-not (Test-HideableEdge) -or $script:EdgeHidden) { return }
    if ($script:Expanded -or $script:SettingsOpen) { return }
    $area = Get-WorkAreaRect
    $script:EdgeHidden = $true
    $script:EdgeRevealBlockedUntil = [DateTimeOffset]::Now.AddMilliseconds(400)
    Show-EdgePeek
    Show-MiniTimer
    if ($script:DockedEdge -eq 'top') {
        $script:Window.Top = Get-DockedTop -Area $area -Edge 'top' -Hidden $true
    } else {
        Set-MainWindowLeftAnimated -Target (Get-DockedLeft -Area $area -Edge $script:DockedEdge -Hidden $true)
    }
}

function Reveal-MainWindowFromEdge {
    if (-not $script:EdgeHidden) { return }
    $area = Get-WorkAreaRect
    $script:EdgeHidden = $false
    $script:EdgeHideBlockedUntil = [DateTimeOffset]::Now.AddMilliseconds(500)
    Hide-EdgePeek
    Hide-MiniTimer
    if ($script:DockedEdge -eq 'top') {
        $script:Window.Top = Get-DockedTop -Area $area -Edge 'top' -Hidden $false
    } else {
        Set-MainWindowLeftAnimated -Target (Get-DockedLeft -Area $area -Edge $script:DockedEdge -Hidden $false)
    }
}

function Focus-IdleWindow {
    if ($null -ne $script:ActiveSession -or $null -eq $script:Window -or $script:Exiting) { return }
    $script:EdgeHidden = $false
    Hide-EdgePeek
    Hide-MiniTimer
    if (-not $script:Window.IsVisible) {
        $script:Window.ShowActivated = $false
        $script:Window.Show()
    }
    $script:Window.Topmost = $true
    Position-MainWindow
    if (-not $UiSmokeTest) {
        try { $script:Window.Activate() | Out-Null } catch { }
        if (-not $script:Expanded -and $null -ne $script:TaskTextBox) {
            $script:SuppressHistoryPopupOnce = $true
            $script:TaskTextBox.Focus() | Out-Null
            $script:TaskTextBox.CaretIndex = $script:TaskTextBox.Text.Length
        }
    }
}

function Initialize-TrayIcon {
    if ($null -ne $script:TrayIcon) { return }
    try {
        $script:TrayIconBitmap = New-Object System.Drawing.Bitmap -ArgumentList 32, 32
        $graphics = [System.Drawing.Graphics]::FromImage($script:TrayIconBitmap)
        $accentBrush = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(255, 99, 230, 190))
        $inkBrush = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(255, 12, 20, 23))
        try {
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.FillEllipse($accentBrush, 1, 1, 30, 30)
            $points = [System.Drawing.Point[]]@(
                (New-Object System.Drawing.Point -ArgumentList 12, 8),
                (New-Object System.Drawing.Point -ArgumentList 12, 24),
                (New-Object System.Drawing.Point -ArgumentList 25, 16)
            )
            $graphics.FillPolygon($inkBrush, $points)
        } finally {
            $accentBrush.Dispose()
            $inkBrush.Dispose()
            $graphics.Dispose()
        }
        $script:TrayIconHandle = $script:TrayIconBitmap.GetHicon()
        $script:TrayIconImage = [System.Drawing.Icon]::FromHandle($script:TrayIconHandle)
        $script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $settingsItem = $script:TrayMenu.Items.Add('设置')
        $settingsItem.Add_Click({ Show-PomoInsightFromTray; Open-Settings })
        $exitItem = $script:TrayMenu.Items.Add('关闭程序')
        $exitItem.Add_Click({ Request-Exit })
        $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
        $script:TrayIcon.Icon = $script:TrayIconImage
        $script:TrayIcon.Text = '番茄洞察 · 工作节奏追踪器'
        $script:TrayIcon.ContextMenuStrip = $script:TrayMenu
        $script:TrayIcon.Add_MouseUp({
            param($sender, $eventArgs)
            if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-PomoInsightFromTray }
        })
        $script:TrayIcon.Add_DoubleClick({ Show-PomoInsightFromTray })
        $script:TrayIcon.Visible = $true
    } catch {
        Write-PomoInsightLog -Root $script:DataRoot -Message ('Tray icon failed: ' + $_.Exception.Message)
        Dispose-TrayIcon
    }
}

function Dispose-TrayIcon {
    try { if ($null -ne $script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } } catch { }
    try { if ($null -ne $script:TrayMenu) { $script:TrayMenu.Dispose() } } catch { }
    try { if ($null -ne $script:TrayIconImage) { $script:TrayIconImage.Dispose() } } catch { }
    try { if ($null -ne $script:TrayIconBitmap) { $script:TrayIconBitmap.Dispose() } } catch { }
    if ($script:TrayIconHandle -ne [IntPtr]::Zero) {
        try { [void][PomoInsightNative.NativeIcon]::DestroyIcon($script:TrayIconHandle) } catch { }
    }
    $script:TrayIcon = $null
    $script:TrayMenu = $null
    $script:TrayIconImage = $null
    $script:TrayIconBitmap = $null
    $script:TrayIconHandle = [IntPtr]::Zero
}

function Show-PomoInsightFromTray {
    if ($script:Exiting -or $null -eq $script:Window) { return }
    if ($script:BreakPrivacyHidden) { Restore-BreakFromPrivacy }
    $script:EdgeHidden = $false
    Hide-EdgePeek
    Hide-MiniTimer
    if (-not $script:Window.IsVisible) {
        $script:Window.ShowActivated = $true
        $script:Window.Show()
    }
    $script:Window.Topmost = if ($null -eq $script:ActiveSession) { $true } else { [bool]$script:Settings.alwaysOnTop }
    Position-MainWindow
    try { $script:Window.Activate() | Out-Null } catch { }
    if ($script:InBreak) {
        $script:ReminderMode = 'break'
        Update-ReminderWindowContent
        Show-ReminderWindow
    } elseif (-not $script:Expanded -and $null -eq $script:ActiveSession -and $null -ne $script:TaskTextBox) {
        $script:SuppressHistoryPopupOnce = $true
        $script:TaskTextBox.Focus() | Out-Null
        $script:TaskTextBox.CaretIndex = $script:TaskTextBox.Text.Length
    }
}

function Stop-EdgeHideTimer {
    if ($null -ne $script:EdgeHideTimer) { $script:EdgeHideTimer.Stop() }
}

function Start-EdgeHideTimer {
    param([double]$DelaySeconds = 0.10)
    if ($null -eq $script:EdgeHideTimer) {
        $script:EdgeHideTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:EdgeHideTimer.Add_Tick({
            $script:EdgeHideTimer.Stop()
            $now = [DateTimeOffset]::Now
            if ($now -lt $script:EdgeHideBlockedUntil) {
                Start-EdgeHideTimer -DelaySeconds ([Math]::Max(0.08, ($script:EdgeHideBlockedUntil - $now).TotalSeconds + 0.03))
                return
            }
            if ($null -eq $script:ActiveSession -or $script:BreakPrivacyHidden) { return }
            if ($script:EdgeHidden) { return }
            if (-not (Test-HideableEdge)) { return }
            if ($script:Expanded -or $script:SettingsOpen -or $script:IsDragging) { return }
            if (Test-CursorInsideMainWindow) {
                Start-EdgeHideTimer -DelaySeconds 0.20
                return
            }
            Hide-MainWindowToEdge
        })
    }
    $script:EdgeHideTimer.Stop()
    $script:EdgeHideTimer.Interval = [TimeSpan]::FromSeconds([Math]::Max(0.04, $DelaySeconds))
    $script:EdgeHideTimer.Start()
}

function Snap-MainWindowToEdge {
    if ($null -eq $script:Window) { return }
    $area = Update-MonitorAreaFromWindow
    $left = [double]$script:Window.Left
    $top = [double]$script:Window.Top
    $width = [double]$script:Window.Width
    $height = [double]$script:Window.Height
    $leftGap = [Math]::Max(0.0, $left - $area.Left)
    $rightGap = [Math]::Max(0.0, $area.Right - ($left + $width))
    $topGap = [Math]::Max(0.0, $top - $area.Top)
    $bottomGap = [Math]::Max(0.0, $area.Bottom - ($top + $height))
    $threshold = 42
    $bestEdge = $null
    $internalEdges = @(Get-InternalMonitorEdges -Screen $script:MonitorScreen)
    $candidates = @(
        [pscustomobject]@{ Edge = 'left'; Gap = $leftGap },
        [pscustomobject]@{ Edge = 'right'; Gap = $rightGap },
        [pscustomobject]@{ Edge = 'top'; Gap = $topGap },
        [pscustomobject]@{ Edge = 'bottom'; Gap = $bottomGap }
    ) | Sort-Object Gap
    foreach ($candidate in $candidates) {
        if ($internalEdges -contains $candidate.Edge) { continue }
        if ($candidate.Gap -le $threshold) {
            $bestEdge = $candidate.Edge
            break
        }
    }

    $script:EdgeHidden = $false
    Hide-EdgePeek
    Hide-MiniTimer
    $center = $left + ($width / 2.0)
    if ($center -lt ($area.Left + ($area.Width / 2.0))) { $script:WindowAnchor = 'left' } else { $script:WindowAnchor = 'right' }

    if ($bestEdge -eq 'left') {
        $script:DockedEdge = 'left'
        $script:WindowAnchor = 'left'
        $script:Window.Left = Get-DockedLeft -Area $area -Edge 'left' -Hidden $false
        $script:Window.Top = [Math]::Max($area.Top, [Math]::Min($area.Bottom - $height, $top))
    } elseif ($bestEdge -eq 'right') {
        $script:DockedEdge = 'right'
        $script:WindowAnchor = 'right'
        $script:Window.Left = Get-DockedLeft -Area $area -Edge 'right' -Hidden $false
        $script:Window.Top = [Math]::Max($area.Top, [Math]::Min($area.Bottom - $height, $top))
    } elseif ($bestEdge -eq 'top') {
        $script:DockedEdge = 'top'
        $script:Window.Top = Get-DockedTop -Area $area -Edge 'top'
        $script:Window.Left = [Math]::Max($area.Left - 6, [Math]::Min($area.Right - $width + 6, $left))
    } elseif ($bestEdge -eq 'bottom') {
        $script:DockedEdge = 'bottom'
        $script:Window.Top = Get-DockedTop -Area $area -Edge 'bottom'
        $script:Window.Left = [Math]::Max($area.Left - 6, [Math]::Min($area.Right - $width + 6, $left))
    } else {
        $script:DockedEdge = $null
        $script:Window.Left = [Math]::Max($area.Left - 6, [Math]::Min($area.Right - $width + 6, $left))
        $script:Window.Top = [Math]::Max($area.Top, [Math]::Min($area.Bottom - $height, $top))
    }

    if ($null -ne $script:ActiveSession -and (Test-HideableEdge) -and -not $script:Expanded -and -not $script:SettingsOpen) {
        Start-EdgeHideTimer -DelaySeconds 0.35
    } else {
        Stop-EdgeHideTimer
    }
}

function Test-InteractiveSource {
    param($Source)
    $dep = $Source
    while ($null -ne $dep) {
        if ($dep -is [System.Windows.Controls.Button] -or
            $dep -is [System.Windows.Controls.TextBox] -or
            $dep -is [System.Windows.Controls.CheckBox] -or
            $dep -is [System.Windows.Controls.Primitives.ScrollBar] -or
            $dep -is [System.Windows.Controls.Primitives.RepeatButton] -or
            $dep -is [System.Windows.Controls.Primitives.Thumb]) { return $true }
        if ($dep -eq $script:Window) { break }
        try { $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep) } catch { break }
    }
    return $false
}

function Test-SourceWithinElement {
    param($Source, $Target)
    if ($null -eq $Target) { return $false }
    $node = $Source
    while ($null -ne $node) {
        if ($node -eq $Target) { return $true }
        if ($node -eq $script:Window) { break }
        try { $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node) } catch { break }
    }
    return $false
}

function Start-WindowDrag {
    param($Sender, $EventArgs)
    if ($script:IsDragging) { return }
    if (Test-InteractiveSource -Source $EventArgs.OriginalSource) { return }
    Hide-RecentTasksPopup
    $script:IsDragging = $true
    Stop-EdgeHideTimer
    Stop-MainWindowLeftSlide
    try { $script:Window.DragMove() }
    catch { }
    finally {
        $script:IsDragging = $false
        Snap-MainWindowToEdge
    }
}

function Set-CompactStatus {
    param([string]$Text, $Brush = $null, [switch]$Force)
    if ($null -eq $script:CompactStatusText) { return }
    if (-not $Force -and $script:StatusResetAt -gt [DateTimeOffset]::Now) { return }
    if ($null -eq $Brush) { $Brush = $script:TextMutedBrush }
    $script:CompactStatusText.Text = $Text
    $script:CompactStatusText.Foreground = $Brush
    if ($null -ne $script:CompactDot) { $script:CompactDot.Fill = $Brush }
}

function Set-HeaderDefault {
    if ($script:StatusResetAt -gt [DateTimeOffset]::Now) { return }
    if ($script:SettingsOpen) {
        $script:HeaderStatusText.Text = 'SETTINGS'
        $script:HeaderStatusText.Foreground = $script:TextMutedBrush
        $script:HeaderDot.Fill = $script:TextMutedBrush
    } elseif ($script:InBreak) {
        $script:HeaderStatusText.Text = 'REST'
        $script:HeaderStatusText.Foreground = $script:AccentBrush
        $script:HeaderDot.Fill = $script:AccentBrush
    } elseif ($null -ne $script:ActiveSession) {
        $script:HeaderStatusText.Text = 'FOCUS'
        $script:HeaderStatusText.Foreground = $script:AccentBrush
        $script:HeaderDot.Fill = $script:AccentBrush
    } elseif ($script:Expanded) {
        $script:HeaderStatusText.Text = 'TODAY'
        $script:HeaderStatusText.Foreground = $script:AccentBrush
        $script:HeaderDot.Fill = $script:AccentBrush
    } else {
        $script:HeaderStatusText.Text = 'POMO'
        $script:HeaderStatusText.Foreground = $script:AccentBrush
        $script:HeaderDot.Fill = $script:AccentBrush
    }
}

function Show-TransientStatus {
    param([string]$Text, [bool]$Good = $true)
    $brush = if ($Good) { $script:AccentBrush } else { $script:DangerBrush }
    $script:HeaderStatusText.Text = $Text
    $script:HeaderStatusText.Foreground = $brush
    $script:HeaderDot.Fill = $brush
    Set-CompactStatus -Text $Text -Brush $brush -Force
    $script:StatusResetAt = [DateTimeOffset]::Now.AddSeconds(4)
}

function Set-Expanded {
    param([bool]$Value)
    Register-Interaction
    Hide-RecentTasksPopup
    $script:Expanded = $Value
    if ($Value) {
        Stop-EdgeHideTimer
        if ($script:EdgeHidden) {
            $script:EdgeHidden = $false
            Hide-EdgePeek
        }
        Hide-MiniTimer
        $script:CompactView.Visibility = [System.Windows.Visibility]::Collapsed
        $script:ExpandedView.Visibility = [System.Windows.Visibility]::Visible
    } else {
        $script:CompactView.Visibility = [System.Windows.Visibility]::Visible
        $script:ExpandedView.Visibility = [System.Windows.Visibility]::Collapsed
        $script:SettingsOpen = $false
    }
    Position-MainWindow
    Update-StaticUi
    Update-LiveUi
    if (-not $Value) {
        if ($null -eq $script:ActiveSession) { Focus-IdleWindow }
        elseif (Test-HideableEdge) { Start-EdgeHideTimer -DelaySeconds 0.45 }
    }
}

function Show-ReminderWindow {
    Position-ReminderWindow
    $script:ReminderWindow.Topmost = $true
    if (-not $script:ReminderVisible) {
        $script:ReminderWindow.ShowActivated = $false
        $script:ReminderWindow.Show()
        $script:ReminderVisible = $true
    }
}

function Hide-ReminderWindow {
    if ($script:ReminderVisible) { $script:ReminderWindow.Hide() }
    $script:ReminderVisible = $false
    $script:ReminderMode = $null
    $script:EyeAutoCloseAt = $null
}

function Hide-BreakForPrivacy {
    if (-not $script:InBreak -or $script:BreakPrivacyHidden) { return }
    $script:BreakPrivacyAt = $null
    $script:BreakPrivacyHidden = $true
    Stop-EdgeHideTimer
    Hide-RecentTasksPopup
    if ($script:Expanded -or $script:SettingsOpen) {
        Set-Expanded $false
        Stop-EdgeHideTimer
    }
    Hide-ReminderWindow
    Hide-MiniTimer
    Stop-MainWindowLeftSlide
    $script:EdgeHidden = $false
    Hide-EdgePeek
    if ($null -ne $script:Window) { $script:Window.Hide() }
    Reset-CursorBaseline
    Write-PomoInsightLog -Root $script:DataRoot -Message 'Break privacy hide after 30 seconds'
}

function Restore-BreakFromPrivacy {
    if (-not $script:BreakPrivacyHidden) { return }
    $script:BreakPrivacyHidden = $false
    $script:EdgeHidden = $false
    Hide-EdgePeek
    Position-MainWindow
    $script:Window.Topmost = $true
    $script:Window.ShowActivated = $false
    if (-not $script:Window.IsVisible) { $script:Window.Show() }
    if ($script:InBreak) {
        $script:ReminderMode = 'break'
        Update-ReminderWindowContent
        Show-ReminderWindow
    }
    Reset-CursorBaseline
    Write-PomoInsightLog -Root $script:DataRoot -Message 'Break privacy window restored by mouse activity'
}

function Update-ReminderWindowContent {
    $now = [DateTimeOffset]::Now
    if ($script:ReminderMode -eq 'break') {
        $script:CloseButton.Visibility = [System.Windows.Visibility]::Collapsed
        $script:EndSessionButton.Visibility = [System.Windows.Visibility]::Visible
        $script:EndSessionButton.Content = '结束并保存'
        $script:PrimaryActionButton.Content = '继续工作'
        $script:SecondaryActionButton.Visibility = [System.Windows.Visibility]::Collapsed
        $elapsed = 0.0
        if ($null -ne $script:BreakStartedAt) { $elapsed = [Math]::Max(0.0, ($now - $script:BreakStartedAt).TotalSeconds) }
        elseif ($null -ne $script:ActiveSession) { $elapsed = Get-SessionBreakSeconds -Session $script:ActiveSession -Now $now }
        $suggestedSeconds = [double]$script:Settings.breakMinutes * 60.0
        if ($elapsed -ge $suggestedSeconds) {
            $script:ModeTitleText.Text = '休息够了，可以继续'
        } else {
            $script:ModeTitleText.Text = '休息中'
        }
        $script:ModeBigText.Text = Format-Clock -Seconds $elapsed
        $script:ModeSubText.Text = ('建议休息 {0} 分钟，已经休息 {1}。可以继续休息，准备好后点“继续工作”；休息时间不计入工作。' -f [int]$script:Settings.breakMinutes, (Format-DurationShort -Seconds $elapsed))
        $script:StatusDot.Fill = $script:AccentBrush
    } elseif ($script:ReminderMode -eq 'break_prompt') {
        $script:CloseButton.Visibility = [System.Windows.Visibility]::Visible
        $script:EndSessionButton.Visibility = [System.Windows.Visibility]::Visible
        $script:EndSessionButton.Content = '结束'
        $script:SecondaryActionButton.Visibility = [System.Windows.Visibility]::Visible
        $script:PrimaryActionButton.Content = ('休息 {0} 分钟' -f $script:Settings.breakMinutes)
        $snooze = if ($script:IsStrongReminder) { 5 } else { $script:Settings.snoozeMinutes }
        $script:SecondaryActionButton.Content = ('再工作 {0} 分钟' -f $snooze)
        if ($script:IsStrongReminder) {
            $script:StatusDot.Fill = $script:WarnBrush
            $script:ModeTitleText.Text = '已经专注很久了'
        } else {
            $script:StatusDot.Fill = $script:AccentBrush
            $script:ModeTitleText.Text = '该休息一下了'
        }
    } elseif ($script:ReminderMode -eq 'eye') {
        $script:CloseButton.Visibility = [System.Windows.Visibility]::Visible
        $script:EndSessionButton.Visibility = [System.Windows.Visibility]::Collapsed
        $script:SecondaryActionButton.Visibility = [System.Windows.Visibility]::Visible
        $script:PrimaryActionButton.Content = '完成'
        $script:SecondaryActionButton.Content = '稍后 5 分钟'
        $script:StatusDot.Fill = $script:AccentBrush
    }
}

function Show-BreakReminder {
    if ($null -eq $script:ActiveSession -or $script:InBreak) { return }
    $now = [DateTimeOffset]::Now
    $focusStart = $script:FocusSegmentStart
    if ($null -eq $focusStart) { $focusStart = $now }
    $elapsedMin = [Math]::Max(0.0, ($now - $focusStart).TotalMinutes)
    $script:IsStrongReminder = ($elapsedMin -ge [double]$script:Settings.maxFocusMinutes)
    $rounded = [int][Math]::Floor($elapsedMin)
    $script:ReminderMode = 'break_prompt'
    $script:ModeBigText.Text = ('{0} 分钟' -f $rounded)
    $task = [string]$script:ActiveSession.task
    if ($script:IsStrongReminder) {
        $script:ModeSubText.Text = ('你已经连续专注 {0} 分钟（{1}）。已经超过健康护栏，建议现在离开屏幕活动 5-10 分钟。' -f $rounded, $task)
    } else {
        $script:ModeSubText.Text = ('你已经连续专注 {0} 分钟（{1}）。起身、喝水，或看向 6 米外 20 秒。' -f $rounded, $task)
    }
    Update-ReminderWindowContent
    Add-SessionEvent -Session $script:ActiveSession -Type 'reminder' -At $now -Minutes $rounded | Out-Null
    Save-ActiveSession -Root $script:DataRoot -Session $script:ActiveSession
    Show-ReminderWindow
    Update-LiveUi
}

function Show-EyeReminder {
    if ($null -eq $script:ActiveSession -or $script:InBreak) { return }
    $now = [DateTimeOffset]::Now
    $script:ReminderMode = 'eye'
    $script:ModeTitleText.Text = '护眼轻提醒'
    $script:ModeBigText.Text = '20 秒'
    $script:ModeSubText.Text = '20-20-20：把视线移到 6 米外，保持 20 秒，顺便眨几次眼。不用离开当前任务。'
    $script:StatusDot.Fill = $script:AccentBrush
    Update-ReminderWindowContent
    Add-SessionEvent -Session $script:ActiveSession -Type 'eye_reminder' -At $now -Minutes 0 | Out-Null
    $script:NextEyeReminderAt = $now.AddMinutes(20)
    $script:EyeAutoCloseAt = $now.AddSeconds(15)
    Show-ReminderWindow
}

function Start-Break {
    if ($null -eq $script:ActiveSession -or $script:InBreak) { return }
    $now = [DateTimeOffset]::Now
    $break = [pscustomobject]@{
        startedAt = $now.ToString('o')
        startedAtUnixMs = (Get-EpochMs -Value $now)
        endedAt = $null
        endedAtUnixMs = $null
        durationSeconds = $null
        plannedMinutes = [int]$script:Settings.breakMinutes
        completed = $false
        source = 'reminder_or_user'
    }
    $script:ActiveSession.breaks = @($script:ActiveSession.breaks) + $break
    $script:ActiveSession.breakCount = @($script:ActiveSession.breaks).Count
    Add-SessionEvent -Session $script:ActiveSession -Type 'break_start' -At $now -Minutes ([int]$script:Settings.breakMinutes) | Out-Null
    $script:InBreak = $true
    $script:BreakStartedAt = $now
    $script:BreakPlannedEnd = $now.AddMinutes([int]$script:Settings.breakMinutes)
    $script:BreakPrivacyAt = $now.AddSeconds(30)
    $script:BreakPrivacyHidden = $false
    Reset-CursorBaseline
    $script:NextReminderAt = $null
    $script:ReminderMode = 'break'
    $script:EyeAutoCloseAt = $null
    Update-ReminderWindowContent
    Show-ReminderWindow
    Save-ActiveSession -Root $script:DataRoot -Session $script:ActiveSession
    Set-HeaderDefault
    Set-Expanded $false
    Update-LiveUi
    Write-PomoInsightLog -Root $script:DataRoot -Message 'Break started'
}

function End-Break {
    if (-not $script:InBreak -or $null -eq $script:ActiveSession) { return }
    if ($script:BreakPrivacyHidden) { Restore-BreakFromPrivacy }
    $now = [DateTimeOffset]::Now
    $breaks = @($script:ActiveSession.breaks)
    for ($i = $breaks.Count - 1; $i -ge 0; $i--) {
        $br = $breaks[$i]
        if ($null -ne $br -and [string]::IsNullOrWhiteSpace([string]$br.endedAt)) {
            $start = ConvertTo-DateTimeOffsetValue -Value $br.startedAt -UnixMs ([long]$br.startedAtUnixMs)
            $br.endedAt = $now.ToString('o')
            $br.endedAtUnixMs = (Get-EpochMs -Value $now)
            if ($null -ne $start) { $br.durationSeconds = [int][Math]::Round(($now - $start).TotalSeconds) }
            $br.completed = $true
            break
        }
    }
    $script:ActiveSession.breaks = @($breaks)
    $script:ActiveSession.breakCount = @($breaks).Count
    Add-SessionEvent -Session $script:ActiveSession -Type 'break_end' -At $now | Out-Null
    $script:InBreak = $false
    $script:BreakStartedAt = $null
    $script:BreakPlannedEnd = $null
    $script:BreakPrivacyAt = $null
    $script:BreakPrivacyHidden = $false
    $script:FocusSegmentStart = $now
    $script:NextReminderAt = $now.AddMinutes([int]$script:Settings.focusMinutes)
    if ($script:Settings.eyeReminder) { $script:NextEyeReminderAt = $now.AddMinutes(20) }
    Hide-ReminderWindow
    $script:Window.Topmost = [bool]$script:Settings.alwaysOnTop
    Save-ActiveSession -Root $script:DataRoot -Session $script:ActiveSession
    Set-HeaderDefault
    Update-LiveUi
    Write-PomoInsightLog -Root $script:DataRoot -Message 'Break ended'
}

function Snooze-Reminder {
    $now = [DateTimeOffset]::Now
    if ($script:ReminderMode -eq 'break_prompt') {
        $minutes = if ($script:IsStrongReminder) { 5 } else { [int]$script:Settings.snoozeMinutes }
        $script:NextReminderAt = $now.AddMinutes($minutes)
        Add-SessionEvent -Session $script:ActiveSession -Type 'snooze' -At $now -Minutes $minutes | Out-Null
        Save-ActiveSession -Root $script:DataRoot -Session $script:ActiveSession
        Hide-ReminderWindow
        Update-LiveUi
        return
    }
    if ($script:ReminderMode -eq 'break') {
        $script:BreakPlannedEnd = $script:BreakPlannedEnd.AddMinutes(5)
        Add-SessionEvent -Session $script:ActiveSession -Type 'break_extend' -At $now -Minutes 5 | Out-Null
        Save-ActiveSession -Root $script:DataRoot -Session $script:ActiveSession
        Update-ReminderWindowContent
        return
    }
    if ($script:ReminderMode -eq 'eye') {
        Add-SessionEvent -Session $script:ActiveSession -Type 'eye_snooze' -At $now -Minutes 5 | Out-Null
        $script:NextEyeReminderAt = $now.AddMinutes(5)
        Hide-ReminderWindow
    }
}

function Start-Work {
    Register-Interaction
    if ($null -ne $script:ActiveSession) { return }
    $task = $script:TaskTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($task)) {
        Show-TransientStatus -Text '请先填写工作内容' -Good $false
        $script:TaskTextBox.Focus() | Out-Null
        return
    }
    Hide-RecentTasksPopup
    $now = [DateTimeOffset]::Now
    $script:LastTickAt = $now
    $script:ActiveSession = New-PomoInsightSession -Task $task -StartedAt $now
    $script:Window.Topmost = [bool]$script:Settings.alwaysOnTop
    $script:FocusSegmentStart = $now
    $script:NextReminderAt = $now.AddMinutes([int]$script:Settings.focusMinutes)
    $script:NextEyeReminderAt = if ($script:Settings.eyeReminder) { $now.AddMinutes(20) } else { $null }
    $script:InBreak = $false
    $script:BreakStartedAt = $null
    $script:BreakPlannedEnd = $null
    $script:BreakPrivacyAt = $null
    $script:BreakPrivacyHidden = $false
    $script:LastHeartbeatWrite = $now
    Save-ActiveSession -Root $script:DataRoot -Session $script:ActiveSession
    $script:TaskTextBox.Text = ''
    $script:UiTimer.Interval = [TimeSpan]::FromSeconds(1)
    if (-not $script:UiTimer.IsEnabled) { $script:UiTimer.Start() }
    Set-Expanded $false
    Set-HeaderDefault
    Update-StaticUi
    Update-LiveUi
    Write-PomoInsightLog -Root $script:DataRoot -Message ("Session started: " + $task)
}

function Stop-Work {
    param([string]$Reason = 'manual')
    Register-Interaction
    if ($null -eq $script:ActiveSession) { return }
    $session = $script:ActiveSession
    $now = [DateTimeOffset]::Now
    if ($script:InBreak) {
        Add-SessionEvent -Session $session -Type 'break_end' -At $now -Note 'session_stop' | Out-Null
        $script:InBreak = $false
    }
    Complete-PomoInsightSession -Session $session -EndedAt $now -Reason $Reason | Out-Null
    $script:Sessions = @($script:Sessions) + $session
    Save-PomoInsightSessions -Root $script:DataRoot -Sessions @($script:Sessions)
    Remove-ActiveSession -Root $script:DataRoot
    $minutes = [int][Math]::Round(([double]$session.workSeconds) / 60.0)
    $script:TaskTextBox.Text = [string]$session.task
    $script:ActiveSession = $null
    $script:FocusSegmentStart = $null
    $script:NextReminderAt = $null
    $script:NextEyeReminderAt = $null
    $script:BreakStartedAt = $null
    $script:BreakPlannedEnd = $null
    $script:BreakPrivacyAt = $null
    $script:BreakPrivacyHidden = $false
    Hide-ReminderWindow
    Hide-MiniTimer
    $script:UiTimer.Interval = [TimeSpan]::FromSeconds(30)
    Focus-IdleWindow
    Set-HeaderDefault
    Update-StaticUi
    Update-LiveUi
    Show-TransientStatus -Text ("已保存 {0} 分钟" -f $minutes) -Good $true
    Write-PomoInsightLog -Root $script:DataRoot -Message ("Session ended: {0} min, reason {1}" -f $minutes, $Reason)
}

function Format-TodayDuration {
    param([double]$Seconds)
    if ($Seconds -le 0) { return '0m' }
    if ($Seconds -lt 60) { return '<1m' }
    return (Format-DurationShort -Seconds $Seconds)
}

function Update-TodayCard {
    $now = [DateTimeOffset]::Now
    $today = $now.ToString('yyyy-MM-dd')
    $summary = Get-TodaySummary -Sessions $script:Sessions
    $work = [double]$summary.workSeconds
    $breakSeconds = [double]$summary.breakSeconds
    $sessions = [int]$summary.sessions
    $breaks = [int]$summary.breakCount
    $longest = 0.0
    foreach ($item in @($script:Sessions)) {
        if ($null -eq $item -or -not [bool]$item.completed) { continue }
        if ([string]$item.localDate -ne $today) { continue }
        $value = [double]$item.longestFocusSeconds
        if ($value -gt $longest) { $longest = $value }
    }
    if ($null -ne $script:ActiveSession -and [string]$script:ActiveSession.localDate -eq $today) {
        $work += Get-SessionWorkSeconds -Session $script:ActiveSession -Now $now
        $breakSeconds += Get-SessionBreakSeconds -Session $script:ActiveSession -Now $now
        $sessions++
        $breaks += @($script:ActiveSession.breaks).Count
        $activeFocus = Get-LongestFocusSeconds -Session $script:ActiveSession -Now $now
        if ($activeFocus -gt $longest) { $longest = $activeFocus }
    }
    $script:TodayWorkText.Text = Format-TodayDuration -Seconds $work
    $script:TodayBreakText.Text = Format-TodayDuration -Seconds $breakSeconds
    $script:TodaySessionsText.Text = [string]$sessions
    $script:TodayLongestText.Text = Format-TodayDuration -Seconds $longest
    $weekNames = @('周日', '周一', '周二', '周三', '周四', '周五', '周六')
    $script:TodayDateText.Text = ('{0}年{1}月{2}日 {3}' -f $now.Year, $now.Month, $now.Day, $weekNames[[int]$now.DayOfWeek])
}

function Get-FilteredRecentTasks {
    $tasks = @(Get-RecentTasks -Sessions $script:Sessions -Limit 8)
    $filter = ''
    if ($null -ne $script:TaskTextBox) { $filter = ([string]$script:TaskTextBox.Text).Trim() }
    if (-not [string]::IsNullOrWhiteSpace($filter)) {
        $tasks = @($tasks | Where-Object {
            ([string]$_).IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        })
    }
    return $tasks
}

function Hide-RecentTasksPopup {
    if ($null -ne $script:RecentTasksPopup -and $script:RecentTasksPopup.IsOpen) {
        $script:RecentTasksPopup.IsOpen = $false
    }
}

function Show-RecentTasksPopup {
    if ($null -eq $script:RecentTasksPopup -or $null -eq $script:TaskTextBox) { return }
    if ($null -ne $script:ActiveSession -or $script:Expanded -or $script:SettingsOpen) {
        Hide-RecentTasksPopup
        return
    }
    $filter = ([string]$script:TaskTextBox.Text).Trim()
    if ($script:RecentTasksPopup.IsOpen -and $script:HistoryPopupFilter -eq $filter) { return }
    $count = Refresh-RecentTasks
    if ($count -le 0) {
        Hide-RecentTasksPopup
        return
    }
    if ($script:RecentTasksPopup.IsOpen) { return }
    $inputWidth = [double]$script:TaskTextBox.ActualWidth
    if ($inputWidth -lt 220 -or [double]::IsNaN($inputWidth)) { $inputWidth = 252 }
    $script:RecentTasksPopupShell.Width = $inputWidth
    $script:RecentTasksPopup.IsOpen = $true
}

function Refresh-RecentTasks {
    if ($null -eq $script:RecentTasksPanel) { return 0 }
    $script:RecentTasksPanel.Children.Clear()
    $tasks = @(Get-FilteredRecentTasks)
    $script:HistoryPopupFilter = ([string]$script:TaskTextBox.Text).Trim()
    foreach ($task in $tasks) {
        $button = New-Object System.Windows.Controls.Button
        $button.Tag = $task
        $button.Style = $script:Window.FindResource('HistoryItemButton')
        $button.ToolTip = '填入工作内容'
        $content = New-Object System.Windows.Controls.Grid
        $iconColumn = New-Object System.Windows.Controls.ColumnDefinition
        $iconColumn.Width = [System.Windows.GridLength]::Auto
        [void]$content.ColumnDefinitions.Add($iconColumn)
        [void]$content.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $icon = New-Object System.Windows.Controls.TextBlock
        $icon.Text = '↺'
        $icon.FontSize = 13
        $icon.Foreground = $script:TextMutedBrush
        $icon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $icon.Margin = New-Object System.Windows.Thickness(0, 0, 9, 0)
        $content.Children.Add($icon) | Out-Null
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = [string]$task
        $label.FontSize = 11.5
        $label.Foreground = $script:TextMainBrush
        $label.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Controls.Grid]::SetColumn($label, 1)
        $content.Children.Add($label) | Out-Null
        $button.Content = $content
        $button.Add_Click({
            param($sender, $eventArgs)
            $script:SuppressHistoryPopupOnce = $true
            $script:TaskTextBox.Text = [string]$sender.Tag
            Hide-RecentTasksPopup
            $script:TaskTextBox.Focus() | Out-Null
            $script:TaskTextBox.CaretIndex = $script:TaskTextBox.Text.Length
        })
        $script:RecentTasksPanel.Children.Add($button) | Out-Null
    }
    return $tasks.Count
}

function Refresh-RecentSessions {
    $script:RecentSessionsPanel.Children.Clear()
    $today = [DateTimeOffset]::Now.ToString('yyyy-MM-dd')
    $recent = @($script:Sessions | Where-Object {
        $null -ne $_ -and [bool]$_.completed -and [string]$_.localDate -eq $today
    } | Sort-Object { [long]$_.endedAtUnixMs } -Descending)
    $script:EmptySessionsText.Visibility = if ($recent.Count -eq 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    if ($recent.Count -eq 0) {
        if ($null -ne $script:ActiveSession -and [string]$script:ActiveSession.localDate -eq $today) {
            $script:EmptySessionsText.Text = '当前工作段结束后会出现在这里。'
        } else {
            $script:EmptySessionsText.Text = '今天还没有工作记录。收起后在上方输入工作内容即可开始。'
        }
    }
    foreach ($session in $recent) {
        $border = New-Object System.Windows.Controls.Border
        $border.CornerRadius = New-Object System.Windows.CornerRadius(11)
        $border.Background = New-Brush '#0DFFFFFF'
        $border.BorderBrush = New-Brush '#16FFFFFF'
        $border.BorderThickness = New-Object System.Windows.Thickness(1)
        $border.Padding = New-Object System.Windows.Thickness(11, 9, 11, 9)
        $border.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
        $grid = New-Object System.Windows.Controls.Grid
        [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $rightCol = New-Object System.Windows.Controls.ColumnDefinition
        $rightCol.Width = [System.Windows.GridLength]::Auto
        [void]$grid.ColumnDefinitions.Add($rightCol)

        $left = New-Object System.Windows.Controls.StackPanel
        $taskText = New-Object System.Windows.Controls.TextBlock
        $taskText.Text = [string]$session.task
        $taskText.FontSize = 11.5
        $taskText.Foreground = $script:TextMainBrush
        $taskText.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $taskText.ToolTip = [string]$session.task
        $left.Children.Add($taskText) | Out-Null

        $metaText = New-Object System.Windows.Controls.TextBlock
        $started = ConvertTo-DateTimeOffsetValue -Value $session.startedAt -UnixMs ([long]$session.startedAtUnixMs)
        $ended = ConvertTo-DateTimeOffsetValue -Value $session.endedAt -UnixMs ([long]$session.endedAtUnixMs)
        if ($null -ne $started -and $null -ne $ended) {
            $metaText.Text = ('{0} - {1} · 休息 {2} 次' -f $started.ToString('HH:mm'), $ended.ToString('HH:mm'), [int]$session.breakCount)
        } else {
            $metaText.Text = [string]$session.localDate
        }
        $metaText.FontSize = 9.5
        $metaText.Foreground = $script:TextMutedBrush
        $metaText.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
        $left.Children.Add($metaText) | Out-Null
        $grid.Children.Add($left) | Out-Null

        $durationText = New-Object System.Windows.Controls.TextBlock
        $durationText.Text = Format-DurationShort -Seconds ([double]$session.workSeconds)
        $durationText.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
        $durationText.FontSize = 14
        $durationText.FontWeight = [System.Windows.FontWeights]::SemiBold
        $durationText.Foreground = $script:AccentBrush
        $durationText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $durationText.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
        [System.Windows.Controls.Grid]::SetColumn($durationText, 1)
        $grid.Children.Add($durationText) | Out-Null

        $border.Child = $grid
        $script:RecentSessionsPanel.Children.Add($border) | Out-Null
    }
}

function Update-TaskInputState {
    if ($null -eq $script:TaskTextBox) { return }
    $hasText = -not [string]::IsNullOrWhiteSpace($script:TaskTextBox.Text)
    $script:TaskPlaceholder.Visibility = if ($hasText) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
    $script:StartButton.IsEnabled = $hasText -and ($null -eq $script:ActiveSession)
}

function Update-StaticUi {
    if ($script:SettingsOpen) {
        $script:NormalContent.Visibility = [System.Windows.Visibility]::Collapsed
        $script:SettingsPanel.Visibility = [System.Windows.Visibility]::Visible
        $script:ExportBar.Visibility = [System.Windows.Visibility]::Collapsed
    } else {
        $script:NormalContent.Visibility = [System.Windows.Visibility]::Visible
        $script:SettingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $script:ExportBar.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($null -ne $script:ActiveSession) {
        $script:CompactIdlePanel.Visibility = [System.Windows.Visibility]::Collapsed
        $script:CompactActivePanel.Visibility = [System.Windows.Visibility]::Visible
        $script:ExpandedActivePanel.Visibility = [System.Windows.Visibility]::Visible
    } else {
        $script:CompactIdlePanel.Visibility = [System.Windows.Visibility]::Visible
        $script:CompactActivePanel.Visibility = [System.Windows.Visibility]::Collapsed
        $script:ExpandedActivePanel.Visibility = [System.Windows.Visibility]::Collapsed
    }
    Update-TodayCard
    Refresh-RecentTasks
    Refresh-RecentSessions
    Set-HeaderDefault
    Update-TaskInputState
    Update-DataLocationUi
    Update-PresetStatus
}

function Update-LiveUi {
    $now = [DateTimeOffset]::Now
    if ($null -ne $script:ActiveSession) {
        $workSeconds = Get-SessionWorkSeconds -Session $script:ActiveSession -Now $now
        $start = ConvertTo-DateTimeOffsetValue -Value $script:ActiveSession.startedAt -UnixMs ([long]$script:ActiveSession.startedAtUnixMs)
        $startText = if ($null -ne $start) { ('{0} 开始' -f $start.ToString('HH:mm')) } else { '' }
        $task = [string]$script:ActiveSession.task
        if ($script:InBreak) {
            $elapsed = 0.0
            if ($null -ne $script:BreakStartedAt) { $elapsed = [Math]::Max(0.0, ($now - $script:BreakStartedAt).TotalSeconds) }
            else { $elapsed = Get-SessionBreakSeconds -Session $script:ActiveSession -Now $now }
            $suggestedSeconds = [double]$script:Settings.breakMinutes * 60.0
            $enough = $elapsed -ge $suggestedSeconds
            $restText = Format-DurationShort -Seconds $elapsed
            Set-CompactStatus -Text $(if ($enough) { '休息够了，可以继续' } else { '休息中' }) -Brush $script:AccentBrush
            $script:CompactTaskText.Text = $task
            $script:CompactStartedText.Text = ('建议休息 {0} 分钟' -f [int]$script:Settings.breakMinutes)
            $script:CompactTimerText.Text = Format-Clock -Seconds $elapsed
            $script:CompactModeText.Text = if ($enough) { '已达建议时长' } else { ('已休息 ' + $restText) }
            $script:TakeBreakButton.Content = '继续工作'
            $script:StopButton.Content = '结束'
            $script:ExpandedModeText.Text = if ($enough) { '休息够了，可以继续' } else { '休息中' }
            $script:ExpandedStartedText.Text = ('建议 {0} 分钟' -f [int]$script:Settings.breakMinutes)
            $script:ExpandedTaskText.Text = $task
            $script:ExpandedTimerText.Text = Format-Clock -Seconds $elapsed
            $script:ExpandedReminderHintText.Text = ('已经休息 {0}，可以继续休息；准备好后点“继续工作”。休息时间不计入工作。' -f $restText)
            $script:ExpandedTakeBreakButton.Content = '继续工作'
            $script:ExpandedStopButton.Content = '结束并保存'
            Update-MiniTimer -Seconds $elapsed -InBreak $true
        } else {
            $focusStart = $script:FocusSegmentStart
            if ($null -eq $focusStart) { $focusStart = $now }
            $focusSeconds = [Math]::Max(0.0, ($now - $focusStart).TotalSeconds)
            $focusMinutes = $focusSeconds / 60.0
            $focusText = Format-DurationShort -Seconds $focusSeconds
            Set-CompactStatus -Text $(if ($startText) { '专注中 · ' + $startText } else { '专注中' }) -Brush $script:AccentBrush
            $script:CompactTaskText.Text = $task
            $script:CompactStartedText.Text = $startText
            $script:CompactTimerText.Text = Format-Clock -Seconds $workSeconds
            $script:CompactModeText.Text = ('专注 ' + $focusText)
            $script:TakeBreakButton.Content = '现在休息'
            $script:StopButton.Content = '结束'

            $hint = ''
            if ($null -ne $script:NextReminderAt) {
                $remainMin = [Math]::Ceiling(($script:NextReminderAt - $now).TotalMinutes)
                if ($remainMin -gt 0) {
                    $hint = ('下一次休息提醒：{0} 分钟后 · 已专注 {1}' -f $remainMin, $focusText)
                } else {
                    $hint = ('休息提醒已到 · 已连续专注 {0}' -f $focusText)
                }
            }
            if ($focusMinutes -ge [double]$script:Settings.focusMinutes) {
                $maxFocus = [int]$script:Settings.maxFocusMinutes
                $toGuardrail = [Math]::Max(0, [int][Math]::Ceiling([double]$maxFocus - $focusMinutes))
                if ($focusMinutes -ge [double]$maxFocus) {
                    $hint = ('已超过 {0} 分钟健康护栏，建议现在休息。' -f $maxFocus)
                } else {
                    $hint = ('已主动延续专注 · 距健康护栏还有 {0} 分钟' -f $toGuardrail)
                }
            }
            $script:ExpandedModeText.Text = '正在专注'
            $script:ExpandedStartedText.Text = $startText
            $script:ExpandedTaskText.Text = $task
            $script:ExpandedTimerText.Text = Format-Clock -Seconds $workSeconds
            $script:ExpandedReminderHintText.Text = $hint
            $script:ExpandedTakeBreakButton.Content = '现在休息'
            $script:ExpandedStopButton.Content = '结束并保存'
            Update-MiniTimer -Seconds $workSeconds
        }
        Update-TodayCard
    } else {
        $today = Get-TodaySummary -Sessions $script:Sessions
        $todayText = if ($today.workSeconds -gt 0) { Format-DurationShort -Seconds ([double]$today.workSeconds) } else { '0m' }
        Set-CompactStatus -Text ('准备开始 · 今日 {0}' -f $todayText) -Brush $script:TextMutedBrush
        $script:CompactTaskText.Text = ''
        $script:CompactStartedText.Text = ''
        $script:CompactTimerText.Text = '00:00:00'
        $script:CompactModeText.Text = ''
        $script:ExpandedTaskText.Text = ''
        $script:ExpandedTimerText.Text = '00:00:00'
        $script:ExpandedReminderHintText.Text = ''
        Hide-MiniTimer
        Update-TodayCard
        Update-TaskInputState
    }
}

function Get-ReminderPresetLabel {
    $focus = [int]$script:Settings.focusMinutes
    $break = [int]$script:Settings.breakMinutes
    $snooze = [int]$script:Settings.snoozeMinutes
    $maxFocus = [int]$script:Settings.maxFocusMinutes
    if ($focus -eq 25 -and $break -eq 5 -and $snooze -eq 5 -and $maxFocus -eq 50) { return '番茄 25/5' }
    if ($focus -eq 50 -and $break -eq 10 -and $snooze -eq 10 -and $maxFocus -eq 90) { return '平衡 50/10' }
    if ($focus -eq 52 -and $break -eq 17 -and $snooze -eq 10 -and $maxFocus -eq 104) { return '52/17 观察' }
    return '自定义'
}

function Update-PresetStatus {
    if ($null -eq $script:PresetStatusText) { return }
    $label = Get-ReminderPresetLabel
    $script:PresetStatusText.Text = '当前：' + $label
    if ($null -eq $script:PresetDescriptionText) { return }
    switch ($label) {
        '番茄 25/5' {
            $script:PresetDescriptionText.Text = '番茄模式：25 分钟专注 + 5 分钟休息。适合任务边界清晰、容易被消息打断的工作，也适合刚开始练习专注节奏时使用。'
        }
        '平衡 50/10' {
            $script:PresetDescriptionText.Text = '平衡模式：50 分钟专注 + 10 分钟休息。适合需要连续推进的开发、写作和深度阅读，在专注深度与休息频率之间取平衡。'
        }
        '52/17 观察' {
            $script:PresetDescriptionText.Text = '观察模式：52 分钟专注 + 17 分钟休息，来自 DeskTime 的观察数据。适合想对照更长的休息间隔、观察自己恢复效率时使用。'
        }
        default {
            $script:PresetDescriptionText.Text = '自定义模式：当前专注、休息、延后和护栏数值由你手动设定。适合已经了解自己的工作节奏、想微调提醒频率时使用。'
        }
    }
}

function Update-DataLocationUi {
    if ($null -eq $script:DataLocationText) { return }
    $script:DataLocationText.Text = $script:DataRoot
    $script:DataLocationText.ToolTip = $script:DataRoot
}

function ConvertTo-NormalizedFolderPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $full = [System.IO.Path]::GetFullPath($Path.Trim())
    if ($full.Length -gt 3) { return $full.TrimEnd('\') }
    return $full
}

function Open-Settings {
    $script:SettingsOpen = $true
    Set-Expanded $true
    $script:FocusMinutesBox.Text = [string]$script:Settings.focusMinutes
    $script:BreakMinutesBox.Text = [string]$script:Settings.breakMinutes
    $script:SnoozeMinutesBox.Text = [string]$script:Settings.snoozeMinutes
    $script:MaxFocusMinutesBox.Text = [string]$script:Settings.maxFocusMinutes
    $script:EyeReminderCheckBox.IsChecked = [bool]$script:Settings.eyeReminder
    $script:AlwaysOnTopCheckBox.IsChecked = [bool]$script:Settings.alwaysOnTop
    $script:AutoStartCheckBox.IsChecked = Test-PomoInsightAutoStart
    Update-DataLocationUi
    Update-PresetStatus
    Update-StaticUi
}

function Close-Settings {
    $script:SettingsOpen = $false
    Update-StaticUi
}

function Apply-ReminderPreset {
    param([ValidateSet('pomodoro', 'balanced', 'observe')][string]$Name)
    switch ($Name) {
        'pomodoro' { $focus = 25; $break = 5; $snooze = 5; $maxFocus = 50; $label = '番茄 25/5' }
        'observe' { $focus = 52; $break = 17; $snooze = 10; $maxFocus = 104; $label = '52/17 观察' }
        default { $focus = 50; $break = 10; $snooze = 10; $maxFocus = 90; $label = '平衡 50/10' }
    }
    $script:FocusMinutesBox.Text = [string]$focus
    $script:BreakMinutesBox.Text = [string]$break
    $script:SnoozeMinutesBox.Text = [string]$snooze
    $script:MaxFocusMinutesBox.Text = [string]$maxFocus
    Save-Settings -KeepOpen -StatusText ('已切换：' + $label)
}

function Save-Settings {
    param([switch]$KeepOpen, [string]$StatusText = '设置已保存')
    $focus = 0
    $break = 0
    $snooze = 0
    $maxFocus = 0
    $ok = [int]::TryParse($script:FocusMinutesBox.Text.Trim(), [ref]$focus) -and
          [int]::TryParse($script:BreakMinutesBox.Text.Trim(), [ref]$break) -and
          [int]::TryParse($script:SnoozeMinutesBox.Text.Trim(), [ref]$snooze) -and
          [int]::TryParse($script:MaxFocusMinutesBox.Text.Trim(), [ref]$maxFocus)
    if (-not $ok -or $focus -lt 10 -or $focus -gt 180 -or $break -lt 1 -or $break -gt 60 -or $snooze -lt 1 -or $snooze -gt 30 -or $maxFocus -lt 20 -or $maxFocus -gt 240) {
        [System.Windows.MessageBox]::Show('请输入有效范围：专注提醒 10-180，休息 1-60，延后 1-30，最长专注 20-240。', '番茄洞察', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    if ($maxFocus -lt $focus) { $maxFocus = $focus }
    $wantAuto = [bool]$script:AutoStartCheckBox.IsChecked
    try {
        Set-PomoInsightAutoStart -Enabled $wantAuto -ScriptPath (Join-Path $script:AppRoot 'PomoInsight.ps1') | Out-Null
    } catch {
        Write-PomoInsightLog -Root $script:DataRoot -Message ('Auto-start failed: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show('开机自启设置失败。可以继续使用，之后再用设置重试。', '番茄洞察', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        $wantAuto = Test-PomoInsightAutoStart
    }
    $newSettings = [pscustomobject]@{
        focusMinutes = $focus
        breakMinutes = $break
        snoozeMinutes = $snooze
        maxFocusMinutes = $maxFocus
        eyeReminder = [bool]$script:EyeReminderCheckBox.IsChecked
        autoStart = $wantAuto
        alwaysOnTop = [bool]$script:AlwaysOnTopCheckBox.IsChecked
    }
    $script:Settings = $newSettings
    Save-PomoInsightSettings -Root $script:DataRoot -Settings $newSettings
    $script:Window.Topmost = if ($null -eq $script:ActiveSession) { $true } else { [bool]$newSettings.alwaysOnTop }
    $script:ReminderWindow.Topmost = $true
    if ($null -ne $script:ActiveSession) {
        if (-not $script:InBreak -and $null -ne $script:FocusSegmentStart) {
            $script:NextReminderAt = $script:FocusSegmentStart.AddMinutes($focus)
        }
        if ($newSettings.eyeReminder -and $null -eq $script:NextEyeReminderAt) { $script:NextEyeReminderAt = [DateTimeOffset]::Now.AddMinutes(20) }
        if (-not $newSettings.eyeReminder) { $script:NextEyeReminderAt = $null }
    }
    if (-not $KeepOpen) { $script:SettingsOpen = $false }
    Update-StaticUi
    Update-LiveUi
    Update-PresetStatus
    Show-TransientStatus -Text $StatusText -Good $true
}

function Select-DataStorageLocation {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择番茄洞察数据存储文件夹'
    $dialog.ShowNewFolderButton = $true
    if (Test-Path -LiteralPath $script:DataRoot) { $dialog.SelectedPath = $script:DataRoot }
    $selected = ''
    $owner = $null
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window
        if ($helper.Handle -ne [IntPtr]::Zero) {
            $owner = New-Object System.Windows.Forms.NativeWindow
            $owner.AssignHandle($helper.Handle)
        }
        $result = if ($null -ne $owner) { $dialog.ShowDialog($owner) } else { $dialog.ShowDialog() }
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $selected = $dialog.SelectedPath }
    } finally {
        if ($null -ne $owner) { try { $owner.ReleaseHandle() } catch { } }
        $dialog.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($selected)) { return }

    $target = ConvertTo-NormalizedFolderPath -Path $selected
    $current = ConvertTo-NormalizedFolderPath -Path $script:DataRoot
    if ([string]::Equals($target, $current, [System.StringComparison]::OrdinalIgnoreCase)) {
        Show-TransientStatus -Text '已经在使用这个目录' -Good $false
        return
    }
    if ((Test-Path -LiteralPath (Join-Path $target 'sessions.json')) -or (Test-Path -LiteralPath (Join-Path $target 'settings.json'))) {
        $answer = [System.Windows.MessageBox]::Show('目标目录已有番茄洞察数据。继续会覆盖目标目录中的 settings.json 和 sessions.json，是否继续？', '番茄洞察', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    try {
        $oldRoot = $script:DataRoot
        Copy-PomoInsightData -Source $oldRoot -Destination $target | Out-Null
        Set-PomoInsightConfiguredRoot -Root $target
        $script:DataRoot = $target
        Initialize-PomoInsightStorage -Root $script:DataRoot
        $oldActive = Join-Path $oldRoot 'active-session.json'
        if (Test-Path -LiteralPath $oldActive) { Remove-Item -LiteralPath $oldActive -Force }
        if ($null -ne $script:ActiveSession) {
            Save-ActiveSession -Root $script:DataRoot -Session $script:ActiveSession
        }
        Save-PomoInsightSettings -Root $script:DataRoot -Settings $script:Settings
        Update-DataLocationUi
        Write-PomoInsightLog -Root $script:DataRoot -Message ('Data root changed from ' + $oldRoot + ' to ' + $target)
        Show-TransientStatus -Text '存储位置已更新' -Good $true
    } catch {
        Write-PomoInsightLog -Root $script:DataRoot -Message ('Data root change failed: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show(('更改存储位置失败：' + $_.Exception.Message), '番茄洞察', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
}

function Show-FileInExplorer {
    param([string]$Path)
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $Path) | Out-Null
}

function Select-ExportPath {
    param([ValidateSet('json', 'csv', 'brief')][string]$Kind)
    $stamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')
    if ($Kind -eq 'json') {
        $extension = 'json'
        $fileName = ('PomoInsight_{0}.json' -f $stamp)
        $filter = 'JSON 文件 (*.json)|*.json|所有文件 (*.*)|*.*'
        $title = '导出番茄洞察 JSON'
    } elseif ($Kind -eq 'csv') {
        $extension = 'csv'
        $fileName = ('PomoInsight_{0}.csv' -f $stamp)
        $filter = 'CSV 文件 (*.csv)|*.csv|所有文件 (*.*)|*.*'
        $title = '导出番茄洞察 CSV'
    } else {
        $extension = 'md'
        $fileName = ('PomoInsight_AI_Prompt_{0}.md' -f $stamp)
        $filter = 'Markdown 文件 (*.md)|*.md|文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*'
        $title = '导出 AI 解读提示词'
    }
    $initialDir = $script:LastExportDirectory
    if ([string]::IsNullOrWhiteSpace($initialDir) -or -not (Test-Path -LiteralPath $initialDir)) {
        $initialDir = [Environment]::GetFolderPath('MyDocuments')
    }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = $title
    $dialog.Filter = $filter
    $dialog.DefaultExt = $extension
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true
    $dialog.FileName = $fileName
    if (-not [string]::IsNullOrWhiteSpace($initialDir)) { $dialog.InitialDirectory = $initialDir }
    $confirmed = $false
    try { $confirmed = [bool]$dialog.ShowDialog($script:Window) }
    catch { $confirmed = [bool]$dialog.ShowDialog() }
    if (-not $confirmed) { return $null }
    $path = $dialog.FileName
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    if ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($path))) { $path = $path + '.' + $extension }
    return [System.IO.Path]::GetFullPath($path)
}

function Export-Data {
    param([ValidateSet('json', 'csv', 'brief')][string]$Kind)
    try {
        $path = Select-ExportPath -Kind $Kind
        if ([string]::IsNullOrWhiteSpace($path)) { return }
        if ($Kind -eq 'json') {
            $path = Export-PomoInsightData -Root $script:DataRoot -Format json -OutputPath $path
            Show-TransientStatus -Text 'JSON 已导出' -Good $true
        } elseif ($Kind -eq 'csv') {
            $path = Export-PomoInsightData -Root $script:DataRoot -Format csv -OutputPath $path
            Show-TransientStatus -Text 'CSV 已导出' -Good $true
        } else {
            $path = Export-PomoInsightAnalysisBrief -Root $script:DataRoot -OutputPath $path
            Show-TransientStatus -Text '提示词已导出' -Good $true
        }
        $script:LastExportDirectory = Split-Path -Parent $path
        Show-FileInExplorer -Path $path
        Write-PomoInsightLog -Root $script:DataRoot -Message ('Exported ' + $Kind + ': ' + $path)
    } catch {
        Write-PomoInsightLog -Root $script:DataRoot -Message ('Export failed: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show(('导出失败：' + $_.Exception.Message), '番茄洞察', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
}

function Open-DataFolder {
    Start-Process -FilePath 'explorer.exe' -ArgumentList $script:DataRoot | Out-Null
}

function Request-Exit {
    if ($script:Exiting -or $script:ExitPromptOpen) { return }
    if ($null -ne $script:ActiveSession) {
        $script:ExitPromptOpen = $true
        try {
            $answer = [System.Windows.MessageBox]::Show('正在计时。退出会结束并保存当前记录。继续退出吗？', '番茄洞察', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        } finally {
            $script:ExitPromptOpen = $false
        }
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    $script:Exiting = $true
    try {
        if ($null -ne $script:ActiveSession) { Stop-Work -Reason 'app_exit' }
    } catch {
        Write-PomoInsightLog -Root $script:DataRoot -Message ('Exit save failed: ' + $_.Exception.Message)
    }
    try { Stop-EdgeHideTimer } catch { }
    try { if ($null -ne $script:UiTimer) { $script:UiTimer.Stop() } } catch { }
    try { if ($null -ne $script:ReminderWindow) { $script:ReminderWindow.Close() } } catch { }
    try { if ($null -ne $script:Window) { $script:Window.Close() } } catch { }
    try {
        $script:App.Shutdown()
    } catch {
        Write-PomoInsightLog -Root $script:DataRoot -Message ('Exit failed: ' + $_.Exception.Message)
    }
}

function On-Tick {
    if ($script:Exiting) { return }
    try {
        $now = [DateTimeOffset]::Now
        $previousTick = $script:LastTickAt
        $script:LastTickAt = $now
        $cursorMoved = Update-CursorBaseline
        if ($null -eq $script:ActiveSession -and ($now - $script:LastInteractionAt).TotalSeconds -gt 180 -and ($now - $script:LastMemoryTrim).TotalMinutes -gt 5) { Trim-WorkingSet }
        if ($script:StatusResetAt -gt [DateTimeOffset]::MinValue -and $now -ge $script:StatusResetAt) {
            $script:StatusResetAt = [DateTimeOffset]::MinValue
            Set-HeaderDefault
        }
        if ($null -ne $script:ActiveSession) {
            $tickGapSeconds = ($now - $previousTick).TotalSeconds
            if (-not $script:InBreak -and $tickGapSeconds -gt 120) {
                $gapRounded = [int][Math]::Round($tickGapSeconds)
                $gap = [pscustomobject]@{
                    startedAt = $previousTick.ToString('o')
                    startedAtUnixMs = (Get-EpochMs -Value $previousTick)
                    endedAt = $now.ToString('o')
                    endedAtUnixMs = (Get-EpochMs -Value $now)
                    durationSeconds = $gapRounded
                    reason = 'timer_gap'
                }
                $script:ActiveSession.timerGaps = @($script:ActiveSession.timerGaps) + $gap
                $script:ActiveSession.timerGapSeconds = [int]$script:ActiveSession.timerGapSeconds + $gapRounded
                $script:ActiveSession.timerGapCount = [int]$script:ActiveSession.timerGapCount + 1
                if ($null -ne $script:FocusSegmentStart) { $script:FocusSegmentStart = $script:FocusSegmentStart.AddSeconds($gapRounded) }
                if ($null -ne $script:NextReminderAt) { $script:NextReminderAt = $script:NextReminderAt.AddSeconds($gapRounded) }
                if ($null -ne $script:NextEyeReminderAt) { $script:NextEyeReminderAt = $script:NextEyeReminderAt.AddSeconds($gapRounded) }
                Add-SessionEvent -Session $script:ActiveSession -Type 'timer_gap' -At $now -Minutes ([Math]::Round($gapRounded / 60.0, 1)) -Note 'deducted_from_work' | Out-Null
                Save-ActiveSession -Root $script:DataRoot -Session $script:ActiveSession
            }
            Update-LiveUi
            if (-not $script:InBreak) {
                if ($null -ne $script:NextReminderAt -and $now -ge $script:NextReminderAt) {
                    if (-not ($script:ReminderVisible -and $script:ReminderMode -eq 'break_prompt')) { Show-BreakReminder }
                }
                if ($script:Settings.eyeReminder -and $null -ne $script:NextEyeReminderAt -and $now -ge $script:NextEyeReminderAt) {
                    if (-not ($script:ReminderVisible -and ($script:ReminderMode -eq 'break_prompt' -or $script:ReminderMode -eq 'break'))) {
                        Show-EyeReminder
                    } else {
                        $script:NextEyeReminderAt = $now.AddMinutes(20)
                    }
                }
            } else {
                if ($null -ne $script:BreakPrivacyAt -and $now -ge $script:BreakPrivacyAt) {
                    Hide-BreakForPrivacy
                } elseif ($script:BreakPrivacyHidden -and $cursorMoved) {
                    Restore-BreakFromPrivacy
                } elseif (-not $script:BreakPrivacyHidden) {
                    Update-ReminderWindowContent
                }
            }
            if ($null -ne $script:EyeAutoCloseAt -and $now -ge $script:EyeAutoCloseAt) {
                Hide-ReminderWindow
            }
            if (($now - $script:LastHeartbeatWrite).TotalSeconds -ge 30) {
                $script:ActiveSession.lastHeartbeatAt = $now.ToString('o')
                $script:ActiveSession.lastHeartbeatAtUnixMs = (Get-EpochMs -Value $now)
                Save-ActiveSession -Root $script:DataRoot -Session $script:ActiveSession
                $script:LastHeartbeatWrite = $now
            }
        } else {
            Update-LiveUi
        }
        if ($script:Expanded) { Set-HeaderDefault }
    } catch {
        Write-PomoInsightLog -Root $script:DataRoot -Message ('Tick error: ' + $_.Exception.Message)
    }
}

function Initialize-Controls {
    $w = $script:Window
    $script:WindowShell = $w.FindName('WindowShell')
    $script:CompactView = $w.FindName('CompactView')
    $script:ExpandedView = $w.FindName('ExpandedView')
    $script:EdgePeek = $w.FindName('EdgePeek')
    $script:CompactDot = $w.FindName('CompactDot')
    $script:CompactStatusText = $w.FindName('CompactStatusText')
    $script:CompactIdlePanel = $w.FindName('CompactIdlePanel')
    $script:CompactActivePanel = $w.FindName('CompactActivePanel')
    $script:TaskTextBox = $w.FindName('TaskTextBox')
    $script:TaskPlaceholder = $w.FindName('TaskPlaceholder')
    $script:StartButton = $w.FindName('StartButton')
    $script:RecentTasksPanel = $w.FindName('RecentTasksPanel')
    $script:RecentTasksPopup = $w.FindName('RecentTasksPopup')
    $script:RecentTasksPopupShell = $w.FindName('RecentTasksPopupShell')
    $script:CompactTaskText = $w.FindName('CompactTaskText')
    $script:CompactStartedText = $w.FindName('CompactStartedText')
    $script:CompactTimerText = $w.FindName('CompactTimerText')
    $script:CompactModeText = $w.FindName('CompactModeText')
    $script:TakeBreakButton = $w.FindName('TakeBreakButton')
    $script:StopButton = $w.FindName('StopButton')
    $script:ExpandButton = $w.FindName('ExpandButton')
    $script:CompactExpandButton = $w.FindName('CompactExpandButton')
    $script:ExpandChevron = $w.FindName('ExpandChevron')
    $script:HeaderDot = $w.FindName('HeaderDot')
    $script:HeaderStatusText = $w.FindName('HeaderStatusText')
    $script:SettingsButton = $w.FindName('SettingsButton')
    $script:CollapseButton = $w.FindName('CollapseButton')
    $script:NormalContent = $w.FindName('NormalContent')
    $script:SettingsPanel = $w.FindName('SettingsPanel')
    $script:ExportBar = $w.FindName('ExportBar')
    $script:ExpandedActivePanel = $w.FindName('ExpandedActivePanel')
    $script:ExpandedModeText = $w.FindName('ExpandedModeText')
    $script:ExpandedStartedText = $w.FindName('ExpandedStartedText')
    $script:ExpandedTaskText = $w.FindName('ExpandedTaskText')
    $script:ExpandedTimerText = $w.FindName('ExpandedTimerText')
    $script:ExpandedReminderHintText = $w.FindName('ExpandedReminderHintText')
    $script:ExpandedTakeBreakButton = $w.FindName('ExpandedTakeBreakButton')
    $script:ExpandedStopButton = $w.FindName('ExpandedStopButton')
    $script:TodayDateText = $w.FindName('TodayDateText')
    $script:TodayWorkText = $w.FindName('TodayWorkText')
    $script:TodayBreakText = $w.FindName('TodayBreakText')
    $script:TodaySessionsText = $w.FindName('TodaySessionsText')
    $script:TodayLongestText = $w.FindName('TodayLongestText')
    $script:RecentSessionsPanel = $w.FindName('RecentSessionsPanel')
    $script:EmptySessionsText = $w.FindName('EmptySessionsText')
    $script:FocusMinutesBox = $w.FindName('FocusMinutesBox')
    $script:BreakMinutesBox = $w.FindName('BreakMinutesBox')
    $script:SnoozeMinutesBox = $w.FindName('SnoozeMinutesBox')
    $script:MaxFocusMinutesBox = $w.FindName('MaxFocusMinutesBox')
    $script:AutoStartCheckBox = $w.FindName('AutoStartCheckBox')
    $script:EyeReminderCheckBox = $w.FindName('EyeReminderCheckBox')
    $script:AlwaysOnTopCheckBox = $w.FindName('AlwaysOnTopCheckBox')
    $script:PresetPomodoroButton = $w.FindName('PresetPomodoroButton')
    $script:PresetBalancedButton = $w.FindName('PresetBalancedButton')
    $script:PresetObserveButton = $w.FindName('PresetObserveButton')
    $script:PresetStatusText = $w.FindName('PresetStatusText')
    $script:PresetDescriptionText = $w.FindName('PresetDescriptionText')
    $script:DataLocationText = $w.FindName('DataLocationText')
    $script:ChangeDataLocationButton = $w.FindName('ChangeDataLocationButton')
    $script:SaveSettingsButton = $w.FindName('SaveSettingsButton')
    $script:CancelSettingsButton = $w.FindName('CancelSettingsButton')
    $script:OpenDataFolderButton = $w.FindName('OpenDataFolderButton')
    $script:ExitAppButton = $w.FindName('ExitAppButton')
    $script:ExportJsonButton = $w.FindName('ExportJsonButton')
    $script:ExportCsvButton = $w.FindName('ExportCsvButton')
    $script:ExportBriefButton = $w.FindName('ExportBriefButton')

    $script:TextMainBrush = New-Brush '#F4F7F8'
    $script:TextMutedBrush = New-Brush '#9AA8B2'
    $script:AccentBrush = New-Brush '#63E6BE'
    $script:DangerBrush = New-Brush '#FF7A90'
    $script:WarnBrush = New-Brush '#FFB86B'

    $r = $script:ReminderWindow
    $script:ModeTitleText = $r.FindName('ModeTitleText')
    $script:ModeBigText = $r.FindName('ModeBigText')
    $script:ModeSubText = $r.FindName('ModeSubText')
    $script:PrimaryActionButton = $r.FindName('PrimaryActionButton')
    $script:SecondaryActionButton = $r.FindName('SecondaryActionButton')
    $script:EndSessionButton = $r.FindName('EndSessionButton')
    $script:CloseButton = $r.FindName('CloseButton')
    $script:StatusDot = $r.FindName('StatusDot')

    $script:MiniTimerText = $script:MiniTimerWindow.FindName('MiniTimerText')
    $script:MiniTimerDot = $script:MiniTimerWindow.FindName('MiniTimerDot')
}

function Wire-Events {
    $script:StartButton.Add_Click({ Start-Work })
    $script:TaskTextBox.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
            Start-Work
            $eventArgs.Handled = $true
        } elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
            Hide-RecentTasksPopup
            $eventArgs.Handled = $true
        }
    })
    $script:TaskTextBox.Add_TextChanged({
        Update-TaskInputState
        if ($null -ne $script:TaskTextBox -and $script:TaskTextBox.IsKeyboardFocusWithin) { Show-RecentTasksPopup }
    })
    $script:TaskTextBox.Add_GotKeyboardFocus({
        Stop-EdgeHideTimer
        Register-Interaction
        if ($script:SuppressHistoryPopupOnce) {
            $script:SuppressHistoryPopupOnce = $false
        } else {
            Show-RecentTasksPopup
        }
    })
    $script:TaskTextBox.Add_PreviewMouseLeftButtonDown({ Show-RecentTasksPopup })
    $script:TaskTextBox.Add_LostKeyboardFocus({
        if ($null -ne $script:DockedEdge -and -not $script:Expanded) { Start-EdgeHideTimer }
        $script:TaskTextBox.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{
            if ($null -eq $script:RecentTasksPopup -or -not $script:RecentTasksPopup.IsOpen) { return }
            if ($script:TaskTextBox.IsKeyboardFocusWithin) { return }
            $overHistory = $false
            try { $overHistory = Test-SourceWithinElement -Source ([System.Windows.Input.Mouse]::DirectlyOver) -Target $script:RecentTasksPopupShell } catch { }
            if ($overHistory -or ($null -ne $script:RecentTasksPopupShell -and $script:RecentTasksPopupShell.IsMouseOver)) { return }
            Hide-RecentTasksPopup
        }) | Out-Null
    })

    $script:TakeBreakButton.Add_Click({ if ($script:InBreak) { End-Break } else { Start-Break } })
    $script:StopButton.Add_Click({ Stop-Work })
    $script:ExpandedTakeBreakButton.Add_Click({ if ($script:InBreak) { End-Break } else { Start-Break } })
    $script:ExpandedStopButton.Add_Click({ Stop-Work })

    $script:ExpandButton.Add_Click({ Hide-RecentTasksPopup; Set-Expanded $true })
    if ($null -ne $script:CompactExpandButton) { $script:CompactExpandButton.Add_Click({ Hide-RecentTasksPopup; Set-Expanded $true }) }
    $script:CollapseButton.Add_Click({ Set-Expanded $false })
    $script:SettingsButton.Add_Click({ if ($script:SettingsOpen) { Close-Settings } else { Open-Settings } })
    $script:SaveSettingsButton.Add_Click({ Save-Settings })
    $script:CancelSettingsButton.Add_Click({ Close-Settings })
    $script:PresetPomodoroButton.Add_Click({ Apply-ReminderPreset -Name 'pomodoro' })
    $script:PresetBalancedButton.Add_Click({ Apply-ReminderPreset -Name 'balanced' })
    $script:PresetObserveButton.Add_Click({ Apply-ReminderPreset -Name 'observe' })
    $script:ChangeDataLocationButton.Add_Click({ Select-DataStorageLocation })
    $script:OpenDataFolderButton.Add_Click({ Open-DataFolder })
    $script:ExitAppButton.Add_Click({ Request-Exit })
    $script:ExportJsonButton.Add_Click({ Export-Data -Kind json })
    $script:ExportCsvButton.Add_Click({ Export-Data -Kind csv })
    $script:ExportBriefButton.Add_Click({ Export-Data -Kind brief })

    $script:PrimaryActionButton.Add_Click({
        if ($script:ReminderMode -eq 'break_prompt') { Start-Break }
        elseif ($script:ReminderMode -eq 'break') { End-Break }
        elseif ($script:ReminderMode -eq 'eye') {
            if ($null -ne $script:ActiveSession) { Add-SessionEvent -Session $script:ActiveSession -Type 'eye_ack' -At ([DateTimeOffset]::Now) | Out-Null }
            Hide-ReminderWindow
        }
    })
    $script:SecondaryActionButton.Add_Click({ Snooze-Reminder })
    $script:EndSessionButton.Add_Click({ Stop-Work })
    $script:CloseButton.Add_Click({ if ($script:ReminderMode -eq 'break_prompt' -or $script:ReminderMode -eq 'eye') { Snooze-Reminder } })

    $script:Window.Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        Start-WindowDrag -Sender $sender -EventArgs $eventArgs
    })
    $script:Window.Add_MouseEnter({
        if ($script:EdgeHidden -and [DateTimeOffset]::Now -ge $script:EdgeRevealBlockedUntil) { Reveal-MainWindowFromEdge }
        if ($null -ne $script:ActiveSession -and $null -ne $script:DockedEdge -and -not $script:Expanded -and -not $script:SettingsOpen -and (Test-HideableEdge)) {
            Start-EdgeHideTimer -DelaySeconds 0.60
        } else {
            Stop-EdgeHideTimer
        }
        Register-Interaction
    })
    $script:Window.Add_MouseLeave({
        if ($null -ne $script:DockedEdge -and -not $script:Expanded -and -not $script:SettingsOpen) {
            Start-EdgeHideTimer
        }
    })
    $script:Window.Add_PreviewMouseDown({
        param($sender, $eventArgs)
        Register-Interaction
        $insideInput = Test-SourceWithinElement -Source $eventArgs.OriginalSource -Target $script:TaskTextBox
        $insideHistory = Test-SourceWithinElement -Source $eventArgs.OriginalSource -Target $script:RecentTasksPopupShell
        if ($null -ne $script:RecentTasksPopup -and $script:RecentTasksPopup.IsOpen -and -not $insideInput -and -not $insideHistory) {
            Hide-RecentTasksPopup
        }
    })
    $script:Window.Add_PreviewKeyDown({ Register-Interaction })
    $script:Window.Add_Closing({
        param($sender, $eventArgs)
        if (-not $script:Exiting) {
            $eventArgs.Cancel = $true
            # Close() is illegal while Closing is running, so let the cancelled
            # close unwind first and re-enter the exit path on the next turn.
            $script:Window.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Normal,
                [Action]{ Request-Exit }) | Out-Null
        }
    })
    $script:App.Add_SessionEnding({
        param($sender, $eventArgs)
        if (-not $script:Exiting -and $null -ne $script:ActiveSession) {
            $script:Exiting = $true
            try { Stop-Work -Reason 'shutdown' } catch { }
        }
    })
    $script:App.Add_DispatcherUnhandledException({
        param($sender, $eventArgs)
        try { Write-PomoInsightLog -Root $script:DataRoot -Message ('Unhandled: ' + $eventArgs.Exception.Message) } catch { }
        [System.Windows.MessageBox]::Show(('番茄洞察遇到错误：' + $eventArgs.Exception.Message), '番茄洞察', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        $eventArgs.Handled = $true
    })
}

function Load-XamlWindow {
    param([string]$RelativePath)
    $path = Join-Path $script:AppRoot $RelativePath
    $xml = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    return [System.Windows.Markup.XamlReader]::Parse($xml)
}

function Set-PomoInsightWindowIcon {
    param($Window)
    if ($null -eq $Window) { return }
    try {
        $path = Join-Path $script:AppRoot 'assets\pomo-insight.ico'
        if (-not (Test-Path -LiteralPath $path)) { return }
        $icon = New-Object System.Drawing.Icon -ArgumentList $path, 32, 32
        try {
            $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $icon.Handle,
                [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $source.Freeze()
            $Window.Icon = $source
        } finally {
            $icon.Dispose()
        }
    } catch { }
}

function Start-UiSmokeTest {
    $script:UiSmokeFailed = $false
    $script:SmokeStep = 0
    $script:SmokeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SmokeTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:SmokeTimer.Add_Tick({
        try {
            switch ($script:SmokeStep) {
                0 {
                    Show-RecentTasksPopup
                    if ($script:RecentTasksPopup.IsOpen) { throw 'empty history popup should stay closed' }
                    if ($null -eq $script:TrayIcon) { throw 'tray icon missing' }
                    if ($script:TrayMenu.Items.Count -ne 2) { throw 'tray menu must have exactly two items' }
                    if (($script:TrayMenu.Items[0].Text -ne '设置') -or ($script:TrayMenu.Items[1].Text -ne '关闭程序')) { throw 'tray menu labels wrong' }
                    $script:DockedEdge = 'right'
                    $script:EdgeHidden = $false
                    Hide-MainWindowToEdge
                    if ($script:EdgeHidden) { throw 'idle window was allowed to hide' }
                    $script:TaskTextBox.Text = 'UI 冒烟测试'
                    Start-Work
                    if ($null -eq $script:ActiveSession) { throw 'session did not start' }

                    $allScreens = @([System.Windows.Forms.Screen]::AllScreens)
                    $outerTopScreen = @($allScreens | Where-Object { -not ((Get-InternalMonitorEdges -Screen $_) -contains 'top') } | Select-Object -First 1)[0]
                    if ($null -eq $outerTopScreen) { throw 'no monitor with outer top edge' }
                    $topArea = Convert-ScreenWorkAreaToBounds -Screen $outerTopScreen
                    $script:Window.Left = $topArea.Left + 120
                    $script:Window.Top = $topArea.Top + 8
                    $script:Window.UpdateLayout()
                    Snap-MainWindowToEdge
                    if ($script:DockedEdge -ne 'top') { throw ('top snap failed: ' + $script:DockedEdge) }
                    Hide-MainWindowToEdge
                    if (-not $script:EdgeHidden) { throw 'top edge did not hide' }
                    if (-not $script:MiniTimerVisible) { throw 'top hide did not show mini timer' }
                    if ([Math]::Abs([double]$script:MiniTimerWindow.Top - [Math]::Round($topArea.Top)) -gt 1) { throw 'top mini timer position wrong' }
                    $expectedMiniLeft = [Math]::Round($topArea.Left + (($topArea.Width - $script:MiniTimerWindow.Width) / 2.0))
                    if ([Math]::Abs([double]$script:MiniTimerWindow.Left - $expectedMiniLeft) -gt 1) { throw 'top mini timer horizontal position wrong' }
                    $script:Window.BeginAnimation([System.Windows.Window]::TopProperty, $null)
                    $expectedTop = [Math]::Round($topArea.Top - $script:Window.Height + $script:EdgePeekWidth)
                    if ([Math]::Abs([double]$script:Window.Top - $expectedTop) -gt 1) { throw 'top hidden position wrong' }
                    Reveal-MainWindowFromEdge
                    if ($script:EdgeHidden) { throw 'top edge did not reveal' }
                    if ($script:MiniTimerVisible -or $script:MiniTimerWindow.IsVisible) { throw 'top reveal left mini timer visible' }
                    $script:Window.BeginAnimation([System.Windows.Window]::TopProperty, $null)
                    if ([Math]::Abs([double]$script:Window.Top - ($topArea.Top - 6)) -gt 1) { throw 'top reveal position wrong' }

                    $outerLeftScreen = @($allScreens | Where-Object { -not ((Get-InternalMonitorEdges -Screen $_) -contains 'left') } | Select-Object -First 1)[0]
                    if ($null -eq $outerLeftScreen) { throw 'no monitor with outer left edge' }
                    $leftArea = Convert-ScreenWorkAreaToBounds -Screen $outerLeftScreen
                    $script:Window.Left = $leftArea.Left + 8
                    $script:Window.Top = $leftArea.Top + 160
                    $script:Window.UpdateLayout()
                    Snap-MainWindowToEdge
                    if ($script:DockedEdge -ne 'left') { throw ('left snap failed: ' + $script:DockedEdge) }
                    Hide-MainWindowToEdge
                    if (-not $script:EdgeHidden) { throw 'left edge did not hide' }
                    $script:Window.BeginAnimation([System.Windows.Window]::LeftProperty, $null)
                    $expectedLeft = [Math]::Round($leftArea.Left - $script:Window.Width + $script:EdgePeekWidth)
                    if ([Math]::Abs([double]$script:Window.Left - $expectedLeft) -gt 1) { throw 'left hidden position wrong' }
                    Reveal-MainWindowFromEdge
                    if ($script:EdgeHidden) { throw 'left edge did not reveal' }
                    $script:Window.BeginAnimation([System.Windows.Window]::LeftProperty, $null)

                    $outerRightScreen = @($allScreens | Where-Object { -not ((Get-InternalMonitorEdges -Screen $_) -contains 'right') } | Select-Object -First 1)[0]
                    if ($null -eq $outerRightScreen) { throw 'no monitor with outer right edge' }
                    $rightArea = Convert-ScreenWorkAreaToBounds -Screen $outerRightScreen
                    $script:Window.Left = $rightArea.Right - $script:Window.Width - 8
                    $script:Window.Top = $rightArea.Top + 160
                    $script:Window.UpdateLayout()
                    Snap-MainWindowToEdge
                    if ($script:DockedEdge -ne 'right') { throw ('right snap failed: ' + $script:DockedEdge) }
                    Hide-MainWindowToEdge
                    if (-not $script:EdgeHidden) { throw 'right edge did not hide' }
                    $script:Window.BeginAnimation([System.Windows.Window]::LeftProperty, $null)
                    $expectedLeft = [Math]::Round($rightArea.Right - $script:EdgePeekWidth)
                    if ([Math]::Abs([double]$script:Window.Left - $expectedLeft) -gt 1) { throw 'right hidden position wrong' }
                    Reveal-MainWindowFromEdge
                    if ($script:EdgeHidden) { throw 'right edge did not reveal' }
                    $script:Window.BeginAnimation([System.Windows.Window]::LeftProperty, $null)

                    $outerBottomScreen = @($allScreens | Where-Object { -not ((Get-InternalMonitorEdges -Screen $_) -contains 'bottom') } | Select-Object -First 1)[0]
                    if ($null -eq $outerBottomScreen) { throw 'no monitor with outer bottom edge' }
                    $bottomArea = Convert-ScreenWorkAreaToBounds -Screen $outerBottomScreen
                    $script:Window.Left = $bottomArea.Left + 120
                    $script:Window.Top = $bottomArea.Bottom - $script:Window.Height - 8
                    $script:Window.UpdateLayout()
                    Snap-MainWindowToEdge
                    if ($script:DockedEdge -ne 'bottom') { throw ('bottom snap failed: ' + $script:DockedEdge) }
                    Hide-MainWindowToEdge
                    if ($script:EdgeHidden) { throw 'bottom edge was allowed to hide' }

                    $seamScreen = @($allScreens | Where-Object { (Get-InternalMonitorEdges -Screen $_) -contains 'right' } | Select-Object -First 1)[0]
                    if ($null -ne $seamScreen) {
                        $seamArea = Convert-ScreenWorkAreaToBounds -Screen $seamScreen
                        $script:Window.Left = $seamArea.Right - $script:Window.Width - 8
                        $script:Window.Top = $seamArea.Top + 160
                        $script:Window.UpdateLayout()
                        Snap-MainWindowToEdge
                        if ($script:DockedEdge -eq 'right') { throw 'internal monitor seam should not snap-hide' }
                    }
                    $script:DockedEdge = 'right'
                    $script:EdgeHidden = $true
                    Show-MiniTimer
                    if (-not $script:MiniTimerVisible) { throw 'mini timer did not show' }
                    if ($script:MiniTimerText.Text -notmatch '^[0-9]{2}:[0-9]{2}:[0-9]{2}$') { throw 'mini timer text invalid' }
                    if ([Math]::Abs([double]$script:MiniTimerWindow.Top - [Math]::Round([double]$script:MonitorArea.Top)) -gt 1) { throw 'mini timer is not aligned to work area top' }
                    Hide-MiniTimer
                    $script:EdgeHidden = $false
                    $script:DockedEdge = $null
                }
                1 {
                    $script:NextReminderAt = [DateTimeOffset]::Now.AddSeconds(-1)
                    On-Tick
                    if ($script:ReminderMode -ne 'break_prompt') { throw 'timed reminder did not open' }
                    Snooze-Reminder
                    if ($script:ReminderVisible) { throw 'snooze did not hide reminder' }
                    if ([int]$script:ActiveSession.snoozeCount -ne 1) { throw 'snooze count not recorded' }
                }
                2 {
                    $script:NextReminderAt = [DateTimeOffset]::Now.AddSeconds(-1)
                    On-Tick
                    if ($script:ReminderMode -ne 'break_prompt') { throw 'second reminder did not open' }
                    Start-Break
                    if (-not $script:InBreak) { throw 'break did not start' }
                    if ($null -eq $script:BreakPrivacyAt) { throw 'break privacy schedule missing' }
                    $script:BreakPrivacyAt = [DateTimeOffset]::Now.AddSeconds(-1)
                    On-Tick
                    if (-not $script:BreakPrivacyHidden) { throw 'break privacy did not hide' }
                    if ($script:Window.IsVisible) { throw 'main window still visible during privacy hide' }
                    if ($script:ReminderVisible) { throw 'reminder still visible during privacy hide' }
                    if ($script:MiniTimerVisible) { throw 'mini timer still visible during privacy hide' }
                    $script:DockedEdge = 'right'
                    $script:EdgeHidden = $false
                    Hide-MainWindowToEdge
                    if ($script:EdgeHidden) { throw 'edge hide ran during privacy hide' }
                    $script:EdgeHidden = $true
                    Show-MiniTimer
                    if ($script:MiniTimerVisible) { throw 'mini timer reappeared during privacy hide' }
                    $script:EdgeHidden = $false
                    $cursor = Get-CursorPosition
                    if ($null -ne $cursor) {
                        $script:LastCursorX = [int]$cursor.X + 120
                        $script:LastCursorY = [int]$cursor.Y
                    }
                    On-Tick
                    if ($script:BreakPrivacyHidden) { throw 'mouse activity did not restore break windows' }
                    if (-not $script:Window.IsVisible) { throw 'main window did not restore' }
                    if (-not $script:ReminderVisible) { throw 'reminder did not restore' }
                }
                3 {
                    End-Break
                    if ($script:InBreak) { throw 'break did not end' }
                    if ([int]$script:ActiveSession.breakCount -lt 1) { throw 'break not recorded' }
                }
                4 {
                    Stop-Work -Reason 'test'
                    $script:DockedEdge = 'right'
                    $script:EdgeHidden = $false
                    Hide-MainWindowToEdge
                    if ($script:EdgeHidden) { throw 'idle window was allowed to hide after stop' }
                    $script:TaskTextBox.Text = ''
                    $historyCount = Refresh-RecentTasks
                    if ($historyCount -lt 1) { throw 'history suggestions were not populated' }
                    if (-not $script:RecentTasksPopup.StaysOpen) { throw 'history popup must stay open' }
                    Show-RecentTasksPopup
                    if (-not $script:RecentTasksPopup.IsOpen) { throw 'history popup did not open' }
                    Show-RecentTasksPopup
                    if (-not $script:RecentTasksPopup.IsOpen) { throw 'history popup closed on repeated open' }
                    $popupTask = [string](@(Get-RecentTasks -Sessions $script:Sessions -Limit 1)[0])
                    if (-not [string]::IsNullOrWhiteSpace($popupTask)) {
                        $script:TaskTextBox.Text = $popupTask.Substring(0, [Math]::Min(2, $popupTask.Length))
                        $filteredCount = Refresh-RecentTasks
                        if ($filteredCount -lt 1) { throw 'history filter returned nothing' }
                        $script:TaskTextBox.Text = ''
                        $historyCount = Refresh-RecentTasks
                    }
                    $firstHistoryButton = $script:RecentTasksPanel.Children[0]
                    $expectedTask = [string]$firstHistoryButton.Tag
                    $mouseArgs = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
                    $mouseArgs.RoutedEvent = [System.Windows.Input.Mouse]::PreviewMouseDownEvent
                    $firstHistoryButton.RaiseEvent($mouseArgs)
                    if (-not $script:RecentTasksPopup.IsOpen) { throw 'history item mousedown closed the popup' }
                    $clickArgs = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)
                    $firstHistoryButton.RaiseEvent($clickArgs)
                    if ([string]$script:TaskTextBox.Text -ne $expectedTask) { throw 'history item click did not fill input' }
                    if ($script:RecentTasksPopup.IsOpen) { throw 'history popup stayed open after selection' }
                    $script:TaskTextBox.Text = ''
                    $historyCount = Refresh-RecentTasks
                    Hide-RecentTasksPopup
                    $path = Export-PomoInsightData -Root $script:DataRoot -OutputDir (Join-Path $script:DataRoot 'exports') -Format json
                    $sessions = @(Get-PomoInsightSessions -Root $script:DataRoot)
                    $session = $sessions[0]
                    if ([int]$session.reminderCount -lt 2) { throw 'reminder events missing' }
                    if ([int]$session.snoozeCount -lt 1) { throw 'snooze event missing' }
                    if ([int]$session.breakCount -lt 1) { throw 'break event missing' }

                    Open-Settings
                    if ($script:DataLocationText.Text -ne $script:DataRoot) { throw 'data location text not updated' }
                    Apply-ReminderPreset -Name 'pomodoro'
                    if ([int]$script:Settings.focusMinutes -ne 25 -or [int]$script:Settings.breakMinutes -ne 5) { throw 'pomodoro preset not saved' }
                    if (-not $script:SettingsOpen) { throw 'preset switch closed settings' }
                    if ((Get-ReminderPresetLabel) -ne '番茄 25/5') { throw 'preset label wrong' }
                    if ($script:PresetDescriptionText.Text -notmatch '番茄模式') { throw 'pomodoro description missing' }
                    Apply-ReminderPreset -Name 'observe'
                    if ((Get-ReminderPresetLabel) -ne '52/17 观察') { throw 'observe preset not saved' }
                    if ($script:PresetDescriptionText.Text -notmatch '观察模式') { throw 'observe description missing' }
                    Apply-ReminderPreset -Name 'balanced'
                    if ([int]$script:Settings.focusMinutes -ne 50 -or [int]$script:Settings.breakMinutes -ne 10) { throw 'balanced preset not saved' }
                    if ($script:PresetDescriptionText.Text -notmatch '平衡模式') { throw 'balanced description missing' }
                    Close-Settings

                    $multi = 'one-screen'
                    $screens = @([System.Windows.Forms.Screen]::AllScreens)
                    if ($screens.Count -gt 1) {
                        $targetScreen = @($screens | Where-Object { -not $_.Primary -and -not ((Get-InternalMonitorEdges -Screen $_) -contains 'left') } | Select-Object -First 1)[0]
                        if ($null -ne $targetScreen) {
                            $scale = Get-WindowDpiScale
                            $expectedLeft = [double]$targetScreen.WorkingArea.Left / $scale.X
                            $expectedTop = [double]$targetScreen.WorkingArea.Top / $scale.Y
                            $script:Window.Left = $expectedLeft + 20
                            $script:Window.Top = $expectedTop + 80
                            $script:Window.UpdateLayout()
                            Snap-MainWindowToEdge
                            if ([Math]::Abs([double]$script:MonitorArea.Left - $expectedLeft) -gt 2) { throw 'multi-monitor area not detected' }
                            if ($script:DockedEdge -ne 'left') { throw ('multi-monitor snap failed: ' + $script:DockedEdge) }
                            if ([Math]::Abs([double]$script:Window.Left - ($expectedLeft - 6)) -gt 2) { throw 'multi-monitor snap position wrong' }
                            $multi = 'ok'
                        }
                    }
                    $marker = Join-Path $script:DataRoot 'uismoke.ok'
                    [System.IO.File]::WriteAllText($marker, ('sessions=' + $sessions.Count + '; reminders=' + $session.reminderCount + '; snoozes=' + $session.snoozeCount + '; breaks=' + $session.breakCount + '; history=' + $historyCount + '; privacy=ok; idle=ok; tray=ok; top=ok; preset=ok; multi=' + $multi + '; export=' + $path), [System.Text.Encoding]::UTF8)
                    $script:SmokeTimer.Stop()
                    $script:Exiting = $true
                    $script:Window.Close()
                    $script:App.Shutdown()
                    return
                }
            }
            $script:SmokeStep++
        } catch {
            $script:UiSmokeFailed = $true
            try { [System.IO.File]::WriteAllText((Join-Path $script:DataRoot 'uismoke.fail.txt'), $_.Exception.ToString(), [System.Text.Encoding]::UTF8) } catch { }
            $script:SmokeTimer.Stop()
            $script:Exiting = $true
            try { $script:Window.Close(); $script:App.Shutdown() } catch { }
        }
    })
    $script:SmokeTimer.Start()
}
$script:Window = Load-XamlWindow -RelativePath 'ui\MainWindow.xaml'
$script:ReminderWindow = Load-XamlWindow -RelativePath 'ui\ReminderWindow.xaml'
$script:MiniTimerWindow = Load-XamlWindow -RelativePath 'ui\MiniTimerWindow.xaml'
Set-PomoInsightWindowIcon -Window $script:Window
Set-PomoInsightWindowIcon -Window $script:ReminderWindow
$script:Window.Topmost = [bool]$script:Settings.alwaysOnTop
$script:ReminderWindow.Topmost = $true
$script:ReminderWindow.ShowActivated = $false
$script:MiniTimerWindow.Topmost = $true
$script:MiniTimerWindow.ShowActivated = $false
Initialize-Controls
$script:UiTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UiTimer.Interval = [TimeSpan]::FromSeconds(30)
$script:UiTimer.Add_Tick({ On-Tick })
$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
Wire-Events

$script:Window.Add_Loaded({
    Position-MainWindow -Initial
    Position-ReminderWindow
    Initialize-TrayIcon
    Update-StaticUi
    Update-LiveUi
    $script:UiTimer.Start()
    if (-not [string]::IsNullOrWhiteSpace($script:RecoveryMessage)) {
        $script:Window.Topmost = $true
        Set-Expanded $true
        Show-TransientStatus -Text $script:RecoveryMessage -Good $true
        if (-not $UiSmokeTest) { try { $script:Window.Activate() | Out-Null } catch { } }
    } else {
        Focus-IdleWindow
        if ($null -ne $script:EdgeHideTimer) { Stop-EdgeHideTimer }
    }
    if ($UiSmokeTest) { Start-UiSmokeTest }
})

try {
    [void]$script:App.Run($script:Window)
} finally {
    try { if ($null -ne $script:UiTimer) { $script:UiTimer.Stop() } } catch { }
    try { if ($null -ne $script:ReminderWindow -and $script:ReminderWindow.IsVisible) { $script:ReminderWindow.Close() } } catch { }
    try { if ($null -ne $script:MiniTimerWindow -and $script:MiniTimerWindow.IsVisible) { $script:MiniTimerWindow.Close() } } catch { }
    Dispose-TrayIcon
    try { $script:Mutex.ReleaseMutex() } catch { }
    try { $script:Mutex.Dispose() } catch { }
}

if ($UiSmokeTest -and $script:UiSmokeFailed) { exit 1 }
