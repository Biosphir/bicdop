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
