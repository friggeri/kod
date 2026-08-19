import KodCore
import SwiftUI

struct WelcomeView: View {
    let buildInfo: KodBuildInfo
    let recentWorkspace: URL?
    let onOpenFolder: @MainActor () -> Void
    let onOpenFile: @MainActor () -> Void
    let onOpenRecent: @MainActor (URL) -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Kod")
                    .font(.system(size: 34, weight: .bold))
                    .accessibilityIdentifier("welcome.title")

                Text("A fast, native, read-only code viewer for macOS")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button(action: onOpenFolder) {
                    Label("Open Folder...", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("welcome.openFolder")

                Button(action: onOpenFile) {
                    Label("Open File...", systemImage: "doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("welcome.openFile")

                Button {
                    if let recentWorkspace {
                        onOpenRecent(recentWorkspace)
                    }
                } label: {
                    Label("Open Recent", systemImage: "clock")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(recentWorkspace == nil)
                .accessibilityIdentifier("welcome.openRecent")
            }
            .frame(width: 240)

            VStack(spacing: 4) {
                Text("Open a repository or source file to view it without editing.")
                    .foregroundStyle(.secondary)
                Text(buildInfo.displayDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("welcome.buildInfo")
            }
            .multilineTextAlignment(.center)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
