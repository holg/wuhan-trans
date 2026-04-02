#!/bin/bash
# Regenerate Xcode project from project.yml
# Usage:
#   ./scripts/generate-project.sh              # just regenerate
#   ./scripts/generate-project.sh --archive    # regenerate + build archives + open Organizer
#   ./scripts/generate-project.sh --bump       # bump build number + regenerate
#   ./scripts/generate-project.sh --bump --archive  # bump + regenerate + archive
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

ARCHIVE=false
BUMP=false
for arg in "$@"; do
    case $arg in
        --archive) ARCHIVE=true ;;
        --bump) BUMP=true ;;
    esac
done

# Bump build number if requested
if $BUMP; then
    CURRENT=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | awk '{print $2}')
    NEXT=$((CURRENT + 1))
    sed -i '' "s/CURRENT_PROJECT_VERSION: $CURRENT/CURRENT_PROJECT_VERSION: $NEXT/g" project.yml
    echo "Build number bumped: $CURRENT → $NEXT"
fi

# Generate Xcode project
xcodegen generate

# Restore entitlements (xcodegen clears them)
cat > VoiceTranslate/VoiceTranslate.entitlements << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
</plist>
PLIST

# Patch: Add "Embed Watch Content" build phase to iOS target
# XcodeGen doesn't create this automatically for watchOS dependencies
python3 << 'PYEOF'
import re, sys

with open("VoiceTranslate.xcodeproj/project.pbxproj", "r") as f:
    content = f.read()

# Find the watch app product reference
watch_ref = re.search(r'(\w+) /\* VoiceTranslateWatch\.app \*/ = \{isa = PBXFileReference', content)
if not watch_ref:
    print("Warning: VoiceTranslateWatch.app reference not found, skipping embed patch")
    sys.exit(0)

watch_file_ref = watch_ref.group(1)

# Check if embed phase already exists
if "Embed Watch Content" in content:
    print("Embed Watch Content phase already exists")
    sys.exit(0)

# Generate a unique ID (simple hash-based)
import hashlib
def make_id(seed):
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()

build_file_id = make_id("embed_watch_buildfile")
copy_phase_id = make_id("embed_watch_copyphase")

# Add PBXBuildFile for embedding
build_file_entry = f'\t\t{build_file_id} /* VoiceTranslateWatch.app in Embed Watch Content */ = {{isa = PBXBuildFile; fileRef = {watch_file_ref} /* VoiceTranslateWatch.app */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n'

# Insert build file entry after the last PBXBuildFile
last_buildfile = content.rfind("/* End PBXBuildFile section */")
content = content[:last_buildfile] + build_file_entry + content[last_buildfile:]

# Create CopyFiles build phase (dstSubfolderSpec = 16 = Watch content)
# Use platformFilters to restrict to iOS only
copy_phase = f'''
/* Begin PBXCopyFilesBuildPhase section */
\t\t{copy_phase_id} /* Embed Watch Content */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "$(CONTENTS_FOLDER_PATH)/Watch";
\t\t\tdstSubfolderSpec = 16;
\t\t\tfiles = (
\t\t\t\t{build_file_id} /* VoiceTranslateWatch.app in Embed Watch Content */,
\t\t\t);
\t\t\tname = "Embed Watch Content";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXCopyFilesBuildPhase section */
'''

# Add platform filter to the build file so it only embeds for iOS
content = content.replace(
    f'{build_file_id} /* VoiceTranslateWatch.app in Embed Watch Content */ = {{isa = PBXBuildFile; fileRef = {watch_file_ref} /* VoiceTranslateWatch.app */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};',
    f'{build_file_id} /* VoiceTranslateWatch.app in Embed Watch Content */ = {{isa = PBXBuildFile; fileRef = {watch_file_ref} /* VoiceTranslateWatch.app */; platformFilters = (ios, ); settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};'
)

# Insert before PBXFrameworksBuildPhase or PBXGroup
insert_point = content.find("/* Begin PBXFrameworksBuildPhase section */")
if insert_point == -1:
    insert_point = content.find("/* Begin PBXGroup section */")
content = content[:insert_point] + copy_phase + "\n" + content[insert_point:]

# Add copy phase to the iOS target's buildPhases
# Find the VoiceTranslate native target and its buildPhases array
ios_target = re.search(
    r'(/\* VoiceTranslate \*/ = \{[^}]*?isa = PBXNativeTarget;[^}]*?buildPhases = \(\s*\n)(.*?)(\s*\);)',
    content, re.DOTALL
)
if ios_target:
    phases = ios_target.group(2)
    new_phases = phases.rstrip() + f"\n\t\t\t\t{copy_phase_id} /* Embed Watch Content */,\n"
    content = content[:ios_target.start(2)] + new_phases + content[ios_target.end(2):]

with open("VoiceTranslate.xcodeproj/project.pbxproj", "w") as f:
    f.write(content)

print("Patched: Added Embed Watch Content build phase")
PYEOF

echo "Project generated."

if $ARCHIVE; then
    ARCHIVE_DIR="$SCRIPT_DIR/../build"
    mkdir -p "$ARCHIVE_DIR"

    echo ""
    echo "=== Building iOS archive ==="
    xcodebuild archive \
        -project VoiceTranslate.xcodeproj \
        -scheme VoiceTranslate \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_DIR/VoiceTranslate-iOS.xcarchive" \
        -quiet

    echo "=== Building macOS archive ==="
    xcodebuild archive \
        -project VoiceTranslate.xcodeproj \
        -scheme VoiceTranslate \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_DIR/VoiceTranslate-macOS.xcarchive" \
        -quiet

    echo ""
    echo "Archives saved to build/"
    echo "Opening Organizer..."
    open "$ARCHIVE_DIR/VoiceTranslate-iOS.xcarchive"
    open "$ARCHIVE_DIR/VoiceTranslate-macOS.xcarchive"
else
    echo "Open VoiceTranslate.xcodeproj in Xcode."
fi
