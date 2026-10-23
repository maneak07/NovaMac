import Foundation

// NovaMac — receiving card registers (device 1), read the way NovaLCT reads them
// (captured over USB on MCTRL300 + XC160-1 cards, 21.10.2026). Works over USB and TCP 5200.
//
//   0x00000000 (2)    card model ID (0x4683 on the test cards)
//   0x02000000 (512)  parameter block — the card's running settings. Known: 0x17 width, 0x19 height (u16 LE,
//                     the same registers Screen Connection writes). Other fields are being mapped.
//   0x08000000 (256)  FPGA program: 4 bytes checksum, 4 bytes version (a.b.c.d), ASCII name
//   0x09000000 (256)  MCU program: same layout
//   0x03004000 (4 KB) cabinet description: LZMA-compressed XML (<IrRegularCabinetProperty>), modules,
//                     scan type, decoder, driver chip, data groups.
// Reads go in 256-byte pieces (NovaLCT's maximum over USB).

nonisolated struct ReceivingCardSnapshot: Sendable, Equatable {
    let port: Int                   // 0-based Ethernet port
    let card: Int                   // 0-based position in the chain
    let readAt: Date
    let modelID: Int?
    var parameters: [UInt8]         // 512 bytes from 0x02000000
    let fpga: ProgramInfo?
    let mcu: ProgramInfo?
    let cabinetXML: String?
    let cabinetError: String?
    /// Register 0x16000000 (16 bytes): fingerprint of the configuration last sent by NovaLCT/NovaMac.
    let configFingerprint: [UInt8]?

    struct ProgramInfo: Sendable, Equatable {
        let version: String
        let name: String
    }

    var width: Int { u16(0x17) }
    var height: Int { u16(0x19) }
    func u16(_ offset: Int) -> Int {
        guard offset + 1 < parameters.count else { return 0 }
        return Int(parameters[offset]) + Int(parameters[offset + 1]) * 256
    }
}

nonisolated enum ReceivingCardRegisters {
    static let parameterBase: UInt32 = 0x0200_0000
    static let parameterSize = 512

    private static func read(_ socket: NovaSocket, _ address: UInt32, _ length: Int, port: Int, card: Int) throws -> [UInt8] {
        var result: [UInt8] = []
        var offset = 0
        while offset < length {
            let n = min(256, length - offset)
            result += try socket.transact(.read(address + UInt32(offset), length: UInt16(n), device: 1, port: UInt8(port), card: UInt16(card)))
            offset += n
        }
        return result
    }

    private static func program(_ bytes: [UInt8]?) -> ReceivingCardSnapshot.ProgramInfo? {
        guard let bytes, bytes.count >= 8 else { return nil }
        let version = bytes[4..<8].map { String($0) }.joined(separator: ".")
        let text = bytes[8...].prefix { $0 != 0 && $0 != 0xFF }
        return .init(version: version, name: String(decoding: text, as: UTF8.self))
    }

    static func read(_ endpoint: NovaEndpoint, port: Int, card: Int) async throws -> ReceivingCardSnapshot {
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            let id = try? socket.transact(.read(0x0000_0000, length: 2, device: 1, port: UInt8(port), card: UInt16(card)))
            let parameters = try read(socket, parameterBase, parameterSize, port: port, card: card)
            let fpga = try? read(socket, 0x0800_0000, 256, port: port, card: card)
            let mcu = try? read(socket, 0x0900_0000, 256, port: port, card: card)
            // Cabinet XML: read 256-byte pieces until the LZMA stream decodes (about 1.3 KB on the test cards).
            var packed: [UInt8] = []
            var xml: String?
            var cabinetError: String?
            while packed.count < 4096 {
                guard let piece = try? read(socket, 0x0300_4000 + UInt32(packed.count), 256, port: port, card: card) else {
                    cabinetError = "not readable"; break
                }
                packed += piece
                if packed.count == 256, packed[0] != 0x5D {
                    cabinetError = "no cabinet description stored on this card"; break
                }
                do {
                    let plain = try LZMAAlone.decode(packed, maxOutput: 2_000_000)
                    xml = String(decoding: plain, as: UTF8.self)
                    break
                } catch LZMAError.truncated {
                    continue
                } catch {
                    cabinetError = error.localizedDescription; break
                }
            }
            if xml == nil && cabinetError == nil { cabinetError = "longer than 4 KB" }
            let fingerprint = try? socket.transact(.read(0x1600_0000, length: 16, device: 1, port: UInt8(port), card: UInt16(card)))
            var model: Int?
            if let id, id.count == 2 { model = Int(id[0]) + Int(id[1]) * 256 }
            return ReceivingCardSnapshot(port: port, card: card, readAt: Date(), modelID: model, parameters: parameters,
                                         fpga: program(fpga), mcu: program(mcu), cabinetXML: xml, cabinetError: cabinetError,
                                         configFingerprint: fingerprint)
        }
    }

    /// Byte ranges where `new` differs from `old`, merged when closer than 4 bytes.
    static func changedRanges(from old: [UInt8], to new: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for i in 0..<min(old.count, new.count) where old[i] != new[i] {
            if let last = ranges.last, i - last.upperBound < 4 {
                ranges[ranges.count - 1] = last.lowerBound..<(i + 1)
            } else {
                ranges.append(i..<(i + 1))
            }
        }
        return ranges
    }

    /// Writes the changed bytes of the parameter block to one card (RAM — lost at power-off unless saved),
    /// then reads the block back. Returns the block as the card reports it.
    static func write(_ endpoint: NovaEndpoint, port: Int, card: Int, original: [UInt8], edited: [UInt8]) async throws -> [UInt8] {
        let ranges = changedRanges(from: original, to: edited)
        return try await NovaLink.run(endpoint, timeout: 2) { socket in
            for range in ranges {
                try socket.transact(.write(parameterBase + UInt32(range.lowerBound), Array(edited[range]),
                                           device: 1, port: UInt8(port), card: UInt16(card)))
            }
            return try read(socket, parameterBase, parameterSize, port: port, card: card)
        }
    }

    /// Parameter blocks (512 bytes from 0x02000000) of every card answering on `port`, in chain order.
    static func parameterBlocks(_ endpoint: NovaEndpoint, port: Int, limit: Int = 128) async throws -> [[UInt8]] {
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            var blocks: [[UInt8]] = []
            while blocks.count < limit, CardProbe.ask(socket, 0x0000_0000, length: 2, port: port, card: blocks.count) != nil {
                blocks.append(try read(socket, parameterBase, parameterSize, port: port, card: blocks.count))
            }
            return blocks
        }
    }

    /// NovaLCT's receiving-card save (part of its Save, captured on MCTRL300): broadcast to every card.
    static func saveAll(_ endpoint: NovaEndpoint) async throws {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            _ = try socket.transact(.write(0x0100_0011, [0x00], destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF, reserved: 0x06))
        }
    }
}

