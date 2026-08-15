//
//  PremiereProTranscriptTests.swift
//  EasySpeechAnalyzerTests
//

import CoreMedia
import Foundation
import Speech
import XCTest

@testable import EasySpeechAnalyzer

// MARK: - Helpers

/// Adobe 公式仕様 (`PremierePro_transcript_format_spec.json`) が
/// `required` として挙げているキー。
private enum AdobeSpec {
    static let rootKeys: Set<String> = ["language", "segments", "speakers"]
    static let segmentKeys: Set<String> = ["duration", "language", "speaker", "start", "words"]
    static let wordKeys: Set<String> = ["confidence", "duration", "eos", "start", "tags", "text", "type"]
    static let speakerKeys: Set<String> = ["id", "name"]
}

@available(iOS 26.0, *)
private func makeAttributedString(
    _ tokens: [(text: String, start: Double, end: Double, confidence: Double?)]
) -> AttributedString {
    var result = AttributedString()
    for token in tokens {
        var piece = AttributedString(token.text)
        piece.audioTimeRange = CMTimeRange(
            start: CMTime(seconds: token.start, preferredTimescale: 600),
            end: CMTime(seconds: token.end, preferredTimescale: 600)
        )
        if let confidence = token.confidence {
            piece.transcriptionConfidence = confidence
        }
        result += piece
    }
    return result
}

@available(iOS 26.0, *)
private func makeTranscript(
    words: [SpeechWord],
    locale: Locale = Locale(identifier: "ja_JP"),
    options: PremiereProTranscriptOptions = PremiereProTranscriptOptions()
) throws -> PremiereProTranscript {
    try PremiereProTranscript(words: words, locale: locale, options: options)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

extension XCTestCase {
    /// word-level timing が無いときに `noTimedWords` が投げられることを確かめる。
    func assertThrowsNoTimedWords(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? PremiereProTranscriptError, .noTimedWords, file: file, line: line)
        }
    }
}

// MARK: - JSON structure

@available(iOS 26.0, *)
/// Premiere Pro Transcript JSON の構造
final class PremiereProTranscriptStructureTests: XCTestCase {
    private let words = [
        SpeechWord(text: "今日", startTime: 1.04, endTime: 1.32, confidence: 1.0),
        SpeechWord(text: "天気", startTime: 1.66, endTime: 1.98, confidence: 0.91)
    ]

    /// root には language / segments / speakers がある
    func testRootKeys() throws {
        let data = try makeTranscript(words: words).jsonData()
        let root = try jsonObject(data)
        XCTAssert(Set(root.keys) == AdobeSpec.rootKeys)
        XCTAssert(root["language"] as? String == "ja-jp")
        XCTAssert((root["segments"] as? [Any])?.isEmpty == false)
        XCTAssert((root["speakers"] as? [Any])?.count == 1)
    }

    /// segment / word / speaker が仕様の必須フィールドを持つ
    func testNestedKeys() throws {
        let data = try makeTranscript(words: words).jsonData()
        let root = try jsonObject(data)

        let segments = try XCTUnwrap(root["segments"] as? [[String: Any]])
        let segment = try XCTUnwrap(segments.first)
        XCTAssert(Set(segment.keys) == AdobeSpec.segmentKeys)
        XCTAssert(segment["language"] as? String == "ja-jp")

        let jsonWords = try XCTUnwrap(segment["words"] as? [[String: Any]])
        XCTAssert(jsonWords.count == 2)
        for word in jsonWords {
            XCTAssert(Set(word.keys) == AdobeSpec.wordKeys)
            XCTAssert(word["type"] as? String == "word")
            XCTAssert((word["tags"] as? [Any])?.isEmpty == true)
        }

        let speakers = try XCTUnwrap(root["speakers"] as? [[String: Any]])
        let speaker = try XCTUnwrap(speakers.first)
        XCTAssert(Set(speaker.keys) == AdobeSpec.speakerKeys)
        // segment.speaker は speakers 配列の id を参照している必要がある。
        XCTAssert(segment["speaker"] as? String == speaker["id"] as? String)
        XCTAssert(speaker["id"] as? String == PremiereProSpeaker.default.id.uuidString.lowercased())
    }

    /// speaker はデフォルトでも利用者指定でも単一話者
    func testSpeaker() throws {
        let custom = PremiereProSpeaker(
            id: UUID(uuidString: "631fbbc0-9c02-47c4-bb8c-732c020fa24f")!,
            name: "話者 1"
        )
        let transcript = try PremiereProTranscript(
            words: words,
            locale: Locale(identifier: "ja_JP"),
            speaker: custom
        )
        XCTAssert(transcript.speakers == [custom])
        XCTAssert(transcript.segments.allSatisfy { $0.speaker == "631fbbc0-9c02-47c4-bb8c-732c020fa24f" })
    }

