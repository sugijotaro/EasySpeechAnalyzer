# EasySpeechAnalyzer

[English README](./README.md)

iOS 26 から導入された `SpeechAnalyzer` を、SwiftUI から数行で扱えるようにした薄いラッパーライブラリです。  
`@Observable` で状態を公開しているため、SwiftUI の `@State` に持たせるだけでリアルタイムの文字起こし UI を構築できます。

`SpeechAnalyzer` がまだ使えない環境（旧来の `SFSpeechRecognizer` を使いたい場合）向けに、フォールバックとして `EasySpeechRecognizerManager` も同梱しています。

## 動作要件

- iOS 26.0 以降
- Swift 6.0 以降

## インストール

`Package.swift` の `dependencies` に追加します。

```swift
.package(url: "https://github.com/<your-account>/EasySpeechAnalyzer.git", from: "1.0.0")
```

利用するターゲットの `dependencies` に `EasySpeechAnalyzer` を追加してください。

```swift
.target(
    name: "YourApp",
    dependencies: ["EasySpeechAnalyzer"]
)
```

## Info.plist に必要なキー

マイクと音声認識の利用許可を取得するため、以下のプライバシーキーを `Info.plist` に追加してください。

| キー | 用途 |
| --- | --- |
| `NSMicrophoneUsageDescription` | マイク入力の利用理由 |
| `NSSpeechRecognitionUsageDescription` | 音声認識（フォールバック使用時）の利用理由 |

例:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>音声入力を文字起こしするためにマイクへのアクセスが必要です。</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>音声を文字に変換するために音声認識機能を使用します。</string>
```

## 基本的な使い方 (SwiftUI)

`EasySpeechAnalyzerManager` を `@State` として保持し、ボタンで録音の開始/停止を切り替えるだけです。

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

            Button(manager.state.isRecording ? "停止" : "録音開始") {
                Task {
                    if manager.state.isRecording {
                        await manager.stopAnalyzer()
                    } else {
                        do {
                            try await manager.startAnalyzer()
                        } catch {
                            print("認識に失敗: \(error.localizedDescription)")
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

### State による分岐

`state` を見れば「準備中」「録音中」「停止処理中」「失敗」が区別できます。

```swift
switch manager.state {
case .idle, .completed:
    Text("待機中")
case .preparing:
    ProgressView("準備中…")
case .recording:
    Text("文字起こし中…")
case .finishing:
    ProgressView("停止しています…")
case .failed(let message):
    Text("エラー: \(message)").foregroundStyle(.red)
}
```

### 利用可否を理由付きで取得する

`checkAvailability()` を使うと、使えない理由を `enum` で取れるので UI のメッセージ分岐が綺麗に書けます。

```swift
switch await manager.checkAvailability() {
case .available:
    break
case .unsupportedLocale(let locale):
    errorMessage = "この言語 (\(locale.identifier)) は端末上の文字起こしに対応していません"
case .microphonePermissionDenied:
    errorMessage = "マイクの使用が許可されていません"
case .speechRecognitionPermissionDenied:
    errorMessage = "音声認識の使用が許可されていません"
case .analyzerUnavailable:
    errorMessage = "この端末で認識フォーマットを取得できませんでした"
case .unsupportedOS:
    errorMessage = "iOS 26 以降が必要です"
}
```

すべてのケースに `defaultMessage` も生えているので、雑に使うなら `availability.defaultMessage` でも OK です。

### 字幕クリップとして取り出す

録音停止 → 字幕分割までを 2 行で書けます。

```swift
let transcript = await manager.stopAndMakeTranscript()
let subtitles = transcript.makeSubtitleSegments() // [SubtitleSegment]
```

`SubtitleSegmentationOptions` でショート動画向け / 横長動画向けのプリセットを切り替えられます。

```swift
let subtitles = transcript.makeSubtitleSegments(options: .longFormDefault)
```

カスタムも自由です。

```swift
let subtitles = transcript.makeSubtitleSegments(options: .init(
    maxCharactersPerLine: 16,
    maxLines: 2,
    maxDuration: 3.5,
    minDuration: 0.7,
    splitByPunctuation: true
))
```

### 録音をやり直す

`reset()` で内部状態と認識結果をすべて初期化できます (録音中なら停止してからクリア)。

```swift
await manager.reset()
```

### 公開 API (`EasySpeechAnalyzerManager`)

- `init(locale: Locale = Locale(identifier: "ja_JP"))`
- 状態
  - `var state: SpeechAnalyzerState` — `.idle` / `.preparing` / `.recording` / `.finishing` / `.completed` / `.failed(String)`
  - `var isRecording: Bool` (state.isRecording のショートカット)
  - `var startedAt: Date?`、`var endedAt: Date?`
- 認識結果 (リアルタイム)
  - `var finalizedSegments: [SpeechSegment]` — 確定済みの字幕クリップ素材
  - `var volatileSegment: SpeechSegment?` — 直近の暫定セグメント
  - `var transcriptText: String` — 全体の連結テキスト
  - `var finalizedPlainText: String` / `var volatilePlainText: String`
  - `var finalizedText: AttributedString` / `var volatileText: AttributedString` (互換用)
- ライフサイクル
  - `func checkAvailability() async -> SpeechAnalyzerAvailability`
  - `func canUseAnalyzer() async -> Bool` (薄いラッパー)
  - `func startAnalyzer() async throws` — 推奨形
  - `func startAnalyzer(onFailure:)` — SwiftUI ボタン直結用の互換 API
  - `func stopAnalyzer() async`
  - `func stopAndMakeTranscript() async -> SpeechTranscript` — 停止+結果取得を 1 行で
  - `func makeTranscript() -> SpeechTranscript` — 録音中にスナップショットを取りたい時
  - `func reset() async` — 全部クリアして `.idle` に戻す
  - `func resetTranscriptOnly()` — 結果だけ消す (録音中は state は触らない)

### モデル型

- `SpeechSegment` — `id` / `text` / `startTime` / `endTime` / `confidence?` / `isFinal` / `duration`
- `SpeechTranscript` — `text` / `segments` / `locale` / `duration?` / `createdAt` (+ `finalizedSegments` `volatileSegments` `makeSubtitleSegments(options:)`)
- `SpeechAnalyzerState` — UI 分岐用の状態 enum
- `SpeechAnalyzerAvailability` — `available` 以外は使えない理由を示す
- `SubtitleSegment` — 字幕 1 クリップ
- `SubtitleSegmentationOptions` — `.shortVideoDefault` / `.longFormDefault` プリセットあり

## ファイル/動画の解析: `EasySpeechFileAnalyzer`

マイク入力ではなく、録音済みオーディオや動画に含まれる音声を文字起こししたい場合は `EasySpeechFileAnalyzer` を使います。状態を持たない一発勝負の API なので、何度呼んでも安全です。

### 基本

```swift
import EasySpeechAnalyzer

