"""Bicdop command-line entry point."""

from argparse import ArgumentParser
from subprocess import CalledProcessError

from .updater import update


def app(prog_name: str = "bicdop") -> None:
    parser = ArgumentParser(
        prog=prog_name,
        description="Bicdop by BIOSPHIR.",
    )
    parser.add_argument("--update", action="store_true", help="Install the latest stable GitHub release.")
    args = parser.parse_args()
    if not args.update:
        parser.print_help()
        return

    try:
        update()
    except (OSError, ValueError, CalledProcessError) as exc:
        parser.exit(1, f"Bicdop update failed: {exc}\n")
