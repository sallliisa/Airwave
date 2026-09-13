import XCTest
@testable import Airwave

final class RealtimeAudioProcessorTests: XCTestCase {
    private let blockSize = 512
    private let maxFrames = 4096

    private func makeProcessor(rendererCount: Int = 2) -> RealtimeAudioProcessor {
        let renderers = (0..<rendererCount).map { index in
            let convolver = try! XCTUnwrap(StereoConvolutionEngine(
                leftEarHRIR: [Float(index + 1)],
                rightEarHRIR: [Float(index + 1)],
                blockSize: blockSize
            ))
            return VirtualSpeakerRenderer(
                speaker: index == 0 ? .FL : .FR,
                convolver: convolver
            )
        }
        return RealtimeAudioProcessor(
            renderers: renderers,
            inputChannelCount: 2,
            fallbackSpeakers: [.FL, .FR],
            blockSize: blockSize,
            maxFramesPerCallback: maxFrames
        )
    }

    private func process(
        _ processor: RealtimeAudioProcessor,
        size: Int,
        leftValue: Float = 1,
        rightValue: Float = 2,
        input: [Float]? = nil
    ) -> ([Float], [Float]) {
        let left = input ?? [Float](repeating: leftValue, count: size)
        let right = input ?? [Float](repeating: rightValue, count: size)
        var outputLeft = [Float](repeating: .nan, count: size)
        var outputRight = [Float](repeating: .nan, count: size)
        left.withUnsafeBufferPointer { leftPtr in
            right.withUnsafeBufferPointer { rightPtr in
                outputLeft.withUnsafeMutableBufferPointer { leftOutPtr in
                    outputRight.withUnsafeMutableBufferPointer { rightOutPtr in
                        let channels: [UnsafePointer<Float>?] = [leftPtr.baseAddress!, rightPtr.baseAddress!]
                        channels.withUnsafeBufferPointer { channelPointers in
                            processor.process(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 2,
                                inputOffset: 0,
                                leftOutput: leftOutPtr.baseAddress!,
                                rightOutput: rightOutPtr.baseAddress!,
                                frameCount: size
                            )
                        }
                    }
                }
            }
        }
        return (outputLeft, outputRight)
    }

    func testAllRequiredCallbackSizesWriteFiniteOutput() {
        for size in [1, 64, 128, 256, 511, 512, 513, 768, 1024, 4096] {
            let processor = makeProcessor()
            let (left, right) = process(processor, size: size)
            XCTAssertTrue(left.allSatisfy { $0.isFinite }, "left size \(size)")
            XCTAssertTrue(right.allSatisfy { $0.isFinite }, "right size \(size)")
        }
    }

    func testMixedCallbackSequencePreservesOrderAfterAdapterLatency() {
        let processor = makeProcessor(rendererCount: 1)
        var output: [Float] = []
        for size in [128, 128, 128, 128, 513, 768, 1024, 4096] {
            output.append(contentsOf: process(processor, size: size).0)
        }

        XCTAssertEqual(output.count, 6913)
        XCTAssertTrue(output.prefix(384).allSatisfy { $0 == 0 })
        XCTAssertTrue(output.dropFirst(384).allSatisfy { abs($0 - 1) < 0.0001 })
    }

    func testResetClearsPendingInputAndQueuedOutput() {
        let processor = makeProcessor(rendererCount: 1)
        _ = process(processor, size: 512)
        processor.reset()
        let (left, right) = process(processor, size: 1)

        XCTAssertEqual(left, [0])
        XCTAssertEqual(right, [0])
    }

    func testUnderflowSilenceAndMonoDuplication() {
        // Two paired renderers so both captured channels are consumed; the
        // identical feeds must then emerge identically on both ears.
        let processor = makeProcessor(rendererCount: 2)
        let (underflowLeft, underflowRight) = process(processor, size: 3, leftValue: 0.5, rightValue: 0.5)
        XCTAssertEqual(underflowLeft, [0, 0, 0])
        XCTAssertEqual(underflowRight, underflowLeft)
        let (left, right) = process(processor, size: 512, leftValue: 0.5, rightValue: 0.5)
        XCTAssertEqual(left, right)
    }

    func testFifoWrapsWithoutLosingOrDuplicatingSamples() {
        // 4096-frame callbacks wrap the 4608-frame ring on every other call.
        // Two paired renderers keep both captured channels consumed, so neither
        // ear picks up an unpaired-channel downmix term. The ramp drives
        // channel 0 only: with two gain-1 renderers a shared-ramp stimulus
        // would legitimately sum to twice the input and defeat the pass-through
        // assertion below.
        let engines = (0..<2).map { _ -> StereoConvolutionEngine in
            try! XCTUnwrap(StereoConvolutionEngine(
                leftEarHRIR: [1],
                rightEarHRIR: [1],
                blockSize: blockSize
            ))
        }
        let renderers = [
            VirtualSpeakerRenderer(speaker: .FL, convolver: engines[0]),
            VirtualSpeakerRenderer(speaker: .FR, convolver: engines[1])
        ]
        let processor = RealtimeAudioProcessor(
            renderers: renderers,
            inputChannelCount: 2,
            fallbackSpeakers: [.FL, .FR],
            blockSize: blockSize,
            maxFramesPerCallback: maxFrames
        )
        let size = 4096
        var frame: Float = 0
        for _ in 0..<6 {
            let input = (0..<size).map { _ -> Float in frame += 1; return frame / 100_000 }
            let silence = [Float](repeating: 0, count: size)
            var left = [Float](repeating: .nan, count: size)
            var right = [Float](repeating: .nan, count: size)
            input.withUnsafeBufferPointer { inputPtr in
                silence.withUnsafeBufferPointer { silencePtr in
                    left.withUnsafeMutableBufferPointer { leftPtr in
                        right.withUnsafeMutableBufferPointer { rightPtr in
                            processor.process(
                                inputChannels: [UnsafePointer<Float>?(inputPtr.baseAddress!), silencePtr.baseAddress!],
                                inputChannelCount: 2,
                                inputOffset: 0,
                                leftOutput: leftPtr.baseAddress!,
                                rightOutput: rightPtr.baseAddress!,
                                frameCount: size
                            )
                        }
                    }
                }
            }
            // Identity impulse response of gain 1: block-aligned callbacks pass through.
            for index in 0..<size {
                XCTAssertEqual(left[index], input[index], accuracy: 1e-5)
                XCTAssertEqual(right[index], input[index], accuracy: 1e-5)
            }
        }
    }

    func testUnalignedCallbacksNeverReorderOrDuplicateSamplesAcrossWrap() {
        // Callbacks smaller than blockSize underflow by design, so the stream is
        // gapped; what must hold across the FIFO wrap is that the samples that do
        // come out are in input order, each at most once.
        let processor = makeProcessor(rendererCount: 1)
        let size = 300
        var output: [Float] = []
        var frame: Float = 0
        for _ in 0..<40 {
            let chunk = (0..<size).map { _ -> Float in frame += 1; return frame / 100_000 }
            output.append(contentsOf: process(processor, size: size, input: chunk).0)
        }

        let delivered = output.filter { $0 != 0 }
        XCTAssertGreaterThan(delivered.count, 40 * size * 3 / 4)
        XCTAssertEqual(delivered, delivered.sorted())
        XCTAssertEqual(Set(delivered).count, delivered.count)
        XCTAssertTrue(delivered.allSatisfy { $0 <= frame / 100_000 })
    }

