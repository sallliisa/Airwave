import Foundation
import Combine

@MainActor
final class AudioRuntimeState: ObservableObject {
    enum CaptureAccess: Equatable {
        case unverified
        case checking
        case verified
        case permissionRequired
        case failed(reason: String)
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
                "System Audio Capture needs access before processing can start."
            case .starting:
                "Airwave is preparing native audio processing."
            case .processing:
                "Airwave is processing audio without changing macOS output or volume."
            }
        }

        var isProcessing: Bool { self == .processing }
    }

    static let shared = AudioRuntimeState()

    @Published private(set) var status: Status
    @Published private(set) var captureAccess: CaptureAccess
    @Published private(set) var currentOutput: OutputDeviceDescriptor?
    @Published private(set) var warningMessage: String?

    init(
        status: Status = .unavailable("Airwave 2.0 audio backend is not installed yet"),
        currentOutput: OutputDeviceDescriptor? = nil,
        warningMessage: String? = nil,
        captureAccess: CaptureAccess = .unverified
    ) {
        self.status = status
        self.captureAccess = captureAccess
        self.currentOutput = currentOutput
        self.warningMessage = warningMessage
    }

    func setCaptureAccess(_ captureAccess: CaptureAccess) {
        self.captureAccess = captureAccess
    }

    var isSetupHealthy: Bool {
        captureAccess == .verified && (currentOutput?.isSupportedProfileOutput == true)
    }

    func publish(
        _ status: Status,
        output: OutputDeviceDescriptor? = nil,
        warning: String? = nil,
        captureAccess: CaptureAccess? = nil
    ) {
        if let captureAccess { self.captureAccess = captureAccess }
        self.currentOutput = output
        self.status = status
        self.warningMessage = warning
    }
}
