import AppKit
import LanguageAdapters
import SwiftUI

struct LanguageSupportStatusPresentation: Equatable {
    let title: String
    let systemImage: String
}

extension LanguageSupportServerState {
    var presentation: LanguageSupportStatusPresentation {
        switch self {
        case .syntaxOnly:
            LanguageSupportStatusPresentation(
                title: String(localized: "Syntax Only"),
                systemImage: "text.page"
            )
        case .checking:
            LanguageSupportStatusPresentation(
                title: String(localized: "Checking"),
                systemImage: "clock"
            )
        case .available:
            LanguageSupportStatusPresentation(
                title: String(localized: "Ready"),
                systemImage: "checkmark.circle.fill"
            )
        case .missing:
            LanguageSupportStatusPresentation(
                title: String(localized: "Not Installed"),
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    var statusColor: Color {
        switch self {
        case .available:
            .green
        case .missing:
            .orange
        case .syntaxOnly:
            .secondary
        case .checking:
            .accentColor
        }
    }

    var installedMetadata: String? {
        guard case .available(let executable) = self else {
            return nil
        }
        let executableName = executable.url.lastPathComponent
        guard let version = executable.version?
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            return executableName
        }
        if version.localizedCaseInsensitiveContains(executableName) {
            return String(version.prefix(120))
        }
        return "\(executableName) · \(version.prefix(120))"
    }

    var installedMetadataHelp: String? {
        guard case .available(let executable) = self else {
            return nil
        }
        return "\(executable.source.displayName): \(executable.url.path)"
    }
}

struct LanguageSupportDetailView: View {
    let item: LanguageSupportItem
    @ObservedObject var service: LanguageSupportService

    @State private var commandText: String
    @State private var committedCommandText: String
    @State private var hasDeferredCommandUpdate = false
    @State private var shouldRestoreCommandFocus = false
    @FocusState private var isCommandFocused: Bool

    init(
        item: LanguageSupportItem,
        service: LanguageSupportService
    ) {
        self.item = item
        self.service = service
        let command = Self.commandText(for: item)
        _commandText = State(initialValue: command)
        _committedCommandText = State(initialValue: command)
    }

    var body: some View {
        Form {
            statusRow
            if item.profile.languageServer != nil {
                commandRow
            }
            if let installationGuide {
                installationRow(installationGuide)
            }
        }
        .formStyle(.columns)
        .controlSize(.regular)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .onChange(of: item.id) { _, _ in
            synchronizeCommand()
        }
        .onChange(of: effectiveCommandText) { _, _ in
            if isCommandFocused {
                hasDeferredCommandUpdate = true
                return
            }
            synchronizeCommand()
        }
        .onChange(of: isCommandFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused {
                commitCommandAfterFocusLoss()
            }
        }
        .task(id: item.id) {
            await Task.yield()
            await service.refresh(profileIdentifier: item.id)
        }
        .onChange(of: service.errorMessage) { _, message in
            guard message == nil, shouldRestoreCommandFocus else {
                return
            }
            shouldRestoreCommandFocus = false
            DispatchQueue.main.async {
                isCommandFocused = true
            }
        }
        .alert(
            "Could Not Update Language Settings",
            isPresented: Binding(
                get: { service.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        service.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                service.errorMessage = nil
            }
        } message: {
            Text(service.errorMessage ?? "")
        }
    }

    private var statusRow: some View {
        LabeledContent("Status") {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.serverState.presentation.title)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier(
                            "settings.languageSupport.serverStatus"
                        )

                    if service.isRefreshing(
                        profileIdentifier: item.id
                    ) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                Text(
                                    "Checking language servers",
                                    comment: "Accessibility label while Settings checks language-server availability"
                                )
                            )
                    }
                }
                if let metadata = item.serverState.installedMetadata {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .help(
                            item.serverState.installedMetadataHelp ?? metadata
                        )
                }
            }
        }
    }

    private var commandRow: some View {
        LabeledContent("Command") {
            TextField(
                "",
                text: $commandText,
                prompt: Text("Automatic"),
                axis: .vertical
            )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3...6)
                .focused($isCommandFocused)
                .frame(maxWidth: 520)
                .accessibilityLabel(
                    Text(
                        "Command",
                        comment: "Accessibility label for a language server's executable and arguments field"
                    )
                )
                .accessibilityIdentifier(
                    "settings.languageSupport.command"
                )
        }
    }

    @ViewBuilder
    private func installationRow(
        _ guide: LanguageServerInstallationGuide
    ) -> some View {
        LabeledContent("Installation") {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Choose an installation method, then check again when it finishes."
                )
                .foregroundStyle(.secondary)

                ForEach(guide.commandOptions, id: \.id) { option in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(option.label)
                            .font(.subheadline.weight(.semibold))

                        ForEach(
                            Array(option.commandLines.enumerated()),
                            id: \.offset
                        ) { _, command in
                            HStack(spacing: 8) {
                                Text(command)
                                    .font(
                                        .system(
                                            .body,
                                            design: .monospaced
                                        )
                                    )
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )

                                Button {
                                    copyToPasteboard(command)
                                } label: {
                                    Label(
                                        "Copy",
                                        systemImage: "doc.on.doc"
                                    )
                                }
                                .labelStyle(.iconOnly)
                                .help(
                                    "Copy \(option.label) installation command"
                                )
                                .accessibilityIdentifier(
                                    "settings.languageSupport.install.\(option.id).copy"
                                )
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Link(
                        "Open Installation Guide…",
                        destination: guide.documentationURL
                    )
                    .accessibilityIdentifier(
                        "settings.languageSupport.install.documentation"
                    )

                    Button("Check Again") {
                        Task {
                            await service.refresh(
                                profileIdentifier: item.id
                            )
                        }
                    }
                    .disabled(
                        service.isRefreshing(
                            profileIdentifier: item.id
                        )
                    )
                    .accessibilityIdentifier(
                        "settings.languageSupport.checkAgain"
                    )
                }
            }
        }
    }

    private var effectiveCommandText: String {
        Self.commandText(for: item)
    }

    private var installationGuide: LanguageServerInstallationGuide? {
        guard case .missing = item.serverState else {
            return nil
        }
        return DefaultLanguageServerInstallationGuides.guide(
            for: item.profile
        )
    }

    private func persistCommand() {
        guard commandText != committedCommandText else {
            return
        }
        let hadDeferredCommandUpdate = hasDeferredCommandUpdate
        do {
            try service.setCommand(
                commandText,
                profileIdentifier: item.id
            )
            committedCommandText = commandText
            hasDeferredCommandUpdate = false
            Task {
                await service.refresh(profileIdentifier: item.id)
            }
        } catch {
            service.report(error)
            if hadDeferredCommandUpdate {
                synchronizeCommand()
            } else {
                commandText = committedCommandText
            }
            shouldRestoreCommandFocus = true
        }
    }

    private func synchronizeCommand() {
        commandText = effectiveCommandText
        committedCommandText = effectiveCommandText
        hasDeferredCommandUpdate = false
    }

    private func commitCommandAfterFocusLoss() {
        guard commandText == committedCommandText else {
            persistCommand()
            return
        }
        if hasDeferredCommandUpdate {
            synchronizeCommand()
        }
    }

    private func copyToPasteboard(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private static func commandText(for item: LanguageSupportItem) -> String {
        if let selected = item.profile.languageServer?.selectedExecutable {
            return LanguageServerCommandLine.format(selected)
        }
        if case .available(let executable) = item.serverState {
            return LanguageServerCommandLine.format(executable)
        }
        return ""
    }
}
