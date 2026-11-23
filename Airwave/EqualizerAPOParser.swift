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
    private static let filterDirectiveRegex = try! NSRegularExpression(
        pattern: #"^Filter(?:\s+([0-9]+))?\s*:\s*(ON|OFF)(?:\s+(.*))?$"#,
        options: [.caseInsensitive]
    )
    private static let filterParametersRegex = try! NSRegularExpression(
        pattern: #"^([a-z]+)(?:\s+(\S+?)\s*dB)?\s+Fc\s*((?:\S|\u00A0)+?)\s*H\s*z(?:\s+Gain\s*(\S+?)\s*dB)?(?:\s+(?:(Q)|(BW\s+Oct))\s*(\S+))?(?:\s+T60\s+target\s+(\S+)\s*ms)?$"#,
        options: [.caseInsensitive]
    )
    private static let graphicRegex = try! NSRegularExpression(
        pattern: #"^GraphicEQ\s*:\s*(.*)$"#,
        options: [.caseInsensitive]
    )

    private struct GraphicParseError: Error {
        let reason: String
    }

    private struct FilterParseError: Error {
        let reason: String
    }

    static func parse(
        data: Data, filename: String, fileBoundaries: [EqualizerConfigFiles.ScopeBoundary] = [],
        assets: [Int: EqualizerConvolutionAsset] = [:]
    ) throws -> EqualizerDefinition {
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

        var filterDeclarationCount = 0
        var graphicDeclarationCount = 0
        var stereoDeclarationCount = 0
        var directives: [EqualizerDirective] = []
        var issues: [EqualizerParseIssue] = []
        let boundaries = Dictionary(grouping: fileBoundaries, by: \.line)
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            if let scopes = boundaries[lineNumber] {
                directives.append(contentsOf: scopes.map(\.directive))
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if let captures = captures(for: preampRegex, in: line) {
                guard let value = filterNumber(captures[0]) else {
                    issues.append(.init(lineNumber: lineNumber, reason: "Preamp must be a finite number"))
                    continue
                }
                directives.append(.preamp(value))
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
                guard let captures = captures(for: filterDirectiveRegex, in: line) else {
                    issues.append(.init(lineNumber: lineNumber, reason: "malformed Filter directive"))
                    continue
                }

                let isEnabled = captures[1].caseInsensitiveCompare("ON") == .orderedSame
                if captures[2].caseInsensitiveCompare("None") == .orderedSame {
                    continue
                }
                do {
                    let filter = try parseFilter(
                        captures[2], lineNumber: lineNumber, sourceNumber: Int(captures[0]), isEnabled: isEnabled
                    )
                    directives.append(.parametric(filter))
                } catch {
                    if isEnabled {
                        issues.append(.init(lineNumber: lineNumber, reason: error.reason))
                    }
                }
                continue
            }

            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if fields.count == 2 {
                let commandName = fields[0].trimmingCharacters(in: .whitespaces)
                if commandName.caseInsensitiveCompare("Convolution") == .orderedSame {
                    if let asset = assets[lineNumber] {
                        directives.append(.convolution(asset))
                    } else {
                        issues.append(.init(lineNumber: lineNumber, reason: "import the config folder with its WAV impulse responses"))
                    }
                    continue
                }
                do {
                    if let command = try EqualizerStereoCommand.parse(
                        command: commandName,
                        parameters: String(fields[1])
                    ) {
                        stereoDeclarationCount += 1
                        if stereoDeclarationCount > 64 {
                            issues.append(.init(lineNumber: lineNumber, reason: "more than 64 stereo commands are not allowed"))
                        } else {
                            directives.append(.stereo(command, line: lineNumber))
                        }
                        continue
                    }
                } catch {
                    issues.append(.init(lineNumber: lineNumber, reason: error.localizedDescription))
                    continue
                }
            }
            if lowercased.hasPrefix("preamp") {
                issues.append(.init(lineNumber: lineNumber, reason: "malformed Preamp directive"))
            } else {
                issues.append(.init(lineNumber: lineNumber, reason: "unsupported directive"))
            }
        }
        if let scopes = boundaries[lines.count + 1] {
            directives.append(contentsOf: scopes.map(\.directive))
        }

        if issues.isEmpty && !directives.contains(where: isEffective) {
            issues.append(.init(
                lineNumber: nil,
                reason: "effective configuration must contain a non-zero preamp, an enabled filter, a GraphicEQ curve, Copy, or Delay"
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
        case .graphic, .convolution: true
        case .stereo(.channel, _), .enterInclude, .leaveInclude: false
        case .stereo: true
        }
    }

    private static func parseFilter(
        _ argument: String,
        lineNumber: Int,
        sourceNumber: Int?,
        isEnabled: Bool
    ) throws(FilterParseError) -> EqualizerFilter {
        guard let fields = captures(for: filterParametersRegex, in: argument) else {
            throw FilterParseError(reason: "malformed Filter parameters")
        }
        let spelling = fields[0].uppercased()
        let type: EqualizerFilterType
        switch spelling {
        case "PK", "PEQ", "MODAL": type = .peaking
        case "LP", "LPQ": type = .lowPass
        case "HP", "HPQ": type = .highPass
        case "BP": type = .bandPass
        case "NO": type = .notch
        case "AP": type = .allPass
        case "LS", "LSC": type = .lowShelf
        case "HS", "HSC": type = .highShelf
        default: throw FilterParseError(reason: "unsupported filter type \(fields[0])")
        }

        let frequency = fields[2].replacingOccurrences(of: "\u{00A0}", with: "")
        guard let frequencyHz = filterNumber(frequency), frequencyHz > 0 else {
            throw FilterParseError(reason: "filter frequency must be finite and positive")
        }
        let isShelf = type == .lowShelf || type == .highShelf
        let requiresGain = isShelf || type == .peaking
        guard let gainDB = fields[3].isEmpty && !requiresGain ? 0 : filterNumber(fields[3]) else {
            throw FilterParseError(reason: "filter requires a finite gain")
        }
        guard fields[7].isEmpty || (spelling == "MODAL" && filterNumber(fields[7]) != nil) else {
            throw FilterParseError(reason: "malformed Filter parameters")
        }

        let frequencyReference: EqualizerShelfFrequency = isShelf && !spelling.hasSuffix("C") ? .corner : .center
        let shape: EqualizerFilterShape
        if !fields[1].isEmpty {
            guard isShelf, fields[6].isEmpty,
                  let slope = filterNumber(fields[1]), slope > 0 else {
                throw FilterParseError(reason: "shelf slope must be positive and used by itself on a shelf filter")
            }
            shape = .shelfSlope(normalized: slope / 12, frequency: frequencyReference)
        } else if !fields[4].isEmpty {
            guard let q = filterNumber(fields[6]), q > 0 else {
                throw FilterParseError(reason: "filter Q must be finite and positive")
            }
            shape = .q(q, frequency: frequencyReference)
        } else if !fields[5].isEmpty {
            guard !isShelf, let bandwidth = filterNumber(fields[6]), bandwidth > 0 else {
                throw FilterParseError(reason: "filter octave bandwidth must be positive and used on a non-shelf filter")
            }
            shape = .bandwidthOctaves(bandwidth)
        } else {
            switch type {
            case .peaking, .allPass:
                throw FilterParseError(reason: "filter requires Q or octave bandwidth")
            case .lowShelf, .highShelf:
                // Equalizer APO uses a center frequency for a shelf with no explicit slope or Q.
                shape = .shelfSlope(normalized: 0.9, frequency: .center)
            case .lowPass, .highPass, .bandPass:
                shape = .q(sqrt(0.5))
            case .notch:
                shape = .q(30)
            }
        }
        return EqualizerFilter(
            sourceLine: lineNumber,
            sourceNumber: sourceNumber,
            isEnabled: isEnabled,
            type: type,
            frequencyHz: frequencyHz,
            gainDB: gainDB,
            shape: shape
        )
    }

    private static func filterNumber(_ value: String) -> Double? {
        finiteDouble(value.replacingOccurrences(of: ",", with: "."))
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
