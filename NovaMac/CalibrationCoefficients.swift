import SwiftUI

// NovaMac — calibration coefficients kept in the receiving cards and in the modules' flash.
// Captured from NovaLCT "Screen Calibration → Manage Coefficients" on VX2000 Pro (09.11.2026, 14 × 10 cabinets):
//   read from the receiving card:  write dev1 port p card c  0x01000006 = 00
//   read from the modules:         write dev1 port p card c  0x01000007 = 00
//   then NovaLCT polls the same card: read 0x02000200 (256 bytes) with reserved byte 0x09;
//   the card answers ack 02 while it is busy and ack 00 when done (module read: ~3 polls).
// The coefficients do not travel to the computer: the card loads them into its working memory.
// Second capture (same object, 09.11.2026):
//   Save Calibration Coefficients (to the receiving card): write dev1 port p card c  0x01000004 = 00, then the same
//                                   poll (busy ~3 s). (Seam values are saved with the same register = A2 per port.)
//   Save to HW:                     write dst FF dev1 port FF card FFFF  0x01000011 = 00
//   Auto Upload Module Coefficients: write dst FF dev1 port FF card FFFF  0x020001D3 = 55 (it read 05 while off).

nonisolated enum CalibrationCoefficients {
    enum Operation: Sendable {
        case readFromCard, readFromModules, saveToCard
        var register: UInt32 {
            switch self {
            case .readFromCard: return 0x0100_0006
            case .readFromModules: return 0x0100_0007
            case .saveToCard: return 0x0100_0004
            }
        }
        /// How long the cards usually need (capture: save ~3.4 s, module read ~1.5 s) — the first poll waits this long,
        /// because a busy card answers a poll only after the controller's 0.5 s time-out.
        var firstPollDelay: TimeInterval {
            switch self { case .saveToCard: return 2.5; case .readFromModules: return 1.2; case .readFromCard: return 0.5 }
        }
    }

    static let autoUploadRegister: UInt32 = 0x0200_01D3
    static let autoUploadBits = 0x50       // 05 off → 55 on

    /// Runs one operation on one card and waits until the card reports it is done.
    static func run(_ endpoint: NovaEndpoint, _ operation: Operation, port: Int, card: Int, timeout: TimeInterval = 40) async throws {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            try socket.transact(.write(operation.register, [0x00], device: 1, port: UInt8(port), card: UInt16(card)))
            let poll = NovaCommand(device: 1, port: UInt8(port), card: UInt16(card), write: false, reserved: 0x09,
                                   address: 0x0200_0200, length: 256)
            let start = Date()
            while true {
                do {
                    _ = try socket.transact(poll)
                    return
                } catch NovaLinkError.nack(let ack, _) where ack == 0x02 {
                    if Date().timeIntervalSince(start) > timeout {
                        throw NovaLinkError.badResponse("the card stayed busy for \(Int(timeout)) s")
                    }
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
        }
    }

    // MARK: All cards at once

    enum PollState: Sendable { case done, busy, failed(String) }

    /// Sends the command to every card without waiting for each one to finish (the cards work in parallel).
    /// Returns the cards that did not take the command: index → reason.
    static func send(_ endpoint: NovaEndpoint, _ operation: Operation, targets: [[Int]]) async throws -> [Int: String] {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            var failed: [Int: String] = [:]
            for (i, t) in targets.enumerated() {
                do {
                    try socket.transact(.write(operation.register, [0x00], device: 1, port: UInt8(t[0]), card: UInt16(t[1])))
                } catch { failed[i] = error.localizedDescription }
            }
            return failed
        }
    }

    /// One status poll of every listed card (same poll as NovaLCT: 0x02000200 with reserved byte 0x09).
    static func poll(_ endpoint: NovaEndpoint, targets: [[Int]]) async throws -> [PollState] {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            targets.map { t -> PollState in
                let command = NovaCommand(device: 1, port: UInt8(t[0]), card: UInt16(t[1]), write: false, reserved: 0x09,
                                          address: 0x0200_0200, length: 256)
                do { _ = try socket.transact(command); return .done }
                catch NovaLinkError.nack(let ack, _) where ack == 0x02 { return .busy }
                catch { return .failed(error.localizedDescription) }
            }
        }
    }

    /// NovaLCT "Save to HW" on Manage Coefficients: every receiving card stores its parameters.
    static func saveToHardware(_ endpoint: NovaEndpoint) async throws {
        _ = try await NovaLink.run(endpoint, timeout: 3) { socket in
            try socket.transact(.write(0x0100_0011, [0x00], destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF))
        }
    }

    /// Raw byte of 0x020001D3 on one card (auto upload of module coefficients = bits 0x50).
    static func readAutoUpload(_ endpoint: NovaEndpoint, port: Int, card: Int) async throws -> Int {
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            let b = try socket.transact(.read(autoUploadRegister, length: 1, device: 1, port: UInt8(port), card: UInt16(card)))
            guard let v = b.first else { throw NovaLinkError.badResponse("short read") }
            return Int(v)
        }
    }

    /// Switches auto upload on every card, keeping the other bits of the byte as read.
    static func setAutoUpload(_ endpoint: NovaEndpoint, on: Bool, current: Int) async throws {
        let value = UInt8(on ? (current | autoUploadBits) : (current & ~autoUploadBits & 0xFF))
        _ = try await NovaLink.run(endpoint, timeout: 3) { socket in
            try socket.transact(.write(autoUploadRegister, [value], destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF))
        }
    }
}

