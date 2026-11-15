import json
import sys

from typer.testing import CliRunner

from biosphir_cli import cli, core


runner = CliRunner()


def test_registry_lifecycle(tmp_path, monkeypatch):
    monkeypatch.setattr(core, "registry_file", lambda: tmp_path / "registry.json")
    project = tmp_path / "My Project"
    project.mkdir()
    assert runner.invoke(cli.app, ["project", "add", str(project), "--name", "Demo"]).exit_code == 0
    assert "demo" in runner.invoke(cli.app, ["projects"]).stdout
    assert runner.invoke(cli.app, ["project", "add", str(project), "--name", "demo"]).exit_code == 1
    assert runner.invoke(cli.app, ["project", "remove", "DEMO"]).exit_code == 0
    assert project.is_dir()
    assert core.read_registry() == {}


def test_init_does_not_overwrite(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert runner.invoke(cli.app, ["init", "--yes"]).exit_code == 0
    config = tmp_path / core.CONFIG
    config.write_text("version = 2", encoding="utf-8")
    assert runner.invoke(cli.app, ["init", "--yes"]).exit_code == 1
    assert config.read_text(encoding="utf-8") == "version = 2"


def test_task_requires_consent_and_preserves_exit_code(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    script = "from pathlib import Path; Path('ran').touch(); raise SystemExit(7)"
    args = json.dumps([sys.executable, "-c", script])
    (tmp_path / core.CONFIG).write_text(f"version = 1\n[tasks]\ntest = {args}\n", encoding="utf-8")
    dry = runner.invoke(cli.app, ["test", "--dry-run"])
    assert dry.exit_code == 0
    assert script not in dry.stdout
    assert runner.invoke(cli.app, ["test"]).exit_code == 1
    assert not (tmp_path / "ran").exists()
    assert runner.invoke(cli.app, ["test", "--yes"]).exit_code == 7
    assert (tmp_path / "ran").is_file()


def test_doctor_json_missing_runtime(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(core.shutil, "which", lambda name: None)
    (tmp_path / core.CONFIG).write_text('version = 1\n[environment]\nnode = "22"\n', encoding="utf-8")
    result = runner.invoke(cli.app, ["doctor", "--json"])
    assert result.exit_code == 1
    assert json.loads(result.stdout)[0]["ready"] is False
