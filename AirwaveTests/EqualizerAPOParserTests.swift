import Foundation
import XCTest
@testable import Airwave

@MainActor
final class EqualizerAPOParserTests: XCTestCase {
    func testReferenceFixtureParsesExactly() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("CCA CRA ParametricEq.txt")
        let definition = try EqualizerAPOParser.parse(
            data: Data(contentsOf: fixtureURL),
            filename: fixtureURL.lastPathComponent
        )

        XCTAssertEqual(definition.preampDB, -2.56)
        XCTAssertEqual(definition.filters.count, 10)
        XCTAssertEqual(definition.filters.first?.type, .lowShelf)
        XCTAssertEqual(definition.filters.last?.type, .highShelf)
        XCTAssertTrue(definition.filters.allSatisfy(\.isEnabled))
        XCTAssertEqual(definition.filters.map(\.frequencyHz), [105.0, 65.3, 180.0, 625.7, 894.2, 1431.5, 3020.2, 6165.4, 9079.1, 10000.0])
        XCTAssertEqual(definition.filters.map(\.gainDB), [-2.8, 1.0, -2.2, 0.6, 2.0, -1.5, 2.5, 2.3, 1.2, -5.2])
        XCTAssertEqual(definition.filters.map(\.q), [0.70, 1.68, 1.08, 1.07, 1.24, 1.77, 2.25, 5.37, 2.75, 0.70])
    }

    func testParsesSupportedDefinitionInSourceOrder() throws {
        let source = """
        # comment
        Preamp: -2.5 dB
        Filter 7: ON PK Fc 1000 Hz Gain 3.25 dB Q 1.20
        Filter: off LSC Fc 80 Hz Gain -1 dB Q 0.7
        Filter 9: ON HSC Fc 10000 Hz Gain -2 dB Q 0.70
        """

        let definition = try EqualizerAPOParser.parse(data: Data(source.utf8), filename: "curve.txt")

        XCTAssertEqual(definition.preampDB, -2.5)
        XCTAssertEqual(definition.filters.map(\.sourceLine), [3, 4, 5])
        XCTAssertEqual(definition.filters.map(\.sourceNumber), [7, nil, 9])
        XCTAssertEqual(definition.filters.map(\.isEnabled), [true, false, true])
        XCTAssertEqual(definition.filters.map(\.type), [.peaking, .lowShelf, .highShelf])
        XCTAssertEqual(definition.filters.map(\.frequencyHz), [1000, 80, 10000])
    }

    func testAcceptsBOMCRLFWhitespaceCaseAndComments() throws {
        let source = "\u{FEFF}  pReAmP : 1e0 dB\r\n\t# ignored\r\n fIlTeR 1 : oN pK Fc 440 Hz gAiN 2 dB q 1\r\n"

        let definition = try EqualizerAPOParser.parse(data: Data(source.utf8), filename: "mixed.txt")

        XCTAssertEqual(definition.preampDB, 1)
        XCTAssertEqual(definition.filters.count, 1)
        XCTAssertEqual(definition.filters[0].gainDB, 2)
    }

    func testMissingPreampDefaultsToZeroAndOFFDoesNotMakeConfigurationEffective() throws {
        let source = "Filter 1: OFF PK Fc 440 Hz Gain 2 dB Q 1"
        let error = try parseError(source)
        XCTAssertTrue(error.issues.contains { $0.reason.contains("effective") })

        let enabled = try EqualizerAPOParser.parse(
            data: Data("Filter 1: ON PK Fc 440 Hz Gain 2 dB Q 1".utf8),
            filename: "test.txt"
        )
        XCTAssertEqual(enabled.preampDB, 0)
        XCTAssertTrue(enabled.filters[0].isEnabled)
    }

    func testRejectsMalformedUnsupportedAndDuplicateDirectives() throws {
        let source = """
        Preamp: 1 dB
        Preamp: 2 dB
        Filter 1: ON PK Fc 440 Hz Gain 2 dB
        Include: other.txt
        """

        let error = try parseError(source, filename: "bad.txt")

        XCTAssertEqual(error.filename, "bad.txt")
        XCTAssertTrue(error.issues.contains { $0.lineNumber == 2 && $0.reason.contains("duplicate") })
        XCTAssertTrue(error.issues.contains { $0.lineNumber == 3 && $0.reason.contains("malformed") })
        XCTAssertTrue(error.issues.contains { $0.lineNumber == 4 && $0.reason.contains("unsupported") })
    }

    func testRejectsNonFiniteNonPositiveAndTooManyFilters() throws {
        let invalidNumbers = """
        Preamp: NaN dB
        Filter 1: ON PK Fc 0 Hz Gain inf dB Q -1
        """
        let numberError = try parseError(invalidNumbers)
        XCTAssertTrue(numberError.issues.contains { $0.reason.contains("finite") })
        XCTAssertTrue(numberError.issues.contains { $0.reason.contains("frequency") })
        XCTAssertTrue(numberError.issues.contains { $0.reason.contains("Q") })

        let filters = (1...65).map { "Filter \($0): ON PK Fc \($0) Hz Gain 1 dB Q 1" }.joined(separator: "\n")
        let limitError = try parseError(filters)
        XCTAssertTrue(limitError.issues.contains { $0.reason.contains("64") })
    }

    func testRejectsOversizedData() throws {
        let data = Data(repeating: 0x20, count: EqualizerAPOParser.maximumDataSize + 1)
        let error = try parseError(data: data, filename: "large.txt")
        XCTAssertEqual(error.filename, "large.txt")
        XCTAssertTrue(error.issues.contains { $0.reason.contains("1 MiB") })
    }

    private func parseError(_ source: String, filename: String = "test.txt") throws -> EqualizerParseError {
        try parseError(data: Data(source.utf8), filename: filename)
    }

    private func parseError(data: Data, filename: String) throws -> EqualizerParseError {
        do {
            _ = try EqualizerAPOParser.parse(data: data, filename: filename)
            XCTFail("Expected parser error")
            throw TestError.unexpectedSuccess
        } catch let error as EqualizerParseError {
            return error
        }
    }
}

private enum TestError: Error {
    case unexpectedSuccess
}
