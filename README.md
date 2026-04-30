# EasySpeechAnalyzer

[日本語版はこちら](./README.ja.md)

EasySpeechAnalyzer is a thin wrapper library that makes the iOS 26 `SpeechAnalyzer` usable from SwiftUI in just a few lines.
Because it exposes state via `@Observable`, you can build a real-time transcription UI by simply holding it in SwiftUI `@State`.

It also includes `EasySpeechRecognizerManager` as a fallback for environments where `SpeechAnalyzer` is not available (or when you prefer the legacy `SFSpeechRecognizer`).

## Requirements

- iOS 26.0+
- Swift 6.0+

## Installation

Add the package to `dependencies` in your `Package.swift`.

```swift
.package(url: "https://github.com/<your-account>/EasySpeechAnalyzer.git", from: "1.0.0")
```

Then add `EasySpeechAnalyzer` to the target's `dependencies`.

```swift
.target(
    name: "YourApp",
    dependencies: ["EasySpeechAnalyzer"]
)
```

## Required `Info.plist` keys

To request microphone access and speech recognition permissions, add the following privacy keys to your `Info.plist`.

| Key | Purpose |
| --- | --- |
| `NSMicrophoneUsageDescription` | Why the app needs microphone input |
| `NSSpeechRecognitionUsageDescription` | Why the app uses speech recognition (fallback) |

Example:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to transcribe your speech.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>This app uses speech recognition to convert speech to text.</string>
```

## Basic usage (SwiftUI)

Hold an `EasySpeechAnalyzerManager` in `@State`, and toggle start/stop with a button.

```swift
import SwiftUI
import EasySpeechAnalyzer

