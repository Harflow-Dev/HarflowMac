from __future__ import annotations

import importlib.util
import json
import os
import signal
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest


SCRIPT = Path(__file__).parents[1] / "scripts" / "test-swift-package.py"
SPEC = importlib.util.spec_from_file_location("swift_package_runner", SCRIPT)
assert SPEC and SPEC.loader
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


NORMAL = "MainWindowFeatureTests.ActivitySuite/testNormal()"
PARAM = "MainWindowFeatureTests.ActivitySuite/NestedSuite/testParameterized()"
EXPECTED = [NORMAL, PARAM]


def record(kind: str, payload: dict) -> str:
    return json.dumps({"version": "6.3.0", "kind": kind, "payload": payload})


def passing_events(expected: list[str] = EXPECTED, *, schema: str = "6.3.0", omit: str | None = None,
                   skip: str | None = None, issue: str | None = None) -> list[str]:
    suites = sorted({runner.suite_identity(test_id) for test_id in expected})
    lines = [
        record("test", {"kind": "suite", "id": suite})
        for suite in suites
    ]
    definitions = []
    for test_id in expected:
        full = test_id + "/source.swift:1"
        definitions.append((test_id, full))
        lines.append(record("test", {
            "kind": "function", "id": full, "isParameterized": test_id == PARAM,
        }))
    lines.append(record("event", {
        "kind": "runStarted", "messages": [{"text": "Testing Library Version: 1902"}],
    }))
    for suite in suites:
        lines.append(record("event", {"kind": "testStarted", "testID": suite}))
    for test_id, full in definitions:
        if test_id == omit:
            continue
        lines.append(record("event", {"kind": "testStarted", "testID": full}))
        if test_id == PARAM:
            lines.append(record("event", {"kind": "testCaseStarted", "testID": full}))
            lines.append(record("event", {"kind": "testCaseEnded", "testID": full}))
        if test_id == skip:
            lines.append(record("event", {"kind": "testSkipped", "testID": full}))
        elif test_id == issue:
            lines.append(record("event", {
                "kind": "issueRecorded", "testID": full,
                "messages": [{"symbol": "expectation"}],
            }))
        else:
            lines.append(record("event", {
                "kind": "testEnded", "testID": full,
                "messages": [{"symbol": "pass"}],
            }))
    for suite in reversed(suites):
        lines.append(record("event", {
            "kind": "testEnded", "testID": suite, "messages": [{"symbol": "pass"}],
        }))
    lines.append(record("event", {
        "kind": "runEnded", "messages": [{
            "symbol": "pass",
            "text": f"Test run with {len(expected)} tests in {len(suites)} suites passed after 0.1 seconds.",
        }],
    }))
    if schema != "6.3.0":
        lines[0] = lines[0].replace('"6.3.0"', json.dumps(schema))
    return lines


def stdout_summary(test_count: int = 2, suite_count: int = 2) -> str:
    return (
        f"Test run with {test_count} tests in {suite_count} suites passed after 0.1 seconds.\n"
        "Test Suite 'legacy' passed.\n\tExecuted 0 tests, with 0 failures (0 unexpected)\n"
    )


def test_parse_discovery_rejects_empty_malformed_and_duplicate_ids() -> None:
    with pytest.raises(runner.RunnerError, match="no test identifiers"):
        runner.parse_list_output("\n")
    with pytest.raises(runner.RunnerError, match="unrecognized"):
        runner.parse_list_output("not-a-swift-test-id\n")
    with pytest.raises(runner.RunnerError, match="duplicate"):
        runner.parse_list_output(f"{NORMAL}\n{NORMAL}\n")


def test_suite_filters_are_disjoint_and_exhaustive_for_nested_and_parameterized_ids() -> None:
    ids = runner.parse_list_output(f"{NORMAL}\n{PARAM}\n")
    partitions = runner.build_partitions(ids, "suites")
    runner.validate_partitions(ids, partitions)
    assert len(partitions) == 2
    assert all(partition.filter_expression.startswith("^") for partition in partitions)
    assert runner.suite_identity(PARAM).endswith("/NestedSuite")

    overlapping = [
        runner.Partition("outer", tuple(ids), runner.suite_filter("MainWindowFeatureTests.ActivitySuite")),
        runner.Partition("nested", (PARAM,), runner.suite_filter(runner.suite_identity(PARAM))),
    ]
    with pytest.raises(runner.RunnerError, match="filter mismatch|exactly one"):
        runner.validate_partitions(ids, overlapping)


