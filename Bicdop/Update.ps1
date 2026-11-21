$script:BicdopReleaseUri = 'https://api.github.com/repos/Biosphir/bicdop/releases/latest'
$script:BicdopModuleFiles = @('Bicdop.psd1', 'Bicdop.psm1', 'Bicdop.Format.ps1xml', 'Registry.ps1', 'Update.ps1')

function Get-BicdopManagedRoot {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bicdop/Modules'
}

function Get-BicdopRelease {
    $release = Invoke-RestMethod -Uri $script:BicdopReleaseUri -TimeoutSec 8 -ErrorAction Stop
    if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v?(?<version>\d+\.\d+\.\d+)$') {
        throw 'GitHub did not return a supported stable Bicdop release.'
    }
    [pscustomobject]@{ Version = [version]$Matches.version; Release = $release }
}

function Get-BicdopManagedModule([string]$Root, [version]$Minimum) {
    if (![IO.Directory]::Exists($Root)) { return }
    Get-ChildItem -LiteralPath $Root -Directory | ForEach-Object {
        $version = $null
        if ($_.Name -match '^\d+\.\d+\.\d+$' -and [version]::TryParse($_.Name, [ref]$version) -and $version -ge $Minimum) {
            $directory = $_.FullName
            $manifest = Join-Path $directory 'Bicdop.psd1'
            $missing = @($script:BicdopModuleFiles | Where-Object { ![IO.File]::Exists((Join-Path $directory $_)) })
            if (!$missing.Count -and (Import-PowerShellDataFile -LiteralPath $manifest -ErrorAction SilentlyContinue).ModuleVersion -eq "$version") {
                [pscustomobject]@{ Version = $version; Path = $manifest }
            }
        }
    } | Sort-Object Version -Descending | Select-Object -First 1
}

function Install-BicdopRelease([version]$Current, [string]$Root) {
    $latest = Get-BicdopRelease
    if ($latest.Version -le $Current) {
        return [pscustomobject]@{ Version = $Current; Updated = $false }
    }
    $name = "Bicdop-$($latest.Version)-module.zip"
    $assets = @($latest.Release.assets | Where-Object { $_.name -ceq $name -and $_.state -eq 'uploaded' })
    if ($assets.Count -ne 1) { throw "Release $($latest.Version) does not contain $name." }
    $asset = $assets[0]
    $expectedUrl = "https://github.com/Biosphir/bicdop/releases/download/$($latest.Release.tag_name)/$name"
    if ($asset.browser_download_url -cne $expectedUrl -or $asset.digest -notmatch '^sha256:([a-f0-9]{64})$' -or
        $asset.size -lt 1 -or $asset.size -gt 2MB) {
        throw 'The GitHub release asset has unexpected metadata.'
    }
    $expectedHash = $Matches[1]

    [void][IO.Directory]::CreateDirectory($Root)
    $destination = Join-Path $Root $latest.Version.ToString()
    if ([IO.Directory]::Exists($destination)) {
        $installed = Get-BicdopManagedModule $Root $latest.Version
        if ($installed) { return [pscustomobject]@{ Version = $installed.Version; Updated = $false } }
        throw "The existing Bicdop directory is incomplete: $destination"
    }

    $stage = Join-Path $Root ('.download-' + [guid]::NewGuid().ToString())
    $module = Join-Path $stage 'module'
    [void][IO.Directory]::CreateDirectory($module)
    try {
        $archivePath = Join-Path $stage 'module.zip'
        Write-Host "Downloading $name..."
        Invoke-WebRequest -UseBasicParsing -Uri $expectedUrl -OutFile $archivePath -TimeoutSec 15 -ErrorAction Stop
        Write-Host "Verifying $name..."
        if ((Get-Item -LiteralPath $archivePath).Length -ne $asset.size -or
            (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ine $expectedHash) {
            throw 'Bicdop download failed SHA-256 verification.'
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            if ($archive.Entries.Count -ne $script:BicdopModuleFiles.Count) { throw 'Unexpected contents in the Bicdop module ZIP.' }
            foreach ($file in $script:BicdopModuleFiles) {
                $entry = $archive.GetEntry($file)
                if (!$entry -or $entry.Length -gt 2MB) { throw "Invalid or missing ZIP entry: $file" }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $module $file))
            }
        } finally {
            $archive.Dispose()
        }

        $data = Import-PowerShellDataFile -LiteralPath (Join-Path $module 'Bicdop.psd1')
        if ($data.ModuleVersion -ne "$($latest.Version)" -or $data.RootModule -cne 'Bicdop.psm1' -or
            $data.GUID -ne '0ca61971-3ba1-441f-b33e-fce8d04b376a') {
            throw 'The downloaded manifest does not match the Bicdop release.'
        }
        Write-Host "Installing Bicdop $($latest.Version)..."
        try {
            [IO.Directory]::Move($module, $destination)
        } catch [IO.IOException] {
            if (!(Get-BicdopManagedModule $Root $latest.Version)) { throw }
        }
        [pscustomobject]@{ Version = $latest.Version; Updated = $true }
    } finally {
        [IO.Directory]::Delete($stage, $true)
    }
}
