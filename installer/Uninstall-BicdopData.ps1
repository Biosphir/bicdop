param(
    [Parameter(Mandatory)][string]$DataRoot,
    [switch]$RemoveMarkers
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bundled/Registry.ps1')
$script:RegistryPath = Join-Path $DataRoot 'registry.json'

function Test-RealDirectory($Directory) {
    for ($current = $Directory; $current; $current = $current.Parent) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    }
    return $true
}

function Remove-ProjectMarker($Directory, [string]$Name) {
    $path = Join-Path $Directory.FullName $Name
    if (![IO.File]::Exists($path)) { return }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    if (Read-BicdopMarker $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
}

if (![IO.Directory]::Exists($DataRoot)) { return }
$data = Get-Item -LiteralPath $DataRoot -Force
if (!(Test-RealDirectory $data)) { throw "Cannot clean redirected Bicdop data: $DataRoot" }

if ($RemoveMarkers) {
    $state = Read-BicdopRegistry
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($workspace in $state.workspaces.Values) {
        if (![IO.Directory]::Exists($workspace.path)) { continue }
        $root = Get-Item -LiteralPath $workspace.path -Force
        if (!(Test-RealDirectory $root)) { continue }
        Remove-ProjectMarker $root '.bicdop-workspace'

        $folders = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
        $folders.Push($root)
        while ($folders.Count) {
            $folder = $folders.Pop()
            if (!$visited.Add($folder.FullName)) { continue }
            Remove-ProjectMarker $folder '.bicdop'
            foreach ($child in $folder.EnumerateDirectories()) {
                if ($child.Name -ne '.git' -and !($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    $folders.Push($child)
                }
            }
        }
    }

    foreach ($project in $state.projects.Values) {
        if (![IO.Directory]::Exists($project.path)) { continue }
        $folder = Get-Item -LiteralPath $project.path -Force
        if ((Test-RealDirectory $folder) -and $visited.Add($folder.FullName)) {
            Remove-ProjectMarker $folder '.bicdop'
        }
    }
}

# Traverse only the resolved app data directory, without following links.
$directories = [Collections.Generic.List[IO.DirectoryInfo]]::new()
$directories.Add($data)
$prefix = $data.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
for ($index = 0; $index -lt $directories.Count; $index++) {
    $directory = $directories[$index]
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    foreach ($entry in $directory.EnumerateFileSystemInfos()) {
        if (!$entry.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unexpected path in Bicdop data: $($entry.FullName)"
        }
        if ($entry -is [IO.DirectoryInfo]) { $directories.Add($entry) }
        else { Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop }
    }
}
for ($index = $directories.Count - 1; $index -ge 0; $index--) {
    $directories[$index].Delete()
}