    /// 時刻付き word が無ければ noTimedWords
    func testNoTimedWords() {
        assertThrowsNoTimedWords { _ = try makeTranscript(words: []) }
        assertThrowsNoTimedWords {
            _ = try makeTranscript(words: [SpeechWord(text: "  ", startTime: 0, endTime: 1)])
        }
    }
}

// MARK: - Timing

@available(iOS 26.0, *)
/// timing
final class PremiereProTranscriptTimingTests: XCTestCase {
    /// Apple の start/end がそのまま start/duration になる
    func testStartAndDuration() throws {
        let transcript = try makeTranscript(
            words: [
                SpeechWord(text: "A", startTime: 1.04, endTime: 1.32),
                SpeechWord(text: "B", startTime: 1.66, endTime: 1.98)
            ]
        )
        let words = try XCTUnwrap(transcript.segments.first?.words)

        XCTAssert(abs(words[0].start - 1.04) < 1e-9)
        XCTAssert(abs(words[0].duration - 0.28) < 1e-9)
        XCTAssert(abs(words[1].start - 1.66) < 1e-9)
        XCTAssert(abs(words[1].duration - 0.32) < 1e-9)
    }

    /// segment.start は最初の word、duration は最後の word の終端まで
    func testSegmentBounds() throws {
        let transcript = try makeTranscript(
            words: [
                SpeechWord(text: "A", startTime: 1.04, endTime: 1.32),
                SpeechWord(text: "B", startTime: 1.66, endTime: 1.98),
                SpeechWord(text: "C", startTime: 2.0, endTime: 2.32)
            ]
        )
        let segment = try XCTUnwrap(transcript.segments.first)
        XCTAssert(abs(segment.start - 1.04) < 1e-9)
        XCTAssert(abs(segment.duration - 1.28) < 1e-9)
    }

    /// word は start の昇順に並ぶ
    func testOrdering() throws {
        let transcript = try makeTranscript(
            words: [
                SpeechWord(text: "C", startTime: 3.0, endTime: 3.5),
                SpeechWord(text: "A", startTime: 1.0, endTime: 1.5),
                SpeechWord(text: "B", startTime: 2.0, endTime: 2.5)
            ]
        )
        let words = try XCTUnwrap(transcript.segments.first?.words)
        XCTAssert(words.map(\.text) == ["A", "B", "C"])
        XCTAssert(words.map(\.start) == words.map(\.start).sorted())
    }

    /// NaN / infinity / 負の値は JSON に出さない
    func testInvalidTiming() throws {
        let transcript = try makeTranscript(
            words: [
                SpeechWord(text: "nan", startTime: .nan, endTime: 1.0),
                SpeechWord(text: "inf", startTime: 0.5, endTime: .infinity),
                SpeechWord(text: "negative-start", startTime: -1.0, endTime: 0.5),
                SpeechWord(text: "negative-duration", startTime: 2.0, endTime: 1.0),
                SpeechWord(text: "ok", startTime: 3.0, endTime: 3.5)
            ]
        )
        let words = try XCTUnwrap(transcript.segments.first?.words)

        XCTAssert(words.map(\.text) == ["negative-start", "negative-duration", "ok"])
        XCTAssert(words.allSatisfy { $0.start.isFinite && $0.duration.isFinite })
        XCTAssert(words.allSatisfy { $0.start >= 0 && $0.duration >= 0 })
        XCTAssert(words[0].start == 0)
        XCTAssert(words[1].duration == 0)

        // 非有限な値が残っていれば JSONEncoder が投げる。
        let data = try transcript.jsonData()
        XCTAssert(!String(decoding: data, as: UTF8.self).lowercased().contains("nan"))
        XCTAssert(!String(decoding: data, as: UTF8.self).lowercased().contains("inf"))
    }

