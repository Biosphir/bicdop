# Bicdop

Bicdop (BIOSPHIR Integrated Command & Development Operations Platform) is a
command-line application by BIOSPHIR. This development baseline provides the
entry point and built-in usage help. Commands will be added individually.

## Install for local development

From the repository root in PowerShell:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e .
.\.venv\Scripts\bicdop.exe
```

Run with `--help` to display usage explicitly.

Run `bicdop --update` to check the latest stable GitHub Release and install it
with pip in the current Python environment. Installations made with `--user`
keep that scope. On Windows, wait for pip to finish before running Bicdop again.
Each release tag must match its package version, for example `v0.2.0` for
package version `0.2.0`.
