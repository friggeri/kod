import AppKit
import PreviewCore

/// A single expandable row in the JSON/plist tree view: a stable
/// identity (its path from the document root) plus the node it displays.
/// Row objects are rebuilt per-search, but their `path` is what
/// `NSOutlineView` item-identity and "copy key path" both key off, not
/// object identity.
final class StructuredTreeRow: NSObject {
    let path: StructuredPath
    let key: String?
    let node: StructuredNode

    init(path: StructuredPath, key: String?, node: StructuredNode) {
        self.path = path
        self.key = key
        self.node = node
    }

    var displayKey: String {
        key ?? Localized.string("root", comment: "Display key shown for the root node of a JSON/plist structured-data preview tree")
    }
}

/// The built-in JSON/property-list preview: an expandable tree view over
/// a `StructuredNode`, search, and copy-value/copy-key-path (SPEC 10.3).
/// Falls back to a plain diagnostic label (never a blank/empty-looking
/// success state) when the document failed to parse — the source view
/// (handled by `EditorGroupViewController`'s existing `CodeDocumentViewController`
/// path, per SPEC 10.3's "Invalid data falls back to the source viewer
/// with a parse diagnostic") remains available via the Source toggle.
@MainActor
final class StructuredDataPreviewViewController: NSViewController {
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let diagnosticLabel = NSTextField(wrappingLabelWithString: "")

    private(set) var document: StructuredDocument
    private var childrenCache: [StructuredPath: [StructuredTreeRow]] = [:]
    private(set) var searchMatches: [StructuredSearchMatch] = []

    init(document: StructuredDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()

        searchField.placeholderString = Localized.string("Search keys and values", comment: "Placeholder text for the structured-data preview's search field")
        searchField.target = self
        searchField.action = #selector(handleSearchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel(Localized.string("Search keys and values", comment: "Accessibility label for the structured-data preview's search field"))

        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        keyColumn.title = Localized.string("Key", comment: "Column title for the structured-data preview's key column")
        keyColumn.width = 180
        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueColumn.title = Localized.string("Value", comment: "Column title for the structured-data preview's value column")
        valueColumn.width = 280

        outlineView.addTableColumn(keyColumn)
        outlineView.addTableColumn(valueColumn)
        outlineView.outlineTableColumn = keyColumn
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = NSTableHeaderView()
        outlineView.rowSizeStyle = .default
        let copyValueItem = NSMenuItem(
            title: Localized.string("Copy Value", comment: "Structured-data preview context menu item that copies the selected node's value"),
            action: #selector(handleCopyValue),
            keyEquivalent: ""
        )
        let copyPathItem = NSMenuItem(
            title: Localized.string("Copy Key Path", comment: "Structured-data preview context menu item that copies the selected node's key path"),
            action: #selector(handleCopyKeyPath),
            keyEquivalent: ""
        )
        let menu = NSMenu()
        menu.addItem(copyValueItem)
        menu.addItem(copyPathItem)
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        diagnosticLabel.textColor = .systemRed
        diagnosticLabel.translatesAutoresizingMaskIntoConstraints = false
        diagnosticLabel.isHidden = document.diagnostic == nil
        diagnosticLabel.stringValue = document.diagnostic?.message ?? ""
        diagnosticLabel.setAccessibilityLabel(Localized.string("Parse error", comment: "Accessibility label for the structured-data preview's parse-error diagnostic text"))

        container.addSubview(searchField)
        container.addSubview(diagnosticLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            diagnosticLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            diagnosticLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            diagnosticLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: diagnosticLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
        outlineView.reloadData()
    }

    /// The rows shown at the outline view's invisible top level
    /// (`item == nil`): a container document's own members/elements
    /// directly (no synthetic wrapper row — `NSOutlineView`'s top level
    /// is already "children of nothing"), or, for the rare case of a
    /// bare scalar as the *entire* document (valid JSON, if unusual),
    /// one single non-expandable row representing it.
    private func topLevelRows() -> [StructuredTreeRow] {
        guard let root = document.node else {
            return []
        }
        switch root {
        case .object(let members):
            return members.map { StructuredTreeRow(path: [.key($0.key)], key: $0.key, node: $0.value) }
        case .array(let elements):
            return elements.enumerated().map { index, element in
                StructuredTreeRow(path: [.index(index)], key: "[\(index)]", node: element)
            }
        default:
            return [StructuredTreeRow(path: [], key: nil, node: root)]
        }
    }

    /// Lazily computes and caches the display rows for the children of
    /// the *non-top-level* container at `path` (always non-empty here —
    /// the top level is handled separately by `topLevelRows()`, never
    /// through this cache, so a container's own path is never confused
    /// with "the children of nothing").
    private func cachedChildren(forPath path: StructuredPath) -> [StructuredTreeRow] {
        if let cached = childrenCache[path] {
            return cached
        }
        guard let root = document.node, let node = node(atPath: path, from: root) else {
            childrenCache[path] = []
            return []
        }
        let rows: [StructuredTreeRow]
        switch node {
        case .object(let members):
            rows = members.map { StructuredTreeRow(path: path + [.key($0.key)], key: $0.key, node: $0.value) }
        case .array(let elements):
            rows = elements.enumerated().map { index, element in
                StructuredTreeRow(path: path + [.index(index)], key: "[\(index)]", node: element)
            }
        default:
            rows = []
        }
        childrenCache[path] = rows
        return rows
    }

    private func node(atPath path: StructuredPath, from root: StructuredNode) -> StructuredNode? {
        var current = root
        for component in path {
            switch (component, current) {
            case (.key(let key), .object(let members)):
                guard let match = members.first(where: { $0.key == key }) else { return nil }
                current = match.value
            case (.index(let index), .array(let elements)):
                guard elements.indices.contains(index) else { return nil }
                current = elements[index]
            default:
                return nil
            }
        }
        return current
    }

    @objc
    private func handleSearchChanged(_ sender: NSSearchField) {
        guard let root = document.node else {
            searchMatches = []
            return
        }
        searchMatches = StructuredSearch.search(root, query: sender.stringValue)
    }

    @objc
    private func handleCopyValue(_ sender: Any?) {
        guard let row = selectedRow() else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.node.previewText, forType: .string)
    }

