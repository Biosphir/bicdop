# Bicdop

Bicdop (BIOSPHIR Integrated Command & Development Operations Platform) is a developer platform designed to unify project workflows, development environments, and engineering tools.

**One command. Every project.**

Developed by BIOSPHIR. Project management and Python environment workflows are available today. Build, hardware, and AI development tools are planned capabilities.

An internal developer toolkit for Windows, built with Python, Typer, and Rich.

## Command syntax

Use `bicdop --action [target] [path]`. For example, run
`bicdop --clone BICDOP_WORKSPACE` or `bicdop --plant .bicdop`.
Use `bicdop --projects` to list projects and `bicdop --help` to see all actions.

## Interactive mode

Run `bicdop` in CMD or PowerShell to open the `bicdop>` prompt. Type commands
such as `--projects`, `--help`, or `--check .bicdop "D:\My Projects\Demo"`.
Type `--exit` or `--quit` to return to your terminal. Commands such as
`bicdop --projects` also work directly from CMD or PowerShell.

Select a project once per interactive session to run its scripts:

```text
bicdop> --select my-project
bicdop[my-project]> --run main.py
```

The interactive shortcut returns to the prompt immediately, and `--exit` leaves
the launched program running. Use `--run main.py --wait` to see script output
and wait for it to finish.

## Install in PowerShell

Install Python 3.10 or newer and Git.

```powershell
git clone https://github.com/Biosphir/biosphir-cli.git
cd biosphir-cli
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install .
.\.venv\Scripts\bicdop.exe
```

If your shell allows activation, run `. .\.venv\Scripts\Activate.ps1` to use the shorter `bicdop` command. The full executable path also works without activation.

| Command | What it does |
| --- | --- |
| `bicdop` | Start interactive mode in a terminal |
| `bicdop --projects` | List folders with a .bicdop marker |
| `bicdop --open notcher` | Open the Notcher folder in File Explorer |
| `bicdop --doctor` | Check Python, Git, VS Code, workspace, and registry |
| `bicdop --version` | Show the installed CLI version |
| `bicdop --help` | Show all commands |
| `bicdop --info` | Show version and configuration paths |

## Automatic project discovery

Use `plant` to create a marker with a project ID and display name in the current folder or in an existing
folder specified by path. An existing marker keeps its contents.

```powershell
bicdop --plant .bicdop
bicdop --plant .bicdop "D:\Projects\My Project"
```

Use `check` to verify the marker exists. It exits with status 1 if the marker is missing.

```powershell
bicdop --check .bicdop
bicdop --check .bicdop "D:\Projects\My Project"
```

Use `delete` to remove the marker from the current folder or a specified folder.

```powershell
bicdop --delete .bicdop
bicdop --delete .bicdop "D:\Projects\My Project"
```

Run `bicdop --show .bicdop` to list marked folders and their paths in a table.
It uses the same search locations and repeatable `--root` option as `discover`,
and includes markers with missing or invalid metadata.

Use `bicdop --fix .bicdop` to repair the current folder's marker, or pass a
folder path as the final argument. Repair fills missing fields and rebuilds
unreadable JSON. Valid fields in a JSON object are preserved. Generated IDs
use the lowercase folder name with spaces replaced by hyphens. Review duplicate
IDs with `bicdop --discover`.

Discovery scans project folders directly under the workspace.
An empty file uses the folder name as its display name and the lowercase folder
name as its ID. For a stable ID and custom display name, use JSON:

```json
{"id": "my-project", "name": "My Project"}
```

The `--projects` command lists folders with a `.bicdop` marker. It uses
the same recursive search and repeatable `--root` option as `discover` and
marks entries without a readable ID as `Review`. It warns about immediate
workspace subfolders that lack a marker. Commit the marker to share
it with everyone who clones the project.

## Discover projects across folders

Run `bicdop --discover` to scan the workspace, Documents, Downloads, and Desktop
recursively. To search specific locations, repeat `--root`:

```powershell
bicdop --discover --root "D:\Projects" --root "$env:USERPROFILE\Downloads"
```

The report flags duplicate IDs and markers that need review. Discovery leaves
all folders in place.

## Set your workspace

Navigate to the folder you want as your workspace and run:

```powershell
bicdop --set BICDOP_WORKSPACE
bicdop --info
```

The CLI saves the folder for future sessions. A `BICDOP_WORKSPACE`
environment variable takes precedence over the saved setting.

## Project registry

The bundled registry includes Notcher, Macro Pad Z1, Gwen, and the BIOSPHIR Website. Relative project paths resolve under `~/Documents/GitHub` by default. Set `$env:BICDOP_WORKSPACE = 'D:\Projects'` to use another workspace in the current shell.

