import CodeViewport
import FontCore
import SwiftUI

enum SettingsTab: Hashable {
    case font
    case languages
    case diagnostics
}

/// Native settings UI for font, language, and diagnostics configuration.
/// Font controls cover family (filtered to installed monospaced families),
/// size, weight, ligatures, line height, letter spacing, and an ordered
/// Unicode fallback chain. Pure SwiftUI state driven by
/// `@Binding`s owned by `SettingsWindowController`, so it is constructible
/// and previewable without any app-wide singleton.
struct SettingsView: View {
    @Binding var selectedTab: SettingsTab

    @Binding var fontSettings: FontSettings
    let availableFamilies: [String]

    @ObservedObject var diagnosticsModel: DiagnosticsViewModel
    let onExportSupportBundle: @MainActor () -> Void
    @ObservedObject var languageSupportService: LanguageSupportService
    let onChooseLanguageServerExecutable: @MainActor (String) -> Void
    let onFindLanguageServer: @MainActor () -> Void

    @State private var newFallbackFamily = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            fontTab
                .tabItem { Label("Font", systemImage: "textformat") }
                .tag(SettingsTab.font)
            LanguageSupportSettingsView(
                service: languageSupportService,
                onChooseExecutable: onChooseLanguageServerExecutable,
                onFindLanguageServer: onFindLanguageServer
            )
            .tabItem { Label("Languages", systemImage: "curlybraces") }
            .tag(SettingsTab.languages)
            DiagnosticsView(model: diagnosticsModel, onExportSupportBundle: onExportSupportBundle)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(SettingsTab.diagnostics)
        }
        .padding(20)
        .frame(width: 720, height: 540)
    }

    private var fontTab: some View {
        Form {
            Picker("Family", selection: $fontSettings.familyName) {
                ForEach(availableFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .accessibilityIdentifier("settings.fontFamily")

            Picker("Weight", selection: $fontSettings.weight) {
                ForEach(FontWeight.allCases, id: \.self) { weight in
                    Text(weight.displayName).tag(weight)
                }
            }

            Stepper(
                "Size: \(Int(fontSettings.pointSize)) pt",
                value: $fontSettings.pointSize,
                in: FontSettings.sizeRange,
                step: 1
            )
            .accessibilityLabel(Localized.string("Font size", comment: "Accessibility label for the font size stepper in Settings"))
            .accessibilityValue(Localized.string("\(Int(fontSettings.pointSize)) points", comment: "Accessibility value announcing the current font point size"))

            Toggle("Ligatures", isOn: $fontSettings.ligaturesEnabled)
                .accessibilityIdentifier("settings.ligatures")

            Slider(
                value: $fontSettings.lineHeightMultiplier,
                in: FontSettings.lineHeightRange
            ) {
                Text("Line Height: \(String(format: "%.2f", fontSettings.lineHeightMultiplier))x")
            }
            .accessibilityLabel(Localized.string("Line height", comment: "Accessibility label for the line height slider in Settings"))
            .accessibilityValue(Localized.string("\(String(format: "%.2f", fontSettings.lineHeightMultiplier)) times", comment: "Accessibility value announcing the current line height multiplier"))

            Slider(
                value: $fontSettings.letterSpacing,
                in: FontSettings.letterSpacingRange
            ) {
                Text("Letter Spacing: \(String(format: "%.2f", fontSettings.letterSpacing))")
            }
            .accessibilityLabel(Localized.string("Letter spacing", comment: "Accessibility label for the letter spacing slider in Settings"))
            .accessibilityValue(Localized.string("\(String(format: "%.2f", fontSettings.letterSpacing))", comment: "Accessibility value announcing the current letter spacing"))

            Section("Fallback Families") {
                ForEach(fontSettings.fallbackFamilies, id: \.self) { family in
                    Text(family)
                }
                .onDelete { indices in
                    fontSettings.fallbackFamilies.remove(atOffsets: indices)
                }

                HStack {
                    TextField("Add fallback family", text: $newFallbackFamily)
                    Button("Add") {
                        let trimmed = newFallbackFamily.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else {
                            return
                        }
                        fontSettings.fallbackFamilies.append(trimmed)
                        newFallbackFamily = ""
                    }
                    .disabled(newFallbackFamily.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !MonospacedFontDiscovery.isFamilyMonospaced(fontSettings.familyName) {
                Label(
                    "\"\(fontSettings.familyName)\" is not monospaced; column alignment may vary.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier("settings.fontAlignmentWarning")
            }
        }
    }
}