    @objc
    private func handleCopyKeyPath(_ sender: Any?) {
        guard let row = selectedRow() else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.path.displayString, forType: .string)
    }

    private func selectedRow() -> StructuredTreeRow? {
        let clickedRow = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard clickedRow >= 0 else {
            return nil
        }
        return outlineView.item(atRow: clickedRow) as? StructuredTreeRow
    }

    // MARK: - Test-facing helpers

    /// Builds a cell for `key`/`node` at `column` ("key" or "value")
    /// through the real `NSOutlineViewDelegate` method and returns its
    /// actual `accessibilityLabel()`, so tests assert on the exact same
    /// code path the real outline view uses (see
    /// `StructuredDataPreviewViewControllerTests`).
    func accessibilityLabelForCell(key: String, node: StructuredNode, column: String) -> String? {
        let row = StructuredTreeRow(path: [.key(key)], key: key, node: node)
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column))
        let view = self.outlineView(outlineView, viewFor: tableColumn, item: row) as? NSTextField
        return view?.accessibilityLabel()
    }

    var searchFieldAccessibilityLabel: String? { searchField.accessibilityLabel() }
    var diagnosticAccessibilityLabel: String? { diagnosticLabel.accessibilityLabel() }
}

extension StructuredDataPreviewViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return topLevelRows().count
        }
        guard let row = item as? StructuredTreeRow else {
            return 0
        }
        return cachedChildren(forPath: row.path).count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let row = item as? StructuredTreeRow else {
            return false
        }
        return row.node.isContainer
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return topLevelRows()[index]
        }
        guard let row = item as? StructuredTreeRow else {
            fatalError("unexpected outline item type")
        }
        return cachedChildren(forPath: row.path)[index]
    }
}

extension StructuredDataPreviewViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? StructuredTreeRow, let tableColumn else {
            return nil
        }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        if tableColumn.identifier.rawValue == "key" {
            field.stringValue = row.displayKey
            field.setAccessibilityLabel(Localized.string("Key: \(row.displayKey)", comment: "Accessibility label for a structured-data preview row's key cell"))
        } else {
            field.stringValue = row.node.isContainer ? row.node.previewText : row.node.previewText
            field.setAccessibilityLabel(Localized.string("Value: \(row.node.previewText)", comment: "Accessibility label for a structured-data preview row's value cell"))
        }
        return field
    }
}
