import XCTest
@testable import Airwave

@MainActor
final class AudioRuntimeStateTests: XCTestCase {
    func testInitialStateIsUnavailableWithMigrationMessage() {
        let runtime = AudioRuntimeState()

        XCTAssertEqual(
            runtime.status,
            .unavailable("Airwave 2.0 audio backend is not installed yet")
        )
        XCTAssertEqual(runtime.status.title, "Unavailable")
        XCTAssertFalse(runtime.status.isProcessing)
    }

    func testStatusDisplayMappingIsFiniteAndTruthful() {
        let values: [(AudioRuntimeState.Status, String, String)] = [
            (.needsSetup, "Setup required", "Airwave needs additional setup before audio processing can begin."),
            (.nativePassthrough(reason: "Safe mode"), "Native passthrough", "Safe mode"),
            (.starting, "Starting", "Airwave is preparing native audio processing."),
            (.processing, "Processing", "Airwave is processing audio without changing macOS output or volume."),
            (.recovering(reason: "Retrying"), "Recovering", "Retrying")
        ]

        for (status, title, detail) in values {
            XCTAssertEqual(status.title, title)
            XCTAssertEqual(status.detail, detail)
        }
        XCTAssertTrue(AudioRuntimeState.Status.processing.isProcessing)
    }
}
