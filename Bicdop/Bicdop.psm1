. "$PSScriptRoot/Registry.ps1"
. "$PSScriptRoot/Update.ps1"

$script:ScanRows = @()
$script:ProjectRows = @()
$script:ListedWorkspace = $null
$script:DetachedRuns = @{}
$script:WebPreviews = @{}
$script:BicdopSessionName = $null
$script:BicdopResumeLogLimit = 10
function Get-BicdopPrompt([switch]$Display, [switch]$UpdateTitle) {
    $location = Get-Location
    $workspaceLabel = ' no-workspace-selected'
    try {
        $state = Read-BicdopRegistry
        if ($state.active -and $state.workspaces.Contains($state.active)) {
            $workspaceLabel = " $($state.workspaces[$state.active].name)"
        }
    } catch {
        # Keep the shell usable if the registry cannot be read.
    }
    if ($UpdateTitle) {
        $workspaceTitle = ($workspaceLabel -replace '[\p{Cc}\p{Cf}]', '').Trim()
        if (!$workspaceTitle) { $workspaceTitle = 'no-workspace-selected' }
        $title = "Bicdop $($ExecutionContext.SessionState.Module.Version) | $workspaceTitle"
        try {
            if ($Host.UI.RawUI.WindowTitle -cne $title) { $Host.UI.RawUI.WindowTitle = $title }
        } catch { Write-Verbose 'This terminal does not expose a writable title.' }
    }
    if ($Display) {
        if ($Host.UI.SupportsVirtualTerminal) {
            $esc = [char]27
            Write-Host "$esc[38;2;139;79;224mbicdop$esc[39m" -NoNewline
        } else {
            Write-Host 'bicdop' -ForegroundColor Magenta -NoNewline
        }
        if ($workspaceLabel) { Write-Host $workspaceLabel -ForegroundColor Blue -NoNewline }
        Write-Host " [$($location.Path)] > : " -NoNewline
        return
    }
    "bicdop$workspaceLabel [$($location.Path)] > "
}

function Write-BicdopSyntax([string]$Text, [switch]$NoNewline) {
    $pattern = @'
(?<adapted>^[ \t]*(?:bicdop[ \t]+)?(?<native>cd\.\.|cd|dir|flush|li|ls|mkdir|ping|pwd|rmdir)(?=\s|$))|(?<quoted>"[^"\r\n]*"|'[^'\r\n]*')|(?<flag>(?<![\w-])--[A-Za-z][A-Za-z0-9-]*)
'@
    $offset = 0
    foreach ($token in [regex]::Matches($Text, $pattern)) {
        if ($token.Index -gt $offset) {
            Write-Host $Text.Substring($offset, $token.Index - $offset) -NoNewline
        }
        if ($token.Groups['adapted'].Success) {
            $native = $token.Groups['native']
            $prefixLength = $native.Index - $token.Index
            if ($prefixLength) { Write-Host $token.Value.Substring(0, $prefixLength) -NoNewline }
            Write-Host $native.Value -ForegroundColor Yellow -NoNewline
        } elseif ($token.Groups['quoted'].Success) {
            Write-Host $token.Value -ForegroundColor Blue -NoNewline
        } elseif ($Host.UI.SupportsVirtualTerminal) {
            $esc = [char]27
            Write-Host "$esc[38;2;108;108;108m$($token.Value)$esc[39m" -NoNewline
        } else {
            Write-Host $token.Value -ForegroundColor DarkGray -NoNewline
        }
        $offset = $token.Index + $token.Length
    }
    Write-Host $Text.Substring($offset) -NoNewline:$NoNewline
}

function Read-BicdopConsoleLine($RawUI, [string[]]$History) {
    $start = $RawUI.CursorPosition
    $width = $RawUI.BufferSize.Width - $start.X - 1
    if ($width -lt 8) {
        Write-Host ''
        $start = $RawUI.CursorPosition
        $width = $RawUI.BufferSize.Width - $start.X - 1
        if ($width -lt 1) { return Read-Host }
    }
    $index = $History.Count
    $draft = ''
    $line = ''
    $cursor = 0
    $left = 0
    $controlC = [Console]::TreatControlCAsInput
    try {
        [Console]::TreatControlCAsInput = $true
        while ($true) {
            $key = [Console]::ReadKey($true)
            $control = $key.Modifiers -band [ConsoleModifiers]::Control
            if ($key.Key -eq [ConsoleKey]::Enter -or ($control -and $key.Key -eq [ConsoleKey]::C)) {
                $RawUI.CursorPosition = $start
                Write-Host (' ' * $width) -NoNewline
                $RawUI.CursorPosition = $start
                if (!$control -or $key.Key -eq [ConsoleKey]::Enter) {
                    Write-BicdopSyntax $line
                    return $line
                }
                Write-Host '^C'
                return ''
            }
            if ($control -and $key.Key -eq [ConsoleKey]::Z -and !$line) {
                Write-Host ''
                return $null
            }
            switch ($key.Key) {
                'UpArrow' {
                    if ($index -gt 0) {
                        if ($index -eq $History.Count) { $draft = $line }
                        $index--
                        $line = $History[$index]
                        $cursor = $line.Length
                    }
                }
                'DownArrow' {
                    if ($index -lt $History.Count) {
                        $index++
                        $line = if ($index -eq $History.Count) { $draft } else { $History[$index] }
                        $cursor = $line.Length
                    }
                }
                'LeftArrow' { if ($cursor -gt 0) { $cursor-- } }
                'RightArrow' { if ($cursor -lt $line.Length) { $cursor++ } }
                'Home' { $cursor = 0 }
                'End' { $cursor = $line.Length }
                'Escape' { $line = ''; $cursor = 0; $index = $History.Count }
                'Backspace' {
                    if ($cursor -gt 0) {
                        $cursor--
                        $line = $line.Remove($cursor, 1)
                    }
                }
                'Delete' { if ($cursor -lt $line.Length) { $line = $line.Remove($cursor, 1) } }
                default {
                    if (![char]::IsControl($key.KeyChar)) {
                        $line = $line.Insert($cursor, [string]$key.KeyChar)
                        $cursor++
                    }
                }
            }

            $left = [Math]::Min($left, $cursor)
            while ($left -lt $cursor -and $RawUI.LengthInBufferCells($line.Substring($left, $cursor - $left)) -ge $width) {
                $left++
            }
            $visibleLength = [Math]::Min($width, $line.Length - $left)
            while ($visibleLength -gt 0 -and $RawUI.LengthInBufferCells($line.Substring($left, $visibleLength)) -gt $width) {
                $visibleLength--
            }
            $visible = $line.Substring($left, $visibleLength)
            $RawUI.CursorPosition = $start
            Write-Host ($visible + (' ' * ($width - $RawUI.LengthInBufferCells($visible)))) -NoNewline
            $position = $start
            $position.X += $RawUI.LengthInBufferCells($line.Substring($left, $cursor - $left))
            $RawUI.CursorPosition = $position
        }
    } finally {
        [Console]::TreatControlCAsInput = $controlC
    }
}

function Read-BicdopConfirmation([string]$Message) {
    Write-Host "$Message " -ForegroundColor Yellow -NoNewline
    Read-Host
}

function Write-BicdopProjectTable {
    begin {
        $raw = $Host.UI.RawUI
        $projectStart = -1
        $workspaceStart = -1
    }
    process {
        $line = [string]$_
        $plain = $line -replace '\x1b\[[0-9;]*m', ''
        if ($plain -match '^\s*No\.\s+Project\s+Workspace\s+Path\s+') {
            $projectStart = $plain.IndexOf('Project', [StringComparison]::Ordinal)
            $workspaceStart = $plain.IndexOf('Workspace', [StringComparison]::Ordinal)
        } elseif ($projectStart -ge 0 -and $raw -and $plain.Length -gt $projectStart -and
            $plain -notmatch '^\s*-+\s+-+') {
            $end = $projectStart
            $cells = $projectStart
            while ($end -lt $plain.Length -and $cells -lt $workspaceStart) {
                $cells += $raw.LengthInBufferCells($plain[$end])
                $end++
            }
            $name = $plain.Substring($projectStart, $end - $projectStart).TrimEnd()
            if ($name.Trim()) {
                Write-Host $plain.Substring(0, $projectStart) -NoNewline
                Write-Host $name -ForegroundColor Cyan -NoNewline
                Write-Host $plain.Substring($projectStart + $name.Length)
                return
            }
        }
        Write-Host $line
    }
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
    $folders = 0
    $displayed = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($pending.Count) {
            $directory = $pending.Pop()
            try {
                foreach ($item in $directory.EnumerateFileSystemInfos()) {
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ($item -is [IO.DirectoryInfo]) { $pending.Push($item) }
                    else { $bytes += $item.Length }
                }
            } catch [UnauthorizedAccessException], [IO.IOException] {
                $partial = $true
            }
            $folders++
            if ($timer.ElapsedMilliseconds -ge 500) {
                Write-Progress -Id 10 -Activity 'Calculating folder size' -Status "$folders folders checked" -CurrentOperation $Path
                $displayed = $true
                $timer.Restart()
            }
        }
    } finally {
        if ($displayed) { Write-Progress -Id 10 -Activity 'Calculating folder size' -Completed }
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
    return (Read-BicdopConfirmation "$Message [y/N]:") -match '^y(es)?$'
}

