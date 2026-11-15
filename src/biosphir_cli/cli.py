"""Bicdop command-line entry point."""

from argparse import ArgumentParser


def app(prog_name: str = "bicdop") -> None:
    parser = ArgumentParser(
        prog=prog_name,
        description="Bicdop by BIOSPHIR.",
    )
    parser.parse_args()
    parser.print_help()
