import CoreAudio
import XCTest
@testable import Airwave

final class InputLayoutResolutionTests: XCTestCase {
    func testDetectEightChannelsYieldsStandardSevenOneOrder() {
        // Order is a contract: it is the fallback mapping for unlabeled devices.
        XCTAssertEqual(
            InputLayout.detect(channelCount: 8).channels,
            [.FL, .FR, .FC, .LFE, .BL, .BR, .SL, .SR]
        )
    }

    func testLabeledSevenOneDeviceResolvesInLabelOrder() {
        // Raw kAudioChannelLabel values: L, R, C, LFE, Rls, Rrs, Lrs, Rrs.
        let labels: [UInt32] = [1, 2, 3, 4, 10, 11, 10, 11]
        let layout = InputLayoutResolver.layout(channelLabels: labels, channelCount: 8)
        XCTAssertEqual(
            layout.channels,
            [.FL, .FR, .FC, .LFE, .BL, .BR, .BL, .BR]
        )
        XCTAssertEqual(layout.name, "Device layout")
    }

    func testLabeledFiveOneDeviceResolvesInLabelOrder() {
        let labels: [UInt32] = [3, 1, 2, 4, 10, 11]
        let layout = InputLayoutResolver.layout(channelLabels: labels, channelCount: 6)
        XCTAssertEqual(
            layout.channels,
            [.FC, .FL, .FR, .LFE, .BL, .BR]
        )
    }

    func testUnknownLabelFallsBackToCountDetection() {
        let labels: [UInt32] = [1, 2, 999]
        let resolved = InputLayoutResolver.resolve(channelLabels: labels, channelCount: 3)
        guard case .unsupported = resolved else {
            return XCTFail("unknown label must stay unsupported, not mono fold-down")
        }
        let layout = InputLayoutResolver.layout(channelLabels: labels, channelCount: 3)
        XCTAssertEqual(
            layout.channels,
            [.custom("Ch0"), .custom("Ch1"), .custom("Ch2")]
        )
    }

