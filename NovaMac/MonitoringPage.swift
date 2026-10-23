import SwiftUI
import Combine

// NovaMac — Monitoring: input signal, receiving-card status (answer, temperature, voltage), cabinet
// positions and the load on every Ethernet port.
//
// Sources:
//   Input sources — VX Pro protocol V1.0.2 §3.8.1 (documented): read dev0 0x13010001, 256 bytes;
//     source k at 1 + 32k: interlaced, state (1 = signal), width u16, height u16, frame-rate count u16
//     (rate = 100 000 000 / count, in 0.01 Hz).
//   Card status — dev1 port p card c 0x0A000000, 82 bytes, as NovaLCT reads it (MEE410 / VX captures).
//       [0] bit 7 = temperature valid, [1] temperature × 2 (°C) — confirmed 21.10.2026 against NovaLCT
//           MonitorSite on VX1000 Pro: 0x66 → 51 °C (card 1), 0x64 → 50 °C (card 2)
//       [3] bit 7 = voltage valid, bits 0-6 voltage × 10 (V) — 4.1/4.2 V (VX), 3.7/3.8 V (MEE410); NovaLCT
//           does not show a voltage for these cards, so this is not confirmed yet
//   Port load — from the screen layout: pixels on the port / 650 000.

nonisolated enum ScreenMonitor {
    struct Input: Sendable, Identifiable {
        let index: Int
        let signal: Bool
        let interlaced: Bool
        let width: Int, height: Int
        let rate: Double?           // Hz
        let raw: [UInt8]            // the source's 32 bytes as read
        var id: Int { index }
    }

    struct Card: Sendable {
        let port: Int, card: Int
        let answered: Bool
        let temperature: Double?
        let voltage: Double?
        let raw: [UInt8]
    }

    static func inputs(_ endpoint: NovaEndpoint) async throws -> [Input] {
        let b = try await NovaLink.run(endpoint, timeout: 2) { socket in
            try socket.transact(.read(0x1301_0001, length: 256))
        }
        var list: [Input] = []
        for k in 0..<8 {
            let o = 1 + 32 * k
            guard o + 7 < b.count else { break }
            let w = Int(b[o + 2]) | Int(b[o + 3]) << 8, h = Int(b[o + 4]) | Int(b[o + 5]) << 8
            let count = Int(b[o + 6]) | Int(b[o + 7]) << 8
            list.append(Input(index: k + 1, signal: b[o + 1] != 0, interlaced: b[o] == 1, width: w, height: h,
                              rate: count > 0 ? (100_000_000.0 / Double(count)) / 100 : nil,
                              raw: Array(b[o..<min(o + 32, b.count)])))
        }
        return list
    }

    static func decode(_ b: [UInt8]) -> (temperature: Double?, voltage: Double?) {
        guard b.count >= 4 else { return (nil, nil) }
        let t = b[0] & 0x80 != 0 ? Double(b[1]) / 2 : nil
        let v = b[3] & 0x80 != 0 ? Double(b[3] & 0x7F) / 10 : nil
        return (t, v)
    }

    /// Status of each card; a card that does not answer (twice) is reported as not answering.
    static func cards(_ endpoint: NovaEndpoint, _ list: [(port: Int, card: Int)]) async throws -> [Card] {
        try await NovaLink.run(endpoint, timeout: 1) { socket in
            var result: [Card] = []
            for (port, card) in list {
                if let b = CardProbe.ask(socket, 0x0A00_0000, length: 82, port: port, card: card) {
                    let d = decode(b)
                    result.append(Card(port: port, card: card, answered: true, temperature: d.temperature, voltage: d.voltage, raw: b))
                } else {
                    result.append(Card(port: port, card: card, answered: false, temperature: nil, voltage: nil, raw: []))
                }
            }
            return result
        }
    }
}