let analyzer = EasySpeechFileAnalyzer(locale: Locale(identifier: "ja_JP"))

// オーディオファイル (.m4a / .wav / .caf など)
let audioResult = try await analyzer.analyzeAudioFile(at: audioURL) { progress in
    print("audio progress: \(Int(progress * 100))%")
}
print(audioResult.plainText)

// 動画ファイル (.mp4 / .mov など)
let videoResult = try await analyzer.analyzeVideoFile(at: videoURL) { progress in
    print("video progress: \(Int(progress * 100))%")
}
print(videoResult.plainText)
```

### デバッグしやすさ

- **ロガー**: `init(logger:)` に `@Sendable (String) -> Void` を渡すと、ファイルオープン・モデルダウンロード・解析開始・ファイナライズなどの段階が逐次出力されます。手早く確認したいだけなら組み込みの `EasySpeechFileAnalyzer.printLogger` を使えます。

  ```swift
  let analyzer = EasySpeechFileAnalyzer(
      locale: Locale(identifier: "ja_JP"),
      logger: EasySpeechFileAnalyzer.printLogger
  )
  ```

- **進捗**: `progress` クロージャで 0.0–1.0 の進捗を受け取れます。長尺ファイルでも今どこを処理しているか分かります。

- **構造化エラー**: 失敗時は `EasySpeechFileAnalyzerError` の各 case (例: `.localeNotSupported(_)`, `.fileUnreadable(_:underlying:)`, `.noAudioTrack(_)`, `.modelDownloadFailed(underlying:)`, `.readerFailed(_:status:underlying:)` など) で原因が特定できます。`description` をそのまま `print` するだけで失敗箇所が分かるよう整形済みです。

- **結果**: `EasySpeechFileResult` には素のテキスト (`plainText`)、`AttributedString` (`text`、`audioTimeRange` 属性付き)、解析にかかった秒数 (`elapsedSeconds`)、`SpeechAnalyzer` が選択した `AVAudioFormat` (`analyzerFormat`) が入っています。

### 公開 API (`EasySpeechFileAnalyzer`)

- `init(locale: Locale = Locale(identifier: "ja_JP"), logger: ((String) -> Void)? = nil)`
- `static let printLogger: (String) -> Void`
- `func analyzeAudioFile(at url: URL, progress: ((Double) -> Void)? = nil) async throws -> EasySpeechFileResult`
- `func analyzeVideoFile(at url: URL, progress: ((Double) -> Void)? = nil) async throws -> EasySpeechFileResult`

## フォールバック: `EasySpeechRecognizerManager`

`SpeechAnalyzer` が利用できない場合や、対応ロケール外で動作させたい場合は、従来の `SFSpeechRecognizer` をラップした `EasySpeechRecognizerManager` を利用できます。

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

            Button(manager.isRecording ? "停止" : "録音開始") {
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

### 公開 API

- `init(locale: Locale = Locale(identifier: "ja_JP"))`
- `var recognizedText: String` — 暫定/確定を区別しない最新の認識結果
- `var isRecording: Bool` — 録音中フラグ
- `func startRecognition()`
- `func stopRecognition()`

## ライセンス

このライブラリのライセンスはリポジトリの `LICENSE` を参照してください。

