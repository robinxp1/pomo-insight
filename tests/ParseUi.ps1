Add-Type -AssemblyName PresentationFramework
$root = Split-Path -Parent $PSScriptRoot
$files = @('ui\MainWindow.xaml', 'ui\ReminderWindow.xaml', 'ui\MiniTimerWindow.xaml')
$failed = $false
foreach ($rel in $files) {
    $path = Join-Path $root $rel
    $xml = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    try {
        $window = [System.Windows.Markup.XamlReader]::Parse($xml)
        Write-Output ('XAML_OK ' + $rel + ' size=' + $window.Width + 'x' + $window.Height)
        $window.Close()
    } catch {
        $failed = $true
        Write-Output ('XAML_FAIL ' + $rel)
        Write-Output $_.Exception.Message
        if ($_.Exception.InnerException) { Write-Output $_.Exception.InnerException.Message }
    }
}
if ($failed) { exit 1 }