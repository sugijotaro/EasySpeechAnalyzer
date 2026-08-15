//
//  PremiereProTranscript.swift
//  EasySpeechAnalyzer
//

import Foundation

// MARK: - PremiereProTranscript

/// Adobe Premiere Pro の「Import Static Transcript」で読み込める Transcript JSON。
///
/// Adobe 公式仕様 `PremierePro_transcript_format_spec.json`
/// (`https://schemas.adobe.com/transcript/v1.0.0`, JSON Schema draft-07) に準拠する。
///
/// ルートの必須フィールドは `language` / `segments` / `speakers` の 3 つで、
/// 仕様は `additionalProperties: false` なのでこれ以外のキーは出力しない。
public struct PremiereProTranscript: Codable, Sendable, Equatable {
    /// 文字起こし全体の言語コード。
    public var language: PremiereProLanguageCode
    /// 発話セグメント (1 つ以上)。
    public var segments: [PremiereProTranscriptSegment]
    /// セグメントから参照される話者の一覧 (1 つ以上)。
    public var speakers: [PremiereProSpeaker]

    public init(
        language: PremiereProLanguageCode,
        segments: [PremiereProTranscriptSegment],
        speakers: [PremiereProSpeaker]
    ) {
        self.language = language
        self.segments = segments
        self.speakers = speakers
    }
}

// MARK: - PremiereProTranscriptSegment

/// 単一話者による連続した発話のかたまり。
public struct PremiereProTranscriptSegment: Codable, Sendable, Equatable {
    /// セグメントの長さ (秒)。仕様上 0 以上。
    public var duration: Double
    /// このセグメントの言語コード。
    public var language: PremiereProLanguageCode
    /// 話者 ID (UUID v4 形式の文字列)。`speakers` に含まれている必要がある。
    public var speaker: String
    /// 音声先頭からの開始秒数。仕様上 0 以上。
    public var start: Double
    /// セグメントに含まれる word (1 つ以上)。
    public var words: [PremiereProTranscriptWord]

    public init(
        duration: Double,
        language: PremiereProLanguageCode,
        speaker: String,
        start: Double,
        words: [PremiereProTranscriptWord]
    ) {
        self.duration = duration
        self.language = language
        self.speaker = speaker
        self.start = start
        self.words = words
    }
}

// MARK: - PremiereProTranscriptWord

/// word (token) 単位の時刻・信頼度情報。
public struct PremiereProTranscriptWord: Codable, Sendable, Equatable {
    /// 信頼度 (0.0–1.0)。Adobe 仕様では必須フィールド。
    public var confidence: Double
    /// word の長さ (秒)。仕様上 0 以上。
    public var duration: Double
    /// 文末かどうか (end of sentence)。
    public var eos: Bool
    /// 音声先頭からの開始秒数。仕様上 0 以上。
    public var start: Double
    /// 追加のタグ。Adobe 仕様では必須フィールドだが空配列でよい。
    public var tags: [PremiereProTranscriptWordTag]
    /// 表示テキスト (句読点を含む)。
    public var text: String
    /// 種別 (`word` / `punctuation`)。
    public var type: PremiereProTranscriptWordType

    public init(
        confidence: Double,
        duration: Double,
        eos: Bool,
        start: Double,
        tags: [PremiereProTranscriptWordTag] = [],
        text: String,
        type: PremiereProTranscriptWordType = .word
    ) {
        self.confidence = confidence
        self.duration = duration
        self.eos = eos
        self.start = start
        self.tags = tags
        self.text = text
        self.type = type
    }
}

// MARK: - PremiereProTranscriptWordType

/// Adobe 仕様の `Word.type` (enum: `word` / `punctuation`)。
public enum PremiereProTranscriptWordType: String, Codable, Sendable, Equatable, CaseIterable {
    case word
    case punctuation
}

// MARK: - PremiereProTranscriptWordTag

/// Adobe 仕様の `Word.tags` の要素 (enum: `profanity` / `filler`)。
public enum PremiereProTranscriptWordTag: String, Codable, Sendable, Equatable, CaseIterable {
    case profanity
    case filler
}

// MARK: - PremiereProSpeaker

