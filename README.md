# Bicdop 0.8.12

## Windows installer

Download BicdopSetup.exe from Releases and open Bicdop from the Start menu.
The per-user installer includes a fallback copy of Bicdop. The launcher checks
for a newer stable GitHub release and starts the best available copy in a terminal.
Use update --apply to download an update manually, then reopen the launcher.
The launcher uses Windows PowerShell; the module also supports PowerShell 7.
When Windows Terminal is available, the installer adds a Bicdop profile with
the Bicdop logo. Open Bicdop from the Start menu or select its Terminal
profile. Its tab title follows the current workspace. Entering Bicdop in an
existing terminal tab updates the title and restores it on exit.


For maintainers, run installer/Build.ps1 -OutputDirectory PATH with Inno Setup 6
installed. Attach only `BicdopSetup.exe` to the GitHub Release tagged
`vVERSION`. The launcher verifies the SHA-256 digest from GitHub and extracts
the module from that installer without rerunning setup. Users with launchers
older than 0.8.11 need to run the new installer once to switch updater formats.

The installer bundles GitHub CLI and MinGit for x64-compatible Windows.
Open Bicdop from the Start menu and run `github --login`. Installed Git and
GitHub CLI tools on PATH remain available. Project-specific SDKs and runtimes
(such as Python, Go, or ESP-IDF) are separate.

Uninstall removes the app, its bundled tools, the Windows Terminal profile,
and Bicdop's local registry, session history, and downloaded modules.
The marker prompt defaults to keeping project and workspace settings.
Choose Yes to also remove valid markers in accessible registered workspaces
and known project folders. Cleanup does not follow links or scan unrelated
drives. It preserves project files, Git repositories, and shared GitHub credentials.