    func testAllUnknownOrUnusedStereoLabelsFallBackToStereo() {
        // Built-in stereo devices (MacBook speakers, External Headphones)
        // report UseChannelDescriptions with every label Unknown
        // (0xFFFFFFFF). That is "no mapping supplied", not an unmappable
        // layout: count fallback keeps stereo engaged. All-Unused (0)
        // behaves the same. A mixed known+unknown row stays unsupported.
        for labels in [[UInt32]([0xFFFF_FFFF, 0xFFFF_FFFF]), [UInt32]([0, 0])] {
            let resolved = InputLayoutResolver.resolve(channelLabels: labels, channelCount: 2)
            XCTAssertEqual(resolved, .supported(.stereo), "labels \(labels) must fall back to stereo")
            XCTAssertEqual(
                InputLayoutResolver.layout(channelLabels: labels, channelCount: 2).channels,
                [.FL, .FR]
            )
            let descriptor = OutputDeviceDescriptor(
                id: .init(44), uid: "builtin-stereo", name: "Built-in", transport: "Built-in",
                channelLabels: labels, outputChannelCount: 2, nominalSampleRate: 48_000,
                isVirtual: false, isAggregate: false
            )
            XCTAssertTrue(descriptor.isSupportedProfileOutput)
            XCTAssertNil(descriptor.unsupportedProfileReason)
        }
        let mixed = OutputDeviceDescriptor(
            id: .init(43), uid: "mixed", name: "Mixed", transport: "Built-in",
            channelLabels: [1, 0xFFFF_FFFF], outputChannelCount: 2, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        XCTAssertFalse(mixed.isSupportedProfileOutput)
        XCTAssertNotNil(mixed.unsupportedProfileReason)
    }

    func testStereoTagVariantsMapToStereoEars() {
        // Real devices may report MatrixStereo (Lt/Rt = labels 38/39),
        // StereoHeadphones (labels 301/302), or Binaural (labels 208/209)
        // instead of plain Left/Right (1/2). All are a stereo ear pair.
        // Labels verified against CoreAudioBaseTypes.h; Mono (42) folds center.
        for labels in [[UInt32]([38, 39]), [UInt32]([301, 302]), [UInt32]([208, 209])] {
            let resolved = InputLayoutResolver.resolve(channelLabels: labels, channelCount: 2)
            guard case .supported(let layout) = resolved else {
                return XCTFail("stereo tag labels \(labels) must stay supported")
            }
            XCTAssertEqual(layout.channels, [.FL, .FR])
        }
        // [LeftTotal, RightTotal] duplicates FL/FR counts like the dual
        // stereo-pair shape, so it stays unsupported (ambiguous) with this
        // speaker model. No silent fold of a matrix pair into rear speakers.
        let matrixQuad = InputLayoutResolver.resolve(channelLabels: [38, 38, 39, 39], channelCount: 4)
        guard case .unsupported = matrixQuad else {
            return XCTFail("matrix quad duplicates FL/FR counts; must stay unsupported")
        }
        let mono = InputLayoutResolver.resolve(channelLabels: [42, 42], channelCount: 2)
        guard case .supported(let monoLayout) = mono else {
            return XCTFail("dual-mono labels must stay supported")
        }
        XCTAssertEqual(monoLayout.channels, [.FC, .FC])
    }

    func testLabelCountMismatchIsUnsupportedBeforePipelineAcquisition() {
        let labels: [UInt32] = [1, 2]
        let resolved = InputLayoutResolver.resolve(channelLabels: labels, channelCount: 8)
        guard case .unsupported = resolved else {
            return XCTFail("wrong-length labels must stay unsupported")
        }
        let layout = InputLayoutResolver.layout(channelLabels: labels, channelCount: 8)
        XCTAssertEqual(
            layout.channels,
            [.FL, .FR, .FC, .LFE, .BL, .BR, .SL, .SR]
        )
    }

    func testNilLabelsFallBackToCountDetection() {
        let layout = InputLayoutResolver.layout(channelLabels: nil, channelCount: 6)
        XCTAssertEqual(
            layout.channels,
            [.FL, .FR, .FC, .LFE, .BL, .BR]
        )
    }

    func testStereoDeviceKeepsStereoLayout() {
        let layout = InputLayoutResolver.layout(channelLabels: [1, 2], channelCount: 2)
        XCTAssertEqual(layout.channels, [.FL, .FR])
    }

    func testUnlabeledQuadUsesGenericFallbackNotVerifiedIdentity() {
        let resolved = InputLayoutResolver.resolve(channelLabels: nil, channelCount: 4)
        XCTAssertEqual(resolved, .supported(InputLayout(channels: [.FL, .FR, .BL, .BR], name: "Quad fallback")))
    }

    func testDuplicateStereoPairLabelsStayAmbiguous() {
        // Four channels can be two independent stereo pairs. Explicit
        // duplicate L/R labels must not become guessed rear speakers.
        // No quad fallback as a routing fix; pair selection is separate work.
        for labels in [[UInt32]([1, 2, 1, 2]), [1, 1, 2, 2], [2, 1, 2, 1]] {
            let resolved = InputLayoutResolver.resolve(channelLabels: labels, channelCount: 4)
            guard case .unsupported = resolved else {
                return XCTFail("duplicate stereo pair \(labels) must stay unsupported")
            }
        }
        let labeled = InputLayoutResolver.layout(channelLabels: [1, 2, 1, 2], channelCount: 4)
        XCTAssertEqual(labeled.channels, [.custom("Ch0"), .custom("Ch1"), .custom("Ch2"), .custom("Ch3")])
    }

    func testDuplicateStereoPairDescriptorIsUnsupportedAtAllConsumers() {
        let output = OutputDeviceDescriptor(
            id: .init(38), uid: "dual-stereo", name: "Dual Stereo", transport: "USB",
            channelLabels: [1, 2, 1, 2], outputChannelCount: 4, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        XCTAssertFalse(output.isSupportedProfileOutput)
        XCTAssertNotNil(output.unsupportedProfileReason)
    }

    func testDecisionTableCoversAbsentValidUnknownDuplicateWrongLength() {
        // 2ch absent/unlabeled stays supported stereo.
        XCTAssertEqual(
            InputLayoutResolver.resolve(channelLabels: nil, channelCount: 2),
            .supported(.stereo)
        )
        // 4ch valid distinct labels resolve to device order.
        XCTAssertEqual(
            InputLayoutResolver.resolve(channelLabels: [1, 2, 5, 6], channelCount: 4),
            .supported(InputLayout(channels: [.FL, .FR, .SL, .SR], name: "Device layout"))
        )
        // 6/8/12 unlabeled keep the standard fallback orders.
        XCTAssertEqual(
            InputLayoutResolver.resolve(channelLabels: nil, channelCount: 6),
            .supported(.surround51)
        )
        XCTAssertEqual(
            InputLayoutResolver.resolve(channelLabels: nil, channelCount: 8),
            .supported(.surround71)
        )
        XCTAssertEqual(
            InputLayoutResolver.resolve(channelLabels: nil, channelCount: 12),
            .supported(.atmos714)
        )
        // 16ch unlabeled stays supported through count detection.
        guard case .supported = InputLayoutResolver.resolve(channelLabels: nil, channelCount: 16) else {
            return XCTFail("unlabeled 16ch must stay supported")
        }
        // Unknown label, wrong length, and unsupported width reject.
        guard case .unsupported = InputLayoutResolver.resolve(channelLabels: [1, 2, 999], channelCount: 3) else {
            return XCTFail("unknown label must reject")
        }
        guard case .unsupported = InputLayoutResolver.resolve(channelLabels: [1, 2], channelCount: 6) else {
            return XCTFail("wrong-length labels must reject")
        }
        guard case .unsupported = InputLayoutResolver.resolve(channelLabels: nil, channelCount: 1) else {
            return XCTFail("width 1 must reject")
        }
        guard case .unsupported = InputLayoutResolver.resolve(channelLabels: nil, channelCount: 17) else {
            return XCTFail("width 17 must reject")
        }
    }

    func testSameDescriptorYieldsSameDecisionAtAllConsumers() {
        let supported = OutputDeviceDescriptor(
            id: .init(41), uid: "avr", name: "AVR", transport: "HDMI",
            channelLabels: [1, 2, 3, 4, 5, 6], outputChannelCount: 6, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        let rejected = OutputDeviceDescriptor(
            id: .init(42), uid: "odd", name: "Odd", transport: "USB",
            channelLabels: [1, 2, 999], outputChannelCount: 3, nominalSampleRate: 48_000,
            isVirtual: false, isAggregate: false
        )
        // Discovery, persistence, and runtime share isSupportedProfileOutput
        // and InputLayoutResolver.resolve; assert both objects agree here.
        XCTAssertTrue(supported.isSupportedProfileOutput)
        XCTAssertNil(supported.unsupportedProfileReason)
        XCTAssertEqual(
            InputLayoutResolver.resolve(channelLabels: supported.channelLabels, channelCount: supported.outputChannelCount),
            .supported(InputLayout(channels: [.FL, .FR, .FC, .LFE, .SL, .SR], name: "Device layout"))
        )
        XCTAssertEqual(
            InputLayoutResolver.layout(channelLabels: supported.channelLabels, channelCount: supported.outputChannelCount).channels,
            [.FL, .FR, .FC, .LFE, .SL, .SR]
        )
        XCTAssertFalse(rejected.isSupportedProfileOutput)
        XCTAssertNotNil(rejected.unsupportedProfileReason)
        guard case .unsupported = InputLayoutResolver.resolve(channelLabels: rejected.channelLabels, channelCount: rejected.outputChannelCount) else {
            return XCTFail("rejected descriptor must resolve unsupported")
        }
    }

    func testNativeTagStereoAndBitmapQuadExpandThroughPublicConversion() {
        // kAudioChannelLayoutTag_Stereo = (101<<16)|2; quad bitmap L/R/Ls/Rs.
        // Both halves replay recorded AudioFormat conversions through the
        // stub, so the test is deterministic with no host service. The
        // production tag/bitmap conversion calls stay live (nil stub) and
        // are covered by testNativeReaderRejectsMalformedSizes plus the
        // device-path tests; AudioFormat service availability is a host
        // property, not a code regression signal.
        CoreAudioPlatformClient.NativeChannelLayoutReader.convertedLayoutStub = { tag, _ in
            if tag == ((101 << 16) | 2) { return [1, 2] }
            return nil
        }
        defer { CoreAudioPlatformClient.NativeChannelLayoutReader.convertedLayoutStub = nil }
        let stereo = CoreAudioPlatformClient.NativeChannelLayoutReader.labelsFromTag((101 << 16) | 2)
        XCTAssertEqual(stereo, [1, 2])
        CoreAudioPlatformClient.NativeChannelLayoutReader.convertedLayoutStub = { _, _ in [1, 2, 5, 6] }
        let quad = CoreAudioPlatformClient.NativeChannelLayoutReader.labelsFromBitmap(.init(rawValue: (1 << 0) | (1 << 1) | (1 << 4) | (1 << 5)))
        XCTAssertEqual(quad, [1, 2, 5, 6])
    }

    func testNativeReaderRejectsMalformedSizes() {
        XCTAssertNil(CoreAudioPlatformClient.NativeChannelLayoutReader.labelsFromTag(kAudioChannelLayoutTag_Unknown))
        XCTAssertNil(CoreAudioPlatformClient.NativeChannelLayoutReader.labelsFromBitmap(.init(rawValue: 0)))
        let empty: [AudioChannelDescription] = []
        let emptyResult = empty.withUnsafeBufferPointer { pointer in
            CoreAudioPlatformClient.NativeChannelLayoutReader.labelsFromDescriptions(
                count: 0,
                descriptions: pointer.baseAddress!,
                capacityBytes: 0
            )
        }
        XCTAssertNil(emptyResult)
        let over = [AudioChannelDescription](
            repeating: AudioChannelDescription(mChannelLabel: 1, mChannelFlags: .init(rawValue: 0), mCoordinates: (0, 0, 0)),
            count: 1
        )
        let overResult = over.withUnsafeBufferPointer { pointer in
            CoreAudioPlatformClient.NativeChannelLayoutReader.labelsFromDescriptions(
                count: 2,
                descriptions: pointer.baseAddress!,
                capacityBytes: MemoryLayout<AudioChannelDescription>.stride
            )
        }
        XCTAssertNil(overResult)
        let hugeResult = over.withUnsafeBufferPointer { pointer in
            CoreAudioPlatformClient.NativeChannelLayoutReader.labelsFromDescriptions(
                count: 65,
                descriptions: pointer.baseAddress!,
                capacityBytes: 65 * MemoryLayout<AudioChannelDescription>.stride
            )
        }
        XCTAssertNil(hugeResult)
    }

    func testHeightCenterRearVariantsMapToModeledSpeakers() {
        // LeftCenter/RightCenter/CenterSurround/height/top-back labels map
        // into the existing VirtualSpeaker model instead of unknown.
        let labels: [UInt32] = [7, 8, 9, 13, 15, 16, 18]
        let layout = InputLayoutResolver.layout(channelLabels: labels, channelCount: 7)
        XCTAssertEqual(layout.channels, [.FLC, .FRC, .BC, .TFL, .TFR, .TBL, .TBR])
        guard case .supported = InputLayoutResolver.resolve(channelLabels: labels, channelCount: 7) else {
            return XCTFail("mapped height/center/rear labels must stay supported")
        }
    }

    func testFrontGainsPin() {
        XCTAssertEqual(StereoDownmixGains.gains(for: .FL).left, 0.707, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .FL).right, 0.0, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .FR).left, 0.0, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .FR).right, 0.707, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .FC).left, 0.707, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .FC).right, 0.707, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .FLC).left, 0.707, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .FRC).right, 0.707, accuracy: 1e-6)
    }

    func testLFEIsOmittedFromFoldDown() {
        XCTAssertEqual(StereoDownmixGains.gains(for: .LFE).left, 0.0, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .LFE).right, 0.0, accuracy: 1e-6)
    }

    func testSurroundGainsPin() {
        XCTAssertEqual(StereoDownmixGains.gains(for: .BL).left, 0.5, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .SL).left, 0.5, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .BR).right, 0.5, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .SR).right, 0.5, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .TFL).left, 0.5, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .TBR).right, 0.5, accuracy: 1e-6)
    }

    func testBackCenterAndCustomGainsPin() {
        XCTAssertEqual(StereoDownmixGains.gains(for: .BC).left, 0.354, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .BC).right, 0.354, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .custom("Ch7")).left, 0.354, accuracy: 1e-6)
        XCTAssertEqual(StereoDownmixGains.gains(for: .custom("Ch7")).right, 0.354, accuracy: 1e-6)
    }

    func testStereoDownmixOperationKeepsPlainStereoByteExact() {
        let left = [Float(1).nextDown, 0.5]
        let right = [Float(2).nextUp, -0.25]
        var outputLeft = [Float](repeating: .nan, count: left.count)
        var outputRight = [Float](repeating: .nan, count: right.count)

        left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                let channels: [UnsafePointer<Float>?] = [leftPointer.baseAddress!, rightPointer.baseAddress!]
                channels.withUnsafeBufferPointer { channelPointers in
                    outputLeft.withUnsafeMutableBufferPointer { leftOutput in
                        outputRight.withUnsafeMutableBufferPointer { rightOutput in
                            StereoDownmixGains.downmix(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 2,
                                inputOffset: 0,
                                inputSpeakers: [.FL, .FR],
                                outputLeft: leftOutput.baseAddress!,
                                outputRight: rightOutput.baseAddress!,
                                frameCount: left.count
                            )
                        }
                    }
                }
            }
        }

        XCTAssertEqual(outputLeft, left)
        XCTAssertEqual(outputRight, right)
    }

    func testStereoDownmixOperationFoldsFiveOneToBothEars() {
        let frames = 2
        var input = [Float](repeating: 1, count: 6 * frames)
        var outputLeft = [Float](repeating: .nan, count: frames)
        var outputRight = [Float](repeating: .nan, count: frames)
        input.withUnsafeMutableBufferPointer { inputBuffer in
            let base = UnsafePointer(inputBuffer.baseAddress!)
            let channels: [UnsafePointer<Float>?] = (0..<6).map { base.advanced(by: $0 * frames) }
            channels.withUnsafeBufferPointer { channelPointers in
                outputLeft.withUnsafeMutableBufferPointer { leftOutput in
                    outputRight.withUnsafeMutableBufferPointer { rightOutput in
                        StereoDownmixGains.downmix(
                            inputChannels: channelPointers.baseAddress!,
                            inputChannelCount: 6,
                            inputOffset: 0,
                            inputSpeakers: [.FL, .FR, .FC, .LFE, .BL, .BR],
                            outputLeft: leftOutput.baseAddress!,
                            outputRight: rightOutput.baseAddress!,
                            frameCount: frames
                        )
                    }
                }
            }
        }

        for (actual, expected) in zip(outputLeft, [Float(1.914), 1.914]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-4)
        }
        for (actual, expected) in zip(outputRight, [Float(1.914), 1.914]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-4)
        }
    }

    func testStereoDownmixOperationTreatsNilChannelsAsSilence() {
        let left = [Float(1), 2]
        let right = [Float(3), 4]
        var outputLeft = [Float](repeating: 9, count: left.count)
        var outputRight = [Float](repeating: 9, count: right.count)
        left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                let channels: [UnsafePointer<Float>?] = [leftPointer.baseAddress!, rightPointer.baseAddress!, nil]
                channels.withUnsafeBufferPointer { channelPointers in
                    outputLeft.withUnsafeMutableBufferPointer { leftOutput in
                        outputRight.withUnsafeMutableBufferPointer { rightOutput in
                            StereoDownmixGains.downmix(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 3,
                                inputOffset: 0,
                                inputSpeakers: [.FL, .FR, .FC],
                                outputLeft: leftOutput.baseAddress!,
                                outputRight: rightOutput.baseAddress!,
                                frameCount: left.count
                            )
                        }
                    }
                }
            }
        }

        for (actual, expected) in zip(outputLeft, [Float(0.707), 1.414]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-4)
        }
        for (actual, expected) in zip(outputRight, [Float(2.121), 2.828]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-4)
        }
    }

    func testReorderedStereoPairRoutesEachInputToItsNamedSide() {
        // [.FR, .FL] must not take the unity-copy path: left input is the
        // right speaker (0.707 right) and right input is the left speaker.
        let leftInput = [Float(1), 2]
        let rightInput = [Float(4), 8]
        var outputLeft = [Float](repeating: .nan, count: 2)
        var outputRight = [Float](repeating: .nan, count: 2)
        leftInput.withUnsafeBufferPointer { leftPointer in
            rightInput.withUnsafeBufferPointer { rightPointer in
                let channels: [UnsafePointer<Float>?] = [leftPointer.baseAddress!, rightPointer.baseAddress!]
                channels.withUnsafeBufferPointer { channelPointers in
                    outputLeft.withUnsafeMutableBufferPointer { leftOutput in
                        outputRight.withUnsafeMutableBufferPointer { rightOutput in
                            StereoDownmixGains.downmix(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 2,
                                inputOffset: 0,
                                inputSpeakers: [.FR, .FL],
                                outputLeft: leftOutput.baseAddress!,
                                outputRight: rightOutput.baseAddress!,
                                frameCount: 2
                            )
                        }
                    }
                }
            }
        }

        let gain = Float(0.707)
        XCTAssertEqual(outputLeft[0], 4 * gain, accuracy: 1e-4)
        XCTAssertEqual(outputLeft[1], 8 * gain, accuracy: 1e-4)
        XCTAssertEqual(outputRight[0], 1 * gain, accuracy: 1e-4)
        XCTAssertEqual(outputRight[1], 2 * gain, accuracy: 1e-4)
    }

    func testValidNonstandardPairUsesSharedSpeakerGains() {
        // [.FL, .FC]: left keeps the FL gain, right input folds center.
        let first = [Float(2), 4]
        let second = [Float(8), 16]
        var outputLeft = [Float](repeating: .nan, count: 2)
        var outputRight = [Float](repeating: .nan, count: 2)
        first.withUnsafeBufferPointer { firstPointer in
            second.withUnsafeBufferPointer { secondPointer in
                let channels: [UnsafePointer<Float>?] = [firstPointer.baseAddress!, secondPointer.baseAddress!]
                channels.withUnsafeBufferPointer { channelPointers in
                    outputLeft.withUnsafeMutableBufferPointer { leftOutput in
                        outputRight.withUnsafeMutableBufferPointer { rightOutput in
                            StereoDownmixGains.downmix(
                                inputChannels: channelPointers.baseAddress!,
                                inputChannelCount: 2,
                                inputOffset: 0,
                                inputSpeakers: [.FL, .FC],
                                outputLeft: leftOutput.baseAddress!,
                                outputRight: rightOutput.baseAddress!,
                                frameCount: 2
                            )
                        }
                    }
                }
            }
        }

        let gain = Float(0.707)
        XCTAssertEqual(outputLeft[0], 2 * gain + 8 * gain, accuracy: 1e-4)
        XCTAssertEqual(outputLeft[1], 4 * gain + 16 * gain, accuracy: 1e-4)
        XCTAssertEqual(outputRight[0], 8 * gain, accuracy: 1e-4)
        XCTAssertEqual(outputRight[1], 16 * gain, accuracy: 1e-4)
    }

    func testRestrictedStereoPathHandlesNilMissingZeroFramesAndCanaries() {
        var outputLeft = [Float](repeating: .nan, count: 2)
        var outputRight = [Float](repeating: .nan, count: 2)
        let frames = 1
        // Nil left pointer: left silences, right copies.
        let right = [Float(3)]
        right.withUnsafeBufferPointer { rightPointer in
            let channels: [UnsafePointer<Float>?] = [nil, rightPointer.baseAddress!]
            channels.withUnsafeBufferPointer { channelPointers in
                outputLeft.withUnsafeMutableBufferPointer { leftOutput in
                    outputRight.withUnsafeMutableBufferPointer { rightOutput in
                        StereoDownmixGains.downmix(
                            inputChannels: channelPointers.baseAddress!,
                            inputChannelCount: 2,
                            inputOffset: 0,
                            inputSpeakers: [.FL, .FR],
                            outputLeft: leftOutput.baseAddress!,
                            outputRight: rightOutput.baseAddress!,
                            frameCount: frames
                        )
                    }
                }
            }
        }
        XCTAssertEqual(outputLeft[0], 0, accuracy: 1e-6)
        XCTAssertEqual(outputRight[0], 3, accuracy: 1e-6)

        // Both missing: right duplicates left (which is silence here).
        let bothMissing: [UnsafePointer<Float>?] = [nil, nil]
        bothMissing.withUnsafeBufferPointer { channelPointers in
            outputLeft.withUnsafeMutableBufferPointer { leftOutput in
                outputRight.withUnsafeMutableBufferPointer { rightOutput in
                    StereoDownmixGains.downmix(
                        inputChannels: channelPointers.baseAddress!,
                        inputChannelCount: 2,
                        inputOffset: 0,
                        inputSpeakers: [.FL, .FR],
                        outputLeft: leftOutput.baseAddress!,
                        outputRight: rightOutput.baseAddress!,
                        frameCount: frames
                    )
                }
            }
        }
        XCTAssertEqual(outputLeft[0], 0, accuracy: 1e-6)
        XCTAssertEqual(outputRight[0], 0, accuracy: 1e-6)

        // Zero frames: outputs stay canaries.
        var canaryLeft = [Float(11)]
        var canaryRight = [Float(13)]
        let bothMissingAgain: [UnsafePointer<Float>?] = [nil, nil]
        bothMissingAgain.withUnsafeBufferPointer { channelPointers in
            canaryLeft.withUnsafeMutableBufferPointer { leftOutput in
                canaryRight.withUnsafeMutableBufferPointer { rightOutput in
                    StereoDownmixGains.downmix(
                        inputChannels: channelPointers.baseAddress!,
                        inputChannelCount: 2,
                        inputOffset: 0,
                        inputSpeakers: [.FL, .FR],
                        outputLeft: leftOutput.baseAddress!,
                        outputRight: rightOutput.baseAddress!,
                        frameCount: 0
                    )
                }
            }
        }
        XCTAssertEqual(canaryLeft, [11])
        XCTAssertEqual(canaryRight, [13])

        // Nonzero offset with distinct values on the gain path.
        let offsetGain = Float(0.707)
        let wide = [Float(0), 0, 5, 9]
        var offsetLeft = [Float](repeating: .nan, count: 2)
        var offsetRight = [Float](repeating: .nan, count: 2)
        wide.withUnsafeBufferPointer { widePointer in
            let channels: [UnsafePointer<Float>?] = [widePointer.baseAddress!, widePointer.baseAddress!]
            channels.withUnsafeBufferPointer { channelPointers in
                offsetLeft.withUnsafeMutableBufferPointer { leftOutput in
                    offsetRight.withUnsafeMutableBufferPointer { rightOutput in
                        StereoDownmixGains.downmix(
                            inputChannels: channelPointers.baseAddress!,
                            inputChannelCount: 2,
                            inputOffset: 2,
                            inputSpeakers: [.FR, .FL],
                            outputLeft: leftOutput.baseAddress!,
                            outputRight: rightOutput.baseAddress!,
                            frameCount: 2
                        )
                    }
                }
            }
        }
        XCTAssertEqual(offsetLeft[0], 5 * offsetGain, accuracy: 1e-4)
        XCTAssertEqual(offsetLeft[1], 9 * offsetGain, accuracy: 1e-4)
        XCTAssertEqual(offsetRight[0], 5 * offsetGain, accuracy: 1e-4)
        XCTAssertEqual(offsetRight[1], 9 * offsetGain, accuracy: 1e-4)
    }
}
