"""BIOSPHIR developer commands and local project configuration."""

import json
import os
import platform
import re
import shutil
import shlex
import subprocess
import stat
import sys
from collections import Counter
from enum import Enum
from importlib.metadata import version
from pathlib import Path
from tempfile import NamedTemporaryFile, TemporaryDirectory
from typing import Annotated
from uuid import uuid4

import typer
from typer.core import TyperGroup
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn, TimeElapsedColumn
from rich.table import Table
from rich.text import Text

class ActionGroup(TyperGroup):
    def parse_args(self, ctx: typer.Context, args: list[str]) -> list[str]:
        # A registered action starts with "--", so end group option parsing
        # before Typer resolves it as a command with its own arguments.
        if args and args[0] in self.commands and args[0].startswith("--"):
            args = ["--", *args]
        return super().parse_args(ctx, args)


app = typer.Typer(cls=ActionGroup, context_settings={"help_option_names": []}, help="BIOSPHIR internal developer toolkit.")
console = Console()
error_console = Console(stderr=True)


def registry_path() -> Path:
    default = Path(__file__).with_name("projects.json")
    return Path(os.environ.get("BIOSPHIR_REGISTRY", str(default))).expanduser()


def workspace_config_path() -> Path:
    base = os.environ.get("LOCALAPPDATA") if os.name == "nt" else os.environ.get("XDG_CONFIG_HOME")
    return Path(base or Path.home() / ".config") / "biosphir-cli" / "workspace.json"


def workspace_path() -> Path:
    override = os.environ.get("BIOSPHIR_WORKSPACE")
    if override:
        return Path(override).expanduser()
    config = workspace_config_path()
    try:
        value = json.loads(config.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return Path.home() / "Documents" / "GitHub"
    except (OSError, ValueError) as exc:
        fail(f"Cannot read workspace setting {config}: {exc}")
    if not isinstance(value, dict) or not marker_field(value, "path"):
        fail(f"Invalid workspace setting: {config}")
    return Path(value["path"])


def set_workspace(setting: str) -> None:
    if setting != "BIOSPHIR_WORKSPACE":
        fail("Use --set BIOSPHIR_WORKSPACE to save the current folder.")
    folder = Path.cwd()
    config = workspace_config_path()
    try:
        config.parent.mkdir(parents=True, exist_ok=True)
        write_marker(config, {"path": str(folder)})
    except OSError as exc:
        fail(f"Cannot save workspace setting: {exc}")
    typer.echo(f"Saved BIOSPHIR_WORKSPACE: {folder}")
    if os.environ.get("BIOSPHIR_WORKSPACE"):
        error_console.print("The BIOSPHIR_WORKSPACE environment variable overrides the saved setting.")


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
    update: Annotated[bool, typer.Option("--update", help="Install the latest stable GitHub release.")] = False,
    setting: Annotated[str | None, typer.Option("--set", help="Save BIOSPHIR_WORKSPACE as the current folder.")] = None,
) -> None:
    if setting is not None:
        set_workspace(setting)
        raise typer.Exit()
    if update:
        from .updater import update_cli

        try:
            update_cli(version("biosphir-cli"))
        except (OSError, ValueError, RuntimeError) as exc:
            fail(f"Update failed: {exc}")
        raise typer.Exit()
    if show_version:
        typer.echo(f"BIOSPHIR CLI v{version('biosphir-cli')}")
        raise typer.Exit()
    if ctx.invoked_subcommand is None:
        if sys.stdin.isatty() and sys.stdout.isatty():
            os.system("cls" if os.name == "nt" else "clear")
        console.print(f"[bold blue]BIOSPHIR CLI v{version('biosphir-cli')}[/]")
        console.print("Internal Developer Toolkit")
        if sys.stdin.isatty():
            console.print("Type --help for commands or --exit to leave.")
            interactive_shell()
        else:
            console.print("Run biosphir --help for all commands.")