To customize the registry, copy [projects.json](src/biosphir_cli/projects.json) and set `$env:BICDOP_REGISTRY` to the copy's path. Each lowercase project ID maps to an object with a `name` and a `path`. Paths can also be absolute. Run `bicdop --info` to see the active paths. `doctor` exits with status 1 when a required check fails.

## Run tests

```powershell
.\.venv\Scripts\python.exe -m pip install -e '.[test]'
.\.venv\Scripts\python.exe -m pytest
```


To mark all unmarked folders directly under the workspace, run
`bicdop --plant .bicdop BICDOP_WORKSPACE` and confirm the listed folders.
Use `bicdop --plant .bicdop BICDOP_WORKSPACE --no-confirm` to skip the prompt.


Use `bicdop --collect` to preview and confirm moves into the workspace.
Add `--no-confirm` to skip the prompt. Moves use the default discovery locations
and keep nested projects inside their parent project. A destination conflict
stops the operation before moving any folders. Moves require the source and
workspace to be on the same volume.


Use `bicdop --delete project-id another-id` to permanently delete
the selected project folders and their contents. The command lists the paths
and asks for confirmation. Add `--no-confirm` to skip the prompt.
Missing or duplicate IDs stop the command before deletion begins.

```powershell
bicdop --rename "project-id" PROJECT_ID "new-project-id"
bicdop --rename "project-id" PROJECT_NAME "New Project Name"
```

The selected field is saved in `.bicdop`. IDs are stored in lowercase and
must be unique across discovered projects. Display names must also be unique
when renaming, ignoring letter case. The folder path stays the same.
After changing the ID of the selected project, select it again using the new ID.

Run `bicdop --run project-id main.py` to execute a Python script from
the project folder. It uses the project's `.venv` when available and otherwise
uses the base Python installation behind the CLI.

## Updating

Exit interactive mode and run `bicdop --update` from your terminal. The CLI
checks the latest stable GitHub release and installs it only when it is newer.
Published release tags must use a version such as `v0.2.0` and match the version
in `pyproject.toml`. On Windows, wait for the installer output before reopening
BIOSPHIR and checking `bicdop --version`.


## Clone a project or workspace

```powershell
bicdop --clone BICDOP_WORKSPACE
bicdop --clone BICDOP_WORKSPACE "D:\Backups\BIOSPHIR"
bicdop --clone "project-id"
bicdop --clone "project-id" "D:\Backups\Project Copy"
```

With no destination, a workspace clone creates a folder ending in `-copy`
in the current terminal directory. A single project is copied beside its source. A supplied
path names the new folder and its parent must already exist. Cloning copies
the original files and Git metadata. Each copied project marker gets an ID
ending in `-clone`, or `-clone-2`, `-clone-3`, and so on when an ID is already
in use. Choose a destination outside the source folder.

### Multiple targets

Repeat `--and` to add targets:

```powershell
bicdop --clone "project-a" --and "project-b" --and "project-c"
bicdop --delete "project-a" --and "project-b"
bicdop --plant .bicdop --to "D:\Projects\First" --and "D:\Projects\Second"
```

Use `--to` once before the first path. For clone, `--to` sets the destination
for the first project. Additional projects use their default destinations.

## Set up a Python project

Run `bicdop --setup project-id` to create or reuse the project's `.venv`
and install dependencies from `requirements.txt`. Then use
`bicdop --run project-id main.py`.

Use `bicdop --status project-id` to check the project path, Python environment,
common Python files, and local Git status.

Use `bicdop --move project-id --to "D:\Projects"` to move the project into an
existing parent folder on the same volume. The project keeps its folder name.
Choose a location within the discovery roots to keep finding the project by ID.

Project markers store `schema_version` and an optional project-relative
Python `entrypoint`. Use `bicdop --run project-id` or `--run` after
selecting a project in interactive mode. Use `--fix .bicdop` to fill missing fields.

## Compatibility and development



For development, install dependencies with `python -m pip install -e ".[test]"` and run `python -m pytest`. The option-style commands documented above are the current command reference.

## Project markers


When upgrading an existing installation, uninstall the old distribution first with `python -m pip uninstall biosphir-cli`, then install Bicdop in the same environment. This avoids two distributions owning the same Python package and executable.

Bicdop discovers projects with a `.bicdop` marker. To migrate a project, rename its existing marker to `.bicdop` if that filename is available. Keep the JSON contents intact. Gwen launch configurations should invoke `bicdop`. Existing workspace settings are still read from the original configuration path, and legacy environment variables are accepted as fallbacks.

For the registry and task runner, see [Configured projects](CONFIGURED_PROJECTS.md). The option-style commands above cover the existing workspace workflow.
