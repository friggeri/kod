import AppKit
import DiagnosticsCore
import FontCore
import Foundation
import GitCore
import KodFixtureSupport
import SearchCore
import SettingsCore
import SourceModel
import SyntaxCore
import ThemeCore
import WorkspaceCore
import XCTest
@testable import CodeViewport

/// The 15 SPEC 12.2 budget benchmarks themselves, split from
/// `PerformanceSuiteTests.swift`'s shared measurement infrastructure
/// purely to keep each file a manageable size.
extension PerformanceSuiteTests {
    // MARK: - Launch model (proxy; never launches real AppKit UI)

    func testLaunchModelProxy() throws {
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )

        measure(
            name: "launch-model-proxy",
            specBudget: "12.2 cold/warm app launch to interactive empty window",
            budgetMilliseconds: nil,
            headlessMeasurable: false,
            notes: "PROXY ONLY, not headless-measurable: constructs the core " +
                "singletons a real launch bootstraps (trust/recent-workspace " +
                "stores, theme/font settings stores, bounded diagnostics log) " +
                "without ever creating Kod's NSApplication/window. Reported for " +
                "engineering visibility only; never asserted against the 750ms " +
                "cold / 300ms warm SPEC targets, which require a real, " +
                "never-run-here Kod.app launch to measure honestly."
        ) {
            _ = WorkspaceTrustStore(repository: repository)
            _ = RecentWorkspaceStore(repository: repository)
            _ = ThemeStore(repository: repository)
            _ = FontSettingsStore(repository: repository)
            _ = BoundedEventLog(capacity: 2_000)
            _ = BundledThemes.all
        }
    }

    // MARK: - 100k-file discovery / Quick Open

    func test100kFileDiscovery() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KOD_RUN_SCALE_TESTS"] == "1",
            "Gated behind KOD_RUN_SCALE_TESTS=1 like WorkspaceCoreTests' own scale " +
                "test: generating and repeatedly scanning a 100,000-file fixture " +
                "is too slow for every default `swift test` invocation. Run via " +
                "`KOD_RUN_SCALE_TESTS=1 Scripts/run-performance-suite`."
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ScaleFixtureGenerator().generate(
            ScaleFixtureConfiguration(root: root, fileCount: 100_000, bytesPerFile: 32)
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var firstBatchSamples: [Double] = []
        var completeSamples: [Double] = []
        let iterations = 30
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            var firstBatchElapsedMs: Double?
            var discoveredCount = 0
            for try await batch in WorkspaceScanner().scan(root: root) {
                if firstBatchElapsedMs == nil {
                    firstBatchElapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1_000
                }
                discoveredCount += batch.entries.count
            }
            let completeMs = (CFAbsoluteTimeGetCurrent() - start) * 1_000
            XCTAssertGreaterThan(discoveredCount, 100_000)
            firstBatchSamples.append(firstBatchElapsedMs ?? completeMs)
            completeSamples.append(completeMs)
        }

        recordPrecomputed(
            name: "100k-file-discovery-first-batch",
            specBudget: "12.2 Workspace open to browsable tree and partial Quick Open results, 100k files",
            budgetMilliseconds: 1_500,
            samples: firstBatchSamples,
            headlessMeasurable: true,
            notes: "First WorkspaceScanner batch over a freshly generated 100,000-file fixture."
        )
        recordPrecomputed(
            name: "100k-file-discovery-complete",
            specBudget: "12.2 Complete filename discovery, 100k files",
            budgetMilliseconds: 3_000,
            samples: completeSamples,
            headlessMeasurable: true,
            notes: "Full WorkspaceScanner discovery over a freshly generated " +
                "100,000-file fixture. On this shared/virtualized session " +
                "environment this has been observed close to or slightly over " +
                "the 3.0s SPEC 12.1 reference-machine budget; see the acceptance-" +
                "evidence report for this run's exact numbers and the " +
                "environment-dependency caveat (SPEC 12.1's reference machine is " +
                "a dedicated baseline Apple-silicon Mac, not necessarily this " +
                "session's shared host)."
        )
    }

    func testQuickOpenQueryUpdateMainThreadWork() async {
        let index = FilenameIndex()
        let entries = (0..<100_000).map { item in
            WorkspaceFileEntry(
                url: URL(fileURLWithPath: "/workspace/Sources/\(item / 1_000)/File-\(item).swift"),
                relativePath: "Sources/\(item / 1_000)/File-\(item).swift",
                kind: .file,
                isHidden: false,
                isIgnored: false
            )
        }
        await index.append(entries)

        var samples: [Double] = []
        for _ in 0..<30 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = await index.search("File-99999")
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }

        recordPrecomputed(
            name: "quick-open-query-update",
            specBudget: "12.2 Quick Open query update after discovery",
            budgetMilliseconds: 16,
            samples: samples,
            headlessMeasurable: true,
            notes: "FilenameIndex.search over a 100,000-entry index, matching the " +
                "SPEC's explicit <=16ms main-thread-work framing."
        )
    }

    // MARK: - 1 MB / 10 MB source first-layout pipeline

    func testOneMegabyteFirstLayoutPipeline() throws {
        try measureFirstLayoutPipeline(approximateByteCount: 1 * 1_024 * 1_024, label: "1mb", budgetMilliseconds: 100)
    }

    func testTenMegabyteFirstLayoutPipeline() throws {
        try measureFirstLayoutPipeline(approximateByteCount: 10 * 1_024 * 1_024, label: "10mb", budgetMilliseconds: 250)
    }

    func testTenMegabyteMinimapUsesViewportBoundedBuffers() throws {
        let snapshot = SourceSnapshot(
            text: syntheticSource(approximateByteCount: 10 * 1_024 * 1_024),
            url: URL(fileURLWithPath: "/10mb-minimap.swift")
        )
        let viewport = CodeViewport(snapshot: snapshot, syntaxLanguage: .swift)
        let layout = CodeMinimapLayout(
            bounds: CGRect(x: 0, y: 0, width: 96, height: 800),
            backingScale: 2,
            totalRows: viewport.minimapTotalVisualRows,
            visibleSourceRows: 40,
            sourceScrollY: 0,
            maximumSourceScrollY: viewport.frame.height,
            requestedColumns: 120
        )
        let presentation = viewport.minimapPresentation(
            visualRows: layout.visibleRowWindow,
            maxColumns: layout.columns
        )
        let renderer = CodeMinimapRenderer()
        renderer.render(
            presentation: presentation,
            layout: layout,
            theme: BundledThemes.dark
        )

        XCTAssertLessThanOrEqual(presentation.rows.count, Int(ceil(layout.bounds.height / layout.rowHeight)))
        XCTAssertEqual(renderer.bufferPixelSize, CGSize(width: 192, height: 1_600))
    }

    private func measureFirstLayoutPipeline(approximateByteCount: Int, label: String, budgetMilliseconds: Double) throws {
        let source = syntheticSource(approximateByteCount: approximateByteCount)
        let size = NSSize(width: 1_200, height: 800)

        try measure(
            name: "\(label)-source-first-layout",
            specBudget: "12.2 Open \(label.uppercased().replacingOccurrences(of: "MB", with: " MB")) UTF-8 source to first plain-text viewport",
            budgetMilliseconds: budgetMilliseconds,
            notes: "Decodes a fresh SourceSnapshot and draws the first visible " +
                "page into an offscreen bitmap context — the full first-paint " +
                "pipeline, end to end, with no syntax/LSP/Git dependency (SPEC " +
                "12.3: \"First paint never waits for a full-file Tree-sitter " +
                "parse or LSP response\")."
        ) {
            let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/\(label).txt"))
            let (viewport, window) = hostedViewport(snapshot: snapshot, size: size)
            let context = try offscreenContext(size: size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            viewport.draw(NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            window.contentView = nil
        }
    }

    // MARK: - Find in File

    func testFindInFileFirstResultTenMegabyteFile() throws {
        let source = syntheticSource(approximateByteCount: 10 * 1_024 * 1_024) + "needle-value-marker\n"
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/ten-megabytes.txt"))

        try measure(
            name: "find-in-file-first-result-10mb",
            specBudget: "12.2 Find in File first result in a 10 MB file",
            budgetMilliseconds: 75,
            notes: "TextFinder.find against a synthetic 10 MB file for a query " +
                "matched exactly once, near the end of the file."
        ) {
            let matches = try TextFinder.find(in: snapshot, query: "needle-value-marker")
            XCTAssertFalse(matches.isEmpty)
        }
    }

    // MARK: - Workspace search first result

    func testWorkspaceSearchFirstResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<200 {
            let fileURL = root.appendingPathComponent("File-\(index).swift")
            try "let value = \(index)\nfunc needleTarget() {}\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        guard let searcher = try? WorkspaceTextSearcher() else {
            throw XCTSkip("bundled ripgrep engine unavailable for this architecture")
        }

        var samples: [Double] = []
        for iteration in 0..<30 {
            let start = CFAbsoluteTimeGetCurrent()
            var receivedFirstResult = false
            let stream = await searcher.search(
                SearchQuery(pattern: "needleTarget", root: root, version: iteration)
            )
            for try await event in stream {
                if case .fileResult = event {
                    receivedFirstResult = true
                    break
                }
            }
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            XCTAssertTrue(receivedFirstResult)
        }

        recordPrecomputed(
            name: "workspace-search-first-result",
            specBudget: "12.2 Workspace search first result on a warm local SSD",
            budgetMilliseconds: 200,
            samples: samples,
            headlessMeasurable: true,
            notes: "WorkspaceTextSearcher (bundled ripgrep) over a small on-disk " +
                "fixture tree, timing to the first streamed match event."
        )
    }

    // MARK: - Back/Forward restore

    func testBackForwardRestoreOfAlreadyOpenLocation() throws {
        let store = WorkspaceLayoutStore(
            repository: CodableSettingsRepository(
                store: InMemorySettingsKeyValueStore()
            )
        )
        let identity = try WorkspaceIdentity(root: FileManager.default.temporaryDirectory)

        var group = EditorGroupState()
        for index in 0..<50 {
            group.openTab(relativePath: "Sources/File-\(index).swift", pinned: true)
        }
        group.current = EditorNavigationEntry(
            relativePath: "Sources/File-49.swift",
            selection: EditorSelection(0..<10),
            viewportAnchorLine: 42
        )
        let state = WorkspaceLayoutState(root: .leaf(group.id), groups: [group.id: group], activeGroupID: group.id)
        try store.save(state, for: identity)

        try measure(
            name: "back-forward-restore",
            specBudget: "12.2 Back/Forward restore of an already open location",
            budgetMilliseconds: 50,
            notes: "WorkspaceLayoutStore.load decode of a persisted 50-tab " +
                "layout with navigation history — the model-restore portion of " +
                "a Back/Forward jump to an already-open location."
        ) {
            guard case .value = try store.load(for: identity) else {
                return XCTFail("Expected persisted layout")
            }
        }
    }

    // MARK: - Theme change to visible repaint / model resolution

    func testThemeChangeRepaintAndModelResolution() throws {
        let source = syntheticSource(approximateByteCount: 512 * 1_024)
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/theme-change.swift"))
        let size = NSSize(width: 1_200, height: 800)
        let (viewport, window) = hostedViewport(snapshot: snapshot, size: size)
        let context = try offscreenContext(size: size)
        var useDark = false

        measure(
            name: "theme-change-repaint",
            specBudget: "12.2 Theme change to visible repaint",
            budgetMilliseconds: 100,
            notes: "Switches CodeViewport.theme between the bundled light/dark " +
                "themes and redraws the visible page into an offscreen bitmap " +
                "context — the model-resolution (token-style lookup) plus " +
                "repaint cost of a theme change."
        ) {
            useDark.toggle()
            viewport.theme = useDark ? BundledThemes.dark : BundledThemes.light
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            viewport.draw(NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
        }
        window.contentView = nil
    }

    // MARK: - External file write to visible refreshed snapshot (Kod-side portion)

    func testExternalRefreshReconciliation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("changed.swift")

        let originalSource = syntheticSource(approximateByteCount: 256 * 1_024)
        try originalSource.write(to: fileURL, atomically: true, encoding: .utf8)
        let oldSnapshot = SourceSnapshot(text: originalSource, url: fileURL)
        let anchor = ReadingAnchor(
            selection: EditorSelection(0..<5),
            viewportAnchorLine: 100,
            foldedHeaderLines: [10, 20, 30]
        )

        var revision = 0
        try measure(
            name: "external-refresh-reconciliation",
            specBudget: "12.2 External file write to visible refreshed snapshot",
            budgetMilliseconds: 500,
            notes: "PROXY for the Kod-side portion only: decodes a changed " +
                "on-disk snapshot and reconciles the prior reading anchor onto " +
                "it (SPEC 5.6). Excludes FSEvents' own OS-driven coalescing " +
                "latency before Kod ever observes the write, which is outside " +
                "Kod's code and not meaningfully measurable in a tight, " +
                "deterministic 30-iteration loop."
        ) {
            revision += 1
            let updatedSource = originalSource + "// revision \(revision)\n"
            try updatedSource.write(to: fileURL, atomically: true, encoding: .utf8)
            let newText = try String(contentsOf: fileURL, encoding: .utf8)
            let newSnapshot = SourceSnapshot(text: newText, url: fileURL)
            _ = ReadingAnchorReconciler.reconcile(anchor, from: oldSnapshot, to: newSnapshot)
        }
    }

    // MARK: - Main-thread work proxy

    func testMainThreadWorkProxy() throws {
        let source = syntheticSource(approximateByteCount: 1 * 1_024 * 1_024)
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/main-thread.swift"))
        let engine = SyntaxEngine()
        let tree = try runBlocking { try await engine.parse(snapshot: snapshot, language: .swift) }
        let size = NSSize(width: 1_200, height: 800)
        let (viewport, window) = hostedViewport(snapshot: snapshot, size: size)
        viewport.applySyntaxTree(tree)
        var layerVersion = 1
        // The visible viewport's byte range only (matching SPEC 12.3
        // "progressive intelligence"/prioritized-viewport highlighting,
        // and this file's own `testViewportPrioritizedHighlightReturns
        // QuicklyEvenForTenMegabyteFile`): a real highlight-completion
        // task applies only what changed for the currently visible
        // page, not the whole file's captures, so that is the correct,
        // representative unit of main-thread work to measure here —
        // capturing the *entire* 1 MB file on every apply would measure
        // an off-main-thread background pass's cost as if it were one
        // synchronous main-thread task.
        let viewportByteRange = 0..<min(4_000, snapshot.utf8Count)

        measure(
            name: "main-thread-work-proxy",
            specBudget: "12.2 Main-thread stall after initial window display",
            budgetMilliseconds: 50,
            notes: "PROXY: applying one viewport's worth of an already-parsed " +
                "1 MB file's decoration layer (the single discrete main-thread " +
                "task AppKit dispatches when new highlighting data arrives for " +
                "the visible page) as a lower bound on \"no task > 50ms.\" " +
                "`layerVersion` increments every iteration so each call is a " +
                "genuinely new layer, not a short-circuited duplicate. The " +
                "resulting redraw itself is a separate, AppKit-scheduled task " +
                "measured instead by core-text-visible-line-draw below; " +
                "combining both into one call would measure two real tasks as " +
                "if they were one."
        ) {
            layerVersion += 1
            _ = viewport.applyDecorationLayer(
                LexicalDecorationSource.layer(
                    fromCaptures: tree.captures(inByteRange: viewportByteRange),
                    theme: viewport.theme,
                    snapshotVersion: snapshot.version,
                    layerVersion: layerVersion
                )
            )
        }
        window.contentView = nil
    }

    // MARK: - Core Text visible-line draw/layout & scrolling proxy

    func testCoreTextVisibleLineDrawAndScrollProxy() throws {
        let source = syntheticSource(approximateByteCount: 10 * 1_024 * 1_024)
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/scroll.txt"))
        let size = NSSize(width: 1_200, height: 800)
        let (viewport, window) = hostedViewport(snapshot: snapshot, size: size)
        let context = try offscreenContext(size: size)
        var scrollLine = 0
        let totalLines = source.split(separator: "\n", omittingEmptySubsequences: false).count

        measure(
            name: "core-text-visible-line-draw",
            specBudget: "12.2 Scrolling at 60 Hz (p95 <= 16.7ms, p99 <= 33ms) / Core Text visible-line draw",
            budgetMilliseconds: 16.7,
            notes: "PROXY for Core Text visible-line layout/draw cost only: " +
                "repeatedly scrolls to a new line and redraws the visible page " +
                "into an offscreen bitmap context. Excludes AppKit's own " +
                "display-link-driven compositor and window-server costs, so " +
                "this is a faithful measure of Kod's own rendering work but not " +
                "the full system frame budget."
        ) {
            scrollLine = (scrollLine + 137) % max(1, totalLines - 40)
            viewport.scrollSourceLineToTop(scrollLine)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            viewport.draw(NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
        }
        window.contentView = nil
    }

    // MARK: - Kod-process memory model

    func testKodProcessMemoryModel() throws {
        // Holds a 100k-entry filename index and a 10 MB open file's
        // snapshot + syntax tree simultaneously (SPEC 12.2's reference
        // scenario), then measures this actual test process's own
        // resident memory via `mach_task_basic_info` — a real
        // measurement technique, but of this XCTest host process rather
        // than a full running Kod.app (so it excludes AppKit/UIKit
        // framework overhead, window server surfaces, and any
        // LSP/search/Git child process — all things the SPEC budget
        // itself already explicitly excludes or that only a real app
        // launch could include).
        let index = FilenameIndex()
        let entries = (0..<100_000).map { item in
            WorkspaceFileEntry(
                url: URL(fileURLWithPath: "/workspace/Sources/\(item / 1_000)/File-\(item).swift"),
                relativePath: "Sources/\(item / 1_000)/File-\(item).swift",
                kind: .file,
                isHidden: false,
                isIgnored: false
            )
        }
        try runBlocking { await index.append(entries) }

        let source = syntheticSource(approximateByteCount: 10 * 1_024 * 1_024)
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/ten-megabytes.swift"))
        let engine = SyntaxEngine()
        let tree = try runBlocking { try await engine.parse(snapshot: snapshot, language: .swift) }

        let residentBytes = Self.currentResidentMemoryBytes()
        let residentMB = Double(residentBytes) / (1_024 * 1_024)
        withExtendedLifetime((index, snapshot, tree)) {}

        let result = BenchmarkResult(
            name: "kod-process-memory-model",
            specBudget: "12.2 Kod resident memory, 100k-file workspace with one 10 MB file open",
            budgetMilliseconds: nil,
            iterations: 1,
            p50Milliseconds: residentMB,
            p95Milliseconds: residentMB,
            p99Milliseconds: residentMB,
            minMilliseconds: residentMB,
            maxMilliseconds: residentMB,
            headlessMeasurable: false,
            passed: residentMB <= 350,
            notes: "PROXY, reported in MB (not ms): this XCTest host process's " +
                "own resident memory while holding a 100,000-entry FilenameIndex " +
                "plus one 10 MB file's SourceSnapshot and parsed SyntaxTree. " +
                "Excludes AppKit/window-server overhead a real running Kod.app " +
                "would add and any LSP/search/Git child process (which the SPEC " +
                "budget itself already excludes). Not asserted as a hard " +
                "pass/fail gate; reported for engineering visibility."
        )
        Self.collector.record(result)
        print("==> \(result.name): \(residentMB) MB resident (budget <= 350 MB, proxy process only)")
    }

    private static func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPointer -> kern_return_t in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        return info.resident_size
    }

    // MARK: - Precomputed-sample recording (for async loops measured by hand)

    private func recordPrecomputed(
        name: String,
        specBudget: String,
        budgetMilliseconds: Double?,
        samples: [Double],
        headlessMeasurable: Bool,
        notes: String
    ) {
        let sorted = samples.sorted()
        let p95 = PercentileMath.percentile(sorted, 0.95)
        let passed: Bool? = (headlessMeasurable && budgetMilliseconds != nil) ? (p95 <= budgetMilliseconds!) : nil

        let result = BenchmarkResult(
            name: name,
            specBudget: specBudget,
            budgetMilliseconds: budgetMilliseconds,
            iterations: samples.count,
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
    }

    /// Bridges an `async throws` operation into this file's synchronous
    /// `measure` helper closures, which cannot themselves be `async`
    /// (XCTest's `measure`-style timing here is deliberately synchronous
    /// so iteration overhead stays uniform across every budget in this
    /// suite). Only ever used for a one-time fixture setup (parsing the
    /// syntax tree used by later, purely synchronous measured
    /// iterations) — never inside a timed block itself.
    private func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let box = LockedBox<Result<T, Error>>()
        let semaphore = DispatchSemaphore(value: 0)
        // Must be `Task.detached`, never a plain `Task { ... }`: this
        // method is called from `@MainActor`-isolated test methods, and
        // a non-detached `Task` inherits that MainActor isolation. Its
        // body would then need the MainActor executor to run at all —
        // but `semaphore.wait()` below blocks that same main thread
        // synchronously with no run-loop servicing, which would deadlock
        // forever rather than merely running slowly.
        Task.detached {
            do {
                box.value = .success(try await operation())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let value = box.value else {
            throw CocoaError(.fileReadUnknown)
        }
        return try value.get()
    }
}

/// A tiny `NSLock`-protected box, used only by `runBlocking` above to
/// hand a value back across the `Task`/semaphore boundary.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?

    var value: T? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}