def test_validate_event_lines_accepts_parameterized_logical_counts() -> None:
    result = runner.validate_event_lines(passing_events(), EXPECTED)
    assert result.ok
    assert result.tests == 2
    assert result.suites == 2


def test_validate_event_lines_rejects_forged_counts_without_identity_coverage() -> None:
    lines = [
        line for line in passing_events()
        if not (PARAM in line and '"kind": "function"' in line)
    ]
    result = runner.validate_event_lines(lines, EXPECTED)
    assert not result.ok
    assert any("missing function definition" in failure for failure in result.failures)


@pytest.mark.parametrize(
    "kwargs, message",
    [
        ({"omit": PARAM}, "missing execution"),
        ({"skip": NORMAL}, "was skipped"),
        ({"issue": NORMAL}, "issue recorded"),
        ({"schema": "9.9.9"}, "unsupported event-stream schema"),
    ],
)
def test_validate_event_lines_rejects_incomplete_or_unsafe_streams(kwargs: dict, message: str) -> None:
    result = runner.validate_event_lines(passing_events(**kwargs), EXPECTED)
    assert not result.ok
    assert any(message in failure for failure in result.failures)


def test_validate_event_lines_rejects_unknown_event_records() -> None:
    lines = passing_events()
    lines.insert(-1, record("event", {"kind": "futureEvent", "testID": NORMAL}))
    result = runner.validate_event_lines(lines, EXPECTED)
    assert not result.ok
    assert any("unrecognized event kind" in failure for failure in result.failures)


def test_validate_event_lines_rejects_duplicate_unfinished_and_malformed_records() -> None:
    duplicate = passing_events()
    duplicate.insert(-1, duplicate[7])
    duplicate_result = runner.validate_event_lines(duplicate, EXPECTED)
    assert not duplicate_result.ok
    assert any("duplicate testStarted" in failure for failure in duplicate_result.failures)

    unfinished = passing_events()
    unfinished = [line for line in unfinished if '"testEnded"' not in line or PARAM not in line]
    unfinished_result = runner.validate_event_lines(unfinished, EXPECTED)
    assert not unfinished_result.ok
    assert any("unfinished test" in failure for failure in unfinished_result.failures)

    malformed = passing_events()[:-1] + ["not-json"]
    malformed_result = runner.validate_event_lines(malformed, EXPECTED)
    assert not malformed_result.ok
    assert any("malformed JSON" in failure or "no runEnded" in failure for failure in malformed_result.failures)


def test_validate_stdout_requires_passing_summary_and_zero_legacy_xctest() -> None:
    assert runner.validate_stdout(stdout_summary(), 2, 2) == []
    assert runner.validate_stdout(stdout_summary(1, 2), 2, 2)
    assert runner.validate_stdout(stdout_summary().replace("0 failures", "1 failures"), 2, 2)
    assert runner.validate_stdout("Test run with 0 tests in 0 suites passed after 0.1 seconds.\n", 0, 0)
    assert runner.validate_stdout("Test run with 2 tests in 2 suites passed after 0.1 seconds.\n", 2, 2)


def test_validate_event_lines_rejects_unknown_testing_library_version() -> None:
    lines = passing_events()
    lines[4] = lines[4].replace("Testing Library Version: 1902", "Testing Library Version: 9999")
    result = runner.validate_event_lines(lines, EXPECTED)
    assert not result.ok
    assert any("unsupported Testing Library version" in failure for failure in result.failures)


