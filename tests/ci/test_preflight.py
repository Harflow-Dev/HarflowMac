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


class NotaryFailureCommands(FakeCommands):
    """Inject a selected notary failure while retaining the normal probe flow."""

    def __init__(self, fail_on, error):
        super().__init__()
        self.fail_on = fail_on
        self.error = error

    def run(self, args, timeout=120, include_stderr=False):
        self.calls.append((list(args), timeout, include_stderr))
        if args[:3] == [preflight.XCRUN, "notarytool", self.fail_on]:
            raise self.error
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
            scratch_paths = [Path(call[0][2]).parent for call in commands.calls if call[0][0] == preflight.SECURITY and call[0][1] == "import"]
            self.assertEqual(len(scratch_paths), 1)
            self.assertFalse(scratch_paths[0].exists())

    def test_notary_command_failures_are_classified_by_command_and_keep_output_private(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory))
            cases = {
                "store-credentials": "notary-credential-validation",
                "history": "notary-history-access",
            }
            for command, stage in cases.items():
                error = subprocess.CalledProcessError(
                    1, [preflight.XCRUN, "notarytool", command],
                    output=b"::error::raw-secret-output", stderr=b"::error::raw-secret-error",
                )
                commands = NotaryFailureCommands(command, error)
                stdout, stderr = io.StringIO(), io.StringIO()
                with self.subTest(command=command), mock.patch.object(preflight, "validate_runner", return_value=Path(directory)), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    self.assertEqual(preflight.preflight(env, commands), 1)
                self.assertEqual(stderr.getvalue(), "")
                self.assertIn(f"preflight {stage} failed: command-failed\n", stdout.getvalue())
                self.assertNotIn("raw-secret", stdout.getvalue())
                self.assertNotIn("::error::", stdout.getvalue())
                self.assertNotIn(env["HARFLOW_NOTARY_APPLE_ID"], stdout.getvalue())
                self.assertNotIn(env["HARFLOW_NOTARY_APP_PASSWORD"], stdout.getvalue())
                expected = [
                    "preflight runner-validation ok",
                    "preflight identity-import ok",
                    "preflight probe-signing ok",
                    f"preflight {stage} failed: command-failed",
                    "preflight cleanup ok",
                ]
                if command == "history":
                    expected.insert(3, "preflight notary-credential-validation ok")
                self.assertEqual(stdout.getvalue().splitlines(), expected)
                restore = [call for call in commands.calls if call[0][:4] == [preflight.SECURITY, "list-keychains", "-d", "user"] and "-s" in call[0]]
                self.assertEqual(restore[-1][0], [preflight.SECURITY, "list-keychains", "-d", "user", "-s", "/Users/runner/login.keychain-db"])
                scratch_paths = [Path(call[0][2]).parent for call in commands.calls if call[0][0] == preflight.SECURITY and call[0][1] == "import"]
                self.assertEqual(len(scratch_paths), 1)
                self.assertFalse(scratch_paths[0].exists())

    def test_notary_failure_categories_are_conservative_and_have_precedence(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory))
            cases = (
                (subprocess.TimeoutExpired([preflight.XCRUN], 1, output=b"401", stderr=b"503 network"), "timed-out"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output="HTTP status code 401", stderr=None), "authentication-rejected"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output=b"HTTP status code: 403", stderr=b""), "authorization-rejected"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output=None, stderr=b"HTTP status 503"), "service-unavailable"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output=None, stderr="Could not resolve host"), "network-failure"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output="HTTP status code 401; HTTP status code 403; HTTP status code 503; network", stderr=None), "authentication-rejected"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output="HTTP status code 401", stderr="HTTP status code 403"), "authentication-rejected"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output="HTTP status code 403", stderr="HTTP status code 503"), "authorization-rejected"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output="HTTP status code 503", stderr="Could not resolve host"), "service-unavailable"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output="HTTP status code 401", stderr="generic failure"), "authentication-rejected"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output="401", stderr="generic failure"), "command-failed"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output=None, stderr=None), "command-failed"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output="hTtP STATUS CODE 403", stderr="COULD NOT RESOLVE HOST"), "authorization-rejected"),
            )
            for error, category in cases:
                commands = NotaryFailureCommands("store-credentials", error)
                stdout, stderr = io.StringIO(), io.StringIO()
                with self.subTest(category=category), mock.patch.object(preflight, "validate_runner", return_value=Path(directory)), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    self.assertEqual(preflight.preflight(env, commands), 1)
                self.assertIn(f"preflight notary-credential-validation failed: {category}\n", stdout.getvalue())
                self.assertEqual(stderr.getvalue(), "")

    def test_history_failures_use_category_suffix(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory))
            cases = (
                (subprocess.TimeoutExpired([preflight.XCRUN], 1, output=b"", stderr=b""), "timed-out"),
                (subprocess.CalledProcessError(1, [preflight.XCRUN], output="HTTP STATUS CODE 503", stderr=None), "service-unavailable"),
            )
            for error, category in cases:
                commands = NotaryFailureCommands("history", error)
                stdout, stderr = io.StringIO(), io.StringIO()
                with self.subTest(category=category), mock.patch.object(preflight, "validate_runner", return_value=Path(directory)), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    self.assertEqual(preflight.preflight(env, commands), 1)
                self.assertIn(f"preflight notary-history-access failed: {category}\n", stdout.getvalue())
                self.assertEqual(stderr.getvalue(), "")

    def test_probe_failure_does_not_get_notary_category_suffix(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory)); commands = FakeCommands(); original = commands.run

            def run(args, timeout=120, include_stderr=False):
                if args[:3] == [preflight.CODESIGN, "--verify", "--strict"]:
                    raise subprocess.CalledProcessError(1, args, output="HTTP status code 401", stderr="Could not resolve host")
                return original(args, timeout, include_stderr)

            commands.run = run
            stdout, stderr = io.StringIO(), io.StringIO()
            with mock.patch.object(preflight, "validate_runner", return_value=Path(directory)), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(preflight.preflight(env, commands), 1)
            self.assertIn("preflight probe-signing failed\n", stdout.getvalue())
            self.assertNotIn("probe-signing failed:", stdout.getvalue())
            self.assertEqual(stderr.getvalue(), "")

    def test_invalid_notary_json_and_schema_fail_at_response_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory))
            values = ("not-json", "[]", "null", '"string"', '{"history": null}')
            for history in values:
                commands = FakeCommands()
                original = commands.run

                def run(args, timeout=120, include_stderr=False, original=original, history=history):
                    result = original(args, timeout, include_stderr)
                    if args[:3] == [preflight.XCRUN, "notarytool", "history"]:
                        return history
                    return result

                commands.run = run
                stdout, stderr = io.StringIO(), io.StringIO()
                with self.subTest(history=history), mock.patch.object(preflight, "validate_runner", return_value=Path(directory)), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    self.assertEqual(preflight.preflight(env, commands), 1)
                self.assertIn("preflight notary-response-validation failed: invalid-response\n", stdout.getvalue())
                self.assertEqual(stderr.getvalue(), "")

    def test_history_write_failure_reports_plain_stage_without_exception_details(self):
        with tempfile.TemporaryDirectory() as directory:
            env = valid_env(Path(directory)); commands = FakeCommands(); original_open = preflight.os.open

            def open_file(path, flags, mode=0o777, *, original=original_open):
                if str(path).endswith("history.json"):
                    raise OSError("secret filesystem detail")
                return original(path, flags, mode)

            stdout, stderr = io.StringIO(), io.StringIO()
            with mock.patch.object(preflight, "validate_runner", return_value=Path(directory)), mock.patch.object(preflight.os, "open", side_effect=open_file), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(preflight.preflight(env, commands), 1)
            self.assertIn("preflight notary-history-access failed\n", stdout.getvalue())
            self.assertNotIn("secret filesystem detail", stdout.getvalue())
            self.assertEqual(stderr.getvalue(), "")

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
        self.assertIs(run.call_args.kwargs["stdin"], preflight.subprocess.DEVNULL)
        self.assertEqual(run.call_args.kwargs["env"]["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")

    def test_preflight_source_has_no_notary_submission_or_raw_exception_output(self):
        source = (ROOT / "scripts/ci/apple_signing_preflight.py").read_text()
        self.assertNotIn("notarytool', 'submit", source)
        self.assertNotIn("print(e", source)
        self.assertIn("def sanitized_exception", source)


if __name__ == "__main__":
    unittest.main()
