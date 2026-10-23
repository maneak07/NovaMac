import SwiftUI
import Combine

// NovaMac — Calibration: turns the receiving cards' calibration coefficients on and off.
// Captured from NovaLCT "Screen Calibration → Enable/Disable Calibration" on VX1000 Pro (21.10.2026):
//   read  dev1 port p card 0     0x02000051 (1)   current mode
//   write dev1 port p card FFFF  0x02000051 = mode
//   write dev1 port p card FFFF  0x010000B3 = 05 (calibration on) / 00 (off)
// Modes (second capture: Chroma alone = 01): 00 off, 01 chroma, 03 brightness.
// Full grayscale: not captured yet (greyed out in NovaLCT on the test cards — no such coefficients stored).

nonisolated enum ScreenCalibration {
    enum Mode: Int, CaseIterable, Identifiable, Sendable {
        case off = 0, brightness = 3, chroma = 1
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .off: return "Disabled"
            case .brightness: return "Brightness"
            case .chroma: return "Chroma"
            }
        }
    }

    static let modeRegister: UInt32 = 0x0200_0051
    static let switchRegister: UInt32 = 0x0100_00B3

    /// Raw mode byte of the first card on `port` (0-based).
    static func read(_ endpoint: NovaEndpoint, port: Int) async throws -> Int {
        let b = try await NovaLink.run(endpoint, timeout: 1) { socket in
            try socket.transact(.read(modeRegister, length: 1, device: 1, port: UInt8(port), card: 0))
        }
        guard let v = b.first else { throw NovaLinkError.badResponse("short read") }
        return Int(v)
    }

    /// Sets the mode on every card of `ports` (nil = all ports), the way NovaLCT does it.
    static func set(_ endpoint: NovaEndpoint, mode: Mode, ports: [Int]?) async throws {
        let value = UInt8(mode.rawValue)
        let on: UInt8 = mode == .off ? 0x00 : 0x05
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            for p in ports ?? [0xFF] {
                let port = UInt8(p)
                if p == 0xFF {
                    try socket.transact(.write(modeRegister, [value], destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF))
                    try socket.transact(.write(switchRegister, [on], destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF))
                } else {
                    try socket.transact(.write(modeRegister, [value], device: 1, port: port, card: 0xFFFF))
                    try socket.transact(.write(switchRegister, [on], device: 1, port: port, card: 0xFFFF))
                }
            }
        }
    }
}

struct CalibrationPage: View {
    @ObservedObject var device: NovaDevice
    @ObservedObject var workspace: ScreenWorkspace

    @State private var selected: Set<UUID> = []
    @State private var mode: ScreenCalibration.Mode? = nil
    @State private var rawMode: Int?
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?
    @State private var started = false

