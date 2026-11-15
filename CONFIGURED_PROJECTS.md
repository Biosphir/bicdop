# Configured projects

Bicdop supports an explicit local registry and versioned project tasks. From an existing project directory:

```powershell
bicdop init --yes
bicdop project add . --name my-app
bicdop projects
bicdop doctor --project my-app --json
bicdop dev --project my-app --dry-run
bicdop dev --project my-app --yes
```

After initialization, edit `bicdop.toml` to define the tools and tasks the project actually uses.

```toml
version = 1

[environment]
python = "3.12"
git = "2"

[tasks]
dev = ["python", "main.py"]
test = ["python", "-m", "pytest"]
build = ["python", "-m", "build"]

[tasks.docs]
args = ["python", "generate.py"]
cwd = "docs"
pass_env = ["DOCS_MODE"]
timeout = 120
```

Run custom tasks with `bicdop run docs`. Commands default to the current directory, or use the registry with `--project <alias>`. Task directories must resolve inside the project. Use arrays of individual arguments and review the configuration before consenting. Dry runs print the executable, working directory and argument count. Argument values and environment values are omitted because they can contain secrets. Interactive runs prompt for consent. CI can use `--yes` for reviewed configurations. Task output is streamed directly, so tasks themselves are responsible for avoiding secret output. The task process receives basic OS variables and any explicitly named `pass_env` variables. Windows batch shims are unsupported; use a native executable.

`bicdop doctor` reports whether Python, Git and Node versions on PATH match the configured version prefixes. `bicdop setup` reports the same checks and remediation. Install runtimes explicitly using the project's normal installation instructions. `bicdop open my-app` opens the project in the OS file manager. `bicdop project remove my-app` unregisters it and preserves the directory.

The writable registry lives at `bicdop/projects.json` under Windows LocalAppData or the XDG configuration directory. Register existing projects explicitly. The option-style commands, such as `bicdop --projects`, continue to use the existing workspace and marker workflow. Existing settings and bundled or overridden registries remain in their current locations. Gwen can launch `bicdop` directly with either command style.

Uninstall with `python -m pip uninstall bicdop` in the installation environment. This preserves the local registry, project configurations, and markers.
