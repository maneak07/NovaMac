import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Receiving Cards page: one place for the receiving cards of a controller (USB or Ethernet):
/// read a card, open a configuration (file or the controller's library), edit, send and save.
struct ReceivingCardPage: View {
    @ObservedObject var device: NovaDevice
    @State private var endpointKey: String?

    /// Network controllers from the Controllers page and the USB sending cards found now.
    private var choices: [NovaEndpoint] {
        var list: [NovaEndpoint] = device.savedIPs.map { .network($0) }
        list += device.usbPorts.map { .usb(path: $0, baud: device.baud(for: $0)) }
        if !list.contains(where: { $0.key == device.selection.key }) { list.insert(device.selection, at: 0) }
        return list
    }
    private var endpoint: NovaEndpoint { choices.first { $0.key == endpointKey } ?? device.selection }

    var body: some View {
        ReceivingCardPanel(endpoint: endpoint, portCount: ControllerModels.portCount(model: device.models[endpoint.key]),
                           model: device.models[endpoint.key]) {
            Picker("", selection: Binding(get: { endpoint.key }, set: { endpointKey = $0 })) {
                ForEach(choices, id: \.key) { choice in
                    Label(device.title(for: choice), systemImage: choice.isUSB ? "cable.connector" : "network").tag(choice.key)
                }
            }
            .labelsHidden()
            .frame(width: 230)
        }
        .id(endpoint.key)
        .onAppear { device.scanUSB() }
    }
}

struct ReceivingCardPanel<ControllerPicker: View>: View {
    let endpoint: NovaEndpoint
    /// Ethernet outputs of the controller when its model is known.
    var portCount: Int? = nil
    /// Model name, for connector numbering (MEE410).
    var model: String? = nil
    private func label(_ index: Int) -> Int { ControllerModels.portLabel(model: model, index: index) }
    @ViewBuilder let controllerPicker: () -> ControllerPicker

    @State private var cards: [RegisterInventory.Card] = []
    @State private var ports: [Int] = []          // 0-based ports shown as headers in the card menu
    @State private var started = false
    @State private var selectedCard: String?
    @State private var snapshot: ReceivingCardSnapshot?
    @State private var previous: ReceivingCardSnapshot?      // previous read of the same card, for "what changed"
    @State private var edited: [UInt8] = []
    @State private var cursor: Int?
    @State private var editValue = ""
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var showRaw = false
    @State private var library: [ReceivingCardAPI.LibraryFile] = []
    @State private var confirmWrite = false
    @State private var confirmSave = false
    @State private var busy = false
    @State private var status = "Scan the cards of the selected controller, then read one."
    @State private var error: String?
    // Configuration file (RCFGX) to send
    @State private var rcfgx: RCFGXFile?
    @State private var rcfgxRecords: [RCFGXRecord] = []      // what gets sent (edits applied)
    @State private var rcfgxBin: [UInt8] = []                 // payload as opened
    @State private var rcfgxXML = ""
    @State private var rcfgxEntryNames: (xml: String, bin: String) = ("", "")
    @State private var rcfgxEdits: [Int: UInt8] = [:]         // parameter-block offset → new value
    @State private var exportingRCFGX = false
    @State private var exportName = ""
    @State private var exportDocument = RCFGXExportDocument(data: Data())
    @State private var importingRCFGX = false
    @State private var sendProgress: Double?
    @State private var confirmSendAll = false
    @State private var confirmSendCard = false

