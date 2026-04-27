//
//  EasySpeechAnalyzerManager.swift
//  EasySpeechAnalyzer
//

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// `SpeechAnalyzer` 利用時に発生し得るエラー。
@available(iOS 26.0, *)
public enum EasySpeechAnalyzerError: Error, LocalizedError {
    case localeNotSupported
    case analyzerUnavailable
    case recordPermissionDenied
    case invalidAudioDataType
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .localeNotSupported:
            return "指定されたロケールはこの端末で対応していません。"
        case .analyzerUnavailable:
            return "SpeechAnalyzer を利用できません。"
        case .recordPermissionDenied:
            return "マイクの利用が許可されていません。"
        case .invalidAudioDataType:
            return "音声データのフォーマットが不正です。"
        case .alreadyRunning:
            return "既に録音/解析を実行中です。"
        }
    }
}

/// iOS 26 以降で利用可能な `SpeechAnalyzer` を簡単に扱うためのマネージャー。
///
/// 主な使い方は 2 通り。
///
/// **A. SwiftUI でリアルタイム表示**
/// ```swift
/// @State private var manager = EasySpeechAnalyzerManager()
/// // body 内で
/// Text(manager.transcriptText)
/// Button(manager.state.isRecording ? "停止" : "開始") {
///     Task {
///         if manager.state.isRecording {
///             _ = await manager.stopAndMakeTranscript()
///         } else {
///             try await manager.startAnalyzer()
///         }
///     }
/// }
/// ```
///
/// **B. 字幕編集アプリで使う**
/// ```swift
/// let transcript = await manager.stopAndMakeTranscript()
/// let subtitles = transcript.makeSubtitleSegments()
/// ```
@available(iOS 26.0, *)
@MainActor
@Observable
public final class EasySpeechAnalyzerManager {
    // MARK: - Stored config

    private let locale: Locale
    private let audioSession = AVAudioSession.sharedInstance()
    private let audioEngine = AVAudioEngine()
    private let speechTranscriber: SpeechTranscriber
    private let speechAnalyzer: SpeechAnalyzer
    private let bufferConverter = BufferConverter()

    // MARK: - Private session state

    private var inputSequence: AsyncStream<AnalyzerInput>?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognitionTask: Task<Void, Never>?
    private var bufferPumpingTask: Task<Void, Never>?
    private var audioBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var hasInputTap = false

    // MARK: - Public observable state

    /// 現在の状態。UI の分岐根拠として使う。
    public private(set) var state: SpeechAnalyzerState = .idle

    /// 確定済みのセグメント (字幕クリップの素)。録音中に逐次追加される。
    public private(set) var finalizedSegments: [SpeechSegment] = []

    /// 暫定の (まだ確定していない) 直近セグメント。`finalizedSegments` の末尾に置きたいときに使う。
    public private(set) var volatileSegment: SpeechSegment?

    /// 認識中の暫定テキスト (AttributedString)。互換のため残している。
    public private(set) var volatileText: AttributedString = ""
    /// 確定済みの認識テキストの累積 (AttributedString)。互換のため残している。
    public private(set) var finalizedText: AttributedString = ""

    /// 録音を開始した時刻 (アプリ側で経過時間を出すのに使える)。
    public private(set) var startedAt: Date?
    /// 直近の録音/解析セッションが終了した時刻。
    public private(set) var endedAt: Date?

    // MARK: - Public derived state

    /// 録音中かどうか (`state == .recording` の糖衣)。
    public var isRecording: Bool { state.isRecording }

    /// 確定テキストのプレーン文字列表現。
    public var finalizedPlainText: String { String(finalizedText.characters) }
    /// 暫定テキストのプレーン文字列表現。
    public var volatilePlainText: String { String(volatileText.characters) }
    /// 確定 + 暫定をつないだ最終的な表示用テキスト。
    public var transcriptText: String { finalizedPlainText + volatilePlainText }

    // MARK: - Init

    /// 任意のロケールでマネージャーを生成する。
    /// - Parameter locale: 認識に用いるロケール。デフォルトは日本語 (`ja_JP`)。
    public init(locale: Locale = Locale(identifier: "ja_JP")) {
        self.locale = locale
        let speechTranscriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.speechTranscriber = speechTranscriber
        self.speechAnalyzer = SpeechAnalyzer(modules: [speechTranscriber])
    }

    // MARK: - Availability

    /// 現在の環境で `SpeechAnalyzer` が利用可能かを bool で返す簡易 API。
    public func canUseAnalyzer() async -> Bool {
        await checkAvailability() == .available
    }

