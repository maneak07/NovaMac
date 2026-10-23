import Foundation

// Clone a receiving card's configuration to another card on the same port (Agent API /v1/receiving-card/clone).
// The regions are the ones an RCFGX file writes (record list of Koala.rcfgx, XC160-1, 23.10.2026), apart from the
// 0x02000000 parameter block, which is handled byte by byte so that the card's own bytes stay:
//   scan / data tables 0x06000387, 0x1B000000, 0x060003DE, 0x03000800, 0x060003CA, 0x060003D0,
//   0x0E/0F/10/1A000000, data-group map 0x03000000, pixel map 0x04000000 (230 400 B), gamma 0x05000000,
//   cabinet description 0x03004000, 0x03002000, 0x03005000, 0x03000780, fingerprint 0x16000000,
//   0x24/28000000, 0x1C000100, 0x26000000, 0x06000200.
// After the writes the same closing commands as the file: 0x0100009D = 05 and 0x01000012 = 00 (2 s).

nonisolated enum ReceivingCardClone {
    struct Region: Sendable { let address: UInt32; let length: Int; let delayMs: Int }

    static let regions: [Region] = [
        .init(address: 0x0600_0387, length: 3, delayMs: 0),
        .init(address: 0x1B00_0000, length: 384, delayMs: 0),
        .init(address: 0x0600_03DE, length: 3, delayMs: 0),
        .init(address: 0x0300_0800, length: 2048, delayMs: 0),
        .init(address: 0x0600_03CA, length: 1, delayMs: 0),
        .init(address: 0x0600_03D0, length: 3, delayMs: 0),
        .init(address: 0x0E00_0000, length: 256, delayMs: 0),
        .init(address: 0x0F00_0000, length: 256, delayMs: 0),
        .init(address: 0x1000_0000, length: 256, delayMs: 0),
        .init(address: 0x1A00_0000, length: 256, delayMs: 0),
        .init(address: 0x0300_0000, length: 160, delayMs: 0),
        .init(address: 0x0400_0000, length: 230_400, delayMs: 0),
        .init(address: 0x0500_0000, length: 512, delayMs: 0),
        .init(address: 0x0300_4000, length: 1333, delayMs: 0),
        .init(address: 0x0300_2000, length: 48, delayMs: 0),
        .init(address: 0x0300_5000, length: 48, delayMs: 0),
        .init(address: 0x0300_0780, length: 68, delayMs: 25),
        .init(address: 0x1600_0000, length: 16, delayMs: 25),
        .init(address: 0x2400_0000, length: 16, delayMs: 0),
        .init(address: 0x2800_0000, length: 16, delayMs: 0),
        .init(address: 0x1C00_0100, length: 45, delayMs: 0),
        .init(address: 0x2600_0000, length: 2, delayMs: 0),
        .init(address: 0x0600_0200, length: 1, delayMs: 0),
    ]

    /// Parameter-block bytes that are the card's own or rewritten by the card: size, card number, test pattern,
    /// black/freeze, status area.
    static let keepInBlock: Set<Int> = Set([0x17, 0x18, 0x19, 0x1A, 0x51, 0x100, 0x101, 0x102]).union(Set(0x13A...0x14D))

    struct Snapshot: Sendable {
        var regions: [UInt32: [UInt8]] = [:]     // nil entry = not readable
        var unreadable: [UInt32] = []
        var block: [UInt8] = []
    }

    private static func read(_ socket: NovaSocket, _ address: UInt32, _ length: Int, port: Int, card: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var offset = 0
        while offset < length {
            let n = min(256, length - offset)
            out += try socket.transact(.read(address + UInt32(offset), length: UInt16(n), device: 1, port: UInt8(port), card: UInt16(card)))
            offset += n
        }
        return out
    }

    /// `sample`: read at most this many bytes of each region (the 230 KB pixel map takes ~30 s over USB).
    static func snapshot(_ endpoint: NovaEndpoint, port: Int, card: Int, sample: Int? = nil) async throws -> Snapshot {
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            var s = Snapshot()
            s.block = try read(socket, 0x0200_0000, 512, port: port, card: card)
            for r in regions {
                let n = min(r.length, sample ?? r.length)
                do { s.regions[r.address] = try read(socket, r.address, n, port: port, card: card) }
                catch NovaLinkError.nack { s.unreadable.append(r.address) }
            }
            return s
        }
    }

    /// Writes the regions in `addresses` (data from `source`) and the parameter-block bytes in `blockOffsets`,
    /// then the closing commands, to one card.
    static func write(_ endpoint: NovaEndpoint, port: Int, card: Int, source: Snapshot,
                      addresses: Set<UInt32>, blockOffsets: [Int]) async throws {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            func put(_ address: UInt32, _ data: [UInt8]) throws {
                var offset = 0
                while offset < data.count {
                    let piece = Array(data[offset..<min(offset + 256, data.count)])
                    _ = try socket.transact(.write(address + UInt32(offset), piece, device: 1, port: UInt8(port), card: UInt16(card)))
                    offset += piece.count
                }
            }
            // Parameter block first, in runs of neighbouring bytes (as the file's own records come first).
            var runs: [(Int, Int)] = []
            for o in blockOffsets.sorted() {
                if let last = runs.last, last.0 + last.1 == o { runs[runs.count - 1].1 += 1 } else { runs.append((o, 1)) }
            }
            for (start, count) in runs { try put(0x0200_0000 + UInt32(start), Array(source.block[start..<start + count])) }
            for r in regions where addresses.contains(r.address) {
                guard let data = source.regions[r.address] else { continue }
                try put(r.address, data)
                if r.delayMs > 0 { Thread.sleep(forTimeInterval: Double(r.delayMs) / 1000) }
            }
            try put(0x0100_009D, [0x05]); Thread.sleep(forTimeInterval: 0.025)
            try put(0x0100_0012, [0x00]); Thread.sleep(forTimeInterval: 2)
        }
    }
}
