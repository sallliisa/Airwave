import XCTest
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
        XCTAssertEqual(platform.tapRequests, [GlobalStereoTapRequest(excludedProcess: platform.process)])
        XCTAssertTrue(platform.tapRequests[0].isGlobal)
        XCTAssertTrue(platform.tapRequests[0].isPrivate)
        XCTAssertTrue(platform.tapRequests[0].mutedWhenTapped)
        XCTAssertEqual(platform.tapRequests[0].channelCount, 2)
        XCTAssertTrue(platform.hasNoLiveResources)
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

    func test44100TapWith48000OutputIsAcceptedAndCleansUp() throws {
        let platform = RecordingAudioPlatformClient()
        platform.tapStreamFormat = .stereo(sampleRate: 44_100)
        platform.aggregateStreamFormat = .stereo(sampleRate: 48_000)
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertNoThrow(try pipeline.start())
        XCTAssertNoThrow(try pipeline.stop())
        XCTAssertTrue(platform.hasNoLiveResources)
    }

    func test48000TapWith44100OutputIsAcceptedAndCleansUp() throws {
        let platform = RecordingAudioPlatformClient()
        platform.output = OutputDeviceDescriptor(
            id: .init(2), uid: "bluetooth", name: "Bluetooth Output", transport: "bluetooth",
            outputChannelCount: 2, nominalSampleRate: 44_100, isVirtual: false, isAggregate: false
        )
        platform.tapStreamFormat = .stereo(sampleRate: 48_000)
        platform.aggregateStreamFormat = .stereo(sampleRate: 44_100)
        let pipeline = AudioPipeline(platform: platform, processor: PassthroughProcessor())

        XCTAssertNoThrow(try pipeline.start(on: platform.output))
        XCTAssertNoThrow(try pipeline.stop())
        XCTAssertTrue(platform.hasNoLiveResources)
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
    func createIO(aggregate: PrivateAggregateHandle, callback: @escaping AudioIOCallback) throws -> AudioIOHandle {
        events.append("createIO")
        if failurePoint == .createIO { throw AudioRuntimeError.ioCreationFailed("test") }
        liveResources.insert(.io)
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
