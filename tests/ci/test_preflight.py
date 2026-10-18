import base64
import importlib.util
import io
import contextlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).parents[2]
SPEC = importlib.util.spec_from_file_location("preflight", ROOT / "scripts/ci/apple_signing_preflight.py")
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)


def valid_env(root):
    return {
        "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64",
        "GITHUB_REPOSITORY": "Harflow-Dev/HarflowMac", "GITHUB_REF": "refs/heads/main", "RUNNER_TEMP": str(root.resolve()),
        "HARFLOW_DEVELOPER_ID_P12_BASE64": base64.b64encode(b"p12").decode(), "HARFLOW_DEVELOPER_ID_P12_PASSWORD": "p12-secret",
        "HARFLOW_NOTARY_APPLE_ID": "apple-id", "HARFLOW_NOTARY_APP_PASSWORD": "notary-secret", "HARFLOW_APPLE_TEAM_ID": "A1B2C3D4E5",
    }


class FakeCommands:
    def __init__(self, fail_at=None, timeout_at=None):
        self.calls = []
        self.fail_at = fail_at
        self.timeout_at = timeout_at

    def run(self, args, timeout=120, include_stderr=False):
        self.calls.append((list(args), timeout, include_stderr))
        if self.timeout_at and self.timeout_at in args:
            raise subprocess.TimeoutExpired(args, timeout, output="fake-secret-out", stderr="fake-secret-err")
        if self.fail_at and self.fail_at in args:
            raise subprocess.CalledProcessError(1, args)
        if args[:3] == [preflight.SECURITY, "list-keychains", "-d"] and "-s" not in args:
            return "/Users/runner/login.keychain-db\n"
        if args[:3] == [preflight.SECURITY, "find-identity", "-v"]:
            return '  1) 0123456789abcdef0123456789abcdef01234567 "Developer ID Application: Harflow (A1B2C3D4E5)"\n'
        if args[:3] == [preflight.CODESIGN, "--display", "--verbose=4"]:
            return "Authority=Developer ID Application: Harflow (A1B2C3D4E5)\nTeamIdentifier=A1B2C3D4E5\n"
        if args[:3] == [preflight.XCRUN, "notarytool", "history"]:
            return '{"history": []}'
        return ""


