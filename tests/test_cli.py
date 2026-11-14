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
    monkeypatch.setenv("BIOSPHIR_REGISTRY", str(registry))
    monkeypatch.setenv("BIOSPHIR_WORKSPACE", str(tmp_path))
    return tmp_path


@pytest.mark.parametrize("args", [[], ["info"]])
def test_version(args):
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 0
    assert "BIOSPHIR CLI v0.1.0" in result.stdout


def test_version_option():
    result = runner.invoke(cli.app, ["--version"])
    assert result.exit_code == 0
    assert result.stdout.strip() == "BIOSPHIR CLI v0.1.0"


def test_projects(workspace, monkeypatch):
    monkeypatch.setenv("COLUMNS", "200")
    folder = workspace / "group" / "marked"
    folder.mkdir(parents=True)
    (folder / ".biosphir").write_text('{"id":"demo","name":"Demo project"}')
    result = runner.invoke(cli.app, ["projects", "--root", str(workspace)])
    assert result.exit_code == 0
    assert "Notcher" not in result.stdout
    assert "Local repo" in result.stdout
    assert "Workspace folder has no .biosphir file" in result.stderr
    assert str(folder.parent) in result.stderr
    assert "Demo project" in result.stdout
    assert "Available" in result.stdout


def test_open(workspace, monkeypatch):
    folder = workspace / "Notcher folder"
    folder.mkdir()
    launched = []
    monkeypatch.setattr(cli, "editor_path", lambda: "Code.exe")
    monkeypatch.setattr(cli.subprocess, "Popen", launched.append)
    result = runner.invoke(cli.app, ["open", "Notcher"])
    assert result.exit_code == 0
    assert launched == [["Code.exe", str(folder)]]


@pytest.mark.parametrize(
    ("project", "message"),
    [("unknown", "Unknown project"), ("notcher", "Project folder missing")],
)
def test_open_errors(workspace, project, message):
    result = runner.invoke(cli.app, ["open", project])
    assert result.exit_code == 1
    assert message in result.stderr


def test_invalid_registry(workspace):
    (workspace / "projects.json").write_text("invalid", encoding="utf-8")
    result = runner.invoke(cli.app, ["open", "notcher"])
    assert result.exit_code == 1
    assert "Cannot load registry" in result.stderr


@pytest.mark.parametrize("editor", ["Code.exe", None])
def test_doctor(workspace, monkeypatch, editor):
    monkeypatch.setattr(cli, "editor_path", lambda: editor)
    monkeypatch.setattr(cli.shutil, "which", lambda name: name)
    result = runner.invoke(cli.app, ["doctor"])
    assert result.exit_code == (0 if editor else 1)
    assert "VS Code" in result.stdout
    assert "1 registered" in result.stdout


def test_discovery(workspace, monkeypatch):
    folder = workspace / "New Project"
    folder.mkdir()
    marker = folder / ".biosphir"
    marker.touch()
    assert "Review" in runner.invoke(cli.app, ["projects", "--root", str(workspace)]).stdout

    marker.write_text('{"id": "new", "name": "New Display Name"}', encoding="utf-8")
    launched = []
    monkeypatch.setattr(cli, "editor_path", lambda: "Code.exe")
    monkeypatch.setattr(cli.subprocess, "Popen", launched.append)
    result = runner.invoke(cli.app, ["open", "new"])
    assert result.exit_code == 0
    assert "New Display Name" in result.stdout
    assert launched == [["Code.exe", str(folder)]]


def test_registered_folder_with_marker_is_listed_once(workspace):
    folder = workspace / "Notcher folder"
    folder.mkdir()
    (folder / ".biosphir").touch()
    result = runner.invoke(cli.app, ["projects"])
    assert result.exit_code == 0
    assert result.stdout.count("Review") == 1


@pytest.mark.parametrize("explicit_folder", [False, True])
def test_plant(tmp_path, monkeypatch, explicit_folder):
    folder = tmp_path / "Project folder"
    folder.mkdir()
    args = ["plant", ".biosphir"]
    if explicit_folder:
        args.append(str(folder))
    else:
        monkeypatch.chdir(folder)
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 0
    marker = folder / ".biosphir"
    assert json.loads(marker.read_text()) == {"id": "project-folder", "name": "Project folder"}

    marker.write_text('{"name": "My Project"}', encoding="utf-8")
    result = runner.invoke(cli.app, args)
    assert result.exit_code == 0
    assert marker.read_text(encoding="utf-8") == '{"name": "My Project"}'