    func testCanariesRemainUnchanged() {
        let processor = makeProcessor(rendererCount: 1)
        let size = 4096
        let canary: Float = 12345
        let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: size + 2)
        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: size + 2)
        inputStorage.initialize(repeating: 0, count: size + 2)
        outputStorage.initialize(repeating: canary, count: size + 2)
        defer {
            inputStorage.deinitialize(count: size + 2)
            outputStorage.deinitialize(count: size + 2)
            inputStorage.deallocate()
            outputStorage.deallocate()
        }

        let inputChannel = UnsafePointer(inputStorage.advanced(by: 1))
        let channels: [UnsafePointer<Float>?] = [inputChannel, nil]
        channels.withUnsafeBufferPointer { channelPointers in
            processor.process(
                inputChannels: channelPointers.baseAddress!,
                inputChannelCount: 2,
                inputOffset: 0,
                leftOutput: outputStorage.advanced(by: 1),
                rightOutput: outputStorage.advanced(by: 1),
                frameCount: size
            )
        }

        XCTAssertEqual(inputStorage[0], 0)
        XCTAssertEqual(inputStorage[size + 1], 0)
        XCTAssertEqual(outputStorage[0], canary)
        XCTAssertEqual(outputStorage[size + 1], canary)
    }

    func testEightIndependentFeedsEachReachTheirPairedRenderer() {
        let renderers = (0..<8).map { index -> VirtualSpeakerRenderer in
            let convolver = try! XCTUnwrap(StereoConvolutionEngine(
                leftEarHRIR: [Float(index + 1)],
                rightEarHRIR: [Float(index + 1)],
                blockSize: blockSize
            ))
            return VirtualSpeakerRenderer(speaker: index == 0 ? .FL : .FR, convolver: convolver)
        }
        let processor = RealtimeAudioProcessor(
            renderers: renderers,
            inputChannelCount: 8,
            fallbackSpeakers: [.FL, .FR, .FC, .LFE, .BL, .BR, .SL, .SR],
            blockSize: blockSize,
            maxFramesPerCallback: maxFrames
        )

        func drainedMix(zeroedChannel: Int?) -> (left: [Float], right: [Float]) {
            var outputLeft = [Float](repeating: .nan, count: blockSize)
            var outputRight = [Float](repeating: .nan, count: blockSize)
            var storage: [Float] = []
            storage.reserveCapacity(8 * blockSize)
            for index in 0..<8 {
                storage.append(contentsOf: repeatElement(Float(index + 1), count: blockSize))
            }
            storage.withUnsafeMutableBufferPointer { storageBuffer in
                let base = UnsafePointer(storageBuffer.baseAddress!)
                let pointers: [UnsafePointer<Float>?] = (0..<8).map { index in
                    index == zeroedChannel ? nil : base.advanced(by: index * blockSize)
                }
                pointers.withUnsafeBufferPointer { channelPointers in
                    outputLeft.withUnsafeMutableBufferPointer { leftOutPtr in
                        outputRight.withUnsafeMutableBufferPointer { rightOutPtr in
                            processor.process(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 8,
                                inputOffset: 0,
                                leftOutput: leftOutPtr.baseAddress!,
                                rightOutput: rightOutPtr.baseAddress!,
                                frameCount: blockSize
                            )
                            processor.process(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 8,
                                inputOffset: 0,
                                leftOutput: leftOutPtr.baseAddress!,
                                rightOutput: rightOutPtr.baseAddress!,
                                frameCount: blockSize
                            )
                        }
                    }
                }
            }
            return (outputLeft, outputRight)
        }

        // Single-tap engines with gain (index + 1): the drained block equals
        // sum((i+1)^2) when every feed participates...
        let full = drainedMix(zeroedChannel: nil)
        let fullSum: Float = (1...8).reduce(0) { $0 + Float($1 * $1) }
        XCTAssertEqual(full.left.first!, fullSum, accuracy: 1e-3)

        // ...and drops by exactly (k+1)^2 when channel k goes silent, proving
        // each feed reaches its own renderer and nothing else.
        for zeroed in [0, 3, 7] {
            let partial = drainedMix(zeroedChannel: zeroed)
            let expected = fullSum - Float((zeroed + 1) * (zeroed + 1))
            XCTAssertEqual(partial.left.first!, expected, accuracy: 1e-3, "zeroed \(zeroed)")
            XCTAssertEqual(partial.right.first!, expected, accuracy: 1e-3, "zeroed \(zeroed)")
        }
    }

    func testUnpairedChannelsFoldThroughDownmixGainsWithoutConvolution() {
        // Two silent paired renderers; channels 2-7 have no renderer and must
        // enter the mix only through StereoDownmixGains.
        let renderers = (0..<2).map { _ -> VirtualSpeakerRenderer in
            let convolver = try! XCTUnwrap(StereoConvolutionEngine(
                leftEarHRIR: [0],
                rightEarHRIR: [0],
                blockSize: blockSize
            ))
            return VirtualSpeakerRenderer(speaker: .FL, convolver: convolver)
        }
        func drainedMix(loudChannels: Set<Int>) -> (left: Float, right: Float) {
            let processor = RealtimeAudioProcessor(
                renderers: renderers,
                inputChannelCount: 8,
                fallbackSpeakers: [.FL, .FR, .FC, .LFE, .BL, .BR, .SL, .SR],
                blockSize: blockSize,
                maxFramesPerCallback: maxFrames
            )
            var storage = [Float](repeating: 0, count: 8 * blockSize)
            for index in loudChannels {
                for frame in (index * blockSize)..<((index + 1) * blockSize) {
                    storage[frame] = 1
                }
            }
            var outputLeft = [Float](repeating: .nan, count: blockSize)
            var outputRight = [Float](repeating: .nan, count: blockSize)
            storage.withUnsafeMutableBufferPointer { storageBuffer in
                let base = UnsafePointer(storageBuffer.baseAddress!)
                let pointers: [UnsafePointer<Float>?] = (0..<8).map { index in
                    base.advanced(by: index * blockSize)
                }
                pointers.withUnsafeBufferPointer { channelPointers in
                    outputLeft.withUnsafeMutableBufferPointer { leftOutPtr in
                        outputRight.withUnsafeMutableBufferPointer { rightOutPtr in
                            processor.process(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 8,
                                inputOffset: 0,
                                leftOutput: leftOutPtr.baseAddress!,
                                rightOutput: rightOutPtr.baseAddress!,
                                frameCount: blockSize
                            )
                            processor.process(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 8,
                                inputOffset: 0,
                                leftOutput: leftOutPtr.baseAddress!,
                                rightOutput: rightOutPtr.baseAddress!,
                                frameCount: blockSize
                            )
                        }
                    }
                }
            }
            return (outputLeft.first!, outputRight.first!)
        }

        // Surround fold-down: FC 0.707 both ears, BL/SL 0.5 left, BR/SR 0.5 right.
        let surround = drainedMix(loudChannels: [2, 4, 5, 6, 7])
        XCTAssertEqual(surround.left, 0.707 + 0.5 + 0.5, accuracy: 1e-4)
        XCTAssertEqual(surround.right, 0.707 + 0.5 + 0.5, accuracy: 1e-4)

        // LFE alone is omitted from the fold-down entirely.
        let lfeOnly = drainedMix(loudChannels: [3])
        XCTAssertEqual(lfeOnly.left, 0, accuracy: 1e-6)
        XCTAssertEqual(lfeOnly.right, 0, accuracy: 1e-6)
    }

    func testMonoCaptureDuplicatesIntoBothRendererFeeds() {
        // FL passes the left ear only; FR passes the right ear only. A mono
        // feed must reach both, which only duplication can achieve.
        let leftOnly = try! XCTUnwrap(StereoConvolutionEngine(
            leftEarHRIR: [1], rightEarHRIR: [0], blockSize: blockSize
        ))
        let rightOnly = try! XCTUnwrap(StereoConvolutionEngine(
            leftEarHRIR: [0], rightEarHRIR: [1], blockSize: blockSize
        ))
        let processor = RealtimeAudioProcessor(
            renderers: [
                VirtualSpeakerRenderer(speaker: .FL, convolver: leftOnly),
                VirtualSpeakerRenderer(speaker: .FR, convolver: rightOnly)
            ],
            inputChannelCount: 1,
            fallbackSpeakers: [.FC],
            blockSize: blockSize,
            maxFramesPerCallback: maxFrames
        )
        let feed = [Float](repeating: 1, count: blockSize)
        var outputLeft = [Float](repeating: .nan, count: blockSize)
        var outputRight = [Float](repeating: .nan, count: blockSize)
        feed.withUnsafeBufferPointer { feedPointer in
            let pointers: [UnsafePointer<Float>?] = [feedPointer.baseAddress!]
            pointers.withUnsafeBufferPointer { channelPointers in
                outputLeft.withUnsafeMutableBufferPointer { leftOutPtr in
                    outputRight.withUnsafeMutableBufferPointer { rightOutPtr in
                        processor.process(
                            inputChannels: channelPointers.baseAddress!,
                            inputChannelCount: 1,
                            inputOffset: 0,
                            leftOutput: leftOutPtr.baseAddress!,
                            rightOutput: rightOutPtr.baseAddress!,
                            frameCount: blockSize
                        )
                        processor.process(
                            inputChannels: channelPointers.baseAddress!,
                            inputChannelCount: 1,
                            inputOffset: 0,
                            leftOutput: leftOutPtr.baseAddress!,
                            rightOutput: rightOutPtr.baseAddress!,
                            frameCount: blockSize
                        )
                    }
                }
            }
        }
        XCTAssertEqual(outputLeft.first!, 1, accuracy: 1e-6)
        XCTAssertEqual(outputRight.first!, 1, accuracy: 1e-6)
    }

    func testFifoWrapPreservesOrderAcrossEightFeeds() {
        let renderers = (0..<8).map { _ -> VirtualSpeakerRenderer in
            let convolver = try! XCTUnwrap(StereoConvolutionEngine(
                leftEarHRIR: [0.125],
                rightEarHRIR: [0.125],
                blockSize: blockSize
            ))
            return VirtualSpeakerRenderer(speaker: .FL, convolver: convolver)
        }
        let processor = RealtimeAudioProcessor(
            renderers: renderers,
            inputChannelCount: 8,
            fallbackSpeakers: Array(repeating: .LFE, count: 8),
            blockSize: blockSize,
            maxFramesPerCallback: maxFrames
        )
        // 4096-frame callbacks wrap the 4608-frame ring on every other call;
        // eight identical unit-gain renderers reconstruct the shared ramp.
        let size = 4096
        var frame: Float = 0
        for _ in 0..<6 {
            let input = (0..<size).map { _ -> Float in frame += 1; return frame / 100_000 }
            var left = [Float](repeating: .nan, count: size)
            var right = [Float](repeating: .nan, count: size)
            input.withUnsafeBufferPointer { inputPtr in
                let pointers: [UnsafePointer<Float>?] = Array(repeating: inputPtr.baseAddress!, count: 8)
                pointers.withUnsafeBufferPointer { channelPointers in
                    left.withUnsafeMutableBufferPointer { leftPtr in
                        right.withUnsafeMutableBufferPointer { rightPtr in
                            processor.process(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 8,
                                inputOffset: 0,
                                leftOutput: leftPtr.baseAddress!,
                                rightOutput: rightPtr.baseAddress!,
                                frameCount: size
                            )
                        }
                    }
                }
            }
            for index in 0..<size {
                XCTAssertEqual(left[index], input[index], accuracy: 1e-4)
                XCTAssertEqual(right[index], input[index], accuracy: 1e-4)
            }
        }
    }

    func testTenSecondsOfStereoInputAcrossPerformanceCallbackSizes() {
        let sampleRate = 48_000
        let callbackSizes = [128, 512, 1024]
        var processedFrames = 0
        var finalLeftOutput: [Float] = []
        var finalRightOutput: [Float] = []

        measure {
            for size in callbackSizes {
                let processor = makeProcessor(rendererCount: 1)
                let input = [Float](repeating: 0.25, count: size)
                var leftOutput = [Float](repeating: 0, count: size)
                var rightOutput = [Float](repeating: 0, count: size)
                processedFrames = 0
                while processedFrames < sampleRate * 10 {
                    input.withUnsafeBufferPointer { inputPtr in
                        leftOutput.withUnsafeMutableBufferPointer { leftPtr in
                            rightOutput.withUnsafeMutableBufferPointer { rightPtr in
                                let channels: [UnsafePointer<Float>?] = [inputPtr.baseAddress!, inputPtr.baseAddress!]
                                channels.withUnsafeBufferPointer { channelPointers in
                                    processor.process(
                                        inputChannels: channelPointers.baseAddress!,
                                        inputChannelCount: 2,
                                        inputOffset: 0,
                                        leftOutput: leftPtr.baseAddress!,
                                        rightOutput: rightPtr.baseAddress!,
                                        frameCount: size
                                    )
                                }
                            }
                        }
                    }
                    processedFrames += size
                }
                finalLeftOutput = leftOutput
                finalRightOutput = rightOutput
            }
        }

        XCTAssertGreaterThanOrEqual(processedFrames, sampleRate * 10)
        XCTAssertTrue(finalLeftOutput.allSatisfy { $0.isFinite })
        XCTAssertTrue(finalRightOutput.allSatisfy { $0.isFinite })
    }
}

final class SpatialRendererCrossfaderTests: XCTestCase {
    private let blockSize = 512
    private let fadeLength = 1_024