    private var current: RegisterInventory.Card? { cards.first { $0.id == selectedCard } }
    private var pending: [Range<Int>] {
        guard let snapshot else { return [] }
        return ReceivingCardRegisters.changedRanges(from: snapshot.parameters, to: edited)
    }
    private var sincePrevious: Set<Int> {
        guard let snapshot, let previous, previous.port == snapshot.port, previous.card == snapshot.card else { return [] }
        return Set(ReceivingCardRegisters.changedRanges(from: previous.parameters, to: snapshot.parameters).flatMap { Array($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                controllerPicker()
                cardMenu.frame(width: 250)
                Button { read() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Read the card again (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(busy || current == nil)
                Button { Task { await scan(thenReadFirst: false) } } label: { Image(systemName: "magnifyingglass") }
                    .help("Search the cards again (after re-plugging a cable)")
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }

            if let snapshot { cardSummary(snapshot) }
            configurationFile
            if let snapshot {
                DisclosureGroup("Raw parameter block (diagnostics)", isExpanded: $showRaw) {
                    parameterEditor(snapshot)
                }
                .font(.callout)
            }
        }
        .task {
            // Opening the page (or choosing another controller) scans and reads port 1, card 1.
            guard !started else { return }
            started = true
            await scan(thenReadFirst: true)
        }
        .alert(writeTitle, isPresented: $confirmWrite) {
            Button("Write") { write() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(writeMessage)
        }
        .fileImporter(isPresented: $importingRCFGX, allowedContentTypes: [UTType(filenameExtension: "rcfgx") ?? .data, .data]) { result in
            openRCFGX(result)
        }
        .alert("Send \(rcfgx?.name ?? "") to every receiving card?", isPresented: $confirmSendAll) {
            Button("Send") { sendRCFGX(toAll: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(sizeWarning + "All receiving cards on \(endpoint.label). Not saved until Save to cards.")
        }
        .alert("Send \(rcfgx?.name ?? "") to port \((current?.port ?? 0) + 1), card \((current?.index ?? 0) + 1)?", isPresented: $confirmSendCard) {
            Button("Send") { sendRCFGX(toAll: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(sizeWarning + "Not saved until Save to cards.")
        }
        .alert("Save on all receiving cards?", isPresented: $confirmSave) {
            Button("Save") { saveAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every receiving card on \(endpoint.label) keeps its current settings after a power cycle.")
        }
    }

    /// Warns when the file is made for another cabinet size than the card runs now.
    private var sizeWarning: String {
        guard let rcfgx, let s = snapshot, let w = Int(rcfgx.value("Width")), let h = Int(rcfgx.value("Height")),
              w != s.width || h != s.height else { return "" }
        return "⚠︎ The file is for a \(w) × \(h) cabinet, the card runs \(s.width) × \(s.height).\n"
    }

    private var writeTitle: String {
        guard let s = snapshot else { return "Write to card?" }
        return "Write \(pending.count) change(s) to port \(s.port + 1), card \(s.card + 1)?"
    }

    private var writeMessage: String {
        var parts: [String] = []
        for range in pending {
            var text = String(format: "0x%03X", range.lowerBound)
            if range.count > 1 { text += "…" + String(format: "0x%03X", range.upperBound - 1) }
            parts.append(text)
        }
        return "Bytes: " + parts.joined(separator: ", ") + ".\nThe card applies them immediately (the image may change or go dark). Not saved — a power cycle restores the stored settings, unless you press Save."
    }

    private func changeList(_ before: [UInt8], _ after: [UInt8]) -> String {
        var parts: [String] = []
        for i in sincePrevious.sorted() where i < before.count && i < after.count {
            parts.append(String(format: "0x%03X %02X→%02X", i, Int(before[i]), Int(after[i])))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Configuration file (RCFGX)

    private var configurationFile: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    openMenu
                    if let rcfgx {
                        Text(rcfgx.name + (rcfgxEdits.isEmpty ? "" : " · edited"))
                            .font(.callout.weight(.medium))
                            .help(rcfgx.value("RCFGXVersion"))
                        matchBadge
                    } else {
                        Text("No configuration open").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if rcfgx != nil {
                        Button("Reset edits") { resetEdits() }.disabled(rcfgxEdits.isEmpty)
                        Button("Save as…") { exportEdited() }
                    }
                }
                if let rcfgx {
                    let fields = Self.rcfgxFields.compactMap { field -> (String, String)? in
                        let v = rcfgx.value(field.key)
                        return v == "—" ? nil : (field.label, field.format(v))
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 6) {
                        ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.0).font(.caption).foregroundStyle(.secondary)
                                Text(f.1).font(.callout.monospaced())
                            }
                        }
                    }
                    Divider()
                    editor
                    Divider()
                    HStack(spacing: 10) {
                        if let sendProgress {
                            ProgressView(value: sendProgress).frame(maxWidth: 240)
                            Text("\(Int(sendProgress * 100)) %").font(.caption.monospaced())
                        }
                        Spacer()
                        Button("Read this card → RCFGX…") { readCardToRCFGX() }
                            .disabled(busy || current == nil)
                            .help("Reads the selected card's configuration into the opened file's records (same cabinet type) and saves it as a new .rcfgx — for analysis and backup. Do not send it to cards to fix them: read-back data is not what a card needs (verified 23.10.2026); send the original RCFGX instead.")
                        Button("Send to this card…") { confirmSendCard = true }
                            .disabled(busy || current == nil)
                        Button("Send to all cards…") { confirmSendAll = true }
                            .disabled(busy)
                        Button("Save to cards…") { confirmSave = true }
                            .disabled(busy)
                    }
                }
            }
            .padding(6)
        } label: {
            Text("Configuration").font(.headline)
        }
    }

    /// Open a configuration from a file or — on controllers with a web interface — from the controller's library.
    private var openMenu: some View {
        Menu("Open") {
            Button("From file…") { importingRCFGX = true }
            if case .network(let ip) = endpoint {
                Section("Controller library") {
                    if library.isEmpty { Text("empty or not available") }
                    ForEach(library) { item in
                        Button(item.cabinetInfo.name) { openLibrary(item, ip: ip) }
                    }
                }
            }
        }
        .fixedSize()
        .task {
            if case .network(let ip) = endpoint { library = (try? await ReceivingCardAPI(ip: ip).library()) ?? [] }
        }
    }

    @ViewBuilder
    private var matchBadge: some View {
        if let block = snapshot?.parameters, !rcfgxRecords.isEmpty {
            if RCFGXBin.matches(rcfgxRecords, block: block) {
                Label("on this card", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
            } else {
                Label("card differs", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.caption)
            }
        }
    }

    private struct RCFGXField {
        let key: String, label: String
        var format: (String) -> String = { $0 }
    }

    /// Parameters shown from the file (names as in NovaLCT's Receiving Card page).
    private static var rcfgxFields: [RCFGXField] { [
        .init(key: "Width", label: "Cabinet W"), .init(key: "Height", label: "Cabinet H"),
        .init(key: "StandardLedModuleProp/ScanType", label: "Scan", format: { $0.replacingOccurrences(of: "Scan_", with: "1/") }),
        .init(key: "StandardLedModuleProp/DecType", label: "Decoder", format: { $0.replacingOccurrences(of: "Decode", with: "") }),
        .init(key: "DclkUnitCycle", label: "DCLK", format: { v in Double(v).map { String(format: "%.1f MHz", 125 / $0) } ?? v }),
        .init(key: "GrayDepth", label: "Grayscale", format: { "\($0) bit" }),
        .init(key: "SubFields", label: "Refresh multiplier"),
        .init(key: "BlankUnitNumPerScan", label: "Row blanking"),
        .init(key: "GammaValue", label: "Gamma", format: { v in Double(v).map { String(format: "%.1f", $0 / 10) } ?? v }),
    ] }

    private func openRCFGX(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try load(Data(contentsOf: url), name: url.lastPathComponent)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openLibrary(_ item: ReceivingCardAPI.LibraryFile, ip: String) {
        busy = true; error = nil; status = "Loading \(item.cabinetInfo.name) from the controller…"
        Task { @MainActor in
            defer { busy = false }
            do {
                let file = try await ReceivingCardAPI(ip: ip).exportLibraryFile(item)
                try load(file.data, name: item.cabinetInfo.name + ".rcfgx")
            } catch { self.error = error.localizedDescription }
        }
    }

    private func load(_ data: Data, name: String) throws {
        do {
            let file = try RCFGXFile(data: data, name: name)
            let archive = try RCFGXArchive(data)
            guard let entry = archive.entries.first(where: { $0.name.lowercased().hasSuffix(".bin") }) else {
                throw RCFGXError.invalid("No .bin payload.")
            }
            let bin = [UInt8](try archive.extract(entry))
            let records = try RCFGXBin.records(bin)
            guard let xmlEntry = archive.entries.first(where: { $0.name.lowercased().hasSuffix(".xml") }) else {
                throw RCFGXError.invalid("No .xml configuration.")
            }
            rcfgxXML = String(decoding: try archive.extract(xmlEntry), as: UTF8.self)
            rcfgxEntryNames = (xmlEntry.name, entry.name)
            rcfgx = file
            rcfgxBin = bin
            rcfgxEdits = [:]
            rcfgxRecords = records
            RCFGXLibrary.save(data, name: name)      // agents can use it from now on (Agent API: /v1/rcfgx)
            error = nil
            status = "Opened \(file.name)."
        }
    }

    private func sendRCFGX(toAll: Bool) {
        guard let file = rcfgx else { return }
        let target = endpoint, records = rcfgxRecords
        let port = toAll ? nil : current?.port, card = toAll ? nil : current?.index
        if !toAll && (port == nil || card == nil) { return }
        busy = true; error = nil; sendProgress = 0
        status = "Sending \(file.name) to " + (toAll ? "all receiving cards" : "port \(port! + 1), card \(card! + 1)") + "…"
        let progress = $sendProgress
        Task { @MainActor in
            var sent = false
            do {
                try await RCFGXBin.send(target, records: records, port: port, card: card) { done, total in
                    Task { @MainActor in progress.wrappedValue = Double(done) / Double(max(total, 1)) }
                }
                status = "\(file.name) sent (not saved yet)."
                sent = true
            } catch {
                self.error = "Send: \(error.localizedDescription)"
                status = "Send stopped — send again or power-cycle."
            }
            busy = false
            sendProgress = nil
            guard sent else { return }
            if toAll { await scan(thenReadFirst: true) }      // every card may have a new size
            else if current != nil { read() }
        }
    }

    // MARK: Editing the opened file

    private func value(_ offset: Int) -> Int? { RCFGXEdit.byte(rcfgxRecords, offset) }
    /// Records as opened, without edits.
    private var originalRecords: [RCFGXRecord] { (try? RCFGXBin.records(rcfgxBin)) ?? [] }

    private func setEdits(_ changes: [Int: Int]) {
        var edits = rcfgxEdits
        for (offset, v) in changes {
            let original = RCFGXEdit.byte((try? RCFGXBin.records(rcfgxBin)) ?? [], offset)
            if original == v { edits[offset] = nil } else { edits[offset] = UInt8(clamping: v) }
        }
        do {
            rcfgxRecords = try RCFGXBin.records(try RCFGXEdit.apply(rcfgxBin, edits: edits))
            rcfgxEdits = edits
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private var editor: some View {
        let cycle = value(0x38) ?? 0
        let phase = value(0x39) ?? 0
        let duty = value(0x08) ?? 50
        let lineChange = value(0x2C) ?? 0
        let ghostEnd = value(0xAD) ?? 1
        let blanking = Int(rcfgx?.value("BlankUnitNumPerScan") ?? "") ?? 0
        let ghostMode = value(0x18E)
        // Byte positions were found on XC160-1 / ICND2065 files. For any other file a field is offered only
        // when the file's own XML value sits at that byte (so the position is right for this file too).
        func confirmed(_ key: String, _ offset: Int) -> Bool {
            guard let x = Int(rcfgx?.value(key) ?? ""), let b = RCFGXEdit.byte(originalRecords, offset) else { return false }
            return x == b
        }
        let ghostXML = rcfgx?.value("ShadowEliminationEnhancedEnable")
        let ghostOK = (ghostXML == "true" && RCFGXEdit.byte(originalRecords, 0x18E) == 0x0D)
            || (ghostXML == "false" && RCFGXEdit.byte(originalRecords, 0x18E) == 0x15)
        let dclkOK = confirmed("DclkUnitCycle", 0x38) && confirmed("DclkPhase", 0x39) && confirmed("DclkHighRatio", 0x08)
        let rowOK = confirmed("RowChangePoint", 0x2C) && confirmed("CtrlEndPoint", 0xAD)
        return Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
            GridRow {
                if dclkOK && cycle >= 2 {
                    Stepper("DCLK phase  \(phase)", value: Binding(get: { phase }, set: { setEdits([0x39: $0]) }), in: 0...(cycle - 1))
                    Stepper("DCLK duty  \(duty) %", value: Binding(get: { duty }, set: { v in
                        setEdits([0x08: v, 0x3A: RCFGXEdit.dclkHigh(cycle: cycle, duty: v)])
                    }), in: 25...75)
                }
                if ghostOK && (ghostMode == 0x0D || ghostMode == 0x15) {
                    Toggle("Ghost elimination", isOn: Binding(get: { ghostMode == 0x0D }, set: { on in
                        setEdits([0x18E: on ? 0x0D : 0x15])
                    }))
                }
            }
            GridRow {
                if rowOK {
                Stepper("Line changing  \(lineChange)", value: Binding(get: { lineChange }, set: { setEdits([0x2C: $0]) }),
                        in: 0...max(0, ghostEnd - 1))
                }
                if rowOK && blanking >= 2 {
                    Stepper("Ghost control end  \(ghostEnd)", value: Binding(get: { ghostEnd }, set: { v in
                        var changes = [0xAD: v]
                        if lineChange >= v { changes[0x2C] = v - 1 }     // NovaLCT keeps line changing below it
                        setEdits(changes)
                    }), in: 1...(blanking - 1))
                }
            }
        }
        .help("Refresh multiplier, DCLK/GCLK frequency, row blanking and grayscale rebuild NovaLCT's timing tables — change those in NovaLCT and open the exported file.")
        .fileExporter(isPresented: $exportingRCFGX, document: exportDocument, contentType: UTType(filenameExtension: "rcfgx") ?? .data,
                      defaultFilename: exportName.isEmpty
                        ? ((rcfgx?.name ?? "config.rcfgx") as NSString).deletingPathExtension + " (NovaMac).rcfgx" : exportName) { result in
            if case .failure(let e) = result { error = e.localizedDescription } else { status = exportName.isEmpty ? "Edited configuration saved." : "\(exportName) saved." }
            exportName = ""
        }
    }

    private func resetEdits() {
        rcfgxEdits = [:]
        rcfgxRecords = (try? RCFGXBin.records(rcfgxBin)) ?? rcfgxRecords
    }

    /// Reads the selected card back into the opened file's records (the template gives the record list and the
    /// ScanBoardProperty XML, which a card does not store) and offers it as a new .rcfgx.
    private func readCardToRCFGX() {
        guard let card = current, !rcfgxBin.isEmpty else { return }
        let target = endpoint, template = rcfgxBin, xml = rcfgxXML, names = rcfgxEntryNames
        let label = "Port \(card.port + 1) card \(card.index + 1)"
        busy = true; error = nil; sendProgress = 0
        status = "Reading \(label) into \(rcfgx?.name ?? "the opened file")'s records…"
        let progress = $sendProgress
        Task { @MainActor in
            defer { busy = false; sendProgress = nil }
            do {
                let result = try await RCFGXBin.readBack(target, template: template, port: card.port, card: card.index) { done, total in
                    Task { @MainActor in progress.wrappedValue = Double(done) / Double(max(total, 1)) }
                }
                let records = try RCFGXBin.records(result.bin)
                var values: [String: String] = [:]
                if let w = RCFGXEdit.byte(records, 0x17), let w2 = RCFGXEdit.byte(records, 0x18), w + w2 * 256 > 0 { values["Width"] = String(w + w2 * 256) }
                if let h = RCFGXEdit.byte(records, 0x19), let h2 = RCFGXEdit.byte(records, 0x1A), h + h2 * 256 > 0 { values["Height"] = String(h + h2 * 256) }
                let newXML = RCFGXEdit.updateXML(xml, values)
                exportDocument = RCFGXExportDocument(data: RCFGXEdit.zip([(names.xml, Array(newXML.utf8)), (names.bin, result.bin)]))
                exportName = ((rcfgx?.name ?? "config.rcfgx") as NSString).deletingPathExtension + " – \(label).rcfgx"
                status = "\(label) read." + (result.kept.isEmpty ? "" : " Kept from the template (not readable or commands): "
                    + result.kept.map { String(format: "0x%08X", $0) }.joined(separator: ", ") + ".")
                exportingRCFGX = true
            } catch {
                self.error = "Read to RCFGX: \(error.localizedDescription)"
            }
        }
    }

    /// Writes the edited payload and the matching XML values into a new .rcfgx (NovaLCT can import it).
    private func exportEdited() {
        do {
            let bin = try RCFGXEdit.apply(rcfgxBin, edits: rcfgxEdits)
            let records = try RCFGXBin.records(bin)
            func v(_ o: Int) -> String { RCFGXEdit.byte(records, o).map { String($0) } ?? "" }
            var values: [String: String] = [:]
            if rcfgxEdits[0x39] != nil { values["DclkPhase"] = v(0x39) }
            if rcfgxEdits[0x08] != nil { values["DclkHighRatio"] = v(0x08); values["DclkHigh"] = v(0x3A) }
            if rcfgxEdits[0x2C] != nil { values["RowChangePoint"] = v(0x2C) }
            if rcfgxEdits[0xAD] != nil { values["CtrlEndPoint"] = v(0xAD) }
            if rcfgxEdits[0x18E] != nil { values["ShadowEliminationEnhancedEnable"] = RCFGXEdit.byte(records, 0x18E) == 0x0D ? "true" : "false" }
            let xml = RCFGXEdit.updateXML(rcfgxXML, values)
            exportDocument = RCFGXExportDocument(data: RCFGXEdit.zip([(rcfgxEntryNames.xml, Array(xml.utf8)), (rcfgxEntryNames.bin, bin)]))
            exportingRCFGX = true
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Card list

    /// Ports as headers, the cards of each port (position in its cable chain) as items.
    private var cardMenu: some View {
        Picker("", selection: Binding(get: { selectedCard ?? "" }, set: { id in
            guard cards.contains(where: { $0.id == id }), id != selectedCard else { return }
            selectedCard = id
            read()
        })) {
            if cards.isEmpty { Text(busy ? "Scanning…" : "No cards").tag("") }
            ForEach(ports, id: \.self) { p in
                Section("Port \(label(p))") {
                    let list = cards.filter { $0.port == p }
                    if list.isEmpty {
                        Text("No cards on port \(label(p))").tag("empty-\(p)")
                    }
                    ForEach(list) { card in
                        Text(cardTitle(card)).tag(card.id)
                    }
                }
            }
        }
        .labelsHidden()
        .disabled(busy && cards.isEmpty)
    }

    private func cardTitle(_ card: RegisterInventory.Card) -> String {
        var text = "Port \(label(card.port)) · Card \(card.index + 1)"
        if let w = card.width, let h = card.height { text += "  (\(w) × \(h))" }
        return text
    }

    // MARK: Information

    private func cardSummary(_ s: ReceivingCardSnapshot) -> some View {
        var items: [(String, String)] = []
        if let xml = s.cabinetXML {
            let info = CabinetDescription(xml: xml)
            let wanted = ["Modules", "Module width (px)", "Module height (px)", "Scan type", "Decoder", "Driver chip code"]
            for (label, value) in info.fields where wanted.contains(label) {
                var text = value
                if label == "Modules" { text = String(value.prefix { $0 != " " }) }
                if label == "Decoder" { text = value.replacingOccurrences(of: "Decode", with: "") }
                if label == "Scan type" { text = value.replacingOccurrences(of: "Scan_", with: "1/") }
                items.append((label.replacingOccurrences(of: " (px)", with: ""), text))
            }
        }
        var versions = ""
        if let f = s.fpga { items.append(("FPGA", f.version)); versions += "FPGA " + f.version + " " + f.name }
        if let m = s.mcu { versions += "\nMCU " + m.version + " " + m.name }
        if let m = s.mcu { items.append(("MCU", m.version)) }
        return GroupBox {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resolution").font(.caption).foregroundStyle(.secondary)
                    Text("\(s.width) × \(s.height)")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("\(s.width * s.height) px · port \(label(s.port)), card \(s.card + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.trailing, 8)
                Divider().frame(height: 56)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.0).font(.caption).foregroundStyle(.secondary)
                        Text(item.1).font(.callout.monospaced()).lineLimit(1)
                    }
                }
            }
            }
            .padding(6)
            .help(versions)
        } label: {
            HStack {
                Text("Receiving card").font(.headline)
                Spacer()
                if let xml = s.cabinetXML {
                    Button("Copy cabinet XML") { copy(xml) }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    // MARK: Parameter block (0x02000000, 512 bytes)

    private func parameterEditor(_ s: ReceivingCardSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    labeled("Width (0x17)") {
                        TextField("", text: $widthText).frame(width: 70).onSubmit { setU16(0x17, widthText) }
                    }
                    labeled("Height (0x19)") {
                        TextField("", text: $heightText).frame(width: 70).onSubmit { setU16(0x19, heightText) }
                    }
                    Divider().frame(height: 30)
                    labeled(cursor.map { String(format: "Bytes at 0x%03X (hex)", $0) } ?? "Click a byte") {
                        TextField("e.g. A0 00", text: $editValue).frame(width: 150)
                            .onSubmit { setBytes() }
                            .disabled(cursor == nil)
                    }
                    Spacer()
                }
                .textFieldStyle(.roundedBorder)

                hexGrid(s)

                HStack(spacing: 14) {
                    legend(.orange, "edited")
                    legend(.cyan, "changed since last read")
                    legend(.green, "width / height")
                    Spacer()
                }
                .font(.caption)

                if !sincePrevious.isEmpty, let previous {
                    Text("Changed since the read at \(previous.readAt.formatted(date: .omitted, time: .standard)): " + changeList(previous.parameters, s.parameters))
                        .font(.caption.monospaced()).foregroundStyle(.cyan).textSelection(.enabled)
                }

                HStack {
                    Button("Revert edits") { edited = s.parameters; syncFields() }
                        .disabled(pending.isEmpty)
                    Button("Copy hex") { copy(hexDump(s.parameters)) }
                    Spacer()
                    Button("Write to card…") { confirmWrite = true }
                        .disabled(busy || pending.isEmpty)
                }
            }
            .padding(6)
        }
    }

    private static var knownFields: Set<Int> { [0x17, 0x18, 0x19, 0x1A] }

    private func byteColor(_ i: Int, edited: Bool, changed: Set<Int>) -> Color {
        if edited { return .orange }
        if changed.contains(i) { return .cyan }
        if Self.knownFields.contains(i) { return .green }
        return .primary
    }

    private func hexGrid(_ s: ReceivingCardSnapshot) -> some View {
        let changedBefore = sincePrevious
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<(s.parameters.count / 16), id: \.self) { row in
                HStack(spacing: 0) {
                    Text(String(format: "%03X  ", row * 16)).foregroundStyle(.secondary)
                    ForEach(0..<16, id: \.self) { column in
                        let i = row * 16 + column
                        let value: Int = Int(i < edited.count ? edited[i] : s.parameters[i])
                        let isEdited: Bool = i < edited.count && edited[i] != s.parameters[i]
                        Text(String(format: "%02X", value))
                            .foregroundStyle(byteColor(i, edited: isEdited, changed: changedBefore))
                            .padding(.horizontal, 3)
                            .background(cursor == i ? Color.accentColor.opacity(0.35) : Color.clear)
                            .onTapGesture { select(i) }
                        if column == 7 { Text(" ") }
                    }
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.disabled)
    }

    // MARK: Actions

    private func scan(thenReadFirst: Bool) async {
        let target = endpoint
        busy = true; error = nil; status = "Scanning \(target.label)…"
        do {
            // Known model: its outputs. Unknown: up to 32 (fibre controllers; empty ports answer at once).
            var probe = Array(0..<(portCount ?? 32))
            var shown: [Int]? = nil
            if case .network(let ip) = target, let netports = try? await UnicoTopology.netports(ip: ip), !netports.isEmpty {
                // The controller lists a port once per output/slot entry: keep each port number once.
                shown = Array(Set(netports.map(\.netportIndex))).sorted()           // every port of the controller
                let linked = Array(Set(netports.filter { $0.linkState == 1 }.map(\.netportIndex))).sorted()
                if !linked.isEmpty { probe = linked }                                 // probe only ports with link
            }
            var seen = Set<String>()
            let found = try await RegisterInventory.read(target, portList: Array(Set(probe)).sorted()).filter { seen.insert($0.id).inserted }
            cards = found
            let highest = found.map(\.port).max() ?? 0
            ports = ControllerModels.physicalPorts(model: model) ?? shown ?? Array(0...max(1, highest))
            if selectedCard == nil || !found.contains(where: { $0.id == selectedCard }) {
                selectedCard = found.sorted { ($0.port, $0.index) < ($1.port, $1.index) }.first?.id
            }
            status = found.isEmpty ? "No receiving card answers on \(target.label)." : "\(found.count) receiving card(s) answer."
        } catch {
            self.error = error.localizedDescription
            busy = false
            return
        }
        busy = false
        if thenReadFirst, current != nil { read() }
    }

    private func read() {
        guard let card = current else { return }
        let target = endpoint
        busy = true; error = nil; status = "Reading port \(label(card.port)), card \(card.index + 1)…"
        Task { @MainActor in
            defer { busy = false }
            do {
                let fresh = try await ReceivingCardRegisters.read(target, port: card.port, card: card.index)
                if let snapshot, snapshot.port == fresh.port, snapshot.card == fresh.card { previous = snapshot }
                else { previous = nil }
                snapshot = fresh
                edited = fresh.parameters
                // Keep the card menu in step with what the card runs now (size changes after a send).
                if let i = cards.firstIndex(where: { $0.port == fresh.port && $0.index == fresh.card }) {
                    cards[i].width = fresh.width
                    cards[i].height = fresh.height
                }
                syncFields()
                status = "Read port \(label(card.port)), card \(card.index + 1)." + (sincePrevious.isEmpty ? "" : " \(sincePrevious.count) byte(s) changed since the previous read (cyan).")
            } catch { self.error = error.localizedDescription }
        }
    }

    private func write() {
        guard let s = snapshot else { return }
        let target = endpoint, original = s.parameters, changes = edited
        busy = true; error = nil; status = "Writing…"
        Task { @MainActor in
            defer { busy = false }
            do {
                let back = try await ReceivingCardRegisters.write(target, port: s.port, card: s.card, original: original, edited: changes)
                previous = s
                var updated = s
                updated.parameters = back
                snapshot = updated
                let mismatch = ReceivingCardRegisters.changedRanges(from: changes, to: back)
                edited = back
                syncFields()
                status = mismatch.isEmpty ? "Written and read back: the card holds the new values (not saved)."
                    : "Written, but the card reports different values at " + mismatch.map { String(format: "0x%03X", $0.lowerBound) }.joined(separator: ", ") + "."
            } catch { self.error = error.localizedDescription }
        }
    }

    private func saveAll() {
        let target = endpoint
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await ReceivingCardRegisters.saveAll(target)
                status = "Saved on the cards."
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Editing helpers

    private func select(_ i: Int) {
        cursor = i
        editValue = String(format: "%02X", Int(i < edited.count ? edited[i] : 0))
    }

    private func setBytes() {
        guard let start = cursor else { return }
        let parts = editValue.split(whereSeparator: { $0 == " " || $0 == "," })
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard !bytes.isEmpty, bytes.count == parts.count, start + bytes.count <= edited.count else {
            error = "Enter hex bytes, e.g. A0 00."; return
        }
        error = nil
        for (k, b) in bytes.enumerated() { edited[start + k] = b }
        syncFields()
    }

    private func setU16(_ offset: Int, _ text: String) {
        guard let v = Int(text), (0...65535).contains(v), offset + 1 < edited.count else { error = "Enter 0…65535."; return }
        error = nil
        edited[offset] = UInt8(v & 0xFF)
        edited[offset + 1] = UInt8(v >> 8)
    }

    private func syncFields() {
        guard edited.count > 0x1A else { return }
        widthText = String(Int(edited[0x17]) + Int(edited[0x18]) * 256)
        heightText = String(Int(edited[0x19]) + Int(edited[0x1A]) * 256)
    }

    private func hexDump(_ bytes: [UInt8]) -> String {
        var lines: [String] = []
        for o in stride(from: 0, to: bytes.count, by: 16) {
            let row: [String] = bytes[o..<min(o + 16, bytes.count)].map { String(format: "%02X", Int($0)) }
            lines.append(String(format: "%03X  ", o) + row.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied to the clipboard."
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).foregroundStyle(.secondary)
        }
    }
}


struct RCFGXExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "rcfgx") ?? .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
