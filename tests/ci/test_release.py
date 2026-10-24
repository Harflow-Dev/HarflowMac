"""Consequence tests for the local Mac release validators."""

import importlib.util
import json
import hashlib
from contextlib import ExitStack
from pathlib import Path
import subprocess
from unittest import mock

import pytest


ROOT = Path(__file__).parents[2]
SPEC = importlib.util.spec_from_file_location("release", ROOT / "scripts/ci/release.py")
release = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(release)

ASSET_MODULE_SPEC = importlib.util.spec_from_file_location("release_assets", ROOT / "scripts/ci/release_assets.py")
release_assets = importlib.util.module_from_spec(ASSET_MODULE_SPEC)
assert ASSET_MODULE_SPEC.loader is not None
ASSET_MODULE_SPEC.loader.exec_module(release_assets)


def test_source_accepts_current_plist_and_runtime_pair():
    assert release.validate_source(ROOT) == ("0.0.2", "0.0.2")


def test_source_rejects_tag_mismatch_before_git_lookup():
    with mock.patch.object(release.subprocess, "check_output") as check_output:
        with pytest.raises(release.ReleaseError):
            release.validate_source(ROOT, tag="v0.0.3", sha="0" * 40)
    check_output.assert_not_called()


def test_runtime_rejects_engine_version_that_is_not_the_paired_release(tmp_path):
    runtime = ROOT / release.RUNTIME_PATH
    data = json.loads(runtime.read_text())
    data["engineVersion"] = "0.0.1"
    candidate = tmp_path / "ManagedRuntime-test.json"
    candidate.write_text(json.dumps(data))
    with pytest.raises(release.ReleaseError):
        release.validate_runtime(candidate)


def _metadata(version="0.0.1", url=None):
    filename = f"harflow_mcp-{version}-py3-none-any.whl"
    return {
        "info": {"name": "harflow-mcp", "version": version},
        "urls": [{
            "filename": filename,
            "packagetype": "bdist_wheel",
            "url": url or f"https://files.pythonhosted.org/packages/xx/{filename}",
            "size": 12,
            "digests": {"sha256": "a" * 64},
        }],
    }


def test_pypi_metadata_rejects_wrong_host_and_requires_exact_version():
    assert release.validate_pypi_metadata(_metadata(), "0.0.1")["filename"].endswith("0.0.1-py3-none-any.whl")
    with pytest.raises(release.ReleaseError):
        release.validate_pypi_metadata(_metadata(url="https://example.com/wheel.whl"), "0.0.1")
    with pytest.raises(release.ReleaseError):
        release.validate_pypi_metadata(_metadata(), "0.0.2")


def test_wait_for_pypi_retries_exact_release_without_latest_fallback():
    calls = []
    sleeps = []

    def fetch():
        calls.append(True)
        if len(calls) == 1:
            raise OSError("not available")
        return _metadata()

    result = release.wait_for_pypi("0.0.1", fetch=fetch, sleep=sleeps.append, attempts=2)
    assert result["filename"] == "harflow_mcp-0.0.1-py3-none-any.whl"
    assert len(calls) == 2
    assert sleeps == [10]


def test_packaged_startup_probe_requires_exact_bounded_json_and_scrubbed_environment():
    calls = []

    def process(args, **kwargs):
        calls.append((args, kwargs))
        assert Path(kwargs["cwd"]).is_dir()
        assert Path(kwargs["env"]["HOME"]).is_dir()
        assert Path(kwargs["env"]["TMPDIR"]).is_dir()
        assert kwargs["env"]["HOME"] != kwargs["env"]["TMPDIR"]
        return subprocess.CompletedProcess(args, 0, b'{"appVersion":"0.0.2","engineVersion":"0.0.1","status":"ok"}\n', b"")

    release.validate_packaged_startup(Path("Harflow.app"), "0.0.2", "0.0.1", process=process)
    args, kwargs = calls[0]
    assert args[-1] == "--check-packaged-startup"
    assert Path(args[0]).is_absolute()
    assert kwargs["stdin"] is subprocess.DEVNULL
    assert kwargs["timeout"] == 10
    assert kwargs["env"]["PATH"] == "/usr/bin:/bin"
    assert set(kwargs["env"]) == {"HOME", "TMPDIR", "PATH"}
    assert Path(kwargs["cwd"]).name.startswith("harflow-startup-")


