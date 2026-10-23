import Foundation

// NovaMac — Screen Connection: SEND to hardware (no save).
//
// Reproduces NovaLCT's "Send to HW" register sequence for VX1000 Pro. Verified byte-for-byte
// (39 of 39 frames, serial numbers excluded) against four NovaLCT sends captured on the test
// screen (4 × XC160-1, 160 × 360, Ethernet port 1): 4×1 in both cable directions (twice) and 2×2.
//
// Sends whatever the plan contains. Hard limits only: sending card 1, one Ethernet port per send
// (any of 1–10; ports 1 and 7 captured, others by the same address stride) and a cable order 1…N. Overlaps, area, card sizes
// and differences from the last hardware read are reported as warnings before sending.
// NovaLCT always saves after sending; NovaMac sends WITHOUT saving (the same 39 commands, no save
// block), so a power cycle restores the layout stored in flash.

// Runs on the main actor (project default); the TCP work itself happens in NovaLink's background task.
enum ScreenConnectionWriter {
    struct Card: Sendable, Equatable {
        let chainIndex: Int    // 0-based position in the port's cable chain
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        var port = 0           // 0-based Ethernet port
    }

    struct Layout: Sendable, Equatable {
        let cards: [Card]      // column by column, top to bottom — the order NovaLCT writes them in
        let width: Int
        let height: Int
        var freePlacement = false
        var warnings: [String] = []
        var portIndex = 0          // 0-based Ethernet port of the sending card (the first one when several)
        /// 0-based ports the layout uses, ascending.
        var ports: [Int] { Array(Set(cards.map(\.port))).sorted() }
        var model: String? = nil   // for connector numbers in the summary (MEE410)
        var summary: String {
            ports.map { p in
                "Port \(ControllerModels.portLabel(model: model, index: p)): "
                    + cards.filter { $0.port == p }.sorted { $0.chainIndex < $1.chainIndex }
                        .map { "(\($0.x),\($0.y)) card \($0.chainIndex + 1)" }.joined(separator: " · ")
            }.joined(separator: "\n")
        }
    }

    // MARK: Validation

