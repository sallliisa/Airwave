import XCTest
@testable import Airwave

final class ConvolutionEngineTests: XCTestCase {
    private let blockSize = 8

    private func makeEngine() -> ConvolutionEngine {
        let impulse = [Float](arrayLiteral: 1, 0, 0, 0, 0, 0, 0, 0)
        return try! XCTUnwrap(ConvolutionEngine(hrirSamples: impulse, blockSize: blockSize))
    }

    func testImpulsePreservesSampleOrder() {
        let engine = makeEngine()
        let input: [Float] = [0.25, -0.5, 1, 0.75, -1, 0.125, 0.5, -0.25]
        var output = [Float](repeating: 0, count: blockSize)

        engine.process(input: input, output: &output)

        XCTAssertTrue(zip(output, input).allSatisfy { abs($0.0 - $0.1) < 0.0001 })
    }

    func testResetClearsOverlapAndFrequencyHistory() {
        let engine = makeEngine()
        var input = [Float](repeating: 0, count: blockSize)
        input[blockSize - 1] = 1
        var output = [Float](repeating: 0, count: blockSize)
        engine.process(input: input, output: &output)

        engine.reset()
        input = [Float](repeating: 0, count: blockSize)
        engine.process(input: input, output: &output)

        XCTAssertTrue(output.allSatisfy { abs($0) < 0.0001 })
    }

    func testMultipleBlocksRemainFinite() {
        let engine = makeEngine()
        var input = (0..<blockSize).map { Float($0) / 7 }
        var output = [Float](repeating: 0, count: blockSize)

        for _ in 0..<64 {
            engine.process(input: input, output: &output)
            XCTAssertTrue(output.allSatisfy { $0.isFinite })
            input = input.map { -$0 * 0.97 + 0.01 }
        }
    }

    func testIdenticalInputAfterResetProducesIdenticalOutput() {
        let engine = makeEngine()
        let input = [Float](stride(from: -0.75, through: 0.75, by: 0.2)).prefix(blockSize)
        var first = [Float](repeating: 0, count: blockSize)
        var second = [Float](repeating: 0, count: blockSize)

        engine.process(input: Array(input), output: &first)
        engine.reset()
        engine.process(input: Array(input), output: &second)

        XCTAssertTrue(zip(first, second).allSatisfy { abs($0.0 - $0.1) < 0.0001 })
    }
}
