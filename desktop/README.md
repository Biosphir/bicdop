# Bicdop Desktop

Bicdop Desktop is a Python and PySide6 terminal application. Each tab opens
an interactive PowerShell or Command Prompt on Windows. Linux uses Bash or
sh for development smoke tests.

## Start from source

Use Python 3.12 and Node.js to prepare the checkout. Run these commands
from the Bicdop repository root in PowerShell:

```powershell
cd desktop
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
npm.cmd ci
.\.venv\Scripts\python.exe main.py
```

npm downloads the xterm.js assets. Starting the app after setup only
requires Python. To open it from a Windows shortcut without a console
window, set the shortcut target to the desktop virtual environment's
`pythonw.exe` and pass the full path to `desktop\main.py` as its argument.

Use the shell selector to set the default for new tabs. The selection is
saved between launches. Each tab opens in your home directory and owns its
shell process. Closing a tab or the window closes its PTY.

| Shortcut | Action |
| --- | --- |
| Alt+Shift+T | Open a terminal tab |
| Alt+Shift+W | Close the active tab |
| Ctrl+Shift+C | Copy selected terminal text |
| Ctrl+Shift+V | Paste into the terminal |

## Architecture

Python owns the Qt window, settings, clipboard, and PTY lifecycle.
Windows uses `pywinpty`, and Linux uses `pexpect`. Qt WebEngine hosts
xterm.js and connects it to Python through Qt WebChannel. The xterm.js
assets are local and provide the VT renderer, Unicode, colors, and scrollback.

The existing Python CLI remains the entry point for workspace management,
Git and release commands, and project setup, run, build, and test. Type
`bicdop` in a desktop terminal tab if the CLI is installed on PATH.

For a Windows distribution, use `main.py` as the GUI entry point and
bundle the HTML, CSS, bridge and renderer scripts, the xterm.js and
fit-addon assets at their existing relative paths, and the Python
dependencies including Qt WebEngine and pywinpty.
