import Foundation
import Combine

@MainActor
final class AudioRuntimeState: ObservableObject {
    enum Status: Equatable {
        case unavailable(String)
        case needsSetup
        case needsPermission
        case nativePassthrough(reason: String)
        case starting
        case processing
        case recovering(reason: String)

        var title: String {
            switch self {
            case .unavailable: "Unavailable"
            case .needsSetup: "Setup required"
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
            case .needsSetup:
                "Airwave needs additional setup before audio processing can begin."
            case .needsPermission:
                "Allow System Audio Recording in macOS Settings to enable processing."
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
    @Published private(set) var currentOutput: OutputDeviceDescriptor?

    init(
        status: Status = .unavailable("Airwave 2.0 audio backend is not installed yet"),
        currentOutput: OutputDeviceDescriptor? = nil
    ) {
        self.status = status
        self.currentOutput = currentOutput
    }

    func publish(_ status: Status, output: OutputDeviceDescriptor? = nil) {
        self.currentOutput = output
        self.status = status
    }
}
