import Foundation
import Combine

@MainActor
final class AudioRuntimeState: ObservableObject {
    enum Status: Equatable {
        case unavailable(String)
        case needsSetup
        case nativePassthrough(reason: String)
        case starting
        case processing
        case recovering(reason: String)

        var title: String {
            switch self {
            case .unavailable: "Unavailable"
            case .needsSetup: "Setup required"
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

    init(status: Status = .unavailable("Airwave 2.0 audio backend is not installed yet")) {
        self.status = status
    }
}