def make_fake_swift(tmp_path: Path, mode: str = "success") -> Path:
    tmp_path.mkdir(parents=True, exist_ok=True)
    fake = tmp_path / "fake-swift.py"
    payload = json.dumps(passing_events())
    script = textwrap.dedent(
        f"""
        #!/usr/bin/env python3
        import json, os, re, sys, time
        from pathlib import Path
        mode = {mode!r}
        args = sys.argv[1:]
        if args[:2] == ["build", "--build-tests"]:
            sys.exit(0)
        if args[:3] == ["test", "list", "--skip-build"]:
            print({NORMAL!r})
            print({PARAM!r})
            sys.exit(0)
        if args[:2] != ["test", "--skip-build"]:
            sys.exit(2)
        if mode == "timeout":
            time.sleep(10)
        event_path = Path(args[args.index("--event-stream-output-path") + 1])
        lines = json.loads({payload!r})
        if "--filter" in args:
            expression = args[args.index("--filter") + 1]
            all_ids = [{NORMAL!r}, {PARAM!r}]
            selected = [test_id for test_id in all_ids if re.search(expression, test_id)]
            selected_suites = set()
            for test_id in selected:
                suite = test_id.rsplit('/', 1)[0]
                while suite:
                    selected_suites.add(suite)
                    suite = suite.rsplit('/', 1)[0] if '/' in suite else ''
            selected_full = {{test_id + '/source.swift:1' for test_id in selected}}
            filtered = []
            for line in lines:
                item = json.loads(line)
                payload_item = item.get('payload', {{}})
                item_id = payload_item.get('id') or payload_item.get('testID')
                item_kind = payload_item.get('kind')
                if item_kind == 'runStarted':
                    filtered.append(line)
                elif item_kind == 'runEnded':
                    summary = f'Test run with {{len(selected)}} tests in {{len(selected_suites)}} suites passed after 0.1 seconds.'
                    payload_item['messages'][0]['text'] = summary
                    filtered.append(json.dumps(item))
                elif item_kind == 'suite':
                    if item_id in selected_suites:
                        filtered.append(line)
                elif item_kind == 'function':
                    if item_id in selected_full:
                        filtered.append(line)
                elif item_id in selected_suites or item_id in selected_full:
                    filtered.append(line)
            lines = filtered
        if mode == "partial":
            lines = [line for line in lines if {PARAM!r} not in line]
        if mode == "unknown-schema":
            lines[0] = lines[0].replace("6.3.0", "9.9.9")
        event_path.write_text("\\n".join(lines) + "\\n", encoding="utf-8")
        if mode == "nonzero":
            sys.exit(7)
        selected_count = 2
        selected_suites_count = 2
        if "--filter" in args:
            selected_count = len([test_id for test_id in [{NORMAL!r}, {PARAM!r}]
                                  if re.search(args[args.index("--filter") + 1], test_id)])
            selected_suites_count = 1 if selected_count == 1 and {NORMAL!r} in [
                test_id for test_id in [{NORMAL!r}, {PARAM!r}]
                if re.search(args[args.index("--filter") + 1], test_id)
            ] else 2
        print({stdout_summary()!r}.replace("2 tests in 2 suites", f"{{selected_count}} tests in {{selected_suites_count}} suites"), end="")
        sys.exit(0)
        """
    )
    fake.write_text(script.lstrip(), encoding="utf-8")
    fake.chmod(0o755)
    package = tmp_path / "package"
    package.mkdir()
    (package / "Package.swift").write_text("// fake package\n", encoding="utf-8")
    return fake


def test_run_package_rejects_zero_exit_partial_and_unknown_event_streams(tmp_path: Path) -> None:
    for mode, expected in [("partial", "missing function definition"), ("unknown-schema", "unsupported event-stream")]:
        fake = make_fake_swift(tmp_path / mode, mode)
        result = runner.run_package(
            str(fake.parent / "package"), "suites", swift=str(fake), partition_timeout=2,
        )
        assert not result.ok
        failures = [failure for partition in result.partitions for failure in partition.failures]
        assert any(expected in failure for failure in failures), (mode, result.failures, failures)


def test_run_package_suites_executes_each_discovered_suite_once(tmp_path: Path) -> None:
    fake = make_fake_swift(tmp_path / "success", "success")
    result = runner.run_package(
        str(fake.parent / "package"), "suites", swift=str(fake), partition_timeout=2,
    )
    assert result.ok, result.failures
    assert result.discovered_tests == 2
    assert result.discovered_suites == 2
    assert len(result.partitions) == 2
    assert [partition.expected_tests for partition in result.partitions] == [1, 1]
    assert all(partition.ok for partition in result.partitions)


