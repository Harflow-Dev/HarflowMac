"""Ownership regressions for the thin native app host (no build or launch)."""

import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

import pytest


ROOT = Path(__file__).resolve().parents[2]
MACOS = ROOT / "macos"
PROJECT = MACOS / "Harflow.xcodeproj"


@pytest.fixture(scope="module")
def project():
    if sys.platform != "darwin":
        pytest.skip("Apple plutil is required to parse an OpenStep Xcode project")
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(PROJECT / "project.pbxproj")],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)["objects"]


def app_target(objects):
    targets = [obj for obj in objects.values()
               if obj.get("isa") == "PBXNativeTarget"
               and obj.get("productType") == "com.apple.product-type.application"]
    assert len(targets) == 1, "One Xcode app target must own the host"
    return targets[0]


def phase_paths(objects, phase_kind):
    target = app_target(objects)
    paths = []
    for key in target["buildPhases"]:
        phase = objects[key]
        if phase["isa"] == phase_kind:
            for item in phase.get("files", []):
                reference = objects[objects[item]["fileRef"]]
                paths.append(reference["path"])
    return paths


def test_xcode_compiles_only_the_single_entry_wrapper(project):
    paths = phase_paths(project, "PBXSourcesBuildPhase")
    assert len(paths) == 1
    wrappers = list((MACOS / "HarflowHost").rglob("*.swift"))
    assert len(wrappers) == 1
    assert Path(paths[0]).name == wrappers[0].name
    assert len(re.findall(r"@main\b", wrappers[0].read_text())) == 1
    assert "import Harflow" in wrappers[0].read_text()
    assert not any(re.search(r"@main\b", path.read_text())
                   for path in (MACOS / "Harflow/Sources").rglob("*.swift"))
    assert not any(project[key]["isa"] == "PBXShellScriptBuildPhase"
                   for key in app_target(project)["buildPhases"])


def test_shell_is_a_library_with_its_existing_test_target():
    manifest = (MACOS / "Harflow/Package.swift").read_text()
    assert re.search(r'\.library\s*\(\s*name:\s*"Harflow"', manifest)
    assert not re.search(r"\.(?:executable|executableTarget)\s*\(", manifest)
    assert re.search(r'\.testTarget\s*\(\s*name:\s*"HarflowTests"', manifest)
    assert re.search(r'\.target\s*\(\s*name:\s*"Harflow"', manifest)


def test_xcode_links_the_local_shell_product(project):
    dependencies = [project[key] for key in app_target(project)["packageProductDependencies"]]
    assert len(dependencies) == 1
    assert dependencies[0]["productName"] == "Harflow"
    package = project[dependencies[0]["package"]]
    assert package["isa"] == "XCLocalSwiftPackageReference"
    assert (MACOS / package["relativePath"]).resolve() == (MACOS / "Harflow").resolve()
    framework_phases = [project[key] for key in app_target(project)["buildPhases"]
                        if project[key]["isa"] == "PBXFrameworksBuildPhase"]
    linked = [project[key].get("productRef") for phase in framework_phases
              for key in phase.get("files", [])]
    assert app_target(project)["packageProductDependencies"][0] in linked


def test_app_owns_branding_but_not_loose_runtime_metadata(project):
    resources = phase_paths(project, "PBXResourcesBuildPhase")
    assert {Path(path).name for path in resources} == {
        "AppIcon.icns", "menubarTemplate.png", "menubarTemplate@2x.png",
    }


