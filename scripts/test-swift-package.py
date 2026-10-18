#!/usr/bin/env python3
"""Trustworthy Swift Testing guard for one Swift package.

Builds the package's tests once, discovers every Swift Testing test identifier
with ``swift test list --skip-build``, and runs them either as one guarded
aggregate process (``--mode aggregate``) or as one fresh process per suite
(``--mode suites``). A partition passes only when its process exits zero, its
event stream (schema 6.3.0 as probed; Testing Library 1902) defines every
discovered identity exactly once and executes each exactly once with no
recorded issues, no failed suites and no skips, the legacy XCTest run reports
0 tests and 0 failures, and the human completion summary reports the exact
discovered logical count. Everything unrecognized fails the run: unsupported
event schemas, unknown toolchain versions, malformed listings, duplicate or
empty discovery, filters that do not partition the discovery set exactly, and
missing or truncated streams. Exit-code-only acceptance is never a fallback.

Probed facts this encodes (Swift 6.3.3 / Testing Library 1902): list output is one target-qualified
identifier per line with no source suffix; event-stream definition ids carry a
final source-location segment that must be stripped for identity comparison;
parameterized functions count once regardless of argument cases; disabled tests
count once and emit an explicit testSkipped; suite start/end events ride the
same kinds as functions but on suite ids and do not inflate coverage; an
anchored ``^<suite>/[^/]+\\([^/]*\\)(/[^/]*)?$`` filter selects exactly one
suite's functions, disjoint from nested suites, while suite definitions (no
parentheses) and XCTest methods never match.

Standard-library Python 3.9+ only. Regression tests drive a fake Swift executable.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from typing import Sequence

__all__ = [
    "AGGREGATE_TIMEOUT_SECONDS",
    "BUILD_TIMEOUT_SECONDS",
    "DISCOVERY_TIMEOUT_SECONDS",
    "SCHEMA_VERSIONS",
    "SUITE_TIMEOUT_SECONDS",
    "TESTING_LIBRARY_VERSIONS",
    "Partition",
    "PartitionResult",
    "RunnerError",
    "RunnerResult",
    "ValidationResult",
    "build_partitions",
    "main",
    "parse_list_output",
    "run_package",
    "suite_filter",
    "suite_identity",
    "validate_event_lines",
    "validate_partitions",
    "validate_stdout",
]

SCHEMA_VERSIONS = {"6.3.0"}
TESTING_LIBRARY_VERSIONS = {"1902"}

BUILD_TIMEOUT_SECONDS = 600
DISCOVERY_TIMEOUT_SECONDS = 600
SUITE_TIMEOUT_SECONDS = 300
AGGREGATE_TIMEOUT_SECONDS = 1200
TERM_GRACE_SECONDS = 5.0

# Identifier grammar, deliberately minimal: anything outside it is rejected, not
# escaped. Suite identity is everything before the last slash of a discovered
# id; the first segment is the dot-joined target and suite (or nested suites
# beyond further slashes), and the final segment is a function name with
# parentheses, which is what keeps suite definitions and XCTest methods out.
_SEGMENT = r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*"
_FUNCTION = r"[A-Za-z0-9_]+\([A-Za-z0-9_:]*\)"
DISCOVERED_ID_PATTERN = re.compile(
    rf"^(?P<suite>{_SEGMENT}(?:/{_SEGMENT})*)/(?P<function>{_FUNCTION})$"
)
SUITE_ID_PATTERN = re.compile(rf"^{_SEGMENT}(?:/{_SEGMENT})*$")
FUNCTION_ID_PATTERN = re.compile(
    rf"^(?P<base>{_SEGMENT}(?:/{_SEGMENT})*/{_FUNCTION})(?:/(?P<suffix>[^/]*))?$"
)
FILTER_TAIL = r"/[^/]+\([^/]*\)(?:/[^/]*)?$"

DEFINITION_KINDS = {"suite", "function"}
EVENT_KINDS = {
    "runStarted",
    "testStarted",
    "testEnded",
    "testCaseStarted",
    "testCaseEnded",
    "testSkipped",
    "issueRecorded",
    "runEnded",
}
COMPLETION_SUMMARY = re.compile(
    r"^Test run with (\d+) tests? in (\d+) suites? (passed|failed) after .+ seconds\.$"
)
STDOUT_SUMMARY = re.compile(
    r"Test run with (\d+) tests? in (\d+) suites? (passed|failed) after [0-9.]+ seconds"
)
XCTEST_EXECUTED = re.compile(r"Executed (\d+) tests?, with (\d+) failures")
LIBRARY_VERSION = re.compile(r"Testing Library Version: (\S+)")


class RunnerError(Exception):
    """A fail-closed discovery, partitioning or execution error."""


@dataclass(frozen=True)
class Partition:
    """One guarded swift test process: the ids it must run and its filter."""

    name: str
    ids: tuple[str, ...]
    filter_expression: str | None


@dataclass
class ValidationResult:
    """Outcome of validating one partition's event stream."""

    ok: bool
    failures: list[str] = field(default_factory=list)
    tests: int | None = None
    suites: int | None = None
    testing_library_version: str | None = None
    skipped: list[str] = field(default_factory=list)


