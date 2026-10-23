import SwiftUI
import Combine

// NovaMac — Screen Connection with several screens (up to 10, like NovaLCT).
// Each screen keeps its own layout, hardware read and controller; switching tabs or pages keeps them.

@MainActor
final class ScreenDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var number: Int
    @Published var endpoint: NovaEndpoint

    // Layout and the last reads (kept while switching screens/pages).
    @Published var plan = ScreenConnectionPlan.empty()
    @Published var columns = 4
    @Published var rows = 1
    @Published var sender = 1
    @Published var port = 1
    @Published var width = 160
    @Published var height = 360
    @Published var zoom = 0.5
    @Published var canvasPreset = 0
    @Published var hideDetails = false
    @Published var connecting = true
    @Published var gridStep = 40
    @Published var magnet = true
    @Published var snapToGrid = true
    @Published var transport = 0            // 0 auto, 1 REST (Unico), 2 register TCP 5200
    @Published var history: [ScreenConnectionPlan] = []
    @Published var cards: [ReceivingCard] = []
    @Published var usbCards: [RegisterInventory.Card] = []
    @Published var answering: [Int: Int] = [:]
    @Published var hardware: UnicoTopology.Snapshot?
    @Published var status = "Local connection plan. Load a plan or arrange the cards; changes are not sent to the controller."

    init(number: Int, endpoint: NovaEndpoint) {
        self.number = number
        self.endpoint = endpoint
    }

    /// Name of the screen on the controller (from Read from HW), shown with the tab.
    @Published var hardwareName = ""

    var name: String { "Screen \(number)" }
}

@MainActor
final class ScreenWorkspace: ObservableObject {
    static let maxScreens = 10
    @Published var screens: [ScreenDocument] = []
    @Published var currentID: UUID?

    var current: ScreenDocument? { screens.first { $0.id == currentID } ?? screens.first }

    func ensureFirst(endpoint: NovaEndpoint) {
        guard screens.isEmpty else { return }
        let first = ScreenDocument(number: 1, endpoint: endpoint)
        screens = [first]
        currentID = first.id
    }

    func add(endpoint: NovaEndpoint) {
        guard screens.count < Self.maxScreens else { return }
        let screen = ScreenDocument(number: (screens.map(\.number).max() ?? 0) + 1, endpoint: endpoint)
        screens.append(screen)
        currentID = screen.id
    }

    @Published var reading = false
    @Published var readStatus = ""

