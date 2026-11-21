. "$PSScriptRoot/Registry.ps1"

$script:ScanRows = @()
$script:ProjectRows = @()
$script:ListedWorkspace = $null
$script:DetachedRuns = @{}
function Get-BicdopPrompt {
    $location = Get-Location
    $workspaceLabel = ''
    try {
        $state = Read-BicdopRegistry
        if ($state.active -and $state.workspaces.Contains($state.active)) {
            $workspaceLabel = " $($state.workspaces[$state.active].name)"
        }
    } catch {
        # Keep the shell usable if the registry cannot be read.
    }
    "bicdop$workspaceLabel [$($location.Path)] > "
}

function Get-BicdopDrives {
    Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root }
}

function Test-BicdopDirectChild([string]$Path, [string]$Root) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    return [string]::Equals(($parent -replace '[\\/]+$', ''), ($Root -replace '[\\/]+$', ''), $script:PathComparison)
}

function Get-BicdopChildFolders([IO.DirectoryInfo]$Folder) {
    $Folder.EnumerateDirectories() | Where-Object {
        !($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } | Sort-Object FullName
}

function Get-BicdopFolderSize([string]$Path) {
    try { $root = Get-BicdopFolder $Path }
    catch { return 'Unavailable' }

    $pending = [System.Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push($root)
    $bytes = 0L
    $partial = $false
    while ($pending.Count) {
        try {
            foreach ($item in $pending.Pop().EnumerateFileSystemInfos()) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($item -is [IO.DirectoryInfo]) { $pending.Push($item) }
                else { $bytes += $item.Length }
            }
        } catch [UnauthorizedAccessException], [IO.IOException] {
            $partial = $true
        }
    }
    $size = if ($bytes -ge 1GB) { '{0:0.##} GB' -f ($bytes / 1GB) }
        elseif ($bytes -ge 1MB) { '{0:0.##} MB' -f ($bytes / 1MB) }
        elseif ($bytes -ge 1KB) { '{0:0.##} KB' -f ($bytes / 1KB) }
        else { "$bytes B" }
    if ($partial) { return "$size+" }
    return $size
}

function Find-BicdopFolders([string[]]$Roots, [scriptblock]$Matches) {
    $pending = [System.Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $comparer = if ($script:RunningOnWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $seen = [System.Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($root in $Roots) {
        try { $pending.Push((Get-BicdopFolder $root)) }
        catch { Write-Warning "Skipping '${root}': $($_.Exception.Message)" }
    }
    try {
        while ($pending.Count) {
            $item = $pending.Pop()
            if (-not $seen.Add($item.FullName)) { continue }
            if ($seen.Count -eq 1 -or $seen.Count % 25 -eq 0) {
                Write-Progress -Activity 'Scanning folders' -Status "$($seen.Count) folders checked" -CurrentOperation $item.FullName
            }
            if (& $Matches $item) { $item }
            try {
                foreach ($child in $item.EnumerateDirectories()) {
                    if ($child.Name -ne '.git' -and -not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        $pending.Push($child)
                    }
                }
            } catch [UnauthorizedAccessException], [IO.IOException] {
                Write-Verbose "Skipping $($item.FullName): $($_.Exception.Message)"
            }
        }
    } finally {
        Write-Progress -Activity 'Scanning folders' -Completed
    }
}

function Get-BicdopActive($State) {
    if (-not $State.active -or -not $State.workspaces.Contains($State.active)) {
        throw 'No active workspace. Run bicdop workspace --set or --use.'
    }
    return $State.workspaces[$State.active]
}

function Confirm-Bicdop([string]$Message) {
    return (Read-Host "$Message [y/N]") -match '^y(es)?$'
}

function Register-BicdopWorkspace {
    $folder = Get-BicdopFolder
    if (-not (Confirm-Bicdop "Register and activate workspace '$($folder.FullName)'?")) { return }
    $path = Join-Path $folder.FullName '.bicdop-workspace'
    Invoke-BicdopRegistryWrite {
        param($state)
        $marker = Read-BicdopMarker $path
        $created = $null
        if (-not $marker) {
            if (Test-Path -LiteralPath $path) { throw "Invalid workspace marker: $path" }
            $marker = @{ schema = 1; id = [guid]::NewGuid().ToString() }
            $created = Write-BicdopMarker $path $marker
        }
        try {
            $previous = $state.workspaces[$marker.id]
            if ($previous -and -not $previous.path.Equals($folder.FullName, $script:PathComparison)) {
                $other = Read-BicdopMarker (Join-Path $previous.path '.bicdop-workspace')
                if ($other -and $other.id -eq $marker.id) {
                    throw "This workspace ID is also present at '$($previous.path)'. Resolve the duplicate marker first."
                }
                foreach ($project in $state.projects.Values) {
                    if ($project.workspace -ne $marker.id -or -not (Test-BicdopUnder $project.path $previous.path)) { continue }
                    $relative = $project.path.Substring($previous.path.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
                    $candidate = Join-Path $folder.FullName $relative
                    $candidate = [IO.Path]::GetFullPath($candidate)
                    $found = Read-BicdopMarker (Join-Path $candidate '.bicdop')
                    if ($found -and $found.id -eq $project.id) { $project.path = $candidate }
                }
            }
            $state.workspaces[$marker.id] = @{ name = $folder.Name; path = $folder.FullName }
            $state.active = $marker.id
            Save-BicdopRegistry $state
        } catch {
            if ($created -and [IO.File]::Exists($path) -and [IO.File]::ReadAllText($path) -ceq $created) {
                [IO.File]::Delete($path)
            }
            throw
        }
    }
    Write-Host "Active workspace: $($folder.FullName)"
}

function Invoke-BicdopWorkspace([object[]]$Options) {
    $state = Read-BicdopRegistry
    if ($Options.Count -eq 1 -and $Options[0] -eq '--goto') {
        $folder = Get-BicdopFolder (Get-BicdopActive $state).path
        Set-Location -LiteralPath $folder.FullName -ErrorAction Stop
        return
    }
    $items = @($state.workspaces.GetEnumerator() | Sort-Object { $_.Value.name }, { $_.Value.path })
    if ($Options.Count -eq 0) {
        if (-not $items.Count) { Write-Host 'No registered workspaces.'; return }
        for ($i = 0; $i -lt $items.Count; $i++) {
            [pscustomobject][ordered]@{
                PSTypeName = 'Bicdop.WorkspaceRow'
                'No.' = $i + 1
                Name = $items[$i].Value.name
                Path = $items[$i].Value.path
                Active = $items[$i].Key -eq $state.active
                Size = Get-BicdopFolderSize $items[$i].Value.path
            }
        }
        return
    }
    if ($Options.Count -eq 1 -and $Options[0] -eq '--set') { Register-BicdopWorkspace; return }
    if ($Options.Count -eq 1 -and $Options[0] -eq '--find') {
        $found = @(Find-BicdopFolders (Get-BicdopDrives) { param($item)
            [IO.File]::Exists((Join-Path $item.FullName '.bicdop-workspace'))
        })
        if (-not $found.Count) { Write-Host 'No workspace markers found.'; return }
        foreach ($folder in $found) {
            [pscustomobject][ordered]@{
                PSTypeName = 'Bicdop.WorkspaceSearchRow'
                Name = $folder.Name
                FullName = $folder.FullName
                Size = Get-BicdopFolderSize $folder.FullName
            }
        }
        return
    }
    if ($Options.Count -eq 2 -and $Options[0] -eq '--use') {
        $value = [string]$Options[1]
        $selected = if ($value -match '^[1-9][0-9]{0,8}$' -and [int]$value -le $items.Count) {
            $items[[int]$value - 1]
        } else { $items | Where-Object { $_.Value.name -eq $value } }
        if (@($selected).Count -ne 1 -or $null -eq $selected) { throw 'Choose a unique workspace name or its displayed number.' }
        $null = Get-BicdopFolder $selected.Value.path
        Invoke-BicdopRegistryWrite {
            param($latest)
            if (-not $latest.workspaces.Contains($selected.Key)) { throw 'The workspace registration changed. List workspaces again.' }
            $latest.active = $selected.Key
            Save-BicdopRegistry $latest
        }
        $script:ProjectRows = @()
        $script:ListedWorkspace = $null
        Write-Host "Active workspace: $($selected.Value.name)"
        return
    }
    throw 'Usage: bicdop workspace [--set | --find | --goto | --use NAME-OR-NUMBER]'
}

function Write-BicdopFolderRows([IO.DirectoryInfo[]]$Folders, $State) {
    for ($i = 0; $i -lt $Folders.Count; $i++) {
        $folder = $Folders[$i]
        $markerPath = Join-Path $folder.FullName '.bicdop'
        $id = Get-BicdopAssociation $State $folder.FullName (Read-BicdopMarker $markerPath)
        [pscustomobject][ordered]@{
            PSTypeName = 'Bicdop.ScanResult'
            'No.' = $i + 1
            Project = $folder.Name
            Workspace = if ($id) { $State.workspaces[$id].name } else { 'Unassigned' }
            Path = $folder.FullName
            Status = if ([IO.File]::Exists($markerPath)) { 'Planted' } else { 'Not planted' }
            Size = Get-BicdopFolderSize $folder.FullName
        }
    }
}

function Invoke-BicdopScan([object[]]$Options) {
    $script:ScanRows = @()
    $state = Read-BicdopRegistry
    $mode = 'marked'
    $query = ''
    if ($Options.Count -eq 0) { $roots = @((Get-BicdopActive $state).path) }
    elseif ($Options.Count -eq 1 -and $Options[0] -eq '--all') { $roots = @(Get-BicdopDrives) }
    elseif ($Options.Count -eq 1 -and $Options[0] -eq '--git') {
        $mode = 'git'
        $roots = @((Get-BicdopActive $state).path)
    } elseif ($Options.Count -eq 2 -and $Options[0] -in '--project', '--new' -and "$($Options[1])".Trim() -and $Options[1] -notlike '--*') {
        $query = [string]$Options[1]
        if ($Options[0] -eq '--new') {
            $mode = 'new'
            $roots = @(Get-BicdopDrives)
        } else { $roots = @((Get-BicdopFolder (Get-BicdopActive $state).path).FullName) }
    } elseif ($Options.Count -eq 1 -and $Options[0] -notlike '--*') {
        $roots = @((Get-BicdopFolder $Options[0]).FullName)
    } else {
        throw 'Usage: bicdop scan [PATH | --all | --git | --project NAME | --new NAME]'
    }
    if ($mode -ne 'new' -and $Options.Count -lt 2 -and $Options[0] -ne '--all') {
        $null = Get-BicdopFolder $roots[0]
    }
    $found = @(Find-BicdopFolders $roots { param($item)
        if ($query -and $item.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        $planted = [IO.File]::Exists((Join-Path $item.FullName '.bicdop'))
        if ($mode -eq 'git') {
            $git = Join-Path $item.FullName '.git'
            return [IO.Directory]::Exists($git) -or [IO.File]::Exists($git)
        }
        if ($mode -eq 'new') { return -not $planted }
        return $planted
    } | Sort-Object FullName)
    Write-BicdopFolderRows $found $state
    $script:ScanRows = $found
    if (-not $found.Count) { Write-Host 'No matching folders found.' }
}

function Find-BicdopMainFile([string]$Root) {
    foreach ($name in 'main.py', '__main__.py', 'app.py', 'main.ps1', 'main.js', 'index.js', 'app.js', 'main.mjs', 'index.mjs', 'index.html', 'index.htm', 'main.html') {
        if ([IO.File]::Exists((Join-Path $Root $name))) { return $name }
    }
}

function Resolve-BicdopMainFile([string]$Root, [string]$File) {
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::IsPathRooted($File)) { throw 'Use an entry point path relative to the project root.' }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $File))
    if (!$path.StartsWith($prefix, $script:PathComparison) -or ![IO.File]::Exists($path)) {
        throw "Entry point must be an existing file inside the project: $File"
    }
    if ([IO.Path]::GetExtension($path) -notin '.py', '.ps1', '.js', '.mjs', '.cjs', '.html', '.htm') {
        throw 'Supported entry points: Python (.py), PowerShell (.ps1), Node.js (.js, .mjs, .cjs), and HTML (.html, .htm).'
    }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Entry point cannot be a symlink: $path"
    }
    for ($dir = $item.Directory; $dir; $dir = $dir.Parent) {
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Entry point cannot use a symlink or junction: $($dir.FullName)"
        }
    }
    return $path
}

function Set-BicdopProjectField([string]$Root, [string]$Field, [string]$Value) {
    $markerPath = Join-Path $Root '.bicdop'
    Invoke-BicdopRegistryWrite {
        param($state)
        $item = Get-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        if (!$item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'A regular .bicdop project marker is required. Run bicdop plant first.'
        }
        $marker = Read-BicdopMarker $markerPath
        if (!$marker) { throw 'A valid .bicdop project marker is required. Run bicdop marker --replant first.' }
        $marker[$Field] = $Value
        $temp = "$markerPath.$([guid]::NewGuid()).tmp"
        try {
            $null = Write-BicdopMarker $temp $marker
            [IO.File]::Replace($temp, $markerPath, [NullString]::Value)
        } finally {
            [IO.File]::Delete($temp)
        }
        $Value
    }
}

function Find-BicdopProjectVersion([string]$Root) {
    foreach ($name in 'package.json', 'pyproject.toml', 'VERSION') {
        $path = Join-Path $Root $name
        if (![IO.File]::Exists($path)) { continue }
        try {
            $content = [IO.File]::ReadAllText($path)
            $version = switch ($name) {
                'package.json' { (ConvertFrom-Json -InputObject $content -ErrorAction Stop).version }
                'pyproject.toml' {
                    $section = [regex]::Match($content, '(?ms)^\s*\[project\][ \t]*(?:#[^\r\n]*)?\r?\n(.*?)(?=^[ \t]*\[|\z)')
                    if ($section.Success) {
                        $pattern = '(?m)^[ \t]*version[ \t]*=[ \t]*(["''])([^"'']+)\1[ \t]*(?:#[^\r\n]*)?\r?$'
                        $value = [regex]::Match($section.Groups[1].Value, $pattern)
                        if ($value.Success) { $value.Groups[2].Value }
                    }
                }
                'VERSION' { $content.Trim() }
            }
            if ($version -is [string] -and $version -match '^\d[0-9A-Za-z.!+_-]*$') { return $version }
        } catch {
            Write-Verbose "Could not read project version from '$path': $_"
        }
    }
}

function Get-BicdopNamedFolder([string]$Name) {
    $workspace = Get-BicdopActive (Read-BicdopRegistry)
    $matches = @(Get-BicdopChildFolders (Get-BicdopFolder $workspace.path) | Where-Object Name -eq $Name)
    if ($matches.Count -ne 1) { throw "Choose a unique folder in the active workspace: $Name" }
    return $matches[0]
}

function Stop-BicdopPreviousRun([string]$Root) {
    $previous = $script:DetachedRuns[$Root]
    if (!$previous) { return }
    if (!$previous.HasExited) {
        if (!$previous.CloseMainWindow() -or !$previous.WaitForExit(2000)) {
            try { $previous.Kill() }
            catch [InvalidOperationException] {
                if (!$previous.HasExited) { throw }
            }
            if (!$previous.WaitForExit(5000)) {
                throw "Previous project process (PID $($previous.Id)) is still running."
            }
        }
    }
    $script:DetachedRuns.Remove($Root)
    $previous.Dispose()
}

function Invoke-BicdopRun([object[]]$Options) {
    if ($Options.Count -eq 2 -and $Options[0] -eq '--set') {
        $root = (Get-BicdopFolder).FullName
        $path = Resolve-BicdopMainFile $root $Options[1]
        $relative = $path.Substring($root.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1)
        $saved = Set-BicdopProjectField $root 'main_file' $relative
        Write-Host "Main file: $saved"
        return
    }
    $detachCount = @($Options | Where-Object { $_ -eq '--detach' }).Count
    $targets = @($Options | Where-Object { $_ -ne '--detach' })
    if ($detachCount -gt 1 -or $targets.Count -gt 1 -or ($targets.Count -and $targets[0] -like '--*')) {
        throw 'Usage: bicdop run [FOLDER-NAME] [--detach] | bicdop run --set FILE'
    }
    $folder = if ($targets.Count) { Get-BicdopNamedFolder $targets[0] } else { Get-BicdopFolder }

    $marker = Read-BicdopMarker (Join-Path $folder.FullName '.bicdop')
    $file = if ($marker.main_file -is [string] -and $marker.main_file) { $marker.main_file } else { Find-BicdopMainFile $folder.FullName }
    if (!$file) { throw "No main file found in '$($folder.FullName)'. Use bicdop run --set FILE in that folder." }
    $entry = Resolve-BicdopMainFile $folder.FullName $file
    $extension = [IO.Path]::GetExtension($entry)
    if ($extension -in '.html', '.htm') {
        Start-Process -FilePath $entry -ErrorAction Stop
        return
    }
    $runtime = switch ($extension) {
        '.py' {
            $python = Join-Path $folder.FullName '.venv/Scripts/python.exe'
            if (![IO.File]::Exists($python)) {
                $python = (Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
                if (!$python) { throw 'Python was not found on PATH.' }
            }
            $python
        }
        '.ps1' {
            $engine = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
            Join-Path $PSHOME $engine
        }
        default {
            $node = (Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if (!$node) { throw 'Node.js was not found on PATH.' }
            $node
        }
    }
    if ($detachCount) {
        $arguments = if ($extension -eq '.ps1') { '-NoLogo -NoProfile -File "{0}"' -f $entry } else { '"{0}"' -f $entry }
        Stop-BicdopPreviousRun $folder.FullName
        $process = Start-Process -FilePath $runtime -ArgumentList $arguments -WorkingDirectory $folder.FullName -PassThru -ErrorAction Stop
        $script:DetachedRuns[$folder.FullName] = $process
        Write-Host "Started '$($folder.Name)' (PID $($process.Id))."
        return
    }

    Push-Location -LiteralPath $folder.FullName -StackName BicdopRun
    try {
        if ($extension -eq '.ps1') { & $entry }
        else { & $runtime $entry }
        if ($extension -ne '.ps1' -and $LASTEXITCODE -ne 0) {
            throw "Entry point exited with code $LASTEXITCODE."
        }
    } finally {
        Pop-Location -StackName BicdopRun
    }
}

function Invoke-BicdopPlant([object[]]$Options) {
    if ($Options.Count -eq 0) { $paths = @((Get-BicdopFolder).FullName) }
    elseif ($Options.Count -eq 1 -and $Options[0] -eq '--all') {
        $paths = @(Get-BicdopChildFolders (Get-BicdopFolder) |
            Where-Object Name -ne '.git' | ForEach-Object FullName)
    } else {
        if (-not $script:ScanRows.Count) { throw 'No current scan results. Run bicdop scan first.' }
        $numbers = @($Options | ForEach-Object { $_ }) -join ','
        if ($numbers -notmatch '^[1-9][0-9]{0,8}(,[1-9][0-9]{0,8})*$') { throw 'Use bicdop plant 1,3,5 or bicdop plant --all.' }
        $indices = $numbers.Split(',') | ForEach-Object { [int]$_ }
        if (@($indices | Select-Object -Unique).Count -ne @($indices).Count -or
            @($indices | Where-Object { $_ -gt $script:ScanRows.Count }).Count) {
            throw 'Choose distinct row numbers from the latest scan.'
        }
        $paths = @($indices | ForEach-Object { $script:ScanRows[$_ - 1].FullName })
    }

    $state = Read-BicdopRegistry
    $activeRoot = if ($state.active -and $state.workspaces.Contains($state.active)) {
        $state.workspaces[$state.active].path
    }
    $planned = @()
    $skipped = 0
    $errors = 0
    foreach ($path in $paths) {
        try { $folder = Get-BicdopFolder $path }
        catch { Write-Warning "Stale selection '${path}': scan again if it moved."; $errors++; continue }
        if ($activeRoot -and (Test-BicdopUnder $path $activeRoot) -and
            !(Test-BicdopDirectChild $path $activeRoot)) {
            Write-Host "Skipped (marker belongs in the project root): $path"
            $skipped++
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $path '.bicdop')) {
            Write-Host "Skipped (already planted): $path"
            $skipped++
            continue
        }
        $id = Get-BicdopAssociation $state $path $null
        $planned += @{ Folder = $folder; Workspace = $id }
        Write-Host "Selected: $path"
    }
    if ($planned.Count -and (Confirm-Bicdop 'Create markers and register these projects?')) {
        $planted = 0
        foreach ($entry in $planned) {
            $folder = $entry.Folder
            $path = Join-Path $folder.FullName '.bicdop'
            $id = $null
            if ($entry.Workspace) { $id = $entry.Workspace }
            if (-not $id -and $state.active -and $state.workspaces.Contains($state.active) -and
                (Confirm-Bicdop "Assign '$($folder.Name)' to '$($state.workspaces[$state.active].name)'?")) {
                $id = $state.active
            }
            try {
                Invoke-BicdopRegistryWrite {
                    param($latest)
                    if ($id -and -not $latest.workspaces.Contains($id)) { throw 'Chosen workspace no longer exists.' }
                    $marker = @{ schema = 1; id = [guid]::NewGuid().ToString(); workspace = $id; main_file = [string](Find-BicdopMainFile $folder.FullName)
                        version = [string](Find-BicdopProjectVersion $folder.FullName) }
                    $json = Write-BicdopMarker $path $marker
                    try {
                        $latest.projects[$marker.id] = @{ id = $marker.id; name = $folder.Name
                            path = $folder.FullName; workspace = $id }
                        Save-BicdopRegistry $latest
                    } catch {
                        if ([IO.File]::Exists($path) -and [IO.File]::ReadAllText($path) -ceq $json) {
                            [IO.File]::Delete($path)
                        }
                        throw
                    }
                }
                Write-Host "Planted: $($folder.FullName)"
                $planted++
            } catch { Write-Warning "Could not plant '${path}': $($_.Exception.Message)"; $errors++ }
        }
        Write-Host "$planted planted, $skipped skipped, $errors errors."
    } elseif (-not $planned.Count) { Write-Host "0 planted, $skipped skipped, $errors errors." }
}

function Stage-BicdopProjectMarker($Folder, $State, [string]$WorkspaceId, [bool]$Replant) {
    $path = Join-Path $Folder.FullName '.bicdop'
    for ($item = Get-BicdopFolder $Folder.FullName; $item; $item = $item.Parent) {
        if ($item.Name -eq '.git' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Cannot edit a marker through this folder: $($item.FullName)"
        }
    }

    $existing = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($existing -and ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "Expected a regular marker file: $path"
    }
    $registrations = @($state.projects.Values | Where-Object {
        $_.path -and $_.path.Equals($Folder.FullName, $script:PathComparison)
    })
    if (!$existing -and !$registrations.Count -and !$Replant) { return }

    $id = $null
    $mainFile = $null
    $version = $null
    if ($Replant) {
        $marker = Read-BicdopMarker $path
        $version = Find-BicdopProjectVersion $Folder.FullName
        if (!$version) { $version = $marker.version }
        $mainFile = if ($marker.main_file -is [string] -and $marker.main_file) { $marker.main_file } else { Find-BicdopMainFile $Folder.FullName }
        if ($marker -and (!$state.projects.Contains($marker.id) -or $marker.id -in $registrations.id)) {
            $id = $marker.id
        } elseif ($registrations.Count -eq 1) {
            $id = $registrations[0].id
        } else {
            $id = [guid]::NewGuid().ToString()
        }
    }

    $backup = $null
    if ($existing) {
        $backup = "$path.$([guid]::NewGuid()).bak"
        [IO.File]::Move($path, $backup)
    }
    try {
        if ($Replant) {
            $null = Write-BicdopMarker $path @{ schema = 1; id = $id; workspace = $WorkspaceId; main_file = [string]$mainFile; version = [string]$version }
        }
    } catch {
        if ($backup) { [IO.File]::Move($backup, $path) }
        throw
    }
    foreach ($project in $registrations) { $State.projects.Remove($project.id) }
    if ($Replant) {
        $State.projects[$id] = @{ id = $id; name = $Folder.Name; path = $Folder.FullName; workspace = $WorkspaceId }
    }
    return @{ Path = $path; Backup = $backup; Written = $Replant }
}

function Invoke-BicdopMarker([object[]]$Options) {
    if ($Options.Count -notin 1,2 -or $Options[0] -notin '--clear','--replant' -or
        ($Options.Count -eq 2 -and $Options[1] -ne '--all')) {
        throw 'Usage: bicdop marker [--clear | --replant] [--all]'
    }
    $state = Read-BicdopRegistry
    $active = Get-BicdopActive $state
    $root = (Get-BicdopFolder $active.path).FullName
    $replant = $Options[0] -eq '--replant'
    $targets = if ($Options.Count -eq 2 -and $replant) {
        Get-BicdopChildFolders (Get-BicdopFolder $root) | Where-Object Name -ne '.git'
    } elseif ($Options.Count -eq 2) {
        Find-BicdopFolders @($root) { param($folder) !$folder.FullName.Equals($root, $script:PathComparison) }
    } else {
        $folder = Get-BicdopFolder
        if (!(Test-BicdopUnder $folder.FullName $root)) { throw 'The current folder is outside the active workspace.' }
        if ($replant -and !(Test-BicdopDirectChild $folder.FullName $root)) {
            throw 'Replant from a project root one level below the active workspace.'
        }
        $folder
    }
    $targets = @($targets | Where-Object { $_ })
    if (!$targets.Count) { Write-Host 'No target folders found.'; return }
    $action = if ($replant) { 'Replant' } else { 'Clear' }
    Write-Host "Found $($targets.Count) target folder(s)."
    if (!(Confirm-Bicdop "$action project markers in $($targets.Count) folder(s) under '$root'?")) { return }

    $changes = [System.Collections.Generic.List[hashtable]]::new()
    $failed = 0
    $processed = 0
    $script:ScanRows = @()
    $script:ProjectRows = @()
    $script:ListedWorkspace = $null
    Invoke-BicdopRegistryWrite {
        param($latest)
        $current = Get-BicdopActive $latest
        if ($latest.active -ne $state.active -or !$current.path.Equals($active.path, $script:PathComparison)) {
            throw 'The active workspace changed. Run the marker command again.'
        }
        $committed = $false
        try {
            foreach ($folder in $targets) {
                if ($processed % 25 -eq 0) {
                    Write-Progress -Activity "$action project markers" -Status "$processed/$($targets.Count) folders | $($changes.Count) markers updated | $failed errors" -CurrentOperation $folder.FullName -PercentComplete (100 * $processed / $targets.Count)
                }
                $processed++
                try {
                    $change = Stage-BicdopProjectMarker $folder $latest $latest.active $replant
                    if ($change) { $changes.Add($change) }
                } catch {
                    Write-Warning "Could not update marker in '$($folder.FullName)': $_"
                    $failed++
                }
            }
            if ($changes.Count) {
                Write-Progress -Activity "$action project markers" -Status "Saving registry for $($changes.Count) changes" -PercentComplete 100
                Save-BicdopRegistry $latest
            }
            $committed = $true
        } finally {
            foreach ($change in $changes) {
                try {
                    if ($committed) {
                        if ($change.Backup) { [IO.File]::Delete($change.Backup) }
                    } else {
                        if ($change.Written) { [IO.File]::Delete($change.Path) }
                        if ($change.Backup) { [IO.File]::Move($change.Backup, $change.Path) }
                    }
                } catch {
                    Write-Warning "Could not finalize marker '$($change.Path)' (backup: '$($change.Backup)'): $_"
                }
            }
            Write-Progress -Activity "$action project markers" -Completed
        }
        Write-Host "$action completed: $($changes.Count) updated, $($targets.Count - $changes.Count - $failed) skipped, $failed errors."
    }
}

function Show-BicdopFolders([object[]]$Options) {
    if ($Options.Count) { throw 'Usage: bicdop show' }
    $state = Read-BicdopRegistry
    $root = Get-BicdopFolder (Get-BicdopActive $state).path
    $folders = @(Get-BicdopChildFolders $root)
    if (!$folders.Count) { Write-Host 'No folders found in the active workspace.'; return }
    Write-BicdopFolderRows $folders $state
}

function Get-BicdopProjects($State) {
    $null = Get-BicdopActive $State
    $State.projects.Values | Where-Object { $_.workspace -eq $State.active } |
        Sort-Object name, path
}

function Show-BicdopProjects([switch]$IncludeNested) {
    $state = Read-BicdopRegistry
    $root = (Get-BicdopActive $state).path
    $script:ProjectRows = @(Get-BicdopProjects $state | Where-Object {
        $IncludeNested -or ($_.path -and (Test-BicdopDirectChild $_.path $root))
    })
    $script:ListedWorkspace = $state.active
    if (-not $script:ProjectRows.Count) { Write-Host 'No registered projects in this workspace.' }
    for ($i = 0; $i -lt $script:ProjectRows.Count; $i++) {
        $project = $script:ProjectRows[$i]
        [pscustomobject][ordered]@{
            PSTypeName = 'Bicdop.ScanResult'
            'No.' = $i + 1
            Project = $project.name
            Workspace = $state.workspaces[$project.workspace].name
            Path = $project.path
            Status = if (![IO.Directory]::Exists($project.path)) { 'Missing' }
                elseif ([IO.File]::Exists((Join-Path $project.path '.bicdop'))) { 'Planted' }
                else { 'Not planted' }
            Size = Get-BicdopFolderSize $project.path
        }
    }
}

function Switch-BicdopProject([string]$Target) {
    $state = Read-BicdopRegistry
    $projects = @(Get-BicdopProjects $state)
    if ($Target -match '^[1-9][0-9]{0,8}$') {
        if ($script:ListedWorkspace -ne $state.active -or [int]$Target -gt $script:ProjectRows.Count) {
            throw 'Run bicdop projects and select a displayed project number.'
        }
        $selectedId = $script:ProjectRows[[int]$Target - 1].id
        $selected = @($projects | Where-Object { $_.id -eq $selectedId })
    } else {
        $selected = @($projects | Where-Object { $_.name -eq $Target })
        if ($selected.Count -gt 1) {
            Show-BicdopProjects -IncludeNested | Format-Table -AutoSize | Out-Host
            $value = Read-Host 'More than one project matches. Enter its displayed number or press Enter to cancel'
            if (-not $value) { return }
            if ($value -notmatch '^[1-9][0-9]{0,8}$' -or [int]$value -gt $script:ProjectRows.Count -or
                $script:ProjectRows[[int]$value - 1].name -ne $Target) { throw 'Choose a displayed number for a matching project.' }
            Switch-BicdopProject $value
            return
        }
    }
    if ($selected.Count -ne 1) { throw "Project not found: $Target" }
    $project = $selected[0]
    if (-not [IO.Directory]::Exists($project.path)) {
        throw "Project path is missing: $($project.path). Restore the folder or update its registered path as documented."
    }
    $folder = Get-BicdopFolder $project.path
    $marker = Read-BicdopMarker (Join-Path $folder.FullName '.bicdop')
    if (-not $marker -or $marker.id -ne $project.id) { throw "The project marker does not match the registry: $($project.path)" }
    Set-Location -LiteralPath $folder.FullName -ErrorAction Stop
}

function Get-BicdopLatestRelease([object[]]$Options) {
    if ($Options.Count -ne 1 -or $Options[0] -ne '--check') {
        throw 'This source distribution supports update --check only. Install updates from a reviewed checkout.'
    }
    $installed = $ExecutionContext.SessionState.Module.Version
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Biosphir/bicdop/releases/latest' -TimeoutSec 15 -ErrorAction Stop
    $latest = [version]'0.0.0'
    if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v?[0-9]+\.[0-9]+\.[0-9]+$' -or
        -not [version]::TryParse($release.tag_name.TrimStart('v'), [ref]$latest)) {
        throw 'GitHub did not return a supported stable release tag.'
    }
    [pscustomobject]@{ Installed = $installed.ToString(); Latest = $latest.ToString()
        UpdateAvailable = $latest -gt $installed; Notes = $release.body }
}

function ConvertFrom-BicdopInput([string]$Line) {
    $pattern = @'
\G\s*(?:"(?<value>[^"]*)"|'(?<value>[^']*)'|(?<value>[^\s"'|;&<>]+))(?=\s|$)
'@
    $offset = 0
    while ($offset -lt $Line.Length) {
        $remaining = $Line.Substring($offset)
        if ([string]::IsNullOrWhiteSpace($remaining)) { return }
        $token = [regex]::Match($remaining, $pattern)
        if (!$token.Success) {
            throw 'Invalid input. Quote paths with spaces. Enter one Bicdop command per line.'
        }
        $token.Groups['value'].Value
        $offset += $token.Length
    }
}

