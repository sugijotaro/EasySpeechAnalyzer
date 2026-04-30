//
//  SubtitleSegment.swift
//  EasySpeechAnalyzer
//

import Foundation

// MARK: - SubtitleSegment

/// 字幕表示用の 1 クリップ。`SpeechSegment` を字幕の制約に合わせて分割した結果。
@available(iOS 26.0, *)
public struct SubtitleSegment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }

    /// 字幕の表示時間 (秒)。
    public var duration: TimeInterval {
        max(0, endTime - startTime)
    }
}

// MARK: - SubtitleSegmentationOptions

/// 字幕分割の挙動を調整するオプション。
@available(iOS 26.0, *)
public struct SubtitleSegmentationOptions: Sendable, Equatable {
    /// 1 行あたりの最大文字数。
    public var maxCharactersPerLine: Int
    /// 最大行数。実際の最大文字数は `maxCharactersPerLine * maxLines`。
    public var maxLines: Int
    /// 1 字幕クリップの最大表示時間 (秒)。これを超えると分割。
    public var maxDuration: TimeInterval
    /// 1 字幕クリップの最小表示時間 (秒)。これより短い場合は前後とマージを試みる。
    public var minDuration: TimeInterval
    /// 句読点 (`。、，．,.!?！？`) を区切り候補にするか。
    public var splitByPunctuation: Bool

    public init(
        maxCharactersPerLine: Int,
        maxLines: Int,
        maxDuration: TimeInterval,
        minDuration: TimeInterval,
        splitByPunctuation: Bool
    ) {
        self.maxCharactersPerLine = maxCharactersPerLine
        self.maxLines = maxLines
        self.maxDuration = maxDuration
        self.minDuration = minDuration
        self.splitByPunctuation = splitByPunctuation
    }
}

@available(iOS 26.0, *)
public extension SubtitleSegmentationOptions {
    /// ショート動画/縦動画向けのデフォルト (14 文字 × 2 行、3.0s)。
    static let shortVideoDefault = SubtitleSegmentationOptions(
        maxCharactersPerLine: 14,
        maxLines: 2,
        maxDuration: 3.0,
        minDuration: 0.8,
        splitByPunctuation: true
    )

    /// 横長動画 (YouTube など) 向けのデフォルト (24 文字 × 2 行、5.0s)。
    static let longFormDefault = SubtitleSegmentationOptions(
        maxCharactersPerLine: 24,
        maxLines: 2,
        maxDuration: 5.0,
        minDuration: 1.0,
        splitByPunctuation: true
    )
}

// MARK: - SubtitleSegmenter

/// `SpeechTranscript` から `SubtitleSegment` 配列を作るための内部ユーティリティ。
///
/// アルゴリズムの大枠:
///   1. 確定済みセグメントを順に処理する。
///   2. 各セグメントが文字数 / 表示時間の上限を超えていれば、句読点と長さで分割する。
///   3. 分割後のピースに対して、元セグメントの時間レンジを文字数比例で割り当てる。
@available(iOS 26.0, *)
enum SubtitleSegmenter {
    static func makeSubtitleSegments(
        from transcript: SpeechTranscript,
        options: SubtitleSegmentationOptions
    ) -> [SubtitleSegment] {
        let segments = transcript.finalizedSegments
        debugLog(
            "makeSubtitleSegments: finalizedSegmentCount=\(segments.count), maxCharactersPerLine=\(options.maxCharactersPerLine), maxLines=\(options.maxLines), maxDuration=\(debugTime(options.maxDuration)), minDuration=\(debugTime(options.minDuration)), splitByPunctuation=\(options.splitByPunctuation)"
        )
        var output: [SubtitleSegment] = []
        for (index, segment) in segments.enumerated() {
            debugLog(
                "inputSpeechSegment[\(index)]: start=\(debugTime(segment.startTime)), end=\(debugTime(segment.endTime)), duration=\(debugTime(segment.duration)), textCount=\(segment.text.count), text=\"\(debugText(segment.text))\""
            )
            let splitSegments = split(segment, with: options)
            debugLog("inputSpeechSegment[\(index)]: producedSubtitleCount=\(splitSegments.count)")
            output.append(contentsOf: splitSegments)
        }
        debugLog("makeSubtitleSegments: outputCount=\(output.count)")
        return output
    }