def test_every_app_configuration_preserves_identity_and_single_binary(project):
    target = app_target(project)
    config_list = project[target["buildConfigurationList"]]
    configurations = [project[key] for key in config_list["buildConfigurations"]]
    assert {entry["name"] for entry in configurations} == {"Debug", "Release"}
    for configuration in configurations:
        settings = configuration["buildSettings"]
        assert settings["ENABLE_DEBUG_DYLIB"] == "NO"
        assert "REGISTER_APP" not in settings
        assert settings["GENERATE_INFOPLIST_FILE"] == "NO"
        assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == "dev.harflow.mac"
        assert float(settings["MACOSX_DEPLOYMENT_TARGET"]) == 26
        assert settings["ARCHS"] in ("arm64", ["arm64"])
        plist_path = MACOS / settings["INFOPLIST_FILE"]
        assert plist_path.resolve() == (MACOS / "HarflowHost/Info.plist").resolve()
        with plist_path.open("rb") as stream:
            plist = plistlib.load(stream)
        assert plist["CFBundleIdentifier"] == "dev.harflow.mac"
        assert plist["CFBundleExecutable"] == "Harflow"
        assert plist["CFBundleShortVersionString"] == "0.0.9"
        assert plist["CFBundleVersion"] == "1"
        assert plist["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["harflow"]
    scheme = ET.parse(PROJECT / "xcshareddata/xcschemes/Harflow.xcscheme")
    buildables = scheme.findall(".//BuildableReference")
    assert buildables
    target_keys = {key for key, value in project.items() if value is target}
    assert all(buildable.attrib["BlueprintIdentifier"] in target_keys for buildable in buildables)


@pytest.fixture
def build_harness(tmp_path, monkeypatch):
    """Run only the wrapper in a scratch tree; all platform tools are inert fakes."""
    import os

    host = tmp_path / "checkout with spaces" / "macos"
    host.mkdir(parents=True)
    shutil.copy2(MACOS / "build-app.sh", host / "build-app.sh")
    tools = tmp_path / "tools"
    tools.mkdir()
    log = tmp_path / "calls.jsonl"
    fake = '''import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ["HOST_TEST_LOG"], "a") as stream:
    stream.write(json.dumps([name, sys.argv[1:]]) + "\\n")
if name == "swift":
    sys.exit(25)
if name == "xcodebuild":
    if os.environ.get("HOST_TEST_BUILD_FAIL"):
        sys.exit(23)
    output = next(arg.split("=", 1)[1] for arg in sys.argv[1:]
                  if arg.startswith("CONFIGURATION_BUILD_DIR="))
    contents = pathlib.Path(output) / "Harflow.app/Contents"
    (contents / "Resources").mkdir(parents=True)
    (contents / "Info.plist").write_text("fake plist")
    for resource in ("AppIcon.icns", "menubarTemplate.png", "menubarTemplate@2x.png"):
        if resource != os.environ.get("HOST_TEST_MISSING_RESOURCE"):
            (contents / "Resources" / resource).write_bytes(b"fixture")
if name == "codesign" and os.environ.get("HOST_TEST_SIGN_FAIL"):
    sys.exit(24)
'''
    for tool in ("xcodebuild", "codesign", "plutil", "swift"):
        path = tools / tool
        path.write_text(f"#!{sys.executable}\n" + fake)
        path.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tools}:{os.environ['PATH']}")
    monkeypatch.setenv("HOST_TEST_LOG", str(log))
    monkeypatch.delenv("CONFIGURATION", raising=False)

    def run(configuration=None):
        if configuration is not None:
            monkeypatch.setenv("CONFIGURATION", configuration)
        result = subprocess.run(["/bin/bash", str(host / "build-app.sh")],
                                cwd=tmp_path, capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    return host, run


@pytest.mark.parametrize("configuration,expected", [(None, "Release"), ("release", "Release"),
                                                   ("debug", "Debug"), ("Debug", "Debug")])
def test_build_wrapper_uses_one_native_build_and_signs_exact_output(build_harness, configuration, expected):
    host, run = build_harness
    result, calls = run(configuration)
    assert result.returncode == 0, result.stderr
    builds = [args for tool, args in calls if tool == "xcodebuild"]
    assert len(builds) == 1
    args = builds[0]
    assert args[args.index("-project") + 1] == str(host / "Harflow.xcodeproj")
    assert args[args.index("-scheme") + 1] == "Harflow"
    assert args[args.index("-configuration") + 1] == expected
    assert "-onlyUsePackageVersionsFromResolvedFile" in args
    assert "ARCHS=arm64" in args
    assert not any(arg.startswith("REGISTER_APP=") for arg in args)
    assert "CODE_SIGNING_ALLOWED=NO" in args
    assert args.count("build") == 1
    signatures = [args for tool, args in calls if tool == "codesign"]
    assert len(signatures) == 2
    assert all(args[-1] == str(host / "build/Harflow.app") for args in signatures)
    assert "--sign" in signatures[0] and "-" in signatures[0]
    assert "--verify" in signatures[1] and "--strict" in signatures[1]


def test_build_wrapper_rejects_unknown_configuration_before_any_tool(build_harness):
    _, run = build_harness
    result, calls = run("profile")
    assert result.returncode != 0
    assert calls == []


def test_build_wrapper_stops_before_signing_when_native_build_fails(build_harness, monkeypatch):
    monkeypatch.setenv("HOST_TEST_BUILD_FAIL", "1")
    _, run = build_harness
    result, calls = run()
    assert result.returncode != 0
    assert [tool for tool, _ in calls] == ["xcodebuild"]


def test_build_wrapper_refuses_missing_resource_before_signing(build_harness, monkeypatch):
    monkeypatch.setenv("HOST_TEST_MISSING_RESOURCE", "menubarTemplate@2x.png")
    _, run = build_harness
    result, calls = run()
    assert result.returncode != 0
    assert not any(tool == "codesign" for tool, _ in calls)


def test_build_wrapper_propagates_signing_failure(build_harness, monkeypatch):
    monkeypatch.setenv("HOST_TEST_SIGN_FAIL", "1")
    _, run = build_harness
    result, calls = run()
    assert result.returncode != 0
    assert len([tool for tool, _ in calls if tool == "codesign"]) == 1
