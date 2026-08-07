import Foundation

/// Decodes an XML property list (`<?xml ... <plist> ...`) into a
/// `StructuredNode` tree using `Foundation.XMLParser`, with every
/// SPEC-10.3-mandated safeguard applied before a single element is parsed:
///
/// - External entities, external DTD fetches, and network access are
///   disabled outright (`shouldResolveExternalEntities = false`,
///   `externalEntityResolvingPolicy = .never`) — an XML plist previews a
///   local file; it must never cause Kod to make a network request.
/// - Any `<!ENTITY` declaration at all — internal or external — is
///   rejected before parsing begins. Property lists have no legitimate use
///   for custom entities; this is what actually stops a "billion laughs"
///   exponential-entity-expansion memory-bomb attack, which parser-level
///   entity-resolution flags alone do not fully prevent (internal entity
///   expansion happens regardless of external-resolution settings).
/// - Depth, node-count, and string-length limits from `StructuredDataLimits`
///   are enforced by the delegate while parsing, not just checked
///   afterward.
enum XMLPlistParser {
    static func parse(_ data: Data, limits: StructuredDataLimits) -> StructuredParseResult {
        guard data.count <= limits.maximumSourceLength else {
            return .invalid(.sourceTooLarge(byteCount: data.count, limit: limits.maximumSourceLength))
        }
        guard looksLikeXMLPlist(data) else {
            return .invalid(.notAPropertyList)
        }
        if containsEntityDeclaration(data) {
            return .invalid(.malformedXMLPlist(reason: "custom <!ENTITY> declarations are not permitted in property lists", line: 0))
        }

        let delegate = Delegate(limits: limits)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        if #available(macOS 12.0, *) {
            parser.externalEntityResolvingPolicy = .never
        }
        parser.shouldProcessNamespaces = false

