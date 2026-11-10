import Foundation

// NovaMac — per-pixel calibration coefficients of the receiving cards, as NovaLCT "Manage Coefficients"
// (Adjust coefficients, Save calibration coefficients to database) uses them; verified on a TB30 with an
// A8s-N by read-back and power cycles (07.11.2026):
//   table    dev1 port p card c  0x07000000 + (y · width + x) · 32, read and written in blocks of 512 bytes.
//            32 bytes per pixel = 4 × 4 u16, 2048 = 1.0. Column 0/1/2 drives the red/green/blue LED (a red
//            factor scales m00, m10, m20); row 3 is (0, m01, m02, m00) in every stored pixel.
//   adjust   dev1 port p card c  0x01000024, 41 bytes:
//              [type] x y width height (u16) · 3 × {u16 factor, 8 × 00} (R, G, B) · 00 00
//            type 00 takes the rectangle's current coefficients as its base, type 01 sets
//            coefficients = base × factor (0x0800 = 1.0). Repeating a factor does not add up, 1.0 restores the
//            base exactly, several rectangles keep their own base. Values stop at about 1.3 (2660).
//   average  dev1 port p card c  0x02000110, 32 bytes: 4 × 4 u16 mean matrix of the last base rectangle.
//   busy     dev1 port p card c  reserved 09, read 0x02000200 (256 bytes): ack 1 while the card works
//            (CalibrationCoefficients.waitIdle).
//   save     dev1 port p card c  0x01000004 = 00 writes the table to flash (about 10 s busy): "Save to cards"
//            in CalibrationCoefficients, used by the module matching box as well.
//            The same register with A2 stores the seam brightness, a gain outside this table.
// Writing table blocks back and saving restores a backup byte for byte. The seam frame (45 bytes) with
// [0] = 02 overwrites the table with flat values; NovaMac never sends it.
// Row stride = card width, verified on a 256 × 256 card only.

