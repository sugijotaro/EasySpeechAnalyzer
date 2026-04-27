//
//  SpeechSegment.swift
//  EasySpeechAnalyzer
//

import Foundation

// MARK: - SpeechSegment

/// 認識されたフレーズ単位のセグメント。
///
/// 字幕編集アプリではこれが「1 つの字幕クリップの素」になる。
/// `id` は安定なので SwiftUI の `ForEach(segments)` にそのまま渡せる。
@available(iOS 26.0, *)
public struct SpeechSegment: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// 認識結果のプレーンテキスト。
    public var text: String
    /// 録音開始からの経過秒数 (セグメント開始)。
    public var startTime: TimeInterval
    /// 録音開始からの経過秒数 (セグメント終了)。
    public var endTime: TimeInterval
    /// 信頼度 (0.0–1.0)。`SpeechTranscriber` が提供しない場合は `nil`。
    public var confidence: Double?
    /// 確定したセグメントなら `true`、暫定 (volatile) なら `false`。
    public var isFinal: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil,
        isFinal: Bool
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.isFinal = isFinal
    }

    /// セグメントの長さ (秒)。
    public var duration: TimeInterval {
        max(0, endTime - startTime)
    }
}

// MARK: - SpeechAnalyzerState

/// マネージャーの実行状態。`isRecording` の代わりに UI 分岐の根拠として使う。
@available(iOS 26.0, *)
public enum SpeechAnalyzerState: Equatable, Sendable {
    /// 何もしていない (まだ開始されていない)。
    case idle
    /// 起動中 (権限取得・モデル準備・解析セッション開始)。
    case preparing
    /// 録音と解析の最中。
    case recording
    /// 停止処理の最中。
    case finishing
    /// 正常に停止した。`makeTranscript()` で結果を取り出せる。
    case completed
    /// エラーで終了した。
    case failed(String)

    /// `state == .recording` を簡潔に書くためのショートカット。
    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// `startAnalyzer()` を新たに呼んでよい状態か。
    public var canStart: Bool {
        switch self {
        case .idle, .completed, .failed: return true
        case .preparing, .recording, .finishing: return false
        }
    }

    /// 失敗の説明文 (失敗していなければ `nil`)。
    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

// MARK: - SpeechAnalyzerAvailability

/// 端末でこのライブラリが使えるかどうかと、使えない場合の理由。
@available(iOS 26.0, *)
public enum SpeechAnalyzerAvailability: Equatable, Sendable {
    /// 利用可能。
    case available
    /// OS が iOS 26 未満。
    case unsupportedOS
    /// 指定ロケールがオンデバイス文字起こしに対応していない。
    case unsupportedLocale(Locale)
    /// マイク権限が拒否されている (まだ未確認の場合は `available` を返す。実際の利用時に要求される)。
    case microphonePermissionDenied
    /// 音声認識の権限が拒否されている (フォールバックリコグナイザを使う場合に意味を持つ)。
    case speechRecognitionPermissionDenied
    /// 端末で `SpeechAnalyzer` のフォーマットを得られない。
    case analyzerUnavailable

    /// 人間に見せる用のデフォルト文言 (アプリ側で上書き推奨)。
    public var defaultMessage: String {
        switch self {
        case .available:
            return "利用可能です"
        case .unsupportedOS:
            return "この端末の OS バージョンでは利用できません"
        case .unsupportedLocale(let locale):
            return "この言語 (\(locale.identifier)) は端末上の文字起こしに対応していません"
        case .microphonePermissionDenied:
            return "マイクの使用が許可されていません"
        case .speechRecognitionPermissionDenied:
            return "音声認識の使用が許可されていません"
        case .analyzerUnavailable:
            return "この端末で音声認識のフォーマットを取得できませんでした"
        }
    }
}

// MARK: - SpeechTranscript

/// 1 回の文字起こしセッションのスナップショット。
///
/// 録音停止時に `EasySpeechAnalyzerManager.makeTranscript()` でこれを取り出し、
/// 字幕分割や永続化に渡す想定。
@available(iOS 26.0, *)
public struct SpeechTranscript: Sendable, Equatable {
    /// 全体の連結テキスト (確定 + 暫定)。
    public var text: String
    /// セグメント配列 (確定 + 暫定の順)。空の場合もある。
    public var segments: [SpeechSegment]
    /// 認識に使ったロケール。
    public var locale: Locale
    /// 録音にかかったおおよその秒数。録音していなかった場合は `nil`。
    public var duration: TimeInterval?
    /// このスナップショットが作られた時刻。
    public var createdAt: Date

    public init(
        text: String,
        segments: [SpeechSegment],
        locale: Locale,
        duration: TimeInterval? = nil,
        createdAt: Date = Date()
    ) {
        self.text = text
        self.segments = segments
        self.locale = locale
        self.duration = duration
        self.createdAt = createdAt
    }

    /// 確定済みセグメントのみを抽出する。
    public var finalizedSegments: [SpeechSegment] {
        segments.filter { $0.isFinal }
    }

    /// 暫定セグメントのみを抽出する。
    public var volatileSegments: [SpeechSegment] {
        segments.filter { !$0.isFinal }
    }
}