@dataclass
class PartitionResult:
    """Recorded evidence for one executed partition."""

    name: str
    filter_expression: str | None
    expected_tests: int
    returncode: int | None = None
    timed_out: bool = False
    duration_seconds: float = 0.0
    ok: bool = False
    failures: list[str] = field(default_factory=list)
    suites: int | None = None
    skipped: list[str] = field(default_factory=list)
    stdout_log: str | None = None
    stderr_log: str | None = None
    events_log: str | None = None


@dataclass
class RunnerResult:
    """Final manifest for one package run."""

    ok: bool
    package: str
    mode: str
    output_dir: str
    discovered_tests: int = 0
    discovered_suites: int = 0
    partitions: list[PartitionResult] = field(default_factory=list)
    failures: list[str] = field(default_factory=list)
    manifest_path: str | None = None


def suite_identity(test_id: str) -> str:
    """Return everything before the last slash of a discovered test id."""
    head, _, tail = test_id.rpartition("/")
    if not head or not tail:
        raise RunnerError(f"not a target-qualified test identifier: {test_id!r}")
    return head


def suite_filter(suite: str) -> str:
    """Return the probed anchored filter that selects exactly one suite's functions.

    The function parentheses exclude suite definitions; the optional final
    segment matches Swift Testing execution ids' source-location suffix.
    """
    return "^" + re.escape(suite) + FILTER_TAIL


def parse_list_output(text: str) -> list[str]:
    """Parse ``swift test list --skip-build`` stdout into discovered test ids.

    Rejects any nonblank line outside the identifier grammar, duplicate ids,
    and empty discovery.
    """
    ids: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        if not line.strip():
            continue
        if not DISCOVERED_ID_PATTERN.match(line):
            raise RunnerError(f"unrecognized test identifier in discovery output: {line!r}")
        if line in seen:
            raise RunnerError(f"duplicate discovered test identifier: {line!r}")
        seen.add(line)
        ids.append(line)
    if not ids:
        raise RunnerError("discovery produced no test identifiers")
    return ids


def build_partitions(ids: Sequence[str], mode: str) -> list[Partition]:
    """Group discovered ids into guarded partitions for the given mode."""
    if mode not in ("suites", "aggregate"):
        raise RunnerError(f"unsupported mode: {mode!r}")
    if mode == "aggregate":
        return [Partition("aggregate", tuple(sorted(ids)), None)]
    groups: dict[str, list[str]] = {}
    for test_id in sorted(ids):
        groups.setdefault(suite_identity(test_id), []).append(test_id)
    return [
        Partition(suite, tuple(members), suite_filter(suite))
        for suite, members in sorted(groups.items())
    ]


def validate_partitions(ids: Sequence[str], partitions: Sequence[Partition]) -> None:
    """Prove the partition filters match the discovery set disjointly and exhaustively."""
    all_ids = list(ids)
    coverage: dict[str, int] = {test_id: 0 for test_id in all_ids}
    for partition in partitions:
        partition_ids = set(partition.ids)
        unknown = partition_ids - set(all_ids)
        if unknown:
            raise RunnerError(
                f"partition {partition.name!r} contains ids absent from discovery: "
                f"{sorted(unknown)!r}"
            )
        if partition.filter_expression is None:
            matched = set(all_ids)
        else:
            pattern = re.compile(partition.filter_expression)
            matched = {test_id for test_id in all_ids if pattern.search(test_id)}
        if matched != partition_ids:
            missing = sorted(matched - partition_ids)
            extra = sorted(partition_ids - matched)
            raise RunnerError(
                f"partition {partition.name!r} filter mismatch: "
                f"unmatched-by-filter={missing!r} not-in-discovery-match={extra!r}"
            )
        for test_id in partition.ids:
            coverage[test_id] += 1
    miscovered = sorted(test_id for test_id, count in coverage.items() if count != 1)
    if miscovered:
        raise RunnerError(
            f"discovered tests not covered by exactly one partition: {miscovered!r}"
        )


