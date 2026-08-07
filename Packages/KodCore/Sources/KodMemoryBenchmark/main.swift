import Darwin
import Foundation
import SourceModel
import SyntaxCore
import WorkspaceCore

private struct MemoryBenchmarkResult: Codable {
    let residentMegabytes: Double
    let baselineMegabytes: Double
    let incrementalMegabytes: Double
    let budgetMegabytes: Double
    let filenameCount: Int
    let sourceBytes: Int
    let passed: Bool
}

private enum MemoryBenchmarkError: Error {
    case residentMemoryUnavailable
    case budgetExceeded(Double)
}

@main
private enum KodMemoryBenchmark {
    static func main() async throws {
        let baselineBytes = try residentMemoryBytes()
        let index = FilenameIndex()

        for batchStart in stride(from: 0, to: 100_000, by: 2_000) {
            let batchEnd = min(100_000, batchStart + 2_000)
            let entries = (batchStart..<batchEnd).map { item in
                let relativePath = "Sources/\(item / 1_000)/File-\(item).swift"
                return WorkspaceFileEntry(
                    url: URL(fileURLWithPath: "/workspace/\(relativePath)"),
                    relativePath: relativePath,
                    kind: .file,
                    isHidden: false,
                    isIgnored: false
                )
            }
            await index.append(entries)
        }

        let line = "let value = 42 // a representative line of source text\n"
        let targetBytes = 10 * 1_024 * 1_024
        let source = String(repeating: line, count: targetBytes / line.utf8.count)
        let snapshot = SourceSnapshot(
            text: source,
            url: URL(fileURLWithPath: "/workspace/ten-megabytes.swift")
        )
        let tree = try await SyntaxEngine().parse(
            snapshot: snapshot,
            language: .swift
        )

        let residentBytes = try residentMemoryBytes()
        let residentMegabytes = megabytes(residentBytes)
        let baselineMegabytes = megabytes(baselineBytes)
        let result = MemoryBenchmarkResult(
            residentMegabytes: residentMegabytes,
            baselineMegabytes: baselineMegabytes,
            incrementalMegabytes: megabytes(residentBytes - baselineBytes),
            budgetMegabytes: 350,
            filenameCount: await index.count,
            sourceBytes: snapshot.utf8Count,
            passed: residentMegabytes <= 350
        )

        withExtendedLifetime((index, snapshot, tree)) {}

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)

        if let outputPath = outputPath() {
            let outputURL = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
        }

        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))

        guard result.passed else {
            throw MemoryBenchmarkError.budgetExceeded(residentMegabytes)
        }
    }

    private static func outputPath() -> String? {
        let arguments = CommandLine.arguments
        guard let outputIndex = arguments.firstIndex(of: "--output") else {
            return nil
        }
        let valueIndex = arguments.index(after: outputIndex)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        return arguments[valueIndex]
    }

    private static func megabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / (1_024 * 1_024)
    }

    private static func residentMemoryBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
                / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else {
            throw MemoryBenchmarkError.residentMemoryUnavailable
        }
        return info.resident_size
    }
}