    /// Builds what will be sent from the plan as drawn. Only hard protocol limits refuse;
    /// everything else (overlaps, area, mismatch with the last hardware read) becomes a warning.
    static func layout(plan: ScreenConnectionPlan, hardware: UnicoTopology.Snapshot? = nil,
                       area: (width: Int, height: Int)? = nil) throws -> Layout {
        func refuse(_ text: String) -> RCFGXError { .invalid("Send to HW refused: \(text)") }
        try plan.validate()
        var warnings: [String] = []
        let connected = plan.cells.filter { !$0.blank && $0.order != nil }.sorted { $0.id < $1.id }
        let n = connected.count
        guard n >= 1 else { throw refuse("no connected cards. Connect the cards (Quick Connection or clicking) first.") }
        guard connected.allSatisfy({ $0.sender == 1 }) else {
            throw refuse("only sending card 1 is supported.")
        }
        let ports = Set(connected.map(\.port)).sorted()
        guard let port = ports.first, ports.allSatisfy({ (1...32).contains($0) }) else { throw refuse("port outside 1…32.") }
        if ports.count > 1 {
            warnings.append("\(ports.count) ports in one send: each port gets its own area (the box around its cards), as the controller stores it when NovaLCT sends — not captured from a NovaLCT send yet.")
        }
        for p in ports {
            let orders = connected.filter { $0.port == p }.compactMap(\.order)
            guard Set(orders) == Set(1...orders.count) else {
                throw refuse("cable order on each port must be 1…N without gaps or repeats (port \(p)).")
            }
            let load = plan.portLoad(sender: 1, port: p)
            guard load <= ScreenConnectionPlan.portCapacity else {
                throw refuse("a port carries \(load) pixels — the limit is \(ScreenConnectionPlan.portCapacity) per port.")
            }
        }
        let unconnected = plan.cells.filter { !$0.blank && $0.order == nil }.count
        if unconnected > 0 { warnings.append("\(unconnected) unconnected card(s) are not sent.") }
        let blanks = plan.cells.filter(\.blank).count
        if blanks > 0 { warnings.append("\(blanks) blank cell(s): no card is sent there, the area stays black.") }
        if plan.originX != 0 || plan.originY != 0 { warnings.append("Screen X/Y origin is not sent; card positions are absolute.") }

        let cards = connected.map { cell -> Card in
            let r = plan.rect(of: cell)
            return Card(chainIndex: cell.order! - 1, x: r.x, y: r.y, width: r.width, height: r.height, port: cell.port - 1)
        }.sorted { ($0.x, $0.y) < ($1.x, $1.y) }   // NovaLCT order: by column, then top to bottom
        // Blank cells are part of the screen area (content skips them as black), so they count for W × H.
        let blankRects = plan.cells.filter(\.blank).map { plan.rect(of: $0) }
        let width = max(cards.map { $0.x + $0.width }.max() ?? 0, blankRects.map(\.maxX).max() ?? 0)
        let height = max(cards.map { $0.y + $0.height }.max() ?? 0, blankRects.map(\.maxY).max() ?? 0)
        guard width <= 65535, height <= 65535 else { throw refuse("screen is larger than 65535 pixels.") }

        let overlaps = plan.overlappingIDs
        if !overlaps.isEmpty {
            let names = connected.filter { overlaps.contains($0.id) }.compactMap(\.order).sorted().map { "\($0)" }.joined(separator: ", ")
            warnings.append("Cards \(names) overlap.")
        }
        if let area, width > area.width || height > area.height {
            warnings.append("Layout \(width)×\(height) exceeds the controller area \(area.width)×\(area.height).")
        }
        if Set(cards.map(\.width)).count > 1 || Set(cards.map(\.height)).count > 1 {
            warnings.append("Mixed card sizes (not covered by the NovaLCT captures).")
        }
        if let hardware {
            if hardware.cabinets.count != n {
                warnings.append("Plan has \(n) cards, last hardware read had \(hardware.cabinets.count).")
            }
            let hwSize = Dictionary(hardware.cabinets.map { ($0.index, $0.cabinetSize) }, uniquingKeysWith: { a, _ in a })
            let changed = cards.filter { c in hwSize[c.chainIndex].map { $0.width != c.width || $0.height != c.height } ?? false }
            if !changed.isEmpty {
                warnings.append("Card size changed for card(s) \(changed.map { "\($0.chainIndex + 1)" }.sorted().joined(separator: ", ")).")
            }
        } else {
            warnings.append("Not compared with hardware (no Read from HW in this session).")
        }
        var layout = Layout(cards: cards, width: width, height: height, freePlacement: !plan.isRegularGrid)
        layout.warnings = warnings
        layout.portIndex = port - 1
        return layout
    }

    // MARK: Register sequence (matches NovaLCT V5.x "Send to HW")

    /// Register map of the sending card family. Both captured from NovaLCT "Send to HW":
    /// - vxPro: VX1000 Pro over TCP 5200 (4 sends, 39/39 frames byte-for-byte).
    /// - classic: MCTRL300 over USB (21.10.2026, 3 sends on ports 1 and 2): only 0x02000018/19 are
    ///   reset, no 0x0200004A, port block stride 9 (0x02000050 + 9·p), no port record (0x03200000)
    ///   and no 0x02030000, coordinate table written in 256-byte pieces.
    nonisolated enum Profile: Sendable, Equatable {
        case vxPro, classic

        /// Model ID (register 0x00000002): 0x622B = VX1000 Pro; anything else is treated as a classic MCTRL card.
        static func forModel(_ id: Int) -> Profile { id == 0x622B ? .vxPro : .classic }
        var name: String { self == .vxPro ? "VX Pro" : "MCTRL (classic)" }
        var tablePiece: Int { self == .vxPro ? 4096 : 256 }
    }

