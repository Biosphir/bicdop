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
| `biosphir projects` | List project IDs and local folder status |
| `biosphir open notcher` | Open the Notcher folder in VS Code |
| `biosphir doctor` | Check Python, Git, VS Code, workspace, and registry |
| `biosphir --version` | Show the installed CLI version |
| `biosphir info` | Show version and configuration paths |

## Project registry

The bundled registry includes Notcher, Macro Pad Z1, Gwen, and the BIOSPHIR Website. Relative project paths resolve under `~/Documents/GitHub` by default. Set `$env:BIOSPHIR_WORKSPACE = 'D:\Projects'` to use another workspace in the current shell.

To customize the registry, copy [projects.json](src/biosphir_cli/projects.json) and set `$env:BIOSPHIR_REGISTRY` to the copy's path. Each lowercase project ID maps to an object with a `name` and a `path`. Paths can also be absolute. Run `biosphir info` to see the active paths. `doctor` exits with status 1 when a required check fails.

## Run tests

```powershell
.\.venv\Scripts\python.exe -m pip install -e '.[test]'
.\.venv\Scripts\python.exe -m pytest
```
