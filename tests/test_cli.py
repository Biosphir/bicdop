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


def test_projects(workspace):
    result = runner.invoke(cli.app, ["projects"])
    assert result.exit_code == 0
    assert "Notcher" in result.stdout
    assert "Local repo" in result.stdout
    assert "Notcher folder" in result.stdout
    assert "Missing" in result.stdout


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
    result = runner.invoke(cli.app, ["projects"])
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
    assert "new project" in runner.invoke(cli.app, ["projects"]).stdout

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
    assert result.stdout.count("Notcher folder") == 1
    assert "Available" in result.stdout
