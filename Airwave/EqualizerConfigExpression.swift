import Foundation

nonisolated struct EqualizerConfigExpression {
    indirect enum Value: Equatable {
        case number(Double)
        case bool(Bool)
        case string(String)
        case array([Value])

        var boolValue: Bool {
            switch self {
            case let .number(value): return value != 0
            case let .bool(value): return value
            case let .string(value): return !value.isEmpty && value != "false" && value != "0"
            case let .array(items): return !items.isEmpty
            }
        }

        var rendered: String {
            switch self {
            case let .number(value):
                if let integer = Int64(exactly: value) { return String(integer) }
                return String(value)
            case let .bool(value): return String(value)
            case let .string(value): return value
            case let .array(items): return "{" + items.map(\.rendered).joined(separator: ",") + "}"
            }
        }

        fileprivate var size: Int {
            switch self {
            case let .string(value): return value.utf8.count + 1
            case let .array(items): return 1 + items.reduce(0) { $0 + $1.size }
            default: return 1
            }
        }

        fileprivate var depth: Int {
            if case let .array(items) = self {
                return 1 + (items.map(\.depth).max() ?? 0)
            }
            return 0
        }

        fileprivate func number() throws -> Double {
            guard case let .number(value) = self else { throw Problem("expected a number") }
            return value
        }

        fileprivate func string() throws -> String {
            guard case let .string(value) = self else { throw Problem("expected a string") }
            return value
        }

        fileprivate func integer() throws -> Int64 {
            let value = try number()
            guard let integer = Int64(exactly: value) else { throw Problem("expected an integer") }
            return integer
        }
    }

    struct Problem: LocalizedError {
        let reason: String

        init(_ reason: String) {
            self.reason = reason
        }

        var errorDescription: String? { reason }
    }

    private static let maximumSize = 8_192
    private let constants: [String: Value]
    private var variables: [String: Value] = [:]

    init(
        sampleRate: Double,
        inputChannelCount: Int,
        outputChannelCount: Int,
        deviceName: String,
        deviceUID: String,
        stage: String
    ) {
        constants = [
            "e": .number(exp(1)),
            "pi": .number(.pi),
            "sampleRate": .number(sampleRate),
            "inputChannelCount": .number(Double(inputChannelCount)),
            "outputChannelCount": .number(Double(outputChannelCount)),
            "deviceName": .string(deviceName),
            "connectionName": .string(deviceName),
            "deviceGuid": .string(deviceUID),
            "deviceUID": .string(deviceUID),
            "stage": .string(stage)
        ]
    }

    mutating func evaluate(_ source: String) throws -> Value {
        var parser = try Parser(source)
        var result = try run(parser.parse())
        while parser.consume(";") {
            if parser.current == .end { return result }
            result = try run(parser.parse())
        }
        guard parser.current == .end else { throw Problem("unexpected token in expression") }
        return result
    }

    static func validateSyntax(_ source: String) throws {
        var parser = try Parser(source)
        _ = try parser.parse()
        while parser.consume(";"), parser.current != .end { _ = try parser.parse() }
        guard parser.current == .end else { throw Problem("unexpected token in expression") }
    }

    mutating func expandInline(_ argument: String) throws -> String {
        guard argument.contains("`") else { return argument }
        var output = ""
        var pendingExpression: String?
        var characters = argument.makeIterator()
        var next = characters.next()
        while let char = next {
            next = characters.next()
            if char == "\\" && next == "`" {
                if pendingExpression != nil {
                    pendingExpression?.append("`")
                } else {
                    output.append("`")
                }
                next = characters.next()
            } else if char == "`" {
                if let expression = pendingExpression {
                    output += try evaluate(expression).rendered
                    pendingExpression = nil
                } else {
                    pendingExpression = ""
                }
            } else if pendingExpression != nil {
                pendingExpression?.append(char)
            } else {
                output.append(char)
            }
            guard output.utf8.count <= Self.maximumSize,
                  (pendingExpression?.utf8.count ?? 0) <= Self.maximumSize else {
                throw Problem("expanded expression exceeds the size limit")
            }
        }
        guard pendingExpression == nil else { throw Problem("unterminated inline expression") }
        return output
    }

    private mutating func run(_ expression: Expression) throws -> Value {
        switch expression {
        case let .literal(value):
            return value
        case let .variable(name):
            return try value(for: name)
        case let .unary(op, operand):
            let value = try run(operand)
            switch op {
            case "-": return try Self.finite(-value.number())
            case "+", "float": return try Self.finite(value.number())
            case "int": return try Self.finite(value.number().rounded(.towardZero))
            default: return .bool(!value.boolValue)
            }
        case let .binary(op, lhs, rhs):
            let left = try run(lhs)
            if op == "and" && !left.boolValue { return .bool(false) }
            if op == "or" && left.boolValue { return .bool(true) }
            return try Self.apply(op, left, run(rhs))
        case let .assignment(op, name, expression):
            guard constants[name] == nil else { throw Problem("cannot assign to \(name)") }
            guard variables[name] != nil || variables.count < 128 else {
                throw Problem("expression has too many variables")
            }
            let assigned = try run(expression)
            let result = op == "=" ? assigned : try Self.apply(String(op.dropLast()), value(for: name), assigned)
            variables[name] = result
            return result
        case let .conditional(predicate, yes, no):
            return try run(run(predicate).boolValue ? yes : no)
        case let .call(name, arguments):
            if name == "readRegString" || name == "readRegDWORD" {
                throw Problem("\(name) requires the Windows registry")
            }
            let values = try arguments.map { try run($0) }
            return try Self.call(name, values)
        case let .array(items):
            var values: [Value] = []
            var size = 1
            for item in items {
                let value = try run(item)
                size += value.size
                guard size <= Self.maximumSize, value.depth < 32 else {
                    throw Problem("expression array exceeds the size limit")
                }
                values.append(value)
            }
            return .array(values)
        case let .element(array, index):
            let value = try run(array)
            let position = try run(index).integer()
            guard case let .array(items) = value else { throw Problem("expected an array") }
            guard position >= 0 && position < items.count else { throw Problem("array index is out of range") }
            return items[Int(position)]
        }
    }

    private func value(for name: String) throws -> Value {
        guard let value = variables[name] ?? constants[name] else { throw Problem("unknown variable \(name)") }
        return value
    }

    private static func apply(_ op: String, _ lhs: Value, _ rhs: Value) throws -> Value {
        switch op {
        case "and": return .bool(lhs.boolValue && rhs.boolValue)
        case "or": return .bool(lhs.boolValue || rhs.boolValue)
        case "xor": return .bool(lhs.boolValue != rhs.boolValue)
        case "==": return .bool(lhs == rhs)
        case "!=": return .bool(lhs != rhs)
        case "<", ">", "<=", ">=":
            if case let .string(left) = lhs, case let .string(right) = rhs {
                return .bool(compare(op, left, right))
            }
            return try .bool(compare(op, lhs.number(), rhs.number()))
        case "+":
            if case .string = lhs { return try concatenate(lhs, rhs) }
            if case .string = rhs { return try concatenate(lhs, rhs) }
            return try finite(lhs.number() + rhs.number())
        case "-": return try finite(lhs.number() - rhs.number())
        case "*": return try finite(lhs.number() * rhs.number())
        case "/": return try finite(lhs.number() / rhs.number())
        case "^": return try finite(pow(lhs.number(), rhs.number()))
        case "&": return try .number(Double(lhs.integer() & rhs.integer()))
        case "|": return try .number(Double(lhs.integer() | rhs.integer()))
        case "<<", ">>":
            let left = try lhs.integer()
            let right = try rhs.integer()
            guard (0..<64).contains(right) else { throw Problem("shift count is out of range") }
            return .number(Double(op == "<<" ? left << right : left >> right))
        default:
            throw Problem("unsupported operator \(op)")
        }
    }

    private static func compare<T: Comparable>(_ op: String, _ lhs: T, _ rhs: T) -> Bool {
        switch op {
        case "<": return lhs < rhs
        case ">": return lhs > rhs
        case "<=": return lhs <= rhs
        default: return lhs >= rhs
        }
    }

    private static func concatenate(_ lhs: Value, _ rhs: Value) throws -> Value {
        try checkedString(lhs.rendered + rhs.rendered)
    }

    private static func checkedString(_ text: String) throws -> Value {
        guard text.utf8.count <= maximumSize else { throw Problem("expression string exceeds the size limit") }
        return .string(text)
    }

    private static let math: [String: @Sendable (Double) -> Double] = [
        "abs": { abs($0) }, "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
        "sinh": { sinh($0) }, "cosh": { cosh($0) }, "tanh": { tanh($0) },
        "ln": { log($0) }, "log": { log($0) }, "log10": { log10($0) },
        "exp": { exp($0) }, "sqrt": { sqrt($0) }
    ]

    private static func call(_ name: String, _ arguments: [Value]) throws -> Value {
        if let function = math[name] {
            guard arguments.count == 1 else { throw Problem("\(name) expects one argument") }
            return try finite(function(arguments[0].number()))
        }
        switch name {
        case "min", "max", "sum":
            guard let first = arguments.first else { throw Problem("\(name) expects at least one argument") }
            let numbers: [Double]
            if arguments.count == 1, case let .array(items) = first {
                numbers = try items.map { try $0.number() }
            } else {
                numbers = try arguments.map { try $0.number() }
            }
            guard let first = numbers.first else { throw Problem("\(name) expects at least one number") }
            switch name {
            case "min": return .number(numbers.min() ?? first)
            case "max": return .number(numbers.max() ?? first)
            default: return try finite(numbers.reduce(0, +))
            }
        case "str2dbl", "strlen", "tolower", "toupper":
            guard arguments.count == 1 else { throw Problem("\(name) expects one string") }
            let value = try arguments[0].string()
            switch name {
            case "str2dbl":
                guard let result = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw Problem("str2dbl could not read a number")
                }
                return try finite(result)
            case "strlen": return .number(Double(value.utf16.count))
            default:
                let text = name == "tolower" ? value.lowercased() : value.uppercased()
                return try checkedString(text)
            }
        case "sizeof":
            guard arguments.count == 1, case let .array(items) = arguments[0] else {
                throw Problem("sizeof expects one array")
            }
            return .number(Double(items.count))
        case "regexSearch", "regexReplace":
            return try regex(name, arguments)
        default:
            throw Problem("unsupported expression function \(name)")
        }
    }

    private static func regex(_ name: String, _ arguments: [Value]) throws -> Value {
        let searching = name == "regexSearch"
        guard arguments.count == (searching ? 2 : 3) else {
            throw Problem("\(name) expects \(searching ? 2 : 3) strings")
        }
        let pattern = try arguments[0].string()
        let input = try arguments[1].string()
        let template = searching ? "" : try arguments[2].string()
        guard pattern.utf8.count <= 512, template.utf8.count <= 512, input.utf8.count <= maximumSize else {
            throw Problem("regular expression exceeds the size limit")
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            throw Problem("invalid regular expression")
        }
        let source = input as NSString
        var matches: [NSTextCheckingResult] = []
        var progress = 0
        var stopped = false
        regex.enumerateMatches(in: input, options: .reportProgress, range: NSRange(location: 0, length: source.length)) {
            match, flags, stop in
            if flags.contains(.progress) { progress += 1 }
            if progress >= 8_192 || flags.contains(.internalError) {
                stopped = true
                stop.pointee = true
            } else if let match {
                matches.append(match)
                if searching { stop.pointee = true }
            }
        }
        guard !stopped else { throw Problem("regular expression exceeded its work limit") }

        if searching {
            guard let match = matches.first else { return .array([]) }
            var values: [Value] = []
            var size = 0
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                let capture = range.location == NSNotFound ? "" : source.substring(with: range)
                size += capture.utf8.count + 1
                guard size <= maximumSize else { throw Problem("regular expression result exceeds the size limit") }
                values.append(.string(capture))
            }
            return .array(values)
        }

        var result = ""
        var previousEnd = 0
        for match in matches {
            result += source.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
            result += regex.replacementString(for: match, in: input, offset: 0, template: template)
            previousEnd = NSMaxRange(match.range)
            guard result.utf8.count <= maximumSize else { throw Problem("regular expression result exceeds the size limit") }
        }
        result += source.substring(from: previousEnd)
        return try checkedString(result)
    }

    private static func finite(_ value: Double) throws -> Value {
        guard value.isFinite else { throw Problem("expression result is not finite") }
        return .number(value)
    }

    private indirect enum Expression {
        case literal(Value)
        case variable(String)
        case unary(String, Expression)
        case binary(String, Expression, Expression)
        case assignment(String, String, Expression)
        case conditional(Expression, Expression, Expression)
        case call(String, [Expression])
        case array([Expression])
        case element(Expression, Expression)
    }

    private enum Token: Equatable {
        case literal(Value)
        case identifier(String)
        case symbol(String)
        case end
    }

    private struct Parser {
        private static let precedence = [
            "=": 1, "+=": 1, "-=": 1, "*=": 1, "/=": 1,
            "or": 3, "xor": 4, "and": 5, "|": 6, "&": 7,
            "==": 8, "!=": 8, "<": 9, ">": 9, "<=": 9, ">=": 9,
            "<<": 10, ">>": 10, "+": 11, "-": 11, "*": 12, "/": 12, "^": 13
        ]

        private let tokens: [Token]
        private var offset = 0
        var current: Token { tokens[offset] }

        init(_ source: String) throws {
            guard source.utf8.count <= EqualizerConfigExpression.maximumSize else {
                throw Problem("expression exceeds the size limit")
            }
            var lexer = Lexer(source)
            tokens = try lexer.readAll()
        }

        mutating func parse(minimum: Int = 1) throws -> Expression {
            var lhs = try primary()
            while case let .symbol(op) = current {
                if op == "?", minimum <= 2 {
                    offset += 1
                    let yes = try parse()
                    try expect(":")
                    lhs = try .conditional(lhs, yes, parse(minimum: 2))
                    continue
                }
                guard let priority = Self.precedence[op], priority >= minimum else { break }
                offset += 1
                if priority == 1 {
                    guard case let .variable(name) = lhs else { throw Problem("expected an assignment variable") }
                    lhs = try .assignment(op, name, parse(minimum: priority))
                } else {
                    lhs = try .binary(op, lhs, parse(minimum: op == "^" ? priority : priority + 1))
                }
            }
            return lhs
        }

        private mutating func primary() throws -> Expression {
            let atom: Expression
            switch current {
            case let .literal(value):
                offset += 1
                atom = .literal(value)
            case let .identifier(name):
                offset += 1
                atom = try consume("(") ? .call(name, list(ending: ")")) : .variable(name)
            case .symbol("("):
                offset += 1
                if offset + 1 < tokens.count,
                   case let .identifier(type) = current, type == "int" || type == "float",
                   tokens[offset + 1] == .symbol(")") {
                    offset += 2
                    return try .unary(type, parse(minimum: 13))
                }
                atom = try parse()
                try expect(")")
            case .symbol("{"):
                offset += 1
                atom = try .array(list(ending: "}"))
            case let .symbol(op) where ["+", "-", "not"].contains(op):
                offset += 1
                return try .unary(op, parse(minimum: 13))
            default:
                throw Problem("expected an expression")
            }

            var result = atom
            while consume("[") {
                result = try .element(result, parse())
                try expect("]")
            }
            return result
        }

        private mutating func list(ending: String) throws -> [Expression] {
            if consume(ending) { return [] }
            var values = [try parse()]
            while consume(",") { values.append(try parse()) }
            try expect(ending)
            return values
        }

        mutating func consume(_ symbol: String) -> Bool {
            guard current == .symbol(symbol) else { return false }
            offset += 1
            return true
        }

        private mutating func expect(_ symbol: String) throws {
            guard consume(symbol) else { throw Problem("expected \(symbol)") }
        }
    }

    private struct Lexer {
        private let source: String
        private var index: String.Index
        private var current: Character? { index < source.endIndex ? source[index] : nil }

        init(_ source: String) {
            self.source = source
            index = source.startIndex
        }

        mutating func readAll() throws -> [Token] {
            var tokens: [Token] = []
            while let char = current {
                if char.isWhitespace {
                    advance()
                    continue
                }
                guard tokens.count < 512 else { throw Problem("expression has too many tokens") }
                tokens.append(try read(char))
            }
            tokens.append(.end)
            return tokens
        }

        private mutating func read(_ char: Character) throws -> Token {
            if char == "\"" { return try .literal(.string(readString())) }
            if char.isASCII && (char.isNumber || char == ".") {
                return try .literal(.number(readNumber()))
            }
            if char == "_" || char.isLetter {
                let text = take { $0 == "_" || $0.isLetter || $0.isNumber }
                switch text {
                case "true": return .literal(.bool(true))
                case "false": return .literal(.bool(false))
                case "and", "or", "xor", "not": return .symbol(String(text))
                default: return .identifier(String(text))
                }
            }

            guard "+-*/^&|=!<>?:;,(){}[]".contains(char) else {
                throw Problem("unexpected character \(char) in expression")
            }
            advance()
            if let next = current {
                let pair = String(char) + String(next)
                if ["+=", "-=", "*=", "/=", "==", "!=", "<=", ">=", "<<", ">>"].contains(pair) {
                    advance()
                    return .symbol(pair)
                }
            }
            return .symbol(String(char))
        }

        private mutating func readNumber() throws -> Double {
            let start = index
            _ = take { $0.isASCII && $0.isNumber }
            if current == "." {
                advance()
                _ = take { $0.isASCII && $0.isNumber }
            }
            if current == "e" || current == "E" {
                advance()
                if current == "+" || current == "-" { advance() }
                _ = take { $0.isASCII && $0.isNumber }
            }
            guard let value = Double(source[start..<index]), value.isFinite else {
                throw Problem("invalid or non-finite number")
            }
            return value
        }

        private mutating func readString() throws -> String {
            advance()
            var text = ""
            while let char = current {
                advance()
                if char == "\"" { return text }
                if char == "\\", let escaped = current, escaped == "\"" || escaped == "\\" {
                    text.append(escaped)
                    advance()
                } else {
                    text.append(char)
                }
            }
            throw Problem("unterminated string")
        }

        private mutating func take(while predicate: (Character) -> Bool) -> Substring {
            let start = index
            while let current, predicate(current) { advance() }
            return source[start..<index]
        }

        private mutating func advance() {
            source.formIndex(after: &index)
        }
    }
}
