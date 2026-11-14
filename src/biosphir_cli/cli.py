"""BIOSPHIR developer commands and local project configuration."""

import json
import os
import platform
import re
import shutil
import subprocess
from collections import Counter
from importlib.metadata import version
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Annotated
from uuid import uuid4

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


def discover_projects() -> dict[str, dict[str, str]]:
    entries = load_projects()
    workspace = workspace_path()
    if not workspace.is_dir():
        return entries

    for folder in sorted(workspace.iterdir(), key=lambda path: path.name.lower()):
        marker = folder / ".biosphir"
        if not folder.is_dir() or not marker.is_file():
            continue
        try:
            content = marker.read_text(encoding="utf-8-sig").strip()
            metadata = json.loads(content) if content else {}
            if not isinstance(metadata, dict) or any(
                not isinstance(metadata[field], str) or not metadata[field].strip()
                for field in ("id", "name")
                if field in metadata
            ):
                raise ValueError("expected a JSON object with optional non-empty id and name")
        except (OSError, ValueError) as exc:
            error_console.print(Text(f"Ignoring {marker}: {exc}", style="yellow"))
            continue

        matching = [
            key for key, entry in entries.items()
            if project_path(entry).resolve() == folder.resolve()
        ]
        default_id = matching[0] if matching else folder.name
        key = metadata.get("id", default_id).strip().lower()
        if key in entries and key not in matching:
            error_console.print(Text(f"Ignoring {marker}: project ID {key!r} is already in use.", style="yellow"))
            continue

        default_name = entries[matching[0]]["name"] if matching else folder.name
        for previous_key in matching:
            if previous_key != key:
                del entries[previous_key]
        entries[key] = {"name": metadata.get("name", default_name).strip(), "path": str(folder.absolute())}

    return entries


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
def projects(
    roots: Annotated[
        list[Path] | None, typer.Option("--root", help="Search folder. Repeat for multiple folders.")
    ] = None,
) -> None:
    """List folders containing a .biosphir marker."""
    workspace = workspace_path()
    if workspace.is_dir():
        for folder in sorted(workspace.iterdir()):
            if folder.is_dir() and not (folder / ".biosphir").is_file():
                error_console.print(
                    Text(f"Warning: Workspace folder has no .biosphir file: {folder}", style="yellow")
                )
    folders = find_marked_folders(roots)
    if not folders:
        typer.echo("No .biosphir projects found.")
        return

    table = Table("Project ID", "Name", "Local repo", "Local status")
    table.add_column("Path", overflow="fold")
    for folder in folders:
        try:
            metadata = read_marker(folder / ".biosphir")
        except (OSError, ValueError):
            metadata = {}
        project_id = marker_field(metadata, "id")
        name = marker_field(metadata, "name") or folder.name
        status = "Available" if project_id else "Review"
        table.add_row(Text(project_id.lower() or "-"), Text(name), Text(folder.name), status, Text(str(folder)))
    console.print(table)


def read_marker(marker: Path) -> dict:
    content = marker.read_text(encoding="utf-8-sig").strip()
    metadata = json.loads(content) if content else {}
    if not isinstance(metadata, dict):
        raise ValueError("Expected a JSON object")
    return metadata


def marker_field(metadata: dict, field: str) -> str:
    value = metadata.get(field)
    return value.strip() if isinstance(value, str) else ""


@app.command("open")
def open_project(project: str) -> None:
    """Open a project folder in VS Code."""
    entry = discover_projects().get(project.lower())
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


def marker_path(marker: str, folder: Path) -> Path:
    if marker != ".biosphir":
        fail("Use .biosphir as the marker filename.")
    folder = folder.expanduser().absolute()
    if not folder.is_dir():
        fail(f"Target folder does not exist or is not a directory: {folder}")

    return folder / marker


def marker_defaults(folder: Path) -> dict[str, str]:
    name = folder.name or str(folder)
    project_id = re.sub(r"[^a-z0-9._-]+", "-", name.lower()).strip(".-_")
    return {"id": project_id or f"project-{uuid4().hex}", "name": name}


@app.command()
def plant(
    marker: Annotated[str, typer.Argument(help="Marker filename (.biosphir).")],
    folder: Annotated[Path, typer.Argument(help="Target folder. Defaults to the current folder.")] = Path("."),
) -> None:
    """Create a .biosphir marker in an existing folder."""
    target = marker_path(marker, folder)
    try:
        with target.open("x", encoding="utf-8") as file:
            json.dump(marker_defaults(target.parent), file, ensure_ascii=False, indent=2)
            file.write("\n")
    except FileExistsError:
        if not target.is_file():
            fail(f"Marker path is not a file: {target}")
        console.print(Text(f"Already exists: {target}"))
    except OSError as exc:
        fail(f"Could not create marker {target}: {exc}")
    else:
        console.print(Text(f"Created {target}"))