def interactive_shell() -> None:
    selected_project = None
    while True:
        try:
            prompt = f"biosphir[{selected_project}]> " if selected_project else "biosphir> "
            line = input(prompt).strip()
        except EOFError:
            typer.echo()
            return
        except KeyboardInterrupt:
            typer.echo()
            continue
        if line.lower() in {"--exit", "--quit"}:
            return
        lexer = shlex.shlex(line, posix=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        if os.name == "nt":
            lexer.escape = ""
        try:
            args = list(lexer)
        except ValueError as exc:
            error_console.print(Text(f"Invalid command: {exc}", style="red"))
            continue
        if len(args) == 2 and args[0] == "--select" and args[1] != "--help":
            try:
                marker = find_project_marker(args[1])
            except typer.Exit:
                continue
            selected_project = args[1].strip().lower()
            typer.echo(f"Selected {selected_project}: {marker.parent}")
            continue
        if args == ["--update"]:
            typer.echo("Type --exit, then run biosphir --update from your terminal.")
            continue
        if args and args[0] == "--run" and "--help" not in args[1:]:
            operands = [arg for arg in args[1:] if arg not in {"--background", "--wait"}]
            if len(operands) == 1 and selected_project is None:
                error_console.print("Select a project first with --select PROJECT_ID.")
                continue
            if len(operands) == 1:
                args = ["--run", "--background", selected_project, *args[1:]]
        if args:
            try:
                subprocess.run([sys.executable, "-m", "biosphir_cli", *args], check=False)
            except KeyboardInterrupt:
                typer.echo()


@app.command("--help", context_settings={"help_option_names": ["--help"]})
def help(ctx: typer.Context) -> None:
    """Show all BIOSPHIR commands."""
    typer.echo(ctx.find_root().get_help())


def unmarked_workspace_folders() -> list[Path]:
    workspace = workspace_path()
    if not workspace.is_dir():
        return []
    return [
        folder for folder in sorted(workspace.iterdir())
        if folder.is_dir() and not (folder / ".biosphir").is_file()
    ]


@app.command("--projects", context_settings={"help_option_names": ["--help"]})
def projects(
    roots: Annotated[
        list[Path] | None, typer.Option("--root", help="Search folder. Repeat for multiple folders.")
    ] = None,
) -> None:
    """List folders containing a .biosphir marker."""
    for folder in unmarked_workspace_folders():
        error_console.print(
            Text(f"Warning: Workspace folder has no .biosphir file: {folder}", style="yellow")
        )
    folders = find_marked_folders(roots)
    if not folders:
        typer.echo("No .biosphir projects found.")
        return

    table = Table("Project ID", "Name", "Local repo", "Local status")
    table.add_column("Path", overflow="fold")
    workspace = workspace_path().resolve()
    for folder in folders:
        try:
            metadata = read_marker(folder / ".biosphir")
        except (OSError, ValueError):
            metadata = {}
        project_id = marker_field(metadata, "id")
        name = marker_field(metadata, "name") or folder.name
        status = "Available" if project_id else "Review"
        path_style = "" if folder.is_relative_to(workspace) else "yellow"
        table.add_row(
            Text(project_id.lower() or "-"), Text(name), Text(folder.name),
            status, Text(str(folder), style=path_style),
        )
    console.print(table)


def read_marker(marker: Path) -> dict:
    content = marker.read_text(encoding="utf-8-sig").strip()
    metadata = json.loads(content) if content else {}
    if not isinstance(metadata, dict):
        raise ValueError("Expected a JSON object")
    return metadata


def write_marker(target: Path, metadata: dict) -> None:
    temp_path = None
    try:
        with NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=target.parent, delete=False
        ) as file:
            temp_path = Path(file.name)
            json.dump(metadata, file, ensure_ascii=False, indent=2)
            file.write("\n")
        temp_path.replace(target)
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


def marker_field(metadata: dict, field: str) -> str:
    value = metadata.get(field)
    return value.strip() if isinstance(value, str) else ""


@app.command("--open", context_settings={"help_option_names": ["--help"]})
def open_project(project: str) -> None:
    """Open a project folder in the file manager."""
    entry = discover_projects().get(project.lower())
    if entry is None:
        fail(f"Unknown project {project!r}. Run biosphir --projects for IDs.")
    path = project_path(entry).absolute()
    if not path.is_dir():
        fail(f"Project folder missing: {path}")
    file_manager = {"Windows": "explorer.exe", "Darwin": "open"}.get(
        platform.system(), "xdg-open"
    )
    try:
        subprocess.Popen([file_manager, str(path)])
    except OSError as exc:
        fail(f"Could not open folder {path}: {exc}")
    console.print(Text(f"Opening {path}"))


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


