"""Read and write Bicdop folder markers."""

import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile

MARKER = ".bicdop"



def write_marker(folder: Path, actual_folder: Path, *, main_file: str | None = None) -> bool:
    marker = folder / MARKER
    if marker.is_symlink() or (marker.exists() and not marker.is_file()):
        raise ValueError(f"Marker path must be a regular file: {marker}")
    try:
        original = marker.read_text(encoding="utf-8-sig")
    except FileNotFoundError:
        original = None
    try:
        data = json.loads(original) if original and original.strip() else {}
    except ValueError:
        if main_file is not None:
            raise ValueError(f"Invalid JSON in {marker}.") from None
        return False
    if not isinstance(data, dict):
        if main_file is not None:
            raise ValueError(f"Expected a JSON object in {marker}.")
        return False
    if main_file is not None:
        data_to_save = project_script(folder, main_file).relative_to(folder).as_posix()
    elif "main_file" in data:
        data_to_save = data["main_file"]
    else:
        default = folder / "main.py"
        data_to_save = "main.py" if default.is_file() and default.resolve().is_relative_to(folder) else None
    name = actual_folder.name or actual_folder.anchor
    updated = {
        **{key: value for key, value in data.items() if key != "folder_id"},
        "folder_name": name,
        "folder_path": str(actual_folder),
        "main_file": data_to_save,
    }
    if updated == data:
        return False
    staged = None
    try:
        with NamedTemporaryFile(dir=folder, mode="w", encoding="utf-8", delete=False) as stream:
            staged = Path(stream.name)
            json.dump(updated, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        if original is None:
            if os.name == "nt":
                staged.rename(marker)
            else:
                os.link(staged, marker)
        else:
            if marker.is_symlink() or marker.read_text(encoding="utf-8-sig") != original:
                raise ValueError(f"Marker changed while being updated: {marker}")
            staged.replace(marker)
    finally:
        if staged is not None:
            staged.unlink(missing_ok=True)
    return True


def project_script(folder: Path, configured: str) -> Path:
    relative = Path(configured)
    if relative.anchor:
        raise ValueError("The main file must be relative to the project folder.")
    script = (folder / relative).resolve()
    if not script.is_relative_to(folder) or script.suffix.lower() != ".py" or not script.is_file():
        raise ValueError(f"Expected a Python file inside the project folder: {configured}")
    return script


def read_main_file(folder: Path) -> Path:
    marker = folder / MARKER
    if marker.is_symlink() or not marker.is_file():
        raise ValueError(f"Project has no regular {MARKER} file: {folder}")
    original = marker.read_text(encoding="utf-8-sig")
    try:
        data = json.loads(original) if original.strip() else {}
    except ValueError:
        raise ValueError(f"Invalid JSON in {marker}.") from None
    if not isinstance(data, dict):
        raise ValueError(f"Expected a JSON object in {marker}.")
    configured = data.get("main_file", "main.py")
    if not isinstance(configured, str) or not configured:
        raise ValueError("No main file configured. Enter the project and use --set-main FILE.")
    return project_script(folder, configured)


def refresh_markers(root: Path, destination: Path) -> None:
    for directory, children, files in os.walk(root):
        folder = Path(directory)
        children[:] = [
            name for name in children
            if not (folder / name).is_symlink() and (folder / name).resolve() == folder / name
        ]
        if MARKER in files and not (folder / MARKER).is_symlink():
            write_marker(folder, destination / folder.relative_to(root))
