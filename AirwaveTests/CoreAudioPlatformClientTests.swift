import CoreAudio
import XCTest
@testable import Airwave

final class CoreAudioPlatformClientTests: XCTestCase {
    func testPermissionAndGenericHALFailuresMapSeparately() {
        XCTAssertEqual(CoreAudioErrorMapping.ioStart(kAudioHardwareIllegalOperationError), .permissionDenied)
        XCTAssertEqual(CoreAudioErrorMapping.ioStart(kAudioDevicePermissionsError), .permissionDenied)
        XCTAssertEqual(CoreAudioErrorMapping.ioStart(-50), .ioStartFailed("Start HAL unit failed (OSStatus -50)"))
        XCTAssertEqual(AudioCaptureVerificationPolicy.event(forRenderStatus: kAudioDevicePermissionsError), .permissionDenied)
        XCTAssertEqual(AudioCaptureVerificationPolicy.event(forRenderStatus: -50), .renderFailed(-50))
    }

    func testCaptureSignalPolicyRejectsSilenceSpikeAndNonFiniteSamples() {
        var policy = CaptureSignalPolicy()
        var zeros = [Float](repeating: 0, count: CaptureSignalPolicy.minimumSustainedFrames)
        XCTAssertFalse(zeros.withUnsafeBufferPointer { policy.observe(inputLeft: $0.baseAddress!, inputRight: $0.baseAddress, frameCount: $0.count) })

        var spike = zeros
        spike[0] = 1
        XCTAssertFalse(spike.withUnsafeBufferPointer { policy.observe(inputLeft: $0.baseAddress!, inputRight: $0.baseAddress, frameCount: $0.count) })

        var nonFinite = [Float](repeating: .infinity, count: CaptureSignalPolicy.minimumSustainedFrames)
        var fresh = CaptureSignalPolicy()
        XCTAssertFalse(nonFinite.withUnsafeBufferPointer { fresh.observe(inputLeft: $0.baseAddress!, inputRight: $0.baseAddress, frameCount: $0.count) })
    }

    func testCaptureSignalPolicyAcceptsSustainedLowLevelSignalOnce() {
        var policy = CaptureSignalPolicy()
        var signal = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.minimumSustainedFrames)

        let detected = signal.withUnsafeBufferPointer {
            policy.observe(inputLeft: $0.baseAddress!, inputRight: $0.baseAddress, frameCount: $0.count)
        }
        XCTAssertTrue(detected)
        XCTAssertTrue(signal.withUnsafeBufferPointer {
            policy.observe(inputLeft: $0.baseAddress!, inputRight: $0.baseAddress, frameCount: $0.count)
        })
    }

    func testCoreAudioTapRequestSupportsAllProcessesAndOwnProcessExclusion() {
        let output = OutputDeviceDescriptor(
            id: .init(1), uid: "built-in", name: "Built-in", transport: "built-in",
            outputChannelCount: 2, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false
        )
        let process = AudioProcessHandle(value: 7)
        XCTAssertEqual(GlobalStereoTapRequest(excludedProcesses: [], output: output).excludedProcesses, [])
        XCTAssertEqual(GlobalStereoTapRequest(excludedProcesses: [process], output: output).excludedProcesses, [process])
    }

    func testCleanupDispositionPreservesCorrectLifecycleSemantics() {
        XCTAssertEqual(
            CoreAudioIOCleanup.disposition(uninitializeStatus: kAudioHardwareBadObjectError, disposeStatus: kAudioHardwareBadObjectError),
            CoreAudioIOCleanupDisposition(shouldRemoveContext: true, error: nil)
        )
        XCTAssertFalse(CoreAudioIOCleanup.disposition(uninitializeStatus: noErr, disposeStatus: -50).shouldRemoveContext)
    }

    private func forRenderStatus(_ status: OSStatus) -> AudioCaptureVerificationEvent {
        AudioCaptureVerificationPolicy.event(forRenderStatus: status)
    }
}
