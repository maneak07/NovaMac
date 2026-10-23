import SwiftUI
import Network
import Combine
enum NovaError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        }
    }
}

/// Controllers known to NovaMac and the one selected. Every page works with `selection`.
@MainActor
final class NovaDevice: ObservableObject {
    @Published var savedIPs: [String]
    @Published var usbPorts: [String] = []
    @Published private(set) var selection: NovaEndpoint
    @Published var models: [String: String] = [:]        // endpoint.key → model name
    @Published var ids: [String: ControllerModels.ID] = [:]   // endpoint.key → identification registers
    @Published var hardwareID = "—"
    @Published var status = "Not connected"
    @Published var model = "—"
    @Published var protocolValue = "—"
    @Published var capability = "—"
    @Published var maxPacket = "—"
    @Published var busy = false
    /// Why a controller's model could not be read (endpoint.key → message); cleared when it answers.
    @Published var identifyErrors: [String: String] = [:]
    private var bauds: [String: Int] = [:]               // USB path → baud the card answered at
    /// Controllers the user connected (Connect / Connected): polled by the Dashboard. Kept between launches.
    @Published private(set) var connected: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "NovaMac.connected") ?? [])

    private static let listKey = "NovaMac.controllers"
    private static let selectedKey = "NovaMac.selected"

    init() {
        var ips = UserDefaults.standard.stringArray(forKey: Self.listKey) ?? []
        if ips.isEmpty { ips = ["192.168.0.10"] }
        savedIPs = ips
        let stored = UserDefaults.standard.string(forKey: Self.selectedKey) ?? ""
        if stored.hasPrefix("usb:") {
            selection = .usb(path: String(stored.dropFirst(4)), baud: 115_200)
        } else if stored.hasPrefix("ip:") {
            selection = .network(String(stored.dropFirst(3)))
        } else {
            selection = .network(ips[0])
        }
        usbPorts = SerialPorts.list()
    }

    /// IP of the selected network controller; empty for a USB sending card.
    var ip: String { if case .network(let address) = selection { return address } else { return "" } }

    func select(_ endpoint: NovaEndpoint) {
        var target = endpoint
        if case .usb(let path, _) = endpoint { target = .usb(path: path, baud: bauds[path] ?? 115_200) }
        guard target != selection else { return }
        selection = target
        UserDefaults.standard.set(target.key, forKey: Self.selectedKey)
        model = models[target.key] ?? "—"
        hardwareID = ids[target.key]?.text ?? "—"
        protocolValue = "—"; capability = "—"; maxPacket = "—"
        status = "Selected \(target.label)"
        read()
    }

    /// Adds a controller IP (IPv4) and selects it. Returns false for an invalid address.
    @discardableResult
    func addIP(_ text: String) -> Bool {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return false }
        if !savedIPs.contains(address) {
            savedIPs.append(address)
            UserDefaults.standard.set(savedIPs, forKey: Self.listKey)
        }
        select(.network(address))
        return true
    }

    func removeIP(_ address: String) {
        guard savedIPs.count > 1 || selection.isUSB else { return }      // keep at least one entry
        savedIPs.removeAll { $0 == address }
        UserDefaults.standard.set(savedIPs, forKey: Self.listKey)
        if connected.remove("ip:" + address) != nil { UserDefaults.standard.set(Array(connected), forKey: "NovaMac.connected") }
        if selection.key == "ip:" + address {
            if let first = savedIPs.first { select(.network(first)) }
            else if let usb = usbPorts.first { select(.usb(path: usb, baud: 115_200)) }
        }
    }

    func scanUSB() { usbPorts = SerialPorts.list() }

    /// A network controller got a new IP (VX network settings): the list entry, selection and connection follow it.
    func renameIP(_ old: String, to new: String) {
        guard old != new else { return }
        let oldKey = "ip:" + old, newKey = "ip:" + new
        if let i = savedIPs.firstIndex(of: old) {
            if savedIPs.contains(new) { savedIPs.remove(at: i) } else { savedIPs[i] = new }
        } else if !savedIPs.contains(new) { savedIPs.append(new) }
        UserDefaults.standard.set(savedIPs, forKey: Self.listKey)
        if let m = models.removeValue(forKey: oldKey) { models[newKey] = m }
        if let id = ids.removeValue(forKey: oldKey) { ids[newKey] = id }
        if connected.remove(oldKey) != nil {
            connected.insert(newKey)
            UserDefaults.standard.set(Array(connected), forKey: "NovaMac.connected")
        }
        if selection.key == oldKey {
            selection = .network(new)
            UserDefaults.standard.set(newKey, forKey: Self.selectedKey)
        }
    }

    func isConnected(_ endpoint: NovaEndpoint) -> Bool { connected.contains(endpoint.key) }

    /// Connect: select the controller, read it and keep polling it. Again: disconnect (stop polling).
    func toggleConnection(_ endpoint: NovaEndpoint) {
        if connected.contains(endpoint.key) {
            connected.remove(endpoint.key)
            if endpoint.key == selection.key { status = "Disconnected from \(endpoint.label)" }
        } else {
            connected.insert(endpoint.key)
            if endpoint.key == selection.key { read() } else { select(endpoint) }
        }
        UserDefaults.standard.set(Array(connected), forKey: "NovaMac.connected")
    }

    /// Endpoint for a stored key ("ip:…" / "usb:…"), with the baud rate the USB card answered at.
    func endpoint(forKey key: String) -> NovaEndpoint? {
        if key.hasPrefix("usb:") { let path = String(key.dropFirst(4)); return .usb(path: path, baud: baud(for: path)) }
        if key.hasPrefix("ip:") { return .network(String(key.dropFirst(3))) }
        return nil
    }

    /// "MCTRL300 · usbserial-140" — model (when known) and address, for pickers and lists.
    func title(for endpoint: NovaEndpoint) -> String {
        let address: String
        switch endpoint {
        case .network(let ip): address = ip
        case .usb(let path, _): address = "USB " + (path as NSString).lastPathComponent
        }
        guard let model = models[endpoint.key] else { return address }
        return model + " · " + address
    }

    private var identifying = false

    /// Reads the model of every listed controller in the background (network ones and USB ports).
    func identifyAll() {
        guard !identifying else { return }
        identifying = true
        let targets: [NovaEndpoint] = savedIPs.map { .network($0) } + usbPorts.map { .usb(path: $0, baud: baud(for: $0)) }
        Task { @MainActor in
            defer { identifying = false }
            for target in targets where ids[target.key] == nil {
                do {
                    var link = target
                    if case .usb(let path, _) = target {
                        let found = try await SerialPorts.identify(path: path)
                        bauds[path] = found.baud
                        link = .usb(path: path, baud: found.baud)
                    }
                    remember(try await ControllerModels.identify(link), for: target.key)
                    identifyErrors[target.key] = nil
                } catch {
                    identifyErrors[target.key] = error.localizedDescription
                }
            }
        }
    }

    /// Reads the model of one controller if it is not known yet (needed before reading its layout).
    func ensureModel(_ endpoint: NovaEndpoint) async {
        guard ids[endpoint.key] == nil, let id = try? await ControllerModels.identify(endpoint) else { return }
        remember(id, for: endpoint.key)
    }

    private func remember(_ id: ControllerModels.ID, for key: String) {
        ids[key] = id
        identifyErrors[key] = nil
        // 0xFFFF = register not implemented on this model: show the other ID instead.
        let shown = id.hardware == 0xFFFF || id.hardware == 0 ? id.family : id.hardware
        models[key] = ControllerModels.name(id) ?? "NovaStar " + String(format: "%04X", shown)
    }

    /// Stores the user's name for this controller model (all controllers with the same ID get it).
    func nameModel(_ name: String, for endpoint: NovaEndpoint) {
        guard let id = ids[endpoint.key] else { return }
        ControllerModels.setName(name, for: id)
        for (key, other) in ids where other == id { remember(other, for: key) }
        if endpoint.key == selection.key { model = models[endpoint.key] ?? model }
    }

    func isKnownModel(_ endpoint: NovaEndpoint) -> Bool {
        guard let id = ids[endpoint.key] else { return true }
        return ControllerModels.name(id) != nil
    }

    /// Baud rate a USB sending card answered at (115200 until identified).
    func baud(for path: String) -> Int { bauds[path] ?? 115_200 }

    /// Reads the identification registers of the selected controller (TCP 5200 or USB).
    func read() {
        guard !busy else { return }
        busy = true
        let target = selection
        status = "Reading \(target.label)..."
        Task { @MainActor in
            defer { busy = false }
            do {
                var link = target
                if case .usb(let path, _) = target {
                    let id = try await SerialPorts.identify(path: path)      // finds the baud rate
                    bauds[path] = id.baud
                    link = .usb(path: path, baud: id.baud)
                    if selection.key == target.key { selection = link }
                }
                let registers: [(UInt32, UInt16)] = [(0x0000_0004, 2), (0x0000_0006, 1), (0x0000_0007, 2)]
                let (id, values) = try await NovaLink.run(link, timeout: 2) { socket -> (ControllerModels.ID, [[UInt8]]) in
                    let id = try ControllerModels.read(socket)
                    let values = try registers.map { try socket.transact(.read($0.0, length: $0.1)) }
                    return (id, values)
                }
                guard selection.key == target.key else { return }
                for (n, register) in registers.enumerated() { update(address: register.0, bytes: values[n], usb: link.isUSB) }
                remember(id, for: target.key)
                model = models[target.key] ?? "—"
                hardwareID = id.text
                status = "Connected — \(model)"
            } catch {
                guard selection.key == target.key else { return }
                status = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func update(address: UInt32, bytes: [UInt8], usb: Bool) {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        var value = 0
        if let low = bytes.first { value = Int(low) }
        if bytes.count >= 2 { value += Int(bytes[1]) * 256 }
        switch address {
        case 0x0000_0004: protocolValue = hex
        case 0x0000_0006: capability = hex
        case 0x0000_0007: maxPacket = "\(value) bytes"
        default: break
        }
    }
}

    struct ContentView: View {
        @StateObject private var device = NovaDevice()
        @StateObject private var screens = ScreenWorkspace()
        @StateObject private var agentAPI = AgentAPI()
        @StateObject private var monitor = MonitorCenter()
        @StateObject private var dashboard = DashboardCenter()
        @State private var page: Page = .dashboard
        @State private var events: [String] = []
        @State private var newIP = ""
        @State private var ipError = false
        @State private var naming: NovaEndpoint?
        @State private var modelName = ""

        @AppStorage("NovaMac.theme") private var theme = AppTheme.system.rawValue
        @AppStorage("NovaMac.language") private var language = AppLanguage.system.rawValue
        @State private var showSettings = false

        private let accent = Color(red: 0.25, green: 0.43, blue: 0.95)
        // Light / dark pairs; the dark values are the original NovaMac palette.
        private let canvas = Color.adaptive(light: NSColor(red: 0.945, green: 0.95, blue: 0.965, alpha: 1),
                                            dark: NSColor(red: 0.075, green: 0.09, blue: 0.12, alpha: 1))
        private let sidebarColor = Color.adaptive(light: NSColor(red: 0.905, green: 0.915, blue: 0.935, alpha: 1),
                                                  dark: NSColor(red: 0.105, green: 0.12, blue: 0.155, alpha: 1))
        private let panelColor = Color.adaptive(light: NSColor.white,
                                                dark: NSColor(red: 0.135, green: 0.155, blue: 0.19, alpha: 1))

        private enum Page: String {
            case dashboard = "Dashboard"
            case receiving = "Receiving Cards"
            case connection = "Screen Connection"
            case brightness = "Brightness"
            case calibration = "Calibration"
            case monitoring = "Monitoring"
            case diagnostics = "Diagnostics"
            case agentAPI = "Agent API"

            var symbol: String {
                switch self {
                case .dashboard: return "square.grid.2x2"
                case .receiving: return "cpu"
                case .connection: return "point.3.connected.trianglepath.dotted"
                case .brightness: return "sun.max"
                case .calibration: return "slider.horizontal.3"
                case .monitoring: return "gauge.with.dots.needle.33percent"
                case .diagnostics: return "waveform.path.ecg"
                case .agentAPI: return "cpu.fill"
                }
            }
        }

        private var readSucceeded: Bool {
            device.status.hasPrefix("Connected") && device.isConnected(device.selection)
        }

        /// Connect / Connected toggle for the selected controller (replaces "Read Device").
        private var connectButton: some View {
            let on = device.isConnected(device.selection)
            return Button {
                if on { dashboard.forget(device.selection.key) }
                device.toggleConnection(device.selection)
            } label: {
                Label(on ? "Connected" : "Connect", systemImage: on ? "checkmark.circle.fill" : "power")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(on ? .green : accent)
            .disabled(device.busy)
            .help(on ? "Click to disconnect (stop polling this controller)." : "Connect to the selected controller and poll its status.")
        }

        var body: some View {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 235)

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)

                VStack(spacing: 0) {
                    topBar

                    Divider()
                        .overlay(Color.primary.opacity(0.07))

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            pageContent
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    bottomBar
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 1050, minHeight: 690)
            .background(canvas)
            .preferredColorScheme(AppTheme(rawValue: theme)?.scheme)
            .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? .current)
            .tint(accent)
            .onReceive(device.$status.removeDuplicates()) { status in
                guard status != "Not connected" else { return }
                let time = Date.now.formatted(
                    date: .omitted,
                    time: .standard
                )
                events.insert("\(time)  \(status)", at: 0)
                if events.count > 100 {
                    events.removeLast()
                }
            }
        }

        // MARK: - Sidebar

        private var sidebar: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(accent)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("NovaMac")
                            .font(.title3.bold())

                        Text("LED Configuration")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 24)

                sectionLabel("WORKSPACE")
                menuItem(.dashboard)

                sectionLabel("CONFIGURATION")
                    .padding(.top, 18)
                menuItem(.connection)
                menuItem(.receiving)
                menuItem(.brightness)
                menuItem(.calibration)

                sectionLabel("SERVICE")
                    .padding(.top, 18)
                menuItem(.monitoring)
                menuItem(.diagnostics)
                menuItem(.agentAPI)

                Spacer()

                Divider()

                HStack(spacing: 8) {
                    Circle()
                        .fill(readSucceeded ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(readSucceeded ? "Connected" : "Not connected")
                            .font(.caption.weight(.medium))
                        Text(device.title(for: device.selection))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 12)

                Text("NovaMac 0.2  •  Read-only")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            .background(sidebarColor)
        }

        private func sectionLabel(_ title: LocalizedStringKey) -> some View {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
        }

        private func menuItem(_ item: Page) -> some View {
            Button {
                page = item
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 15))
                        .frame(width: 22)

                    Text(LocalizedStringKey(item.rawValue))
                        .font(.system(size: 13, weight: .medium))

                    Spacer()
                    if item == .monitoring { monitorBadge }
                }
                .foregroundStyle(
                    page == item ? Color.primary : Color.primary.opacity(0.7)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    page == item ? accent.opacity(0.24) : menuAlarm(item).opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(menuAlarm(item).opacity(0.8), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }

        /// Red when a cabinet does not answer, yellow when one overheats (Monitoring only).
        private func menuAlarm(_ item: Page) -> Color {
            guard item == .monitoring else { return .clear }
            if monitor.silentCount > 0 { return .red }
            if monitor.hotCount > 0 { return .yellow }
            return .clear
        }

        @ViewBuilder
        private var monitorBadge: some View {
            let hot = monitor.hotCount, silent = monitor.silentCount
            if hot > 0 || silent > 0 {
                HStack(spacing: 4) {
                    if hot > 0 {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("\(hot)").foregroundStyle(.yellow)
                    }
                    if silent > 0 {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text("\(silent)").foregroundStyle(.red)
                    }
                }
                .font(.system(size: 12, weight: .bold))
                .help("\(hot) cabinet(s) overheating, \(silent) not answering")
            }
        }

        // MARK: - Header

        private var topBar: some View {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(page.rawValue))
                        .font(.title2.bold())

                    Text("NovaStar Engineering Workspace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsPopover(theme: $theme, language: $language)
                }
                .padding(.trailing, 8)

                Label("TEST MODE", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color.green.opacity(0.10),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 17)
        }

        // MARK: - Pages

        @ViewBuilder
        private var pageContent: some View {
            switch page {
            case .dashboard:
                dashboardPage
            case .monitoring:
                MonitoringPage(device: device, workspace: screens, center: monitor)
            case .agentAPI:
                AgentAPIPage(api: agentAPI)
            case .diagnostics:
                diagnosticsPage
            case .connection:
                ScreenWorkspaceView(workspace: screens, device: device)
            case .receiving:
                ReceivingCardPage(device: device)
            case .brightness:
                BrightnessPage(device: device, workspace: screens)
            case .calibration:
                CalibrationPage(device: device, workspace: screens)
            }
        }

        private var dashboardPage: some View {
            VStack(alignment: .leading, spacing: 18) {
                DashboardPage(device: device, center: dashboard, warnTemperature: monitor.warnTemperature,
                              accent: accent, panelColor: panelColor, openMonitoring: { page = .monitoring })

                HStack(alignment: .top, spacing: 18) {
                    devicePanel

                    panel {
                        Label("Configuration Tools",
                              systemImage: "square.grid.2x2")
                            .font(.headline)

                        Text("Engineering modules")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        toolRow("Screen Connection",
                                symbol: "point.3.connected.trianglepath.dotted",
                                destination: .connection)
                        toolRow("Receiving Cards",
                                symbol: "cpu",
                                destination: .receiving)
                        toolRow("Calibration",
                                symbol: "slider.horizontal.3",
                                destination: .calibration)
                        toolRow("Diagnostics",
                                symbol: "waveform.path.ecg",
                                destination: .diagnostics)
                    }
                    .frame(width: 290)
                }
            }
            .onAppear {
                device.scanUSB(); device.identifyAll()
                agentAPI.attach(device: device, workspace: screens)
                monitor.attach(device: device, workspace: screens)
                dashboard.attach(device: device)
            }
        }

        // MARK: - Connection

        private var connectionPanel: some View {
            panel {
                HStack {
                    Label("Controller Connection",
                          systemImage: "network")
                        .font(.headline)

                    Spacer()

                    if device.busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 12) {
                    Label(device.title(for: device.selection), systemImage: device.selection.isUSB ? "cable.connector" : "network")
                        .font(.system(.body, design: .monospaced))

                    Spacer()


                    connectButton
                }

                HStack(spacing: 8) {
                    Image(systemName:
                        readSucceeded ? "checkmark.circle.fill" :
                        device.status.hasPrefix("Error")
                        ? "exclamationmark.triangle.fill" : "circle.dotted"
                    )
                    .foregroundStyle(
                        readSucceeded ? Color.green :
                        device.status.hasPrefix("Error")
                        ? Color.orange : Color.gray
                    )

                    Text(device.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text(device.selection.isUSB ? "Reads over the USB-serial port (8N1)." : "Each read uses a temporary TCP connection on port 5200.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }

        // MARK: - Controllers (selection used by every page)

        private var controllersPanel: some View {
            panel {
                HStack {
                    Label("Controllers", systemImage: "network")
                        .font(.headline)
                    Spacer()
                    if device.busy { ProgressView().controlSize(.small) }
                    connectButton
                }

                Text("Click a controller to select it. All pages work with the selected controller only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                sectionLabel("NETWORK")
                ForEach(device.savedIPs, id: \.self) { address in
                    controllerRow(.network(address), title: address,
                                  subtitle: "Network controller · TCP 5200 / web API", removable: true)
                }
                HStack(spacing: 10) {
                    TextField("Add controller IP, e.g. 192.168.0.20", text: $newIP)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addIP)
                    Button("Add", action: addIP)
                        .disabled(newIP.isEmpty)
                }
                if ipError {
                    Text("Enter an IPv4 address (four numbers 0–255).")
                        .font(.caption).foregroundStyle(.orange)
                }

                HStack {
                    sectionLabel("USB")
                    Spacer()
                    Button {
                        device.scanUSB()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Rescan USB-serial ports")
                }
                .padding(.top, 6)
                if device.usbPorts.isEmpty {
                    Text("No USB sending cards found. Connect one (MCTRL300…) and rescan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(device.usbPorts, id: \.self) { path in
                    controllerRow(.usb(path: path, baud: 115_200), title: (path as NSString).lastPathComponent,
                                  subtitle: "USB sending card", removable: false)
                }
                if device.selection.isUSB, case .usb(let path, _) = device.selection, !device.usbPorts.contains(path) {
                    Text("Selected USB port \((path as NSString).lastPathComponent) is not present now.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .onAppear { device.scanUSB(); device.identifyAll(); agentAPI.attach(device: device, workspace: screens); monitor.attach(device: device, workspace: screens) }
            .alert("Name this controller model", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("e.g. MCTRL660", text: $modelName)
                Button("Save") { if let naming { device.nameModel(modelName, for: naming) }; naming = nil }
                Button("Cancel", role: .cancel) { naming = nil }
            } message: {
                Text("NovaMac does not know this model ID yet. The name is stored for every controller with the same ID.")
            }
        }

        private func addIP() {
            ipError = !device.addIP(newIP)
            if !ipError { newIP = "" }
        }

        private func controllerRow(_ endpoint: NovaEndpoint, title: String, subtitle: String, removable: Bool) -> some View {
            let isSelected = device.selection.key == endpoint.key
            return HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? accent : Color.secondary)
                Image(systemName: endpoint.isUSB ? "cable.connector" : "network")
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .monospaced))
                    Text(device.models[endpoint.key] ?? subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !device.isKnownModel(endpoint) {
                    Button("Name model…") { modelName = ""; naming = endpoint }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                if isSelected {
                    Text("SELECTED")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                }
                if removable {
                    Button {
                        device.removeIP(title)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from the list")
                }
            }
            .padding(10)
            .background(isSelected ? accent.opacity(0.2) : Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
            .onTapGesture { device.select(endpoint) }
        }

        /// Pages built on the controller's web API (Unico, port 19999) need a network controller.
        @ViewBuilder
        private func webAPIOnly<V: View>(@ViewBuilder _ content: (String) -> V) -> some View {
            if case .network(let address) = device.selection {
                content(address)
                    .id(address)
            } else {
                placeholder(
                    page.rawValue,
                    "This page works through the controller's web interface (VX Pro, COEX). The selected controller is \(device.selection.label), a USB sending card without one. Select a network controller on the Dashboard.",
                    badge: "NEEDS A NETWORK CONTROLLER"
                )
            }
        }

        // MARK: - Device Details

        private var devicePanel: some View {
            panel {
                HStack {
                    Label("Controller Information",
                          systemImage: "cpu")
                        .font(.headline)

                    Spacer()

                    Text("LIVE READ")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(readSucceeded ? .green : .gray)
                }

                Divider()

                field("Model", device.model)
                field("Controller", device.selection.label)
                field("Hardware ID", device.hardwareID)
                field("Transport", device.selection.isUSB ? "USB-serial 8N1" : "TCP 5200")
                field("Protocol raw", device.protocolValue)
                field("Packet marker", device.capability)
                field("Max packet", device.maxPacket)

                Divider()

                HStack {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.green)

                    Text("Register reads only. No configuration writes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        private func field(_ label: String, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 10)

                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .font(.system(size: 13))
            .padding(.vertical, 5)
        }

        // MARK: - Diagnostics

        private var diagnosticsPage: some View {
            VStack(alignment: .leading, spacing: 18) {
                devicePanel

                panel {
                    Label("Register dump (read only)", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                    SenderDumpView(endpoint: device.selection,
                                   ports: ControllerModels.portCount(model: device.models[device.selection.key]) ?? 32)
                        .id(device.selection.key)
                }

                panel {
                    Label("Application Events",
                          systemImage: "terminal")
                        .font(.headline)

                    Text("Status changes recorded during this session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    if events.isEmpty {
                        Text("No activity recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(events.indices, id: \.self) { index in
                            Text(events[index])
                                .font(.system(size: 12,
                                              design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity,
                                       alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }

        // MARK: - Components

        private func toolRow(
            _ title: String,
            symbol: String,
            destination: Page
        ) -> some View {
            Button {
                page = destination
            } label: {
                HStack {
                    Image(systemName: symbol)
                        .frame(width: 22)
                        .foregroundStyle(accent)

                    Text(title)
                        .font(.system(size: 12))

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }

        private func placeholder(
            _ title: String,
            _ description: String,
            badge: String = "MODULE NOT IMPLEMENTED"
        ) -> some View {
            panel {
                VStack(alignment: .center, spacing: 16) {
                    Image(systemName: page.symbol)
                        .font(.system(size: 38))
                        .foregroundStyle(accent)
                        .padding(.top, 35)

                    Text(title)
                        .font(.title2.bold())

                    Text(description)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.top, 10)
                        .padding(.bottom, 35)
                }
                .frame(maxWidth: .infinity)
            }
        }

        private func panel<Content: View>(
            @ViewBuilder content: () -> Content
        ) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                panelColor,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.075))
            }
        }

        private var bottomBar: some View {
            HStack {
                Text("NovaMac 0.2")
                Spacer()
                Text("TCP 5200  •  NovaStar Protocol  •  TEST MODE")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(sidebarColor)
        }
    }

