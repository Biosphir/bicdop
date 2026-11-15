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
workspace. Scroll command history with the mouse wheel over the output panel or with PgUp and PgDn.

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
configuration. Use `--goto-workspace` to change the working directory in Bicdop
to the active workspace.

Use `--show` to list direct child folders of the current directory or
`--projects` to list direct child folders of the active workspace. Both commands display a table. Folders missing a `.bicdop` file are labeled and shown
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

## Connect a GitHub repository

Install Git and the [GitHub CLI](https://cli.github.com/) and make them
available on PATH. Open Bicdop from a local Git checkout, or navigate there
with `--cd`. Run the following in Bicdop:

```text
--set-github "https://github.com/OWNER/REPO"
--push
--pull
```

If GitHub CLI is signed out, Bicdop starts its browser login. You can also
run `--set-github` without a URL to sign in first. Bicdop verifies repository
access and saves the URL and local checkout path in `github.json` alongside
workspace settings. GitHub CLI manages credentials.

Push sends existing commits from the current branch to the branch of the
same name. Pull requires a clean checkout and accepts only fast-forward
updates from that branch. Both commands require the connected checkout,
which prevents running them from another repository by accident. If you
move the checkout, run `--set-github` again from its new location.

## Run a project

Run `--run ProjectName` from the Bicdop prompt. Bicdop looks for the folder
in the current location first, then in the active workspace. A quoted project
path also works. The folder must have a `.bicdop` marker. New markers record
`main.py` when it exists. For a different Python file, enter the project and
run `--set-main app.py` or `--set-main "src/app.py"`. The path is stored
relative to the project, and the script runs from the project folder using
the Python interpreter running Bicdop.

Use `--info ProjectName` to see which folder, marker, main file, and Python
interpreter Bicdop resolves. It uses the same folder search as `--run`.

## Prepare and diagnose a Python project

```text
--info Demo
--status Demo
--doctor Demo
--setup Demo
--run Demo
--test Demo
```

`--doctor` checks the marker, main file, and interpreter. `--setup` creates
or reuses the project's `.venv` and asks before installing `requirements.txt`.
Bicdop prefers the project's `.venv` and otherwise uses its own Python
interpreter. `--test` runs pytest and requires it to be installed in that
interpreter. Add `--` to pass options or select a test file, for example
`--test Demo -- "tests/test_auth.py" -q`. `--status` shows the branch,
change count, Python environment, and main file.

Bicdop saves GitHub connections separately for each local Git checkout. The
header follows the current directory, and push and pull use that checkout's
saved repository. The previous single connection is read and retained when
you add another checkout.

Use `--build Demo` to run `python -m build` with the project interpreter.
The project needs a `pyproject.toml` and the Python `build` package.
Output is written to the project's `dist` directory. The build backend can
install build-time dependencies in its isolated environment.

Use `--git-status` from the current checkout, or pass a project folder.
It displays changed files and ahead/behind information from the last
locally known upstream state.

## Review and commit local Git changes

Run these commands inside the checkout:

```text
--diff
--stage app.py, "test app.py"
--diff --staged
--commit "Describe the changes"
```

`--diff` shows unstaged changes to tracked files. Use `--diff --staged`
to inspect the next commit. Stage individual files, separating multiple
names with commas. `--commit` previews the staged file list and asks for
confirmation. Use `--push` separately when ready to send commits.
