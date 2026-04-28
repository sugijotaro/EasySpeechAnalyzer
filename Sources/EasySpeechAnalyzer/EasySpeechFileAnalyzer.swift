//
//  EasySpeechFileAnalyzer.swift
//  EasySpeechAnalyzer
//

@preconcurrency import AVFoundation
import Foundation
import Speech

// MARK: - Result

/// ファイル/動画解析の結果。
@available(iOS 26.0, *)
public struct EasySpeechFileResult: Sendable {
    /// 認識された全文 (`AttributedString`)。`audioTimeRange` 属性付き。
    public let text: AttributedString
    /// `text` の素のテキスト表現。ログ出力やテキスト処理時に便利。
    public let plainText: String
    /// 解析にかかった実時間 (秒)。
    public let elapsedSeconds: TimeInterval
    /// 解析元メディアのおおよその長さ (秒)。取得できない場合は `nil`。
    public let sourceDuration: TimeInterval?
    /// 認識に使ったロケール。
    public let locale: Locale
    /// `SpeechAnalyzer` が選択した解析フォーマット。デバッグ時の状況確認用に保持する。
    public let analyzerFormat: AVAudioFormat
}

@available(iOS 26.0, *)
public extension EasySpeechFileResult {
    /// ファイル解析結果を `SpeechTranscript` に変換する。
    ///
    /// `text` に含まれる `audioTimeRange` 属性から、句読点・長さ・時間で区切ったセグメントを復元する。
    /// 属性が取得できない場合は `sourceDuration` を使い、最後のフォールバックとして `0...0` を返す。
    func makeSpeechTranscript(createdAt: Date = Date()) -> SpeechTranscript {
        makeSpeechTranscript(
            createdAt: createdAt,
            maxCharactersPerSegment: 56,
            maxDuration: 5.0
        )
    }

    /// ファイル解析結果から字幕セグメントを生成する。
    func makeSubtitleSegments(
        options: SubtitleSegmentationOptions = .shortVideoDefault
    ) -> [SubtitleSegment] {
        let maxCharacters = max(1, options.maxCharactersPerLine * options.maxLines)
        return makeSpeechTranscript(
            maxCharactersPerSegment: maxCharacters,
            maxDuration: options.maxDuration
        )
        .makeSubtitleSegments(options: options)
    }

    private func makeSpeechTranscript(
        createdAt: Date = Date(),
        maxCharactersPerSegment: Int,
        maxDuration: TimeInterval
    ) -> SpeechTranscript {
        let segments = makeSegmentsFromAudioTimeRanges(
            maxCharactersPerSegment: maxCharactersPerSegment,
            maxDuration: maxDuration
        )

        if !segments.isEmpty {
            return SpeechTranscript(
                text: plainText,
                segments: segments,
                locale: locale,
                duration: sourceDuration,
                createdAt: createdAt
            )
        }

        let segment = SpeechSegment(
            text: plainText,
            startTime: attributedAudioTimeRange?.start ?? 0,
            endTime: attributedAudioTimeRange?.end ?? sourceDuration ?? 0,
            confidence: nil,
            isFinal: true
        )

        return SpeechTranscript(
            text: plainText,
            segments: plainText.isEmpty ? [] : [segment],
            locale: locale,
            duration: sourceDuration,
            createdAt: createdAt
        )
    }

    private var attributedAudioTimeRange: (start: TimeInterval, end: TimeInterval)? {
        var earliestStart: TimeInterval?
        var latestEnd: TimeInterval?

        for run in text.runs {
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

        guard let earliestStart, let latestEnd else { return nil }
        return (earliestStart, latestEnd)
    }

    private func makeSegmentsFromAudioTimeRanges(
        maxCharactersPerSegment: Int,
        maxDuration: TimeInterval
    ) -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        var currentText = ""
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval?

        func flushCurrentSegment() {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            defer {
                currentText = ""
                currentStart = nil
                currentEnd = nil
            }

            guard !trimmed.isEmpty, let currentStart, let currentEnd else { return }
            segments.append(SpeechSegment(
                text: trimmed,
                startTime: currentStart,
                endTime: max(currentEnd, currentStart),
                confidence: nil,
                isFinal: true
            ))
        }

        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }

            let piece = String(text[run.range].characters)
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            if currentStart == nil {
                currentStart = start
            }
            currentEnd = end
            currentText += piece

            let duration = (currentEnd ?? start) - (currentStart ?? start)
            let shouldFlush = currentText.count >= maxCharactersPerSegment
                || duration >= maxDuration
                || piece.contains(where: isSubtitleBoundary)

