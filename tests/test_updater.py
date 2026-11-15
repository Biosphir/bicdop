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


@pytest.mark.parametrize("valid_digest", [True, False])
def test_frozen_update_checks_release_asset(monkeypatch, tmp_path, valid_digest):
    import hashlib
    from io import BytesIO

    content = b"test installer"
    checksum = hashlib.sha256(content if valid_digest else b"wrong").hexdigest()
    tag = "v0.2.0"
    filename = "BicdopSetup-x64.exe"
    url = f"{updater.REPOSITORY}/releases/download/{tag}/{filename}"
    staging = tmp_path / "installer"
    staging.mkdir()
    launched = []
    monkeypatch.setattr(updater.sys, "frozen", True, raising=False)
    monkeypatch.setattr(updater, "mkdtemp", lambda **kwargs: staging)
    monkeypatch.setattr(updater, "latest_release", lambda: {
        "tag_name": tag,
        "assets": [{"name": filename, "browser_download_url": url,
                    "size": len(content), "digest": f"sha256:{checksum}"}],
    })
    monkeypatch.setattr(updater, "urlopen", lambda actual, **kwargs: BytesIO(content) if actual == url else pytest.fail("Unexpected URL"))
    monkeypatch.setattr(updater.subprocess, "Popen", launched.append)

    if valid_digest:
        updater.update_cli("0.1.0")
        assert launched == [[str(staging / filename)]]
        assert (staging / filename).read_bytes() == content
    else:
        with pytest.raises(ValueError, match="SHA-256"):
            updater.update_cli("0.1.0")
        assert not launched
        assert not staging.exists()