/// Polls every screen in the background (also while another page is open), so the sidebar can flag alarms.
final class MonitorCenter: ObservableObject {
    @Published var status: [UUID: [String: ScreenMonitor.Card]] = [:]   // screen → "port-card" → status
    @Published var inputs: [UUID: [ScreenMonitor.Input]] = [:]
    @Published var notes: [UUID: String] = [:]
    @Published var errors: [UUID: String] = [:]
    @Published var lastRead: Date?
    @Published var reading = false
    @Published var interval = UserDefaults.standard.object(forKey: "NovaMac.monitor.interval") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(interval, forKey: "NovaMac.monitor.interval"); restart() }
    }
    @Published var warnTemperature = UserDefaults.standard.object(forKey: "NovaMac.monitor.warn") as? Double ?? 70 {
        didSet { UserDefaults.standard.set(warnTemperature, forKey: "NovaMac.monitor.warn") }
    }

    private weak var device: NovaDevice?
    private weak var workspace: ScreenWorkspace?
    private var loop: Task<Void, Never>?

    func attach(device: NovaDevice, workspace: ScreenWorkspace) {
        let same = self.device === device && self.workspace === workspace && loop != nil
        self.device = device
        self.workspace = workspace
        if !same { restart() }
    }

    private var readingSince: Date?

    func restart() {
        loop?.cancel()
        let seconds = interval
        loop = Task { @MainActor [weak self] in
            await self?.refreshAll()
            guard seconds > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.refreshAll()
            }
        }
    }

    private func cabinets(_ screen: ScreenDocument) -> [(port: Int, card: Int)] {
        screen.plan.cells.filter { $0.order != nil && !$0.blank }.map { (port: $0.port - 1, card: $0.order! - 1) }
    }

    /// Cabinets that are hot / not answering, over all screens.
    var hotCount: Int { status.values.flatMap(\.values).filter { ($0.temperature ?? 0) >= warnTemperature }.count }
    var silentCount: Int {
        guard let workspace else { return 0 }
        return workspace.screens.reduce(0) { sum, screen in
            let map = status[screen.id] ?? [:]
            return sum + cabinets(screen).filter { map["\($0.port)-\($0.card)"]?.answered == false }.count
        }
    }

    func refreshAll() async {
        guard let device, let workspace, !workspace.reading else { return }
        // A read that hangs (controller gone mid-read) must not stop monitoring for good.
        if reading, let since = readingSince, Date().timeIntervalSince(since) < 60 { return }
        reading = true
        readingSince = Date()
        defer { reading = false; readingSince = nil }
        for screen in workspace.screens {
            let endpoint = screen.endpoint
            let list = cabinets(screen)
            guard !list.isEmpty else { status[screen.id] = [:]; continue }
            do {
                let result = try await ScreenMonitor.cards(endpoint, list)
                var map: [String: ScreenMonitor.Card] = [:]
                for c in result { map["\(c.port)-\(c.card)"] = c }
                status[screen.id] = map
                errors[screen.id] = nil
            } catch { errors[screen.id] = "Cards: \(error.localizedDescription)" }
            if device.ids[endpoint.key]?.family == 0x622B || device.models[endpoint.key]?.uppercased().hasPrefix("VX") == true {
                do { inputs[screen.id] = try await ScreenMonitor.inputs(endpoint); notes[screen.id] = nil }
                catch { inputs[screen.id] = nil; notes[screen.id] = "Input status not readable: \(error.localizedDescription)" }
            } else {
                inputs[screen.id] = nil
                notes[screen.id] = "Input status: documented for VX Pro only. For \(device.models[endpoint.key] ?? "this controller") it needs a NovaLCT capture."
            }
        }
        lastRead = Date()
    }
}

struct MonitoringPage: View {
    @ObservedObject var device: NovaDevice
    @ObservedObject var workspace: ScreenWorkspace
    @ObservedObject var center: MonitorCenter

    @State private var screenID: UUID?
    @State private var hovered: String?

    private var status: [String: ScreenMonitor.Card] { screen.flatMap { center.status[$0.id] } ?? [:] }
    private var inputs: [ScreenMonitor.Input]? { screen.flatMap { center.inputs[$0.id] } }
    private var inputNote: String { screen.flatMap { center.notes[$0.id] } ?? "" }
    private var error: String? { screen.flatMap { center.errors[$0.id] } }
    private var lastRead: Date? { center.lastRead }
    private var reading: Bool { center.reading }
    private var warnTemperature: Double { center.warnTemperature }

