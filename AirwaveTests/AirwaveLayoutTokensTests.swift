import XCTest
@testable import Airwave

final class AirwaveLayoutTokensTests: XCTestCase {
    func testTopBarControlsMeetMinimumHitTarget() {
        XCTAssertGreaterThanOrEqual(AirwaveLayout.topBarControlMinSize, 44)
    }
}