/// Cabinet map of a screen with per-cabinet selection, and the coefficient reads.
struct CoefficientsPanel: View {
    @ObservedObject var screen: ScreenDocument
    @ObservedObject var device: NovaDevice

    private struct CardRef: Hashable { let port: Int, card: Int }       // both 0-based
    private struct Cabinet: Identifiable { let ref: CardRef; let rect: PixelRect; var id: CardRef { ref } }
    private enum CardStatus { case working, done, failed(String) }

    @State private var selected: Set<CardRef> = []
    @State private var results: [CardRef: CardStatus] = [:]
    @State private var dragRect: CGRect?
    @State private var job: Task<Void, Never>?
    @State private var progress = ""
    @State private var confirmModules = false
    @State private var confirmSaveHW = false
    @State private var autoUploadRaw: Int?

    private var cabinets: [Cabinet] {
        screen.plan.cells.filter { $0.order != nil && !$0.blank }.map {
            Cabinet(ref: CardRef(port: $0.port - 1, card: $0.order! - 1), rect: screen.plan.rect(of: $0))
        }
    }

    private var bounds: (minX: Int, minY: Int, width: Int, height: Int) {
        let r = cabinets.map(\.rect)
        let minX = r.map(\.x).min() ?? 0, minY = r.map(\.y).min() ?? 0
        return (minX, minY, max(1, (r.map(\.maxX).max() ?? 1) - minX), max(1, (r.map(\.maxY).max() ?? 1) - minY))
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("\(selected.count) of \(cabinets.count) cabinets selected").font(.callout)
                    Spacer()
                    Button("Select all") { selected = Set(cabinets.map(\.ref)) }
                    Button("Deselect") { selected.removeAll() }
                }
                if cabinets.isEmpty {
                    Text("No mapped cabinets on this screen. Read the screen from the hardware on Screen Connection first.")
                        .foregroundStyle(.secondary)
                } else {
                    map
                }
                HStack(spacing: 10) {
                    Button("Read from receiving cards") { start(.readFromCard) }
                        .help("Each selected card loads the coefficients stored in it (NovaLCT: Manage Coefficients).")
                    Button("Read from modules") { confirmModules = true }
                        .help("Each selected card loads the coefficients stored in its modules' flash.")
                    Button("Save to cards") { start(.saveToCard) }
                        .help("Each selected card stores its working coefficients in its own flash (NovaLCT: Save Calibration Coefficients).")
                    Button("Save to HW") { confirmSaveHW = true }
                        .help("Every receiving card on the controller stores its parameters (NovaLCT: Save to HW).")
                    Spacer()
                    if job != nil {
                        ProgressView().controlSize(.small)
                        Button("Stop") { job?.cancel() }
                    }
                }
                .disabled(selected.isEmpty && job == nil)
                HStack(spacing: 8) {
                    Toggle("Auto upload module coefficients", isOn: Binding(
                        get: { (autoUploadRaw ?? 0) & CalibrationCoefficients.autoUploadBits == CalibrationCoefficients.autoUploadBits },
                        set: { setAutoUpload($0) }))
                        .disabled(autoUploadRaw == nil || job != nil)
                        .help("Cards load the coefficients from their modules by themselves (NovaLCT: Auto Upload Module Coefficients). Read from the first cabinet; written to every card.")
                    if autoUploadRaw == nil { Text("state not read").font(.caption).foregroundStyle(.secondary) }
                }
                if !progress.isEmpty { Text(progress).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("Click a cabinet to select it, drag across the map to select several. The coefficients are loaded inside the cards (nothing is copied to the Mac) and are not stored until they are saved to the cards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Text("Calibration coefficients — \(screen.name)").font(.headline)
        }
        .task(id: screen.endpoint.key) { await readAutoUpload() }
        .alert("Save to HW?", isPresented: $confirmSaveHW) {
            Button("Save") { saveToHardware() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every receiving card on \(screen.endpoint.label) stores its current parameters in flash.")
        }
        .alert("Read coefficients from the modules?", isPresented: $confirmModules) {
            Button("Read") { start(.readFromModules) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected cards replace their working coefficients with the ones stored in the modules. Nothing is saved to the cards until you save.")
        }
    }

    // MARK: Map

    private var map: some View {
        let b = bounds
        let model = device.models[screen.endpoint.key]
        return GeometryReader { geo in
            let s = geo.size.width / Double(b.width)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)
                ForEach(cabinets) { c in
                    Rectangle()
                        .fill(fill(c.ref))
                        .overlay(Rectangle().stroke(Color.primary.opacity(0.35), lineWidth: 0.5))
                        .overlay(Text("P\(ControllerModels.portLabel(model: model, index: c.ref.port))-\(c.ref.card + 1)")
                            .font(.system(size: max(7, min(11, Double(c.rect.width) * s / 5))))
                            .foregroundStyle(.primary.opacity(0.8)))
                        .frame(width: Double(c.rect.width) * s, height: Double(c.rect.height) * s)
                        .offset(x: Double(c.rect.x - b.minX) * s, y: Double(c.rect.y - b.minY) * s)
                        .help(help(c.ref))
                }
                if let r = dragRect {
                    Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .background(Color.accentColor.opacity(0.1))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let r = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                   width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
                    dragRect = r.width + r.height > 6 ? r : nil
                }
                .onEnded { g in
                    defer { dragRect = nil }
                    guard job == nil else { return }
                    func toPixels(_ p: CGPoint) -> (Double, Double) { (p.x / s + Double(b.minX), p.y / s + Double(b.minY)) }
                    if let r = dragRect {
                        let (x0, y0) = toPixels(CGPoint(x: r.minX, y: r.minY)), (x1, y1) = toPixels(CGPoint(x: r.maxX, y: r.maxY))
                        for c in cabinets where Double(c.rect.x) < x1 && x0 < Double(c.rect.maxX) && Double(c.rect.y) < y1 && y0 < Double(c.rect.maxY) {
                            selected.insert(c.ref)
                        }
                    } else {
                        let (x, y) = toPixels(g.location)
                        if let c = cabinets.first(where: { Double($0.rect.x) <= x && x < Double($0.rect.maxX) && Double($0.rect.y) <= y && y < Double($0.rect.maxY) }) {
                            if selected.contains(c.ref) { selected.remove(c.ref) } else { selected.insert(c.ref) }
                        }
                    }
                })
        }
        .aspectRatio(Double(b.width) / Double(b.height), contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 520)
    }

