import AppKit

struct WorkspaceHealthPresentation: Equatable {
    let issue: WorkspaceHealthIssue
    let position: Int
    let issueCount: Int
    let stateText: String
    let positionText: String
}

@MainActor
final class WorkspaceHealthPresenter {
    private struct DismissedGeneration: Hashable {
        let id: WorkspaceHealthIssue.ID
        let generation: UInt64
    }

    let view = WorkspaceHealthBannerView()
    private let routeRecovery: (WorkspaceHealthRecoveryIntent) -> Void
    private var health = WorkspaceHealth()
    private var dismissedGenerations: Set<DismissedGeneration> = []
    private var selectedIssueID: WorkspaceHealthIssue.ID?
    private(set) var presentation: WorkspaceHealthPresentation?

    init(routeRecovery: @escaping (WorkspaceHealthRecoveryIntent) -> Void) {
        self.routeRecovery = routeRecovery
        view.onPrevious = { [weak self] in self?.selectPrevious() }
        view.onNext = { [weak self] in self?.selectNext() }
        view.onRetry = { [weak self] in self?.activate(.retry) }
        view.onRefresh = { [weak self] in self?.activate(.refresh) }
        view.onDismiss = { [weak self] in self?.dismissCurrentIssue() }
        render()
    }

    convenience init(session: WorkspaceSession) {
        self.init { [weak session] intent in
            session?.beginRecovery(intent)
        }
    }

    func update(_ health: WorkspaceHealth) {
        self.health = health
        render()
    }

    func selectPrevious() {
        moveSelection(by: -1)
    }

    func selectNext() {
        moveSelection(by: 1)
    }

    func activate(_ actionID: WorkspaceHealthRecoveryActionID) {
        guard let issue = presentation?.issue,
              issue.state == .failed,
              issue.recoveryActionIDs.contains(actionID) else {
            return
        }
        routeRecovery(
            WorkspaceHealthRecoveryIntent(
                issueID: issue.id,
                actionID: actionID
            )
        )
    }

    func dismissCurrentIssue() {
        guard let issue = presentation?.issue else {
            return
        }
        dismissedGenerations.insert(
            DismissedGeneration(id: issue.id, generation: issue.generation)
        )
        selectedIssueID = nil
        render()
    }

    private var visibleIssues: [WorkspaceHealthIssue] {
        health.issues
            .filter {
                !dismissedGenerations.contains(
                    DismissedGeneration(id: $0.id, generation: $0.generation)
                )
            }
            .sorted(by: Self.precedes)
    }

