import SwiftUI
import Combine

// NovaMac — Dashboard: every known controller as a tile with a quick health summary.
// Polls only the controllers the user connected (Connect / Connected button), every 10 s.
//   Power   — the sending card answers its identification registers (0x00000000 / 0x00000002).
//   Cards   — receiving cards answering on each port: status register 0x0A000000 (82 bytes) of card 0, 1, 2…
//             until "no such card" (same read as Monitoring). The most cards ever seen on a port is kept as
//             the expected count, so a card that drops out shows as lost.
//   Temp.   — highest card temperature (0x0A000000 [1] / 2 °C, valid when bit 7 of [0] is set).
//   Input   — VX Pro: register 0x13010001 (protocol PDF §3.8.1; still not matching HDMI on the test unit).
//             Other models: not known yet (needs a NovaLCT capture).

nonisolated enum ControllerHealth {
    struct Scan: Sendable {
        let id: ControllerModels.ID
        let counts: [Int: Int]          // port (0-based) → cards answering
        let temperatures: [Double]
        let voltages: [Double]
    }

    static func scan(_ endpoint: NovaEndpoint, ports: [Int], limit: Int = 64) async throws -> Scan {
        try await NovaLink.run(endpoint, timeout: 1) { socket in
            let id = try ControllerModels.read(socket)
            var counts: [Int: Int] = [:]
            var temperatures: [Double] = [], voltages: [Double] = []
            for p in ports {
                var n = 0
                while n < limit, let b = CardProbe.ask(socket, 0x0A00_0000, length: 82, port: p, card: n) {
                    let d = ScreenMonitor.decode(b)
                    if let t = d.temperature { temperatures.append(t) }
                    if let v = d.voltage { voltages.append(v) }
                    n += 1
                }
                counts[p] = n
            }
            return Scan(id: id, counts: counts, temperatures: temperatures, voltages: voltages)
        }
    }
}

final class DashboardCenter: ObservableObject {
    enum Input: Equatable {
        case notRead
        case unknown(String)        // not readable for this model
        case signal(String)         // "1920 × 1080 @ 60.00 Hz"
        case noSignal
    }

    struct Health {
        var online: Bool
        var counts: [Int: Int] = [:]
        var expected: [Int: Int] = [:]
        var maxTemperature: Double?
        var minVoltage: Double?
        var input: Input = .notRead
        var updated = Date()
        var error: String?

        var cards: Int { counts.values.reduce(0, +) }
        var lost: Int { expected.reduce(0) { $0 + max(0, $1.value - (counts[$1.key] ?? 0)) } }
    }

    @Published var health: [String: Health] = [:]      // endpoint.key → last poll
    @Published var polling: Set<String> = []
    static let interval: UInt64 = 10

    private var peak: [String: [Int: Int]] = [:]
    private weak var device: NovaDevice?
    private var loop: Task<Void, Never>?

    func attach(device: NovaDevice) {
        guard self.device !== device || loop == nil else { return }
        self.device = device
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(nanoseconds: Self.interval * 1_000_000_000)
            }
        }
    }

    func refreshAll() async {
        guard let device else { return }
        device.scanUSB()
        device.identifyAll()            // retries controllers whose model is still unknown
        for key in health.keys where !device.connected.contains(key) { forget(key) }
        for key in device.connected.sorted() { await refresh(key) }
    }

    func forget(_ key: String) {
        health[key] = nil
        peak[key] = nil
    }

    func refresh(_ key: String) async {
        guard let device, device.connected.contains(key), !polling.contains(key),
              let endpoint = device.endpoint(forKey: key) else { return }
        polling.insert(key)
        defer { polling.remove(key) }
        await device.ensureModel(endpoint)
        let model = device.models[key]
        let ports = ControllerModels.physicalPorts(model: model)
            ?? Array(0..<(ControllerModels.portCount(model: model) ?? 4))
        do {
            let scan = try await ControllerHealth.scan(endpoint, ports: ports)
            guard device.connected.contains(key) else { return }
            var top = peak[key] ?? [:]
            for (p, n) in scan.counts where n > (top[p] ?? 0) { top[p] = n }
            peak[key] = top
            var h = Health(online: true, counts: scan.counts, expected: top,
                           maxTemperature: scan.temperatures.max(), minVoltage: scan.voltages.min())
            if scan.id.family == 0x622B || model?.uppercased().hasPrefix("VX") == true {
                if let list = try? await ScreenMonitor.inputs(endpoint) {
                    if let on = list.first(where: { $0.signal }) {
                        h.input = .signal("\(on.width) × \(on.height)" + (on.rate.map { String(format: " @ %.0f Hz", $0) } ?? ""))
                    } else {
                        h.input = .noSignal
                    }
                } else {
                    h.input = .unknown("Input register not readable")
                }
            } else {
                h.input = .unknown("Input status for \(model ?? "this model") needs a NovaLCT capture")
            }
            health[key] = h
        } catch {
            guard device.connected.contains(key) else { return }
            var h = health[key] ?? Health(online: false)
            h.online = false
            h.counts = [:]
            h.expected = peak[key] ?? [:]
            h.updated = Date()
            h.error = error.localizedDescription
            health[key] = h
        }
    }
}

