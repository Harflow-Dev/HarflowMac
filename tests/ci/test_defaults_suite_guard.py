"""Guard: named UserDefaults suites must go through ScratchDefaults.

A named suite persists to ~/Library/Preferences/<name>.plist through cfprefsd, even under a scratch
HOME, so tests that create one leak files into the real user's Preferences folder. The shared
ScratchDefaults helper uses absolute-path suite names instead, which are stored next to the path.
"""

from pathlib import Path
import re
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
SCAN_ROOTS = ("macos", "scripts/support")
ALLOWED = {"macos/HfFoundation/HfUtilities/Sources/HfTestUtilities/ScratchDefaults.swift"}

PATTERNS = {
    "suite initializer": re.compile(r"\b(?:NS)?UserDefaults\s*(?:\.\s*init)?\s*\(\s*suiteName"),
    "implicit initializer": re.compile(r"(?<![\w.])\.init\s*\(\s*suiteName"),
    "addSuite": re.compile(r"\baddSuite\s*\(\s*named"),
    "setPersistentDomain": re.compile(r"\bsetPersistentDomain\s*\("),
    "CFPreferencesSet": re.compile(r"\bCFPreferencesSet"),
    "CFPreferencesAddSuite": re.compile(r"\bCFPreferencesAddSuitePreferencesToAppDomain"),
}


# The AppKit test host must never write to any defaults domain: its settings go through the volatile
# argument domain. Receiver-independent on purpose (an alias such as `let d = UserDefaults.standard`
# must not slip through). It deliberately also matches non-defaults calls such as `NSColor.set()`, and
# string literals and comments. Applies to scripts/support only, not to macos/, where the app writes its own.
HOST_SCAN_ROOT = "scripts/support"
HOST_PATTERNS = {
    "host defaults set": re.compile(r"\.\s*set\s*\("),
    "host defaults setValue": re.compile(r"\.\s*setValue\s*\("),
    "host defaults setObject": re.compile(r"\.\s*setObject\s*\("),
    "host defaults removeObject": re.compile(r"\.\s*removeObject\s*\("),
    "host defaults removePersistentDomain": re.compile(r"\.\s*removePersistentDomain\s*\("),
}


def host_violations(text):
    """Names of the host-only forbidden writes found in Swift source text."""
    normalised = text.replace("\r\n", "\n").replace("\r", "\n")
    return sorted(name for name, pattern in HOST_PATTERNS.items() if pattern.search(normalised))


def violations(text):
    """Names of the forbidden patterns found in Swift source text."""
    normalised = text.replace("\r\n", "\n").replace("\r", "\n")
    return sorted(name for name, pattern in PATTERNS.items() if pattern.search(normalised))


def swift_files():
    """Tracked or addable Swift files under the scan roots; build output and checkouts are ignored."""
    listing = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", *SCAN_ROOTS],
        cwd=ROOT, capture_output=True, check=True,
    ).stdout.decode("utf-8")
    return [ROOT / name for name in sorted(listing.split("\0")) if name.endswith(".swift") and (ROOT / name).is_file()]


def test_no_named_defaults_suites_outside_the_scratch_helper():
    files = swift_files()
    visited = {path.relative_to(ROOT).as_posix() for path in files}
    assert len(visited) > 200, f"The scan visited only {len(visited)} Swift files"
    assert ALLOWED <= visited, "The scan did not include the allowlisted helper"
    offenders = {}
    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        if relative in ALLOWED:
            continue
        found = violations(path.read_text(encoding="utf-8", errors="replace"))
        if found:
            offenders[relative] = found
    assert not offenders, f"Use ScratchDefaults from HfTestUtilities instead: {offenders}"


def test_the_appkit_test_host_never_writes_defaults():
    files = [path for path in swift_files() if path.relative_to(ROOT).as_posix().startswith(HOST_SCAN_ROOT + "/")]
    assert any(path.name == "AppKitTestHost.swift" for path in files), "The scan did not include the test host"
    offenders = {
        path.relative_to(ROOT).as_posix(): found
        for path in files
        if (found := host_violations(path.read_text(encoding="utf-8", errors="replace")))
    }
    assert not offenders, f"The test host must use the volatile argument domain only: {offenders}"


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
        ('let d: UserDefaults? = .init(suiteName: "x")', "implicit initializer"),
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


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ('UserDefaults.standard.set(false, forKey: "k")', "host defaults set"),
        ('let d = UserDefaults.standard\nd.set(true, forKey: "k")', "host defaults set"),
        ('defaults\n    .set(\n        true, forKey: "k")', "host defaults set"),
        ('d.setValue(1, forKey: "k")', "host defaults setValue"),
        ('d.setObject(1, forKey: "k")', "host defaults setObject"),
        ('d.removeObject(forKey: "k")', "host defaults removeObject"),
        ('d.removePersistentDomain(forName: "x")', "host defaults removePersistentDomain"),
    ],
)
def test_each_host_write_pattern_fires(source, expected):
    assert expected in host_violations(source)


@pytest.mark.parametrize(
    "source",
    [
        'd.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)',
        'UserDefaults.standard.register(defaults: ["a": true])',
        'let value = d.object(forKey: "k")',
    ],
)
def test_clean_host_sources_pass(source):
    assert host_violations(source) == []
