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
        var output: [SubtitleSegment] = []
        for segment in segments {
            output.append(contentsOf: split(segment, with: options))
        }
        return output
    }

    private static func split(
        _ segment: SpeechSegment,
        with options: SubtitleSegmentationOptions
    ) -> [SubtitleSegment] {
        let maxChars = max(1, options.maxCharactersPerLine * options.maxLines)
        let trimmedText = segment.text
        guard !trimmedText.isEmpty else { return [] }

        let withinChars = trimmedText.count <= maxChars
        let withinDuration = segment.duration <= options.maxDuration

        if withinChars && withinDuration {
            return [SubtitleSegment(
                text: trimmedText,
                startTime: segment.startTime,
                endTime: segment.endTime
            )]
        }

        // ステップ 1: 句読点で分ける (オプション)
        let initialPieces: [String]
        if options.splitByPunctuation {
            initialPieces = splitByPunctuation(trimmedText)
        } else {
            initialPieces = [trimmedText]
        }

        // ステップ 2: それでも長すぎるピースは文字数で強制分割
        var refinedPieces: [String] = []
        for piece in initialPieces {
            if piece.count <= maxChars {
                refinedPieces.append(piece)
            } else {
                refinedPieces.append(contentsOf: splitByLength(piece, maxChars: maxChars))
            }
        }

        // ステップ 3: 元セグメントの時間レンジを文字数比例で割り当てる
        let totalChars = refinedPieces.reduce(0) { $0 + $1.count }
        guard totalChars > 0 else { return [] }

        let totalDuration = segment.duration
        var subtitles: [SubtitleSegment] = []
        var cursor = segment.startTime

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

            subtitles.append(SubtitleSegment(
                text: piece,
                startTime: cursor,
                endTime: adjustedEnd
            ))
            cursor = adjustedEnd
        }

        return subtitles
    }

    private static let punctuationCharacters: Set<Character> = [
        "。", "、", "．", "，", ".", ",", "!", "?", "！", "？"
    ]

    private static func splitByPunctuation(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if punctuationCharacters.contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pieces.append(trimmed)
                }
                current = ""
            }
        }
        let trimmedTail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTail.isEmpty {
            pieces.append(trimmedTail)
        }
        return pieces.isEmpty ? [text] : pieces
    }

    private static func splitByLength(_ text: String, maxChars: Int) -> [String] {
        guard maxChars > 0 else { return [text] }
        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= maxChars {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
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