class PreflightTests(unittest.TestCase):
    def test_valid_runner_control_accepts_canonical_root(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory))
            with mock.patch.object(preflight.sys, "platform", "darwin"), mock.patch.object(preflight.platform, "machine", return_value="arm64"), mock.patch.object(preflight.platform, "mac_ver", return_value=("26.0", (), ())):
                self.assertEqual(preflight.validate_runner(env), Path(directory).resolve())

    def test_workflow_scope_is_manual_read_only_and_preflight_only(self):
        workflow = (ROOT / ".github/workflows/apple-signing-preflight.yml").read_text()
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("permissions: {}", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertNotIn("upload-artifact", workflow)
        self.assertNotIn("submit", workflow)
        self.assertNotIn("release", workflow)

    def test_team_id_is_scoped_as_secret_not_plain_environment_variable(self):
        workflow = (ROOT / ".github/workflows/apple-signing-preflight.yml").read_text()
        self.assertIn("HARFLOW_APPLE_TEAM_ID: ${{ secrets.HARFLOW_APPLE_TEAM_ID }}", workflow)
        self.assertNotIn("HARFLOW_APPLE_TEAM_ID: ${{ vars.HARFLOW_APPLE_TEAM_ID }}", workflow)

    def test_rejects_wrong_runner_before_any_command(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory)); env["GITHUB_REF"] = "refs/heads/feature"
            commands = FakeCommands()
            with mock.patch.object(preflight.sys, "platform", "darwin"), mock.patch.object(preflight.platform, "machine", return_value="arm64"), mock.patch.object(preflight.platform, "mac_ver", return_value=("26.0", (), ())):
                self.assertEqual(preflight.preflight(env, commands), 1)
            self.assertEqual(commands.calls, [])

    def test_guard_matrix_rejects_before_commands(self):
        cases = {
            "missing-secret": lambda e: e.pop("HARFLOW_NOTARY_APP_PASSWORD"),
            "bad-team": lambda e: e.__setitem__("HARFLOW_APPLE_TEAM_ID", "bad"),
            "bad-repository": lambda e: e.__setitem__("GITHUB_REPOSITORY", "other/repo"),
            "bad-host": lambda e: e.__setitem__("RUNNER_ENVIRONMENT", "self-hosted"),
            "bad-ref": lambda e: e.__setitem__("GITHUB_REF", "refs/heads/release"),
            "bad-arch": lambda e: e.__setitem__("RUNNER_ARCH", "X64"),
        }
        for name, mutate in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                env = valid_env(Path(directory)); mutate(env); commands = FakeCommands()
                with mock.patch.object(preflight.sys, "platform", "darwin"), mock.patch.object(preflight.platform, "machine", return_value="arm64"), mock.patch.object(preflight.platform, "mac_ver", return_value=("26.0", (), ())):
                    self.assertEqual(preflight.preflight(env, commands), 1)
                self.assertEqual(commands.calls, [])

    def test_decode_p12_is_strict_and_capped(self):
        self.assertEqual(preflight.decode_p12("  " + base64.b64encode(b"abc").decode() + "\n"), b"abc")
        for value in ("%%%", base64.b64encode(b"x" * (preflight.MAX_DECODED_P12_BYTES + 1)).decode(), "A" * (preflight.MAX_ENCODED_P12_BYTES + 1)):
            with self.assertRaises(preflight.PreflightError):
                preflight.decode_p12(value)

    def test_signing_identity_rejects_wrong_or_ambiguous_team(self):
        good = '  1) 0123456789abcdef0123456789abcdef01234567 "Developer ID Application: Harflow (A1B2C3D4E5)"\n'
        self.assertEqual(preflight.signing_identity(good, "A1B2C3D4E5"), "0123456789abcdef0123456789abcdef01234567")
        for output in (good + good, good.replace("A1B2C3D4E5", "ZZZZZZZZZZ"), good.replace("Developer ID Application", "Developer ID Installer")):
            with self.assertRaises(preflight.PreflightError):
                preflight.signing_identity(output, "A1B2C3D4E5")

    def test_successful_probe_flow_uses_explicit_keychain_and_never_prints_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory)); commands = FakeCommands()
            output = io.StringIO()
            with mock.patch.object(preflight.sys, "platform", "darwin"), mock.patch.object(preflight.platform, "machine", return_value="arm64"), mock.patch.object(preflight.platform, "mac_ver", return_value=("26.0", (), ())), mock.patch("sys.stdout", output):
                self.assertEqual(preflight.preflight(env, commands), 0)
            flat = " ".join(" ".join(call[0]) for call in commands.calls)
            self.assertIn("--keychain", flat)
            self.assertNotIn(" -A ", flat)
            self.assertNotIn("p12-secret", output.getvalue())
            self.assertNotIn("notary-secret", output.getvalue())
            self.assertTrue(any(call[0][:3] == [preflight.SECURITY, "delete-keychain", call[0][2]] for call in commands.calls))
            import_paths = [Path(call[0][2]) for call in commands.calls if call[0][0] == preflight.SECURITY and call[0][1] == "import"]
            self.assertEqual(len(import_paths), 1)
            self.assertFalse(import_paths[0].exists())

    def test_timeout_restores_original_search_list_and_cleans_up_without_leaking_output(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory)); commands = FakeCommands(timeout_at=preflight.XCRUN)
            stdout, stderr = io.StringIO(), io.StringIO()
            with mock.patch.object(preflight, "validate_runner", return_value=Path(directory)), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(preflight.preflight(env, commands), 1)
            restore = [call for call in commands.calls if call[0][:4] == [preflight.SECURITY, "list-keychains", "-d", "user"] and "-s" in call[0]]
            self.assertEqual(restore[-1][0], [preflight.SECURITY, "list-keychains", "-d", "user", "-s", "/Users/runner/login.keychain-db"])
            self.assertTrue(any(call[0][0] == preflight.SECURITY and call[0][1] == "delete-keychain" for call in commands.calls))

    def test_notary_failure_and_cleanup_failure_are_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory))
            for failure in ("notarytool", "delete-keychain"):
                commands = FakeCommands(fail_at=failure)
                with self.subTest(failure=failure), mock.patch.object(preflight, "validate_runner", return_value=Path(directory)):
                    self.assertEqual(preflight.preflight(env, commands), 1)

    def test_post_sign_identity_mismatch_fails_without_submit(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory)); commands = FakeCommands()
            original = commands.run
            def run(args, timeout=120, include_stderr=False):
                result = original(args, timeout, include_stderr)
                if args[:3] == [preflight.CODESIGN, "--display", "--verbose=4"]:
                    return "Authority=Developer ID Application: Wrong (A1B2C3D4E5)\nTeamIdentifier=WRONG\n"
                return result
            commands.run = run
            with mock.patch.object(preflight, "validate_runner", return_value=Path(directory)):
                self.assertEqual(preflight.preflight(env, commands), 1)
            self.assertFalse(any(call[0][0] == preflight.XCRUN and "submit" in call[0] for call in commands.calls))

    def test_partial_prepend_failure_still_restores_exact_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory)); commands = FakeCommands()
            original_run = commands.run
            failed = {"done": False}
            def run(args, timeout=120, include_stderr=False):
                if args[:5] == [preflight.SECURITY, "list-keychains", "-d", "user", "-s"] and not failed["done"]:
                    failed["done"] = True; commands.calls.append((list(args), timeout, include_stderr)); raise subprocess.CalledProcessError(1, args)
                return original_run(args, timeout, include_stderr)
            commands.run = run
            with mock.patch.object(preflight, "validate_runner", return_value=Path(directory)):
                self.assertEqual(preflight.preflight(env, commands), 1)
            self.assertTrue(any(call[0] == [preflight.SECURITY, "list-keychains", "-d", "user", "-s", "/Users/runner/login.keychain-db"] for call in commands.calls))

    def test_early_failure_before_snapshot_does_not_restore_or_delete(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory)); commands = FakeCommands()
            with mock.patch.object(preflight, "validate_runner", return_value=Path(directory)), mock.patch.object(preflight, "decode_p12", side_effect=preflight.PreflightError()):
                self.assertEqual(preflight.preflight(env, commands), 1)
            self.assertFalse(any(call[0][1] == "list-keychains" for call in commands.calls))
            self.assertFalse(any(call[0][1] == "delete-keychain" for call in commands.calls))

    def test_commands_captures_stderr_and_bounds_timeout(self):
        env = {"HOME": "/tmp/home", "TMPDIR": "/tmp", "LANG": "C"}
        commands = preflight.Commands(env)
        completed = subprocess.CompletedProcess(["tool"], 0, stdout="out", stderr="secret")
        with mock.patch.object(preflight.subprocess, "run", return_value=completed) as run:
            self.assertEqual(commands.run(["tool"], timeout=7, include_stderr=True), "outsecret")
        self.assertEqual(run.call_args.kwargs["timeout"], 7)
        self.assertEqual(run.call_args.kwargs["env"]["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")


if __name__ == "__main__":
    unittest.main()
