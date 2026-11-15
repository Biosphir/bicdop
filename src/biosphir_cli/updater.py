"""Update pip installations from stable GitHub releases."""

import json
import os
import re
import site
import subprocess
import sys
from importlib.metadata import distribution
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

REPOSITORY = "https://github.com/Biosphir/bicdop"
RELEASE_API = "https://api.github.com/repos/Biosphir/bicdop/releases/latest"

WINDOWS_INSTALLER_HELPER = """
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
        sys.exit("Update timed out waiting for Bicdop to close.")
elif ctypes.get_last_error() != 87:
    raise ctypes.WinError(ctypes.get_last_error())
sys.exit(subprocess.call(sys.argv[2:]))
"""


def stable_version(tag: str) -> tuple[int, ...]:
    match = re.fullmatch(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)
    if not match:
        raise ValueError(f"Invalid stable version: {tag!r}")
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
        raise ValueError("GitHub returned invalid release metadata.")
    if release.get("draft") or release.get("prerelease"):
        return None
    return release["tag_name"]


def update() -> None:
    installed = distribution("bicdop")
    tag = latest_tag()
    if tag is None:
        print("No stable Bicdop release is available.")
        return
    if stable_version(tag) <= stable_version(installed.version):
        print(f"Bicdop {installed.version} is up to date.")
        return

    command = [sys.executable, "-m", "pip", "install", "--upgrade"]
    if Path(installed.locate_file("")).resolve().is_relative_to(Path(site.getusersitepackages()).resolve()):
        command.append("--user")
    command.append(f"bicdop @ {REPOSITORY}/archive/refs/tags/{tag}.zip")
    if os.name == "nt":
        subprocess.Popen([sys.executable, "-c", WINDOWS_INSTALLER_HELPER, str(os.getpid()), *command])
        print(f"Update to {tag} started. Wait for pip to finish before reopening Bicdop.")
    else:
        subprocess.run(command, check=True)