@app.command()
def fix(
    marker: Annotated[str, typer.Argument(help="Marker filename (.biosphir).")],
    folder: Annotated[Path, typer.Argument(help="Target folder. Defaults to the current folder.")] = Path("."),
) -> None:
    """Repair an existing .biosphir marker."""
    target = marker_path(marker, folder)
    if not target.is_file():
        fail(f"Marker file not found: {target}. Use biosphir plant .biosphir to create it.")
    if target.is_symlink():
        fail(f"Cannot repair a symbolic link: {target}")

    temp_path = None
    try:
        try:
            metadata = json.loads(target.read_text(encoding="utf-8-sig"))
        except ValueError:
            metadata = {}
        if not isinstance(metadata, dict):
            metadata = {}
        missing = [
            key for key in ("id", "name")
            if not isinstance(metadata.get(key), str) or not metadata[key].strip()
        ]
        if not missing:
            console.print(Text(f"Already valid: {target}"))
            return
        defaults = marker_defaults(target.parent)
        for key in missing:
            metadata[key] = defaults[key]
        with NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=target.parent, delete=False
        ) as file:
            temp_path = Path(file.name)
            json.dump(metadata, file, ensure_ascii=False, indent=2)
            file.write("\n")
        temp_path.replace(target)
    except OSError as exc:
        fail(f"Could not repair marker {target}: {exc}")
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)
    console.print(Text(f"Repaired {target}"))


@app.command()
def check(
    marker: Annotated[str, typer.Argument(help="Marker filename (.biosphir).")],
    folder: Annotated[Path, typer.Argument(help="Target folder. Defaults to the current folder.")] = Path("."),
) -> None:
    """Check whether a folder contains a .biosphir file."""
    target = marker_path(marker, folder)
    if not target.is_file():
        fail(f"Marker file not found: {target}")
    console.print(Text(f"Found {target}"))


@app.command()
def delete(
    marker: Annotated[str, typer.Argument(help="Marker filename (.biosphir).")],
    folder: Annotated[Path, typer.Argument(help="Target folder. Defaults to the current folder.")] = Path("."),
) -> None:
    """Delete the .biosphir file in a folder."""
    target = marker_path(marker, folder)
    if not target.is_file():
        fail(f"Marker file not found: {target}")
    try:
        target.unlink()
    except OSError as exc:
        fail(f"Could not delete marker {target}: {exc}")
    console.print(Text(f"Deleted {target}"))


def find_marked_folders(roots: list[Path] | None) -> list[Path]:
    defaults = [workspace_path(), *(Path.home() / name for name in ("Documents", "Downloads", "Desktop"))]
    search_roots = roots or [root for root in defaults if root.is_dir()]
    matches: set[Path] = set()

    def report_error(error: OSError) -> None:
        error_console.print(Text(f"Skipped: {error}", style="yellow"))

    for root in search_roots:
        root = root.expanduser()
        if not root.is_dir():
            fail(f"Search folder does not exist: {root}")
        for directory, folders, files in os.walk(root.resolve(), onerror=report_error):
            folder = Path(directory)
            folders[:] = [
                name for name in folders
                if name not in {".git", ".venv", "node_modules", "__pycache__"}
                and not (folder / name).is_symlink()
                and (folder / name).resolve().parent == folder
            ]
            if not any(os.path.normcase(name) == ".biosphir" for name in files):
                continue
            if (folder / ".biosphir").is_file():
                matches.add(folder)

    return sorted(matches)


@app.command()
def show(
    marker: Annotated[str, typer.Argument(help="Marker filename (.biosphir).")],
    roots: Annotated[
        list[Path] | None, typer.Option("--root", help="Search folder. Repeat for multiple folders.")
    ] = None,
) -> None:
    """Print every folder containing a .biosphir file."""
    if marker != ".biosphir":
        fail("Use .biosphir as the marker filename.")
    folders = find_marked_folders(roots)
    if not folders:
        typer.echo("No .biosphir projects found.")
        return
    table = Table("Folder")
    table.add_column("Path", overflow="fold")
    for folder in folders:
        table.add_row(Text(folder.name or folder.anchor), Text(str(folder)))
    console.print(table)


@app.command()
def discover(
    roots: Annotated[
        list[Path] | None, typer.Option("--root", help="Search folder. Repeat for multiple folders.")
    ] = None,
) -> None:
    """Find marked projects recursively and flag duplicate IDs."""
    matches: dict[Path, tuple[str, str]] = {}
    for folder in find_marked_folders(roots):
        marker = folder / ".biosphir"
        try:
            project_id = marker_field(read_marker(marker), "id")
            if not project_id:
                matches[folder] = ("", "Review: missing ID")
                continue
            matches[folder] = (project_id.strip().lower(), "Detected")
        except (OSError, ValueError):
            matches[folder] = ("", "Review: unreadable or invalid JSON")


    if not matches:
        typer.echo("No .biosphir projects found.")
        return
    counts = Counter(project_id for project_id, _ in matches.values() if project_id)
    table = Table("Project ID", "Folder", "Status")
    for folder, (project_id, status) in sorted(matches.items()):
        if counts[project_id] > 1:
            status = "Duplicate ID"
        table.add_row(Text(project_id or "-"), Text(str(folder)), status)
    console.print(table)


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
