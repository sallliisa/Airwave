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

    func testOutputEligibilityExcludesAllKnownVirtualDriversAndMonoOutputs() {
        let names = [
            "BlackHole 2ch",
            "Loopback Audio",
            "Soundflower (2ch)",
            "Existential Audio Device"
        ]
        let virtualOutputs = names.enumerated().map { index, name in
            AggregateDeviceInspector.SubDeviceInfo(
                device: device(id: AudioDeviceID(index + 1), name: name, uid: name, input: 0, output: 2, sampleRate: 48_000, aggregate: false),
                uid: name,
                name: name,
                inputChannelRange: nil,
                outputChannelRange: index * 2..<(index * 2 + 2)
            )
        }
        let physical = AggregateDeviceInspector.SubDeviceInfo(
            device: device(id: 99, name: "Built-in Output", uid: "built.in", input: 0, output: 2, sampleRate: 48_000, aggregate: false),
            uid: "built.in",
            name: "Built-in Output",
            inputChannelRange: nil,
            outputChannelRange: 8..<10
        )
        let mono = AggregateDeviceInspector.SubDeviceInfo(
            device: device(id: 100, name: "Mono Output", uid: "mono", input: 0, output: 1, sampleRate: 48_000, aggregate: false),
            uid: "mono",
            name: "Mono Output",
            inputChannelRange: nil,
            outputChannelRange: 10..<11
        )

        let eligible = DeviceOutputEligibility.filter(virtualOutputs + [physical, mono])

        XCTAssertEqual(eligible.map(\.uid), ["built.in"])
    }

    func testTestHostRuntimeEnvironmentIsDeterministic() {
        XCTAssertEqual(
            RuntimeEnvironment.isTestHost,
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        )
    }
}

@MainActor
final class DeviceSelectionCoordinatorTests: XCTestCase {
    private func device(id: AudioDeviceID, name: String, uid: String, input: UInt32 = 0, output: UInt32 = 0, aggregate: Bool = false) -> AudioDevice {
        AudioDevice(id: id, name: name, uid: uid, inputChannelCount: input, outputChannelCount: output, sampleRate: 48_000, isAggregateDevice: aggregate)
    }

    private func subdevice(_ device: AudioDevice, output: Range<Int>? = nil, input: Range<Int>? = nil) -> AggregateDeviceInspector.SubDeviceInfo {
        AggregateDeviceInspector.SubDeviceInfo(device: device, uid: device.uid!, name: device.name, inputChannelRange: input, outputChannelRange: output)
    }

    func testUnchangedInventoryGenerationDoesNotReapplyRoute() {
        let aggregate = device(id: 1, name: "Aggregate", uid: "aggregate", output: 2, aggregate: true)
        let output = device(id: 2, name: "Built-in Output", uid: "output", output: 2)
        let sink = RecordingRouteSink()
        let coordinator = DeviceSelectionCoordinator(routeSink: sink)
        coordinator.restorePreferences(DeviceSelectionPreferences(aggregateUID: "aggregate", inputUID: nil, outputUID: "output"))

        let topology = [subdevice(output, output: 0..<2)]
        coordinator.receive(snapshot: DeviceSelectionSnapshot(generation: 1, aggregate: aggregate, subdevices: topology))
        coordinator.receive(snapshot: DeviceSelectionSnapshot(generation: 2, aggregate: aggregate, subdevices: topology))

        XCTAssertEqual(sink.appliedRoutes.count, 1)
        XCTAssertEqual(sink.appliedRoutes.first?.sourceGeneration, 1)
    }

    func testSameUIDNewLiveIDReappliesOnceWithoutChangingPreference() {
        let aggregate = device(id: 1, name: "Aggregate", uid: "aggregate", output: 2, aggregate: true)
        let oldOutput = device(id: 2, name: "Built-in Output", uid: "output", output: 2)
        let newOutput = device(id: 9, name: "Built-in Output", uid: "output", output: 2)
        let sink = RecordingRouteSink()
        let coordinator = DeviceSelectionCoordinator(routeSink: sink)
        coordinator.restorePreferences(DeviceSelectionPreferences(aggregateUID: "aggregate", inputUID: nil, outputUID: "output"))
        coordinator.receive(snapshot: DeviceSelectionSnapshot(generation: 1, aggregate: aggregate, subdevices: [subdevice(oldOutput, output: 0..<2)]))
        coordinator.receive(snapshot: DeviceSelectionSnapshot(generation: 2, aggregate: aggregate, subdevices: [subdevice(newOutput, output: 0..<2)]))

        XCTAssertEqual(sink.appliedRoutes.map { $0.output.device.id }, [2, 9])
        XCTAssertEqual(coordinator.state.preferences.outputUID, "output")
    }