        let succeeded = parser.parse()
        if let diagnostic = delegate.diagnostic {
            return .invalid(diagnostic)
        }
        guard succeeded else {
            let nsError = parser.parserError as NSError?
            let reason = nsError?.localizedDescription ?? "unknown XML error"
            return .invalid(.malformedXMLPlist(reason: reason, line: parser.lineNumber))
        }
        guard let root = delegate.rootNode else {
            return .invalid(.malformedXMLPlist(reason: "no <plist> root value found", line: parser.lineNumber))
        }
        return .valid(root)
    }

    static func looksLikeXMLPlist(_ data: Data) -> Bool {
        // Sniff only a bounded prefix so an attacker cannot force a large
        // scan just to fail the sniff.
        let prefix = data.prefix(4_096)
        guard let text = String(data: prefix, encoding: .utf8) ?? String(data: prefix, encoding: .isoLatin1) else {
            return false
        }
        return text.contains("<plist") || text.hasPrefix("<?xml")
    }

    private static func containsEntityDeclaration(_ data: Data) -> Bool {
        // Bounded, case-sensitive-per-XML-spec scan for the literal
        // `<!ENTITY` marker. XML entity declarations always use this
        // exact ASCII casing, so a byte scan is sufficient and avoids
        // decoding the (possibly huge) document as a `String` just to
        // reject it.
        let marker = Array("<!ENTITY".utf8)
        guard marker.count <= data.count else {
            return false
        }
        var matchIndex = 0
        for byte in data {
            if byte == marker[matchIndex] {
                matchIndex += 1
                if matchIndex == marker.count {
                    return true
                }
            } else {
                matchIndex = (byte == marker[0]) ? 1 : 0
            }
        }
        return false
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let limits: StructuredDataLimits
        var diagnostic: StructuredDataDiagnostic?
        var rootNode: StructuredNode?

        /// A stack mirroring the open-element structure. Container frames
        /// (`dict`/`array`) accumulate finished child values; the pending
        /// dictionary key (if any) is tracked alongside its frame.
        private enum Frame {
            case array([StructuredNode])
            case dict(members: [StructuredMember], pendingKey: String?, seenKeys: Set<String>)
        }
        private var stack: [Frame] = []
        private var elementNameStack: [String] = []
        private var textBuffer = ""
        private var nodeCount = 0
        private var didFinishRoot = false

        init(limits: StructuredDataLimits) {
            self.limits = limits
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard diagnostic == nil else {
                return
            }
            elementNameStack.append(elementName)
            textBuffer = ""

            switch elementName {
            case "dict":
                guard stack.count < limits.maximumDepth else {
                    fail(.depthLimitExceeded(limit: limits.maximumDepth, atByteOffset: 0))
                    return
                }
                stack.append(.dict(members: [], pendingKey: nil, seenKeys: []))
            case "array":
                guard stack.count < limits.maximumDepth else {
                    fail(.depthLimitExceeded(limit: limits.maximumDepth, atByteOffset: 0))
                    return
                }
                stack.append(.array([]))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard diagnostic == nil else {
                return
            }
            textBuffer += string
            if textBuffer.utf8.count > limits.maximumStringLength {
                fail(.stringTooLong(limit: limits.maximumStringLength, atByteOffset: 0))
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard diagnostic == nil else {
                return
            }
            elementNameStack.removeLast()
            defer { textBuffer = "" }

            let value: StructuredNode?
            switch elementName {
            case "plist":
                return
            case "dict":
                guard case .dict(let members, _, _) = stack.popLast() else {
                    fail(.malformedXMLPlist(reason: "mismatched </dict>", line: parser.lineNumber))
                    return
                }
                value = .object(members)
            case "array":
                guard case .array(let elements) = stack.popLast() else {
                    fail(.malformedXMLPlist(reason: "mismatched </array>", line: parser.lineNumber))
                    return
                }
                value = .array(elements)
            case "key":
                guard case .dict(let members, _, let seenKeys) = stack.last else {
                    fail(.malformedXMLPlist(reason: "<key> outside of <dict>", line: parser.lineNumber))
                    return
                }
                stack[stack.count - 1] = .dict(members: members, pendingKey: textBuffer, seenKeys: seenKeys)
                return
            case "string":
                value = .string(textBuffer)
            case "true":
                value = .bool(true)
            case "false":
                value = .bool(false)
            case "integer":
                value = .number(textBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
            case "real":
                value = .number(textBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
            case "date":
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let date = formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed) else {
                    fail(.malformedXMLPlist(reason: "invalid <date> value \"\(trimmed)\"", line: parser.lineNumber))
                    return
                }
                value = .date(date)
            case "data":
                let cleaned = textBuffer.filter { !$0.isWhitespace }
                guard let decoded = Data(base64Encoded: cleaned) else {
                    fail(.malformedXMLPlist(reason: "invalid base64 <data> value", line: parser.lineNumber))
                    return
                }
                value = .data(decoded)
            default:
                value = nil
            }

            guard let value else {
                return
            }
            append(value)
        }

        private func append(_ value: StructuredNode) {
            nodeCount += 1
            guard nodeCount <= limits.maximumNodeCount else {
                fail(.nodeCountLimitExceeded(limit: limits.maximumNodeCount))
                return
            }

            if stack.isEmpty {
                if didFinishRoot {
                    fail(.malformedXMLPlist(reason: "multiple root values inside <plist>", line: 0))
                    return
                }
                rootNode = value
                didFinishRoot = true
                return
            }

            switch stack[stack.count - 1] {
            case .array(let elements):
                stack[stack.count - 1] = .array(elements + [value])
            case .dict(let members, let pendingKey, var seenKeys):
                guard let key = pendingKey else {
                    fail(.malformedXMLPlist(reason: "dictionary value without a preceding <key>", line: 0))
                    return
                }
                guard seenKeys.insert(key).inserted else {
                    fail(.duplicateKey(key, atByteOffset: 0))
                    return
                }
                stack[stack.count - 1] = .dict(members: members + [StructuredMember(key: key, value: value)], pendingKey: nil, seenKeys: seenKeys)
            }
        }

        private func fail(_ diagnostic: StructuredDataDiagnostic) {
            guard self.diagnostic == nil else {
                return
            }
            self.diagnostic = diagnostic
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            let nsError = parseError as NSError
            fail(.malformedXMLPlist(reason: nsError.localizedDescription, line: parser.lineNumber))
        }
    }
}
