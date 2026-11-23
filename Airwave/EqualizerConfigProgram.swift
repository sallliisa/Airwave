import Foundation

nonisolated struct EqualizerConfigContext {
    let sampleRate: Double
    let inputChannelCount: Int
    let deviceName: String
    let deviceUID: String
}

nonisolated struct EqualizerConfigProgram: Equatable {
    let data: Data
    let filename: String
    let fileBoundaries: [EqualizerConfigFiles.ScopeBoundary]
    let assets: [Int: EqualizerConvolutionAsset]

    static func needsEvaluation(_ source: String) -> Bool {
        source.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let command = CommandLine(line) else { return false }
            return Command(rawValue: command.key) != nil || command.parameters.contains("`")
        }
    }

    func validate() throws {
        _ = try process(context: nil)
    }

    func resolve(context: EqualizerConfigContext) throws -> EqualizerDefinition {
        let activeData = try process(context: context)
        return try EqualizerAPOParser.parse(
            data: activeData, filename: filename, fileBoundaries: fileBoundaries,
            assets: assets, allowDeferred: false
        )
    }

    private func process(context: EqualizerConfigContext?) throws -> Data {
        var expression = context.map {
            EqualizerConfigExpression(
                sampleRate: $0.sampleRate, inputChannelCount: $0.inputChannelCount,
                outputChannelCount: 2, deviceName: $0.deviceName, deviceUID: $0.deviceUID, stage: "post-mix"
            )
        }
        let boundaries = Dictionary(grouping: fileBoundaries, by: \.line)
        let source = String(decoding: data, as: UTF8.self)
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var scopes: [Scope] = []
        var branches: [Branch] = []
        var deviceMatches = true
        var stageMatches = true
        var output = [String](repeating: "", count: lines.count)
        var commandCount = 0

        func fail(_ line: Int, _ reason: String) -> EqualizerParseError {
            EqualizerParseError(filename: filename, issues: [.init(lineNumber: line, reason: reason)])
        }

        for index in 0...lines.count {
            let lineNumber = index + 1
            if let events = boundaries[lineNumber] {
                for scope in events {
                    switch scope {
                    case .enter:
                        let enabled = (scopes.last?.enabled ?? true) && deviceMatches && (branches.last?.active ?? true)
                        scopes.append(Scope(branchCount: branches.count, deviceMatches: deviceMatches,
                                            stageMatches: stageMatches, enabled: enabled))
                    case .leave:
                        guard let previous = scopes.popLast(), branches.count == previous.branchCount else {
                            throw fail(lineNumber, "An If block must end in the file where it starts.")
                        }
                        deviceMatches = previous.deviceMatches
                        stageMatches = previous.stageMatches
                    }
                }
            }
            guard index < lines.count else { break }
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            commandCount += 1
            guard commandCount <= 1_024 else { throw fail(lineNumber, "Config has more than 1,024 commands.") }
            let command = CommandLine(line)
            let key = command.flatMap { Command(rawValue: $0.key) }
            let argument = command?.parameters ?? ""
            let scopeEnabled = scopes.last?.enabled ?? true
            let branchActive = scopeEnabled && deviceMatches && (branches.last?.active ?? true)
            let active = branchActive && stageMatches
            let minimumDepth = scopes.last?.branchCount ?? 0

            do {
                switch key {
                case .if:
                    guard !argument.isEmpty, branches.count < 32 else {
                        throw fail(lineNumber, "If requires an expression and supports at most 32 nesting levels.")
                    }
                    if context == nil { try EqualizerConfigExpression.validateSyntax(argument) }
                    let match = branchActive ? try expression?.evaluate(argument).boolValue ?? false : false
                    branches.append(Branch(openingLine: lineNumber, parentActive: branchActive, active: match, hasMatched: match))
                case .elseIf:
                    guard branches.count > minimumDepth, !branches[branches.count - 1].hasElse, !argument.isEmpty else {
                        throw fail(lineNumber, "ElseIf requires an expression and a preceding If.")
                    }
                    if context == nil { try EqualizerConfigExpression.validateSyntax(argument) }
                    let last = branches.count - 1
                    var branch = branches[last]
                    branch.active = false
                    if branch.parentActive && scopeEnabled && deviceMatches && !branch.hasMatched {
                        branch.active = try expression?.evaluate(argument).boolValue ?? false
                        branch.hasMatched = branch.active
                    }
                    branches[last] = branch
                case .else:
                    guard branches.count > minimumDepth, !branches[branches.count - 1].hasElse, argument.isEmpty else {
                        throw fail(lineNumber, "Else must follow If or ElseIf, with no argument.")
                    }
                    let last = branches.count - 1
                    branches[last].active = branches[last].parentActive && !branches[last].hasMatched
                    branches[last].hasElse = true
                case .endIf:
                    guard branches.count > minimumDepth, argument.isEmpty else {
                        throw fail(lineNumber, "EndIf must close a preceding If, with no argument.")
                    }
                    branches.removeLast()
                case .device:
                    let patterns = argument.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard patterns.contains(where: { !$0.isEmpty }) else { throw fail(lineNumber, "Device requires a selector.") }
                    if scopeEnabled, let context {
                        let identity = "\(context.deviceName) \(context.deviceUID)".lowercased()
                        deviceMatches = patterns.contains { pattern in
                            let words = pattern.lowercased().split(whereSeparator: \.isWhitespace)
                            return pattern.lowercased() == "all" || (!words.isEmpty && words.allSatisfy { identity.contains($0) })
                        }
                    }
                case .stage:
                    let stages = argument.lowercased().split(whereSeparator: \.isWhitespace)
                    guard !stages.isEmpty, stages.allSatisfy({ ["post-mix", "pre-mix", "capture"].contains($0) }) else {
                        throw fail(lineNumber, "Stage requires post-mix, pre-mix, or capture.")
                    }
                    if branchActive && context != nil { stageMatches = stages.contains("post-mix") }
                case .eval:
                    guard !argument.isEmpty else { throw fail(lineNumber, "Eval requires an expression.") }
                    if context == nil && !argument.contains("`") {
                        try EqualizerConfigExpression.validateSyntax(argument)
                    }
                    if branchActive, let expanded = try expression?.expandInline(argument) {
                        _ = try expression?.evaluate(expanded)
                    }
                case nil:
                    if active, context != nil {
                        if let command, let expanded = try expression?.expandInline(command.parameters) {
                            guard !expanded.contains(where: \.isNewline) else {
                                throw fail(lineNumber, "Inline expressions must expand to a single line.")
                            }
                            output[index] = "\(command.originalKey): \(expanded)"
                        } else {
                            output[index] = line
                        }
                    }
                }
            } catch let error as EqualizerParseError {
                throw error
            } catch {
                throw fail(lineNumber, error.localizedDescription)
            }
        }
        if let opening = branches.last {
            throw fail(opening.openingLine, "If must end with EndIf.")
        }

        return Data(output.joined(separator: "\n").utf8)
    }

    private enum Command: String {
        case `if`, elseIf = "elseif", `else`, endIf = "endif", eval, device, stage
    }

    private struct CommandLine {
        let originalKey: String
        let key: String
        let parameters: String

        init?(_ line: String) {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            originalKey = line[..<colon].trimmingCharacters(in: .whitespaces)
            key = originalKey.lowercased()
            parameters = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    private struct Scope {
        let branchCount: Int
        let deviceMatches: Bool
        let stageMatches: Bool
        let enabled: Bool
    }

    private struct Branch {
        let openingLine: Int
        let parentActive: Bool
        var active: Bool
        var hasMatched: Bool
        var hasElse = false
    }
}
