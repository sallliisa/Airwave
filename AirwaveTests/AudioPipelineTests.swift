import XCTest
import os
@testable import Airwave

final class AudioPipelineTests: XCTestCase {
    func testDefaultOutputFailureAcquiresNoResources() {
        assertFailure(.defaultOutput, cleanup: [])
    }

    func testOwnProcessFailureAcquiresNoResources() {
        assertFailure(.resolveOwnProcess, cleanup: [])
    }

    func testSuccessfulLifecycleUsesStrictOrderAndRequiredTapConfiguration() throws {
        let platform = RecordingAudioPlatformClient()
        let processor = PassthroughProcessor()
        let pipeline = AudioPipeline(platform: platform, processor: processor)

        try pipeline.start()
        try pipeline.stop()

        XCTAssertEqual(platform.events, [
            "defaultOutput", "resolveOwnProcess", "createTap", "tapFormat",
            "createAggregate:Built-in Output", "aggregateFormat", "createIO", "startIO",
            "stopIO", "destroyIO", "destroyAggregate", "destroyTap"
        ])
        let defaultRouting = resolvedRoute(for: platform.output)
        XCTAssertEqual(platform.tapRequests, [GlobalStereoTapRequest(excludedProcess: platform.process, routing: defaultRouting)])
        XCTAssertEqual(platform.tapRequests[0].outputDeviceUID, platform.output.uid)
        XCTAssertEqual(platform.tapRequests[0].streamIndex, defaultRouting.tapStreamIndex)
        XCTAssertTrue(platform.tapRequests[0].isGlobal)
        XCTAssertTrue(platform.tapRequests[0].isPrivate)
        XCTAssertEqual(platform.tapRequests[0].muteBehavior, .mutedWhenTapped)
        XCTAssertEqual(platform.tapRequests[0].channelCount, 2)
        XCTAssertTrue(platform.hasNoLiveResources)
        XCTAssertEqual(processor.cleanupCount, 1)
    }

    func testPipelineForwardsCaptureVerificationEvents() throws {
        let platform = RecordingAudioPlatformClient()
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())
        let events = OSAllocatedUnfairLock<[AudioCaptureVerificationEvent]>(initialState: [])

        try pipeline.start(on: platform.output) { event in
            events.withLock { $0.append(event) }
        }
        platform.verificationHandler?(.tapReady)

