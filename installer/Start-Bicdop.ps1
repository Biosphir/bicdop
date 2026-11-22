$ErrorActionPreference = 'Stop'
$bundled = Join-Path $PSScriptRoot 'bundled/Bicdop.psd1'
. (Join-Path $PSScriptRoot 'bundled/Update.ps1')
$root = Get-BicdopManagedRoot
$minimum = [version](Import-PowerShellDataFile -LiteralPath $bundled).ModuleVersion
$installed = Get-BicdopManagedModule $root $minimum
$current = if ($installed) { $installed.Version } else { $minimum }

Write-Host "Checking GitHub for Bicdop updates (current $current)..."
try {
    $result = Install-BicdopRelease $current $root
    if ($result.Updated) { Write-Host "Installed Bicdop $($result.Version)." }
} catch {
    Write-Warning "Update skipped: $($_.Exception.Message)"
}

foreach ($manifest in @((Get-BicdopManagedModule $root $minimum).Path, $bundled) | Where-Object { $_ } | Select-Object -Unique) {
    try {
        Import-Module -Name $manifest -ErrorAction Stop
        break
    } catch {
        if ($manifest -eq $bundled) { throw }
        Write-Warning 'Could not load the downloaded version. Starting the bundled version.'
    }
}
Write-Host "Bicdop $((Get-Command bicdop).Module.Version). Type help for commands. Up Arrow recalls previous commands."
bicdop
