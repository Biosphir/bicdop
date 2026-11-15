# Changelog

## Unreleased

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