function Start-BicdopShell {
    while ($true) {
        $line = Read-Host (Get-BicdopPrompt)
        if ($null -eq $line) { return }
        try {
            $words = @(ConvertFrom-BicdopInput $line)
            if ($words.Count -and $words[0] -eq 'bicdop') {
                $words = @($words | Select-Object -Skip 1)
            }
            if (!$words.Count) { continue }
            if ($words[0] -in 'exit','--exit' -and $words.Count -eq 1) { return }
            bicdop @words | Out-Host
        } catch {
            Write-Error -ErrorRecord $_ -ErrorAction Continue
        }
    }
}

function bicdop {
    if (-not $args.Count) { Start-BicdopShell; return }
    $command = $args[0]
    $options = @($args | Select-Object -Skip 1)
    if ($command -eq 'cd..' -and !$options.Count) { $command = 'cd'; $options = @('..') }
    switch ($command) {
        'workspace' { Invoke-BicdopWorkspace $options }
        'scan' { Invoke-BicdopScan $options }
        'plant' { Invoke-BicdopPlant $options }
        'marker' { Invoke-BicdopMarker $options }
        'run' { Invoke-BicdopRun $options }
        'project' {
            $folder = if ($options.Count -eq 2 -and $options[0] -notlike '--*' -and $options[1] -eq '--version') {
                $named = Get-BicdopNamedFolder $options[0]
                $options = @('--version')
                $named
            } else { Get-BicdopFolder }
            if ($options.Count -eq 2 -and $options[0] -eq '--version') {
                if ($options[1] -notmatch '^\d[0-9A-Za-z.!+_-]*$') { throw 'Enter a valid project version, such as 1.2.3.' }
                Set-BicdopProjectField $folder.FullName 'version' $options[1]
                return
            }
            if ($options.Count -ne 1 -or $options[0] -notin '--main','--list','--version') {
                throw 'Usage: bicdop project [--main | --list | --version [VERSION]] or bicdop project PROJECT --version'
            }
            if ($options[0] -eq '--list') {
                Get-ChildItem -LiteralPath $folder.FullName -Force -ErrorAction Stop
                return
            }
            $marker = Read-BicdopMarker (Join-Path $folder.FullName '.bicdop')
            if (!$marker) { throw "No valid .bicdop project marker in '$($folder.FullName)'." }
            if ($options[0] -eq '--version') {
                $declared = Find-BicdopProjectVersion $folder.FullName
                if ($declared -and $declared -cne $marker.version) {
                    Set-BicdopProjectField $folder.FullName 'version' $declared
                } elseif ($marker.version -is [string] -and $marker.version) {
                    $marker.version
                } else {
                    Write-Host 'No project version found. Use bicdop project --version VERSION.'
                }
                return
            }
            if ($marker.main_file -isnot [string] -or !$marker.main_file) {
                Write-Host 'No main file saved. Use bicdop run --set FILE.'
            } else { $marker.main_file }
        }
        'show' { Show-BicdopFolders $options }
        'projects' { if ($options.Count) { throw 'Usage: bicdop projects' }; Show-BicdopProjects }
        'switch' {
            if ($options.Count -ne 1) { throw 'Usage: bicdop switch NUMBER-OR-NAME' }
            Switch-BicdopProject $options[0]
        }
        'cd' {
            if ($options.Count -ne 1) { throw 'Usage: cd PATH' }
            $folder = Get-BicdopFolder $options[0]
            Set-Location -LiteralPath $folder.FullName -ErrorAction Stop
        }
        'mkdir' {
            if ($options.Count -ne 1) { throw 'Usage: mkdir PATH' }
            $provider = $null
            $drive = $null
            $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
                $options[0], [ref]$provider, [ref]$drive
            )
            if ($provider.Name -ne 'FileSystem') { throw 'mkdir requires a filesystem path.' }
            [IO.Directory]::CreateDirectory($path)
        }
        { $_ -in 'li','ls','dir' } {
            if ($options.Count -gt 1) { throw 'Usage: li [PATH]' }
            $target = if ($options.Count) { $options[0] } else { '.' }
            $folder = Get-BicdopFolder $target
            Get-ChildItem -LiteralPath $folder.FullName -ErrorAction Stop
        }
        'pwd' {
            if ($options.Count) { throw 'Usage: pwd' }
            (Get-Location).Path
        }
        { $_ -in 'exit','--exit' } {
            if ($options.Count) { throw 'Usage: exit' }
        }
        'update' { Get-BicdopLatestRelease $options }
        'version' {
            if ($options.Count) { throw 'Usage: bicdop version' }
            Get-BicdopLatestRelease @('--check')
        }
        { $_ -in 'help','--help' } {
            @'
bicdop                                   Start the interactive Bicdop shell
bicdop workspace [--set | --find | --goto | --use NAME-OR-NUMBER]
bicdop scan [PATH | --all | --git | --project NAME | --new NAME]
bicdop plant [1,3,5 | --all]             --all plants direct subfolders of the current folder
bicdop marker [--clear | --replant] [--all]
bicdop projects                          List registered projects one level below the active workspace
bicdop show                              List direct subfolders of the active workspace
bicdop switch NUMBER-OR-NAME
bicdop run [FOLDER-NAME] [--detach]      Run the main file, replacing the previous detached run in this session
bicdop run --set FILE
bicdop project --main                   Show the main file saved in .bicdop
bicdop project --list                   List direct files and folders in the current directory
bicdop project --version [VERSION]      Refresh, show, or set the project version
bicdop project PROJECT --version        Refresh and show a named workspace project version
bicdop version                          Compare installed and latest stable versions
bicdop update --check
bicdop mkdir PATH                        Create a directory
bicdop cd PATH                           Change directory (cd.. moves up one level)
bicdop li [PATH]                         List directory contents (also ls or dir)
bicdop pwd                               Print the current directory

Inside Bicdop, omit the 'bicdop' prefix. Type 'exit' to return to PowerShell.
Quote paths or names that contain spaces.
'@
        }
        default { throw "Unknown Bicdop command '$command'. Run bicdop help." }
    }
}

Export-ModuleMember -Function bicdop