def test_plant_rejects_missing_folder(tmp_path):
    result = runner.invoke(cli.app, ["plant", ".biosphir", str(tmp_path / "missing")])
    assert result.exit_code == 1
    assert "Target folder does not exist" in result.stderr


@pytest.mark.parametrize("explicit_folder", [False, True])
def test_check(tmp_path, monkeypatch, explicit_folder):
    args = ["check", ".biosphir"]
    if explicit_folder:
        args.append(str(tmp_path))
    else:
        monkeypatch.chdir(tmp_path)
    marker = tmp_path / ".biosphir"
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
    args = ["delete", ".biosphir"]
    if explicit_folder:
        args.append(str(tmp_path))
    else:
        monkeypatch.chdir(tmp_path)

    marker = tmp_path / ".biosphir"
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
    (marked / ".biosphir").touch()
    nested = workspace / "outer" / "nested"
    nested.mkdir(parents=True)
    (nested / ".biosphir").touch()
    result = runner.invoke(cli.app, ["show", ".biosphir", "--root", str(workspace)], terminal_width=200)
    assert result.exit_code == 0
    assert "Folder" in result.stdout
    assert "Path" in result.stdout
    assert str(marked) in result.stdout
    assert str(nested) in result.stdout


def test_discover_reports_duplicates_and_review(tmp_path):
    for name, content in (("first", '{"id":"demo"}'), ("second", '{"id":"DEMO"}'), ("empty", "")):
        folder = tmp_path / "group" / name
        folder.mkdir(parents=True)
        (folder / ".biosphir").write_text(content, encoding="utf-8")
    result = runner.invoke(cli.app, ["discover", "--root", str(tmp_path)], terminal_width=160)
    assert result.exit_code == 0
    assert result.stdout.count("Duplicate ID") == 2
    assert "Review: missing ID" in result.stdout


@pytest.mark.parametrize("content", ["", "{broken", '{"id": "stable", "extra": true}'])
def test_fix(tmp_path, content):
    folder = tmp_path / "Project Folder"
    folder.mkdir()
    marker = folder / ".biosphir"
    marker.write_text(content, encoding="utf-8")
    result = runner.invoke(cli.app, ["fix", ".biosphir", str(folder)])
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
    (existing / ".biosphir").write_text('{"id":"keep"}')
    result = runner.invoke(
        cli.app, ["projects", "plant", ".biosphir", *options], input=answer
    )
    assert result.exit_code == 0
    marker = folder / ".biosphir"
    assert marker.exists() == created
    if created:
        assert json.loads(marker.read_text())["id"] == "new-project"
    assert (existing / ".biosphir").read_text() == '{"id":"keep"}'


@pytest.mark.parametrize(("options", "answer", "moved"), [
    ([], "n\n", False),
    ([], "y\n", True),
    (["--no-confirm"], "", True),
])
def test_collect_workspace(workspace, monkeypatch, options, answer, moved):
    source = workspace.parent / f"{workspace.name}-external"
    source.mkdir()
    (source / ".biosphir").touch()
    nested = source / "nested"
    nested.mkdir()
    (nested / ".biosphir").touch()
    monkeypatch.setattr(cli, "find_marked_folders", lambda roots: [source, nested])
    result = runner.invoke(cli.app, ["projects", "collect", *options], input=answer)
    assert result.exit_code == 0
    assert source.exists() != moved
    assert (workspace / source.name / "nested" / ".biosphir").is_file() == moved


@pytest.mark.parametrize(("options", "answer", "deleted"), [
    ([], "n\n", False),
    ([], "y\n", True),
    (["--no-confirm"], "", True),
])
def test_delete_projects(workspace, monkeypatch, options, answer, deleted):
    folders = [workspace / "first", workspace / "second"]
    for folder in folders:
        folder.mkdir()
        (folder / ".biosphir").write_text(json.dumps({"id": folder.name}))
        (folder / "content.txt").touch()
    monkeypatch.setattr(cli, "find_marked_folders", lambda roots: folders)
    result = runner.invoke(
        cli.app, ["projects", "delete", "first", "second", *options], input=answer
    )
    assert result.exit_code == 0, result.output
    assert all(folder.exists() != deleted for folder in folders)
