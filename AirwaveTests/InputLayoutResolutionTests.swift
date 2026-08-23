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
}