    /// 端末/権限/ロケールを総合的にチェックする。
    /// 失敗理由を case で返すので、UI 上のエラーメッセージ分岐に使える。
    public func checkAvailability() async -> SpeechAnalyzerAvailability {
        // ロケール対応チェック
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let isLocaleSupported = supportedLocales
            .map { $0.identifier(.bcp47) }
            .contains(locale.identifier(.bcp47))
        guard isLocaleSupported else {
            return .unsupportedLocale(locale)
        }

        // SpeechAnalyzer のフォーマット確保
        guard await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [speechTranscriber]) != nil else {
            return .analyzerUnavailable
        }

        // マイク権限 (ここでは要求しない。明示的に拒否されている場合のみ報告)
        if AVAudioApplication.shared.recordPermission == .denied {
            return .microphonePermissionDenied
        }

        return .available
    }

    // MARK: - Start (async)

    /// 録音と認識を開始する (推奨形)。
    ///
    /// 内部のセットアップ (権限取得・モデル準備・解析セッション開始) が完了するまで `await` を待ち、
    /// その後マイクからのバッファ供給はバックグラウンド Task で続行される。
    public func startAnalyzer() async throws {
        guard state.canStart else {
            throw EasySpeechAnalyzerError.alreadyRunning
        }

        state = .preparing

        do {
            try await setupAnalyzer()

            guard let inputSequence, let inputBuilder else {
                throw EasySpeechAnalyzerError.analyzerUnavailable
            }

            guard await requestRecordPermission() else {
                throw EasySpeechAnalyzerError.recordPermissionDenied
            }

            try activateAudioSession()
            try await speechAnalyzer.start(inputSequence: inputSequence)

            startedAt = Date()
            endedAt = nil
            state = .recording

            // バッファ供給は別 Task に切り出す。失敗時は state を .failed にする。
            bufferPumpingTask = Task { [weak self, inputBuilder] in
                await self?.pumpAudioBuffers(inputBuilder: inputBuilder)
            }
        } catch {
            await teardown()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Start (callback, 互換用)

    /// 録音と認識を開始する (失敗時はクロージャで通知)。SwiftUI のボタンから直接呼びたい時に。
    public func startAnalyzer(onFailure: @escaping @MainActor @Sendable (Error) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startAnalyzer()
            } catch {
                onFailure(error)
            }
        }
    }

    // MARK: - Stop (async)

    /// 録音と認識を停止する。
    /// 結果を取り出したい場合は `stopAndMakeTranscript()` を使うほうが楽。
    public func stopAnalyzer() async {
        guard state == .recording || state == .preparing else { return }

        state = .finishing

        stopAudioEngine()
        try? deactivateAudioSession()

        inputBuilder?.finish()
        inputBuilder = nil
        inputSequence = nil

        do {
            try await speechAnalyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            // 停止時の失敗は致命的扱いしない
        }

        // recognitionTask が残りの結果を消化し終えるのを待つ
        if let recognitionTask {
            _ = await recognitionTask.value
        }
        recognitionTask = nil
        bufferPumpingTask?.cancel()
        bufferPumpingTask = nil

        endedAt = Date()
        state = .completed
    }

    // MARK: - Transcript

    /// 現時点でのスナップショットを返す。録音中でも呼べる。
    public func makeTranscript() -> SpeechTranscript {
        var allSegments = finalizedSegments
        if let volatileSegment {
            allSegments.append(volatileSegment)
        }
        let duration: TimeInterval?
        if let startedAt {
            let end = endedAt ?? Date()
            duration = end.timeIntervalSince(startedAt)
        } else {
            duration = nil
        }
        return SpeechTranscript(
            text: transcriptText,
            segments: allSegments,
            locale: locale,
            duration: duration,
            createdAt: Date()
        )
    }

    /// 停止 → スナップショット取得を一発で行うショートカット。字幕編集アプリ向け。
    @discardableResult
    public func stopAndMakeTranscript() async -> SpeechTranscript {
        await stopAnalyzer()
        return makeTranscript()
    }

    // MARK: - Reset

    /// 認識結果と内部状態をクリアして `idle` に戻す。
    /// 録音中だった場合は先に停止してから初期化する。
    public func reset() async {
        if state == .recording || state == .preparing {
            await stopAnalyzer()
        }

        finalizedText = ""
        volatileText = ""
        finalizedSegments = []
        volatileSegment = nil
        startedAt = nil
        endedAt = nil
        state = .idle
    }

    /// 同期版の `reset`。録音中の場合は停止せず単に状態だけ初期化する。
    /// (途中で `state` を初期化したいだけのときに使う。録音中なら別途停止が必要。)
    public func resetTranscriptOnly() {
        finalizedText = ""
        volatileText = ""
        finalizedSegments = []
        volatileSegment = nil
        if state == .completed || state.failureMessage != nil {
            startedAt = nil
            endedAt = nil
            state = .idle
        }
    }
}

