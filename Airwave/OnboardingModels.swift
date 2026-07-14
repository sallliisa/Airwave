import Foundation
import AVFoundation

enum SetupStep: String, Codable, CaseIterable, Identifiable {
    case introduction
    case virtualDriver
    case aggregateDevice
    case microphonePermission
    case hrirPreset
    case audioRoute
    case completion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .introduction: return "Welcome"
        case .virtualDriver: return "Virtual audio"
        case .aggregateDevice: return "Aggregate device"
        case .microphonePermission: return "Mic permission"
        case .hrirPreset: return "HRIR preset"
        case .audioRoute: return "Audio route"
        case .completion: return "Ready to use"
        }
    }

    var systemImage: String {
        switch self {
        case .introduction: return "waveform"
        case .virtualDriver: return "puzzlepiece.extension"
        case .aggregateDevice: return "rectangle.stack"
        case .microphonePermission: return "mic"
        case .hrirPreset: return "waveform.circle"
        case .audioRoute: return "point.3.connected.trianglepath.dotted"
        case .completion: return "checkmark.seal"
        }
    }

    var requirementStep: SetupStep? {
        switch self {
        case .introduction, .completion: return nil
        default: return self
        }
    }
}

enum OnboardingStepNavigationPolicy {
    static func canSelect(
        step _: SetupStep,
        currentStep _: SetupStep,
        snapshot _: SetupSnapshot
    ) -> Bool {
        true
    }
}

enum SetupRequirementStatus: Equatable {
    case checking
    case incomplete
    case blocked(String)
    case complete

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    var icon: String {
        switch self {
        case .checking: return "hourglass"
        case .incomplete: return "circle"
        case .blocked: return "exclamationmark.triangle.fill"
        case .complete: return "checkmark.circle.fill"
        }
    }
}

struct SetupRouteState: Equatable {
    var aggregateSelected = false
    var inputSelected = false
    var outputSelected = false
    var presetSelected = false
    var aggregateName: String?
    var inputName: String?
    var outputName: String?
    var presetName: String?

    var isComplete: Bool {
        aggregateSelected && inputSelected && outputSelected && presetSelected
    }
}

struct SetupSnapshot: Equatable {
    var driverStatus: SetupRequirementStatus
    var aggregateStatus: SetupRequirementStatus
    var permissionStatus: SetupRequirementStatus
    var hrirStatus: SetupRequirementStatus
    var routeStatus: SetupRequirementStatus
    var detectedDrivers: [String]
    var route: SetupRouteState

    var isReadyToRun: Bool {
        driverStatus.isComplete &&
        aggregateStatus.isComplete &&
        permissionStatus.isComplete &&
        hrirStatus.isComplete &&
        routeStatus.isComplete
    }

    static var checking: SetupSnapshot {
        SetupSnapshot(
            driverStatus: .checking,
            aggregateStatus: .checking,
            permissionStatus: .checking,
            hrirStatus: .checking,
            routeStatus: .checking,
            detectedDrivers: [],
            route: SetupRouteState()
        )
    }

    init(
        diagnostics: DiagnosticsResult,
        presets: [HRIRPreset],
        route: SetupRouteState,
        isChecking: Bool = false,
        microphoneStatus: AVAuthorizationStatus? = nil
    ) {
        self.route = route
        self.detectedDrivers = diagnostics.detectedVirtualDrivers

        if isChecking {
            driverStatus = .checking
            aggregateStatus = .checking
            permissionStatus = .checking
            hrirStatus = .checking
            routeStatus = .checking
            return
        }

        driverStatus = diagnostics.virtualDriverInstalled ? .complete : .incomplete

        if diagnostics.validAggregateExists {
            aggregateStatus = .complete
        } else if !diagnostics.aggregateDevicesExist {
            aggregateStatus = .incomplete
        } else if diagnostics.aggregateHealth.contains(where: { !$0.hasInput && !$0.hasOutput }) {
            aggregateStatus = .blocked("The aggregate device is missing its input and physical output. Add both in Audio MIDI Setup.")
        } else if diagnostics.aggregateHealth.contains(where: { !$0.hasInput }) {
            aggregateStatus = .blocked("Add the virtual input device to your aggregate in Audio MIDI Setup.")
        } else if diagnostics.aggregateHealth.contains(where: { !$0.hasOutput }) {
            aggregateStatus = .blocked("Add a connected pair of headphones or speakers to your aggregate in Audio MIDI Setup.")
        } else if diagnostics.aggregateHealth.contains(where: { !$0.missingDevices.isEmpty }) {
            aggregateStatus = .blocked("Your aggregate includes a device that’s disconnected. Reconnect it or update the aggregate in Audio MIDI Setup.")
        } else {
            aggregateStatus = .blocked("Create an aggregate in Audio MIDI Setup, or repair the one that’s already there.")
        }

        let authorizationStatus = microphoneStatus ?? PermissionManager.shared.currentMicrophoneStatus
        switch authorizationStatus {
        case .authorized:
            permissionStatus = .complete
        case .notDetermined:
            permissionStatus = .incomplete
        case .denied:
            permissionStatus = .blocked("Microphone access is off for Airwave. Turn it on in System Settings to continue.")
        case .restricted:
            permissionStatus = .blocked("Microphone access is restricted by macOS or your device policy.")
        @unknown default:
            permissionStatus = .blocked("We couldn’t determine Airwave’s microphone permission. Please check System Settings.")
        }

        hrirStatus = presets.isEmpty
            ? .incomplete
            : .complete

        if route.isComplete {
            routeStatus = .complete
        } else if !route.aggregateSelected {
            routeStatus = .incomplete
        } else if !route.inputSelected {
            routeStatus = .blocked("Choose an input from the aggregate device.")
        } else if !route.outputSelected {
            routeStatus = .blocked("Choose a connected pair of headphones or speakers.")
        } else if !route.presetSelected {
            routeStatus = .blocked("Choose an HRIR preset to continue.")
        } else {
            routeStatus = .blocked("Choose an option in each audio path field to continue.")
        }
    }

    init(
        driverStatus: SetupRequirementStatus,
        aggregateStatus: SetupRequirementStatus,
        permissionStatus: SetupRequirementStatus,
        hrirStatus: SetupRequirementStatus,
        routeStatus: SetupRequirementStatus,
        detectedDrivers: [String] = [],
        route: SetupRouteState = SetupRouteState()
    ) {
        self.driverStatus = driverStatus
        self.aggregateStatus = aggregateStatus
        self.permissionStatus = permissionStatus
        self.hrirStatus = hrirStatus
        self.routeStatus = routeStatus
        self.detectedDrivers = detectedDrivers
        self.route = route
    }

    func status(for step: SetupStep) -> SetupRequirementStatus? {
        switch step {
        case .virtualDriver: return driverStatus
        case .aggregateDevice: return aggregateStatus
        case .microphonePermission: return permissionStatus
        case .hrirPreset: return hrirStatus
        case .audioRoute: return routeStatus
        case .introduction, .completion: return nil
        }
    }
}
