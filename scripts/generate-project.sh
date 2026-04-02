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