        XCTAssertEqual(events.withLock { $0 }, [.tapReady])
        try pipeline.stop()
    }

    func testUnmutedProbeReachesPlatformWithoutChangingLifecycle() throws {
        let platform = RecordingAudioPlatformClient()
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        try pipeline.start(
            on: platform.output,
            muteBehavior: .unmuted,
            verificationHandler: { _ in }
        )

        XCTAssertEqual(platform.tapRequests.map(\.muteBehavior), [.unmuted])
        try pipeline.stop()
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func testExplicitVerificationIncludesOwnProcessAndWritesUnmutedSilence() throws {
        let platform = RecordingAudioPlatformClient()
        let processor = RecordingProcessor()
        let pipeline = AudioPipeline(platform: platform, processor: processor)

        try pipeline.start(on: platform.output, purpose: .verification(includeOwnProcess: true), verificationHandler: { _ in })

        XCTAssertEqual(platform.tapRequests[0].excludedProcesses, [])
        XCTAssertEqual(platform.tapRequests[0].muteBehavior, .unmuted)
        var left = [Float](repeating: 9, count: 4)
        var right = [Float](repeating: 8, count: 4)
        let inputLeft = [Float](repeating: 1, count: 4)
        let inputRight = [Float](repeating: 1, count: 4)
        inputLeft.withUnsafeBufferPointer { inL in
            inputRight.withUnsafeBufferPointer { inR in
                left.withUnsafeMutableBufferPointer { outL in
                    right.withUnsafeMutableBufferPointer { outR in
                        var inputs: [UnsafePointer<Float>?] = [inL.baseAddress!, inR.baseAddress]
                        platform.ioCallback?(&inputs, inputs.count, outL.baseAddress!, outR.baseAddress!, 4)
                    }
                }
            }
        }
        XCTAssertEqual(left, [0, 0, 0, 0])
        XCTAssertEqual(right, [0, 0, 0, 0])
        XCTAssertEqual(processor.callCount, 0)
        try pipeline.stop()
    }

    func testPassiveVerificationExcludesOwnProcess() throws {
        let platform = RecordingAudioPlatformClient()
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        try pipeline.start(on: platform.output, purpose: .verification(includeOwnProcess: false), verificationHandler: { _ in })

        XCTAssertEqual(platform.tapRequests[0].excludedProcesses, [platform.process])
        try pipeline.stop()
    }

    func testInterleavedTapIsAcceptedWhenAUHALCanConvertIt() throws {
        let platform = RecordingAudioPlatformClient()
        platform.tapStreamFormat = AudioStreamFormat(
            sampleRate: 48_000,
            channelCount: 2,
            sampleType: .float32,
            isInterleaved: true
        )
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertNoThrow(try pipeline.start())
        XCTAssertNoThrow(try pipeline.stop())
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func test44100BluetoothTapTargetsOutputAndCompletesLifecycle() throws {
        let platform = RecordingAudioPlatformClient()
        platform.output = OutputDeviceDescriptor(
            id: .init(2), uid: "bluetooth", name: "Bluetooth Output", transport: "bluetooth",
            channelLabels: nil, outputChannelCount: 2, nominalSampleRate: 44_100,
            isVirtual: false, isAggregate: false
        )
        platform.tapStreamFormat = .stereo(sampleRate: 44_100)
        platform.aggregateStreamFormat = .stereo(sampleRate: 44_100)
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertNoThrow(try pipeline.start(on: platform.output))
        XCTAssertNoThrow(try pipeline.stop())
        XCTAssertEqual(platform.tapRequests[0].outputDeviceUID, "bluetooth")
        XCTAssertEqual(platform.tapRequests[0].streamIndex, 0)
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func testCrossRateTapAndOutputFailsBeforeAggregateCreation() {
        let platform = RecordingAudioPlatformClient()
        platform.output = OutputDeviceDescriptor(
            id: .init(2), uid: "bluetooth", name: "Bluetooth Output", transport: "bluetooth",
            channelLabels: nil, outputChannelCount: 2, nominalSampleRate: 44_100,
            isVirtual: false, isAggregate: false
        )
        platform.tapStreamFormat = .stereo(sampleRate: 48_000)
        platform.aggregateStreamFormat = .stereo(sampleRate: 44_100)
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertThrowsError(try pipeline.start(on: platform.output))
        XCTAssertFalse(platform.events.contains(where: { $0.hasPrefix("createAggregate") }))
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func testMatchingNativeRatesCompleteLifecycle() {
        for sampleRate in [44_100.0, 48_000.0, 88_200.0, 96_000.0] {
            let platform = RecordingAudioPlatformClient()
            platform.output = OutputDeviceDescriptor(
                id: .init(UInt64(sampleRate)), uid: "output-\(sampleRate)", name: "Output \(sampleRate)", transport: "built-in",
                channelLabels: nil, outputChannelCount: 2, nominalSampleRate: sampleRate,
                isVirtual: false, isAggregate: false
            )
            platform.tapStreamFormat = .stereo(sampleRate: sampleRate)
            platform.aggregateStreamFormat = .stereo(sampleRate: sampleRate)
            let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

            XCTAssertNoThrow(try pipeline.start(on: platform.output), "rate \(sampleRate)")
            XCTAssertNoThrow(try pipeline.stop(), "rate \(sampleRate)")
            XCTAssertTrue(platform.hasNoLiveResources, "rate \(sampleRate)")
        }
    }

    func testUnsupportedTapSampleRateMismatchStillFailsAndCleansUp() {
        let platform = RecordingAudioPlatformClient()
        platform.tapStreamFormat = .stereo(sampleRate: 96_000)
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertThrowsError(try pipeline.start())
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func testFailureAfterTapUnwindsTap() {
        assertFailure(.tapFormat, cleanup: ["destroyTap"])
    }

    func testTapCreationFailureAcquiresNoResources() {
        assertFailure(.createTap, cleanup: [])
    }

    func testAggregateFailureUnwindsTap() {
        assertFailure(.createAggregate, cleanup: ["destroyTap"])
    }

    func testCallbackCreationFailureUnwindsAggregateThenTap() {
        assertFailure(.createIO, cleanup: ["destroyAggregate", "destroyTap"])
    }

    func testChannelMapSetupFailureUnwindsAggregateThenTap() {
        assertFailure(.mapSetup, cleanup: ["destroyAggregate", "destroyTap"])
    }

    func testAggregateFormatFailureUnwindsAggregateThenTap() {
        assertFailure(.aggregateFormat, cleanup: ["destroyAggregate", "destroyTap"])
    }

    func testStartFailureDestroysIOAggregateAndTapWithoutStoppingUnstartedIO() {
        assertFailure(.startIO, cleanup: ["destroyIO", "destroyAggregate", "destroyTap"])
    }

    func testRepeatedStopIsIdempotent() throws {
        let platform = RecordingAudioPlatformClient()
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())
        try pipeline.start()
        try pipeline.stop()
        let events = platform.events

        try pipeline.stop()

        XCTAssertEqual(platform.events, events)
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func testDeinitCleansUpStartedPipeline() throws {
        let platform = RecordingAudioPlatformClient()
        var pipeline: AudioPipeline? = AudioPipeline(platform: platform, processor: PassthroughProcessor())
        try pipeline?.start()

        pipeline = nil

        XCTAssertEqual(Array(platform.events.suffix(4)), ["stopIO", "destroyIO", "destroyAggregate", "destroyTap"])
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func testMultichannelDeviceCarriesWidthThroughTapRequestAndLifecycle() throws {
        let platform = RecordingAudioPlatformClient()
        platform.output = OutputDeviceDescriptor(
            id: .init(5), uid: "avr", name: "AVR", transport: "HDMI",
            channelLabels: nil, outputChannelCount: 8, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        let wide = AudioStreamFormat.capturing(channels: 8, sampleRate: 48_000)
        platform.tapStreamFormat = wide
        platform.aggregateStreamFormat = wide
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertNoThrow(try pipeline.start(on: platform.output))
        XCTAssertEqual(platform.tapRequests[0].channelCount, 8)
        XCTAssertNoThrow(try pipeline.stop())
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func testStereoCaptureUsesNativeTapWidthAndHardwareOutputWidthIndependently() throws {
        let platform = RecordingAudioPlatformClient()
        platform.output = OutputDeviceDescriptor(
            id: .init(7), uid: "four-channel", name: "Four channel", transport: "USB",
            channelLabels: nil, outputChannelCount: 4, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false,
            preferredStereoChannels: .init(left: 1, right: 2)
        )
        platform.tapStreamFormat = .init(sampleRate: 48_000, channelCount: 4, sampleType: .float32, isInterleaved: false)
        platform.aggregateStreamFormat = .init(sampleRate: 48_000, channelCount: 4, sampleType: .float32, isInterleaved: false)
        let routing = resolvedRoute(for: platform.output, channels: .init(left: 3, right: 4))
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        try pipeline.start(on: routing, purpose: .processing, verificationHandler: { _ in })

        XCTAssertEqual(platform.tapRequests[0].channelCount, 4, "native tap width")
        XCTAssertEqual(platform.tapRequests[0].streamIndex, 0)
        XCTAssertEqual(platform.createdAggregateRouting?.sourceChannelIndices, [0, 1], "selected capture width is stereo")
        XCTAssertEqual(platform.createdAggregateRouting?.outputChannels, .init(left: 3, right: 4))
        XCTAssertEqual(platform.createdAggregateRouting?.device.outputChannelCount, 4, "physical output width")
        XCTAssertEqual(platform.createdIORouting, routing)
        try pipeline.stop()
    }

    func testMultiStreamRoutingUsesResolvedTapStreamIndex() throws {
        let platform = RecordingAudioPlatformClient()
        platform.output = OutputDeviceDescriptor(
            id: .init(6), uid: "multi-stream", name: "Multi-stream", transport: "USB",
            channelLabels: nil, outputChannelCount: 4, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false, outputStreamCount: 2,
            outputStreams: [
                .init(streamIndex: 0, startingChannel: 1, channelCount: 2),
                .init(streamIndex: 1, startingChannel: 3, channelCount: 2),
            ],
            preferredStereoChannels: .init(left: 3, right: 4)
        )
        platform.tapStreamFormat = .stereo(sampleRate: 48_000)
        platform.aggregateStreamFormat = .init(sampleRate: 48_000, channelCount: 4, sampleType: .float32, isInterleaved: false)
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())
        let routing = resolvedRoute(for: platform.output, channels: .init(left: 1, right: 2))

        try pipeline.start(on: routing, purpose: .processing, verificationHandler: { _ in })

        XCTAssertEqual(routing.tapStreamIndex, 1)
        XCTAssertEqual(routing.sourceChannelIndices, [0, 1])
        XCTAssertEqual(platform.tapRequests[0].streamIndex, 1)
        XCTAssertEqual(platform.tapRequests[0].channelCount, 2)
        XCTAssertEqual(platform.createdIORouting, routing)
        try pipeline.stop()
    }

    func testInvalidMultiStreamGeometryFailsBeforeResourceAcquisition() {
        let platform = RecordingAudioPlatformClient()
        platform.output = OutputDeviceDescriptor(
            id: .init(8), uid: "bad-multi-stream", name: "Bad multi-stream", transport: "USB",
            channelLabels: nil, outputChannelCount: 4, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false, outputStreamCount: 2,
            outputStreams: [.init(streamIndex: 0, startingChannel: 1, channelCount: 2)]
        )
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertThrowsError(try pipeline.start(on: platform.output))
        XCTAssertTrue(platform.events.isEmpty)
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func testVirtualAndAggregateDevicesStayRejectedAtEveryWidth() {
        for width in [2, 8] {
            let virtual = RecordingAudioPlatformClient()
            virtual.output = OutputDeviceDescriptor(
                id: .init(9), uid: "virtual", name: "Virtual", transport: "virtual",
                channelLabels: nil, outputChannelCount: width, nominalSampleRate: 48_000,
                isVirtual: true, isAggregate: false
            )
            XCTAssertThrowsError(try AudioPipeline(platform: virtual, processor: PassthroughProcessor()).start(on: virtual.output))
            XCTAssertFalse(virtual.events.contains("createTap"), "width \(width)")

            let aggregate = RecordingAudioPlatformClient()
            aggregate.output = OutputDeviceDescriptor(
                id: .init(10), uid: "aggregate", name: "Aggregate", transport: "aggregate",
                channelLabels: nil, outputChannelCount: width, nominalSampleRate: 48_000,
                isVirtual: false, isAggregate: true
            )
            XCTAssertThrowsError(try AudioPipeline(platform: aggregate, processor: PassthroughProcessor()).start(on: aggregate.output))
            XCTAssertFalse(aggregate.events.contains("createTap"), "width \(width)")
        }
    }

    func testCaptureWidthOutsideTwoToSixteenIsRejectedBeforeTapCreation() {
        for width in [1, 17] {
            let platform = RecordingAudioPlatformClient()
            platform.output = OutputDeviceDescriptor(
                id: .init(UInt64(width)), uid: "odd-\(width)", name: "Odd \(width)", transport: "USB",
                channelLabels: nil, outputChannelCount: width, nominalSampleRate: 48_000,
                isVirtual: false, isAggregate: false
            )
            XCTAssertThrowsError(try AudioPipeline(platform: platform, processor: PassthroughProcessor()).start(on: platform.output))
            XCTAssertFalse(platform.events.contains("createTap"), "width \(width)")
            XCTAssertTrue(platform.hasNoLiveResources, "width \(width)")
        }
    }

    func testUnsupportedOutputNeverCreatesTap() {
        let platform = RecordingAudioPlatformClient()
        platform.output = OutputDeviceDescriptor(
            id: .init(99), uid: "virtual", name: "Virtual", transport: "virtual",
            channelLabels: nil, outputChannelCount: 2, nominalSampleRate: 48_000,
            isVirtual: true, isAggregate: false
        )
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertThrowsError(try pipeline.start())
        XCTAssertEqual(platform.events, ["defaultOutput"])
    }

    func testStopFailurePreservesFullChainForRetry() throws {
        let platform = RecordingAudioPlatformClient()
        let processor = PassthroughProcessor()
        let pipeline = AudioPipeline(platform: platform, processor: processor)
        try pipeline.start()
        platform.teardownFailuresRemaining["stopIO"] = 1

        XCTAssertThrowsError(try pipeline.stop())
        XCTAssertEqual(platform.liveResources, [.tap, .aggregate, .io])
        XCTAssertEqual(processor.cleanupCount, 0)
        let retryStart = platform.events.count

        XCTAssertNoThrow(try pipeline.stop())
        XCTAssertEqual(Array(platform.events[retryStart...]), ["stopIO", "destroyIO", "destroyAggregate", "destroyTap"])
        XCTAssertEqual(processor.cleanupCount, 1)
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func testIODestroyFailurePreservesIOAndDependenciesForRetry() throws {
        try assertRetryableTeardownFailure(
            "destroyIO",
            liveAfterFailure: [.tap, .aggregate, .io],
            retryEvents: ["destroyIO", "destroyAggregate", "destroyTap"]
        )
    }

    func testAggregateDestroyFailurePreservesAggregateAndTapForRetry() throws {
        try assertRetryableTeardownFailure(
            "destroyAggregate",
            liveAfterFailure: [.tap, .aggregate],
            retryEvents: ["destroyAggregate", "destroyTap"]
        )
    }

    func testTapDestroyFailurePreservesTapForRetry() throws {
        try assertRetryableTeardownFailure(
            "destroyTap",
            liveAfterFailure: [.tap],
            retryEvents: ["destroyTap"]
        )
    }

    func testPlatformContractHasNoRouteVolumeOrGenericPropertyMutation() throws {
        let source = try String(contentsOf: contractSourceURL, encoding: .utf8)
        let protocolSource = source.components(separatedBy: "protocol AudioPlatformClient").last ?? ""
        for forbidden in ["setDefault", "setVolume", "AudioObjectSetPropertyData", "selectOutput"] {
            XCTAssertFalse(protocolSource.contains(forbidden), "Forbidden platform capability: \(forbidden)")
        }
    }

    private func assertFailure(_ point: RecordingAudioPlatformClient.FailurePoint, cleanup: [String]) {
        let platform = RecordingAudioPlatformClient()
        platform.failurePoint = point
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertThrowsError(try pipeline.start())
        if cleanup.isEmpty {
            XCTAssertFalse(platform.events.contains(where: { $0.hasPrefix("destroy") || $0 == "stopIO" }))
        } else {
            XCTAssertEqual(Array(platform.events.suffix(cleanup.count)), cleanup)
        }
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    private func assertRetryableTeardownFailure(
        _ event: String,
        liveAfterFailure: Set<RecordingAudioPlatformClient.Resource>,
        retryEvents: [String]
    ) throws {
        let platform = RecordingAudioPlatformClient()
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())
        try pipeline.start()
        platform.teardownFailuresRemaining[event] = 1

        XCTAssertThrowsError(try pipeline.stop())
        XCTAssertEqual(platform.liveResources, liveAfterFailure)
        let retryStart = platform.events.count

        XCTAssertNoThrow(try pipeline.stop())
        XCTAssertEqual(Array(platform.events[retryStart...]), retryEvents)
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func testPassthroughHoldHaltsIOImmediatelyAndDestroysOnceOrderedAfterWindow() throws {
        let platform = RecordingAudioPlatformClient()
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())
        try pipeline.start()
        AudioPipeline.passthroughHoldInterval = 0.05
        defer { AudioPipeline.passthroughHoldInterval = 0.5 }
        var completionError: Error?
        var completed = false

        XCTAssertNoThrow(try pipeline.stop(holdingPassthroughFade: true) { error in
            completionError = error
            completed = true
        })

        // While the fade is pending: program audio stopped (one stopIO) but
        // every handle stays registered (native audio stays muted).
        XCTAssertEqual(platform.events.filter { $0 == "stopIO" }.count, 1)
        XCTAssertEqual(platform.liveResources, [.tap, .aggregate, .io])

        try waitUntil(completed)
        XCTAssertNil(completionError)
        XCTAssertTrue(platform.hasNoLiveResources)
        // Exactly one ordered destroy sequence, strictly after the window.
        XCTAssertEqual(Array(platform.events.suffix(3)), ["destroyIO", "destroyAggregate", "destroyTap"])
        XCTAssertEqual(platform.events.filter { $0 == "destroyIO" }.count, 1)
        XCTAssertEqual(platform.events.filter { $0 == "destroyAggregate" }.count, 1)
        XCTAssertEqual(platform.events.filter { $0 == "destroyTap" }.count, 1)
    }

    func testNoUnmuteWhilePassthroughFadeIsPending() throws {
        let platform = RecordingAudioPlatformClient()
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())
        try pipeline.start()
        AudioPipeline.passthroughHoldInterval = 60
        defer { AudioPipeline.passthroughHoldInterval = 0.5 }

        XCTAssertNoThrow(try pipeline.stop(holdingPassthroughFade: true, onTeardownComplete: nil))

        // Nothing may be destroyed while the fade window is pending — this is
        // the property that keeps native audio muted through HRIR→None.
        XCTAssertEqual(platform.events.last, "stopIO")
        XCTAssertFalse(platform.events.contains("destroyTap"))
        XCTAssertFalse(platform.events.contains("destroyAggregate"))

        // A concurrent stop while teardown is pending must be refused instead
        // of reporting success (which would allow a replacement pipeline).
        XCTAssertThrowsError(try pipeline.stop())
        XCTAssertEqual(platform.events.last, "stopIO")
    }

    func testStopSuccessRunsDSPCleanupOnceAndReleasesStorage() throws {
        let platform = RecordingAudioPlatformClient()
        let processor = PassthroughProcessor()
        let pipeline = AudioPipeline(platform: platform, processor: processor)
        try pipeline.start()
        try pipeline.stop()
        XCTAssertEqual(processor.cleanupCount, 1)
        XCTAssertTrue(platform.hasNoLiveResources)
        // Repeated cleanup stays harmless.
        try pipeline.stop()
        XCTAssertEqual(processor.cleanupCount, 1)
    }

    func testFailedDeferredTeardownPreservesChainForSameObjectRetry() throws {
        let platform = RecordingAudioPlatformClient()
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())
        try pipeline.start()
        AudioPipeline.passthroughHoldInterval = 0.02
        defer { AudioPipeline.passthroughHoldInterval = 0.5 }
        platform.teardownFailuresRemaining["destroyTap"] = 1
        var completionError: Error?
        var completed = false

        XCTAssertNoThrow(try pipeline.stop(holdingPassthroughFade: true) { error in
            completionError = error
            completed = true
        })
        try waitUntil(completed)

        // The failing stage surfaces its error and preserves the surviving
        // chain on THE SAME object for a later stop() retry.
        XCTAssertNotNil(completionError)
        XCTAssertEqual(platform.liveResources, [.tap])

        XCTAssertNoThrow(try pipeline.stop())
        XCTAssertTrue(platform.hasNoLiveResources)
        guard let destroyStart = platform.events.firstIndex(of: "destroyIO") else {
            return XCTFail("expected a deferred destroy sequence")
        }
        XCTAssertEqual(
            Array(platform.events[destroyStart...]),
            ["destroyIO", "destroyAggregate", "destroyTap", "destroyTap"]
        )
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @autoclosure () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for deferred teardown") }
            // Pump the main queue so the deferred-teardown timer can fire;
            // synchronous XCTests execute on the main thread.
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private var contractSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Airwave/AudioPlatformClient.swift")
    }
}

private final class PassthroughProcessor: StereoAudioProcessing {
    var cleanupCount = 0
    func process(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>, inputChannelCount: Int,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, frameCount: Int
    ) {}
    func cleanupAfterIOStopped() { cleanupCount += 1 }
}

private final class RecordingProcessor: StereoAudioProcessing {
    var callCount = 0
    func process(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>, inputChannelCount: Int,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, frameCount: Int
    ) { callCount += 1 }
}

private final class RecordingAudioPlatformClient: AudioPlatformClient {
    enum Resource: Hashable { case tap, aggregate, io }
    enum FailurePoint {
        case defaultOutput, resolveOwnProcess, createTap, tapFormat
        case createAggregate, aggregateFormat, createIO, mapSetup, startIO
    }

    let process = AudioProcessHandle(value: 10)
    let tap = AudioTapHandle(value: 20)
    let aggregate = PrivateAggregateHandle(value: 30)
    let io = AudioIOHandle(value: 40)
    var output = OutputDeviceDescriptor(
        id: .init(1), uid: "builtin", name: "Built-in Output", transport: "built-in",
        channelLabels: nil, outputChannelCount: 2, nominalSampleRate: 48_000,
        isVirtual: false, isAggregate: false
    )
    var failurePoint: FailurePoint?
    var teardownFailuresRemaining: [String: Int] = [:]
    var events: [String] = []
    var tapRequests: [GlobalStereoTapRequest] = []
    private(set) var createdAggregateRouting: ResolvedOutputRouting?
    private(set) var createdIORouting: ResolvedOutputRouting?
    var tapStreamFormat = AudioStreamFormat.stereo(sampleRate: 48_000)
    var aggregateStreamFormat = AudioStreamFormat.stereo(sampleRate: 48_000)
    private(set) var liveResources: Set<Resource> = []
    private(set) var verificationHandler: AudioCaptureVerificationHandler?
    private(set) var ioCallback: AudioIOCallback?
    private var ioIsStarted = false

    var hasNoLiveResources: Bool { liveResources.isEmpty && !ioIsStarted }

    func defaultOutputDevice() throws -> OutputDeviceDescriptor {
        events.append("defaultOutput")
        if failurePoint == .defaultOutput { throw AudioRuntimeError.noOutputDevice }
        return output
    }
    func observeDefaultOutput(_ handler: @escaping DefaultOutputChangeHandler) throws {}
    func stopObservingDefaultOutput() {}
    func resolveOwnProcess() throws -> AudioProcessHandle {
        events.append("resolveOwnProcess")
        if failurePoint == .resolveOwnProcess { throw AudioRuntimeError.tapCreationFailed("process") }
        return process
    }
    func createGlobalStereoTap(_ request: GlobalStereoTapRequest) throws -> AudioTapHandle {
        events.append("createTap"); tapRequests.append(request)
        if failurePoint == .createTap { throw AudioRuntimeError.tapCreationFailed("test") }
        liveResources.insert(.tap)
        return tap
    }
    func destroyTap(_ tap: AudioTapHandle) throws { try teardown("destroyTap") }
    func createPrivateAggregate(tap: AudioTapHandle, routing: ResolvedOutputRouting) throws -> PrivateAggregateHandle {
        events.append("createAggregate:\(routing.device.name)")
        if failurePoint == .createAggregate { throw AudioRuntimeError.aggregateCreationFailed("test") }
        liveResources.insert(.aggregate)
        createdAggregateRouting = routing
        return aggregate
    }
    func destroyPrivateAggregate(_ aggregate: PrivateAggregateHandle) throws { try teardown("destroyAggregate") }
    func streamFormat(for tap: AudioTapHandle) throws -> AudioStreamFormat {
        events.append("tapFormat")
        if failurePoint == .tapFormat { throw AudioRuntimeError.deviceLost }
        return tapStreamFormat
    }
    func streamFormat(for aggregate: PrivateAggregateHandle) throws -> AudioStreamFormat {
        events.append("aggregateFormat")
        if failurePoint == .aggregateFormat { throw AudioRuntimeError.deviceLost }
        return aggregateStreamFormat
    }
    func createIO(
        aggregate: PrivateAggregateHandle,
        routing: ResolvedOutputRouting,
        callback: @escaping AudioIOCallback,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws -> AudioIOHandle {
        events.append("createIO")
        if failurePoint == .mapSetup { throw AudioRuntimeError.ioCreationFailed("channel map") }
        if failurePoint == .createIO { throw AudioRuntimeError.ioCreationFailed("test") }
        liveResources.insert(.io)
        createdIORouting = routing
        self.ioCallback = callback
        self.verificationHandler = verificationHandler
        return io
    }
    func startIO(_ io: AudioIOHandle) throws {
        events.append("startIO")
        if failurePoint == .startIO { throw AudioRuntimeError.ioStartFailed("test") }
        ioIsStarted = true
    }
    func stopIO(_ io: AudioIOHandle) throws { try teardown("stopIO") }
    func destroyIO(_ io: AudioIOHandle) throws { try teardown("destroyIO") }
    func openAudioCapturePermissionSettings() {}

    private func teardown(_ event: String) throws {
        events.append(event)
        if let remaining = teardownFailuresRemaining[event], remaining > 0 {
            teardownFailuresRemaining[event] = remaining - 1
            throw AudioRuntimeError.cleanupFailed(event)
        }
        switch event {
        case "stopIO":
            ioIsStarted = false
        case "destroyIO":
            precondition(!ioIsStarted)
            liveResources.remove(.io)
        case "destroyAggregate":
            precondition(!liveResources.contains(.io))
            liveResources.remove(.aggregate)
        case "destroyTap":
            precondition(!liveResources.contains(.aggregate))
            liveResources.remove(.tap)
        default:
            break
        }
    }
}

private func resolvedRoute(
    for output: OutputDeviceDescriptor,
    channels: StereoOutputChannels? = nil
) -> ResolvedOutputRouting {
    guard case .resolved(let route) = OutputRoutingResolver.resolve(output: output, channels: channels) else {
        preconditionFailure("Test output must resolve to a route")
    }
    return route
}
