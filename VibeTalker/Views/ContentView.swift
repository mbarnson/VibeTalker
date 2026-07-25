import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            conversationPanel
                .frame(minWidth: 360, idealWidth: 460)
            consolePanel
                .frame(minWidth: 540)
        }
        .frame(minWidth: 980, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.runNativePreflight()
                } label: {
                    Label("Run Preflight", systemImage: "checkmark.shield")
                }
                .disabled(model.health == .checking)
                .accessibilityIdentifier("run-preflight")
            }
        }
    }

    private var conversationPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Conversation")
                        .font(.title2.weight(.semibold))
                    Text("Moshi voice surface and native coordinator")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HealthBadge(health: model.health)
            }

            GroupBox("Native preflight") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    diagnosticRow("Helper stdio", model.helperRoundTrip)
                    diagnosticRow("Node runtime", model.jitStatus)
                    diagnosticRow("Nested sandbox", model.sandboxStatus)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Managed local voice runtime") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.runtimeArtifacts) { artifact in
                        HStack {
                            Image(systemName: artifact.available
                                ? "checkmark.circle.fill"
                                : "xmark.circle")
                                .foregroundStyle(artifact.available ? .green : .secondary)
                            Text(artifact.label)
                            Spacer()
                            Text(artifact.available ? "Ready" : "Missing")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button("Refresh") {
                            model.refreshRuntimeInstallation()
                        }
                        Spacer()
                        Button("Stop") {
                            model.stopVoiceRuntime()
                        }
                        Button("Start Local Voice") {
                            model.startVoiceRuntime()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.health != .ready ||
                            model.runtimeArtifacts.contains(where: { !$0.available })
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .padding(20)
    }

    private var consolePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Pi Console", systemImage: "terminal")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(model.events.count) events")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.events) { event in
                            ConsoleEventRow(event: event)
                                .id(event.id)
                        }
                    }
                    .padding(14)
                    .textSelection(.enabled)
                }
                .onChange(of: model.events.count) {
                    if let last = model.events.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack(spacing: 10) {
                TextField(
                    model.isJobRunning ? "Type abort to cancel…" : "Type a task for pi…",
                    text: Bindable(model).composerText
                )
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .onSubmit { model.submitComposer() }
                .accessibilityIdentifier("pi-composer")

                Button("Send") {
                    model.submitComposer()
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(12)
            .background(.bar)
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
        }
    }
}

private struct HealthBadge: View {
    let health: RuntimeHealth

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var label: String {
        switch health {
        case .idle: "Not checked"
        case .checking: "Checking"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }

    private var icon: String {
        switch health {
        case .idle: "circle"
        case .checking: "clock"
        case .ready: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch health {
        case .idle: .secondary
        case .checking: .orange
        case .ready: .green
        case .failed: .red
        }
    }
}

private struct ConsoleEventRow: View {
    let event: LedgerEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(String(format: "%05llu", event.sequence))
                .foregroundStyle(.tertiary)
            Text(event.timestamp, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
            Text(event.kind.rawValue.uppercased())
                .foregroundStyle(kindColor)
                .frame(width: 92, alignment: .leading)
            Text(event.message)
                .foregroundStyle(event.kind == .error ? .red : .primary)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindColor: Color {
        switch event.kind {
        case .error: .red
        case .completion: .green
        case .policy: .orange
        case .request: .purple
        case .reference: .blue
        default: .secondary
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
