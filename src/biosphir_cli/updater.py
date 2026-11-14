"""Install newer stable releases from the official BIOSPHIR CLI repository."""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import typer

REPOSITORY = "https://github.com/Biosphir/biosphir-cli"
RELEASE_API = "https://api.github.com/repos/Biosphir/biosphir-cli/releases/latest"


def stable_version(tag: str) -> tuple[int, ...]:
    match = re.fullmatch(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)
    if match is None:
        raise ValueError(f"Expected a stable version such as v0.2.0, got {tag!r}.")
    return tuple(map(int, match.groups()))


def latest_tag() -> str | None:
    request = Request(RELEASE_API, headers={"Accept": "application/vnd.github+json"})
    try:
        with urlopen(request, timeout=15) as response:
            release = json.load(response)
    except HTTPError as exc:
        if exc.code == 404:
            return None
        raise
    if not isinstance(release, dict) or not isinstance(release.get("tag_name"), str):
        raise ValueError("GitHub returned an invalid release.")
    if release.get("draft") or release.get("prerelease"):
        return None
    return release["tag_name"]


def update_cli(installed: str) -> None:
    tag = latest_tag()
    if tag is None:
        typer.echo("No stable BIOSPHIR CLI release has been published on GitHub.")
        return
    if stable_version(tag) <= stable_version(installed):
        typer.echo(f"BIOSPHIR CLI {installed} is up to date.")
        return

    source = f"{REPOSITORY}/archive/refs/tags/{tag}.zip"
    if (Path(sys.prefix) / "uv-receipt.toml").is_file():
        uv = shutil.which("uv")
        if uv is None:
            raise RuntimeError("uv is required to update this installation.")
        command = [uv, "tool", "install", "--force", f"biosphir-cli @ {source}"]
    else:
        command = [sys.executable, "-m", "pip", "install", "--upgrade", f"biosphir-cli @ {source}"]

    typer.echo(f"Updating BIOSPHIR CLI {installed} to {tag}...")
    if os.name == "nt":
        # The helper uses base Python so the tool environment can be replaced.
        helper = """
import ctypes
import subprocess
import sys
from ctypes import wintypes

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel.CloseHandle.argtypes = [wintypes.HANDLE]
handle = kernel.OpenProcess(0x00100000, False, int(sys.argv[1]))
if handle:
    status = kernel.WaitForSingleObject(handle, 30000)
    kernel.CloseHandle(handle)
    if status != 0:
        sys.exit("Update timed out waiting for BIOSPHIR CLI to close.")
elif ctypes.get_last_error() != 87:
    raise ctypes.WinError(ctypes.get_last_error())
sys.exit(subprocess.call(sys.argv[2:]))
"""
        base_python = getattr(sys, "_base_executable", None) or sys.executable
        subprocess.Popen(
            [base_python, "-c", helper, str(os.getpid()), *command],
            stdin=subprocess.DEVNULL,
        )
        typer.echo("Update started. Wait for the installer output before reopening BIOSPHIR.")
    elif subprocess.run(command, check=False).returncode:
        raise RuntimeError("The installer exited with an error.")