    /// Several ports (register protocol, classic cards): every port gets the box around its cards as its
    /// area (block: flag, W, H, X, Y) and the card positions relative to that box — the form in which
    /// MEE410 reports a NovaLCT layout when it is read.
    static func multiPortCommands(for layout: Layout, model: String?) -> [NovaCommand] {
        let w = layout.width, h = layout.height
        let le16 = { (v: Int) in NovaBytes.le16(v) }
        var list: [NovaCommand] = []
        for address: UInt32 in [0x0200_0018, 0x0200_0019] { list.append(.write(address, [0], destination: 0xFF)) }
        for (address, data) in [(UInt32(0x0200_00F0), [UInt8(0)]), (0x0200_0028, le16(0)), (0x0200_002A, le16(0)),
                                (0x0200_0024, le16(w)), (0x0200_0026, le16(h)), (0x0200_002C, le16(w))] {
            list.append(.write(address, data))
        }
        for port in layout.ports {
            guard let block = ControllerModels.portBlock(model: model, port: port) else { continue }
            let cards = layout.cards.filter { $0.port == port }
            let x0 = cards.map(\.x).min() ?? 0, y0 = cards.map(\.y).min() ?? 0
            let aw = (cards.map { $0.x + $0.width }.max() ?? 0) - x0
            let ah = (cards.map { $0.y + $0.height }.max() ?? 0) - y0
            let p = UInt32(port), n = cards.count
            list.append(.write(block + 5, le16(x0))); list.append(.write(block + 7, le16(y0)))
            list.append(.write(block + 1, le16(aw))); list.append(.write(block + 3, le16(ah)))
            list.append(.write(0x0310_0000 + 0x20 * p, le16(n)))
            list.append(.write(block, [0]))
            let position = Dictionary(cards.map { ($0.chainIndex, UInt32($0.x - x0) | UInt32($0.y - y0) << 16) },
                                      uniquingKeysWith: { a, _ in a })
            var table: [UInt8] = []
            for i in 0..<1024 { table += NovaBytes.le32(position[i % n] ?? 0) }
            for offset in stride(from: 0, to: table.count, by: 256) {
                list.append(.write(0x0300_0000 + 0x1000 * p + UInt32(offset), Array(table[offset..<(offset + 256)])))
            }
        }
        for port in layout.ports {
            let p = UInt8(port)
            list.append(.write(0x0200_009A, [0], device: 1, port: p, card: 0xFFFF))
            for card in layout.cards where card.port == port {
                list.append(.write(0x0200_0017, le16(card.width), device: 1, port: p, card: UInt16(card.chainIndex)))
                list.append(.write(0x0200_0019, le16(card.height), device: 1, port: p, card: UInt16(card.chainIndex)))
            }
        }
        list.append(.write(0x0100_0012, [0xAA], destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF, reserved: 0x08))
        list.append(.write(0x0200_01EC, le16(w) + le16(h)))
        list.append(.write(0x0200_00AE, [1], destination: 0xFF))
        return list
    }

