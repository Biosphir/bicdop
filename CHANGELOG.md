# Changelog

## 0.3.8

- Added local Git diff, selective staging, and confirmed commits.

- Added `--build` for Python packages and `--git-status` for change and upstream details.

- Added project status, pytest argument forwarding, and GitHub connections per checkout.

- Added `--doctor`, `--setup`, and `--test` with shared project Python selection.

- Added `--info` for inspecting project locations, markers, main files, and Python.

- Store a Python main file in project markers and run it with `--run`.

- List current folders with `--show` and active workspace folders with `--projects`.

## 0.3.7

- Added `--goto-workspace` to navigate to the active workspace.

## 0.3.6

- Connect GitHub through browser sign-in and push or fast-forward pull from the bound local checkout.

- Fix command history scrolling and show a scrollbar.

## 0.3.5

- Pin the Bicdop header and active workspace above a scrollable command history.

## 0.3.4

- Added --set-name-workspace to rename the active workspace.

- Store folder name and path in markers and support selection by name or quoted path.

- Show the active workspace in the prompt and color interactive input.
- Support comma-separated deletion and collect marked folders into the workspace.

## 0.3.3

- Added a startup header to the interactive prompt.

## 0.3.2

- Open Bicdop without arguments to clear the screen and enter its interactive prompt.
- Run all commands inside the prompt, including updates.
- Added `--find .bicdop` to flag markers outside the active workspace.

## Earlier changes

- Added `bicdop --version` to display the installed package version.

- Reset the CLI to its entry point and built-in usage help so commands can be added individually.

- Rebranded BIOSPHIR CLI as Bicdop and introduced the `bicdop` executable.
- Made `bicdop` the sole executable and `.bicdop` the sole project marker.

- Added a local project registry, versioned task configuration, explicit execution consent, and runtime diagnostics.

- Added a standalone Windows installer and checksum-verified installer updates from GitHub Releases.

- Added --set-workspace and --set-name for saving a named workspace.
- Added --select to switch between saved workspaces.
- Added --show to list workspace folders and flag missing .bicdop markers.
- Added --plant marker commands and automatic workspace marker creation.
- Added an interactive prompt with folder navigation, creation, rename, and deletion.
