import XCTest
@testable import Airwave

@MainActor
final class DeviceProfileRuntimeCoordinatorTests: XCTestCase {
    func testNewDeviceCompletesWithOneEmptyPairAndCreatesBypassedProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Coordinator.\(UUID().uuidString)"))
        let profiles = DeviceProfileManager(defaults: defaults)
        let hrir = HRIRManager(presetsDirectory: root.appendingPathComponent("hrir"), startWatcher: false)
        let equalizer = EqualizerManager(managedDirectory: root.appendingPathComponent("eq"))
        let platform = CoordinatorPlatformFake()
        let controller = AudioRuntimeController(
            state: AudioRuntimeState(), platform: platform,
            pipelineFactory: { CoordinatorPipelineFake() },
            scheduler: CoordinatorSchedulerFake()
        )
        let coordinator = DeviceProfileRuntimeCoordinator(
            profiles: profiles, hrir: hrir, equalizer: equalizer, controller: controller
        )
        let output = OutputDeviceDescriptor(
            id: .init(7), uid: "headphones", name: "Headphones", transport: "USB",
            outputChannelCount: 2, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false
        )
        var result: AudioRuntimeEffectReadiness?

        coordinator.prepare(output: output) { result = $0 }

        XCTAssertEqual(result, .init(spatialReady: false, equalizerDefinition: nil))
        XCTAssertEqual(profiles.currentDeviceUID, "headphones")
        XCTAssertNil(profiles.currentProfile?.hrirPresetID)
        XCTAssertNil(profiles.currentProfile?.equalizerPresetID)
    }
}

private final class CoordinatorSchedulerFake: AudioRuntimeScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AudioRuntimeCancellation {
        CoordinatorCancellationFake()
    }
}

private final class CoordinatorCancellationFake: AudioRuntimeCancellation { func cancel() {} }
private final class CoordinatorPipelineFake: AudioPipelineControlling {
    func start(
        on output: OutputDeviceDescriptor,
        muteBehavior: AudioTapMuteBehavior,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws { verificationHandler(.tapReady) }
    func stop() throws {}
}

private final class CoordinatorPlatformFake: AudioPlatformClient {
    func defaultOutputDevice() throws -> OutputDeviceDescriptor { throw AudioRuntimeError.noOutputDevice }
    func observeDefaultOutput(_ handler: @escaping DefaultOutputChangeHandler) throws {}
    func stopObservingDefaultOutput() {}
    func resolveOwnProcess() throws -> AudioProcessHandle { .init(value: 1) }
    func createGlobalStereoTap(_ request: GlobalStereoTapRequest) throws -> AudioTapHandle { .init(value: 1) }
    func destroyTap(_ tap: AudioTapHandle) throws {}
    func createPrivateAggregate(tap: AudioTapHandle, output: OutputDeviceDescriptor) throws -> PrivateAggregateHandle { .init(value: 1) }
    func destroyPrivateAggregate(_ aggregate: PrivateAggregateHandle) throws {}
    func streamFormat(for tap: AudioTapHandle) throws -> AudioStreamFormat { .stereo(sampleRate: 48_000) }
    func streamFormat(for aggregate: PrivateAggregateHandle) throws -> AudioStreamFormat { .stereo(sampleRate: 48_000) }
    func createIO(
        aggregate: PrivateAggregateHandle,
        callback: @escaping AudioIOCallback,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws -> AudioIOHandle { .init(value: 1) }
    func startIO(_ io: AudioIOHandle) throws {}
    func stopIO(_ io: AudioIOHandle) throws {}
    func destroyIO(_ io: AudioIOHandle) throws {}
    func openAudioCapturePermissionSettings() {}
}
