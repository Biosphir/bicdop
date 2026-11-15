"""Connect Bicdop's current Git checkout to a GitHub repository."""

import json
import os
import re
import shlex
import shutil
import subprocess
from pathlib import Path
from tempfile import NamedTemporaryFile

from .folders import confirm, folder_names
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


def read_repositories() -> dict[Path, str]:
    try:
        data = json.loads(repository_config().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    if not isinstance(data, dict):
        raise ValueError("Invalid GitHub configuration. Set the repository again.")
    entries = data.get("repositories")
    if entries is None:
        old_path = data.get("checkout")
        if not isinstance(old_path, str):
            raise ValueError("Invalid saved Git checkout path.")
        entries = {old_path: data.get("url")}
    if not isinstance(entries, dict):
        raise ValueError("Invalid saved GitHub repositories.")
    repositories = {}
    for path, url in entries.items():
        checkout_path = Path(path)
        if not checkout_path.is_absolute() or not isinstance(url, str):
            raise ValueError("Invalid saved GitHub repository.")
        repositories[checkout_path.resolve()] = repository_url(url)[0]
    return repositories


def active_repository() -> tuple[str, Path] | None:
    repositories = read_repositories()
    if not repositories:
        return None
    current = Path.cwd().resolve()
    for directory in (current, *current.parents):
        if (directory / ".git").exists():
            url = repositories.get(directory)
            return (url, directory) if url else None
    return None


def save_repository(url: str, path: Path) -> None:
    repositories = read_repositories()
    repositories[path.resolve()] = repository_url(url)[0]
    config = repository_config()
    config.parent.mkdir(parents=True, exist_ok=True)
    staged = None
    try:
        with NamedTemporaryFile(dir=config.parent, delete=False, mode="w", encoding="utf-8") as stream:
            staged = Path(stream.name)
            json.dump({"repositories": {str(folder): remote for folder, remote in repositories.items()}}, stream, indent=2)
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
    git = executable("git")
    folder = checkout(git)
    url = read_repositories().get(folder)
    if url is None:
        raise ValueError('No GitHub connection for this checkout. Run --set-github "https://github.com/OWNER/REPO" here.')
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



def show_diff(staged: bool) -> None:
    git = executable("git")
    checkout(git)
    args = ["--no-pager", "diff", "--no-ext-diff", "--no-textconv"]
    if staged:
        args.append("--cached")
    result = subprocess.run(
        [git, *args], capture_output=True, text=True,
        encoding="utf-8", errors="replace", check=False,
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or "Could not show Git diff.")
    if result.stdout:
        print(result.stdout, end="")
    else:
        print("No staged changes." if staged else "No unstaged changes to tracked files.")


def stage_files(arguments: list[str]) -> None:
    git = executable("git")
    checkout(git)
    names = folder_names(arguments)
    if any(Path(name).is_dir() for name in names):
        raise ValueError("Select individual files to stage.")
    subprocess.run([git, "--literal-pathspecs", "add", "--", *names], check=True)
    print(f"Staged {len(names)} file selection(s).")


def commit_staged(message: str) -> None:
    if not message.strip():
        raise ValueError("Commit message cannot be blank.")
    git = executable("git")
    root = checkout(git)
    staged = git_output(git, "diff", "--cached", "--name-status", "--no-ext-diff", cwd=root)
    if not staged:
        raise ValueError("No staged changes. Use --stage to select files first.")
    index_tree = git_output(git, "write-tree", cwd=root)
    print(f"Staged changes:\n{staged}", flush=True)
    if confirm("Commit these staged changes?"):
        # Commit the same index that was displayed, or stop if it changed.
        if git_output(git, "write-tree", cwd=root) != index_tree:
            raise ValueError("The staged changes differ from the preview. Review it and try again.")
        subprocess.run([git, "commit", "-m", message], cwd=root, check=True)
