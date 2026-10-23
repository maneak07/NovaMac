import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

private struct ConnectionDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw RCFGXError.invalid("Cannot read connection plan.") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ScreenConnectionView: View {
    /// This screen's layout and state (kept by the workspace while switching screens and pages).
    @ObservedObject var screen: ScreenDocument
    /// Controller lists for the per-screen controller picker.
    @ObservedObject var device: NovaDevice
    /// Controllers of all screen tabs — Save to HW stores the settings on every one of them.
    var workspaceEndpoints: [NovaEndpoint] = []
    /// The controller of this screen (network controller or USB sending card).
    private var endpoint: NovaEndpoint { screen.endpoint }
    /// IP for the controller's web API; empty for a USB sending card.
    private var ip: String { if case .network(let address) = endpoint { return address } else { return "" } }
    /// Register protocol for everything (USB, or a network controller without a web interface, e.g. MEE410).
    private var useUSB: Bool { endpoint.isUSB || restAvailable == false }

    /// Connector number shown for protocol port `oneBased` (1-based) — differs on MEE410.
    private func portName(_ oneBased: Int) -> Int {
        ControllerModels.portLabel(model: device.models[endpoint.key], index: oneBased - 1)
    }

    /// Port buttons (1-based protocol numbers) in connector order.
    private var portButtons: [Int] {
        if let list = ControllerModels.physicalPorts(model: device.models[endpoint.key]) { return list.map { $0 + 1 } }
        return Array(1...max(1, portCount))
    }
    /// Network controllers from the Controllers page, USB sending cards found now, and this screen's own controller.
    private var controllerChoices: [NovaEndpoint] {
        var list: [NovaEndpoint] = device.savedIPs.map { .network($0) }
        list += device.usbPorts.map { .usb(path: $0, baud: device.baud(for: $0)) }
        if !list.contains(where: { $0.key == endpoint.key }) { list.insert(endpoint, at: 0) }
        return list
    }
    @State private var blank = false
    @State private var selected: Int?
    @State private var importing = false
    @State private var exporting = false
    @State private var document = ConnectionDocument(data: Data())
    @State private var pendingSend: ScreenConnectionWriter.Layout?
    @State private var confirmSave = false
    @State private var busy = false
    @State private var hover: (Int, Int)?
    @State private var activePorts: Set<Int> = []
    @State private var portCount = 10              // Ethernet outputs of this controller (buttons shown)
    @State private var restAvailable: Bool?        // network controller answers the Unico web API (port 19999)
    @State private var mappingOn: Bool?
    @State private var loginSheet = false
    @State private var loginUser = UserDefaults.standard.string(forKey: "NovaMac.username") ?? "admin"
    @State private var loginPassword = ""
    @State private var rememberPassword = true
    @State private var afterLogin: ScreenConnectionWriter.Layout?
    @State private var press: Press?
    @State private var error: String?
    // Persistent per-screen values (stored in ScreenDocument).
    private var plan: ScreenConnectionPlan { get { screen.plan } nonmutating set { screen.plan = newValue } }
    private var columns: Int { get { screen.columns } nonmutating set { screen.columns = newValue } }
    private var rows: Int { get { screen.rows } nonmutating set { screen.rows = newValue } }
    private var sender: Int { get { screen.sender } nonmutating set { screen.sender = newValue } }
    private var port: Int { get { screen.port } nonmutating set { screen.port = newValue } }
    private var width: Int { get { screen.width } nonmutating set { screen.width = newValue } }
    private var height: Int { get { screen.height } nonmutating set { screen.height = newValue } }
    private var zoom: Double { get { screen.zoom } nonmutating set { screen.zoom = newValue } }
    private var canvasPreset: Int { get { screen.canvasPreset } nonmutating set { screen.canvasPreset = newValue } }
    private var hideDetails: Bool { get { screen.hideDetails } nonmutating set { screen.hideDetails = newValue } }
    private var connecting: Bool { get { screen.connecting } nonmutating set { screen.connecting = newValue } }
    private var gridStep: Int { get { screen.gridStep } nonmutating set { screen.gridStep = newValue } }
    private var magnet: Bool { get { screen.magnet } nonmutating set { screen.magnet = newValue } }
    private var snapToGrid: Bool { get { screen.snapToGrid } nonmutating set { screen.snapToGrid = newValue } }
    private var transport: Int { get { screen.transport } nonmutating set { screen.transport = newValue } }
    private var history: [ScreenConnectionPlan] { get { screen.history } nonmutating set { screen.history = newValue } }
    private var cards: [ReceivingCard] { get { screen.cards } nonmutating set { screen.cards = newValue } }
    private var usbCards: [RegisterInventory.Card] { get { screen.usbCards } nonmutating set { screen.usbCards = newValue } }
    private var answering: [Int: Int] { get { screen.answering } nonmutating set { screen.answering = newValue } }
    private var hardware: UnicoTopology.Snapshot? { get { screen.hardware } nonmutating set { screen.hardware = newValue } }
    private var status: String { get { screen.status } nonmutating set { screen.status = newValue } }
    /// Maximum output area of the controller. VX1000 Pro: 4K.
    private let canvasPresets: [(name: String, width: Int, height: Int)] = [
        ("4K UHD 3840 × 2160", 3840, 2160), ("DCI 4K 4096 × 2160", 4096, 2160),
        ("3840 × 1920", 3840, 1920), ("Full HD 1920 × 1080", 1920, 1080),
    ]
    private var canvasLimit: (width: Int, height: Int) { (canvasPresets[canvasPreset].width, canvasPresets[canvasPreset].height) }
    private let routeNames = ["↘ Rows", "↘ Columns", "↙ Rows", "↙ Columns", "↗ Rows", "↗ Columns", "↖ Rows", "↖ Columns"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Screen Connection").font(.title2.bold())
                Spacer()
                Text("\(screen.name) · Standard Screen").foregroundStyle(.secondary)
            }
            Text(status).font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack(alignment: .top, spacing: 16) {
                controls.frame(width: 220)
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Basic Information") {
                        VStack(spacing: 12) {
                            HStack {
                                number("X", value: screenOrigin(true), range: 0...65535)
                                number("Y", value: screenOrigin(false), range: 0...65535)
                            }
                            HStack {
                                number("Columns", value: $screen.columns, range: 1...64) { Task { @MainActor in resize() } }
                                number("Rows", value: $screen.rows, range: 1...64) { Task { @MainActor in resize() } }
                                Button("Configure") { resize() }
                            }
                            HStack {
                                Toggle("Hide card details", isOn: $screen.hideDetails)
                                Spacer()
                                Button("Undo") {
                                    if let previous = history.popLast() { plan = previous; columns = plan.columns; rows = plan.rows; selected = nil }
                                }.disabled(history.isEmpty)
                                Button {
                                    toggleMapping()
                                } label: {
                                    Label(mappingOn == true ? "Disable Mapping" : "Enable Mapping",
                                          systemImage: mappingOn == true ? "eye.slash" : "eye")
                                }
                                .tint(mappingOn == true ? .green : nil)
                                .disabled(busy)
                                .help("Shows the card numbers on the LED screen (all receiving cards, all ports).")
                                Button("Reset connections") {
                                    remember()
                                    for i in plan.cells.indices { plan.cells[i].order = nil }
                                }
                                let offline = plan.cells.filter { $0.offline == true && $0.order != nil }.count
                                if offline > 0 {
                                    Button("Drop offline (\(offline))") {
                                        remember()
                                        for i in plan.cells.indices where plan.cells[i].offline == true {
                                            plan.cells[i].order = nil
                                            plan.cells[i].offline = nil
                                        }
                                        status = "\(offline) offline cabinet(s) removed from the plan. Send to HW (and Save) to store the layout without them in the controller."
                                    }
                                    .help("Cabinets the controller keeps in its layout but that do not answer: disconnect them in the plan, so Send to HW stores only the cabinets that are really there.")
                                }
                            }
                        }.padding(8)
                    }
                    canvas
                    HStack {
                        Text("Zoom")
                        Slider(value: $screen.zoom, in: 0.25...4).frame(maxWidth: 200)
                        Text("\(Int(zoom * 100))%")
                        Spacer()
                        Toggle("Connect by clicking cards", isOn: $screen.connecting)
                    }
                    Text(connecting ? "Click cards in cable order, or press on a card and drag across the next ones — each card you pass joins the chain. Right-click a card to undo the mapping back to it (it stays the last card)." : "Click a card to select it, drag it to any point. It snaps to neighbouring card edges (magnet) and to the grid. Right-click undoes the mapping back to that card.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Load from File…") { importing = true }
                Button("Save to File…") { save() }
                Spacer()
                Button("Read from HW") { readFromHardware() }.disabled(busy)
                Button("Read card inventory") { readCards() }.disabled(busy)
                Picker("", selection: $screen.transport) {
                    Text("Auto").tag(0)
                    Text("REST (saved)").tag(1)
                    Text("TCP 5200 (not saved)").tag(2)
                }
                .labelsHidden().fixedSize()
                .disabled(useUSB)
                .help("Auto: controllers with a web interface (Unico: VX Pro, COEX) get the layout over REST and store it themselves; other sending cards get it over TCP 5200 without saving.")
                Button("Send to HW…") { prepareSend() }
                    .disabled(busy)
                Button("Save to HW…") { confirmSave = true }
                    .disabled(busy)
                    .help("Stores the current settings on every controller of the screen tabs")
                if busy { ProgressView().controlSize(.small) }
            }
            Text("Load accepts NovaMac JSON and the tested NovaLCT V5.9.2 standard-grid SCR profile (sender 1, port 1). Save exports JSON (with positions). Read from HW loads the controller's current topology with exact coordinates. Send to HW sends the plan as drawn (one port per send, cable order 1…N, max 650 000 px per port) and verifies the read-back. On controllers with a web interface (Unico) it goes over REST and the controller stores the layout; otherwise over TCP 5200 without saving. Card-size changes, several ports and SCR export are not implemented yet.")
                .font(.caption).foregroundStyle(.secondary)
            if let hardware {
                Text("HW: screen \(hardware.screenId) · \(hardware.cabinets.count) cards · GUID \(hardware.screenGuid)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if useUSB && !usbCards.isEmpty {
                GroupBox("Receiving cards over USB (answering now)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(usbCards) { card in
                            let size = card.width.map { w in "\(w) × \(card.height ?? 0)" } ?? "size not readable"
                            let pos = card.x.map { x in " · at (\(x), \(card.y ?? 0))" } ?? ""
                            Text("Port \(portName(card.port + 1)) · Card \(card.index + 1) · \(size)\(pos)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            if !useUSB && !cards.isEmpty {
                GroupBox("Connected cards — inventory, not connection coordinates") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(cards) { card in
                            let silent = answering[card.netPortID].map { card.cabinetIndex >= $0 } ?? false
                            Text("Port ID \(card.netPortID) · Card \(card.cabinetIndex + 1) · \(card.cabinetBaseInfo.modelName) · \(card.cabinetPhysicalInfo.width) × \(card.cabinetPhysicalInfo.height)\(silent ? " · NOT ANSWERING (stale entry)" : "")")
                                .foregroundStyle(silent ? Color.orange : Color.primary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, UTType(filenameExtension: "scr") ?? .data, .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2_000_000 else { throw RCFGXError.invalid("Plan exceeds 2 MB.") }
                let data = try Data(contentsOf: url)
                let isSCR = url.pathExtension.lowercased() == "scr" || data.starts(with: Data("DSCI".utf8))
                let loaded = try isSCR ? NovaLCTSCR.decode(data) : JSONDecoder().decode(ScreenConnectionPlan.self, from: data)
                try loaded.validate(); remember(); plan = loaded; columns = loaded.columns; rows = loaded.rows; selected = nil
                error = nil; status = isSCR ? "Imported SCR layout from \(url.lastPathComponent). Local plan only; Save exports NovaMac JSON, not the original SCR settings." : "Loaded \(url.lastPathComponent). Local plan only."
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Screen-Connection.novamac.json") { result in
            do { _ = try result.get(); status = "Connection plan saved."; error = nil }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: endpoint.key) { _, _ in
            cards = []; usbCards = []; answering = [:]; hardware = nil; activePorts = []; mappingOn = nil; error = nil
            status = "Controller changed to \(endpoint.label). The local plan has not been applied."
        }
        .task(id: endpoint.key) {
            // Port count and link state, refreshed while this page is open.
            // Network (web interface): the controller's own port list and link state, every 5 s.
            // USB / classic cards: ports per model (or found by probing); "active" = the first card answers, every 10 s.
            if case .network(let address) = endpoint, restAvailable == nil {
                restAvailable = (try? await UnicoAPI.fetchScreens(ip: address)) != nil
            }
            if useUSB {
                portCount = ControllerModels.portCount(model: device.models[endpoint.key]) ?? max(2, (usbCards.map(\.port).max() ?? 0) + 1)
            }
            while !Task.isCancelled {
                if useUSB {
                    if !busy, let active = try? await CardProbe.activePorts(endpoint, ports: Array(0..<portCount)) {
                        activePorts = Set(active.map { $0 + 1 })
                        if mappingOn == nil, let first = active.min() { mappingOn = try? await ScreenMapping.state(endpoint, port: first + 1) }
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    if let ports = try? await UnicoTopology.netports(ip: ip), !ports.isEmpty {
                        portCount = Set(ports.map(\.netportIndex)).count
                        activePorts = Set(ports.filter { $0.linkState == 1 }.map { $0.netportIndex + 1 })
                        if mappingOn == nil, !busy, let first = activePorts.min(),
                           let state = try? await ScreenMapping.state(.network(ip), port: first) { mappingOn = state }
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
        .alert("Send screen connection to \(endpoint.label)?", isPresented: Binding(get: { pendingSend != nil }, set: { if !$0 { pendingSend = nil } })) {
            Button("Send") { if let layout = pendingSend { send(layout) } }
            Button("Cancel", role: .cancel) { pendingSend = nil }
        } message: {
            Text("\((pendingSend?.warnings ?? []).map { "⚠︎ " + $0 + "\n" }.joined())\(pendingSend?.freePlacement == true ? "Free placement (not a rows × columns grid).\n" : "")\(pendingSend?.summary ?? "")\nScreen \(pendingSend?.width ?? 0) × \(pendingSend?.height ?? 0). The image on the LED screen will change immediately. \(useUSB ? "USB: not saved until you press Save to HW — a power cycle restores the stored layout." : transport == 2 ? "TCP 5200: not saved — a power cycle restores the saved layout." : "Controllers with a web interface store the layout (survives a power cycle); others get it over TCP 5200 without saving.")")
        }
        .sheet(isPresented: $loginSheet) { loginView }
        .alert("Save on all controllers of this tab?", isPresented: $confirmSave) {
            Button("Save") { saveHW() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((workspaceEndpoints.isEmpty ? [endpoint] : workspaceEndpoints).map { device.title(for: $0) }.joined(separator: "\n")
                 + "\n\nEach controller keeps what it runs now after a power cycle.")
        }
    }
    private var controls: some View {
        VStack(spacing: 16) {
            GroupBox("Controller") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: Binding(get: { endpoint.key }, set: { key in
                        if let choice = controllerChoices.first(where: { $0.key == key }) { screen.endpoint = choice }
                    })) {
                        ForEach(controllerChoices, id: \.key) { choice in
                            Label(device.title(for: choice), systemImage: choice.isUSB ? "cable.connector" : "network").tag(choice.key)
                        }
                    }
                    .labelsHidden()
                    .disabled(busy)
                    Button {
                        device.scanUSB()
                    } label: {
                        Label("Rescan USB", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(8)
                .help("Controller of \(screen.name). Add network controllers on the Dashboard.")
            }
            if (device.models[endpoint.key] ?? "").uppercased().hasPrefix("MCTRL") {
                SenderEDIDBox(endpoint: endpoint)
            }
            GroupBox("Sending Card Number") { number("Sender", value: $screen.sender, range: 1...256).padding(8) }
            GroupBox("Ethernet Port No.") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5)) {
                    ForEach(portButtons, id: \.self) { n in
                        Button("\(portName(n))") { port = n }.tint(port == n ? .accentColor : .secondary)
                            .buttonStyle(.borderedProminent)
                            .overlay(alignment: .topTrailing) {
                                if activePorts.contains(n) {
                                    Image(systemName: "arrowtriangle.up.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(.green)
                                        .offset(x: 3, y: -3)
                                        .help(useUSB ? "Receiving cards answer on this port" : "Link up")
                                }
                            }
                    }
                }.padding(8)
            }
            GroupBox("Receiving Card Size") {
                VStack(spacing: 10) {
                    number("Width", value: $screen.width, range: 1...8192)
                    number("Height", value: $screen.height, range: 1...8192)
                    Toggle("Set Blank", isOn: selectedBlank)
                        .disabled(selected == nil)
                        .help("Blank = no card here: content skips it as a black area and it cannot be mapped.")
                    Button("Apply size to current card") { applySize(all: false) }.disabled(selected == nil)
                    Button("Apply size to entire screen") { applySize(all: true) }
                }.padding(8)
            }
            GroupBox("Placement") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Area", selection: $screen.canvasPreset) {
                        ForEach(canvasPresets.indices, id: \.self) { Text(canvasPresets[$0].name).tag($0) }
                    }
                    Toggle("Magnet (snap to cards)", isOn: $screen.magnet)
                    Toggle("Snap to grid", isOn: $screen.snapToGrid)
                    Picker("Grid", selection: $screen.gridStep) {
                        ForEach([8, 10, 16, 20, 32, 40, 80, 160], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    HStack {
                        number("Card X", value: selectedCoordinate(true), range: 0...65535)
                        number("Card Y", value: selectedCoordinate(false), range: 0...65535)
                    }.disabled(selected == nil)
                    Button("Back to rows × columns grid") { remember(); plan.unpinPositions(); status = "Positions reset to the rows × columns grid." }
                }.padding(8)
            }
            GroupBox("Quick Connection") {
                VStack(alignment: .leading) {
                    Text("Apply selected sender and port to all non-blank cards.").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                        ForEach(0..<8, id: \.self) { mode in
                            Button(routeNames[mode]) { quickConnect(mode) }
                        }
                    }
                }.padding(8)
            }
        }
    }
    // MARK: Coordinate canvas

    /// Points per screen pixel.
    private var scale: CGFloat { 0.5 * zoom }
    private let rulerSize: CGFloat = 24

    private var canvas: some View {
        let s = scale
        let bounds = plan.pixelBounds
        let limit = canvasLimit
        let extentW = CGFloat(max(limit.width, bounds.width)), extentH = CGFloat(max(limit.height, bounds.height))
        let rects = plan.rects
        let overlaps = plan.overlappingIDs
        return VStack(alignment: .leading, spacing: 6) {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Color.black.opacity(0.35).frame(width: rulerSize, height: rulerSize)
                        ruler(horizontal: true, length: extentW * s, scale: s)
                    }
                    HStack(alignment: .top, spacing: 0) {
                        ruler(horizontal: false, length: extentH * s, scale: s)
                        ZStack(alignment: .topLeading) {
                            gridLayer(width: extentW * s, height: extentH * s, scale: s, screen: bounds, limit: limit)
                            ForEach(plan.cells) { cell in
                                let r = rects[cell.id] ?? plan.rect(of: cell)
                                cabinetView(cell, rect: r, scale: s, overlapping: overlaps.contains(cell.id))
                                    .offset(x: CGFloat(r.x) * s, y: CGFloat(r.y) * s)
                                    .allowsHitTesting(false)
                            }
                            cableLayer(rects: rects, scale: s).allowsHitTesting(false)
                        }
                        .frame(width: extentW * s, height: extentH * s, alignment: .topLeading)
                        .clipped()
                        .overlay(
                            BoardInput(down: boardDown, dragged: boardDragged, up: boardUp, right: boardRight,
                                       moved: { p in hover = p.map { (Int(($0.x / s).rounded()), Int(($0.y / s).rounded())) } })
                        )
                    }
                }
            }
            .frame(height: 460)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 14) {
                Text("Screen \(bounds.width) × \(bounds.height) px of \(limit.width) × \(limit.height)")
                if let hover { Text("Cursor x \(hover.0)  y \(hover.1)") }
                if let id = selected, let r = rects[id] { Text("Selected x \(r.x)  y \(r.y)  ·  \(r.width)×\(r.height)") }
                ForEach(plan.portLoads) { load in
                    Text("P\(portName(load.port)): \(load.pixels.formatted()) / \(ScreenConnectionPlan.portCapacity.formatted()) px")
                        .foregroundStyle(load.pixels > ScreenConnectionPlan.portCapacity ? .red
                                         : load.pixels > ScreenConnectionPlan.portCapacity * 9 / 10 ? .orange : .secondary)
                }
                if !overlaps.isEmpty { Text("Overlap: \(overlaps.count) cards").foregroundStyle(.red) }
                if !plan.isRegularGrid { Text("Free placement").foregroundStyle(.orange) }
                if bounds.width > limit.width || bounds.height > limit.height { Text("Outside controller area").foregroundStyle(.red) }
            }
            .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func cabinetView(_ cell: ScreenConnectionPlan.Cell, rect r: PixelRect, scale s: CGFloat, overlapping: Bool) -> some View {
        let isSelected = selected == cell.id
        let fill: Color = cell.blank ? .black : overlapping ? .red.opacity(0.4) : .blue.opacity(0.32)
        return ZStack {
            Rectangle().fill(fill)
            if cell.blank {
                // Hatched black field: no card, content skipped.
                Canvas { context, size in
                    var hatch = Path()
                    var d: CGFloat = -size.height
                    while d < size.width { hatch.move(to: CGPoint(x: d, y: size.height)); hatch.addLine(to: CGPoint(x: d + size.height, y: 0)); d += 10 }
                    context.stroke(hatch, with: .color(.white.opacity(0.12)), lineWidth: 1)
                }
            }
            if cell.offline == true && !cell.blank && !isSelected {
                Rectangle().strokeBorder(Color.orange.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            } else {
                Rectangle().strokeBorder(isSelected ? Color.yellow : Color.white.opacity(0.45), lineWidth: isSelected ? 2.5 : 1)
            }
            if !hideDetails && CGFloat(r.width) * s >= 56 && CGFloat(r.height) * s >= 56 {
                VStack(spacing: 2) {
                    Text(cell.blank ? "BLANK" : cell.order.map { "Card \($0)" } ?? "Unconnected").bold()
                    if cell.offline == true && !cell.blank { Text("OFFLINE").font(.caption2.bold()).foregroundStyle(.orange) }
                    Text("S\(cell.sender) · P\(portName(cell.port))")
                    Text("W: \(r.width)  H: \(r.height)").monospacedDigit()
                    Text("X: \(r.x)  Y: \(r.y)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: min(13, max(9, 11 * zoom))))
                .multilineTextAlignment(.center)
                .padding(3)
            }
        }
        .frame(width: CGFloat(r.width) * s, height: CGFloat(r.height) * s)
        .contentShape(Rectangle())
    }

    /// Coordinate grid: minor lines every grid step, major lines every 5 steps, screen outline.
    private func gridLayer(width: CGFloat, height: CGFloat, scale s: CGFloat, screen: (width: Int, height: Int), limit: (width: Int, height: Int)) -> some View {
        Canvas { context, _ in
            var step = CGFloat(gridStep) * s
            while step < 6 { step *= 2 }
            var minor = Path(), major = Path()
            var i = 0
            var x: CGFloat = 0
            while x <= width {
                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: height))
                if i % 5 == 0 { major.addPath(line) } else { minor.addPath(line) }
                x += step; i += 1
            }
            i = 0
            var y: CGFloat = 0
            while y <= height {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: width, y: y))
                if i % 5 == 0 { major.addPath(line) } else { minor.addPath(line) }
                y += step; i += 1
            }
            context.stroke(minor, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
            context.stroke(major, with: .color(.white.opacity(0.16)), lineWidth: 0.8)
            let outline = Path(CGRect(x: 0, y: 0, width: CGFloat(screen.width) * s, height: CGFloat(screen.height) * s))
            context.stroke(outline, with: .color(.green.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            let area = Path(CGRect(x: 0, y: 0, width: CGFloat(limit.width) * s, height: CGFloat(limit.height) * s))
            context.stroke(area, with: .color(.orange.opacity(0.8)), lineWidth: 1.5)
        }
        .frame(width: width, height: height)
    }

    private func ruler(horizontal: Bool, length: CGFloat, scale s: CGFloat) -> some View {
        Canvas { context, size in
            var step = CGFloat(gridStep) * s
            var pixels = gridStep
            while step < 6 { step *= 2; pixels *= 2 }
            var tick = Path()
            var i = 0
            var p: CGFloat = 0
            while p <= length {
                let isMajor = i % 5 == 0
                let len: CGFloat = isMajor ? rulerSize * 0.5 : rulerSize * 0.25
                if horizontal {
                    tick.move(to: CGPoint(x: p, y: rulerSize)); tick.addLine(to: CGPoint(x: p, y: rulerSize - len))
                } else {
                    tick.move(to: CGPoint(x: rulerSize, y: p)); tick.addLine(to: CGPoint(x: rulerSize - len, y: p))
                }
                if isMajor {
                    let label = context.resolve(Text("\(i * pixels)").font(.system(size: 9)).foregroundStyle(.secondary))
                    if horizontal { context.draw(label, at: CGPoint(x: p + 2, y: 1), anchor: .topLeading) }
                    else { context.draw(label, at: CGPoint(x: 2, y: p + 2), anchor: .topLeading) }
                }
                p += step; i += 1
            }
            context.stroke(tick, with: .color(.white.opacity(0.4)), lineWidth: 0.8)
        }
        .frame(width: horizontal ? length : rulerSize, height: horizontal ? rulerSize : length)
        .background(Color.black.opacity(0.35))
    }

    /// Cable order arrows between card centres, per sender/port.
    private func cableLayer(rects: [Int: PixelRect], scale s: CGFloat) -> some View {
        Canvas { context, _ in
            let groups = Dictionary(grouping: plan.cells.filter { $0.order != nil && !$0.blank }, by: { "\($0.sender)/\($0.port)" })
            for group in groups.values {
                let sorted = group.sorted { $0.order! < $1.order! }
                for (a, b) in zip(sorted, sorted.dropFirst()) {
                    guard let ra = rects[a.id], let rb = rects[b.id] else { continue }
                    let start = CGPoint(x: (CGFloat(ra.x) + CGFloat(ra.width) / 2) * s, y: (CGFloat(ra.y) + CGFloat(ra.height) * 0.8) * s)
                    let end = CGPoint(x: (CGFloat(rb.x) + CGFloat(rb.width) / 2) * s, y: (CGFloat(rb.y) + CGFloat(rb.height) * 0.8) * s)
                    var path = Path(); path.move(to: start); path.addLine(to: end)
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    for delta in [-0.5, 0.5] {
                        path.move(to: end)
                        path.addLine(to: CGPoint(x: end.x - 10 * cos(angle + delta), y: end.y - 10 * sin(angle + delta)))
                    }
                    context.stroke(path, with: .color(.green), lineWidth: 2)
                }
            }
        }
    }

    private var selectedBlank: Binding<Bool> {
        Binding(
            get: { selected.flatMap { id in plan.cells.first(where: { $0.id == id })?.blank } ?? false },
            set: { value in
                guard let id = selected else { return }
                remember()
                plan.setBlank(id, value)
                blank = value
                status = value ? "Card set blank: content skips it as black, it cannot be mapped. Chain numbers after it moved up."
                               : "Card active again — connect it to include it in a chain."
            })
    }

    /// Top-left corner of the whole layout. Typing a value moves every card (the layout keeps its shape).
    private func screenOrigin(_ isX: Bool) -> Binding<Int> {
        Binding(
            get: {
                let rects = plan.rects.values
                return (isX ? rects.map(\.x).min() : rects.map(\.y).min()) ?? 0
            },
            set: { value in
                let rects = Array(plan.rects.values)
                guard !rects.isEmpty else { return }
                let current = (isX ? rects.map(\.x).min() : rects.map(\.y).min()) ?? 0
                let farEdge = (isX ? rects.map(\.maxX).max() : rects.map(\.maxY).max()) ?? 0
                let delta = min(value, current + 65535 - farEdge) - current
                guard delta != 0 else { return }
                remember()
                plan.pinPositions()
                for i in plan.cells.indices {
                    if isX { plan.cells[i].x = (plan.cells[i].x ?? 0) + delta }
                    else { plan.cells[i].y = (plan.cells[i].y ?? 0) + delta }
                }
                let r = plan.rects.values
                status = "Layout moved to X \(r.map(\.x).min() ?? 0), Y \(r.map(\.y).min() ?? 0)."
            })
    }

    private func selectedCoordinate(_ isX: Bool) -> Binding<Int> {
        Binding(
            get: {
                guard let id = selected, let cell = plan.cells.first(where: { $0.id == id }) else { return 0 }
                let r = plan.rect(of: cell)
                return isX ? r.x : r.y
            },
            set: { value in
                guard let id = selected else { return }
                remember()
                plan.pinPositions()
                if let i = plan.cells.firstIndex(where: { $0.id == id }) {
                    if isX { plan.cells[i].x = value } else { plan.cells[i].y = value }
                }
            })
    }

    private func number(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, onSubmit: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit?() }
        }
    }
    private func toggleMapping() {
        let target = endpoint, enable = mappingOn != true
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await ScreenMapping.set(target, enabled: enable)
                mappingOn = enable
                status = enable ? "Mapping enabled on the LED screen." : "Mapping disabled; normal image restored."
            } catch { self.error = "Mapping: \(error.localizedDescription)" }
        }
    }
    // MARK: Mouse on the canvas (one AppKit layer for left, drag, right and hover)

    private struct Press {
        var id: Int?
        var start: CGPoint
        var connecting: Bool
        var originX = 0, originY = 0
        var moved = false
        var head: Int?          // last card of the chain being drawn
        var truncated = false   // chain after the head already cleared
        var added = 0
    }

    private func cellID(at p: CGPoint) -> Int? {
        let x = Int(p.x / scale), y = Int(p.y / scale)
        return plan.cells.reversed().first { cell in
            let r = plan.rect(of: cell)
            return x >= r.x && x < r.maxX && y >= r.y && y < r.maxY
        }?.id
    }

    private func nextOrder() -> Int {
        (plan.cells.filter { $0.sender == sender && $0.port == port }.compactMap(\.order).max() ?? 0) + 1
    }

    private func quickConnect(_ mode: Int) {
        var trial = plan
        trial.connect(mode: mode, sender: sender, port: port)
        let load = trial.portLoad(sender: sender, port: port)
        guard load <= ScreenConnectionPlan.portCapacity else {
            error = "Quick Connection refused: port \(port) would carry \(load) px, the limit is \(ScreenConnectionPlan.portCapacity) px per port. Split the cards across ports."
            return
        }
        remember(); plan = trial
    }

    private func refuseOverload(_ cell: ScreenConnectionPlan.Cell) {
        let load = plan.portLoad(sender: sender, port: port)
        error = "Port \(port) limit: \(load) + \(cell.width * cell.height) px would exceed \(ScreenConnectionPlan.portCapacity) px. The card was not connected — use another port."
    }

    private func boardDown(_ p: CGPoint) {
        let id = cellID(at: p)
        press = Press(id: id, start: p, connecting: connecting)
        guard let id, let i = plan.cells.firstIndex(where: { $0.id == id }) else { selected = nil; return }
        selected = id
        let cell = plan.cells[i]
        width = cell.width; height = cell.height; blank = cell.blank
        guard connecting else { return }
        guard !cell.blank else { error = "This cell is blank and cannot be mapped. Turn off Set Blank first."; press = nil; return }
        if cell.order != nil && cell.sender == sender && cell.port == port {
            remember()
            press?.head = id                       // continue the chain from this card
        } else {
            guard plan.canConnect(cell, sender: sender, port: port) else { refuseOverload(cell); press = nil; return }
            remember()
            plan.cells[i].sender = sender; plan.cells[i].port = port; plan.cells[i].order = nextOrder()
            press?.head = id; press?.added = 1
        }
    }

    private func boardDragged(_ p: CGPoint) {
        guard var pr = press else { return }
        if pr.connecting {
            // Mapping by dragging: every card the cursor enters joins the chain in order.
            guard let id = cellID(at: p), id != pr.head,
                  let i = plan.cells.firstIndex(where: { $0.id == id }), !plan.cells[i].blank else { return }
            if !pr.truncated, let head = pr.head {
                plan.unmap(after: head); pr.truncated = true
            }
            let c = plan.cells[i]
            if c.order != nil && c.sender == sender && c.port == port { press = pr; return }   // already in this chain
            guard plan.canConnect(c, sender: sender, port: port) else { refuseOverload(c); press = pr; return }
            plan.cells[i].sender = sender; plan.cells[i].port = port; plan.cells[i].order = nextOrder()
            pr.head = id; pr.added += 1
            press = pr
            return
        }
        guard let id = pr.id else { return }
        if !pr.moved {
            guard hypot(p.x - pr.start.x, p.y - pr.start.y) > 3,
                  let cell = plan.cells.first(where: { $0.id == id }) else { return }
            remember()
            plan.pinPositions()
            let r = plan.rect(of: cell)
            pr.originX = r.x; pr.originY = r.y; pr.moved = true
            press = pr
        }
        let s = scale
        let proposedX = pr.originX + Int(((p.x - pr.start.x) / s).rounded())
        let proposedY = pr.originY + Int(((p.y - pr.start.y) / s).rounded())
        let snappedPoint = plan.snapped(id: id, proposedX: proposedX, proposedY: proposedY,
                                        threshold: max(1, Int((12 / s).rounded())), magnet: magnet,
                                        gridStep: snapToGrid ? gridStep : nil,
                                        limitWidth: canvasLimit.width, limitHeight: canvasLimit.height)
        if let i = plan.cells.firstIndex(where: { $0.id == id }) {
            plan.cells[i].x = snappedPoint.x; plan.cells[i].y = snappedPoint.y
        }
    }

    private func boardUp(_ p: CGPoint) {
        guard let pr = press else { return }
        press = nil
        if pr.connecting, pr.added > 0 || pr.truncated {
            let last = pr.head.flatMap { id in plan.cells.first(where: { $0.id == id })?.order } ?? 0
            status = "Sender \(sender) · port \(port): chain now ends at card \(last)."
        } else if pr.moved, let id = pr.id, let cell = plan.cells.first(where: { $0.id == id }) {
            let r = plan.rect(of: cell)
            status = "Card moved to x \(r.x), y \(r.y). Local plan only until Send to HW."
        }
    }

    private func boardRight(_ p: CGPoint) {
        guard let id = cellID(at: p), let cell = plan.cells.first(where: { $0.id == id }) else { return }
        unmap(cell)
    }

    private func unmap(_ cell: ScreenConnectionPlan.Cell) {
        guard let current = plan.cells.first(where: { $0.id == cell.id }), let order = current.order else {
            status = "This card is not connected."; return
        }
        var trial = plan
        guard trial.unmap(after: cell.id) > 0 else {
            status = "Card \(order) is already the last card on sender \(current.sender) · port \(current.port)."; return
        }
        remember()
        let removed = plan.unmap(after: cell.id)
        selected = cell.id
        sender = current.sender; port = current.port
        status = "Mapping undone back to card \(order): \(removed) card(s) after it disconnected. Continue connecting from card \(order + 1)."
    }
    private func remember() { history.append(plan); if history.count > 30 { history.removeFirst() }; error = nil }
    private func resize() {
        guard columns * rows <= 1024 else { error = "Maximum 1024 cards per plan."; return }
        remember(); plan.columns = columns; plan.rows = rows
        plan.cells = (0..<columns*rows).map { ScreenConnectionPlan.Cell(id: $0, width: width, height: height, sender: sender, port: port) }
        selected = nil; status = "New local grid. Use Undo to recover the previous layout."
    }
    private func select(_ cell: ScreenConnectionPlan.Cell) {
        selected = cell.id
        if connecting, !cell.blank, let i = plan.cells.firstIndex(where: { $0.id == cell.id }) {
            remember()
            let next = (plan.cells.filter { $0.sender == sender && $0.port == port }.compactMap(\.order).max() ?? 0) + 1
            plan.cells[i].sender = sender; plan.cells[i].port = port; plan.cells[i].order = next
        }
        width = cell.width; height = cell.height; blank = cell.blank
    }
    private func applySize(all: Bool) {
        remember()
        for i in plan.cells.indices where all || plan.cells[i].id == selected {
            plan.cells[i].width = width; plan.cells[i].height = height
        }
    }
    private func save() {
        do { try plan.validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; document = ConnectionDocument(data: try encoder.encode(plan)); exporting = true }
        catch { self.error = error.localizedDescription }
    }
    /// Network controllers: find out once whether they have the web API; without it everything goes over registers.
    private func withMode(_ action: @escaping () -> Void) {
        guard case .network(let address) = endpoint, restAvailable == nil else { action(); return }
        Task { @MainActor in
            restAvailable = (try? await UnicoAPI.fetchScreens(ip: address)) != nil
            action()
        }
    }

    private func readFromHardware() {
        if case .network = endpoint, restAvailable == nil { withMode { readFromHardware() }; return }
        if useUSB { readUSB(makePlan: true); return }
        let address = ip; busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let snapshot = try await UnicoTopology.readFromHardware(ip: address, guid: hardware?.screenGuid)
                guard address == ip else { return }
                remember()
                hardware = snapshot
                plan = snapshot.plan; columns = plan.columns; rows = plan.rows; selected = nil
                // Ground truth: cards that do not answer in their port chain are offline, whatever the controller caches.
                answering = await probe(address, netPortIDs: Set(snapshot.cabinets.map(\.netPortID)))
                let ports = (try? await UnicoTopology.netports(ip: address)) ?? []
                for i in plan.cells.indices {
                    guard let order = plan.cells[i].order,
                          let np = ports.first(where: { $0.netportIndex == plan.cells[i].port - 1 }),
                          let n = answering[np.netportID] else { continue }
                    if order > n { plan.cells[i].offline = true }
                }
                let offlineCount = plan.cells.filter { $0.offline == true }.count
                let shown = plan.cells.filter { $0.order != nil }.count
                let stale = snapshot.cabinets.count - shown
                status = "Read from HW: \(shown) cards in the controller's layout"
                    + (offlineCount > 0 ? ", \(shown - offlineCount) online, \(offlineCount) OFFLINE (kept in the layout, not answering)." : ", all online.")
                    + (stale > 0 ? " \(stale) leftover cabinet(s) of an older layout (offline, under other cabinets) left out." : "")
            } catch { self.error = error.localizedDescription }
        }
    }
    private func prepareSend() {
        error = nil
        do {
            var layout = try ScreenConnectionWriter.layout(plan: plan, hardware: hardware, area: canvasLimit)
            layout.model = device.models[endpoint.key]
            pendingSend = layout
        }
        catch { self.error = error.localizedDescription }
    }
    /// GUID of the LED screen if the controller speaks Unico REST (port 19999), else nil.
    private func unicoScreenGuid(_ address: String) async -> String? {
        guard let screens = try? await UnicoAPI.fetchScreens(ip: address) else { return nil }
        return screens.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "MVR" }?.guid
    }

    private func send(_ layout: ScreenConnectionWriter.Layout) {
        pendingSend = nil
        if case .network = endpoint, restAvailable == nil { withMode { send(layout) }; return }
        if useUSB { sendUSB(layout); return }
        let address = ip, route = transport
        busy = true; error = nil; status = "Sending to \(address)…"
        Task { @MainActor in
            defer { busy = false }
            do {
                let known = hardware?.screenGuid
                let guid = route == 2 ? nil : (known != nil ? known : await unicoScreenGuid(address))
                if route == 1 && guid == nil { throw RCFGXError.invalid("This controller does not answer the Unico REST API (port 19999). Use TCP 5200.") }
                if let guid {
                    // VX Pro keeps two copies of the layout: the sending card's registers (what NovaLCT writes) and the
                    // web interface's model. Both are written, so NovaLCT, the web UI and NovaMac all see the same.
                    var registers = ""
                    if layout.ports.count == 1 {
                        status = "Sending to \(address): sending-card registers (NovaLCT protocol)…"
                        try await ScreenConnectionWriter.sendRegistersOnly(ip: address, layout: layout)
                        registers = "Registers (NovaLCT protocol) written. "
                    } else {
                        registers = "Registers not written (several ports: the VX register map for that is not captured yet). "
                    }
                    status = "Sending to \(address): web interface…"
                    status = registers + (try await UnicoTopologyWriter.send(ip: address, layout: layout, screenGuid: guid))
                } else {
                    status = try await ScreenConnectionWriter.send(.network(address), layout: layout)
                }
                if let fresh = try? await UnicoTopology.readFromHardware(ip: address, guid: guid) { self.hardware = fresh }
            } catch let failure as UnicoSession.Failure {
                switch failure {
                case .needsPassword, .rejected:
                    afterLogin = layout
                    loginPassword = ""
                    if case .rejected(let code, let message) = failure { error = "Login: \(message) (\(code))" }
                    loginSheet = true
                    status = "Controller login required to send."
                default:
                    self.error = failure.localizedDescription
                }
            } catch {
                self.error = error.localizedDescription
                status = "Send failed. Read from HW shows the current state."
            }
        }
    }

    private var loginView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Log in to \(ip)").font(.headline)
            Text("Needed to change the screen layout through the controller's web API (same account as its web interface).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("User", text: $loginUser).textFieldStyle(.roundedBorder)
            SecureField("Password", text: $loginPassword).textFieldStyle(.roundedBorder)
            Toggle("Remember password", isOn: $rememberPassword)
            HStack {
                Spacer()
                Button("Cancel") { loginSheet = false; afterLogin = nil }
                Button("Log in & Send") { performLogin() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loginUser.isEmpty || loginPassword.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func performLogin() {
        let address = ip, user = loginUser, password = loginPassword, remember = rememberPassword
        Task { @MainActor in
            let session = UnicoSession.shared(ip: address)
            session.username = user
            do {
                try await session.login(password: password, remember: remember)
                loginSheet = false; loginPassword = ""; error = nil
                if let layout = afterLogin { afterLogin = nil; send(layout) }
            } catch {
                self.error = "Login: \(error.localizedDescription)"
            }
        }
    }
    // MARK: USB sending card (register protocol over the serial port)


    private func readUSB(makePlan: Bool) {
        let target = endpoint
        busy = true; error = nil; status = "Reading the sending card…"
        Task { @MainActor in
            defer { busy = false }
            do {
                // Known model: its port count. Unknown: look at up to 32 ports (fibre controllers) (empty ports answer at once).
                await device.ensureModel(target)
                let known = ControllerModels.portCount(model: device.models[target.key])
                let found = try await RegisterInventory.read(target, ports: known ?? 32, model: device.models[target.key])
                portCount = known ?? max(2, (found.map(\.port).max() ?? 0) + 1)
                guard target == endpoint else { return }
                usbCards = found
                activePorts = Set(found.map { $0.port + 1 })
                if let first = activePorts.min() { mappingOn = try? await ScreenMapping.state(target, port: first) }
                let perPort = Dictionary(grouping: found, by: \.port).sorted { $0.key < $1.key }
                    .map { "port \(portName($0.key + 1)): \($0.value.count)" }.joined(separator: ", ")
                if makePlan {
                    let loaded = try RegisterInventory.plan(found, defaultSize: (width, height))
                    remember(); hardware = nil
                    plan = loaded; columns = plan.columns; rows = plan.rows; selected = nil
                    let positioned = found.allSatisfy { $0.x != nil }
                    status = "Read from HW: \(found.count) receiving cards (\(perPort))."
                        + (positioned ? " Positions from the sending card's table." : " Positions not readable — cards placed in a row.")
                } else {
                    status = found.isEmpty ? "USB sending card answers, but no receiving card answers on ports 1–\(portCount)."
                                           : "\(found.count) receiving cards answer (\(perPort))."
                }
            } catch { self.error = "USB: \(error.localizedDescription)"; status = "No answer from the USB sending card." }
        }
    }

    /// Saves the settings on every controller used by the screen tabs.
    private func saveHW() {
        let targets = workspaceEndpoints.isEmpty ? [endpoint] : workspaceEndpoints
        let route = transport
        busy = true; error = nil; status = "Saving on \(targets.count) controller(s)…"
        Task { @MainActor in
            defer { busy = false }
            var done: [String] = [], failed: [String] = []
            for target in targets {
                let name = device.title(for: target)
                // Web-interface controllers (VX Pro, COEX) store REST sends themselves and restore their own
                // layout at power-up, so a register-level save does not persist there (tested on VX1000 Pro).
                if !target.isUSB, route != 2, case .network(let address) = target, await unicoScreenGuid(address) != nil {
                    done.append(name + " (stored by the controller)")
                    continue
                }
                do { _ = try await ClassicSave.save(target); done.append(name) }
                catch { failed.append(name + ": " + error.localizedDescription) }
            }
            status = "Saved: " + (done.isEmpty ? "—" : done.joined(separator: ", ")) + "."
            if !failed.isEmpty { self.error = "Save failed on " + failed.joined(separator: "; ") }
        }
    }

    private func sendUSB(_ layout: ScreenConnectionWriter.Layout) {
        let target = endpoint
        busy = true; error = nil; status = "Sending over \(target.label)…"
        Task { @MainActor in
            defer { busy = false }
            do { status = try await ScreenConnectionWriter.sendRegisters(target, layout: layout) }
            catch { self.error = "USB send: \(error.localizedDescription)"; status = "Send failed." }
        }
    }

    /// Probes every port that has cards (in the list or with link) and returns netPortID → answering count.
    private func probe(_ address: String, netPortIDs: Set<Int>) async -> [Int: Int] {
        guard let ports = try? await UnicoTopology.netports(ip: address) else { return [:] }
        var result: [Int: Int] = [:]
        for netport in ports where netPortIDs.contains(netport.netportID) || netport.linkState == 1 {
            if result[netport.netportID] != nil { continue }
            if let n = try? await CardProbe.count(ip: address, portIndex: netport.netportIndex) { result[netport.netportID] = n }
        }
        return result
    }
    private func readCards() {
        if case .network = endpoint, restAvailable == nil { withMode { readCards() }; return }
        if useUSB { readUSB(makePlan: false); return }
        let address = ip; busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await ReceivingCardAPI(ip: address).cards()
                guard address == ip else { return }
                cards = result
                answering = await probe(address, netPortIDs: Set(result.map(\.netPortID)))
                let real = answering.values.reduce(0, +)
                status = "Controller lists \(result.count) cards; \(real) actually answer (TCP 5200 probe)."
                    + (real < result.count ? " The rest are stale entries from an earlier scan." : "")
            } catch { self.error = error.localizedDescription }
        }
    }
}


/// One AppKit layer over the canvas: left press/drag/release, right press and hover,
/// in canvas coordinates (points, origin top-left).
private struct BoardInput: NSViewRepresentable {
    var down: (CGPoint) -> Void
    var dragged: (CGPoint) -> Void
    var up: (CGPoint) -> Void
    var right: (CGPoint) -> Void
    var moved: (CGPoint?) -> Void

    func makeNSView(context: Context) -> InputView { let view = InputView(); view.handlers = self; return view }
    func updateNSView(_ view: InputView, context: Context) { view.handlers = self }

    final class InputView: NSView {
        var handlers: BoardInput?
        private var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
        override func mouseDown(with event: NSEvent) { handlers?.down(point(event)) }
        override func mouseDragged(with event: NSEvent) { handlers?.dragged(point(event)); handlers?.moved(point(event)) }
        override func mouseUp(with event: NSEvent) { handlers?.up(point(event)) }
        override func rightMouseDown(with event: NSEvent) { handlers?.right(point(event)) }
        override func mouseMoved(with event: NSEvent) { handlers?.moved(point(event)) }
        override func mouseExited(with event: NSEvent) { handlers?.moved(nil) }
    }
}