    /// The screen picked in the menu; otherwise the first screen of the selected controller
    /// (Dashboard "Monitoring ›" selects the controller first), otherwise the first screen.
    private var screen: ScreenDocument? {
        workspace.screens.first { $0.id == screenID }
            ?? workspace.screens.first { $0.endpoint.key == device.selection.key }
            ?? workspace.screens.first
    }

    private var selectionHasScreen: Bool {
        workspace.screens.contains { $0.endpoint.key == device.selection.key }
    }

    private struct Cabinet: Identifiable {
        let port: Int, card: Int, rect: PixelRect
        var id: String { "\(port)-\(card)" }
    }

    private func cabinets(_ screen: ScreenDocument) -> [Cabinet] {
        screen.plan.cells.filter { $0.order != nil && !$0.blank }
            .map { Cabinet(port: $0.port - 1, card: $0.order! - 1, rect: screen.plan.rect(of: $0)) }
            .sorted { ($0.port, $0.card) < ($1.port, $1.card) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !selectionHasScreen {
                HStack(spacing: 8) {
                    if workspace.reading { ProgressView().controlSize(.small) }
                    Text(workspace.reading ? "Reading screens of \(device.title(for: device.selection))…"
                         : "\(device.title(for: device.selection)) has no screen yet (no receiving cards answered).")
                        .font(.callout).foregroundStyle(.orange)
                    Spacer()
                    if !workspace.reading {
                        Button("Read screens from HW") { Task { await workspace.readAll(device: device); await center.refreshAll() } }
                    }
                }
            }
            if let screen {
                alerts(screen)
                HStack(alignment: .top, spacing: 16) {
                    inputBox(screen)
                    portsBox(screen)
                }
                mapBox(screen)
                tableBox(screen)
            } else {
                GroupBox {
                    HStack {
                        Text(workspace.reading ? "Reading screens from the controllers…" : "No screens yet.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Read screens from HW") { Task { await workspace.readAll(device: device) } }.disabled(workspace.reading)
                    }.padding(6)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onAppear {
            center.attach(device: device, workspace: workspace)
            Task {
                if !selectionHasScreen && !workspace.reading { await workspace.readAll(device: device) }
                await center.refreshAll()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Screen", selection: Binding(get: { screen?.id }, set: { screenID = $0 })) {
                ForEach(workspace.screens) { s in Text("\(s.name) · \(device.title(for: s.endpoint))").tag(Optional(s.id)) }
            }
            .frame(maxWidth: 380)
            Picker("Refresh", selection: $center.interval) {
                Text("5 s").tag(5); Text("10 s").tag(10); Text("30 s").tag(30); Text("Off").tag(0)
            }
            .frame(width: 150)
            Button("Refresh now") { Task { await center.refreshAll() } }.disabled(reading || screen == nil)
            if reading { ProgressView().controlSize(.small) }
            Spacer()
            if let lastRead { Text("Updated \(lastRead.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Alerts

    @ViewBuilder
    private func alerts(_ screen: ScreenDocument) -> some View {
        let list = cabinets(screen)
        let model = device.models[screen.endpoint.key]
        let hot = list.filter { (status[$0.id]?.temperature ?? 0) >= warnTemperature }
        let silent = list.filter { status[$0.id]?.answered == false }
        if !hot.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overheating: \(hot.count) cabinet(s) at \(Int(warnTemperature)) °C or more").font(.callout.weight(.semibold))
                    Text(hot.map { c in
                        "P\(ControllerModels.portLabel(model: model, index: c.port))-\(c.card + 1) "
                            + String(format: "%.0f °C", status[c.id]?.temperature ?? 0)
                    }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                }
                Spacer()
            }
            .padding(10)
            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.7), lineWidth: 1))
        }
        if !silent.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill").font(.title2).foregroundStyle(.red)
                Text("\(silent.count) cabinet(s) not answering: " + silent.map { c in
                    "P\(ControllerModels.portLabel(model: model, index: c.port))-\(c.card + 1)"
                }.joined(separator: ", "))
                .font(.callout.weight(.semibold))
                Spacer()
            }
            .padding(10)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Input signal

    private func inputBox(_ screen: ScreenDocument) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let inputs {
                    let active = inputs.filter { $0.signal || $0.width > 0 }
                    if active.isEmpty { Text("No input reports a signal (register 0x13010001).").foregroundStyle(.red) }
                    DisclosureGroup("Raw input status") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(inputs) { input in
                                Text("\(input.index): " + input.raw.map { String(format: "%02X", $0) }.joined(separator: " "))
                                    .font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption)
                    ForEach(active) { input in
                        HStack(spacing: 8) {
                            Circle().fill(input.signal ? Color.green : Color.red).frame(width: 9, height: 9)
                            Text("Input \(input.index)").font(.callout.weight(.medium))
                            Text(input.signal ? "\(input.width) × \(input.height)\(input.interlaced ? "i" : "")"
                                 + (input.rate.map { String(format: " @ %.2f Hz", $0) } ?? "") : "no signal")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(inputNote.isEmpty ? "Reading…" : inputNote).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: { Text("Input signal").font(.headline) }
    }

    // MARK: Ports

    private func portsBox(_ screen: ScreenDocument) -> some View {
        let model = device.models[screen.endpoint.key]
        let byPort = Dictionary(grouping: cabinets(screen), by: \.port)
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(byPort.keys.sorted(), id: \.self) { p in
                    let load = screen.plan.portLoad(sender: 1, port: p + 1)
                    let share = Double(load) / Double(ScreenConnectionPlan.portCapacity)
                    let list = byPort[p] ?? []
                    let silent = list.filter { status[$0.id]?.answered == false }.count
                    HStack(spacing: 10) {
                        Text("Port \(ControllerModels.portLabel(model: model, index: p))").font(.callout.weight(.medium)).frame(width: 60, alignment: .leading)
                        ProgressView(value: min(share, 1)).tint(share > 1 ? .red : share > 0.9 ? .orange : .accentColor).frame(width: 140)
                        Text(String(format: "%.0f %%", share * 100)).font(.callout.monospacedDigit()).frame(width: 46, alignment: .trailing)
                        Text("\(load.formatted()) px · \(list.count) cards").font(.caption).foregroundStyle(.secondary)
                        if silent > 0 { Text("\(silent) not answering").font(.caption.weight(.semibold)).foregroundStyle(.red) }
                    }
                }
                Text("Load = pixels of the port's cabinets / 650 000 per port.").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: { Text("Ports").font(.headline) }
    }

    // MARK: Map

    private func color(_ c: Cabinet) -> Color {
        guard let s = status[c.id] else { return .secondary.opacity(0.25) }
        if !s.answered { return .red.opacity(0.75) }
        if let t = s.temperature, t >= warnTemperature { return .orange.opacity(0.8) }
        return .green.opacity(0.55)
    }

    private func mapBox(_ screen: ScreenDocument) -> some View {
        let list = cabinets(screen)
        let minX = list.map(\.rect.x).min() ?? 0, minY = list.map(\.rect.y).min() ?? 0
        let w = Double(max(1, (list.map(\.rect.maxX).max() ?? 1) - minX))
        let h = Double(max(1, (list.map(\.rect.maxY).max() ?? 1) - minY))
        let scale = min(900 / w, 420 / h)
        let model = device.models[screen.endpoint.key]
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    ForEach(list) { c in
                        let s = status[c.id]
                        Rectangle().fill(color(c))
                            .overlay(Rectangle().stroke(hovered == c.id ? Color.white : Color.black.opacity(0.4), lineWidth: hovered == c.id ? 2 : 1))
                            .overlay(
                                VStack(spacing: 1) {
                                    Text("P\(ControllerModels.portLabel(model: model, index: c.port))-\(c.card + 1)").font(.caption2.bold())
                                    if let t = s?.temperature {
                                        HStack(spacing: 2) {
                                            if t >= warnTemperature {
                                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                            }
                                            Text(String(format: "%.0f°", t))
                                        }
                                        .font(t >= warnTemperature ? .caption.bold() : .caption2)
                                    }
                                }
                                .foregroundStyle(.primary)
                            )
                            .frame(width: Double(c.rect.width) * scale, height: Double(c.rect.height) * scale)
                            .offset(x: Double(c.rect.x - minX) * scale, y: Double(c.rect.y - minY) * scale)
                            .onHover { hovered = $0 ? c.id : (hovered == c.id ? nil : hovered) }
                            .help(details(c, model: model))
                    }
                }
                .frame(width: w * scale, height: h * scale, alignment: .topLeading)
                HStack(spacing: 14) {
                    legend(.green.opacity(0.55), "OK")
                    legend(.orange.opacity(0.8), "≥ \(Int(warnTemperature)) °C")
                    legend(.red.opacity(0.75), "not answering")
                    legend(.secondary.opacity(0.25), "not read yet")
                    Spacer()
                    Stepper("Warn at \(Int(warnTemperature)) °C", value: $center.warnTemperature, in: 40...100, step: 5).font(.caption)
                }
            }
            .padding(6)
        } label: { Text("Cabinets").font(.headline) }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) { Rectangle().fill(color).frame(width: 12, height: 12); Text(text).font(.caption) }
    }