@pytest.mark.parametrize("result", [
    subprocess.CompletedProcess(["Harflow"], 1, b"{}\n", b""),
    subprocess.CompletedProcess(["Harflow"], 0, b"not-json\n", b""),
    subprocess.CompletedProcess(["Harflow"], 0, b'{"appVersion":"0.0.3","engineVersion":"0.0.1","status":"ok"}\n', b""),
    subprocess.CompletedProcess(["Harflow"], 0, b'{"appVersion":"0.0.2","engineVersion":"0.0.1","status":"ok"}\n', b"unexpected"),
])
def test_packaged_startup_probe_rejects_bad_process_result(result):
    with pytest.raises(release.ReleaseError):
        release.validate_packaged_startup(Path("Harflow.app"), "0.0.2", "0.0.1", process=lambda *args, **kwargs: result)


@pytest.mark.parametrize("payload", [
    b'{"appVersion":"0.0.2","engineVersion":"0.0.1","status":"ok","extra":true}\n',
    b'{"appVersion":"0.0.2","engineVersion":"0.0.1"}\n',
    b'{"appVersion":"0.0.2","engineVersion":"0.0.2","status":"ok"}\n',
    b'{"appVersion":"0.0.2","engineVersion":"0.0.1","status":"ok","status":"ok"}\n',
    b"{" + b"a" * 4100 + b"}\n",
])
def test_packaged_startup_probe_rejects_wrong_shape_or_oversized_output(payload):
    result = subprocess.CompletedProcess(["Harflow"], 0, payload, b"")
    with pytest.raises(release.ReleaseError):
        release.validate_packaged_startup(Path("Harflow.app"), "0.0.2", "0.0.1", process=lambda *args, **kwargs: result)


def test_packaged_startup_probe_rejects_timeout():
    def process(*args, **kwargs):
        raise subprocess.TimeoutExpired(args[0], 10)

    with pytest.raises(release.ReleaseError):
        release.validate_packaged_startup(Path("Harflow.app"), "0.0.2", "0.0.1", process=process)


def test_validate_bundle_requires_exact_packaged_runtime_path_and_rejects_duplicates(tmp_path):
    root = tmp_path / "source"
    runtime = root / release.RUNTIME_PATH
    runtime.parent.mkdir(parents=True)
    runtime.write_bytes((ROOT / release.RUNTIME_PATH).read_bytes())
    app = tmp_path / "Harflow.app"
    resources = app / "Contents/Resources"
    exact = resources / "MonitorCore_MonitorCore.bundle/ManagedRuntime.json"
    exact.parent.mkdir(parents=True)
    exact.write_bytes(runtime.read_bytes())
    for name in ("AppIcon.icns", "menubarTemplate.png", "menubarTemplate@2x.png"):
        (resources / name).write_bytes(b"asset")

    good_process = lambda *args, **kwargs: subprocess.CompletedProcess(
        args[0], 0, b'{"appVersion":"0.0.2","engineVersion":"0.0.2","status":"ok"}\n', b""
    )
    with mock.patch.object(release, "validate_source", return_value=("0.0.2", "0.0.2")), \
            mock.patch.object(release, "validate_plist", return_value="0.0.2"), \
            mock.patch.object(release, "code_paths", return_value=[]), \
            mock.patch.object(release, "verify_signature"):
        assert release.validate_bundle(app, root, startup_process=good_process) == ("0.0.2", "0.0.2")
        duplicate = resources / "Other.bundle/ManagedRuntime.json"
        duplicate.parent.mkdir()
        duplicate.write_bytes(runtime.read_bytes())
        with pytest.raises(release.ReleaseError):
            release.validate_bundle(app, root, startup_process=good_process)

        duplicate.unlink()
        exact.unlink()
        misplaced = resources / "ManagedRuntime.json"
        misplaced.write_bytes(runtime.read_bytes())
        with pytest.raises(release.ReleaseError):
            release.validate_bundle(app, root, startup_process=good_process)

        exact.write_bytes(runtime.read_bytes())
        root_duplicate = app / "ManagedRuntime.json"
        root_duplicate.write_bytes(runtime.read_bytes())
        with pytest.raises(release.ReleaseError):
            release.validate_bundle(app, root, startup_process=good_process)