    private var chosen: [ScreenDocument] { workspace.screens.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            screensBox
            calibrationBox
            if let screen = chosen.first {
                SeamPanel(screen: screen, device: device).id(screen.id)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onAppear {
            guard !started else { return }
            started = true
            if workspace.screens.isEmpty {
                Task { await workspace.readAll(device: device); selectDefault() }
            } else { selectDefault() }
        }
    }

    // MARK: Screens

    private var screensBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if workspace.screens.isEmpty {
                    HStack {
                        Text(workspace.reading ? "Reading screens from the controllers…" : "No screens yet.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Read screens from HW") { Task { await workspace.readAll(device: device); selectDefault() } }
                            .disabled(workspace.reading)
                    }
                } else {
                    Toggle("All screens", isOn: Binding(get: { selected.count == workspace.screens.count && !selected.isEmpty },
                                                        set: { $0 ? selectAll() : selected.removeAll() }))
                        .font(.callout.weight(.semibold))
                    Divider()
                    ForEach(workspace.screens) { screen in
                        Toggle(isOn: Binding(get: { selected.contains(screen.id) }, set: { on in
                            if on { selected.insert(screen.id) } else { selected.remove(screen.id) }
                            readCurrent()
                        })) {
                            HStack(spacing: 8) {
                                Text(screen.name).font(.callout.weight(.medium))
                                Text(device.title(for: screen.endpoint)).font(.callout).foregroundStyle(.secondary)
                                Text(portsText(screen)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("Screens").font(.headline)
        }
    }

    /// Default choice: the screens of the first active controller — the selected one if it is connected,
    /// else the first connected controller that has screens, else the selected one, else the first screen's.
    private func selectDefault() {
        let keys = workspace.screens.map(\.endpoint.key)
        let selection = device.selection.key
        let key = (device.connected.contains(selection) && keys.contains(selection) ? selection : nil)
            ?? keys.first { device.connected.contains($0) }
            ?? (keys.contains(selection) ? selection : nil)
            ?? keys.first
        selected = Set(workspace.screens.filter { $0.endpoint.key == key }.map(\.id))
        readCurrent()
    }

    private func selectAll() {
        selected = Set(workspace.screens.map(\.id))
        readCurrent()
    }

    private func ports(of screen: ScreenDocument) -> [Int] {
        Array(Set(screen.plan.cells.filter { $0.order != nil && !$0.blank }.map { $0.port - 1 })).sorted()
    }

    private func portsText(_ screen: ScreenDocument) -> String {
        let p = ports(of: screen)
        guard !p.isEmpty else { return "" }
        let model = device.models[screen.endpoint.key]
        return (p.count == 1 ? "port " : "ports ") + p.map { String(ControllerModels.portLabel(model: model, index: $0)) }.joined(separator: ", ")
    }

    /// Controllers and the ports of the chosen screens (nil = no ports known → all ports).
    private var targets: [(NovaEndpoint, [Int]?)] {
        var result: [(NovaEndpoint, [Int]?)] = []
        var seen = Set<String>()
        for screen in chosen where seen.insert(screen.endpoint.key).inserted {
            let p = Set(chosen.filter { $0.endpoint.key == screen.endpoint.key }.flatMap { ports(of: $0) })
            result.append((screen.endpoint, p.isEmpty ? nil : p.sorted()))
        }
        return result
    }

    // MARK: Calibration

    private var calibrationBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Calibration coefficients").font(.callout.weight(.medium))
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Picker("", selection: Binding(get: { mode ?? .off }, set: { apply($0) })) {
                    ForEach([ScreenCalibration.Mode.off, .brightness, .chroma]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                HStack {
                    if let rawMode, ScreenCalibration.Mode(rawValue: rawMode) == nil {
                        Text(String(format: "Cards report mode 0x%02X (not one of the modes above).", rawMode))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Read current") { readCurrent() }
                }
                Text("Takes effect immediately, not saved — a power cycle restores the stored setting. Full grayscale needs cards that store full-grayscale coefficients (not captured yet). Low grayscale and dark/bright lines come next.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(chosen.isEmpty)
            .padding(6)
        } label: {
            Text("Calibration").font(.headline)
        }
    }

    private func apply(_ newMode: ScreenCalibration.Mode) {
        let previous = mode
        mode = newMode
        let jobs = targets
        Task { @MainActor in
            busy = true
            defer { busy = false }
            var failed: [String] = []
            for (endpoint, ports) in jobs {
                do { try await ScreenCalibration.set(endpoint, mode: newMode, ports: ports) }
                catch { failed.append(device.title(for: endpoint) + ": " + error.localizedDescription) }
            }
            error = failed.isEmpty ? nil : failed.joined(separator: "\n")
            if failed.count == jobs.count && !jobs.isEmpty { mode = previous }
            status = failed.isEmpty ? "\(newMode.title) on \(chosen.count) screen(s)" : "Not set everywhere"
            rawMode = newMode.rawValue
        }
    }

    private func readCurrent() {
        guard let screen = chosen.first else { return }
        let endpoint = screen.endpoint, port = ports(of: screen).first ?? 0
        Task { @MainActor in
            do {
                let raw = try await ScreenCalibration.read(endpoint, port: port)
                rawMode = raw
                mode = ScreenCalibration.Mode(rawValue: raw)
                status = "\(screen.name): " + (mode?.title ?? String(format: "0x%02X", raw))
                error = nil
            } catch { self.error = "Read: \(error.localizedDescription)" }
        }
    }
}
