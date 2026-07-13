import XCTest
import CoreAudio
@testable import Airwave

@MainActor
final class AudioDeviceQueryServiceTests: XCTestCase {
    private func device(
        id: AudioDeviceID,
        name: String,
        uid: String,
        input: UInt32,
        output: UInt32,
        sampleRate: Double,
        aggregate: Bool
    ) -> AudioDevice {
        AudioDevice(
            id: id,
            name: name,
            uid: uid,
            inputChannelCount: input,
            outputChannelCount: output,
            sampleRate: sampleRate,
            isAggregateDevice: aggregate
        )
    }

    func testSnapshotPropertiesAreStoredAndDerivedWithoutQueries() {
        let snapshot = device(
            id: 1,
            name: "Input",
            uid: "input.uid",
            input: 2,
            output: 0,
            sampleRate: 48_000,
            aggregate: false
        )

        XCTAssertEqual(snapshot.name, "Input")
        XCTAssertEqual(snapshot.uid, "input.uid")
        XCTAssertTrue(snapshot.hasInput)
        XCTAssertFalse(snapshot.hasOutput)
        XCTAssertEqual(snapshot.channelCount, 2)
        XCTAssertEqual(snapshot.sampleRate, 48_000)
    }

    func testEqualityAndHashUseOnlyDeviceID() {
        let first = device(id: 7, name: "Old", uid: "old", input: 1, output: 0, sampleRate: 44_100, aggregate: false)
        let second = device(id: 7, name: "New", uid: "new", input: 0, output: 2, sampleRate: 48_000, aggregate: true)

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([first]).count, 1)
        XCTAssertEqual(Set([first, second]).count, 1)
    }

    func testRefreshPublishesOneCoherentSnapshotAndRejectsStaleResult() {
        let old = device(id: 1, name: "Old", uid: "old", input: 1, output: 0, sampleRate: 44_100, aggregate: false)
        let new = device(id: 2, name: "New", uid: "new", input: 0, output: 2, sampleRate: 48_000, aggregate: false)
        let service = DelayedDeviceQueryService(results: [
            AudioDeviceRefreshResult(devices: [old], defaultInputID: 1, defaultOutputID: nil),
            AudioDeviceRefreshResult(devices: [new], defaultInputID: nil, defaultOutputID: 2),
            AudioDeviceRefreshResult(devices: [new], defaultInputID: nil, defaultOutputID: 2)
        ])
        let manager = AudioDeviceManager(queryService: service, installListeners: false)
        manager.refreshDevices()

        let expectation = expectation(description: "new snapshot published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(manager.inputDevices, [])
            XCTAssertEqual(manager.outputDevices.map(\.id), [2])
            XCTAssertEqual(manager.defaultOutputDevice?.id, 2)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}

private final class DelayedDeviceQueryService: AudioDeviceQuerying {
    private let lock = NSLock()
    private var results: [AudioDeviceRefreshResult]
    private var callCount = 0

    init(results: [AudioDeviceRefreshResult]) {
        self.results = results
    }

    func refresh() -> AudioDeviceRefreshResult {
        lock.lock()
        let index = min(callCount, results.count - 1)
        callCount += 1
        lock.unlock()

        if index == 0 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return results[index]
    }
}