class _Commands:
    def __init__(self, response):
        self.response = response
        self.calls = []

    def run(self, args, timeout=120, include_stderr=False):
        self.calls.append(list(args))
        if args[:3] == [release.preflight.SECURITY, "list-keychains", "-d"] and "-s" not in args:
            return "/Users/runner/login.keychain-db\n"
        if args[:3] == [release.preflight.SECURITY, "find-identity", "-v"]:
            return '  1) abc "Developer ID Application: Harflow (A1B2C3D4E5)"\n'
        if args[:3] == [release.preflight.XCRUN, "notarytool", "submit"]:
            if isinstance(self.response, BaseException):
                raise self.response
            return self.response
        return ""


class _FailCommands(_Commands):
    def __init__(self, token):
        super().__init__("{\"status\":\"Accepted\",\"id\":\"n-1\"}")
        self.token = token

    def run(self, args, timeout=120, include_stderr=False):
        if self.token in args:
            self.calls.append(list(args))
            raise subprocess.CalledProcessError(1, args, stderr="private-secret")
        return super().run(args, timeout, include_stderr)


def _signing_env(tmp_path):
    return {
        "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64",
        "GITHUB_REPOSITORY": "Harflow-Dev/HarflowMac", "GITHUB_REF": "refs/heads/main", "RUNNER_TEMP": str(tmp_path),
        "GITHUB_EVENT_NAME": "workflow_dispatch", "HARFLOW_DEVELOPER_ID_P12_BASE64": "cDEy",
        "HARFLOW_DEVELOPER_ID_P12_PASSWORD": "p12-secret", "HARFLOW_NOTARY_APPLE_ID": "apple-id",
        "HARFLOW_NOTARY_APP_PASSWORD": "notary-secret", "HARFLOW_APPLE_TEAM_ID": "A1B2C3D4E5",
    }


@pytest.mark.parametrize("token", ["import", "set-key-partition-list"])
def test_signing_failure_restores_exact_keychain_search_list(token, tmp_path, capsys):
    env = _signing_env(tmp_path)
    commands = _FailCommands(token)
    with mock.patch.object(release, "validate_signing_runner", return_value=tmp_path), \
            mock.patch.object(release, "validate_bundle", return_value=("0.0.1", "0.0.1")), \
            mock.patch.object(release, "code_paths", return_value=[Path("Harflow")]), \
            mock.patch.object(release.preflight, "decode_p12", return_value=b"p12"), \
            mock.patch.object(release.preflight, "signing_identity", return_value="Developer ID Application: Harflow (A1B2C3D4E5)"):
        assert release.sign_product(Path("Harflow.app"), ROOT, tmp_path / "release-dist", env=env, commands=commands) == 1
    restores = [call for call in commands.calls if call[:4] == [release.preflight.SECURITY, "list-keychains", "-d", "user"] and "-s" in call]
    assert restores and restores[-1][-1] == "/Users/runner/login.keychain-db"
    output = capsys.readouterr().out
    assert "p12-secret" not in output and "private-secret" not in output


def _successful_signing_patches(stack, tmp_path, assessment=None):
    stack.enter_context(mock.patch.object(release, "validate_signing_runner", return_value=tmp_path))
    stack.enter_context(mock.patch.object(release, "validate_bundle", return_value=("0.0.1", "0.0.1")))
    stack.enter_context(mock.patch.object(release, "code_paths", return_value=[Path("Harflow")]))
    stack.enter_context(mock.patch.object(release.preflight, "decode_p12", return_value=b"p12"))
    stack.enter_context(mock.patch.object(release.preflight, "signing_identity", return_value="Developer ID Application: Harflow (A1B2C3D4E5)"))
    stack.enter_context(mock.patch.object(release, "create_zip", side_effect=lambda app, destination, commands: Path(destination).write_bytes(b"signed zip")))
    stack.enter_context(mock.patch.object(release, "verify_zip"))
    stack.enter_context(mock.patch.object(release, "assess", side_effect=assessment))