    /// Reads what the hardware actually has: every LED screen of every listed controller (network: the
    /// controller's screens and their cabinet mapping; USB: the cards answering on the sending card).
    /// Replaces the tabs with one tab per screen found. Controllers that do not answer are skipped.
    func readAll(device: NovaDevice) async {
        guard !reading else { return }
        reading = true
        readStatus = "Reading screens from the controllers…"
        defer { reading = false }
        var found: [ScreenDocument] = []
        var notes: [String] = []
        for ip in device.savedIPs {
            guard let snapshots = try? await UnicoTopology.readAllScreens(ip: ip) else {
                // No web interface (MEE410, MCTRL over Ethernet…): read the cards over the register protocol.
                let endpoint = NovaEndpoint.network(ip)
                await device.ensureModel(endpoint)
                let ports = ControllerModels.portCount(model: device.models[endpoint.key]) ?? 32
                let cards: [RegisterInventory.Card]
                let plan: ScreenConnectionPlan
                do {
                    cards = try await RegisterInventory.read(endpoint, ports: ports, model: device.models[endpoint.key])
                    guard !cards.isEmpty else { notes.append("\(ip): no receiving cards answer"); continue }
                    plan = try RegisterInventory.plan(cards, defaultSize: (160, 360))
                } catch {
                    notes.append("\(ip): \(error.localizedDescription)"); continue
                }
                let doc = ScreenDocument(number: found.count + 1, endpoint: endpoint)
                doc.hardwareName = device.models[endpoint.key] ?? "sending card"
                doc.plan = plan; doc.columns = plan.columns; doc.rows = plan.rows
                if let p = plan.cells.first(where: { $0.order != nil })?.port { doc.port = p }
                doc.usbCards = cards
                doc.status = "Read from HW: \(cards.count) cards (register protocol)."
                if found.count < Self.maxScreens { found.append(doc) }
                continue
            }
            for snapshot in snapshots where found.count < Self.maxScreens {
                let doc = ScreenDocument(number: found.count + 1, endpoint: .network(ip))
                doc.hardware = snapshot
                doc.hardwareName = snapshot.name
                doc.plan = snapshot.plan; doc.columns = snapshot.plan.columns; doc.rows = snapshot.plan.rows
                if let p = snapshot.plan.cells.first(where: { $0.order != nil })?.port { doc.port = p }
                let shown = snapshot.plan.cells.filter { $0.order != nil }.count
                let stale = snapshot.cabinets.count - shown
                doc.status = "Read from HW: \(snapshot.name), \(shown) cards."
                    + (stale > 0 ? " \(stale) leftover cabinet(s) of an older layout (offline, under other cabinets) left out." : "")
                found.append(doc)
            }
        }
        for path in device.usbPorts where found.count < Self.maxScreens {
            guard let id = try? await SerialPorts.identify(path: path) else { notes.append("USB \((path as NSString).lastPathComponent): no answer"); continue }
            let endpoint = NovaEndpoint.usb(path: path, baud: id.baud)
            await device.ensureModel(endpoint)
            let portCount = ControllerModels.portCount(model: device.models[endpoint.key]) ?? 32
            guard let cards = try? await RegisterInventory.read(endpoint, ports: portCount, model: device.models[endpoint.key]), !cards.isEmpty,
                  let plan = try? RegisterInventory.plan(cards, defaultSize: (160, 360)) else { continue }
            let doc = ScreenDocument(number: found.count + 1, endpoint: endpoint)
            doc.hardwareName = device.models[endpoint.key] ?? "USB sending card"
            doc.plan = plan; doc.columns = plan.columns; doc.rows = plan.rows
            if let p = plan.cells.first(where: { $0.order != nil })?.port { doc.port = p }
            doc.usbCards = cards
            doc.status = "Read from HW: \(cards.count) cards on the USB sending card."
            found.append(doc)
        }
        guard !found.isEmpty else {
            readStatus = "No screen with mapped cards found" + (notes.isEmpty ? "." : " (" + notes.joined(separator: ", ") + ").")
            return
        }
        screens = found
        currentID = found.first?.id
        readStatus = "\(found.count) screen(s) read from the hardware" + (notes.isEmpty ? "." : " · " + notes.joined(separator: ", "))
    }

