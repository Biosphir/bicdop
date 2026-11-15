"""Connect Bicdop's current Git checkout to a GitHub repository."""

import json
import os
import re
import shlex
import shutil
import subprocess
from pathlib import Path
from tempfile import NamedTemporaryFile

from .workspace import workspace_config_path

REPOSITORY = re.compile(r"https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9_.-]+)/?", re.IGNORECASE)


def repository_url(value: str) -> tuple[str, str]:
    match = REPOSITORY.fullmatch(value)
    if not match:
        raise ValueError("Use an HTTPS repository URL such as https://github.com/OWNER/REPO.")
    owner, repo = match.groups()
    repo = repo.removesuffix(".git")
    if repo in {"", ".", ".."}:
        raise ValueError("Enter a GitHub repository name.")
    slug = f"{owner}/{repo}"
    return f"https://github.com/{slug}.git", slug


def repository_config() -> Path:
    return workspace_config_path().with_name("github.json")


def active_repository() -> tuple[str, Path] | None:
    try:
        entry = json.loads(repository_config().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    if not isinstance(entry, dict) or not all(isinstance(entry.get(key), str) for key in ("url", "checkout")):
        raise ValueError("Invalid GitHub configuration. Set the repository again.")
    path = Path(entry["checkout"])
    if not path.is_absolute():
        raise ValueError("Invalid saved Git checkout path.")
    return repository_url(entry["url"])[0], path


def save_repository(url: str, path: Path) -> None:
    config = repository_config()
    config.parent.mkdir(parents=True, exist_ok=True)
    staged = None
    try:
        with NamedTemporaryFile(dir=config.parent, delete=False, mode="w", encoding="utf-8") as stream:
            staged = Path(stream.name)
            json.dump({"url": url, "checkout": str(path)}, stream, indent=2)
            stream.write("\n")
        staged.replace(config)
    finally:
        if staged is not None:
            staged.unlink(missing_ok=True)


def executable(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise ValueError(f"Install {name} and make it available on PATH.")
    return str(Path(path).resolve())


def git_output(git: str, *args: str, cwd: Path | None = None) -> str:
    result = subprocess.run(
        [git, *args], cwd=cwd, capture_output=True, text=True,
        encoding="utf-8", errors="replace", check=False,
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"Git command failed: {args[0]}")
    return result.stdout.strip()


def checkout(git: str) -> Path:
    try:
        value = git_output(git, "rev-parse", "--show-toplevel")
    except ValueError:
        raise ValueError("Open a local Git working tree first. Clone the repository if needed.") from None
    return Path(value).resolve()


def authenticate(gh: str) -> None:
    status = subprocess.run(
        [gh, "auth", "status", "--hostname", "github.com"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if status.returncode:
        print("Complete GitHub sign-in in the browser opened by GitHub CLI.", flush=True)
        subprocess.run([gh, "auth", "login", "--hostname", "github.com", "--web", "--git-protocol", "https"], check=True)


def connect_repository(value: str | None) -> None:
    if value is None:
        authenticate(executable("gh"))
        print('GitHub login is ready. In a local Git checkout, run --set-github "https://github.com/OWNER/REPO".')
        return
    url, slug = repository_url(value)
    folder = checkout(executable("git"))
    gh = executable("gh")
    authenticate(gh)
    access = subprocess.run(
        [gh, "repo", "view", slug, "--json", "nameWithOwner"],
        cwd=folder, stdout=subprocess.DEVNULL, check=False,
    )
    if access.returncode:
        raise ValueError("GitHub CLI could not access that repository. Check the URL and signed-in account.")
    save_repository(url, folder)
    print(f"Active GitHub repo: {slug}\nLocal checkout: {folder}")


def transfer(operation: str) -> None:
    selected = active_repository()
    if selected is None:
        raise ValueError('Set a repository first with --set-github "https://github.com/OWNER/REPO".')
    url, folder = selected
    git = executable("git")
    if checkout(git) != folder:
        raise ValueError(f"Run this command from the connected checkout: {folder}")
    gh = executable("gh")
    authenticate(gh)
    try:
        ref = git_output(git, "symbolic-ref", "--quiet", "HEAD", cwd=folder)
    except ValueError:
        raise ValueError("Switch to a local branch before pushing or pulling.") from None
    if not ref.startswith("refs/heads/"):
        raise ValueError("Switch to a local branch before pushing or pulling.")
    branch = ref.removeprefix("refs/heads/")
    if operation == "pull" and git_output(git, "status", "--porcelain", "--untracked-files=normal", cwd=folder):
        raise ValueError("Commit or stash local changes before pulling.")

    config = [
        "-c", "credential.helper=",
        "-c", f"credential.https://github.com.helper=!{shlex.quote(Path(gh).as_posix())} auth git-credential",
        "-c", "http.followRedirects=false",
    ]
    if git_output(git, "ls-remote", "--get-url", url, cwd=folder) != url:
        raise ValueError("Git configuration rewrites the selected GitHub URL. Check url.insteadOf settings.")
    options = (
        ["--no-follow-tags", "--no-recurse-submodules", url, f"{ref}:{ref}"]
        if operation == "push"
        else ["--ff-only", "--no-rebase", "--no-tags", "--no-recurse-submodules", url, ref]
    )
    print(f"Git {operation}: {url} ({branch})", flush=True)
    subprocess.run([git, *config, operation, *options], cwd=folder, check=True)
