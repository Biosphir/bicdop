"""Local project registration, configuration and explicit task execution."""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from tempfile import NamedTemporaryFile

import typer

if sys.version_info >= (3, 11):
    import tomllib
else:
    import tomli as tomllib

project_app = typer.Typer(help="Register and unregister local projects.")
CONFIG = "bicdop.toml"
TOOLS = {"python": "--version", "git": "--version", "node": "--version"}


def registry_file() -> Path:
    base = os.environ.get("LOCALAPPDATA" if os.name == "nt" else "XDG_CONFIG_HOME")
    return Path(base or Path.home() / ".config") / "bicdop" / "projects.json"


def read_registry() -> dict[str, str]:
    try:
        data = json.loads(registry_file().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    if not isinstance(data, dict) or any(not isinstance(path, str) for path in data.values()):
        raise ValueError("Invalid Bicdop project registry.")
    return data


def write_registry(entries: dict[str, str]) -> None:
    path = registry_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
    try:
        temporary.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def error(exc: Exception) -> None:
    typer.echo(str(exc), err=True)
    raise typer.Exit(1)


def normalize(name: str) -> str:
    alias = name.strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", alias):
        raise ValueError("Use an alias containing letters, numbers, dots, underscores or hyphens.")
    return alias


@project_app.command("add")
def add(path: Path, name: str = typer.Option("", "--name")) -> None:
    """Register an existing directory under an optional alias."""
    try:
        path = path.expanduser().resolve(strict=True)
        if not path.is_dir():
            raise ValueError("Project path must be a directory.")
        alias = normalize(name or path.name)
        entries = read_registry()
        if alias in entries:
            raise ValueError(f"Alias already registered: {alias}")
        entries[alias] = str(path)
        write_registry(entries)
        typer.echo(f"Registered {alias}")
    except (OSError, ValueError) as exc:
        error(exc)


@project_app.command("remove")
def remove(name: str) -> None:
    """Unregister a project while keeping its files."""
    try:
        entries = read_registry()
        if entries.pop(normalize(name), None) is None:
            raise ValueError(f"Unknown project: {name}")
        write_registry(entries)
    except (OSError, ValueError) as exc:
        error(exc)


def projects() -> None:
    """List registered projects."""
    try:
        for alias, path in sorted(read_registry().items()):
            typer.echo(f"{alias}\t{path}")
    except (OSError, ValueError) as exc:
        error(exc)


def root_for(project: str) -> Path:
    if not project:
        return Path.cwd()
    path = read_registry().get(normalize(project))
    if path is None or not Path(path).is_dir():
        raise ValueError(f"Unknown or unavailable project: {project}")
    return Path(path).resolve()


def open_project(name: str) -> None:
    """Open a registered project in the desktop file manager."""
    try:
        path = root_for(name)
        if os.name == "nt":
            os.startfile(path)
        else:
            subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", str(path)])
    except (OSError, ValueError) as exc:
        error(exc)


def init(yes: bool = typer.Option(False, "--yes")) -> None:
    """Create a project configuration in the current directory."""
    try:
        if not yes and (not sys.stdin.isatty() or not typer.confirm(f"Create {CONFIG}?")):
            raise ValueError("Pass --yes to explicitly initialize the current directory.")
        with Path(CONFIG).open("x", encoding="utf-8") as stream:
            stream.write('version = 1\n\n[environment]\n\n[tasks]\n')
    except FileExistsError:
        error(ValueError(f"{CONFIG} already exists."))
    except (OSError, ValueError) as exc:
        error(exc)


def load_config(root: Path) -> dict:
    with (root / CONFIG).open("rb") as stream:
        try:
            config = tomllib.load(stream)
        except tomllib.TOMLDecodeError:
            raise ValueError(f"Invalid TOML syntax in {CONFIG}.") from None
    if type(config.get("version")) is not int or config["version"] != 1:
        raise ValueError(f"{CONFIG} requires version = 1.")
    for field in ("tasks", "environment"):
        if not isinstance(config.get(field, {}), dict):
            raise ValueError(f"{field} must be a TOML table.")
    for tool, required in config.get("environment", {}).items():
        if tool not in TOOLS or not isinstance(required, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", required):
            raise ValueError("Declare python, git or node versions as strings such as '3.12'.")
    return config


def run_task(task: str, project: str = "", dry_run: bool = False, yes: bool = False) -> None:
    try:
        root = root_for(project)
        definition = load_config(root).get("tasks", {}).get(task)
        if isinstance(definition, list):
            definition = {"args": definition}
        if not isinstance(definition, dict):
            raise ValueError(f"Task {task!r} is missing or invalid in {CONFIG}.")
        if definition.keys() - {"args", "cwd", "pass_env", "timeout"}:
            raise ValueError("Task has unsupported fields.")
        args = definition.get("args")
        cwd = definition.get("cwd", ".")
        keys = definition.get("pass_env", [])
        timeout = definition.get("timeout")
        if not isinstance(args, list) or not args or not all(isinstance(arg, str) and "\0" not in arg for arg in args) or not args[0]:
            raise ValueError("Task args must be a nonempty array of strings.")
        if not isinstance(cwd, str) or not isinstance(keys, list) or not all(isinstance(key, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) for key in keys):
            raise ValueError("Task cwd must be a string and pass_env must contain environment variable names.")
        if timeout is not None and (type(timeout) is not int or timeout <= 0):
            raise ValueError("Task timeout must be a positive integer in seconds.")
        directory = (root / cwd).resolve()
        if not directory.is_relative_to(root) or not directory.is_dir():
            raise ValueError("Task cwd must be an existing directory inside the project.")
        # Arguments can contain credentials. Display only the executable and argument count.
        typer.echo(json.dumps({"task": task, "cwd": str(directory), "executable": Path(args[0]).name, "argument_count": len(args) - 1}, ensure_ascii=True))
        if dry_run:
            return
        if not yes and (not sys.stdin.isatty() or not typer.confirm(f"Run this task from the reviewed {CONFIG}?")):
            raise ValueError("Review the project configuration and pass --yes to authorize this task.")
        executable = shutil.which(args[0])
        if executable is None or (os.name == "nt" and Path(executable).suffix.lower() in {".bat", ".cmd"}):
            raise ValueError("Task requires an available executable. Windows batch shims are unsupported.")
        allowed = {"PATH", "SYSTEMROOT", "WINDIR", "TEMP", "TMP", "HOME", "USERPROFILE", *keys}
        environment = {key: os.environ[key] for key in allowed if key in os.environ}
        result = subprocess.run([executable, *args[1:]], cwd=directory, env=environment, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        error(ValueError("Task timed out."))
    except KeyboardInterrupt:
        raise typer.Exit(130) from None
    except OSError:
        error(ValueError("Could not read the project configuration or start the task."))
    except ValueError as exc:
        error(exc)
    raise typer.Exit(result.returncode)


def diagnostics(project: str, as_json: bool) -> None:
    try:
        root = root_for(project)
        requirements = load_config(root).get("environment", {})
        checks = []
        for tool, required in requirements.items():
            executable = shutil.which(tool)
            installed = None
            # Windows may search the working directory before PATH.
            if executable and Path(executable).resolve().is_relative_to(root):
                executable = None
            if executable and Path(executable).suffix.lower() not in {".bat", ".cmd"}:
                try:
                    result = subprocess.run([executable, TOOLS[tool]], capture_output=True, text=True, timeout=5)
                    match = re.search(r"[0-9]+(?:\.[0-9]+)+", result.stdout) if result.returncode == 0 else None
                    installed = match.group() if match else None
                except (OSError, subprocess.TimeoutExpired):
                    pass
            ready = bool(installed and installed.split(".")[:len(required.split("."))] == required.split("."))
            checks.append({"tool": tool, "required": required, "installed": installed, "ready": ready,
                           "remediation": None if ready else f"Install {tool} {required} and select it on PATH."})
        if as_json:
            typer.echo(json.dumps(checks))
        else:
            for check in checks:
                typer.echo(f"{check['tool']}: {check['installed'] or 'unavailable'} (required {check['required']})")
                if check["remediation"]:
                    typer.echo(check["remediation"])
            if not checks:
                typer.echo("No runtime requirements configured.")
        if any(not check["ready"] for check in checks):
            raise typer.Exit(1)
    except (OSError, ValueError) as exc:
        error(exc)
