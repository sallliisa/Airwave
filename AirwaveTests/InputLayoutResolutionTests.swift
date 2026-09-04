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
        let layout = InputLayoutResolver.layout(channelLabels: labels, channelCount: 3)
        XCTAssertEqual(
            layout.channels,
            [.custom("Ch0"), .custom("Ch1"), .custom("Ch2")]
        )
    }

    func testLabelCountMismatchFallsBackToCountDetection() {
        let labels: [UInt32] = [1, 2]
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
}
