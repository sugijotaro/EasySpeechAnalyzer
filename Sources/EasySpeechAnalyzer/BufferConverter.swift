//
//  BufferConverter.swift
//  EasySpeechAnalyzer
//

@preconcurrency import AVFoundation
import Foundation

/// マイクから入力された音声データを、`SpeechAnalyzer` が要求するフォーマットへ変換するための内部ユーティリティ。
@available(iOS 26.0, *)
final class BufferConverter {
    enum Error: Swift.Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else {
            return buffer
        }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            // 最初のサンプルの品質を犠牲にして、ソースとのタイムスタンプのずれを回避する。
            converter?.primeMethod = .none
        }

        guard let converter else {
            throw Error.failedToCreateConverter
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = AVAudioFrameCount(scaledInputFrameLength.rounded(.up))
        guard let conversionBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frameCapacity) else {
            throw Error.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        // converter.convert(to:error:withInputFrom:) のクロージャは @Sendable と扱われるため、
        // 単純な `var` は捕捉できない。同期的に同じスレッドで呼ばれる前提で参照型に閉じ込める。
        final class State: @unchecked Sendable { var processed = false }
        let state = State()

        let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
            // このクロージャは複数回呼び出されることがあるが、提供できるバッファは一つだけ。
            defer { state.processed = true }
            inputStatusPointer.pointee = state.processed ? .noDataNow : .haveData
            return state.processed ? nil : buffer
        }

        guard status != .error else {
            throw Error.conversionFailed(nsError)
        }

        return conversionBuffer
    }
}