def test_run_package_rejects_nonzero_partition_exit_even_with_valid_output(tmp_path: Path) -> None:
    fake = make_fake_swift(tmp_path / "nonzero", "nonzero")
    result = runner.run_package(
        str(fake.parent / "package"), "suites", swift=str(fake), partition_timeout=2,
    )
    assert not result.ok
    assert any("swift-test exited with 7" in failure
               for partition in result.partitions for failure in partition.failures)


def test_run_package_timeout_does_not_signal_unrelated_process(tmp_path: Path) -> None:
    unrelated = __import__("subprocess").Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        fake = make_fake_swift(tmp_path / "timeout", "timeout")
        result = runner.run_package(
            str(fake.parent / "package"), "suites", swift=str(fake), partition_timeout=0.1,
        )
        assert not result.ok
        assert any(partition.timed_out for partition in result.partitions)
        assert unrelated.poll() is None
    finally:
        unrelated.terminate()
        unrelated.wait(timeout=2)


def test_run_process_times_out_and_signals_only_its_owned_group(tmp_path: Path) -> None:
    child_pid = tmp_path / "child.pid"
    script = tmp_path / "sleep.py"
    script.write_text(
        "import os, signal, subprocess, sys, time\n"
        "child = subprocess.Popen([sys.executable, '-c', 'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'])\n"
        "open(sys.argv[1], 'w').write(str(child.pid))\n"
        "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n"
        "time.sleep(30)\n",
        encoding="utf-8",
    )
    stdout = tmp_path / "out.log"
    stderr = tmp_path / "err.log"
    child: int | None = None
    try:
        returncode, timed_out, _ = runner.run_process(
            [sys.executable, str(script), str(child_pid)], str(tmp_path), 0.5, str(stdout), str(stderr)
        )
        assert timed_out
        assert returncode is not None
        assert child_pid.exists(), "leader should have written its child PID before timeout"
        child = int(child_pid.read_text())
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            pytest.fail("runner left a TERM-ignoring child in its owned process group")
    finally:
        if child is not None:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass


@pytest.mark.parametrize(
    "probe_failure",
    [
        subprocess.CalledProcessError(1, ["ps"]),
        ValueError("malformed ps row"),
        subprocess.TimeoutExpired(["ps"], 0.1),
    ],
    ids=["ps-exit", "ps-malformed", "ps-timeout"],
)
def test_run_process_records_exit_probe_failures_and_cleans_owned_group(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, probe_failure: BaseException,
) -> None:
    original_run = runner.subprocess.run
    probe_calls = 0

    def fail_first_ps_probe(command, *args, **kwargs):
        nonlocal probe_calls
        if command[:2] == ["ps", "-axo"]:
            probe_calls += 1
            if probe_calls == 1:
                raise probe_failure
        return original_run(command, *args, **kwargs)

    monkeypatch.setattr(runner.subprocess, "run", fail_first_ps_probe)
    monkeypatch.setattr(runner, "TERM_GRACE_SECONDS", 0.01)
    stdout_path = tmp_path / "stdout.log"
    stderr_path = tmp_path / "stderr.log"
    returncode, timed_out, _ = runner.run_process(
        [sys.executable, "-c", "import time; time.sleep(30)"],
        cwd=str(tmp_path), timeout=2, stdout_path=str(stdout_path), stderr_path=str(stderr_path),
    )

    assert probe_calls >= 1
    assert returncode not in (None, 0)
    assert not timed_out
    assert "exit probe" in stderr_path.read_text(encoding="utf-8").lower()


HOSTED_NORMAL = runner.HOSTED_SUITE + "/testApproval()"
HOSTED_SECOND = runner.HOSTED_SUITE + "/testBlockedApproval()"


def hosted_partition(*ids: str) -> runner.Partition:
    return runner.Partition(
        runner.HOSTED_SUITE,
        tuple(ids),
        runner.suite_filter(runner.HOSTED_SUITE),
    )