    private func makeState(gain: Float) -> HRIRManager.RendererState {
        let convolver = StereoConvolutionEngine(
            leftEarHRIR: [gain],
            rightEarHRIR: [gain],
            blockSize: blockSize
        )!
        return HRIRManager.RendererState(
            renderers: [VirtualSpeakerRenderer(speaker: .FL, convolver: convolver)],
            inputChannelCount: 2,
            fallbackSpeakers: [.FL, .FR],
            blockSize: blockSize
        )
    }

    private let wideSpeakers: [VirtualSpeaker] = [.FL, .FR, .FC, .LFE, .BL, .BR]

    private func makeWideState() -> HRIRManager.RendererState {
        let renderers = wideSpeakers.map { speaker in
            let convolver = StereoConvolutionEngine(
                leftEarHRIR: [1],
                rightEarHRIR: [1],
                blockSize: blockSize
            )!
            return VirtualSpeakerRenderer(speaker: speaker, convolver: convolver)
        }
        return HRIRManager.RendererState(
            renderers: renderers,
            inputChannelCount: wideSpeakers.count,
            fallbackSpeakers: wideSpeakers,
            blockSize: blockSize
        )
    }

    private func makeCrossfader() -> SpatialRendererCrossfader {
        SpatialRendererCrossfader(primeLength: blockSize, fadeLength: fadeLength, maxFramesPerCallback: 4_096)
    }

    /// Drives a continuous 480 Hz sine through the crossfader in fixed callbacks
    /// and records the input and output streams for comparison.
    private final class Driver {
        let crossfader: SpatialRendererCrossfader
        private(set) var input: [Float] = []
        private(set) var outputLeft: [Float] = []
        private(set) var outputRight: [Float] = []
        private var frame = 0

        init(_ crossfader: SpatialRendererCrossfader) { self.crossfader = crossfader }

        func run(callbacks: Int, size: Int = 512) {
            for _ in 0..<callbacks {
                var chunk = [Float](repeating: 0, count: size)
                for index in 0..<size {
                    chunk[index] = Float(sin(2 * Double.pi * 480 * Double(frame + index) / 48_000))
                }
                frame += size
                var left = [Float](repeating: .nan, count: size)
                var right = [Float](repeating: .nan, count: size)
                chunk.withUnsafeBufferPointer { inputPtr in
                    left.withUnsafeMutableBufferPointer { leftPtr in
                        right.withUnsafeMutableBufferPointer { rightPtr in
                            let channels: [UnsafePointer<Float>?] = [inputPtr.baseAddress!, inputPtr.baseAddress!]
                            channels.withUnsafeBufferPointer { channelPointers in
                                let wrote = crossfader.processIfNeeded(
                                    inputChannels: channelPointers.baseAddress!,
                                    inputChannelCount: 2,
                                    leftOutput: leftPtr.baseAddress!,
                                    rightOutput: rightPtr.baseAddress!,
                                    frameCount: size
                                )
                                if !wrote {
                                    memcpy(leftPtr.baseAddress!, inputPtr.baseAddress!, size * MemoryLayout<Float>.size)
                                    memcpy(rightPtr.baseAddress!, inputPtr.baseAddress!, size * MemoryLayout<Float>.size)
                                }
                            }
                        }
                    }
                }
                input.append(contentsOf: chunk)
                outputLeft.append(contentsOf: left)
                outputRight.append(contentsOf: right)
            }
        }
    }

    /// Drives a wide fallback with non-front content so both crossfade
    /// directions exercise the shared downmix operation.
    private final class WideDriver {
        let crossfader: SpatialRendererCrossfader
        let signals: [Float] = [0, 0, 1, 0, 2, 3]
        private(set) var outputLeft: [Float] = []
        private(set) var outputRight: [Float] = []

        init(_ crossfader: SpatialRendererCrossfader) { self.crossfader = crossfader }

        func run(callbacks: Int, size: Int = 512) {
            for _ in 0..<callbacks {
                var input = [Float](repeating: 0, count: signals.count * size)
                for channel in signals.indices {
                    input.replaceSubrange(
                        (channel * size)..<((channel + 1) * size),
                        with: repeatElement(signals[channel], count: size)
                    )
                }
                var left = [Float](repeating: .nan, count: size)
                var right = [Float](repeating: .nan, count: size)
                input.withUnsafeMutableBufferPointer { inputBuffer in
                    let base = UnsafePointer(inputBuffer.baseAddress!)
                    let channels: [UnsafePointer<Float>?] = signals.indices.map {
                        base.advanced(by: $0 * size)
                    }
                    channels.withUnsafeBufferPointer { channelPointers in
                        left.withUnsafeMutableBufferPointer { leftOutput in
                            right.withUnsafeMutableBufferPointer { rightOutput in
                                let wrote = crossfader.processIfNeeded(
                                    inputChannels: channelPointers.baseAddress!,
                                    inputChannelCount: channels.count,
                                    leftOutput: leftOutput.baseAddress!,
                                    rightOutput: rightOutput.baseAddress!,
                                    frameCount: size
                                )
                                if !wrote {
                                    StereoDownmixGains.downmix(
                                        inputChannels: channelPointers.baseAddress!,
                                        inputChannelCount: channels.count,
                                        inputOffset: 0,
                                        inputSpeakers: [.FL, .FR, .FC, .LFE, .BL, .BR],
                                        outputLeft: leftOutput.baseAddress!,
                                        outputRight: rightOutput.baseAddress!,
                                        frameCount: size
                                    )
                                }
                            }
                        }
                    }
                }
                outputLeft.append(contentsOf: left)
                outputRight.append(contentsOf: right)
            }
        }
    }

    private func maximumStepDelta(_ samples: [Float]) -> Float {
        var maximum: Float = 0
        for index in 1..<samples.count {
            maximum = max(maximum, abs(samples[index] - samples[index - 1]))
        }
        return maximum
    }

    /// Largest per-sample curvature (second difference). A hard level jump of
    /// size J appears as curvature ≈ J; a sine of amplitude A contributes only
    /// A·ω² (≈0.007 at these settings), so this detects swaps without firing
    /// on steep-but-smooth wide-mix streams whose amplitude grew past unity
    /// (plan 022 adds the unpaired-channel fold-down to the captured mix).
    private func maximumCurvature(_ samples: [Float]) -> Float {
        var maximum: Float = 0
        for index in 2..<samples.count {
            let curvature = abs(samples[index] - 2 * samples[index - 1] + samples[index - 2])
            maximum = max(maximum, curvature)
        }
        return maximum
    }

    func testSwapProducesNoOutputDiscontinuity() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        let stateA = makeState(gain: 1)
        let stateB = makeState(gain: 0.5)

        crossfader.observe(stateA)
        driver.run(callbacks: 6)
        crossfader.observe(stateB)
        driver.run(callbacks: 8)

        // A hard swap steps by ~0.5 (the gain delta times the sine peak);
        // smooth rendering of even a 1.707-amplitude mix stays below 0.01.
        XCTAssertLessThan(maximumCurvature(driver.outputLeft), 0.1)
        XCTAssertLessThan(maximumCurvature(driver.outputRight), 0.1)
        XCTAssertTrue(driver.outputLeft.allSatisfy { $0.isFinite })
    }

    func testFadeCompletesOnIncomingState() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        crossfader.observe(makeState(gain: 1))
        driver.run(callbacks: 6)
        crossfader.observe(makeState(gain: 0.5))
        driver.run(callbacks: 8)

        XCTAssertFalse(crossfader.isFadingForTesting)
        let tail = driver.outputLeft.suffix(512)
        let expected = driver.input.suffix(512).map { $0 * 0.5 }
        for (actual, want) in zip(tail, expected) {
            XCTAssertEqual(actual, want, accuracy: 1e-5)
        }
    }

    func testRetiredStateIsHandedToControlThreadAndDrained() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        crossfader.observe(makeState(gain: 1))
        driver.run(callbacks: 6)
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 0) // faded in from passthrough

        crossfader.observe(makeState(gain: 0.5))
        driver.run(callbacks: 8)

        XCTAssertEqual(crossfader.retiredStateCountForTesting, 1)
        crossfader.drainRetiredStates()
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 0)
    }

    func testRapidDoubleSwitchSettlesOnNewestState() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        crossfader.observe(makeState(gain: 1))
        driver.run(callbacks: 6)

        crossfader.observe(makeState(gain: 0.5))
        driver.run(callbacks: 1) // still priming
        crossfader.observe(makeState(gain: 0.25))
        driver.run(callbacks: 12)

        XCTAssertFalse(crossfader.isFadingForTesting)
        XCTAssertLessThan(maximumStepDelta(driver.outputLeft), 0.1)
        let tail = driver.outputLeft.suffix(512)
        let expected = driver.input.suffix(512).map { $0 * 0.25 }
        for (actual, want) in zip(tail, expected) {
            XCTAssertEqual(actual, want, accuracy: 1e-5)
        }
    }

    func testRetirementSaturationEventuallyReachesNewestState() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        var newest: HRIRManager.RendererState?

        for index in 1...20 {
            newest = makeState(gain: Float(index) / 20)
            crossfader.observe(newest)
            driver.run(callbacks: 1)
        }

        for _ in 0..<40 {
            crossfader.drainRetiredStates()
            driver.run(callbacks: 1)
            if !crossfader.isFadingForTesting,
               crossfader.activeStateForTesting === newest { break }
        }

        XCTAssertFalse(crossfader.isFadingForTesting)
        XCTAssertTrue(crossfader.activeStateForTesting === newest)
        crossfader.drainRetiredStates()
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 0)
    }

    func testRemovingPresetFadesToPassthrough() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        crossfader.observe(makeState(gain: 0.5))
        driver.run(callbacks: 6)

        crossfader.observe(nil)
        XCTAssertTrue(crossfader.isFadingForTesting)
        driver.run(callbacks: 4)

        XCTAssertFalse(crossfader.isFadingForTesting)
        XCTAssertLessThan(maximumStepDelta(driver.outputLeft), 0.1)
        let tail = Array(driver.outputLeft.suffix(512))
        let expected = Array(driver.input.suffix(512))
        for (actual, want) in zip(tail, expected) {
            XCTAssertEqual(actual, want, accuracy: 1e-5)
        }
    }

    func testResetDropsStateWithoutFadingAndRetiresIt() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        let state = makeState(gain: 0.5)
        crossfader.observe(state)
        driver.run(callbacks: 6)

        crossfader.requestReset()
        driver.run(callbacks: 1)

        XCTAssertFalse(crossfader.isFadingForTesting)
        XCTAssertNil(crossfader.activeStateForTesting)
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 1)
        let tail = Array(driver.outputLeft.suffix(512))
        let expected = Array(driver.input.suffix(512))
        for (actual, want) in zip(tail, expected) {
            XCTAssertEqual(actual, want, accuracy: 1e-5)
        }
    }

    func testWidePassthroughEndpointKeepsCenterAndSurroundDuringBothFades() {
        let crossfader = makeCrossfader()
        let driver = WideDriver(crossfader)
        let state = makeWideState()

        crossfader.observe(state)
        driver.run(callbacks: 4)
        let incoming = driver.outputLeft
        XCTAssertTrue(incoming.allSatisfy { abs($0) > 1e-5 })

        crossfader.observe(nil)
        let outgoingStart = driver.outputLeft.count
        driver.run(callbacks: 4)
        let outgoing = driver.outputLeft[outgoingStart...]
        XCTAssertTrue(outgoing.allSatisfy { abs($0) > 1e-5 })
        XCTAssertFalse(crossfader.isFadingForTesting)

        let expectedLeft: Float = 0.707 + 2 * 0.5
        let expectedRight: Float = 0.707 + 3 * 0.5
        for sample in driver.outputLeft.suffix(512) {
            XCTAssertEqual(sample, expectedLeft, accuracy: 1e-4)
        }
        for sample in driver.outputRight.suffix(512) {
            XCTAssertEqual(sample, expectedRight, accuracy: 1e-4)
        }
    }
}

