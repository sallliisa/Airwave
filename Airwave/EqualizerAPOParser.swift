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

    private static let preampRegex = try! NSRegularExpression(
        pattern: #"^Preamp\s*:\s*(\S+)\s+dB$"#,
        options: [.caseInsensitive]
    )
    private static let filterRegex = try! NSRegularExpression(
        pattern: #"^Filter(?:\s+([0-9]+))?\s*:\s+(ON|OFF)\s+(PK|LSC|HSC)\s+Fc\s+(\S+)\s+Hz\s+Gain\s+(\S+)\s+dB\s+Q\s+(\S+)$"#,
        options: [.caseInsensitive]
    )

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

        var preampDB = 0.0
        var hasPreamp = false
        var filterDeclarationCount = 0
        var filters: [EqualizerFilter] = []
        var issues: [EqualizerParseIssue] = []

        for (index, rawLine) in source.components(separatedBy: .newlines).enumerated() {
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
                preampDB = value
                hasPreamp = true
                continue
            }

            if line.lowercased().hasPrefix("filter") {
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

                filters.append(EqualizerFilter(
                    sourceLine: lineNumber,
                    sourceNumber: sourceNumber,
                    isEnabled: isEnabled,
                    type: type,
                    frequencyHz: frequencyHz,
                    gainDB: gainDB,
                    q: q
                ))
                continue
            }

            if line.lowercased().hasPrefix("preamp") {
                issues.append(.init(lineNumber: lineNumber, reason: "malformed Preamp directive"))
            } else {
                issues.append(.init(lineNumber: lineNumber, reason: "unsupported directive"))
            }
        }

        if issues.isEmpty && preampDB == 0 && !filters.contains(where: \.isEnabled) {
            issues.append(.init(lineNumber: nil, reason: "effective configuration must contain a non-zero preamp or an enabled supported filter"))
        }
        guard issues.isEmpty else {
            throw EqualizerParseError(filename: filename, issues: issues)
        }
        return EqualizerDefinition(preampDB: preampDB, filters: filters)
    }

    private static func finiteDouble(_ value: String) -> Double? {
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
