# Bicdop 0.5.9

Bicdop runs inside your current Windows PowerShell 5.1 or PowerShell 7 session.

```powershell
Import-Module .\Bicdop\Bicdop.psd1
bicdop
```

The Bicdop shell displays the current path and active workspace. Enter
commands directly, such as `workspace --set`, `scan`, `switch 1`, or `help`.

Use `mkdir PATH`, `cd PATH`, `cd..`, `li [PATH]` (also `ls` or `dir`), and
`pwd` to work with directories. `uote paths and names with spaces. The shell
accepts one Bicdop command per line. Type `exit` to return to PowerShell.
From PowerShell, use the prefix for individual commands, for example `bicdop show`.

Add the module import to your PowerShell profile to load it on startup.

## Data and recovery

Workspace roots contain `.bicdop-workspace`; projects contain `.bicdop`.
New markers are JSON with a schema number and a random UUID. Project
markers also record the workspace UUID or null. Workspace and project UUIDs
stay stable on rename. Older project markers are visible in scans and
are never overwritten.

The registry is stored in `%LOCALAPPDATA%\Bicdop\registry.json` on Windows
and in the user's local application data directory elsewhere. It maps
workspace and project IDs to last-registered names and paths. Registry writes
are serialized and replaced atomically. If registering a new marker fails,
Bicdop attempts to remove the marker it just created and reports failures.

After moving a workspace, run `bicdop workspace --set` from its new root.
Projects within it have their stored paths adjusted if the matching marker
is present. For a separately moved project, back up the registry, close all
Bicdop sessions, and update the stored path for the matching UUID. If two
folders contain copies of a marker, keep the intended identity in one folder
and remove the copied marker from the other before planting it as a new
project. Bicdop will not silently overwrite the original registration.

## Show workspace folders

`projects` lists registered projects directly under the active workspace.
Its row numbers can be used with `switch`.

`bicdop show` lists the direct subfolders of the active workspace in the same
table as `bicdop scan`, including unmarked and hidden folders. It skips symlinks and junctions.
Use `show` directly while the Bicdop prompt is active.

`bicdop workspace --goto` changes the current PowerShell location to the
active workspace root.

Folder tables display `Size` as the total size of files in the folder and its
descendants. Symlinks and junctions are skipped. A trailing `+` marks a partial
total when some contents could not be read.

## Plant direct subfolders

`bicdop plant --all` creates project markers for the direct subfolders of
the current folder after confirmation. It skips existing markers, the
`.git` directory, symlinks, and junctions. Use `bicdop plant 1,3,5` to plant
specific rows from the latest scan.

## Manage project markers

`bicdop marker --clear` removes the current folder's `.bicdop` marker and
project registration. `bicdop marker --replant` writes or refreshes the marker
and registers the folder with the active workspace. A project marker belongs at the project root, directly under the active
workspace. Replanting with --all targets only those project roots. Clearing
with --all includes nested folders so legacy project markers can be removed.
The workspace marker is preserved.
The console shows scan and marker-processing progress, then reports how many
folders were updated, skipped, or failed.

## Scan defaults

`bicdop scan`, `bicdop scan --git`, and `bicdop scan --project NAME` use the
active workspace. `bicdop scan PATH` uses that path. `--all` and
`--new NAME` scan accessible filesystem drives. Results are read-only,
skip links and junctions, and replace the current session's scan selection.
A failed or interrupted scan invalidates the previous selection. Project
listing and scan numbering are separate.

`bicdop update --check` checks the official stable GitHub release. Applying
an update is deferred until a verified module distribution and update
procedure are available.

## Verify on Windows

Run `powershell.exe -NoProfile -File .\tests\smoke.ps1` for Windows
PowerShell 5.1 and `pwsh -NoProfile -File .\tests\smoke.ps1` for
PowerShell 7 from the checkout root.
For a manual check, import the module in Windows Terminal, enable the
prompt, and use a temporary workspace to test native commands and
`bicdop switch`. Start a broad scan and press Ctrl+C, then verify that
the prompt still accepts commands and that the canceled scan cannot
be used with `bicdop plant 1`. Type `exit` to return to PowerShell.


## Run a project

Run from the current folder with bicdop run, or pass a quoted folder name
to run a direct child of the active workspace. New and replanted markers
store a detected relative main_file. Older markers can use automatic
detection or save a relative path with bicdop run --set FILE from the
project root. Bicdop supports Python, PowerShell, Node.js, and HTML entry points.
HTML entry points such as index.html open as local files in the default Windows browser.

Use bicdop project --main to print the entry point saved in the current folder's marker.
Use bicdop version to check the installed and latest stable versions without applying an update.

Use bicdop project --list to show direct files and folders, including hidden items.

Bicdop records the declared project version in .bicdop when planting or replanting.
It checks package.json, the project section of pyproject.toml, then VERSION.
Use bicdop project --version to read it or bicdop project --version VERSION to set it.
Use bicdop project "Project Name" --version to read a named project in the active workspace without changing folders.

Both project version commands refresh the marker when the declared local version changes.
If no version is declared, they use the value already stored in the marker.

Use run --detach or run "Project Name" --detach for long-running apps.
Bicdop starts a separate process and displays its PID. A normal run waits for
script completion. HTML previews already open separately in the default browser.

Running the same project again with --detach replaces the previous process
started by this Bicdop session. Bicdop requests a normal close when possible,
then stops the process if it stays open. Browser tabs are managed by the browser.