    private func details(_ c: Cabinet, model: String?) -> String {
        var text = "Port \(ControllerModels.portLabel(model: model, index: c.port)), card \(c.card + 1)\n"
        text += "x \(c.rect.x), y \(c.rect.y), \(c.rect.width) × \(c.rect.height)"
        if let s = status[c.id] {
            if !s.answered { text += "\nNot answering" }
            if let t = s.temperature { text += String(format: "\nTemperature %.1f °C", t) }
            if let v = s.voltage { text += String(format: "\nVoltage %.1f V", v) }
        }
        return text
    }

    // MARK: Table

    private func tableBox(_ screen: ScreenDocument) -> some View {
        let model = device.models[screen.endpoint.key]
        return GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Port-card").frame(width: 80, alignment: .leading)
                    Text("X").frame(width: 60, alignment: .trailing)
                    Text("Y").frame(width: 60, alignment: .trailing)
                    Text("Size").frame(width: 90, alignment: .trailing)
                    Text("Status").frame(width: 120, alignment: .leading).padding(.leading, 16)
                    Text("Temp.").frame(width: 90, alignment: .trailing)
                    Text("Voltage").frame(width: 70, alignment: .trailing)
                    Spacer()
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(cabinets(screen)) { c in
                            let s = status[c.id]
                            HStack {
                                Text("P\(ControllerModels.portLabel(model: model, index: c.port))-\(c.card + 1)").frame(width: 80, alignment: .leading)
                                Text("\(c.rect.x)").frame(width: 60, alignment: .trailing)
                                Text("\(c.rect.y)").frame(width: 60, alignment: .trailing)
                                Text("\(c.rect.width)×\(c.rect.height)").frame(width: 90, alignment: .trailing)
                                Group {
                                    if let s { Text(s.answered ? "OK" : "Not answering").foregroundStyle(s.answered ? Color.green : Color.red) }
                                    else { Text("—").foregroundStyle(.secondary) }
                                }
                                .frame(width: 120, alignment: .leading).padding(.leading, 16)
                                HStack(spacing: 3) {
                                    if (s?.temperature ?? 0) >= warnTemperature {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                    }
                                    Text(s?.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
                                        .foregroundStyle((s?.temperature ?? 0) >= warnTemperature ? Color.orange : Color.primary)
                                }
                                .frame(width: 90, alignment: .trailing)
                                Text(s?.voltage.map { String(format: "%.1f V", $0) } ?? "—").frame(width: 70, alignment: .trailing)
                                Spacer()
                            }
                            .font(.callout.monospacedDigit())
                            .padding(.vertical, 3)
                            .background(hovered == c.id ? Color.accentColor.opacity(0.15) : Color.clear)
                            .onHover { hovered = $0 ? c.id : (hovered == c.id ? nil : hovered) }
                        }
                    }
                }
                .frame(maxHeight: 320)
                Text("Temperature matches NovaLCT's MonitorSite. Voltage is the card's own reading (NovaLCT does not show it for these cards) — not confirmed yet.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
            }
            .padding(6)
        } label: { Text("Cabinet list").font(.headline) }
    }

}
