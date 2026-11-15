"""Read and write Bicdop folder markers."""

import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile

MARKER = ".bicdop"



def write_marker(folder: Path, actual_folder: Path) -> bool:
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
        return False
    if not isinstance(data, dict):
        return False
    name = actual_folder.name or actual_folder.anchor
    updated = {
        **{key: value for key, value in data.items() if key != "folder_id"},
        "folder_name": name,
        "folder_path": str(actual_folder),
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


def refresh_markers(root: Path, destination: Path) -> None:
    for directory, children, files in os.walk(root):
        folder = Path(directory)
        children[:] = [
            name for name in children
            if not (folder / name).is_symlink() and (folder / name).resolve() == folder / name
        ]
        if MARKER in files and not (folder / MARKER).is_symlink():
            write_marker(folder, destination / folder.relative_to(root))