def test_appkit_host_allowlist_is_exact_and_aggregate_is_rejected(tmp_path: Path) -> None:
    package = str(tmp_path / runner.HOSTED_PACKAGE)
    ordinary = runner.Partition("ordinary", (NORMAL,), runner.suite_filter(runner.suite_identity(NORMAL)))
    assert not runner.requires_appkit_host(package, ordinary)
    assert runner.requires_appkit_host(package, hosted_partition(HOSTED_NORMAL, HOSTED_SECOND))

    with pytest.raises(runner.RunnerError, match="unsupported package"):
        runner.requires_appkit_host(str(tmp_path / "OtherPackage"), hosted_partition(HOSTED_NORMAL))
    with pytest.raises(runner.RunnerError, match="aggregate"):
        runner.requires_appkit_host(
            package,
            runner.Partition("aggregate", (HOSTED_NORMAL,), None),
        )
    with pytest.raises(runner.RunnerError, match="inconsistent filter"):
        runner.requires_appkit_host(
            package,
            runner.Partition(runner.HOSTED_SUITE, (HOSTED_NORMAL,), "wrong-filter"),
        )
    with pytest.raises(runner.RunnerError, match="aggregate"):
        runner.requires_appkit_host(
            package,
            runner.Partition(runner.HOSTED_SUITE, (HOSTED_NORMAL, NORMAL), runner.suite_filter(runner.HOSTED_SUITE)),
        )


def test_appkit_probe_and_host_summary_keep_evidence_separate() -> None:
    assert runner.validate_legacy_probe("Test Suite 'legacy' passed.\nExecuted 0 tests, with 0 failures\n") == []
    assert runner.validate_legacy_probe("") == ["no legacy XCTest execution report on probe stdout"]
    assert runner.validate_legacy_probe("Executed 1 test, with 0 failures\n")
    assert runner.validate_legacy_probe("Executed 0 tests, with 1 failures\n")

    summary = "Test run with 2 tests in 1 suites passed after 0.1 seconds.\n"
    assert runner.validate_host_summary(summary, 2, 1) == []
    assert runner.validate_host_summary(
        "Test run with 1 test in 1 suites passed after 0.1 seconds.\n", 2, 1
    )
    assert runner.validate_host_summary(
        "Test run with 2 tests in 1 suites failed after 0.1 seconds.\n", 2, 1
    )


def _run_fake_host_partition(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    *,
    probe_stdout: str = "Executed 0 tests, with 0 failures\n",
    host_stderr: str | None = None,
    event_lines: list[str] | None = None,
    host_returncode: int = 0,
    host_timed_out: bool = False,
) -> tuple[runner.PartitionResult, list[tuple[list[str], float]]]:
    package = tmp_path / runner.HOSTED_PACKAGE
    package.mkdir()
    output = tmp_path / "logs"
    output.mkdir()
    partition = hosted_partition(HOSTED_NORMAL, HOSTED_SECOND)
    host = runner.AppKitHost("/fake-host", "/fake-tests.xctest", "/fake/Testing", {})
    calls: list[tuple[list[str], float]] = []
    events = event_lines if event_lines is not None else passing_events([HOSTED_NORMAL, HOSTED_SECOND])

    def fake_run_process(argv, cwd, timeout, stdout_path, stderr_path, env=None):
        del cwd, env
        calls.append((list(argv), timeout))
        if "--disable-swift-testing" in argv:
            Path(stdout_path).write_text(probe_stdout, encoding="utf-8")
            Path(stderr_path).write_text("legacy stderr\n", encoding="utf-8")
            return 0, False, 0.01
        Path(stdout_path).write_text("host stdout is intentionally separate\n", encoding="utf-8")
        Path(stderr_path).write_text(
            host_stderr if host_stderr is not None else
            "Test run with 2 tests in 1 suites passed after 0.1 seconds.\n",
            encoding="utf-8",
        )
        Path(argv[-1]).write_text("\n".join(events) + "\n", encoding="utf-8")
        return host_returncode, host_timed_out, 0.02

    monkeypatch.setattr(runner, "run_process", fake_run_process)
    result = runner._execute_partition(
        "swift", str(package), partition, 5, str(output), 1, host=host,
    )
    return result, calls


