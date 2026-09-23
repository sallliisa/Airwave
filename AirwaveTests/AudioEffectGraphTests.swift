import XCTest
@testable import Airwave

final class AudioEffectGraphTests: XCTestCase {
    func testBundledPresetSpatialOutputStaysWithinHeadroomAfterWarmup() throws {
        for presetName in ["NeutralSH1.0", "RoomSH1.0", "StageSH1.0"] {
            let spatial = try bundledSpatialEffect(named: presetName)
            let graph = AudioEffectGraph(
                spatial: spatial,
                equalizer: EqualizerEffectSpy(),
                maxFramesPerCallback: 512
            )
            let preparation = graph.prepare(
                for: deviceOutput(sampleRate: 48_000),
                equalizerDefinition: nil
            )
            XCTAssertEqual(preparation.runnableEffects, [.spatial], "preset \(presetName)")

            var sampleOffset = 0
            var measuredPeak: Float = 0
            for callback in 0..<48 {
                let input = sine(amplitude: 0.8, frameCount: 512, startFrame: sampleOffset)
                let result = process(graph, left: input, right: input)
                assertFiniteAndSized(result, frameCount: input.count)
                if callback >= 24 {
                    measuredPeak = max(
                        measuredPeak,
                        max(
                            result.left.reduce(Float.zero) { max($0, abs($1)) },
                            result.right.reduce(Float.zero) { max($0, abs($1)) }
                        )
                    )
                }
                sampleOffset += input.count
            }

            XCTAssertLessThanOrEqual(
                measuredPeak,
                0.98,
                "\(presetName) final graph peak was \(measuredPeak)"
            )
        }
    }

