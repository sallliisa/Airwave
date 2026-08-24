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
                                crossfader.process(
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
                input.append(contentsOf: chunk)
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

    func testRemovingPresetFadesToPassthrough() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        crossfader.observe(makeState(gain: 0.5))
        driver.run(callbacks: 6)

        crossfader.observe(nil)
        XCTAssertTrue(crossfader.isRenderingSpatialAudio)
        driver.run(callbacks: 4)

        XCTAssertFalse(crossfader.isRenderingSpatialAudio)
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
                            crossfader.process(
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
        while crossfader.isRenderingSpatialAudio, chunkIndex < 64 {
            let (left, _) = driver.run(size: 1 + Int(random() % 4_096), mono: false)
            tail.append(contentsOf: left)
            chunkIndex += 1
        }
        XCTAssertFalse(crossfader.isRenderingSpatialAudio, "removal fade never completed")
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
