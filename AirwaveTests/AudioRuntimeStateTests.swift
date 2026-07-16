import XCTest
@testable import Airwave

@MainActor
final class AudioRuntimeStateTests: XCTestCase {
    func testInitialStateIsUnavailableWithMigrationMessage() {
        let runtime = AudioRuntimeState()

        XCTAssertEqual(
            runtime.status,
            .unavailable("Airwave 2.0 audio backend is not installed yet")
        )
        XCTAssertEqual(runtime.status.title, "Unavailable")
        XCTAssertFalse(runtime.status.isProcessing)
        XCTAssertEqual(runtime.permissionStatus, .unknown)
        XCTAssertEqual(runtime.tapHealth, .idle)
    }

    func testStatusDisplayMappingIsFiniteAndTruthful() {
        let values: [(AudioRuntimeState.Status, String, String)] = [
            (.inactive, "Inactive", "No HRIR preset selected; native audio remains unchanged."),
            (.nativePassthrough(reason: "Safe mode"), "Native passthrough", "Safe mode"),
            (.starting, "Starting", "Airwave is preparing native audio processing."),
            (.processing, "Processing", "Airwave is processing audio without changing macOS output or volume."),
            (.recovering(reason: "Retrying"), "Recovering", "Retrying")
        ]

        for (status, title, detail) in values {
            XCTAssertEqual(status.title, title)
            XCTAssertEqual(status.detail, detail)
        }
        XCTAssertTrue(AudioRuntimeState.Status.processing.isProcessing)
    }

    func testPermissionStatusCanBeIndependentFromEffectRuntimeStatus() {
        let runtime = AudioRuntimeState(
            status: .recovering(reason: "EQ is changing"),
            permissionStatus: .granted
        )

        XCTAssertEqual(runtime.permissionStatus, .granted)
        runtime.publish(
            .recovering(reason: "EQ is changing"),
            permission: .unknown
        )
        XCTAssertEqual(runtime.permissionStatus, .unknown)
    }

    func testRecoveringStateCanExitAnExplicitPermissionRequestToUnknown() {
        let runtime = AudioRuntimeState(
            status: .starting,
            permissionStatus: .checking
        )

        runtime.publish(
            .recovering(reason: "Create process tap failed (OSStatus -50). Retrying in 1s."),
            permission: .unknown
        )

        XCTAssertEqual(runtime.status, .recovering(reason: "Create process tap failed (OSStatus -50). Retrying in 1s."))
        XCTAssertEqual(runtime.permissionStatus, .unknown)
    }

    func testSetupHealthRequiresIndependentPermissionTapAndSupportedOutput() {
        let runtime = AudioRuntimeState(
            status: .inactive,
            currentOutput: OutputDeviceDescriptor(
                id: .init(1), uid: "built-in", name: "Built-in Output", transport: "Built-in",
                outputChannelCount: 2, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false
            ),
            permissionStatus: .granted,
            tapHealth: .ready
        )

        XCTAssertTrue(runtime.isSetupHealthy)
        runtime.setTapHealth(.failed(reason: "Tap failed"))
        XCTAssertFalse(runtime.isSetupHealthy)
        runtime.setTapHealth(.ready)
        runtime.setPermissionStatus(.denied)
        XCTAssertFalse(runtime.isSetupHealthy)
    }
}
