import Foundation

/// Workspace-scoped diagnostics keyed by language-profile owner and resource.
/// Raw entries retain producer separation; presentation snapshots merge files
/// and suppress only identical diagnostics reported by different owners.
@MainActor
public final class WorkspaceDiagnosticsStore {
    public typealias Owner = String

    public struct Snapshot: Sendable {
        public let diagnosticsByOwner: [Owner: [URL: [Diagnostic]]]
        public let presentationDiagnosticsByFile: [URL: [Diagnostic]]

        public init(
            diagnosticsByOwner: [Owner: [URL: [Diagnostic]]],
            presentationDiagnosticsByFile: [URL: [Diagnostic]]
        ) {
            self.diagnosticsByOwner = diagnosticsByOwner
            self.presentationDiagnosticsByFile = presentationDiagnosticsByFile
        }
    }

    private struct DiagnosticIdentity: Equatable {
        let range: LSPRange
        let severity: DiagnosticSeverity?
        let code: JSONValue?
        let source: String?
        let message: String

        init(_ diagnostic: Diagnostic) {
            range = diagnostic.range
            severity = diagnostic.severity
            code = diagnostic.code
            source = diagnostic.source
            message = diagnostic.message
        }
    }

    private struct PresentedIdentity {
        let owner: Owner
        let identity: DiagnosticIdentity
    }

    private var diagnosticsByOwner: [Owner: [URL: [Diagnostic]]] = [:]
    private var presentationDiagnosticsByFile: [URL: [Diagnostic]] = [:]
    private var observers: [UUID: @MainActor @Sendable (Snapshot) -> Void] = [:]

    public init() {}

    public var snapshot: Snapshot {
        Snapshot(
            diagnosticsByOwner: diagnosticsByOwner,
            presentationDiagnosticsByFile: presentationDiagnosticsByFile
        )
    }

    public func diagnostics(owner: Owner, resource: URL) -> [Diagnostic] {
        diagnosticsByOwner[owner]?[resource.standardizedFileURL] ?? []
    }

    public func replace(owner: Owner, resource: URL, diagnostics: [Diagnostic]) {
        let resource = resource.standardizedFileURL
        if diagnostics.isEmpty {
            guard diagnosticsByOwner[owner]?.removeValue(forKey: resource) != nil else {
                return
            }
            if diagnosticsByOwner[owner]?.isEmpty == true {
                diagnosticsByOwner.removeValue(forKey: owner)
            }
        } else {
            guard diagnosticsByOwner[owner]?[resource] != diagnostics else {
                return
            }
            diagnosticsByOwner[owner, default: [:]][resource] = diagnostics
        }
        updatePresentation(for: resource)
        notifyObservers()
    }

    public func clear(owner: Owner) {
        guard let removedResources = diagnosticsByOwner.removeValue(forKey: owner) else {
            return
        }
        for resource in removedResources.keys {
            updatePresentation(for: resource)
        }
        notifyObservers()
    }

    public func clear(resource: URL) {
        let resource = resource.standardizedFileURL
        var changed = false
        for owner in Array(diagnosticsByOwner.keys) {
            if diagnosticsByOwner[owner]?.removeValue(forKey: resource) != nil {
                changed = true
            }
            if diagnosticsByOwner[owner]?.isEmpty == true {
                diagnosticsByOwner.removeValue(forKey: owner)
            }
        }
        if changed {
            presentationDiagnosticsByFile.removeValue(forKey: resource)
            notifyObservers()
        }
    }

    public func clearAll() {
        guard !diagnosticsByOwner.isEmpty else {
            return
        }
        diagnosticsByOwner.removeAll()
        presentationDiagnosticsByFile.removeAll()
        notifyObservers()
    }

    @discardableResult
    public func observeChanges(
        _ observer: @escaping @MainActor @Sendable (Snapshot) -> Void
    ) -> UUID {
        let identifier = UUID()
        observers[identifier] = observer
        observer(snapshot)
        return identifier
    }

    public func removeObserver(_ identifier: UUID) {
        observers.removeValue(forKey: identifier)
    }

    private func notifyObservers() {
        let snapshot = snapshot
        for observer in observers.values {
            observer(snapshot)
        }
    }

    private func updatePresentation(for resource: URL) {
        var diagnosticsForPresentation: [Diagnostic] = []
        var identities: [PresentedIdentity] = []
        for owner in diagnosticsByOwner.keys.sorted() {
            guard let diagnostics = diagnosticsByOwner[owner]?[resource] else {
                continue
            }
            for diagnostic in diagnostics {
                let identity = DiagnosticIdentity(diagnostic)
                let isDuplicateFromAnotherOwner = identities.contains {
                    $0.owner != owner && $0.identity == identity
                }
                if !isDuplicateFromAnotherOwner {
                    diagnosticsForPresentation.append(diagnostic)
                }
                identities.append(PresentedIdentity(owner: owner, identity: identity))
            }
        }
        if diagnosticsForPresentation.isEmpty {
            presentationDiagnosticsByFile.removeValue(forKey: resource)
        } else {
            presentationDiagnosticsByFile[resource] = diagnosticsForPresentation
        }
    }
}
