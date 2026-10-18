#!/usr/bin/env python3
"""Reject legacy product identities in maintained files; exceptions require exact literals."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parts = ["Poly" + "bridge", "poly" + "bridge", "POLY" + "BRIDGE", "P" + "B_", r"\bP" + "b", r"\bp" + "b"]
pattern = re.compile("|".join(parts))
allow = json.loads((ROOT / "scripts/legacy-name-allowlist.json").read_text())
seen = set()
for entry in allow:
    if (set(entry) != {"file", "literal", "reason", "count"}
            or not isinstance(entry["file"], str) or not entry["file"]
            or not isinstance(entry["literal"], str) or not entry["literal"]
            or not isinstance(entry["reason"], str) or not entry["reason"].strip()
            or type(entry["count"]) is not int or entry["count"] <= 0):
        raise SystemExit("Invalid legacy-name exception")
    key = (entry["file"], entry["literal"])
    if key in seen or not (ROOT / entry["file"]).is_file():
        raise SystemExit("Duplicate or missing-file legacy-name exception")
    seen.add(key)
paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT, text=True).splitlines()
failures = []
for name in sorted(set(paths)):
    path = ROOT / name
    if not path.is_file():
        continue
    try:
        text = path.read_text()
    except UnicodeError:
        continue
    for entry in allow:
        if entry["file"] == name:
            observed = text.count(entry["literal"])
            if observed != entry["count"]:
                failures.append(f"{name}: legacy exception occurrence count {observed} != {entry['count']}")
            text = text.replace(entry["literal"], "")
    if pattern.search(name) or pattern.search(text):
        failures.append(name)
if failures:
    print("Legacy identities require removal or exact justified exceptions:", file=sys.stderr)
    print("\n".join(failures), file=sys.stderr)
    raise SystemExit(1)
print("Legacy identity guard passed")