    func testBundledPresetBelowCeilingOutputIsUnchanged() throws {
        for presetName in ["NeutralSH1.0", "RoomSH1.0", "StageSH1.0"] {
            let reference = try bundledProcessor(named: presetName)
            let spatial = try bundledSpatialEffect(named: presetName)
            let graph = AudioEffectGraph(
                spatial: spatial,
                equalizer: EqualizerEffectSpy(),
                maxFramesPerCallback: 512
            )
            _ = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)

            var sampleOffset = 0
            var referencePeak: Float = 0
            var maximumDifference: Float = 0
            for callback in 0..<48 {
                let input = sine(amplitude: 0.6, frameCount: 512, startFrame: sampleOffset)
                let expected = process(reference, left: input, right: input)
                let actual = process(graph, left: input, right: input)
                assertFiniteAndSized(actual, frameCount: input.count)
                if callback >= 24 {
                    referencePeak = max(
                        referencePeak,
                        max(
                            expected.left.reduce(Float.zero) { max($0, abs($1)) },
                            expected.right.reduce(Float.zero) { max($0, abs($1)) }
                        )
                    )
                    let leftDifference = zip(expected.left, actual.left)
                        .map { abs($0 - $1) }
                        .max() ?? 0
                    let rightDifference = zip(expected.right, actual.right)
                        .map { abs($0 - $1) }
                        .max() ?? 0
                    maximumDifference = max(maximumDifference, max(leftDifference, rightDifference))
                }
                sampleOffset += input.count
            }

            XCTAssertLessThan(referencePeak, 0.98, "\(presetName) reference peak was \(referencePeak)")
            XCTAssertLessThanOrEqual(
                maximumDifference,
                1e-6,
                "\(presetName) changed below-ceiling output by \(maximumDifference)"
            )
        }
    }

    func testSpatialOutputBelowCeilingRemainsUnchanged() throws {
        let spatial = SpatialEffectSpy(isReady: true, multiplier: 1.2)
        let graph = AudioEffectGraph(
            spatial: spatial,
            equalizer: EqualizerEffectSpy(),
            maxFramesPerCallback: 128
        )
        _ = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)
        let input = sine(amplitude: 0.6, frameCount: 96)

        let result = process(graph, left: input, right: input)
        let expected = input.map { $0 * 1.2 }

        assertFiniteAndSized(result, frameCount: input.count)
        XCTAssertEqual(result.left, expected)
        XCTAssertEqual(result.right, expected)
        XCTAssertLessThan(result.left.map { abs($0) }.max() ?? 0, 0.98)
    }

    func testSpatialOverloadScalesWholeCallbackWithoutClippingPeaks() throws {
        let spatial = SpatialEffectSpy(isReady: true, multiplier: 2)
        let graph = AudioEffectGraph(
            spatial: spatial,
            equalizer: EqualizerEffectSpy(),
            maxFramesPerCallback: 128
        )
        _ = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)
        let input = sine(amplitude: 0.8, frameCount: 96)

        let result = process(graph, left: input, right: input)
        let gain = result.left[12] / (input[12] * 2)
        let peak = max(result.left.map { abs($0) }.max() ?? 0, result.right.map { abs($0) }.max() ?? 0)

        assertFiniteAndSized(result, frameCount: input.count)
        XCTAssertLessThan(gain, 1)
        XCTAssertEqual(peak, 0.98, accuracy: 2e-5)
        for index in input.indices {
            XCTAssertEqual(result.left[index], input[index] * 2 * gain, accuracy: 1e-6)
            XCTAssertEqual(result.right[index], input[index] * 2 * gain, accuracy: 1e-6)
        }
    }

    func testSpatialOverloadUsesOneLinkedGainForDifferentStereoSignals() throws {
        let spatial = SpatialEffectSpy(isReady: true, multiplier: 2)
        let graph = AudioEffectGraph(
            spatial: spatial,
            equalizer: EqualizerEffectSpy(),
            maxFramesPerCallback: 128
        )
        _ = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)
        let leftInput = sine(amplitude: 0.8, frameCount: 96)
        let rightInput = (0..<96).map { Float(0.4 * cos(2 * Double.pi * 1_000 * Double($0) / 48_000)) }

        let result = process(graph, left: leftInput, right: rightInput)
        let leftGain = result.left[12] / (leftInput[12] * 2)
        let rightGain = result.right[0] / (rightInput[0] * 2)

        assertFiniteAndSized(result, frameCount: leftInput.count)
        XCTAssertEqual(leftGain, rightGain, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(result.left.map { abs($0) }.max() ?? 0, 0.98)
        XCTAssertLessThanOrEqual(result.right.map { abs($0) }.max() ?? 0, 0.98)
    }

    func testHeadroomRecoveryUsesElapsedFramesAcrossMixedCallbackSizes() throws {
        let spatial = SpatialEffectSpy(isReady: true, multiplier: 2)
        let graph = AudioEffectGraph(
            spatial: spatial,
            equalizer: EqualizerEffectSpy(),
            maxFramesPerCallback: 4_096
        )
        _ = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)

        let callbackSizes = [64, 128, 300, 512, 513, 4_096]
        let amplitudes: [Float] = [0.8, 0.1, 0.1, 0.1, 0.1, 0.1, 0.2, 0.4, 0.6, 0.8]
        var previousGain: Float = 1
        for (callback, amplitude) in amplitudes.enumerated() {
            let frameCount = callbackSizes[callback % callbackSizes.count]
            let result = process(
                graph,
                left: [Float](repeating: amplitude, count: frameCount),
                right: [Float](repeating: amplitude, count: frameCount)
            )
            let processedPeak = amplitude * 2
            let safeGain = processedPeak > 0.98 ? Float(0.98).nextDown / processedPeak : 1
            let reducing = safeGain < previousGain
            let expectedStartGain = reducing ? safeGain : previousGain
            let expectedTargetGain = reducing
                ? safeGain
                : min(safeGain, previousGain + Float(frameCount) / 4_800)
            let expectedLastGain = expectedStartGain
                + (expectedTargetGain - expectedStartGain)
                * Float(frameCount - 1) / Float(frameCount)
            let measuredStartGain = result.left[0] / processedPeak
            let measuredLastGain = result.left[frameCount - 1] / processedPeak

            assertFiniteAndSized(result, frameCount: frameCount)
            XCTAssertEqual(measuredStartGain, expectedStartGain, accuracy: 1e-5)
            XCTAssertEqual(measuredLastGain, expectedLastGain, accuracy: 1e-5)
            XCTAssertLessThanOrEqual(result.left.map { abs($0) }.max() ?? 0, 0.98)
            XCTAssertLessThanOrEqual(result.right.map { abs($0) }.max() ?? 0, 0.98)
            previousGain = expectedTargetGain
        }
    }

    func testHeadroomRecoveryRemainsSmoothAcrossCallbackBoundaries() throws {
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: true, multiplier: 2),
            equalizer: EqualizerEffectSpy(),
            maxFramesPerCallback: 4_096
        )
        _ = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)

        let overloadInput = [Float](repeating: 0.8, count: 512)
        let overloadOutput = process(graph, left: overloadInput, right: overloadInput)
        var previousStartGain = overloadOutput.left[0] / 1.6
        var previousLastGain = overloadOutput.left[overloadOutput.left.count - 1] / 1.6
        var previousGainStep: Float = 0

        for frameCount in [64, 128, 300, 512, 513, 4_096] {
            let input = [Float](repeating: 0.1, count: frameCount)
            let result = process(graph, left: input, right: input)
            let nextGain = min(1, previousStartGain + Float(frameCount) / 4_800)
            let gainStep = (nextGain - previousStartGain) / Float(frameCount)
            let measuredGains = result.left.map { $0 / 0.2 }

            assertFiniteAndSized(result, frameCount: frameCount)
            XCTAssertEqual(
                measuredGains[0],
                previousStartGain,
                accuracy: 1e-5,
                "recovery did not continue at the start of a \(frameCount)-frame callback"
            )
            XCTAssertEqual(
                measuredGains[0] - previousLastGain,
                previousGainStep,
                accuracy: 1e-5,
                "callback boundary gain step differed from the preceding frame step"
            )
            for index in measuredGains.indices {
                let expectedGain = previousStartGain + gainStep * Float(index)
                XCTAssertEqual(measuredGains[index], expectedGain, accuracy: 1e-5)
            }

            previousStartGain = nextGain
            previousLastGain = measuredGains[measuredGains.count - 1]
            previousGainStep = gainStep
        }
    }

    func testStopCleanupClearsPreviousHeadroomReduction() throws {
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: true, multiplier: 2),
            equalizer: EqualizerEffectSpy(),
            maxFramesPerCallback: 8
        )
        _ = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)

        let overloaded = processConstant(graph, frameCount: 8, value: 0.8)
        XCTAssertLessThanOrEqual(overloaded.left.map { abs($0) }.max() ?? 0, 0.98)
        graph.cleanupAfterIOStopped()

        let quiet = processConstant(graph, frameCount: 8, value: 0.2)

        assertFiniteAndSized(quiet, frameCount: 8)
        XCTAssertEqual(quiet.left, [Float](repeating: 0.4, count: 8))
        XCTAssertEqual(quiet.right, [Float](repeating: 0.4, count: 8))
    }

    func testNoEffectPassthroughClearsReductionAndKeepsInputBits() throws {
        let spatial = SpatialEffectSpy(isReady: true, multiplier: 2)
        let graph = AudioEffectGraph(
            spatial: spatial,
            equalizer: EqualizerEffectSpy(),
            maxFramesPerCallback: 8
        )
        _ = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)
        _ = processConstant(graph, frameCount: 8, value: 0.8)
        spatial.processResult = false

        let leftInput: [Float] = [Float(2).nextUp, -3, 0.25, -0.5]
        let rightInput: [Float] = [0.75, Float(-2).nextDown, 0.125, -0.25]
        let passthrough = process(graph, left: leftInput, right: rightInput)

        assertFiniteAndSized(passthrough, frameCount: leftInput.count)
        XCTAssertEqual(passthrough.left.map { $0.bitPattern }, leftInput.map { $0.bitPattern })
        XCTAssertEqual(passthrough.right.map { $0.bitPattern }, rightInput.map { $0.bitPattern })

        spatial.processResult = true
        let resumed = processConstant(graph, frameCount: 1, value: 0.2)
        XCTAssertEqual(resumed.left, [0.4])
        XCTAssertEqual(resumed.right, [0.4])
    }

    func testNeitherEffectCopiesStereoAndDuplicatesMono() throws {
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: false, processResult: false),
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

        XCTAssertEqual(result.left[0], 11 * 0.98 / 12, accuracy: 1e-5)
        XCTAssertEqual(result.right[0], 0.98, accuracy: 1e-5)
        XCTAssertEqual(spatial.processCount, 1)
        XCTAssertEqual(equalizer.processCount, 0)
    }

    func testCallbackUsesSpatialOutputWhenControlReadinessIsFalse() throws {
        let spatial = SpatialEffectSpy(isReady: false, offset: 10, processResult: true)
        let graph = AudioEffectGraph(spatial: spatial, equalizer: EqualizerEffectSpy(), maxFramesPerCallback: 8)
        let preparation = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)

        XCTAssertTrue(preparation.noEffectCanRun)
        let result = process(graph, left: [1], right: [2])

        XCTAssertEqual(result.left[0], 11 * 0.98 / 12, accuracy: 1e-5)
        XCTAssertEqual(result.right[0], 0.98, accuracy: 1e-5)
        XCTAssertEqual(spatial.processCount, 1)
    }

    func testCallbackUsesFallbackWhenControlReadinessIsTrueButSpatialWritesNothing() throws {
        let spatial = SpatialEffectSpy(isReady: true, processResult: false)
        let graph = AudioEffectGraph(spatial: spatial, equalizer: EqualizerEffectSpy(), maxFramesPerCallback: 8)
        let preparation = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)

        XCTAssertEqual(preparation.runnableEffects, [.spatial])
        let result = process(graph, left: [1], right: [2])

        XCTAssertEqual(result.left, [1])
        XCTAssertEqual(result.right, [2])
        XCTAssertEqual(spatial.processCount, 1)
    }

    func testEqualizerOnlyRunsAfterInputPassthrough() throws {
        let spatial = SpatialEffectSpy(isReady: false, processResult: false)
        let equalizer = EqualizerEffectSpy(multiplier: 2)
        let graph = AudioEffectGraph(spatial: spatial, equalizer: equalizer, maxFramesPerCallback: 8)
        let definition = EqualizerDefinition(preampDB: 3)
        let preparation = graph.prepare(for: deviceOutput(sampleRate: 44_100), equalizerDefinition: definition)

        XCTAssertEqual(preparation.runnableEffects, [.equalizer])
        XCTAssertEqual(equalizer.preparedSampleRates, [44_100])
        let result = process(graph, left: [1], right: nil)

        XCTAssertEqual(result.left[0], 0.98, accuracy: 1e-5)
        XCTAssertEqual(result.right[0], 0.98, accuracy: 1e-5)
        XCTAssertEqual(equalizer.processCount, 1)
    }

    func testWideDeviceFoldsDownThroughGainTableWhenSpatialInactive() throws {
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: false, processResult: false),
            equalizer: EqualizerEffectSpy(),
            maxFramesPerCallback: 8
        )
        // 5.1 device: FL, FR, FC, LFE, BL, BR.
        let output = OutputDeviceDescriptor(
            id: .init(3), uid: "avr", name: "AVR", transport: "HDMI",
            channelLabels: nil, outputChannelCount: 6, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        _ = graph.prepare(for: output, equalizerDefinition: nil)

        // Channels carry 1.0; expected fold-down per the gain table:
        // left = 0.707 (FL) + 0.707 (FC) + 0.5 (BL), right = FR/FC/BR likewise.
        let result = process(graph, channels: [Float](repeating: 1, count: 6))
        XCTAssertEqual(result.left.first!, 0.707 + 0.707 + 0.5, accuracy: 1e-4)
        XCTAssertEqual(result.right.first!, 0.707 + 0.707 + 0.5, accuracy: 1e-4)
    }

    func testPlainStereoPassthroughStaysByteExactMemcpy() throws {
        let spatial = SpatialEffectSpy(isReady: false, processResult: false)
        let graph = AudioEffectGraph(spatial: spatial, equalizer: EqualizerEffectSpy(), maxFramesPerCallback: 8)
        _ = graph.prepare(for: deviceOutput(sampleRate: 48_000), equalizerDefinition: nil)

        let leftInput = [Float(1).nextDown, 0.5]
        let rightInput = [Float(2).nextUp, -0.25]
        let result = process(graph, left: leftInput, right: rightInput)

        XCTAssertEqual(result.left, leftInput)
        XCTAssertEqual(result.right, rightInput)
    }

    func testEqualizerRunsAfterWideFoldDown() throws {
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: false, processResult: false),
            equalizer: EqualizerEffectSpy(multiplier: 2),
            maxFramesPerCallback: 8
        )
        let output = OutputDeviceDescriptor(
            id: .init(4), uid: "avr", name: "AVR", transport: "HDMI",
            channelLabels: nil, outputChannelCount: 6, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        _ = graph.prepare(for: output, equalizerDefinition: EqualizerDefinition(preampDB: 3))

        let result = process(graph, channels: [Float](repeating: 1, count: 6))
        XCTAssertEqual(result.left.first!, 0.98, accuracy: 1e-5)
        XCTAssertEqual(result.right.first!, 0.98, accuracy: 1e-5)
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

        XCTAssertEqual(result.left[0], 22 * 0.98 / 24, accuracy: 1e-5)
        XCTAssertEqual(result.right[0], 0.98, accuracy: 1e-5)
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
            spatial: SpatialEffectSpy(isReady: false, processResult: false),
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
            spatial: SpatialEffectSpy(isReady: false, processResult: false),
            equalizer: EqualizerRuntimeEffect(),
            maxFramesPerCallback: 4_096
        )
        let output = deviceOutput(sampleRate: 48_000)
        let presetA = EqualizerDefinition(preampDB: 6)
        let presetB = EqualizerDefinition(preampDB: -6)
        let transitionFrames = 960
        let positiveGain = Float(pow(10.0, 6.0 / 20.0))
        let negativeGain = Float(pow(10.0, -6.0 / 20.0))
        let inputLevel: Float = 0.25

        XCTAssertEqual(graph.prepare(for: output, equalizerDefinition: presetA).runnableEffects, [.equalizer])
        XCTAssertEqual(
            processConstant(graph, frameCount: transitionFrames, value: inputLevel).left.last!,
            inputLevel * positiveGain,
            accuracy: 1e-5
        )

        let noneResult = graph.updateEqualizer(definition: nil)
        XCTAssertTrue(noneResult.noEffectCanRun)
        XCTAssertEqual(
            processConstant(graph, frameCount: transitionFrames, value: inputLevel).left.last!,
            inputLevel,
            accuracy: 1e-5
        )

        XCTAssertEqual(graph.updateEqualizer(definition: presetA).runnableEffects, [.equalizer])
        XCTAssertEqual(
            processConstant(graph, frameCount: transitionFrames, value: inputLevel).left.last!,
            inputLevel * positiveGain,
            accuracy: 1e-5
        )

        _ = graph.updateEqualizer(definition: nil)
        _ = processConstant(graph, frameCount: transitionFrames, value: inputLevel)
        XCTAssertEqual(graph.prepare(for: output, equalizerDefinition: presetA).runnableEffects, [.equalizer])
        XCTAssertEqual(
            processConstant(graph, frameCount: transitionFrames, value: inputLevel).left.last!,
            inputLevel * positiveGain,
            accuracy: 1e-5
        )

        XCTAssertEqual(graph.updateEqualizer(definition: presetB).runnableEffects, [.equalizer])
        XCTAssertEqual(
            processConstant(graph, frameCount: transitionFrames, value: inputLevel).left.last!,
            inputLevel * negativeGain,
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
        XCTAssertEqual(result.runnableEffects, [.spatial, .equalizer])
        _ = process(graph, left: [1], right: [1])
        XCTAssertEqual(equalizer.processCount, 2)
    }

    func testRejectedEQOnlyUpdateKeepsWorkingTargetRunnable() throws {
        // Production path: no spatial effect, one active EQ target, then an
        // invalid replacement. The processor keeps the old target, so the
        // returned status must keep .equalizer runnable and the callback must
        // keep the old gain. An empty status would stop an EQ-only pipeline
        // that still has audible output.
        let equalizer = EqualizerRuntimeEffect()
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: false, processResult: false),
            equalizer: equalizer,
            maxFramesPerCallback: 4_096
        )
        let output = deviceOutput(sampleRate: 48_000)
        let working = EqualizerDefinition(preampDB: 6)
        let workingGain = Float(pow(10.0, 6.0 / 20.0))

        let prepared = graph.prepare(for: output, equalizerDefinition: working)
        XCTAssertEqual(prepared.runnableEffects, [.equalizer])
        // Settle the 20 ms unity->+6 dB ramp before the rejection: the graph
        // holds the working target through the fade, so the check below reads
        // the retained gain, not a mid-ramp sample.
        _ = processConstant(graph, frameCount: 960, value: 0.25)
        XCTAssertEqual(
            process(graph, left: [0.25], right: [0.25]).left,
            [0.25 * workingGain]
        )

        let invalid = EqualizerDefinition(filters: [testFilter(line: 31, frequency: 30_000)])
        let rejected = graph.updateEqualizer(definition: invalid)

        XCTAssertEqual(rejected.runnableEffects, [.equalizer])
        XCTAssertFalse(rejected.noEffectCanRun)
        XCTAssertEqual(rejected.equalizerWarning?.filterLine, 31)
        XCTAssertEqual(
            process(graph, left: [0.25], right: [0.25]).left,
            [0.25 * workingGain]
        )
    }

    func testStopCleanupReleasesRetiredEQProcessor() throws {
        let effect = EqualizerRuntimeEffect()
        try effect.prepare(definition: EqualizerDefinition(preampDB: 6), sampleRate: 48_000)
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: false, processResult: false),
            equalizer: effect,
            maxFramesPerCallback: 8
        )
        _ = graph.prepare(
            for: deviceOutput(sampleRate: 48_000),
            equalizerDefinition: EqualizerDefinition(preampDB: 6)
        )
        // Drive one callback so the audio side adopts the processor, then
        // replace the sample-rate processor and drive again so the old one
        // retires. Stop cleanup must release every audio reference.
        _ = process(graph, left: [Float](repeating: 0.25, count: 8), right: [Float](repeating: 0.25, count: 8))
        try effect.prepare(definition: EqualizerDefinition(preampDB: -6), sampleRate: 44_100)
        _ = process(graph, left: [Float](repeating: 0.25, count: 8), right: [Float](repeating: 0.25, count: 8))
        graph.cleanupAfterIOStopped()
        // Post-stop processing with no published EQ must passthrough.
        let result = process(graph, left: [Float](repeating: 0.25, count: 8), right: [Float](repeating: 0.25, count: 8))
        XCTAssertEqual(result.left, [Float](repeating: 0.25, count: 8))
    }

    func testNewEqualizerTargetWinsRaceWithBypassCompletion() {
        let equalizer = EqualizerEffectSpy(multiplier: 2)
        let graph = AudioEffectGraph(
            spatial: SpatialEffectSpy(isReady: false, processResult: false),
            equalizer: equalizer,
            maxFramesPerCallback: 8
        )
        _ = graph.prepare(
            for: deviceOutput(sampleRate: 48_000),
            equalizerDefinition: EqualizerDefinition(preampDB: 3)
        )
        equalizer.bypassed = true
        equalizer.onBypassRead = {
            equalizer.bypassed = false
            _ = graph.updateEqualizer(definition: EqualizerDefinition(preampDB: 6))
        }

        _ = process(graph, left: [1], right: [1])
        equalizer.onBypassRead = nil
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

    private func process(
        _ graph: AudioEffectGraph,
        channels: [Float],
        frameCount: Int? = nil
    ) -> (left: [Float], right: [Float]) {
        let frames = frameCount ?? 1
        var outputLeft = [Float](repeating: .nan, count: frames)
        var outputRight = [Float](repeating: .nan, count: frames)
        var storage = channels
        if storage.count < 2 { storage.append(contentsOf: repeatElement(0, count: 2 - storage.count)) }
        let channelCount = storage.count
        storage.withUnsafeMutableBufferPointer { storageBuffer in
            let base = UnsafePointer(storageBuffer.baseAddress!)
            let pointers: [UnsafePointer<Float>?] = (0..<channelCount).map {
                base.advanced(by: $0 * frames)
            }
            pointers.withUnsafeBufferPointer { channelPointers in
                outputLeft.withUnsafeMutableBufferPointer { leftOutput in
                    outputRight.withUnsafeMutableBufferPointer { rightOutput in
                        graph.process(
                            inputChannels: channelPointers.baseAddress!,
                            inputChannelCount: channelCount,
                            outputLeft: leftOutput.baseAddress!,
                            outputRight: rightOutput.baseAddress!,
                            frameCount: frames
                        )
                    }
                }
            }
        }
        return (outputLeft, outputRight)
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
                let channels: [UnsafePointer<Float>?] = [leftPointer.baseAddress!, rightPointer?.baseAddress]
                channels.withUnsafeBufferPointer { channelPointers in
                    graph.process(
                        inputChannels: channelPointers.baseAddress!,
                        inputChannelCount: 2,
                        outputLeft: leftOutput.baseAddress!,
                        outputRight: rightOutput.baseAddress!,
                        frameCount: leftPointer.count
                    )
                }
            }
        }
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

    private func sine(amplitude: Float, frameCount: Int, startFrame: Int = 0) -> [Float] {
        (0..<frameCount).map { frame in
            Float(Double(amplitude) * sin(2 * Double.pi * 1_000 * Double(startFrame + frame) / 48_000))
        }
    }

    private func assertFiniteAndSized(
        _ result: (left: [Float], right: [Float]),
        frameCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.left.count, frameCount, file: file, line: line)
        XCTAssertEqual(result.right.count, frameCount, file: file, line: line)
        XCTAssertTrue(result.left.allSatisfy({ $0.isFinite }), file: file, line: line)
        XCTAssertTrue(result.right.allSatisfy({ $0.isFinite }), file: file, line: line)
    }

    private func bundledSpatialEffect(named presetName: String) throws -> BundledRealtimeSpatialEffect {
        BundledRealtimeSpatialEffect(processor: try bundledProcessor(named: presetName))
    }

    private func bundledProcessor(named presetName: String) throws -> RealtimeAudioProcessor {
        let root = URL(fileURLWithPath: #filePath)
            .standardizedFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let presetURL = root.appendingPathComponent("assets/hrtf/\(presetName).wav")
        let wav = try WAVLoader.load(from: presetURL)
        XCTAssertEqual(wav.channelCount, 14)

        let frontLeft = try XCTUnwrap(StereoConvolutionEngine(
            leftEarHRIR: wav.audioData[0],
            rightEarHRIR: wav.audioData[1],
            blockSize: 512
        ))
        let frontRight = try XCTUnwrap(StereoConvolutionEngine(
            leftEarHRIR: wav.audioData[8],
            rightEarHRIR: wav.audioData[7],
            blockSize: 512
        ))
        let processor = RealtimeAudioProcessor(
            renderers: [
                VirtualSpeakerRenderer(speaker: .FL, convolver: frontLeft),
                VirtualSpeakerRenderer(speaker: .FR, convolver: frontRight)
            ],
            inputChannelCount: 2,
            fallbackSpeakers: [.FL, .FR],
            blockSize: 512,
            maxFramesPerCallback: 512
        )
        return processor
    }

    private func process(
        _ processor: RealtimeAudioProcessor,
        left: [Float],
        right: [Float]
    ) -> (left: [Float], right: [Float]) {
        var outputLeft = [Float](repeating: .nan, count: left.count)
        var outputRight = [Float](repeating: .nan, count: left.count)
        left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                outputLeft.withUnsafeMutableBufferPointer { leftOutput in
                    outputRight.withUnsafeMutableBufferPointer { rightOutput in
                        let channels: [UnsafePointer<Float>?] = [leftPointer.baseAddress!, rightPointer.baseAddress!]
                        channels.withUnsafeBufferPointer { channelPointers in
                            processor.process(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 2,
                                inputOffset: 0,
                                leftOutput: leftOutput.baseAddress!,
                                rightOutput: rightOutput.baseAddress!,
                                frameCount: left.count
                            )
                        }
                    }
                }
            }
        }
        return (outputLeft, outputRight)
    }
}

