import AppKit
import DiagnosticsCore
import FontCore
import Foundation
import GitCore
import KodFixtureSupport
import SearchCore
import SourceModel
import SyntaxCore
import ThemeCore
import WorkspaceCore
import XCTest
@testable import CodeViewport

// MARK: - Shared measurement infrastructure

/// One SPEC 12.2 budget's measured result: 30 (or fewer, for slow
/// scale-gated benchmarks noted below) timed iterations reduced to
/// p50/p95/p99, retained as JSON alongside every other budget in this
/// file so a single artifact documents Kod's entire performance
/// contract in one place (the "consolidate performance benchmarks for
/// every SPEC 12.2 budget" requirement).
struct BenchmarkResult: Codable {
    let name: String
    let specBudget: String
    let budgetMilliseconds: Double?
    let iterations: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let minMilliseconds: Double
    let maxMilliseconds: Double
    /// `true` only when this measurement exercises the real, product
    /// code path headlessly (no `Kod.app`/`XCUIApplication` launch
    /// involved) closely enough that a budget breach here is
    /// attributable to Kod's own code, and should therefore fail this
    /// suite automatically. `false` marks a documented proxy (e.g. "cold
    /// app launch," which fundamentally requires launching real AppKit
    /// UI this suite must never do) that is still measured and reported
    /// for engineering visibility, but never asserted against the
    /// literal SPEC target.
    let headlessMeasurable: Bool
    let passed: Bool?
    let notes: String
}

struct PerformanceReport: Codable {
    let generatedAt: String
    let architecture: String
    let results: [BenchmarkResult]
}

enum PercentileMath {
    static func percentile(_ sortedAscending: [Double], _ fraction: Double) -> Double {
        guard !sortedAscending.isEmpty else {
            return 0
        }
        let rank = Int((fraction * Double(sortedAscending.count)).rounded(.up)) - 1
        return sortedAscending[max(0, min(sortedAscending.count - 1, rank))]
    }
}

/// Thread-safe accumulator so every test method in this single XCTest
/// class (run serially by XCTest, but written defensively regardless)
/// can append its own result; `PerformanceSuiteTests.tearDown()`
/// (the class-level teardown, called once after every test method in
/// the class has finished) writes the consolidated JSON artifact.
final class BenchmarkResultsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [BenchmarkResult] = []

    func record(_ result: BenchmarkResult) {
        lock.lock()
        defer { lock.unlock() }
        results.append(result)
    }

    func snapshot() -> [BenchmarkResult] {
        lock.lock()
        defer { lock.unlock() }
        return results.sorted { $0.name < $1.name }
    }
}

/// Headless, offline, 30-measured-iteration benchmarks for every SPEC
/// 12.2 performance budget that can be exercised without launching
/// `Kod.app`, `XCUIApplication`, or any GUI automation — consolidating
/// what were previously several separate ad hoc benchmark files
/// (`TenMegabyteParseBenchmarkTests`, `TenMegabyteRepaintBenchmarkTests`)
/// plus new coverage for every remaining budget into one place, one
/// JSON artifact, and one consistent p50/p95/p99 methodology.
///
/// Two budgets are fundamentally impossible to measure headlessly and
/// are reported as documented, clearly-labeled proxies rather than
/// silently skipped or silently asserted as passing:
///   - Cold/warm **app launch** (SPEC: "Cold app launch to interactive
///     empty window") requires actually launching `Kod.app`'s real
///     `NSApplication`/window, which this suite must never do. The
///     proxy below measures constructing the same core singletons a
///     launch bootstraps (`WorkspaceTrustStore`, `RecentWorkspaceStore`,
///     `ThemeStore`, `FontSettingsStore`, `BoundedEventLog`) as a lower
///     bound only.
///   - **Scrolling at 60 Hz**'s true per-frame cost includes AppKit's
///     real display-link-driven compositor, not just `CodeViewport`'s
///     own `draw(_:)`; the proxy below repeatedly calls `draw(_:)` at
///     different scroll offsets into an offscreen bitmap context (the
///     same headless technique `TenMegabyteRepaintBenchmarkTests`
///     already established), which is a faithful proxy for Kod's own
///     rendering cost but excludes the system compositor.
///
/// Every other budget below measures the real, shipped code path.
@MainActor
final class PerformanceSuiteTests: XCTestCase {
    nonisolated static let collector = BenchmarkResultsCollector()
    nonisolated static let defaultIterations = 30

