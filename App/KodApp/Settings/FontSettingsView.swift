import AppKit
import FontCore
import SwiftUI

struct FontSettingsView: View {
    @Binding var fontSettings: FontSettings
    let availableFamilies: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Font")
                    .font(.headline)
                    .accessibilityIdentifier("settings.fontTab")
                Text("Choose how code is displayed throughout Kod.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            typefaceCard
            spacingCard
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var typefaceCard: some View {
        VStack(spacing: 0) {
            settingsRow("Family", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    FontFamilyPicker(
                        selection: $fontSettings.familyName,
                        families: availableFamilies
                    )
                    if !MonospacedFontDiscovery.isFamilyMonospaced(
                        fontSettings.familyName
                    ) {
                        Label(
                            "\"\(fontSettings.familyName)\" is not monospaced; column alignment may vary.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.fontAlignmentWarning")
                    }
                }
            }

            Divider().padding(.leading, 108)

            settingsRow("Weight") {
                Picker("", selection: $fontSettings.weight) {
                    ForEach(FontWeight.allCases, id: \.self) { weight in
                        Text(weight.displayName).tag(weight)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                .accessibilityLabel(
                    Localized.string(
                        "Font weight",
                        comment: "Accessibility label for the font weight picker in Settings"
                    )
                )
                Spacer()
            }

            Divider().padding(.leading, 108)

            settingsRow("Size") {
                Stepper(
                    value: $fontSettings.pointSize,
                    in: FontSettings.sizeRange,
                    step: 1
                ) {
                    Text("\(Int(fontSettings.pointSize)) pt")
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
                .accessibilityLabel(
                    Localized.string(
                        "Font size",
                        comment: "Accessibility label for the font size stepper in Settings"
                    )
                )
                .accessibilityValue(
                    Localized.string(
                        "\(Int(fontSettings.pointSize)) points",
                        comment: "Accessibility value announcing the current font point size"
                    )
                )
                Spacer()
            }

            Divider().padding(.leading, 108)

            settingsRow("Ligatures") {
                Toggle("", isOn: $fontSettings.ligaturesEnabled)
                    .labelsHidden()
                    .accessibilityLabel(
                        Localized.string(
                            "Enable font ligatures",
                            comment: "Accessibility label for the font ligature toggle in Settings"
                        )
                    )
                    .accessibilityIdentifier("settings.ligatures")
                Spacer()
            }
        }
        .fontSettingsCard()
    }

    private var spacingCard: some View {
        VStack(spacing: 0) {
            settingsRow("Line height") {
                Slider(
                    value: $fontSettings.lineHeightMultiplier,
                    in: FontSettings.lineHeightRange,
                    step: 0.05
                )
                .accessibilityLabel(
                    Localized.string(
                        "Line height",
                        comment: "Accessibility label for the line height slider in Settings"
                    )
                )
                .accessibilityValue(
                    Localized.string(
                        "\(formatted(fontSettings.lineHeightMultiplier)) times",
                        comment: "Accessibility value announcing the current line height multiplier"
                    )
                )
                Text("\(formatted(fontSettings.lineHeightMultiplier))×")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }

            Divider().padding(.leading, 108)

            settingsRow("Letter spacing") {
                Slider(
                    value: $fontSettings.letterSpacing,
                    in: FontSettings.letterSpacingRange,
                    step: 0.1
                )
                .accessibilityLabel(
                    Localized.string(
                        "Letter spacing",
                        comment: "Accessibility label for the letter spacing slider in Settings"
                    )
                )
                .accessibilityValue(formatted(fontSettings.letterSpacing))
                Text(formatted(fontSettings.letterSpacing))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .fontSettingsCard()
    }

    private func settingsRow<Content: View>(
        _ title: LocalizedStringKey,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 38)
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct FontFamilyPicker: View {
    @Binding var selection: String
    let families: [String]

    @State private var isPresented = false
    @State private var query = ""
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                Text(selection)
                    .font(previewFont(for: selection, size: 13))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("settings.fontFamily")
        .accessibilityLabel(
            Localized.string(
                "Font family",
                comment: "Accessibility label for the font family picker in Settings"
            )
        )
        .accessibilityValue(selection)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            pickerContent
        }
        .onChange(of: isPresented) { _, presented in
            guard presented else {
                return
            }
            query = ""
            Task { @MainActor in
                searchFieldFocused = true
            }
        }
    }

    private var pickerContent: some View {
        VStack(spacing: 8) {
            TextField("Search fonts", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFieldFocused)
                .accessibilityIdentifier("settings.fontFamily.search")

            let matches = Self.filteredFamilies(families, query: query)
            if matches.isEmpty {
                ContentUnavailableView(
                    "No Matching Fonts",
                    systemImage: "text.magnifyingglass",
                    description: Text("Try a different font-family search.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches, id: \.self) { family in
                            Button {
                                selection = family
                                isPresented = false
                            } label: {
                                HStack(spacing: 12) {
                                    Text(family)
                                        .font(previewFont(for: family, size: 13))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("!=  ->  <=")
                                        .font(previewFont(for: family, size: 12))
                                        .foregroundStyle(.secondary)
                                    if family == selection {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                family == selection
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel(Text(family))
                            .accessibilityAddTraits(
                                family == selection ? .isSelected : []
                            )
                        }
                    }
                }
                .accessibilityIdentifier("settings.fontFamily.list")
            }
        }
        .padding(10)
        .frame(width: 340, height: 300)
    }

    static func filteredFamilies(
        _ families: [String],
        query: String
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return families
        }
        return families.filter {
            $0.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            ) != nil
        }
    }

    private func previewFont(for family: String, size: Double) -> Font {
        Font(
            FontResolver.resolve(
                FontSettings(familyName: family, pointSize: size)
            ).nsFont
        )
    }
}

private struct FontSettingsCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}

private extension View {
    func fontSettingsCard() -> some View {
        modifier(FontSettingsCard())
    }
}
