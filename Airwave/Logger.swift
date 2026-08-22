import Foundation
import os

/// os_log destinations for incidents that must be visible in the unified log
/// (`log stream`/`log show`) even when the DEBUG print path is compiled out.
/// Subsystem matches the bundle so coreaudiod/HAL lines join Airwave's stream.
nonisolated enum AirwaveLog {
    static let subsystem = "com.southneuhof.Airwave"

    /// Pipeline lifecycle: tap/aggregate/IO creation, destruction, retries.
    static let audioRuntime = os.Logger(subsystem: subsystem, category: "audioRuntime")
    /// Output-device observation and route changes.
    static let deviceRoute = os.Logger(subsystem: subsystem, category: "deviceRoute")
    /// Capture verification (probe) outcomes.
    static let captureVerification = os.Logger(subsystem: subsystem, category: "captureVerification")
}

nonisolated enum Logger {
    static func log(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        #if DEBUG
        let output = items.map { "\($0)" }.joined(separator: separator)
        print(output, terminator: terminator)
        #endif
    }
}
