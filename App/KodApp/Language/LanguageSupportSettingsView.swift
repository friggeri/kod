import AppKit
import LanguageAdapters
import SwiftUI
import SyntaxCore

struct LanguageSupportSettingsView: View {
    @ObservedObject var service: LanguageSupportService
    let onChooseExecutable: @MainActor (String) -> Void
    let onFindLanguageServer: @MainActor () -> Void

    @State private var grammarDetailsProfile: LanguageProfile?
    @State private var pendingDeleteIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(service.items) { item in
                            languageCard(item)
                                .id(item.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: service.focusedProfileIdentifier) {
                    _,
                    identifier in
                    guard let identifier else {
                        return
                    }
                    withAnimation {
                        proxy.scrollTo(identifier, anchor: .center)
                    }
                }
            }
        }
        .task {
            await service.refresh()
        }
        .sheet(item: $service.requestedProfileDraft) { draft in
            LanguageProfileEditorView(
                initialDraft: draft,
                service: service
            )
        }
        .sheet(item: $grammarDetailsProfile) { profile in
            LanguageGrammarDetailsView(profile: profile)
        }
        .alert(
            "Could Not Update Language Profile",
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
        .confirmationDialog(
            "Delete this custom language profile?",
            isPresented: Binding(
                get: { pendingDeleteIdentifier != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteIdentifier = nil
                    }
                }
            )
        ) {
            Button("Delete Profile", role: .destructive) {
                guard let identifier = pendingDeleteIdentifier else {
                    return
                }
                do {
                    try service.deleteCustom(identifier: identifier)
                } catch {
                    service.report(error)
                }
                pendingDeleteIdentifier = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteIdentifier = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Language Profiles")
                    .font(.headline)
                Text(
                    "Kod bundles syntax grammars; language servers stay installed and controlled by you."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Find a Language Server...") {
                onFindLanguageServer()
            }
            .help("Opens the public LSP server directory.")
            Button("Add Profile") {
                service.beginAddingProfile()
            }
            .accessibilityIdentifier("settings.languageSupport.addProfile")
            Button("Refresh") {
                Task {
                    await service.refresh()
                }
            }
            .disabled(service.isRefreshing)
            .accessibilityIdentifier("settings.languageSupport.refresh")
        }
    }

    private func languageCard(
        _ item: LanguageSupportItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(
                    isOn: Binding(
                        get: { item.profile.isEnabled },
                        set: { isEnabled in
                            do {
                                try service.setEnabled(
                                    isEnabled,
                                    identifier: item.id
                                )
                            } catch {
                                service.report(error)
                            }
                        }
                    )
                ) {
                    Text(item.profile.displayName)
                        .font(.headline)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Text(item.profile.origin == .default
                    ? String(localized: "Default Profile")
                    : String(localized: "Custom Profile"))
                .font(.caption)
                .foregroundStyle(.secondary)
                statusLabel(item.serverState)
            }

            Label(item.syntaxDescription, systemImage: "text.page")
                .font(.subheadline)
                .textSelection(.enabled)

            serverDetails(item)

            if !item.conflicts.isEmpty {
                Label(
                    "Overlapping file associations; the most recently edited enabled profile takes precedence.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack {
                Button("Edit") {
                    service.beginEditingProfile(identifier: item.id)
                }
                if item.profile.languageServer != nil {
                    Button("Choose Executable...") {
                        onChooseExecutable(item.id)
                    }
                }
                Button("Grammar Details...") {
                    grammarDetailsProfile = item.profile
                }
                Spacer()
                moreActionsMenu(item)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(
            item.id == service.focusedProfileIdentifier
                ? Color.accentColor.opacity(0.12)
                : Color.secondary.opacity(0.08)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.languageSupport.\(item.id)")
    }

    /// Secondary, less-frequently-used actions moved out of the primary
    /// action row to reduce crowding. Hidden entirely when none apply.
    @ViewBuilder
    private func moreActionsMenu(_ item: LanguageSupportItem) -> some View {
        let showsUseAutoDetected = item.profile.languageServer?.selectedExecutable != nil
        let showsResetDefault = item.profile.origin == .default
            && service.profileStore.isCustomized(identifier: item.id) == true
        let showsDelete = item.profile.origin == .custom
        if showsUseAutoDetected || showsResetDefault || showsDelete {
            Menu("More") {
                if showsUseAutoDetected {
                    Button("Use Auto-Detected") {
                        do {
                            try service.useAutoDetectedExecutable(
                                profileIdentifier: item.id
                            )
                        } catch {
                            service.report(error)
                        }
                    }
                }
                if showsResetDefault {
                    Button("Reset Default") {
                        do {
                            try service.resetDefault(identifier: item.id)
                        } catch {
                            service.report(error)
                        }
                    }
                }
                if showsDelete {
                    Button("Delete", role: .destructive) {
                        pendingDeleteIdentifier = item.id
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("settings.languageSupport.\(item.id).more")
        }
    }

    @ViewBuilder
    private func serverDetails(
        _ item: LanguageSupportItem
    ) -> some View {
        switch item.serverState {
        case .notConfigured:
            Text("Language server disabled; syntax remains available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .available(let executable):
            VStack(alignment: .leading, spacing: 2) {
                detail("Executable", executable.url.path)
                detail("Source", executable.source.displayName)
                if executable.version != nil || !executable.arguments.isEmpty {
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 2) {
                            if let version = executable.version {
                                detail("Version", version)
                            }
                            detail(
                                "Arguments",
                                executable.arguments.isEmpty
                                    ? String(localized: "None")
                                    : executable.arguments.joined(separator: " ")
                            )
                        }
                        .padding(.top, 2)
                    }
                    .font(.caption)
                }
            }
        case .missing(let reason):
            Text(verbatim: reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if item.profile.origin == .default,
               let guide = DefaultLanguageServerInstallationGuides.guide(
                   for: item.profile
               ) {
                InstallationGuidanceView(
                    profileIdentifier: item.profile.identifier,
                    guide: guide
                )
            }
        }
    }

    private func detail(
        _ label: LocalizedStringKey,
        _ value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label) + Text(verbatim: ":")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func statusLabel(
        _ state: LanguageSupportServerState
    ) -> some View {
        switch state {
        case .notConfigured:
            Label("Syntax Only", systemImage: "text.page")
                .font(.caption)
        case .checking:
            Label("Checking LSP", systemImage: "clock")
                .font(.caption)
        case .available:
            Label("LSP Ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
        case .missing:
            Label("LSP Missing", systemImage: "minus.circle")
                .font(.caption)
        }
    }
}

@MainActor
enum LanguageServerInstallationClipboard {
    @discardableResult
    static func copy(
        _ option: LanguageServerInstallCommandOption,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(
            option.commandLines.joined(separator: "\n"),
            forType: .string
        )
    }
}

/// Compact, curated "Suggested installation" area shown under a missing
/// language server on a *default* profile that has shipped guidance
/// (see `DefaultLanguageServerInstallationGuides`). Kod never executes
/// any of these commands: this view only ever displays them as
/// selectable, monospaced text and copies the exact string to the
/// pasteboard when the user asks, with immediate visible "Copied"
/// feedback per command.
private struct InstallationGuidanceView: View {
    let profileIdentifier: String
    let guide: LanguageServerInstallationGuide

    @State private var copiedCommandID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggested Installation")
                .font(.caption.bold())
            ForEach(guide.commandOptions, id: \.id) { option in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: option.commandLines.joined(separator: " && "))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier(
                            "settings.languageSupport.\(profileIdentifier).installCommand.\(option.id)"
                        )
                    Button(copyButtonTitle(for: option)) {
                        copy(option)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier(
                        "settings.languageSupport.\(profileIdentifier).copyCommand.\(option.id)"
                    )
                    if copiedCommandID == option.id {
                        Label("Copied", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
            }
            Link(
                "Installation Documentation",
                destination: guide.documentationURL
            )
            .font(.caption)
            .accessibilityIdentifier(
                "settings.languageSupport.\(profileIdentifier).installDocumentation"
            )
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier(
            "settings.languageSupport.\(profileIdentifier).installationGuidance"
        )
    }

    private func copyButtonTitle(for option: LanguageServerInstallCommandOption) -> String {
        String(
            localized: "Copy \(option.label) Command"
        )
    }

    private func copy(_ option: LanguageServerInstallCommandOption) {
        guard LanguageServerInstallationClipboard.copy(option) else {
            return
        }
        withAnimation {
            copiedCommandID = option.id
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedCommandID == option.id {
                withAnimation {
                    copiedCommandID = nil
                }
            }
        }
    }
}

private struct LanguageProfileEditorView: View {
    @State private var draft: LanguageProfileDraft
    @State private var conflictMessage: String?
    @State private var errorMessage: String?
    @ObservedObject var service: LanguageSupportService

    init(
        initialDraft: LanguageProfileDraft,
        service: LanguageSupportService
    ) {
        _draft = State(initialValue: initialDraft)
        self.service = service
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if draft.originalProfile == nil {
                Text("Add Language Profile")
                    .font(.title2.bold())
            } else {
                Text("Edit \(draft.displayName)")
                    .font(.title2.bold())
            }

            Form {
                TextField("Profile ID", text: $draft.identifier)
                    .disabled(draft.originalProfile != nil)
                TextField("Name", text: $draft.displayName)
                Toggle("Enabled", isOn: $draft.isEnabled)

                Section("File Associations") {
                    ForEach($draft.associations) { $association in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(
                                "Extensions (comma-separated)",
                                text: $association.fileExtensions
                            )
                            TextField(
                                "Exact filenames (comma-separated)",
                                text: $association.exactFileNames
                            )
                            Picker(
                                "Syntax",
                                selection: $association.syntaxLanguage
                            ) {
                                Text("Plain Text")
                                    .tag(Optional<SyntaxLanguage>.none)
                                ForEach(
                                    SyntaxLanguage.allCases.filter {
                                        $0 != .markdownInline
                                    },
                                    id: \.self
                                ) { language in
                                    Text(language.displayName)
                                        .tag(Optional(language))
                                }
                            }
                            if draft.languageServerEnabled {
                                TextField(
                                    "LSP language ID",
                                    text: $association.languageID
                                )
                            }
                            if draft.associations.count > 1 {
                                Button(
                                    "Remove Association",
                                    role: .destructive
                                ) {
                                    draft.associations.removeAll {
                                        $0.id == association.id
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button("Add Association") {
                        draft.associations.append(
                            LanguageAssociationDraft(
                                identifier:
                                    "files-\(draft.associations.count + 1)",
                                fileExtensions: "",
                                exactFileNames: "",
                                syntaxLanguage: nil,
                                languageID: draft.defaultLanguageID
                            )
                        )
                    }
                }

                Section("Language Server") {
                    Toggle(
                        "Enable Language Server",
                        isOn: $draft.languageServerEnabled
                    )
                    if draft.languageServerEnabled {
                        TextField(
                            "Default language ID",
                            text: $draft.defaultLanguageID
                        )
                        TextField(
                            "Executable path",
                            text: $draft.executablePath
                        )
                        ForEach(draft.arguments.indices, id: \.self) {
                            index in
                            HStack {
                                TextField(
                                    "Argument \(index + 1)",
                                    text: $draft.arguments[index]
                                )
                                Button {
                                    draft.arguments.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(
                                    String(localized: "Remove argument")
                                )
                            }
                        }
                        Button("Add Argument") {
                            draft.arguments.append("")
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    service.requestedProfileDraft = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(confirmingConflicts: false)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 620)
        .alert(
            "Replace Existing File Associations?",
            isPresented: Binding(
                get: { conflictMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        conflictMessage = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                conflictMessage = nil
            }
            Button("Save and Take Precedence") {
                save(confirmingConflicts: true)
            }
        } message: {
            Text(conflictMessage ?? "")
        }
        .alert(
            "Could Not Save Profile",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save(confirmingConflicts: Bool) {
        do {
            switch try service.save(
                draft: draft,
                confirmConflicts: confirmingConflicts
            ) {
            case .saved:
                conflictMessage = nil
            case .requiresConflictConfirmation(let conflicts):
                conflictMessage = conflicts.map {
                    conflictDescription($0)
                }
                .joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func conflictDescription(
        _ conflict: LanguageProfileConflict
    ) -> String {
        let association: String
        switch conflict.matchKey {
        case .exactFileName(let fileName):
            association = fileName
        case .fileExtension(let fileExtension):
            association = "*.\(fileExtension)"
        case .contentMatcher:
            association = String(localized: "content matcher")
        }
        let others = conflict.profileIdentifiers
            .filter { $0 != draft.identifier.lowercased() }
            .joined(separator: ", ")
        return "\(association): \(others)"
    }
}

private struct LanguageGrammarDetailsView: View {
    let profile: LanguageProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(profile.displayName) Syntax")
                .font(.title2.bold())
            ForEach(profile.associations, id: \.identifier) {
                association in
                VStack(alignment: .leading, spacing: 3) {
                    Text(association.identifier)
                        .font(.headline)
                    switch association.syntax {
                    case .plainText:
                        Text("Plain Text (no tokenizer)")
                    case .treeSitter(let language):
                        Text("Bundled Tree-sitter grammar: \(language.displayName)")
                        Link(
                            "Upstream provenance and license",
                            destination: upstreamURL(for: language)
                        )
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 500, height: 320)
    }

    private func upstreamURL(for language: SyntaxLanguage) -> URL {
        let knownURLs = [
            "swift": "https://github.com/alex-pinkus/tree-sitter-swift",
            "typescript": "https://github.com/tree-sitter/tree-sitter-typescript",
            "tsx": "https://github.com/tree-sitter/tree-sitter-typescript",
            "javascript": "https://github.com/tree-sitter/tree-sitter-javascript",
            "jsx": "https://github.com/tree-sitter/tree-sitter-javascript",
            "html": "https://github.com/tree-sitter/tree-sitter-html",
            "css": "https://github.com/tree-sitter/tree-sitter-css",
            "python": "https://github.com/tree-sitter/tree-sitter-python",
            "rust": "https://github.com/tree-sitter/tree-sitter-rust",
            "shell": "https://github.com/tree-sitter/tree-sitter-bash",
            "markdown": "https://github.com/tree-sitter-grammars/tree-sitter-markdown",
            "json": "https://github.com/tree-sitter/tree-sitter-json",
            "yaml": "https://github.com/tree-sitter-grammars/tree-sitter-yaml",
            "toml": "https://github.com/tree-sitter-grammars/tree-sitter-toml",
            "c": "https://github.com/tree-sitter/tree-sitter-c",
            "go": "https://github.com/tree-sitter/tree-sitter-go",
            "java": "https://github.com/tree-sitter/tree-sitter-java",
            "ruby": "https://github.com/tree-sitter/tree-sitter-ruby",
            "lua": "https://github.com/tree-sitter-grammars/tree-sitter-lua",
            "graphql": "https://github.com/bkegley/tree-sitter-graphql",
            "xml": "https://github.com/tree-sitter-grammars/tree-sitter-xml"
        ]
        let value = knownURLs[language.rawValue]
            ?? "https://github.com/search?q=tree-sitter-\(language.rawValue)&type=repositories"
        return URL(string: value)
            ?? LanguageSupportService.serverDirectoryURL
    }
}
