import AppKit
import CodeViewport
import Foundation
import LanguageClient
import SourceModel
import os

private let languageHoverLog = Logger(
    subsystem: "com.kodapp.Kod",
    category: "language-hover"
)

@MainActor
final class LanguageHoverController {
    struct AnchorKey: Hashable {
        let providerIdentifier: String
        let providerGeneration: UInt64
        let globalGeneration: UInt64
        let documentURL: URL
        let snapshotVersion: Int
        let utf8Range: Range<Int>
    }

    enum CachedDefinitions {
        case missing
        case resolved([NavigationTarget])
    }

    typealias HoverRequest = @MainActor (SourceSnapshot, Int) async throws -> Hover?
    typealias DefinitionRequest = @MainActor (SourceSnapshot, Int) async throws -> [NavigationTarget]

    var onHoverApplied: ((AnchorKey, Hover?) -> Void)?
    var onDefinitionsApplied: ((AnchorKey, [NavigationTarget]) -> Void)?

    private enum HoverState {
        case pending
        case resolved(Hover?)
        case failed
    }

    private enum CachedValue<Value> {
        case missing
        case resolved(Value)
    }

    private struct CacheEntry {
        var hover: CachedValue<Hover?> = .missing
        var definitions: CachedValue<[NavigationTarget]> = .missing
    }

    private let dwellDuration: Duration
    private let cacheCapacity: Int
    private let hoverRequest: HoverRequest
    private let definitionRequest: DefinitionRequest

    private var globalGeneration: UInt64 = 0
    private var providerGenerations: [String: UInt64] = [:]
    private var cache: [AnchorKey: CacheEntry] = [:]
    private var cacheRecency: [AnchorKey] = []
    private weak var currentController: CodeDocumentViewController?
    private var currentKey: AnchorKey?
    private var latestAnchorRect = NSRect.zero
    private var interactionGeneration: UInt64 = 0
    private var hoverState = HoverState.pending
    private var dwellElapsed = false
    private var hoverWasApplied = false
    private var hoverTask: Task<Void, Never>?
    private var definitionTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?

    init(
        dwellDuration: Duration = .milliseconds(75),
        cacheCapacity: Int = 256,
        hoverRequest: @escaping HoverRequest,
        definitionRequest: @escaping DefinitionRequest
    ) {
        self.dwellDuration = dwellDuration
        self.cacheCapacity = max(1, cacheCapacity)
        self.hoverRequest = hoverRequest
        self.definitionRequest = definitionRequest
    }

