"""Save the workspace selected by the user."""

import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile


def workspace_config_path() -> Path:
    base = os.environ.get("LOCALAPPDATA" if os.name == "nt" else "XDG_CONFIG_HOME")
    return Path(base or Path.home() / ".config") / "bicdop" / "workspace.json"


def save_workspace(path: Path, name: str | None) -> tuple[Path, str]:
    folder = path.expanduser().resolve()
    if not folder.is_dir():
        raise ValueError(f"Workspace must be an existing directory: {folder}")
    label = name if name is not None else "-".join((folder.name or folder.anchor).split())
    if not label:
        raise ValueError("Workspace name cannot be blank.")
    if any(character.isspace() for character in label):
        raise ValueError("Workspace name cannot contain whitespace. Use underscores or hyphens.")

    config = workspace_config_path()
    entries = read_workspaces(config)
    plant_marker(folder)
    entries[label] = str(folder)
    write_workspace(config, entries, folder, label)
    return folder, label


def plant_marker(folder: Path) -> bool:
    marker = folder / ".bicdop"
    try:
        with marker.open("x", encoding="utf-8"):
            pass
    except FileExistsError:
        if not marker.is_file():
            raise ValueError(f"Marker path is not a file: {marker}") from None
        return False
    return True


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
        created = plant_marker(directory)
        print(f"{'Created' if created else 'Already exists'}: {directory / '.bicdop'}")


def select_workspace(name: str) -> Path:
    config = workspace_config_path()
    entries = read_workspaces(config)
    folder = workspace_folder(entries, name)
    write_workspace(config, entries, folder, name)
    return folder


def workspace_folder(entries: dict[str, str], name: str) -> Path:
    if name not in entries:
        raise ValueError(f"Unknown workspace: {name}. Save it with --set-workspace first.")
    folder = Path(entries[name])
    if not folder.is_dir():
        raise ValueError(f"Workspace folder no longer exists: {folder}")
    return folder


def list_workspace_folders() -> list[tuple[str, bool]]:
    config = workspace_config_path()
    try:
        saved = json.loads(config.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ValueError("No active workspace. Use --set-workspace first.") from None
    if not isinstance(saved, dict) or not isinstance(saved.get("path"), str) or not saved["path"]:
        raise ValueError("Invalid active workspace configuration.")
    folder = Path(saved["path"])
    if not folder.is_dir():
        raise ValueError(f"Workspace folder no longer exists: {folder}")
    return sorted(
        ((child.name, (child / ".bicdop").is_file()) for child in folder.iterdir() if child.is_dir()),
        key=lambda item: item[0].casefold(),
    )


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
