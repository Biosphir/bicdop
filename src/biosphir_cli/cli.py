"""BIOSPHIR developer commands and local project configuration."""

import json
import os
import platform
import shutil
import subprocess
from importlib.metadata import version
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.table import Table
from rich.text import Text

app = typer.Typer(help="BIOSPHIR internal developer toolkit.")
console = Console()
error_console = Console(stderr=True)


def registry_path() -> Path:
    default = Path(__file__).with_name("projects.json")
    return Path(os.environ.get("BIOSPHIR_REGISTRY", str(default))).expanduser()


def workspace_path() -> Path:
    default = Path.home() / "Documents" / "GitHub"
    return Path(os.environ.get("BIOSPHIR_WORKSPACE", str(default))).expanduser()


def load_projects() -> dict[str, dict[str, str]]:
    path = registry_path()
    try:
        entries = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(entries, dict):
            raise ValueError("expected an object keyed by project ID")
        for key, entry in entries.items():
            if not isinstance(entry, dict) or any(
                not isinstance(entry.get(field), str) or not entry[field].strip()
                for field in ("name", "path")
            ):
                raise ValueError(f"project {key!r} needs a name and path")
        return entries
    except (OSError, ValueError) as exc:
        fail(f"Cannot load registry {path}: {exc}")


def fail(message: str) -> None:
    error_console.print(Text(message, style="red"))
    raise typer.Exit(1)


def project_path(entry: dict[str, str]) -> Path:
    return workspace_path() / Path(entry["path"]).expanduser()


def editor_path() -> str | None:
    if os.name == "nt":
        executable = shutil.which("Code.exe")
        if executable:
            return executable
        for variable, directory in (
            ("LOCALAPPDATA", "Programs/Microsoft VS Code"),
            ("ProgramFiles", "Microsoft VS Code"),
            ("ProgramFiles(x86)", "Microsoft VS Code"),
        ):
            base = os.environ.get(variable)
            if base:
                candidate = Path(base) / directory / "Code.exe"
                if candidate.is_file():
                    return str(candidate)
        return None
    return shutil.which("code")


@app.callback(invoke_without_command=True)
def main(
    ctx: typer.Context,
    show_version: Annotated[
        bool, typer.Option("--version", help="Show the BIOSPHIR CLI version.")
    ] = False,
) -> None:
    if show_version:
        typer.echo(f"BIOSPHIR CLI v{version('biosphir-cli')}")
        raise typer.Exit()
    if ctx.invoked_subcommand is None:
        console.print(f"[bold blue]BIOSPHIR CLI v{version('biosphir-cli')}[/]")
        console.print("Internal Developer Toolkit")
        console.print("Run biosphir --help for commands.")


@app.command()
def projects() -> None:
    """List registered projects and their local status."""
    table = Table("Project ID", "Name", "Local repo", "Local status")
    for key, entry in load_projects().items():
        folder = project_path(entry)
        status = "Available" if folder.is_dir() else "Missing"
        table.add_row(Text(key), Text(entry["name"]), Text(folder.name), status)
    console.print(table)


@app.command("open")
def open_project(project: str) -> None:
    """Open a registered project folder in VS Code."""
    entry = load_projects().get(project.lower())
    if entry is None:
        fail(f"Unknown project {project!r}. Run biosphir projects for IDs.")
    path = project_path(entry).absolute()
    if not path.is_dir():
        fail(f"Project folder missing: {path}")
    editor = editor_path()
    if editor is None:
        fail("VS Code was not found. Install it or add its executable to PATH.")
    try:
        subprocess.Popen([editor, str(path)])
    except OSError as exc:
        fail(f"Could not launch VS Code: {exc}")
    console.print(Text(f"Requested VS Code to open {entry['name']}."))


@app.command()
def doctor() -> None:
    """Check Python, Git, VS Code, workspace, and the registry."""
    entries = load_projects()
    git = shutil.which("git")
    editor = editor_path()
    workspace = workspace_path()
    table = Table("Check", "Result")
    table.add_row("Python", platform.python_version())
    table.add_row("Git", Text(git or "Missing from PATH"))
    table.add_row("VS Code", Text(editor or "Missing"))
    table.add_row("Workspace", Text(str(workspace) if workspace.is_dir() else f"Missing: {workspace}"))
    table.add_row("Registry", f"{len(entries)} registered")
    console.print(table)
    if not (git and editor and workspace.is_dir()):
        raise typer.Exit(1)


@app.command()
def info() -> None:
    """Show the CLI version and configuration paths."""
    console.print(Text(f"BIOSPHIR CLI v{version('biosphir-cli')}"))
    console.print(Text(f"Workspace: {workspace_path()}"))
    console.print(Text(f"Registry: {registry_path()}"))