@app.command("--plant", context_settings={"help_option_names": ["--help"]})
def plant(
    marker: Annotated[str, typer.Argument(help="Marker filename (.biosphir).")],
    folder: Annotated[
        str | None, typer.Argument(help="Folder path or BIOSPHIR_WORKSPACE for bulk planting.")
    ] = None,
    to: Annotated[
        str | None, typer.Option("--to", help="First folder path or BIOSPHIR_WORKSPACE.")
    ] = None,
    additional_folders: Annotated[
        list[str] | None, typer.Option("--and", help="Additional folder path. Repeat as needed.")
    ] = None,
    no_confirm: Annotated[
        bool, typer.Option("--no-confirm", help="Skip confirmation when planting across the workspace.")
    ] = False,
) -> None:
    """Create a .biosphir marker in a folder or across the workspace."""
    if folder is not None and to is not None:
        fail("Provide the first folder either as an argument or with --to.")
    folders = [to or folder or ".", *(additional_folders or [])]
    for item in folders:
        marker_path(marker, workspace_path() if item == "BIOSPHIR_WORKSPACE" else Path(item))
    for item in folders:
        if item == "BIOSPHIR_WORKSPACE":
            plant_workspace(marker, no_confirm)
        else:
            plant_marker(marker, Path(item))


def plant_marker(marker: str, folder: Path) -> None:
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


def plant_workspace(marker: str, no_confirm: bool) -> None:
    workspace = workspace_path()
    marker_path(marker, workspace)
    folders = unmarked_workspace_folders()
    if not folders:
        typer.echo("All workspace folders already have .biosphir.")
        return

    for folder in folders:
        typer.echo(str(folder))
    if not no_confirm and not typer.confirm("Create .biosphir in these folders?"):
        typer.echo("Cancelled.")
        return

    failed = False
    for folder in folders:
        try:
            plant_marker(marker, folder)
        except typer.Exit:
            failed = True
    if failed:
        raise typer.Exit(1)


def matching_project_markers(project_id: str) -> list[Path]:
    key = project_id.strip().lower()
    matches = []
    for folder in find_marked_folders(None):
        marker = folder / ".biosphir"
        try:
            metadata = read_marker(marker)
        except (OSError, ValueError):
            continue
        if key and marker_field(metadata, "id").lower() == key:
            matches.append(marker)

    return matches


def find_project_marker(project_id: str) -> Path:
    matches = matching_project_markers(project_id)
    if not matches:
        fail(f"Project ID not found: {project_id!r}")
    if len(matches) > 1:
        fail(f"Ambiguous project ID {project_id!r}: " + ", ".join(map(str, matches)))

    return matches[0]


@app.command("--select", context_settings={"help_option_names": ["--help"]})
def select_project(
    project_id: Annotated[str, typer.Argument(help="Project ID to select in interactive mode.")],
) -> None:
    """Select a project at the biosphir prompt."""
    fail("Start interactive mode with biosphir, then run --select PROJECT_ID.")


@app.command("--run", context_settings={"help_option_names": ["--help"]})
def run_project(
    project_id: Annotated[str, typer.Argument(help="Project ID.")],
    script: Annotated[Path, typer.Argument(help="Python script relative to the project folder.")],
    background: Annotated[
        bool, typer.Option("--background/--wait", help="Run separately or wait for the script to finish.")
    ] = False,
) -> None:
    """Run a Python script from a project folder."""
    folder = find_project_marker(project_id).parent
    target = (folder / script).resolve()
    if not target.is_relative_to(folder) or target.suffix.lower() != ".py" or not target.is_file():
        fail(f"Expected an existing .py file inside the project: {target}")

    executable = folder / ".venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    if not executable.is_file():
        executable = Path(getattr(sys, "_base_executable", None) or sys.executable)
    command = [str(executable), str(target)]
    try:
        if background:
            process = subprocess.Popen(
                command,
                cwd=folder,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.DETACHED_PROCESS if os.name == "nt" else 0,
                start_new_session=os.name != "nt",
            )
            typer.echo(f"Started {target.name} (PID {process.pid}). Use --wait to see script output.")
            return
        result = subprocess.run(command, cwd=folder, check=False)
    except OSError as exc:
        fail(f"Could not run {target}: {exc}")
    raise typer.Exit(result.returncode)


class RenameField(str, Enum):
    PROJECT_ID = "PROJECT_ID"
    PROJECT_NAME = "PROJECT_NAME"