    static func commands(for layout: Layout, profile: Profile = .vxPro) -> [NovaCommand] {
        let w = layout.width, h = layout.height, n = layout.cards.count
        var list: [NovaCommand] = []
        let resets: [UInt32] = profile == .vxPro
            ? [0x0200_0018, 0x0200_0019, 0x0200_001A, 0x0200_001B, 0x0200_0098, 0x0200_0099,
               0x0200_009A, 0x0200_009B, 0x0200_0100, 0x0200_0101]
            : [0x0200_0018, 0x0200_0019]
        for address in resets { list.append(.write(address, [0], destination: 0xFF)) }
        let le16 = { (v: Int) in NovaBytes.le16(v) }
        // Per-port register blocks:
        //   VX Pro (port 1 and port 7 captured): 0x02000050 + 0x13·p, port record 0x03200000 + 0x4000·p, 0x02030000 + 2·p.
        //   MCTRL300 (port 1 and port 2 captured): 0x02000050 + 9·p, no port record.
        //   Both: card count 0x03100000 + 0x20·p, coordinate table 0x03000000 + 0x1000·p.
        let p = UInt32(layout.portIndex)
        let block: UInt32 = 0x0200_0050 + (profile == .vxPro ? 0x13 : 9) * p
        var senderRegisters: [(UInt32, [UInt8])] = profile == .vxPro ? [(0x0200_004A, [0])] : []
        senderRegisters += [
            (0x0200_00F0, [0]),
            (0x0200_0028, le16(0)), (0x0200_002A, le16(0)),
            (0x0200_0024, le16(w)), (0x0200_0026, le16(h)),
            (0x0200_002C, le16(w)),
            (block + 5, le16(0)), (block + 7, le16(0)),
            (block + 1, le16(w)), (block + 3, le16(h)),
            (0x0310_0000 + 0x20 * p, le16(n)),
            (block, [0]),
        ]
        for (address, data) in senderRegisters { list.append(.write(address, data)) }
        if profile == .vxPro {
            let portRecord = [UInt8(0)] + le16(w) + le16(h) + [UInt8](repeating: 0, count: 11)
            list.append(.write(0x0320_0000 + 0x4000 * p, portRecord))
            list.append(.write(0x0320_0010 + 0x4000 * p, portRecord))
            list.append(.write(0x0203_0000 + 2 * p, le16(2)))
        }

        // Card position table: 1024 × UInt32 (x | y << 16) indexed by chain position,
        // repeated cyclically exactly as NovaLCT fills it.
        let position = Dictionary(layout.cards.map { ($0.chainIndex, UInt32($0.x) | UInt32($0.y) << 16) },
                                  uniquingKeysWith: { a, _ in a })
        var table: [UInt8] = []
        table.reserveCapacity(4096)
        for i in 0..<1024 { table += NovaBytes.le32(position[i % n] ?? 0) }
        let piece = profile.tablePiece
        for offset in stride(from: 0, to: table.count, by: piece) {
            list.append(.write(0x0300_0000 + 0x1000 * p + UInt32(offset), Array(table[offset..<min(offset + piece, table.count)])))
        }

        list.append(.write(0x0200_009A, [0], device: 1, port: UInt8(p), card: 0xFFFF))
        for card in layout.cards {
            list.append(.write(0x0200_0017, le16(card.width), device: 1, port: UInt8(p), card: UInt16(card.chainIndex)))
            list.append(.write(0x0200_0019, le16(card.height), device: 1, port: UInt8(p), card: UInt16(card.chainIndex)))
        }
        list.append(.write(0x0100_0012, [0xAA], destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF, reserved: 0x08))
        list.append(.write(0x0200_01EC, le16(w) + le16(h)))
        list.append(.write(0x0200_00AE, [1], destination: 0xFF))
        return list
    }

    // MARK: Send + verify

    /// Sends over the given link. Network: verified through the controller's REST model.
    /// USB: verified by reading the sending card's coordinate table back.
    static func send(_ endpoint: NovaEndpoint, layout target: Layout) async throws -> String {
        if case .network(let ip) = endpoint { return try await send(ip: ip, layout: target) }
        return try await sendRegisters(endpoint, layout: target)
    }

