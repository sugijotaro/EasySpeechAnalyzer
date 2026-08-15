//
//  PremiereProTranscriptExport.swift
//  EasySpeechAnalyzer
//

import Foundation

// MARK: - Options

/// Premiere Pro Transcript JSON を書き出すときの調整項目。
public struct PremiereProTranscriptOptions: Sendable, Equatable {
    /// 出力する言語コード。`nil` なら `Locale` から自動判定する。
    public var language: PremiereProLanguageCode?

    /// この秒数以上の無音があればセグメントを分ける。
    ///
    /// `nil` (既定) の場合は全 word を 1 セグメントにまとめる。
    /// Premiere Pro の実 export でもセグメントは話者の切り替わりで分かれており、
    /// 単一話者なら 1 セグメントが最も素直で、word の時刻にも一切手を加えない。
    public var segmentSilenceThreshold: TimeInterval?

    /// `confidence` 属性が取得できなかった word に使うフォールバック値。
    ///
    /// Adobe 仕様では `confidence` は必須フィールド (`required`) のため省略できない。
    /// `SpeechTranscriber` の `attributeOptions` に `.transcriptionConfidence` が
    /// 指定されていれば実測値が入るので、この値が使われるのは属性が無い場合だけ。
    public var missingConfidenceFallback: Double

    public init(
        language: PremiereProLanguageCode? = nil,
        segmentSilenceThreshold: TimeInterval? = nil,
        missingConfidenceFallback: Double = 1.0
    ) {
        self.language = language
        self.segmentSilenceThreshold = segmentSilenceThreshold
        self.missingConfidenceFallback = missingConfidenceFallback
    }
}

// MARK: - Error

/// Premiere Pro Transcript JSON 生成時のエラー。
public enum PremiereProTranscriptError: Error, CustomStringConvertible, Equatable {
    /// 時刻付きの word が 1 つも無い (Adobe 仕様は `segments` / `words` に最低 1 要素を要求する)。
    case noTimedWords

    public var description: String {
        switch self {
        case .noTimedWords:
            return "PremiereProTranscriptError.noTimedWords: audioTimeRange を持つ word がありません"
        }
    }
}

// MARK: - Build from SpeechWord

@available(iOS 26.0, *)
public extension PremiereProTranscript {
    /// word-level timing を持つ `SpeechWord` 配列から Premiere Pro Transcript を組み立てる。
    ///
    /// Apple Speech が付与した時刻をそのまま使い、文字数比などで作り直すことはしない。
    ///
    /// - Parameters:
    ///   - words: `AttributedString.speechWords()` などで得た token 配列。
    ///   - locale: 認識に使ったロケール。`options.language` が `nil` のときの言語判定に使う。
    ///   - speaker: 書き出す話者。EasySpeechAnalyzer は話者分離をしないため常に単一話者。
    ///   - options: 追加の調整項目。
    /// - Throws: `PremiereProTranscriptError.noTimedWords`
    init(
        words: [SpeechWord],
        locale: Locale,
        speaker: PremiereProSpeaker = .default,
        options: PremiereProTranscriptOptions = PremiereProTranscriptOptions()
    ) throws {
        let language = options.language ?? PremiereProLanguageCode(locale: locale)

        let sanitized = words
            .compactMap { PremiereProTranscriptWord(speechWord: $0, options: options) }
            .sorted { $0.start < $1.start }

        guard !sanitized.isEmpty else {
            throw PremiereProTranscriptError.noTimedWords
        }

        let groups = Self.groupWords(sanitized, silenceThreshold: options.segmentSilenceThreshold)
        let segments = groups.map { group -> PremiereProTranscriptSegment in
            let start = group[0].start
            let end = group.reduce(start) { max($0, $1.start + $1.duration) }
            return PremiereProTranscriptSegment(
                duration: max(0, end - start),
                language: language,
                speaker: speaker.id.uuidString.lowercased(),
                start: start,
                words: group
            )
        }

        self.init(language: language, segments: segments, speakers: [speaker])
    }

    /// 無音のしきい値で word をセグメントへ束ねる。時刻には一切手を加えない。
    private static func groupWords(
        _ words: [PremiereProTranscriptWord],
        silenceThreshold: TimeInterval?
    ) -> [[PremiereProTranscriptWord]] {
        guard let silenceThreshold, silenceThreshold > 0 else {
            return [words]
        }

        var groups: [[PremiereProTranscriptWord]] = []
        var current: [PremiereProTranscriptWord] = []
        var previousEnd: Double?

        for word in words {
            if let previousEnd, word.start - previousEnd >= silenceThreshold, !current.isEmpty {
                groups.append(current)
                current = []
            }
            current.append(word)
            previousEnd = max(previousEnd ?? word.start, word.start + word.duration)
        }

        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }
}

// MARK: - SpeechWord → PremiereProTranscriptWord