    /// `#filePath` at compile time gives an absolute path regardless of
    /// `swift test`'s current working directory (which varies depending
    /// on whether it is invoked from the repository root or the package
    /// directory), so the JSON artifact always lands in one predictable,
    /// repository-relative location.
    nonisolated static var artifactsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PerformanceSuiteTests.swift -> Tests/PerformanceSuiteTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> KodCore/
            .deletingLastPathComponent() // -> Packages/
            .deletingLastPathComponent() // -> repository root
            .appendingPathComponent("Artifacts/performance", isDirectory: true)
    }

    nonisolated override class func tearDown() {
        super.tearDown()
        let results = collector.snapshot()
        guard !results.isEmpty else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload = PerformanceReport(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                architecture: currentArchitectureLabel(),
                results: results
            )
            let data = try encoder.encode(payload)
            try data.write(to: artifactsDirectory.appendingPathComponent("performance-results.json"))
            print("==> Wrote \(results.count) performance results to \(artifactsDirectory.path)/performance-results.json")
        } catch {
            XCTFail("Failed to write performance-results.json: \(error)")
        }
    }

    nonisolated static func currentArchitectureLabel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { rawBuffer -> String in
            guard let baseAddress = rawBuffer.baseAddress else {
                return "unknown"
            }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
    }

    // MARK: - Measurement helper

    /// Runs `block` once as an untimed warmup (paging in code/data so the
    /// first *measured* iteration is not penalized for the process's own
    /// cold-start cost, which is measured separately by the launch-model
    /// proxy below), then `iterations` timed iterations, and records the
    /// resulting percentiles under `name`.
    @discardableResult
    func measure(
        name: String,
        specBudget: String,
        budgetMilliseconds: Double?,
        iterations: Int = PerformanceSuiteTests.defaultIterations,
        headlessMeasurable: Bool = true,
        notes: String,
        _ block: () throws -> Void
    ) rethrows -> BenchmarkResult {
        try block()

        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            try block()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        let sorted = samples.sorted()

        let p95 = PercentileMath.percentile(sorted, 0.95)
        let passed: Bool?
        if headlessMeasurable, let budgetMilliseconds {
            passed = p95 <= budgetMilliseconds
        } else {
            passed = nil
        }

        let result = BenchmarkResult(
            name: name,
            specBudget: specBudget,
            budgetMilliseconds: budgetMilliseconds,
            iterations: iterations,
            p50Milliseconds: PercentileMath.percentile(sorted, 0.50),
            p95Milliseconds: p95,
            p99Milliseconds: PercentileMath.percentile(sorted, 0.99),
            minMilliseconds: sorted.first ?? 0,
            maxMilliseconds: sorted.last ?? 0,
            headlessMeasurable: headlessMeasurable,
            passed: passed,
            notes: notes
        )
        Self.collector.record(result)

        if let passed {
            XCTAssertTrue(
                passed,
                "\(name): p95 \(result.p95Milliseconds)ms exceeds budget \(budgetMilliseconds ?? -1)ms (SPEC \(specBudget))"
            )
        }
        return result
    }

    // MARK: - Fixture helpers

    func syntheticSource(approximateByteCount: Int) -> String {
        let line = "let value = 42 // a representative line of source text\n"
        let repeats = max(1, approximateByteCount / line.utf8.count)
        return String(repeating: line, count: repeats)
    }

    func hostedViewport(snapshot: SourceSnapshot, size: NSSize) -> (CodeViewport, NSWindow) {
        let viewport = CodeViewport(snapshot: snapshot)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.documentView = viewport
        window.contentView = scrollView
        window.setContentSize(size)
        window.layoutIfNeeded()
        viewport.setMinimumViewportWidth(size.width)
        return (viewport, window)
    }

    func offscreenContext(size: NSSize) throws -> NSGraphicsContext {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw XCTSkip("failed to create offscreen bitmap context")
        }
        return context
    }
}