    /// Register-protocol send for any link (USB, or TCP 5200 to a controller without a web interface):
    /// the register map is chosen from the model ID, verified by reading the coordinate table back.
    static func sendRegisters(_ endpoint: NovaEndpoint, layout target: Layout) async throws -> String {
        // MEE410 keeps its port areas elsewhere (see ControllerModels.portBlock): always the per-port form.
        let mee = target.model?.uppercased().replacingOccurrences(of: " ", with: "") == "MEE410"
        if target.ports.count > 1 || mee { return try await sendRegistersMulti(endpoint, layout: target) }
        let vxSequence = Self.commands(for: target, profile: .vxPro)
        let classicSequence = Self.commands(for: target, profile: .classic)
        let p = UInt32(target.portIndex), n = target.cards.count
        let (table, skipped, profile) = try await NovaLink.run(endpoint, timeout: 2) { socket -> ([UInt8]?, [String], Profile) in
            let id = try socket.transact(.read(0x0000_0002, length: 2))
            var model = 0
            if id.count == 2 { model = Int(id[0]) + Int(id[1]) * 256 }
            let profile = Profile.forModel(model)
            let steps = profile == .vxPro ? vxSequence : classicSequence
            // A step the card does not answer is skipped and reported; three silent steps in a row abort.
            var skipped: [String] = []
            var silentInRow = 0
            for (k, command) in steps.enumerated() {
                do {
                    try socket.transact(command)
                    silentInRow = 0
                } catch NovaLinkError.timeout where silentInRow < 2 {
                    silentInRow += 1
                    skipped.append("step \(k + 1) " + String(format: "0x%08X", command.address))
                } catch {
                    let kind = command.write ? "write" : "read"
                    let register = String(format: "0x%08X", command.address)
                    let route = String(format: "dst %02X dev %d port %02X card %04X", Int(command.destination), Int(command.device), Int(command.port), Int(command.card))
                    let message = "Step \(k + 1) of \(steps.count) (\(profile.name)): \(kind) \(register), \(route), \(command.data.count) bytes: \(error.localizedDescription)"
                    throw NovaLinkError.failedStep(message + " Commands before this step were applied; a power cycle restores the stored layout.")
                }
            }
            // Read back in pieces the card accepts (NovaLCT reads at most 256 bytes over USB).
            var table: [UInt8]? = []
            var offset = 0
            while offset < 4 * n, table != nil {
                let length = min(256, 4 * n - offset)
                if let part = try? socket.transact(.read(0x0300_0000 + 0x1000 * p + UInt32(offset), length: UInt16(length))) {
                    table! += part
                } else { table = nil }
                offset += length
            }
            return (table, skipped, profile)
        }
        let skipNote = skipped.isEmpty ? "" : " Not answered (skipped): \(skipped.joined(separator: ", "))."
        guard let table, table.count >= 4 * n else {
            return "Sent.\(skipNote) Coordinate table cannot be read back — check the LED screen. Not saved."
        }
        let wrong = target.cards.filter { c in
            let o = 4 * c.chainIndex
            guard o + 3 < table.count else { return true }
            let x: Int = Int(table[o]) + Int(table[o + 1]) * 256
            let y: Int = Int(table[o + 2]) + Int(table[o + 3]) * 256
            return x != c.x || y != c.y
        }
        if wrong.isEmpty { return "Sent (\(profile.name) register map); read-back of all \(n) card positions matches.\(skipNote) Not saved — a power cycle restores the stored layout." }
        let names: [String] = wrong.map { String($0.chainIndex + 1) }
        return "Sent, but card(s) \(names.joined(separator: ", ")) read back at a different position.\(skipNote) Check the LED screen."
    }

