import AVFoundation
import Foundation

enum ResamplerError: Error { case invalidRate, outputTooLarge, conversionFailed }

enum Resampler {
    static let maximumOutputFrames = 96_000

    static func resample(input: [Float], fromRate: Double, toRate: Double) throws -> [Float] {
        try resampleHighQuality(input: input, fromRate: fromRate, toRate: toRate)
    }

    static func resampleHighQuality(input: [Float], fromRate: Double, toRate: Double) throws -> [Float] {
        guard fromRate.isFinite, toRate.isFinite, fromRate > 0, toRate > 0 else { throw ResamplerError.invalidRate }
        guard !input.isEmpty else { return [] }
        guard fromRate != toRate else { return input }
        let estimated = ceil(Double(input.count) * toRate / fromRate) + 256
        guard estimated.isFinite, estimated > 0, estimated <= Double(maximumOutputFrames),
              input.count <= Int(AVAudioFrameCount.max),
              let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: fromRate, channels: 1),
              let destinationFormat = AVAudioFormat(standardFormatWithSampleRate: toRate, channels: 1),
              let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(input.count)),
              let destination = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: AVAudioFrameCount(estimated)) else {
            throw ResamplerError.outputTooLarge
        }
        source.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: input.count) }
        var supplied = false
        var output: [Float] = []
        output.reserveCapacity(Int(estimated))
        while true {
            destination.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: destination, error: &conversionError) { _, state in
                guard !supplied else { state.pointee = .endOfStream; return nil }
                supplied = true
                state.pointee = .haveData
                return source
            }
            guard conversionError == nil, status != .error, status != .inputRanDry else {
                throw ResamplerError.conversionFailed
            }
            let count = Int(destination.frameLength)
            guard output.count + count <= maximumOutputFrames else { throw ResamplerError.outputTooLarge }
            output.append(contentsOf: UnsafeBufferPointer(start: destination.floatChannelData![0], count: count))
            if status == .endOfStream { break }
        }
        let scale = Float(fromRate / toRate)
        return output.map { $0 * scale }
    }
}