def test_successful_signing_retains_only_final_zip_and_checksum_after_cleanup(tmp_path):
    output = tmp_path / "release-dist"
    commands = _Commands('{"status":"Accepted","id":"n-1"}')
    with ExitStack() as stack:
        _successful_signing_patches(stack, tmp_path)
        assert release.sign_product(Path("Harflow.app"), ROOT, output, env=_signing_env(tmp_path), commands=commands) == 0
    archive = output / "Harflow-0.0.1-arm64.zip"
    checksum = output / (archive.name + ".sha256")
    assert archive.read_bytes() == b"signed zip"
    assert checksum.read_text() == hashlib.sha256(b"signed zip").hexdigest() + "  " + archive.name + "\n"
    restores = [call for call in commands.calls if call[:4] == [release.preflight.SECURITY, "list-keychains", "-d", "user"] and "-s" in call]
    assert restores and restores[-1][-1] == "/Users/runner/login.keychain-db"


@pytest.mark.parametrize("failure", ["staple", "assessment"])
def test_accepted_notary_staple_or_assessment_failure_emits_no_assets(tmp_path, failure):
    output = tmp_path / "release-dist"
    commands = _FailCommands("staple") if failure == "staple" else _Commands('{"status":"Accepted","id":"n-1"}')
    assessment = release.ReleaseError() if failure == "assessment" else None
    with ExitStack() as stack:
        _successful_signing_patches(stack, tmp_path, assessment)
        assert release.sign_product(Path("Harflow.app"), ROOT, output, env=_signing_env(tmp_path), commands=commands) == 1
    assert not output.exists() or not list(output.iterdir())
    restores = [call for call in commands.calls if call[:4] == [release.preflight.SECURITY, "list-keychains", "-d", "user"] and "-s" in call]
    assert restores and restores[-1][-1] == "/Users/runner/login.keychain-db"


@pytest.mark.parametrize("response", ["{}", '{"status":"Rejected","id":"n-1"}', subprocess.TimeoutExpired(["notarytool"], 1)])
def test_notary_failure_never_emits_final_assets_or_secret(response, tmp_path, capsys):
    output = tmp_path / "release-dist"
    env = _signing_env(tmp_path)
    commands = _Commands(response)
    with mock.patch.object(release, "validate_signing_runner", return_value=tmp_path), \
            mock.patch.object(release, "validate_bundle", return_value=("0.0.1", "0.0.1")), \
            mock.patch.object(release, "code_paths", return_value=[Path("Harflow")]), \
            mock.patch.object(release.preflight, "decode_p12", return_value=b"p12"), \
            mock.patch.object(release.preflight, "signing_identity", return_value="Developer ID Application: Harflow (A1B2C3D4E5)"), \
            mock.patch.object(release, "create_zip"), mock.patch.object(release, "verify_zip"), \
            mock.patch.object(release, "assess"):
        assert release.sign_product(Path("Harflow.app"), ROOT, output, env=env, commands=commands) == 1
    assert not output.exists() or not list(output.iterdir())
    captured = capsys.readouterr()
    assert "p12-secret" not in captured.out and "notary-secret" not in captured.out


