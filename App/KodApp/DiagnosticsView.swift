import DiagnosticsCore
import SwiftUI

/// The Diagnostics settings tab (SPEC 15): shows a live, always-redacted
/// view of the shared `BoundedEventLog`'s `redactedSnapshot()`, the
/// opt-in crash-reporting toggle (SPEC 13.3), and the support-bundle export
/// action. A plain SwiftUI `View` driven by an `@ObservedObject`
/// view-model plus a couple of closures for the file-panel-backed export
/// action — no app-wide singleton is referenced directly from the view
/// itself, mirroring `SettingsView`'s existing `@Binding`/plain-params
/// style.
struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsViewModel
    let onExportSupportBundle: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            eventLogSection
            Divider()
            privacySection
            Spacer()
        }
        .padding(4)
        .task {
            await model.refresh()
        }
    }

    private var eventLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Diagnostics Log", comment: "Section header for the diagnostics event log in Settings").font(.headline)
                Spacer()
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .accessibilityIdentifier("diagnostics.refresh")
            }

            Picker("Minimum Level", selection: $model.minimumLevel) {
                ForEach(DiagnosticLevel.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("diagnostics.levelFilter")

            if model.droppedCount > 0 {
                Label(
                    "\(model.droppedCount) earlier event(s) dropped (the log is bounded).",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier("diagnostics.droppedCount")
            }

            if model.filteredEvents.isEmpty {
                Text("No diagnostic events recorded yet at this level.", comment: "Empty-state message shown when the diagnostics log has no events at the selected minimum level")
                    .foregroundStyle(.secondary)
            } else {
                List(model.filteredEvents, id: \.id) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.subsystem.rawValue.capitalized)
                                .font(.caption.bold())
                            Text(event.level.rawValue.uppercased())
                                .font(.caption)
                                .foregroundStyle(color(for: event.level))
                            Spacer()
                            Text(event.timestamp, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(event.message)
                            .font(.body)
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(minHeight: 160, maxHeight: 220)
                .accessibilityIdentifier("diagnostics.eventList")
            }
        }
    }

    private func color(for level: DiagnosticLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy", comment: "Section header for the privacy controls in Settings").font(.headline)

            Toggle("Enable Opt-In Crash Reporting", isOn: $model.crashReportingEnabled)
                .accessibilityIdentifier("diagnostics.crashReportingToggle")
                .accessibilityLabel(
                    Localized.string(
                        "Enable opt-in crash reporting. Off by default. Kod has no usage telemetry.",
                        comment: "Accessibility label for the crash-reporting opt-in toggle in Settings"
                    )
                )

            if let persistenceError = model.persistenceErrorDescription {
                Text(
                    Localized.string(
                        "Crash-reporting preference could not be saved: \(persistenceError)",
                        comment: "Error shown when persisting the crash-reporting preference fails"
                    )
                )
                .font(.caption)
                .foregroundStyle(.red)
            }

            Text(
                Localized.string(
                    """
                    Crash reports are never sent automatically. No upload destination is configured \
                    in this build, so enabling this toggle does not transmit anything anywhere — \
                    it only prepares Kod to record a crash report locally if a real upload \
                    destination is added in a future release. Kod has no usage telemetry.
                    """,
                    comment: "Explanatory body text under the crash-reporting toggle in Settings"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Export Support Bundle...", action: onExportSupportBundle)
                    .accessibilityIdentifier("diagnostics.exportSupportBundle")
                if let lastExportErrorDescription = model.lastExportErrorDescription {
                    Text(
                        Localized.string(
                            "Export failed: \(lastExportErrorDescription)",
                            comment: "Status message shown under the Export Support Bundle button when export fails"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
        }
    }
}