    /// 無音しきい値を指定すると word の時刻を変えずに segment が分かれる
    func testSilenceSplitting() throws {
        let words = [
            SpeechWord(text: "A", startTime: 1.0, endTime: 1.5),
            SpeechWord(text: "B", startTime: 1.6, endTime: 2.0),
            SpeechWord(text: "C", startTime: 5.0, endTime: 5.4)
        ]
        let single = try makeTranscript(words: words)
        XCTAssert(single.segments.count == 1)

        let split = try makeTranscript(
            words: words,
            options: PremiereProTranscriptOptions(segmentSilenceThreshold: 1.0)
        )
        XCTAssert(split.segments.count == 2)
        XCTAssert(split.segments[0].words.map(\.text) == ["A", "B"])
        XCTAssert(split.segments[1].words.map(\.text) == ["C"])
        XCTAssert(abs(split.segments[1].start - 5.0) < 1e-9)
        XCTAssert(abs(split.segments[1].duration - 0.4) < 1e-9)
        // 分割しても word の時刻は 1 セグメント時と完全に同じ。
        XCTAssert(split.segments.flatMap(\.words) == single.segments[0].words)
    }
}

// MARK: - Text / eos / confidence

@available(iOS 26.0, *)
/// テキスト・eos・confidence
final class PremiereProTranscriptContentTests: XCTestCase {
    /// 日本語 token を分割・結合しない
    func testJapaneseTokens() throws {
        let attributed = makeAttributedString([
            ("今日", 1.04, 1.32, 1.0),
            ("天気", 1.66, 1.98, 0.91),
            ("いいですね。", 2.0, 2.32, 0.55)
        ])
        let transcript = try makeTranscript(words: attributed.speechWords())
        let words = try XCTUnwrap(transcript.segments.first?.words)
        XCTAssert(words.map(\.text) == ["今日", "天気", "いいですね。"])
    }

    /// 文末記号を持つ token で eos が true になる
    func testEndOfSentence() throws {
        let transcript = try makeTranscript(
            words: [
                SpeechWord(text: "今日", startTime: 0.0, endTime: 0.2),
                SpeechWord(text: "です。", startTime: 0.2, endTime: 0.4),
                SpeechWord(text: "world.", startTime: 0.4, endTime: 0.6),
                SpeechWord(text: "really", startTime: 0.6, endTime: 0.8),
                SpeechWord(text: "ですか？", startTime: 0.8, endTime: 1.0),
                SpeechWord(text: "元気！", startTime: 1.0, endTime: 1.2),
                SpeechWord(text: "「はい。」", startTime: 1.2, endTime: 1.4),
                SpeechWord(text: "そして、", startTime: 1.4, endTime: 1.6)
            ]
        )
        let words = try XCTUnwrap(transcript.segments.first?.words)
        XCTAssert(words.map(\.eos) == [false, true, true, false, true, true, true, false])
    }

    /// 句読点だけの token は type = punctuation
    func testPunctuationType() throws {
        let transcript = try makeTranscript(
            words: [
                SpeechWord(text: "hello", startTime: 0, endTime: 0.2),
                SpeechWord(text: "。", startTime: 0.2, endTime: 0.3)
            ]
        )
        let words = try XCTUnwrap(transcript.segments.first?.words)
        XCTAssert(words[0].type == .word)
        XCTAssert(words[1].type == .punctuation)
        XCTAssert(words[1].eos)
    }

    /// Apple の confidence が JSON まで保持される
    func testConfidencePreserved() throws {
        let attributed = makeAttributedString([
            ("今日", 1.04, 1.32, 1.0),
            ("とても", 1.66, 1.98, 0.7300000190734863),
            ("です。", 2.0, 2.12, 0.6200000047683716)
        ])
        let words = attributed.speechWords()
        XCTAssert(words.map(\.confidence) == [1.0, 0.7300000190734863, 0.6200000047683716])

        let data = try makeTranscript(words: words).jsonData()
        let root = try jsonObject(data)
        let segments = try XCTUnwrap(root["segments"] as? [[String: Any]])
        let jsonWords = try XCTUnwrap(segments.first?["words"] as? [[String: Any]])
        let confidences = jsonWords.compactMap { $0["confidence"] as? Double }
        XCTAssert(confidences == [1.0, 0.7300000190734863, 0.6200000047683716])
    }

    /// confidence 属性が無い場合はフォールバック値を使う (Adobe 仕様で必須のため)
    func testConfidenceFallback() throws {
        // 属性を付けずに認識した場合 (attributeOptions に .transcriptionConfidence が無い等)。
        let attributed = makeAttributedString([("今日", 1.04, 1.32, nil)])
        let words = attributed.speechWords()
        XCTAssert(words[0].confidence == nil)

        let defaultFallback = try makeTranscript(words: words)
        XCTAssert(defaultFallback.segments[0].words[0].confidence == 1.0)

        let custom = try makeTranscript(
            words: words,
            options: PremiereProTranscriptOptions(missingConfidenceFallback: 0.5)
        )
        XCTAssert(custom.segments[0].words[0].confidence == 0.5)
    }

