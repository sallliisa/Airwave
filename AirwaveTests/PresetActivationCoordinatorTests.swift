import XCTest
@testable import Airwave

@MainActor
final class PresetActivationCoordinatorTests: XCTestCase {
    private enum TestError: Error { case failed }

    private func key(
        name: String,
        sampleRate: Double = 48_000,
        channels: [VirtualSpeaker] = [.FL, .FR]
    ) -> PresetActivationKey {
        let preset = HRIRPreset(
            id: UUID(),
            name: name,
            fileURL: URL(fileURLWithPath: "/tmp/\(name).wav"),
            channelCount: 2,
            sampleRate: sampleRate
        )
        return PresetActivationKey(
            preset: preset,
            targetSampleRate: sampleRate,
            inputLayout: InputLayout(channels: channels, name: name)
        )
    }

    private func waitForSuccess(
        _ coordinator: PresetActivationCoordinator<String>,
        key: PresetActivationKey,
        value: String,
        expectation: XCTestExpectation
    ) {
        XCTAssertTrue(coordinator.request(
            key: key,
            build: { _ in value },
            onSuccess: { _, result in
                XCTAssertEqual(result, value)
                expectation.fulfill()
            },
            onFailure: { _, _ in XCTFail("unexpected activation failure") }
        ))
    }

    func testIdenticalRequestsBuildOnce() {
        let coordinator = PresetActivationCoordinator<String>()
        let requestKey = key(name: "same")
        let expectation = expectation(description: "published")
        var buildCount = 0

        XCTAssertTrue(coordinator.request(
            key: requestKey,
            build: { _ in buildCount += 1; return "same" },
            onSuccess: { _, _ in expectation.fulfill() },
            onFailure: { _, _ in XCTFail() }
        ))
        XCTAssertFalse(coordinator.request(
            key: requestKey,
            build: { _ in buildCount += 1; return "duplicate" },
            onSuccess: { _, _ in XCTFail() },
            onFailure: { _, _ in XCTFail() }
        ))

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(buildCount, 1)
    }

    func testSlowAThenFastBPublishesBOnly() {
        let coordinator = PresetActivationCoordinator<String>()
        let keyA = key(name: "A")
        let keyB = key(name: "B")
        let expectation = expectation(description: "B published")
        let started = DispatchSemaphore(value: 0)

        XCTAssertTrue(coordinator.request(
            key: keyA,
            build: { isCancelled in
                started.signal()
                while !isCancelled() { Thread.sleep(forTimeInterval: 0.005) }
                return "A"
            },
            onSuccess: { _, _ in XCTFail("stale A published") },
            onFailure: { _, _ in XCTFail("stale A failed visibly") }
        ))
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        waitForSuccess(coordinator, key: keyB, value: "B", expectation: expectation)

        wait(for: [expectation], timeout: 2)
    }

    func testStaleFailureAfterBSuccessDoesNotReplaceB() {
        let coordinator = PresetActivationCoordinator<String>()
        let keyA = key(name: "fail-A")
        let keyB = key(name: "success-B")
        let expectation = expectation(description: "B published")
        let started = DispatchSemaphore(value: 0)

        _ = coordinator.request(
            key: keyA,
            build: { isCancelled in
                started.signal()
                while !isCancelled() { Thread.sleep(forTimeInterval: 0.005) }
                throw TestError.failed
            },
            onSuccess: { _, _ in XCTFail() },
            onFailure: { _, _ in XCTFail("stale failure published") }
        )
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        waitForSuccess(coordinator, key: keyB, value: "B", expectation: expectation)
        wait(for: [expectation], timeout: 2)
    }

    func testCancellationProducesNoError() {
        let coordinator = PresetActivationCoordinator<String>()
        let requestKey = key(name: "cancel")
        let started = DispatchSemaphore(value: 0)
        let noCallback = expectation(description: "no callback")
        noCallback.isInverted = true

        _ = coordinator.request(
            key: requestKey,
            build: { isCancelled in
                started.signal()
                while !isCancelled() { Thread.sleep(forTimeInterval: 0.005) }
                throw CancellationError()
            },
            onSuccess: { _, _ in noCallback.fulfill() },
            onFailure: { _, _ in noCallback.fulfill() }
        )
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        coordinator.deactivate()
        wait(for: [noCallback], timeout: 0.2)
    }

    func testChangedSampleRateAndInputChannelsRebuild() {
        let coordinator = PresetActivationCoordinator<String>()
        let firstKey = key(name: "config", sampleRate: 48_000)
        let rateKey = key(name: "config", sampleRate: 44_100)
        let layoutKey = key(name: "config", channels: [.FL, .FR, .FC])
        let expectations = (0..<3).map { expectation(description: "publish \($0)") }
        var buildCount = 0

        for (index, requestKey) in [firstKey, rateKey, layoutKey].enumerated() {
            XCTAssertTrue(coordinator.request(
                key: requestKey,
                build: { _ in buildCount += 1; return "value" },
                onSuccess: { _, _ in expectations[index].fulfill() },
                onFailure: { _, _ in XCTFail() }
            ))
            wait(for: [expectations[index]], timeout: 2)
        }
        XCTAssertEqual(buildCount, 3)
    }
}
