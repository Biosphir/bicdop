"""Install newer stable releases from the official Bicdop repository."""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from tempfile import mkdtemp
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import typer

REPOSITORY = "https://github.com/Biosphir/bicdop"
RELEASE_API = "https://api.github.com/repos/Biosphir/bicdop/releases/latest"


def stable_version(tag: str) -> tuple[int, ...]:
    match = re.fullmatch(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)
    if match is None:
        raise ValueError(f"Expected a stable version such as v0.2.0, got {tag!r}.")
    return tuple(map(int, match.groups()))


def latest_release() -> dict | None:
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
    return release


def latest_tag() -> str | None:
    release = latest_release()
    return release["tag_name"] if release else None


def install_windows_update(release: dict) -> None:
    tag = release["tag_name"]
    filename = "BicdopSetup-x64.exe"
    expected_url = f"{REPOSITORY}/releases/download/{tag}/{filename}"
    for asset in release.get("assets", []):
        if asset.get("name") == filename and asset.get("browser_download_url") == expected_url:
            break
    else:
        raise ValueError(f"Release {tag} has no {filename}.")
    digest = asset.get("digest") or ""
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
        raise ValueError("GitHub did not provide a valid SHA-256 digest for the installer.")
    size = asset.get("size")
    if type(size) is not int or not 0 < size <= 200 * 1024 * 1024:
        raise ValueError("Unexpected installer size.")

    directory = Path(mkdtemp(prefix="bicdop-update-"))
    installer = directory / filename
    try:
        checksum = hashlib.sha256()
        received = 0
        with urlopen(expected_url, timeout=30) as response, installer.open("xb") as stream:
            while chunk := response.read(1024 * 1024):
                received += len(chunk)
                if received > size:
                    raise ValueError("Installer download exceeds the release asset size.")
                checksum.update(chunk)
                stream.write(chunk)
        if received != size or f"sha256:{checksum.hexdigest()}" != digest:
            raise ValueError("Installer download failed SHA-256 verification.")
        subprocess.Popen([str(installer)])
    except BaseException:
        installer.unlink(missing_ok=True)
        directory.rmdir()
        raise
    typer.echo("Verified update downloaded. Complete the Bicdop Setup window.")


def update_cli(installed: str) -> None:
    frozen = getattr(sys, "frozen", False)
    release = latest_release() if frozen else None
    tag = (release["tag_name"] if release else None) if frozen else latest_tag()
    if tag is None:
        typer.echo("No stable Bicdop release has been published on GitHub.")
        return
    if stable_version(tag) <= stable_version(installed):
        typer.echo(f"Bicdop {installed} is up to date.")
        return

    if frozen:
        install_windows_update(release)
        return

    source = f"{REPOSITORY}/archive/refs/tags/{tag}.zip"
    if (Path(sys.prefix) / "uv-receipt.toml").is_file():
        uv = shutil.which("uv")
        if uv is None:
            raise RuntimeError("uv is required to update this installation.")
        command = [uv, "tool", "install", "--force", source]
    else:
        command = [sys.executable, "-m", "pip", "install", "--upgrade", source]

    typer.echo(f"Updating Bicdop {installed} to {tag}...")
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
        sys.exit("Update timed out waiting for Bicdop to close.")
elif ctypes.get_last_error() != 87:
    raise ctypes.WinError(ctypes.get_last_error())
sys.exit(subprocess.call(sys.argv[2:]))
"""
        base_python = getattr(sys, "_base_executable", None) or sys.executable
        subprocess.Popen(
            [base_python, "-c", helper, str(os.getpid()), *command],
            stdin=subprocess.DEVNULL,
        )
        typer.echo("Update started. Wait for the installer output before reopening Bicdop.")
    elif subprocess.run(command, check=False).returncode:
        raise RuntimeError("The installer exited with an error.")
