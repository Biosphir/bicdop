"""Bicdop command-line entry point."""

import sys
from argparse import ArgumentParser
from pathlib import Path
from importlib.metadata import version
from subprocess import CalledProcessError

from .prompt import show_interface
from .github import active_repository, connect_repository, transfer
from .help_view import show_help
from .folders import change_folder, collect_folders, delete_folders, direct_child, make_folder, one_folder, rename_folder
from .updater import update
from .workspace import active_workspace_details, find_marked_folders, list_workspace_folders, plant_markers, rename_workspace, save_workspace, select_workspace


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
    actions.add_argument("--show", action="store_true", help="List folders in the active workspace.")
    parser.add_argument(
        "--set-name", nargs="*", metavar="NAME",
        help="Rename a folder with -to. Defaults to the current folder.",
    )
    parser.add_argument("-to", metavar="NEW_NAME", help="New folder name for --set-name.")
    parser.add_argument("--no-confirm", action="store_true", help="Skip --delete confirmation.")
    actions.add_argument("--cd", nargs="+", metavar="FOLDER", help="Change folders inside the Bicdop prompt.")
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
    args = parser.parse_args([prefix + arg if arg in escaped else arg for arg in argv])
    for value in vars(args).values():
        if isinstance(value, list):
            value[:] = [item.removeprefix(prefix) for item in value]
    if args.help or not argv:
        show_help()
        return
    if args.copy and args.collect is None:
        parser.error("--copy requires --collect.")
    if args.no_confirm and args.delete is None:
        parser.error("--no-confirm requires --delete.")
    if args.to is not None:
        if args.set_name is None or any((
            args.set_workspace is not None, args.set_name_workspace is not None, args.select is not None, args.show, args.find is not None, args.collect is not None,
            args.version, args.update, args.set_github is not None, args.push, args.pull, args.plant is not None, args.cd is not None,
            args.cd_back, args.mkdir is not None, args.delete is not None,
        )):
            parser.error("Use --set-name [FOLDER_NAME] -to NEW_NAME on its own.")
    elif args.set_name is not None:
        parser.error("--set-name is only for renaming folders. Use -to NEW_NAME.")
    try:
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
    if args.show:
        try:
            folders = list_workspace_folders()
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not show workspace: {exc}\n")
        if not folders:
            print("No folders in this workspace.")
        for name, marked in folders:
            if marked:
                print(name)
            else:
                label = f"{name} (missing .bicdop)"
                print(f"\x1b[33m{label}\x1b[0m" if sys.stdout.isatty() else label)
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
