$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '../Bicdop'
. (Join-Path $module 'Update.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('bicdop-update-test-' + [guid]::NewGuid().ToString())
$source = Join-Path $fixture 'source'
$root = Join-Path $fixture 'installed'
[void][IO.Directory]::CreateDirectory($source)

function Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $TimeoutSec)
    return $script:Release
}

function Invoke-WebRequest {
    [CmdletBinding()]
    param([switch]$UseBasicParsing, $Uri, $OutFile, $TimeoutSec)
    if ($Uri -cne $script:Release.assets[0].browser_download_url) { throw 'Unexpected download URL' }
    Copy-Item -LiteralPath $script:Archive -Destination $OutFile
}

try {
    foreach ($file in $script:BicdopModuleFiles) {
        Copy-Item -LiteralPath (Join-Path $module $file) -Destination $source
    }
    $manifest = Join-Path $source 'Bicdop.psd1'
    $bundled = [version](Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion
    $latest = [version]::new($bundled.Major, $bundled.Minor, ($bundled.Build + 1))
    [IO.File]::WriteAllText($manifest, [IO.File]::ReadAllText($manifest).Replace("'$bundled'", "'$latest'"))
    $name = "Bicdop-$latest-module.zip"
    $script:Archive = Join-Path $fixture $name
    Compress-Archive -LiteralPath @($script:BicdopModuleFiles | ForEach-Object { Join-Path $source $_ }) -DestinationPath $script:Archive
    $script:Release = @{
        tag_name = "v$latest"; assets = @(@{
            name = $name; state = 'uploaded'; size = (Get-Item -LiteralPath $script:Archive).Length
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

    $script:Release.assets[0].digest = 'sha256:' + (Get-FileHash -LiteralPath $script:Archive).Hash.ToLowerInvariant()
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
