# Agent Prompt — VoiceTranslate (Arbeitstitel)

## Project Identity

On-device Chinese ↔ English ↔ German voice translator app for iOS and macOS. Pure Swift, SwiftUI, no cloud dependencies. Designed for real-world bilingual family conversations (Wuhan, China) and professional use in the European lighting industry.

## Developer Context

The developer (Holger) is an experienced Rust/Swift systems programmer running Trahe Consult, specializing in open-source lighting/BIM tooling. He has 13+ years industry experience, maintains multiple iOS apps via UniFFI/Swift, and is a contributor to Bevy and CubeCL/Burn. He communicates tersely, corrects imprecision directly, and prefers short prose over bullet lists. Do not over-explain fundamentals — he knows Xcode, code signing, Swift Package Manager, CoreML, and audio pipelines. Focus on architecture decisions, non-obvious gotchas, and correct API usage.

## Hardware Targets

- **iPhone 15 Pro Max**: A17 Pro, 8GB RAM (~5GB usable), 16-core ANE. Primary deployment target.
- **MacBook Pro M2 Max**: 96GB RAM. Development machine and secondary deployment target.

## Architecture

### Pipeline

```
Microphone (AVAudioEngine, 16kHz mono f32)
    → ASR (WhisperKit / Apple SpeechAnalyzer — user-selectable)
    → Language detection (from ASR output or manual toggle)
    → Translation (NLLB-200-distilled-600M via CoreML)
    → TTS (AVSpeechSynthesizer)
    → Speaker
```

### UX Pattern

Walkie-talkie mode: tap-to-speak, release to translate. Three-way language selector (🇨🇳 🇬🇧 🇩🇪) for source language — do NOT rely on auto-detection for short utterances between Chinese and English, it's unreliable with code-switching. Conversation history as scrollable chat view with original transcript + translation. Option to copy/share individual translations.

### Model Selection Strategy

Platform-adaptive model loading:

| Model | Size (Q5 GGUF) | Use Case |
|---|---|---|
| `BELLE-2/Belle-whisper-large-v3-zh` | ~600MB | macOS default — best Chinese accuracy |
| `BELLE-2/Belle-whisper-large-v3-turbo-zh` | ~400MB | iOS default — best accuracy/speed tradeoff |
| `openai/whisper-small` | ~170MB | iOS fallback — lower RAM, continuous mode |
| Apple SpeechAnalyzer | 0MB (OS-provided) | Fallback — no additional memory cost |

The user should be able to switch between ASR engines in a settings screen. The app must display which engine is active.

Belle models are fine-tuned specifically for Chinese (24-65% improvement over base Whisper on AISHELL/WenetSpeech/HKUST benchmarks) while retaining English and German capability from the base Whisper weights.

### Memory Budget (iPhone 15 Pro Max)

```
Target: ≤ 2.5GB total app memory
├── ASR model (Belle-turbo Q5):     ~400MB
├── NLLB-200-distilled-600M CoreML: ~600MB
├── Audio buffers + app:            ~200MB
└── Headroom:                       ~1.3GB
```

If using Belle-large-v3-zh on iPhone (Q5 ~600MB), total rises to ~1.4GB — functional but tight. Monitor memory pressure via `os_proc_available_memory()` and degrade gracefully (suggest switching to smaller model).

### Translation Model

`facebook/nllb-200-distilled-600M` — purpose-built translation model, 200 languages, strong zh↔en and zh↔de. Convert to CoreML on the M2 Max via `coremltools` from the HuggingFace checkpoint. This is a specialist translation model, NOT a generalist LLM — it will outperform Apple Foundation Models and generic LLM translation for this task.

Do NOT use Apple Foundation Models framework for translation — the developer has tested it and finds the Chinese quality insufficient.

### TTS

`AVSpeechSynthesizer` — zero memory overhead, built-in Chinese/English/German voices. Sufficient quality for a translator. Do NOT add WhisperKit TTSKit unless explicitly requested — it adds ~1GB memory pressure for marginal quality gain.

## Technical Decisions

### WhisperKit Integration

- Swift Package: `https://github.com/argmaxinc/whisperkit`
- Products needed: `WhisperKit` only (not TTSKit, not SpeakerKit)
- Always set language explicitly: `.language = "zh"` / `.language = "en"` / `.language = "de"` — do not rely on auto-detection
- For Belle models: convert from HuggingFace Transformers format to CoreML using `whisperkittools`, upload to a custom HuggingFace repo, load via `WhisperKitConfig(model: "...", modelRepo: "username/repo")`
- Alternative path: convert to GGUF via whisper.cpp scripts for quantization, then use via whisper.cpp with CoreML encoder