            if shouldFlush {
                flushCurrentSegment()
            }
        }

        flushCurrentSegment()
        return segments
    }

    private func isSubtitleBoundary(_ character: Character) -> Bool {
        ["。", "、", ".", ",", "!", "?", "！", "？"].contains(character)
    }
}

// MARK: - Error

/// ファイル/動画解析中に発生し得るエラー。`description` を `print` するだけで失敗箇所を特定できる。
@available(iOS 26.0, *)
public enum EasySpeechFileAnalyzerError: Error, CustomStringConvertible {
    case localeNotSupported(Locale)
    case fileUnreadable(URL, underlying: Error)
    case noAudioTrack(URL)
    case analyzerFormatUnavailable
    case readerSetupFailed(URL, underlying: Error?)
    case readerFailed(URL, status: AVAssetReader.Status, underlying: Error?)
    case bufferConversionFailed(underlying: Error)
    case modelDownloadFailed(underlying: Error)
    case analysisFailed(underlying: Error)

    public var description: String {
        switch self {
        case .localeNotSupported(let locale):
            return "EasySpeechFileAnalyzerError.localeNotSupported(\(locale.identifier))"
        case .fileUnreadable(let url, let error):
            return "EasySpeechFileAnalyzerError.fileUnreadable(\(url.lastPathComponent), underlying: \(error))"
        case .noAudioTrack(let url):
            return "EasySpeechFileAnalyzerError.noAudioTrack(\(url.lastPathComponent))"
        case .analyzerFormatUnavailable:
            return "EasySpeechFileAnalyzerError.analyzerFormatUnavailable"
        case .readerSetupFailed(let url, let error):
            return "EasySpeechFileAnalyzerError.readerSetupFailed(\(url.lastPathComponent), underlying: \(String(describing: error)))"
        case .readerFailed(let url, let status, let error):
            return "EasySpeechFileAnalyzerError.readerFailed(\(url.lastPathComponent), status: \(status.rawValue), underlying: \(String(describing: error)))"
        case .bufferConversionFailed(let error):
            return "EasySpeechFileAnalyzerError.bufferConversionFailed(underlying: \(error))"
        case .modelDownloadFailed(let error):
            return "EasySpeechFileAnalyzerError.modelDownloadFailed(underlying: \(error))"
        case .analysisFailed(let error):
            return "EasySpeechFileAnalyzerError.analysisFailed(underlying: \(error))"
        }
    }
}

// MARK: - EasySpeechFileAnalyzer

/// 録音済みオーディオファイルや動画ファイルから音声を解析するクラス。
///
/// マイク入力に依存しないため、状態を持たない一発勝負で安心して使える。
/// インスタンスを作って何度でも `analyzeAudioFile(at:)` / `analyzeVideoFile(at:)` を呼び出せる。
///
/// デバッグ支援:
/// - `logger` を渡すと内部の進行状況 (ファイルオープン、モデル準備、解析、ファイナライズ) が文字列で流れる。
/// - `progress` コールバックで 0.0–1.0 の進捗を受け取れる。
/// - 失敗時は `EasySpeechFileAnalyzerError` の各 case で原因が特定できる。
@available(iOS 26.0, *)
public final class EasySpeechFileAnalyzer: Sendable {
    public typealias Logger = @Sendable (String) -> Void
    public typealias ProgressHandler = @Sendable (Double) -> Void

    private let locale: Locale
    private let logger: Logger?

    /// - Parameters:
    ///   - locale: 認識ロケール。デフォルトは日本語 (`ja_JP`)。
    ///   - logger: 各処理段階で呼び出されるログ出力。`nil` (デフォルト) なら何も出力しない。
    ///             デバッグ時は `EasySpeechFileAnalyzer.printLogger` を渡すと標準出力に流せる。
    public init(locale: Locale = Locale(identifier: "ja_JP"), logger: Logger? = nil) {
        self.locale = locale
        self.logger = logger
    }

    /// `print` に直接流すログのプリセット。`init(logger:)` に渡せる。
    public static let printLogger: Logger = { message in
        print(message)
    }

    // MARK: - Public API

