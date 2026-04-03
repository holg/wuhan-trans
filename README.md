# VoiceTranslator - offline

On-device voice translator for iOS, macOS, and watchOS. Chinese, English, German + 23 more languages. Fully offline — no cloud dependencies.

## Features

- **Walkie-talkie UX** — press and hold to speak, release to translate and hear the result
- **Type to translate** — text input for when you can't speak
- **Multiple ASR engines** — Apple Speech, WhisperKit (Whisper Medium/Large v3), Belle (Chinese-optimized), Cohere Transcribe
- **Apple Translation framework** — on-device translation, no internet needed
- **Paired device mode** — connect two phones via Bluetooth/WiFi Direct (MultipeerConnectivity)
- **Internet relay** — connect devices anywhere in the world via WebSocket relay server
- **Multi-user rooms** — up to 10 people, each translates into their preferred language
- **Apple Watch companion** — dictate on your wrist, translated on your phone
- **Action Button shortcut** — toggle recording from iPhone 15 Pro Action Button
- **26 languages** with configurable 3-language quick selector

## Architecture

```
VoiceTranslate/          iOS + macOS app
VoiceTranslateWatch/     watchOS companion
Shared/                  Shared models (ConversationMessage, PeerMessage, etc.)
relay-server/            Rust WebSocket relay for internet pairing
scripts/                 Build, deploy, and setup scripts
fastlane/                App Store metadata (en/de/zh)
docs/                    Original app specification
```

## Quick Start

```bash
# Install dependencies
brew install xcodegen

# Generate Xcode project
./scripts/generate-project.sh

# Open in Xcode
open VoiceTranslate.xcodeproj

# Build + archive (bump version)
./scripts/generate-project.sh --bump --archive
```

## ASR Models

| Engine | Size | Languages | Notes |
|--------|------|-----------|-------|
| Apple Speech | 0 MB | System | Works immediately, no download |
| Whisper Medium | ~500 MB | 99 | Via WhisperKit, good multilingual |
| Whisper Large v3 | ~1 GB | 99 | Best accuracy |
| Whisper Large v3 Turbo | ~950 MB | 99 | Fast, near-best |
| Belle Large v3 Chinese | ~2.9 GB | zh/en/de | Chinese-optimized Whisper |
| Cohere Transcribe | ~1.4 GB | 14 | 6-bit CoreML, custom pipeline |

Models are downloaded on first use from HuggingFace:
- WhisperKit models: `argmaxinc/whisperkit-coreml`
- Belle: `holgt/belle-whisper-large-v3-zh-coreml`
- Cohere: `holgt/cohere-transcribe-coreml-compiled`

## Relay Server

A lightweight Rust WebSocket server for connecting devices over the internet. See [relay-server/README.md](relay-server/README.md).

```bash
# Deploy to your server
./scripts/deploy_to_server.sh setup
./scripts/deploy_to_server.sh deploy
```

Default relay: `wss://voice.rlxapi.eu` (configurable in app Settings).

## Device Pairing

### Nearby (MultipeerConnectivity)
Both devices on same WiFi or Bluetooth range. One taps "Host", other taps "Join". No internet needed.

### Internet (Relay)
One device creates a room → gets 6-digit code → other device enters code. Works worldwide. Up to 10 participants per room — each translates locally into their preferred language.

### Apple Watch
Dictate on watch → text sent to phone → phone translates → result shown on both + TTS on phone. Green dot on watch indicates phone connection.

## Build Requirements

- Xcode 17+ (macOS 26 / iOS 26 SDK)
- XcodeGen (`brew install xcodegen`)
- Swift 6
- For relay server: Rust toolchain + cross-compilation tools for Linux

## Privacy

Everything runs on-device. No data collection, no analytics, no cloud services. See [PRIVACY.md](PRIVACY.md).

## License

MIT
