# EasySpeechAnalyzer

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
    // ロケールを省略すると日本語 (ja_JP) になります。
    // 英語にするなら EasySpeechAnalyzerManager(locale: Locale(identifier: "en_US")) のように指定。
    @State private var manager = EasySpeechAnalyzerManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                Text(manager.finalizedText + manager.volatileText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            Button(manager.isRecording ? "停止" : "録音開始") {
                if manager.isRecording {
                    manager.stopAnalyzer()
                } else {
                    manager.startAnalyzer { error in
                        print("認識に失敗: \(error)")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .task {
            // 端末で SpeechAnalyzer が使えるかを事前にチェックしたい場合に。
            let canUse = await manager.canUseAnalyzer()
            print("SpeechAnalyzer 利用可: \(canUse)")
        }
    }
}
```

### 公開 API

- `init(locale: Locale = Locale(identifier: "ja_JP"))`
- `var volatileText: AttributedString` — 認識中の暫定テキスト（確定すると空になる）
- `var finalizedText: AttributedString` — 確定したテキストの累積
- `var isRecording: Bool` — 録音中フラグ
- `func canUseAnalyzer() async -> Bool` — 端末・ロケールで `SpeechAnalyzer` が利用可能か
- `func startAnalyzer(onFailure:)` — 録音と認識の開始
- `func stopAnalyzer()` — 録音と認識の停止

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
