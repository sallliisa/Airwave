import XCTest
@testable import Airwave

final class AudioEffectGraphTests: XCTestCase {
    func testNeitherEffectCopiesStereoAndDuplicatesMono() throws {
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: false),
            equalizer: EqualizerEffectSpy(),
            maxFramesPerCallback: 8
        )
        let output = deviceOutput(sampleRate: 48_000)
        let preparation = graph.prepare(for: output, equalizerDefinition: nil)

        XCTAssertTrue(preparation.noEffectCanRun)
        let stereo = process(graph, left: [1, 2], right: [3, 4])
        XCTAssertEqual(stereo.left, [1, 2])
        XCTAssertEqual(stereo.right, [3, 4])

        let mono = process(graph, left: [5, 6], right: nil)
        XCTAssertEqual(mono.left, [5, 6])
        XCTAssertEqual(mono.right, [5, 6])
    }

    func testSpatialOnlyUsesSpatialEffect() throws {
        let spatial = SpatialEffectSpy(isReady: true, offset: 10)
        let equalizer = EqualizerEffectSpy()
        let graph = AudioEffectGraph(spatial: spatial, equalizer: equalizer, maxFramesPerCallback: 8)
        _ = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)

        let result = process(graph, left: [1], right: [2])

        XCTAssertEqual(result.left, [11])
        XCTAssertEqual(result.right, [12])
        XCTAssertEqual(spatial.processCount, 1)
        XCTAssertEqual(equalizer.processCount, 0)
    }

    func testEqualizerOnlyRunsAfterInputPassthrough() throws {
        let spatial = SpatialEffectSpy(isReady: false)
        let equalizer = EqualizerEffectSpy(multiplier: 2)
        let graph = AudioEffectGraph(spatial: spatial, equalizer: equalizer, maxFramesPerCallback: 8)
        let definition = EqualizerDefinition(preampDB: 3)
        let preparation = graph.prepare(for: deviceOutput(sampleRate: 44_100), equalizerDefinition: definition)

        XCTAssertEqual(preparation.runnableEffects, [.equalizer])
        XCTAssertEqual(equalizer.preparedSampleRates, [44_100])
        let result = process(graph, left: [1], right: nil)

        XCTAssertEqual(result.left, [2])
        XCTAssertEqual(result.right, [2])
        XCTAssertEqual(equalizer.processCount, 1)
    }

    func testBothEffectsRunInSpatialThenEqualizerOrder() throws {
        let spatial = SpatialEffectSpy(isReady: true, offset: 10)
        let equalizer = EqualizerEffectSpy(multiplier: 2)
        let graph = AudioEffectGraph(spatial: spatial, equalizer: equalizer, maxFramesPerCallback: 8)
        let preparation = graph.prepare(
            for: deviceOutput(sampleRate: 96_000),
            equalizerDefinition: EqualizerDefinition(preampDB: 3)
        )

        XCTAssertEqual(preparation.runnableEffects, [.spatial, .equalizer])
        let result = process(graph, left: [1], right: [2])

        XCTAssertEqual(result.left, [22])
        XCTAssertEqual(result.right, [24])
        XCTAssertEqual(spatial.processCount, 1)
        XCTAssertEqual(equalizer.processCount, 1)
    }

    func testPreparationReturnsNonfatalLineSpecificEqualizerWarning() throws {
        let spatial = SpatialEffectSpy(isReady: true)
        let equalizer = EqualizerEffectSpy()
        equalizer.error = .invalidFilter(line: 17, reason: "frequency is above Nyquist")
        let graph = AudioEffectGraph(spatial: spatial, equalizer: equalizer, maxFramesPerCallback: 8)

        let preparation = graph.prepare(
            for: deviceOutput(sampleRate: 44_100),
            equalizerDefinition: EqualizerDefinition(filters: [testFilter(line: 17)])
        )

        XCTAssertEqual(preparation.runnableEffects, [.spatial])
        XCTAssertFalse(preparation.noEffectCanRun)
        XCTAssertEqual(preparation.equalizerWarning?.filterLine, 17)
        XCTAssertTrue(preparation.equalizerWarning?.reason.contains("Nyquist") == true)
    }

    func testProductionEqualizerPreparationUsesOutputRateAndRejectsNyquist() throws {
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: false),
            equalizer: EqualizerRuntimeEffect(),
            maxFramesPerCallback: 8
        )
        let invalid = EqualizerDefinition(filters: [testFilter(line: 31, frequency: 23_000)])

        let invalidResult = graph.prepare(
            for: deviceOutput(sampleRate: 44_100),
            equalizerDefinition: invalid
        )

        XCTAssertTrue(invalidResult.noEffectCanRun)
        XCTAssertEqual(invalidResult.equalizerWarning?.filterLine, 31)

        let validResult = graph.prepare(
            for: deviceOutput(sampleRate: 96_000),
            equalizerDefinition: EqualizerDefinition(preampDB: 3, filters: [testFilter(line: 31, frequency: 23_000)])
        )
        XCTAssertEqual(validResult.runnableEffects, [.equalizer])
        XCTAssertNil(validResult.equalizerWarning)
    }

    func testProductionEqualizerCanReenableAfterNoneSelection() throws {
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: false),
            equalizer: EqualizerRuntimeEffect(),
            maxFramesPerCallback: 4_096
        )
        let output = deviceOutput(sampleRate: 48_000)
        let presetA = EqualizerDefinition(preampDB: 6)
        let presetB = EqualizerDefinition(preampDB: -6)
        let transitionFrames = 960
        let positiveGain = Float(pow(10.0, 6.0 / 20.0))
        let negativeGain = Float(pow(10.0, -6.0 / 20.0))

        XCTAssertEqual(graph.prepare(for: output, equalizerDefinition: presetA).runnableEffects, [.equalizer])
        XCTAssertEqual(
            processConstant(graph, frameCount: transitionFrames).left.last!,
            positiveGain,
            accuracy: 1e-5
        )

        let noneResult = graph.updateEqualizer(definition: nil)
        XCTAssertTrue(noneResult.noEffectCanRun)
        XCTAssertEqual(
            processConstant(graph, frameCount: transitionFrames).left.last!,
            1,
            accuracy: 1e-5
        )

        XCTAssertEqual(graph.updateEqualizer(definition: presetA).runnableEffects, [.equalizer])
        XCTAssertEqual(
            processConstant(graph, frameCount: transitionFrames).left.last!,
            positiveGain,
            accuracy: 1e-5
        )

        _ = graph.updateEqualizer(definition: nil)
        _ = processConstant(graph, frameCount: transitionFrames)
        XCTAssertEqual(graph.prepare(for: output, equalizerDefinition: presetA).runnableEffects, [.equalizer])
        XCTAssertEqual(
            processConstant(graph, frameCount: transitionFrames).left.last!,
            positiveGain,
            accuracy: 1e-5
        )

        XCTAssertEqual(graph.updateEqualizer(definition: presetB).runnableEffects, [.equalizer])
        XCTAssertEqual(
            processConstant(graph, frameCount: transitionFrames).left.last!,
            negativeGain,
            accuracy: 1e-5
        )
    }

    func testInvalidLiveTargetKeepsEqualizerInCallbackForUnityCrossfade() throws {
        let equalizer = EqualizerEffectSpy(multiplier: 2)
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: true),
            equalizer: equalizer,
            maxFramesPerCallback: 8
        )
        _ = graph.prepare(
            for: deviceOutput(sampleRate: 48_000),
            equalizerDefinition: EqualizerDefinition(preampDB: 3)
        )
        _ = process(graph, left: [1], right: [1])
        XCTAssertEqual(equalizer.processCount, 1)

        equalizer.setTargetError = .invalidFilter(line: 31, reason: "frequency is above Nyquist")
        let result = graph.updateEqualizer(
            definition: EqualizerDefinition(filters: [testFilter(line: 31, frequency: 30_000)])
        )

        XCTAssertTrue(result.noEffectCanRun == false)
        XCTAssertEqual(result.runnableEffects, [.spatial])
        _ = process(graph, left: [1], right: [1])
        XCTAssertEqual(equalizer.processCount, 2)
    }

    private func process(
        _ graph: AudioEffectGraph,
        left: [Float],
        right: [Float]?
    ) -> (left: [Float], right: [Float]) {
        var outputLeft = [Float](repeating: .nan, count: left.count)
        var outputRight = [Float](repeating: .nan, count: left.count)
        left.withUnsafeBufferPointer { leftPointer in
            if let right {
                right.withUnsafeBufferPointer { rightPointer in
                    render(graph, leftPointer: leftPointer, rightPointer: rightPointer, outputLeft: &outputLeft, outputRight: &outputRight)
                }
            } else {
                render(graph, leftPointer: leftPointer, rightPointer: nil, outputLeft: &outputLeft, outputRight: &outputRight)
            }
        }
        return (outputLeft, outputRight)
    }

    private func processConstant(
        _ graph: AudioEffectGraph,
        frameCount: Int,
        value: Float = 1
    ) -> (left: [Float], right: [Float]) {
        process(
            graph,
            left: [Float](repeating: value, count: frameCount),
            right: [Float](repeating: value, count: frameCount)
        )
    }

    private func render(
        _ graph: AudioEffectGraph,
        leftPointer: UnsafeBufferPointer<Float>,
        rightPointer: UnsafeBufferPointer<Float>?,
        outputLeft: inout [Float],
        outputRight: inout [Float]
    ) {
        outputLeft.withUnsafeMutableBufferPointer { leftOutput in
            outputRight.withUnsafeMutableBufferPointer { rightOutput in
                graph.process(
                    inputLeft: leftPointer.baseAddress!,
                    inputRight: rightPointer?.baseAddress,
                    outputLeft: leftOutput.baseAddress!,
                    outputRight: rightOutput.baseAddress!,
                    frameCount: leftPointer.count
                )
            }
        }
    }
}