def _first_message(payload: dict) -> tuple[object, object]:
    messages = payload.get("messages")
    if not isinstance(messages, list) or not messages or not isinstance(messages[0], dict):
        return None, None
    return messages[0].get("symbol"), messages[0].get("text")


def validate_event_lines(lines: Sequence[str], expected_ids: Sequence[str]) -> ValidationResult:
    """Validate one partition's JSONL event stream against its discovered identities.

    Every expected identity must be defined exactly once (source-suffix
    stripped), and each must finish exactly once: one started plus one passed
    ended, or one explicit skip — a skip is accounted for coverage but is a
    validation failure. Suite definition/start/end events are tracked but never
    inflate coverage. runStarted must come first, runEnded last and passing,
    with logical test and suite counts equal to the expected set and the suite
    definitions.
    """
    result = ValidationResult(ok=False)
    failures = result.failures
    expected = list(expected_ids)
    expected_set = set(expected)

    suite_defs: dict[str, int] = {}
    function_defs: dict[str, dict] = {}
    base_to_full: dict[str, str] = {}
    function_state: dict[str, dict] = {}
    suite_state: dict[str, dict] = {}
    run_started = False
    library_version_seen = False
    summary_text: str | None = None
    summary_symbol: str | None = None
    saw_event = False
    saw_run_ended = False

    for index, line in enumerate(lines, 1):
        if not line.strip():
            failures.append(f"line {index}: blank line in event stream")
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            failures.append(f"line {index}: malformed JSON ({error})")
            continue
        if not isinstance(record, dict):
            failures.append(f"line {index}: event stream record is not an object")
            continue
        version = record.get("version")
        if version not in SCHEMA_VERSIONS:
            failures.append(
                f"line {index}: unsupported event-stream schema version {version!r} "
                f"(supported: {sorted(SCHEMA_VERSIONS)})"
            )
        kind = record.get("kind")
        payload = record.get("payload")
        if kind not in ("test", "event") or not isinstance(payload, dict):
            failures.append(f"line {index}: malformed record (kind={kind!r})")
            continue
        payload_kind = payload.get("kind")

        if kind == "test":
            if saw_event:
                failures.append(f"line {index}: test definition after events began")
                continue
            identifier = payload.get("id")
            if not isinstance(identifier, str):
                failures.append(f"line {index}: definition without a string id")
                continue
            if payload_kind == "suite":
                if not SUITE_ID_PATTERN.match(identifier) or DISCOVERED_ID_PATTERN.match(identifier):
                    failures.append(f"line {index}: unrecognized suite definition id {identifier!r}")
                    continue
                if identifier in suite_defs:
                    failures.append(f"line {index}: duplicate suite definition {identifier!r}")
                    continue
                suite_defs[identifier] = index
                suite_state[identifier] = {"started": 0, "ended": 0, "end_symbol": None}
            elif payload_kind == "function":
                match = FUNCTION_ID_PATTERN.match(identifier)
                if not match:
                    failures.append(
                        f"line {index}: unrecognized function definition id {identifier!r}"
                    )
                    continue
                base = match.group("base")
                if base not in expected_set:
                    failures.append(
                        f"line {index}: unexpected function definition {base!r} "
                        "(not in discovery)"
                    )
                if base in base_to_full:
                    failures.append(
                        f"line {index}: duplicate function definition for {base!r}"
                    )
                    continue
                parameterized = payload.get("isParameterized")
                if not isinstance(parameterized, bool):
                    failures.append(
                        f"line {index}: function definition {base!r} lacks boolean "
                        "isParameterized"
                    )
                base_to_full[base] = identifier
                function_defs[identifier] = {"base": base, "parameterized": parameterized}
                function_state[base] = {
                    "started": 0,
                    "ended": 0,
                    "skipped": 0,
                    "case_started": 0,
                    "case_ended": 0,
                }
            else:
                failures.append(f"line {index}: unknown test definition kind {payload_kind!r}")
            continue

        saw_event = True
        if saw_run_ended:
            failures.append(f"line {index}: event after runEnded")
            continue
        if payload_kind not in EVENT_KINDS:
            failures.append(
                f"line {index}: unrecognized event kind {payload_kind!r} "
                f"(supported: {sorted(EVENT_KINDS)})"
            )
            continue

        if payload_kind == "runStarted":
            if run_started:
                failures.append(f"line {index}: duplicate runStarted")
                continue
            run_started = True
            for message in payload.get("messages") or []:
                if not isinstance(message, dict):
                    continue
                match = LIBRARY_VERSION.search(str(message.get("text", "")))
                if match:
                    library_version_seen = True
                    version_text = match.group(1)
                    result.testing_library_version = version_text
                    if version_text not in TESTING_LIBRARY_VERSIONS:
                        failures.append(
                            f"line {index}: unsupported Testing Library version "
                            f"{version_text!r} (supported: "
                            f"{sorted(TESTING_LIBRARY_VERSIONS)}) — toolchain not "
                            "certified for this guard"
                        )
            continue
        if payload_kind == "runEnded":
            symbol, text = _first_message(payload)
            summary_symbol = symbol
            summary_text = text if isinstance(text, str) else None
            saw_run_ended = True
            continue
        if not run_started:
            failures.append(f"line {index}: {payload_kind} before runStarted")
            continue

        test_id = payload.get("testID")
        if not isinstance(test_id, str):
            failures.append(f"line {index}: {payload_kind} without a string testID")
            continue
        if payload_kind == "issueRecorded":
            failures.append(f"line {index}: issue recorded for {test_id!r}")
            continue
        if test_id in function_defs:
            definition = function_defs[test_id]
            base = definition["base"]
            state = function_state[base]
            if payload_kind == "testStarted":
                state["started"] += 1
                if state["started"] > 1:
                    failures.append(f"line {index}: duplicate testStarted for {base!r}")
            elif payload_kind == "testEnded":
                if state["started"] < 1:
                    failures.append(f"line {index}: testEnded without testStarted for {base!r}")
                if state["ended"] >= 1:
                    failures.append(f"line {index}: duplicate testEnded for {base!r}")
                state["ended"] += 1
                symbol, _ = _first_message(payload)
                if symbol != "pass":
                    failures.append(
                        f"line {index}: test {base!r} ended with symbol {symbol!r}"
                    )
            elif payload_kind == "testSkipped":
                state["skipped"] += 1
                if state["skipped"] > 1:
                    failures.append(f"line {index}: duplicate testSkipped for {base!r}")
                result.skipped.append(base)
            elif payload_kind in ("testCaseStarted", "testCaseEnded"):
                if definition["parameterized"] is not True:
                    failures.append(
                        f"line {index}: test case event for non-parameterized test {base!r}"
                    )
                if payload_kind == "testCaseStarted":
                    state["case_started"] += 1
                else:
                    state["case_ended"] += 1
            else:
                failures.append(f"line {index}: unexpected event kind for function {base!r}")
        elif test_id in suite_defs:
            state = suite_state[test_id]
            if payload_kind == "testStarted":
                state["started"] += 1
                if state["started"] > 1:
                    failures.append(f"line {index}: duplicate suite start for {test_id!r}")
            elif payload_kind == "testEnded":
                if state["started"] < 1:
                    failures.append(f"line {index}: suite end without start for {test_id!r}")
                if state["ended"] >= 1:
                    failures.append(f"line {index}: duplicate suite end for {test_id!r}")
                state["ended"] += 1
                symbol, _ = _first_message(payload)
                state["end_symbol"] = symbol
                if symbol != "pass":
                    failures.append(
                        f"line {index}: suite {test_id!r} ended with symbol {symbol!r}"
                    )
            else:
                failures.append(
                    f"line {index}: unexpected event kind {payload_kind!r} for suite {test_id!r}"
                )
        else:
            failures.append(f"line {index}: event for unknown test id {test_id!r}")

    if not run_started:
        failures.append("no runStarted event")
    if not library_version_seen:
        failures.append("runStarted did not report a Testing Library version")
    if summary_text is None:
        failures.append("no runEnded event")
    else:
        match = COMPLETION_SUMMARY.match(summary_text)
        if not match:
            failures.append(f"unrecognized completion summary: {summary_text!r}")
        else:
            result.tests = int(match.group(1))
            result.suites = int(match.group(2))
            if match.group(3) != "passed" or summary_symbol != "pass":
                failures.append(
                    f"completion summary reports a non-passing run (symbol={summary_symbol!r})"
                )
            if result.tests != len(expected):
                failures.append(
                    f"summary reports {result.tests} logical tests, expected {len(expected)}"
                )
            if result.suites != len(suite_defs):
                failures.append(
                    f"summary reports {result.suites} suites, stream defines {len(suite_defs)}"
                )

    for suite_id, state in sorted(suite_state.items()):
        if state["started"] != 1 or state["ended"] != 1:
            failures.append(
                f"suite {suite_id!r} must start and end exactly once "
                f"(started={state['started']}, ended={state['ended']})"
            )

    for base in expected:
        if base not in base_to_full:
            failures.append(f"missing function definition for discovered test {base!r}")
            failures.append(f"missing execution for discovered test {base!r}")
            continue
        state = function_state[base]
        terminal = state["ended"] + state["skipped"]
        if terminal == 0:
            if state["started"]:
                failures.append(f"unfinished test {base!r}: started but never ended or skipped")
            else:
                failures.append(f"missing execution for discovered test {base!r}")
        elif terminal > 1:
            failures.append(f"multiple terminal events for test {base!r}")
        elif state["skipped"]:
            failures.append(
                f"test {base!r} was skipped — explicit skips are validation failures"
            )
        elif state["started"] != 1 or state["ended"] != 1:
            failures.append(
                f"test {base!r} needs exactly one started and one ended "
                f"(started={state['started']}, ended={state['ended']})"
            )
        parameterized = function_defs[base_to_full[base]]["parameterized"]
        if parameterized is True and state["skipped"] == 0:
            if state["case_started"] == 0:
                failures.append(f"parameterized test {base!r} ran no test cases")
            elif state["case_started"] != state["case_ended"]:
                failures.append(
                    f"unfinished test cases for {base!r} "
                    f"(started={state['case_started']}, ended={state['case_ended']})"
                )

    result.ok = not failures
    return result