// MARK: - Setup / pump / teardown

@available(iOS 26.0, *)
private extension EasySpeechAnalyzerManager {
    func setupAnalyzer() async throws {
        let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [speechTranscriber])
        guard let bestFormat else {
            throw EasySpeechAnalyzerError.analyzerUnavailable
        }
        self.analyzerFormat = bestFormat

        try await ensureModel(transcriber: speechTranscriber, locale: locale)

        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputSequence = sequence
        self.inputBuilder = builder

        let transcriber = speechTranscriber
        recognitionTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let attributed = result.text
                    if result.isFinal {
                        self.finalizedText += attributed
                        self.volatileText = ""
                        if let segment = Self.makeSegment(from: attributed, isFinal: true) {
                            self.finalizedSegments.append(segment)
                        }
                        self.volatileSegment = nil
                    } else {
                        self.volatileText = attributed
                        self.volatileSegment = Self.makeSegment(from: attributed, isFinal: false)
                    }
                }
            } catch {
                // ストリーム終了 or 認識失敗。state は呼び出し側 (stop/teardown) が更新する。
            }
        }
    }

    func pumpAudioBuffers(inputBuilder: AsyncStream<AnalyzerInput>.Continuation) async {
        do {
            let stream = try audioBufferStream()
            for await buffer in stream {
                try Task.checkCancellation()
                guard let analyzerFormat else {
                    throw EasySpeechAnalyzerError.invalidAudioDataType
                }
                let converted = try bufferConverter.convertBuffer(buffer, to: analyzerFormat)
                inputBuilder.yield(AnalyzerInput(buffer: converted))
            }
        } catch is CancellationError {
            // stop 経由のキャンセル
        } catch {
            await teardown()
            state = .failed(error.localizedDescription)
        }
    }

    func teardown() async {
        recognitionTask?.cancel()
        recognitionTask = nil
        bufferPumpingTask?.cancel()
        bufferPumpingTask = nil
        inputBuilder?.finish()
        inputBuilder = nil
        inputSequence = nil
        stopAudioEngine()
        try? deactivateAudioSession()
    }
}

// MARK: - Segment extraction

@available(iOS 26.0, *)
private extension EasySpeechAnalyzerManager {
    /// `SpeechTranscriber` の結果テキストから `SpeechSegment` を作る。
    /// `audioTimeRange` 属性を持つ run の最早 start・最遅 end を採用する。
    static func makeSegment(from attributed: AttributedString, isFinal: Bool) -> SpeechSegment? {
        let plain = String(attributed.characters)
        guard !plain.isEmpty else { return nil }

        var earliestStart: Double?
        var latestEnd: Double?

        for run in attributed.runs {
            guard let range = run.audioTimeRange else { continue }
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }
            if earliestStart == nil || start < earliestStart! {
                earliestStart = start
            }
            if latestEnd == nil || end > latestEnd! {
                latestEnd = end
            }
        }

        return SpeechSegment(
            text: plain,
            startTime: earliestStart ?? 0,
            endTime: latestEnd ?? 0,
            confidence: nil,
            isFinal: isFinal
        )
    }
}

// MARK: - AudioEngine

@available(iOS 26.0, *)
private extension EasySpeechAnalyzerManager {
    func activateAudioSession() throws {
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true)
    }

    func deactivateAudioSession() throws {
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func audioBufferStream() throws -> AsyncStream<AVAudioPCMBuffer> {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.inputFormat(forBus: 0)

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            of: AVAudioPCMBuffer.self,
            bufferingPolicy: .unbounded
        )
        self.audioBufferContinuation = continuation

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: recordingFormat) { buffer, _ in
            continuation.yield(buffer)
        }
        hasInputTap = true

        audioEngine.prepare()
        try audioEngine.start()

        return stream
    }

    func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }

        audioBufferContinuation?.finish()
        audioBufferContinuation = nil
    }
}

// MARK: - Speech To Text Model Helpers

@available(iOS 26.0, *)
private extension EasySpeechAnalyzerManager {
    func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        guard await supported(locale: locale) else {
            throw EasySpeechAnalyzerError.localeNotSupported
        }

        guard await !installed(locale: locale) else { return }
        try await downloadIfNeeded(for: transcriber)
    }

    func supported(locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    func installed(locale: Locale) async -> Bool {
        let installed = await Set(SpeechTranscriber.installedLocales)
        return installed.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    func downloadIfNeeded(for module: SpeechTranscriber) async throws {
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await downloader.downloadAndInstall()
        }
    }
}
