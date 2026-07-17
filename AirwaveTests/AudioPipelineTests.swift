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
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        try pipeline.start()
        try pipeline.stop()

        XCTAssertEqual(platform.events, [
            "defaultOutput", "resolveOwnProcess", "createTap", "tapFormat",
            "createAggregate:Built-in Output", "aggregateFormat", "createIO", "startIO",
            "stopIO", "destroyIO", "destroyAggregate", "destroyTap"
        ])
        XCTAssertEqual(platform.tapRequests, [GlobalStereoTapRequest(excludedProcess: platform.process, output: platform.output)])
        XCTAssertEqual(platform.tapRequests[0].outputDeviceUID, platform.output.uid)
        XCTAssertEqual(platform.tapRequests[0].streamIndex, 0)
        XCTAssertTrue(platform.tapRequests[0].isGlobal)
        XCTAssertTrue(platform.tapRequests[0].isPrivate)
        XCTAssertEqual(platform.tapRequests[0].muteBehavior, .mutedWhenTapped)
        XCTAssertEqual(platform.tapRequests[0].channelCount, 2)
        XCTAssertTrue(platform.hasNoLiveResources)
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
                        platform.ioCallback?(inL.baseAddress!, inR.baseAddress, outL.baseAddress!, outR.baseAddress!, 4)
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
            outputChannelCount: 2, nominalSampleRate: 44_100, isVirtual: false, isAggregate: false
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
            outputChannelCount: 2, nominalSampleRate: 44_100, isVirtual: false, isAggregate: false
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
                outputChannelCount: 2, nominalSampleRate: sampleRate, isVirtual: false, isAggregate: false
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

    func testUnsupportedOutputNeverCreatesTap() {
        let platform = RecordingAudioPlatformClient()
        platform.output = OutputDeviceDescriptor(
            id: .init(99), uid: "virtual", name: "Virtual", transport: "virtual",
            outputChannelCount: 2, nominalSampleRate: 48_000, isVirtual: true, isAggregate: false
        )
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertThrowsError(try pipeline.start())
        XCTAssertEqual(platform.events, ["defaultOutput"])
    }

    func testStopFailurePreservesFullChainForRetry() throws {
        try assertRetryableTeardownFailure(
            "stopIO",
            liveAfterFailure: [.tap, .aggregate, .io],
            retryEvents: ["stopIO", "destroyIO", "destroyAggregate", "destroyTap"]
        )
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

    private var contractSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Airwave/AudioPlatformClient.swift")
    }
}

private final class PassthroughProcessor: StereoAudioProcessing {
    func process(
        inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>?,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, frameCount: Int
    ) {}
}

private final class RecordingProcessor: StereoAudioProcessing {
    var callCount = 0
    func process(
        inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>?,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, frameCount: Int
    ) { callCount += 1 }
}

private final class RecordingAudioPlatformClient: AudioPlatformClient {
    enum Resource: Hashable { case tap, aggregate, io }
    enum FailurePoint {
        case defaultOutput, resolveOwnProcess, createTap, tapFormat
        case createAggregate, aggregateFormat, createIO, startIO
    }

    let process = AudioProcessHandle(value: 10)
    let tap = AudioTapHandle(value: 20)
    let aggregate = PrivateAggregateHandle(value: 30)
    let io = AudioIOHandle(value: 40)
    var output = OutputDeviceDescriptor(
        id: .init(1), uid: "builtin", name: "Built-in Output", transport: "built-in",
        outputChannelCount: 2, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false
    )
    var failurePoint: FailurePoint?
    var teardownFailuresRemaining: [String: Int] = [:]
    var events: [String] = []
    var tapRequests: [GlobalStereoTapRequest] = []
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
    func createPrivateAggregate(tap: AudioTapHandle, output: OutputDeviceDescriptor) throws -> PrivateAggregateHandle {
        events.append("createAggregate:\(output.name)")
        if failurePoint == .createAggregate { throw AudioRuntimeError.aggregateCreationFailed("test") }
        liveResources.insert(.aggregate)
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
        callback: @escaping AudioIOCallback,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws -> AudioIOHandle {
        events.append("createIO")
        if failurePoint == .createIO { throw AudioRuntimeError.ioCreationFailed("test") }
        liveResources.insert(.io)
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
