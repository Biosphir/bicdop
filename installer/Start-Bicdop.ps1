param([switch]$Agent, [string]$Directory)

$ErrorActionPreference = 'Stop'
$ghDirectory = Join-Path $PSScriptRoot 'tools/gh'
$gitDirectory = Join-Path $PSScriptRoot 'tools/git/cmd'
$bundledGit = Join-Path $gitDirectory 'git.exe'
$bundledGh = Join-Path $ghDirectory 'gh.exe'
$useBundledGit = [IO.File]::Exists($bundledGit) -and !(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
$paths = @($env:Path)
if ([IO.File]::Exists($bundledGh)) { $paths += $ghDirectory }
if ([IO.File]::Exists($bundledGit)) { $paths += $gitDirectory }
$env:Path = $paths -join [IO.Path]::PathSeparator
if ($useBundledGit -and !$env:GIT_CONFIG_COUNT -and [IO.File]::Exists($bundledGh)) {
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'credential.https://github.com.helper'
    $env:GIT_CONFIG_VALUE_0 = '!gh auth git-credential'
}

$bundled = Join-Path $PSScriptRoot 'bundled/Bicdop.psd1'
. (Join-Path $PSScriptRoot 'bundled/Update.ps1')
$root = Get-BicdopManagedRoot
$minimum = [version](Import-PowerShellDataFile -LiteralPath $bundled).ModuleVersion
$installed = Get-BicdopManagedModule $root $minimum
$current = if ($installed) { $installed.Version } else { $minimum }

if (!$Agent) {
    Write-Host "Checking GitHub for Bicdop updates (current $current)..."
    try {
        $result = Install-BicdopRelease $current $root
        if ($result.Updated) { Write-Host "Installed Bicdop $($result.Version)." }
    } catch {
        Write-Warning "Update skipped: $($_.Exception.Message)"
    }
}

foreach ($manifest in @((Get-BicdopManagedModule $root $minimum).Path, $bundled) | Where-Object { $_ } | Select-Object -Unique) {
    try {
        Import-Module -Name $manifest -ErrorAction Stop
        break
    } catch {
        if ($manifest -eq $bundled) { throw }
        if (!$Agent) { Write-Warning 'Could not load the downloaded version. Starting the bundled version.' }
    }
}
if ($Agent) { bicdop agent serve; exit }
Write-Host "Bicdop $((Get-Command bicdop).Module.Version). Type help for commands. Up Arrow recalls previous commands."
if ($Directory) { bicdop --directory $Directory } else { bicdop }
