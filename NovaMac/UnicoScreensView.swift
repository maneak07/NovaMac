import SwiftUI
import Foundation

// NovaMac v0.8 — Screen Configuration (read-only)
// Shared Unico models and network client are in UnicoAPI.swift.
struct UnicoScreensView: View {
    let ip: String

    @State private var screens: [UnicoScreen] = []
    @State private var loading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var lastRefresh: Date?
    @State private var autoRefresh = true

    private var orderedScreens: [UnicoScreen] {
        screens.filter { $0.info?.select == 1 } + screens.filter { $0.info?.select != 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Screen Configuration", systemImage: "rectangle.3.group")
                    .font(.headline)
                Spacer()
                Toggle("Auto Refresh (5 s)", isOn: $autoRefresh)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
                    .fixedSize()
                if loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await refreshScreens() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }

            HStack(spacing: 10) {
                Text("Unico REST API · Project: \(UnicoAPI.projectID)")
                Spacer()
                if let lastRefresh {
                    Text("Last read: \(lastRefresh.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if hasLoaded && screens.isEmpty && errorMessage == nil {
                Text("No screen objects returned.")
                    .foregroundStyle(.secondary)
            }

            ForEach(orderedScreens) { screen in
                UnicoScreenCard(screen: screen, initiallyExpanded: screen.guid == orderedScreens.first?.guid) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let info = screen.info {
                            infoRow("Screen ID", "\(info.screenId)")
                            infoRow("Window", "\(info.mosaic.window.width) × \(info.mosaic.window.height)")
                            infoRow("Selected flag", "\(info.select)")
                            infoRow("Controller serial", screen.deviceList.first?.sn ?? "—")
                        } else {
                            Text("Screen details unavailable")
                                .foregroundStyle(.orange)
                        }
                        Divider()
                        Text("GUID: \(screen.guid)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                }
                .id("\(ip)/\(screen.guid)")
            }

            Label("READ ONLY · This page shows data returned by VX1000 Pro.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .task(id: ip) {
            await refreshScreens()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch { break }
                if autoRefresh && !loading {
                    await refreshScreens(silent: true)
                }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    @MainActor
    private func refreshScreens(silent: Bool = false) async {
        guard !loading else { return }
        loading = true
        if !silent { errorMessage = nil }
        defer {
            loading = false
            hasLoaded = true
        }
        do {
            screens = try await UnicoAPI.fetchScreens(ip: ip)
            lastRefresh = Date()
        } catch {
            // Keep last successfully read values.
            if !silent {
                errorMessage = "Reading screens: \(error.localizedDescription)"
            }
        }
    }
}

// Local presentation only. Expanding a card never selects or writes to a device.
// A manual choice survives GET refreshes; changing controller IP resets it.
struct UnicoScreenCard<Content: View>: View {
    let screen: UnicoScreen
    let initiallyExpanded: Bool
    private let content: Content
    @State private var expansionOverride: Bool?

    init(screen: UnicoScreen, initiallyExpanded: Bool,
         @ViewBuilder content: () -> Content) {
        self.screen = screen
        self.initiallyExpanded = initiallyExpanded
        self.content = content()
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: Binding(
                get: { expansionOverride ?? initiallyExpanded },
                set: { expansionOverride = $0 }
            )) {
                content.padding(.top, 8)
            } label: {
                HStack(spacing: 12) {
                    Label(screen.displayName, systemImage: "display")
                        .font(.headline)
                    if screen.info?.select == 1 {
                        Text("Active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    if let info = screen.info {
                        Text("\(info.mosaic.window.width) × \(info.mosaic.window.height)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .padding(6)
        }
    }
}
