#requires -Version 5.1
[CmdletBinding()]
param([string]$Destination, [switch]$Force)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Destination) {
    $codexDirectory = $env:CODEX_HOME
    if (-not $codexDirectory) { $codexDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
    $Destination = Join-Path $codexDirectory 'skills/research-mode'
}
$Destination = [IO.Path]::GetFullPath($Destination)
if ((Test-Path -LiteralPath $Destination) -and -not $Force) { throw '目标已存在。更新已审查的安装请显式使用 -Force，或指定新目录。' }
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'skills/research-mode/SKILL.md') -Destination $Destination -Force
New-Item -ItemType Directory -Path (Join-Path $Destination 'agents') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'skills/research-mode/agents/openai.yaml') -Destination (Join-Path $Destination 'agents/openai.yaml') -Force
$runtime = Join-Path $Destination 'scripts'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
foreach ($folder in @('src', 'rules')) {
    New-Item -ItemType Directory -Path (Join-Path $runtime $folder) -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runtime $folder) -Force }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ResearchMode.ps1') -Destination $runtime -Force
Write-Host "已安装 skill：$Destination"
Write-Host '运行逻辑已复制；数据仍默认保存在 LOCALAPPDATA/ResearchMode。'
