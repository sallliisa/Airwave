import CoreAudio
import AudioToolbox
import XCTest
@testable import Airwave

final class CoreAudioPlatformClientTests: XCTestCase {
    func testStatusMappingIncludesOperationAndCode() {
        XCTAssertEqual(CoreAudioStatus.creationError(-50, operation: "Create tap"), "Create tap failed (OSStatus -50)")
        XCTAssertTrue(CoreAudioStatus.isAlreadyGone(kAudioHardwareBadObjectError))
        XCTAssertFalse(CoreAudioStatus.isAlreadyGone(-50))
    }

    func testTapCreationIllegalOperationRemainsTapFailure() {
        XCTAssertEqual(
            CoreAudioErrorMapping.tapCreation(kAudioHardwareIllegalOperationError),
            .tapCreationFailed("Create process tap failed (OSStatus \(kAudioHardwareIllegalOperationError))")
        )
    }

    func testIOStartIllegalOperationIsPermissionDenied() {
        XCTAssertEqual(
            CoreAudioErrorMapping.ioStart(kAudioHardwareIllegalOperationError),
            .permissionDenied
        )
        XCTAssertEqual(
            CoreAudioErrorMapping.ioStart(-50),
            .ioStartFailed("Start HAL unit failed (OSStatus -50)")
        )
        XCTAssertEqual(CoreAudioErrorMapping.ioStart(kAudioDevicePermissionsError), .permissionDenied)
    }

    func testSuccessfulRenderReportsTapReady() {
        XCTAssertEqual(AudioCaptureVerificationPolicy.event(forRenderStatus: noErr), .tapReady)
    }

    func testSystemAudioPermissionPreflightMappingAndMissingSPI() {
        XCTAssertEqual(SystemAudioPermissionSPI.status(forPreflightResult: 0), .granted)
        XCTAssertEqual(SystemAudioPermissionSPI.status(forPreflightResult: 1), .denied)
        XCTAssertEqual(SystemAudioPermissionSPI.status(forPreflightResult: 2), .unknown)
        XCTAssertEqual(SystemAudioPermissionSPI.status(forPreflightResult: -1), .unknown)
        XCTAssertEqual(SystemAudioPermissionSPI.currentStatus(using: nil), .unknown)
    }

    func testPermissionRequestRequiresMatchingGrantedPreflight() {
        XCTAssertEqual(
            SystemAudioPermissionSPI.resolvedRequestStatus(
                requestGranted: true,
                preflightStatus: .granted
            ),
            .granted
        )
        XCTAssertEqual(
            SystemAudioPermissionSPI.resolvedRequestStatus(
                requestGranted: true,
                preflightStatus: .denied
            ),
            .unknown
        )
        XCTAssertEqual(
            SystemAudioPermissionSPI.resolvedRequestStatus(
                requestGranted: false,
                preflightStatus: .granted
            ),
            .denied
        )
    }

    func testRenderVerificationSeparatesPermissionAndGenericFailures() {
        XCTAssertEqual(
            AudioCaptureVerificationPolicy.event(forRenderStatus: kAudioDevicePermissionsError),
            .permissionDenied
        )
        XCTAssertEqual(AudioCaptureVerificationPolicy.event(forRenderStatus: -50), .renderFailed(-50))
    }

    func testCleanupRemovesDisposedContextWhileReportingUninitializeFailure() {
        let disposition = CoreAudioIOCleanup.disposition(uninitializeStatus: -50, disposeStatus: noErr)
        XCTAssertTrue(disposition.shouldRemoveContext)
        XCTAssertEqual(disposition.error, .cleanupFailed("Uninitialize HAL unit failed (OSStatus -50)"))
    }

    func testCleanupToleratesAlreadyGoneStatuses() {
        let disposition = CoreAudioIOCleanup.disposition(
            uninitializeStatus: kAudioHardwareBadObjectError,
            disposeStatus: kAudioHardwareBadObjectError
        )
        XCTAssertEqual(disposition, CoreAudioIOCleanupDisposition(shouldRemoveContext: true, error: nil))
    }

    func testCleanupPreservesContextWhenDisposeFails() {
        let disposition = CoreAudioIOCleanup.disposition(uninitializeStatus: noErr, disposeStatus: -50)
        XCTAssertFalse(disposition.shouldRemoveContext)
        XCTAssertEqual(disposition.error, .cleanupFailed("Dispose HAL unit failed (OSStatus -50)"))
    }

    func testFormatValidationRejectsMonoAndUnsupportedSamples() {
        XCTAssertTrue(StereoCallbackBridge.validate(.stereo(sampleRate: 48_000)))
        XCTAssertFalse(StereoCallbackBridge.validate(AudioStreamFormat(
            sampleRate: 48_000, channelCount: 1, sampleType: .float32, isInterleaved: false
        )))
        XCTAssertFalse(StereoCallbackBridge.validate(AudioStreamFormat(
            sampleRate: 48_000, channelCount: 2, sampleType: .unsupported, isInterleaved: false
        )))
        XCTAssertFalse(StereoCallbackBridge.validate(AudioStreamFormat(
            sampleRate: 48_000, channelCount: 2, sampleType: .float32, isInterleaved: true
        )))
    }

