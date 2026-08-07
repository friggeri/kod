import Foundation

// A process-spy test double used only by `GitCoreTests`'s process-
// invocation assertions and the immutability tests. Kod's own
// `GitContext` never invokes this binary in production — tests inject
// its path as the "resolved Git executable" so `GitProcessRunner`
// launches this binary with exactly the argument array and environment
// GitCore itself constructed. It:
//
// 1. Appends one JSON line describing this invocation (argv tail,
//    current directory, and a fixed allow-listed subset of the
//    environment) to the file named by `GIT_PROCESS_SPY_LOG_PATH`.
// 2. Re-executes the real, already-resolved Git binary named by
//    `GIT_PROCESS_SPY_REAL_GIT` with the identical argument array,
//    current directory, and environment, forwarding stdio and exit
//    code — so functional (golden/parser) tests still see real Git
//    behavior end-to-end while a spy test independently inspects the
//    logged invocation.
//
// This file is intentionally the only place in the whole repository
// that re-execs a subprocess "transparently": it exists purely as a
// test fixture, is never shipped, and is never invoked by production
// GitCore code.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(97)
}

guard let logPath = ProcessInfo.processInfo.environment["GIT_PROCESS_SPY_LOG_PATH"] else {
    fail("GitProcessSpy: GIT_PROCESS_SPY_LOG_PATH not set")
}
guard let realGitPath = ProcessInfo.processInfo.environment["GIT_PROCESS_SPY_REAL_GIT"] else {
    fail("GitProcessSpy: GIT_PROCESS_SPY_REAL_GIT not set")
}

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let currentDirectory = FileManager.default.currentDirectoryPath

// Every environment key GitCore's own `GitInvocationHardening` sets, so
// the spy log captures the exact values GitCore chose to pass — not the
// spy process's own ambient environment (which Foundation's `Process`
// never leaks into here anyway, since `GitProcessRunner` always sets
// `process.environment` explicitly rather than inheriting).
let observedKeys = [
    "PATH", "GIT_OPTIONAL_LOCKS", "GIT_TERMINAL_PROMPT", "GIT_ASKPASS",
    "SSH_ASKPASS", "GIT_SSH_COMMAND", "GIT_SSH", "GIT_NO_REPLACE_OBJECTS",
    "GIT_PAGER", "GIT_EDITOR", "LC_ALL", "LANG", "HOME"
]
var observedEnvironment: [String: String] = [:]
for key in observedKeys {
    if let value = environment[key] {
        observedEnvironment[key] = value
    }
}
// Also record every key present that is *not* in the observed allow-list
// above, so a spy-test can assert the environment contains nothing
// beyond what hardening explicitly sets (catching an accidental leak of
// ambient parent-process environment).
let unexpectedKeys = Set(environment.keys).subtracting(observedKeys).sorted()

struct SpyRecord: Encodable {
    let arguments: [String]
    let currentDirectory: String
    let environment: [String: String]
    let unexpectedEnvironmentKeys: [String]
}

let record = SpyRecord(
    arguments: arguments,
    currentDirectory: currentDirectory,
    environment: observedEnvironment,
    unexpectedEnvironmentKeys: unexpectedKeys
)

do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(record)
    data.append(0x0A)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        try handle.close()
    } else {
        try data.write(to: URL(fileURLWithPath: logPath))
    }
} catch {
    fail("GitProcessSpy: failed to write log: \(error)")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: realGitPath)
process.arguments = arguments
process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
process.environment = environment
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

do {
    try process.run()
} catch {
    fail("GitProcessSpy: failed to launch real git at \(realGitPath): \(error)")
}
process.waitUntilExit()
exit(process.terminationStatus)