def _asset_fixture(tmp_path, version="0.0.1"):
    name = f"Harflow-{version}-arm64.zip"
    archive = tmp_path / name
    archive.write_bytes(b"validated zip bytes")
    (tmp_path / f"{name}.sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + name + "\n")
    return name


def test_asset_upload_verifies_both_fixed_assets(tmp_path):
    name = _asset_fixture(tmp_path)
    calls = []
    existing = []
    posted = []
    uploaded = {name: {"id": 41, "name": name, "state": "uploaded", "size": (tmp_path / name).stat().st_size, "digest": "sha256:" + hashlib.sha256((tmp_path / name).read_bytes()).hexdigest()},
                name + ".sha256": {"id": 42, "name": name + ".sha256", "state": "uploaded", "size": (tmp_path / (name + ".sha256")).stat().st_size, "digest": "sha256:" + hashlib.sha256((tmp_path / (name + ".sha256")).read_bytes()).hexdigest()}}

    def request(method, url, data=None, content_type="application/json"):
        calls.append((method, url, data, content_type))
        if method == "GET" and url.endswith("/releases/9"):
            return {"tag_name": "v0.0.1", "draft": False}
        if method == "GET":
            return list(existing) if not posted else list(uploaded.values())
        if method == "POST":
            item = url.split("name=", 1)[1].split("&", 1)[0]
            item = Path(item).name
            posted.append(item)
            uploaded[item]["label"] = url.split("&label=", 1)[1]
            return uploaded[item]
        if method == "PATCH":
            asset_id = int(url.rsplit("/", 1)[1])
            for asset in uploaded.values():
                if asset["id"] == asset_id:
                    asset["label"] = ""
            return {"id": asset_id}
        raise AssertionError(method)

    release_assets.upload_release_assets(tmp_path, "0.0.1", 9, "secret-token", request=request)
    assert [call[0] for call in calls] == ["GET", "GET", "POST", "POST", "GET", "PATCH", "PATCH", "GET"]
    assert all(json.loads(call[2].decode()) == {"label": ""} for call in calls if call[0] == "PATCH")
    assert all(asset.get("label") in ("", name, name + ".sha256") for asset in uploaded.values())
    assert all("secret-token" not in str(call) for call in calls)


def test_asset_upload_failure_deletes_only_own_labelled_assets(tmp_path):
    name = _asset_fixture(tmp_path)
    other = {"id": 7, "name": "unrelated.txt", "state": "uploaded"}
    foreign_same_name = {"id": 8, "name": name, "state": "uploaded", "label": "concurrent-invocation"}
    own = {"id": 41, "name": name, "state": "uploaded", "label": "invocation"}
    calls = []
    post_started = False

    def request(method, url, data=None, content_type="application/json"):
        nonlocal post_started
        calls.append((method, url))
        if method == "GET" and url.endswith("/releases/9"):
            return {"tag_name": "v0.0.1", "draft": False}
        if method == "GET":
            # The ZIP POST response is deliberately lost; discovery must use our invocation label.
            return [other, foreign_same_name, own] if post_started else [other]
        item = url.split("name=", 1)[1].split("&", 1)[0] if method == "POST" else ""
        if method == "POST" and item == name:
            post_started = True
            own["label"] = url.split("&label=", 1)[1]
            raise OSError("upload response lost")
        if method == "POST":
            raise OSError("upload interrupted")
        if method == "DELETE":
            assert url.endswith("/assets/41")
            return None
        raise AssertionError(method)

    with pytest.raises(ValueError, match="asset pair upload failed"):
        release_assets.upload_release_assets(tmp_path, "0.0.1", 9, "secret-token", request=request)
    deletes = [url for method, url in calls if method == "DELETE"]
    assert deletes == [release_assets.API + "/releases/assets/41"]
    assert not any(url.endswith("/assets/7") for url in deletes)
    assert not any(url.endswith("/assets/8") for url in deletes)


def test_asset_upload_discovery_failure_still_deletes_known_upload(tmp_path):
    name = _asset_fixture(tmp_path)
    calls = []

    listing_calls = 0

    def request(method, url, data=None, content_type="application/json"):
        nonlocal listing_calls
        calls.append((method, url))
        if method == "GET" and url.endswith("/releases/9"):
            return {"tag_name": "v0.0.1", "draft": False}
        if method == "GET":
            listing_calls += 1
            if listing_calls == 1:
                return []
            raise OSError("asset listing unavailable")
        item = url.split("name=", 1)[1].split("&", 1)[0] if method == "POST" else ""
        if method == "POST" and item == name:
            return {"id": 41, "name": name, "label": url.split("&label=", 1)[1]}
        if method == "POST":
            raise OSError("second upload failed")
        if method == "DELETE":
            assert url.endswith("/assets/41")
            return None
        raise AssertionError(method)

    with pytest.raises(ValueError, match="asset pair upload failed"):
        release_assets.upload_release_assets(tmp_path, "0.0.1", 9, "secret-token", request=request)
    assert [url for method, url in calls if method == "DELETE"] == [release_assets.API + "/releases/assets/41"]


def test_asset_upload_patch_failure_rolls_back_all_known_ids(tmp_path):
    name = _asset_fixture(tmp_path)
    assets = {
        name: {"id": 41, "name": name, "state": "uploaded", "size": (tmp_path / name).stat().st_size, "digest": "sha256:" + hashlib.sha256((tmp_path / name).read_bytes()).hexdigest()},
        name + ".sha256": {"id": 42, "name": name + ".sha256", "state": "uploaded", "size": (tmp_path / (name + ".sha256")).stat().st_size, "digest": "sha256:" + hashlib.sha256((tmp_path / (name + ".sha256")).read_bytes()).hexdigest()},
    }
    posted = []
    patches = 0
    calls = []

    def request(method, url, data=None, content_type="application/json"):
        nonlocal patches
        calls.append((method, url, data))
        if method == "GET" and url.endswith("/releases/9"):
            return {"tag_name": "v0.0.1", "draft": False}
        if method == "GET":
            return [] if not posted else list(assets.values())
        if method == "POST":
            item = Path(url.split("name=", 1)[1].split("&", 1)[0]).name
            posted.append(item)
            assets[item]["label"] = url.split("&label=", 1)[1]
            return assets[item]
        if method == "PATCH":
            patches += 1
            if patches == 2:
                raise OSError("patch failed")
            assets[name]["label"] = ""
            return {"id": 41}
        if method == "DELETE":
            return None
        raise AssertionError(method)

    with pytest.raises(ValueError, match="asset pair upload failed"):
        release_assets.upload_release_assets(tmp_path, "0.0.1", 9, "secret-token", request=request)
    assert assets[name]["label"] == ""
    assert [url.rsplit("/", 1)[1] for method, url, _ in calls if method == "DELETE"] == ["41", "42"]


def test_asset_upload_cleanup_failure_reports_owner_recovery_without_secret(tmp_path, capsys):
    name = _asset_fixture(tmp_path)
    own = {"id": 41, "name": name, "label": "invocation"}
    post_started = False

    def request(method, url, data=None, content_type="application/json"):
        nonlocal post_started
        if method == "GET" and url.endswith("/releases/9"):
            return {"tag_name": "v0.0.1", "draft": False}
        if method == "GET":
            return [own] if post_started else []
        if method == "POST":
            post_started = True
            own["label"] = url.split("&label=", 1)[1]
            raise OSError("network failure")
        if method == "DELETE":
            raise OSError("delete failure")
        raise AssertionError(method)

    with pytest.raises(ValueError, match="asset pair upload failed"):
        release_assets.upload_release_assets(tmp_path, "0.0.1", 9, "secret-token", request=request)
    output = capsys.readouterr().out
    assert "owner recovery required" in output
    assert "secret-token" not in output


def test_asset_upload_main_rejects_manual_dispatch_before_requests(tmp_path, monkeypatch):
    monkeypatch.setenv("GITHUB_EVENT_NAME", "workflow_dispatch")
    monkeypatch.setenv("GITHUB_REPOSITORY", release_assets.REPOSITORY)
    monkeypatch.setenv("GH_TOKEN", "secret-token")
    monkeypatch.setattr("sys.argv", ["release_assets.py", "--directory", str(tmp_path), "--version", "0.0.1"])
    with mock.patch.object(release_assets, "upload_release_assets") as upload:
        assert release_assets.main() == 1
    upload.assert_not_called()


def test_unsigned_packaging_preserves_preexisting_pair_and_cleans_only_new_archive(tmp_path):
    output = tmp_path / "release-dist"
    output.mkdir()
    archive = output / "Harflow-0.0.1-unsigned-arm64.zip"
    checksum = output / (archive.name + ".sha256")
    archive.write_bytes(b"existing archive")
    checksum.write_text("existing checksum\n")
    original = (archive.read_bytes(), checksum.read_bytes())
    commands = _Commands("")
    with mock.patch.object(release, "validate_bundle", return_value=("0.0.1", "0.0.1")), \
            mock.patch.object(release, "create_zip", side_effect=lambda app, destination, commands: Path(destination).write_bytes(b"staged archive")), \
            mock.patch.object(release, "verify_zip"):
        with pytest.raises(FileExistsError):
            release.unsigned_package(Path("Harflow.app"), ROOT, output, commands=commands)
    assert (archive.read_bytes(), checksum.read_bytes()) == original

    archive.unlink()
    with mock.patch.object(release, "validate_bundle", return_value=("0.0.1", "0.0.1")), \
            mock.patch.object(release, "create_zip", side_effect=lambda app, destination, commands: Path(destination).write_bytes(b"new archive")), \
            mock.patch.object(release, "verify_zip"):
        with pytest.raises(FileExistsError):
            release.unsigned_package(Path("Harflow.app"), ROOT, output, commands=commands)
    assert not archive.exists()
    assert checksum.read_bytes() == original[1]