struct TranscriptionView: View {
    @State private var manager = EasySpeechAnalyzerManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                Text(manager.transcriptText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            Button(manager.state.isRecording ? "Stop" : "Start recording") {
                Task {
                    if manager.state.isRecording {
                        await manager.stopAnalyzer()
                    } else {
                        do {
                            try await manager.startAnalyzer()
                        } catch {
                            print("Recognition failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
```

### UI branching with `state`

By checking `state`, you can distinguish between preparing, recording, finishing, completed, and failed.

```swift
switch manager.state {
case .idle, .completed:
    Text("Idle")
case .preparing:
    ProgressView("Preparing…")
case .recording:
    Text("Transcribing…")
case .finishing:
    ProgressView("Stopping…")
case .failed(let message):
    Text("Error: \(message)").foregroundStyle(.red)
}
```

### Get availability with a reason

Use `checkAvailability()` to get an `enum` that includes the reason when the analyzer is not available, making UI messaging straightforward.

```swift
switch await manager.checkAvailability() {
case .available:
    break
case .unsupportedLocale(let locale):
    errorMessage = "This language (\(locale.identifier)) is not supported for on-device transcription."
case .microphonePermissionDenied:
    errorMessage = "Microphone permission is denied."
case .speechRecognitionPermissionDenied:
    errorMessage = "Speech recognition permission is denied."
case .analyzerUnavailable:
    errorMessage = "Failed to obtain the analyzer format on this device."
case .unsupportedOS:
    errorMessage = "iOS 26 or later is required."
}
```

Each case also provides `defaultMessage`, so `availability.defaultMessage` is fine for a quick message.

### Export as subtitle clips

You can stop recording and segment the transcript into subtitle clips in two lines.

```swift
let transcript = await manager.stopAndMakeTranscript()
let subtitles = transcript.makeSubtitleSegments() // [SubtitleSegment]
```

Switch presets for short videos vs. long-form videos via `SubtitleSegmentationOptions`.

```swift
let subtitles = transcript.makeSubtitleSegments(options: .longFormDefault)
```

You can also customize freely.

```swift
let subtitles = transcript.makeSubtitleSegments(options: .init(
    maxCharactersPerLine: 16,
    maxLines: 2,
    maxDuration: 3.5,
    minDuration: 0.7,
    splitByPunctuation: true
))
```

### Start over

`reset()` clears all internal state and recognition results (it stops recording first if currently recording).

```swift
await manager.reset()
```

### Public API (`EasySpeechAnalyzerManager`)

- `init(locale: Locale = Locale(identifier: "ja_JP"))`
- State
  - `var state: SpeechAnalyzerState` — `.idle` / `.preparing` / `.recording` / `.finishing` / `.completed` / `.failed(String)`
  - `var isRecording: Bool` (shortcut for `state.isRecording`)
  - `var startedAt: Date?`, `var endedAt: Date?`
- Recognition results (real-time)
  - `var finalizedSegments: [SpeechSegment]` — finalized segments for subtitle materials
  - `var volatileSegment: SpeechSegment?` — latest non-final segment
  - `var transcriptText: String` — concatenated full text
  - `var finalizedPlainText: String` / `var volatilePlainText: String`
  - `var finalizedText: AttributedString` / `var volatileText: AttributedString` (compat)
- Lifecycle
  - `func checkAvailability() async -> SpeechAnalyzerAvailability`
  - `func canUseAnalyzer() async -> Bool` (thin wrapper)
  - `func startAnalyzer() async throws` — recommended
  - `func startAnalyzer(onFailure:)` — compatibility API for SwiftUI button wiring
  - `func stopAnalyzer() async`
  - `func stopAndMakeTranscript() async -> SpeechTranscript` — stop + get transcript
  - `func makeTranscript() -> SpeechTranscript` — snapshot while recording
  - `func reset() async` — clear all and return to `.idle`
  - `func resetTranscriptOnly()` — clear results only (does not touch state while recording)

### Model types

- `SpeechSegment` — `id` / `text` / `startTime` / `endTime` / `confidence?` / `isFinal` / `duration`
- `SpeechTranscript` — `text` / `segments` / `locale` / `duration?` / `createdAt` (+ `finalizedSegments` `volatileSegments` `makeSubtitleSegments(options:)`)
- `SpeechAnalyzerState` — state enum for UI branching
- `SpeechAnalyzerAvailability` — the reason when unavailable
- `SubtitleSegment` — a subtitle clip
- `SubtitleSegmentationOptions` — presets: `.shortVideoDefault` / `.longFormDefault`

## File/Video analysis: `EasySpeechFileAnalyzer`

If you want to transcribe pre-recorded audio or the audio track inside a video (instead of microphone input), use `EasySpeechFileAnalyzer`.
It is a stateless one-shot API, so it is safe to call multiple times.

### Basic

```swift
import EasySpeechAnalyzer

let analyzer = EasySpeechFileAnalyzer(locale: Locale(identifier: "ja_JP"))

// Audio file (.m4a / .wav / .caf, etc.)
let audioResult = try await analyzer.analyzeAudioFile(at: audioURL) { progress in
    print("audio progress: \(Int(progress * 100))%")
}
print(audioResult.plainText)

// Video file (.mp4 / .mov, etc.)
let videoResult = try await analyzer.analyzeVideoFile(at: videoURL) { progress in
    print("video progress: \(Int(progress * 100))%")
}
print(videoResult.plainText)
```

### Debuggability

- **Logger**: Pass an `@Sendable (String) -> Void` to `init(logger:)` to get step-by-step logs (file open, model download, analysis start, finalize, etc.). For quick checks, you can use the built-in `EasySpeechFileAnalyzer.printLogger`.

  ```swift
  let analyzer = EasySpeechFileAnalyzer(
      locale: Locale(identifier: "ja_JP"),
      logger: EasySpeechFileAnalyzer.printLogger
  )
  ```

- **Progress**: Receive 0.0–1.0 progress via the `progress` closure. Useful for long files.

- **Structured errors**: Failures are reported as `EasySpeechFileAnalyzerError` cases (e.g. `.localeNotSupported(_)`, `.fileUnreadable(_:underlying:)`, `.noAudioTrack(_)`, `.modelDownloadFailed(underlying:)`, `.readerFailed(_:status:underlying:)`, etc.). `description` is formatted to quickly identify the failure point.

- **Result**: `EasySpeechFileResult` includes raw text (`plainText`), `AttributedString` (`text` with `audioTimeRange` attributes), elapsed seconds (`elapsedSeconds`), and the `AVAudioFormat` chosen by `SpeechAnalyzer` (`analyzerFormat`).

### Public API (`EasySpeechFileAnalyzer`)

- `init(locale: Locale = Locale(identifier: "ja_JP"), logger: ((String) -> Void)? = nil)`
- `static let printLogger: (String) -> Void`
- `func analyzeAudioFile(at url: URL, progress: ((Double) -> Void)? = nil) async throws -> EasySpeechFileResult`
- `func analyzeVideoFile(at url: URL, progress: ((Double) -> Void)? = nil) async throws -> EasySpeechFileResult`

## Fallback: `EasySpeechRecognizerManager`

When `SpeechAnalyzer` is unavailable or you need to run outside the supported locales, you can use `EasySpeechRecognizerManager`, which wraps the legacy `SFSpeechRecognizer`.

```swift
import SwiftUI
import EasySpeechAnalyzer

struct FallbackTranscriptionView: View {
    @State private var manager = EasySpeechRecognizerManager(locale: Locale(identifier: "ja_JP"))

    var body: some View {
        VStack(spacing: 16) {
            Text(manager.recognizedText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Button(manager.isRecording ? "Stop" : "Start recording") {
                if manager.isRecording {
                    manager.stopRecognition()
                } else {
                    manager.startRecognition()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}
```

### Public API

- `init(locale: Locale = Locale(identifier: "ja_JP"))`
- `var recognizedText: String` — latest recognition result (no distinction between interim/final)
- `var isRecording: Bool` — whether currently recording
- `func startRecognition()`
- `func stopRecognition()`

## License

See `LICENSE` in this repository.
