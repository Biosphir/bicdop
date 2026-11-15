import json

import pytest
from typer.testing import CliRunner

from biosphir_cli import cli

runner = CliRunner()


@pytest.fixture
def workspace(tmp_path, monkeypatch):
    registry = tmp_path / "projects.json"
    registry.write_text(
        json.dumps({"notcher": {"name": "Notcher", "path": "Notcher folder"}}),
        encoding="utf-8",
    )
    monkeypatch.setenv("BICDOP_REGISTRY", str(registry))
    monkeypatch.setenv("BICDOP_WORKSPACE", str(tmp_path))
    return tmp_path


@pytest.mark.parametrize("args", [[], ["--info"]])
def test_version(args):
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 0
    assert "Bicdop v0.1.0" in result.stdout


def test_version_option():
    result = runner.invoke(cli.app, ["--version"])
    assert result.exit_code == 0
    assert result.stdout.strip() == "Bicdop v0.1.0"


def test_projects(workspace, monkeypatch):
    monkeypatch.setenv("COLUMNS", "200")
    folder = workspace / "group" / "marked"
    folder.mkdir(parents=True)
    (folder / ".bicdop").write_text('{"id":"demo","name":"Demo project"}')
    result = runner.invoke(cli.app, ["--projects", "--root", str(workspace)])
    assert result.exit_code == 0
    assert "Notcher" not in result.stdout
    assert "Local repo" in result.stdout
    assert "Workspace folder has no .bicdop file" in result.stderr
    assert str(folder.parent) in result.stderr
    assert "Demo project" in result.stdout
    assert "Available" in result.stdout


def test_open(workspace, monkeypatch):
    folder = workspace / "Notcher folder"
    folder.mkdir()
    launched = []
    monkeypatch.setattr(cli.platform, "system", lambda: "Windows")
    monkeypatch.setattr(cli.subprocess, "Popen", launched.append)
    result = runner.invoke(cli.app, ["--open", "Notcher"])
    assert result.exit_code == 0
    assert launched == [["explorer.exe", str(folder)]]


@pytest.mark.parametrize(
    ("project", "message"),
    [("unknown", "Unknown project"), ("notcher", "Project folder missing")],
)
def test_open_errors(workspace, project, message):
    result = runner.invoke(cli.app, ["--open", project])
    assert result.exit_code == 1
    assert message in result.stderr


def test_invalid_registry(workspace):
    (workspace / "projects.json").write_text("invalid", encoding="utf-8")
    result = runner.invoke(cli.app, ["--open", "notcher"])
    assert result.exit_code == 1
    assert "Cannot load registry" in result.stderr


@pytest.mark.parametrize("editor", ["Code.exe", None])
def test_doctor(workspace, monkeypatch, editor):
    monkeypatch.setattr(cli, "editor_path", lambda: editor)
    monkeypatch.setattr(cli.shutil, "which", lambda name: name)
    result = runner.invoke(cli.app, ["--doctor"])
    assert result.exit_code == (0 if editor else 1)
    assert "VS Code" in result.stdout
    assert "1 registered" in result.stdout


def test_discovery(workspace, monkeypatch):
    folder = workspace / "New Project"
    folder.mkdir()
    marker = folder / ".bicdop"
    marker.touch()
    assert "Review" in runner.invoke(cli.app, ["--projects", "--root", str(workspace)]).stdout

    marker.write_text('{"id": "new", "name": "New Display Name"}', encoding="utf-8")
    launched = []
    monkeypatch.setattr(cli.platform, "system", lambda: "Windows")
    monkeypatch.setattr(cli.subprocess, "Popen", launched.append)
    result = runner.invoke(cli.app, ["--open", "new"])
    assert result.exit_code == 0
    assert "Opening" in result.stdout
    assert launched == [["explorer.exe", str(folder)]]


def test_registered_folder_with_marker_is_listed_once(workspace):
    folder = workspace / "Notcher folder"
    folder.mkdir()
    (folder / ".bicdop").touch()
    result = runner.invoke(cli.app, ["--projects"])
    assert result.exit_code == 0
    assert result.stdout.count("Review") == 1