    func testSampleRateCompatibilityRequiresMatchingPositiveFiniteRates() {
        let rates = [44_100.0, 48_000.0, 88_200.0, 96_000.0]
        for rate in rates {
            XCTAssertTrue(AudioSampleRateCompatibility.matches(rate, with: rate))
        }
        for actual in rates {
            for expected in rates where actual != expected {
                XCTAssertFalse(AudioSampleRateCompatibility.matches(actual, with: expected))
            }
        }
        XCTAssertTrue(AudioSampleRateCompatibility.matches(48_000.49, with: 48_000))
        XCTAssertFalse(AudioSampleRateCompatibility.matches(0, with: 48_000))
        XCTAssertFalse(AudioSampleRateCompatibility.matches(-48_000, with: 48_000))
        XCTAssertFalse(AudioSampleRateCompatibility.matches(.infinity, with: 48_000))
        XCTAssertFalse(AudioSampleRateCompatibility.matches(.nan, with: 48_000))
    }

    func testCallbackPreparationMapsAndSilencesStereoOutput() {
        var left: [Float] = [8, 8, 8]
        var right: [Float] = [9, 9, 9]
        withBufferList(left: &left, right: &right, frameCapacity: 3) { list in
            let preparation = StereoCallbackBridge.prepare(ioData: list, requestedFrames: 3)
            XCTAssertEqual(preparation.status, noErr)
            XCTAssertEqual(preparation.output?.frameCount, 3)
            XCTAssertEqual(preparation.output?.left[0], 0)
            XCTAssertEqual(preparation.output?.right[0], 0)
            preparation.output?.left[1] = 1
            preparation.output?.right[2] = 2
        }
        XCTAssertEqual(left, [0, 1, 0])
        XCTAssertEqual(right, [0, 0, 2])
    }

    func testOversizedCallbackSilencesOnlyAdvertisedBoundsAndPreservesCanaries() {
        let count = StereoCallbackBridge.maximumFrames
        let canary: Float = 99
        var left = [Float](repeating: 1, count: count) + [canary]
        var right = [Float](repeating: 1, count: count) + [canary]
        withBufferList(left: &left, right: &right, frameCapacity: count) { list in
            let preparation = StereoCallbackBridge.prepare(
                ioData: list,
                requestedFrames: UInt32(count + 1)
            )
            XCTAssertNil(preparation.output)
            XCTAssertEqual(preparation.status, kAudioUnitErr_TooManyFramesToProcess)
        }
        XCTAssertTrue(left.prefix(count).allSatisfy { $0 == 0 })
        XCTAssertTrue(right.prefix(count).allSatisfy { $0 == 0 })
        XCTAssertEqual(left.last, canary)
        XCTAssertEqual(right.last, canary)
    }

    func testInvalidCallbackLayoutSilencesAvailableOutput() {
        var left: [Float] = [3, 3]
        var right: [Float] = [4, 4]
        withBufferList(left: &left, right: &right, frameCapacity: 2, rightChannels: 2) { list in
            let preparation = StereoCallbackBridge.prepare(ioData: list, requestedFrames: 2)
            XCTAssertNil(preparation.output)
            XCTAssertEqual(preparation.status, kAudio_ParamError)
        }
        XCTAssertEqual(left, [0, 0])
        XCTAssertEqual(right, [0, 0])
    }

    func testSingleBufferCallbackListIsRejectedAfterBoundedSilence() {
        var samples: [Float] = [5, 5, 77]
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(2 * MemoryLayout<Float>.size),
                    mData: buffer.baseAddress
                )
            )
            let preparation = withUnsafeMutablePointer(to: &list) {
                StereoCallbackBridge.prepare(ioData: $0, requestedFrames: 2)
            }
            XCTAssertNil(preparation.output)
            XCTAssertEqual(preparation.status, kAudio_ParamError)
        }
        XCTAssertEqual(samples, [0, 0, 77])
    }

    func testSignedManualPipelinePreservesDefaultOutput() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AIRWAVE_RUN_SIGNED_TAP_TESTS"] == "1",
            "Opt-in signed macOS integration harness"
        )
        let platform = CoreAudioPlatformClient()
        let before = try platform.defaultOutputDevice()
        let pipeline = AudioPipeline(platform: platform, processor: ManualSilenceProcessor())
        try pipeline.start()
        try pipeline.stop()
        XCTAssertEqual(try platform.defaultOutputDevice().id, before.id)
        XCTAssertNoThrow(try pipeline.stop())
    }

    private func withBufferList(
        left: inout [Float],
        right: inout [Float],
        frameCapacity: Int,
        rightChannels: UInt32 = 1,
        body: (UnsafeMutablePointer<AudioBufferList>) -> Void
    ) {
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                let byteCount = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
                let storage = UnsafeMutableRawPointer.allocate(
                    byteCount: byteCount,
                    alignment: MemoryLayout<AudioBufferList>.alignment
                )
                defer { storage.deallocate() }
                storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
                let list = storage.assumingMemoryBound(to: AudioBufferList.self)
                list.pointee.mNumberBuffers = 2
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                buffers[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frameCapacity * MemoryLayout<Float>.size),
                    mData: leftBuffer.baseAddress
                )
                buffers[1] = AudioBuffer(
                    mNumberChannels: rightChannels,
                    mDataByteSize: UInt32(frameCapacity * MemoryLayout<Float>.size),
                    mData: rightBuffer.baseAddress
                )
                body(list)
            }
        }
    }
}

private final class ManualSilenceProcessor: StereoAudioProcessing {
    func process(
        inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>?,
        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, frameCount: Int
    ) {
        StereoCallbackBridge.zero(left: outputLeft, right: outputRight, frameCount: frameCount)
    }
}
