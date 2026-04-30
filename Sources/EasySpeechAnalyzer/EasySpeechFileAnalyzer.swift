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
        debugLog(
            "makeSubtitleSegments: plainTextCount=\(plainText.count), sourceDuration=\(debugTime(sourceDuration)), maxCharacters=\(maxCharacters), maxDuration=\(debugTime(options.maxDuration)), minDuration=\(debugTime(options.minDuration)), splitByPunctuation=\(options.splitByPunctuation), plainText=\"\(debugText(plainText))\""
        )
        let transcript = makeSpeechTranscript(
            maxCharactersPerSegment: maxCharacters,
            maxDuration: options.maxDuration
        )
        debugLog(
            "makeSubtitleSegments: transcriptSegmentCount=\(transcript.segments.count), finalizedCount=\(transcript.finalizedSegments.count)"
        )
        let subtitleSegments = transcript.makeSubtitleSegments(options: options)
        debugLog("makeSubtitleSegments: outputSubtitleSegmentCount=\(subtitleSegments.count)")
        for (index, segment) in subtitleSegments.enumerated() {
            debugLog(
                "subtitleSegment[\(index)]: start=\(debugTime(segment.startTime)), end=\(debugTime(segment.endTime)), duration=\(debugTime(segment.duration)), textCount=\(segment.text.count), text=\"\(debugText(segment.text))\""
            )
        }
        return subtitleSegments
    }

    private func makeSpeechTranscript(
        createdAt: Date = Date(),
        maxCharactersPerSegment: Int,
        maxDuration: TimeInterval
    ) -> SpeechTranscript {
        debugLog(
            "makeSpeechTranscript: maxCharactersPerSegment=\(maxCharactersPerSegment), maxDuration=\(debugTime(maxDuration))"
        )
        let segments = makeSegmentsFromAudioTimeRanges(
            maxCharactersPerSegment: maxCharactersPerSegment,
            maxDuration: maxDuration
        )

        if !segments.isEmpty {
            debugLog("makeSpeechTranscript: using audioTimeRange segments count=\(segments.count)")
            for (index, segment) in segments.enumerated() {
                debugLog(
                    "speechSegment[\(index)]: start=\(debugTime(segment.startTime)), end=\(debugTime(segment.endTime)), duration=\(debugTime(segment.duration)), textCount=\(segment.text.count), text=\"\(debugText(segment.text))\""
                )
            }
            return SpeechTranscript(
                text: plainText,
                segments: segments,
                locale: locale,
                duration: sourceDuration,
                createdAt: createdAt
            )
        }

        debugLog("makeSpeechTranscript: no audioTimeRange segments; using fallback single segment if plainText is not empty")
        let segment = SpeechSegment(
            text: plainText,
            startTime: attributedAudioTimeRange?.start ?? 0,
            endTime: attributedAudioTimeRange?.end ?? sourceDuration ?? 0,
            confidence: nil,
            isFinal: true
        )
        debugLog(
            "fallbackSpeechSegment: start=\(debugTime(segment.startTime)), end=\(debugTime(segment.endTime)), duration=\(debugTime(segment.duration)), textCount=\(segment.text.count), text=\"\(debugText(segment.text))\""
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
        debugLog(
            "makeSegmentsFromAudioTimeRanges: runCount=\(text.runs.count), maxCharactersPerSegment=\(maxCharactersPerSegment), maxDuration=\(debugTime(maxDuration))"
        )
        var segments: [SpeechSegment] = []
        var currentText = ""
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval?

        func appendSpeechSegment(text: String, startTime: TimeInterval, endTime: TimeInterval, reason: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                debugLog("append speech segment: skipped empty text; reason=\(reason), raw=\"\(debugText(text))\"")
                return
            }
            let segment = SpeechSegment(
                text: trimmed,
                startTime: startTime,
                endTime: max(endTime, startTime),
                confidence: nil,
                isFinal: true
            )
            debugLog(
                "append speech segment: reason=\(reason), start=\(debugTime(segment.startTime)), end=\(debugTime(segment.endTime)), duration=\(debugTime(segment.duration)), textCount=\(segment.text.count), text=\"\(debugText(segment.text))\""
            )
            segments.append(segment)
        }

        func flushCurrentSegment(reason: String) {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            defer {
                currentText = ""
                currentStart = nil
                currentEnd = nil
            }

            guard !trimmed.isEmpty else {
                debugLog("flush speech segment: skipped because trimmed text is empty; raw=\"\(debugText(currentText))\"")
                return
            }
            guard let currentStart, let currentEnd else {
                debugLog("flush speech segment: skipped because start or end is missing; text=\"\(debugText(trimmed))\"")
                return
            }
            appendSpeechSegment(text: trimmed, startTime: currentStart, endTime: currentEnd, reason: reason)
        }

        func flushCurrentSegment(atCharacterOffset offset: Int, reason: String) {
            guard let segmentStart = currentStart, let segmentEnd = currentEnd else {
                flushCurrentSegment(reason: "\(reason); missing start/end")
                return
            }

            let characterCount = currentText.count
            guard offset > 0, offset < characterCount else {
                flushCurrentSegment(reason: "\(reason); offset \(offset) flushes all")
                return
            }

            let splitIndex = currentText.index(currentText.startIndex, offsetBy: offset)
            let prefix = String(currentText[..<splitIndex])
            let suffix = String(currentText[splitIndex...])
            let fraction = Double(offset) / Double(max(characterCount, 1))
            let splitTime = segmentStart + max(0, segmentEnd - segmentStart) * fraction

            debugLog(
                "safe lookback split: reason=\(reason), offset=\(offset)/\(characterCount), splitTime=\(debugTime(splitTime)), prefix=\"\(debugText(prefix))\", suffix=\"\(debugText(suffix))\""
            )
            appendSpeechSegment(text: prefix, startTime: segmentStart, endTime: splitTime, reason: reason)

            currentText = suffix
            currentStart = splitTime
            currentEnd = segmentEnd
        }

        for (index, run) in text.runs.enumerated() {
            let piece = String(text[run.range].characters)
            guard let range = run.audioTimeRange else {
                debugLog("audioRun[\(index)]: skipped because audioTimeRange is missing; text=\"\(debugText(piece))\"")
                continue
            }
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite else {
                debugLog(
                    "audioRun[\(index)]: skipped because time is not finite; start=\(debugTime(start)), end=\(debugTime(end)), text=\"\(debugText(piece))\""
                )
                continue
            }

            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                debugLog(
                    "audioRun[\(index)]: skipped because text is empty after trimming; start=\(debugTime(start)), end=\(debugTime(end)), text=\"\(debugText(piece))\""
                )
                continue
            }

            if currentStart == nil {
                currentStart = start
                debugLog("audioRun[\(index)]: starting new speech segment at \(debugTime(start))")
            }
            currentEnd = end
            currentText += piece

            let duration = (currentEnd ?? start) - (currentStart ?? start)
            var flushReasons: [String] = []
            if currentText.count >= maxCharactersPerSegment {
                flushReasons.append("currentText.count \(currentText.count) >= maxCharactersPerSegment \(maxCharactersPerSegment)")
            }
            if duration >= maxDuration {
                flushReasons.append("duration \(debugTime(duration)) >= maxDuration \(debugTime(maxDuration))")
            }
            if piece.contains(where: isSubtitleBoundary) {
                flushReasons.append("piece contains subtitle boundary")
            }
            let shouldFlush = !flushReasons.isEmpty
            debugLog(
                "audioRun[\(index)]: append piece start=\(debugTime(start)), end=\(debugTime(end)), currentStart=\(debugTime(currentStart)), currentEnd=\(debugTime(currentEnd)), currentTextCount=\(currentText.count), duration=\(debugTime(duration)), shouldFlush=\(shouldFlush), reasons=\(flushReasons.joined(separator: "; ")), piece=\"\(debugText(piece))\""
            )

            guard shouldFlush else { continue }

            if let punctuationOffset = lastSubtitleBoundaryOffset(in: currentText) {
                if punctuationOffset < currentText.count {
                    flushCurrentSegment(
                        atCharacterOffset: punctuationOffset,
                        reason: "subtitle boundary lookback"
                    )
                } else {
                    flushCurrentSegment(reason: "subtitle boundary at end")
                }
                continue
            }

            let targetOffset = targetSplitOffset(
                textCount: currentText.count,
                duration: duration,
                maxCharacters: maxCharactersPerSegment,
                maxDuration: maxDuration
            )

            if let safeOffset = safeLookbackSplitOffset(in: currentText, targetOffset: targetOffset) {
                flushCurrentSegment(
                    atCharacterOffset: safeOffset,
                    reason: "limit reached; safe lookback; \(flushReasons.joined(separator: "; "))"
                )
            } else if shouldForceHardSplit(
                textCount: currentText.count,
                duration: duration,
                maxCharacters: maxCharactersPerSegment,
                maxDuration: maxDuration
            ) {
                let hardOffset = fallbackSplitOffset(in: currentText, targetOffset: targetOffset)
                flushCurrentSegment(
                    atCharacterOffset: hardOffset,
                    reason: "limit exceeded; fallback split; \(flushReasons.joined(separator: "; "))"
                )
            } else {
                debugLog(
                    "defer speech segment flush: no safe boundary before targetOffset=\(targetOffset); reasons=\(flushReasons.joined(separator: "; ")), currentText=\"\(debugText(currentText))\""
                )
            }
        }

        flushCurrentSegment(reason: "end of audio runs")
        debugLog("makeSegmentsFromAudioTimeRanges: resultCount=\(segments.count)")
        return segments
    }

    private func isSubtitleBoundary(_ character: Character) -> Bool {
        ["。", "、", ".", ",", "!", "?", "！", "？"].contains(character)
    }

    private func lastSubtitleBoundaryOffset(in text: String) -> Int? {
        let characters = Array(text)
        for index in characters.indices.reversed() where isSubtitleBoundary(characters[index]) {
            return index + 1
        }
        return nil
    }

    private func targetSplitOffset(
        textCount: Int,
        duration: TimeInterval,
        maxCharacters: Int,
        maxDuration: TimeInterval
    ) -> Int {
        let characterTarget = max(1, min(textCount - 1, maxCharacters))
        guard duration > maxDuration, duration > 0 else {
            return characterTarget
        }
        let durationTarget = Int((Double(textCount) * maxDuration / duration).rounded(.down))
        return max(1, min(characterTarget, durationTarget, textCount - 1))
    }

    private func shouldForceHardSplit(
        textCount: Int,
        duration: TimeInterval,
        maxCharacters: Int,
        maxDuration: TimeInterval
    ) -> Bool {
        textCount >= maxCharacters * 2 || duration >= maxDuration + 1.2
    }

    private func safeLookbackSplitOffset(in text: String, targetOffset: Int) -> Int? {
        splitOffset(in: text, targetOffset: targetOffset, requiresSafeBoundary: true)
    }

    private func fallbackSplitOffset(in text: String, targetOffset: Int) -> Int {
        splitOffset(in: text, targetOffset: targetOffset, requiresSafeBoundary: false)
            ?? max(1, min(targetOffset, text.count - 1))
    }

    private func splitOffset(
        in text: String,
        targetOffset: Int,
        requiresSafeBoundary: Bool
    ) -> Int? {
        let characters = Array(text)
        guard characters.count > 1 else { return nil }

        let upperBound = max(1, min(targetOffset, characters.count - 1))
        var bestOffset: Int?
        var bestScore = Int.min

        for offset in 1...upperBound {
            let score = boundaryScore(characters: characters, offset: offset)
            if requiresSafeBoundary, score <= 0 {
                continue
            }
            if !requiresSafeBoundary, score < 0 {
                continue
            }

            let distance = abs(upperBound - offset)
            let candidateScore = score * 1_000 - distance
            if candidateScore > bestScore {
                bestScore = candidateScore
                bestOffset = offset
            }
        }

        return bestOffset
    }

    private func boundaryScore(characters: [Character], offset: Int) -> Int {
        guard offset > 0, offset < characters.count else { return -1 }
        let previous = characters[offset - 1]
        let next = characters[offset]

        if isProhibitedLineStarter(next) || isProhibitedLineEnder(previous) {
            return -1
        }
        if isInsideProtectedChunk(characters: characters, offset: offset) {
            return -1
        }
        if isProtectedChunkStart(characters: characters, offset: offset) {
            return 85
        }
        if isProtectedConnectorEnd(characters: characters, offset: offset) {
            return 75
        }
        if isSameWordContinuation(previous: previous, next: next) {
            return -1
        }
        if isSubtitleBoundary(previous) {
            return 100
        }
        if previous.isWhitespace || next.isWhitespace {
            return 90
        }
        if isParticleBoundary(characters: characters, offset: offset) {
            return 70
        }
        if isScriptTransitionBoundary(previous: previous, next: next) {
            return 35
        }
        return 0
    }

    private func isParticleBoundary(characters: [Character], offset: Int) -> Bool {
        let prefix = String(characters[..<offset])
        let particles = ["から", "まで", "より", "けど", "ので", "のに", "って", "は", "が", "を", "に", "へ", "と", "で", "も", "や", "か", "ね", "よ"]
        return particles.contains { prefix.hasSuffix($0) }
    }

    private func isInsideProtectedChunk(characters: [Character], offset: Int) -> Bool {
        protectedChunks.contains { chunk in
            chunkRanges(characters: characters, matching: chunk).contains { range in
                range.lowerBound < offset && offset < range.upperBound
            }
        }
    }

    private func isProtectedChunkStart(characters: [Character], offset: Int) -> Bool {
        let suffix = String(characters[offset...])
        return protectedChunks.contains { suffix.hasPrefix($0) }
    }

    private func isProtectedConnectorEnd(characters: [Character], offset: Int) -> Bool {
        let prefix = String(characters[..<offset])
        return protectedConnectors.contains { prefix.hasSuffix($0) }
    }

    private func chunkRanges(characters: [Character], matching chunk: String) -> [Range<Int>] {
        let chunkCharacters = Array(chunk)
        guard !chunkCharacters.isEmpty, chunkCharacters.count <= characters.count else { return [] }

        var ranges: [Range<Int>] = []
        let lastStart = characters.count - chunkCharacters.count
        for start in 0...lastStart {
            let end = start + chunkCharacters.count
            if Array(characters[start..<end]) == chunkCharacters {
                ranges.append(start..<end)
            }
        }
        return ranges
    }

    private var protectedChunks: [String] {
        protectedConnectors + protectedFormalNouns
    }

    private var protectedConnectors: [String] {
        ["ながら", "けれど", "けど", "たり", "たら", "なら", "ので", "のに"]
    }

    private var protectedFormalNouns: [String] {
        ["ところ", "わけ", "こと", "もの", "ため", "とき"]
    }

    private func isScriptTransitionBoundary(previous: Character, next: Character) -> Bool {
        if isKatakana(previous), !isKatakana(next), !isProlongedSoundMark(next) {
            return true
        }
        if isLatin(previous), !isLatin(next) {
            return true
        }
        if !isLatin(previous), isLatin(next) {
            return true
        }
        if previous.isNumber != next.isNumber {
            return true
        }
        return false
    }

    private func isSameWordContinuation(previous: Character, next: Character) -> Bool {
        if isKatakana(previous), isKatakana(next) || isProlongedSoundMark(next) {
            return true
        }
        if isProlongedSoundMark(previous), isKatakana(next) {
            return true
        }
        if isKanji(previous), isKanji(next) || isHiragana(next) {
            return true
        }
        if isHiragana(previous), isHiragana(next), !isParticle(previous) {
            return true
        }
        if isLatin(previous), isLatin(next) {
            return true
        }
        return false
    }

    private func isProhibitedLineStarter(_ character: Character) -> Bool {
        isSmallKana(character)
            || isProlongedSoundMark(character)
            || ["、", "。", "，", "．", ",", ".", "!", "?", "！", "？", ")", "]", "」", "』"].contains(character)
    }

    private func isProhibitedLineEnder(_ character: Character) -> Bool {
        ["(", "[", "「", "『"].contains(character)
    }

    private func isParticle(_ character: Character) -> Bool {
        ["は", "が", "を", "に", "へ", "と", "で", "も", "や", "か", "ね", "よ", "の"].contains(character)
    }

    private func isSmallKana(_ character: Character) -> Bool {
        ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ", "ゎ", "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ"].contains(character)
    }

    private func isProlongedSoundMark(_ character: Character) -> Bool {
        character == "ー"
    }

    private func isHiragana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
    }

    private func isKatakana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }
    }

    private func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }
    }

    private func isLatin(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (0x0041...0x005A).contains($0.value) || (0x0061...0x007A).contains($0.value)
        }
    }

    private func debugLog(_ message: String) {
        print("[SpeechSegments] \(message)")
    }

    private func debugText(_ text: String, limit: Int = 120) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard singleLine.count > limit else { return singleLine }
        let endIndex = singleLine.index(singleLine.startIndex, offsetBy: limit)
        return String(singleLine[..<endIndex]) + "..."
    }

    private func debugTime(_ time: TimeInterval?) -> String {
        guard let time else { return "nil" }
        return debugTime(time)
    }

    private func debugTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "\(time)" }
        return String(format: "%.3f", time)
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
            preset: SpeechTranscriber.Preset(
                transcriptionOptions: [],
                // ファイル解析では確定結果のみ欲しいので volatile は無効化。
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        log("asset: status for \(locale.identifier(.bcp47)) is \(assetStatus)")

        guard assetStatus != .unsupported else {
            throw EasySpeechFileAnalyzerError.localeNotSupported(locale)
        }

        if assetStatus != .installed {
            log("asset: downloading model for \(locale.identifier(.bcp47))...")
            do {
                if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await downloader.downloadAndInstall()
                    log("asset: download finished for \(locale.identifier(.bcp47))")
                } else {
                    log("asset: installation request returned nil for \(locale.identifier(.bcp47))")
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