    /// Several ports in one send (classic register map), verified by reading every port's area and table
    /// back and comparing the absolute card positions.
    static func sendRegistersMulti(_ endpoint: NovaEndpoint, layout target: Layout) async throws -> String {
        let steps = multiPortCommands(for: target, model: target.model)
        var blocks: [Int: UInt32] = [:]
        for port in target.ports { blocks[port] = ControllerModels.portBlock(model: target.model, port: port) }
        let areaBlocks = blocks
        // Plain values for the background task: port → [(chain index, x, y)].
        var expected: [Int: [[Int]]] = [:]
        for c in target.cards { expected[c.port, default: []].append([c.chainIndex, c.x, c.y]) }
        let want = expected
        var names: [Int: Int] = [:]
        for port in target.ports { names[port] = ControllerModels.portLabel(model: target.model, index: port) }
        let label = names
        let result = try await NovaLink.run(endpoint, timeout: 2) { socket -> (Profile, [String]) in
            let id = try socket.transact(.read(0x0000_0002, length: 2))
            let family = id.count == 2 ? Int(id[0]) + Int(id[1]) * 256 : 0
            let profile = Profile.forModel(family)
            guard profile == .classic else { return (profile, []) }
            for (k, command) in steps.enumerated() {
                do { try socket.transact(command) } catch {
                    let message = String(format: "Step %d of %d: write 0x%08X port %d: ", k + 1, steps.count, command.address, Int(command.port))
                        + error.localizedDescription
                    throw NovaLinkError.failedStep(message + " Commands before this step were applied; a power cycle restores the stored layout.")
                }
            }
            // Read back: area origin + relative table = absolute position of every card.
            var wrong: [String] = []
            for (port, cards) in want.sorted(by: { $0.key < $1.key }) {
                guard let block = areaBlocks[port],
                      let b = try? socket.transact(.read(block, length: 9)), b.count == 9 else { wrong.append("port \(label[port] ?? port + 1): area"); continue }
                let ox = Int(b[5]) + Int(b[6]) * 256, oy = Int(b[7]) + Int(b[8]) * 256
                let n = cards.count
                guard let t = try? socket.transact(.read(0x0300_0000 + 0x1000 * UInt32(port), length: UInt16(4 * n))), t.count == 4 * n else {
                    wrong.append("port \(label[port] ?? port + 1): table"); continue
                }
                for c in cards {
                    let o = 4 * c[0]
                    guard o + 3 < t.count else { wrong.append("port \(label[port] ?? port + 1) card \(c[0] + 1)"); continue }
                    let x = ox + Int(t[o]) + Int(t[o + 1]) * 256, y = oy + Int(t[o + 2]) + Int(t[o + 3]) * 256
                    if x != c[1] || y != c[2] { wrong.append("port \(label[port] ?? port + 1) card \(c[0] + 1)") }
                }
            }
            return (profile, wrong)
        }
        guard result.0 == .classic else {
            throw RCFGXError.invalid("Send to HW refused: over TCP 5200 a VX Pro takes one port per send — use the web interface (REST) mode for several ports.")
        }
        let n = target.cards.count, ports = target.ports.count
        if result.1.isEmpty {
            return "Sent \(n) cards on \(ports) ports; read-back of all positions matches. Not saved — press Save to HW to keep it."
        }
        return "Sent \(n) cards on \(ports) ports, but these read back differently: \(result.1.joined(separator: ", ")). Check the LED screen. Not saved."
    }

    /// The NovaLCT register sequence only (VX Pro), without any read-back — used together with the web API send.
    static func sendRegistersOnly(ip: String, layout target: Layout) async throws {
        guard target.ports.count == 1 else { throw RCFGXError.invalid("Register send: one port per send on VX Pro.") }
        let sequence = Self.commands(for: target)
        try await NovaLink.run(ip: ip) { socket in
            _ = try socket.transact(.read(0x0000_0002, length: 2))
            for (k, command) in sequence.enumerated() {
                do { try socket.transact(command) } catch {
                    throw NovaLinkError.failedStep(String(format: "Register step %d of %d (0x%08X): ", k + 1, sequence.count, command.address)
                                                   + error.localizedDescription)
                }
            }
        }
    }