    private static func precedes(
        _ lhs: WorkspaceHealthIssue,
        _ rhs: WorkspaceHealthIssue
    ) -> Bool {
        let lhsKey = priorityKey(lhs)
        let rhsKey = priorityKey(rhs)
        if lhsKey != rhsKey {
            return lhsKey.lexicographicallyPrecedes(rhsKey)
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func priorityKey(_ issue: WorkspaceHealthIssue) -> [Int] {
        let severity = issue.severity == .unavailable ? 0 : 1
        let state = issue.state == .failed ? 0 : 1
        let subsystem = WorkspaceSubsystem.allCases.firstIndex(
            of: issue.subsystem
        ) ?? Int.max
        return [severity, state, subsystem]
    }

    private func moveSelection(by offset: Int) {
        let issues = visibleIssues
        guard issues.count > 1 else {
            return
        }
        let current = issues.firstIndex { $0.id == presentation?.issue.id } ?? 0
        let next = (current + offset + issues.count) % issues.count
        selectedIssueID = issues[next].id
        render()
    }

    private func render() {
        let issues = visibleIssues
        guard !issues.isEmpty else {
            selectedIssueID = nil
            presentation = nil
            view.render(nil)
            return
        }
        let index = issues.firstIndex { $0.id == selectedIssueID } ?? 0
        let issue = issues[index]
        selectedIssueID = issue.id
        let value = WorkspaceHealthPresentation(
            issue: issue,
            position: index,
            issueCount: issues.count,
            stateText: Self.stateText(for: issue),
            positionText: Localized.string(
                "\(index + 1) of \(issues.count) workspace issues",
                comment: "Position of the currently displayed workspace health issue"
            )
        )
        presentation = value
        view.render(value)
    }

    private static func stateText(for issue: WorkspaceHealthIssue) -> String {
        if issue.state == .recovering {
            return Localized.string(
                "Recovering — \(issue.summary)",
                comment: "Workspace health banner summary while recovery is in progress"
            )
        }
        switch issue.severity {
        case .degraded:
            return Localized.string(
                "Degraded — \(issue.summary)",
                comment: "Workspace health banner summary for reduced functionality"
            )
        case .unavailable:
            return Localized.string(
                "Unavailable — \(issue.summary)",
                comment: "Workspace health banner summary for unavailable functionality"
            )
        }
    }
}

@MainActor
final class WorkspaceHealthBannerView: NSStackView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onRetry: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let summaryLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let retryButton = NSButton(
        title: Localized.string(
            "Retry",
            comment: "Button retrying a failed workspace subsystem"
        ),
        target: nil,
        action: nil
    )
    private let refreshButton = NSButton(
        title: Localized.string(
            "Refresh Files",
            comment: "Button manually refreshing workspace files when live updates are unavailable"
        ),
        target: nil,
        action: nil
    )
    private let dismissButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func render(_ presentation: WorkspaceHealthPresentation?) {
        guard let presentation else {
            isHidden = true
            return
        }
        isHidden = false
        summaryLabel.stringValue = presentation.stateText
        summaryLabel.toolTip = presentation.issue.reason
        summaryLabel.setAccessibilityLabel(presentation.stateText)
        summaryLabel.setAccessibilityHelp(presentation.issue.reason)
        positionLabel.stringValue = presentation.positionText
        positionLabel.setAccessibilityLabel(presentation.positionText)
        previousButton.isHidden = presentation.issueCount < 2
        nextButton.isHidden = presentation.issueCount < 2
        retryButton.isHidden = !presentation.issue.recoveryActionIDs.contains(.retry)
        refreshButton.isHidden = !presentation.issue.recoveryActionIDs.contains(.refresh)
        let canRecover = presentation.issue.state != .recovering
        retryButton.isEnabled = canRecover
        refreshButton.isEnabled = canRecover
        setAccessibilityLabel(
            Localized.string(
                "Workspace issue: \(presentation.stateText). \(presentation.positionText)",
                comment: "Accessibility label for the persistent workspace health banner"
            )
        )
    }

    private func configure() {
        identifier = NSUserInterfaceItemIdentifier("workspace.healthBanner")
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 6)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.systemOrange
            .withAlphaComponent(0.12).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        summaryLabel.identifier = NSUserInterfaceItemIdentifier(
            "workspace.healthSummary"
        )
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summaryLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        positionLabel.identifier = NSUserInterfaceItemIdentifier(
            "workspace.healthPosition"
        )
        positionLabel.textColor = .secondaryLabelColor
        positionLabel.font = .systemFont(ofSize: 11)

        configureNavigationButton(
            previousButton,
            symbol: "chevron.left",
            identifier: "workspace.healthPrevious",
            label: Localized.string(
                "Previous Workspace Issue",
                comment: "Accessibility label for navigating to the previous workspace issue"
            ),
            action: #selector(previousPressed)
        )
        configureNavigationButton(
            nextButton,
            symbol: "chevron.right",
            identifier: "workspace.healthNext",
            label: Localized.string(
                "Next Workspace Issue",
                comment: "Accessibility label for navigating to the next workspace issue"
            ),
            action: #selector(nextPressed)
        )

        retryButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.healthRetry"
        )
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        refreshButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.healthRefresh"
        )
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)

        dismissButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.healthDismiss"
        )
        dismissButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: Localized.string(
                "Dismiss Workspace Issue",
                comment: "Accessibility description for dismissing the current workspace issue"
            )
        )
        dismissButton.bezelStyle = .inline
        dismissButton.isBordered = false
        dismissButton.target = self
        dismissButton.action = #selector(dismissPressed)
        dismissButton.setAccessibilityLabel(
            Localized.string(
                "Dismiss Workspace Issue",
                comment: "Accessibility label for dismissing the current workspace issue"
            )
        )

        [previousButton, nextButton, retryButton, refreshButton, dismissButton]
            .forEach {
                $0.setContentHuggingPriority(.required, for: .horizontal)
            }
        addArrangedSubview(summaryLabel)
        addArrangedSubview(positionLabel)
        addArrangedSubview(previousButton)
        addArrangedSubview(nextButton)
        addArrangedSubview(retryButton)
        addArrangedSubview(refreshButton)
        addArrangedSubview(dismissButton)
        isHidden = true
    }

    private func configureNavigationButton(
        _ button: NSButton,
        symbol: String,
        identifier: String,
        label: String,
        action: Selector
    ) {
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
    }

    @objc private func previousPressed() { onPrevious?() }
    @objc private func nextPressed() { onNext?() }
    @objc private func retryPressed() { onRetry?() }
    @objc private func refreshPressed() { onRefresh?() }
    @objc private func dismissPressed() { onDismiss?() }
}
