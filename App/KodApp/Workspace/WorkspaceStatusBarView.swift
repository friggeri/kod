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

    struct LanguageServerStatus: Equatable {
        let item: Item
        let symbolName: String
        let settingsProfileIdentifier: String?
    }

    struct Model: Equatable {
        let branch: Item?
        let git: Item?
        let languageServer: LanguageServerStatus?
        let language: Item?
        let encoding: Item?
        let lineEnding: Item?
        let cursor: Item?
    }

    struct LayoutPlan: Equatable {
        let showsLineEnding: Bool
        let showsEncoding: Bool
        let truncatesBranch: Bool
        let estimatedRequiredWidth: CGFloat
    }

    var onShowSourceControl: (() -> Void)?
    var onShowLanguageSupportSettings: ((String) -> Void)?

    private let branchButton = NSButton()
    private let gitButton = NSButton()
    private let languageServerButton = KodSymbolButton(
        systemSymbolName: "circle.dashed",
        accessibilityLabel: Localized.string(
            "Language server status",
            comment: "Accessibility label describing the language server state"
        ),
        pointSize: 12
    )
    private let languageLabel = NSTextField(labelWithString: "")
    private let encodingLabel = NSTextField(labelWithString: "")
    private let lineEndingLabel = NSTextField(labelWithString: "")
    private let cursorLabel = NSTextField(labelWithString: "")
    private let trustControl: NSButton
    private let gitGroup = NSStackView()
    private let fileGroup = NSStackView()
    private let cursorGroup = NSStackView()
    private let trustGroup = NSStackView()
    private let separatorAfterGit = NSBox()
    private let separatorAfterFile = NSBox()
    private let separatorAfterCursor = NSBox()
    private let contentStack = NSStackView()
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

        languageServerButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.languageServerStatus"
        )
        languageServerButton.title = ""
        languageServerButton.target = self
        languageServerButton.action = #selector(performLanguageServerAction(_:))
        languageServerButton.translatesAutoresizingMaskIntoConstraints = false
        languageServerButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        languageServerButton.heightAnchor.constraint(equalToConstant: 20).isActive = true

        trustControl.translatesAutoresizingMaskIntoConstraints = false
        trustControl.widthAnchor.constraint(equalToConstant: 24).isActive = true
        trustControl.heightAnchor.constraint(equalToConstant: 24).isActive = true

        configureGroup(
            gitGroup,
            identifier: "workspace.status.gitGroup",
            views: [branchButton, gitButton]
        )
        configureGroup(
            fileGroup,
            identifier: "workspace.status.fileGroup",
            views: [
                languageLabel,
                languageServerButton,
                encodingLabel,
                lineEndingLabel
            ]
        )
        configureGroup(
            cursorGroup,
            identifier: "workspace.status.cursorGroup",
            views: [cursorLabel]
        )
        configureGroup(
            trustGroup,
            identifier: "workspace.status.trustGroup",
            views: [trustControl]
        )
        configureGroupSeparator(
            separatorAfterGit,
            identifier: "workspace.status.separatorAfterGit"
        )
        configureGroupSeparator(
            separatorAfterFile,
            identifier: "workspace.status.separatorAfterFile"
        )
        configureGroupSeparator(
            separatorAfterCursor,
            identifier: "workspace.status.separatorAfterCursor"
        )

        contentStack.identifier = NSUserInterfaceItemIdentifier(
            "workspace.status.content"
        )
        [
            gitGroup,
            separatorAfterGit,
            fileGroup,
            separatorAfterFile,
            cursorGroup,
            separatorAfterCursor,
            trustGroup
        ].forEach(contentStack.addArrangedSubview)
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.setAccessibilityElement(false)
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topSeparator)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            topSeparator.topAnchor.constraint(equalTo: topAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 6
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -6
            ),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        branchButton.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        gitButton.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        languageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        cursorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        branchButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cursorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        branchButton.nextKeyView = gitButton
        gitButton.nextKeyView = languageServerButton
        languageServerButton.nextKeyView = trustControl
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(_ model: Model) {
        self.model = model
        render(model.branch, on: branchButton)
        render(model.git, on: gitButton)
        render(model.languageServer, on: languageServerButton)
        render(model.language, on: languageLabel)
        render(model.encoding, on: encodingLabel)
        render(model.lineEnding, on: lineEndingLabel)
        render(model.cursor, on: cursorLabel)
        updateGroupVisibility()
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
                updateGroupVisibility()
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
            func groupWidth(_ widths: [CGFloat]) -> CGFloat? {
                let visible = widths.filter { $0 > 0 }
                guard !visible.isEmpty else {
                    return nil
                }
                return visible.reduce(0, +)
                    + CGFloat(max(0, visible.count - 1)) * 8
            }

            var groups: [CGFloat] = []
            let gitWidth = groupWidth([
                model.branch == nil
                    ? 0
                    : (
                    minimumBranchWidth
                        ? 72
                        : textWidth(model.branch, maximum: 260)
                    ),
                textWidth(model.git, maximum: 120)
            ])
            if let gitWidth {
                groups.append(gitWidth)
            }

            let fileWidth = groupWidth([
                textWidth(model.language, maximum: 140),
                model.languageServer == nil ? 0 : 20,
                showsEncoding ? textWidth(model.encoding, maximum: 90) : 0,
                showsLineEnding
                    ? textWidth(model.lineEnding, maximum: 70)
                    : 0
            ])
            if let fileWidth {
                groups.append(fileWidth)
            }
            if model.cursor != nil {
                groups.append(textWidth(model.cursor, maximum: 140))
            }
            groups.append(24)
            let separatorAndSpacing = CGFloat(max(0, groups.count - 1)) * 21
            return 12 + groups.reduce(0, +) + separatorAndSpacing
        }

        if estimatedWidth(minimumBranchWidth: false) > availableWidth {
            showsLineEnding = false
        }
        if estimatedWidth(minimumBranchWidth: false) > availableWidth {
            showsEncoding = false
        }

        let idealWidth = estimatedWidth(minimumBranchWidth: false)
        return LayoutPlan(
            showsLineEnding: showsLineEnding,
            showsEncoding: showsEncoding,
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

    static func languageServerStatus(
        profileIdentifier: String?,
        profileName: String?,
        state: LanguageServerState
    ) -> LanguageServerStatus {
        let stateName = localizedLanguageServerStateName(state)
        let name = profileName ?? Localized.string(
            "LSP",
            comment: "Short generic label for language server status"
        )
        let value = Localized.string(
            "\(name) language server: \(stateName)",
            comment: "Accessibility value describing a language server and its state"
        )
        let settingsProfileIdentifier: String?
        switch state {
        case .missing, .stopped, .crashed, .disabled:
            settingsProfileIdentifier = profileIdentifier
        case .starting, .indexing, .ready, .busy, .stopping:
            settingsProfileIdentifier = nil
        }
        var toolTip = languageServerReason(state).map {
            "\(value): \($0)"
        } ?? value
        if settingsProfileIdentifier != nil {
            let action = Localized.string(
                "Click to open \(name) language support settings.",
                comment: "Language server status tooltip action opening the matching language settings"
            )
            toolTip += "\n\(action)"
        }
        return LanguageServerStatus(
            item: Item(
                text: stateName,
                accessibilityLabel: Localized.string(
                    "Language server status",
                    comment: "Accessibility label describing the language server state value"
                ),
                accessibilityValue: value,
                toolTip: toolTip,
                tone: languageServerTone(state)
            ),
            symbolName: languageServerSymbolName(state),
            settingsProfileIdentifier: settingsProfileIdentifier
        )
    }

    static func unavailableLanguageServerStatus(
        _ message: String,
        settingsProfileIdentifier: String? = nil
    ) -> LanguageServerStatus {
        let toolTip: String
        if settingsProfileIdentifier == nil {
            toolTip = message
        } else {
            let action = Localized.string(
                "Click to open language support settings.",
                comment: "Language server status tooltip action opening language settings"
            )
            toolTip = "\(message)\n\(action)"
        }
        return LanguageServerStatus(
            item: Item(
                text: message,
                accessibilityLabel: Localized.string(
                    "Language server status",
                    comment: "Accessibility label describing the language server state value"
                ),
                accessibilityValue: message,
                toolTip: toolTip,
                tone: .secondary
            ),
            symbolName: "exclamationmark.triangle",
            settingsProfileIdentifier: settingsProfileIdentifier
        )
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
            accessibilityValue: languageName,
            tone: .normal
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

    private static func languageServerSymbolName(
        _ state: LanguageServerState
    ) -> String {
        switch state {
        case .missing:
            "exclamationmark.triangle"
        case .starting, .stopping:
            "arrow.triangle.2.circlepath"
        case .indexing:
            "magnifyingglass.circle"
        case .ready:
            "checkmark.circle"
        case .busy:
            "ellipsis.circle"
        case .stopped:
            "stop.circle"
        case .crashed:
            "exclamationmark.triangle"
        case .disabled:
            "slash.circle"
        }
    }

    private func configureGroup(
        _ stack: NSStackView,
        identifier: String,
        views: [NSView]
    ) {
        stack.identifier = NSUserInterfaceItemIdentifier(identifier)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        views.forEach(stack.addArrangedSubview)
    }

    private func configureGroupSeparator(
        _ separator: NSBox,
        identifier: String
    ) {
        separator.identifier = NSUserInterfaceItemIdentifier(identifier)
        separator.boxType = .separator
        separator.setAccessibilityElement(false)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 14).isActive = true
    }

    private func updateGroupVisibility() {
        gitGroup.isHidden = branchButton.isHidden && gitButton.isHidden
        fileGroup.isHidden = languageLabel.isHidden
            && languageServerButton.isHidden
            && encodingLabel.isHidden
            && lineEndingLabel.isHidden
        cursorGroup.isHidden = cursorLabel.isHidden

        let gitVisible = !gitGroup.isHidden
        let fileVisible = !fileGroup.isHidden
        let cursorVisible = !cursorGroup.isHidden
        let trustVisible = !trustGroup.isHidden
        separatorAfterGit.isHidden = !gitVisible
            || !(fileVisible || cursorVisible || trustVisible)
        separatorAfterFile.isHidden = !fileVisible
            || !(cursorVisible || trustVisible)
        separatorAfterCursor.isHidden = !cursorVisible || !trustVisible
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

    private func render(
        _ status: LanguageServerStatus?,
        on button: KodSymbolButton
    ) {
        guard let status else {
            button.isHidden = true
            button.isEnabled = false
            return
        }
        button.isHidden = false
        button.setSymbol(
            status.symbolName,
            accessibilityDescription: status.item.accessibilityValue,
            pointSize: 12
        )
        button.isEnabled = status.settingsProfileIdentifier != nil
        button.contentTintColor = color(for: status.item.tone)
        button.toolTip = status.item.toolTip
        button.setAccessibilityLabel(status.item.accessibilityLabel)
        button.setAccessibilityValue(status.item.accessibilityValue)
        button.setAccessibilityHelp(
            status.settingsProfileIdentifier == nil ? nil : status.item.toolTip
        )
    }

    private func color(for tone: Tone) -> NSColor {
        switch tone {
        case .normal, .progress, .warning, .error:
            .labelColor
        case .secondary:
            .secondaryLabelColor
        }
    }

    @objc
    private func showSourceControl(_ sender: Any?) {
        onShowSourceControl?()
    }

    @objc
    private func performLanguageServerAction(_ sender: Any?) {
        guard let profileIdentifier =
                model?.languageServer?.settingsProfileIdentifier else {
            return
        }
        onShowLanguageSupportSettings?(profileIdentifier)
    }
}
