import Foundation
import XCTest
@testable import Airwave

@MainActor
final class OutputDeviceDiscoveryCoordinatorTests: XCTestCase {
    func testInitialInventoryPublishesToManager() throws {
        let context = try DiscoveryContext()
        let output = discoveryDevice(id: 1, uid: "usb", name: "USB DAC")
        context.client.outputs = [output]

        context.coordinator.launch()

        XCTAssertEqual(context.profiles.availableOutputs, [output])
        XCTAssertEqual(context.profiles.targets.map(\.deviceUID), ["usb"])
    }

    func testListenerUpdatesReplaceSnapshot() throws {
        let context = try DiscoveryContext()
        let first = discoveryDevice(id: 1, uid: "first", name: "First")
        let second = discoveryDevice(id: 2, uid: "second", name: "Second")
        context.client.outputs = [first]
        context.coordinator.launch()

        context.client.emit([second])
        waitForCallback()

        XCTAssertEqual(context.profiles.availableOutputs, [second])
        XCTAssertEqual(context.profiles.targets.map(\.deviceUID), ["second"])
    }

    func testLaunchIsIdempotent() throws {
        let context = try DiscoveryContext()

        context.coordinator.launch()
        context.coordinator.launch()

        XCTAssertEqual(context.client.observationCount, 1)
    }

    func testManagerBoundaryFiltersUnsupportedAndDuplicateUIDs() throws {
        let context = try DiscoveryContext()
        context.client.outputs = [
            discoveryDevice(id: 1, uid: "same", name: "Zulu"),
            discoveryDevice(id: 2, uid: "same", name: "Alpha"),
            discoveryDevice(id: 3, uid: "virtual", name: "Virtual", virtual: true),
            discoveryDevice(id: 4, uid: "mono", name: "Mono", channels: 1),
            discoveryDevice(id: 5, uid: "", name: "No UID")
        ]

        context.coordinator.launch()

        XCTAssertEqual(context.profiles.availableOutputs.map(\.uid), ["same"])
        XCTAssertEqual(context.profiles.availableOutputs.first?.name, "Alpha")
        XCTAssertEqual(context.profiles.profiles, [])
    }

    func testInitialFailureRecoversThroughLaterCallback() throws {
        let context = try DiscoveryContext()
        context.client.failInitialRead = true
        let output = discoveryDevice(id: 1, uid: "recovered", name: "Recovered")

        context.coordinator.launch()
        XCTAssertTrue(context.profiles.availableOutputs.isEmpty)

        context.client.emit([output])
        waitForCallback()

        XCTAssertEqual(context.profiles.availableOutputs, [output])
    }

    func testRefreshFailureRetainsLastSuccessfulSnapshot() throws {
        let context = try DiscoveryContext()
        let first = discoveryDevice(id: 1, uid: "first", name: "First")
        let second = discoveryDevice(id: 2, uid: "second", name: "Second")
        context.client.outputs = [first]
        context.coordinator.launch()

        context.client.emitFailure()
        waitForCallback()

        XCTAssertEqual(context.profiles.availableOutputs, [first])
        context.client.emit([second])
        waitForCallback()
        XCTAssertEqual(context.profiles.availableOutputs, [second])
    }

    private func waitForCallback() {
        let expectation = expectation(description: "discovery callback")
        Task { @MainActor in
            await Task.yield()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}

@MainActor
private final class DiscoveryContext {
    let defaults: UserDefaults
    let profiles: DeviceProfileManager
    let client = DiscoveryClientFake()
    let coordinator: OutputDeviceDiscoveryCoordinator

    init() throws {
        let suite = "OutputDeviceDiscoveryCoordinatorTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        profiles = DeviceProfileManager(defaults: defaults)
        coordinator = OutputDeviceDiscoveryCoordinator(profiles: profiles, client: client)
    }
}

private final class DiscoveryClientFake: OutputDeviceDiscovering {
    var outputs: [OutputDeviceDescriptor] = []
    var failInitialRead = false
    private(set) var observationCount = 0
    private var handler: AvailableOutputChangeHandler?

    func availableOutputDevices() throws -> [OutputDeviceDescriptor] {
        if failInitialRead {
            failInitialRead = false
            throw AudioRuntimeError.deviceLost
        }
        return outputs
    }

    func observeAvailableOutputs(_ handler: @escaping AvailableOutputChangeHandler) throws {
        observationCount += 1
        self.handler = handler
    }

    func stopObservingAvailableOutputs() {}

    func emit(_ outputs: [OutputDeviceDescriptor]) {
        self.outputs = outputs
        handler?(outputs)
    }

    func emitFailure() {
        // Production Core Audio sends no handler call when refresh read fails.
    }
}

private func discoveryDevice(
    id: UInt64,
    uid: String,
    name: String,
    transport: String = "USB",
    virtual: Bool = false,
    aggregate: Bool = false,
    channels: Int = 2
) -> OutputDeviceDescriptor {
    OutputDeviceDescriptor(
        id: .init(id), uid: uid, name: name, transport: transport,
        outputChannelCount: channels, nominalSampleRate: 48_000,
        isVirtual: virtual, isAggregate: aggregate
    )
}