def validate_stdout(
    text: str, expected_tests: int, expected_suites: int | None
) -> list[str]:
    """Validate a partition's captured stdout: exact summary plus 0/0 XCTest."""
    failures: list[str] = []
    matches = list(STDOUT_SUMMARY.finditer(text))
    if not matches:
        failures.append("stdout has no Swift Testing completion summary")
    else:
        if len(matches) > 1:
            failures.append("stdout has multiple Swift Testing completion summaries")
        match = matches[0]
        tests, suites, outcome = int(match.group(1)), int(match.group(2)), match.group(3)
        if outcome != "passed":
            failures.append(f"stdout completion summary reports {outcome!r}")
        if tests != expected_tests:
            failures.append(
                f"stdout summary reports {tests} tests, expected {expected_tests}"
            )
        if expected_suites is not None and suites != expected_suites:
            failures.append(
                f"stdout summary reports {suites} suites, expected {expected_suites}"
            )
    executed = list(XCTEST_EXECUTED.finditer(text))
    if not executed:
        failures.append("no legacy XCTest execution report on stdout")
    for match in executed:
        tests, test_failures = int(match.group(1)), int(match.group(2))
        if tests != 0 or test_failures != 0:
            failures.append(
                f"legacy XCTest run reported {tests} tests with {test_failures} "
                "failures — expected 0 tests and 0 failures"
            )
    return failures


