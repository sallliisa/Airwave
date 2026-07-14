import Combine
import CoreAudio
import Foundation

struct AudioRouteIdentity: Equatable {
    let aggregateUID: String
    let aggregateID: AudioDeviceID
    let inputUID: String?
    let inputID: AudioDeviceID?
    let outputUID: String
    let outputID: AudioDeviceID
    let inputChannelRange: Range<Int>?
    let outputChannelRange: Range<Int>
}

struct AudioRoute {
    let aggregate: AudioDevice
    let input: AggregateDeviceInspector.SubDeviceInfo?
    let output: AggregateDeviceInspector.SubDeviceInfo
    let inputChannelRange: Range<Int>?
    let outputChannelRange: Range<Int>
    let sourceGeneration: Int

    init?(
        aggregate: AudioDevice,
        input: AggregateDeviceInspector.SubDeviceInfo?,
        output: AggregateDeviceInspector.SubDeviceInfo?,
        inputChannelRange: Range<Int>?,
        outputChannelRange: Range<Int>?,
        sourceGeneration: Int
    ) {
        guard let output,
              let outputChannels = output.outputChannelRange,
              let outputChannelRange,
              outputChannelRange.count == 2,
              outputChannelRange.lowerBound >= outputChannels.lowerBound,
              outputChannelRange.upperBound <= outputChannels.upperBound else { return nil }
        if let input {
            guard let inputChannels = input.inputChannelRange,
                  let inputChannelRange,
                  !inputChannelRange.isEmpty,
                  inputChannelRange.lowerBound >= inputChannels.lowerBound,
                  inputChannelRange.upperBound <= inputChannels.upperBound else { return nil }
        } else if inputChannelRange != nil {
            return nil
        }
        self.aggregate = aggregate
        self.input = input
        self.output = output
        self.inputChannelRange = inputChannelRange
        self.outputChannelRange = outputChannelRange
        self.sourceGeneration = sourceGeneration
    }

    var identity: AudioRouteIdentity {
        AudioRouteIdentity(
            aggregateUID: aggregate.uid ?? "id:\(aggregate.id)",
            aggregateID: aggregate.id,
            inputUID: input?.uid,
            inputID: input?.device.id,
            outputUID: output.uid,
            outputID: output.device.id,
            inputChannelRange: inputChannelRange,
            outputChannelRange: outputChannelRange
        )
    }
}

struct DeviceSelectionSnapshot {
    let generation: Int
    let aggregate: AudioDevice?
    let subdevices: [AggregateDeviceInspector.SubDeviceInfo]
}

@MainActor
protocol DeviceSelectionRouteSink: AnyObject {
    func apply(route: AudioRoute)
    func clear()
}

@MainActor
protocol DeviceSelectionPreferenceSink: AnyObject {
    func persist(preferences: DeviceSelectionPreferences)
}

@MainActor
final class AudioGraphRouteSink: DeviceSelectionRouteSink {
    private let audioManager: AudioGraphManager

    init(audioManager: AudioGraphManager = .shared) {
        self.audioManager = audioManager
    }

    func apply(route: AudioRoute) {
        audioManager.applyTransactionalRoute(route)
    }

    func clear() {
        audioManager.clearTransactionalRoute()
    }
}

@MainActor
final class SettingsRoutePreferenceSink: DeviceSelectionPreferenceSink {
    private let settings: SettingsManager

    init(settings: SettingsManager = SettingsManager.shared) {
        self.settings = settings
    }

    func persist(preferences: DeviceSelectionPreferences) {
        settings.updateSelectionPreferences(
            aggregateUID: preferences.aggregateUID,
            inputUID: preferences.inputUID,
            outputUID: preferences.outputUID
        )
    }
}

/// Policy/effect coordinator. Production wiring is intentionally deferred until
/// route-effect and hardware gates pass; tests can submit immutable snapshots.
@MainActor
final class DeviceSelectionCoordinator: ObservableObject {
    @Published private(set) var state = DeviceSelectionState(
        preferences: DeviceSelectionPreferences(aggregateUID: nil, inputUID: nil, outputUID: nil),
        effective: nil
    )
    @Published private(set) var snapshot: DeviceSelectionSnapshot?

    private weak var routeSink: DeviceSelectionRouteSink?
    private weak var preferenceSink: DeviceSelectionPreferenceSink?
    private var lastAppliedIdentity: AudioRouteIdentity?
    private(set) var isStarted = false

    init(routeSink: DeviceSelectionRouteSink? = nil, preferenceSink: DeviceSelectionPreferenceSink? = nil) {
        self.routeSink = routeSink
        self.preferenceSink = preferenceSink
    }

    func start() { isStarted = true }
    func refresh() { isStarted = true }

    func restorePreferences(_ preferences: DeviceSelectionPreferences) {
        state = reduce(.restorePreferences(preferences))
        applyCurrentRoute()
    }

    func receive(snapshot: DeviceSelectionSnapshot) {
        guard self.snapshot?.generation ?? 0 <= snapshot.generation else { return }
        self.snapshot = snapshot
        state = reduce(.inventoryChanged)
        applyCurrentRoute()
    }

    func selectAggregate(uid: String?) {
        state = reduce(.userSelectedAggregate(uid))
        preferenceSink?.persist(preferences: state.preferences)
        applyCurrentRoute()
    }

    func selectInput(uid: String?) {
        state = reduce(.userSelectedInput(uid))
        preferenceSink?.persist(preferences: state.preferences)
        applyCurrentRoute()
    }

    func selectOutput(uid: String?) {
        state = reduce(.userSelectedOutput(uid))
        preferenceSink?.persist(preferences: state.preferences)
        applyCurrentRoute()
    }

    private func reduce(_ event: DeviceSelectionEvent) -> DeviceSelectionState {
        let inventory = makeInventory()
        return DeviceSelectionPolicy.reduce(state: state, event: event, inventory: inventory)
    }

    private func makeInventory() -> DeviceSelectionInventory {
        let aggregateUID = snapshot?.aggregate?.uid
        let subdevices = snapshot?.subdevices ?? []
        return DeviceSelectionInventory(
            aggregateUID: aggregateUID,
            inputs: subdevices.filter { $0.inputChannelRange != nil }.map(DeviceSelectionSubdevice.init),
            outputs: DeviceOutputEligibility.filter(subdevices).map(DeviceSelectionSubdevice.init)
        )
    }

    private func applyCurrentRoute() {
        guard let snapshot,
              let aggregate = snapshot.aggregate,
              let effective = state.effective,
              let selectedOutput = effective.output,
              let output = snapshot.subdevices.first(where: { $0.uid == selectedOutput.uid }) else {
            lastAppliedIdentity = nil
            routeSink?.clear()
            return
        }
        let input = effective.input.flatMap { selected in
            snapshot.subdevices.first(where: { $0.uid == selected.uid })
        }
        guard let route = AudioRoute(
            aggregate: aggregate,
            input: input,
            output: output,
            inputChannelRange: effective.inputChannelRange,
            outputChannelRange: effective.outputChannelRange,
            sourceGeneration: snapshot.generation
        ) else {
            lastAppliedIdentity = nil
            routeSink?.clear()
            return
        }
        guard route.identity != lastAppliedIdentity else { return }
        lastAppliedIdentity = route.identity
        routeSink?.apply(route: route)
    }
}