@app.command("--rename", context_settings={"help_option_names": ["--help"]})
def rename_project(
    project_id: Annotated[str, typer.Argument(help="Current project ID.")],
    field: Annotated[RenameField, typer.Argument(help="Project field to change.")],
    value: Annotated[str, typer.Argument(help="New value for the selected field.")],
) -> None:
    """Change a project's ID or display name."""
    value = value.strip()
    if not value:
        fail(f"{field.value} cannot be empty.")

    marker = find_project_marker(project_id)
    key = project_id.strip().lower()
    if field == RenameField.PROJECT_ID:
        value = value.lower()
        if value != key and matching_project_markers(value):
            fail(f"Project ID already in use: {value!r}")
        metadata_key = "id"
    else:
        metadata_key = "name"
        for folder in find_marked_folders(None):
            other_marker = folder / ".biosphir"
            if other_marker == marker:
                continue
            try:
                other_name = marker_field(read_marker(other_marker), "name")
            except (OSError, ValueError):
                other_name = ""
            if (other_name or folder.name).casefold() == value.casefold():
                fail(f"Project name already in use: {value!r}")

    try:
        metadata = read_marker(marker)
        if marker.is_symlink() or marker_field(metadata, "id").lower() != key:
            fail(f"Project marker changed or is a symbolic link: {marker}")
        metadata[metadata_key] = value
        write_marker(marker, metadata)
    except (OSError, ValueError) as exc:
        fail(f"Could not rename project {project_id!r}: {exc}")
    typer.echo(f"Updated {field.value} for {project_id} to {value}")


@app.command("--delete", context_settings={"help_option_names": ["--help"]})
def delete(
    targets: Annotated[
        list[str], typer.Argument(help="Project IDs, or .biosphir followed by an optional folder path.")
    ],
    additional_targets: Annotated[
        list[str] | None, typer.Option("--and", help="Additional project ID or marker folder. Repeat as needed.")
    ] = None,
    no_confirm: Annotated[
        bool, typer.Option("--no-confirm", help="Delete project folders without prompting.")
    ] = False,
) -> None:
    """Delete project folders permanently or remove a .biosphir marker."""
    if targets[0] == ".biosphir":
        if len(targets) > 2:
            fail("Provide at most one folder path after .biosphir.")
        folders = [Path(item) for item in [*targets[1:], *(additional_targets or [])]]
        folders = list(dict.fromkeys(folder.expanduser().resolve() for folder in folders or [Path(".")]))
        for folder in folders:
            target = marker_path(".biosphir", folder)
            if not target.is_file():
                fail(f"Marker file not found: {target}")
        for folder in folders:
            delete_marker(folder)
        return
    delete_projects([*targets, *(additional_targets or [])], no_confirm)


def retry_readonly_file_delete(operation, filename, error_info) -> None:
    error = error_info[1]
    if os.name != "nt" or operation is not os.unlink or getattr(error, "winerror", None) != 5:
        raise error
    attributes = os.lstat(filename).st_file_attributes
    if not attributes & stat.FILE_ATTRIBUTE_READONLY or attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
        raise error
    os.chmod(filename, stat.S_IWRITE)
    try:
        operation(filename)
    except OSError:
        os.chmod(filename, stat.S_IREAD)
        raise


def delete_projects(project_ids: list[str], no_confirm: bool) -> None:
    matches: dict[str, list[Path]] = {
        key: [] for key in dict.fromkeys(value.strip().lower() for value in project_ids)
    }
    for folder in find_marked_folders(None):
        try:
            key = marker_field(read_marker(folder / ".biosphir"), "id").lower()
        except (OSError, ValueError):
            continue
        if key and key in matches:
            matches[key].append(folder)

    protected = [Path.home().resolve(), workspace_path().resolve(), Path.cwd().resolve()]
    protected.extend(Path.home().joinpath(name).resolve() for name in ("Documents", "Downloads", "Desktop"))
    targets = []
    for key, folders in matches.items():
        if not folders:
            fail(f"Project ID not found: {key!r}")
        if len(folders) > 1:
            fail(f"Ambiguous project ID {key!r}: " + ", ".join(map(str, folders)))
        folder = folders[0]
        if any(path.is_relative_to(folder) for path in protected):
            fail(f"Cannot delete a protected or enclosing folder: {folder}")
        targets.append((key, folder))

    if any(parent in folder.parents for _, folder in targets for _, parent in targets):
        fail("Selected projects overlap. Select the parent project to delete its entire folder.")

    for key, folder in targets:
        typer.echo(f"{key}: {folder}")
    if not no_confirm and not typer.confirm("Permanently delete these folders and their contents?"):
        typer.echo("Cancelled.")
        return

    for key, folder in targets:
        try:
            if folder.resolve() != folder or marker_field(
                read_marker(folder / ".biosphir"), "id"
            ).lower() != key:
                fail(f"Project changed since discovery: {folder}")
            shutil.rmtree(folder, onerror=retry_readonly_file_delete)
        except (OSError, ValueError) as exc:
            fail(f"Could not delete {folder}: {exc}")
        typer.echo(f"Deleted {folder}")


