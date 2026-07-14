import XCTest
@testable import Airwave

final class UpdateStateModelTests: XCTestCase {
    func testInitialStateIsIdle() {
        XCTAssertEqual(UpdateStateModel().state, .idle)
    }

    func testCheckingTransition() {
        var model = UpdateStateModel()
        model.beganChecking()
        XCTAssertEqual(model.state, .checking)
    }

    func testAvailableTransitionIncludesDisplayVersion() {
        var model = UpdateStateModel()
        model.found(version: "1.2.0")
        XCTAssertEqual(model.state, .available(version: "1.2.0"))
    }

    func testCurrentTransition() {
        var model = UpdateStateModel()
        model.foundNoUpdate()
        XCTAssertEqual(model.state, .current)
    }

    func testErrorTransitionIncludesMessageAndCanRetry() {
        var model = UpdateStateModel()
        model.failed(message: "Feed unavailable")
        XCTAssertEqual(model.state, .error(message: "Feed unavailable"))

        model.beganChecking()
        XCTAssertEqual(model.state, .checking)
    }
}
