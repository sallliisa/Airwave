import Foundation
import Combine

@MainActor
final class AudioRuntimeState: ObservableObject {
    enum PermissionStatus: Equatable {
        case unknown
        case requesting
        case granted
        case denied
    }

    enum Status: Equatable {
        case unavailable(String)
        case inactive
        case needsPermission
        case nativePassthrough(reason: String)
        case starting
        case processing
        case recovering(reason: String)

        var title: String {
            switch self {
            case .unavailable: "Unavailable"
            case .inactive: "Inactive"
            case .needsPermission: "Permission required"
            case .nativePassthrough: "Native passthrough"
            case .starting: "Starting"
            case .processing: "Processing"
            case .recovering: "Recovering"
            }
        }

        var detail: String {
            switch self {
            case .unavailable(let reason), .nativePassthrough(let reason), .recovering(let reason):
                reason
            case .inactive:
                "No HRIR preset selected; native audio remains unchanged."
            case .needsPermission:
                "Allow System Audio Capture in macOS Settings to enable processing."
            case .starting:
                "Airwave is preparing native audio processing."
            case .processing:
                "Airwave is processing audio without changing macOS output or volume."
            }
        }

        var isProcessing: Bool {
            self == .processing
        }
    }

    static let shared = AudioRuntimeState()

    @Published private(set) var status: Status
    @Published private(set) var permissionStatus: PermissionStatus
    @Published private(set) var currentOutput: OutputDeviceDescriptor?
    @Published private(set) var warningMessage: String?

    init(
        status: Status = .unavailable("Airwave 2.0 audio backend is not installed yet"),
        currentOutput: OutputDeviceDescriptor? = nil,
        warningMessage: String? = nil,
        permissionStatus: PermissionStatus? = nil
    ) {
        self.status = status
        self.permissionStatus = permissionStatus ?? Self.inferredPermissionStatus(
            for: status,
            output: currentOutput
        )
        self.currentOutput = currentOutput
        self.warningMessage = warningMessage
    }

    func setPermissionStatus(_ permissionStatus: PermissionStatus) {
        self.permissionStatus = permissionStatus
    }

    func publish(
        _ status: Status,
        output: OutputDeviceDescriptor? = nil,
        warning: String? = nil,
        permission: PermissionStatus? = nil
    ) {
        if let permission { permissionStatus = permission }
        self.currentOutput = output
        self.status = status
        self.warningMessage = warning
    }

    private static func inferredPermissionStatus(
        for status: Status,
        output: OutputDeviceDescriptor?
    ) -> PermissionStatus {
        switch status {
        case .needsPermission:
            .denied
        case .processing:
            .granted
        case .inactive where output != nil:
            .granted
        default:
            .unknown
        }
    }
}
