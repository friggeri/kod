import AppKit
import CodeViewport
import GitCore
import KodUIComponents
import LanguageClient
import SourceModel

@MainActor
final class WorkspaceStatusBarView: NSVisualEffectView {
    enum Tone: Equatable {
        case normal
        case secondary
        case progress
        case warning
        case error
    }

    struct Item: Equatable {
        let text: String
        let accessibilityLabel: String
        let accessibilityValue: String
        let toolTip: String?
        let tone: Tone

        init(
            text: String,
            accessibilityLabel: String,
            accessibilityValue: String? = nil,
            toolTip: String? = nil,
            tone: Tone = .secondary
        ) {
            self.text = text
            self.accessibilityLabel = accessibilityLabel
            self.accessibilityValue = accessibilityValue ?? text
            self.toolTip = toolTip
            self.tone = tone
        }
    }

    struct Model: Equatable {
        let branch: Item?
        let git: Item?
        let languageServer: Item
        let showsLanguageServerRestart: Bool
        let enablesLanguageServerRestart: Bool
        let language: Item?
        let encoding: Item?
        let lineEnding: Item?
        let cursor: Item?
    }

    struct LayoutPlan: Equatable {
        let showsLineEnding: Bool
        let showsEncoding: Bool
        let showsLanguage: Bool
        let truncatesBranch: Bool
        let estimatedRequiredWidth: CGFloat
    }

    var onShowSourceControl: (() -> Void)?
    var onRestartLanguageServer: (() -> Void)?

    private let branchButton = NSButton()
    private let gitButton = NSButton()
    private let languageServerLabel = NSTextField(labelWithString: "")
    private let restartButton = KodSymbolButton(
        systemSymbolName: "arrow.clockwise",
        accessibilityLabel: Localized.string(
            "Restart Language Server",
            comment: "Accessibility label for the language server restart button"
        ),
        pointSize: 12
    )
    private let languageLabel = NSTextField(labelWithString: "")
    private let encodingLabel = NSTextField(labelWithString: "")
    private let lineEndingLabel = NSTextField(labelWithString: "")
    private let cursorLabel = NSTextField(labelWithString: "")
    private let trustControl: NSButton
    private var model: Model?
    private var appliedLayoutPlan: LayoutPlan?

    init(trustControl: NSButton) {
        self.trustControl = trustControl
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("workspace.statusBar")
        material = .contentBackground
        blendingMode = .withinWindow
        state = .active
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            Localized.string(
                "Workspace status",
                comment: "Accessibility label for the workspace status bar"
            )
        )

        configureButton(
            branchButton,
            identifier: "workspace.status.branch",
            symbolName: "arrow.triangle.branch",
            action: #selector(showSourceControl(_:)),
            truncationMode: .byTruncatingMiddle
        )
        configureButton(
            gitButton,
            identifier: "workspace.status.git",
            symbolName: "arrow.triangle.2.circlepath",
            action: #selector(showSourceControl(_:)),
            truncationMode: .byTruncatingTail
        )
        configureLabel(
            languageServerLabel,
            identifier: "workspace.languageServerState"
        )
        configureLabel(
            languageLabel,
            identifier: "workspace.status.language"
        )
        configureLabel(
            encodingLabel,
            identifier: "workspace.status.encoding"
        )
        configureLabel(
            lineEndingLabel,
            identifier: "workspace.status.lineEnding"
        )
        configureLabel(
            cursorLabel,
            identifier: "workspace.status.cursor"
        )

        restartButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.languageServerRestart"
        )
        restartButton.target = self
        restartButton.action = #selector(restartLanguageServer(_:))
        restartButton.translatesAutoresizingMaskIntoConstraints = false
        restartButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        restartButton.heightAnchor.constraint(equalToConstant: 20).isActive = true

        trustControl.translatesAutoresizingMaskIntoConstraints = false
        trustControl.widthAnchor.constraint(equalToConstant: 24).isActive = true
        trustControl.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let leftStack = NSStackView(
            views: [
                branchButton,
                gitButton,
                languageServerLabel,
                restartButton
            ]
        )
        configureStack(leftStack)

        let rightStack = NSStackView(
            views: [
                languageLabel,
                encodingLabel,
                lineEndingLabel,
                cursorLabel,
                trustControl
            ]
        )
        configureStack(rightStack)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let contentStack = NSStackView(views: [leftStack, spacer, rightStack])
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.setAccessibilityElement(false)
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        branchButton.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        gitButton.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        languageServerLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        languageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        cursorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        branchButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        languageServerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cursorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        branchButton.nextKeyView = gitButton
        gitButton.nextKeyView = restartButton
        restartButton.nextKeyView = trustControl
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(_ model: Model) {
        self.model = model
        render(model.branch, on: branchButton)
        render(model.git, on: gitButton)
        render(model.languageServer, on: languageServerLabel)
        render(model.language, on: languageLabel)
        render(model.encoding, on: encodingLabel)
        render(model.lineEnding, on: lineEndingLabel)
        render(model.cursor, on: cursorLabel)
        restartButton.isHidden = !model.showsLanguageServerRestart
        restartButton.isEnabled = model.enablesLanguageServerRestart
        appliedLayoutPlan = nil
        needsLayout = true
    }

    override func layout() {
        if let model {
            let plan = Self.layoutPlan(
                for: model,
                availableWidth: bounds.width
            )
            if plan != appliedLayoutPlan {
                lineEndingLabel.isHidden =
                    model.lineEnding == nil || !plan.showsLineEnding
                encodingLabel.isHidden =
                    model.encoding == nil || !plan.showsEncoding
                languageLabel.isHidden =
                    model.language == nil || !plan.showsLanguage
                appliedLayoutPlan = plan
            }
        }
        super.layout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let model {
            update(model)
        }
    }

    static func layoutPlan(
        for model: Model,
        availableWidth: CGFloat
    ) -> LayoutPlan {
        var showsLineEnding = model.lineEnding != nil
        var showsEncoding = model.encoding != nil
        var showsLanguage = model.language != nil

        func textWidth(_ item: Item?, maximum: CGFloat) -> CGFloat {
            guard let item else {
                return 0
            }
            let measured = (item.text as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 11)]
            ).width + 12
            return min(maximum, ceil(measured))
        }

        func estimatedWidth(
            minimumBranchWidth: Bool
        ) -> CGFloat {
            var widths: [CGFloat] = []
            if model.branch != nil {
                widths.append(
                    minimumBranchWidth
                        ? 72
                        : textWidth(model.branch, maximum: 260)
                )
            }
            if model.git != nil {
                widths.append(textWidth(model.git, maximum: 120))
            }
            widths.append(textWidth(model.languageServer, maximum: 200))
            if model.showsLanguageServerRestart {
                widths.append(20)
            }
            if showsLanguage {
                widths.append(textWidth(model.language, maximum: 140))
            }
            if showsEncoding {
                widths.append(textWidth(model.encoding, maximum: 90))
            }
            if showsLineEnding {
                widths.append(textWidth(model.lineEnding, maximum: 70))
            }
            if model.cursor != nil {
                widths.append(textWidth(model.cursor, maximum: 140))
            }
            widths.append(24)
            let spacing = CGFloat(max(0, widths.count - 1)) * 8
            return 18 + widths.reduce(0, +) + spacing
        }

        if estimatedWidth(minimumBranchWidth: false) > availableWidth {
            showsLineEnding = false
        }
        if estimatedWidth(minimumBranchWidth: false) > availableWidth {
            showsEncoding = false
        }
        if estimatedWidth(minimumBranchWidth: false) > availableWidth {
            showsLanguage = false
        }

        let idealWidth = estimatedWidth(minimumBranchWidth: false)
        return LayoutPlan(
            showsLineEnding: showsLineEnding,
            showsEncoding: showsEncoding,
            showsLanguage: showsLanguage,
            truncatesBranch: model.branch != nil && idealWidth > availableWidth,
            estimatedRequiredWidth: estimatedWidth(minimumBranchWidth: true)
        )
    }

    static func gitItems(
        for state: GitWorkspaceCoordinator.RepositoryState
    ) -> (branch: Item?, git: Item?) {
        switch state {
        case .loading:
            return (
                nil,
                Item(
                    text: Localized.string(
                        "Git loading",
                        comment: "Workspace status text shown while Git status is loading"
                    ),
                    accessibilityLabel: Localized.string(
                        "Git status",
                        comment: "Accessibility label for workspace Git status"
                    ),
                    tone: .progress
                )
            )
        case .noRepository:
            return (nil, nil)
        case .available(let location, let status):
            return (
                branchItem(for: location.head),
                gitItem(for: status)
            )
        case .unavailable(let location, let reason):
            return (
                location.map { branchItem(for: $0.head) },
                Item(
                    text: Localized.string(
                        "Git unavailable",
                        comment: "Workspace status text shown when Git status could not be refreshed"
                    ),
                    accessibilityLabel: Localized.string(
                        "Git status",
                        comment: "Accessibility label for workspace Git status"
                    ),
                    accessibilityValue: Localized.string(
                        "Git status is unavailable",
                        comment: "Accessibility value shown when Git status could not be refreshed"
                    ),
                    toolTip: reason,
                    tone: .error
                )
            )
        }
    }

    static func languageServerItem(
        profileName: String?,
        state: LanguageServerState
    ) -> Item {
        let stateName = localizedLanguageServerStateName(state)
        let name = profileName ?? Localized.string(
            "LSP",
            comment: "Short generic label for language server status"
        )
        let text = Localized.string(
            "\(name): \(stateName)",
            comment: "Workspace status text showing the active language profile and language server state"
        )
        return Item(
            text: text,
            accessibilityLabel: Localized.string(
                "Language server status",
                comment: "Accessibility label describing the language server state value"
            ),
            accessibilityValue: text,
            toolTip: languageServerReason(state),
            tone: languageServerTone(state)
        )
    }

    static func unavailableLanguageServerItem(_ message: String) -> Item {
        Item(
            text: message,
            accessibilityLabel: Localized.string(
                "Language server status",
                comment: "Accessibility label describing the language server state value"
            ),
            accessibilityValue: message,
            toolTip: message,
            tone: .secondary
        )
    }

    static func restartAvailability(
        profileName: String?,
        state: LanguageServerState,
        isTrusted: Bool
    ) -> (visible: Bool, enabled: Bool) {
        let visible: Bool
        switch state {
        case .missing, .stopped, .crashed, .disabled:
            visible = profileName != nil
        case .starting, .indexing, .ready, .busy, .stopping:
            visible = false
        }
        return (visible, visible && isTrusted)
    }

    static func encodingItem(_ encoding: SourceEncoding) -> Item {
        Item(
            text: encoding.displayName,
            accessibilityLabel: Localized.string(
                "File encoding",
                comment: "Accessibility label for the active file encoding"
            ),
            accessibilityValue: encoding.displayName
        )
    }

    static func lineEndingItem(_ lineEnding: SourceLineEnding) -> Item {
        let (token, description): (String, String)
        switch lineEnding {
        case .none:
            token = Localized.string(
                "None",
                comment: "Compact status token for a file with no line endings"
            )
            description = Localized.string(
                "No line endings",
                comment: "Accessibility description for a file with no line endings"
            )
        case .lineFeed:
            token = "LF"
            description = Localized.string(
                "Line Feed line endings",
                comment: "Accessibility description for LF line endings"
            )
        case .carriageReturnLineFeed:
            token = "CRLF"
            description = Localized.string(
                "Carriage Return and Line Feed line endings",
                comment: "Accessibility description for CRLF line endings"
            )
        case .carriageReturn:
            token = "CR"
            description = Localized.string(
                "Carriage Return line endings",
                comment: "Accessibility description for CR line endings"
            )
        case .mixed:
            token = Localized.string(
                "Mixed",
                comment: "Compact status token for mixed line endings"
            )
            description = Localized.string(
                "Mixed line endings",
                comment: "Accessibility description for mixed line endings"
            )
        }
        return Item(
            text: token,
            accessibilityLabel: Localized.string(
                "Line endings",
                comment: "Accessibility label for the active file line endings"
            ),
            accessibilityValue: description,
            toolTip: description
        )
    }

    static func languageItem(_ languageName: String) -> Item {
        Item(
            text: languageName,
            accessibilityLabel: Localized.string(
                "File language",
                comment: "Accessibility label for the active file language profile"
            ),
            accessibilityValue: languageName
        )
    }

    static func cursorItem(
        snapshot: SourceSnapshot,
        selectionState: CodeViewportSelectionState
    ) -> Item? {
        let selectedRange = selectionState.selectedUTF8Range
        let offset = selectedRange?.lowerBound
            ?? selectionState.focusedUTF8Offset
        guard let position = try? snapshot.position(
            forUTF8Offset: offset,
            encoding: .utf16
        ) else {
            return nil
        }
        let line = position.line + 1
        let column = position.character + 1
        let selectedCount: Int
        if let selectedRange,
           let start = try? snapshot.globalUTF16Offset(
                forUTF8Offset: selectedRange.lowerBound
           ),
           let end = try? snapshot.globalUTF16Offset(
                forUTF8Offset: selectedRange.upperBound
           ) {
            selectedCount = max(0, end - start)
        } else {
            selectedCount = 0
        }

        let text: String
        let value: String
        if selectedCount > 0 {
            text = Localized.string(
                "Ln \(line), Col \(column), \(selectedCount) selected",
                comment: "Compact active-file cursor position and UTF-16 selection count"
            )
            value = Localized.string(
                "Line \(line), Column \(column), \(selectedCount) UTF-16 code units selected",
                comment: "Accessibility value for active-file cursor position and selection count"
            )
        } else {
            text = Localized.string(
                "Ln \(line), Col \(column)",
                comment: "Compact active-file cursor line and column"
            )
            value = Localized.string(
                "Line \(line), Column \(column)",
                comment: "Accessibility value for active-file cursor line and column"
            )
        }
        return Item(
            text: text,
            accessibilityLabel: Localized.string(
                "Cursor position",
                comment: "Accessibility label for the active file cursor position"
            ),
            accessibilityValue: value,
            toolTip: value,
            tone: .normal
        )
    }

    private static func branchItem(for head: GitHeadState) -> Item {
        switch head {
        case .branch(let name):
            return Item(
                text: name,
                accessibilityLabel: Localized.string(
                    "Git branch",
                    comment: "Accessibility label for the current Git branch"
                ),
                accessibilityValue: name,
                toolTip: name,
                tone: .normal
            )
        case .detached(let commitID):
            let shortID = String(commitID.prefix(8))
            let text = shortID.isEmpty
                ? Localized.string(
                    "Detached HEAD",
                    comment: "Workspace status text for an unborn or detached Git HEAD without a commit identifier"
                )
                : Localized.string(
                    "Detached \(shortID)",
                    comment: "Workspace status text for a detached Git HEAD with an abbreviated commit identifier"
                )
            let value = commitID.isEmpty
                ? text
                : Localized.string(
                    "Detached HEAD at \(commitID)",
                    comment: "Accessibility value for a detached Git HEAD with the full commit identifier"
                )
            return Item(
                text: text,
                accessibilityLabel: Localized.string(
                    "Git branch",
                    comment: "Accessibility label for the current Git branch"
                ),
                accessibilityValue: value,
                toolTip: value,
                tone: .warning
            )
        }
    }

    private static func gitItem(for snapshot: GitStatusSnapshot) -> Item {
        let total = snapshot.entries.filter { !$0.isIgnored }.count
        let text: String
        if total == 1 {
            text = Localized.string(
                "1 change",
                comment: "Workspace status text for exactly one Git change"
            )
        } else {
            text = Localized.string(
                "\(total) changes",
                comment: "Workspace status text for the number of Git changes"
            )
        }
        let value = Localized.string(
            "\(text): \(snapshot.staged.count) staged, \(snapshot.unstaged.count) unstaged, \(snapshot.untracked.count) untracked, \(snapshot.conflicted.count) conflicted",
            comment: "Accessibility value breaking down workspace Git changes"
        )
        return Item(
            text: text,
            accessibilityLabel: Localized.string(
                "Git changes",
                comment: "Accessibility label for the workspace Git change count"
            ),
            accessibilityValue: value,
            toolTip: value,
            tone: snapshot.conflicted.isEmpty
                ? (total == 0 ? .secondary : .warning)
                : .error
        )
    }

    private static func localizedLanguageServerStateName(
        _ state: LanguageServerState
    ) -> String {
        switch state {
        case .missing:
            Localized.string("Missing", comment: "Language server state name")
        case .starting:
            Localized.string("Starting", comment: "Language server state name")
        case .indexing:
            Localized.string("Indexing", comment: "Language server state name")
        case .ready:
            Localized.string("Ready", comment: "Language server state name")
        case .busy:
            Localized.string("Busy", comment: "Language server state name")
        case .stopping:
            Localized.string("Stopping", comment: "Language server state name")
        case .stopped:
            Localized.string("Stopped", comment: "Language server state name")
        case .crashed:
            Localized.string("Crashed", comment: "Language server state name")
        case .disabled:
            Localized.string("Disabled", comment: "Language server state name")
        }
    }

    private static func languageServerReason(
        _ state: LanguageServerState
    ) -> String? {
        switch state {
        case .missing(let reason), .crashed(let reason), .disabled(let reason):
            reason
        case .starting, .indexing, .ready, .busy, .stopping, .stopped:
            nil
        }
    }

    private static func languageServerTone(
        _ state: LanguageServerState
    ) -> Tone {
        switch state {
        case .ready:
            .normal
        case .starting, .indexing, .busy, .stopping:
            .progress
        case .missing, .stopped:
            .warning
        case .crashed, .disabled:
            .error
        }
    }

    private func configureStack(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureButton(
        _ button: NSButton,
        identifier: String,
        symbolName: String,
        action: Selector,
        truncationMode: NSLineBreakMode
    ) {
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        )
        button.imagePosition = .imageLeading
        button.target = self
        button.action = action
        (button.cell as? NSButtonCell)?.lineBreakMode = truncationMode
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureLabel(
        _ label: NSTextField,
        identifier: String
    ) {
        label.identifier = NSUserInterfaceItemIdentifier(identifier)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    private func render(_ item: Item?, on label: NSTextField) {
        guard let item else {
            label.isHidden = true
            return
        }
        label.isHidden = false
        label.stringValue = item.text
        label.textColor = color(for: item.tone)
        label.toolTip = item.toolTip
        label.setAccessibilityLabel(item.accessibilityLabel)
        label.setAccessibilityValue(item.accessibilityValue)
    }

    private func render(_ item: Item?, on button: NSButton) {
        guard let item else {
            button.isHidden = true
            return
        }
        button.isHidden = false
        button.title = item.text
        button.contentTintColor = color(for: item.tone)
        button.toolTip = item.toolTip
        button.setAccessibilityLabel(item.accessibilityLabel)
        button.setAccessibilityValue(item.accessibilityValue)
    }

    private func color(for tone: Tone) -> NSColor {
        switch tone {
        case .normal:
            .labelColor
        case .secondary:
            .secondaryLabelColor
        case .progress:
            .systemBlue
        case .warning:
            .systemOrange
        case .error:
            .systemRed
        }
    }

    @objc
    private func showSourceControl(_ sender: Any?) {
        onShowSourceControl?()
    }

    @objc
    private func restartLanguageServer(_ sender: Any?) {
        onRestartLanguageServer?()
    }
}
