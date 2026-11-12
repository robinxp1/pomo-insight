param([string]$Version = '')
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Version)) {
    $core = Get-Content (Join-Path $root 'lib\PomoInsight.Core.ps1') -Raw
    if ($core -match "PomoInsightVersion\s*=\s*'([^']+)'") { $Version = $Matches[1] } else { $Version = '0.0.0' }
}

$name = "pomo-insight-$Version-portable"
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist $name
if (-not (Test-Path -LiteralPath $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
foreach ($dir in @('', 'lib', 'ui', 'assets')) {
    $target = if ($dir) { Join-Path $stage $dir } else { $stage }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
}

Copy-Item -LiteralPath (Join-Path $root 'PomoInsight.ps1') -Destination (Join-Path $stage 'PomoInsight.ps1')
Copy-Item -LiteralPath (Join-Path $root 'lib\PomoInsight.Core.ps1') -Destination (Join-Path $stage 'lib\PomoInsight.Core.ps1')
Copy-Item -Path (Join-Path $root 'ui\*.xaml') -Destination (Join-Path $stage 'ui')
Copy-Item -LiteralPath (Join-Path $root 'assets\pomo-insight.ico') -Destination (Join-Path $stage 'assets\pomo-insight.ico')
Copy-Item -LiteralPath (Join-Path $root '启动番茄洞察.cmd') -Destination (Join-Path $stage '启动番茄洞察.cmd')

$readme = @(
    ('番茄洞察 · 工作节奏追踪器 ' + $Version + '（绿色免安装版）'),
    '',
    '1. 解压到任意目录即可，不需要安装，也不需要管理员权限。',
    '   建议不要放在 C:\Program Files 这类受保护目录。',
    '2. 双击「启动番茄洞察.cmd」运行。',
    '3. 所有记录和设置都保存在本目录的 data 文件夹里，',
    '   整个目录可以拷到 U 盘或另一台电脑继续用，数据跟着走。',
    '4. 需要开机自启：打开设置勾选「开机自启」，',
    '   会在当前用户的启动文件夹里创建一个指向本目录的快捷方式。',
    '5. 卸载：先关闭程序，再删掉整个文件夹即可，不写注册表、不留残留。',
    '',
    '运行环境：Windows 10 / 11 自带的 PowerShell 5.1，无需额外安装 .NET。'
) -join "`r`n"

$utf8 = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText((Join-Path $stage 'portable.dat'), "portable`r`n", $utf8)
[System.IO.File]::WriteAllText((Join-Path $stage '使用说明.txt'), $readme + "`r`n", $utf8)

$zip = Join-Path $dist ($name + '.zip')
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal

$size = [Math]::Round((Get-Item -LiteralPath $zip).Length / 1KB, 1)
Write-Output ('PORTABLE_OK ' + $zip + ' (' + $size + ' KB)')