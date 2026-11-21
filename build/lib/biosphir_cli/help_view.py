"""Display a grouped command reference inside the interactive prompt."""

import os
import shutil
import sys
from textwrap import wrap


SECTIONS = (
    ("Workspace", (
        ("--set-workspace [folder]", "Save and activate a workspace. Defaults to the current folder."),
        ("--select WORKSPACE", "Switch to a saved workspace."),
        ("--goto-workspace", "Go to the active workspace folder."),
        ("--set-name-workspace NEW_NAME", "Rename the active workspace."),
        ("--projects", "List folders in the active workspace. Yellow marks folders without .bicdop."),
    )),
    ("Folders", (
        ("--show", "List folders in the current directory. Yellow marks folders without .bicdop."),
        ("--cd folder / --cd-back", "Enter a folder or go up one level."),
        ("--mkdir name", "Create a folder in the current directory."),
        ("--set-name [folder] -to name", "Rename a folder. Omit the folder to rename the current one."),
        ("--delete [folder, ...] [--no-confirm]", "Delete the current folder or direct children. Prompts by default."),
    )),
    ("Project execution", (
        ("--build folder", "Build wheel and source archives into dist using the project's Python."),
        ("--status folder", "Show the Git branch, changes, Python environment, and main-file status."),
        ("--doctor folder", "Check the marker, main file, and Python interpreter."),
        ("--setup folder", "Create or reuse .venv and offer to install requirements.txt."),
        ("--test folder [-- PYTEST_ARGS]", "Run pytest using the project's Python. Arguments after -- go to pytest."),
        ("--info folder", "Show the selected project, marker, main file, and Python interpreter."),
        ("--set-main FILE", "Save a Python main file in the current folder's marker."),
        ("--run folder", "Run the Python main file from a marked project."),
    )),
    ("Markers and collection", (
        ("--plant -here | -all | folder", "Mark the current folder, its immediate children as well, or one chosen folder."),
        ("--find .bicdop", "Find marked folders. Yellow marks folders outside the active workspace."),
        ("--collect [folder, ...] [--copy]", "Move marked folders into the workspace, or copy them with --copy."),
    )),
    ("Git and GitHub", (
        ("--diff [--staged]", "Review changes to tracked files, or inspect the staged changes."),
        ("--stage file, ...", "Stage the selected files for the next commit."),
        ('--commit "message"', "Preview and commit the staged changes after confirmation."),
        ("--git-status [folder]", "List changed files and branch tracking status from local Git data."),
        ('--set-github ["repo URL"]', "Sign in through GitHub CLI, or connect a GitHub repo to this checkout."),
        ("--push", "Push commits from the current branch to its matching GitHub branch."),
        ("--pull", "Fast-forward the current branch from GitHub. Requires a clean working tree."),
    )),
    ("Bicdop", (
        ("--help / -h", "Show this command reference."),
        ("--version", "Show the installed version."),
        ("--update", "Install the latest stable release."),
        ("exit / quit", "Return to your terminal."),
    )),
)


def show_help() -> None:
    width = max(30, shutil.get_terminal_size().columns)
    color = sys.stdout.isatty() and "NO_COLOR" not in os.environ

    def styled(value: str, code: str) -> str:
        return f"\x1b[{code}m{value}\x1b[0m" if color else value

    print(styled("Bicdop Command Reference", "1;36"))
    print("Type commands directly at the Bicdop prompt.")
    for title, commands in SECTIONS:
        print()
        print(styled(title, "1;36"))
        for syntax, description in commands:
            print(f"  {styled(syntax, '1;33')}")
            for line in wrap(description, width - 4):
                print(f"    {line}")

    print()
    print(styled("Examples", "1;36"))
    for example in (
        '--set-workspace "C:\\Projects\\My Workspace"',
        '--collect ProjectA, "Project B" --copy',
        '--delete Folder1, Folder2',
    ):
        print(f"  {styled(example, '33')}")
    for line in wrap("Quote paths and names containing spaces. Separate multiple folders with commas.", width - 2):
        print(f"  {line}")