def _signal_group(pgid: int, sig: int) -> None:
    """Signal the process group this runner owns via start_new_session."""
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Darwin can report EPERM for a group containing only zombies.
        # Verify that case while the owned leader still pins the group ID.
        listing = subprocess.run(
            ["ps", "-axo", "pid=,pgid=,stat="],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=5.0, check=True,
        ).stdout
        for line in listing.splitlines():
            _, group_text, state = line.split()
            if int(group_text) == pgid and not state.startswith("Z"):
                raise


def run_process(
    argv: Sequence[str],
    cwd: str,
    timeout: float,
    stdout_path: str,
    stderr_path: str,
) -> tuple[int | None, bool, float]:
    """Run argv in its own process group with redirected logs and a bounded timeout.

    Returns (returncode, timed_out, elapsed). On timeout the runner-owned group
    gets SIGTERM, then SIGKILL after the grace period. Only that group is
    signalled. Logs stream to files, so the child's exit code is never lost to
    a blocked pipe.
    """
    started = time.monotonic()
    timed_out = False
    with open(stdout_path, "wb") as out, open(stderr_path, "wb") as err:
        process = subprocess.Popen(
            argv,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=out,
            stderr=err,
            start_new_session=True,
        )
        # Keep the leader unreaped until all group inspection/signalling ends.
        # Its PID then cannot be reused for an unrelated process group.
        pgid = process.pid
        previous_term = signal.getsignal(signal.SIGTERM)

        def interrupted(signum, frame):
            raise KeyboardInterrupt("runner received SIGTERM")

        def cleanup():
            # Ignore further interrupts only during bounded cleanup.
            old_int = signal.signal(signal.SIGINT, signal.SIG_IGN)
            old_term = signal.signal(signal.SIGTERM, signal.SIG_IGN)
            try:
                cleanup_failed = False
                def send(sig):
                    nonlocal cleanup_failed
                    try:
                        _signal_group(pgid, sig)
                    except (OSError, subprocess.SubprocessError, ValueError) as error:
                        cleanup_failed = True
                        err.write(f"runner: owned group cleanup failed: {error}\n".encode())
                        err.flush()
                send(signal.SIGTERM)
                time.sleep(TERM_GRACE_SECONDS)
                send(signal.SIGKILL)
                try:
                    code = process.wait(timeout=TERM_GRACE_SECONDS)
                    return code if code or not cleanup_failed else 1
                except subprocess.TimeoutExpired:
                    return None
            finally:
                signal.signal(signal.SIGINT, old_int)
                signal.signal(signal.SIGTERM, old_term)

        signal.signal(signal.SIGTERM, interrupted)
        try:
            deadline = time.monotonic() + timeout
            while True:
                # macOS Python 3.9 lacks os.waitid; ps observes the zombie
                # leader without reaping it and keeps group ownership pinned.
                listing = subprocess.run(
                    ["ps", "-axo", "pid=,pgid=,stat="],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True, timeout=min(5.0, max(0.1, deadline - time.monotonic())),
                    check=True,
                ).stdout
                members = []
                leader_done = False
                for line in listing.splitlines():
                    pid_text, group_text, state = line.split()
                    if int(group_text) != pgid:
                        continue
                    pid = int(pid_text)
                    if pid == process.pid:
                        leader_done = state.startswith("Z")
                    elif not state.startswith("Z"):
                        members.append(pid)
                if leader_done:
                    if members:
                        err.write(b"runner: owned descendants survived process exit\n")
                        err.flush()
                        leader_code = cleanup()
                        returncode = leader_code if leader_code else 1
                    else:
                        returncode = process.wait(timeout=TERM_GRACE_SECONDS)
                    break
                if time.monotonic() >= deadline:
                    timed_out = True
                    returncode = cleanup()
                    break
                time.sleep(min(0.1, max(0.0, deadline - time.monotonic())))
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            timed_out = time.monotonic() >= deadline
            err.write(f"runner: exit probe failed: {error}\n".encode())
            err.flush()
            leader_code = cleanup()
            returncode = leader_code if leader_code else 1
        except BaseException:
            cleanup()
            raise
        finally:
            signal.signal(signal.SIGTERM, previous_term)
    return returncode, timed_out, time.monotonic() - started


