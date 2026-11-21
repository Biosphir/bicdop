. "$PSScriptRoot/Registry.ps1"
. "$PSScriptRoot/Update.ps1"

$script:ScanRows = @()
$script:ProjectRows = @()
$script:ListedWorkspace = $null
$script:DetachedRuns = @{}
function Get-BicdopPrompt([switch]$Display) {
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

function Set-BicdopSubmittedInputColor($RawUI, $Start, [string]$Line) {
    if (!$Start -or !$Line -or $Line -match '[\x00-\x1F]') { return }
    $end = $RawUI.CursorPosition
    if ($end.Y -ne ($Start.Y + 1) -or
        ($Start.X + $RawUI.LengthInBufferCells($Line)) -ge $RawUI.BufferSize.Width) { return }
    try {
        $RawUI.CursorPosition = $Start
        Write-BicdopSyntax $Line -NoNewline
    } finally {
        $RawUI.CursorPosition = $end
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
        if ([string]::IsNullOrWhiteSpace($command)) { Write-Host 'PyInstaller build cancelled.'; return }
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
        Write-Host "Build complete. See the PyInstaller output for the destination."
    } finally {
        Pop-Location -StackName BicdopPyInstaller
    }
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
        Write-Host "Opened preview: $entry"
        return
    }
    $runtime = switch ($extension) {
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
        $arguments = if ($extension -eq '.ps1') { '-NoLogo -NoProfile -File "{0}"' -f $entry } else { '"{0}"' -f $entry }
        Stop-BicdopPreviousRun $folder.FullName
        $process = Start-Process -FilePath $runtime -ArgumentList $arguments -WorkingDirectory $folder.FullName -PassThru -ErrorAction Stop
        $script:DetachedRuns[$folder.FullName] = $process
        Write-Host "Started '$($folder.Name)' (PID $($process.Id))."
        return
    }

    Write-Host "Running '$file' in '$($folder.Name)'..."
    Push-Location -LiteralPath $folder.FullName -StackName BicdopRun
    try {
        if ($extension -eq '.ps1') { & $entry }
        else { & $runtime $entry }
        if ($extension -ne '.ps1' -and $LASTEXITCODE -ne 0) {
            throw "Entry point exited with code $LASTEXITCODE."
        }
        Write-Host "Run finished: $file"
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

function Get-BicdopGitRepository {
    $root = (Get-BicdopFolder).FullName
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

function Show-BicdopGitHubStatus {
    $repository = Get-BicdopGitRepository
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
        'create' { Write-Host "Draft $tag created. Use github --release --view $tag to review it." }
        'upload' { Write-Host "Assets uploaded to $tag." }
        'publish' { Write-Host "Release $tag published." }
    }
}

function Invoke-BicdopGitHub([object[]]$Options) {
    $action = $Options[0]
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
        throw 'Usage: bicdop github --status | --stage FILE [...] | --unstage FILE [...] | --diff [--staged] | --commit "MESSAGE" | --fetch | --pull | --push | --publish. Use --all with --stage or --unstage.'
    }
    if ($action -eq '--status') {
        Write-Host 'Checking the local working tree and GitHub branch...'
        Show-BicdopGitHubStatus
        return
    }

    $repository = Get-BicdopGitRepository
    $ErrorActionPreference = 'Continue'
    if ($action -in '--fetch','--pull','--push' -and !(Get-BicdopGitHubUrl $repository.Root)) {
        throw 'Configure a GitHub origin for this repository first.'
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
                $pushUrls = @(& $repository.Git -C $repository.Root remote get-url --push --all origin 2>$null)
                if ($LASTEXITCODE -ne 0 -or $pushUrls.Count -ne 1 -or !(ConvertTo-BicdopGitHubUrl $pushUrls[0])) {
                    throw 'Origin must have exactly one GitHub push URL.'
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
            if ($staged.Count) { Write-Host "$($staged.Count) path(s) ready to commit." }
            else { Write-Host 'No changes staged.' }
            return
        }
    }
    if ($action -ne '--diff') { Write-Host "Git $($action.Substring(2)) complete." }
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
        'switch' { return 'Run projects to see the registered project names and current row numbers.' }
        { $_ -in 'workspace','scan','show','projects' } { return 'Check that the workspace folder is accessible. Use workspace to see registered workspaces.' }
        { $_ -in 'cd','cd..','open','li','ls','dir','mkdir','rmdir','plant','marker','project' } {
            return 'Check the target folder and your access to it. Quote paths containing spaces.'
        }
        default { return 'Type help for command syntax or help errors for common fixes.' }
    }
}

function Start-BicdopShell {
    $rawUI = $Host.UI.RawUI
    $interactiveConsole = $Host.Name -eq 'ConsoleHost' -and $rawUI -and
        ![Console]::IsInputRedirected -and ![Console]::IsOutputRedirected
    $warningColor = if ($Host.PrivateData) { $Host.PrivateData.PSObject.Properties['WarningForegroundColor'] }
    $previousWarning = if ($warningColor) { $warningColor.Value }
    try {
        if ($warningColor) { $warningColor.Value = [ConsoleColor]::Yellow }
        while ($true) {
            Get-BicdopPrompt -Display
            $start = if ($interactiveConsole) { $rawUI.CursorPosition }
            $line = Read-Host
            if ($null -eq $line) { return }
            if ($interactiveConsole) {
                try { Set-BicdopSubmittedInputColor $rawUI $start $line }
                catch { Write-Verbose 'The terminal could not recolor the submitted line.' }
            }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
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
                } else {
                    bicdop @words | Out-Host
                }
            } catch {
                $message = $_.Exception.Message
                Write-Host "Error: $message" -ForegroundColor Red
                Write-Host ("Try: " + (Get-BicdopErrorHint $words $message)) -ForegroundColor Red
            } finally {
                Write-Host ''
            }
        }
    } finally {
        if ($warningColor) { $warningColor.Value = $previousWarning }
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
        Write-Host 'Folder deletion cancelled.'
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
    Write-Host "Deleted folder: $path"
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
        'workspace' { Invoke-BicdopWorkspace $options }
        'scan' { Invoke-BicdopScan $options }
        'plant' { Invoke-BicdopPlant $options }
        'marker' { Invoke-BicdopMarker $options }
        'github' { Invoke-BicdopGitHub $options }
        'run' { Invoke-BicdopRun $options }
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
bicdop workspace [--set | --find | --goto | --use NAME-OR-NUMBER]
bicdop scan [PATH | --all | --git | --project NAME | --new NAME]
bicdop plant [1,3,5 | --all]             --all plants direct subfolders of the current folder
bicdop marker [--clear | --replant] [--all]
bicdop marker [PROJECT] --check         Show the contents of the .bicdop marker
bicdop github --status                  Check the working tree and compare with GitHub
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