    private func fill(_ ref: CardRef) -> Color {
        switch results[ref] {
        case .working: return .orange.opacity(0.75)
        case .failed: return .red.opacity(0.7)
        case .done: return selected.contains(ref) ? .green.opacity(0.75) : .green.opacity(0.35)
        case nil: return selected.contains(ref) ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18)
        }
    }

    private func help(_ ref: CardRef) -> String {
        let name = "Port \(ref.port + 1), card \(ref.card + 1)"
        switch results[ref] {
        case .working: return name + " — working…"
        case .done: return name + " — done"
        case .failed(let why): return name + " — " + why
        case nil: return name
        }
    }

    // MARK: Reads

    private func readAutoUpload() async {
        guard let first = cabinets.map(\.ref).sorted(by: { ($0.port, $0.card) < ($1.port, $1.card) }).first else { autoUploadRaw = nil; return }
        autoUploadRaw = try? await CalibrationCoefficients.readAutoUpload(screen.endpoint, port: first.port, card: first.card)
    }

    private func setAutoUpload(_ on: Bool) {
        guard let current = autoUploadRaw else { return }
        let endpoint = screen.endpoint
        Task { @MainActor in
            do {
                try await CalibrationCoefficients.setAutoUpload(endpoint, on: on, current: current)
                await readAutoUpload()
                progress = "Auto upload of module coefficients " + (on ? "on" : "off") + " (all cards; saved with Save to HW)."
            } catch { progress = "Auto upload: " + error.localizedDescription }
        }
    }

    private func saveToHardware() {
        let endpoint = screen.endpoint
        Task { @MainActor in
            do {
                try await CalibrationCoefficients.saveToHardware(endpoint)
                progress = "Save to HW acknowledged by \(endpoint.label)."
            } catch { progress = "Save to HW: " + error.localizedDescription }
        }
    }

    private func start(_ source: CalibrationCoefficients.Operation) {
        guard job == nil else { return }
        let order = cabinets.map(\.ref).filter { selected.contains($0) }      // map order: by screen position
            .sorted { ($0.port, $0.card) < ($1.port, $1.card) }
        guard !order.isEmpty else { return }
        let endpoint = screen.endpoint
        let what: String
        switch source {
        case .readFromCard: what = "Reading from receiving cards"
        case .readFromModules: what = "Reading from modules"
        case .saveToCard: what = "Saving to cards"
        }
        for r in order { results[r] = nil }
        job = Task { @MainActor in
            defer { job = nil }
            let began = Date()
            for r in order { results[r] = .working }
            // 1. The command to every card, without waiting (they all work at the same time).
            progress = "\(what): sending to \(order.count) cabinets…"
            var pending: [CardRef] = order
            var lastError: [CardRef: String] = [:]
            var retry: [CardRef] = []
            do {
                let refused = try await CalibrationCoefficients.send(endpoint, source, targets: order.map { [$0.port, $0.card] })
                for (i, why) in refused { retry.append(order[i]); lastError[order[i]] = why }
                pending.removeAll { retry.contains($0) }
            } catch {
                for r in order { results[r] = .failed(error.localizedDescription) }
                progress = "\(what): " + error.localizedDescription
                return
            }
            // 2. Poll until every card reports done.
            try? await Task.sleep(nanoseconds: UInt64(source.firstPollDelay * 1_000_000_000))
            let deadline = Date().addingTimeInterval(90)
            while !pending.isEmpty && Date() < deadline && !Task.isCancelled {
                guard let states = try? await CalibrationCoefficients.poll(endpoint, targets: pending.map { [$0.port, $0.card] }) else {
                    try? await Task.sleep(nanoseconds: 500_000_000); continue
                }
                var still: [CardRef] = []
                for (ref, state) in zip(pending, states) {
                    switch state {
                    case .done: results[ref] = .done
                    case .busy: still.append(ref)
                    case .failed(let why): still.append(ref); lastError[ref] = why
                    }
                }
                pending = still
                progress = "\(what): \(order.count - pending.count - retry.count) of \(order.count) done, \(pending.count) still working…"
                if !pending.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
            for ref in pending { results[ref] = .failed(lastError[ref] ?? (Task.isCancelled ? "stopped" : "no 'done' within 90 s")) }
            // 3. Cards that did not take the command at once: one by one, as NovaLCT does.
            for ref in retry where !Task.isCancelled {
                progress = "\(what): retrying port \(ref.port + 1), card \(ref.card + 1) on its own…"
                do {
                    try await CalibrationCoefficients.run(endpoint, source, port: ref.port, card: ref.card)
                    results[ref] = .done
                } catch { results[ref] = .failed(error.localizedDescription) }
            }
            let failed = order.filter { if case .failed = results[$0] { return true } else { return false } }.count
            let seconds = Int(Date().timeIntervalSince(began).rounded())
            progress = "\(what): \(order.count - failed) of \(order.count) cabinets done in \(seconds) s" + (failed > 0 ? ", \(failed) failed (red — hover for the reason)." : ".")
                + (source == .saveToCard ? " Stored in the cards." : " Not saved to the cards yet.")
        }
    }
}
