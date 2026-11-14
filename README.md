# BIOSPHIR CLI v0.1.0

An internal developer toolkit for Windows, built with Python, Typer, and Rich.

## Install in PowerShell

Install Python 3.10 or newer and Git. Install VS Code to use `open`.

```powershell
git clone https://github.com/Biosphir/biosphir-cli.git
cd biosphir-cli
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install .
.\.venv\Scripts\biosphir.exe
```

If your shell allows activation, run `. .\.venv\Scripts\Activate.ps1` to use the shorter `biosphir` command. The full executable path also works without activation.

| Command | What it does |
| --- | --- |
| `biosphir` | Show the CLI dashboard |
| `biosphir projects` | List folders with a .biosphir marker |
| `biosphir open notcher` | Open the Notcher folder in VS Code |
| `biosphir doctor` | Check Python, Git, VS Code, workspace, and registry |
| `biosphir --version` | Show the installed CLI version |
| `biosphir info` | Show version and configuration paths |

## Automatic project discovery

Use `plant` to create a marker with a project ID and display name in the current folder or in an existing
folder specified by path. An existing marker keeps its contents.

```powershell
biosphir plant .biosphir
biosphir plant .biosphir "D:\Projects\My Project"
```

Use `check` to verify the marker exists. It exits with status 1 if the marker is missing.

```powershell
biosphir check .biosphir
biosphir check .biosphir "D:\Projects\My Project"
```

Use `delete` to remove the marker from the current folder or a specified folder.

```powershell
biosphir delete .biosphir
biosphir delete .biosphir "D:\Projects\My Project"
```

Run `biosphir show .biosphir` to list marked folders and their paths in a table.
It uses the same search locations and repeatable `--root` option as `discover`,
and includes markers with missing or invalid metadata.

Use `biosphir fix .biosphir` to repair the current folder's marker, or pass a
folder path as the final argument. Repair fills missing fields and rebuilds
unreadable JSON. Valid fields in a JSON object are preserved. Generated IDs
use the lowercase folder name with spaces replaced by hyphens. Review duplicate
IDs with `biosphir discover`.

Discovery scans project folders directly under the workspace.
An empty file uses the folder name as its display name and the lowercase folder
name as its ID. For a stable ID and custom display name, use JSON:

```json
{"id": "my-project", "name": "My Project"}
```

The `projects` command lists only folders with a `.biosphir` marker. It uses
the same recursive search and repeatable `--root` option as `discover` and
marks entries without a readable ID as `Review`. Commit the marker to share
it with everyone who clones the project.

## Discover projects across folders

Run `biosphir discover` to scan the workspace, Documents, Downloads, and Desktop
recursively. To search specific locations, repeat `--root`:

```powershell
biosphir discover --root "D:\Projects" --root "$env:USERPROFILE\Downloads"
```

The report flags duplicate IDs and markers that need review. Discovery leaves
all folders in place.

## Project registry

The bundled registry includes Notcher, Macro Pad Z1, Gwen, and the BIOSPHIR Website. Relative project paths resolve under `~/Documents/GitHub` by default. Set `$env:BIOSPHIR_WORKSPACE = 'D:\Projects'` to use another workspace in the current shell.

To customize the registry, copy [projects.json](src/biosphir_cli/projects.json) and set `$env:BIOSPHIR_REGISTRY` to the copy's path. Each lowercase project ID maps to an object with a `name` and a `path`. Paths can also be absolute. Run `biosphir info` to see the active paths. `doctor` exits with status 1 when a required check fails.

## Run tests

```powershell
.\.venv\Scripts\python.exe -m pip install -e '.[test]'
.\.venv\Scripts\python.exe -m pytest
```
