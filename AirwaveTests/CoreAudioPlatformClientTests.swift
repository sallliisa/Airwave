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
        let zeros = [Float](repeating: 0, count: CaptureSignalPolicy.minimumSustainedFrames)
        XCTAssertFalse(zeros.withUnsafeBufferPointer { policy.observe(channel: $0.baseAddress!, frameCount: $0.count) })

        var spike = zeros
        spike[0] = 1
        XCTAssertFalse(spike.withUnsafeBufferPointer { policy.observe(channel: $0.baseAddress!, frameCount: $0.count) })

        let nonFinite = [Float](repeating: .infinity, count: CaptureSignalPolicy.minimumSustainedFrames)
        var fresh = CaptureSignalPolicy()
        XCTAssertFalse(nonFinite.withUnsafeBufferPointer { fresh.observe(channel: $0.baseAddress!, frameCount: $0.count) })
    }

    func testCaptureSignalPolicyAcceptsSustainedLowLevelSignalOnce() {
        var policy = CaptureSignalPolicy()
        let signal = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.minimumSustainedFrames)

        let detected = signal.withUnsafeBufferPointer {
            policy.observe(channel: $0.baseAddress!, frameCount: $0.count)
        }
        XCTAssertTrue(detected)
        XCTAssertTrue(signal.withUnsafeBufferPointer {
            policy.observe(channel: $0.baseAddress!, frameCount: $0.count)
        })
    }

    func testVerificationStateDetectsSignalOnAnySingleChannelOfEight() {
        var state = CoreAudioIOVerificationState(inputChannelCount: 8)
        let quiet = [Float](repeating: 0, count: CaptureSignalPolicy.minimumSustainedFrames)
        let loud = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.minimumSustainedFrames)

        quiet.withUnsafeBufferPointer { quietPointer in
            loud.withUnsafeBufferPointer { loudPointer in
                let channels: [UnsafePointer<Float>?] = {
                    var values = Array(repeating: quietPointer.baseAddress!, count: 8)
                    values[5] = loudPointer.baseAddress!
                    return values
                }()
                channels.withUnsafeBufferPointer { channelPointers in
                    let event = state.observeSignal(
                        inputChannels: channelPointers.baseAddress!,
                        inputChannelCount: 8,
                        frameCount: CaptureSignalPolicy.minimumSustainedFrames
                    )
                    XCTAssertEqual(event, .signalDetected)
                }
            }
        }
    }

    func testVerificationStateStaysSilentWhenOnlyOneChannelSpikes() {
        var state = CoreAudioIOVerificationState(inputChannelCount: 4)
        let quiet = [Float](repeating: 0, count: CaptureSignalPolicy.minimumSustainedFrames)
        var spiking = quiet
        spiking[0] = 1

        quiet.withUnsafeBufferPointer { quietPointer in
            spiking.withUnsafeBufferPointer { spikePointer in
                let channels: [UnsafePointer<Float>?] = {
                    var values = Array(repeating: quietPointer.baseAddress!, count: 4)
                    values[2] = spikePointer.baseAddress!
                    return values
                }()
                channels.withUnsafeBufferPointer { channelPointers in
                    let event = state.observeSignal(
                        inputChannels: channelPointers.baseAddress!,
                        inputChannelCount: 4,
                        frameCount: CaptureSignalPolicy.minimumSustainedFrames
                    )
                    XCTAssertNil(event)
                }
            }
        }
    }

    func testSignalReportDoesNotSuppressLaterRenderFailureReport() {
        var state = CoreAudioIOVerificationState(inputChannelCount: 2)
        let signal = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.minimumSustainedFrames)

        let signalEvent = signal.withUnsafeBufferPointer { signalPointer in
            let channels: [UnsafePointer<Float>?] = [signalPointer.baseAddress!, nil]
            return channels.withUnsafeBufferPointer { channelPointers in
                state.observeSignal(
                    inputChannels: channelPointers.baseAddress!,
                    inputChannelCount: 2,
                    frameCount: CaptureSignalPolicy.minimumSustainedFrames
                )
            }
        }

        XCTAssertEqual(signalEvent, .signalDetected)
        XCTAssertEqual(state.observeRenderFailure(status: -50), .renderFailed(-50))
        XCTAssertNil(state.observeRenderFailure(status: -51))
    }

    func testRenderFailureReportDoesNotRepeat() {
        var state = CoreAudioIOVerificationState(inputChannelCount: 2)

        XCTAssertEqual(state.observeRenderFailure(status: -50), .renderFailed(-50))
        XCTAssertNil(state.observeRenderFailure(status: -51))
    }

    func testCoreAudioTapRequestSupportsAllProcessesAndOwnProcessExclusion() {
        let output = OutputDeviceDescriptor(
            id: .init(1), uid: "built-in", name: "Built-in", transport: "built-in",
            channelLabels: nil, outputChannelCount: 2, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        let process = AudioProcessHandle(value: 7)
        XCTAssertEqual(GlobalStereoTapRequest(excludedProcesses: [], output: output).excludedProcesses, [])
        XCTAssertEqual(GlobalStereoTapRequest(excludedProcesses: [process], output: output).excludedProcesses, [process])
    }

    func testTapRequestWidthFollowsDeviceChannelCount() {
        for width in [2, 6, 8, 16] {
            let output = OutputDeviceDescriptor(
                id: .init(UInt64(width)), uid: "device-\(width)", name: "Device \(width)", transport: "USB",
                channelLabels: nil, outputChannelCount: width, nominalSampleRate: 48_000,
                isVirtual: false, isAggregate: false
            )
            XCTAssertEqual(GlobalStereoTapRequest(excludedProcesses: [], output: output).channelCount, width, "width \(width)")
        }
    }

    /// Regression: non-interleaved PCM stores one channel per AudioBuffer, so
    /// a frame is always 4 bytes per buffer regardless of stream width. The
    /// multichannel overhaul briefly scaled mBytesPerFrame by channel count,
    /// producing a contradictory ASBD that Core Audio rejected with 'fmt!'
    /// and left AUHAL's input chain unconnected (-10876).
    func testCanonicalCaptureFormatKeepsNonInterleavedByteGeometryAtEveryWidth() {
        for width in [2, 6, 8, 16] {
            let format = CoreAudioPlatformClient.canonicalNonInterleavedFloat32Format(
                sampleRate: 48_000,
                channelCount: width
            )
            XCTAssertEqual(format.mFormatID, kAudioFormatLinearPCM, "width \(width)")
            XCTAssertEqual(
                format.mFormatFlags,
                kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                "width \(width)"
            )
            XCTAssertEqual(format.mBitsPerChannel, 32, "width \(width)")
            XCTAssertEqual(format.mChannelsPerFrame, UInt32(width), "width \(width)")
            XCTAssertEqual(format.mFramesPerPacket, 1, "width \(width)")
            XCTAssertEqual(format.mBytesPerFrame, 4, "non-interleaved frame stays one sample per buffer (width \(width))")
            XCTAssertEqual(format.mBytesPerPacket, 4, "width \(width)")
            XCTAssertEqual(format.mSampleRate, 48_000, "width \(width)")
        }
    }

    func testTapGuardRejectsWidthOutsideTwoToSixteenBeforeAnyHALWork() {
        let client = CoreAudioPlatformClient()
        var accepted = 0
        for width in [1, 17] {
            let output = OutputDeviceDescriptor(
                id: .init(UInt64(width)), uid: "odd-\(width)", name: "Odd \(width)", transport: "USB",
                channelLabels: nil, outputChannelCount: width, nominalSampleRate: 48_000,
                isVirtual: false, isAggregate: false
            )
            let request = GlobalStereoTapRequest(excludedProcesses: [], output: output)
            XCTAssertEqual(request.channelCount, width, "request width must follow the descriptor")
            XCTAssertThrowsError(try client.createGlobalStereoTap(request), "width \(width)") { error in
                guard case AudioRuntimeError.tapCreationFailed("Invalid global tap request") = error else {
                    return XCTFail("expected tap-validation failure for width \(width), got \(error)")
                }
            }
            accepted += 1
        }
        XCTAssertEqual(accepted, 2)
    }

    func testAggregateGuardRejectsVirtualAndAggregateDevicesAtWideWidths() {
        let client = CoreAudioPlatformClient()
        let tap = AudioTapHandle(value: 1)
        for (name, isVirtual, isAggregate) in [("virtual", true, false), ("aggregate", false, true)] {
            let output = OutputDeviceDescriptor(
                id: .init(2), uid: name, name: name.capitalized, transport: name,
                channelLabels: nil, outputChannelCount: 8, nominalSampleRate: 48_000,
                isVirtual: isVirtual, isAggregate: isAggregate
            )
            XCTAssertThrowsError(try client.createPrivateAggregate(tap: tap, output: output), name) { error in
                XCTAssertEqual(error as? AudioRuntimeError, .unsupportedOutput(name.capitalized), name)
            }
        }
    }

    @discardableResult
    private func makeBufferList(channelBuffers: Int, frames: Int, fill: Float) -> ([UnsafeMutablePointer<Float>], UnsafeMutablePointer<AudioBufferList>) {
        let pointers = (0..<channelBuffers).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: frames)
        }
        for pointer in pointers {
            pointer.initialize(repeating: fill, count: frames)
        }
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(
            capacity: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * max(channelBuffers - 1, 0)
        )
        list.initialize(
            to: AudioBufferList(
                mNumberBuffers: UInt32(channelBuffers),
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: pointers[0]
                )
            )
        )
        if channelBuffers > 1 {
            let extra = UnsafeMutablePointer<AudioBuffer>(OpaquePointer(list.advanced(by: 1)))
            for index in 1..<channelBuffers {
                extra[index - 1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: pointers[index]
                )
            }
        }
        return (pointers, list)
    }

    private func destroyBufferList(_ pointers: [UnsafeMutablePointer<Float>], _ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        for pointer in pointers {
            pointer.deinitialize(count: frames)
            pointer.deallocate()
        }
        list.deallocate()
    }

    func testPrepareSilencesEveryOutputBufferIncludingBeyondTwo() {
        let frames = 64
        let (pointers, list) = makeBufferList(channelBuffers: 4, frames: frames, fill: 3.25)
        defer { destroyBufferList(pointers, list, frames: frames) }

        // The stereo-output contract still fails a 4-buffer list...
        let preparation = StereoCallbackBridge.prepare(ioData: list, requestedFrames: UInt32(frames))
        XCTAssertNil(preparation.output)

        // ...but every buffer was pre-silenced first, so stale memory cannot leak.
        for pointer in pointers {
            XCTAssertEqual(Array(UnsafeBufferPointer(start: pointer, count: frames)), [Float](repeating: 0, count: frames))
        }
    }

    func testPrepareKeepsStereoContractAndWritesRequestedFrameCount() {
        let frames = 32
        let (pointers, list) = makeBufferList(channelBuffers: 2, frames: frames * 2, fill: 5)
        defer { destroyBufferList(pointers, list, frames: frames * 2) }

        let preparation = StereoCallbackBridge.prepare(ioData: list, requestedFrames: UInt32(frames))
        XCTAssertEqual(preparation.status, noErr)
        XCTAssertEqual(preparation.output?.frameCount, frames)
        XCTAssertTrue(preparation.output?.left == pointers[0])
        XCTAssertTrue(preparation.output?.right == pointers[1])

        // Buffers were zeroed up to capacity before returning the stereo pair.
        for pointer in pointers {
            XCTAssertEqual(
                Array(UnsafeBufferPointer(start: pointer, count: frames)),
                [Float](repeating: 0, count: frames),
                "first \(frames) samples must be pre-silenced"
            )
            XCTAssertEqual(
                Array(UnsafeBufferPointer(start: pointer.advanced(by: frames), count: frames)),
                [Float](repeating: 5, count: frames),
                "samples beyond the requested window stay untouched"
            )
        }
    }

    func testCleanupDispositionPreservesCorrectLifecycleSemantics() {
        XCTAssertEqual(
            CoreAudioIOCleanup.disposition(uninitializeStatus: kAudioHardwareBadObjectError, disposeStatus: kAudioHardwareBadObjectError),
            CoreAudioIOCleanupDisposition(shouldRemoveContext: true, error: nil)
        )
        XCTAssertFalse(CoreAudioIOCleanup.disposition(uninitializeStatus: noErr, disposeStatus: -50).shouldRemoveContext)
    }

    func testDefaultOutputObservationOnlyPublishesMissingForGenuineUnknownOutput() {
        let valid = OutputDeviceDescriptor(
            id: .init(1), uid: "built-in", name: "Built-in", transport: "built-in",
            channelLabels: nil, outputChannelCount: 2, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )

        XCTAssertEqual(
            DefaultOutputObservationDecision.make(from: .success(valid)),
            .output(valid)
        )
        XCTAssertEqual(
            DefaultOutputObservationDecision.make(from: .failure(AudioRuntimeError.noOutputDevice)),
            .missing
        )
        XCTAssertEqual(
            DefaultOutputObservationDecision.make(from: .failure(AudioRuntimeError.deviceLost)),
            .retainLastValid
        )
    }

    private func forRenderStatus(_ status: OSStatus) -> AudioCaptureVerificationEvent {
        AudioCaptureVerificationPolicy.event(forRenderStatus: status)
    }
}