    private static func split(
        _ segment: SpeechSegment,
        with options: SubtitleSegmentationOptions
    ) -> [SubtitleSegment] {
        let maxChars = max(1, options.maxCharactersPerLine * options.maxLines)
        let trimmedText = segment.text
        debugLog(
            "split speech segment: maxChars=\(maxChars), start=\(debugTime(segment.startTime)), end=\(debugTime(segment.endTime)), duration=\(debugTime(segment.duration)), textCount=\(trimmedText.count), text=\"\(debugText(trimmedText))\""
        )
        guard !trimmedText.isEmpty else {
            debugLog("split speech segment: skipped because text is empty")
            return []
        }

        let withinChars = trimmedText.count <= maxChars
        let withinDuration = segment.duration <= options.maxDuration
        debugLog(
            "split speech segment: withinChars=\(withinChars) (\(trimmedText.count) <= \(maxChars)), withinDuration=\(withinDuration) (\(debugTime(segment.duration)) <= \(debugTime(options.maxDuration)))"
        )

        if withinChars && withinDuration {
            let subtitle = SubtitleSegment(
                text: trimmedText,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
            debugLog(
                "split speech segment: no split; append subtitle start=\(debugTime(subtitle.startTime)), end=\(debugTime(subtitle.endTime)), text=\"\(debugText(subtitle.text))\""
            )
            return [subtitle]
        }

        // ステップ 1: 句読点で分ける (オプション)
        let initialPieces: [String]
        if options.splitByPunctuation {
            initialPieces = splitByPunctuation(trimmedText)
            debugLog(
                "split speech segment: punctuation split enabled; initialPieceCount=\(initialPieces.count), pieces=\(debugTexts(initialPieces))"
            )
        } else {
            initialPieces = [trimmedText]
            debugLog("split speech segment: punctuation split disabled; initialPieceCount=1")
        }

        // ステップ 2: それでも長すぎるピースは文字数で強制分割
        var refinedPieces: [String] = []
        for (index, piece) in initialPieces.enumerated() {
            if piece.count <= maxChars {
                debugLog(
                    "refinePiece[\(index)]: keep because pieceCount \(piece.count) <= maxChars \(maxChars); text=\"\(debugText(piece))\""
                )
                refinedPieces.append(piece)
            } else {
                let lengthPieces = splitByLength(piece, maxChars: maxChars)
                debugLog(
                    "refinePiece[\(index)]: split by length because pieceCount \(piece.count) > maxChars \(maxChars); produced=\(debugTexts(lengthPieces))"
                )
                refinedPieces.append(contentsOf: lengthPieces)
            }
        }
        debugLog(
            "split speech segment: refinedPieceCount=\(refinedPieces.count), refinedPieces=\(debugTexts(refinedPieces))"
        )

        // ステップ 3: 元セグメントの時間レンジを文字数比例で割り当てる
        let totalChars = refinedPieces.reduce(0) { $0 + $1.count }
        guard totalChars > 0 else {
            debugLog("split speech segment: skipped because refined pieces have no characters")
            return []
        }

        let totalDuration = segment.duration
        var subtitles: [SubtitleSegment] = []
        var cursor = segment.startTime
        debugLog(
            "split speech segment: allocate time by character count; totalChars=\(totalChars), totalDuration=\(debugTime(totalDuration)), cursor=\(debugTime(cursor))"
        )

        for (index, piece) in refinedPieces.enumerated() {
            let isLast = (index == refinedPieces.count - 1)
            let endTime: TimeInterval
            if isLast {
                // 端数誤差を最後で吸収
                endTime = segment.endTime
            } else {
                let fraction = Double(piece.count) / Double(totalChars)
                endTime = cursor + totalDuration * fraction
            }

            // minDuration 未満の場合は強制的に下限まで伸ばす (前のセグメントと被るのを許容)
            let adjustedEnd = max(endTime, cursor + options.minDuration)

            let subtitle = SubtitleSegment(
                text: piece,
                startTime: cursor,
                endTime: adjustedEnd
            )
            debugLog(
                "append subtitlePiece[\(index)]: isLast=\(isLast), pieceCount=\(piece.count), rawEnd=\(debugTime(endTime)), adjustedEnd=\(debugTime(adjustedEnd)), minDurationApplied=\(adjustedEnd != endTime), start=\(debugTime(subtitle.startTime)), end=\(debugTime(subtitle.endTime)), duration=\(debugTime(subtitle.duration)), text=\"\(debugText(piece))\""
            )
            subtitles.append(subtitle)
            cursor = adjustedEnd
        }

        return subtitles
    }

    private static let punctuationCharacters: Set<Character> = [
        "。", "、", "．", "，", ".", ",", "!", "?", "！", "？"
    ]

    private static func splitByPunctuation(_ text: String) -> [String] {
        debugLog("splitByPunctuation: inputCount=\(text.count), input=\"\(debugText(text))\"")
        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if punctuationCharacters.contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    debugLog(
                        "splitByPunctuation: boundary=\(character), append=\"\(debugText(trimmed))\""
                    )
                    pieces.append(trimmed)
                } else {
                    debugLog("splitByPunctuation: boundary=\(character), skipped empty piece")
                }
                current = ""
            }
        }
        let trimmedTail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTail.isEmpty {
            debugLog("splitByPunctuation: append tail=\"\(debugText(trimmedTail))\"")
            pieces.append(trimmedTail)
        }
        debugLog("splitByPunctuation: resultCount=\(pieces.count), result=\(debugTexts(pieces.isEmpty ? [text] : pieces))")
        return pieces.isEmpty ? [text] : pieces
    }

    private static func splitByLength(_ text: String, maxChars: Int) -> [String] {
        debugLog(
            "splitByLength: inputCount=\(text.count), maxChars=\(maxChars), input=\"\(debugText(text))\""
        )
        guard maxChars > 0 else {
            debugLog("splitByLength: maxChars <= 0; returning original text")
            return [text]
        }
        guard text.count > maxChars else {
            debugLog("splitByLength: keep as one piece because inputCount <= maxChars")
            return [text]
        }

        var pieces: [String] = []
        var remaining = text

        while remaining.count > maxChars {
            let targetOffset = min(maxChars, remaining.count - 1)
            let offset = safeLookbackSplitOffset(in: remaining, targetOffset: targetOffset)
                ?? fallbackSplitOffset(in: remaining, targetOffset: targetOffset)
            let splitIndex = remaining.index(remaining.startIndex, offsetBy: offset)
            let piece = String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

            debugLog(
                "splitByLength: split offset=\(offset), targetOffset=\(targetOffset), usedSafeBoundary=\(safeLookbackSplitOffset(in: remaining, targetOffset: targetOffset) != nil), piece=\"\(debugText(piece))\", suffix=\"\(debugText(suffix))\""
            )

            if !piece.isEmpty {
                pieces.append(piece)
            }
            guard !suffix.isEmpty, suffix.count < remaining.count else {
                remaining = ""
                break
            }
            remaining = suffix
        }

        if !remaining.isEmpty {
            debugLog("splitByLength: append tail=\"\(debugText(remaining))\"")
            pieces.append(remaining)
        }
        debugLog("splitByLength: resultCount=\(pieces.count), result=\(debugTexts(pieces))")
        return pieces
    }

    private static func safeLookbackSplitOffset(in text: String, targetOffset: Int) -> Int? {
        splitOffset(in: text, targetOffset: targetOffset, requiresSafeBoundary: true)
    }

    private static func fallbackSplitOffset(in text: String, targetOffset: Int) -> Int {
        splitOffset(in: text, targetOffset: targetOffset, requiresSafeBoundary: false)
            ?? max(1, min(targetOffset, text.count - 1))
    }

    private static func splitOffset(
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

    private static func boundaryScore(characters: [Character], offset: Int) -> Int {
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
        if punctuationCharacters.contains(previous) {
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

    private static func isParticleBoundary(characters: [Character], offset: Int) -> Bool {
        let prefix = String(characters[..<offset])
        let particles = ["から", "まで", "より", "けど", "ので", "のに", "って", "は", "が", "を", "に", "へ", "と", "で", "も", "や", "か", "ね", "よ"]
        return particles.contains { prefix.hasSuffix($0) }
    }

    private static func isInsideProtectedChunk(characters: [Character], offset: Int) -> Bool {
        protectedChunks.contains { chunk in
            chunkRanges(characters: characters, matching: chunk).contains { range in
                range.lowerBound < offset && offset < range.upperBound
            }
        }
    }

    private static func isProtectedChunkStart(characters: [Character], offset: Int) -> Bool {
        let suffix = String(characters[offset...])
        return protectedChunks.contains { suffix.hasPrefix($0) }
    }

    private static func isProtectedConnectorEnd(characters: [Character], offset: Int) -> Bool {
        let prefix = String(characters[..<offset])
        return protectedConnectors.contains { prefix.hasSuffix($0) }
    }

    private static func chunkRanges(characters: [Character], matching chunk: String) -> [Range<Int>] {
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

    private static var protectedChunks: [String] {
        protectedConnectors + protectedFormalNouns
    }

    private static var protectedConnectors: [String] {
        ["ながら", "けれど", "けど", "たり", "たら", "なら", "ので", "のに"]
    }

    private static var protectedFormalNouns: [String] {
        ["ところ", "わけ", "こと", "もの", "ため", "とき"]
    }

    private static func isScriptTransitionBoundary(previous: Character, next: Character) -> Bool {
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

    private static func isSameWordContinuation(previous: Character, next: Character) -> Bool {
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

    private static func isProhibitedLineStarter(_ character: Character) -> Bool {
        isSmallKana(character)
            || isProlongedSoundMark(character)
            || ["、", "。", "，", "．", ",", ".", "!", "?", "！", "？", ")", "]", "」", "』"].contains(character)
    }

    private static func isProhibitedLineEnder(_ character: Character) -> Bool {
        ["(", "[", "「", "『"].contains(character)
    }

    private static func isParticle(_ character: Character) -> Bool {
        ["は", "が", "を", "に", "へ", "と", "で", "も", "や", "か", "ね", "よ", "の"].contains(character)
    }

    private static func isSmallKana(_ character: Character) -> Bool {
        ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ", "ゎ", "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ"].contains(character)
    }

    private static func isProlongedSoundMark(_ character: Character) -> Bool {
        character == "ー"
    }

    private static func isHiragana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
    }

    private static func isKatakana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }
    }

    private static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }
    }

    private static func isLatin(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (0x0041...0x005A).contains($0.value) || (0x0061...0x007A).contains($0.value)
        }
    }

    private static func debugLog(_ message: String) {
        print("[SubtitleSegmenter] \(message)")
    }

    private static func debugText(_ text: String, limit: Int = 120) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard singleLine.count > limit else { return singleLine }
        let endIndex = singleLine.index(singleLine.startIndex, offsetBy: limit)
        return String(singleLine[..<endIndex]) + "..."
    }

    private static func debugTexts(_ texts: [String]) -> String {
        "[" + texts.enumerated().map { index, text in
            "#\(index) \"\(debugText(text))\"(\(text.count))"
        }.joined(separator: ", ") + "]"
    }

    private static func debugTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "\(time)" }
        return String(format: "%.3f", time)
    }
}

// MARK: - SpeechTranscript ergonomic helper

@available(iOS 26.0, *)
public extension SpeechTranscript {
    /// この transcript から字幕セグメントを生成する。
    ///
    /// ```swift
    /// let transcript = await manager.stopAndMakeTranscript()
    /// let subtitles = transcript.makeSubtitleSegments()
    /// ```
    func makeSubtitleSegments(
        options: SubtitleSegmentationOptions = .shortVideoDefault
    ) -> [SubtitleSegment] {
        SubtitleSegmenter.makeSubtitleSegments(from: self, options: options)
    }
}
