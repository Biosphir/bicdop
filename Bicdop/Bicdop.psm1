. "$PSScriptRoot/Registry.ps1"

$script:ScanRows = @()
$script:ProjectRows = @()
$script:ListedWorkspace = $null
$script:OriginalPrompt = $null
$script:BicdopPrompt = {
    $location = Get-Location
    "bicdop [$($location.Path)] > "
}

function Enable-BicdopPrompt {
    if ($null -eq $script:OriginalPrompt) {
        $script:OriginalPrompt = (Get-Item Function:prompt).ScriptBlock
        Set-Item Function:global:prompt $script:BicdopPrompt
    }
}

function Disable-BicdopPrompt {
    if ($null -ne $script:OriginalPrompt) {
        if ((Get-Item Function:prompt).ScriptBlock.ToString() -eq $script:BicdopPrompt.ToString()) {
            Set-Item Function:global:prompt $script:OriginalPrompt
        }
        $script:OriginalPrompt = $null
    }
}

$ExecutionContext.SessionState.Module.OnRemove = { Disable-BicdopPrompt }

function Get-BicdopDrives {
    Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root }
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
            if ($seen.Count -eq 1 -or $seen.Count % 100 -eq 0) {
                Write-Progress -Activity 'Scanning folders' -Status "$($seen.Count) checked: $($item.FullName)"
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
    $items = @($state.workspaces.GetEnumerator() | Sort-Object { $_.Value.name }, { $_.Value.path })
    if ($Options.Count -eq 0) {
        if (-not $items.Count) { Write-Host 'No registered workspaces.'; return }
        for ($i = 0; $i -lt $items.Count; $i++) {
            [pscustomobject]@{ 'No.' = $i + 1; Name = $items[$i].Value.name
                Path = $items[$i].Value.path; Active = $items[$i].Key -eq $state.active }
        }
        return
    }
    if ($Options.Count -eq 1 -and $Options[0] -eq '--set') { Register-BicdopWorkspace; return }
    if ($Options.Count -eq 1 -and $Options[0] -eq '--find') {
        $found = @(Find-BicdopFolders (Get-BicdopDrives) { param($item)
            [IO.File]::Exists((Join-Path $item.FullName '.bicdop-workspace'))
        })
        if (-not $found.Count) { Write-Host 'No workspace markers found.'; return }
        $found | Select-Object Name, FullName
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
    throw 'Usage: bicdop workspace [--set | --find | --use NAME-OR-NUMBER]'
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
    for ($i = 0; $i -lt $found.Count; $i++) {
        $folder = $found[$i]
        $markerPath = Join-Path $folder.FullName '.bicdop'
        $id = Get-BicdopAssociation $state $folder.FullName (Read-BicdopMarker $markerPath)
        [pscustomobject][ordered]@{
            PSTypeName = 'Bicdop.ScanResult'
            'No.' = $i + 1
            Project = $folder.Name
            Workspace = if ($id) { $state.workspaces[$id].name } else { 'Unassigned' }
            Path = $folder.FullName
            Status = if ([IO.File]::Exists($markerPath)) { 'Planted' } else { 'Not planted' }
        }
    }
    $script:ScanRows = $found
    if (-not $found.Count) { Write-Host 'No matching folders found.' }
}

function Invoke-BicdopPlant([object[]]$Options) {
    if ($Options.Count -eq 0) { $paths = @((Get-BicdopFolder).FullName) }
    else {
        if (-not $script:ScanRows.Count) { throw 'No current scan results. Run bicdop scan first.' }
        if ($Options.Count -eq 1 -and $Options[0] -eq '--all') {
            $paths = @($script:ScanRows.FullName)
        } else {
            $numbers = @($Options | ForEach-Object { $_ }) -join ','
            if ($numbers -notmatch '^[1-9][0-9]{0,8}(,[1-9][0-9]{0,8})*$') { throw 'Use bicdop plant 1,3,5 or bicdop plant --all.' }
            $indices = $numbers.Split(',') | ForEach-Object { [int]$_ }
            if (@($indices | Select-Object -Unique).Count -ne @($indices).Count -or
                @($indices | Where-Object { $_ -gt $script:ScanRows.Count }).Count) {
                throw 'Choose distinct row numbers from the latest scan.'
            }
            $paths = @($indices | ForEach-Object { $script:ScanRows[$_ - 1].FullName })
        }
    }

    $state = Read-BicdopRegistry
    $planned = @()
    $skipped = 0
    $errors = 0
    foreach ($path in $paths) {
        try { $folder = Get-BicdopFolder $path }
        catch { Write-Warning "Stale selection '${path}': scan again if it moved."; $errors++; continue }
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
            $id = $entry.Workspace
            if (-not $id -and $state.active -and $state.workspaces.Contains($state.active) -and
                (Confirm-Bicdop "Assign '$($folder.Name)' to '$($state.workspaces[$state.active].name)'?")) {
                $id = $state.active
            }
            try {
                Invoke-BicdopRegistryWrite {
                    param($latest)
                    if ($id -and -not $latest.workspaces.Contains($id)) { throw 'Chosen workspace no longer exists.' }
                    $marker = @{ schema = 1; id = [guid]::NewGuid().ToString(); workspace = $id }
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

function Get-BicdopProjects($State) {
    $null = Get-BicdopActive $State
    $State.projects.Values | Where-Object { $_.workspace -eq $State.active } |
        Sort-Object name, path
}

function Show-BicdopProjects {
    $state = Read-BicdopRegistry
    $script:ProjectRows = @(Get-BicdopProjects $state)
    $script:ListedWorkspace = $state.active
    if (-not $script:ProjectRows.Count) { Write-Host 'No registered projects in this workspace.' }
    for ($i = 0; $i -lt $script:ProjectRows.Count; $i++) {
        $project = $script:ProjectRows[$i]
        [pscustomobject]@{ 'No.' = $i + 1; Project = $project.name; Path = $project.path
            Status = if ([IO.Directory]::Exists($project.path)) { 'Registered' } else { 'Missing' } }
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
            Show-BicdopProjects | Format-Table -AutoSize | Out-Host
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

function bicdop {
    if (-not $args.Count) { Enable-BicdopPrompt; return }
    $command = $args[0]
    $options = @($args | Select-Object -Skip 1)
    switch ($command) {
        'workspace' { Invoke-BicdopWorkspace $options }
        'scan' { Invoke-BicdopScan $options }
        'plant' { Invoke-BicdopPlant $options }
        'projects' { if ($options.Count) { throw 'Usage: bicdop projects' }; Show-BicdopProjects }
        'switch' {
            if ($options.Count -ne 1) { throw 'Usage: bicdop switch NUMBER-OR-NAME' }
            Switch-BicdopProject $options[0]
        }
        'exit' { if ($options.Count) { throw 'Usage: bicdop exit' }; Disable-BicdopPrompt }
        'update' { Get-BicdopLatestRelease $options }
        'help' {
            @'
bicdop                                   Enable the Bicdop prompt
bicdop workspace [--set | --find | --use NAME-OR-NUMBER]
bicdop scan [PATH | --all | --git | --project NAME | --new NAME]
bicdop plant [1,3,5 | --all]
bicdop projects
bicdop switch NUMBER-OR-NAME
bicdop update --check
bicdop exit                              Restore the PowerShell prompt
'@
        }
        default { throw "Unknown Bicdop command '$command'. Run bicdop help." }
    }
}

Export-ModuleMember -Function bicdop