#if DEBUG
/// Plan 033 ownership proof for spatial states. Each RendererState carries
/// its own DEBUG probe, so probe death runs on the thread that frees the
/// last state owner. A serial audio queue runs every observe/process call,
/// so a probe death on that queue proves an audio-thread release.
final class SpatialDestructionProofTests: XCTestCase {
    private let blockSize = 512
    private let audioKey = DispatchSpecificKey<Void>()
    private var audioQueue: DispatchQueue!
    private var recorder: SpatialRendererCrossfader.DestructionRecorder!

    private func makeState() -> HRIRManager.RendererState {
        SpatialRendererCrossfader.configureDestructionProbeForTesting(audioKey: audioKey, recorder: recorder)
        let convolver = StereoConvolutionEngine(
            leftEarHRIR: [1],
            rightEarHRIR: [1],
            blockSize: blockSize
        )!
        return SpatialRendererCrossfader.makeProbedStateForTesting(
            renderers: [VirtualSpeakerRenderer(speaker: .FL, convolver: convolver)],
            inputChannelCount: 2,
            fallbackSpeakers: [.FL, .FR],
            blockSize: blockSize
        )
    }

    private func runAudio(_ body: @escaping () -> Void) {
        let done = expectation(description: "audio phase")
        audioQueue.async {
            body()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    private func drive(_ crossfader: SpatialRendererCrossfader, callbacks: Int, size: Int = 512) {
        var chunk = [Float](repeating: 0.25, count: size)
        var left = [Float](repeating: 0, count: size)
        var right = [Float](repeating: 0, count: size)
        for _ in 0..<callbacks {
            chunk.withUnsafeBufferPointer { inputPtr in
                left.withUnsafeMutableBufferPointer { leftPtr in
                    right.withUnsafeMutableBufferPointer { rightPtr in
                        let channels: [UnsafePointer<Float>?] = [inputPtr.baseAddress!, inputPtr.baseAddress!]
                        channels.withUnsafeBufferPointer { channelPointers in
                            _ = crossfader.processIfNeeded(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 2,
                                leftOutput: leftPtr.baseAddress!,
                                rightOutput: rightPtr.baseAddress!,
                                frameCount: size
                            )
                        }
                    }
                }
            }
        }
    }

    override func setUp() {
        super.setUp()
        audioQueue = DispatchQueue(label: "test.spatial.audio")
        audioQueue.setSpecific(key: audioKey, value: ())
        recorder = SpatialRendererCrossfader.DestructionRecorder()
        SpatialRendererCrossfader.configureDestructionProbeForTesting(audioKey: audioKey, recorder: recorder)
    }

    override func tearDown() {
        SpatialRendererCrossfader.configureDestructionProbeForTesting(audioKey: nil, recorder: nil)
        audioQueue = nil
        recorder = nil
        super.tearDown()
    }

    func testABCDReplaceKeepsAudioDestructionAtZero() {
        let crossfader = SpatialRendererCrossfader(primeLength: blockSize)
        var stateA: HRIRManager.RendererState? = makeState()
        var stateB: HRIRManager.RendererState? = makeState()
        var stateC: HRIRManager.RendererState? = makeState()
        var stateD: HRIRManager.RendererState? = makeState()
        let idA = ObjectIdentifier(stateA! as AnyObject).hashValue
        let idB = ObjectIdentifier(stateB! as AnyObject).hashValue
        let idC = ObjectIdentifier(stateC! as AnyObject).hashValue
        let idD = ObjectIdentifier(stateD! as AnyObject).hashValue

        runAudio { crossfader.observe(stateA); self.drive(crossfader, callbacks: 6) }
        runAudio { crossfader.observe(stateB); self.drive(crossfader, callbacks: 1) }
        runAudio { crossfader.observe(stateC); self.drive(crossfader, callbacks: 1) }
        // Publish D on control, then observe it on audio. C must stay
        // owned (retired, not destroyed) and no destruction runs on audio.
        let publishedD = stateD
        runAudio { crossfader.observe(publishedD); self.drive(crossfader, callbacks: 1) }

        XCTAssertEqual(recorder.audioThreadDestructionCount, 0)
        // Release test references, then drain until D is active.
        stateA = nil; stateB = nil; stateC = nil
        var keepD = stateD; stateD = nil
        for _ in 0..<40 {
            crossfader.drainRetiredStates()
            runAudio { self.drive(crossfader, callbacks: 1) }
            if !crossfader.isFadingForTesting, crossfader.activeStateForTesting === keepD { break }
        }
        XCTAssertTrue(crossfader.activeStateForTesting === keepD)
        crossfader.drainRetiredStates()
        // D stays active. A, B, C each destroyed exactly once, off audio.
        let ids = recorder.snapshot.map(\.id)
        for id in [idA, idB, idC] {
            XCTAssertEqual(ids.filter { $0 == id }.count, 1, "id \(id)")
        }
        XCTAssertEqual(ids.filter { $0 == idD }.count, 0)
        XCTAssertEqual(recorder.audioThreadDestructionCount, 0)
        keepD = nil
        crossfader.cleanupAfterIOStopped()
    }

    func testNonFadingPendingOverwriteRetiresHeldPendingOffAudio() {
        // Finding 1 regression: retirement full + pending held + not fading,
        // then a new publication. The old pending must retire (stay owned),
        // never drop on audio. Pre-fix this test records one audio-thread
        // destruction of the overwritten pending. The harness jams retire()
        // with forceRetireFailureForTesting so both tiers stay full while
        // audio holds a pending without fading.
        let crossfader = SpatialRendererCrossfader(primeLength: blockSize)
        crossfader.forceRetireFailureForTesting = true
        var states: [HRIRManager.RendererState?] = (0..<4).map { _ in makeState() }
        for state in states { runAudio { crossfader.observe(state); self.drive(crossfader, callbacks: 1) } }
        runAudio { self.drive(crossfader, callbacks: 8) }
        var extra: [HRIRManager.RendererState?] = (0..<6).map { _ in makeState() }
        for state in extra { runAudio { crossfader.observe(state); self.drive(crossfader, callbacks: 1) } }
        runAudio { self.drive(crossfader, callbacks: 12) }
        // New publication while retirement cannot accept and a pending is
        // held outside a fade.
        var fresh: HRIRManager.RendererState? = makeState()
        let freshID = ObjectIdentifier(fresh! as AnyObject).hashValue
        let heldIDs = Set((states + extra).compactMap { $0.map { ObjectIdentifier($0 as AnyObject).hashValue } })
        runAudio { crossfader.observe(fresh); self.drive(crossfader, callbacks: 1) }
        crossfader.forceRetireFailureForTesting = false
        // The overwritten pending must not have died on audio: every recorded
        // destruction so far runs off audio, and the fresh state stays alive.
        XCTAssertEqual(recorder.audioThreadDestructionCount, 0)
        let deadHeld = recorder.snapshot.map(\.id).filter { heldIDs.contains($0) }
        for id in Set(deadHeld) {
            XCTAssertEqual(deadHeld.filter { $0 == id }.count, 1, "held id \(id) destroyed more than once")
        }
        XCTAssertEqual(recorder.snapshot.map(\.id).filter { $0 == freshID }.count, 0)
        states.removeAll()
        extra.removeAll()
        fresh = nil
        crossfader.drainRetiredStates()
        crossfader.cleanupAfterIOStopped()
    }

    func testOverCapacityPublicationDefersWithoutAudioDestruction() {
        let crossfader = SpatialRendererCrossfader(primeLength: blockSize)
        // Publish from control, observe on audio. The test array keeps
        // every state alive, so a state that never reaches audio or a
        // retired slot reports no destruction until the array releases it.
        // Only states the audio side has retired may report destruction.
        var states: [HRIRManager.RendererState?] = (0..<10).map { _ in makeState() }
        let ids = states.map { ObjectIdentifier($0! as AnyObject).hashValue }
        for state in states {
            let published = state
            runAudio { crossfader.observe(published); self.drive(crossfader, callbacks: 1) }
        }
        XCTAssertEqual(recorder.audioThreadDestructionCount, 0)
        XCTAssertLessThanOrEqual(crossfader.retiredStateCountForTesting, 4)
        let newest = states.last!
        let newestID = ids.last!
        states.removeAll()
        var keep: HRIRManager.RendererState? = newest
        for _ in 0..<60 {
            crossfader.drainRetiredStates()
            runAudio { self.drive(crossfader, callbacks: 1) }
            if !crossfader.isFadingForTesting, crossfader.activeStateForTesting === keep { break }
        }
        XCTAssertTrue(crossfader.activeStateForTesting === keep)
        crossfader.drainRetiredStates()
        // Newest stays active. Every retired older state destroyed exactly
        // once, off audio. States dropped while still held by the test
        // array (never retired) report no destruction yet.
        let seen = recorder.snapshot.map(\.id)
        var retiredCount = 0
        for id in ids.dropLast() {
            let count = seen.filter { $0 == id }.count
            XCTAssertLessThanOrEqual(count, 1, "id \(id)")
            retiredCount += count
        }
        XCTAssertGreaterThan(retiredCount, 0)
        XCTAssertEqual(seen.filter { $0 == newestID }.count, 0)
        XCTAssertEqual(recorder.audioThreadDestructionCount, 0)
        keep = nil
        crossfader.cleanupAfterIOStopped()
    }

    func testNonePublicationAndResetUnderSaturationReleaseOffAudio() {
        let crossfader = SpatialRendererCrossfader(primeLength: blockSize)
        var states: [HRIRManager.RendererState?] = (0..<8).map { _ in makeState() }
        for state in states { runAudio { crossfader.observe(state); self.drive(crossfader, callbacks: 1) } }
        runAudio { crossfader.observe(nil); self.drive(crossfader, callbacks: 1) }
        runAudio { crossfader.requestReset(); self.drive(crossfader, callbacks: 2) }
        states.removeAll()
        crossfader.drainRetiredStates()
        runAudio { self.drive(crossfader, callbacks: 2) }
        crossfader.cleanupAfterIOStopped()
        XCTAssertEqual(recorder.audioThreadDestructionCount, 0)
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 0)
    }

    func testFailedFadeRetireHoldRetriesAfterControlDrain() {
        // Finding 3 regression: a failed-retire outgoing in finishFade must
        // reach control after the next successful drain, not leak until stop.
        // The harness jams retire() so a completing fade takes the bounded
        // failedRetirementHold, then unjams: one drain plus callbacks must
        // move the hold to the shared slots.
        let crossfader = SpatialRendererCrossfader(primeLength: blockSize)
        var first: HRIRManager.RendererState? = makeState()
        var second: HRIRManager.RendererState? = makeState()
        runAudio { crossfader.observe(first); self.drive(crossfader, callbacks: 6) }
        runAudio { crossfader.observe(second); self.drive(crossfader, callbacks: 1) }
        crossfader.forceRetireFailureForTesting = true
        runAudio { self.drive(crossfader, callbacks: 4) }
        XCTAssertFalse(crossfader.isFadingForTesting)
        crossfader.forceRetireFailureForTesting = false
        crossfader.drainRetiredStates()
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 0)
        runAudio { self.drive(crossfader, callbacks: 2) }
        XCTAssertGreaterThan(crossfader.retiredStateCountForTesting, 0)
        XCTAssertEqual(recorder.audioThreadDestructionCount, 0)
        first = nil
        second = nil
        crossfader.drainRetiredStates()
        crossfader.cleanupAfterIOStopped()
    }

