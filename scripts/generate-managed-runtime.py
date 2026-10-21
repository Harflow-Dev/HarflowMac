#!/usr/bin/env python3
"""Generate the app's pinned target wheel specification from explicit product inputs.

Run with the pinned target standalone Python; pip's vendored packaging interprets
its supported tags and the exported production requirement markers. No resolution,
network access, package manager invocation, or sibling checkout discovery occurs.
"""

import argparse
import hashlib
import json
import pathlib
import platform
import sys
import tomllib
import urllib.parse

from pip._vendor.packaging.markers import default_environment
from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.tags import sys_tags
from pip._vendor.packaging.utils import canonicalize_name, parse_wheel_filename


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=pathlib.Path, required=True)
    parser.add_argument("--requirements", type=pathlib.Path, required=True)
    parser.add_argument("--interpreter", type=pathlib.Path, required=True)
    parser.add_argument("--engine-version", required=True)
    parser.add_argument("--provenance", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def active_requirements(text):
    result = {}
    for line in text.replace("\\\n", " ").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        requirement = Requirement(line.split(" --hash=", 1)[0].strip())
        if requirement.marker and not requirement.marker.evaluate(default_environment()):
            continue
        pins = list(requirement.specifier)
        if requirement.url or len(pins) != 1 or pins[0].operator != "==":
            raise ValueError(f"requirement must have one exact pin: {requirement}")
        name = canonicalize_name(requirement.name)
        if name in result and result[name] != pins[0].version:
            raise ValueError(f"conflicting active versions for {name}")
        result[name] = pins[0].version
    result.pop("harflow-mcp", None)
    return result


def select_wheels(lock, requirements):
    ranks = {tag: index for index, tag in enumerate(sys_tags())}
    selected = []
    for name, version in sorted(requirements.items()):
        packages = [p for p in lock["package"] if canonicalize_name(p["name"]) == name and p["version"] == version]
        if len(packages) != 1:
            raise ValueError(f"lock must contain one matching package for {name}=={version}")
        candidates = []
        for wheel in packages[0].get("wheels", []):
            url = urllib.parse.urlparse(wheel["url"])
            filename = urllib.parse.unquote(url.path.rsplit("/", 1)[-1])
            wheel_name, wheel_version, _, tags = parse_wheel_filename(filename)
            compatible = [ranks[tag] for tag in tags if tag in ranks]
            if not compatible:
                continue
            if url.scheme != "https" or url.hostname != "files.pythonhosted.org":
                raise ValueError(f"wheel must use files.pythonhosted.org TLS: {filename}")
            if canonicalize_name(wheel_name) != name or str(wheel_version) != version:
                raise ValueError(f"wheel identity disagrees with lock: {filename}")
            algorithm, digest = wheel["hash"].split(":", 1)
            if algorithm != "sha256" or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                raise ValueError(f"invalid SHA256: {filename}")
            if not 0 < wheel["size"] <= 64 << 20:
                raise ValueError(f"invalid wheel size: {filename}")
            artifact = dict(name=name, version=version, filename=filename, url=wheel["url"], sha256=digest, size=wheel["size"])
            candidates.append((min(compatible), filename, artifact))
        if not candidates:
            raise ValueError(f"no locked target binary wheel for {name}=={version}")
        selected.append(min(candidates, key=lambda candidate: candidate[:2])[2])
    return selected


def main():
    args = arguments()
    interpreter = json.loads(args.interpreter.read_text())
    if sys.version.split()[0] != interpreter["pythonVersion"] or platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Run this generator with the pinned Darwin arm64 standalone Python.")
    lock_bytes = args.lock.read_bytes()
    export_bytes = args.requirements.read_bytes()
    requirements = active_requirements(export_bytes.decode())
    result = dict(schema=1, engineVersion=args.engine_version, **interpreter,
                  dependencies=select_wheels(tomllib.loads(lock_bytes.decode()), requirements),
                  provenance=args.provenance + "; lock sha256:" + hashlib.sha256(lock_bytes).hexdigest()
                  + "; production export sha256:" + hashlib.sha256(export_bytes).hexdigest())
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"Generated {len(result['dependencies'])} locked target wheels in {args.output}")


if __name__ == "__main__":
    main()
