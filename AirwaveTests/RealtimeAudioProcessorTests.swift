import XCTest
@testable import Airwave

final class RealtimeAudioProcessorTests: XCTestCase {
    private let blockSize = 512
    private let maxFrames = 4096

    private func makeProcessor(rendererCount: Int = 2) -> RealtimeAudioProcessor {
        let renderers = (0..<rendererCount).map { index in
            let left = try! XCTUnwrap(ConvolutionEngine(
                hrirSamples: [Float(index + 1)],
                blockSize: blockSize
            ))
            let right = try! XCTUnwrap(ConvolutionEngine(
                hrirSamples: [Float(index + 1)],
                blockSize: blockSize
            ))
            return VirtualSpeakerRenderer(
                speaker: index == 0 ? .FL : .FR,
                convolverLeftEar: left,
                convolverRightEar: right
            )
        }
        return RealtimeAudioProcessor(
            renderers: renderers,
            blockSize: blockSize,
            maxFramesPerCallback: maxFrames
        )
    }

    private func process(
        _ processor: RealtimeAudioProcessor,
        size: Int,
        leftValue: Float = 1,
        rightValue: Float = 2
    ) -> ([Float], [Float]) {
        let left = [Float](repeating: leftValue, count: size)
        let right = [Float](repeating: rightValue, count: size)
        var outputLeft = [Float](repeating: .nan, count: size)
        var outputRight = [Float](repeating: .nan, count: size)
        left.withUnsafeBufferPointer { leftPtr in
            right.withUnsafeBufferPointer { rightPtr in
                outputLeft.withUnsafeMutableBufferPointer { leftOutPtr in
                    outputRight.withUnsafeMutableBufferPointer { rightOutPtr in
                        processor.process(
                            inputLeft: leftPtr.baseAddress!,
                            inputRight: rightPtr.baseAddress!,
                            leftOutput: leftOutPtr.baseAddress!,
                            rightOutput: rightOutPtr.baseAddress!,
                            frameCount: size
                        )
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
        let processor = makeProcessor(rendererCount: 1)
        let (underflowLeft, underflowRight) = process(processor, size: 3, leftValue: 0.5, rightValue: 0.5)
        XCTAssertEqual(underflowLeft, [0, 0, 0])
        XCTAssertEqual(underflowRight, underflowLeft)
        let (left, right) = process(processor, size: 512, leftValue: 0.5, rightValue: 0.5)
        XCTAssertEqual(left, right)
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

        processor.process(
            inputLeft: UnsafePointer(inputStorage.advanced(by: 1)),
            inputRight: nil,
            leftOutput: outputStorage.advanced(by: 1),
            rightOutput: outputStorage.advanced(by: 1),
            frameCount: size
        )

        XCTAssertEqual(inputStorage[0], 0)
        XCTAssertEqual(inputStorage[size + 1], 0)
        XCTAssertEqual(outputStorage[0], canary)
        XCTAssertEqual(outputStorage[size + 1], canary)
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
                                processor.process(
                                    inputLeft: inputPtr.baseAddress!,
                                    inputRight: inputPtr.baseAddress!,
                                    leftOutput: leftPtr.baseAddress!,
                                    rightOutput: rightPtr.baseAddress!,
                                    frameCount: size
                                )
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