    func testStopCleanupReleasesStorage() {
        let crossfader = SpatialRendererCrossfader(primeLength: blockSize)
        var state: HRIRManager.RendererState? = makeState()
        runAudio { crossfader.observe(state); self.drive(crossfader, callbacks: 6) }
        state = nil
        crossfader.cleanupAfterIOStopped()
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 0)
        XCTAssertNil(crossfader.activeStateForTesting)
        XCTAssertEqual(recorder.audioThreadDestructionCount, 0)
    }
}
#endif

final class SpatialRendererCrossfaderPerformanceTests: XCTestCase {
    private let blockSize = 512
    private let channelSpeakers = InputLayout.surround71.channels
    private let impulseLength = 4_320

    private func makeRandom(seed: UInt64) -> () -> UInt64 {
        var state = seed
        return {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private func normalizedIR(seed: UInt64) -> [Float] {
        let random = makeRandom(seed: seed)
        var taps = [Float](repeating: 0, count: impulseLength)
        var norm: Float = 0
        for index in taps.indices {
            let sample = Float(random() % 1000) / 1000 - 0.5
            let tap = sample * pow(0.996, Float(index))
            taps[index] = tap
            norm += abs(tap)
        }
        for index in taps.indices {
            taps[index] /= norm
        }
        return taps
    }

    private func makeState(seed: UInt64) -> HRIRManager.RendererState {
        let renderers = channelSpeakers.enumerated().map { index, speaker in
            let convolver = try! XCTUnwrap(StereoConvolutionEngine(
                leftEarHRIR: normalizedIR(seed: seed + UInt64(index)),
                rightEarHRIR: normalizedIR(seed: seed + UInt64(index) + 100),
                blockSize: blockSize
            ))
            return VirtualSpeakerRenderer(speaker: speaker, convolver: convolver)
        }
        return HRIRManager.RendererState(
            renderers: renderers,
            inputChannelCount: channelSpeakers.count,
            fallbackSpeakers: channelSpeakers,
            blockSize: blockSize
        )
    }

    private func makeNChannelState(
        channelCount: Int,
        fallbackSpeakers: [VirtualSpeaker],
        seed: UInt64
    ) -> HRIRManager.RendererState {
        let renderers = (0..<channelCount).map { index -> VirtualSpeakerRenderer in
            let convolver = try! XCTUnwrap(StereoConvolutionEngine(
                leftEarHRIR: normalizedIR(seed: seed + UInt64(index)),
                rightEarHRIR: normalizedIR(seed: seed + UInt64(index) + 10_000),
                blockSize: blockSize
            ))
            return VirtualSpeakerRenderer(speaker: fallbackSpeakers[index], convolver: convolver)
        }
        return HRIRManager.RendererState(
            renderers: renderers,
            inputChannelCount: channelCount,
            fallbackSpeakers: fallbackSpeakers,
            blockSize: blockSize
        )
    }

    func testEightChannelRepresentativeHRIRSwitchRunsFasterThanRealtime() {
        // Plan 025 corrected hard gate: 25 distinct 8-channel states (one
        // warm-up plus 24 requested targets), each with eight independent
        // L1-normalized 4,320-frame ear responses. Construction and warm-up
        // stay outside both timing regions. Callback time (processIfNeeded
        // only) is timed apart from control work (observe plus drain); total
        // driver time is reported. Every timed output sample is checked.
        let targetCount = 24
        var states: [HRIRManager.RendererState] = []
        states.reserveCapacity(targetCount + 1)
        for index in 0...targetCount {
            states.append(makeState(seed: 1_000 + UInt64(index) * 10_000))
        }
        let warmup = states[0]
        let targets = Array(states[1...])
        XCTAssertEqual(targets.count, targetCount)

        let channelCount = channelSpeakers.count
        XCTAssertEqual(channelCount, 8)

        // Preallocated distinct deterministic inputs per speaker.
        let inputBuffers: [UnsafeMutablePointer<Float>] = (0..<channelCount).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        }
        let leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        let rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        defer {
            inputBuffers.forEach { $0.deallocate() }
            leftBuffer.deallocate()
            rightBuffer.deallocate()
        }
        for channel in 0..<channelCount {
            for frame in 0..<blockSize {
                let phase = Double(channel) * 0.7
                let frequency = Double(120 + channel * 53)
                inputBuffers[channel][frame] =
                    0.125 * Float(sin(2.0 * Double.pi * frequency * Double(frame) / 48_000.0 + phase))
            }
        }
        let channelPtrs: [UnsafePointer<Float>?] = inputBuffers.map { UnsafePointer($0) }

        let crossfader = SpatialRendererCrossfader(
            primeLength: blockSize,
            maxFramesPerCallback: 4_096
        )

        // Warm-up outside timing so setup and priming do not enter the gate.
        crossfader.observe(warmup)
        var warmBlocks = 0
        channelPtrs.withUnsafeBufferPointer { pointers in
            while (crossfader.isFadingForTesting || crossfader.activeStateForTesting !== warmup),
                warmBlocks < 20 {
                _ = crossfader.processIfNeeded(
                    inputChannels: pointers.baseAddress!,
                    inputChannelCount: channelCount,
                    leftOutput: leftBuffer,
                    rightOutput: rightBuffer,
                    frameCount: blockSize
                )
                warmBlocks += 1
            }
        }
        XCTAssertFalse(crossfader.isFadingForTesting)
        XCTAssertTrue(crossfader.activeStateForTesting === warmup)
        crossfader.drainRetiredStates()

        // Each distinct target fades over exactly three 512-frame blocks
        // (512 prime plus 1,024 fade), then holds five steady blocks. Timed
        // audio is 24 * 8 * 512 = 98,304 frames (2.048 seconds at 48 kHz).
        let steadyBlocksPerTarget = 5
        let expectedTimedBlocks = targetCount * (3 + steadyBlocksPerTarget)
        let renderedFrames = expectedTimedBlocks * blockSize
        let audioSeconds = Double(renderedFrames) / 48_000
        XCTAssertGreaterThanOrEqual(audioSeconds, 2.0)

        var callbackElapsed: Double = 0
        var completedTargets = 0
        var timedBlocks = 0
        let totalStart = DispatchTime.now().uptimeNanoseconds
        channelPtrs.withUnsafeBufferPointer { pointers in
            let inputBase = pointers.baseAddress!
            for target in targets {
                // Control work: publish the next distinct target. Not timed
                // in the callback region.
                crossfader.observe(target)
                var fadeBlocks = 0
                while true {
                    let callbackStart = DispatchTime.now().uptimeNanoseconds
                    _ = crossfader.processIfNeeded(
                        inputChannels: inputBase,
                        inputChannelCount: channelCount,
                        leftOutput: leftBuffer,
                        rightOutput: rightBuffer,
                        frameCount: blockSize
                    )
                    let callbackEnd = DispatchTime.now().uptimeNanoseconds
                    callbackElapsed += Double(callbackEnd - callbackStart) / 1_000_000_000
                    timedBlocks += 1
                    fadeBlocks += 1
                    // Validation stays outside the callback timing region.
                    for index in 0..<blockSize {
                        XCTAssertTrue(leftBuffer[index].isFinite)
                        XCTAssertTrue(rightBuffer[index].isFinite)
                        XCTAssertLessThanOrEqual(abs(leftBuffer[index]), 2.0)
                        XCTAssertLessThanOrEqual(abs(rightBuffer[index]), 2.0)
                    }
                    if !crossfader.isFadingForTesting { break }
                    XCTAssertLessThan(fadeBlocks, 20, "distinct-target fade did not complete")
                }
                XCTAssertFalse(crossfader.isFadingForTesting)
                XCTAssertTrue(
                    crossfader.activeStateForTesting === target,
                    "fade completed on the wrong target"
                )
                completedTargets += 1
                // Control work: release retired states. Not callback timed.
                crossfader.drainRetiredStates()
                for _ in 0..<steadyBlocksPerTarget {
                    let callbackStart = DispatchTime.now().uptimeNanoseconds
                    _ = crossfader.processIfNeeded(
                        inputChannels: inputBase,
                        inputChannelCount: channelCount,
                        leftOutput: leftBuffer,
                        rightOutput: rightBuffer,
                        frameCount: blockSize
                    )
                    let callbackEnd = DispatchTime.now().uptimeNanoseconds
                    callbackElapsed += Double(callbackEnd - callbackStart) / 1_000_000_000
                    timedBlocks += 1
                    for index in 0..<blockSize {
                        XCTAssertTrue(leftBuffer[index].isFinite)
                        XCTAssertTrue(rightBuffer[index].isFinite)
                        XCTAssertLessThanOrEqual(abs(leftBuffer[index]), 2.0)
                        XCTAssertLessThanOrEqual(abs(rightBuffer[index]), 2.0)
                    }
                }
                XCTAssertFalse(crossfader.isFadingForTesting)
                XCTAssertTrue(crossfader.activeStateForTesting === target)
            }
        }
        let totalEnd = DispatchTime.now().uptimeNanoseconds
        let totalElapsed = Double(totalEnd - totalStart) / 1_000_000_000

        XCTAssertEqual(completedTargets, targetCount)
        XCTAssertEqual(timedBlocks, expectedTimedBlocks)
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 0)
        let callbackRatio = callbackElapsed / audioSeconds
        let totalRatio = totalElapsed / audioSeconds
        print(
            "eight-channel 24-distinct-target switch: callback \(callbackElapsed)s "
                + "(ratio \(callbackRatio)), total \(totalElapsed)s (ratio \(totalRatio)) "
                + "for \(audioSeconds)s of audio, completed \(completedTargets)/\(targetCount)"
        )
        XCTAssertLessThan(
            callbackElapsed,
            audioSeconds,
            "eight-channel 24-distinct-target switch callback elapsed \(callbackElapsed)s "
                + "for \(audioSeconds)s of audio (ratio \(callbackRatio))"
        )
    }

