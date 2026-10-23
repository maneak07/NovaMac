import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let rcfgx = UTType(importedAs: "com.novastar.rcfgx", conformingTo: .data)
}
private struct RCFGXDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.rcfgx, .zip] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw RCFGXError.invalid("Cannot read file.") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ReceivingCardView: View {
    let ip: String
    @State private var file: RCFGXFile?
    @State private var importing = false
    @State private var exporting = false
    @State private var busy = false
    @State private var status = "Import an RCFGX file to inspect its configuration."
    @State private var error: String?
    @State private var cards: [ReceivingCard] = []
    @State private var selectedPorts: Set<Int> = []
    @State private var confirmingSend = false
    @State private var search = ""
    @State private var library: [ReceivingCardAPI.LibraryFile] = []
    @State private var backup: Data?
    @State private var exportingBackup = false
    @State private var backupName = "ReceivingCard-backup.zip"
    private var targets: [ReceivingCard] { cards.filter { selectedPorts.contains($0.netPortID) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Receiving Card").font(.title2.bold())
                    Text("RCFGX configuration and connected cards").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import RCFGX…") { importing = true }
                Button("Export RCFGX…") { exporting = true }.disabled(file == nil)
            }
            Text(status).font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if busy { ProgressView() }
            fileInformation(file)
            GroupBox("Connected receiving cards • \(ip)") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Read card information") { refresh() }
                        Spacer()
                        Button("Send RCFGX…") { confirmingSend = true }
                            .disabled(file == nil || targets.isEmpty)
                    }
                    if cards.isEmpty {
                        Text("Read the connected cards before selecting a destination.").foregroundStyle(.secondary)
                    } else {
                        Text("Select output ports. Unico applies the configuration to every card on each selected port.").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(Set(cards.map(\.netPortID))).sorted(), id: \.self) { port in
                            Toggle("Port ID \(port) • \(cards.filter { $0.netPortID == port }.count) cards", isOn: Binding(get: { selectedPorts.contains(port) }, set: { if $0 { selectedPorts.insert(port) } else { selectedPorts.remove(port) } }))
                        }
                        ForEach(cards) { card in
                            HStack(alignment: .top) {
                                Text("#\(card.cabinetIndex + 1)").monospacedDigit().frame(width: 32)
                                VStack(alignment: .leading) {
                                    Text(card.cabinetBaseInfo.modelName).bold()
                                    Text("Firmware \(card.cabinetBaseInfo.workVer)").font(.caption)
                                }
                                Spacer()
                                Text("\(card.cabinetPhysicalInfo.width) × \(card.cabinetPhysicalInfo.height)")
                                Text("1/\(card.cabinetBaseInfo.scanNumber) scan")
                                Text("\(card.cabinetBaseInfo.grayScale) bit")
                                Text("\(card.cabinetBaseInfo.refreshRate) Hz")
                                Button("Readback…") { readback(card) }
                            }.textSelection(.enabled)
                        }
                    }
                    Text("Readback saves Unico’s ZIP backup (settings + firmware). It is not an RCFGX file. Export RCFGX saves the open file unchanged.").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            GroupBox("Controller RCFGX library") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Read library") { readLibrary() }
                    ForEach(library) { item in
                        HStack {
                            Text(item.cabinetInfo.name)
                            Spacer()
                            Button("Open RCFGX") { openLibrary(item) }
                        }
                    }
                    Text("Open a library file to inspect it and export it to your Mac. Sending is a separate action.").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
        }
        .disabled(busy)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.rcfgx, .data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw RCFGXError.invalid("File exceeds 32 MB.") }
                let parsed = try RCFGXFile(data: Data(contentsOf: url), name: url.lastPathComponent)
                file = parsed; error = nil; status = "Imported \(parsed.name). No controller settings were changed."
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: file.map { RCFGXDocument(data: $0.data) }, contentType: .rcfgx, defaultFilename: file?.name ?? "Configuration.rcfgx") { result in
            switch result {
            case .success: status = "RCFGX exported with the original XML and BIN payload intact."; error = nil
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .fileExporter(isPresented: $exportingBackup, document: backup.map { RCFGXDocument(data: $0) }, contentType: .zip, defaultFilename: backupName) { result in
            switch result {
            case .success: status = "Card backup saved as ZIP."
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .confirmationDialog("Apply \(file?.name ?? "RCFGX") to \(targets.count) receiving cards?", isPresented: $confirmingSend, titleVisibility: .visible) {
            Button("Send configuration") { send() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Controller: \(ip). Ports: \(selectedPorts.sorted().map(String.init).joined(separator: ", ")). This changes module scanning and cabinet settings and may interrupt the picture. File cabinet: \(file?.cabinetSize ?? "—").")
        }
        .onChange(of: ip) { _, _ in cards = []; selectedPorts = []; library = []; backup = nil; error = nil }
    }
    private func refresh() {
        let address = ip
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await ReceivingCardAPI(ip: address).cards()
                guard address == ip else { return }
                cards = result; selectedPorts = selectedPorts.intersection(Set(result.map(\.netPortID)))
                status = "Read \(result.count) receiving cards from \(address)."
            } catch { cards = []; selectedPorts = []; self.error = error.localizedDescription }
        }
    }
    private func send() {
        guard let file, !targets.isEmpty else { return }
        let destination = ip, ids = targets.map(\.id), ports = selectedPorts
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let api = ReceivingCardAPI(ip: destination)
                let current = try await api.cards().filter { ports.contains($0.netPortID) }
                guard Set(current.map(\.id)) == Set(ids) else { throw RCFGXError.invalid("Connected cards changed. Read the cards and select destinations again.") }
                status = "Uploading \(file.name) to the controller library…"
                let id = try await api.upload(file)
                status = "Applying configuration to \(ids.count) cards…"
                try await api.apply(rcfgxID: id, cabinetIDs: ids)
                status = "Controller accepted the configuration for \(ids.count) cards. Check the LED picture. Re-read the cards and check persistence before relying on these settings after a restart."
                cards = try await api.cards()
            } catch { self.error = error.localizedDescription; status = "Operation stopped. Read card information before retrying; an upload or apply may already have completed." }
        }
    }
    private func readLibrary() {
        let address = ip
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await ReceivingCardAPI(ip: address).library()
                guard address == ip else { return }
                library = result; status = "Read \(result.count) RCFGX files from the controller library."
            } catch { library = []; self.error = error.localizedDescription }
        }
    }
    private func openLibrary(_ item: ReceivingCardAPI.LibraryFile) {
        let address = ip
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await ReceivingCardAPI(ip: address).exportLibraryFile(item)
                guard address == ip else { return }
                file = result; status = "Opened \(result.name) from the controller library. Cards were not changed."
            } catch { self.error = error.localizedDescription }
        }
    }
    private func readback(_ card: ReceivingCard) {
        let address = ip
        busy = true; error = nil; status = "Reading card #\(card.cabinetIndex + 1)…"
        Task { @MainActor in
            defer { busy = false }
            do {
                let data = try await ReceivingCardAPI(ip: address).readback(cardID: card.id)
                guard address == ip else { return }
                backup = data; backupName = "Card-\(card.id)-backup.zip"; exportingBackup = true
                status = "Read settings and firmware from card #\(card.cabinetIndex + 1). Choose where to save the ZIP backup."
            } catch { self.error = error.localizedDescription }
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).textSelection(.enabled) }
    }
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        }
    }
    private func fileInformation(_ file: RCFGXFile?) -> some View {
        let columns = [GridItem(.adaptive(minimum: 210), spacing: 16)]
        return VStack(alignment: .leading, spacing: 16) {
            Text(file.map { "File: \($0.name)" } ?? "No RCFGX file loaded").font(.headline)
            Text("Configuration fields are read-only. Import and export preserve the complete RCFGX; parameter editing is not available yet.")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("Module Information") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    field("Chip", file.map { "Code " + $0.value("StandardLedModuleProp/DriverChipType/ChipCode") } ?? "—")
                    field("Size", file?.moduleSize ?? "—")
                    field("Scanning Type", value(file, "StandardLedModuleProp/ScanType").replacingOccurrences(of: "Scan_", with: "1/"))
                    field("Decoding Type", value(file, "StandardLedModuleProp/DecType").replacingOccurrences(of: "Decode", with: "").replacingOccurrences(of: "_", with: "/"))
                    field("Data Groups", value(file, "StandardLedModuleProp/DataGroup"))
                }.padding(10)
            }
            GroupBox("Cabinet Information") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    field("Regular / Irregular", flag(file, "IsIrRegular", yes: "Irregular", no: "Regular"))
                    field("Width (Pixel)", value(file, "Width"))
                    field("Height (Pixel)", value(file, "Height"))
                    field("Module Cascade", value(file, "ModCascadeType").replacingOccurrences(of: "RightLeft", with: "From Right to Left"))
                    field("Module Columns / Rows", file.map { "\($0.value("ModuleCols")) × \($0.value("ModuleRows"))" } ?? "—")
                    field("Rotation", value(file, "CabinetRotateAngle"))
                }.padding(10)
            }
            GroupBox("Performance Settings") {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        field("Big Loading Capacity", flag(file, "IsSupportHighLoad"))
                        field("18bit+", flag(file, "Enable18BitModel"))
                        field("Driver Version", "Not available in parsed data")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            performanceLeft(file).frame(minWidth: 280)
                            performanceRight(file).frame(minWidth: 280)
                        }
                        VStack(spacing: 16) { performanceLeft(file); performanceRight(file) }
                    }
                }.padding(10)
            }
            GroupBox("Configuration Information") {
                VStack(spacing: 8) {
                    row("Current Receiving Card", cards.isEmpty ? "Read card information to identify connected cards" : Set(cards.map { $0.cabinetBaseInfo.modelName }).sorted().joined(separator: ", "))
                    row("Firmware Version", cards.isEmpty ? "—" : Set(cards.map { $0.cabinetBaseInfo.workVer }).sorted().joined(separator: ", "))
                    row("Config File Software Version", value(file, "RCFGXVersion"))
                    row("Brightness in RCFGX (0–255)", value(file, "Brightness"))
                }.padding(10)
            }
            if let file {
                DisclosureGroup("All XML values") {
                    TextField("Search parameter", text: $search).textFieldStyle(.roundedBorder)
                    LazyVStack(spacing: 8) {
                        ForEach(file.fields.keys.sorted().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { key in
                            row(key, file.value(key).count > 160 ? "Binary/table data (\(file.value(key).count) characters)" : file.value(key)).font(.caption)
                        }
                    }
                }
            }
        }
    }
    private func value(_ file: RCFGXFile?, _ key: String) -> String { file?.value(key) ?? "—" }
    private func flag(_ file: RCFGXFile?, _ key: String, yes: String = "Enabled", no: String = "Disabled") -> String {
        switch file?.fields[key] { case "true": return yes; case "false": return no; default: return "—" }
    }
    private func performanceLeft(_ file: RCFGXFile?) -> some View {
        VStack(spacing: 16) {
            GroupBox("Data Clock") {
                VStack(spacing: 10) {
                    field("DCLK Frequency (MHz)", "Calculation not verified")
                    field("DCLK Phase", value(file, "DclkPhase"))
                    field("DCLK Duty Cycle (%)", value(file, "DclkHighRatio"))
                    row("DCLK cycle (file)", value(file, "DclkUnitCycle")).font(.caption)
                }.padding(8)
            }
            GroupBox("Performance Parameters") {
                VStack(spacing: 10) {
                    field("Refresh Rate (Hz)", "Read from connected card below")
                    field("Grayscale (Bit)", value(file, "GrayDepth"))
                    field("Refresh Rate Multiplier / Subfields", value(file, "SubFields"))
                    field("Brightness Efficiency (%)", "Calculation not verified")
                }.padding(8)
            }
        }
    }
    private func performanceRight(_ file: RCFGXFile?) -> some View {
        VStack(spacing: 16) {
            GroupBox("Grayscale Clock") {
                VStack(spacing: 10) {
                    field("GCLK Frequency (MHz)", value(file, "GCLKRate2055"))
                    field("Frequency Multiplier", "Calculation not verified")
                }.padding(8)
            }
            GroupBox("Row Decoding") {
                VStack(spacing: 10) {
                    field("Row Blanking Time", value(file, "BlankUnitNumPerScan"))
                    field("Line Changing Time", value(file, "RowChangePoint"))
                    field("Ghost Control Ending", value(file, "CtrlEndPoint"))
                }.padding(8)
            }
            field("Ghost Elimination", flag(file, "IsClearGhost"))
            field("Ghost Elimination Potential", value(file, "ShadowEliminationPotentialLevel"))
        }
    }
}
