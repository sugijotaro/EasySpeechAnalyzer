//
//  EasySpeechAnalyzerManager.swift
//  EasySpeechAnalyzer
//

@preconcurrency import AVFoundation
import Foundation
import Speech

/// `SpeechAnalyzer` 利用時に発生し得るエラー。
@available(iOS 26.0, *)
public enum EasySpeechAnalyzerError: Error {
    case localeNotSupported
    case analyzerUnavailable
    case recordPermissionDenied
    case invalidAudioDataType
}

/// iOS 26 以降で利用可能な `SpeechAnalyzer` を簡単に扱うためのマネージャー。
///
/// `@Observable` であるため、SwiftUI からそのままバインドして利用できる。
/// `volatileText` と `finalizedText` を `Text` などに表示しつつ、
/// `startAnalyzer()` / `stopAnalyzer()` で録音と認識を制御する。
@available(iOS 26.0, *)
@MainActor
@Observable
public final class EasySpeechAnalyzerManager {
    private let locale: Locale
    private let audioSession = AVAudioSession.sharedInstance()
    private let audioEngine = AVAudioEngine()
    private let speechTranscriber: SpeechTranscriber
    private let speechAnalyzer: SpeechAnalyzer
    private let bufferConverter = BufferConverter()

    private var inputSequence: AsyncStream<AnalyzerInput>?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognitionTask: Task<Void, Error>?
    private var audioBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var hasInputTap = false
    private var isStopping = false

    /// 認識中の暫定テキスト。確定するとクリアされる。
    public private(set) var volatileText: AttributedString = ""
    /// 確定済みの認識テキストが追記されていく。
    public private(set) var finalizedText: AttributedString = ""
    /// 録音中かどうか。
    public private(set) var isRecording = false

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

    // MARK: - Public API

    /// 現在の環境で `SpeechAnalyzer` が利用可能かを確認する。
    public func canUseAnalyzer() async -> Bool {
        guard await supported(locale: locale) else {
            return false
        }
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [speechTranscriber]) != nil
    }

    /// 録音と認識を開始する。
    /// - Parameter onFailure: 失敗時に MainActor 上で呼び出されるクロージャ。
    public func startAnalyzer(onFailure: (@MainActor (Error) -> Void)? = nil) {
        Task {
            do {
                guard !isRecording else {
                    return
                }

                try await setupAnalyzer()

                guard let inputSequence, let inputBuilder else {
                    throw EasySpeechAnalyzerError.analyzerUnavailable
                }

                guard await requestRecordPermission() else {
                    throw EasySpeechAnalyzerError.recordPermissionDenied
                }

                try activateAudioSession()
                try await speechAnalyzer.start(inputSequence: inputSequence)

                isRecording = true

                for await buffer in try audioBufferStream() {
                    guard let analyzerFormat else {
                        throw EasySpeechAnalyzerError.invalidAudioDataType
                    }
                    let converted = try bufferConverter.convertBuffer(buffer, to: analyzerFormat)
                    inputBuilder.yield(AnalyzerInput(buffer: converted))
                }
            } catch {
                recognitionTask?.cancel()
                recognitionTask = nil
                inputBuilder?.finish()
                inputBuilder = nil
                inputSequence = nil
                stopAudioEngine()
                try? deactivateAudioSession()

                isRecording = false
                if !isStopping {
                    onFailure?(error)
                }
            }
        }
    }

    /// 録音と認識を停止する。
    public func stopAnalyzer() {
        Task {
            do {
                isStopping = true
                defer { isStopping = false }

                stopAudioEngine()
                try deactivateAudioSession()

                inputBuilder?.finish()
                inputBuilder = nil
                inputSequence = nil

                try await speechAnalyzer.finalizeAndFinishThroughEndOfInput()

                recognitionTask?.cancel()
                recognitionTask = nil

                isRecording = false
            } catch {
                // 停止処理中の失敗は致命的ではないため、状態だけ整える。
                isRecording = false
            }
        }
    }
}

// MARK: - Setup

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
                    let text = result.text
                    if result.isFinal {
                        self.finalizedText += text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                }
            } catch {
                // ストリームが終了したか、認識自体が失敗した場合に到達する。
            }
        }
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
