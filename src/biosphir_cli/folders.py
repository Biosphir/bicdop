"""Filesystem operations rooted in the current Bicdop session."""

import os
import shutil
from pathlib import Path


def child_path(folder: Path, name: str) -> Path:
    part = Path(name)
    if not name.strip() or part.name != name or name in {".", ".."} or "/" in name or "\\" in name:
        raise ValueError("Specify a single folder name.")
    return folder / name


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
    print(f"Renamed: {destination}")


def delete_folder(name: str, no_confirm: bool) -> None:
    target, active = existing_folder(name)
    if not no_confirm:
        try:
            answer = input(f"Permanently delete {target} and its contents? [y/N] ")
        except EOFError:
            answer = ""
        if answer.strip().lower() not in {"y", "yes"}:
            print("Cancelled.")
            return
    target, active = existing_folder(name)
    if active:
        os.chdir(target.parent)
    try:
        shutil.rmtree(target)
    except OSError:
        if active and target.is_dir():
            os.chdir(target)
        raise
    print(f"Deleted: {target}")