    func testTwoAndSixteenChannelTransitionsCompleteAcrossCallbackSizes() {
        // Plan 025 step 3.1 correctness: 2-input and 16-input transitions
        // across 64/300/512/513/4096-frame callbacks. Each case asserts the
        // requested final state and finite output, and records the maximum
        // callback time. No real-time limit applies here; the hard gate owns
        // the timing limit.
        var maximumCallbackSeconds: Double = 0
        var casesRun = 0
        for inputCount in [2, 16] {
            let fallback = InputLayout.detect(channelCount: inputCount).channels
            XCTAssertEqual(fallback.count, inputCount)
            for callbackSize in [64, 300, 512, 513, 4096] {
                let seedBase = UInt64(200_000 + inputCount * 1_000 + callbackSize)
                let stateA = makeNChannelState(
                    channelCount: inputCount,
                    fallbackSpeakers: fallback,
                    seed: seedBase
                )
                let stateB = makeNChannelState(
                    channelCount: inputCount,
                    fallbackSpeakers: fallback,
                    seed: seedBase + 100_000
                )
                let crossfader = SpatialRendererCrossfader(
                    primeLength: blockSize,
                    maxFramesPerCallback: 4_096
                )
                var storage = [Float](repeating: 0, count: inputCount * callbackSize)
                for channel in 0..<inputCount {
                    for frame in 0..<callbackSize {
                        storage[channel * callbackSize + frame] = 0.125 * Float(
                            sin(2.0 * Double.pi * Double(90 + channel * 41) * Double(frame) / 48_000.0
                                + Double(channel) * 0.3)
                        )
                    }
                }
                var left = [Float](repeating: .nan, count: callbackSize)
                var right = [Float](repeating: .nan, count: callbackSize)

                func driveUntilActive(
                    _ wanted: HRIRManager.RendererState?,
                    label: String
                ) {
                    var callbacks = 0
                    while callbacks < 64 {
                        var callbackSeconds: Double = 0
                        storage.withUnsafeMutableBufferPointer { storageBuffer in
                            let base = UnsafePointer(storageBuffer.baseAddress!)
                            let ptrs: [UnsafePointer<Float>?] = (0..<inputCount).map {
                                base.advanced(by: $0 * callbackSize)
                            }
                            ptrs.withUnsafeBufferPointer { channelPointers in
                                left.withUnsafeMutableBufferPointer { leftPtr in
                                    right.withUnsafeMutableBufferPointer { rightPtr in
                                        let start = DispatchTime.now().uptimeNanoseconds
                                        _ = crossfader.processIfNeeded(
                                            inputChannels: channelPointers.baseAddress!,
                                            inputChannelCount: inputCount,
                                            leftOutput: leftPtr.baseAddress!,
                                            rightOutput: rightPtr.baseAddress!,
                                            frameCount: callbackSize
                                        )
                                        let end = DispatchTime.now().uptimeNanoseconds
                                        callbackSeconds = Double(end - start) / 1_000_000_000
                                    }
                                }
                            }
                        }
                        maximumCallbackSeconds = max(maximumCallbackSeconds, callbackSeconds)
                        callbacks += 1
                        for sample in left {
                            XCTAssertTrue(sample.isFinite, "\(label) left non-finite")
                        }
                        for sample in right {
                            XCTAssertTrue(sample.isFinite, "\(label) right non-finite")
                        }
                        if !crossfader.isFadingForTesting,
                            crossfader.activeStateForTesting === wanted {
                            break
                        }
                    }
                    XCTAssertFalse(
                        crossfader.isFadingForTesting,
                        "\(label) fade did not complete (\(inputCount)ch \(callbackSize)fr)"
                    )
                    XCTAssertTrue(
                        crossfader.activeStateForTesting === wanted,
                        "\(label) wrong final state (\(inputCount)ch \(callbackSize)fr)"
                    )
                }

                crossfader.observe(stateA)
                driveUntilActive(stateA, label: "initial")
                crossfader.drainRetiredStates()
                crossfader.observe(stateB)
                driveUntilActive(stateB, label: "switched")
                crossfader.drainRetiredStates()
                XCTAssertEqual(crossfader.retiredStateCountForTesting, 0)
                casesRun += 1
            }
        }
        print(
            "transition correctness: \(casesRun) cases (2/16 inputs x 5 callback sizes), "
                + "maximum callback \(maximumCallbackSeconds)s"
        )
        XCTAssertEqual(casesRun, 10)
    }
}

/// Regression soak for the full-scale-output incident reported on external
/// headphones: convolution audio died mid-stream and switching HRIR -> None
/// produced an extremely loud blast. These tests drive the real render chain
/// (crossfader -> RealtimeAudioProcessor -> StereoConvolutionEngine) the way
/// Core Audio drives it — arbitrary callback sizes, mono or stereo input,
/// rapid preset swaps, mid-stream deactivation and reset — and assert every
/// emitted sample stays finite and within a tight bound. A blast cannot pass.
final class RenderSafetySoakTests: XCTestCase {
    private let blockSize = 512
    private let sampleRate = 48_000.0
    /// Input sine peaks at 0.5; every state is L1-normalized (gain <= 1) and
    /// equal-power fades stay under sqrt(2), so 2.0 leaves a wide margin while
    /// still catching any garbage-scale output.
    private let outputBound: Float = 2.0