Bundled dependency sources: [GitHub CLI v2.105.0](https://github.com/cli/cli/tree/v2.105.0)
and [Git for Windows v2.56.1.windows.1](https://github.com/git-for-windows/git/tree/v2.56.1.windows.1).

## Source checkout

Bicdop runs inside your current Windows PowerShell 5.1 or PowerShell 7 session.

```powershell
Import-Module .\Bicdop\Bicdop.psd1
bicdop
```

The Bicdop shell displays the current path and active workspace. Enter
commands directly, such as `workspace --set`, `scan`, `switch 1`, or `help`.

Use `mkdir PATH`, `cd PATH`, `cd..`, `li [PATH]` (also `ls` or `dir`), and
`pwd` to work with directories. `uote paths and names with spaces. The shell
accepts one Bicdop command per line. Use `flush` to clear the display and `exit` to return to PowerShell.
From PowerShell, use the prefix for individual commands, for example `bicdop show`.

Add the module import to your PowerShell profile to load it on startup.

Use open to open the current directory in File Explorer, open --workspace
for the active workspace, or open "Project Name" for a folder inside that workspace.
Bicdop restores a minimized Explorer window for the target folder and requests focus. If Windows initially denies focus, Bicdop retries activation before falling back to the normal Explorer window.

## Resume your session

Bicdop clears the terminal and restores the last working folder and workspace when you open it. Press the Up Arrow (or Down Arrow) to browse recent commands. The
highlighted command is editable and only runs when you press Enter. Commands
are saved before they run, so the history survives an interrupted operation.
Bicdop never replays a command on startup.
Explicit session --resume shows the last ten command results for that session. Use
session --log to see the saved summary. An interrupted command without
a recorded result is marked as outcome unknown. Full terminal output and
progress lines are not copied into the summary.


Use session --save "Name" and session --resume "Name" to keep separate named
contexts. Use session --list to see them and session --close to return to the
automatic unnamed session. The latest 100 commands and the session state are
stored locally under %LOCALAPPDATA%/Bicdop, outside project repositories.
Recognized password, API key, and token inputs are excluded from history.
Console history navigation uses the Windows console; redirected input still works.

## Data and recovery

Workspace roots contain `.bicdop-workspace`; projects contain `.bicdop`.
New markers are JSON with a schema number and a random UUID. Project
markers also record the workspace UUID or null. Workspace and project UUIDs
stay stable on rename. Older project markers are visible in scans and
are never overwritten.

The registry is stored in `%LOCALAPPDATA%\Bicdop\registry.json` on Windows
and in the user's local application data directory elsewhere. It maps
workspace and project IDs to last-registered names and paths. Registry writes
are serialized and replaced atomically. If registering a new marker fails,
Bicdop attempts to remove the marker it just created and reports failures.

After moving a workspace, run `bicdop workspace --set` from its new root.
Projects within it have their stored paths adjusted if the matching marker
is present. For a separately moved project, back up the registry, close all
Bicdop sessions, and update the stored path for the matching UUID. If two
folders contain copies of a marker, keep the intended identity in one folder
and remove the copied marker from the other before planting it as a new
project. Bicdop will not silently overwrite the original registration.

## Show workspace folders

`projects` lists registered projects directly under the active workspace.
Its row numbers can be used with `switch`.

`bicdop show` lists the direct subfolders of the active workspace in the same
table as `bicdop scan`, including unmarked and hidden folders. It skips symlinks and junctions.
Use `show` directly while the Bicdop prompt is active.

`bicdop workspace --goto` changes the current PowerShell location to the
active workspace root.

Folder tables display `Size` as the total size of files in the folder and its
descendants. Symlinks and junctions are skipped. A trailing `+` marks a partial
total when some contents could not be read.

## Plant direct subfolders

`bicdop plant --all` creates project markers for the direct subfolders of
the current folder after confirmation. It skips existing markers, the
`.git` directory, symlinks, and junctions. Use `bicdop plant 1,3,5` to plant
specific rows from the latest scan.

## Manage project markers

Inside Bicdop, use marker --set FIELD VALUE in the project root. Quote text
such as marker --set release_channel "beta". Numbers, true, false, and null
are accepted without quotes. From PowerShell, preserve the inner quotes with
bicdop marker --set release_channel '"beta"'. Bicdop manages schema (the
marker format version), id, and workspace.


Run marker --check to read the current folder marker, or marker "Project Name"
--check to read a project marker from the active workspace.

`bicdop marker --clear` removes the current folder's `.bicdop` marker and
project registration. `bicdop marker --replant` writes or refreshes the marker
and registers the folder with the active workspace. A project marker belongs at the project root, directly under the active
workspace. Replanting with --all targets only those project roots. Clearing
with --all includes nested folders so legacy project markers can be removed.
The workspace marker is preserved.
The console shows scan and marker-processing progress, then reports how many
folders were updated, skipped, or failed.

## Scan defaults

`bicdop scan`, `bicdop scan --git`, and `bicdop scan --project NAME` use the
active workspace. `bicdop scan PATH` uses that path. `--all` and
`--new NAME` scan accessible filesystem drives. Results are read-only,
skip links and junctions, and replace the current session's scan selection.
A failed or interrupted scan invalidates the previous selection. Project
listing and scan numbering are separate.

`bicdop update --check` checks the official stable GitHub release. Applying
an update is deferred until a verified module distribution and update
procedure are available.

## Verify on Windows

Run `powershell.exe -NoProfile -File .\tests\smoke.ps1` for Windows
PowerShell 5.1 and `pwsh -NoProfile -File .\tests\smoke.ps1` for
PowerShell 7 from the checkout root.
For a manual check, import the module in Windows Terminal, enable the
prompt, and use a temporary workspace to test native commands and
`bicdop switch`. Start a broad scan and press Ctrl+C, then verify that
the prompt still accepts commands and that the canceled scan cannot
be used with `bicdop plant 1`. Use `flush` to clear the display and `exit` to return to PowerShell.


## Run a project

Run from the current folder with bicdop run, or pass a quoted folder name
to run a direct child of the active workspace. New and replanted markers
store a detected relative main_file. Older markers can use automatic
detection or save a relative path with bicdop run --set FILE from the
project root. Bicdop supports Python, PowerShell, Node.js, HTML, and PHP entry points.
For a file in a subfolder, run `bicdop run --set "biosphir/index.html"` from the project root.
HTML and PHP previews open in the default browser over HTTP on 127.0.0.1.
The folder containing the entry file is the document root, so links such as
`/assets/...` resolve there. HTML requires Python. PHP requires `php.exe` on PATH.
The preview runs in the background. Running the project again reuses a live
server for the same document root and runtime. Use `bicdop stop [PROJECT]` in
the same PowerShell session to stop it.

Use bicdop project --main to print the entry point saved in the current folder's marker.
Use bicdop version to check the installed and latest stable versions without applying an update.

Use bicdop project --list to show direct files and folders, including hidden items.

Bicdop records the declared project version in .bicdop when planting or replanting.
It checks package.json, the project section of pyproject.toml, then VERSION.
Use bicdop project --version to read it or bicdop project --version VERSION to set it.
Use bicdop project "Project Name" --version to read a named project in the active workspace without changing folders.

Both project version commands refresh the marker when the declared local version changes.
If no version is declared, they use the value already stored in the marker.

Use run --detach or run "Project Name" --detach for long-running apps.
Bicdop starts a separate process and displays its PID. A normal run waits for
script completion. HTML and PHP previews run in the background by default.

Running the same project again with --detach replaces the previous process
started by this Bicdop session. Bicdop requests a normal close when possible,
then stops the process if it stays open. Browser tabs are managed by the browser.

## Build and test with project toolchains

Run `bicdop build [PROJECT]` or `bicdop test [PROJECT]` from PowerShell.
Inside Bicdop, omit the prefix. Run tasks for Go, Rust, Java and npm are
available when a project has no explicit `main_file`. Toolchain run tasks
stay in the foreground. The toolchain must be installed and on PATH.

| Project | Detection | Run | Build and test |
| --- | --- | --- | --- |
| Go | go.mod | go run . | go build . / go test ./... |
| Rust | Cargo.toml | cargo run | cargo build / cargo test |
| Java, Maven | pom.xml | exec:java with a configured main class | package / test |
| Java, Gradle | Gradle build file or wrapper | run with an application task | build / test |
| React and other npm projects | package.json | npm run dev or npm run start | npm run build / npm run test |
| C++ and Pico SDK | CMakeLists.txt | Save a built Windows executable with run --set | CMake build / CTest in .bicdop-build |
| PlatformIO (ESP32, RP2040 and other boards) | platformio.ini | Use flash for the device | pio run / pio test |
| Native ESP-IDF | ESP-IDF CMake project | Use flash for the device | idf.py build in an activated ESP-IDF environment |

Use `bicdop flash [PROJECT]` to upload firmware with PlatformIO or ESP-IDF.
The board, environment and serial port follow the project's toolchain settings.
For a Pico SDK build, configure your SDK and compiler environment, build, then
copy the generated UF2 to the device in BOOTSEL mode.

## Build with PyInstaller

Use pyinstaller in a marked project or pyinstaller "Project Name" to build a
direct child of the active workspace. If pyinstaller_command is empty, Bicdop
asks for a full command such as python -m PyInstaller --clean Notcher.spec,
saves it in .bicdop, then starts the build. An empty response cancels.
Use pyinstaller --set "COMMAND-LINE" to save or replace the command without building.
Bicdop uses the project's .venv when available and runs the build from its root.

Project markers store github_url when Git is available and the project's origin
points to GitHub. Planting and replanting capture a clean HTTPS link without
credentials. Use marker --replant to refresh it after the remote changes.

Use `github --login` to sign in to GitHub CLI through the browser,
`github --account` to see the active username, and `github --logout` to
sign out that account after confirming. These commands work without an
active workspace and share the local GitHub CLI session. Signing out of
GitHub CLI does not remove credentials stored by Git Credential Manager.
GitHub operations report the active CLI account when it can be verified.
Git uses its own configured credentials and commit author.

Use `github --create --repo NAME` to create an empty private repository on
GitHub under the active account. Add `--public` to make it public. Use
`github --create --local NAME` to initialize an empty Git repository in a
new folder in the active workspace. Use `github --list` to list the repos
owned by the active account that its credentials can access.

Use `github --clone OWNER/REPO` to clone into the active workspace.
A GitHub repository URL also works. A bare name such as `github --clone bicdop`
uses the owner from your signed-in GitHub CLI account. Clone skips existing
destination paths. Run `plant` inside the new folder if you want it registered
as a Bicdop project.

Run github --status from a Git project root to check its GitHub origin, working
tree, and latest branch commit. It queries GitHub without fetching objects.
Synced means the working tree is clean and the local commit matches GitHub.

From a Git project root, github --commit "MESSAGE" commits staged changes.
Use github --fetch to refresh origin refs, github --pull for a fast-forward
merge, and github --push to publish the current branch and set its upstream.
Remote operations use the configured GitHub origin and Git credentials.

Use github --stage FILE [...] to stage specific paths or github --stage --all
for all new, modified, and deleted files. Git ignore rules still apply.

Use github --publish to stage all changes, create a summary commit if needed,
and push. The older github --push --force spelling still works. Both use a
normal Git push, which rejects non-fast-forward updates.
Use github --diff and github --diff --staged to review changes, or use
github --unstage FILE [...] and github --unstage --all to undo staging while
keeping working files. Use github --status to list staged and unstaged paths.

## GitHub Releases

github_release_url defaults to github_url. Set a different repository with
marker --set github_release_url "https://github.com/owner/release-repo".
From the project root, use github --release TAG [FILE ...] to create a draft,
github --release --view TAG to review it, and github --release --publish TAG
to publish it. Use github --release --upload TAG FILE [...] to add assets
without replacing existing assets. GitHub CLI (gh) must be signed in.

## Errors and feedback

Use help errors for common fixes. In the Bicdop shell, errors show the
original message and a suggested next step. Long operations display progress
or stream their tool output. Short commands show the result directly.

Use rmdir PATH to delete an empty folder after confirmation, or add
--recursive to include its contents. Recursive deletion stops if a directory symlink or junction is found. Use ping HOST to test connectivity,
or ping HOST --count NUMBER to send a specific number of requests.

Use github --workspace to run the same status checks for all Git project
roots inside the active workspace, including nested repositories. It does
not change the current folder, stage files, or fetch commits.

Use github --workspace --publish to preview repositories with publishable
changes and confirm once. Bicdop then stages, commits as needed, and pushes
each eligible repo normally. Synced, inaccessible, detached, behind, and
diverged repositories are skipped. Use github --workspace to review details.
