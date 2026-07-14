import Foundation

enum RuntimeEnvironment {
    /// XCTest host launches app bundle before executing hosted tests.
    /// Keep CoreAudio listeners, permission prompts, and recovery writes out.
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var useSelectionCoordinator: Bool {
        ProcessInfo.processInfo.arguments.contains("-UseSelectionCoordinator")
    }
}
