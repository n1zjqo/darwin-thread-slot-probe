"""Structural checks only; not a substitute for Xcode/Swift compilation."""
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
project = (ROOT / "Switch2IOS.xcodeproj/project.pbxproj").read_text()
definitions = re.findall(r"^\s*([0-9A-F]{24}) = \{", project, re.M)
assert len(definitions) == len(set(definitions)), "Duplicate Xcode object ID"
references = set(re.findall(r"\b[0-9A-F]{24}\b", project))
assert references == set(definitions), "Dangling Xcode object reference"
for filename in ["Switch2IOSApp.swift", "ContentView.swift", "InputInventory.swift", "SessionModel.swift", "PayloadValidator.swift", "LoadedInspection.swift", "PreparedInspection.swift", "LinkInspection.swift", "RuntimeBridge.h", "Info.plist"]:
    assert (ROOT / "Switch2IOS" / filename).is_file()
    assert f"path = {filename};" in project
for relative in [f"../runtime/{folder}/{name}.{suffix}" for name in ("s2i_nso", "s2i_dynamic", "s2i_module", "s2i_prepared", "s2i_link_plan") for folder, suffix in (("include", "h"), ("src", "c"))]:
    assert (ROOT / relative).is_file()
    assert f"path = {relative};" in project
assert 'SWIFT_OBJC_BRIDGING_HEADER = Switch2IOS/RuntimeBridge.h;' in project
info = plistlib.loads((ROOT / "Switch2IOS/Info.plist").read_bytes())
assert info["CFBundlePackageType"] == "APPL"
assert info["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"] is False
scheme = ET.parse(ROOT / "Switch2IOS.xcodeproj/xcshareddata/xcschemes/Switch2IOS.xcscheme")
for ref in scheme.findall(".//BuildableReference"):
    assert ref.attrib["BlueprintIdentifier"] in definitions
assert scheme.find(".//TestAction/Testables/TestableReference") is not None
print("iOS project structural checks passed; Swift compilation and Apple-platform tests NOT run.")

# A path/file-reference alone does not compile a source. Resolve build-phase
# membership separately for the app and test targets. Still not a compiler check.
objects = dict(re.findall(r"^\s*([0-9A-F]{24}) = \{([^{}]*)\};", project, re.M))
def source_paths(phase_id):
    phase = objects[phase_id]
    assert "isa = PBXSourcesBuildPhase;" in phase
    ids = re.search(r"files = \(([^)]*)\)", phase).group(1)
    paths = []
    for build_id in re.findall(r"[0-9A-F]{24}", ids):
        ref = re.search(r"fileRef = ([0-9A-F]{24});", objects[build_id]).group(1)
        paths.append(re.search(r"path = ([^;]+);", objects[ref]).group(1))
    assert len(paths) == len(set(paths)), "Duplicate source membership"
    return set(paths)
app_sources = source_paths("000000000000000000000006")
assert {"Switch2IOSApp.swift", "ContentView.swift", "InputInventory.swift",
        "SessionModel.swift", "PayloadValidator.swift", "LoadedInspection.swift",
        "../runtime/src/s2i_nso.c", "../runtime/src/s2i_dynamic.c",
        "../runtime/src/s2i_module.c", "../runtime/src/s2i_prepared.c", "PreparedInspection.swift", "LinkInspection.swift", "../runtime/src/s2i_link_plan.c"} <= app_sources
test_sources = source_paths("00000000000000000000002C")
assert {"InputInventoryTests.swift", "LoadedInspectionTests.swift", "PreparedInspectionTests.swift", "LinkInspectionTests.swift"} <= test_sources
for filename in test_sources:
    assert (ROOT / "Switch2IOSTests" / filename).is_file()
bridge = (ROOT / "Switch2IOS/RuntimeBridge.h").read_text()
for header in ("s2i_nso.h", "s2i_dynamic.h", "s2i_module.h", "s2i_prepared.h", "s2i_link_plan.h"):
    assert f'#include "{header}"' in bridge
print("Owned, prepared and link inventory inspection bridge and app/test source membership passed (structural only).")

# The native fixture is test-only, with no production bridge exposure.
native_sources = {"X18NativeFixture.c", "X18NativeFixture.S", "X18NativeTests.m"}
assert native_sources <= test_sources
assert native_sources.isdisjoint(app_sources)
assert "X18NativeFixture" not in bridge
assert (ROOT / "Switch2IOSTests/X18NativeFixture.h").is_file()
print("Native owned fixture source membership is test-only; no Apple build or execution performed.")
