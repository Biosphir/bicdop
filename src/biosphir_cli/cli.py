"""Bicdop command-line entry point."""

import sys
from argparse import ArgumentParser
from pathlib import Path
from importlib.metadata import version
from subprocess import CalledProcessError

from .updater import update
from .workspace import list_workspace_folders, plant_markers, save_workspace, select_workspace


def app(prog_name: str = "bicdop") -> None:
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
    actions.add_argument("--show", action="store_true", help="List folders in the active workspace.")
    parser.add_argument("--set-name", metavar="NAME", help="Name to save with --set-workspace.")
    actions.add_argument(
        "--plant", metavar="PATH|-here|-all",
        help="Create .bicdop in a folder, the current folder, or the current folder and its direct children.",
    )
    argv = sys.argv[1:]
    # Pass the two dash-prefixed modes as values instead of argparse options.
    for index, argument in enumerate(argv[:-1]):
        if argument == "--plant" and argv[index + 1] in ("-here", "-all"):
            argv[index:index + 2] = [f"--plant={argv[index + 1]}"]
            break
    args = parser.parse_args(argv)
    if args.set_name is not None and args.set_workspace is None:
        parser.error("--set-name requires --set-workspace.")
    if args.set_workspace is not None:
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
        update()
    except (OSError, ValueError, CalledProcessError) as exc:
        parser.exit(1, f"Bicdop update failed: {exc}\n")
