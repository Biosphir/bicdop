from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import Mock

import pytest

from biosphir_cli import github


@pytest.fixture
def checkout(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".git").mkdir()
    config = tmp_path / "config" / "github.json"
    monkeypatch.setattr(github, "repository_config", lambda: config)
    monkeypatch.setattr(github, "checkout", lambda git: tmp_path)
    monkeypatch.setattr(github, "executable", lambda name: name)
    return tmp_path


def test_connect_signs_in_and_saves_checkout(checkout, monkeypatch):
    run = Mock(side_effect=[CompletedProcess([], 1), CompletedProcess([], 0), CompletedProcess([], 0)])
    monkeypatch.setattr(github.subprocess, "run", run)
    github.connect_repository("https://github.com/BIOSPHIR/demo")
    assert github.active_repository() == ("https://github.com/BIOSPHIR/demo.git", checkout)
    assert "--web" in run.call_args_list[1].args[0]
    assert run.call_args_list[2].args[0][1:4] == ["repo", "view", "BIOSPHIR/demo"]


@pytest.mark.parametrize("value", [
    "https://other.com/BIOSPHIR/demo",
    "https://user:token@github.com/BIOSPHIR/demo",
    "https://github.com/BIOSPHIR/demo/issues",
])
def test_rejects_non_repository_urls(value):
    with pytest.raises(ValueError):
        github.repository_url(value)


def test_transfers_use_bound_repo_and_branch(checkout, monkeypatch):
    url = "https://github.com/BIOSPHIR/demo.git"
    github.save_repository(url, checkout)
    run = Mock(return_value=CompletedProcess([], 0))
    monkeypatch.setattr(github.subprocess, "run", run)
    monkeypatch.setattr(github, "git_output", lambda _, command, *args, **kwargs: {
        "symbolic-ref": "refs/heads/feature/demo",
        "ls-remote": url,
        "status": "",
    }[command])
    github.transfer("push")
    assert run.call_args.args[0][-3:] == ["--no-recurse-submodules", url, "refs/heads/feature/demo:refs/heads/feature/demo"]
    github.transfer("pull")
    command = run.call_args.args[0]
    assert "--ff-only" in command
    assert command[-2:] == [url, "refs/heads/feature/demo"]


def test_rejects_wrong_checkout_and_dirty_pull(checkout, monkeypatch):
    github.save_repository("https://github.com/BIOSPHIR/demo.git", checkout / "other")
    with pytest.raises(ValueError, match="No GitHub connection for this checkout"):
        github.transfer("push")
    github.save_repository("https://github.com/BIOSPHIR/demo.git", checkout)
    monkeypatch.setattr(github, "authenticate", Mock())
    monkeypatch.setattr(github, "git_output", lambda _, command, *args, **kwargs: {
        "symbolic-ref": "refs/heads/main",
        "status": " M README.md",
    }[command])
    with pytest.raises(ValueError, match="Commit or stash"):
        github.transfer("pull")


def test_checkout_connections_preserve_previous_config(checkout, monkeypatch):
    import json

    other = checkout / "other"
    (other / ".git").mkdir(parents=True)
    subfolder = other / "src"
    subfolder.mkdir()
    config = github.repository_config()
    config.parent.mkdir()
    original_url = "https://github.com/BIOSPHIR/first.git"
    other_url = "https://github.com/BIOSPHIR/second.git"
    config.write_text(json.dumps({"checkout": str(checkout), "url": original_url}), encoding="utf-8")
    assert github.active_repository() == (original_url, checkout)
    github.save_repository(other_url, other)
    monkeypatch.chdir(subfolder)
    assert github.active_repository() == (other_url, other)
    monkeypatch.chdir(checkout)
    assert github.active_repository() == (original_url, checkout)
    assert github.read_repositories() == {checkout: original_url, other: other_url}
