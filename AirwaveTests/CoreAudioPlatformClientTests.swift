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
        let zeros = [Float](repeating: 0, count: CaptureSignalPolicy.windowFrames)
        XCTAssertFalse(zeros.withUnsafeBufferPointer { policy.observe(channel: $0.baseAddress!, frameCount: $0.count) })
        XCTAssertFalse(policy.hasDetectedSignal)

        var spike = zeros
        spike[0] = 1
        XCTAssertFalse(spike.withUnsafeBufferPointer { policy.observe(channel: $0.baseAddress!, frameCount: $0.count) })

        let nonFinite = [Float](repeating: .infinity, count: CaptureSignalPolicy.windowFrames)
        var fresh = CaptureSignalPolicy()
        XCTAssertFalse(nonFinite.withUnsafeBufferPointer { fresh.observe(channel: $0.baseAddress!, frameCount: $0.count) })
        XCTAssertFalse(fresh.hasDetectedSignal)
    }

    func testCaptureSignalPolicyAcceptsSustainedLowLevelSignalOnce() {
        var policy = CaptureSignalPolicy()
        let signal = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.windowFrames)

        let detected = signal.withUnsafeBufferPointer {
            policy.observe(channel: $0.baseAddress!, frameCount: $0.count)
        }
        XCTAssertTrue(detected)
        XCTAssertTrue(policy.hasDetectedSignal)
        XCTAssertTrue(signal.withUnsafeBufferPointer {
            policy.observe(channel: $0.baseAddress!, frameCount: $0.count)
        })
    }

    private func makeOccupancyVector(activeCount: Int) -> [Float] {
        precondition(activeCount <= CaptureSignalPolicy.windowFrames)
        var vector = [Float](repeating: 0, count: CaptureSignalPolicy.windowFrames)
        for index in 0..<activeCount {
            vector[index] = CaptureSignalPolicy.sampleThreshold * 2
        }
        return vector
    }

    private func observeVector(_ vector: [Float], policy: inout CaptureSignalPolicy) -> Bool {
        vector.withUnsafeBufferPointer { policy.observe(channel: $0.baseAddress!, frameCount: $0.count) }
    }

    private func observeChunks(_ chunks: [[Float]], policy: inout CaptureSignalPolicy) -> Bool {
        var result = false
        for chunk in chunks {
            chunk.withUnsafeBufferPointer {
                result = policy.observe(channel: $0.baseAddress!, frameCount: $0.count)
            }
            if result { return true }
        }
        return result
    }

    private func splitIntoChunks(_ vector: [Float], sizes: [Int]) -> [[Float]] {
        var chunks: [[Float]] = []
        var offset = 0
        var sizeIndex = 0
        while offset < vector.count {
            let size = min(sizes[sizeIndex % sizes.count], vector.count - offset)
            chunks.append(Array(vector[offset..<(offset + size)]))
            offset += size
            sizeIndex += 1
        }
        return chunks
    }

    private func sineTone(frequency: Double, sampleRate: Double, frameCount: Int, peak: Float) -> [Float] {
        (0..<frameCount).map { frame in
            peak * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
        }
    }

    func testCaptureSignalPolicyBoundaryUnderFullWindow() {
        for activeCount in [0, 1, CaptureSignalPolicy.minimumActiveFrames - 1] {
            var policy = CaptureSignalPolicy()
            let vector = makeOccupancyVector(activeCount: activeCount)
            XCTAssertFalse(observeVector(vector, policy: &policy), "\(activeCount) active frames must reject")
            XCTAssertFalse(policy.hasDetectedSignal)
        }
    }

    func testCaptureSignalPolicyPartialWindowNeverAccepts() {
        var policy = CaptureSignalPolicy()
        let active = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.windowFrames - 1)
        XCTAssertFalse(active.withUnsafeBufferPointer {
            policy.observe(channel: $0.baseAddress!, frameCount: $0.count)
        })
        XCTAssertFalse(policy.hasDetectedSignal)
    }

    func testCaptureSignalPolicyEmptyCallbackNeverAccepts() {
        var policy = CaptureSignalPolicy()
        let active = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.windowFrames)
        XCTAssertFalse(active.withUnsafeBufferPointer {
            policy.observe(channel: $0.baseAddress!, frameCount: 0)
        })
        XCTAssertFalse(policy.hasDetectedSignal)
    }

    func testCaptureSignalPolicyAcceptsBoundaryCounts() {
        for activeCount in [CaptureSignalPolicy.minimumActiveFrames, CaptureSignalPolicy.minimumActiveFrames + 1, CaptureSignalPolicy.windowFrames] {
            var policy = CaptureSignalPolicy()
            let vector = makeOccupancyVector(activeCount: activeCount)
            XCTAssertTrue(observeVector(vector, policy: &policy), "\(activeCount) active frames must accept")
            XCTAssertTrue(policy.hasDetectedSignal)
        }
    }

    func testCaptureSignalPolicyThresholdEdges() {
        let threshold = CaptureSignalPolicy.sampleThreshold
        let window = CaptureSignalPolicy.windowFrames
        var cases: [(samples: [Float], expectAccept: Bool, name: String)] = [
            ([Float](repeating: threshold, count: window), true, "positive threshold"),
            ([Float](repeating: -threshold, count: window), true, "negative threshold"),
            ([Float](repeating: threshold.nextDown, count: window), false, "below threshold"),
            ([Float](repeating: .nan, count: window), false, "NaN"),
            ([Float](repeating: -.infinity, count: window), false, "negative infinity"),
        ]
        for index in 0..<window {
            var mixed = [Float](repeating: 0, count: window)
            mixed[index] = (index % 2 == 0) ? .nan : .infinity
            cases.append((mixed, false, "non-finite at \(index)"))
            if index >= 8 { break }
        }
        for testCase in cases {
            var policy = CaptureSignalPolicy()
            XCTAssertEqual(observeVector(testCase.samples, policy: &policy), testCase.expectAccept, testCase.name)
            XCTAssertEqual(policy.hasDetectedSignal, testCase.expectAccept, testCase.name)
        }
    }

    /// A sine peak just above threshold does not imply 50% occupancy: verify
    /// the active fraction math on DC-quality input instead. Full-scale 1 kHz
    /// at 48 kHz stays active except near zero crossings; a near-threshold
    /// peak sine stays mostly inactive and must reject.
    func testCaptureSignalPolicyTonesMatchOccupancyMath() {
        var loudPolicy = CaptureSignalPolicy()
        let loudTone = sineTone(frequency: 1_000, sampleRate: 48_000, frameCount: CaptureSignalPolicy.windowFrames, peak: 0.5)
        let loudActive = loudTone.filter { abs($0) >= CaptureSignalPolicy.sampleThreshold }.count
        XCTAssertGreaterThanOrEqual(loudActive, CaptureSignalPolicy.minimumActiveFrames)
        XCTAssertTrue(observeVector(loudTone, policy: &loudPolicy))

        var quietPolicy = CaptureSignalPolicy()
        let quietTone = sineTone(frequency: 1_000, sampleRate: 48_000, frameCount: CaptureSignalPolicy.windowFrames, peak: CaptureSignalPolicy.sampleThreshold * 1.1)
        let quietActive = quietTone.filter { abs($0) >= CaptureSignalPolicy.sampleThreshold }.count
        XCTAssertLessThan(quietActive, CaptureSignalPolicy.minimumActiveFrames)
        XCTAssertFalse(observeVector(quietTone, policy: &quietPolicy))

        for sampleRate in [44_100.0, 48_000.0] {
            for frequency in [55.0, 1_000.0] {
                var policy = CaptureSignalPolicy()
                let tone = sineTone(frequency: frequency, sampleRate: sampleRate, frameCount: CaptureSignalPolicy.windowFrames, peak: 0.5)
                XCTAssertTrue(observeVector(tone, policy: &policy), "\(frequency) Hz at \(sampleRate) Hz must accept")
            }
        }
    }

    func testCaptureSignalPolicyResultIgnoresCallbackPartitioning() {
        let accept = makeOccupancyVector(activeCount: CaptureSignalPolicy.minimumActiveFrames)
        let reject = makeOccupancyVector(activeCount: CaptureSignalPolicy.minimumActiveFrames - 1)
        let partitions: [[Int]] = [[64], [300], [512], [4_096], [64, 300, 512, 1_000]]
        for sizes in partitions {
            var acceptPolicy = CaptureSignalPolicy()
            XCTAssertTrue(observeChunks(splitIntoChunks(accept, sizes: sizes), policy: &acceptPolicy), "partition \(sizes) must accept")
            var rejectPolicy = CaptureSignalPolicy()
            XCTAssertFalse(observeChunks(splitIntoChunks(reject, sizes: sizes), policy: &rejectPolicy), "partition \(sizes) must reject")
        }
    }

    func testCaptureSignalPolicyRejectsTwiceThenAcceptsInSequence() {
        var policy = CaptureSignalPolicy()
        let reject = makeOccupancyVector(activeCount: CaptureSignalPolicy.minimumActiveFrames - 1)
        let combined = reject + reject + makeOccupancyVector(activeCount: CaptureSignalPolicy.minimumActiveFrames)
        var acceptedAt: Int?
        var offset = 0
        for chunk in splitIntoChunks(combined, sizes: [4_096]) {
            let accepted = chunk.withUnsafeBufferPointer {
                policy.observe(channel: $0.baseAddress!, frameCount: $0.count)
            }
            offset += chunk.count
            if accepted {
                acceptedAt = offset
                break
            }
        }
        XCTAssertEqual(acceptedAt, CaptureSignalPolicy.windowFrames * 3)
        XCTAssertTrue(policy.hasDetectedSignal)
        // A later observed window never merges with an earlier rejected one:
        // two individually rejected halves are still rejected when observed
        // as one window each.
        var halfPolicy = CaptureSignalPolicy()
        let half = CaptureSignalPolicy.windowFrames / 2
        let firstHalf = Array(reject.prefix(half))
        let secondHalf = Array(reject.suffix(half))
        XCTAssertFalse(observeChunks([firstHalf], policy: &halfPolicy))
        XCTAssertFalse(observeChunks([secondHalf], policy: &halfPolicy))
    }

    func testCaptureSignalPolicyNeverMergesChannels() {
        // Each channel stays below the occupancy limit alone; occupancy is
        // per channel and must not combine across channels.
        let quarter = CaptureSignalPolicy.windowFrames / 4
        var first = CaptureSignalPolicy()
        var second = CaptureSignalPolicy()
        let firstVector = makeOccupancyVector(activeCount: quarter)
        let secondVector = [Float](repeating: 0, count: CaptureSignalPolicy.windowFrames - quarter)
            + [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: quarter)
        XCTAssertFalse(observeVector(firstVector, policy: &first))
        XCTAssertFalse(observeVector(secondVector, policy: &second))
        XCTAssertFalse(first.hasDetectedSignal)
        XCTAssertFalse(second.hasDetectedSignal)
    }

    func testVerificationStateDetectsSignalOnAnySingleChannelOfEight() {
        var state = CoreAudioIOVerificationState(inputChannelCount: 8)
        let quiet = [Float](repeating: 0, count: CaptureSignalPolicy.windowFrames)
        // Sustained signal only on channel 8 (index 7); others stay quiet.
        let loud = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.windowFrames)

        quiet.withUnsafeBufferPointer { quietPointer in
            loud.withUnsafeBufferPointer { loudPointer in
                let channels: [UnsafePointer<Float>?] = {
                    var values = Array(repeating: quietPointer.baseAddress!, count: 8)
                    values[7] = loudPointer.baseAddress!
                    return values
                }()
                channels.withUnsafeBufferPointer { channelPointers in
                    let event = state.observeSignal(
                        inputChannels: channelPointers.baseAddress!,
                        inputChannelCount: 8,
                        frameCount: CaptureSignalPolicy.windowFrames
                    )
                    XCTAssertEqual(event, .signalDetected)
                    // One event only: later callbacks repeat nothing.
                    let repeatEvent = state.observeSignal(
                        inputChannels: channelPointers.baseAddress!,
                        inputChannelCount: 8,
                        frameCount: CaptureSignalPolicy.windowFrames
                    )
                    XCTAssertNil(repeatEvent)
                }
            }
        }
    }

    func testVerificationStateStaysSilentWhenOnlyOneChannelSpikes() {
        var state = CoreAudioIOVerificationState(inputChannelCount: 4)
        let quiet = [Float](repeating: 0, count: CaptureSignalPolicy.windowFrames)
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
                        frameCount: CaptureSignalPolicy.windowFrames
                    )
                    XCTAssertNil(event)
                }
            }
        }
    }

    private func observeStateChannels(
        _ state: inout CoreAudioIOVerificationState,
        channels: [UnsafePointer<Float>?],
        frameCount: Int
    ) -> AudioCaptureVerificationEvent? {
        channels.withUnsafeBufferPointer { channelPointers in
            state.observeSignal(
                inputChannels: channelPointers.baseAddress!,
                inputChannelCount: channels.count,
                frameCount: frameCount
            )
        }
    }

    func testVerificationStateRejectsSparseSpikesAcrossAllChannels() {
        var state = CoreAudioIOVerificationState(inputChannelCount: 8)
        let window = CaptureSignalPolicy.windowFrames
        // Eight sparse spikes spread across all channels: each channel still
        // observes far below the occupancy limit, so nothing verifies.
        var sparse = [Float](repeating: 0, count: window)
        for channel in 0..<8 {
            sparse[channel * 100] = 1
        }
        let event = sparse.withUnsafeBufferPointer { sparsePointer in
            let channels = [UnsafePointer<Float>?](repeating: sparsePointer.baseAddress!, count: 8)
            return observeStateChannels(&state, channels: channels, frameCount: window)
        }
        XCTAssertNil(event)
    }

    func testVerificationStateMissingChannelGapDoesNotBridgePartialWindow() {
        // First call leaves a partial window: 1,024 quiet frames plus a
        // trailing run of 512 active frames (1,536 observed, 512 active).
        // A 512-frame nil gap completes that window as mostly inactive, so
        // it rejects. A later 1,536-frame fully active run then starts a
        // fresh partial window and stays unverified. Without gap
        // advancement, the stale trailing run would merge with the later
        // actives (512 + 1,536 = 2,048 consecutive) and wrongly accept.
        var state = CoreAudioIOVerificationState(inputChannelCount: 1)
        let first = [Float](repeating: 0, count: 1_024)
            + [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: 512)
        XCTAssertNil(first.withUnsafeBufferPointer { pointer in
            observeStateChannels(&state, channels: [pointer.baseAddress!], frameCount: first.count)
        })
        let gap: AudioCaptureVerificationEvent? = withUnsafePointer(to: Optional<UnsafePointer<Float>>.none) { nilPointer in
            state.observeSignal(
                inputChannels: nilPointer,
                inputChannelCount: 1,
                frameCount: 512
            )
        }
        XCTAssertNil(gap)
        let later = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: 1_536)
        XCTAssertNil(later.withUnsafeBufferPointer { pointer in
            observeStateChannels(&state, channels: [pointer.baseAddress!], frameCount: later.count)
        })
        // The state still works: a further full active window accepts.
        let loud = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.windowFrames)
        XCTAssertEqual(loud.withUnsafeBufferPointer { pointer in
            observeStateChannels(&state, channels: [pointer.baseAddress!], frameCount: loud.count)
        }, .signalDetected)
    }

    func testVerificationStateFreshStateAfterRestartDetectsAgain() {
        let loud = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.windowFrames)
        var first = CoreAudioIOVerificationState(inputChannelCount: 2)
        let firstEvent = loud.withUnsafeBufferPointer { pointer in
            observeStateChannels(&first, channels: [pointer.baseAddress!, pointer.baseAddress!], frameCount: loud.count)
        }
        XCTAssertEqual(firstEvent, .signalDetected)
        var restarted = CoreAudioIOVerificationState(inputChannelCount: 2)
        let secondEvent = loud.withUnsafeBufferPointer { pointer in
            observeStateChannels(&restarted, channels: [pointer.baseAddress!, pointer.baseAddress!], frameCount: loud.count)
        }
        XCTAssertEqual(secondEvent, .signalDetected)
    }

    func testSignalReportDoesNotSuppressLaterRenderFailureReport() {
        var state = CoreAudioIOVerificationState(inputChannelCount: 2)
        let signal = [Float](repeating: CaptureSignalPolicy.sampleThreshold * 2, count: CaptureSignalPolicy.windowFrames)

        let signalEvent = signal.withUnsafeBufferPointer { signalPointer in
            let channels: [UnsafePointer<Float>?] = [signalPointer.baseAddress!, nil]
            return channels.withUnsafeBufferPointer { channelPointers in
                state.observeSignal(
                    inputChannels: channelPointers.baseAddress!,
                    inputChannelCount: 2,
                    frameCount: CaptureSignalPolicy.windowFrames
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

    func testPhysicalMultiStreamOutputIsUnsupportedByProfilePolicy() {
        let output = OutputDeviceDescriptor(
            id: .init(17), uid: "multi-stream", name: "Multi-stream", transport: "USB",
            channelLabels: nil, outputChannelCount: 8, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false, outputStreamCount: 2
        )

        XCTAssertFalse(output.isSupportedProfileOutput)
        XCTAssertEqual(
            output.unsupportedProfileReason,
            "Airwave supports physical output devices with one output stream."
        )
    }

    func testUnlabeledStandardWidthsStaySupportedThroughSharedPolicy() {
        for (width, name) in [(2, "stereo"), (4, "quad fallback"), (6, "5.1"), (8, "7.1"), (12, "7.1.4"), (16, "16ch")] {
            let output = OutputDeviceDescriptor(
                id: .init(UInt64(100 + width)), uid: "unlabeled-\(width)", name: "Unlabeled \(name)", transport: "USB",
                channelLabels: nil, outputChannelCount: width, nominalSampleRate: 48_000,
                isVirtual: false, isAggregate: false
            )
            XCTAssertTrue(output.isSupportedProfileOutput, "width \(width)")
            XCTAssertNil(output.unsupportedProfileReason, "width \(width)")
        }
    }

    func testOtherWidthsNeedCompleteUsableLabels() {
        let mapped = OutputDeviceDescriptor(
            id: .init(101), uid: "mapped-3", name: "Mapped 3", transport: "USB",
            channelLabels: [1, 2, 3], outputChannelCount: 3, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        XCTAssertTrue(mapped.isSupportedProfileOutput)
        XCTAssertNil(mapped.unsupportedProfileReason)

        let unknown = OutputDeviceDescriptor(
            id: .init(102), uid: "unknown-3", name: "Unknown 3", transport: "USB",
            channelLabels: [1, 2, 999], outputChannelCount: 3, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        XCTAssertFalse(unknown.isSupportedProfileOutput)
        XCTAssertEqual(
            unknown.unsupportedProfileReason,
            "Airwave could not map this output layout. Change output in macOS Settings."
        )

        let wrongLength = OutputDeviceDescriptor(
            id: .init(103), uid: "wrong-length", name: "Wrong Length", transport: "USB",
            channelLabels: [1, 2], outputChannelCount: 8, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        XCTAssertFalse(wrongLength.isSupportedProfileOutput)
        XCTAssertEqual(
            wrongLength.unsupportedProfileReason,
            "Airwave could not read this output layout. Change output in macOS Settings."
        )

        let duplicatePair = OutputDeviceDescriptor(
            id: .init(104), uid: "dual-stereo", name: "Dual Stereo", transport: "USB",
            channelLabels: [1, 2, 1, 2], outputChannelCount: 4, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        XCTAssertFalse(duplicatePair.isSupportedProfileOutput)
        XCTAssertEqual(
            duplicatePair.unsupportedProfileReason,
            "Airwave could not map this output layout. Change output in macOS Settings."
        )
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

    func testDefaultOutputObservationOnlyPublishesMissingForGenuineUnknownOutput() {        let valid = OutputDeviceDescriptor(
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

    // MARK: - Plan 039 Step 1: current-device listeners (production path)

    private func plan039Descriptor(
        rate: Double = 48_000,
        channels: Int = 2,
        streams: Int = 1,
        labels: [UInt32]? = nil,
        name: String = "Built-in"
    ) -> OutputDeviceDescriptor {
        OutputDeviceDescriptor(
            id: .init(11), uid: "plan039-device", name: name, transport: "built-in",
            channelLabels: labels, outputChannelCount: channels,
            nominalSampleRate: rate, isVirtual: false, isAggregate: false,
            outputStreamCount: streams
        )
    }

    func testPlan039CurrentDeviceRecordsWatchRateStreamConfigAndLayout() {
        let records = CurrentDeviceFormatObservation.records(for: 77)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].selector, kAudioDevicePropertyNominalSampleRate)
        XCTAssertTrue(records[0].isRequired)
        XCTAssertEqual(records[1].selector, kAudioDevicePropertyStreamConfiguration)
        XCTAssertEqual(records[1].scope, kAudioObjectPropertyScopeOutput)
        XCTAssertTrue(records[1].isRequired)
        XCTAssertEqual(records[2].selector, kAudioDevicePropertyPreferredChannelLayout)
        XCTAssertFalse(records[2].isRequired, "optional layout absence uses plan 038 fallback, not failure")
        XCTAssertTrue(records.allSatisfy { $0.deviceID == 77 })
    }

    func testPlan039ListenerSetBindAndUnbindAreBalanced() {
        var added = 0
        var removed = 0
        let set = CurrentDeviceListenerSet(add: { _, _ in added += 1; return noErr }, remove: { _, _ in removed += 1; return noErr })
        XCTAssertNoThrow(try set.bind(deviceID: 5, seed: plan039Descriptor()))
        XCTAssertEqual(added, 3)
        XCTAssertEqual(set.installedCount, 3)
        set.unbind()
        XCTAssertEqual(removed, 3)
        XCTAssertEqual(set.installedCount, 0)
        let removedAfterFirstStop = removed
        set.unbind()
        XCTAssertEqual(removed, removedAfterFirstStop, "repeated stop removes nothing further")
    }

    func testPlan039ListenerSetRequiredFailureUnwindsPartialRegistrations() {
        var added = 0
        var removed = 0
        // Fail the second (required) registration: stream configuration.
        let set = CurrentDeviceListenerSet(
            add: { _, address in added += 1; return address.mSelector == kAudioDevicePropertyStreamConfiguration ? OSStatus(-50) : noErr },
            remove: { _, _ in removed += 1; return noErr }
        )
        XCTAssertThrowsError(try set.bind(deviceID: 6))
        XCTAssertEqual(added, 2)
        XCTAssertEqual(removed, 1, "the one successful registration is removed")
        XCTAssertEqual(set.installedCount, 0)
    }

    func testPlan039ListenerSetOptionalLayoutFailureKeepsRequiredListeners() {
        let set = CurrentDeviceListenerSet(
            add: { _, address in address.mSelector == kAudioDevicePropertyPreferredChannelLayout ? OSStatus(-50) : noErr },
            remove: { _, _ in noErr }
        )
        XCTAssertNoThrow(try set.bind(deviceID: 7, seed: plan039Descriptor()))
        XCTAssertEqual(set.installedCount, 2)
        XCTAssertTrue(set.installed.allSatisfy { $0.isRequired })
    }

    func testPlan039ListenerSetReplacementRemovesOldDeviceBeforeBindingNew() {
        var removedDevices: [AudioObjectID] = []
        let set = CurrentDeviceListenerSet(
            add: { _, _ in noErr },
            remove: { device, _ in removedDevices.append(device); return noErr }
        )
        XCTAssertNoThrow(try set.bind(deviceID: 8, seed: plan039Descriptor()))
        XCTAssertNoThrow(try set.bind(deviceID: 9, seed: plan039Descriptor()))
        XCTAssertEqual(removedDevices, [8, 8, 8], "old device registrations removed before new bind")
        XCTAssertTrue(set.installed.allSatisfy { $0.deviceID == 9 })
    }

    func testPlan039ListenerSetGenerationGuardsAndSuppressesUnchangedEvents() {
        let set = CurrentDeviceListenerSet(add: { _, _ in noErr }, remove: { _, _ in noErr })
        let seed = plan039Descriptor()
        XCTAssertNoThrow(try set.bind(deviceID: 10, seed: seed))
        let generation = set.generation
        XCTAssertFalse(
            set.shouldDeliver(plan039Descriptor(rate: 44_100), eventGeneration: generation &+ 99),
            "stale generation must not deliver"
        )
        XCTAssertFalse(
            set.shouldDeliver(seed, eventGeneration: generation),
            "unchanged values must not restart audio"
        )
        XCTAssertFalse(
            set.shouldDeliver(plan039Descriptor(name: "Renamed"), eventGeneration: generation),
            "identity-only change must not restart audio"
        )
        XCTAssertTrue(
            set.shouldDeliver(plan039Descriptor(rate: 44_100), eventGeneration: generation),
            "same-ID rate change reaches the descriptor path"
        )
        XCTAssertFalse(
            set.shouldDeliver(plan039Descriptor(rate: 44_100), eventGeneration: generation),
            "duplicate of the delivered descriptor coalesces"
        )
        XCTAssertTrue(
            set.shouldDeliver(plan039Descriptor(channels: 6, labels: [1, 2, 3, 4, 5, 6]), eventGeneration: generation),
            "width change reaches the descriptor path"
        )
    }

    func testPlan039ListenerSetFirstReadAfterBindDeliversAndStopCancelsStale() {
        let set = CurrentDeviceListenerSet(add: { _, _ in noErr }, remove: { _, _ in noErr })
        XCTAssertNoThrow(try set.bind(deviceID: 12))
        let generation = set.generation
        XCTAssertTrue(
            set.shouldDeliver(plan039Descriptor(), eventGeneration: generation),
            "first read after bind has no seed and must deliver"
        )
        set.unbind()
        XCTAssertFalse(
            set.shouldDeliver(plan039Descriptor(rate: 44_100), eventGeneration: generation),
            "events tied to the pre-stop generation are ignored after stop"
        )
    }

    func testPlan039DescriptorFormatChangeComparesProcessingFieldsOnly() {
        let base = plan039Descriptor()
        XCTAssertFalse(base.hasProcessingFormatChange(from: base))
        XCTAssertFalse(plan039Descriptor(name: "Renamed").hasProcessingFormatChange(from: base))
        XCTAssertTrue(plan039Descriptor(rate: 44_100).hasProcessingFormatChange(from: base))
        XCTAssertTrue(plan039Descriptor(channels: 6).hasProcessingFormatChange(from: base))
        XCTAssertTrue(plan039Descriptor(streams: 2).hasProcessingFormatChange(from: base))
        XCTAssertTrue(plan039Descriptor(channels: 2, labels: [1, 2]).hasProcessingFormatChange(from: base))
    }

    // MARK: - Plan 039 Step 2: bounded descriptor retries (same seam)

    private final class Plan039RetryScheduler: CurrentDeviceRetryScheduling {
        final class Task: AudioRuntimeCancellation {
            let delay: TimeInterval
            let action: () -> Void
            var cancelled = false
            init(delay: TimeInterval, action: @escaping () -> Void) {
                self.delay = delay
                self.action = action
            }
            func cancel() { cancelled = true }
            func run() { if !cancelled { action() } }
        }

        private(set) var tasks: [Task] = []
        var delays: [TimeInterval] { tasks.map(\.delay) }
        var pendingCount: Int { tasks.filter { !$0.cancelled }.count }

        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> AudioRuntimeCancellation {
            let task = Task(delay: delay, action: action)
            tasks.append(task)
            return task
        }

        func runNext() {
            guard let index = tasks.firstIndex(where: { !$0.cancelled }) else { return }
            tasks[index].run()
        }

        func runAll() {
            while tasks.contains(where: { !$0.cancelled }) { runNext() }
        }
    }

    private func plan039BoundSet(
        read: @escaping CurrentDeviceListenerSet.ReadDescriptor,
        scheduler: Plan039RetryScheduler
    ) -> CurrentDeviceListenerSet {
        CurrentDeviceListenerSet(
            add: { _, _ in noErr },
            remove: { _, _ in noErr },
            read: read,
            scheduler: scheduler
        )
    }

    func testPlan039RetryDelaysAreBoundedAtThreeAttempts() {
        XCTAssertEqual(CurrentDeviceDescriptorRetry.delays, [0.1, 0.25, 1.0])
    }

    func testPlan039RetrySuccessCoalescesBurstsAndClearsPending() {
        let scheduler = Plan039RetryScheduler()
        var reads = 0
        let set = plan039BoundSet(read: { _ in reads += 1; return .failure(AudioRuntimeError.deviceLost) }, scheduler: scheduler)
        XCTAssertNoThrow(try set.bind(deviceID: 20, seed: plan039Descriptor()))
        let generation = set.generation
        var delivered: [OutputDeviceDescriptor] = []
        var missing = 0
        XCTAssertTrue(set.noteTransientReadFailure(
            for: 20, eventGeneration: generation,
            onOutput: { delivered.append($0) }, onMissing: { missing += 1 }
        ))
        // A burst before the control read executes: one pending token only.
        set.coalescePendingRetry(for: 20, eventGeneration: generation)
        XCTAssertTrue(set.noteTransientReadFailure(
            for: 20, eventGeneration: generation,
            onOutput: { delivered.append($0) }, onMissing: { missing += 1 }
        ))
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertTrue(set.hasPendingRetry)
        scheduler.runNext()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(scheduler.delays, [0.1, 0.25])
        XCTAssertEqual(scheduler.pendingCount, 1, "second delay armed after the first failure")
        XCTAssertEqual(delivered.count, 0)
        XCTAssertEqual(missing, 0)
    }

    func testPlan039RetryDelayedReadabilityDeliversOnce() {
        let scheduler = Plan039RetryScheduler()
        var reads = 0
        let changed = plan039Descriptor(rate: 44_100)
        let set = plan039BoundSet(read: { _ in
            reads += 1
            return reads < 2 ? .failure(AudioRuntimeError.deviceLost) : .success(changed)
        }, scheduler: scheduler)
        XCTAssertNoThrow(try set.bind(deviceID: 21, seed: plan039Descriptor()))
        let generation = set.generation
        var delivered: [OutputDeviceDescriptor] = []
        var missing = 0
        XCTAssertTrue(set.noteTransientReadFailure(
            for: 21, eventGeneration: generation,
            onOutput: { delivered.append($0) }, onMissing: { missing += 1 }
        ))
        scheduler.runNext()
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(set.hasPendingRetry)
        scheduler.runNext()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(delivered, [changed])
        XCTAssertEqual(missing, 0)
        XCTAssertFalse(set.hasPendingRetry)
        XCTAssertEqual(set.pendingRetryAttempt, 0)
        // The delivered descriptor is now the baseline: a duplicate coalesces.
        XCTAssertFalse(set.shouldDeliver(changed, eventGeneration: generation))
    }

    func testPlan039RetryExhaustionPublishesUnavailableOnce() {
        let scheduler = Plan039RetryScheduler()
        var reads = 0
        let set = plan039BoundSet(read: { _ in reads += 1; return .failure(AudioRuntimeError.deviceLost) }, scheduler: scheduler)
        XCTAssertNoThrow(try set.bind(deviceID: 22, seed: plan039Descriptor()))
        let generation = set.generation
        var delivered = 0
        var missing = 0
        XCTAssertTrue(set.noteTransientReadFailure(
            for: 22, eventGeneration: generation,
            onOutput: { _ in delivered += 1 }, onMissing: { missing += 1 }
        ))
        scheduler.runAll()
        XCTAssertEqual(reads, 3, "three bounded attempts after the initial failure")
        XCTAssertEqual(scheduler.delays, [0.1, 0.25, 1.0])
        XCTAssertEqual(missing, 1, "unavailable publishes once through the established handler")
        XCTAssertEqual(delivered, 0)
        XCTAssertFalse(set.hasPendingRetry)
    }

    func testPlan039RetryOptionalMetadataUnavailableStillDelivers() {
        // Nil channel labels mean unreadable layout metadata: the descriptor
        // is delivered with the plan 038 count fallback, not treated as a
        // transient failure.
        let scheduler = Plan039RetryScheduler()
        let unlabeled = plan039Descriptor(rate: 44_100, channels: 2, labels: nil)
        let set = plan039BoundSet(read: { _ in .success(unlabeled) }, scheduler: scheduler)
        XCTAssertNoThrow(try set.bind(deviceID: 23, seed: plan039Descriptor()))
        let generation = set.generation
        XCTAssertTrue(set.shouldDeliver(unlabeled, eventGeneration: generation))
        XCTAssertFalse(set.hasPendingRetry, "a readable descriptor never arms a retry")
    }

    func testPlan039RetryStopCancelsPendingAndStaleCallbackHasNoEffect() {
        let scheduler = Plan039RetryScheduler()
        var reads = 0
        var delivered = 0
        var missing = 0
        let set = plan039BoundSet(read: { _ in reads += 1; return .failure(AudioRuntimeError.deviceLost) }, scheduler: scheduler)
        XCTAssertNoThrow(try set.bind(deviceID: 24, seed: plan039Descriptor()))
        let generation = set.generation
        XCTAssertTrue(set.noteTransientReadFailure(
            for: 24, eventGeneration: generation,
            onOutput: { _ in delivered += 1 }, onMissing: { missing += 1 }
        ))
        XCTAssertTrue(set.hasPendingRetry)
        set.unbind()
        XCTAssertFalse(set.hasPendingRetry, "stop clears the pending token")
        scheduler.runAll()
        XCTAssertEqual(reads, 0, "the cancelled token never reads")
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(missing, 0)
        XCTAssertFalse(set.shouldDeliver(plan039Descriptor(rate: 44_100), eventGeneration: generation))
    }

    func testPlan039RetryNewerIdentityCancelsStaleChain() {
        let scheduler = Plan039RetryScheduler()
        var reads = 0
        var delivered: [OutputDeviceDescriptor] = []
        var missing = 0
        let set = plan039BoundSet(read: { _ in reads += 1; return .failure(AudioRuntimeError.deviceLost) }, scheduler: scheduler)
        XCTAssertNoThrow(try set.bind(deviceID: 25, seed: plan039Descriptor()))
        let oldGeneration = set.generation
        XCTAssertTrue(set.noteTransientReadFailure(
            for: 25, eventGeneration: oldGeneration,
            onOutput: { delivered.append($0) }, onMissing: { missing += 1 }
        ))
        XCTAssertTrue(set.hasPendingRetry)
        // A newer device identity rebinds (bind cancels via unbind).
        XCTAssertNoThrow(try set.bind(deviceID: 26, seed: plan039Descriptor()))
        XCTAssertFalse(set.hasPendingRetry, "newer identity cancels the old retry chain")
        scheduler.runAll()
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(missing, 0)
        // A stale callback for the old generation is ignored.
        XCTAssertFalse(set.shouldDeliver(plan039Descriptor(rate: 44_100), eventGeneration: oldGeneration))
    }
}