function Register-BicdopWorkspace {
    $folder = Get-BicdopFolder
    if (!(Confirm-Bicdop "Register and activate workspace '$($folder.FullName)'?")) {
        Write-Host 'Workspace registration cancelled.'
        return
    }
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
    foreach ($name in 'main.py', '__main__.py', 'app.py', 'main.ps1', 'main.js', 'index.js', 'app.js', 'main.mjs', 'index.mjs', 'index.html', 'index.htm', 'main.html', 'index.php', 'main.php') {
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
    if ([IO.Path]::GetExtension($path) -notin '.py', '.ps1', '.js', '.mjs', '.cjs', '.html', '.htm', '.php', '.exe') {
        throw 'Supported entry points: Python (.py), PowerShell (.ps1), Node.js (.js, .mjs, .cjs), HTML (.html, .htm), PHP (.php), and Windows executables (.exe).'
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

function Set-BicdopProjectField([string]$Root, [string]$Field, [object]$Value) {
    $markerPath = Join-Path $Root '.bicdop'
    Invoke-BicdopRegistryWrite {
        param($state)
        $item = Get-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        if (!$item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'A regular .bicdop project marker is required. Run bicdop plant first.'
        }
        $marker = Read-BicdopMarker $markerPath
        if (!$marker) { throw 'A valid .bicdop project marker is required. Run bicdop marker --replant first.' }
        if ($Field -eq 'github_url' -and (!$marker.github_release_url -or $marker.github_release_url -ieq $marker.github_url)) {
            $marker.github_release_url = $Value
        } elseif ($Field -eq 'github_release_url' -and !$Value) {
            $Value = $marker.github_url
        }
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

function Find-BicdopExplorerWindow($Shell, [string]$Path) {
    $target = $Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
    foreach ($window in $Shell.Windows()) {
        try {
            if ([IO.Path]::GetFileName($window.FullName) -ine 'explorer.exe') { continue }
            $current = [string]$window.Document.Folder.Self.Path
            if (!$current) {
                $uri = $null
                if ([uri]::TryCreate([string]$window.LocationURL, [UriKind]::Absolute, [ref]$uri) -and $uri.IsFile) {
                    $current = $uri.LocalPath
                }
            }
            if ($current -and $current.TrimEnd([IO.Path]::DirectorySeparatorChar).Equals($target, $script:PathComparison)) {
                return [IntPtr]$window.HWND
            }
        } catch [Runtime.InteropServices.COMException] {
            # A window can close or change tabs during enumeration.
        }
    }
}

function Open-BicdopExplorer([string]$Path) {
    try {
        $shell = New-Object -ComObject Shell.Application -ErrorAction Stop
        $window = Find-BicdopExplorerWindow $shell $Path
        if (!$window) {
            Invoke-Item -LiteralPath $Path -ErrorAction Stop
            for ($attempt = 0; $attempt -lt 30 -and !$window; $attempt++) {
                Start-Sleep -Milliseconds 100
                $window = Find-BicdopExplorerWindow $shell $Path
            }
        }
        if (!$window) { return }
        if (!('Bicdop.ExplorerActivation' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Bicdop {
    public static class ExplorerActivation {
        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr handle);
        [DllImport("user32.dll")]
        public static extern bool ShowWindowAsync(IntPtr handle, int command);
        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr handle);

        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr handle, IntPtr insertAfter, int x, int y,
                                                int width, int height, uint flags);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr handle, IntPtr process);

        [DllImport("user32.dll")]
        private static extern bool AttachThreadInput(uint source, uint target, bool attach);

        public static bool Activate(IntPtr handle) {
            if (SetForegroundWindow(handle)) return true;

            uint thread = GetCurrentThreadId();
            uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
            if (foreground != 0 && foreground != thread && AttachThreadInput(thread, foreground, true)) {
                try {
                    if (SetForegroundWindow(handle)) return true;
                } finally {
                    AttachThreadInput(thread, foreground, false);
                }
            }

            const uint noSize = 0x0001;
            const uint noMove = 0x0002;
            const uint showWindow = 0x0040;
            return SetWindowPos(handle, IntPtr.Zero, 0, 0, 0, 0, noSize | noMove | showWindow);
        }
    }
}
"@
        }
        if ([Bicdop.ExplorerActivation]::IsIconic($window)) {
            $null = [Bicdop.ExplorerActivation]::ShowWindowAsync($window, 9)
        }
        if (![Bicdop.ExplorerActivation]::Activate($window)) {
            Write-Verbose 'Windows did not allow Explorer to be moved in front.'
        }
    } catch {
        Write-Verbose "Explorer activation unavailable: $_"
        Invoke-Item -LiteralPath $Path -ErrorAction Stop
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
        Write-Host "Stopping the previous run (PID $($previous.Id))..."
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
    $script:WebPreviews.Remove($Root)
    $previous.Dispose()
}

function Get-BicdopPython([string]$Root) {
    $python = Join-Path $Root '.venv/Scripts/python.exe'
    if (![IO.File]::Exists($python)) {
        $python = (Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (!$python) { throw 'Python was not found on PATH.' }
    }
    return $python
}

function ConvertTo-BicdopPyInstallerArgs([string]$Command) {
    $tokens = @(ConvertFrom-BicdopInput $Command)
    if ($tokens.Count -lt 4 -or $tokens[0] -notin 'python','python.exe' -or
        $tokens[1] -ne '-m' -or $tokens[2] -ine 'PyInstaller') {
        throw 'Enter a full command, for example: python -m PyInstaller --clean Notcher.spec'
    }
    $tokens | Select-Object -Skip 3
}

function Invoke-BicdopPyInstaller([object[]]$Options) {
    $set = $Options.Count -eq 2 -and $Options[0] -eq '--set'
    if (!$set -and ($Options.Count -gt 1 -or ($Options.Count -and $Options[0] -like '--*'))) {
        throw 'Usage: bicdop pyinstaller [PROJECT] | bicdop pyinstaller --set "COMMAND-LINE"'
    }
    $folder = if (!$set -and $Options.Count) { Get-BicdopNamedFolder $Options[0] } else { Get-BicdopFolder }
    $marker = Read-BicdopMarker (Join-Path $folder.FullName '.bicdop')
    if (!$marker) { throw "No valid .bicdop project marker in '$($folder.FullName)'. Run bicdop plant first." }

    $command = if ($set) { [string]$Options[1] } else { $marker.pyinstaller_command }
    $needsPreset = !$set -and ($command -isnot [string] -or [string]::IsNullOrWhiteSpace($command))
    if ($needsPreset) {
        $command = Read-BicdopConfirmation "Full PyInstaller command for '$($folder.Name)' (Enter to cancel):"
        if ([string]::IsNullOrWhiteSpace($command)) { Write-BicdopResult 'PyInstaller build cancelled.'; return }
    }
    $buildArgs = @(ConvertTo-BicdopPyInstallerArgs $command)
    if ($set -or $needsPreset) {
        $saved = Set-BicdopProjectField $folder.FullName 'pyinstaller_command' $command.Trim()
        Write-Host "Saved PyInstaller command: $saved"
        if ($set) { return }
    }

    $python = Get-BicdopPython $folder.FullName
    Write-Host "Building '$($folder.Name)' with PyInstaller..."
    Push-Location -LiteralPath $folder.FullName -StackName BicdopPyInstaller
    try {
        & $python -m PyInstaller @buildArgs
        if ($LASTEXITCODE -ne 0) { throw "PyInstaller exited with code $LASTEXITCODE." }
        Write-BicdopResult "Build complete. See the PyInstaller output for the destination."
    } finally {
        Pop-Location -StackName BicdopPyInstaller
    }
}

function Open-BicdopPreviewUrl([string]$Url) {
    Start-Process -FilePath $Url -ErrorAction Stop
}

function Invoke-BicdopWebPreview([string]$Root, [string]$Entry, [string]$Extension) {
    $directory = [IO.Path]::GetDirectoryName($Entry)
    $serverType = if ($Extension -eq '.php') { 'PHP' } else { 'HTML' }
    $preview = $script:WebPreviews[$Root]
    $process = $script:DetachedRuns[$Root]
    if (!$preview -or !$process -or $process.HasExited -or
        $preview.Directory -ne $directory -or $preview.Type -ne $serverType) {
        if ($serverType -eq 'PHP') {
            $runtime = (Get-Command php -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if (!$runtime) { throw 'PHP CLI was not found. Install PHP and make php.exe available on PATH, then retry run.' }
        } else {
            $runtime = Get-BicdopPython $Root
        }

        Stop-BicdopPreviousRun $Root
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try { $port = $listener.LocalEndpoint.Port }
        finally { $listener.Stop() }

        $arguments = if ($serverType -eq 'PHP') { "-S 127.0.0.1:${port}" }
        else { "-m http.server $port --bind 127.0.0.1" }
        Write-Host "Starting $serverType preview on 127.0.0.1:${port}..."
        $process = Start-Process -FilePath $runtime -ArgumentList $arguments -WorkingDirectory $directory -WindowStyle Hidden -PassThru -ErrorAction Stop
        $script:DetachedRuns[$Root] = $process

        try {
            $ready = $false
            $timeout = [Diagnostics.Stopwatch]::StartNew()
            while (!$ready -and !$process.HasExited -and $timeout.ElapsedMilliseconds -lt 5000) {
                $client = [Net.Sockets.TcpClient]::new()
                try {
                    $connection = $client.ConnectAsync([Net.IPAddress]::Loopback, $port)
                    $ready = $connection.Wait(150)
                } catch [AggregateException] {
                    Start-Sleep -Milliseconds 100
                } finally { $client.Dispose() }
            }
            if (!$ready -or $process.HasExited) {
                throw "The $serverType preview server did not start in '$directory'. Check the runtime installation and retry run."
            }
        } catch {
            Stop-BicdopPreviousRun $Root
            throw
        }
        $preview = @{ Directory = $directory; Type = $serverType; Port = $port }
        $script:WebPreviews[$Root] = $preview
    }

    $name = [uri]::EscapeDataString([IO.Path]::GetFileName($Entry))
    $url = "http://127.0.0.1:$($preview.Port)/$name"
    Open-BicdopPreviewUrl $url
    Write-BicdopResult "Preview: $url (PID $($process.Id)). Use stop to end it."
}

function Get-BicdopProjectToolchain([string]$Root) {
    foreach ($signature in 'platformio.ini','go.mod','Cargo.toml','pom.xml','gradlew.bat','build.gradle','build.gradle.kts','package.json','CMakeLists.txt') {
        if (![IO.File]::Exists((Join-Path $Root $signature))) { continue }
        return $(switch -Exact ($signature) {
            'platformio.ini' { 'PlatformIO' }
            'go.mod' { 'Go' }
            'Cargo.toml' { 'Cargo' }
            'pom.xml' { 'Maven' }
            { $_ -in 'gradlew.bat','build.gradle','build.gradle.kts' } { 'Gradle' }
            'package.json' { 'npm' }
            'CMakeLists.txt' {
                if ([IO.File]::ReadAllText((Join-Path $Root $signature)) -match 'esp-idf|ENV\{IDF_PATH\}') { 'ESP-IDF' }
                else { 'CMake' }
            }
        })
    }
}

function Invoke-BicdopProjectTool([string]$Tool, [string[]]$Arguments) {
    $command = if ([IO.Path]::IsPathRooted($Tool)) { $Tool }
    else { (Get-Command $Tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if (!$command) { throw "Required tool '$Tool' was not found on PATH. Install or activate the project's toolchain and retry." }
    Write-Host "$Tool $($Arguments -join ' ')"
    & $command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "'$Tool' exited with code $LASTEXITCODE." }
}

function Invoke-BicdopProjectTask($Folder, [string]$Action, [string]$Toolchain) {
    $root = $Folder.FullName
    Push-Location -LiteralPath $root -StackName BicdopProjectTask
    try {
        Write-Host "Running $Action for '$($Folder.Name)' ($Toolchain) in '$root'..."
        switch ($Toolchain) {
            'Go' {
                $target = if ($Action -eq 'test') { './...' } else { '.' }
                Invoke-BicdopProjectTool 'go' @($Action, $target)
            }
            'Cargo' { Invoke-BicdopProjectTool 'cargo' @($Action) }
            'Maven' {
                $tool = if ([IO.File]::Exists((Join-Path $root 'mvnw.cmd'))) { Join-Path $root 'mvnw.cmd' } else { 'mvn' }
                $goal = @{ run = 'exec:java'; build = 'package'; test = 'test' }[$Action]
                Invoke-BicdopProjectTool $tool @($goal)
            }
            'Gradle' {
                $tool = if ([IO.File]::Exists((Join-Path $root 'gradlew.bat'))) { Join-Path $root 'gradlew.bat' } else { 'gradle' }
                Invoke-BicdopProjectTool $tool @($Action)
            }
            'npm' {
                $package = Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                $scriptName = if ($Action -eq 'run') {
                    if ($package.scripts.dev) { 'dev' } elseif ($package.scripts.start) { 'start' }
                } elseif ($package.scripts.$Action) { $Action }
                if (!$scriptName) { throw "No npm script for '$Action' in package.json. Add a dev, start, build, or test script as appropriate." }
                Invoke-BicdopProjectTool 'npm.cmd' @('run', $scriptName)
            }
            'PlatformIO' {
                switch ($Action) {
                    'build' { Invoke-BicdopProjectTool 'pio' @('run') }
                    'test' { Invoke-BicdopProjectTool 'pio' @('test') }
                    'flash' { Invoke-BicdopProjectTool 'pio' @('run', '-t', 'upload') }
                    default { throw 'Use build for firmware or flash to upload it to the board configured in platformio.ini.' }
                }
            }
            'ESP-IDF' {
                if ($Action -notin 'build','flash') { throw 'Use build or flash from a shell configured for ESP-IDF.' }
                $idf = if ($env:IDF_PATH) { Join-Path $env:IDF_PATH 'tools/idf.py' }
                if (!$idf -or ![IO.File]::Exists($idf)) {
                    throw 'Activate the ESP-IDF environment first so IDF_PATH points to the SDK and its Python is on PATH.'
                }
                Invoke-BicdopProjectTool 'python' @($idf, $Action)
            }
            'CMake' {
                if ($Action -eq 'run') {
                    throw 'Build the CMake project first, then use run --set PATH-TO-EXE for a Windows app. For Pico firmware, find the UF2 in the build directory.'
                }
                $buildDirectory = '.bicdop-build'
                Invoke-BicdopProjectTool 'cmake' @('-S', '.', '-B', $buildDirectory)
                Invoke-BicdopProjectTool 'cmake' @('--build', $buildDirectory, '--config', 'Debug')
                if ($Action -eq 'test') {
                    Invoke-BicdopProjectTool 'ctest' @('--test-dir', $buildDirectory, '-C', 'Debug', '--output-on-failure')
                }
            }
        }
        Write-BicdopResult "$Action completed for '$($Folder.Name)'."
    } finally { Pop-Location -StackName BicdopProjectTask }
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
    $file = if ($marker.main_file -is [string] -and $marker.main_file) { $marker.main_file }
    if (!$file) {
        $toolchain = Get-BicdopProjectToolchain $folder.FullName
        if ($toolchain) {
            if ($detachCount) { throw 'Use run without --detach for toolchain projects. Press Ctrl+C to stop a foreground task.' }
            Invoke-BicdopProjectTask $folder 'run' $toolchain
            return
        }
        $file = Find-BicdopMainFile $folder.FullName
    }
    if (!$file) { throw "No main file found in '$($folder.FullName)'. Use bicdop run --set FILE in that folder." }
    $entry = Resolve-BicdopMainFile $folder.FullName $file
    $extension = [IO.Path]::GetExtension($entry)
    if ($extension -in '.html', '.htm', '.php') {
        Invoke-BicdopWebPreview $folder.FullName $entry $extension
        return
    }
    $runtime = switch ($extension) {
        '.exe' { $entry }
        '.py' { Get-BicdopPython $folder.FullName }
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
        $arguments = if ($extension -eq '.ps1') { '-NoLogo -NoProfile -File "{0}"' -f $entry } elseif ($extension -ne '.exe') { '"{0}"' -f $entry }
        Stop-BicdopPreviousRun $folder.FullName
        $processOptions = @{ FilePath = $runtime; WorkingDirectory = $folder.FullName; PassThru = $true; ErrorAction = 'Stop' }
        if ($arguments) { $processOptions.ArgumentList = $arguments }
        $process = Start-Process @processOptions
        $script:DetachedRuns[$folder.FullName] = $process
        Write-BicdopResult "Started '$($folder.Name)' (PID $($process.Id))."
        return
    }

    Write-Host "Running '$file' in '$($folder.Name)'..."
    Push-Location -LiteralPath $folder.FullName -StackName BicdopRun
    try {
        if ($extension -eq '.ps1') { & $entry }
        elseif ($extension -eq '.exe') { & $runtime }
        else { & $runtime $entry }
        if ($extension -ne '.ps1' -and $LASTEXITCODE -ne 0) {
            throw "Entry point exited with code $LASTEXITCODE."
        }
        Write-BicdopResult "Run finished: $file"
    } finally {
        Pop-Location -StackName BicdopRun
    }
}

function Get-BicdopGitHubUrl([string]$Root) {
    if (!(Test-Path -LiteralPath (Join-Path $Root '.git'))) { return }
    $ErrorActionPreference = 'Continue'
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$git) { return }
    $repository = & $git.Source -C $Root rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or !$repository -or
        ![IO.Path]::GetFullPath($repository).Equals([IO.Path]::GetFullPath($Root), $script:PathComparison)) { return }

    $remote = & $git.Source -C $Root remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or !$remote) { return }
    ConvertTo-BicdopGitHubUrl $remote
}

function ConvertTo-BicdopGitHubUrl([string]$Remote) {
    if ($remote -match '^git@github\.com:(?<path>[^?#]+)$') {
        $repoPath = $Matches.path
    } else {
        $uri = $null
        if (![uri]::TryCreate([string]$remote, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Host -ne 'github.com' -or $uri.Scheme -notin 'https','ssh') { return }
        $repoPath = $uri.AbsolutePath.Trim('/')
    }
    $repoPath = $repoPath -replace '\.git$', ''
    if ($repoPath -match '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$' -and
        ($repoPath.Split('/')[1] -notin '.','..')) {
        return "https://github.com/$repoPath"
    }
}

function Get-BicdopGitRepository([string]$Path = '.') {
    $root = (Get-BicdopFolder $Path).FullName
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$git) { throw 'Git was not found on PATH.' }

    $ErrorActionPreference = 'Continue'
    $repository = & $git.Source -C $root rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or !$repository -or
        ![IO.Path]::GetFullPath($repository).Equals([IO.Path]::GetFullPath($root), $script:PathComparison)) {
        throw 'The current folder is not the root of a Git repository.'
    }
    [pscustomobject]@{ Root = $root; Git = $git.Source }
}

function Get-BicdopGitOriginRef($Repository, [string]$Branch, [switch]$RequireOrigin) {
    $ErrorActionPreference = 'Continue'
    $trackingRemote = & $Repository.Git -C $Repository.Root config --get "branch.$Branch.remote" 2>$null
    if ($trackingRemote -ceq 'origin') {
        $trackingRef = & $Repository.Git -C $Repository.Root config --get "branch.$Branch.merge" 2>$null
        if ($trackingRef -clike 'refs/heads/*') { return $trackingRef }
    } elseif ($RequireOrigin -and $trackingRemote) {
        throw 'This branch tracks another remote. Set its upstream to origin before using github --pull or --push.'
    }
    "refs/heads/$Branch"
}

function Show-BicdopGitHubStatus([string]$Path = '.') {
    $repository = Get-BicdopGitRepository $Path
    $root = $repository.Root
    $ErrorActionPreference = 'Continue'
    $url = Get-BicdopGitHubUrl $root
    $branch = & $repository.Git -C $root symbolic-ref --quiet --short HEAD 2>$null
    $local = & $repository.Git -C $root rev-parse --verify HEAD 2>$null
    $changes = @(& $repository.Git --no-optional-locks -C $root -c core.quotePath=false status --porcelain=v1 --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the local Git working tree.' }
    $staged = [Collections.Generic.List[string]]::new()
    $unstaged = [Collections.Generic.List[string]]::new()
    foreach ($entry in $changes) {
        $code = $entry.Substring(0, 2)
        $path = $entry.Substring(3)
        if ($code -in 'DD','AU','UD','UA','DU','AA','UU') {
            $unstaged.Add("Conflict $path")
        } elseif ($code -eq '??') {
            $unstaged.Add("New $path")
        } else {
            if ($code[0] -ne ' ') { $staged.Add("$($code[0]) $path") }
            if ($code[1] -ne ' ') { $unstaged.Add("$($code[1]) $path") }
        }
    }
    $status = [ordered]@{
        GitHub          = if ($url) { $url } else { 'No GitHub origin configured' }
        Branch          = if ($branch) { $branch } else { 'Detached HEAD' }
        RemoteBranch    = ''
        RemoteReachable = $false
        Commits         = 'Not compared'
        WorkingTree     = if ($changes.Count) { "$($changes.Count) changed or untracked entries" } else { 'Clean' }
        Staged          = if ($staged.Count) { $staged -join [Environment]::NewLine } else { 'None' }
        Unstaged        = if ($unstaged.Count) { $unstaged -join [Environment]::NewLine } else { 'None' }
        Synced          = $false
    }
    if (!$url) { return [pscustomobject]$status }

    $ref = if ($branch) { "refs/heads/$branch" } else { 'HEAD' }
    if ($branch) {
        $ref = Get-BicdopGitOriginRef $repository $branch
        $status.RemoteBranch = $ref.Substring('refs/heads/'.Length)
    }
    $previousPrompt = [Environment]::GetEnvironmentVariable('GIT_TERMINAL_PROMPT', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Process')
        $remoteRows = @(& $repository.Git -C $root -c credential.interactive=never -c http.lowSpeedLimit=1 -c http.lowSpeedTime=10 ls-remote --refs origin $ref 2>$null)
        $remoteExit = $LASTEXITCODE
    } finally {
        if ($null -eq $previousPrompt) {
            [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', [NullString]::Value, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', $previousPrompt, 'Process')
        }
    }
    if ($remoteExit -ne 0) {
        $status.Commits = 'Could not verify GitHub origin. Check access and connectivity.'
        return [pscustomobject]$status
    }
    $status.RemoteReachable = $true
    $remoteCommit = foreach ($line in $remoteRows) {
        if ($line -cmatch '^([a-f0-9]{40}|[a-f0-9]{64})\t(.+)$' -and $Matches[2] -ceq $ref) {
            $Matches[1]
            break
        }
    }
    if (!$branch) { $status.Commits = 'Detached HEAD. Switch to a branch to compare.' }
    elseif (!$local) { $status.Commits = 'The local branch has no commits.' }
    elseif (!$remoteCommit) { $status.Commits = 'Branch has not been published to GitHub.' }
    elseif ($local -ceq $remoteCommit) {
        $status.Commits = 'Up to date'
        $status.Synced = !$changes.Count
    } else {
        $counts = & $repository.Git -C $root rev-list --left-right --count "HEAD...$remoteCommit" 2>$null
        if ($LASTEXITCODE -eq 0 -and $counts -match '^\s*(\d+)\s+(\d+)\s*$') {
            $status.Commits = "$($Matches[1]) ahead, $($Matches[2]) behind"
        } else {
            $status.Commits = 'Different commits. Fetch is needed to determine ahead/behind counts.'
        }
    }
    return [pscustomobject]$status
}

function Show-BicdopWorkspaceGitHubStatus {
    $active = Get-BicdopActive (Read-BicdopRegistry)
    $root = (Get-BicdopFolder $active.path).FullName
    if (!(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Git was not found on PATH.'
    }
    Write-Host "Looking for Git repositories in '$($active.name)'..."
    $repos = @(Find-BicdopFolders @($root) {
        param($folder)
        !$folder.FullName.Equals($root, $script:PathComparison) -and
            (Test-Path -LiteralPath (Join-Path $folder.FullName '.git'))
    } | Sort-Object FullName)
    if (!$repos.Count) {
        Write-BicdopResult 'No Git repository roots found inside the active workspace.'
        return
    }
    $checked = 0
    $reachable = 0
    $synced = 0
    $failed = 0
    try {
        for ($i = 0; $i -lt $repos.Count; $i++) {
            $repo = $repos[$i]
            Write-Progress -Activity 'Checking Git repositories' -Status "$($i + 1)/$($repos.Count): $($repo.Name)" -CurrentOperation $repo.FullName -PercentComplete (100 * $i / $repos.Count)
            try {
                $status = Show-BicdopGitHubStatus $repo.FullName
                $row = [ordered]@{ Project = $repo.Name; Path = $repo.FullName }
                foreach ($field in $status.PSObject.Properties) { $row[$field.Name] = $field.Value }
                $checked++
                if ($status.RemoteReachable) { $reachable++ }
                if ($status.Synced) { $synced++ }
                [pscustomobject]$row
            } catch {
                Write-Warning "Could not check '$($repo.FullName)': $($_.Exception.Message)"
                $failed++
            }
        }
    } finally {
        Write-Progress -Activity 'Checking Git repositories' -Completed
    }
    Write-BicdopResult "$checked repos checked, $reachable GitHub remotes reachable, $synced synced, $failed errors."
}

function Get-BicdopGitPushUrl($Repository) {
    $ErrorActionPreference = 'Continue'
    $pushUrls = @(& $Repository.Git -C $Repository.Root remote get-url --push --all origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or $pushUrls.Count -ne 1) { throw 'Origin must have exactly one GitHub push URL.' }
    $url = ConvertTo-BicdopGitHubUrl $pushUrls[0]
    if (!$url) { throw 'Origin must have exactly one GitHub push URL.' }
    $url
}

function Publish-BicdopWorkspace {
    $candidates = [Collections.Generic.List[object]]::new()
    $skipped = 0
    foreach ($repo in @(Show-BicdopWorkspaceGitHubStatus)) {
        if ($repo.Synced) {
            Write-Host "Skipped '$($repo.Project)': already synced."
        } elseif ($repo.RemoteReachable -and $repo.Branch -ne 'Detached HEAD' -and
            ($repo.Commits -in 'Up to date','Branch has not been published to GitHub.' -or
                $repo.Commits -match '^[1-9]\d* ahead, 0 behind$')) {
            try {
                $pushUrl = Get-BicdopGitPushUrl (Get-BicdopGitRepository $repo.Path)
                if ($pushUrl -ine $repo.GitHub) { throw 'Origin fetch and push point to different repositories.' }
                $candidates.Add($repo)
                continue
            } catch {
                Write-Warning "Skipped '$($repo.Project)': $($_.Exception.Message)"
            }
        } else {
            Write-Warning "Skipped '$($repo.Project)': $($repo.Commits) ($($repo.GitHub)). Check github --status for that project."
        }
        $skipped++
    }

    if (!$candidates.Count) {
        Write-BicdopResult "Nothing to publish. $skipped repos skipped."
        return
    }
    Write-Host "Ready to publish $($candidates.Count) repo(s):"
    foreach ($repo in $candidates) {
        Write-Host "  $($repo.Path) -> $($repo.GitHub) [$($repo.RemoteBranch)]"
        Write-Host "    $($repo.Commits) | $($repo.WorkingTree)"
    }
    if (!(Confirm-Bicdop 'Stage all changes, commit as needed, and push these repositories?')) {
        Write-BicdopResult 'Workspace publish cancelled.'
        return
    }

    $published = 0
    $failed = 0
    try {
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $repo = $candidates[$i]
            Write-Progress -Activity 'Publishing workspace repositories' -Status "$($i + 1)/$($candidates.Count): $($repo.Project)" -CurrentOperation $repo.Path -PercentComplete (100 * $i / $candidates.Count)
            $entered = $false
            try {
                Push-Location -LiteralPath $repo.Path -StackName BicdopWorkspacePublish -ErrorAction Stop
                $entered = $true
                Write-Host "Publishing '$($repo.Project)'..."
                Invoke-BicdopGitHub @('--publish') -ExpectedTarget $repo
                $published++
            } catch {
                Write-Warning "Publish failed in '$($repo.Path)': $($_.Exception.Message)"
                $failed++
            } finally {
                if ($entered) { Pop-Location -StackName BicdopWorkspacePublish }
            }
        }
    } finally {
        Write-Progress -Activity 'Publishing workspace repositories' -Completed
    }
    Write-BicdopResult "Workspace publish finished: $published published, $skipped skipped, $failed failed."
}

function Invoke-BicdopGitHubRelease([object[]]$Options) {
    $usage = 'Usage: github --release TAG [FILE ...] | --release --view TAG | --release --upload TAG FILE [...] | --release --publish TAG'
    if (!$Options.Count) { throw $usage }
    $action = 'create'
    if ($Options[0] -in '--view','--upload','--publish') {
        $action = $Options[0].Substring(2)
        $Options = @($Options | Select-Object -Skip 1)
    }
    if (!$Options.Count -or $Options[0] -notmatch '^[A-Za-z0-9_][A-Za-z0-9._/-]*$' -or
        ($action -in 'view','publish' -and $Options.Count -ne 1) -or
        ($action -eq 'upload' -and $Options.Count -lt 2)) {
        throw $usage
    }
    $tag = $Options[0]
    $folder = Get-BicdopFolder
    $marker = Read-BicdopMarker (Join-Path $folder.FullName '.bicdop')
    if (!$marker) { throw 'No valid .bicdop marker in the current folder. Enter a marked project folder first.' }
    $target = if ($marker.github_release_url) { $marker.github_release_url } else { $marker.github_url }
    $url = ConvertTo-BicdopGitHubUrl $target
    if (!$url) { throw 'Set github_release_url or github_url to a valid GitHub repository URL in .bicdop.' }

    $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$gh) { throw 'GitHub CLI (gh) was not found on PATH.' }
    $repo = ([uri]$url).Host + ([uri]$url).AbsolutePath
    $assets = @(foreach ($file in ($Options | Select-Object -Skip 1)) {
        $item = Get-Item -LiteralPath $file -ErrorAction Stop
        if ($item -isnot [IO.FileInfo] -or $item.FullName.Contains('#')) {
            throw "Release assets must be files and their paths cannot contain '#': $file"
        }
        $item.FullName
    })
    $arguments = switch ($action) {
        'create' { 'release', 'create', $tag, '--draft', '--generate-notes', '--repo', $repo, '--'; $assets }
        'view' { 'release', 'view', $tag, '--repo', $repo }
        'upload' { 'release', 'upload', $tag, '--repo', $repo, '--'; $assets }
        'publish' { 'release', 'edit', $tag, '--draft=false', '--repo', $repo }
    }
    Write-Host "GitHub Release: $action $tag in $repo..."
    & $gh.Source @arguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub release $action failed (exit code $LASTEXITCODE)." }
    switch ($action) {
        'create' { Write-BicdopResult "Draft $tag created. Use github --release --view $tag to review it." }
        'upload' { Write-BicdopResult "Assets uploaded to $tag." }
        'publish' { Write-BicdopResult "Release $tag published." }
    }
}

function Get-BicdopGitHubAccount([string]$Cli) {
    $login = & $Cli api --hostname github.com user --jq '.login' 2>$null
    if ($LASTEXITCODE -ne 0 -or @($login).Count -ne 1 -or $login -notmatch '^[A-Za-z0-9-]+$') {
        throw 'Could not verify the active GitHub account. Check your connection or run github --login.'
    }
    return [string]$login
}

function Invoke-BicdopGitHubAuth([string]$Action) {
    $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$gh) { throw 'GitHub CLI (gh) was not found on PATH.' }
    switch ($Action) {
        '--login' {
            Write-Host 'Opening GitHub CLI browser sign-in...'
            & $gh.Source auth login --hostname github.com --web
            if ($LASTEXITCODE -ne 0) { throw "GitHub CLI login failed (exit code $LASTEXITCODE)." }
            Write-BicdopResult "GitHub CLI active account: $(Get-BicdopGitHubAccount $gh.Source)"
        }
        '--account' {
            Write-Host 'Checking the active GitHub CLI account...'
            $login = Get-BicdopGitHubAccount $gh.Source
            Write-BicdopResult "GitHub CLI active account: $login"
        }
        '--logout' {
            if ($env:GH_TOKEN -or $env:GITHUB_TOKEN) {
                throw 'GitHub CLI is using an environment token. Unset GH_TOKEN or GITHUB_TOKEN in PowerShell before logging out of a stored account.'
            }
            $login = Get-BicdopGitHubAccount $gh.Source
            if (!(Confirm-Bicdop "Log out '$login' from GitHub CLI on this computer?")) {
                Write-BicdopResult 'GitHub logout cancelled.'
                return
            }
            & $gh.Source auth logout --hostname github.com --user $login
            if ($LASTEXITCODE -ne 0) { throw "GitHub CLI logout failed (exit code $LASTEXITCODE)." }
            Write-BicdopResult "Logged out '$login' from GitHub CLI. Use github --account to check which account is now active."
        }
    }
}

function Invoke-BicdopGitHubClone([string]$Repository, [string]$Account) {
    $workspace = Get-BicdopActive (Read-BicdopRegistry)
    $root = (Get-BicdopFolder $workspace.path).FullName
    $repo = $Repository -replace '^https://github\.com/', '' -replace '\.git$', ''
    if ($repo -notmatch '^(?:[A-Za-z0-9-]+/)?[A-Za-z0-9_.-]+$') {
        throw 'Use a GitHub repo name, OWNER/REPO, or https://github.com/OWNER/REPO.'
    }

    $name = $repo.Split('/')[-1]
    if ($name.EndsWith('.') -or $name -match '^(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {
        throw "Cannot use '$name' as a Windows folder name."
    }
    $destination = Join-Path $root $name
    if (Test-Path -LiteralPath $destination) {
        throw "Destination already exists: $destination. Use github --status from the existing repository."
    }

    if (!$repo.Contains('/')) {
        if (!$Account) { throw 'No verified GitHub CLI account. Run github --login or specify OWNER/REPO.' }
        $repo = "$Account/$repo"
    }

    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$git) { throw 'Git was not found on PATH.' }
    Write-Host "Cloning $repo into '$destination'..."
    & $git.Source clone --progress -- "https://github.com/$repo.git" $destination
    if ($LASTEXITCODE -ne 0) { throw "Clone failed for '$repo' (exit code $LASTEXITCODE)." }
    Write-BicdopResult "Cloned $repo into '$destination'. Use plant from that folder to register it as a Bicdop project."
}

