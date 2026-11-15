"""Save the workspace selected by the user."""

import json
import os
import sys
from pathlib import Path
from tempfile import NamedTemporaryFile

from .markers import MARKER, write_marker


def workspace_config_path() -> Path:
    base = os.environ.get("LOCALAPPDATA" if os.name == "nt" else "XDG_CONFIG_HOME")
    return Path(base or Path.home() / ".config") / "bicdop" / "workspace.json"


def save_workspace(path: Path) -> tuple[Path, str]:
    folder = path.expanduser().resolve()
    if not folder.is_dir():
        raise ValueError(f"Workspace must be an existing directory: {folder}")
    label = "-".join((folder.name or folder.anchor).split())
    if not label:
        raise ValueError("Workspace name cannot be blank.")

    config = workspace_config_path()
    entries = read_workspaces(config)
    write_marker(folder, folder)
    entries[label] = str(folder)
    write_workspace(config, entries, folder, label)
    return folder, label


def plant_markers(target: str) -> None:
    folder = Path.cwd() if target in ("-here", "-all") else Path(target).expanduser()
    folder = folder.resolve()
    if not folder.is_dir():
        raise ValueError(f"Marker target must be an existing directory: {folder}")
    folders = [folder]
    if target == "-all":
        folders.extend(
            child for child in sorted(folder.iterdir())
            if child.is_dir() and not child.is_symlink() and child.resolve() == child
        )
    for directory in folders:
        updated = write_marker(directory, directory)
        print(f"{'Marker saved' if updated else 'Marker kept'}: {directory / MARKER}")


def select_workspace(name: str) -> Path:
    config = workspace_config_path()
    entries = read_workspaces(config)
    folder = workspace_folder(entries, name)
    write_workspace(config, entries, folder, name)
    return folder


def rename_workspace(new_name: str) -> Path:
    if not new_name or any(character.isspace() for character in new_name):
        raise ValueError("Workspace name must be nonempty and cannot contain whitespace.")
    active = active_workspace_details()
    if active is None:
        raise ValueError("No active workspace. Use --set-workspace first.")
    current_name, folder = active
    config = workspace_config_path()
    entries = read_workspaces(config)
    if current_name not in entries:
        current_name = "-".join(current_name.split())
    if current_name not in entries or Path(entries[current_name]).resolve() != folder:
        raise ValueError("Active workspace does not match its saved entry.")
    if new_name != current_name and new_name in entries:
        raise ValueError(f"Workspace name already exists: {new_name}")
    entries[new_name] = entries.pop(current_name)
    write_workspace(config, entries, folder, new_name)
    return folder


def workspace_folder(entries: dict[str, str], name: str) -> Path:
    if name not in entries:
        raise ValueError(f"Unknown workspace: {name}. Save it with --set-workspace first.")
    folder = Path(entries[name])
    if not folder.is_dir():
        raise ValueError(f"Workspace folder no longer exists: {folder}")
    return folder


def active_workspace_details() -> tuple[str, Path] | None:
    try:
        saved = json.loads(workspace_config_path().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    if not isinstance(saved, dict) or not isinstance(saved.get("path"), str) or not saved["path"]:
        raise ValueError("Invalid active workspace configuration.")
    folder = Path(saved["path"]).resolve()
    name = saved.get("name")
    return (name if isinstance(name, str) and name else folder.name or folder.anchor), folder


def active_workspace() -> Path | None:
    details = active_workspace_details()
    return details[1] if details else None


def list_workspace_folders() -> list[tuple[str, bool]]:
    folder = active_workspace()
    if folder is None:
        raise ValueError("No active workspace. Use --set-workspace first.")
    if not folder.is_dir():
        raise ValueError(f"Workspace folder no longer exists: {folder}")
    return sorted(
        ((child.name, (child / MARKER).is_file()) for child in folder.iterdir() if child.is_dir()),
        key=lambda item: item[0].casefold(),
    )


def find_marked_folders() -> list[tuple[Path, bool]]:
    workspace = active_workspace()
    roots = [Path.cwd(), *(Path.home() / name for name in ("Documents", "Desktop", "Downloads"))]
    if workspace is not None:
        roots.append(workspace)

    def report_error(exc: OSError) -> None:
        print(f"Skipped: {exc}", file=sys.stderr)

    visited: set[Path] = set()
    matches = []
    for root in roots:
        if not root.is_dir():
            continue
        for directory, children, _ in os.walk(root.resolve(), onerror=report_error):
            folder = Path(directory)
            if folder in visited:
                children.clear()
                continue
            visited.add(folder)
            children[:] = [
                child for child in children
                if child not in {".git", ".venv", "node_modules", "__pycache__"}
                and not (folder / child).is_symlink()
                and (folder / child).resolve() == folder / child
            ]
            if (folder / MARKER).is_file():
                matches.append((folder, workspace is None or not folder.is_relative_to(workspace)))
    return sorted(matches)


def read_workspaces(config: Path) -> dict[str, str]:
    try:
        saved = json.loads(config.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    if not isinstance(saved, dict):
        raise ValueError("Invalid workspace configuration.")
    if "workspaces" not in saved:
        path = saved.get("path")
        if not isinstance(path, str) or not path:
            raise ValueError("Invalid saved workspace path.")
        folder = Path(path)
        name = saved.get("name", folder.name or folder.anchor)
        if not isinstance(name, str) or not name.strip():
            raise ValueError("Invalid saved workspace name.")
        return {"-".join(name.split()): path}
    entries = saved["workspaces"]
    if not isinstance(entries, dict) or any(
        not name or not isinstance(path, str) or not path
        for name, path in entries.items()
    ):
        raise ValueError("Invalid saved workspaces.")
    return entries


def write_workspace(config: Path, entries: dict[str, str], folder: Path, label: str) -> None:
    payload = json.dumps(
        {"path": str(folder), "name": label, "workspaces": entries},
        ensure_ascii=False,
        indent=2,
    )
    config.parent.mkdir(parents=True, exist_ok=True)
    staged = None
    try:
        with NamedTemporaryFile(dir=config.parent, delete=False, mode="w", encoding="utf-8") as stream:
            staged = Path(stream.name)
            stream.write(payload + "\n")
        staged.replace(config)
    finally:
        if staged is not None:
            staged.unlink(missing_ok=True)
