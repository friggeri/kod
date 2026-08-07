/// A tiny, deterministic fixture type for SourceKit-LSP integration tests:
/// hover, definition, references, document symbols, diagnostics, and
/// semantic tokens are all exercised against this single small file.
public struct Greeter {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    /// Returns a friendly greeting for `name`.
    public func greet() -> String {
        "Hello, \(name)!"
    }
}

public func makeDefaultGreeter() -> Greeter {
    Greeter(name: "Kod")
}
