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


def target_phase_files(objects, phase_kind):
    target = app_target(objects)
    files = []
    for key in target["buildPhases"]:
        phase = objects[key]
        if phase["isa"] == phase_kind:
            files.extend(phase.get("files", []))
    return files


def synchronized_groups(objects):
    return {key: obj for key, obj in objects.items()
            if obj.get("isa") == "PBXFileSystemSynchronizedRootGroup"}


def main_group_children(objects):
    root = next(obj for obj in objects.values() if obj.get("isa") == "PBXProject")
    return objects[root["mainGroup"]]["children"]


HOST_FILES = {"HarflowHost.swift", "Info.plist", "AppIcon.icns",
              "menubarTemplate.png", "menubarTemplate@2x.png"}
PACKAGE_GROUPS = ("HfFoundation", "HfCore", "HfFeatures")


def test_project_lists_no_explicit_sources_resources_or_script_phases(project):
    assert target_phase_files(project, "PBXSourcesBuildPhase") == []
    assert target_phase_files(project, "PBXResourcesBuildPhase") == []
    assert not any(project[key]["isa"] == "PBXShellScriptBuildPhase"
                   for key in app_target(project)["buildPhases"])
    groups = synchronized_groups(project)
    target_groups = [groups[key]["path"] for key in app_target(project)["fileSystemSynchronizedGroups"]]
    assert target_groups == ["HarflowHost"]


def test_host_folder_holds_exactly_the_wrapper_plist_and_branding_with_plist_excluded(project):
    folder = MACOS / "HarflowHost"
    assert {path.name for path in folder.iterdir() if not path.name.startswith(".")} == HOST_FILES
    wrappers = list(folder.rglob("*.swift"))
    assert [path.name for path in wrappers] == ["HarflowHost.swift"]
    assert len(re.findall(r"@main\b", wrappers[0].read_text())) == 1
    assert "import Harflow" in wrappers[0].read_text()
    assert not any(re.search(r"@main\b", path.read_text())
                   for path in (MACOS / "HfFeatures/Harflow/Sources").rglob("*.swift"))
    group = synchronized_groups(project)[app_target(project)["fileSystemSynchronizedGroups"][0]]
    exceptions = [project[key] for key in group["exceptions"]]
    assert len(exceptions) == 1
    assert exceptions[0]["isa"] == "PBXFileSystemSynchronizedBuildFileExceptionSet"
    assert exceptions[0]["membershipExceptions"] == ["Info.plist"]
    target_keys = {key for key, value in project.items() if value is app_target(project)}
    assert exceptions[0]["target"] in target_keys


def test_shell_is_a_library_with_its_existing_test_target():
    manifest = (MACOS / "HfFeatures/Harflow/Package.swift").read_text()
    assert re.search(r'\.library\s*\(\s*name:\s*"Harflow"', manifest)
    assert not re.search(r"\.(?:executable|executableTarget)\s*\(", manifest)
    assert re.search(r'\.testTarget\s*\(\s*name:\s*"HarflowTests"', manifest)
    assert re.search(r'\.target\s*\(\s*name:\s*"Harflow"', manifest)


def test_xcode_links_the_shell_product_by_name_only_without_package_references(project):
    dependencies = [project[key] for key in app_target(project)["packageProductDependencies"]]
    assert len(dependencies) == 1
    assert dependencies[0]["productName"] == "Harflow"
    assert "package" not in dependencies[0]
    assert not any(obj.get("isa") == "XCLocalSwiftPackageReference" for obj in project.values())
    assert not any(obj.get("isa") == "XCRemoteSwiftPackageReference" for obj in project.values())
    assert not any("packageReferences" in obj for obj in project.values() if obj.get("isa") == "PBXProject")
    framework_phases = [project[key] for key in app_target(project)["buildPhases"]
                        if project[key]["isa"] == "PBXFrameworksBuildPhase"]
    linked = [project[key].get("productRef") for phase in framework_phases
              for key in phase.get("files", [])]
    assert linked == [app_target(project)["packageProductDependencies"][0]]


def test_synchronized_roots_are_the_host_configuration_and_three_package_groups(project):
    groups = synchronized_groups(project)
    assert sorted(group["path"] for group in groups.values()) == sorted(
        ["HarflowHost", "Configuration", *PACKAGE_GROUPS])
    assert set(groups) <= set(main_group_children(project))
    for name in PACKAGE_GROUPS:
        manifests = sorted(path.relative_to(MACOS / name).parts
                           for path in (MACOS / name).rglob("Package.swift")
                           if ".build" not in path.parts)
        assert manifests, name
        assert all(len(parts) == 2 for parts in manifests), (name, manifests)


def test_wrapper_workspace_does_not_exist():
    assert not (MACOS / "Harflow.xcworkspace").exists()


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
    scheme = ET.parse(PROJECT / "xcshareddata/xcschemes/HarflowHost.xcscheme")
    buildables = scheme.findall(".//BuildableReference")
    assert buildables
    target_keys = {key for key, value in project.items() if value is target}
    assert all(buildable.attrib["BlueprintIdentifier"] in target_keys for buildable in buildables)