    /// 録音済みオーディオファイル (`.m4a` `.wav` `.caf` など `AVAudioFile` で開けるもの) を解析する。
    ///
    /// - Parameters:
    ///   - url: 解析するオーディオファイルの URL。
    ///   - progress: 0.0–1.0 の進捗を非同期に受け取るコールバック (任意)。
    /// - Returns: 解析結果。
    /// - Throws: `EasySpeechFileAnalyzerError`。
    public func analyzeAudioFile(at url: URL, progress: ProgressHandler? = nil) async throws -> EasySpeechFileResult {
        let startedAt = Date()
        log("audio: opening \(url.lastPathComponent)")

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw EasySpeechFileAnalyzerError.fileUnreadable(url, underlying: error)
        }
        log("audio: format=\(audioFile.processingFormat), frames=\(audioFile.length)")
        let sourceDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let context = try await prepareSession()
        log("audio: analyzer started (format=\(context.analyzerFormat))")

        do {
            try await feed(audioFile: audioFile, into: context, progress: progress)
        } catch let error as EasySpeechFileAnalyzerError {
            await context.cancel()
            throw error
        } catch {
            await context.cancel()
            throw EasySpeechFileAnalyzerError.analysisFailed(underlying: error)
        }

        let text = try await finalize(context)
        let elapsed = Date().timeIntervalSince(startedAt)
        log("audio: done in \(String(format: "%.2f", elapsed))s, chars=\(text.characters.count)")