@pytest.mark.parametrize("explicit_folder", [False, True])
def test_plant(tmp_path, monkeypatch, explicit_folder):
    folder = tmp_path / "Project folder"
    folder.mkdir()
    args = ["--plant", ".bicdop"]
    if explicit_folder:
        args.append(str(folder))
    else:
        monkeypatch.chdir(folder)
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 0
    marker = folder / ".bicdop"
    assert json.loads(marker.read_text()) == {"schema_version": 1, "id": "project-folder", "name": "Project folder", "entrypoint": None}

    marker.write_text('{"name": "My Project"}', encoding="utf-8")
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 0
    assert marker.read_text(encoding="utf-8") == '{"name": "My Project"}'


def test_plant_rejects_missing_folder(tmp_path):
    result = runner.invoke(cli.app, ["--plant", ".bicdop", str(tmp_path / "missing")])
    assert result.exit_code == 1
    assert "Target folder does not exist" in result.stderr


@pytest.mark.parametrize("explicit_folder", [False, True])
def test_check(tmp_path, monkeypatch, explicit_folder):
    args = ["--check", ".bicdop"]
    if explicit_folder:
        args.append(str(tmp_path))
    else:
        monkeypatch.chdir(tmp_path)
    marker = tmp_path / ".bicdop"
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 1
    assert "Marker file not found" in result.stderr
    assert not marker.exists()

    marker.touch()
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 0
    assert "Found" in result.stdout


@pytest.mark.parametrize("explicit_folder", [False, True])
def test_delete(tmp_path, monkeypatch, explicit_folder):
    args = ["--delete", ".bicdop"]
    if explicit_folder:
        args.append(str(tmp_path))
    else:
        monkeypatch.chdir(tmp_path)

    marker = tmp_path / ".bicdop"
    marker.touch()
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 0
    assert not marker.exists()

    result = runner.invoke(cli.app, args)
    assert result.exit_code == 1
    assert "Marker file not found" in result.stderr


def test_show(workspace, monkeypatch):
    monkeypatch.setenv("COLUMNS", "200")
    marked = workspace / "marked"
    marked.mkdir()
    (marked / ".bicdop").touch()
    nested = workspace / "outer" / "nested"
    nested.mkdir(parents=True)
    (nested / ".bicdop").touch()
    result = runner.invoke(cli.app, ["--show", ".bicdop", "--root", str(workspace)], terminal_width=200)
    assert result.exit_code == 0
    assert "Folder" in result.stdout
    assert "Path" in result.stdout
    assert str(marked) in result.stdout
    assert str(nested) in result.stdout


def test_discover_reports_duplicates_and_review(tmp_path):
    for name, content in (("first", '{"id":"demo"}'), ("second", '{"id":"DEMO"}'), ("empty", "")):
        folder = tmp_path / "group" / name
        folder.mkdir(parents=True)
        (folder / ".bicdop").write_text(content, encoding="utf-8")
    result = runner.invoke(cli.app, ["--discover", "--root", str(tmp_path)], terminal_width=160)
    assert result.exit_code == 0
    assert result.stdout.count("Duplicate ID") == 2
    assert "Review: missing ID" in result.stdout


@pytest.mark.parametrize("content", ["", "{broken", '{"id": "stable", "extra": true}'])
def test_fix(tmp_path, content):
    folder = tmp_path / "Project Folder"
    folder.mkdir()
    marker = folder / ".bicdop"
    marker.write_text(content, encoding="utf-8")
    result = runner.invoke(cli.app, ["--fix", ".bicdop", str(folder)])
    assert result.exit_code == 0
    data = json.loads(marker.read_text(encoding="utf-8"))
    assert data["name"] == "Project Folder"
    if "stable" in content:
        assert data["id"] == "stable"
        assert data["extra"] is True
    else:
        assert data["id"] == "project-folder"


