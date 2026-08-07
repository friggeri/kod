import Foundation
import KodFixtureSupport

enum FixtureGeneratorCommandError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownArgument(String)
    case missingRoot
    case invalidInteger(name: String, value: String)

    var description: String {
        switch self {
        case .missingValue(let argument):
            "Missing value for \(argument)"
        case .unknownArgument(let argument):
            "Unknown argument: \(argument)"
        case .missingRoot:
            "Usage: KodFixtureGenerator --root PATH [--files COUNT] [--bytes-per-file COUNT]"
        case .invalidInteger(let name, let value):
            "Invalid integer for \(name): \(value)"
        }
    }
}

@main
struct KodFixtureGeneratorCommand {
    static func main() throws {
        let configuration = try parse(arguments: Array(CommandLine.arguments.dropFirst()))
        try ScaleFixtureGenerator().generate(configuration)
        print("Generated \(configuration.fileCount) files at \(configuration.root.path)")
    }

    private static func parse(arguments: [String]) throws -> ScaleFixtureConfiguration {
        var root: URL?
        var fileCount = 100_000
        var bytesPerFile = 128
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else {
                throw FixtureGeneratorCommandError.missingValue(argument)
            }
            let value = arguments[index + 1]

            switch argument {
            case "--root":
                root = URL(fileURLWithPath: value, isDirectory: true)
            case "--files":
                guard let parsed = Int(value) else {
                    throw FixtureGeneratorCommandError.invalidInteger(name: argument, value: value)
                }
                fileCount = parsed
            case "--bytes-per-file":
                guard let parsed = Int(value) else {
                    throw FixtureGeneratorCommandError.invalidInteger(name: argument, value: value)
                }
                bytesPerFile = parsed
            default:
                throw FixtureGeneratorCommandError.unknownArgument(argument)
            }

            index += 2
        }

        guard let root else {
            throw FixtureGeneratorCommandError.missingRoot
        }

        return ScaleFixtureConfiguration(
            root: root,
            fileCount: fileCount,
            bytesPerFile: bytesPerFile
        )
    }
}