    /// 範囲外の confidence は 0.0–1.0 にクランプされる
    func testConfidenceClamped() throws {
        let transcript = try makeTranscript(
            words: [
                SpeechWord(text: "high", startTime: 0, endTime: 0.1, confidence: 1.4),
                SpeechWord(text: "low", startTime: 0.1, endTime: 0.2, confidence: -0.2)
            ]
        )
        XCTAssert(transcript.segments[0].words.map(\.confidence) == [1.0, 0.0])
    }
}

// MARK: - Language

/// language コード
final class PremiereProLanguageCodeTests: XCTestCase {
    /// ja_JP は ja-jp になる
    func testJapanese() {
        XCTAssert(PremiereProLanguageCode(locale: Locale(identifier: "ja_JP")).rawValue == "ja-jp")
        XCTAssert(PremiereProLanguageCode(locale: Locale(identifier: "ja")).rawValue == "ja-jp")
    }

    /// その他のロケール
    func testOthers() {
        XCTAssert(PremiereProLanguageCode(locale: Locale(identifier: "en_US")).rawValue == "en-us")
        XCTAssert(PremiereProLanguageCode(locale: Locale(identifier: "en_GB")).rawValue == "en-gb")
        // 仕様に無い地域は同じ言語の代表コードへ寄せる
        XCTAssert(PremiereProLanguageCode(locale: Locale(identifier: "de_AT")).rawValue == "de-de")
        XCTAssert(PremiereProLanguageCode(locale: Locale(identifier: "pt_BR")).rawValue == "pt-br")
        // 中国語は Premiere の表記へ読み替える
        XCTAssert(PremiereProLanguageCode(locale: Locale(identifier: "zh_Hans_CN")).rawValue == "cmn-hans")
        XCTAssert(PremiereProLanguageCode(locale: Locale(identifier: "zh_Hant_TW")).rawValue == "cmn-hant")
        XCTAssert(PremiereProLanguageCode(locale: Locale(identifier: "zh_HK")).rawValue == "zh-hk")
        // 非対応言語は仕様上の unknown
        XCTAssert(PremiereProLanguageCode(locale: Locale(identifier: "eu_ES")).rawValue == "??-??")
    }

