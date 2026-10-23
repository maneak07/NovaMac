import Foundation

// NovaMac — picture settings of the receiving cards: same registers on VX Pro (TCP 5200) and MCTRL (USB).
// Addressing as NovaLCT: device 1, port p (FF = all ports), card FFFF.
//
//   0x02000000  gamma × 10 (28 = 2.8)            0x02000001  brightness 0…255 (documented by NovaStar)
//   0x02000002  red gain · 0x03 green · 0x04 blue · 0x05 virtual red (= red)   (NovaLCT capture)
//   0x05000000  gamma table: 256 × u16 LE, 0 … MaxGammaValue (512 bytes)
//   0x060003CA = 02  apply
//
// Gamma table: every .rcfgx carries it at 0x05000000 (Koala: 2.8 → 0, 1, 2 … 4096). Its top value
// (MaxGammaValue) depends on the card's PWM settings (4096, 6120, 3776 … in the files), so NovaMac reads
// the card's table first and keeps its top value. The curve is the standard power law
//   v(i) = round(top × (i / 255)^gamma), each entry at least one above the previous
// — within 0.4 % of NovaLCT's own tables in all 19 files checked (NovaLCT adds a slightly softer toe).
// (NovaLCT's brightness page once wrote 3 × 512 bytes scaled to 65520 there — those writes went to a port
// without cards, so that format is not verified; it overwrote more than the table and broke the picture.)

nonisolated enum ScreenPicture {
    struct Settings: Sendable, Equatable {
        var gamma: Int          // × 10
        var brightness: Int
        var red: Int, green: Int, blue: Int
        var gammaTop: Int?      // last entry of the card's gamma table (MaxGammaValue)
        var table: [UInt8]      // the card's 512-byte table as read
    }

    static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[2 * i]) + Int(b[2 * i + 1]) * 256 }

    /// Standard power-law table, 256 × u16 LE, 0…top, strictly increasing at the dark end.
    static func gammaTable(gamma: Double, top: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(512)
        var previous = -1
        for i in 0..<256 {
            var v = i == 0 ? 0 : Int((Double(top) * pow(Double(i) / 255, gamma)).rounded())
            if i > 0 && v <= previous { v = previous + 1 }
            v = min(v, 65535)
            out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8))
            previous = v
        }
        return out
    }

    private static func write(_ socket: NovaSocket, _ address: UInt32, _ data: [UInt8], ports: [Int]?) throws {
        for p in ports ?? [0xFF] {
            try socket.transact(.write(address, data, device: 1, port: UInt8(p), card: 0xFFFF))
        }
    }

    /// Reads gamma, brightness, colour gains and the gamma table from the first card on `port` (0-based).
    static func read(_ endpoint: NovaEndpoint, port: Int) async throws -> Settings {
        let (b, table) = try await NovaLink.run(endpoint, timeout: 1) { socket -> ([UInt8], [UInt8]) in
            let b = try socket.transact(.read(0x0200_0000, length: 6, device: 1, port: UInt8(port), card: 0))
            var table: [UInt8] = []
            for offset in [0, 256] {
                table += (try? socket.transact(.read(0x0500_0000 + UInt32(offset), length: 256, device: 1, port: UInt8(port), card: 0))) ?? []
            }
            return (b, table)
        }
        guard b.count >= 6 else { throw NovaLinkError.badResponse("short read") }
        var top: Int?
        if table.count == 512 {
            let last = u16(table, 255)
            // A real gamma table rises to its top; anything else (empty, FF…) is not used as a scale.
            if last > 255, last < 65535, u16(table, 128) < last { top = last }
        }
        return Settings(gamma: Int(b[0]), brightness: Int(b[1]), red: Int(b[2]), green: Int(b[3]), blue: Int(b[4]),
                        gammaTop: top, table: table)
    }

    /// Red, green, blue gains in NovaLCT's order (R, VR = R, G, B). `ports` nil = all ports.
    static func setColor(_ endpoint: NovaEndpoint, red: Int, green: Int, blue: Int, ports: [Int]?) async throws {
        let r = UInt8(clamping: red), g = UInt8(clamping: green), b = UInt8(clamping: blue)
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            try write(socket, 0x0200_0002, [r], ports: ports)
            try write(socket, 0x0200_0005, [r], ports: ports)
            try write(socket, 0x0200_0003, [g], ports: ports)
            try write(socket, 0x0200_0004, [b], ports: ports)
        }
    }

    /// Writes a 512-byte gamma table and the gamma value (× 10), then applies them.
    static func setGamma(_ endpoint: NovaEndpoint, gamma: Int, table: [UInt8], ports: [Int]?) async throws {
        guard table.count == 512 else { throw NovaLinkError.badResponse("gamma table must be 512 bytes") }
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            try write(socket, 0x0500_0000, Array(table[0..<256]), ports: ports)
            try write(socket, 0x0500_0100, Array(table[256..<512]), ports: ports)
            try write(socket, 0x0200_0000, [UInt8(clamping: gamma)], ports: ports)
            try write(socket, 0x0600_03CA, [0x02], ports: ports)
        }
    }
}