    /// Sends the layout without saving, then reads the topology back through Unico and checks it.
    static func send(ip: String, layout target: Layout) async throws -> String {
        guard target.ports.count == 1 else {
            throw RCFGXError.invalid("Send to HW refused: over TCP 5200 a VX Pro takes one port per send — use the web interface (REST) mode for several ports.")
        }
        let sequence = Self.commands(for: target)
        try await NovaLink.run(ip: ip) { socket in
            // Same first read NovaLCT does; proves the link before any write.
            _ = try socket.transact(.read(0x0000_0002, length: 2))
            for command in sequence { try socket.transact(command) }
        }
        // Verify through the controller's own model (only the cards that were sent).
        let want = Dictionary(target.cards.map { ($0.chainIndex, [$0.x, $0.y]) }, uniquingKeysWith: { a, _ in a })
        var lastResult = "no data"
        for attempt in 0..<4 {
            try await Task.sleep(nanoseconds: UInt64(attempt == 0 ? 800 : 1000) * 1_000_000)
            do {
                let readBack = try await UnicoTopology.readFromHardware(ip: ip)
                let all = Dictionary(readBack.cabinets.map { ($0.index, [$0.cabinetPosition.x, $0.cabinetPosition.y]) }, uniquingKeysWith: { a, _ in a })
                let got = all.filter { want[$0.key] != nil }
                if got == want {
                    let extra = all.count - got.count
                    return "Sent \(sequence.count) commands; read-back matches all \(want.count) cards\(extra > 0 ? " (+\(extra) more on the port)" : ""). Not saved to flash."
                }
                lastResult = "controller reports " + all.sorted { $0.key < $1.key }.map { "card \($0.key + 1)→\($0.value)" }.joined(separator: ", ")
            } catch { lastResult = error.localizedDescription }
        }
        return "Sent \(sequence.count) commands (all acknowledged), but the read-back differs: \(lastResult). Check the LED screen. Not saved to flash."
    }
}

// MARK: - Mapping (NovaLCT "Enable Mapping" / "Disable Mapping")
// Captured: one broadcast write to every receiving card on every port,
//   dst FF, device 1, port FF, card FFFF, register 0x01000088 = 05 (mapping on) / 01 (normal).
nonisolated enum ScreenMapping {
    static let register: UInt32 = 0x0100_0088
    static let on: UInt8 = 0x05
    static let off: UInt8 = 0x01

    static func set(_ endpoint: NovaEndpoint, enabled: Bool) async throws {
        let value = enabled ? on : off
        try await NovaLink.run(endpoint) { socket in
            _ = try socket.transact(.write(register, [value], destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF))
        }
    }

    /// Reads the display mode of the first receiving card on `port` (1-based). nil = unknown value.
    static func state(_ endpoint: NovaEndpoint, port: Int) async throws -> Bool? {
        let p = UInt8(max(0, port - 1))
        let data = try await NovaLink.run(endpoint, timeout: 1) { socket in
            try socket.transact(.read(register, length: 1, device: 1, port: p, card: 0))
        }
        switch data.first {
        case on: return true
        case off: return false
        default: return nil
        }
    }
}

// MARK: - Save to flash
// NovaLCT "Save" (identical in all 4 captures):
//   R 0x0200009D (= 0x5A) → W 0x02000018…0x02000101 = 00 (sending card)
//   → W FF 0x05066000 "SSPE" (256) → W FF 0x05000000 = 00000000 → W FF 0x02100000 = 55 00
//   → W 0x05000000/0x05001000/0x05002000 = "NSSD" screen file (header + encoded 315–321 bytes)
//   → W FF 0x01000001 = 00 (rsv 06) → W FF dev3 0x05000000 = 00 (rsv 06) → W FF dev4 0x01000011 = 00 (rsv 06).
// The NSSD file is NovaLCT's own encoded copy of the screen configuration (not decoded yet).
// NovaMac writes the save commands WITHOUT touching the NSSD file and its SSPE/erase step, so the
// NovaLCT file stays as NovaLCT last saved it. Whether the layout survives a power cycle this way is
// what the first test must show.
enum ScreenFlash {
    static func save(ip: String) async throws {
        try await NovaLink.run(ip: ip) { socket in
            let check = try socket.transact(.read(0x0200_009D, length: 1))
            guard check.first == 0x5A else {
                throw NovaLinkError.badResponse(String(format: "save refused — sending card status 0x%02X (NovaLCT expects 0x5A)", Int(check.first ?? 0)))
            }
            for address: UInt32 in [0x0200_0018, 0x0200_0019, 0x0200_001A, 0x0200_001B,
                                    0x0200_0098, 0x0200_0099, 0x0200_009A, 0x0200_009B,
                                    0x0200_0100, 0x0200_0101] {
                try socket.transact(.write(address, [0]))
            }
            try socket.transact(.write(0x0210_0000, [0x55, 0x00], destination: 0xFF))
            try socket.transact(.write(0x0100_0001, [0x00], destination: 0xFF, reserved: 0x06))
            try socket.transact(.write(0x0500_0000, [0x00], destination: 0xFF, device: 3, port: 0xFF, card: 0xFFFF, reserved: 0x06))
            try socket.transact(.write(0x0100_0011, [0x00], destination: 0xFF, device: 4, port: 0xFF, card: 0xFFFF, reserved: 0x06))
        }
    }
}

