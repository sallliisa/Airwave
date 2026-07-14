import CoreAudio
import Foundation

enum AudioRoutingEffect: Equatable {
    case noOp
    case stopInternalUnit
    case applyRoute(AudioRouteIdentity)
    case switchSystemOutput(AudioDeviceID)
    case restorePhysicalOutput(AudioDeviceID)
    case clearRoute
    case restartUnit
}

enum AudioRouteTransitionPlanner {
    static func plan(
        oldRoute: AudioRoute?,
        newRoute: AudioRoute?,
        engineRunning: Bool,
        physicalRestoreDeviceID: AudioDeviceID?
    ) -> [AudioRoutingEffect] {
        if let oldRoute, let newRoute, oldRoute.identity == newRoute.identity {
            return [.noOp]
        }

        guard let newRoute else {
            var effects: [AudioRoutingEffect] = []
            if engineRunning { effects.append(.stopInternalUnit) }
            if let physicalRestoreDeviceID { effects.append(.restorePhysicalOutput(physicalRestoreDeviceID)) }
            effects.append(.clearRoute)
            return effects
        }

        var effects: [AudioRoutingEffect] = []
        if engineRunning { effects.append(.stopInternalUnit) }
        effects.append(.applyRoute(newRoute.identity))

        let oldInputID = oldRoute?.input?.device.id
        let newInputID = newRoute.input?.device.id
        if engineRunning, oldInputID != newInputID, let newInputID {
            effects.append(.switchSystemOutput(newInputID))
        }
        if engineRunning { effects.append(.restartUnit) }
        return effects
    }
}
