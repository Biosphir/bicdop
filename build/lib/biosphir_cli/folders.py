"""Filesystem operations rooted in the current Bicdop session."""

import os
import shutil
from pathlib import Path
from tempfile import TemporaryDirectory

from .markers import refresh_markers
from .workspace import active_workspace, find_marked_folders


def child_path(folder: Path, name: str) -> Path:
    part = Path(name)
    if not name.strip() or part.name != name or name in {".", ".."} or "/" in name or "\\" in name:
        raise ValueError("Specify a single folder name.")
    return folder / name


def is_folder_path(value: str) -> bool:
    return value in {".", "..", "~"} or "/" in value or "\\" in value or bool(Path(value).drive)


def folder_names(arguments: list[str]) -> list[str]:
    names = arguments[::2]
    if (
        len(arguments) % 2 != 1
        or any(token != "," for token in arguments[1::2])
        or any(not name.strip() or name == "," for name in names)
    ):
        raise ValueError("Separate folder names or paths with commas.")
    return names


def resolve_folder(value: str, candidates: list[Path] | None = None) -> Path:
    if is_folder_path(value):
        folder = Path(value).expanduser().resolve()
    elif candidates is None:
        folder = child_path(Path.cwd(), value)
    else:
        matches = [path for path in candidates if path.name.casefold() == value.casefold()]
        if len(matches) != 1:
            detail = "Ambiguous" if matches else "Unknown"
            raise ValueError(f"{detail} folder: {value}. Use its full path if the name is ambiguous.")
        folder = matches[0]
    if not folder.is_dir():
        raise ValueError(f"Folder does not exist: {folder}")
    return folder


def one_folder(arguments: list[str]) -> Path:
    if len(arguments) != 1:
        raise ValueError("Specify exactly one folder name or path.")
    return resolve_folder(arguments[0])


def direct_child(folder: Path) -> str:
    if folder.parent != Path.cwd().resolve():
        raise ValueError(f"Expected a direct child of the current folder: {folder}")
    return folder.name


def change_folder(target: Path) -> None:
    os.chdir(target)
    print(Path.cwd())


def make_folder(name: str) -> None:
    target = child_path(Path.cwd(), name)
    target.mkdir()
    print(f"Created: {target}")


def existing_folder(name: str) -> tuple[Path, bool]:
    current = Path.cwd().resolve()
    active = name == "."
    target = current if active else child_path(current, name)
    if not target.is_dir() or target.is_symlink() or target.resolve() != target:
        raise ValueError(f"Expected a local folder without a redirected path: {target}")
    if active and target in {target.parent, Path.home().resolve()}:
        raise ValueError(f"Cannot modify a drive root or the home folder: {target}")
    return target, active


def rename_folder(name: str, new_name: str) -> None:
    source, active = existing_folder(name)
    destination = child_path(source.parent, new_name)
    if os.path.lexists(destination):
        raise FileExistsError(f"Destination already exists: {destination}")
    if active:
        os.chdir(source.parent)
    try:
        source.rename(destination)
    except OSError:
        if active and source.is_dir():
            os.chdir(source)
        raise
    if active:
        os.chdir(destination)
    refresh_markers(destination, destination)
    print(f"Renamed: {destination}")


def confirm(message: str) -> bool:
    try:
        answer = input(f"{message} [y/N] ")
    except EOFError:
        answer = ""
    if answer.strip().lower() in {"y", "yes"}:
        return True
    print("Cancelled.")
    return False


def delete_folders(arguments: list[str], no_confirm: bool) -> None:
    names = [direct_child(resolve_folder(value)) for value in folder_names(arguments)] if arguments else []
    targets = dict.fromkeys(existing_folder(name) for name in (names or ["."]))
    for target, _ in targets:
        print(target)
    if not no_confirm and not confirm("Permanently delete these folders and their contents?"):
        return
    for target, active in targets:
        checked, _ = existing_folder("." if active else target.name)
        if checked != target:
            raise ValueError(f"Folder changed: {target}")
        if active:
            os.chdir(target.parent)
        try:
            shutil.rmtree(target)
        except OSError:
            if active and target.is_dir():
                os.chdir(target)
            raise
        print(f"Deleted: {target}")


def check_copy_entries(directory: str, names: list[str]) -> list[str]:
    for name in names:
        path = Path(directory) / name
        if path.is_dir() and not path.is_symlink() and path.resolve() != path:
            raise ValueError(f"Cannot copy a redirected directory: {path}")
    return []


def collect_folders(copy: bool, arguments: list[str]) -> None:
    workspace = active_workspace()
    if workspace is None or not workspace.is_dir():
        raise ValueError("Select an existing workspace first.")
    current = Path.cwd().resolve()
    protected = {Path.home().resolve(), workspace, current}
    matches = find_marked_folders()
    candidates = {
        folder for folder, outside in matches
        if outside and not any(path.is_relative_to(folder) for path in protected)
    }
    if arguments:
        sources = list(dict.fromkeys(
            resolve_folder(value, [folder for folder, _ in matches])
            for value in folder_names(arguments)
        ))
        for source in sources:
            if not (source / ".bicdop").is_file() or any(path.is_relative_to(source) for path in protected) or source.is_relative_to(workspace):
                raise ValueError(f"Folder is not collectible: {source}")
        if any(parent in sources for source in sources for parent in source.parents):
            raise ValueError("Selected folders overlap. Select the parent only.")
    else:
        sources = sorted(folder for folder in candidates if candidates.isdisjoint(folder.parents))
    if not sources:
        print("No collectible .bicdop folders found outside the workspace.")
        return

    plan = [(source, workspace / source.name) for source in sources]
    destinations = set()
    for source, destination in plan:
        key = os.path.normcase(str(destination))
        if key in destinations or os.path.lexists(destination):
            raise ValueError(f"Destination already exists or conflicts: {destination}")
        destinations.add(key)
        print(f"{source} -> {destination}")

    if not confirm("Copy these folders?" if copy else "Move these folders?"):
        return
    for source, destination in plan:
        if not workspace.is_dir() or workspace.resolve() != workspace:
            raise ValueError(f"Workspace changed: {workspace}")
        if source.resolve() != source or not (source / ".bicdop").is_file() or os.path.lexists(destination):
            raise ValueError(f"Source or destination changed: {source} -> {destination}")
        if copy:
            with TemporaryDirectory(prefix=".bicdop-copy-", dir=workspace) as staged:
                payload = Path(staged) / "project"
                shutil.copytree(source, payload, symlinks=True, ignore=check_copy_entries)
                if os.path.lexists(destination):
                    raise FileExistsError(f"Destination already exists: {destination}")
                refresh_markers(payload, destination)
                payload.rename(destination)
        else:
            source.rename(destination)
            refresh_markers(destination, destination)
        print(f"{'Copied' if copy else 'Moved'}: {destination}")