/// 話者。Adobe 仕様では `id` (UUID v4 形式) と `name` が必須。
public struct PremiereProSpeaker: Codable, Sendable, Equatable {
    /// 話者 ID。JSON へは小文字の UUID 文字列として書き出す (Premiere Pro の実 export と同じ表記)。
    public var id: UUID
    /// 表示名。空文字は仕様違反 (`minLength: 1`)。
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// EasySpeechAnalyzer は話者分離 (speaker diarization) を行わないため、
    /// 既定ではこの単一話者として書き出す。
    ///
    /// テストや差分比較を安定させるため、ランダム UUID ではなく固定値を使う
    /// (UUID v4 のフォーマット要件は満たしている)。
    public static let `default` = PremiereProSpeaker(
        id: UUID(uuidString: "8ba28b4b-7f6b-4bd3-9d1f-2c5d3f47a1e0")!,
        name: "Speaker 1"
    )

    private enum CodingKeys: String, CodingKey {
        case id
        case name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        guard let uuid = UUID(uuidString: rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "speaker id is not a UUID string: \(rawID)"
            )
        }
        self.id = uuid
        self.name = try container.decode(String.self, forKey: .name)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Foundation の UUID は大文字で文字列化されるが、Premiere Pro の実 export は小文字。
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(name, forKey: .name)
    }
}

// MARK: - PremiereProLanguageCode

/// Adobe 仕様の `LanguageCode`。仕様に列挙された値のみを取り得る。
///
/// 対応外・不明な言語は `.unknown` (`"??-??"`) を使う。
public struct PremiereProLanguageCode: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    /// 仕様に列挙されている値のみ受け付ける。それ以外は `nil`。
    public init?(rawValue: String) {
        guard Self.allCases.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    /// Adobe 公式仕様に列挙されている言語コード (出現順)。
    public static let allCases: [String] = [
        "en-us", "en-gb", "zh-hk", "cmn-hans", "cmn-hant", "es-es", "de-de",
        "fr-fr", "ja-jp", "pt-pt", "pt-br", "ko-kr", "it-it", "ru-ru", "hi-in",
        "nb-no", "sv-se", "nl-nl", "da-dk", "id-id", "th-th", "vi-vn", "ms-my",
        "tr-tr", "pl-pl", "fil-ph", "te-in", "ml-in", "pa-in", "??-??"
    ]

    /// 不明・非対応言語を表す仕様上の値。
    public static let unknown = PremiereProLanguageCode(unchecked: "??-??")

    public static let japanese = PremiereProLanguageCode(unchecked: "ja-jp")
    public static let englishUS = PremiereProLanguageCode(unchecked: "en-us")

    /// `Locale` を Adobe 仕様の言語コードへ変換する。
    ///
    /// 1. BCP-47 識別子を小文字化して完全一致を探す (`ja_JP` → `ja-jp`)。
    /// 2. 中国語は `zh-Hans` → `cmn-hans` のように Premiere 側の表記へ読み替える。
    /// 3. 見つからなければ言語部分だけで一致する最初のコードを使う (`de_AT` → `de-de`)。
    /// 4. それでも見つからなければ `.unknown` (`"??-??"`)。
    public init(locale: Locale) {
        let bcp47 = locale.identifier(.bcp47).lowercased()

        if let exact = PremiereProLanguageCode(rawValue: bcp47) {
            self = exact
            return
        }

        if let mapped = Self.chineseCode(forBCP47: bcp47) {
            self = mapped
            return
        }

        let languagePart = bcp47.split(separator: "-").first.map(String.init) ?? bcp47
        if let prefixed = Self.allCases.first(where: { $0.hasPrefix(languagePart + "-") }),
           let code = PremiereProLanguageCode(rawValue: prefixed) {
            self = code
            return
        }

        self = .unknown
    }

    /// 中国語系ロケールの読み替え。Premiere は普通話を `cmn-hans` / `cmn-hant` で表す。
    private static func chineseCode(forBCP47 bcp47: String) -> PremiereProLanguageCode? {
        guard bcp47 == "zh" || bcp47.hasPrefix("zh-") else { return nil }

        if bcp47.contains("hk") {
            return PremiereProLanguageCode(rawValue: "zh-hk")
        }
        if bcp47.contains("hant") || bcp47.contains("tw") || bcp47.contains("mo") {
            return PremiereProLanguageCode(rawValue: "cmn-hant")
        }
        return PremiereProLanguageCode(rawValue: "cmn-hans")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let code = PremiereProLanguageCode(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\(rawValue) is not a Premiere Pro language code"
            )
        }
        self = code
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
