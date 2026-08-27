import Foundation

/// A launch-counting shim standing in for the language server
/// executable: every time it is spawned it appends one line to a log and
/// then `exec`s the real `FakeLanguageServer` with the same arguments, so
/// a test can assert on the exact number of *process launches* that
/// happened rather than inferring it from connection state.
struct ProcessLaunchLedger {
    let directoryURL: URL
    let executableURL: URL
    let logURL: URL

    static func make() throws -> ProcessLaunchLedger {
        let realServerURL = try FakeLanguageServerLocator.executableURL()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kod-launch-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let logURL = directoryURL.appendingPathComponent("launches.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let executableURL = directoryURL.appendingPathComponent("language-server-shim")
        let script = """
        #!/bin/sh
        printf 'launch\\n' >> '\(logURL.path)'
        exec '\(realServerURL.path)' "$@"

        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )

        return ProcessLaunchLedger(
            directoryURL: directoryURL,
            executableURL: executableURL,
            logURL: logURL
        )
    }

    var launchCount: Int {
        guard let data = FileManager.default.contents(atPath: logURL.path) else {
            return 0
        }
        return data.split(separator: 0x0A).count
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