@pytest.mark.parametrize(("options", "answer", "created"), [
    ([], "n\n", False),
    ([], "y\n", True),
    (["--no-confirm"], "", True),
])
def test_projects_plant(workspace, options, answer, created):
    folder = workspace / "New Project"
    folder.mkdir()
    existing = workspace / "Existing"
    existing.mkdir()
    (existing / ".bicdop").write_text('{"id":"keep"}')
    result = runner.invoke(
        cli.app, ["--plant", ".bicdop", "BICDOP_WORKSPACE", *options], input=answer
    )
    assert result.exit_code == 0
    marker = folder / ".bicdop"
    assert marker.exists() == created
    if created:
        assert json.loads(marker.read_text())["id"] == "new-project"
    assert (existing / ".bicdop").read_text() == '{"id":"keep"}'


@pytest.mark.parametrize(("options", "answer", "moved"), [
    ([], "n\n", False),
    ([], "y\n", True),
    (["--no-confirm"], "", True),
])
def test_collect_workspace(workspace, monkeypatch, options, answer, moved):
    source = workspace.parent / f"{workspace.name}-external"
    source.mkdir()
    (source / ".bicdop").touch()
    nested = source / "nested"
    nested.mkdir()
    (nested / ".bicdop").touch()
    monkeypatch.setattr(cli, "find_marked_folders", lambda roots: [source, nested])
    result = runner.invoke(cli.app, ["--collect", *options], input=answer)
    assert result.exit_code == 0
    assert source.exists() != moved
    assert (workspace / source.name / "nested" / ".bicdop").is_file() == moved


@pytest.mark.parametrize(("options", "answer", "deleted"), [
    ([], "n\n", False),
    ([], "y\n", True),
    (["--no-confirm"], "", True),
])
def test_delete_projects(workspace, monkeypatch, options, answer, deleted):
    folders = [workspace / "first", workspace / "second"]
    for folder in folders:
        folder.mkdir()
        (folder / ".bicdop").write_text(json.dumps({"id": folder.name}))
        (folder / "content.txt").touch()
    monkeypatch.setattr(cli, "find_marked_folders", lambda roots: folders)
    result = runner.invoke(
        cli.app, ["--delete", "first", "second", *options], input=answer
    )
    assert result.exit_code == 0, result.output
    assert all(folder.exists() != deleted for folder in folders)


@pytest.mark.parametrize(("field", "value", "expected_id", "expected_name"), [
    ("PROJECT_ID", "New Project ID", "new project id", "Old name"),
    ("PROJECT_NAME", "New name", "demo", "New name"),
    ("PROJECT_ID", "TAKEN", None, None),
    ("PROJECT_NAME", "Taken Name", None, None),
])
def test_rename_project(workspace, monkeypatch, field, value, expected_id, expected_name):
    folder = workspace / "original"
    folder.mkdir()
    marker = folder / ".bicdop"
    original = {"id": "demo", "name": "Old name", "extra": True}
    marker.write_text(json.dumps(original))
    other = workspace / "other"
    other.mkdir()
    (other / ".bicdop").write_text('{"id":"taken","name":"taken name"}')
    monkeypatch.setattr(cli, "find_marked_folders", lambda roots: [folder, other])

    result = runner.invoke(cli.app, ["--rename", "DEMO", field, value])
    if expected_id is None:
        assert result.exit_code == 1, result.output
        assert "already in use" in result.output
        assert json.loads(marker.read_text()) == original
    else:
        assert result.exit_code == 0, result.output
        assert json.loads(marker.read_text()) == {"id": expected_id, "name": expected_name, "extra": True}
        assert cli.find_project_marker(expected_id) == marker