// MARK: - Save on classic MCTRL sending cards (USB)
// NovaLCT "Save" on MCTRL300 (captured over USB 21.10.2026):
//   W 0x05066000 "SSPE" (256) → W FF/port FF/card FFFF 0x05000000 = 00000000 → W FF 0x02100000 = 55 00
//   → W 0x05000000…0x05002100 NSSD screen file (NovaLCT's own encoded copy, not decoded)
//   → W FF 0x01000001 = 00 (rsv 06) → W FF dev3 0x05000000 = 00 (rsv 06)
//   → W FF dev1 0x01000011 = 00 (rsv 06) → W FF dev4 0x01000011 = 00 (rsv 06).
// NovaMac sends the save commands only. NovaLCT's NSSD file and its SSPE/erase step are left untouched,
// so NovaLCT keeps showing the layout it saved last; the sending and receiving cards store what they run now.
enum ClassicSave {
    /// Works over USB and TCP 5200. The register map is chosen by the model ID like Send to HW:
    /// classic MCTRL cards get the MCTRL300 sequence (incl. the receiving-card save, dev1 0x01000011),
    /// VX Pro gets its own captured sequence (status check 0x0200009D, no dev1 save).
    static func save(_ endpoint: NovaEndpoint) async throws -> String {
        let profile = try await NovaLink.run(endpoint, timeout: 3) { socket -> ScreenConnectionWriter.Profile in
            let id = try socket.transact(.read(0x0000_0002, length: 2))
            var model = 0
            if id.count == 2 { model = Int(id[0]) + Int(id[1]) * 256 }
            let profile = ScreenConnectionWriter.Profile.forModel(model)
            if profile == .vxPro {
                let check = try socket.transact(.read(0x0200_009D, length: 1))
                guard check.first == 0x5A else {
                    throw NovaLinkError.badResponse(String(format: "save refused — sending card status 0x%02X (expected 0x5A)", Int(check.first ?? 0)))
                }
            }
            try socket.transact(.write(0x0210_0000, [0x55, 0x00], destination: 0xFF))
            try socket.transact(.write(0x0100_0001, [0x00], destination: 0xFF, reserved: 0x06))
            try socket.transact(.write(0x0500_0000, [0x00], destination: 0xFF, device: 3, port: 0xFF, card: 0xFFFF, reserved: 0x06))
            if profile == .classic {
                try socket.transact(.write(0x0100_0011, [0x00], destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF, reserved: 0x06))
            }
            try socket.transact(.write(0x0100_0011, [0x00], destination: 0xFF, device: 4, port: 0xFF, card: 0xFFFF, reserved: 0x06))
            return profile
        }
        return "Save commands (\(profile.name)) acknowledged by \(endpoint.label). Power-cycle it to check that the layout stays."
    }
}
