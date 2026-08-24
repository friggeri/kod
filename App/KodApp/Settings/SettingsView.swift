import AppKit
import FontCore
import KodUIComponents
import SwiftUI

enum SettingsDestination: Hashable {
    case font
    case language(String)
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selectedDestination: SettingsDestination?

    init(selectedDestination: SettingsDestination = .font) {
        self.selectedDestination = selectedDestination
    }

    func selectLanguage(_ identifier: String?) {
        guard let identifier else {
            return
        }
        selectedDestination = .language(identifier)
    }

    func reconcileSelection(in items: [LanguageSupportItem]) {
        guard case .language(let identifier) = selectedDestination else {
            if selectedDestination == nil {
                selectedDestination = .font
            }
            return
        }
        guard !items.contains(where: { $0.id == identifier }) else {
            return
        }
        selectedDestination = .font
    }
}

struct SettingsSidebarView: View {
    @ObservedObject var navigationModel: SettingsNavigationModel
    @ObservedObject var languageSupportService: LanguageSupportService

    var body: some View {
        List(selection: deferredSelection) {
            Section("Editor") {
                Label("Font", systemImage: "textformat")
                    .tag(SettingsDestination.font)
                    .accessibilityIdentifier("settings.font.row")
            }

            Section("Languages") {
                ForEach(languageSupportService.items) { item in
                    HStack(spacing: 8) {
                        MaterialLanguageIcon(
                            fileName: SettingsLanguageIcon.fileName(
                                for: item.id
                            )
                        )
                        .frame(
                            width: SettingsLanguageIcon.pointSize,
                            height: SettingsLanguageIcon.pointSize
                        )
                        .accessibilityIdentifier(
                            "settings.languageSupport.\(item.id).icon"
                        )

                        Text(item.profile.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Image(
                            systemName:
                                item.serverState.presentation.systemImage
                        )
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(item.serverState.statusColor)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    }
                    .tag(SettingsDestination.language(item.id))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        Text(item.profile.displayName)
                            + Text(", ")
                            + Text(item.serverState.presentation.title)
                    )
                    .accessibilityIdentifier(
                        "settings.languageSupport.\(item.id).row"
                    )
                }
            }

        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("settings.sidebar")
        .task {
            navigationModel.selectLanguage(
                languageSupportService.focusedProfileIdentifier
            )
            navigationModel.reconcileSelection(
                in: languageSupportService.items
            )
        }
        .onChange(of: navigationModel.selectedDestination) { _, destination in
            guard destination == nil else {
                return
            }
            Task { @MainActor in
                await Task.yield()
                if navigationModel.selectedDestination == nil {
                    navigationModel.selectedDestination = .font
                }
            }
        }
        .onChange(of: languageSupportService.items) { _, items in
            Task { @MainActor in
                await Task.yield()
                navigationModel.reconcileSelection(in: items)
            }
        }
        .onChange(of: languageSupportService.focusRequestRevision) { _, _ in
            Task { @MainActor in
                await Task.yield()
                navigationModel.selectLanguage(
                    languageSupportService.focusedProfileIdentifier
                )
            }
        }
    }

    private var deferredSelection: Binding<SettingsDestination?> {
        Binding(
            get: { navigationModel.selectedDestination },
            set: { destination in
                guard destination
                        != navigationModel.selectedDestination else {
                    return
                }
                Task { @MainActor in
                    await Task.yield()
                    navigationModel.selectedDestination = destination
                }
            }
        )
    }
}

struct SettingsDetailView: View {
    @ObservedObject var navigationModel: SettingsNavigationModel
    @ObservedObject var model: SettingsModel
    let availableFamilies: [String]
    @ObservedObject var languageSupportService: LanguageSupportService

    @ViewBuilder
    var body: some View {
        switch navigationModel.selectedDestination ?? .font {
        case .font:
            FontSettingsView(
                fontSettings: $model.fontSettings,
                availableFamilies: availableFamilies
            )
            .padding(24)
        case .language(let identifier):
            if let item = languageSupportService.items.first(where: {
                $0.id == identifier
            }) {
                LanguageSupportDetailView(
                    item: item,
                    service: languageSupportService
                )
                .id(item.id)
            } else {
                ContentUnavailableView(
                    "Language Unavailable",
                    systemImage: "curlybraces",
                    description: Text(
                        "This shipped language is no longer available."
                    )
                )
            }
        }
    }
}

enum SettingsLanguageIcon {
    static let pointSize: CGFloat = 12

    static func fileName(for identifier: String) -> String {
        switch identifier {
        case "swift": "Example.swift"
        case "typescript": "Example.ts"
        case "html": "index.html"
        case "css": "styles.css"
        case "python": "example.py"
        case "rust": "main.rs"
        case "shellscript": "script.sh"
        case "markdown": "README.md"
        case "json": "example.json"
        case "yaml": "config.yaml"
        case "toml": "config.toml"
        case "c": "main.c"
        case "go": "main.go"
        case "java": "Main.java"
        case "ruby": "script.rb"
        case "lua": "script.lua"
        case "graphql": "schema.graphql"
        case "xml": "document.xml"
        default: "file.txt"
        }
    }
}

private struct MaterialLanguageIcon: NSViewRepresentable {
    let fileName: String

    func makeNSView(context: Context) -> MaterialLanguageIconContainer {
        MaterialLanguageIconContainer(fileName: fileName)
    }

    func updateNSView(
        _ container: MaterialLanguageIconContainer,
        context: Context
    ) {
        container.fileName = fileName
    }
}

@MainActor
private final class MaterialLanguageIconContainer: NSView {
    private let imageView = MaterialFileIconView()

    var fileName: String {
        get { imageView.fileName ?? "" }
        set { imageView.fileName = newValue }
    }

    init(fileName: String) {
        super.init(
            frame: NSRect(
                origin: .zero,
                size: NSSize(
                    width: SettingsLanguageIcon.pointSize,
                    height: SettingsLanguageIcon.pointSize
                )
            )
        )
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(
                equalToConstant: SettingsLanguageIcon.pointSize
            ),
            imageView.heightAnchor.constraint(
                equalToConstant: SettingsLanguageIcon.pointSize
            ),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        self.fileName = fileName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: SettingsLanguageIcon.pointSize,
            height: SettingsLanguageIcon.pointSize
        )
    }
}