function Invoke-BicdopGitHubCreate([object[]]$Options, [string]$Account) {
    if ($Options.Count -notin 3,4 -or $Options[1] -notin '--repo','--local' -or
        ($Options.Count -eq 4 -and ($Options[1] -ne '--repo' -or $Options[3] -notin '--private','--public'))) {
        throw 'Usage: bicdop github --create --repo NAME [--private | --public] | --create --local NAME'
    }
    $name = [string]$Options[2]
    if ($name -notmatch '^[A-Za-z0-9_.][A-Za-z0-9_.-]{0,99}$' -or
        $name.EndsWith('.') -or $name -ieq '.git') {
        throw 'Use a repository name of 1 to 100 characters with letters, numbers, dots, underscores, or hyphens.'
    }

    if ($Options[1] -eq '--local') {
        if ($name -match '^(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {
            throw "Cannot use '$name' as a Windows folder name."
        }
        $workspace = Get-BicdopActive (Read-BicdopRegistry)
        $root = (Get-BicdopFolder $workspace.path).FullName
        $destination = Join-Path $root $name
        if (Test-Path -LiteralPath $destination) { throw "Destination already exists: $destination" }
        $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (!$git) { throw 'Git was not found on PATH.' }
        $null = New-Item -ItemType Directory -Path $destination -ErrorAction Stop
        Write-Host "Initializing local Git repository in '$destination'..."
        & $git.Source init -- $destination
        if ($LASTEXITCODE -ne 0) { throw "Git init failed (exit code $LASTEXITCODE). Check '$destination'." }
        Write-BicdopResult "Created local Git repository: $destination"
        return
    }

    if (!$Account) { throw 'No verified GitHub CLI account. Run github --login first.' }
    $gh = (Get-Command gh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $visibility = if ($Options[3] -eq '--public') { 'public' } else { 'private' }
    $private = if ($visibility -eq 'public') { 'false' } else { 'true' }
    Write-Host "Creating $visibility GitHub repository '$Account/$name'..."
    $url = & $gh api --hostname github.com --method POST user/repos -f "name=$name" -F "private=$private" --jq '.html_url'
    if ($LASTEXITCODE -ne 0 -or @($url).Count -ne 1 -or $url -notlike "https://github.com/$Account/*") { throw "Could not create '$Account/$name'. Check permissions and whether the name is already in use." }
    Write-BicdopResult "Created GitHub repository: $url"
}

function Show-BicdopGitHubRepositories([string]$Account) {
    if (!$Account) { throw 'No verified GitHub CLI account. Run github --login first.' }
    $gh = (Get-Command gh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    Write-Host "Fetching repositories owned by '$Account'..."
    $rows = @(& $gh api --hostname github.com 'user/repos?affiliation=owner&per_page=100' --paginate --jq '.[] | [.full_name, .visibility, .html_url] | @tsv')
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch repositories for '$Account'. Check your connection and permissions." }
    if (!$rows.Count) { Write-BicdopResult "No repositories found for '$Account'."; return }
    foreach ($row in $rows) {
        $name, $visibility, $url = $row -split "`t", 3
        [pscustomobject][ordered]@{ Repository = $name; Visibility = $visibility; Url = $url }
    }
    Write-BicdopResult "Found $($rows.Count) repositories for '$Account'."
}

function Invoke-BicdopGitHub([object[]]$Options, $ExpectedTarget, [string]$Account) {
    $action = $Options[0]
    if ($action -eq '--create') {
        Invoke-BicdopGitHubCreate $Options $Account
        return
    }
    if ($action -eq '--list') {
        if ($Options.Count -ne 1) { throw 'Usage: bicdop github --list' }
        Show-BicdopGitHubRepositories $Account
        return
    }
    if ($action -in '--login','--logout','--account') {
        if ($Options.Count -ne 1) { throw 'Usage: bicdop github --login | --logout | --account' }
        Invoke-BicdopGitHubAuth $action
        return
    }
    if ($action -eq '--clone') {
        if ($Options.Count -ne 2 -or [string]::IsNullOrWhiteSpace($Options[1])) {
            throw 'Usage: bicdop github --clone REPO | OWNER/REPO | GITHUB-URL'
        }
        Invoke-BicdopGitHubClone $Options[1] $Account
        return
    }
    if ($action -eq '--workspace') {
        if ($Options.Count -eq 2 -and $Options[1] -eq '--publish') { Publish-BicdopWorkspace }
        elseif ($Options.Count -eq 1) { Show-BicdopWorkspaceGitHubStatus }
        else { throw 'Usage: bicdop github --workspace [--publish]' }
        return
    }
    if ($action -eq '--release') {
        Invoke-BicdopGitHubRelease @($Options | Select-Object -Skip 1)
        return
    }
    $quickPush = ($action -eq '--publish' -and $Options.Count -eq 1) -or
        ($action -eq '--push' -and $Options.Count -eq 2 -and $Options[1] -eq '--force')
    if ($quickPush) { $action = '--push' }
    if ($action -notin '--status','--stage','--unstage','--diff','--commit','--fetch','--pull','--push' -or
        ($action -eq '--commit' -and ($Options.Count -ne 2 -or [string]::IsNullOrWhiteSpace($Options[1]))) -or
        ($action -in '--stage','--unstage' -and ($Options.Count -lt 2 -or ('--all' -in $Options -and $Options.Count -ne 2))) -or
        ($action -eq '--diff' -and ($Options.Count -gt 2 -or ($Options.Count -eq 2 -and $Options[1] -ne '--staged'))) -or
        ($action -notin '--commit','--stage','--unstage','--diff' -and $Options.Count -ne 1 -and !$quickPush)) {
        throw 'Usage: bicdop github --login | --logout | --account | --list | --create --repo NAME | --create --local NAME | --status | --clone REPO | --workspace | --stage FILE [...] | --unstage FILE [...] | --diff [--staged] | --commit "MESSAGE" | --fetch | --pull | --push | --publish. Use --all with --stage or --unstage.'
    }
    if ($action -eq '--status') {
        Write-Host 'Checking the local working tree and GitHub branch...'
        Show-BicdopGitHubStatus
        return
    }

    $repository = Get-BicdopGitRepository
    $ErrorActionPreference = 'Continue'
    if ($action -in '--fetch','--pull','--push') {
        $originUrl = Get-BicdopGitHubUrl $repository.Root
        if (!$originUrl) { throw 'Configure a GitHub origin for this repository first.' }
    }
    $arguments = switch ($action) {
        '--stage' {
            if ($Options[1] -eq '--all') {
                Write-Host 'Staging all changes...'
                'add', '--all'
            } else {
                Write-Host 'Staging selected paths...'
                '--literal-pathspecs', 'add', '--'
                $Options | Select-Object -Skip 1
            }
        }
        '--unstage' {
            Write-Host 'Removing changes from staging...'
            '--literal-pathspecs', 'reset', '--quiet', '--'
            if ($Options[1] -eq '--all') { '.' }
            else { $Options | Select-Object -Skip 1 }
        }
        '--diff' {
            '--no-pager', 'diff'
            if ($Options[1] -eq '--staged') { '--cached' }
            '--'
        }
        '--commit' {
            Write-Host 'Creating a commit from staged changes...'
            'commit', '-m', $Options[1]
        }
        '--fetch' {
            Write-Host 'Fetching changes from origin...'
            'fetch', '--progress', 'origin'
        }
        default {
            $branch = & $repository.Git -C $repository.Root symbolic-ref --quiet --short HEAD 2>$null
            if (!$branch) { throw 'Switch to a branch before pulling or pushing.' }
            $reference = Get-BicdopGitOriginRef $repository $branch -RequireOrigin
            if ($action -eq '--pull') {
                Write-Host "Pulling $reference from origin (fast-forward only)..."
                'pull', '--progress', '--ff-only', 'origin', $reference
            } else {
                $pushUrl = Get-BicdopGitPushUrl $repository
                if ($ExpectedTarget -and ($originUrl -ine $ExpectedTarget.GitHub -or
                    $pushUrl -ine $ExpectedTarget.GitHub -or $branch -cne $ExpectedTarget.Branch -or
                    $reference -cne "refs/heads/$($ExpectedTarget.RemoteBranch)")) {
                    throw 'The branch or GitHub destination changed after the preview. Run workspace publish again.'
                }
                'push', '--progress', '--set-upstream', 'origin', "HEAD:$reference"
            }
        }
    }
    if ($quickPush) {
        Write-Host 'Preparing all changes for commit and push...'
        Invoke-BicdopGitHub @('--stage', '--all')
        $changes = @(& $repository.Git -C $repository.Root diff --cached --no-renames --name-status -- 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'Could not summarize staged changes.' }
        if ($changes.Count) {
            $added = @($changes -cmatch '^A\t').Count
            $deleted = @($changes -cmatch '^D\t').Count
            $modified = $changes.Count - $added - $deleted
            $message = "+$added files -$deleted files $modified Modified"
            Write-Host "Commit message: $message"
            Invoke-BicdopGitHub @('--commit', $message)
        } else {
            Write-Host 'No changes to commit. Checking for commits to push...'
        }
    }
    if ($action -eq '--push') { Write-Host "Pushing $branch to origin ($reference)..." }
    if ($action -eq '--diff') {
        $shown = $false
        & $repository.Git -C $repository.Root @arguments | ForEach-Object {
            $shown = $true
            $_
        }
        if ($LASTEXITCODE -eq 0 -and !$shown) {
            if ($Options[1] -eq '--staged') { Write-Host 'No staged changes to show.' }
            else { Write-Host 'No unstaged changes in tracked files. Use github --status to see new files.' }
        }
    } else {
        & $repository.Git -C $repository.Root @arguments
    }
    if ($LASTEXITCODE -ne 0) { throw "Git $($action.Substring(2)) exited with code $LASTEXITCODE." }
    if ($action -in '--stage','--unstage') {
        $staged = @(& $repository.Git -C $repository.Root diff --cached --name-only -- 2>$null)
        if ($LASTEXITCODE -eq 0) {
            if ($staged.Count) { Write-BicdopResult "$($staged.Count) path(s) ready to commit." }
            else { Write-BicdopResult 'No changes staged.' }
            return
        }
    }
    if ($action -ne '--diff') { Write-BicdopResult "Git $($action.Substring(2)) complete." }
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
                    $githubUrl = [string](Get-BicdopGitHubUrl $folder.FullName)
                    $marker = @{ schema = 1; id = [guid]::NewGuid().ToString(); workspace = $id; main_file = [string](Find-BicdopMainFile $folder.FullName)
                        version = [string](Find-BicdopProjectVersion $folder.FullName)
                        github_url = $githubUrl; github_release_url = $githubUrl }
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
    else { Write-Host 'Plant cancelled.' }
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
    $pyinstallerCommand = $null
    if ($Replant) {
        $marker = Read-BicdopMarker $path
        $pyinstallerCommand = $marker.pyinstaller_command
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
            if (!$marker) { $marker = @{} }
            $marker.schema = 1
            $marker.id = $id
            $marker.workspace = $WorkspaceId
            $marker.main_file = [string]$mainFile
            $marker.version = [string]$version
            $marker.pyinstaller_command = [string]$pyinstallerCommand
            $githubUrl = [string](Get-BicdopGitHubUrl $Folder.FullName)
            if (!$marker.github_release_url -or $marker.github_release_url -ieq $marker.github_url) {
                $marker.github_release_url = $githubUrl
            }
            $marker.github_url = $githubUrl
            $null = Write-BicdopMarker $path $marker
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

function Set-BicdopMarkerValue([string]$Field, [string]$Literal) {
    if ($Field -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
        throw 'Use a field name such as github_url or release_channel.'
    }
    if ($Field -in 'schema','id','workspace') { throw "Bicdop manages '$Field'. It cannot be changed with marker --set." }

    $value = $null
    if ($Literal.StartsWith('"') -or $Literal.StartsWith("'")) {
        $tokens = @(ConvertFrom-BicdopInput $Literal)
        if ($tokens.Count -ne 1) { throw 'Enter exactly one quoted value.' }
        $value = [string]$tokens[0]
    } elseif ($Literal -cin 'true','false') {
        $value = $Literal -ceq 'true'
    } elseif ($Literal -match '^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$') {
        $value = (ConvertFrom-Json -InputObject ('{"value":' + $Literal + '}') -ErrorAction Stop).value
        if ($value -is [double] -and [double]::IsInfinity($value)) { throw 'The number is out of range.' }
    } elseif ($Literal -cne 'null') {
        throw 'Put text values in quotes. Unquoted values must be a number, true, false, or null.'
    }

    $root = (Get-BicdopFolder).FullName
    if ($Field -in 'main_file','version','github_url','github_release_url','pyinstaller_command' -and $null -ne $value) {
        if ($value -isnot [string]) { throw "Put the value of '$Field' in quotes." }
        if ($value) {
            switch ($Field) {
                'main_file' { $null = Resolve-BicdopMainFile $root $value }
                'version' {
                    if ($value -notmatch '^\d[0-9A-Za-z.!+_-]*$') { throw 'Enter a project version such as "1.2.3".' }
                }
                { $_ -in 'github_url','github_release_url' } {
                    if ($value -notmatch '^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$' -or
                        ($value.Split('/')[-1] -in '.','..')) {
                        throw 'Use a GitHub repository URL such as "https://github.com/owner/project".'
                    }
                }
                'pyinstaller_command' { $null = ConvertTo-BicdopPyInstallerArgs $value }
            }
        }
    }

    $null = Set-BicdopProjectField $root $Field $value
    Write-Host "Saved '$Field' in .bicdop."
}

function Invoke-BicdopMarker([object[]]$Options) {
    if ($Options.Count -eq 3 -and $Options[0] -eq '--set') {
        Set-BicdopMarkerValue $Options[1] $Options[2]
        return
    }
    if (($Options.Count -eq 1 -and $Options[0] -eq '--check') -or
        ($Options.Count -eq 2 -and $Options[0] -notlike '--*' -and $Options[1] -eq '--check')) {
        $folder = if ($Options.Count -eq 2) { Get-BicdopNamedFolder $Options[0] } else { Get-BicdopFolder }
        $marker = Join-Path $folder.FullName '.bicdop'
        if (![IO.File]::Exists($marker)) { throw "No .bicdop marker in '$($folder.FullName)'." }
        Get-Content -LiteralPath $marker -Raw -Encoding UTF8 -ErrorAction Stop
        return
    }
    if ($Options.Count -notin 1,2 -or $Options[0] -notin '--clear','--replant' -or
        ($Options.Count -eq 2 -and $Options[1] -ne '--all')) {
        throw 'Usage: bicdop marker [--clear | --replant] [--all] or bicdop marker [PROJECT] --check or bicdop marker --set FIELD VALUE'
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
    if (!(Confirm-Bicdop "$action project markers in $($targets.Count) folder(s) under '$root'?")) {
        Write-Host "$action cancelled."
        return
    }

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
            $value = Read-BicdopConfirmation 'More than one project matches. Enter its displayed number or press Enter to cancel:'
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
    if ($Options.Count -ne 1 -or $Options[0] -notin '--check','--apply') {
        throw 'Usage: bicdop update [--check | --apply]'
    }
    $installed = $ExecutionContext.SessionState.Module.Version
    Write-Host 'Checking the latest stable Bicdop release...'
    if ($Options[0] -eq '--apply') {
        $root = Get-BicdopManagedRoot
        $managed = Get-BicdopManagedModule $root $installed
        $current = if ($managed) { $managed.Version } else { $installed }
        $result = Install-BicdopRelease $current $root
        if ($result.Version -gt $installed) {
            $manifest = Join-Path $root "$($result.Version)/Bicdop.psd1"
            Write-Host "Bicdop $($result.Version) is ready. Reopen the Bicdop launcher to use it."
            Write-Host "For a manual PowerShell import: $manifest"
        } else {
            Write-Host "Bicdop $installed is up to date."
        }
        return
    }
    $release = Get-BicdopRelease
    [pscustomobject]@{ Installed = $installed.ToString(); Latest = $release.Version.ToString()
        UpdateAvailable = $release.Version -gt $installed; Notes = $release.Release.body }
}

function ConvertFrom-BicdopInput([string]$Line, [switch]$PreserveQuotes) {
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
        if ($PreserveQuotes) { $token.Value.TrimStart() }
        else { $token.Groups['value'].Value }
        $offset += $token.Length
    }
}

function Get-BicdopErrorHint([string[]]$Words, [string]$Message) {
    if ($Message -like 'Usage:*') { return 'Use help to see the supported command forms.' }
    if ($Message -match 'No active workspace') { return 'Run workspace to list workspaces, or workspace --set from the workspace root.' }
    if ($Message -match 'No valid \.bicdop|regular \.bicdop|No \.bicdop marker') {
        return 'Run plant from the project root. If the marker already exists and is invalid, use marker --replant.'
    }
    if ($Message -match 'not found on PATH') { return 'Install the tool named above, add it to PATH, and reopen Bicdop.' }
    if ($Message -match 'No main file|Entry point must') { return 'Use project --list to find the file, then run --set FILE.' }
    if ($Message -like 'Invalid input.*') { return 'Use one command per line and quote paths or names with spaces.' }

    switch ($Words[0]) {
        'github' {
            if ($Words[1] -in '--login','--logout','--account') {
                return 'Use github --login to sign in and github --account to verify the active account. Check the GitHub CLI error above.'
            }
            if ($Words[1] -eq '--create' -and $Words[2] -eq '--local') {
                return 'Check the active workspace and choose a folder name that does not already exist.'
            }
            if ($Words[1] -in '--create','--list') {
                return 'Check github --account and your account permissions. For create, check whether the name is already in use.'
            }
            if ($Words[1] -eq '--clone') {
                return 'Check the active workspace and repository name. Use OWNER/REPO for another account. For private repos, check your Git credentials.'
            }
            if ($Words[1] -eq '--release') {
                return 'Check gh auth status in PowerShell, then check github_release_url and the asset paths. If the draft exists, use github --release --view TAG or --upload TAG FILE.'
            }
            if ($Words[1] -eq '--commit') {
                return 'Use github --status to check staging. If Git asks for your identity, configure user.name and user.email in PowerShell.'
            }
            return 'Read the Git message above. Use github --status to check your branch and staging. If GitHub has newer commits, fetch and review before retrying.'
        }
        'pyinstaller' { return 'Read the build error above. Verify PyInstaller in the project Python environment and check the saved .spec or .py path.' }
        'run' { return 'Check project --main and the runtime output above. Check that the project dependencies are installed.' }
        { $_ -in 'update','version' } { return 'Check GitHub connectivity and run update --check. If a package fails verification, keep the installed copy.' }
        'session' { return 'Use session --list to see saved sessions and check that the saved folder still exists.' }
        'switch' { return 'Run projects to see the registered project names and current row numbers.' }
        { $_ -in 'workspace','scan','show','projects' } { return 'Check that the workspace folder is accessible. Use workspace to see registered workspaces.' }
        { $_ -in 'cd','cd..','open','li','ls','dir','mkdir','rmdir','plant','marker','project' } {
            return 'Check the target folder and your access to it. Quote paths containing spaces.'
        }
        default { return 'Type help for command syntax or help errors for common fixes.' }
    }
}

function Test-BicdopHistoryLine([string]$Line) {
    return $Line -notmatch '^\s*(?:bicdop\s+)?(?:exit|--exit)\s*$' -and
        $Line -notmatch '(?:--(?:password|token|secret|api[-_]?key)(?:[=\s]|$)|https?://[^/\s]+@|marker\s+--set\s+\S*(?:password|token|secret|credential|api[-_]?key)\S*\s)'
}

function Write-BicdopResult([string]$Message) {
    $script:BicdopCommandResult = $Message
    Write-Host $Message
}

function Format-BicdopSessionSummary([string]$Text) {
    $clean = ($Text -replace '[\x00-\x1F\x7F]', ' ' -replace '\s{2,}', ' ').Trim()
    $clean = $clean -replace '(https?://)[^/\s]+@', '$1[redacted]@'
    if ($clean.Length -gt 240) { return $clean.Substring(0, 237) + '...' }
    return $clean
}

function Show-BicdopSessionLog($State, [int]$Limit = 0) {
    $entries = @($State.log | Where-Object { [string]$_.session -ieq [string]$script:BicdopSessionName })
    if (!$entries.Count) {
        if (!$Limit) { Write-Host 'No command results recorded for this session yet.' }
        return
    }
    if ($Limit) { $entries = @($entries | Select-Object -Last $Limit) }
    $label = if ($script:BicdopSessionName) { $script:BicdopSessionName } else { 'automatic session' }
    Write-Host "Recent commands ($label)"
    foreach ($entry in $entries) {
        $detail = switch ($entry.status) {
            'completed' { if ($entry.result) { $entry.result } else { 'Finished' } }
            'failed'    { "Error: $($entry.result)" }
            default     { 'Outcome unknown (no completion recorded)' }
        }
        Write-BicdopSyntax ('  ' + $entry.command) -NoNewline
        Write-Host " | $detail"
    }
    Write-Host ''
}

function Save-BicdopSession([string]$Command, [string]$EntryId, [string]$Status, [string]$Result) {
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return }
    $context = @{
        workspace = (Read-BicdopRegistry).active
        path = $location.ProviderPath
        name = $script:BicdopSessionName
        saved_at = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Invoke-BicdopSessionWrite {
        param($state)
        $state.last = $context
        if ($context.name) { $state.named[$context.name] = $context }
        if ($Command -and $state.history[-1] -cne $Command) {
            $state.history = @((@($state.history) + $Command) | Select-Object -Last 100)
        }
        if ($EntryId -and $Command) {
            $entry = @{
                id = $EntryId
                session = [string]$context.name
                command = Format-BicdopSessionSummary $Command
                status = 'pending'
            }
            $state.log = @((@($state.log) + $entry) | Select-Object -Last 200)
        } elseif ($EntryId -and $Status) {
            foreach ($entry in $state.log) {
                if ($entry.id -ceq $EntryId) {
                    $entry.status = $Status
                    $entry.result = Format-BicdopSessionSummary $Result
                    break
                }
            }
        }
    }
}

function Restore-BicdopSession($Context) {
    if (!$Context) { return $false }
    $state = Read-BicdopRegistry
    $workspace = $null
    if ($Context.workspace) {
        $workspace = $state.workspaces[$Context.workspace]
        if (!$workspace) { Write-Warning 'The saved workspace is no longer registered.' }
    }
    $path = $Context.path
    if (![IO.Directory]::Exists($path)) {
        $path = $workspace.path
        if (![IO.Directory]::Exists($path)) {
            Write-Warning 'The last session folder is unavailable. Staying in the current folder.'
            return $false
        }
        Write-Warning 'The last session folder is unavailable. Opening the workspace root.'
    }
    $folder = Get-BicdopFolder $path
    if ($state.active -ne $Context.workspace -and (!$Context.workspace -or $workspace)) {
        Invoke-BicdopRegistryWrite {
            param($latest)
            if ($Context.workspace -and !$latest.workspaces.Contains($Context.workspace)) {
                throw 'The saved workspace is no longer registered.'
            }
            $latest.active = $Context.workspace
            Save-BicdopRegistry $latest
        }
        $script:ScanRows = @()
        $script:ProjectRows = @()
        $script:ListedWorkspace = $null
    }
    Set-Location -LiteralPath $folder.FullName -ErrorAction Stop
    $script:BicdopSessionName = $Context.name
    Write-Host "Session resumed: $($folder.FullName)"
    return $true
}

function Invoke-BicdopSession([object[]]$Options) {
    $usage = 'Usage: session --list | --save NAME | --resume NAME | --close | --log'
    if ($Options.Count -notin 1,2 -or $Options[0] -notin '--list','--save','--resume','--close','--log' -or
        ($Options[0] -in '--list','--close','--log' -and $Options.Count -ne 1) -or
        ($Options[0] -in '--save','--resume' -and ($Options.Count -ne 2 -or [string]::IsNullOrWhiteSpace($Options[1])))) {
        throw $usage
    }
    switch ($Options[0]) {
        '--log' { Show-BicdopSessionLog (Read-BicdopSessions) }
        '--list' {
            $state = Read-BicdopSessions
            if (!$state.named.Count) { Write-Host 'No named sessions. Your last session is saved automatically.' }
            $workspaces = (Read-BicdopRegistry).workspaces
            foreach ($item in ($state.named.GetEnumerator() | Sort-Object Key)) {
                $record = $item.Value
                $workspaceName = if ($record.workspace) { $workspaces[$record.workspace].name }
                [pscustomobject][ordered]@{
                    Name = $item.Key
                    Workspace = $workspaceName
                    Path = $record.path
                    SavedAt = $record.saved_at
                }
            }
        }
        '--save' {
            $script:BicdopSessionName = $Options[1].Trim()
            Save-BicdopSession
            Write-Host "Saved session '$script:BicdopSessionName'."
        }
        '--resume' {
            $state = Read-BicdopSessions
            $name = $Options[1].Trim()
            if (!$state.named.Contains($name)) { throw "Session '$name' was not found. Use session --list." }
            if (Restore-BicdopSession $state.named[$name]) {
                Show-BicdopSessionLog $state -Limit $script:BicdopResumeLogLimit
                Save-BicdopSession
            }
        }
        '--close' {
            if (!$script:BicdopSessionName) { Write-Host 'No named session is open. Automatic saving remains active.'; return }
            Save-BicdopSession
            $script:BicdopSessionName = $null
            Save-BicdopSession
            Write-Host 'Named session closed. Automatic saving remains active.'
        }
    }
}

function Start-BicdopShell {
    $rawUI = $Host.UI.RawUI
    $interactiveConsole = $Host.Name -eq 'ConsoleHost' -and $rawUI -and
        ![Console]::IsInputRedirected -and ![Console]::IsOutputRedirected
    $previousTitle = $null
    if ($interactiveConsole) {
        try { $previousTitle = $rawUI.WindowTitle }
        catch { Write-Verbose 'This terminal does not expose a title.' }
    }
    $warningColor = if ($Host.PrivateData) { $Host.PrivateData.PSObject.Properties['WarningForegroundColor'] }
    $previousWarning = if ($warningColor) { $warningColor.Value }
    try {
        if ($warningColor) { $warningColor.Value = [ConsoleColor]::Yellow }
        if ($interactiveConsole) { Clear-Host }
        $history = @()
        $sessionErrorShown = $false
        try {
            $saved = Read-BicdopSessions
            $history = @($saved.history | Where-Object { $_ -is [string] })
            $null = Restore-BicdopSession $saved.last
        } catch {
            Write-Warning "Could not restore the last Bicdop session: $($_.Exception.Message)"
        }
        while ($true) {
            Get-BicdopPrompt -Display -UpdateTitle:($null -ne $previousTitle)
            $line = if ($interactiveConsole) { Read-BicdopConsoleLine $rawUI $history } else { Read-Host }
            if ($null -eq $line) { return }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $shouldSave = $line -notmatch '^\s*(?:bicdop\s+)?(?:exit|--exit)\s*$'
            $entryId = $null
            $outcome = $null
            $script:BicdopCommandResult = $null
            if ($shouldSave) {
                $command = $null
                if (Test-BicdopHistoryLine $line) {
                    $command = $line
                    if ($line -notmatch '^\s*(?:bicdop\s+)?(?:session|help|--help|flush)(?:\s|$)') {
                        $entryId = [guid]::NewGuid().ToString()
                    }
                    if ($history[-1] -cne $line) { $history = @(($history + $line) | Select-Object -Last 100) }
                }
                try { Save-BicdopSession -Command $command -EntryId $entryId }
                catch {
                    if (!$sessionErrorShown) {
                        Write-Warning "Could not save Bicdop session: $($_.Exception.Message)"
                        $sessionErrorShown = $true
                    }
                }
            }
            $words = @()
            try {
                $words = @(ConvertFrom-BicdopInput $line)
                if ($words.Count -and $words[0] -eq 'bicdop') {
                    $words = @($words | Select-Object -Skip 1)
                }
                if (!$words.Count) { continue }
                if ($words[0] -in 'exit','--exit' -and $words.Count -eq 1) { return }
                if ($words.Count -eq 4 -and $words[0] -eq 'marker' -and $words[1] -eq '--set') {
                    $words[3] = (ConvertFrom-BicdopInput $line -PreserveQuotes | Select-Object -Last 1)
                }
                if ($words[0] -in 'help','--help') {
                    $help = bicdop @words
                    if ($words[1] -eq 'errors') { Write-Host $help -ForegroundColor Red }
                    else { foreach ($row in $help -split '\r?\n') { Write-BicdopSyntax $row } }
                } elseif ($words[0] -in 'projects','show','scan') {
                    bicdop @words | Out-String -Stream | Write-BicdopProjectTable
                } elseif ($words[0] -eq 'github' -and $words[1] -eq '--status') {
                    $report = bicdop @words
                    if ($report) { $script:BicdopCommandResult = "$($report.Commits); $($report.WorkingTree)" }
                    $report | Out-Host
                } else {
                    bicdop @words | Out-Host
                }
                $outcome = 'completed'
            } catch {
                $message = $_.Exception.Message
                $outcome = 'failed'
                $script:BicdopCommandResult = $message
                Write-Host "Error: $message" -ForegroundColor Red
                Write-Host ("Try: " + (Get-BicdopErrorHint $words $message)) -ForegroundColor Red
            } finally {
                if ($shouldSave) {
                    try { Save-BicdopSession -EntryId $entryId -Status $outcome -Result $script:BicdopCommandResult }
                    catch {
                        if (!$sessionErrorShown) {
                            Write-Warning "Could not save Bicdop session: $($_.Exception.Message)"
                            $sessionErrorShown = $true
                        }
                    }
                }
                Write-Host ''
            }
        }
    } finally {
        foreach ($root in @($script:WebPreviews.Keys)) {
            try { Stop-BicdopPreviousRun $root }
            catch { Write-Warning "Could not stop the web preview for $root : $($_.Exception.Message)" }
        }
        if ($warningColor) { $warningColor.Value = $previousWarning }
        if ($null -ne $previousTitle) {
            try { $rawUI.WindowTitle = $previousTitle }
            catch { Write-Verbose 'Could not restore the original terminal title.' }
        }
    }
}

function Remove-BicdopFolder([object[]]$Options) {
    if ($Options.Count -notin 1,2 -or
        ($Options.Count -eq 2 -and $Options[1] -ne '--recursive')) {
        throw 'Usage: rmdir PATH [--recursive]'
    }
    $folder = Get-BicdopFolder $Options[0]
    $path = $folder.FullName
    $current = Get-Location
    if (!$folder.Parent -or ($current.Provider.Name -eq 'FileSystem' -and (Test-BicdopUnder $current.ProviderPath $path))) {
        throw 'Cannot delete a drive root, the current folder, or one of its parent folders.'
    }
    for ($parent = $folder.Parent; $parent; $parent = $parent.Parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Cannot delete through a symlink or junction: $($parent.FullName)"
        }
    }
    $recursive = $Options.Count -eq 2
    if (!$recursive -and ($folder.EnumerateFileSystemInfos() | Select-Object -First 1)) {
        throw 'The folder is not empty. Add --recursive if you intend to delete its contents.'
    }
    $target = if ($recursive) { "folder '$path' and everything inside it" } else { "folder '$path'" }
    if (!(Confirm-Bicdop "Permanently delete $target?")) {
        Write-BicdopResult 'Folder deletion cancelled.'
        return
    }
    $confirmed = Get-BicdopFolder $path
    if (!$confirmed.FullName.Equals($path, $script:PathComparison)) { throw 'The deletion target changed.' }
    for ($parent = $confirmed.Parent; $parent; $parent = $parent.Parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Cannot delete through a symlink or junction: $($parent.FullName)"
        }
    }
    if ($recursive) {
        Write-Host "Checking the folder before deleting it..."
        $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
        $pending.Push($confirmed)
        while ($pending.Count) {
            foreach ($entry in $pending.Pop().EnumerateDirectories()) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "The folder contains a symlink or junction: $($entry.FullName). Remove the link separately before retrying."
                }
                $pending.Push($entry)
            }
        }
        Write-Host "Deleting '$path' and its contents..."
    }
    [IO.Directory]::Delete($confirmed.FullName, $recursive)
    Write-BicdopResult "Deleted folder: $path"
}