    private func makeRandom(seed: UInt64) -> () -> UInt64 {
        var state = seed
        return {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// Decaying-noise impulse response normalized to unit L1 gain, so the
    /// convolution can never exceed the input amplitude.
    private func normalizedIR(tapCount: Int, gain: Float, seed: UInt64) -> [Float] {
        let random = makeRandom(seed: seed)
        var taps = (0..<tapCount * blockSize).map { index -> Float in
            let amplitude = Float(random() % 1000) / 1000 - 0.5
            return amplitude * pow(0.996, Float(index))
        }
        let energy = taps.reduce(0) { $0 + abs($1) }
        taps = taps.map { $0 / energy * gain }
        return taps
    }

    private func makeState(tapCount: Int, gain: Float, seed: UInt64) -> HRIRManager.RendererState {
        let renderers = (0..<2).map { channel -> VirtualSpeakerRenderer in
            let engine = StereoConvolutionEngine(
                leftEarHRIR: normalizedIR(tapCount: tapCount, gain: gain, seed: seed + UInt64(channel)),
                rightEarHRIR: normalizedIR(tapCount: tapCount, gain: gain, seed: seed + UInt64(channel) + 100),
                blockSize: blockSize
            )!
            return VirtualSpeakerRenderer(speaker: channel == 0 ? .FL : .FR, convolver: engine)
        }
        return HRIRManager.RendererState(
            renderers: renderers,
            inputChannelCount: 2,
            fallbackSpeakers: [.FL, .FR],
            blockSize: blockSize
        )
    }

    /// Drives the crossfader with randomized callback sizes and mono/stereo
    /// input, asserting finite bounded output after every callback.
    private final class SoakDriver {
        let crossfader: SpatialRendererCrossfader
        private(set) var peak: Float = 0
        private(set) var frames = 0
        private var frame = 0

        init(_ crossfader: SpatialRendererCrossfader) {
            self.crossfader = crossfader
        }

        /// Returns the emitted segment so callers can assert passthrough tails.
        func run(size: Int, mono: Bool, file: StaticString = #filePath, line: UInt = #line) -> ([Float], [Float]) {
            var chunk = [Float](repeating: 0, count: size)
            for index in 0..<size {
                chunk[index] = 0.5 * Float(sin(2 * Double.pi * 480 * Double(frame + index) / 48_000))
            }
            frame += size
            frames += size
            var left = [Float](repeating: .nan, count: size)
            var right = [Float](repeating: .nan, count: size)
            chunk.withUnsafeBufferPointer { inputPtr in
                left.withUnsafeMutableBufferPointer { leftPtr in
                    right.withUnsafeMutableBufferPointer { rightPtr in
                        let channels: [UnsafePointer<Float>?] = [
                            inputPtr.baseAddress!, mono ? nil : inputPtr.baseAddress!
                        ]
                        channels.withUnsafeBufferPointer { channelPointers in
                            let wrote = crossfader.processIfNeeded(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 2,
                                leftOutput: leftPtr.baseAddress!,
                                rightOutput: rightPtr.baseAddress!,
                                frameCount: size
                            )
                            if !wrote {
                                memcpy(leftPtr.baseAddress!, inputPtr.baseAddress!, size * MemoryLayout<Float>.size)
                                memcpy(
                                    rightPtr.baseAddress!,
                                    mono ? inputPtr.baseAddress! : inputPtr.baseAddress!,
                                    size * MemoryLayout<Float>.size
                                )
                            }
                        }
                    }
                }
            }
            for channel in [left, right] {
                for sample in channel {
                    XCTAssertTrue(sample.isFinite, "non-finite output at frame \(frames)", file: file, line: line)
                    XCTAssertLessThanOrEqual(abs(sample), 2.0, "output exceeded blast bound at frame \(frames)", file: file, line: line)
                    peak = max(peak, abs(sample))
                }
            }
            return (left, right)
        }
    }

    private func makeSoakCrossfader() -> SpatialRendererCrossfader {
        SpatialRendererCrossfader(primeLength: blockSize, maxFramesPerCallback: 4_096)
    }

    func testSteadyStateRandomizedCallbacksStayFiniteAndBounded() {
        let crossfader = makeSoakCrossfader()
        let driver = SoakDriver(crossfader)
        let random = makeRandom(seed: 0xA11CE)
        crossfader.observe(makeState(tapCount: 7, gain: 1, seed: 42))

        for callback in 0..<600 {
            let size = 1 + Int(random() % 4_096)
            _ = driver.run(size: size, mono: callback % 3 == 0)
            if callback % 50 == 49 {
                crossfader.drainRetiredStates()
            }
        }

        XCTAssertGreaterThan(driver.frames, 1_000_000)
        XCTAssertLessThanOrEqual(driver.peak, 0.75)
    }

    func testSwitchStormIncludingRemovalToPassthroughStaysFiniteAndBounded() {
        let crossfader = makeSoakCrossfader()
        let driver = SoakDriver(crossfader)
        let random = makeRandom(seed: 0xBEEF)
        let stateA = makeState(tapCount: 7, gain: 1, seed: 42)
        let stateB = makeState(tapCount: 1, gain: 0.8, seed: 7)
        let stateC = makeState(tapCount: 3, gain: 0.9, seed: 99)

        // Mirrors the reported incident: HRIR playing, then rapid switches,
        // then HRIR -> None on the live pipeline.
        crossfader.observe(stateA)
        for _ in 0..<20 { _ = driver.run(size: 1 + Int(random() % 4_096), mono: false) }

        crossfader.observe(stateB)
        for _ in 0..<3 { _ = driver.run(size: 1 + Int(random() % 4_096), mono: true) }
        crossfader.observe(stateC)
        for _ in 0..<2 { _ = driver.run(size: 1 + Int(random() % 4_096), mono: false) }

        // Deactivate while a fade is still in flight (None during priming/fade).
        crossfader.observe(nil)
        for _ in 0..<3 { _ = driver.run(size: 1 + Int(random() % 4_096), mono: false) }
        crossfader.requestReset()
        _ = driver.run(size: 1 + Int(random() % 4_096), mono: false)

        // Back to convolution, then out again — the exact HRIR -> None action.
        crossfader.observe(stateB)
        for _ in 0..<10 { _ = driver.run(size: 1 + Int(random() % 4_096), mono: false) }
        crossfader.observe(nil)
        crossfader.drainRetiredStates()

        var tail: [Float] = []
        var chunkIndex = 0
        while crossfader.isFadingForTesting, chunkIndex < 64 {
            let (left, _) = driver.run(size: 1 + Int(random() % 4_096), mono: false)
            tail.append(contentsOf: left)
            chunkIndex += 1
        }
        XCTAssertFalse(crossfader.isFadingForTesting, "removal fade never completed")
        XCTAssertLessThanOrEqual(driver.peak, 0.75)
    }

    func testAdapterResetStormStaysFiniteAndBounded() {
        let renderers = (0..<2).map { channel -> VirtualSpeakerRenderer in
            let engine = StereoConvolutionEngine(
                leftEarHRIR: normalizedIR(tapCount: 5, gain: 1, seed: 3 + UInt64(channel)),
                rightEarHRIR: normalizedIR(tapCount: 5, gain: 1, seed: 13 + UInt64(channel)),
                blockSize: blockSize
            )!
            return VirtualSpeakerRenderer(speaker: channel == 0 ? .FL : .FR, convolver: engine)
        }
        let processor = RealtimeAudioProcessor(
            renderers: renderers,
            inputChannelCount: 2,
            fallbackSpeakers: [.FL, .FR],
            blockSize: blockSize,
            maxFramesPerCallback: 4_096
        )
        let random = makeRandom(seed: 0xC0FFEE)
        var frame = 0
        var peak: Float = 0

        for block in 0..<400 {
            let size = 1 + Int(random() % 4_096)
            var chunk = [Float](repeating: 0, count: size)
            for index in 0..<size {
                chunk[index] = 0.5 * Float(sin(2 * Double.pi * 300 * Double(frame + index) / 48_000))
            }
            frame += size
            var left = [Float](repeating: .nan, count: size)
            var right = [Float](repeating: .nan, count: size)
            chunk.withUnsafeBufferPointer { inputPtr in
                left.withUnsafeMutableBufferPointer { leftPtr in
                    right.withUnsafeMutableBufferPointer { rightPtr in
                        let channels: [UnsafePointer<Float>?] = [
                            inputPtr.baseAddress!, block % 5 == 0 ? nil : inputPtr.baseAddress!
                        ]
                        channels.withUnsafeBufferPointer { channelPointers in
                            processor.process(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 2,
                                inputOffset: 0,
                                leftOutput: leftPtr.baseAddress!,
                                rightOutput: rightPtr.baseAddress!,
                                frameCount: size
                            )
                        }
                    }
                }
            }
            for channel in [left, right] {
                for sample in channel {
                    XCTAssertTrue(sample.isFinite, "non-finite output in block \(block)")
                    XCTAssertLessThanOrEqual(abs(sample), 2.0, "output exceeded blast bound in block \(block)")
                    peak = max(peak, abs(sample))
                }
            }
            if block % 37 == 36 {
                processor.reset()
            }
        }

        XCTAssertLessThanOrEqual(peak, 0.75)
    }
}

// MARK: - Plan 014 FIFO-priming characterization

/// Plan 014 regression proof for the one-time FIFO cushion in
/// `RealtimeAudioProcessor.drain`.
///
/// Method: two gain-1 single-tap renderers consume both captured channels,
/// channel 1 carries silence, so each emitted ear sample must equal the next
/// expected ramp value on channel 0 when present; zero then means inserted
/// silence. A fixed frame counter (not sample magnitude) identifies samples,
/// so a zero-valued input frame can never pass as silence.
///
/// Corrected premise (not permanent gaps): without the cushion the adapter
/// self-primes with total silence `blockSize - gcd(C, blockSize)` spread over
/// the stream (worst: 511 one-frame gaps over ~5.5 s at C=513). The cushion
/// finishes that same total in one stretch on the first mid-stream underflow.
/// Latency after priming is exactly `blockSize` for affected sizes and is
/// unchanged (below `blockSize`) for sizes that never underflow mid-stream.
final class FIFOCushionCharacterizationTests: XCTestCase {
    private let blockSize = 512
    private let maxFrames = 4096

    private func makeRampProcessor() -> RealtimeAudioProcessor {
        let engines = (0..<2).map { _ -> StereoConvolutionEngine in
            try! XCTUnwrap(StereoConvolutionEngine(
                leftEarHRIR: [1],
                rightEarHRIR: [1],
                blockSize: blockSize
            ))
        }
        return RealtimeAudioProcessor(
            renderers: [
                VirtualSpeakerRenderer(speaker: .FL, convolver: engines[0]),
                VirtualSpeakerRenderer(speaker: .FR, convolver: engines[1]),
            ],
            inputChannelCount: 2,
            fallbackSpeakers: [.FL, .FR],
            blockSize: blockSize,
            maxFramesPerCallback: maxFrames
        )
    }

    /// Feeds `callbackCount` callbacks of `size` frames. Channel 0 carries a
    /// 1-based integer ramp (exact in Float32 below 2^24 fed frames; zero is
    /// reserved for inserted silence). Channel 1 carries silence. Returns the
    /// concatenated left-ear stream plus the count of fed input frames.
    private func driveRamp(
        _ processor: RealtimeAudioProcessor,
        size: Int,
        callbackCount: Int,
        startFrame: Int = 0
    ) -> (output: [Float], fedFrames: Int) {
        var output: [Float] = []
        output.reserveCapacity(size * callbackCount)
        var frame = startFrame
        for _ in 0..<callbackCount {
            let ramp = (0..<size).map { _ -> Float in frame += 1; return Float(frame) }
            let silence = [Float](repeating: 0, count: size)
            var left = [Float](repeating: .nan, count: size)
            var right = [Float](repeating: .nan, count: size)
            ramp.withUnsafeBufferPointer { rampPtr in
                silence.withUnsafeBufferPointer { silencePtr in
                    left.withUnsafeMutableBufferPointer { leftPtr in
                        right.withUnsafeMutableBufferPointer { rightPtr in
                            processor.process(
                                inputChannels: [UnsafePointer<Float>?(rampPtr.baseAddress!), silencePtr.baseAddress!],
                                inputChannelCount: 2,
                                inputOffset: 0,
                                leftOutput: leftPtr.baseAddress!,
                                rightOutput: rightPtr.baseAddress!,
                                frameCount: size
                            )
                        }
                    }
                }
            }
            output.append(contentsOf: left)
            XCTAssertEqual(left, right, "ears must match with silent channel 1 (size \(size))")
        }
        return (output, frame - startFrame)
    }

    private func zeroRuns(in output: [Float]) -> [(start: Int, end: Int, length: Int)] {
        var runs: [(Int, Int, Int)] = []
        var index = 0
        while index < output.count {
            if output[index] == 0 {
                var end = index
                while end + 1 < output.count, output[end + 1] == 0 { end += 1 }
                runs.append((index, end, end - index + 1))
                index = end + 1
            } else {
                index += 1
            }
        }
        return runs
    }

    /// Delay of output position `at` = at - fedFrameIndex(value). The integer
    /// ramp value is the 1-based fed frame number; the FFT round-trip adds
    /// sub-0.5 error, so round before decoding.
    private func delay(at position: Int, value: Float) -> Int {
        position - (Int(value.rounded()) - 1)
    }

    private func checkSettledDelay(_ output: [Float], expectedDelay: Int, label: String) {
        // Gap scan covers the whole stream (no later silence); the delay
        // window sits right after the last zero run, where ramp values are
        // small and the FFT round-trip error cannot cross the 0.5 decode
        // boundary. Checking delay at the far tail would measure Float32/FFT
        // precision, not adapter latency.
        let runs = zeroRuns(in: output)
        let windowStart = runs.last.map { $0.end + 1 } ?? 0
        let windowEnd = min(output.count, windowStart + 20_000)
        XCTAssertGreaterThan(windowEnd - windowStart, 0, "\(label): empty delay window")
        for position in windowStart..<windowEnd {
            let value = output[position]
            XCTAssertNotEqual(value, 0, "\(label): interior silence at \(position)")
            XCTAssertEqual(
                value, Float(Int(value.rounded())), accuracy: Float(0.5),
                "\(label): sample no longer identifies its input frame at \(position)"
            )
            XCTAssertEqual(delay(at: position, value: value), expectedDelay, "\(label): delay at \(position)")
        }
    }

    func testUnaffectedSizesKeepSubBlockLatencyWithoutInteriorGaps() {
        // 64/128/256/512/4096 never underflow mid-stream, so the cushion must
        // never arm: their warm-up silence stays below one block and the tail
        // delay stays at that same sub-block value.
        let expectations: [(size: Int, zeros: Int, delay: Int)] = [
            (64, 448, 448),
            (128, 384, 384),
            (256, 256, 256),
            (512, 0, 0),
            (4096, 0, 0),
        ]
        for (size, zeros, expectedDelay) in expectations {
            let processor = makeRampProcessor()
            let callbacks = max(300, 131_072 / size)
            let (output, _) = driveRamp(processor, size: size, callbackCount: callbacks)
            let runs = zeroRuns(in: output)
            XCTAssertEqual(
                runs.count, zeros == 0 ? 0 : 1,
                "size \(size): expected one warm-up run, got \(runs.count)"
            )
            if zeros > 0 {
                XCTAssertEqual(runs[0].start, 0, "size \(size): silence must lead")
                XCTAssertEqual(runs[0].length, zeros, "size \(size): warm-up length")
            }
            checkSettledDelay(output, expectedDelay: expectedDelay, label: "size \(size)")
        }
    }

    func testFixed513SettlesAfterOneBlockWithNoLaterGaps() {
        // Worst scattered stutter without the fix: 511 one-frame gaps spread
        // over ~282k frames (~5.5 s at 48 kHz). With the cushion the whole
        // 512-frame total lands in one stretch and the tail delay is 512.
        let processor = makeRampProcessor()
        // 700 callbacks x 513 = 359,100 frames, past the old warm-up period.
        let (output, _) = driveRamp(processor, size: 513, callbackCount: 700)
        let runs = zeroRuns(in: output)
        XCTAssertEqual(runs.count, 1, "expected a single primed run, got \(runs.count)")
        XCTAssertEqual(runs[0].start, 512, "primed run must start after the first block")
        XCTAssertEqual(runs[0].length, 512, "primed run must total exactly one block")
        checkSettledDelay(output, expectedDelay: 512, label: "fixed 513")
    }

    func testFixed300SettlesAfterOneBlockWithNoLaterGaps() {
        let processor = makeRampProcessor()
        // 3,000 callbacks x 300 = 900,000 frames, past the old warm-up spread.
        let (output, _) = driveRamp(processor, size: 300, callbackCount: 3_000)
        let runs = zeroRuns(in: output)
        XCTAssertEqual(runs.count, 2, "expected warm-up plus one cushion, got \(runs.count)")
        XCTAssertEqual(runs[0].start, 0, "first run must lead")
        XCTAssertEqual(runs[0].length, 300, "initial 300-frame silence")
        XCTAssertEqual(runs[1].start, 812, "cushion must start after first mid-stream underflow")
        XCTAssertEqual(runs[1].length, 212, "cushion finishes the 512 total (300 + 212)")
        XCTAssertEqual(
            runs.reduce(0) { $0 + $1.length }, 512,
            "total inserted silence must equal one block"
        )
        checkSettledDelay(output, expectedDelay: 512, label: "fixed 300")
    }

    func testVariableSequencePreservesOrderAndArmsAtMostOnce() {
        // The plan's variable pattern, run long enough to wrap the ring many
        // times and to pass the old 513 warm-up span. The integer ramp stays
        // exact in Float32 (fed frames < 2^24), so zero still means silence.
        let pattern = [300, 512, 200, 700, 128]
        let processor = makeRampProcessor()
        var output: [Float] = []
        var frame = 0
        for _ in 0..<200 {
            for size in pattern {
                let ramp = (0..<size).map { _ -> Float in frame += 1; return Float(frame) }
                let silence = [Float](repeating: 0, count: size)
                var left = [Float](repeating: .nan, count: size)
                var right = [Float](repeating: .nan, count: size)
                ramp.withUnsafeBufferPointer { rampPtr in
                    silence.withUnsafeBufferPointer { silencePtr in
                        left.withUnsafeMutableBufferPointer { leftPtr in
                            right.withUnsafeMutableBufferPointer { rightPtr in
                                processor.process(
                                    inputChannels: [UnsafePointer<Float>?(rampPtr.baseAddress!), silencePtr.baseAddress!],
                                    inputChannelCount: 2,
                                    inputOffset: 0,
                                    leftOutput: leftPtr.baseAddress!,
                                    rightOutput: rightPtr.baseAddress!,
                                    frameCount: size
                                )
                            }
                        }
                    }
                }
                XCTAssertEqual(left, right, "ears must match on variable callbacks")
                output.append(contentsOf: left)
            }
        }

        let runs = zeroRuns(in: output)
        XCTAssertEqual(runs.count, 2, "expected warm-up plus one cushion, got \(runs.count)")
        XCTAssertEqual(runs[0].start, 0)
        XCTAssertEqual(runs[0].length, 300)
        XCTAssertEqual(runs[1].start, 812)
        XCTAssertEqual(runs[1].length, 212)

        // Order: delivered values strictly increase, each exactly once, and
        // none runs ahead of the fed input.
        let delivered = output.filter { $0 != 0 }
        let rounded = delivered.map { $0.rounded() }
        XCTAssertEqual(rounded, rounded.sorted())
        XCTAssertEqual(Set(rounded).count, rounded.count)
        XCTAssertTrue(delivered.allSatisfy { $0 <= Float(frame) + 0.5 })
        checkSettledDelay(output, expectedDelay: 512, label: "variable pattern")
    }

    func testUnaffectedReferenceOutputIsUnchanged() {
        // Reference sequences for sizes that must not gain latency: the exact
        // output stream recorded from the cushion algorithm. Any extra priming
        // on these sizes changes the leading-zero count and fails here.
        let expectations: [(size: Int, callbacks: Int, leadingZeros: Int, firstValue: Float?)] = [
            (64, 300, 448, 1),
            (128, 300, 384, 1),
            (256, 300, 256, 1),
            (512, 4, 0, 1),
            (4096, 6, 0, 1),
        ]
        for (size, callbacks, leadingZeros, firstValue) in expectations {
            let processor = makeRampProcessor()
            let (output, _) = driveRamp(processor, size: size, callbackCount: callbacks)
            var leading = 0
            while leading < output.count, output[leading] == 0 { leading += 1 }
            XCTAssertEqual(leading, leadingZeros, "size \(size): reference lead changed")
            if let firstValue {
                XCTAssertEqual(output[leading], firstValue, accuracy: Float(0.5), "size \(size): first value")
                XCTAssertEqual(output[leading + 1], 2, accuracy: Float(0.5), "size \(size): second value")
            } else {
                XCTAssertEqual(output.count, leading, "size \(size): expected all silence")
            }
        }
    }

    func testResetClearsPrimingState() {
        // Reset during partial input, queued output, and remaining cushion:
        // after each reset 512-frame callbacks must show no old samples and
        // no extra delay.
        let expectedFirst: Float = 1

        // 1. Partial input: half a block fed, then reset.
        do {
            let processor = makeRampProcessor()
            _ = driveRamp(processor, size: 256, callbackCount: 1)
            processor.reset()
            let (output, _) = driveRamp(processor, size: 512, callbackCount: 2)
            XCTAssertEqual(output[0], expectedFirst, accuracy: Float(0.5))
            XCTAssertEqual(output[512], 513, accuracy: Float(0.5))
        }

        // 2. Queued output: prime the FIFO, then reset before draining.
        do {
            let processor = makeRampProcessor()
            _ = driveRamp(processor, size: 4096, callbackCount: 2)
            processor.reset()
            let (output, _) = driveRamp(processor, size: 512, callbackCount: 2)
            XCTAssertEqual(output[0], expectedFirst, accuracy: Float(0.5))
        }

        // 3. Remaining cushion: arm the cushion, reset mid-cushion.
        do {
            let processor = makeRampProcessor()
            _ = driveRamp(processor, size: 513, callbackCount: 1)
            processor.reset()
            let (output, _) = driveRamp(processor, size: 512, callbackCount: 2)
            XCTAssertEqual(output[0], expectedFirst, accuracy: Float(0.5))
            // No retained extra delay: second block follows immediately.
            XCTAssertEqual(output[512], 513, accuracy: Float(0.5))
        }
    }

    func testCapacityBoundHoldsAtMaximumCallback() {
        // 4096-frame callbacks wrap the 4608-frame ring on every other call;
        // with unit-gain renderers the stream passes through block-aligned.
        let processor = makeRampProcessor()
        let (output, fed) = driveRamp(processor, size: 4096, callbackCount: 6)
        XCTAssertEqual(output.count, fed)
        var frame = 0
        for position in 0..<output.count {
            frame += 1
            XCTAssertEqual(output[position], Float(frame), accuracy: Float(0.5), "at \(position)")
        }
    }

    func testZeroFrameCallLeavesStreamUnchanged() {
        let processor = makeRampProcessor()
        _ = driveRamp(processor, size: 512, callbackCount: 2)
        var probe = [Float](repeating: .nan, count: 1)
        var probeRight = [Float](repeating: .nan, count: 1)
        let silent = [Float](repeating: 0, count: 1)
        silent.withUnsafeBufferPointer { silentPtr in
            probe.withUnsafeMutableBufferPointer { leftPtr in
                probeRight.withUnsafeMutableBufferPointer { rightPtr in
                    let channels: [UnsafePointer<Float>?] = [silentPtr.baseAddress!, silentPtr.baseAddress!]
                    channels.withUnsafeBufferPointer { channelPointers in
                        processor.process(
                            inputChannels: channelPointers.baseAddress!,
                            inputChannelCount: 2,
                            inputOffset: 0,
                            leftOutput: leftPtr.baseAddress!,
                            rightOutput: rightPtr.baseAddress!,
                            frameCount: 0
                        )
                    }
                }
            }
        }
        XCTAssertTrue(probe[0].isNaN, "zero-frame call must not touch the output buffer")
        let (output, _) = driveRamp(processor, size: 512, callbackCount: 1, startFrame: 1024)
        XCTAssertEqual(output[0], 1025, accuracy: Float(0.5))
    }
}