def clone_marker_updates(source: Path) -> dict[Path, dict]:
    source_folders = find_marked_folders([source])
    used_ids = set()
    source_metadata = {}
    for folder in sorted(set(find_marked_folders(None)) | set(source_folders)):
        try:
            metadata = read_marker(folder / ".biosphir")
        except (OSError, ValueError):
            continue
        project_id = marker_field(metadata, "id").lower()
        if project_id:
            used_ids.add(project_id)
        if folder in source_folders:
            source_metadata[folder] = metadata

    updates = {}
    for folder, metadata in source_metadata.items():
        original_id = marker_field(metadata, "id").lower() or marker_defaults(folder)["id"]
        base_id = f"{original_id}-clone"
        clone_id = base_id
        number = 2
        while clone_id in used_ids:
            clone_id = f"{base_id}-{number}"
            number += 1
        used_ids.add(clone_id)
        updates[folder.relative_to(source) / ".biosphir"] = {**metadata, "id": clone_id}
    return updates


@app.command("--clone", context_settings={"help_option_names": ["--help"]})
def clone_project(
    project: Annotated[str, typer.Argument(help="Project ID or BIOSPHIR_WORKSPACE.")],
    destination: Annotated[
        Path | None, typer.Argument(help="New folder path. Workspace copies default to the current directory.")
    ] = None,
    to: Annotated[
        Path | None, typer.Option("--to", help="Destination folder for the first clone.")
    ] = None,
    additional_projects: Annotated[
        list[str] | None, typer.Option("--and", help="Additional project ID or BIOSPHIR_WORKSPACE. Repeat as needed.")
    ] = None,
) -> None:
    """Duplicate projects or the workspace, including their files."""
    if destination is not None and to is not None:
        fail("Provide the destination either as an argument or with --to.")
    plan = [clone_paths(project, to if to is not None else destination)]
    plan.extend(clone_paths(item, None) for item in additional_projects or [])
    targets = [target.resolve() for _, target in plan]
    if len(set(targets)) != len(targets):
        fail("Multiple clones would use the same destination.")
    for source, target in plan:
        copy_project(source, target)


def clone_paths(project: str, destination: Path | None) -> tuple[Path, Path]:
    whole_workspace = project == "BIOSPHIR_WORKSPACE"
    source = (
        workspace_path().resolve()
        if whole_workspace
        else find_project_marker(project).parent
    )
    if not source.is_dir():
        fail(f"Source folder does not exist: {source}")
    default_parent = Path.cwd() if whole_workspace else source.parent
    target = (
        destination.expanduser().absolute()
        if destination is not None
        else default_parent / f"{source.name}-copy"
    )
    if target.resolve().is_relative_to(source):
        fail(f"Destination must be outside the source: {target}")
    if os.path.lexists(target):
        fail(f"Destination already exists: {target}")
    if not target.parent.is_dir():
        fail(f"Destination parent folder does not exist: {target.parent}")

    return source, target


