"""Prepare, diagnose, and run Python projects."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

from .folders import confirm
from .markers import MARKER, read_main_file


def python_for(folder: Path) -> Path:
    environment = folder / ".venv"
    executable = environment / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    if os.path.lexists(environment):
        if not (environment / "pyvenv.cfg").is_file() or not executable.is_file():
            raise ValueError(f"Incomplete virtual environment: {environment}. Repair it or move it aside, then run --setup.")
        return executable
    return Path(sys.executable)


def doctor(folder: Path) -> bool:
    ready = True
    print(f"Project: {folder}")
    try:
        main = read_main_file(folder)
    except (OSError, ValueError) as exc:
        print(f"Marker/main file: FAIL ({exc})")
        print("Check .bicdop and use --set-main FILE from the project directory.")
        ready = False
    else:
        print(f"Marker/main file: OK ({main})")
    try:
        python = python_for(folder)
        check = subprocess.run([str(python), "--version"], cwd=folder, capture_output=True, text=True, timeout=10)
        if check.returncode:
            raise ValueError(f"Python exited with code {check.returncode}: {python}")
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print(f"Python: FAIL ({exc})")
        ready = False
    else:
        print(f"Python: OK ({(check.stdout or check.stderr).strip()}, {python})")
        if python == Path(sys.executable):
            print("Using Bicdop's Python. Use --setup to create a project environment.")
    return ready


def setup(folder: Path) -> None:
    marker = folder / MARKER
    if marker.is_symlink() or not marker.is_file():
        raise ValueError("Mark the project with --plant before running setup.")
    environment = folder / ".venv"
    requirements = folder / "requirements.txt"
    if requirements.exists() and (not requirements.is_file() or not requirements.resolve().is_relative_to(folder)):
        raise ValueError("requirements.txt must be a file inside the project.")
    if not os.path.lexists(environment):
        subprocess.run([sys.executable, "-m", "venv", str(environment)], cwd=folder, check=True)
    python = python_for(folder)
    print(f"Project Python: {python}", flush=True)
    if requirements.is_file() and confirm(f"Install dependencies from {requirements}?"):
        subprocess.run([str(python), "-m", "pip", "install", "-r", str(requirements)], cwd=folder, check=True)
        print("Project dependencies installed.")
    elif not requirements.is_file():
        print("No requirements.txt found.")
    

def project_status(folder: Path) -> None:
    print(f"Project: {folder}")
    try:
        main = read_main_file(folder)
    except (OSError, ValueError) as exc:
        print(f"Main file: unavailable ({exc})")
    else:
        print(f"Main file: {main}")
    try:
        python = python_for(folder)
    except ValueError as exc:
        print(f"Python environment: incomplete ({exc})")
    else:
        print(f"Python environment: {'project .venv' if python != Path(sys.executable) else 'Bicdop Python'} ({python})")

    try:
        lines = git_status_lines(folder)
    except ValueError as exc:
        print(f"Git: unavailable ({exc})")
        return
    branch, *changes = lines or ["## unknown"]
    print(f"Git branch: {branch.removeprefix('## ')}")
    print(f"Git changes: {len(changes)}" if changes else "Git changes: clean")


def git_status_lines(folder: Path) -> list[str]:
    git = shutil.which("git")
    if git is None:
        raise ValueError("Git is not on PATH.")
    result = subprocess.run(
        [git, "status", "--porcelain=v1", "--branch", "--ahead-behind", "--untracked-files=all"],
        cwd=folder, capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or "git status failed")
    return result.stdout.splitlines()


def git_status(folder: Path) -> None:
    lines = git_status_lines(folder)
    for line in lines:
        print(line)
    if len(lines) <= 1:
        print("Working tree is clean.")


def build_project(folder: Path) -> int:
    config = folder / "pyproject.toml"
    if not config.is_file():
        raise ValueError("No pyproject.toml found. Add a Python build configuration before running --build.")
    python = python_for(folder)
    check = subprocess.run(
        [str(python), "-c", "import importlib.util, sys; sys.exit(importlib.util.find_spec('build') is None)"],
        cwd=python.parent, check=False,
    )
    if check.returncode:
        raise ValueError(f'Install the build module first: "{python}" -m pip install build')
    print(f"Building with {python}", flush=True)
    status = subprocess.run([str(python), "-m", "build"], cwd=folder, check=False).returncode
    if status == 0:
        print(f"Build output: {folder / 'dist'}")
    return status


def run_tests(folder: Path, arguments: list[str]) -> int:
    marker = folder / MARKER
    if marker.is_symlink() or not marker.is_file():
        raise ValueError("Mark the project with --plant before running tests.")
    python = python_for(folder)
    print(f"Running pytest with {python}", flush=True)
    return subprocess.run([str(python), "-m", "pytest", *arguments], cwd=folder, check=False).returncode
