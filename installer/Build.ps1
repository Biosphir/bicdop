param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$module = Join-Path $repo 'Bicdop'
$version = (Import-PowerShellDataFile -LiteralPath (Join-Path $module 'Bicdop.psd1')).ModuleVersion
$output = (New-Item -ItemType Directory -Path $OutputDirectory -Force).FullName
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
$inno = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (!$inno) { $inno = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Inno Setup 6/ISCC.exe' }
if (![IO.File]::Exists($inno)) { throw 'Install Inno Setup 6 before building the Bicdop installer.' }

$stage = Join-Path ([IO.Path]::GetTempPath()) ('bicdop-build-' + [guid]::NewGuid().ToString())
[void][IO.Directory]::CreateDirectory($stage)
try {
    $launcher = Join-Path $stage 'Bicdop.exe'
    & $compiler /nologo /target:exe /optimize "/out:$launcher" (Join-Path $PSScriptRoot 'Launcher.cs')
    if ($LASTEXITCODE) { throw 'Bicdop launcher compilation failed.' }
    & $inno "/DBicdopVersion=$version" "/DLauncherPath=$launcher" "/O$output" (Join-Path $PSScriptRoot 'Bicdop.iss')
    if ($LASTEXITCODE) { throw 'Bicdop installer compilation failed.' }
} finally {
    [IO.Directory]::Delete($stage, $true)
}
