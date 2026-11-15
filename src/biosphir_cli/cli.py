"""Bicdop command-line entry point."""

import sys
from argparse import ArgumentParser
from pathlib import Path
from importlib.metadata import version
from subprocess import CalledProcessError, run

from .markers import MARKER, read_main_file, write_marker
from .project import build_project, doctor, git_status, project_status, python_for, run_tests, setup
from .prompt import show_interface
from .github import active_repository, commit_staged, connect_repository, show_diff, stage_files, transfer
from .help_view import show_help
from .folders import change_folder, child_path, collect_folders, delete_folders, direct_child, is_folder_path, make_folder, one_folder, rename_folder
from .updater import update
from .workspace import active_workspace, active_workspace_details, find_marked_folders, list_folders, list_workspace_folders, plant_markers, rename_workspace, save_workspace, select_workspace


def app(prog_name: str = "bicdop") -> None:
    if len(sys.argv) != 1 or not sys.stdin.isatty():
        print(f"Open {prog_name} without arguments in a terminal to use its commands.", file=sys.stderr)
        raise SystemExit(2)
    interactive(prog_name)


def interactive(prog_name: str) -> None:
    title = f"Bicdop v{version('bicdop')} by BIOSPHIR"

    def header() -> str:
        try:
            active = active_workspace_details()
            workspace = f"{active[0]} ({active[1]})" if active else "none"
        except (OSError, ValueError):
            workspace = "unavailable"
        try:
            repository = active_repository()
            github = repository[0] if repository else "unset"
        except (OSError, ValueError):
            github = "unavailable"
        return (
            f"{title}\n"
            "You are in the Bicdop interactive interface.\n"
            f"Active workspace: {workspace}\n"
            f"Active github repo: {github}\n"
            "--help for commands | PgUp/PgDn to scroll | exit to leave"
        )

    show_interface(header, lambda arguments: run_command(prog_name, arguments))


def project_folder(value: str) -> Path:
    if not is_folder_path(value) and not child_path(Path.cwd(), value).is_dir():
        workspace = active_workspace()
        if workspace is not None:
            return child_path(workspace, value).resolve()
    return one_folder([value]).resolve()