/// Summary of the cabinet description XML stored on the card.
nonisolated struct CabinetDescription: Sendable {
    struct Module: Sendable { let x: Int, y: Int, width: Int, height: Int }
    var fields: [(String, String)] = []
    var modules: [Module] = []

    init(xml: String) {
        guard let doc = try? XMLDocument(xmlString: xml, options: []) else { return }
        func first(_ name: String) -> String? {
            (try? doc.nodes(forXPath: "//\(name)"))?.first?.stringValue
        }
        let labels: [(String, String)] = [
            ("ModulePixelCols", "Module width (px)"), ("ModulePixelRows", "Module height (px)"),
            ("ScanType", "Scan type"), ("DecType", "Decoder"), ("ChipCode", "Driver chip code"),
            ("DataGroup", "Data groups per module"), ("PhysicalDataGroupNum", "Physical data groups"),
            ("DataDirectType", "Data direction"), ("OEPolarity", "OE polarity"), ("ScreenDriveType", "Drive type"),
            ("LineBias", "Line bias"), ("CabinetVersion", "Cabinet file version"),
        ]
        for (tag, label) in labels { if let v = first(tag), !v.isEmpty { fields.append((label, v)) } }
        let nodes = (try? doc.nodes(forXPath: "//ModuleInIrRegularCabinet")) ?? []
        for node in nodes {
            func value(_ tag: String) -> Int { Int((try? node.nodes(forXPath: ".//\(tag)"))?.first?.stringValue ?? "") ?? 0 }
            modules.append(Module(x: value("XInCabinet"), y: value("YInCabinet"),
                                  width: value("PixelColInCabinet"), height: value("PixelRowInCabinet")))
        }
        if !modules.isEmpty {
            let w = modules.map { $0.x + $0.width }.max() ?? 0, h = modules.map { $0.y + $0.height }.max() ?? 0
            fields.insert(("Modules", "\(modules.count) (cabinet \(w) × \(h) px)"), at: 0)
        }
    }
}