function Invoke-BicdopPing([object[]]$Options) {
    $count = 4
    if ($Options.Count -notin 1,3 -or
        ($Options.Count -eq 3 -and ($Options[1] -ne '--count' -or
            ![int]::TryParse([string]$Options[2], [ref]$count) -or $count -lt 1))) {
        throw 'Usage: ping HOST [--count NUMBER]'
    }
    $target = [string]$Options[0]
    if ($target -match '^[-/]' -or [uri]::CheckHostName($target) -eq [UriHostNameType]::Unknown) {
        throw 'Enter a hostname or IP address, such as example.com or 127.0.0.1.'
    }
    $pingExe = Join-Path ([Environment]::GetFolderPath('System')) 'ping.exe'
    Write-Host "Pinging $target ($count requests)..."
    & $pingExe -n $count $target
    if ($LASTEXITCODE -ne 0) { throw "Ping to '$target' failed. Check the host and your connection." }
}

function bicdop {
    if (-not $args.Count) { Start-BicdopShell; return }
    $command = $args[0]
    $options = @($args | Select-Object -Skip 1)
    if ($command -eq 'cd..' -and !$options.Count) { $command = 'cd'; $options = @('..') }
    switch ($command) {
        'session' { Invoke-BicdopSession $options }
        'workspace' { Invoke-BicdopWorkspace $options }
        'scan' { Invoke-BicdopScan $options }
        'plant' { Invoke-BicdopPlant $options }
        'marker' { Invoke-BicdopMarker $options }
        'github' {
            $account = $null
            if ($options[0] -notin '--login','--logout','--account') {
                $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($gh) {
                    try { $account = Get-BicdopGitHubAccount $gh.Source }
                    catch { Write-Verbose $_.Exception.Message }
                }
                if ($account) { Write-Host "GitHub CLI active account: $account" }
                else { Write-Host 'GitHub CLI active account: unavailable.' }
                if ($options[0] -notin '--release','--list' -and !($options[0] -eq '--create' -and $options[1] -eq '--repo')) {
                    Write-Host 'Git operations use the credentials and author configured in Git.'
                }
            }
            Invoke-BicdopGitHub $options -Account $account
        }
        'run' { Invoke-BicdopRun $options }
        { $_ -in 'build','test','flash' } {
            if ($options.Count -gt 1 -or ($options.Count -and $options[0] -like '--*')) {
                throw "Usage: bicdop $command [PROJECT]"
            }
            $folder = if ($options.Count) { Get-BicdopNamedFolder $options[0] } else { Get-BicdopFolder }
            $toolchain = Get-BicdopProjectToolchain $folder.FullName
            if (!$toolchain) { throw "No supported project configuration found in '$($folder.FullName)'." }
            if ($command -eq 'flash' -and $toolchain -notin 'PlatformIO','ESP-IDF') {
                throw 'Flash requires a PlatformIO or ESP-IDF project. For Pico SDK projects, build and copy the generated UF2 in BOOTSEL mode.'
            }
            Invoke-BicdopProjectTask $folder $command $toolchain
        }
        'stop' {
            if ($options.Count -gt 1 -or ($options.Count -and $options[0] -like '--*')) {
                throw 'Usage: bicdop stop [PROJECT]'
            }
            $folder = if ($options.Count) { Get-BicdopNamedFolder $options[0] } else { Get-BicdopFolder }
            $process = $script:DetachedRuns[$folder.FullName]
            if (!$process -or $process.HasExited) {
                Stop-BicdopPreviousRun $folder.FullName
                Write-BicdopResult "No active run for '$($folder.Name)' in this session."
                return
            }
            Stop-BicdopPreviousRun $folder.FullName
            Write-BicdopResult "Stopped '$($folder.Name)'."
        }
        'pyinstaller' { Invoke-BicdopPyInstaller $options }
        'rmdir' { Remove-BicdopFolder $options }
        'ping' { Invoke-BicdopPing $options }
        'open' {
            if ($options.Count -gt 1 -or ($options[0] -like '--*' -and $options[0] -ne '--workspace')) {
                throw 'Usage: bicdop open [--workspace | PROJECT]'
            }
            $folder = if (!$options.Count) { Get-BicdopFolder }
                elseif ($options[0] -eq '--workspace') {
                    Get-BicdopFolder (Get-BicdopActive (Read-BicdopRegistry)).path
                } else { Get-BicdopNamedFolder $options[0] }
            Open-BicdopExplorer $folder.FullName
            Write-Host "File Explorer target: $($folder.FullName)"
        }
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
                $items = @(Get-ChildItem -LiteralPath $folder.FullName -Force -ErrorAction Stop)
                if (!$items.Count) { Write-Host 'The project folder is empty.' }
                $items
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
            $items = @(Get-ChildItem -LiteralPath $folder.FullName -ErrorAction Stop)
            if (!$items.Count) { Write-Host 'No visible files or folders.' }
            $items
        }
        'pwd' {
            if ($options.Count) { throw 'Usage: pwd' }
            (Get-Location).Path
        }
        'flush' {
            if ($options.Count) { throw 'Usage: flush' }
            Clear-Host
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
            if ($options.Count -eq 1 -and $options[0] -eq 'errors') {
                @'
Common fixes

Workspace missing: use workspace to list registrations or workspace --set at the root.
Marker missing: run plant at the project root. Use marker --check to inspect a marker.
Main file missing: use project --list, then run --set FILE from the project root.
Build failed: read the first PyInstaller error and check dependencies, the preset, and the .spec.
Push rejected: run github --status and github --fetch. Resolve diverged branches before retrying.
Nothing to commit: use github --status and github --stage FILE to select changes.
Release failed: check gh auth status in PowerShell, then the release repository, tag, and assets.
Update failed: use update --check. Installing requires a compatible module ZIP that passes verification.
Paths with spaces: wrap the complete path or name in quotes.
'@
                return
            }
            if ($options.Count) { throw 'Usage: help [errors]' }
            @'
bicdop                                   Start the interactive Bicdop shell
bicdop session [--list | --save NAME | --resume NAME | --close | --log]
bicdop workspace [--set | --find | --goto | --use NAME-OR-NUMBER]
bicdop scan [PATH | --all | --git | --project NAME | --new NAME]
bicdop plant [1,3,5 | --all]             --all plants direct subfolders of the current folder
bicdop marker [--clear | --replant] [--all]
bicdop marker [PROJECT] --check         Show the contents of the .bicdop marker
bicdop github --login                  Sign in to GitHub CLI through the browser
bicdop github --logout                 Sign out the active GitHub CLI account
bicdop github --account                Show the active GitHub CLI account
bicdop github --list                   List repositories owned by the active GitHub account
bicdop github --create --repo NAME [--private | --public]  Create a GitHub repo (private by default)
bicdop github --create --local NAME    Initialize a new Git repo inside the active workspace
bicdop github --clone REPO              Clone a GitHub repo into the active workspace
bicdop github --status                  Check the working tree and compare with GitHub
bicdop github --workspace               Check every Git repository in the active workspace
bicdop github --workspace --publish     Preview and publish ready repositories in the active workspace
bicdop github --stage FILE [...]        Stage selected paths
bicdop github --stage --all             Stage new, modified, and deleted files
bicdop github --diff [--staged]         Show unstaged or staged changes
bicdop github --unstage FILE [...]      Remove selected changes from staging
bicdop github --unstage --all           Remove all changes from staging
bicdop github --commit "MESSAGE"        Commit staged changes
bicdop github --fetch                   Refresh refs from origin
bicdop github --pull                    Fast-forward the current branch from origin
bicdop github --push                    Push the current branch to origin
bicdop github --publish                 Stage all changes, auto-commit, and push normally
bicdop github --push --force            Legacy alias for github --publish
bicdop github --release TAG [FILE ...]  Create a draft GitHub Release
bicdop github --release --view TAG     Review a release
bicdop github --release --upload TAG FILE [...]  Attach files to a release
bicdop github --release --publish TAG  Publish a GitHub Release draft
bicdop marker --set FIELD VALUE         Save a value in the current .bicdop (quote text)
bicdop projects                          List registered projects one level below the active workspace
bicdop show                              List direct subfolders of the active workspace
bicdop switch NUMBER-OR-NAME
bicdop run [FOLDER-NAME] [--detach]      Run the main file, replacing the previous detached run in this session
bicdop run --set FILE
bicdop build [PROJECT]                 Build using the detected project toolchain
bicdop test [PROJECT]                  Run the project test task
bicdop flash [PROJECT]                 Upload PlatformIO or ESP-IDF firmware
bicdop stop [PROJECT]                  Stop a preview or detached run in this session
bicdop pyinstaller [PROJECT]            Build using the command stored in .bicdop
bicdop pyinstaller --set "COMMAND-LINE" Save a full build command without running it
bicdop project --main                   Show the main file saved in .bicdop
bicdop project --list                   List direct files and folders in the current directory
bicdop project --version [VERSION]      Refresh, show, or set the project version
bicdop project PROJECT --version        Refresh and show a named workspace project version
bicdop version                          Compare installed and latest stable versions
bicdop update --check                   Check the latest stable GitHub release
bicdop update --apply                   Download and install the latest compatible release
bicdop mkdir PATH                        Create a directory
bicdop rmdir PATH [--recursive]          Delete a directory after confirmation
bicdop ping HOST [--count NUMBER]        Send ICMP echo requests
bicdop cd PATH                           Change directory (cd.. moves up one level)
bicdop li [PATH]                         List directory contents (also ls or dir)
bicdop pwd                               Print the current directory
bicdop flush                             Clear the terminal display
bicdop open [--workspace | PROJECT]      Open a folder in File Explorer

Inside Bicdop, omit the 'bicdop' prefix. Type 'exit' to return to PowerShell.
Quote paths or names that contain spaces. Type 'help errors' for recovery steps.
'@
        }
        default { throw "Unknown Bicdop command '$command'. Run bicdop help." }
    }
}

Export-ModuleMember -Function bicdop