    func update(
        controller: CodeDocumentViewController,
        providerIdentifier: String,
        utf8Offset: Int,
        targetRange: Range<Int>,
        anchorRect: NSRect
    ) {
        let snapshot = controller.snapshot
        guard targetRange.contains(utf8Offset),
              targetRange.lowerBound >= 0,
              targetRange.upperBound <= snapshot.utf8Count else {
            cancel(for: controller)
            return
        }

        let key = AnchorKey(
            providerIdentifier: providerIdentifier,
            providerGeneration: providerGenerations[providerIdentifier, default: 0],
            globalGeneration: globalGeneration,
            documentURL: snapshot.url.standardizedFileURL,
            snapshotVersion: snapshot.version,
            utf8Range: targetRange
        )
        if currentController === controller, currentKey == key {
            latestAnchorRect = anchorRect
            return
        }

        cancel()
        interactionGeneration &+= 1
        let generation = interactionGeneration
        currentController = controller
        currentKey = key
        latestAnchorRect = anchorRect
        hoverState = .pending
        dwellElapsed = dwellDuration == .zero
        hoverWasApplied = false
        controller.dismissHover()
        controller.viewport.setHoveredLinkUTF8Range(nil)

        let cachedEntry = cachedEntry(for: key)
        if case .resolved(let hover) = cachedEntry?.hover {
            hoverState = .resolved(hover)
        }

        if !dwellElapsed {
            presentationTask = Task { @MainActor [weak self, weak controller] in
                do {
                    try await Task.sleep(for: self?.dwellDuration ?? .zero)
                } catch {
                    return
                }
                guard let self, let controller,
                      self.isCurrent(key: key, generation: generation, controller: controller) else {
                    return
                }
                self.dwellElapsed = true
                self.applyHoverIfReady(
                    key: key,
                    generation: generation,
                    controller: controller
                )
            }
        }

        if case .missing = cachedEntry?.hover ?? .missing {
            hoverTask = Task { @MainActor [weak self, weak controller] in
                guard let self, let controller else {
                    return
                }
                do {
                    let hover = try await self.hoverRequest(snapshot, utf8Offset)
                    guard !Task.isCancelled,
                          self.isCurrent(
                            key: key,
                            generation: generation,
                            controller: controller
                          ) else {
                        return
                    }
                    self.updateCache(for: key) { $0.hover = .resolved(hover) }
                    self.hoverState = .resolved(hover)
                    self.applyHoverIfReady(
                        key: key,
                        generation: generation,
                        controller: controller
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrent(
                        key: key,
                        generation: generation,
                        controller: controller
                    ) else {
                        return
                    }
                    self.hoverState = .failed
                    languageHoverLog.debug(
                        "Hover request failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        applyHoverIfReady(
            key: key,
            generation: generation,
            controller: controller
        )

        if case .resolved(let targets) = cachedEntry?.definitions {
            controller.viewport.setHoveredLinkUTF8Range(
                targets.isEmpty ? nil : targetRange
            )
            onDefinitionsApplied?(key, targets)
        } else {
            definitionTask = Task { @MainActor [weak self, weak controller] in
                guard let self, let controller else {
                    return
                }
                do {
                    let targets = try await self.definitionRequest(snapshot, utf8Offset)
                    guard !Task.isCancelled,
                          self.isCurrent(
                            key: key,
                            generation: generation,
                            controller: controller
                          ) else {
                        return
                    }
                    self.updateCache(for: key) {
                        $0.definitions = .resolved(targets)
                    }
                    controller.viewport.setHoveredLinkUTF8Range(
                        targets.isEmpty ? nil : targetRange
                    )
                    self.onDefinitionsApplied?(key, targets)
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrent(
                        key: key,
                        generation: generation,
                        controller: controller
                    ) else {
                        return
                    }
                    controller.viewport.setHoveredLinkUTF8Range(nil)
                    languageHoverLog.debug(
                        "Definition request failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    func cachedDefinitions(
        controller: CodeDocumentViewController,
        providerIdentifier: String,
        utf8Offset: Int
    ) -> CachedDefinitions {
        guard let range = controller.viewport.hoverTargetUTF8Range(at: utf8Offset) else {
            return .missing
        }
        let snapshot = controller.snapshot
        let key = AnchorKey(
            providerIdentifier: providerIdentifier,
            providerGeneration: providerGenerations[providerIdentifier, default: 0],
            globalGeneration: globalGeneration,
            documentURL: snapshot.url.standardizedFileURL,
            snapshotVersion: snapshot.version,
            utf8Range: range
        )
        guard let entry = cachedEntry(for: key) else {
            return .missing
        }
        switch entry.definitions {
        case .missing:
            return .missing
        case .resolved(let targets):
            return .resolved(targets)
        }
    }

    func invalidateCache(forProvider providerIdentifier: String? = nil) {
        if let providerIdentifier {
            if currentKey?.providerIdentifier == providerIdentifier {
                cancel()
            }
            providerGenerations[providerIdentifier, default: 0] &+= 1
            cache = cache.filter { $0.key.providerIdentifier != providerIdentifier }
            cacheRecency.removeAll {
                $0.providerIdentifier == providerIdentifier
            }
        } else {
            cancel()
            globalGeneration &+= 1
            cache.removeAll(keepingCapacity: true)
            cacheRecency.removeAll(keepingCapacity: true)
        }
    }

    var cachedEntryCount: Int {
        cache.count
    }

    func cancel(for controller: CodeDocumentViewController? = nil) {
        if let controller, currentController !== controller {
            return
        }
        interactionGeneration &+= 1
        hoverTask?.cancel()
        definitionTask?.cancel()
        presentationTask?.cancel()
        hoverTask = nil
        definitionTask = nil
        presentationTask = nil
        currentController?.dismissHover()
        currentController?.viewport.setHoveredLinkUTF8Range(nil)
        currentController = nil
        currentKey = nil
        hoverState = .pending
        dwellElapsed = false
        hoverWasApplied = false
    }

    private func applyHoverIfReady(
        key: AnchorKey,
        generation: UInt64,
        controller: CodeDocumentViewController
    ) {
        guard dwellElapsed,
              !hoverWasApplied,
              isCurrent(key: key, generation: generation, controller: controller),
              case .resolved(let hover) = hoverState else {
            return
        }
        hoverWasApplied = true
        if let hover {
            controller.presentHover(
                hover.contents.value,
                atViewportRect: latestAnchorRect
            )
        } else {
            controller.dismissHover()
        }
        onHoverApplied?(key, hover)
    }

    private func isCurrent(
        key: AnchorKey,
        generation: UInt64,
        controller: CodeDocumentViewController
    ) -> Bool {
        currentController === controller
            && currentKey == key
            && interactionGeneration == generation
            && controller.snapshot.version == key.snapshotVersion
            && controller.snapshot.url.standardizedFileURL == key.documentURL
    }

    private func cachedEntry(for key: AnchorKey) -> CacheEntry? {
        guard let entry = cache[key] else {
            return nil
        }
        touch(key)
        return entry
    }

    private func updateCache(
        for key: AnchorKey,
        update: (inout CacheEntry) -> Void
    ) {
        var entry = cache[key] ?? CacheEntry()
        update(&entry)
        cache[key] = entry
        touch(key)
        while cache.count > cacheCapacity, let oldest = cacheRecency.first {
            cacheRecency.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: AnchorKey) {
        cacheRecency.removeAll { $0 == key }
        cacheRecency.append(key)
    }
}
