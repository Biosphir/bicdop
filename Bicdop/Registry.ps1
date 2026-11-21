$script:RegistryPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData', 'DoNotVerify')) 'Bicdop/registry.json'
$script:PathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Read-BicdopRegistry {
    if (-not [IO.File]::Exists($script:RegistryPath)) {
        return @{ schema = 1; active = $null; workspaces = @{}; projects = @{} }
    }
    $state = [IO.File]::ReadAllText($script:RegistryPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($state.schema -ne 1 -or $state.workspaces -isnot [System.Collections.IDictionary] -or
        $state.projects -isnot [System.Collections.IDictionary]) {
        throw "Invalid Bicdop registry: $script:RegistryPath"
    }
    return $state
}

function Invoke-BicdopRegistryWrite([scriptblock]$Change) {
    $directory = Split-Path -LiteralPath $script:RegistryPath
    [void][IO.Directory]::CreateDirectory($directory)
    try {
        $lock = [IO.File]::Open("$script:RegistryPath.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    } catch {
        throw "Could not lock the Bicdop registry. Close any other Bicdop operation and try again. $($_.Exception.Message)"
    }
    try {
        $state = Read-BicdopRegistry
        & $Change $state
    } finally {
        $lock.Dispose()
    }
}

function Save-BicdopRegistry($State) {
    $temporary = "$script:RegistryPath.$([guid]::NewGuid()).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $State -Depth 8))
        [IO.File]::Move($temporary, $script:RegistryPath, $true)
    } finally {
        [IO.File]::Delete($temporary)
    }
}

function Write-BicdopMarker([string]$Path, $Marker) {
    $json = ConvertTo-Json -InputObject $Marker
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $stream = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    } catch {
        $stream.Dispose()
        [IO.File]::Delete($Path)
        throw
    } finally {
        $stream.Dispose()
    }
    return $json
}

function Read-BicdopMarker([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return }
    try {
        $marker = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $id = [guid]::Empty
        if ($marker.schema -eq 1 -and [guid]::TryParse($marker.id, [ref]$id) -and $id -ne [guid]::Empty) {
            $marker.id = $id.ToString()
            return $marker
        }
    } catch {
        # Scans can still identify legacy or unreadable markers as planted.
    }
}

function Get-BicdopFolder([string]$Path = '.') {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.DirectoryInfo]) { throw "Expected a filesystem folder: $Path" }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Choose the real folder instead of a symlink or junction: $Path"
    }
    return $item
}

function Test-BicdopUnder([string]$Path, [string]$Root) {
    $separator = [IO.Path]::DirectorySeparatorChar
    $prefix = $Root.TrimEnd($separator) + $separator
    return $Path.Equals($Root, $script:PathComparison) -or $Path.StartsWith($prefix, $script:PathComparison)
}

function Get-BicdopAssociation($State, [string]$Path, $Marker) {
    if ($Marker -and $Marker.workspace -and $State.workspaces.Contains($Marker.workspace)) {
        return $Marker.workspace
    }
    $root = $State.workspaces.GetEnumerator() |
        Where-Object { Test-BicdopUnder $Path $_.Value.path } |
        Sort-Object { $_.Value.path.Length } -Descending | Select-Object -First 1
    if ($root) { return $root.Key }
}
