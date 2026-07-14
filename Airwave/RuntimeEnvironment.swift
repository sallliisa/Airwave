import Foundation

enum RuntimeEnvironment {
    /// XCTest host launches app bundle before executing hosted tests.
    /// Keep CoreAudio listeners, permission prompts, and recovery writes out.
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var useSelectionCoordinator: Bool {
        guard !isTestHost else { return false }
        return !ProcessInfo.processInfo.arguments.contains("-UseLegacyRouting")
    }
}
