#!/bin/bash
set -euo pipefail

task_ios_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Use an installed Xcode even while the global selection still points to CLT.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcodebuild -version >/dev/null 2>&1 \
    && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

plutil -lint "$task_ios_dir/PitchLensDockKit/Info.plist" "$task_ios_dir/PitchLensDockKit.xcodeproj/project.pbxproj"
python3 - "$task_ios_dir" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
from xml.etree import ElementTree

root = Path(sys.argv[1])
project = json.loads(subprocess.check_output([
    'plutil', '-convert', 'json', '-o', '-', str(root / 'PitchLensDockKit.xcodeproj/project.pbxproj')
]))
objects = project['objects']
sources = []

def walk(group_id, parent):
    group = objects[group_id]
    location = parent / group.get('path', '')
    for child_id in group.get('children', []):
        child = objects[child_id]
        if child['isa'] == 'PBXGroup':
            walk(child_id, location)
        elif child.get('sourceTree') == '<group>':
            path = location / child['path']
            assert path.exists(), f'Missing project file: {path}'
            if path.suffix in {'.swift', '.mlpackage'}:
                sources.append(child_id)

walk(objects[project['rootObject']]['mainGroup'], root)
compiled = []
for obj in objects.values():
    if obj['isa'] == 'PBXSourcesBuildPhase':
        compiled.extend(objects[file_id]['fileRef'] for file_id in obj['files'])
assert sorted(compiled) == sorted(sources), 'Sources missing/duplicated in build phase'
scheme = ElementTree.parse(root / 'PitchLensDockKit.xcodeproj/xcshareddata/xcschemes/PitchLensDockKit.xcscheme')
for ref in scheme.iter('BuildableReference'):
    assert objects[ref.attrib['BlueprintIdentifier']]['isa'] == 'PBXNativeTarget'
print(f'Project references and scheme valid: {len(sources)} source files')
PY

swiftc -frontend -parse "$task_ios_dir"/PitchLensDockKit/*.swift "$task_ios_dir"/DockKitCore/Sources/DockKitCore/*.swift

swift run --package-path "$task_ios_dir/DockKitCore" MotorControllerChecks

if xcodebuild -version >/dev/null 2>&1; then
    xcodebuild -project "$task_ios_dir/PitchLensDockKit.xcodeproj" \
        -scheme PitchLensDockKit -configuration Debug \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$task_ios_dir/DerivedData" \
        CODE_SIGNING_ALLOWED=NO build
else
    printf '%s\n' 'iOS BUILD NOT RUN: Xcode and the iOS SDK are not available in the active developer directory.'
fi
