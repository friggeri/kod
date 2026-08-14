import AppKit
import GitCore

/// Presents `GitBlameViewController` as a sheet. Selecting a line shows a
/// commit-metadata popover anchored to that row (SPEC 9.1: "Commit
/// metadata popover for a blamed line"), built from
/// `GitBlameViewController.popoverText(for:)`.
@MainActor
public final class GitBlamePanelController: NSWindowController {
    private let blameViewController: GitBlameViewController
    private var popover: NSPopover?

    public init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false

        let controller = GitBlameViewController()
        blameViewController = controller

        super.init(window: panel)

        controller.onSelectLine = { [weak self] line in
            self?.presentPopover(for: line)
        }
        panel.contentViewController = controller
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func show(result: GitBlameResult, asSheetFor parent: NSWindow) {
        blameViewController.update(result: result)
        guard let window else {
            return
        }
        parent.beginSheet(window)
    }

    public func close(parent: NSWindow) {
        guard let window else {
            return
        }
        parent.endSheet(window)
        window.close()
    }

    private func presentPopover(for line: GitBlameLine) {
        let content = NSViewController()
        let label = NSTextField(wrappingLabelWithString: GitBlameViewController.popoverText(for: line))
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityLabel(gitUIStrings.string("Commit details", comment: "Accessibility label for the Git blame commit-details popover text"))
        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        content.view = container

        let newPopover = NSPopover()
        newPopover.contentViewController = content
        newPopover.behavior = .transient
        // SPEC 14 (Reduce Motion): this popover's default open/close
        // animation is the one place in `GitUI` where AppKit
        // performs an implicit animation Kod doesn't otherwise control
        // (there are no `NSAnimationContext`/`.animator()`/SwiftUI
        // `.animation(...)` transitions anywhere else in the app) — gate
        // it on the real, live system setting via the pure/testable
        // `Self.shouldAnimatePopover(reduceMotionEnabled:)` rather than
        // leaving `animates` at its default `true`.
        newPopover.animates = Self.shouldAnimatePopover(
            reduceMotionEnabled: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        popover = newPopover
        guard let contentView = blameViewController.view.window?.contentView else {
            return
        }
        newPopover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .maxY)
    }

    /// Pure so `GitBlamePanelControllerTests` can assert Reduce Motion is
    /// actually honored without needing to read the live system setting
    /// or show a real popover.
    static func shouldAnimatePopover(reduceMotionEnabled: Bool) -> Bool {
        !reduceMotionEnabled
    }
}
