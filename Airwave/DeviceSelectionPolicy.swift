import Foundation
import CoreAudio

struct DeviceSelectionPreferences: Equatable {
    var aggregateUID: String?
    var inputUID: String?
    var outputUID: String?
}

struct DeviceSelectionSubdevice: Equatable {
    let uid: String
    let liveDeviceID: AudioDeviceID
    let inputChannelRange: Range<Int>?
    let outputChannelRange: Range<Int>?

    init(_ value: AggregateDeviceInspector.SubDeviceInfo) {
        uid = value.uid
        liveDeviceID = value.device.id
        inputChannelRange = value.inputChannelRange
        outputChannelRange = value.outputChannelRange
    }

    var inputRouteRange: Range<Int>? {
        guard let range = inputChannelRange, !range.isEmpty else { return nil }
        return range.lowerBound..<min(range.lowerBound + 2, range.upperBound)
    }

    var outputRouteRange: Range<Int>? {
        guard let range = outputChannelRange, range.count >= 2 else { return nil }
        return range.lowerBound..<min(range.lowerBound + 2, range.upperBound)
    }
}

struct DeviceSelectionInventory: Equatable {
    let aggregateUID: String?
    let inputs: [DeviceSelectionSubdevice]
    let outputs: [DeviceSelectionSubdevice]
}

enum DeviceSelectionResolution: Equatable {
    case preferred
    case fallback(preferredUID: String?)
    case unavailable(preferredUID: String?)
    case unconfigured
}

struct EffectiveDeviceSelection: Equatable {
    let aggregateUID: String?
    let input: DeviceSelectionSubdevice?
    let output: DeviceSelectionSubdevice?
    let aggregateStatus: DeviceSelectionResolution
    let inputStatus: DeviceSelectionResolution
    let outputStatus: DeviceSelectionResolution

    var inputChannelRange: Range<Int>? { input?.inputRouteRange }
    var outputChannelRange: Range<Int>? { output?.outputRouteRange }
}

struct DeviceSelectionState: Equatable {
    var preferences: DeviceSelectionPreferences
    var effective: EffectiveDeviceSelection?
}

enum DeviceSelectionEvent {
    case restorePreferences(DeviceSelectionPreferences)
    case inventoryChanged
    case userSelectedAggregate(String?)
    case userSelectedInput(String?)
    case userSelectedOutput(String?)
}

enum DeviceSelectionPolicy {
    static func reduce(
        state: DeviceSelectionState,
        event: DeviceSelectionEvent,
        inventory: DeviceSelectionInventory
    ) -> DeviceSelectionState {
        var preferences = state.preferences
        switch event {
        case .restorePreferences(let restored): preferences = restored
        case .inventoryChanged: break
        case .userSelectedAggregate(let uid): preferences.aggregateUID = uid
        case .userSelectedInput(let uid): preferences.inputUID = uid
        case .userSelectedOutput(let uid): preferences.outputUID = uid
        }

        let aggregate: (uid: String?, status: DeviceSelectionResolution)
        if let preferred = preferences.aggregateUID {
            aggregate = inventory.aggregateUID == preferred
                ? (preferred, .preferred)
                : (nil, .unavailable(preferredUID: preferred))
        } else if let discovered = inventory.aggregateUID {
            aggregate = (discovered, .fallback(preferredUID: nil))
        } else {
            aggregate = (nil, .unconfigured)
        }

        guard let aggregateUID = aggregate.uid else {
            return DeviceSelectionState(
                preferences: preferences,
                effective: EffectiveDeviceSelection(
                    aggregateUID: nil,
                    input: nil,
                    output: nil,
                    aggregateStatus: aggregate.status,
                    inputStatus: status(for: preferences.inputUID, aggregateAvailable: false),
                    outputStatus: status(for: preferences.outputUID, aggregateAvailable: false)
                )
            )
        }

        let previous = state.effective
        let aggregateChanged = previous?.aggregateUID != aggregateUID
        let input = resolve(
            preferredUID: preferences.inputUID,
            current: aggregateChanged ? nil : previous?.input,
            devices: inventory.inputs,
            routable: { $0.inputRouteRange != nil }
        )
        let output = resolve(
            preferredUID: preferences.outputUID,
            current: aggregateChanged ? nil : previous?.output,
            devices: inventory.outputs,
            routable: { $0.outputRouteRange != nil }
        )

        return DeviceSelectionState(
            preferences: preferences,
            effective: EffectiveDeviceSelection(
                aggregateUID: aggregateUID,
                input: input.device,
                output: output.device,
                aggregateStatus: aggregate.status,
                inputStatus: input.status,
                outputStatus: output.status
            )
        )
    }

    private static func resolve(
        preferredUID: String?,
        current: DeviceSelectionSubdevice?,
        devices: [DeviceSelectionSubdevice],
        routable: (DeviceSelectionSubdevice) -> Bool
    ) -> (device: DeviceSelectionSubdevice?, status: DeviceSelectionResolution) {
        if let preferredUID, let device = devices.first(where: { $0.uid == preferredUID && routable($0) }) {
            return (device, .preferred)
        }
        if let current, let device = devices.first(where: { $0.uid == current.uid && routable($0) }) {
            return (device, .fallback(preferredUID: preferredUID))
        }
        if let fallback = devices.first(where: routable) {
            return (fallback, .fallback(preferredUID: preferredUID))
        }
        return (nil, status(for: preferredUID, aggregateAvailable: true))
    }

    private static func status(for preferredUID: String?, aggregateAvailable: Bool) -> DeviceSelectionResolution {
        guard aggregateAvailable else {
            return preferredUID.map { .unavailable(preferredUID: $0) } ?? .unconfigured
        }
        return preferredUID.map { .unavailable(preferredUID: $0) } ?? .unconfigured
    }
}
