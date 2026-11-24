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

function Get-BicdopBuildDependency([string]$Uri, [string]$Sha256, [string]$Directory) {
    $archive = "$Directory.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $archive -TimeoutSec 120 -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $Sha256) {
        throw "Installer dependency failed SHA-256 verification: $Uri"
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $Directory
    return $Directory
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ('bicdop-build-' + [guid]::NewGuid().ToString())
[void][IO.Directory]::CreateDirectory($stage)
try {
    $ghUri = 'https://github.com/cli/cli/releases/download/v2.105.0/gh_2.105.0_windows_amd64.zip'
    $gitUri = 'https://github.com/git-for-windows/git/releases/download/v2.56.1.windows.1/MinGit-2.56.1-64-bit.zip'
    $gh = Get-BicdopBuildDependency $ghUri '8813a72c899900afaa10e3fec8fbc64b908c89dbfe837e95ed2fa500fc140627' (Join-Path $stage 'gh')
    $git = Get-BicdopBuildDependency $gitUri '4a92850b6e917da4fd010669b614b55dccf5b0ec333a534cc4be4700dfefdafd' (Join-Path $stage 'git')
    $icon = Join-Path $repo 'assets/logo-bicdop-windows.ico'
    $launcher = Join-Path $stage 'Bicdop.exe'
    & $compiler /nologo /target:exe /optimize "/out:$launcher" "/win32icon:$icon" (Join-Path $PSScriptRoot 'Launcher.cs')
    if ($LASTEXITCODE) { throw 'Bicdop launcher compilation failed.' }
    & $inno "/DBicdopVersion=$version" "/DLauncherPath=$launcher" "/DGhPath=$gh" "/DGitPath=$git" "/O$output" (Join-Path $PSScriptRoot 'Bicdop.iss')
    if ($LASTEXITCODE) { throw 'Bicdop installer compilation failed.' }
} finally {
    [IO.Directory]::Delete($stage, $true)
}
