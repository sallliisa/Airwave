import Accelerate
import AVFoundation
import AudioToolbox

nonisolated struct SpatialInputLayout {
    static let maximumChannelCount = 16

    let channelCount: Int
    let layout: InputLayout

    init?(format: AVAudioFormat) {
        let count = Int(format.channelCount)
        guard (1...Self.maximumChannelCount).contains(count) else { return nil }
        channelCount = count

        if count == 1 {
            layout = .stereo
        } else {
            let labels = format.channelLayout.flatMap { Self.channelLabels($0.layout, channelCount: count) }
            guard case .supported(let resolved) = InputLayoutResolver.resolve(
                channelLabels: labels, channelCount: count
            ) else { return nil }
            layout = resolved
        }
    }

    private static func channelLabels(_ layout: UnsafePointer<AudioChannelLayout>, channelCount: Int) -> [UInt32]? {
        let tag = layout.pointee.mChannelLayoutTag
        if tag & 0xFFFF_0000 == kAudioChannelLayoutTag_DiscreteInOrder { return nil }
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        func labels(at pointer: UnsafePointer<AudioChannelLayout>) -> [UInt32]? {
            guard pointer.pointee.mNumberChannelDescriptions == channelCount else { return nil }
            let descriptions = UnsafeRawPointer(pointer).advanced(by: offset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            let labels = (0..<channelCount).map { descriptions[$0].mChannelLabel }
            return labels.allSatisfy { label in
                label == kAudioChannelLabel_Discrete || label & 0xFFFF_0000 == kAudioChannelLabel_Discrete_0
            } ? nil : labels
        }

        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return labels(at: layout)
        }

        // A tagged layout or bitmap carries speaker order but no inline descriptions.
        let property = tag == kAudioChannelLayoutTag_UseChannelBitmap
            ? kAudioFormatProperty_ChannelLayoutForBitmap
            : kAudioFormatProperty_ChannelLayoutForTag
        var specifier = property == kAudioFormatProperty_ChannelLayoutForBitmap
            ? layout.pointee.mChannelBitmap.rawValue
            : tag
        var size = UInt32(offset + channelCount * MemoryLayout<AudioChannelDescription>.stride)
        return withUnsafeTemporaryAllocation(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment) {
            guard AudioFormatGetProperty(property, UInt32(MemoryLayout<UInt32>.size), &specifier, &size, $0.baseAddress!) == noErr,
                  size >= offset + channelCount * MemoryLayout<AudioChannelDescription>.stride else { return nil }
            return labels(at: $0.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self))
        }
    }
}

nonisolated final class SpatialProcessor {
    private enum SpeakerFilter {
        case convolve(StereoConvolutionEngine)
        case downmix(left: Float, right: Float)
    }

    private enum FilterBank {
        case symmetricStereo(sum: StereoConvolutionEngine, difference: StereoConvolutionEngine)
        case perSpeaker([SpeakerFilter])
    }

    private let channelCount: Int
    private let blockSize: Int
    let tailFrames: Int
    private let filters: FilterBank
    private let scratch: UnsafeMutablePointer<Float>

    init(url: URL, sampleRate: Double, layout: SpatialInputLayout) throws {
        var responses: [VirtualSpeaker: (left: [Float], right: [Float])] = [:]
        var longestResponse = 0
        _ = try HRIRRenderPlan.readResponses(url: url, inputLayout: layout.layout, sampleRate: sampleRate) { speaker, left, right in
            responses[speaker] = (left, right)
            longestResponse = max(longestResponse, left.count, right.count)
        }

        // Longer responses use larger partitions to bound spectral work per block.
        let size = longestResponse <= 8192 ? 128 : 512
        channelCount = layout.channelCount
        blockSize = size
        tailFrames = max(0, longestResponse - 1)
        let setup = FFTSetupManager.shared.getSetup(log2n: vDSP_Length(log2(Double(2 * size))))
        func filter(_ left: [Float], _ right: [Float]) throws -> StereoConvolutionEngine {
            guard let engine = StereoConvolutionEngine(leftEarHRIR: left, rightEarHRIR: right,
                                                       blockSize: size, sharedFFTSetup: setup) else {
                throw HRIRError.convolutionSetupFailed("Could not prepare the stereo filters.")
            }
            return engine
        }

        if layout.layout.channels == [.FL, .FR], let left = responses[.FL], let right = responses[.FR],
           left.left == right.right, left.right == right.left, left.left.count == left.right.count {
            // The sum and difference diagonalize a mirror-symmetric stereo filter.
            filters = .symmetricStereo(
                sum: try filter(zip(left.left, left.right).map { ($0 + $1) * 0.5 }, []),
                difference: try filter(zip(left.left, left.right).map { ($0 - $1) * 0.5 }, [])
            )
        } else {
            filters = .perSpeaker(try layout.layout.channels.map { speaker in
                if let response = responses[speaker] {
                    return .convolve(try filter(response.left, response.right))
                }
                let gains = StereoDownmixGains.gains(for: speaker)
                return .downmix(left: gains.left, right: gains.right)
            })
        }
        scratch = .allocate(capacity: size * 2)
    }

    deinit { scratch.deallocate() }

    func reset() {
        switch filters {
        case .symmetricStereo(let sum, let difference):
            sum.reset()
            difference.reset()
        case .perSpeaker(let speakers):
            for case .convolve(let engine) in speakers {
                engine.reset()
            }
        }
    }

    func process(input: UnsafePointer<Float>, channelStride: Int, leftOutput: UnsafeMutablePointer<Float>,
                 rightOutput: UnsafeMutablePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let frames = min(frameCount - offset, blockSize)
            let length = vDSP_Length(frames)
            let source = input + offset
            let outL = leftOutput + offset
            let outR = rightOutput + offset
            let rightScratch = scratch + blockSize
            switch filters {
            case .symmetricStereo(let sum, let difference):
                let right = source + (channelCount - 1) * channelStride
                vDSP_vadd(source, 1, right, 1, scratch, 1, length)
                vDSP_vsub(right, 1, source, 1, rightScratch, 1, length)
                sum.process(input: scratch, outputLeft: scratch, outputRight: nil, frames: frames)
                difference.process(input: rightScratch, outputLeft: rightScratch, outputRight: nil, frames: frames)
                vDSP_vadd(scratch, 1, rightScratch, 1, outL, 1, length)
                vDSP_vsub(rightScratch, 1, scratch, 1, outR, 1, length)
            case .perSpeaker(let speakers):
                vDSP_vclr(outL, 1, length)
                vDSP_vclr(outR, 1, length)
                for (channel, speaker) in speakers.enumerated() {
                    let samples = source + min(channel, channelCount - 1) * channelStride
                    switch speaker {
                    case .convolve(let engine):
                        engine.process(input: samples, outputLeft: scratch, outputRight: rightScratch, frames: frames)
                        vDSP_vadd(outL, 1, scratch, 1, outL, 1, length)
                        vDSP_vadd(outR, 1, rightScratch, 1, outR, 1, length)
                    case .downmix(var left, var right):
                        if left != 0 { vDSP_vsma(samples, 1, &left, outL, 1, outL, 1, length) }
                        if right != 0 { vDSP_vsma(samples, 1, &right, outR, 1, outR, 1, length) }
                    }
                }
            }
            offset += frames
        }
    }
}
