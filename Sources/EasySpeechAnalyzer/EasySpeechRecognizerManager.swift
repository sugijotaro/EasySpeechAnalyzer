//
//  EasySpeechRecognizerManager.swift
//  EasySpeechAnalyzer
//

@preconcurrency import AVFoundation
import Foundation
import Speech

/// `SFSpeechRecognizer` をベースにした、フォールバック用の音声認識マネージャー。
///
/// `SpeechAnalyzer` が利用できない環境（旧 OS バージョン、対応していないロケール等）でも動作する。
@MainActor
@Observable
public final class EasySpeechRecognizerManager {
    private let speechRecognizer: SFSpeechRecognizer?
    private let audioSession = AVAudioSession.sharedInstance()
    private let audioEngine = AVAudioEngine()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var recognitionTaskWrapper: Task<Void, Error>?
    private var hasInputTap = false

    /// 認識中・確定済みを区別しないリアルタイムの結果テキスト。
    public private(set) var recognizedText: String = ""
    /// 録音中かどうか。
    public private(set) var isRecording: Bool = false

    /// 任意のロケールでマネージャーを生成する。
    /// - Parameter locale: 認識に用いるロケール。デフォルトは日本語 (`ja_JP`)。
    public init(locale: Locale = Locale(identifier: "ja_JP")) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - Public API

    /// 録音と認識を開始する。
    public func startRecognition() {
        Task {
            do {
                guard recognitionTask == nil else {
                    return
                }

                guard await requestSpeechRecognizerPermission() else {
                    return
                }

                try setupAudioSession()

                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                self.recognitionRequest = request

                isRecording = true
                recognizedText = ""

                recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                    guard let self else { return }

                    if let result, !result.bestTranscription.formattedString.isEmpty {
                        let formatted = result.bestTranscription.formattedString
                        let isFinal = result.isFinal
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.recognizedText = formatted
                            if isFinal {
                                await self.completeRecognitionSession()
                            }
                        }
                    }

                    if let error {
                        let nsError = error as NSError
                        if !Self.isCancellationError(nsError) {
                            // ここではエラーをユーザーに伝搬しないため、握り潰す。
                        }
                        Task { @MainActor [weak self] in
                            await self?.completeRecognitionSession()
                        }
                        return
                    }
                }

                recognitionTaskWrapper = Task { [weak self] in
                    guard let self else { return }
                    do {
                        for try await buffer in try self.audioBufferStream() {
                            self.recognitionRequest?.append(buffer)
                        }
                    } catch is CancellationError {
                        // 停止に伴う意図的なキャンセル。
                    } catch {
                        await self.cleanupAfterStartFailure()
                    }
                }
            } catch {
                await cleanupAfterStartFailure()
            }
        }
    }

    /// 録音と認識を停止する。
    public func stopRecognition() {
        Task {
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            recognitionTaskWrapper?.cancel()
            recognitionTaskWrapper = nil

            stopAudioEngine()

            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

            isRecording = false
        }
    }
}

// MARK: - AudioEngine

private extension EasySpeechRecognizerManager {
    func setupAudioSession() throws {
        try audioSession.setCategory(.record, mode: .measurement)
        try audioSession.setActive(true)
    }

    func requestSpeechRecognizerPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized:
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                case .denied, .restricted, .notDetermined:
                    continuation.resume(returning: false)
                @unknown default:
                    continuation.resume(returning: false)
                }
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

    func completeRecognitionSession() async {
        recognitionTask = nil
        recognitionTaskWrapper?.cancel()
        recognitionTaskWrapper = nil
        recognitionRequest = nil

        stopAudioEngine()

        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

        isRecording = false
    }

    static func isCancellationError(_ error: NSError) -> Bool {
        let message = error.localizedDescription.lowercased()
        return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || message.contains("canceled")
            || message.contains("cancelled")
    }

    func cleanupAfterStartFailure() async {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionTaskWrapper?.cancel()
        recognitionTaskWrapper = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        stopAudioEngine()

        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

        isRecording = false
    }
}
