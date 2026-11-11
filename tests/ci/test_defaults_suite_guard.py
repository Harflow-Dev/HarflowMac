"""Guard: named UserDefaults suites must go through ScratchDefaults.

A named suite persists to ~/Library/Preferences/<name>.plist through cfprefsd, even under a scratch
HOME, so tests that create one leak files into the real user's Preferences folder. The shared
ScratchDefaults helper uses absolute-path suite names instead, which are stored next to the path.
"""

from pathlib import Path
import re

import pytest


ROOT = Path(__file__).resolve().parents[2]
SCAN_ROOTS = ("macos", "scripts/support")
ALLOWED = {"macos/HfFoundation/HfUtilities/Sources/HfTestUtilities/ScratchDefaults.swift"}

PATTERNS = {
    "suite initializer": re.compile(r"\b(?:NS)?UserDefaults\s*(?:\.\s*init)?\s*\(\s*suiteName"),
    "addSuite": re.compile(r"\baddSuite\s*\(\s*named"),
    "setPersistentDomain": re.compile(r"\bsetPersistentDomain\s*\("),
    "CFPreferencesSet": re.compile(r"\bCFPreferencesSet"),
    "CFPreferencesAddSuite": re.compile(r"\bCFPreferencesAddSuitePreferencesToAppDomain"),
}


def violations(text):
    """Names of the forbidden patterns found in Swift source text."""
    normalised = text.replace("\r\n", "\n").replace("\r", "\n")
    return sorted(name for name, pattern in PATTERNS.items() if pattern.search(normalised))


def swift_files():
    for base in SCAN_ROOTS:
        for path in sorted((ROOT / base).rglob("*.swift")):
            if "/.build/" in path.as_posix():
                continue
            yield path


def test_no_named_defaults_suites_outside_the_scratch_helper():
    offenders = {}
    for path in swift_files():
        relative = path.relative_to(ROOT).as_posix()
        if relative in ALLOWED:
            continue
        found = violations(path.read_text(encoding="utf-8", errors="replace"))
        if found:
            offenders[relative] = found
    assert not offenders, f"Use ScratchDefaults from HfTestUtilities instead: {offenders}"


def test_the_allowlisted_helper_exists():
    for relative in ALLOWED:
        assert (ROOT / relative).is_file(), relative


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ('let d = UserDefaults(suiteName: "x")!', "suite initializer"),
        ('let d = UserDefaults(\n    suiteName: "x"\n)!', "suite initializer"),
        ('let d = UserDefaults\n    .init(suiteName: "x")', "suite initializer"),
        ('let d = UserDefaults . init ( suiteName: name)', "suite initializer"),
        ('let d = NSUserDefaults(suiteName: "x")', "suite initializer"),
        ('let d = UserDefaults(\r\n  suiteName: "x")', "suite initializer"),
        ('UserDefaults.standard.addSuite(named: "x")', "addSuite"),
        ('UserDefaults.standard.addSuite(\n  named: "x")', "addSuite"),
        ('d.setPersistentDomain(["a": 1], forName: "x")', "setPersistentDomain"),
        ('CFPreferencesSetValue(key, value, app, user, host)', "CFPreferencesSet"),
        ('CFPreferencesAddSuitePreferencesToAppDomain(app, suite)', "CFPreferencesAddSuite"),
    ],
)
def test_each_forbidden_pattern_fires(source, expected):
    assert expected in violations(source)


@pytest.mark.parametrize(
    "source",
    [
        "let d = UserDefaults.standard",
        "let d = ScratchDefaults().defaults",
        "// mentions suiteName only",
    ],
)
def test_clean_sources_pass(source):
    assert violations(source) == []
