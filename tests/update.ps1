param([string]$InstallerPath)

$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '../Bicdop'
. (Join-Path $module 'Update.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('bicdop-update-test-' + [guid]::NewGuid().ToString())
$root = Join-Path $fixture 'installed'
[void][IO.Directory]::CreateDirectory($fixture)

function Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $TimeoutSec)
    return $script:Release
}

function Invoke-WebRequest {
    [CmdletBinding()]
    param([switch]$UseBasicParsing, $Uri, $OutFile, $TimeoutSec)
    if ($Uri -cne $script:Release.assets[0].browser_download_url) { throw 'Unexpected download URL' }
    Copy-Item -LiteralPath $script:Installer -Destination $OutFile
}

try {
    $latest = [version](Import-PowerShellDataFile -LiteralPath (Join-Path $module 'Bicdop.psd1')).ModuleVersion
    $bundled = [version]::new($latest.Major, $latest.Minor, ($latest.Build - 1))
    $name = 'BicdopSetup.exe'
    if (!$InstallerPath) {
        & (Join-Path $PSScriptRoot '../installer/Build.ps1') -OutputDirectory $fixture | Out-Null
        $InstallerPath = Join-Path $fixture $name
    }
    $script:Installer = (Resolve-Path -LiteralPath $InstallerPath).Path
    $script:Release = @{
        tag_name = "v$latest"; assets = @(@{
            name = $name; state = 'uploaded'; size = (Get-Item -LiteralPath $script:Installer).Length
            browser_download_url = "https://github.com/Biosphir/bicdop/releases/download/v$latest/$name"
            digest = 'sha256:' + ('0' * 64)
        })
    }

    try {
        Install-BicdopRelease $bundled $root | Out-Null
        throw 'Updater accepted an invalid digest.'
    } catch {
        if ($_.Exception.Message -notmatch 'SHA-256 verification') { throw }
    }
    if (Get-BicdopManagedModule $root $bundled) { throw 'Invalid package became active.' }

    $script:Release.assets[0].digest = 'sha256:' + (Get-FileHash -LiteralPath $script:Installer).Hash.ToLowerInvariant()
    $result = Install-BicdopRelease $bundled $root
    if (!$result.Updated -or (Get-BicdopManagedModule $root $bundled).Version -ne $latest) {
        throw 'Verified package was not installed.'
    }
    Import-Module -Name (Get-BicdopManagedModule $root $bundled).Path -ErrorAction Stop
    if ((Get-Command bicdop).Module.Version -ne $latest) { throw 'Verified package failed to load.' }
    Remove-Module Bicdop

    $script:Release = @{ tag_name = "v$bundled" }
    if ((Install-BicdopRelease $latest $root).Updated) { throw 'Updater attempted a downgrade.' }
    'Bicdop updater test passed.'
} finally {
    [IO.Directory]::Delete($fixture, $true)
}