    func testFallbackExcludesVirtualOutputAndReconnectKeepsPreference() {
        let aggregate = device(id: 1, name: "Aggregate", uid: "aggregate", output: 2, aggregate: true)
        let virtual = device(id: 2, name: "BlackHole 2ch", uid: "blackhole", output: 2)
        let physical = device(id: 3, name: "Built-in Output", uid: "physical", output: 2)
        let sink = RecordingRouteSink()
        let preferences = RecordingPreferenceSink()
        let coordinator = DeviceSelectionCoordinator(routeSink: sink, preferenceSink: preferences)
        coordinator.restorePreferences(DeviceSelectionPreferences(aggregateUID: "aggregate", inputUID: nil, outputUID: "preferred"))

        coordinator.receive(snapshot: DeviceSelectionSnapshot(generation: 1, aggregate: aggregate, subdevices: [subdevice(virtual, output: 0..<2), subdevice(physical, output: 2..<4)]))
        XCTAssertEqual(coordinator.state.effective?.output?.uid, "physical")
        XCTAssertEqual(coordinator.state.preferences.outputUID, "preferred")
        XCTAssertTrue(preferences.values.isEmpty)

        let preferred = device(id: 4, name: "Headphones", uid: "preferred", output: 2)
        coordinator.receive(snapshot: DeviceSelectionSnapshot(generation: 2, aggregate: aggregate, subdevices: [subdevice(physical, output: 2..<4), subdevice(preferred, output: 4..<6)]))
        XCTAssertEqual(coordinator.state.effective?.output?.uid, "preferred")
        XCTAssertEqual(sink.appliedRoutes.map { $0.output.uid }, ["physical", "preferred"])
    }

    func testTransitionPlannerNoOpsForUnchangedRoute() {
        let aggregate = device(id: 1, name: "Aggregate", uid: "aggregate", output: 2, aggregate: true)
        let output = device(id: 2, name: "Built-in Output", uid: "output", output: 2)
        let route = AudioRoute(
            aggregate: aggregate,
            input: nil,
            output: subdevice(output, output: 0..<2),
            inputChannelRange: nil,
            outputChannelRange: 0..<2,
            sourceGeneration: 1
        )!

        XCTAssertEqual(
            AudioRouteTransitionPlanner.plan(oldRoute: route, newRoute: route, engineRunning: true, physicalRestoreDeviceID: 99),
            [.noOp]
        )
    }

    func testTransitionPlannerStopsAppliesAndRestartsOnce() {
        let aggregate = device(id: 1, name: "Aggregate", uid: "aggregate", output: 2, aggregate: true)
        let outputA = device(id: 2, name: "Built-in Output", uid: "output.a", output: 2)
        let outputB = device(id: 3, name: "Headphones", uid: "output.b", output: 2)
        let routeA = AudioRoute(aggregate: aggregate, input: nil, output: subdevice(outputA, output: 0..<2), inputChannelRange: nil, outputChannelRange: 0..<2, sourceGeneration: 1)!
        let routeB = AudioRoute(aggregate: aggregate, input: nil, output: subdevice(outputB, output: 2..<4), inputChannelRange: nil, outputChannelRange: 2..<4, sourceGeneration: 2)!

        let effects = AudioRouteTransitionPlanner.plan(oldRoute: routeA, newRoute: routeB, engineRunning: true, physicalRestoreDeviceID: 99)

        XCTAssertEqual(effects.count, 3)
        XCTAssertEqual(effects[0], .stopInternalUnit)
        XCTAssertEqual(effects[1], .applyRoute(routeB.identity))
        XCTAssertEqual(effects[2], .restartUnit)
    }

    func testTransitionPlannerClearsAndRestoresOnceWhenRouteInvalid() {
        let effects = AudioRouteTransitionPlanner.plan(oldRoute: nil, newRoute: nil, engineRunning: true, physicalRestoreDeviceID: 77)
        XCTAssertEqual(effects, [.stopInternalUnit, .restorePhysicalOutput(77), .clearRoute])
    }
}

@MainActor
private final class RecordingRouteSink: DeviceSelectionRouteSink {
    private(set) var appliedRoutes: [AudioRoute] = []
    private(set) var clearCount = 0

    func apply(route: AudioRoute) { appliedRoutes.append(route) }
    func clear() { clearCount += 1 }
}

@MainActor
private final class RecordingPreferenceSink: DeviceSelectionPreferenceSink {
    private(set) var values: [DeviceSelectionPreferences] = []
    func persist(preferences: DeviceSelectionPreferences) { values.append(preferences) }
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
