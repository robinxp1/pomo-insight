$tokens = $null
$errors = $null
$files = @(
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'PomoInsight.ps1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\PomoInsight.Core.ps1')
)
$failed = $false
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -eq 0) {
        Write-Output ('SYNTAX_OK ' + $file)
    } else {
        $failed = $true
        Write-Output ('SYNTAX_FAIL ' + $file)
        foreach ($err in $errors) { Write-Output $err.ToString() }
    }
}
if ($failed) { exit 1 }