private final class SpatialEffectSpy: AudioSpatialEffect {
    let isReady: Bool
    let offset: Float
    let multiplier: Float
    var processResult: Bool
    private(set) var processCount = 0

    init(isReady: Bool, offset: Float = 0, multiplier: Float = 1, processResult: Bool = true) {
        self.isReady = isReady
        self.offset = offset
        self.multiplier = multiplier
        self.processResult = processResult
    }

    func process(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>, inputChannelCount: Int,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, frameCount: Int
    ) -> Bool {
        processCount += 1
        for index in 0..<frameCount {
            let left = inputChannels[0]
            let right = inputChannelCount > 1 ? inputChannels[1] : inputChannels[0]
            outputLeft[index] = (left?[index] ?? 0) * multiplier + offset
            outputRight[index] = (right?[index] ?? 0) * multiplier + offset
        }
        return processResult
    }
}

private final class BundledRealtimeSpatialEffect: AudioSpatialEffect {
    let isReady = true
    private let processor: RealtimeAudioProcessor

    init(processor: RealtimeAudioProcessor) {
        self.processor = processor
    }

    func process(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Bool {
        processor.process(
            inputChannels: inputChannels,
            inputChannelCount: inputChannelCount,
            inputOffset: 0,
            leftOutput: outputLeft,
            rightOutput: outputRight,
            frameCount: frameCount
        )
        return true
    }
}

private final class EqualizerEffectSpy: AudioEqualizerEffect {
    private(set) var processCount = 0
    private(set) var preparedSampleRates: [Double] = []
    var error: EqualizerAudioEffectError?
    var setTargetError: EqualizerAudioEffectError?
    var bypassed = false
    var onBypassRead: (() -> Void)?
    var isBypassed: Bool {
        onBypassRead?()
        return bypassed
    }
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
        channelLabels: nil, outputChannelCount: 2, nominalSampleRate: sampleRate,
        isVirtual: false, isAggregate: false
    )
}

    private func testFilter(line: Int, frequency: Double = 1_000) -> EqualizerFilter {
    EqualizerFilter(
        sourceLine: line, sourceNumber: nil, isEnabled: true,
        type: .peaking, frequencyHz: frequency, gainDB: 3, q: 0.707
    )
}