def copy_project(source: Path, target: Path) -> None:
    try:
        updates = clone_marker_updates(source)
        with Progress(
            SpinnerColumn(),
            TextColumn("Cloning"),
            TextColumn("{task.completed:.0f} copied"),
            TextColumn("{task.fields[filename]}", markup=False),
            TimeElapsedColumn(),
            console=console,
            transient=True,
        ) as progress:
            task = progress.add_task("Cloning", total=None, filename="")
            copied = 0

            def copy_file(original: str, destination: str) -> str:
                nonlocal copied
                progress.update(task, filename=Path(original).name, refresh=True)
                result = shutil.copy2(original, destination)
                copied += 1
                progress.advance(task)
                return result

            with TemporaryDirectory(prefix=".biosphir-clone-", dir=target.parent) as directory:
                staged = Path(directory) / "copy"
                shutil.copytree(source, staged, symlinks=True, copy_function=copy_file)
                for marker, metadata in updates.items():
                    write_marker(staged / marker, metadata)
                if os.path.lexists(target):
                    fail(f"Destination already exists: {target}")
                staged.rename(target)
        typer.echo(f"Files copied: {copied}")
    except OSError as exc:
        fail(f"Could not clone {source} to {target}: {exc}")
    typer.echo(f"Cloned {source} to {target}")


@app.command("--collect", context_settings={"help_option_names": ["--help"]})
def collect_workspace(
    no_confirm: Annotated[
        bool, typer.Option("--no-confirm", help="Move projects without prompting.")
    ] = False,
) -> None:
    """Move marked projects into the workspace."""
    workspace = workspace_path().resolve()
    if not workspace.is_dir():
        fail(f"Workspace folder does not exist: {workspace}")

    outside = {
        folder for folder in find_marked_folders(None)
        if not folder.is_relative_to(workspace)
    }
    sources = [
        folder for folder in sorted(outside)
        if not any(parent in outside for parent in folder.parents)
    ]
    if not sources:
        typer.echo("No marked projects outside the workspace.")
        return

    plan = [(source, workspace / source.name) for source in sources]
    counts = Counter(os.path.normcase(target.name) for _, target in plan)
    for source, target in plan:
        if workspace.is_relative_to(source) or source == Path.home().resolve():
            fail(f"Cannot collect an enclosing folder: {source}")
        if os.path.lexists(target) or counts[os.path.normcase(target.name)] > 1:
            fail(f"Destination conflict: {target}")
        typer.echo(f"{source} -> {target}")

    if not no_confirm and not typer.confirm("Move these folders into the workspace?"):
        typer.echo("Cancelled.")
        return

    for source, target in plan:
        if not (source / ".biosphir").is_file() or os.path.lexists(target):
            fail(f"Source marker or destination changed: {source} -> {target}")
        try:
            source.rename(target)
        except OSError as exc:
            fail(f"Could not move {source} to {target}: {exc}")
        typer.echo(f"Moved {target}")


@app.command("--fix", context_settings={"help_option_names": ["--help"]})
def fix(
    marker: Annotated[str, typer.Argument(help="Marker filename (.biosphir).")],
    folder: Annotated[Path, typer.Argument(help="Target folder. Defaults to the current folder.")] = Path("."),
) -> None:
    """Repair an existing .biosphir marker."""
    target = marker_path(marker, folder)
    if not target.is_file():
        fail(f"Marker file not found: {target}. Use biosphir --plant .biosphir to create it.")
    if target.is_symlink():
        fail(f"Cannot repair a symbolic link: {target}")

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
        write_marker(target, metadata)
    except OSError as exc:
        fail(f"Could not repair marker {target}: {exc}")
    console.print(Text(f"Repaired {target}"))


@app.command("--check", context_settings={"help_option_names": ["--help"]})
def check(
    marker: Annotated[str, typer.Argument(help="Marker filename (.biosphir).")],
    folder: Annotated[Path, typer.Argument(help="Target folder. Defaults to the current folder.")] = Path("."),
) -> None:
    """Check whether a folder contains a .biosphir file."""
    target = marker_path(marker, folder)
    if not target.is_file():
        fail(f"Marker file not found: {target}")
    console.print(Text(f"Found {target}"))


def delete_marker(folder: Path) -> None:
    target = marker_path(".biosphir", folder)
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


@app.command("--show", context_settings={"help_option_names": ["--help"]})
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


@app.command("--discover", context_settings={"help_option_names": ["--help"]})
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


@app.command("--doctor", context_settings={"help_option_names": ["--help"]})
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


@app.command("--info", context_settings={"help_option_names": ["--help"]})
def info() -> None:
    """Show the CLI version and configuration paths."""
    console.print(Text(f"BIOSPHIR CLI v{version('biosphir-cli')}"))
    console.print(Text(f"Workspace: {workspace_path()}"))
    console.print(Text(f"Registry: {registry_path()}"))