    /// Reads the screens of one controller only and puts them in place of that controller's tabs
    /// (other controllers' tabs, and their unsaved layouts, stay as they are). Used by Monitoring.
    func read(_ endpoint: NovaEndpoint, device: NovaDevice) async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        var found: [ScreenDocument] = []
        var target = endpoint
        if case .usb(let path, _) = endpoint {
            guard let id = try? await SerialPorts.identify(path: path) else {
                readStatus = "USB \((path as NSString).lastPathComponent): no answer"; return
            }
            target = .usb(path: path, baud: id.baud)
        }
        if case .network(let ip) = target, let snapshots = try? await UnicoTopology.readAllScreens(ip: ip) {
            for snapshot in snapshots {
                let doc = ScreenDocument(number: 0, endpoint: target)
                doc.hardware = snapshot
                doc.hardwareName = snapshot.name
                doc.plan = snapshot.plan; doc.columns = snapshot.plan.columns; doc.rows = snapshot.plan.rows
                if let p = snapshot.plan.cells.first(where: { $0.order != nil })?.port { doc.port = p }
                doc.status = "Read from HW: \(snapshot.name), \(snapshot.plan.cells.filter { $0.order != nil }.count) cards."
                found.append(doc)
            }
        } else {
            await device.ensureModel(target)
            let model = device.models[target.key]
            let ports = ControllerModels.portCount(model: model) ?? 32
            guard let cards = try? await RegisterInventory.read(target, ports: ports, model: model), !cards.isEmpty,
                  let plan = try? RegisterInventory.plan(cards, defaultSize: (160, 360)) else {
                readStatus = "\(device.title(for: target)): no receiving cards answer"; return
            }
            let doc = ScreenDocument(number: 0, endpoint: target)
            doc.hardwareName = model ?? (target.isUSB ? "USB sending card" : "sending card")
            doc.plan = plan; doc.columns = plan.columns; doc.rows = plan.rows
            if let p = plan.cells.first(where: { $0.order != nil })?.port { doc.port = p }
            doc.usbCards = cards
            doc.status = "Read from HW: \(cards.count) cards (register protocol)."
            found.append(doc)
        }
        guard !found.isEmpty else { readStatus = "\(device.title(for: target)): no screens"; return }
        var list = screens.filter { $0.endpoint.key != target.key }
        for doc in found where list.count < Self.maxScreens {
            doc.number = (list.map(\.number).max() ?? 0) + 1
            list.append(doc)
        }
        screens = list
        readStatus = "\(found.count) screen(s) of \(device.title(for: target)) read from the hardware."
    }

    /// Every controller used by the tabs, once.
    var endpoints: [NovaEndpoint] {
        var seen = Set<String>()
        return screens.map(\.endpoint).filter { seen.insert($0.key).inserted }
    }

    func remove(_ screen: ScreenDocument) {
        guard screens.count > 1, let index = screens.firstIndex(where: { $0.id == screen.id }) else { return }
        screens.remove(at: index)
        if currentID == screen.id { currentID = screens[max(0, index - 1)].id }
        for (n, s) in screens.enumerated() { s.number = n + 1 }
    }
}

/// Screen tabs (Screen 1…10) above the Screen Connection editor.
struct ScreenWorkspaceView: View {
    @ObservedObject var workspace: ScreenWorkspace
    @ObservedObject var device: NovaDevice
    @State private var confirmReadAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(workspace.screens) { screen in
                    tab(screen)
                }
                Button {
                    workspace.add(endpoint: workspace.current?.endpoint ?? device.selection)
                } label: {
                    Label("Add Screen", systemImage: "plus")
                }
                .disabled(workspace.screens.count >= ScreenWorkspace.maxScreens)
                .help("Up to \(ScreenWorkspace.maxScreens) screens. Each one has its own layout and controller.")
                Spacer()
                if workspace.reading { ProgressView().controlSize(.small) }
                Text(workspace.readStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button {
                    confirmReadAll = true
                } label: {
                    Label("Read all from HW", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(workspace.reading)
                .help("Read every screen and its mapping from all controllers (replaces these tabs)")
            }
            if let screen = workspace.current {
                ScreenConnectionView(screen: screen, device: device, workspaceEndpoints: workspace.endpoints)
                    .id(screen.id)
            }
        }
        .onAppear {
            // First visit: start from what the hardware actually runs.
            if workspace.screens.isEmpty {
                workspace.ensureFirst(endpoint: device.selection)
                Task { await workspace.readAll(device: device) }
            }
        }
        .alert("Read all screens from the hardware?", isPresented: $confirmReadAll) {
            Button("Read") { Task { await workspace.readAll(device: device) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The tabs are replaced by the screens found on the controllers. Unsent changes in the tabs are lost.")
        }
    }

    private func tab(_ screen: ScreenDocument) -> some View {
        let isCurrent = screen.id == workspace.current?.id
        return HStack(spacing: 6) {
            Image(systemName: screen.endpoint.isUSB ? "cable.connector" : "network")
                .font(.caption)
            Text(screen.name)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
            if workspace.screens.count > 1 {
                Button {
                    workspace.remove(screen)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Remove \(screen.name) (the controller is not changed)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isCurrent ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isCurrent ? Color.accentColor.opacity(0.7) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { workspace.currentID = screen.id }
        .help(device.title(for: screen.endpoint) + (screen.hardwareName.isEmpty ? "" : " — " + screen.hardwareName))
    }
}
