"""Bicdop command-line entry point."""

from argparse import ArgumentParser
from importlib.metadata import version
from subprocess import CalledProcessError

from .updater import update


def app(prog_name: str = "bicdop") -> None:
    parser = ArgumentParser(
        prog=prog_name,
        description="Bicdop by BIOSPHIR.",
    )
    parser.add_argument("--update", action="store_true", help="Install the latest stable GitHub release.")
    parser.add_argument("--version", action="store_true", help="Show the installed Bicdop version.")
    args = parser.parse_args()
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