def _read_text(path: str, strict: bool) -> str:
    with open(path, "rb") as handle:
        data = handle.read()
    if strict:
        return data.decode("utf-8")
    return data.decode("utf-8", errors="replace")


def _log_name(index: int, name: str, suffix: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
    return f"{index:02d}-{safe}.{suffix}"


def _execute_partition(
    swift: str,
    package: str,
    partition: Partition,
    timeout: float,
    output_dir: str,
    index: int,
) -> PartitionResult:
    """Run one guarded swift test process and validate its evidence."""
    result = PartitionResult(
        name=partition.name,
        filter_expression=partition.filter_expression,
        expected_tests=len(partition.ids),
    )
    stdout_log = os.path.join(output_dir, _log_name(index, partition.name, "stdout.log"))
    stderr_log = os.path.join(output_dir, _log_name(index, partition.name, "stderr.log"))
    events_log = os.path.join(output_dir, _log_name(index, partition.name, "events.jsonl"))
    result.stdout_log = stdout_log
    result.stderr_log = stderr_log
    result.events_log = events_log
    if os.path.exists(events_log):
        os.remove(events_log)

    argv = [swift, "test", "--skip-build", "--no-parallel"]
    if partition.filter_expression is not None:
        argv += ["--filter", partition.filter_expression]
    argv += ["--event-stream-output-path", events_log]

    returncode, timed_out, elapsed = run_process(
        argv, cwd=package, timeout=timeout, stdout_path=stdout_log, stderr_path=stderr_log
    )
    result.returncode = returncode
    result.timed_out = timed_out
    result.duration_seconds = elapsed
    if timed_out:
        result.failures.append(
            f"partition timed out after {timeout:g}s and its process group was terminated"
        )
    if returncode != 0:
        result.failures.append(f"swift test exited with {returncode}")

    stdout_text = _read_text(stdout_log, strict=False)
    if not os.path.exists(events_log):
        result.failures.append("event stream file was not written")
        return result
    try:
        events_text = _read_text(events_log, strict=True)
    except UnicodeDecodeError:
        result.failures.append("event stream is not valid UTF-8")
        return result
    validation = validate_event_lines(events_text.splitlines(), partition.ids)
    result.suites = validation.suites
    result.skipped = validation.skipped
    result.failures.extend(validation.failures)
    result.failures.extend(
        validate_stdout(stdout_text, expected_tests=len(partition.ids), expected_suites=result.suites)
    )
    result.ok = not result.failures
    return result


def run_package(
    package: str,
    mode: str,
    swift: str = "swift",
    output_dir: str | None = None,
    partition_timeout: float | None = None,
    build_timeout: float = BUILD_TIMEOUT_SECONDS,
    discovery_timeout: float = DISCOVERY_TIMEOUT_SECONDS,
) -> RunnerResult:
    """Build, discover, partition, run and validate one Swift package's tests."""
    package = os.path.abspath(package)
    if not os.path.isfile(os.path.join(package, "Package.swift")):
        raise RunnerError(f"no Package.swift under {package!r}")
    if mode not in ("suites", "aggregate"):
        raise RunnerError(f"unsupported mode: {mode!r}")
    if output_dir is None:
        output_dir = tempfile.mkdtemp(prefix="polybridge-swift-test-")
    else:
        os.makedirs(output_dir, exist_ok=True)
    if partition_timeout is None:
        partition_timeout = SUITE_TIMEOUT_SECONDS if mode == "suites" else AGGREGATE_TIMEOUT_SECONDS

    overall = RunnerResult(
        ok=False, package=package, mode=mode, output_dir=os.path.abspath(output_dir)
    )

    build_stdout = os.path.join(overall.output_dir, "build.stdout.log")
    build_stderr = os.path.join(overall.output_dir, "build.stderr.log")
    returncode, timed_out, elapsed = run_process(
        [swift, "build", "--build-tests"],
        cwd=package,
        timeout=build_timeout,
        stdout_path=build_stdout,
        stderr_path=build_stderr,
    )
    if timed_out or returncode != 0:
        overall.failures.append(
            f"swift build --build-tests failed (exit {returncode}, timed_out={timed_out}, "
            f"{elapsed:.1f}s); logs: {build_stdout} {build_stderr}"
        )
        _write_manifest(overall)
        return overall

    list_stdout = os.path.join(overall.output_dir, "list.stdout.log")
    list_stderr = os.path.join(overall.output_dir, "list.stderr.log")
    returncode, timed_out, elapsed = run_process(
        [swift, "test", "list", "--skip-build"],
        cwd=package,
        timeout=discovery_timeout,
        stdout_path=list_stdout,
        stderr_path=list_stderr,
    )
    if timed_out or returncode != 0:
        overall.failures.append(
            f"swift test list --skip-build failed (exit {returncode}, timed_out={timed_out}, "
            f"{elapsed:.1f}s); logs: {list_stdout} {list_stderr}"
        )
        _write_manifest(overall)
        return overall
    try:
        discovered = parse_list_output(_read_text(list_stdout, strict=True))
    except (RunnerError, UnicodeDecodeError) as error:
        overall.failures.append(f"discovery rejected: {error}; logs: {list_stdout} {list_stderr}")
        _write_manifest(overall)
        return overall

    overall.discovered_tests = len(discovered)
    overall.discovered_suites = len({suite_identity(test_id) for test_id in discovered})
    partitions = build_partitions(discovered, mode)
    try:
        validate_partitions(discovered, partitions)
    except RunnerError as error:
        overall.failures.append(f"partition validation failed: {error}")
        _write_manifest(overall)
        return overall

    for index, partition in enumerate(partitions, 1):
        print(
            f"swift-package-runner: START {index}/{len(partitions)} {partition.name} "
            f"({len(partition.ids)} tests); logs: {overall.output_dir}",
            flush=True,
        )
        result = _execute_partition(
            swift, package, partition, partition_timeout, overall.output_dir, index
        )
        overall.partitions.append(result)
        print(
            f"swift-package-runner: END {index}/{len(partitions)} {partition.name}: "
            f"{'PASS' if result.ok else 'FAIL'} ({result.duration_seconds:.1f}s)",
            flush=True,
        )
    overall.ok = all(partition.ok for partition in overall.partitions) and not overall.failures
    _write_manifest(overall)
    return overall


def _write_manifest(result: RunnerResult) -> None:
    manifest = {
        "package": result.package,
        "mode": result.mode,
        "passed": result.ok,
        "discovered_tests": result.discovered_tests,
        "discovered_suites": result.discovered_suites,
        "failures": result.failures,
        "partitions": [
            {
                "name": partition.name,
                "filter": partition.filter_expression,
                "expected_tests": partition.expected_tests,
                "returncode": partition.returncode,
                "timed_out": partition.timed_out,
                "duration_seconds": round(partition.duration_seconds, 3),
                "passed": partition.ok,
                "suites": partition.suites,
                "skipped": partition.skipped,
                "failures": partition.failures,
                "stdout_log": partition.stdout_log,
                "stderr_log": partition.stderr_log,
                "events_log": partition.events_log,
            }
            for partition in result.partitions
        ],
    }
    path = os.path.join(result.output_dir, "manifest.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    result.manifest_path = path


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="test-swift-package.py",
        description=(
            "Guarded Swift Testing runner: builds once, discovers every test id, runs "
            "per-suite partitions or one aggregate process, and fail-closed validates "
            "event streams, summaries, XCTest silence and exact identity coverage."
        ),
    )
    parser.add_argument("--package", default=".", help="Swift package directory (default: cwd)")
    parser.add_argument(
        "--mode",
        choices=("suites", "aggregate"),
        default="aggregate",
        help="suites: one fresh process per discovered suite; aggregate: one guarded process",
    )
    parser.add_argument("--swift", default="swift", help="swift executable (default: from PATH)")
    parser.add_argument(
        "--output-dir",
        default=None,
        help="directory for logs, event streams and manifest (default: a fresh temp dir)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help="per-partition timeout in seconds (default: 300 suites, 1200 aggregate)",
    )
    args = parser.parse_args(argv)

    try:
        result = run_package(
            package=args.package,
            mode=args.mode,
            swift=args.swift,
            output_dir=args.output_dir,
            partition_timeout=args.timeout,
        )
    except RunnerError as error:
        print(f"swift-package-runner: FAIL: {error}", file=sys.stderr)
        return 1

    for failure in result.failures:
        print(f"swift-package-runner: FAIL: {failure}")
    label = "suite" if result.mode == "suites" else "aggregate"
    total = len(result.partitions)
    for index, partition in enumerate(result.partitions, 1):
        status = "PASS" if partition.ok else "FAIL"
        detail = f"{partition.expected_tests} test" + ("s" if partition.expected_tests != 1 else "")
        if partition.suites is not None:
            detail += f" in {partition.suites} suite" + ("s" if partition.suites != 1 else "")
        extra = ""
        if not partition.ok:
            extra = f" — {partition.failures[0]}" if partition.failures else " — no evidence"
        print(
            f"{label} {index}/{total} {partition.name}: {status} {detail} "
            f"({partition.duration_seconds:.1f}s){extra}"
        )
    passed = sum(1 for partition in result.partitions if partition.ok)
    tests_run = sum(p.expected_tests for p in result.partitions if p.ok)
    tests_total = sum(p.expected_tests for p in result.partitions)
    outcome = "PASS" if result.ok else "FAIL"
    print(
        f"swift-package-runner: {outcome} mode={result.mode} package={result.package} "
        f"partitions={passed}/{total} tests={tests_run}/{tests_total}"
    )
    if not result.ok:
        print(f"swift-package-runner: logs: {result.output_dir}")
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
