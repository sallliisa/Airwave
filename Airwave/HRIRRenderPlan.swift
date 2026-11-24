import Accelerate
import Foundation

/// Renders a single virtual speaker to binaural output
nonisolated struct VirtualSpeakerRenderer {
    let speaker: VirtualSpeaker
    let convolver: StereoConvolutionEngine
}

/// One set of convolution engines prepared for a specific input layout and sample rate.
nonisolated struct HRIRRenderPlan {
    static let blockSize = 512

    let channelMap: HRIRChannelMap
    let renderers: [VirtualSpeakerRenderer]
    let tailFrames: Int

    static func prepare(
        url: URL,
        inputLayout: InputLayout,
        sampleRate: Double,
        blockSize: Int,
        isCancelled: () -> Bool = { false }
    ) throws -> HRIRRenderPlan {
        let wav = try WAVLoader.load(from: url)
        guard !isCancelled() else { throw CancellationError() }
        let speakers = inputLayout.channels
        let channelMap = wav.channelCount == 7
            ? HRIRChannelMap.hesuvi7Channel(speakers: speakers)
            : HRIRChannelMap.hesuvi14Channel(speakers: speakers)
        let log2n = vDSP_Length(log2(Double(blockSize * 2)))
        let fftSetup = FFTSetupManager.shared.getSetup(log2n: log2n)

        func response(at index: Int) throws -> [Float] {
            let samples = wav.audioData[index]
            guard abs(wav.sampleRate - sampleRate) > 0.01 else { return samples }
            return try Resampler.resampleHighQuality(input: samples, fromRate: wav.sampleRate, toRate: sampleRate)
        }

        var renderers: [VirtualSpeakerRenderer] = []
        renderers.reserveCapacity(speakers.count)
        var responseLength = 0
        for speaker in speakers {
            guard !isCancelled() else { throw CancellationError() }
            guard let (leftIndex, rightIndex) = channelMap.getIndices(for: speaker) else { continue }
            guard leftIndex < wav.channelCount, rightIndex < wav.channelCount else {
                throw HRIRError.invalidChannelMapping(
                    "HRIR indices (\(leftIndex), \(rightIndex)) out of range for \(wav.channelCount) channels"
                )
            }

            let left = try response(at: leftIndex)
            let right = try response(at: rightIndex)
            guard let convolver = StereoConvolutionEngine(
                leftEarHRIR: left,
                rightEarHRIR: right,
                blockSize: blockSize,
                sharedFFTSetup: fftSetup
            ) else {
                throw HRIRError.convolutionSetupFailed("Failed to create engines for \(speaker.displayName)")
            }
            responseLength = max(responseLength, left.count, right.count)
            renderers.append(VirtualSpeakerRenderer(speaker: speaker, convolver: convolver))
        }

        guard !renderers.isEmpty else {
            throw HRIRError.convolutionSetupFailed("No valid renderers created")
        }
        return HRIRRenderPlan(channelMap: channelMap, renderers: renderers, tailFrames: max(0, responseLength - 1))
    }
}

nonisolated enum HRIRError: LocalizedError {
    case invalidChannelCount(Int)
    case emptyFile
    case convolutionSetupFailed(String)
    case invalidChannelMapping(String)
    case batchImportFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidChannelCount(let count):
            return "Invalid HRIR channel count: \(count). Must have at least 2 channels."
        case .emptyFile:
            return "HRIR file is empty"
        case .convolutionSetupFailed(let detail):
            return "Failed to set up convolution: \(detail)"
        case .invalidChannelMapping(let detail):
            return "Invalid channel mapping: \(detail)"
        case .batchImportFailed(let detail):
            return "Batch import failed: \(detail)"
        }
    }
}
