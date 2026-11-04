"""Fail-closed coverage for exact content and path identity exceptions."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[2]
PROJECT_PATH = "macos/Harflow.xcodeproj/project." + "p" + "bxproj"
LEGACY_WORD = "Poly" + "bridge"
LEGACY_PREFIX = "P" + "B_"


@pytest.fixture
def guard(tmp_path):
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    shutil.copy2(ROOT / "scripts/check-legacy-names.py", scripts)
    tools = tmp_path / "tools"
    tools.mkdir()
    git = tools / "git"
    git.write_text(f"#!{sys.executable}\nimport os\nprint(os.environ['GUARD_TEST_PATHS'])\n")
    git.chmod(0o755)

    def run(files, entries=()):
        for name, content in files.items():
            path = tmp_path / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        (scripts / "legacy-name-allowlist.json").write_text(json.dumps(entries))
        env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                   GUARD_TEST_PATHS="\n".join(files))
        return subprocess.run([sys.executable, str(scripts / "check-legacy-names.py")],
                              cwd=tmp_path, env=env, capture_output=True, text=True)

    return run


def exception(file, literal, *, count=1, scope=None):
    entry = {"file": file, "literal": literal, "reason": "Exact regression fixture", "count": count}
    if scope is not None:
        entry["scope"] = scope
    return entry


@pytest.mark.parametrize("content", [LEGACY_WORD, LEGACY_WORD.lower(), LEGACY_PREFIX + "TASK_ID"])
def test_unapproved_legacy_content_is_rejected(guard, content):
    result = guard({"source.txt": content})
    assert result.returncode != 0
    assert "source.txt" in result.stderr


def test_unapproved_legacy_path_is_rejected_even_with_clean_content(guard):
    name = LEGACY_WORD + "/source.txt"
    result = guard({name: "clean"})
    assert result.returncode != 0
    assert name in result.stderr


def test_standard_project_path_requires_an_explicit_path_exception(guard):
    files = {PROJECT_PATH: "clean native project"}
    assert guard(files).returncode != 0
    # A content exception cannot authorize a path, even when its count matches.
    result = guard({PROJECT_PATH: PROJECT_PATH}, [exception(PROJECT_PATH, PROJECT_PATH)])
    assert result.returncode != 0
    result = guard(files, [exception(PROJECT_PATH, PROJECT_PATH, scope="path")])
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("content", [LEGACY_WORD, PROJECT_PATH])
def test_path_exception_does_not_hide_legacy_content(guard, content):
    result = guard({PROJECT_PATH: content},
                   [exception(PROJECT_PATH, PROJECT_PATH, scope="path")])
    assert result.returncode != 0
    assert PROJECT_PATH in result.stderr


def test_path_exception_does_not_authorize_another_project(guard):
    other = PROJECT_PATH.replace("Harflow.xcodeproj", "Other.xcodeproj")
    result = guard({PROJECT_PATH: "clean", other: "clean"},
                   [exception(PROJECT_PATH, PROJECT_PATH, scope="path")])
    assert result.returncode != 0
    assert other in result.stderr


def test_path_exception_masks_only_its_exact_fragment(guard):
    name = LEGACY_WORD + "/" + PROJECT_PATH
    result = guard({name: "clean"}, [exception(name, PROJECT_PATH, scope="path")])
    assert result.returncode != 0
    assert name in result.stderr


def test_content_exception_defaults_to_content_and_is_exact(guard):
    entry = exception("source.txt", LEGACY_PREFIX)
    assert guard({"source.txt": LEGACY_PREFIX}, [entry]).returncode == 0
    result = guard({"source.txt": LEGACY_PREFIX + " " + LEGACY_WORD}, [entry])
    assert result.returncode != 0


@pytest.mark.parametrize("scope", [None, "content", "path"])
def test_exception_count_mismatch_fails_closed(guard, scope):
    name = PROJECT_PATH if scope == "path" else "source.txt"
    literal = PROJECT_PATH if scope == "path" else LEGACY_PREFIX
    result = guard({name: "clean" if scope == "path" else literal},
                   [exception(name, literal, count=2, scope=scope)])
    assert result.returncode != 0
    assert "count" in result.stderr.lower()


@pytest.mark.parametrize("scope", ["both", "PATH", "", 1, None])
def test_unknown_or_invalid_scope_is_rejected(guard, scope):
    entry = exception("source.txt", LEGACY_PREFIX)
    entry["scope"] = scope
    result = guard({"source.txt": LEGACY_PREFIX}, [entry])
    assert result.returncode != 0
    assert "Invalid legacy-name exception" in result.stderr
