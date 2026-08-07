import CTreeSitter
import Foundation

/// Evaluates the `#match?`, `#eq?`, `#not-eq?`, and `#any-of?` predicate
/// families that the bundled `highlights.scm` queries use. Predicates Kod
/// does not implement (`#is?`, `#is-not?`, `#set!`, `#offset!`, and any
/// future addition) are treated as satisfied rather than as a hard error,
/// because they gate refinements (e.g. "is this identifier shadowed by a
/// local binding") that require full `locals.scm` scope resolution, which
/// is out of scope for the lexical highlighting layer in this phase. This
/// makes affected captures occasionally over-inclusive, never incorrectly
/// hidden, and never a crash or hang.
struct TreeSitterPredicateEvaluator {
    let query: OpaquePointer
    let utf8: Data

    func matches(_ match: TSQueryMatch) -> Bool {
        var stepCount: UInt32 = 0
        guard let steps = ts_query_predicates_for_pattern(query, UInt32(match.pattern_index), &stepCount),
              stepCount > 0 else {
            return true
        }

        let stepsBuffer = UnsafeBufferPointer(start: steps, count: Int(stepCount))
        var index = 0
        while index < stepsBuffer.count {
            var predicateSteps: [TSQueryPredicateStep] = []
            while index < stepsBuffer.count, stepsBuffer[index].type != TSQueryPredicateStepTypeDone {
                predicateSteps.append(stepsBuffer[index])
                index += 1
            }
            index += 1
            guard !predicateSteps.isEmpty else {
                continue
            }
            if !evaluate(predicateSteps, match: match) {
                return false
            }
        }
        return true
    }

    private func evaluate(_ steps: [TSQueryPredicateStep], match: TSQueryMatch) -> Bool {
        guard let first = steps.first, first.type == TSQueryPredicateStepTypeString else {
            return true
        }
        let name = stringValue(first.value_id)
        let operands = Array(steps.dropFirst())

        switch name {
        case "match?", "not-match?", "vim-match?":
            return evaluateMatch(operands, match: match, negate: name.hasPrefix("not-"))
        case "eq?", "not-eq?":
            return evaluateEquality(operands, match: match, negate: name == "not-eq?")
        case "any-of?", "not-any-of?":
            return evaluateAnyOf(operands, match: match, negate: name.hasPrefix("not-"))
        default:
            return true
        }
    }

    private func evaluateMatch(
        _ operands: [TSQueryPredicateStep],
        match: TSQueryMatch,
        negate: Bool
    ) -> Bool {
        guard operands.count == 2,
              operands[0].type == TSQueryPredicateStepTypeCapture,
              operands[1].type == TSQueryPredicateStepTypeString,
              let text = nodeText(forCaptureIndex: operands[0].value_id, match: match) else {
            return true
        }
        let pattern = stringValue(operands[1].value_id)
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return true
        }
        let isMatch = regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
        return negate ? !isMatch : isMatch
    }

    private func evaluateEquality(
        _ operands: [TSQueryPredicateStep],
        match: TSQueryMatch,
        negate: Bool
    ) -> Bool {
        guard operands.count == 2 else {
            return true
        }
        let lhs = value(for: operands[0], match: match)
        let rhs = value(for: operands[1], match: match)
        guard let lhs, let rhs else {
            return true
        }
        let isEqual = lhs == rhs
        return negate ? !isEqual : isEqual
    }

    private func evaluateAnyOf(
        _ operands: [TSQueryPredicateStep],
        match: TSQueryMatch,
        negate: Bool
    ) -> Bool {
        guard let first = operands.first,
              first.type == TSQueryPredicateStepTypeCapture,
              let text = nodeText(forCaptureIndex: first.value_id, match: match) else {
            return true
        }
        let candidates = operands.dropFirst()
            .filter { $0.type == TSQueryPredicateStepTypeString }
            .map { stringValue($0.value_id) }
        let contains = candidates.contains(text)
        return negate ? !contains : contains
    }

    private func value(for step: TSQueryPredicateStep, match: TSQueryMatch) -> String? {
        step.type == TSQueryPredicateStepTypeCapture
            ? nodeText(forCaptureIndex: step.value_id, match: match)
            : stringValue(step.value_id)
    }

    private func nodeText(forCaptureIndex captureIndex: UInt32, match: TSQueryMatch) -> String? {
        guard let captures = match.captures else {
            return nil
        }
        let matchCaptures = UnsafeBufferPointer(start: captures, count: Int(match.capture_count))
        guard let capture = matchCaptures.first(where: { $0.index == captureIndex }) else {
            return nil
        }
        let start = Int(ts_node_start_byte(capture.node))
        let end = Int(ts_node_end_byte(capture.node))
        guard start >= 0, end <= utf8.count, start <= end else {
            return nil
        }
        return String(decoding: utf8[start..<end], as: UTF8.self)
    }

    private func stringValue(_ id: UInt32) -> String {
        var length: UInt32 = 0
        guard let pointer = ts_query_string_value_for_id(query, id, &length) else {
            return ""
        }
        return String(
            decoding: UnsafeBufferPointer(start: pointer, count: Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
