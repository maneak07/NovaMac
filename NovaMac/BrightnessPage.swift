import SwiftUI
import Combine

/// Brightness page: pick one, several or all screens (from Screen Connection) and set their brightness.
/// Uses NovaStar's documented register command, the same on VX Pro (TCP 5200) and MCTRL (USB).
struct BrightnessPage: View {
    @ObservedObject var device: NovaDevice
    @ObservedObject var workspace: ScreenWorkspace

    @State private var selected: Set<UUID> = []
    @State private var percent: Double = 100
    @State private var pending: Int?
    @State private var sending = false
    @State private var status = ""
    @State private var error: String?
    @State private var started = false
    @State private var gamma = 28
    @State private var originals: [String: (gamma: Int, table: [UInt8])] = [:]   // per controller, as first read
    @State private var red: Double = 255
    @State private var green: Double = 255
    @State private var blue: Double = 255
    @State private var pendingColor: (Int, Int, Int)?
    @State private var sendingColor = false

    private var chosen: [ScreenDocument] { workspace.screens.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            screensBox
            brightnessBox
            colorBox
            if !testTargets.isEmpty {
                ReceiverTestBox(targets: testTargets, title: { device.title(for: $0) })
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if case .network(let ip) = chosen.first?.endpoint ?? device.selection {
                DisclosureGroup("Test patterns, freeze, black screen (web interface of \(ip))") {
                    UnicoBrightnessView(ip: ip).id(ip)
                }
                .font(.callout)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            if workspace.screens.isEmpty {
                // Show the controller's current values right away; the screen list follows when the cards are read.
                Task {
                    await loadCurrent(fallback: device.selection)
                    await workspace.readAll(device: device)
                    selectDefault()
                }
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

    /// Controllers for the register test patterns (MCTRL…; VX Pro uses its web interface below):
    /// the chosen screens' controllers, or the selected controller when no screen is chosen.
    private var testTargets: [(NovaEndpoint, [Int]?)] {
        let list: [(NovaEndpoint, [Int]?)] = targets.isEmpty ? [(device.selection, nil)] : targets
        return list.filter { !(device.models[$0.0.key]?.uppercased().hasPrefix("VX") ?? false) }
    }

    /// Controllers to address and their ports. A controller whose every screen is chosen gets one broadcast;
    /// otherwise only the ports of the chosen screens.
    private var targets: [(NovaEndpoint, [Int]?)] {
        var result: [(NovaEndpoint, [Int]?)] = []
        var seen = Set<String>()
        for screen in chosen where seen.insert(screen.endpoint.key).inserted {
            let all = workspace.screens.filter { $0.endpoint.key == screen.endpoint.key }
            if all.allSatisfy({ selected.contains($0.id) }) {
                result.append((screen.endpoint, nil))
            } else {
                let p = Set(chosen.filter { $0.endpoint.key == screen.endpoint.key }.flatMap { ports(of: $0) })
                result.append((screen.endpoint, p.sorted()))
            }
        }
        return result
    }

    // MARK: Brightness

    private var brightnessBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(percent.rounded())) %")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("(\(byteValue) / 255)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if sending { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { percent }, set: { percent = $0; apply() }), in: 0...100, step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "sun.min")
                } maximumValueLabel: {
                    Image(systemName: "sun.max.fill")
                }
                HStack {
                    ForEach([0, 10, 25, 50, 75, 100], id: \.self) { p in
                        Button("\(p) %") { percent = Double(p); apply() }
                    }
                    Spacer()
                    Button("Read current") { readCurrent() }
                }
            }
            .disabled(chosen.isEmpty)
            .padding(6)
        } label: {
            Text("Brightness").font(.headline)
        }
    }

    // MARK: Gamma and colour

    private var colorBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Gamma").frame(width: 60, alignment: .leading)
                    Slider(value: Binding(get: { Double(gamma) }, set: { gamma = Int($0.rounded()) }), in: 10...40, step: 1) {
                        EmptyView()
                    } onEditingChanged: { editing in
                        if !editing { setGamma(gamma) }
                    }
                    Text(String(format: "%.1f", Double(gamma) / 10))
                        .font(.callout.monospaced()).frame(width: 36, alignment: .trailing)
                    Stepper("", value: Binding(get: { gamma }, set: { gamma = $0; setGamma($0) }), in: 10...40)
                        .labelsHidden()
                    Button("Restore") { restoreGamma() }
                        .disabled(originals.isEmpty)
                        .help("Put back the gamma table the cards had when this page first read them")
                }
                colorSlider("Red", value: $red, tint: .red)
                colorSlider("Green", value: $green, tint: .green)
                colorSlider("Blue", value: $blue, tint: .blue)
                HStack {
                    Button("White balance 255 / 255 / 255") { red = 255; green = 255; blue = 255; applyColor() }
                    Spacer()
                    Text("Contrast: not a receiving-card setting on MCTRL300 (NovaLCT has none).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(chosen.isEmpty)
            .padding(6)
        } label: {
            Text("Gamma · Color").font(.headline)
        }
    }

    private func colorSlider(_ title: String, value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; applyColor() }), in: 0...255, step: 1)
                .tint(tint)
            Text("\(Int(value.wrappedValue))").font(.callout.monospaced()).frame(width: 36, alignment: .trailing)
        }
    }

    /// Standard gamma table scaled to each card's own table top (read first), then sent with the gamma value.
    private func setGamma(_ value: Int) {
        let jobs = targets
        Task { @MainActor in
            var failed: [String] = []
            for (endpoint, ports) in jobs {
                do {
                    let port = ports?.first ?? firstPort(of: endpoint)
                    let now = try await ScreenPicture.read(endpoint, port: port)
                    if originals[endpoint.key] == nil, now.table.count == 512 { originals[endpoint.key] = (now.gamma, now.table) }
                    guard let top = now.gammaTop else {
                        failed.append(device.title(for: endpoint) + ": the card's gamma table could not be read — not changed"); continue
                    }
                    let table = ScreenPicture.gammaTable(gamma: Double(value) / 10, top: top)
                    try await ScreenPicture.setGamma(endpoint, gamma: value, table: table, ports: ports)
                } catch { failed.append(device.title(for: endpoint) + ": " + error.localizedDescription) }
            }
            error = failed.isEmpty ? nil : failed.joined(separator: "\n")
            status = failed.isEmpty ? String(format: "Gamma %.1f set", Double(value) / 10) : "Gamma not set everywhere"
        }
    }

    private func restoreGamma() {
        let jobs = targets
        Task { @MainActor in
            var failed: [String] = []
            for (endpoint, ports) in jobs {
                guard let original = originals[endpoint.key] else { continue }
                do { try await ScreenPicture.setGamma(endpoint, gamma: original.gamma, table: original.table, ports: ports) }
                catch { failed.append(device.title(for: endpoint) + ": " + error.localizedDescription) }
            }
            error = failed.isEmpty ? nil : failed.joined(separator: "\n")
            status = failed.isEmpty ? "Gamma restored" : "Gamma not restored everywhere"
            readCurrent()
        }
    }

    private func firstPort(of endpoint: NovaEndpoint) -> Int {
        chosen.filter { $0.endpoint.key == endpoint.key }.flatMap { ports(of: $0) }.min() ?? 0
    }

    private func applyColor() {
        pendingColor = (Int(red), Int(green), Int(blue))
        guard !sendingColor else { return }
        Task { @MainActor in
            sendingColor = true
            defer { sendingColor = false }
            while let color = pendingColor {
                pendingColor = nil
                let (r, g, b) = color
                var failed: [String] = []
                for (endpoint, ports) in targets {
                    do { try await ScreenPicture.setColor(endpoint, red: r, green: g, blue: b, ports: ports) }
                    catch { failed.append(device.title(for: endpoint) + ": " + error.localizedDescription) }
                }
                error = failed.isEmpty ? nil : failed.joined(separator: "\n")
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private var byteValue: Int { Int((percent * 255 / 100).rounded()) }

    /// Sends the latest value; while the slider moves, at most one update every 100 ms goes out.
    private func apply() {
        pending = byteValue
        guard !sending else { return }
        Task { @MainActor in
            sending = true
            defer { sending = false }
            while let value = pending {
                pending = nil
                var failed: [String] = []
                for (endpoint, ports) in targets {
                    do { try await ScreenBrightness.set(endpoint, value: value, ports: ports) }
                    catch { failed.append(device.title(for: endpoint) + ": " + error.localizedDescription) }
                }
                error = failed.isEmpty ? nil : failed.joined(separator: "\n")
                status = failed.isEmpty ? "Set on \(chosen.count) screen(s)" : "Some screens did not answer"
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Shows the brightness of the first chosen screen.
    private func readCurrent() { Task { @MainActor in await loadCurrent() } }

    private func loadCurrent(fallback: NovaEndpoint? = nil) async {
        // The selected controller's screen first (Dashboard / Controllers choice), then the other chosen screens.
        let ordered = chosen.filter { $0.endpoint.key == device.selection.key } + chosen.filter { $0.endpoint.key != device.selection.key }
        let screen = ordered.first
        guard let endpoint = screen?.endpoint ?? fallback else { return }
        let port = screen.map { ports(of: $0).first ?? 0 } ?? 0
        let name = screen?.name ?? device.title(for: endpoint)
        do {
                let now = try await ScreenPicture.read(endpoint, port: port)
                if originals[endpoint.key] == nil, now.gammaTop != nil { originals[endpoint.key] = (now.gamma, now.table) }
                percent = (Double(now.brightness) * 100 / 255).rounded()
                gamma = now.gamma
                red = Double(now.red); green = Double(now.green); blue = Double(now.blue)
                status = "\(name): \(Int(percent)) %, gamma " + String(format: "%.1f", Double(now.gamma) / 10)
                error = nil
        } catch NovaLinkError.nack {
            // The controller answers, but no receiving card does on that port (cabinets off, cable out, old layout).
            let label = ControllerModels.portLabel(model: device.models[endpoint.key], index: port)
            self.error = "\(name) (\(device.title(for: endpoint))): the controller answers, but no receiving card answers on port \(label) — are the cabinets powered and connected?"
        } catch { self.error = "Read \(name) (\(device.title(for: endpoint))): \(error.localizedDescription)" }
    }
}