def test_set_workspace(tmp_path, monkeypatch):
    config = tmp_path / "config" / "workspace.json"
    monkeypatch.setattr(cli, "workspace_config_path", lambda: config)
    monkeypatch.delenv("BICDOP_WORKSPACE", raising=False)
    monkeypatch.chdir(tmp_path)
    result = runner.invoke(cli.app, ["--set", "BICDOP_WORKSPACE"])
    assert result.exit_code == 0, result.output
    assert cli.workspace_path() == tmp_path
    monkeypatch.setenv("BICDOP_WORKSPACE", str(tmp_path / "override"))
    assert cli.workspace_path() == tmp_path / "override"


@pytest.mark.parametrize("whole_workspace", [False, True])
@pytest.mark.parametrize("explicit", [False, True])
def test_clone_project(tmp_path, monkeypatch, whole_workspace, explicit):
    workspace = tmp_path / "workspace"
    project = workspace / "Demo"
    project.mkdir(parents=True)
    (project / ".bicdop").write_text('{"id":"demo"}')
    (project / "main.py").write_text("print('hello')")
    monkeypatch.setenv("BICDOP_WORKSPACE", str(workspace))
    existing = workspace / "existing"
    existing.mkdir()
    (existing / ".bicdop").write_text('{"id":"DEMO-CLONE"}')
    nested = project / "nested"
    nested.mkdir()
    (nested / ".bicdop").write_text('{"id":"nested"}')
    monkeypatch.setattr(cli, "find_marked_folders", lambda roots: [
        folder for folder in (project, nested, existing)
        if roots is None or folder.is_relative_to(roots[0])
    ])
    source = workspace if whole_workspace else project
    current = tmp_path / "current"
    current.mkdir()
    monkeypatch.chdir(current)
    default_parent = current if whole_workspace else source.parent
    target = tmp_path / "Copy with spaces" if explicit else default_parent / (source.name + "-copy")
    args = ["--clone", "BICDOP_WORKSPACE" if whole_workspace else "demo"]
    if explicit:
        args.append(str(target))
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 0, result.output
    copied = target / "Demo" if whole_workspace else target
    assert (copied / "main.py").read_text() == (project / "main.py").read_text()
    assert json.loads((copied / ".bicdop").read_text())["id"] == "demo-clone-2"
    assert json.loads((copied / "nested" / ".bicdop").read_text())["id"] == "nested-clone"
    assert json.loads((project / ".bicdop").read_text())["id"] == "demo"
    assert runner.invoke(cli.app, args).exit_code == 1


@pytest.mark.parametrize("args", [["plant", ".bicdop"], ["unknown", "--plant", ".bicdop"]])
def test_actions_require_prefix(args):
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 2
    assert "No such command" in result.output


def test_action_help():
    result = runner.invoke(cli.app, ["--help"])
    assert result.exit_code == 0
    assert "--plant" in result.output
    assert "--clone" in result.output
    result = runner.invoke(cli.app, ["--clone", "--help"])
    assert result.exit_code == 0
    assert "BICDOP_WORKSPACE" in result.output


@pytest.mark.skipif(cli.os.name != "nt", reason="Windows read-only file attributes")
def test_delete_project_with_readonly_git_object(workspace, monkeypatch):
    folder = workspace / "clone"
    objects = folder / ".git" / "objects"
    objects.mkdir(parents=True)
    (folder / ".bicdop").write_text('{"id":"clone"}')
    git_object = objects / "object"
    git_object.write_text("object")
    git_object.chmod(cli.stat.S_IREAD)
    monkeypatch.setattr(cli, "find_marked_folders", lambda roots: [folder])
    result = runner.invoke(cli.app, ["--delete", "clone", "--no-confirm"])
    assert result.exit_code == 0, result.output
    assert not folder.exists()


def test_bic_marker_commands(tmp_path):
    result = runner.invoke(cli.app, ["--plant", ".bicdop", str(tmp_path)])
    assert result.exit_code == 0
    assert (tmp_path / ".bicdop").is_file()
    assert runner.invoke(cli.app, ["--check", ".bicdop", str(tmp_path)]).exit_code == 0
    assert runner.invoke(cli.app, ["--delete", ".bicdop", str(tmp_path)]).exit_code == 0
    assert not (tmp_path / ".bicdop").exists()