def test_appkit_partition_validates_real_probe_host_stderr_and_events(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    result, calls = _run_fake_host_partition(monkeypatch, tmp_path)
    assert result.ok, result.failures
    assert result.backend == "appkit-host"
    assert result.legacy_probe_returncode == 0
    assert len(calls) == 2
    assert "--disable-swift-testing" in calls[0][0]
    assert calls[1][0][0] == "/fake-host"
    assert result.stdout_log and "host stdout is intentionally separate" in Path(result.stdout_log).read_text()
    assert result.stderr_log and "Test run with 2 tests" in Path(result.stderr_log).read_text()


@pytest.mark.parametrize(
    ("kwargs", "expected"),
    [
        ({"probe_stdout": ""}, "no legacy XCTest execution report"),
        ({"probe_stdout": "Executed 1 test, with 0 failures\n"}, "nonzero tests or failures"),
        ({"host_stderr": ""}, "host stderr has no Swift Testing completion summary"),
        ({"event_lines": passing_events([HOSTED_NORMAL])}, "missing function definition"),
        ({"event_lines": passing_events([HOSTED_NORMAL, HOSTED_SECOND], skip=HOSTED_NORMAL)}, "was skipped"),
    ],
)
def test_appkit_partition_fails_closed_for_probe_summary_identity_and_skip_errors(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, kwargs: dict, expected: str,
) -> None:
    result, _ = _run_fake_host_partition(monkeypatch, tmp_path, **kwargs)
    assert not result.ok
    assert any(expected in failure for failure in result.failures), result.failures


def test_appkit_partition_nonzero_host_exit_remains_failure_with_valid_evidence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    result, _ = _run_fake_host_partition(monkeypatch, tmp_path, host_returncode=9)
    assert not result.ok
    assert any("appkit-host exited with 9" in failure for failure in result.failures)


def test_appkit_partition_shares_one_deadline_between_probe_and_host(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    result, calls = _run_fake_host_partition(monkeypatch, tmp_path, host_timed_out=True)
    assert not result.ok
    assert result.timed_out
    assert len(calls) == 2
    assert 0 < calls[1][1] < calls[0][1]
    assert any("timed out" in failure for failure in result.failures)


def _fake_host_setup_environment(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    include_bundle: bool = True,
    include_testing_image: bool = True,
    version_mismatch: bool = False,
    selected_swift_mismatch: bool = False,
    activation_receipt: str = "APPKIT_ACTIVATION active=true key=true",
    activation_returncode: int = 0,
) -> tuple[str, Path, dict]:
    package = tmp_path / runner.HOSTED_PACKAGE
    package.mkdir(parents=True)
    toolchain = tmp_path / "toolchain"
    compiler = toolchain / "swiftc"
    swift = toolchain / "swift"
    compiler.parent.mkdir()
    compiler.touch()
    swift.touch()
    platform = tmp_path / "platform"
    framework = platform / "Developer" / "Library" / "Frameworks" / "Testing.framework"
    modules = framework / "Modules" / "Testing.swiftmodule"
    modules.mkdir(parents=True)
    (modules / "arm64.swiftinterface").write_text("-user-module-version 1902\n", encoding="utf-8")
    testing_image = framework / "Testing"
    if include_testing_image:
        testing_image.touch()
    sdk = tmp_path / "sdk"
    build = tmp_path / "build"
    bundle = build / "MainWindowFeaturePackageTests.xctest" / "Contents" / "MacOS" / "MainWindowFeaturePackageTests"
    if include_bundle:
        bundle.parent.mkdir(parents=True)
        bundle.touch()
    outputs = {
        "compiler": str(compiler), "swift": str(swift), "platform": str(platform),
        "sdk": str(sdk), "build": str(build), "version": "Swift version 6.3.3",
        "testing": str(testing_image), "bundle": str(bundle),
    }

    def fake_run_process(argv, cwd, timeout, stdout_path, stderr_path, env=None):
        del cwd, timeout, env
        text = ""
        if argv[:2] == ["xcrun", "--find"]:
            text = outputs["compiler"] if argv[2] == "swiftc" else outputs["swift"]
        elif argv[:2] == ["xcrun", "--show-sdk-platform-path"]:
            text = outputs["platform"]
        elif argv[:2] == ["xcrun", "--show-sdk-path"]:
            text = outputs["sdk"]
        elif len(argv) >= 2 and argv[1] == "build":
            text = outputs["build"]
        elif argv[:2] == [str(compiler), "--version"]:
            text = outputs["version"]
        elif argv[:2] == [str(swift), "--version"]:
            text = "Swift version 6.3.4" if version_mismatch else outputs["version"]
        elif "--activation-self-test" in argv:
            text = activation_receipt
        Path(stdout_path).write_text(text + ("\n" if text else ""), encoding="utf-8")
        Path(stderr_path).write_text("", encoding="utf-8")
        return (activation_returncode if "--activation-self-test" in argv else 0), False, 0.01

    monkeypatch.setattr(runner, "run_process", fake_run_process)
    monkeypatch.setattr(runner.shutil, "which", lambda _: str(tmp_path / "other-swift") if selected_swift_mismatch else str(swift))
    return str(swift), package, outputs


def test_prepare_appkit_host_rejects_missing_bundle_and_testing_image(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    swift, package, _ = _fake_host_setup_environment(
        tmp_path / "missing-bundle", monkeypatch, include_bundle=False,
    )
    (tmp_path / "missing-bundle" / "logs").mkdir()
    with pytest.raises(runner.RunnerError, match="bundle is missing"):
        runner.prepare_appkit_host(swift, str(package), str(tmp_path / "missing-bundle" / "logs"),
                                   time.monotonic() + 10, {})

    swift, package, _ = _fake_host_setup_environment(
        tmp_path / "missing-testing", monkeypatch, include_testing_image=False,
    )
    (tmp_path / "missing-testing" / "logs").mkdir()
    with pytest.raises(runner.RunnerError, match="Testing Library 1902"):
        runner.prepare_appkit_host(swift, str(package), str(tmp_path / "missing-testing" / "logs"),
                                   time.monotonic() + 10, {})


def test_prepare_appkit_host_rejects_toolchain_version_and_path_mismatches(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    swift, package, _ = _fake_host_setup_environment(
        tmp_path / "version", monkeypatch, version_mismatch=True,
    )
    (tmp_path / "version" / "logs").mkdir()
    with pytest.raises(runner.RunnerError, match="versions differ"):
        runner.prepare_appkit_host(swift, str(package), str(tmp_path / "version" / "logs"),
                                   time.monotonic() + 10, {})

    swift, package, _ = _fake_host_setup_environment(
        tmp_path / "path", monkeypatch, selected_swift_mismatch=True,
    )
    (tmp_path / "path" / "logs").mkdir()
    with pytest.raises(runner.RunnerError, match="selected xcrun toolchain"):
        runner.prepare_appkit_host(swift, str(package), str(tmp_path / "path" / "logs"),
                                   time.monotonic() + 10, {})


@pytest.mark.parametrize(
    ("receipt", "returncode", "message"),
    [
        ("APPKIT_ACTIVATION active=false key=true", 0, "activation self-test"),
        ("APPKIT_ACTIVATION active=true key=false", 0, "activation self-test"),
        ("APPKIT_ACTIVATION active=true key=true", 7, "host-activation failed"),
    ],
)
def test_prepare_appkit_host_rejects_activation_readiness_and_nonzero_setup(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, receipt: str, returncode: int, message: str,
) -> None:
    root = tmp_path / "activation"
    swift, package, _ = _fake_host_setup_environment(
        root, monkeypatch, activation_receipt=receipt, activation_returncode=returncode,
    )
    (root / "logs").mkdir()
    with pytest.raises(runner.RunnerError, match=message):
        runner.prepare_appkit_host(swift, str(package), str(root / "logs"), time.monotonic() + 10, {})


def test_prepare_appkit_host_rejects_expired_setup_budget(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = tmp_path / "expired"
    swift, package, _ = _fake_host_setup_environment(root, monkeypatch)
    (root / "logs").mkdir()
    with pytest.raises(runner.RunnerError, match="setup exhausted the build budget"):
        runner.prepare_appkit_host(swift, str(package), str(root / "logs"), time.monotonic() - 1, {})
