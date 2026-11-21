# Bicdop 0.4.0

Bicdop runs inside your current Windows PowerShell 5.1 or PowerShell 7 session.

```powershell
Import-Module .\Bicdop\Bicdop.psd1
bicdop
bicdop workspace --set
bicdop scan
bicdop help
```

Use native PowerShell for commands such as `mkdir`, `cd`, and pipelines.
`bicdop exit` restores the original prompt without closing PowerShell.
Add the import to your PowerShell profile to make the command available
in each session. The Git checkout is the source distribution for this milestone.

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
be used with `bicdop plant --all`. Run `bicdop exit` to restore the
original prompt.
