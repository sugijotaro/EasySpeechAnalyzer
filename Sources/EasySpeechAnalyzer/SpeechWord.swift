//
//  SpeechWord.swift
//  EasySpeechAnalyzer
//

import CoreMedia
import Foundation
import Speech

// MARK: - SpeechWord

/// `SpeechTranscriber` が返す「時刻付き run」1 つ分 (word / token) を表すモデル。
///
/// `SpeechSegment` がフレーズ単位なのに対し、こちらは Apple Speech が
/// `audioTimeRange` 属性を付与した最小単位をそのまま保持する。
/// Premiere Pro の Transcript JSON など、word-level timecode を要求する書き出しに使う。
///
/// 日本語では英語のような空白区切りにはならず、`今日` `とても` `です。` のような
/// token 単位になる。ライブラリ側で再分割はしない (Apple の分割を信頼する)。
@available(iOS 26.0, *)
public struct SpeechWord: Sendable, Equatable {
    /// この token のテキスト (前後の空白は除去済み。句読点は含む)。
    public var text: String
    /// 音声先頭からの開始秒数。
    public var startTime: TimeInterval
    /// 音声先頭からの終了秒数。
    public var endTime: TimeInterval
    /// 認識の信頼度 (0.0–1.0)。`transcriptionConfidence` 属性が無い場合は `nil`。
    public var confidence: Double?

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }

    /// token の長さ (秒)。負にはならない。
    public var duration: TimeInterval {
        max(0, endTime - startTime)
    }
}

// MARK: - AttributedString → [SpeechWord]

@available(iOS 26.0, *)
public extension AttributedString {
    /// `audioTimeRange` 属性を持つ run を `SpeechWord` として取り出す。
    ///
    /// - Apple が付与した時刻をそのまま使う (文字数比などで作り直さない)。
    /// - 時刻属性が無い run、非有限な時刻、空白のみの run は無視する。
    /// - `transcriptionConfidence` 属性があれば `confidence` に格納する。
    ///   (`SpeechTranscriber` の `attributeOptions` に `.transcriptionConfidence` を
    ///   指定していない場合は `nil` になる。)
    /// - 結果は `startTime` の昇順 (同時刻なら元の並び順)。
    func speechWords() -> [SpeechWord] {
        var indexed: [(offset: Int, word: SpeechWord)] = []

        for (offset, run) in runs.enumerated() {
            guard let timeRange = run.audioTimeRange else { continue }

            let start = timeRange.start.seconds
            let end = timeRange.end.seconds
            guard start.isFinite, end.isFinite else { continue }

            let text = String(self[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let clampedStart = max(0, start)
            let clampedEnd = max(clampedStart, end)

            var confidence: Double?
            if let value = run.transcriptionConfidence, value.isFinite {
                confidence = value
            }

            indexed.append(
                (
                    offset,
                    SpeechWord(
                        text: text,
                        startTime: clampedStart,
                        endTime: clampedEnd,
                        confidence: confidence
                    )
                )
            )
        }

        return indexed
            .sorted { lhs, rhs in
                if lhs.word.startTime == rhs.word.startTime {
                    return lhs.offset < rhs.offset
                }
                return lhs.word.startTime < rhs.word.startTime
            }
            .map(\.word)
    }
}