nonisolated enum CoefficientTable {
    static let base: UInt32 = 0x0700_0000
    static let blockSize = 512
    static let pixelSize = 32
    static let adjustRegister: UInt32 = 0x0100_0024
    static let averageRegister: UInt32 = 0x0200_0110
    static let factorRange = 0.0...1.3

    /// One receiving card: 0-based port and chain index, loaded size in pixels.
    struct Card: Hashable, Sendable, Codable {
        let port: Int
        let card: Int
        let width: Int
        let height: Int
        var tableBytes: Int { width * height * CoefficientTable.pixelSize }
        func offset(x: Int, y: Int) -> Int { (y * width + x) * CoefficientTable.pixelSize }
    }

    struct Factors: Equatable, Sendable {
        var red = 1.0, green = 1.0, blue = 1.0
        static let one = Factors()
    }

    /// Mean coefficients (diagonal) of a rectangle, 1.0 = 2048.
    struct Mean: Equatable, Sendable {
        let red: Double, green: Double, blue: Double
    }

    /// What Pixel Razor switches off in one pixel.
    enum Cut: String, Codable, CaseIterable, Identifiable, Sendable {
        case pixel, red, green, blue
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pixel: return "Whole pixel"
            case .red: return "Red LED"
            case .green: return "Green LED"
            case .blue: return "Blue LED"
            }
        }
    }

    // MARK: Low level (inside one NovaLink session)

    static func read(_ socket: NovaSocket, _ card: Card, offset: Int, count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var at = offset
        while at < offset + count {
            let n = min(blockSize, offset + count - at)
            let data = try socket.transact(.read(base + UInt32(at), length: UInt16(n), device: 1,
                                                 port: UInt8(card.port), card: UInt16(card.card)))
            guard data.count == n else { throw NovaLinkError.badResponse("short coefficient read") }
            out += data
            at += n
        }
        return out
    }

    static func write(_ socket: NovaSocket, _ card: Card, offset: Int, bytes: [UInt8]) throws {
        var at = 0
        while at < bytes.count {
            let n = min(blockSize, bytes.count - at)
            try socket.transact(.write(base + UInt32(offset + at), Array(bytes[at..<at + n]), device: 1,
                                       port: UInt8(card.port), card: UInt16(card.card)))
            at += n
        }
    }

    static func adjustFrame(type: UInt8, rect: PixelRect, factors: Factors?) -> [UInt8] {
        var b: [UInt8] = [type] + NovaBytes.le16(rect.x) + NovaBytes.le16(rect.y) + NovaBytes.le16(rect.width) + NovaBytes.le16(rect.height)
        for f in factors.map({ [$0.red, $0.green, $0.blue] }) ?? [0, 0, 0] {
            let raw = Int((min(max(f, factorRange.lowerBound), factorRange.upperBound) * 2048).rounded())
            b += NovaBytes.le16(raw) + [UInt8](repeating: 0, count: 8)
        }
        return b + [0, 0]
    }

    /// The 16 matrix values of one pixel with `cut` switched off. Row 3 follows row 0, as in every stored pixel.
    static func cutting(_ m: [UInt16], _ cut: Cut) -> [UInt16] {
        guard cut != .pixel else { return [UInt16](repeating: 0, count: 16) }
        let column = cut == .red ? 0 : cut == .green ? 1 : 2
        var r = m
        for row in 0..<3 { r[row * 4 + column] = 0 }
        r[12] = 0; r[13] = r[1]; r[14] = r[2]; r[15] = r[0]
        return r
    }

    /// True while the 32 bytes of a pixel still show `cut`.
    static func isCut(_ bytes: [UInt8], _ cut: Cut) -> Bool {
        guard bytes.count >= pixelSize else { return false }
        let m = matrix(bytes[0..<pixelSize])
        return cutting(m, cut) == m
    }

    static func matrix(_ bytes: ArraySlice<UInt8>) -> [UInt16] {
        let b = Array(bytes)
        return (0..<16).map { UInt16(b[$0 * 2]) | UInt16(b[$0 * 2 + 1]) << 8 }
    }

    static func bytes(_ m: [UInt16]) -> [UInt8] { m.flatMap { NovaBytes.le16($0) } }

    // MARK: Sessions

    /// Whole table of one card. Read in chunks, one session each, so a dropped login costs one chunk.
    static func readTable(_ endpoint: NovaEndpoint, _ card: Card,
                          progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Data {
        let total = card.tableBytes, chunk = blockSize * 64
        var data = Data(capacity: total)
        var at = 0
        while at < total {
            let start = at, n = min(chunk, total - at)
            let part = try await NovaLink.run(endpoint, timeout: 3) { socket in try read(socket, card, offset: start, count: n) }
            data.append(contentsOf: part)
            at += n
            await progress(Double(at) / Double(total))
        }
        return data
    }

    /// Writes a whole table (or the part from `offset`) back into the card's RAM. Not saved.
    static func writeTable(_ endpoint: NovaEndpoint, _ card: Card, _ table: Data, offset: Int = 0,
                           progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let bytes = [UInt8](table), chunk = blockSize * 64
        var at = 0
        while at < bytes.count {
            let part = Array(bytes[at..<min(at + chunk, bytes.count)]), start = offset + at
            try await NovaLink.run(endpoint, timeout: 3) { socket in try write(socket, card, offset: start, bytes: part) }
            at += part.count
            await progress(Double(at) / Double(bytes.count))
        }
    }

    /// Takes the rectangles' current coefficients as the base for `apply` and returns their mean values.
    static func setBase(_ endpoint: NovaEndpoint, _ card: Card, _ rects: [PixelRect]) async throws -> Mean {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            var sums = (0.0, 0.0, 0.0), weight = 0.0
            for rect in rects {
                try socket.transact(.write(adjustRegister, adjustFrame(type: 0, rect: rect, factors: nil), device: 1,
                                           port: UInt8(card.port), card: UInt16(card.card)))
                try CalibrationCoefficients.waitIdle(socket, port: card.port, card: card.card, timeout: 60)
                let m = matrix(try socket.transact(.read(averageRegister, length: 32, device: 1,
                                                         port: UInt8(card.port), card: UInt16(card.card)))[0..<32])
                let w = Double(rect.width * rect.height)
                sums.0 += Double(m[0]) * w; sums.1 += Double(m[5]) * w; sums.2 += Double(m[10]) * w
                weight += w
            }
            let d = max(weight, 1) * 2048
            return Mean(red: sums.0 / d, green: sums.1 / d, blue: sums.2 / d)
        }
    }

    /// Coefficients of the rectangles = their base × `factors` (live, not saved).
    static func apply(_ endpoint: NovaEndpoint, _ card: Card, _ rects: [PixelRect], _ factors: Factors) async throws {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            for rect in rects {
                try socket.transact(.write(adjustRegister, adjustFrame(type: 1, rect: rect, factors: factors), device: 1,
                                           port: UInt8(card.port), card: UInt16(card.card)))
                try CalibrationCoefficients.waitIdle(socket, port: card.port, card: card.card, timeout: 60)
            }
        }
    }

    /// Switches off one pixel (or one of its LEDs) and returns its previous 32 bytes for undo.
    static func cut(_ endpoint: NovaEndpoint, _ card: Card, x: Int, y: Int, _ what: Cut) async throws -> [UInt8] {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            let at = card.offset(x: x, y: y)
            let old = try read(socket, card, offset: at, count: pixelSize)
            let new = bytes(cutting(matrix(old[0..<pixelSize]), what))
            try write(socket, card, offset: at, bytes: new)
            guard try read(socket, card, offset: at, count: pixelSize) == new else {
                throw NovaLinkError.failedStep("The card did not take the new pixel coefficients.")
            }
            return old
        }
    }

    /// Writes 32 stored bytes back into one pixel.
    static func restorePixel(_ endpoint: NovaEndpoint, _ card: Card, x: Int, y: Int, _ old: [UInt8]) async throws {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            let at = card.offset(x: x, y: y)
            try write(socket, card, offset: at, bytes: old)
            guard try read(socket, card, offset: at, count: pixelSize) == old else {
                throw NovaLinkError.failedStep("The card did not take the restored pixel coefficients.")
            }
        }
    }

    /// Current 32 bytes of each pixel at the card-local positions `[x, y]`.
    static func pixels(_ endpoint: NovaEndpoint, _ card: Card, _ positions: [[Int]]) async throws -> [[UInt8]] {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            try positions.map { try read(socket, card, offset: card.offset(x: $0[0], y: $0[1]), count: pixelSize) }
        }
    }
}
