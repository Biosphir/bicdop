"""Bicdop command-line entry point."""

import os
import shlex
import sys
from argparse import ArgumentParser
from pathlib import Path
from importlib.metadata import version
from subprocess import CalledProcessError

from .folders import change_folder, delete_folder, make_folder, rename_folder
from .updater import update
from .workspace import find_marked_folders, list_workspace_folders, plant_markers, save_workspace, select_workspace


def app(prog_name: str = "bicdop") -> None:
    if len(sys.argv) != 1 or not sys.stdin.isatty():
        print(f"Open {prog_name} without arguments in a terminal to use its commands.", file=sys.stderr)
        raise SystemExit(2)
    interactive(prog_name)


def interactive(prog_name: str) -> None:
    if sys.stdout.isatty():
        if os.name == "nt":
            os.system("cls")
        else:
            print("\x1b[2J\x1b[H", end="", flush=True)
    print("Type --help for commands or exit to leave Bicdop.")
    while True:
        try:
            line = input(f"bicdop [{Path.cwd()}]> ").strip()
            if line.lower() in {"exit", "quit"}:
                return
            if line:
                lexer = shlex.shlex(line, posix=True)
                lexer.whitespace_split = True
                lexer.commenters = ""
                lexer.escape = ""
                if run_command(prog_name, list(lexer)):
                    return
        except EOFError:
            return
        except KeyboardInterrupt:
            print()
        except SystemExit:
            continue
        except ValueError as exc:
            print(exc, file=sys.stderr)


def run_command(prog_name: str, argv: list[str]) -> bool | None:
    parser = ArgumentParser(
        prog=prog_name,
        description="Bicdop by BIOSPHIR.",
    )
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--update", action="store_true", help="Install the latest stable GitHub release.")
    actions.add_argument("--version", action="store_true", help="Show the installed Bicdop version.")
    actions.add_argument(
        "--set-workspace", nargs="?", const=".", metavar="PATH",
        help="Save a workspace and create its marker. Defaults to the current folder.",
    )
    actions.add_argument("--select", metavar="NAME", help="Select a saved workspace by name.")
    actions.add_argument("--find", choices=[".bicdop"], help="Find folders containing a .bicdop marker.")
    actions.add_argument("--show", action="store_true", help="List folders in the active workspace.")
    parser.add_argument(
        "--set-name", nargs="?", const=".", metavar="NAME",
        help="Name a workspace, or rename a folder when used with -to.",
    )
    parser.add_argument("-to", metavar="NEW_NAME", help="New folder name for --set-name.")
    parser.add_argument("--no-confirm", action="store_true", help="Skip --delete confirmation.")
    actions.add_argument("--cd", metavar="PATH", help="Change folders inside the Bicdop prompt.")
    actions.add_argument("--cd-back", action="store_true", help="Go to the parent folder inside the Bicdop prompt.")
    actions.add_argument("--mkdir", metavar="NAME", help="Create a folder in the current directory.")
    actions.add_argument("--delete", nargs="?", const=".", metavar="NAME", help="Delete the current folder or a direct child.")
    actions.add_argument(
        "--plant", metavar="PATH|-here|-all",
        help="Create .bicdop in a folder, the current folder, or the current folder and its direct children.",
    )
    argv = argv.copy()
    # Pass the two dash-prefixed modes as values instead of argparse options.
    for index, argument in enumerate(argv[:-1]):
        if argument == "--plant" and argv[index + 1] in ("-here", "-all"):
            argv[index:index + 2] = [f"--plant={argv[index + 1]}"]
            break
    args = parser.parse_args(argv)
    if args.no_confirm and args.delete is None:
        parser.error("--no-confirm requires --delete.")
    if args.to is not None:
        if args.set_name is None or any((
            args.set_workspace is not None, args.select is not None, args.show, args.find is not None,
            args.version, args.update, args.plant is not None, args.cd is not None,
            args.cd_back, args.mkdir is not None, args.delete is not None,
        )):
            parser.error("Use --set-name [FOLDER_NAME] -to NEW_NAME on its own.")
    elif args.set_name is not None and args.set_workspace is None:
        parser.error("--set-name requires --set-workspace or -to.")
    try:
        if args.cd is not None or args.cd_back:
            change_folder(Path(args.cd).expanduser() if args.cd is not None else Path.cwd().parent)
            return
        if args.mkdir is not None:
            make_folder(args.mkdir)
            return
        if args.to is not None:
            rename_folder(args.set_name, args.to)
            return
        if args.delete is not None:
            delete_folder(args.delete, args.no_confirm)
            return
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Folder command failed: {exc}\n")
    if args.set_workspace is not None:
        if args.set_name == ".":
            parser.error("--set-name requires a workspace name.")
        try:
            folder, name = save_workspace(Path(args.set_workspace), args.set_name)
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not save workspace: {exc}\n")
        print(f"Workspace saved: {name} ({folder})")
        return
    if args.plant is not None:
        try:
            plant_markers(args.plant)
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not plant marker: {exc}\n")
        return
    if args.select is not None:
        try:
            folder = select_workspace(args.select)
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not select workspace: {exc}\n")
        print(f"Active workspace: {args.select} ({folder})")
        return
    if args.find is not None:
        try:
            folders = find_marked_folders()
        except (OSError, ValueError) as exc:
            parser.exit(1, f"Could not find markers: {exc}\n")
        if not folders:
            print("No .bicdop markers found.")
        for folder, outside in folders:
            label = f"{folder} (outside workspace)" if outside else str(folder)
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
    if args.version:
        print(f"Bicdop v{version('bicdop')}")
        return
    if not args.update:
        parser.print_help()
        return

    try:
        return update()
    except (OSError, ValueError, CalledProcessError) as exc:
        parser.exit(1, f"Bicdop update failed: {exc}\n")
