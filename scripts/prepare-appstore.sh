#!/bin/bash
# Prepare App Store submission metadata and screenshots
# Usage: ./scripts/prepare-appstore.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
METADATA_DIR="$SCRIPT_DIR/../appstore"
SCREENSHOTS_DIR="$METADATA_DIR/screenshots"

mkdir -p "$SCREENSHOTS_DIR/iphone_6_7"
mkdir -p "$SCREENSHOTS_DIR/iphone_6_5"
mkdir -p "$SCREENSHOTS_DIR/ipad_12_9"
mkdir -p "$SCREENSHOTS_DIR/mac"
mkdir -p "$SCREENSHOTS_DIR/watch"

# --- Metadata ---
cat > "$METADATA_DIR/metadata.txt" << 'META'
=== App Store Metadata ===

App Name: VoiceTranslate
Subtitle: On-device Voice Translator

Category: Utilities
Secondary Category: Productivity

Price: Free

Privacy URL: https://github.com/holg/wuhan-trans/blob/main/PRIVACY.md
Support URL: https://github.com/holg/wuhan-trans

Keywords: translator, voice, chinese, german, english, offline, whisper, speech, translation, walkie-talkie

=== Description (4000 chars max) ===

VoiceTranslate is a fully on-device voice translator for Chinese, English, German and 23+ more languages. No internet required — perfect for travel, family conversations, and business meetings.

WALKIE-TALKIE TRANSLATION
Press and hold to speak, release to translate. Your speech is transcribed, translated, and spoken aloud in the target language — all in seconds, all on your device.

MULTIPLE ASR ENGINES
• Apple Speech — zero download, works immediately
• Whisper Medium / Large v3 — OpenAI's multilingual models via WhisperKit
• Belle Whisper Large v3 — Chinese-optimized for best Mandarin accuracy
• Cohere Transcribe — 14 languages, 6-bit optimized CoreML

PAIRED DEVICE MODE
Connect two phones via Bluetooth/WiFi Direct (no internet needed). Speak on one phone, hear the translation on the other. Perfect for bilingual conversations across a dinner table.

APPLE WATCH COMPANION
Record on your watch, hear the translation on your phone. Keep your phone in your pocket — your watch is the remote control.

FULLY OFFLINE
Everything runs on-device. No cloud services, no API keys, no data leaves your phone. Works in China, on airplanes, anywhere without connectivity.

FEATURES
• 26 languages with configurable quick-select
• Apple Translation framework for accurate translations
• Text-to-speech in all supported languages
• Copy/paste any transcript or translation
• Conversation history with search
• Action Button shortcut support (iPhone 15 Pro)
• iOS, macOS, and watchOS

=== What's New (Release Notes) ===

Initial release. On-device voice translation with walkie-talkie UX, paired device mode, and Apple Watch companion.

=== Promotional Text (170 chars max) ===

Speak in one language, hear it in another — completely offline. Walkie-talkie style voice translation for Chinese, English, German and 23+ more languages.

META

echo "Metadata written to $METADATA_DIR/metadata.txt"

# --- Screenshot instructions ---
cat > "$SCREENSHOTS_DIR/README.txt" << 'SHOTS'
=== Required Screenshots ===

Take screenshots on actual devices or use Xcode Window > Devices > Take Screenshot.
Then resize with sips if needed.

REQUIRED SIZES:
  iPhone 6.7" (iPhone 15 Pro Max): 1290 x 2796 — REQUIRED
  iPhone 6.5" (iPhone 11 Pro Max): 1242 x 2688 — optional (auto-generated from 6.7")

RECOMMENDED SHOTS (3-5 per device):
  1. Main conversation view with language flags visible
  2. Translation in progress (Chinese → English or German → Chinese)
  3. Settings with model picker
  4. Paired device connection screen
  5. Apple Watch companion showing translation

TO CAPTURE FROM CONNECTED DEVICE:
  xcrun devicectl device capture screenshot --device <UDID> --output screenshot.png

TO FIND DEVICE UDID:
  xcrun devicectl list devices

TO RESIZE:
  sips -z 2796 1290 screenshot.png --out iphone_6_7/01_main.png

SHOTS

echo "Screenshot instructions at $SCREENSHOTS_DIR/README.txt"
echo ""
echo "Next steps:"
echo "  1. Take screenshots on your iPhone 15 Pro Max"
echo "  2. Drop them in appstore/screenshots/iphone_6_7/"
echo "  3. Go to App Store Connect and fill in metadata from appstore/metadata.txt"
echo "  4. Upload screenshots"
