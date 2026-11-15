import subprocess

import pytest

from biosphir_cli import updater


@pytest.mark.parametrize("tag", [None, "v0.1.0", "v0.0.9"])
def test_update_skips_when_no_new_release(monkeypatch, tag):
    monkeypatch.setattr(updater, "latest_tag", lambda: tag)

    def unexpected(*args, **kwargs):
        pytest.fail("Installer should not run")

    monkeypatch.setattr(subprocess, "Popen", unexpected)
    monkeypatch.setattr(subprocess, "run", unexpected)
    updater.update_cli("0.1.0")


def test_update_installs_newer_release(monkeypatch, tmp_path):
    monkeypatch.setattr(updater, "latest_tag", lambda: "v0.10.0")
    monkeypatch.setattr(updater.sys, "prefix", str(tmp_path))
    launched = []

    def install(command, **kwargs):
        launched.append(command)
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(subprocess, "Popen", install)
    monkeypatch.setattr(subprocess, "run", install)
    updater.update_cli("0.9.0")
    assert len(launched) == 1
    assert launched[0][-1] == f"{updater.REPOSITORY}/archive/refs/tags/v0.10.0.zip"
