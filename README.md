# Bicdop

Bicdop (BIOSPHIR Integrated Command & Development Operations Platform) is a
command-line application by BIOSPHIR. This development baseline provides the
entry point and built-in usage help. Commands will be added individually.

## Install for local development

From the repository root in PowerShell:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e .
.\.venv\Scripts\bicdop.exe
```

Run with `--help` to display usage explicitly.

Run `bicdop --update` to check the latest stable GitHub Release and install it
with pip in the current Python environment. Installations made with `--user`
keep that scope. On Windows, wait for pip to finish before running Bicdop again.
Each release tag must match its package version, for example `v0.2.0` for
package version `0.2.0`.

## Set a workspace

```powershell
bicdop --set-workspace "C:\Projects\My Project" --set-name BIOSPHIR_WORKSPACE
bicdop --set-workspace --set-name CURRENT_WORKSPACE
bicdop --set-workspace
```

The path must be an existing folder. With no path, Bicdop saves the current
directory. Names cannot contain whitespace. With no name, Bicdop uses the folder
name and replaces whitespace with hyphens. On Windows the selection is
saved in `%LOCALAPPDATA%\bicdop\workspace.json`.

Save another workspace with `--set-workspace`, then switch between saved
workspaces by name:

```powershell
bicdop --select BIOSPHIR_WORKSPACE
```

Saving a workspace also makes it active. Selecting one updates Bicdop's
configuration and leaves the terminal's current directory as it is.

Use `bicdop --show` to list the direct child folders of the active workspace. Folders missing a `.bicdop` file are labeled and shown
in yellow in a terminal.

## Plant project markers

```powershell
bicdop --plant -here
bicdop --plant -all
bicdop --plant "C:\Projects\My Project"
```

`-here` marks the current folder. `-all` marks the current folder and its
immediate subfolders. A path marks only that existing folder.
`--set-workspace` also creates a marker in the workspace folder itself.
Existing marker files keep their contents.

## Folder commands

Run `bicdop` to enter the interactive prompt. Type the commands below without
the `bicdop` prefix at that prompt. `--cd` and `--cd-back` navigate within the
Bicdop session. `--cd-back` goes to the parent folder. Type `exit` to leave.

```text
--cd "FOLDER_NAME"
--cd-back
--mkdir "NEW_FOLDER_NAME"
--set-name -to "NEW_FOLDER_NAME"
--set-name "FOLDER_NAME" -to "NEW_FOLDER_NAME"
--delete
--delete "FOLDER_NAME"
--delete "FOLDER_NAME" --no-confirm
```

Use quoted folder names, and use workspace names without quotes, such as
`bicdop --select BIOSPHIR_WORKSPACE`. The rename and delete commands accept
a direct child name or act on the current folder if the source is omitted.
Delete removes the folder and all its contents after confirmation, unless
you supply `--no-confirm`. After a successful current-folder delete, the
Bicdop session stays in the parent folder. If you rename or delete a registered
workspace folder, its saved path is not automatically updated.