    /// 仕様に無い値は生成もデコードもできない
    func testValidation() {
        XCTAssert(PremiereProLanguageCode(rawValue: "ja-JP") == nil)
        XCTAssert(PremiereProLanguageCode(rawValue: "klingon") == nil)
        XCTAssertThrowsError(
            try JSONDecoder().decode(PremiereProLanguageCode.self, from: Data(#""ja-JP""#.utf8))
        )
    }
}

// MARK: - Codable / golden fixture

@available(iOS 26.0, *)
/// Codable と golden fixture
final class PremiereProTranscriptCodableTests: XCTestCase {
    private var referenceWords: [SpeechWord] {
        makeAttributedString([
            ("今日", 1.04, 1.32, 1.0),
            ("天気", 1.66, 1.98, 0.91),
            ("いいですね。", 2.0, 2.32, 0.55)
        ]).speechWords()
    }

    /// 既定の書き出しは Premiere Pro の実 export と同じく改行を含まない 1 行
    func testDefaultOutputHasNoNewlines() throws {
        let transcript = try makeTranscript(words: referenceWords)

        let json = String(decoding: try transcript.jsonData(), as: UTF8.self)
        XCTAssertFalse(json.contains("\n"))
        XCTAssertFalse(json.contains("\r"))
        // 空白も入らない (文字列リテラルの中を除く)。
        XCTAssertFalse(json.contains("\" : \""))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("premiere-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try transcript.write(to: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssert(written.filter { $0.isNewline }.isEmpty)

        // 明示的に指定したときだけ整形する。
        let pretty = String(decoding: try transcript.jsonData(prettyPrinted: true), as: UTF8.self)
        XCTAssert(pretty.contains("\n"))
    }

    /// encode → decode で内容が一致する
    func testRoundTrip() throws {
        let transcript = try makeTranscript(words: referenceWords)
        let data = try transcript.jsonData()
        let decoded = try JSONDecoder().decode(PremiereProTranscript.self, from: data)
        XCTAssert(decoded == transcript)

        let compact = try transcript.jsonData(prettyPrinted: false)
        XCTAssert(try JSONDecoder().decode(PremiereProTranscript.self, from: compact) == transcript)
    }

    /// Premiere Pro の実 export と同じ構造の fixture と一致する
    func testGoldenFixture() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "premiere-transcript-reference",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let fixtureData = try Data(contentsOf: url)
        // fixture 自体も Premiere Pro の実 export と同じ 1 行の JSON。
        XCTAssert(String(decoding: fixtureData, as: UTF8.self).filter { $0.isNewline }.isEmpty)
        let fixture = try JSONDecoder().decode(PremiereProTranscript.self, from: fixtureData)

        let generated = try makeTranscript(words: referenceWords)

        XCTAssert(generated.language == fixture.language)
        XCTAssert(generated.speakers == fixture.speakers)
        XCTAssert(generated.segments.count == fixture.segments.count)

        let generatedSegment = try XCTUnwrap(generated.segments.first)
        let fixtureSegment = try XCTUnwrap(fixture.segments.first)
        XCTAssert(generatedSegment.speaker == fixtureSegment.speaker)
        XCTAssert(generatedSegment.language == fixtureSegment.language)
        XCTAssert(abs(generatedSegment.start - fixtureSegment.start) < 1e-6)
        XCTAssert(abs(generatedSegment.duration - fixtureSegment.duration) < 1e-6)
        XCTAssert(generatedSegment.words.count == fixtureSegment.words.count)

        for (generatedWord, fixtureWord) in zip(generatedSegment.words, fixtureSegment.words) {
            XCTAssert(generatedWord.text == fixtureWord.text)
            XCTAssert(generatedWord.type == fixtureWord.type)
            XCTAssert(generatedWord.tags == fixtureWord.tags)
            XCTAssert(generatedWord.eos == fixtureWord.eos)
            XCTAssert(abs(generatedWord.start - fixtureWord.start) < 1e-6)
            XCTAssert(abs(generatedWord.duration - fixtureWord.duration) < 1e-6)
            XCTAssert(abs(generatedWord.confidence - fixtureWord.confidence) < 1e-6)
        }

        // キー構成そのものが Premiere Pro の export と同一であること。
        let generatedRoot = try jsonObject(try generated.jsonData())
        let fixtureRoot = try jsonObject(fixtureData)
        XCTAssert(Set(generatedRoot.keys) == Set(fixtureRoot.keys))
    }
}

// MARK: - Public API

@available(iOS 26.0, *)
/// 公開 API
final class PremiereProTranscriptPublicAPITests: XCTestCase {
    /// SpeechTranscript から書き出せる
    func testFromSpeechTranscript() throws {
        let attributed = makeAttributedString([
            ("今日", 1.04, 1.32, 1.0),
            ("天気", 1.66, 1.98, 0.91)
        ])
        let transcript = SpeechTranscript(
            text: "今日天気",
            segments: [
                SpeechSegment(text: "今日天気", startTime: 1.04, endTime: 1.98, isFinal: true)
            ],
            words: attributed.speechWords(),
            locale: Locale(identifier: "ja_JP")
        )

        let data = try transcript.makePremiereProTranscriptJSON()
        let root = try jsonObject(data)
        XCTAssert(root["language"] as? String == "ja-jp")

        let premiere = try transcript.makePremiereProTranscript()
        XCTAssert(premiere.segments[0].words.map(\.text) == ["今日", "天気"])
    }

    /// word-level timing が無い SpeechTranscript からは書き出さない
    func testSpeechTranscriptWithoutWords() {
        // SpeechSegment の start/end から word の時刻を捏造しないことの確認。
        let transcript = SpeechTranscript(
            text: "今日天気",
            segments: [
                SpeechSegment(text: "今日天気", startTime: 1.04, endTime: 1.98, isFinal: true)
            ],
            locale: Locale(identifier: "ja_JP")
        )
        assertThrowsNoTimedWords { _ = try transcript.makePremiereProTranscriptJSON() }
    }

    /// ファイルへ書き出せる
    func testWriteToFile() throws {
        let transcript = SpeechTranscript(
            text: "今日",
            segments: [],
            words: [SpeechWord(text: "今日", startTime: 1.04, endTime: 1.32, confidence: 1.0)],
            locale: Locale(identifier: "ja_JP")
        )
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("premiere-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try transcript.writePremiereProTranscriptJSON(to: url)

        let decoded = try JSONDecoder().decode(
            PremiereProTranscript.self,
            from: try Data(contentsOf: url)
        )
        XCTAssert(decoded.segments[0].words[0].text == "今日")
    }
}
