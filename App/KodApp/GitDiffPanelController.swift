import AppKit
import GitCore

/// Presents `GitDiffViewController` as a sheet, mirroring
/// `GoToLinePanelController`'s lightweight panel pattern.
@MainActor
final class GitDiffPanelController: NSWindowController {
    let diffViewController = GitDiffViewController()

    init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false

        super.init(window: panel)
        panel.contentViewController = diffViewController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(diff: GitFileDiff, asSheetFor parent: NSWindow) {
        diffViewController.update(diff: diff)
        guard let window else {
            return
        }
        parent.beginSheet(window)
    }

    func close(parent: NSWindow) {
        guard let window else {
            return
        }
        parent.endSheet(window)
        window.close()
    }
}