        return EasySpeechFileResult(
            text: text,
            plainText: String(text.characters),
            elapsedSeconds: elapsed,
            sourceDuration: sourceDuration.isFinite ? sourceDuration : nil,
            locale: locale,
            analyzerFormat: context.analyzerFormat
        )
    }

    /// 動画ファイル (`.mp4` `.mov` など `AVURLAsset` で開けるもの) から音声トラックを抽出して解析する。
    ///
    /// - Parameters:
    ///   - url: 解析する動画ファイルの URL。
    ///   - progress: 0.0–1.0 の進捗を非同期に受け取るコールバック (任意)。
    /// - Returns: 解析結果。
    /// - Throws: `EasySpeechFileAnalyzerError`。
    public func analyzeVideoFile(at url: URL, progress: ProgressHandler? = nil) async throws -> EasySpeechFileResult {
        let startedAt = Date()
        log("video: opening \(url.lastPathComponent)")

        let asset = AVURLAsset(url: url)

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw EasySpeechFileAnalyzerError.fileUnreadable(url, underlying: error)
        }
        guard let audioTrack = audioTracks.first else {
            throw EasySpeechFileAnalyzerError.noAudioTrack(url)
        }

        let totalDuration: Double
        do {
            totalDuration = try await asset.load(.duration).seconds
        } catch {
            totalDuration = 0
        }
        log("video: audio track found, duration=\(String(format: "%.2f", totalDuration))s")

        let context = try await prepareSession()
        log("video: analyzer started (format=\(context.analyzerFormat))")

        do {
            try await feed(
                videoURL: url,
                asset: asset,
                audioTrack: audioTrack,
                totalDuration: totalDuration,
                into: context,
                progress: progress
            )
        } catch let error as EasySpeechFileAnalyzerError {
            await context.cancel()
            throw error
        } catch {
            await context.cancel()
            throw EasySpeechFileAnalyzerError.analysisFailed(underlying: error)
        }

        let text = try await finalize(context)
        let elapsed = Date().timeIntervalSince(startedAt)
        log("video: done in \(String(format: "%.2f", elapsed))s, chars=\(text.characters.count)")

        return EasySpeechFileResult(
            text: text,
            plainText: String(text.characters),
            elapsedSeconds: elapsed,
            sourceDuration: totalDuration.isFinite ? totalDuration : nil,
            locale: locale,
            analyzerFormat: context.analyzerFormat
        )
    }

    // MARK: - Internal

    private func log(_ message: String) {
        logger?("[EasySpeechFileAnalyzer] \(message)")
    }

    private func prepareSession() async throws -> SessionContext {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // ファイル解析では確定結果のみ欲しいので volatile は無効化。
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // ロケールサポート確認
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let isSupported = supportedLocales
            .map { $0.identifier(.bcp47) }
            .contains(locale.identifier(.bcp47))
        guard isSupported else {
            throw EasySpeechFileAnalyzerError.localeNotSupported(locale)
        }

        // モデル未インストールならダウンロード
        let installedLocales = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if !installedLocales.contains(locale.identifier(.bcp47)) {
            log("downloading model for \(locale.identifier(.bcp47))...")
            do {
                if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await downloader.downloadAndInstall()
                }
            } catch {
                throw EasySpeechFileAnalyzerError.modelDownloadFailed(underlying: error)
            }
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EasySpeechFileAnalyzerError.analyzerFormatUnavailable
        }

        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()

        // 結果収集はバックグラウンド Task で並走させる
        let collector = Task<AttributedString, Error> {
            var accumulated = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                accumulated += result.text
            }
            return accumulated
        }

        try await analyzer.start(inputSequence: sequence)

        return SessionContext(
            analyzer: analyzer,
            inputBuilder: builder,
            collector: collector,
            analyzerFormat: analyzerFormat
        )
    }

    private func feed(
        audioFile: AVAudioFile,
        into context: SessionContext,
        progress: ProgressHandler?
    ) async throws {
        let chunkFrames: AVAudioFrameCount = 8192
        let totalFrames = audioFile.length
        let processingFormat = audioFile.processingFormat
        let converter = BufferConverter()

        while audioFile.framePosition < totalFrames {
            try Task.checkCancellation()
            let remaining = AVAudioFrameCount(totalFrames - audioFile.framePosition)
            let toRead = min(chunkFrames, remaining)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: toRead) else {
                break
            }
            try audioFile.read(into: buffer, frameCount: toRead)

            let converted: AVAudioPCMBuffer
            do {
                converted = try converter.convertBuffer(buffer, to: context.analyzerFormat)
            } catch {
                throw EasySpeechFileAnalyzerError.bufferConversionFailed(underlying: error)
            }

            context.inputBuilder.yield(AnalyzerInput(buffer: converted))

            if totalFrames > 0 {
                progress?(Double(audioFile.framePosition) / Double(totalFrames))
            }
        }
    }

    private func feed(
        videoURL: URL,
        asset: AVURLAsset,
        audioTrack: AVAssetTrack,
        totalDuration: Double,
        into context: SessionContext,
        progress: ProgressHandler?
    ) async throws {
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EasySpeechFileAnalyzerError.readerSetupFailed(videoURL, underlying: error)
        }
        guard reader.canAdd(trackOutput) else {
            throw EasySpeechFileAnalyzerError.readerSetupFailed(videoURL, underlying: nil)
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw EasySpeechFileAnalyzerError.readerFailed(videoURL, status: reader.status, underlying: reader.error)
        }

        let converter = BufferConverter()

        while reader.status == .reading {
            do {
                try Task.checkCancellation()
            } catch {
                reader.cancelReading()
                throw error
            }

            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                break
            }

            guard let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer) else {
                continue
            }

            let converted: AVAudioPCMBuffer
            do {
                converted = try converter.convertBuffer(pcmBuffer, to: context.analyzerFormat)
            } catch {
                reader.cancelReading()
                throw EasySpeechFileAnalyzerError.bufferConversionFailed(underlying: error)
            }

            context.inputBuilder.yield(AnalyzerInput(buffer: converted))

            if totalDuration > 0 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                let dur = CMSampleBufferGetDuration(sampleBuffer).seconds
                let progressed = (pts.isFinite ? pts : 0) + (dur.isFinite ? dur : 0)
                progress?(min(max(progressed / totalDuration, 0), 1))
            }
        }

        if reader.status == .failed {
            throw EasySpeechFileAnalyzerError.readerFailed(videoURL, status: reader.status, underlying: reader.error)
        }
    }

    private func finalize(_ context: SessionContext) async throws -> AttributedString {
        context.inputBuilder.finish()
        log("finalizing analyzer...")
        do {
            try await context.analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            throw EasySpeechFileAnalyzerError.analysisFailed(underlying: error)
        }
        do {
            return try await context.collector.value
        } catch {
            throw EasySpeechFileAnalyzerError.analysisFailed(underlying: error)
        }
    }

    /// `CMSampleBuffer` から `AVAudioPCMBuffer` を作る内部ヘルパー。
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let srcBuffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let dstBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let count = min(srcBuffers.count, dstBuffers.count)
        for i in 0..<count {
            let src = srcBuffers[i]
            let dst = dstBuffers[i]
            let bytes = min(Int(src.mDataByteSize), Int(dst.mDataByteSize))
            if let srcData = src.mData, let dstData = dst.mData, bytes > 0 {
                memcpy(dstData, srcData, bytes)
            }
        }

        return pcmBuffer
    }
}

// MARK: - SessionContext

/// 1 回の解析セッションをまとめた内部コンテキスト。
@available(iOS 26.0, *)
private struct SessionContext: @unchecked Sendable {
    let analyzer: SpeechAnalyzer
    let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    let collector: Task<AttributedString, Error>
    let analyzerFormat: AVAudioFormat

    /// エラー発生時の後始末。完了している場合は無害。
    func cancel() async {
        inputBuilder.finish()
        collector.cancel()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }
}