struct DashboardPage: View {
    @ObservedObject var device: NovaDevice
    @ObservedObject var center: DashboardCenter
    var warnTemperature: Double
    var accent: Color
    var panelColor: Color
    var openMonitoring: () -> Void

    @State private var newIP = ""
    @State private var ipError = false
    @State private var naming: NovaEndpoint?
    @State private var modelName = ""
    @State private var removing: String?
    @State private var settingsIP: String?

    private var endpoints: [NovaEndpoint] {
        device.savedIPs.map { NovaEndpoint.network($0) }
            + device.usbPorts.map { NovaEndpoint.usb(path: $0, baud: device.baud(for: $0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Controllers").font(.headline)
                Text("\(device.connected.count) connected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if device.discovering { ProgressView().controlSize(.small) }
                Button {
                    Task { await device.discoverControllers() }
                } label: {
                    Label("Find controllers", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .disabled(device.discovering)
                .help("Search the Mac's local networks for NovaStar controllers (TCP 5200) and add them to the list.")
                Button {
                    device.scanUSB()
                    device.identifyAll()
                    Task { await center.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(endpoints, id: \.key) { tile($0) }
            }
            if endpoints.isEmpty {
                Text("No controllers yet. Click Find controllers, add an IP below or connect a USB sending card.")
                    .foregroundStyle(.secondary)
            }
            if !device.discoveryNote.isEmpty {
                Text(device.discoveryNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField("Add controller IP, e.g. 192.168.0.20", text: $newIP)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 320)
                    .onSubmit(addIP)
                Button("Add", action: addIP).disabled(newIP.isEmpty)
                if ipError { Text("Enter an IPv4 address (four numbers 0–255).").font(.caption).foregroundStyle(.orange) }
                Spacer()
            }
            Text("Connected controllers are polled every \(DashboardCenter.interval) s. USB sending cards appear by themselves.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .sheet(isPresented: Binding(get: { settingsIP != nil }, set: { if !$0 { settingsIP = nil } })) {
            if let ip = settingsIP { VXSettingsSheet(ip: ip, device: device) }
        }
        .alert("Name this controller model", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("e.g. MCTRL660", text: $modelName)
            Button("Save") { if let naming { device.nameModel(modelName, for: naming) }; naming = nil }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text("NovaMac does not know this model ID yet. The name is stored for every controller with the same ID.")
        }
        .alert("Remove \(removing ?? "") from the list?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let ip = removing { center.forget("ip:" + ip); device.removeIP(ip) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        }
        .onAppear { center.attach(device: device) }
        .onChange(of: device.connected) { _, _ in Task { await center.refreshAll() } }
    }

    private func isVX(_ endpoint: NovaEndpoint) -> Bool {
        device.ids[endpoint.key]?.family == 0x622B || device.models[endpoint.key]?.uppercased().hasPrefix("VX") == true
    }

    private func addIP() {
        ipError = !device.addIP(newIP)
        if !ipError { newIP = "" }
    }

    // MARK: Tile

    private func tile(_ endpoint: NovaEndpoint) -> some View {
        let key = endpoint.key
        let connected = device.isConnected(endpoint)
        let selected = device.selection.key == key
        let h = center.health[key]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: endpoint.isUSB ? "cable.connector" : "network")
                    .font(.title3)
                    .foregroundStyle(connected ? accent : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.models[key] ?? (endpoint.isUSB ? "USB sending card" : "Network controller"))
                        .font(.headline)
                    Text(address(endpoint)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if center.polling.contains(key) { ProgressView().controlSize(.small) }
                Button {
                    if connected { center.forget(key) }
                    device.toggleConnection(endpoint)
                } label: {
                    Label(connected ? "Connected" : "Connect",
                          systemImage: connected ? "checkmark.circle.fill" : "power")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(connected ? .green : accent)
                .help(connected ? "Click to disconnect (stop polling this controller)." : "Connect: select this controller and poll its status.")
            }

            HStack(spacing: 0) {
                indicator("bolt.fill", "Power", power(h, connected: connected))
                indicator("square.grid.3x3.fill", "Cards", cards(h))
                indicator("thermometer.medium", "Temp.", temperature(h))
                indicator("play.rectangle.fill", "Input", input(h))
            }

            HStack {
                if let error = h?.error, h?.online == false {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                } else if let h {
                    Text("Updated \(h.updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let why = device.identifyErrors[key] {
                    Text(why).font(.caption2).foregroundStyle(.orange).lineLimit(2).help(why)
                } else {
                    Text(connected ? "Reading…" : "Not connected").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !device.isKnownModel(endpoint) {
                    Button("Name model…") { modelName = ""; naming = endpoint }
                        .buttonStyle(.borderless).font(.caption)
                }
                if selected {
                    Text("SELECTED").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                }
                if case .network(let ip) = endpoint, isVX(endpoint) {
                    Button("Settings…") { settingsIP = ip }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Name, network (IP, mask, gateway, DHCP) and HDCP of this controller")
                }
                if case .network(let ip) = endpoint {
                    Button { removing = ip } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Remove \(ip) from the list")
                }
                if connected {
                    Button("Monitoring ›", action: { device.select(endpoint); openMonitoring() })
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .padding(16)
        .background(panelColor, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(alarm(h, connected: connected) ?? (selected ? accent.opacity(0.7) : Color.primary.opacity(0.075)),
                    lineWidth: alarm(h, connected: connected) != nil || selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { device.select(endpoint) }
    }

    private func address(_ endpoint: NovaEndpoint) -> String {
        switch endpoint {
        case .network(let ip): return ip
        case .usb(let path, _): return "USB " + (path as NSString).lastPathComponent
        }
    }

    // MARK: Indicators

    private struct Lamp {
        var color: Color
        var value: String
        var help: String
    }

    private func indicator(_ symbol: String, _ label: LocalizedStringKey, _ s: Lamp) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(s.color.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(s.color)
            }
            Text(s.value).font(.caption.monospacedDigit().weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help(s.help)
    }

    private let off = Color.gray

    private func power(_ h: DashboardCenter.Health?, connected: Bool) -> Lamp {
        guard connected, let h else { return Lamp(color: off, value: "—", help: "Not connected") }
        if !h.online { return Lamp(color: .red, value: "Offline", help: "The controller does not answer.") }
        var help = "The sending card answers."
        if let v = h.minVoltage { help += String(format: "\nLowest card voltage %.1f V (card's own reading, not confirmed).", v) }
        return Lamp(color: .green, value: "On", help: help)
    }

    private func cards(_ h: DashboardCenter.Health?) -> Lamp {
        guard let h, h.online else { return Lamp(color: off, value: "—", help: "No data") }
        let expected = h.expected.values.reduce(0, +)
        let perPort = h.counts.keys.sorted().filter { (h.counts[$0] ?? 0) > 0 || (h.expected[$0] ?? 0) > 0 }
            .map { p in "Port \(p + 1): \(h.counts[p] ?? 0)" + ((h.expected[p] ?? 0) > (h.counts[p] ?? 0) ? " of \(h.expected[p]!)" : "") }
            .joined(separator: "\n")
        if h.lost > 0 {
            return Lamp(color: .red, value: "\(h.cards)/\(expected)", help: "\(h.lost) card(s) stopped answering.\n" + perPort)
        }
        if h.cards == 0 { return Lamp(color: .orange, value: "0", help: "No receiving card answers on any port.") }
        return Lamp(color: .green, value: "\(h.cards)", help: perPort)
    }

    private func temperature(_ h: DashboardCenter.Health?) -> Lamp {
        guard let h, h.online else { return Lamp(color: off, value: "—", help: "No data") }
        guard let t = h.maxTemperature else { return Lamp(color: off, value: "—", help: "The cards report no temperature.") }
        let color: Color = t >= warnTemperature ? .orange : .green
        return Lamp(color: color, value: String(format: "%.0f °C", t),
                     help: "Hottest card. Warning at \(Int(warnTemperature)) °C (set on the Monitoring page).")
    }

    private func input(_ h: DashboardCenter.Health?) -> Lamp {
        guard let h, h.online else { return Lamp(color: off, value: "—", help: "No data") }
        switch h.input {
        case .notRead: return Lamp(color: off, value: "—", help: "Not read yet")
        case .unknown(let why): return Lamp(color: off, value: "n/a", help: why)
        case .noSignal: return Lamp(color: .red, value: "No signal",
                                     help: "Register 0x13010001 reports no signal. Not confirmed yet on VX1000 Pro (it read \"no signal\" with HDMI active).")
        case .signal(let text): return Lamp(color: .green, value: text, help: "Input signal: " + text)
        }
    }

    private func alarm(_ h: DashboardCenter.Health?, connected: Bool) -> Color? {
        guard connected, let h else { return nil }
        if !h.online || h.lost > 0 { return .red }
        if let t = h.maxTemperature, t >= warnTemperature { return .orange }
        return nil
    }
}