def run_command(prog_name: str, argv: list[str]) -> bool | None:
    parser = ArgumentParser(
        prog=prog_name,
        description="Bicdop by BIOSPHIR.",
        usage="%(prog)s [command] (type --help for examples)",
        add_help=False,
    )
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("-h", "--help", action="store_true")
    actions.add_argument("--update", action="store_true", help="Install the latest stable GitHub release.")
    actions.add_argument("--set-github", nargs="?", const="", metavar="URL", help="Sign in to GitHub or connect a repository.")
    actions.add_argument("--diff", action="store_true", help="Show Git changes for tracked files.")
    parser.add_argument("--staged", action="store_true", help="Show staged changes with --diff.")
    actions.add_argument("--stage", nargs="+", metavar="FILE", help="Stage files separated by commas.")
    actions.add_argument("--commit", metavar="MESSAGE", help="Commit only staged changes.")
    actions.add_argument("--push", action="store_true", help="Push committed changes from the current branch.")
    actions.add_argument("--pull", action="store_true", help="Fast-forward the current branch from GitHub.")
    actions.add_argument("--version", action="store_true", help="Show the installed Bicdop version.")
    actions.add_argument(
        "--set-workspace", nargs="*", metavar="FOLDER",
        help="Save a workspace and create its marker. Defaults to the current folder.",
    )
    actions.add_argument("--set-name-workspace", metavar="NEW_NAME", help="Rename the active workspace.")
    actions.add_argument("--select", metavar="NAME", help="Select a saved workspace by name.")
    actions.add_argument("--find", choices=[".bicdop"], help="Find folders containing a .bicdop marker.")
    actions.add_argument("--collect", nargs="*", metavar="FOLDER", help="Move marked folders into the active workspace, optionally by folder name or path.")
    parser.add_argument("--copy", action="store_true", help="Copy folders with --collect.")
    actions.add_argument("--show", action="store_true", help="List folders in the current directory.")
    actions.add_argument("--set-main", metavar="FILE", help="Set the current project's Python main file.")
    actions.add_argument("--build", metavar="FOLDER", help="Build a Python project.")
    actions.add_argument("--git-status", nargs="?", const=".", metavar="FOLDER", help="Show Git files and local upstream status.")
    actions.add_argument("--status", metavar="FOLDER", help="Show quick project and Git status.")
    actions.add_argument("--doctor", metavar="FOLDER", help="Check a project's marker, main file and Python.")
    actions.add_argument("--setup", metavar="FOLDER", help="Prepare a project's Python environment.")
    actions.add_argument("--test", metavar="FOLDER", help="Run the project's pytest suite.")
    actions.add_argument("--info", metavar="FOLDER", help="Show a project's location, marker, main file and Python.")
    actions.add_argument("--run", metavar="FOLDER", help="Run a marked project's main file.")
    actions.add_argument("--projects", action="store_true", help="List folders in the active workspace.")
    parser.add_argument(
        "--set-name", nargs="*", metavar="NAME",
        help="Rename a folder with -to. Defaults to the current folder.",
    )
    parser.add_argument("-to", metavar="NEW_NAME", help="New folder name for --set-name.")
    parser.add_argument("--no-confirm", action="store_true", help="Skip --delete confirmation.")
    actions.add_argument("--cd", nargs="+", metavar="FOLDER", help="Change folders inside the Bicdop prompt.")
    actions.add_argument("--goto-workspace", action="store_true", help="Go to the active workspace.")
    actions.add_argument("--cd-back", action="store_true", help="Go to the parent folder inside the Bicdop prompt.")
    actions.add_argument("--mkdir", nargs="+", metavar="NAME", help="Create a folder in the current directory.")
    actions.add_argument("--delete", nargs="*", metavar="NAME", help="Delete the current folder or direct children separated by commas.")
    actions.add_argument(
        "--plant", nargs="+", metavar="FOLDER",
        help="Create .bicdop in a folder, the current folder, or the current folder and its direct children.",
    )
    # These tokens belong to folder selectors, rather than argparse options.
    escaped = {"-here", "-all"}
    prefix = "\0selector"
    test_arguments = []
    if "--" in argv:
        separator = argv.index("--")
        argv, test_arguments = argv[:separator], argv[separator + 1:]
        if "--test" not in argv:
            parser.error("Use -- only after --test FOLDER to pass pytest arguments.")
    args = parser.parse_args([prefix + arg if arg in escaped else arg for arg in argv])
    if test_arguments and args.test is None:
        parser.error("Pytest arguments require --test FOLDER.")
    for value in vars(args).values():
        if isinstance(value, list):
            value[:] = [item.removeprefix(prefix) for item in value]
    if args.help or not argv:
        show_help()
        return
    if args.staged and not args.diff:
        parser.error("--staged requires --diff.")
    if args.copy and args.collect is None:
        parser.error("--copy requires --collect.")
    if args.no_confirm and args.delete is None:
        parser.error("--no-confirm requires --delete.")
    if args.to is not None:
        if args.set_name is None or any((
            args.set_workspace is not None, args.set_name_workspace is not None, args.select is not None, args.show, args.projects, args.set_main is not None, args.run is not None, args.info is not None, args.doctor is not None, args.status is not None, args.build is not None, args.git_status is not None, args.setup is not None, args.test is not None, args.find is not None, args.collect is not None,
            args.version, args.update, args.set_github is not None, args.push, args.pull, args.diff, args.stage is not None, args.commit is not None, args.plant is not None, args.cd is not None,
            args.cd_back, args.goto_workspace, args.mkdir is not None, args.delete is not None,
        )):
            parser.error("Use --set-name [FOLDER_NAME] -to NEW_NAME on its own.")
    elif args.set_name is not None:
        parser.error("--set-name is only for renaming folders. Use -to NEW_NAME.")
    try:
        if args.goto_workspace:
            folder = active_workspace()
            if folder is None:
                raise ValueError("No active workspace. Use --set-workspace first.")
            change_folder(folder)
            return
        if args.cd is not None or args.cd_back:
            change_folder(one_folder(args.cd) if args.cd is not None else Path.cwd().parent)
            return
        if args.mkdir is not None:
            if len(args.mkdir) != 1:
                raise ValueError("Specify one folder name. Quote names containing spaces.")
            make_folder(args.mkdir[0])
            return
        if args.to is not None:
            rename_folder(direct_child(one_folder(args.set_name)) if args.set_name else ".", args.to)
            return
        if args.delete is not None:
            delete_folders(args.delete, args.no_confirm)
            return
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Folder command failed: {exc}\n")
    if args.set_workspace is not None:
        try:
            folder, name = save_workspace(one_folder(args.set_workspace) if args.set_workspace else Path.cwd())
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not save workspace: {exc}\n")
        print(f"Workspace saved: {name} ({folder})")
        return
    if args.plant is not None:
        try:
            target = args.plant[0] if args.plant in (["-here"], ["-all"]) else str(one_folder(args.plant))
            plant_markers(target)
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not plant marker: {exc}\n")
        return
    if args.set_name_workspace is not None:
        try:
            folder = rename_workspace(args.set_name_workspace)
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not rename workspace: {exc}\n")
        print(f"Active workspace: {args.set_name_workspace} ({folder})")
        return
    if args.select is not None:
        try:
            folder = select_workspace(args.select)
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not select workspace: {exc}\n")
        print(f"Active workspace: {args.select} ({folder})")
        return
    if args.collect is not None:
        try:
            collect_folders(copy=args.copy, arguments=args.collect)
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not collect folders: {exc}\n")
        return
    if args.find is not None:
        try:
            folders = find_marked_folders()
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not find markers: {exc}\n")
        if not folders:
            print("No .bicdop markers found.")
        for folder, outside in folders:
            label = str(folder)
            if outside:
                label += " (outside workspace)"
            print(f"\x1b[33m{label}\x1b[0m" if outside and sys.stdout.isatty() else label)
        return
    for operation, target in ((doctor, args.doctor), (setup, args.setup), (project_status, args.status), (git_status, args.git_status), (build_project, args.build), (run_tests, args.test)):
        if target is None:
            continue
        try:
            folder = project_folder(target)
            if not folder.is_dir():
                raise ValueError(f"Project folder does not exist: {folder}")
            result = run_tests(folder, test_arguments) if operation is run_tests else operation(folder)
            if operation is doctor and not result:
                raise SystemExit(1)
            if operation in (run_tests, build_project):
                print(f"{'Tests' if operation is run_tests else 'Build'} exited with code {result}.")
                if result:
                    raise SystemExit(result)
        except (OSError, ValueError, CalledProcessError) as exc:
            parser.exit(1, f"Project command failed: {exc}\n")
        return
    if args.info is not None:
        try:
            folder = project_folder(args.info)
            if not folder.is_dir():
                raise ValueError(f"Project folder does not exist: {folder}")
            print(f"Project: {folder}")
            marker = folder / MARKER
            print(f"Marker: {marker}" if marker.is_file() and not marker.is_symlink() else f"Marker: missing or invalid ({marker})")
            try:
                print(f"Python: {python_for(folder)}")
            except ValueError as exc:
                print(f"Python: unavailable ({exc})")
            try:
                main = read_main_file(folder)
            except (OSError, ValueError) as exc:
                print(f"Main file: unavailable ({exc})")
            else:
                print(f"Main file: {main}")
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not show project info: {exc}\n")
        return
    if args.set_main is not None or args.run is not None:
        try:
            current = Path.cwd()
            if args.set_main is not None:
                write_marker(current, current, main_file=args.set_main)
                print(f"Main file saved: {args.set_main}")
            else:
                folder = project_folder(args.run)
                script = read_main_file(folder)
                print(f"Running: {script}", flush=True)
                status = run([str(python_for(folder)), str(script)], cwd=folder, check=False).returncode
                print(f"Project exited with code {status}.")
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Project command failed: {exc}\n")
        return
    if args.show or args.projects:
        try:
            folders = list_workspace_folders() if args.projects else list_folders(Path.cwd())
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not list folders: {exc}\n")
        if not folders:
            print("No subfolders found.")
        else:
            width = max(len("Folder"), *(len(name) for name, _ in folders))
            print(f"{'Folder':<{width}} | .bicdop")
            print(f"{'-' * width}-+-{'-' * len('Missing')}")
            for name, marked in folders:
                status = "Present" if marked else "Missing"
                row = f"{name:<{width}} | {status}"
                print(f"\x1b[33m{row}\x1b[0m" if not marked and sys.stdout.isatty() else row)
        return
    if args.diff or args.stage is not None or args.commit is not None:
        try:
            if args.diff:
                show_diff(args.staged)
            elif args.stage is not None:
                stage_files(args.stage)
            else:
                commit_staged(args.commit)
        except (OSError, ValueError, CalledProcessError) as exc:
            parser.exit(1, f"Git command failed: {exc}\n")
        return
    if args.set_github is not None or args.push or args.pull:
        try:
            if args.set_github is not None:
                connect_repository(args.set_github or None)
            else:
                transfer("push" if args.push else "pull")
        except (OSError, ValueError, CalledProcessError) as exc:
            parser.exit(1, f"GitHub command failed: {exc}\n")
        return
    if args.version:
        print(f"Bicdop v{version('bicdop')}")
        return
    if not args.update:
        show_help()
        return

    try:
        return update()
    except (OSError, ValueError, CalledProcessError) as exc:
        parser.exit(1, f"Bicdop update failed: {exc}\n")