def discovered_packages():
    """Return {(group, package)} for every Package.swift one level below a package group."""
    return {(group, manifest.parent.name)
            for group in PACKAGE_GROUPS
            for manifest in (MACOS / group).glob("*/Package.swift")}


def load_runner():
    import importlib.util
    path = ROOT / "scripts/test-swift-package.py"
    spec = importlib.util.spec_from_file_location("swift_package_runner_under_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def scheme_buildables(scheme_path):
    root = ET.parse(scheme_path).getroot()
    entries = [(ref.attrib["BlueprintIdentifier"], ref.attrib["BlueprintName"], ref.attrib["ReferencedContainer"])
               for ref in root.findall("./BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference")]
    testables = [(ref.attrib["BlueprintIdentifier"], ref.attrib["BlueprintName"], ref.attrib["ReferencedContainer"])
                 for ref in root.findall("./TestAction/Testables/TestableReference/BuildableReference")]
    return root, entries, testables


def test_host_scheme_builds_only_the_app_without_building_for_testing_and_defaults_to_the_test_plan():
    root, entries, testables = scheme_buildables(PROJECT / "xcshareddata/xcschemes/HarflowHost.xcscheme")
    assert entries == [("A00000000000000000000001", "HarflowHost", "container:Harflow.xcodeproj")]
    assert testables == []
    entry = root.find("./BuildAction/BuildActionEntries/BuildActionEntry")
    assert entry.attrib["buildForTesting"] == "NO"
    assert root.find("./TestAction").attrib["shouldAutocreateTestPlan"] == "NO"
    plans = root.findall("./TestAction/TestPlans/TestPlanReference")
    assert [(plan.attrib["reference"], plan.attrib.get("default")) for plan in plans] == [
        ("container:Configuration/Harflow-UnitTests.xctestplan", "YES")]


def test_every_package_has_its_own_shared_scheme_building_it_and_testing_its_test_target():
    packages = discovered_packages()
    schemes = {path.stem for path in (PROJECT / "xcshareddata/xcschemes").glob("*.xcscheme")}
    assert schemes == {"HarflowHost"} | {package for _, package in packages}
    for group, package in packages:
        _, entries, testables = scheme_buildables(PROJECT / f"xcshareddata/xcschemes/{package}.xcscheme")
        container = f"container:{group}/{package}"
        assert entries == [(package, package, container)]
        assert testables == [(f"{package}Tests", f"{package}Tests", container)]


def test_plan_runs_every_package_test_target_serially_and_disables_only_the_runner_hosted_one():
    plan = json.loads((MACOS / "Configuration/Harflow-UnitTests.xctestplan").read_text())
    targets = plan["testTargets"]
    assert {(entry["target"]["containerPath"], entry["target"]["identifier"], entry["target"]["name"]) for entry in targets} == {
        (f"container:{group}/{package}", f"{package}Tests", f"{package}Tests") for group, package in discovered_packages()}
    assert len(targets) == len(discovered_packages())
    assert all(entry["parallelizable"] is False for entry in targets)
    # Xcode 26.6 does not honor per-suite skips for these Swift Testing targets, so the only
    # target holding runner-hosted suites is disabled as a whole; nothing else is.
    disabled = {entry["target"]["name"] for entry in targets if entry.get("enabled") is False}
    assert disabled == {"MainWindowFeatureTests"}
    assert all("skippedTests" not in entry and "selectedTests" not in entry for entry in targets)


def test_hosted_suites_all_live_in_the_disabled_main_window_target():
    hosted = {name.split(".", 1)[0] for name in load_runner().HOSTED_SUITES}
    assert hosted == {"MainWindowFeatureTests"}


def test_main_window_scheme_skips_its_test_target_and_no_other_scheme_skips_tests():
    for path in (PROJECT / "xcshareddata/xcschemes").glob("*.xcscheme"):
        root = ET.parse(path).getroot()
        skipped = [ref.attrib["skipped"] for ref in root.findall(".//TestableReference")]
        assert not root.findall(".//SkippedTests"), path.name
        assert skipped == (["YES"] if path.stem == "MainWindowFeature" else (["NO"] if skipped else [])), path.name


def test_ci_covers_every_package_exactly_once():
    import glob
    workflow = (ROOT / ".github/workflows/macos.yml").read_text()
    suites = re.findall(r"--package (macos/\S+) --mode suites", workflow)
    assert suites == ["macos/HfFeatures/MainWindowFeature"]
    loop = re.search(r"for package in ([^;]+); do", workflow).group(1).split()
    covered = list(suites)
    for entry in loop:
        covered.extend(sorted(glob.glob(str(ROOT / entry))) if "*" in entry else [str(ROOT / entry)])
    covered = [str(Path(entry).resolve().relative_to(ROOT.resolve())) if Path(entry).is_absolute() else entry
               for entry in covered]
    expected = sorted(f"macos/{group}/{package}" for group, package in discovered_packages())
    assert sorted(covered) == expected


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
    assert args[args.index("-scheme") + 1] == "HarflowHost"
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
