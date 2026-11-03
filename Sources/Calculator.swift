import Foundation

// MARK: - Calculator
//
// Recursive-descent math evaluator for the Action Palette ("12*45+3" → 543).
// Deliberately NOT NSExpression-based: NSExpression can throw Objective-C
// exceptions on malformed input. This parser never throws and never executes
// anything — digits, + - * / ( ) and whitespace only.
//
// Grammar:
//   expr    := term (('+' | '-') term)*
//   term    := unary (('*' | '/') unary)*
//   unary   := '-' unary | primary
//   primary := NUMBER | '(' expr ')'

enum Calculator {

    static func eval(_ input: String) -> Double? {
        let scalars = input.unicodeScalars
        let allowed = CharacterSet(charactersIn: "0123456789+-*/(). \n")
        guard !scalars.isEmpty, scalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        var parser = Parser(Array(input))
        guard let value = parser.parseExpr(), parser.atEnd else { return nil }
        guard value.isFinite else { return nil }
        return value
    }

    /// Trimmed, compact representation: 543, 2.5, -7.25
    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.6g", value)
    }

    private struct Parser {
        let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool {
            var probe = self
            probe.skipSpaces()
            return probe.index >= chars.count
        }

        mutating func skipSpaces() {
            while index < chars.count, chars[index].isWhitespace || chars[index].isNewline {
                index += 1
            }
        }

        mutating func parseExpr() -> Double? {
            guard var value = parseTerm() else { return nil }
            skipSpaces()
            while index < chars.count {
                let op = chars[index]
                guard op == "+" || op == "-" else { break }
                index += 1
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
                skipSpaces()
            }
            return value
        }

        mutating func parseTerm() -> Double? {
            guard var value = parseUnary() else { return nil }
            skipSpaces()
            while index < chars.count {
                let op = chars[index]
                guard op == "*" || op == "/" else { break }
                index += 1
                guard let rhs = parseUnary() else { return nil }
                if op == "/" {
                    guard rhs != 0 else { return nil }
                    value = value / rhs
                } else {
                    value = value * rhs
                }
                skipSpaces()
            }
            return value
        }

        mutating func parseUnary() -> Double? {
            skipSpaces()
            if index < chars.count, chars[index] == "-" {
                index += 1
                return parseUnary().map { -$0 }
            }
            if index < chars.count, chars[index] == "+" {
                index += 1
                return parseUnary()
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Double? {
            skipSpaces()
            guard index < chars.count else { return nil }

            if chars[index] == "(" {
                index += 1
                guard let value = parseExpr() else { return nil }
                skipSpaces()
                guard index < chars.count, chars[index] == ")" else { return nil }
                index += 1
                return value
            }

            var text = ""
            var sawDigit = false
            var sawDot = false
            while index < chars.count {
                let ch = chars[index]
                if ch.isNumber {
                    sawDigit = true
                    text.append(ch)
                    index += 1
                } else if ch == "." && !sawDot {
                    sawDot = true
                    text.append(ch)
                    index += 1
                } else {
                    break
                }
            }
            guard sawDigit else { return nil }
            return Double(text)
        }
    }
}