private final class SpatialEffectSpy: AudioSpatialEffect {
    let isReady: Bool
    let offset: Float
    private(set) var processCount = 0

    init(isReady: Bool, offset: Float = 0) {
        self.isReady = isReady
        self.offset = offset
    }

    func process(
        inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>?,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, frameCount: Int
    ) {
        processCount += 1
        for index in 0..<frameCount {
            outputLeft[index] = inputLeft[index] + offset
            outputRight[index] = (inputRight?[index] ?? inputLeft[index]) + offset
        }
    }
}

private final class EqualizerEffectSpy: AudioEqualizerEffect {
    private(set) var processCount = 0
    private(set) var preparedSampleRates: [Double] = []
    var error: EqualizerAudioEffectError?
    var setTargetError: EqualizerAudioEffectError?
    let multiplier: Float

    init(multiplier: Float = 1) {
        self.multiplier = multiplier
    }

    func prepare(definition: EqualizerDefinition?, sampleRate: Double) throws {
        preparedSampleRates.append(sampleRate)
        if let error { throw error }
    }

    func setTarget(definition: EqualizerDefinition?) throws {
        if let setTargetError { throw setTargetError }
    }

    func process(
        inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>?,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, frameCount: Int
    ) {
        processCount += 1
        for index in 0..<frameCount {
            outputLeft[index] = inputLeft[index] * multiplier
            outputRight[index] = (inputRight?[index] ?? inputLeft[index]) * multiplier
        }
    }
}

private func deviceOutput(sampleRate: Double) -> OutputDeviceDescriptor {
    OutputDeviceDescriptor(
        id: .init(1), uid: "test-output", name: "Test Output", transport: "test",
        outputChannelCount: 2, nominalSampleRate: sampleRate, isVirtual: false, isAggregate: false
    )
}

    private func testFilter(line: Int, frequency: Double = 1_000) -> EqualizerFilter {
    EqualizerFilter(
        sourceLine: line, sourceNumber: nil, isEnabled: true,
        type: .peaking, frequencyHz: frequency, gainDB: 3, q: 0.707
    )
}