@available(iOS 26.0, *)
extension PremiereProTranscriptWord {
    /// `SpeechWord` を Adobe 仕様に適合する word へ変換する。
    /// 仕様を満たせない (テキストが空、時刻が NaN / infinity) 場合は `nil`。
    init?(speechWord: SpeechWord, options: PremiereProTranscriptOptions) {
        let text = speechWord.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let rawStart = speechWord.startTime
        let rawEnd = speechWord.endTime
        guard rawStart.isFinite, rawEnd.isFinite else { return nil }

        // 仕様は start >= 0 / duration >= 0。負の値は出力しない。
        let start = max(0, rawStart)
        let duration = max(0, rawEnd - start)

        let confidence: Double
        if let value = speechWord.confidence, value.isFinite {
            // 仕様は 0.0–1.0。念のためクランプする。
            confidence = min(max(value, 0), 1)
        } else {
            let fallback = options.missingConfidenceFallback
            confidence = fallback.isFinite ? min(max(fallback, 0), 1) : 1
        }

        self.init(
            confidence: confidence,
            duration: duration,
            eos: PremiereProTranscriptWord.isEndOfSentence(text),
            start: start,
            tags: [],
            text: text,
            type: PremiereProTranscriptWord.wordType(for: text)
        )
    }
}

extension PremiereProTranscriptWord {
    /// 文末記号の集合。Adobe 仕様は `eos` を
    /// 「this word ends a sentence or phrase」とだけ定義しているため、
    /// 日本語・英語の文末句読点で判定する。
    private static let sentenceEndings: Set<Character> = [
        "。", "．", "…", "‥",
        ".", "!", "?",
        "！", "？"
    ]

    /// 判定前に取り除く閉じ括弧・引用符 (`た。」` のようなケース)。
    private static let trailingClosers: Set<Character> = [
        "」", "』", "）", "〕", "】", "》", "”", "’",
        ")", "]", "}", "\"", "'"
    ]

    static func isEndOfSentence(_ text: String) -> Bool {
        var characters = Array(text)
        while let last = characters.last, trailingClosers.contains(last) {
            characters.removeLast()
        }
        guard let last = characters.last else { return false }
        return sentenceEndings.contains(last)
    }

    /// token 全体が句読点なら `punctuation`、それ以外は `word`。
    static func wordType(for text: String) -> PremiereProTranscriptWordType {
        let isAllPunctuation = text.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
        return isAllPunctuation ? .punctuation : .word
    }
}

// MARK: - JSON encoding

public extension PremiereProTranscript {
    /// Premiere Pro が読み込む JSON へエンコードする。
    ///
    /// - Parameter prettyPrinted: 整形して出力するか (既定 `true`)。
    func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        return try encoder.encode(self)
    }

    /// Premiere Pro Transcript JSON をファイルへ書き出す。
    func write(to url: URL, prettyPrinted: Bool = true) throws {
        try jsonData(prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
    }
}

// MARK: - EasySpeechFileResult

@available(iOS 26.0, *)
public extension EasySpeechFileResult {
    /// 解析結果に残っている `audioTimeRange` / `transcriptionConfidence` 属性から
    /// word-level の token を取り出す。
    var words: [SpeechWord] {
        text.speechWords()
    }

    /// Premiere Pro Transcript を組み立てる。
    func makePremiereProTranscript(
        speaker: PremiereProSpeaker = .default,
        options: PremiereProTranscriptOptions = PremiereProTranscriptOptions()
    ) throws -> PremiereProTranscript {
        try PremiereProTranscript(
            words: words,
            locale: locale,
            speaker: speaker,
            options: options
        )
    }

    /// Premiere Pro Transcript JSON を `Data` として得る。
    func makePremiereProTranscriptJSON(
        speaker: PremiereProSpeaker = .default,
        options: PremiereProTranscriptOptions = PremiereProTranscriptOptions(),
        prettyPrinted: Bool = true
    ) throws -> Data {
        try makePremiereProTranscript(speaker: speaker, options: options)
            .jsonData(prettyPrinted: prettyPrinted)
    }

    /// Premiere Pro Transcript JSON をファイルへ書き出す。
    func writePremiereProTranscriptJSON(
        to url: URL,
        speaker: PremiereProSpeaker = .default,
        options: PremiereProTranscriptOptions = PremiereProTranscriptOptions(),
        prettyPrinted: Bool = true
    ) throws {
        try makePremiereProTranscript(speaker: speaker, options: options)
            .write(to: url, prettyPrinted: prettyPrinted)
    }
}

// MARK: - SpeechTranscript

@available(iOS 26.0, *)
public extension SpeechTranscript {
    /// Premiere Pro Transcript を組み立てる。
    ///
    /// `words` (word-level timing) が空の場合は `PremiereProTranscriptError.noTimedWords` を投げる。
    /// `segments` の start/end から word の時刻を推定することはしない。
    func makePremiereProTranscript(
        speaker: PremiereProSpeaker = .default,
        options: PremiereProTranscriptOptions = PremiereProTranscriptOptions()
    ) throws -> PremiereProTranscript {
        try PremiereProTranscript(
            words: words,
            locale: locale,
            speaker: speaker,
            options: options
        )
    }

    /// Premiere Pro Transcript JSON を `Data` として得る。
    func makePremiereProTranscriptJSON(
        speaker: PremiereProSpeaker = .default,
        options: PremiereProTranscriptOptions = PremiereProTranscriptOptions(),
        prettyPrinted: Bool = true
    ) throws -> Data {
        try makePremiereProTranscript(speaker: speaker, options: options)
            .jsonData(prettyPrinted: prettyPrinted)
    }

    /// Premiere Pro Transcript JSON をファイルへ書き出す。
    func writePremiereProTranscriptJSON(
        to url: URL,
        speaker: PremiereProSpeaker = .default,
        options: PremiereProTranscriptOptions = PremiereProTranscriptOptions(),
        prettyPrinted: Bool = true
    ) throws {
        try makePremiereProTranscript(speaker: speaker, options: options)
            .write(to: url, prettyPrinted: prettyPrinted)
    }
}
