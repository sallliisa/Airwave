import Foundation

nonisolated struct EqualizerParseIssue: Equatable {
    let lineNumber: Int?
    let reason: String
}

nonisolated struct EqualizerParseError: LocalizedError, Equatable {
    let filename: String
    let issues: [EqualizerParseIssue]

    var errorDescription: String? {
        let details = issues.map { issue in
            if let lineNumber = issue.lineNumber {
                return "line \(lineNumber): \(issue.reason)"
            }
            return issue.reason
        }.joined(separator: "; ")
        return "Could not read \(filename): \(details)"
    }
}

nonisolated struct EqualizerAPOParser {
    static let maximumDataSize = 1_048_576
    static let maximumFilterCount = 64
    static let maximumGraphicCurveCount = 4
    static let maximumGraphicPointCount = 1_024

    private static let preampRegex = try! NSRegularExpression(
        pattern: #"^Preamp\s*:\s*(\S+)\s+dB$"#,
        options: [.caseInsensitive]
    )
    private static let filterRegex = try! NSRegularExpression(
        pattern: #"^Filter(?:\s+([0-9]+))?\s*:\s+(ON|OFF)\s+(PK|LSC|HSC)\s+Fc\s+(\S+)\s+Hz\s+Gain\s+(\S+)\s+dB\s+Q\s+(\S+)$"#,
        options: [.caseInsensitive]
    )
    private static let graphicRegex = try! NSRegularExpression(
        pattern: #"^GraphicEQ\s*:\s*(.*)$"#,
        options: [.caseInsensitive]
    )

    private struct GraphicParseError: Error {
        let reason: String
    }

    static func parse(data: Data, filename: String) throws -> EqualizerDefinition {
        guard data.count <= maximumDataSize else {
            throw EqualizerParseError(
                filename: filename,
                issues: [.init(lineNumber: nil, reason: "file exceeds the 1 MiB limit")]
            )
        }
        guard var source = String(data: data, encoding: .utf8) else {
            throw EqualizerParseError(
                filename: filename,
                issues: [.init(lineNumber: nil, reason: "file is not valid UTF-8")]
            )
        }
        if source.first == "\u{FEFF}" {
            source.removeFirst()
        }

        var hasPreamp = false
        var filterDeclarationCount = 0
        var graphicDeclarationCount = 0
        var directives: [EqualizerDirective] = []
        var issues: [EqualizerParseIssue] = []

        for (index, rawLine) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if let captures = captures(for: preampRegex, in: line) {
                if hasPreamp {
                    issues.append(.init(lineNumber: lineNumber, reason: "duplicate Preamp directive"))
                    continue
                }
                guard let value = finiteDouble(captures[0]) else {
                    issues.append(.init(lineNumber: lineNumber, reason: "Preamp must be a finite number"))
                    continue
                }
                directives.append(.preamp(value))
                hasPreamp = true
                continue
            }

            let lowercased = line.lowercased()
            if lowercased.hasPrefix("graphiceq") {
                graphicDeclarationCount += 1
                guard graphicDeclarationCount <= maximumGraphicCurveCount else {
                    issues.append(.init(
                        lineNumber: lineNumber,
                        reason: "more than \(maximumGraphicCurveCount) GraphicEQ declarations are not allowed"
                    ))
                    continue
                }
                guard let captures = captures(for: graphicRegex, in: line) else {
                    issues.append(.init(lineNumber: lineNumber, reason: "malformed GraphicEQ directive"))
                    continue
                }
                do {
                    let points = try parseGraphicPoints(captures[0])
                    directives.append(.graphic(.init(sourceLine: lineNumber, points: points)))
                } catch {
                    issues.append(.init(lineNumber: lineNumber, reason: error.reason))
                }
                continue
            }

            if lowercased.hasPrefix("filter") {
                filterDeclarationCount += 1
                if filterDeclarationCount > maximumFilterCount {
                    issues.append(.init(lineNumber: lineNumber, reason: "more than 64 filter declarations are not allowed"))
                    continue
                }
                guard let captures = captures(for: filterRegex, in: line) else {
                    issues.append(.init(lineNumber: lineNumber, reason: "malformed Filter directive"))
                    continue
                }

                let sourceNumber = captures[0].isEmpty ? nil : Int(captures[0])
                let isEnabled = captures[1].caseInsensitiveCompare("ON") == .orderedSame
                let type: EqualizerFilterType
                switch captures[2].uppercased() {
                case "PK": type = .peaking
                case "LSC": type = .lowShelf
                case "HSC": type = .highShelf
                default:
                    issues.append(.init(lineNumber: lineNumber, reason: "unsupported filter type"))
                    continue
                }

                let frequencyHz = finiteDouble(captures[3])
                let gainDB = finiteDouble(captures[4])
                let q = finiteDouble(captures[5])
                var numericIssues: [String] = []
                if let frequencyHz {
                    if frequencyHz <= 0 { numericIssues.append("frequency must be positive") }
                } else {
                    numericIssues.append("frequency must be a finite number")
                }
                if gainDB == nil {
                    numericIssues.append("gain must be a finite number")
                }
                if let q {
                    if q <= 0 { numericIssues.append("Q must be positive") }
                } else {
                    numericIssues.append("Q must be a finite number")
                }
                if !numericIssues.isEmpty {
                    issues.append(contentsOf: numericIssues.map { .init(lineNumber: lineNumber, reason: $0) })
                    continue
                }

                guard let frequencyHz, let gainDB, let q else { continue }

                directives.append(.parametric(EqualizerFilter(
                    sourceLine: lineNumber,
                    sourceNumber: sourceNumber,
                    isEnabled: isEnabled,
                    type: type,
                    frequencyHz: frequencyHz,
                    gainDB: gainDB,
                    q: q
                )))
                continue
            }

            if lowercased.hasPrefix("preamp") {
                issues.append(.init(lineNumber: lineNumber, reason: "malformed Preamp directive"))
            } else {
                issues.append(.init(lineNumber: lineNumber, reason: "unsupported directive"))
            }
        }

        if issues.isEmpty && !directives.contains(where: isEffective) {
            issues.append(.init(
                lineNumber: nil,
                reason: "effective configuration must contain a non-zero preamp, an enabled filter, or a GraphicEQ curve"
            ))
        }
        guard issues.isEmpty else {
            throw EqualizerParseError(filename: filename, issues: issues)
        }
        return EqualizerDefinition(directives: directives)
    }

    private static func isEffective(_ directive: EqualizerDirective) -> Bool {
        switch directive {
        case .preamp(let gainDB): gainDB != 0
        case .parametric(let filter): filter.isEnabled
        case .graphic: true
        }
    }

    private static func parseGraphicPoints(_ argument: String) throws(GraphicParseError) -> [EqualizerGraphicPoint] {
        let normalized = argument.contains(".") ? argument : argument.replacingOccurrences(of: ",", with: ".")
        let value = normalized.last == ";" ? normalized.dropLast() : normalized[...]
        let pairs = value.split(
            separator: ";",
            maxSplits: maximumGraphicPointCount,
            omittingEmptySubsequences: false
        )
        guard pairs.count <= maximumGraphicPointCount else {
            throw GraphicParseError(reason: "more than \(maximumGraphicPointCount) GraphicEQ points are not allowed")
        }

        guard !value.isEmpty else {
            throw GraphicParseError(reason: "GraphicEQ needs at least one frequency and gain pair")
        }

        var points: [EqualizerGraphicPoint] = []
        var frequencies: Set<Double> = []
        for pair in pairs {
            let fields = pair.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  let frequencyHz = finiteDouble(fields[0]), frequencyHz >= 0,
                  let gainDB = finiteDouble(fields[1]) else {
                throw GraphicParseError(reason: "GraphicEQ needs pairs of non-negative frequencies and finite gains")
            }
            guard frequencies.insert(frequencyHz).inserted else {
                throw GraphicParseError(reason: "duplicate GraphicEQ frequency \(frequencyHz) Hz")
            }
            points.append(.init(frequencyHz: frequencyHz, gainDB: gainDB))
        }
        return points.sorted { $0.frequencyHz < $1.frequencyHz }
    }

    private static func finiteDouble(_ value: some StringProtocol) -> Double? {
        guard let number = Double(value), number.isFinite else { return nil }
        return number
    }

    private static func captures(for regex: NSRegularExpression, in line: String) -> [String]? {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: fullRange), match.range == fullRange else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return "" }
            return String(line[swiftRange])
        }
    }
}
