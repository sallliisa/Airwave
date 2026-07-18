import XCTest
@testable import Airwave

@MainActor
final class AudioRuntimeStateTests: XCTestCase {
    func testNeutralStateIsUnverified() {
        let runtime = AudioRuntimeState()

        XCTAssertEqual(runtime.captureAccess, .unverified)
        XCTAssertFalse(runtime.isSetupHealthy)
    }

    func testSetupHealthRequiresVerifiedCaptureAndSupportedOutput() {
        let runtime = AudioRuntimeState(currentOutput: output(), captureAccess: .verified)

        XCTAssertTrue(runtime.isSetupHealthy)
        runtime.setCaptureAccess(AudioRuntimeState.CaptureAccess.failed(reason: "silent capture"))
        XCTAssertFalse(runtime.isSetupHealthy)
        runtime.setCaptureAccess(AudioRuntimeState.CaptureAccess.verified)
        runtime.publish(AudioRuntimeState.Status.inactive, output: output(channels: 1))
        XCTAssertFalse(runtime.isSetupHealthy)
    }

    func testCaptureFailureRemainsDistinctFromPermissionRequired() {
        let runtime = AudioRuntimeState()

        runtime.publish(.nativePassthrough(reason: "timeout"), captureAccess: .failed(reason: "timeout"))
        XCTAssertEqual(runtime.captureAccess, .failed(reason: "timeout"))
        runtime.setCaptureAccess(.permissionRequired)
        XCTAssertEqual(runtime.captureAccess, .permissionRequired)
    }

    func testHealthIssuesAreUniqueByCategoryAndStablyOrdered() {
        let runtime = AudioRuntimeState(currentOutput: output(), captureAccess: .verified)

        runtime.setHealthIssue(.equalizerFailed(reason: "first"), for: .equalizer)
        runtime.setHealthIssue(.noUsableOutput, for: .output)
        runtime.setHealthIssue(.permissionRequired, for: .permission)
        runtime.setHealthIssue(.equalizerFailed(reason: "latest"), for: .equalizer)

        XCTAssertEqual(runtime.healthIssues, [
            .permissionRequired,
            .noUsableOutput,
            .equalizerFailed(reason: "latest")
        ])
        XCTAssertTrue(runtime.hasBlockingHealthIssue)
        XCTAssertFalse(runtime.isSetupHealthy)

        runtime.setHealthIssue(nil, for: .permission)
        runtime.setHealthIssue(nil, for: .output)
        runtime.setHealthIssue(nil, for: .equalizer)
        XCTAssertFalse(runtime.hasBlockingHealthIssue)
        XCTAssertTrue(runtime.isSetupHealthy)
    }

    private func output(channels: Int = 2) -> OutputDeviceDescriptor {
        OutputDeviceDescriptor(
            id: .init(1), uid: "built-in", name: "Built-in Output", transport: "Built-in",
            outputChannelCount: channels, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false
        )
    }
}
