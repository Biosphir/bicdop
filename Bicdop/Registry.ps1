$script:RegistryPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData', 'DoNotVerify')) 'Bicdop/registry.json'
$script:RunningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:PathComparison = if ($script:RunningOnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Convert-BicdopJsonValue($Value) {
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $map = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = Convert-BicdopJsonValue $property.Value
        }
        return $map
    }
    if ($Value -is [array]) {
        $items = foreach ($item in $Value) { ,(Convert-BicdopJsonValue $item) }
        return ,@($items)
    }
    return $Value
}

function Read-BicdopJson([string]$Path) {
    $value = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -ErrorAction Stop
    return Convert-BicdopJsonValue $value
}

function Read-BicdopRegistry {
    if (-not [IO.File]::Exists($script:RegistryPath)) {
        return @{ schema = 1; active = $null; workspaces = @{}; projects = @{} }
    }
    $state = Read-BicdopJson $script:RegistryPath
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
    Save-BicdopJson $script:RegistryPath $State
}

function Save-BicdopJson([string]$Path, $State) {
    $temporary = "$Path.$([guid]::NewGuid()).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $State -Depth 8))
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporary, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        [IO.File]::Delete($temporary)
    }
}

function Get-BicdopSessionsPath {
    Join-Path (Split-Path -LiteralPath $script:RegistryPath) 'session.json'
}

function Read-BicdopSessions {
    $path = Get-BicdopSessionsPath
    if (![IO.File]::Exists($path)) { return @{ schema = 1; last = $null; named = @{}; history = @(); log = @() } }
    $state = Read-BicdopJson $path
    if ($state.schema -ne 1 -or $state.named -isnot [Collections.IDictionary] -or $state.history -isnot [array]) {
        throw "Invalid Bicdop session file: $path"
    }
    if ($state.log -isnot [array]) { $state.log = @() }
    return $state
}

function Invoke-BicdopSessionWrite([scriptblock]$Change) {
    $path = Get-BicdopSessionsPath
    [void][IO.Directory]::CreateDirectory((Split-Path -LiteralPath $path))
    $lock = $null
    for ($attempt = 0; $attempt -lt 20 -and !$lock; $attempt++) {
        try { $lock = [IO.File]::Open("$path.lock", 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] { Start-Sleep -Milliseconds 25 }
    }
    if (!$lock) { throw 'Could not lock Bicdop session storage. Try again.' }
    try {
        $state = Read-BicdopSessions
        & $Change $state
        Save-BicdopJson $path $state
    } finally {
        $lock.Dispose()
    }
}

function Write-BicdopMarker([string]$Path, $Marker) {
    $identityFields = 'schema', 'id', 'workspace'
    $ordered = [ordered]@{}
    foreach ($field in $identityFields) {
        if ($Marker.Contains($field)) { $ordered[$field] = $Marker[$field] }
    }
    foreach ($field in $Marker.Keys | Where-Object { $_ -notin $identityFields } | Sort-Object) {
        $ordered[$field] = $Marker[$field]
    }
    $json = ConvertTo-Json -InputObject $ordered
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
        $marker = Read-BicdopJson $Path
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
