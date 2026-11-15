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

Run `bicdop` to clear the screen and open the interactive prompt. Type `--help`
there to display usage, or `exit` to leave. The header shows the active
workspace. Scroll command history with PgUp and PgDn.

Inside the Bicdop prompt, run `--update` to check the latest stable GitHub Release and install it
with pip in the current Python environment. Installations made with `--user`
keep that scope. When an update starts, Bicdop exits. On Windows, wait for pip
to finish before reopening Bicdop.
Each release tag must match its package version, for example `v0.2.0` for
package version `0.2.0`.

## Set a workspace

```powershell
--set-workspace "C:\Projects\My Project" --setBIOSPHIR_WORKSPACE
--set-workspace --setCURRENT_WORKSPACE
--set-workspace
```

The path must be an existing folder. With no path, Bicdop saves the current
directory. Bicdop uses the folder name and replaces whitespace with hyphens.
`--set-name` is for renaming folders. On Windows the selection is
saved in `%LOCALAPPDATA%\bicdop\workspace.json`.

Save another workspace with `--set-workspace`, then switch between saved
workspaces by name:

```powershell
--select My-Project
```

`--set-name-workspace NEW_NAME` changes the active workspace name without
renaming the folder. Workspace names cannot contain whitespace.

Saving a workspace also makes it active. Selecting one updates Bicdop's
configuration and leaves the terminal's current directory as it is.

Use `--show` to list the direct child folders of the active workspace. Folders missing a `.bicdop` file are labeled and shown
in yellow in a terminal.

## Plant project markers

```powershell
--plant -here
--plant -all
--plant "C:\Projects\My Project"
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
--set-to "NEW_FOLDER_NAME"
--set"FOLDER_NAME" -to "NEW_FOLDER_NAME"
--delete
--delete "FOLDER_NAME"
--delete "FOLDER_NAME" --no-confirm
```

Use quotes around paths and folder names containing spaces. Workspace names can be used without quotes, such as
`--select My-Project`. The rename and delete commands accept
a direct child name or act on the current folder if the source is omitted.
Delete removes the folder and all its contents after confirmation, unless
you supply `--no-confirm`. After a successful current-folder delete, the
Bicdop session stays in the parent folder. If you rename or delete a registered
workspace folder, its saved path is not automatically updated.

Use `--find .bicdop` to search recursively from the current folder, the active
workspace, and your Documents, Desktop, and Downloads folders. Results outside
the active workspace are yellow in the terminal. With no active workspace,
all matches are labeled as outside the workspace.

## Find and collect projects

`--find .bicdop` lists full paths for marked folders in the documented search
locations. The prompt always displays the current workspace name and path.

```text
--delete "Folder One", "Folder Two" --no-confirm
--collect
--collect --copy
```

A comma separates direct child names for deletion. Bicdop validates all targets
before deleting and asks once unless you pass `--no-confirm`.

Collect previews the source and destination for each marked folder outside the
workspace, then asks for confirmation. Nested marked folders move or copy with
their marked ancestor. Collect skips folders containing the active workspace,
current directory or home directory. Destination name conflicts stop the
operation before any changes. Moving requires the same drive. Use
`--collect --copy` to copy from another drive and retain the originals.

A `.bicdop` marker stores `folder_name` and `folder_path`. Bicdop refreshes
these fields when renaming, moving, or copying marked folders. After an
external rename, `--find .bicdop` shows the actual path. Run `--plant -here`
inside the renamed folder to refresh its marker. Refreshing a marker also
removes its former ID field.

Use plain folder names or quoted paths. Quote names containing spaces.
Separate multiple folders with commas. Use the full quoted path when a name is ambiguous.

```text
--collect "Project One", "Project Two", "C:\Downloads\Another Folder"
--collect "C:\Downloads\Project One" --copy
--delete "Folder One", "Folder Two" --no-confirm
```