### CoreML Model Conversion (NLLB)

```bash
# On M2 Max development machine
pip install coremltools transformers torch
# Convert facebook/nllb-200-distilled-600M to CoreML
# Encoder-decoder architecture converts cleanly
# Target compute units: CPU_AND_NE (Neural Engine)
# Use float16 precision for CoreML
```

The NLLB conversion is the main integration challenge. The encoder-decoder seq2seq architecture with language tokens needs careful handling of the tokenizer and forced BOS token for target language selection.

### Audio Pipeline

- `AVAudioEngine` for mic capture
- Install a tap on the input node at 16kHz, mono, f32
- Feed audio chunks to WhisperKit's streaming API
- Voice Activity Detection: WhisperKit includes VAD — use it to detect speech boundaries for walkie-talkie mode auto-stop

### Platform Parity

Single SwiftUI codebase. Use `#if os(macOS)` / `#if os(iOS)` only for:
- Default model selection (larger on Mac)
- UI layout adaptations (sidebar vs tab on Mac)
- No platform-specific audio or ML code — all shared frameworks

### Offline Operation

Everything runs offline. No network calls after initial model download. This is critical — the app must work in China where Google/OpenAI services are blocked and connectivity may be unreliable.

Model downloads happen on first launch or in settings. Show download progress. Cache models in the app's documents directory.

## Project Structure

```
VoiceTranslate/
├── App/
│   ├── VoiceTranslateApp.swift
│   └── ContentView.swift
├── Features/
│   ├── Conversation/
│   │   ├── ConversationView.swift        # Chat-style transcript + translations
│   │   ├── ConversationViewModel.swift   # Orchestrates ASR → translate → TTS
│   │   └── MessageBubble.swift
│   ├── Recording/
│   │   ├── AudioRecorder.swift           # AVAudioEngine wrapper
│   │   └── WalkieTalkieButton.swift      # Press-to-speak UI
│   └── Settings/
│       ├── SettingsView.swift
│       ├── ModelPickerView.swift          # ASR engine selection + download
│       └── LanguagePickerView.swift
├── Services/
│   ├── ASR/
│   │   ├── ASRService.swift              # Protocol
│   │   ├── WhisperKitASR.swift           # WhisperKit implementation
│   │   └── AppleSpeechASR.swift          # SpeechAnalyzer/SFSpeechRecognizer fallback
│   ├── Translation/
│   │   └── NLLBTranslator.swift          # CoreML NLLB inference
│   └── TTS/
│       └── SpeechSynthesizer.swift       # AVSpeechSynthesizer wrapper
├── Models/
│   └── (CoreML .mlmodelc bundles or downloaded at runtime)
├── Utilities/
│   ├── MemoryMonitor.swift               # Track available memory, suggest model downgrade
│   └── LanguageDetection.swift
└── Resources/
    └── Assets.xcassets
```

## Constraints

- No AI-generated code pasted without review — the developer reviews all output. Claude's role is architecture, API guidance, and code drafting for review.
- No cloud/API fallbacks. Fully on-device or nothing.
- Three languages only: zh (Simplified Chinese / Mandarin), en, de. No need to support other languages.
- App Store deployment intended — follow Apple review guidelines, no private API usage.
- Minimum deployment target: iOS 17 (for WhisperKit compatibility) / macOS 14.

## Open Questions to Resolve During Development

1. **NLLB CoreML conversion**: Does the distilled-600M encoder-decoder convert cleanly to CoreML with coremltools? What compute unit configuration (CPU_AND_NE vs CPU_AND_GPU) gives best latency on A17 Pro?
2. **Belle model conversion**: WhisperKit's `whisperkittools` or whisper.cpp's GGUF conversion — which path yields better quality/speed on device? Test both.
3. **Streaming vs batch ASR**: WhisperKit supports streaming — does Belle-turbo maintain quality in streaming mode or does it need full-utterance batch inference?
4. **Wuhan accent handling**: Real-world testing with family members. If Belle-turbo struggles with local accent, consider whisper-medium as alternative (broader training data, less Chinese-specific tuning but more accent diversity).
5. **Memory pressure on iPhone**: Profile actual peak memory during ASR + translation pipeline overlap. May need to sequence (unload ASR before loading NLLB) if both don't fit simultaneously.

## Success Criteria

The app works at a family dinner in Wuhan. Someone speaks Mandarin, the phone translates to English or German, and speaks it aloud. The other person responds in English or German, the phone translates to Mandarin. Latency under 3 seconds end-to-end in walkie-talkie mode. Works offline. Does not crash from memory pressure after 30 minutes of use.

