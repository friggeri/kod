import Foundation
import LanguageAdapters

enum LanguageServerCommandLineError: LocalizedError, Equatable {
    case unterminatedQuote
    case trailingEscape
    case missingExecutable
    case executableMustBeAbsolute(String)

    var errorDescription: String? {
        switch self {
        case .unterminatedQuote:
            String(
                localized: "The language-server command contains an unterminated quote."
            )
        case .trailingEscape:
            String(
                localized: "The language-server command ends with an incomplete escape."
            )
        case .missingExecutable:
            String(
                localized: "The language-server command needs an executable."
            )
        case .executableMustBeAbsolute(let value):
            String(
                localized: "The language-server executable must use an absolute path: \(value)"
            )
        }
    }
}

enum LanguageServerCommandLine {
    static func parse(
        _ command: String
    ) throws -> RegisteredLanguageServerExecutable? {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let tokens = try tokens(in: command)
        guard let executable = tokens.first, !executable.isEmpty else {
            throw LanguageServerCommandLineError.missingExecutable
        }
        guard (executable as NSString).isAbsolutePath else {
            throw LanguageServerCommandLineError.executableMustBeAbsolute(
                executable
            )
        }
        return RegisteredLanguageServerExecutable(
            path: URL(fileURLWithPath: executable).standardizedFileURL.path,
            arguments: Array(tokens.dropFirst())
        )
    }

    static func format(
        path: String,
        arguments: [String]
    ) -> String {
        ([path] + arguments).map(quoteIfNeeded).joined(separator: " ")
    }

    static func format(_ executable: RegisteredLanguageServerExecutable) -> String {
        format(path: executable.path, arguments: executable.arguments)
    }

    static func format(_ executable: DiscoveredExecutable) -> String {
        format(path: executable.url.path, arguments: executable.arguments)
    }

    private static func tokens(in command: String) throws -> [String] {
        enum Quote {
            case single
            case double
        }

        var values: [String] = []
        var value = ""
        var quote: Quote?
        var isEscaping = false
        var hasToken = false

        func appendValue() {
            values.append(value)
            value = ""
            hasToken = false
        }

        for character in command {
            if isEscaping {
                value.append(character)
                hasToken = true
                isEscaping = false
                continue
            }

            switch quote {
            case .single:
                if character == "'" {
                    quote = nil
                } else {
                    value.append(character)
                }
                hasToken = true
            case .double:
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    isEscaping = true
                } else {
                    value.append(character)
                }
                hasToken = true
            case nil:
                if character.isWhitespace {
                    if hasToken {
                        appendValue()
                    }
                } else if character == "'" {
                    quote = .single
                    hasToken = true
                } else if character == "\"" {
                    quote = .double
                    hasToken = true
                } else if character == "\\" {
                    isEscaping = true
                    hasToken = true
                } else {
                    value.append(character)
                    hasToken = true
                }
            }
        }

        guard !isEscaping else {
            throw LanguageServerCommandLineError.trailingEscape
        }
        guard quote == nil else {
            throw LanguageServerCommandLineError.unterminatedQuote
        }
        if hasToken {
            appendValue()
        }
        return values
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        guard !value.isEmpty else {
            return "\"\""
        }
        guard value.contains(where: {
            $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\"
        }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
