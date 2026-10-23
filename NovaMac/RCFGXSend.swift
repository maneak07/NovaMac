import Foundation

// NovaMac — sending an RCFGX configuration to receiving cards over USB or TCP 5200.
//
// The .bin inside an .rcfgx is the exact list of register writes NovaLCT performs on "Send"
// (verified 21.10.2026: Koala.rcfgx ↔ NovaLCT send to MCTRL300 + 2 × XC160-1 captured over USB —
// all 58 records, every byte, same order):
//   64-byte header ("RCCB", u32 total size, u32 checksum), then records:
//     u32 record length (32 + data) · u16 type (1 = write) · u32 register address · u32 data length
//     · u16 delay after the write in ms (25, 2000…) · 16 reserved bytes · data
//   NovaLCT writes every record to device 1 (receiving cards), broadcast dst FF / port FF / card FFFF,
//   in pieces of 256 bytes, and waits the record's delay afterwards.
// Changing one value in NovaLCT changes many derived tables (timing, gamma, driver registers),
// so NovaMac sends whole configuration files rather than single values.

nonisolated struct RCFGXRecord: Sendable, Equatable {
    let address: UInt32
    let data: [UInt8]
    let delayMs: Int
}

nonisolated enum RCFGXBin {
    enum Failure: LocalizedError {
        case format(String)
        var errorDescription: String? { if case .format(let s) = self { return "RCFGX payload: \(s)" }; return nil }
    }

    static func records(_ bin: [UInt8]) throws -> [RCFGXRecord] {
        // Header: "RCCB", u32 total size, u32 checksum, zero padding to 64 bytes.
        guard bin.count >= 64, Array(bin[0..<4]) == Array("RCCB".utf8) else {
            throw Failure.format("not an RCCB register list (starts \(bin.prefix(8).map { String(format: "%02X", Int($0)) }.joined()))")
        }
        func u32(_ i: Int) -> Int { Int(bin[i]) | Int(bin[i + 1]) << 8 | Int(bin[i + 2]) << 16 | Int(bin[i + 3]) << 24 }
        guard u32(4) == bin.count else { throw Failure.format("size field \(u32(4)) ≠ payload \(bin.count) bytes") }
        func u16(_ i: Int) -> Int { Int(bin[i]) | Int(bin[i + 1]) << 8 }
        var records: [RCFGXRecord] = []
        var i = 64
        while i < bin.count {
            guard i + 32 <= bin.count else { throw Failure.format("truncated record header at \(i)") }
            let total = u32(i), type = u16(i + 4), address = u32(i + 6), length = u32(i + 10), delay = u16(i + 14)
            guard type == 1, total == 32 + length, i + total <= bin.count else {
                throw Failure.format("unknown record at \(i) (type \(type), length \(length))")
            }
            records.append(RCFGXRecord(address: UInt32(address), data: Array(bin[(i + 32)..<(i + total)]), delayMs: delay))
            i += total
        }
        guard !records.isEmpty else { throw Failure.format("no records") }
        return records
    }

    /// Bytes the file writes into the receiving card's parameter block (0x02000000…0x020001FF), by offset.
    static func parameterImage(_ records: [RCFGXRecord]) -> [Int: UInt8] {
        var image: [Int: UInt8] = [:]
        for record in records where record.address >= 0x0200_0000 && record.address < 0x0200_0200 {
            let start = Int(record.address - 0x0200_0000)
            for (k, b) in record.data.enumerated() where start + k < 512 { image[start + k] = b }
        }
        return image
    }

    /// True when the card's parameter block holds what this file writes.
    /// Ignored: 0x01 (brightness — the sending card sets it at run time) and the bytes the file leaves
    /// at FF in 0x13A…0x14D (filled by the card itself). Checked on the Koala files: the running file
    /// matches, the same file with another refresh multiplier differs in 9 bytes.
    static func matches(_ records: [RCFGXRecord], block: [UInt8]) -> Bool {
        let image = parameterImage(records)
        guard image.count > 64, block.count >= 512 else { return false }
        for (offset, value) in image where offset != 0x01 && offset < block.count {
            if (0x13A...0x14D).contains(offset) && value == 0xFF { continue }
            if block[offset] != value { return false }
        }
        return true
    }

    /// Sends all records. `port`/`card` nil = every receiving card on the controller (as NovaLCT does).
    /// `progress(sentBytes, totalBytes)` is called from the background thread.
    static func send(_ endpoint: NovaEndpoint, records: [RCFGXRecord], port: Int?, card: Int?,
                     progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        let total = records.reduce(0) { $0 + $1.data.count }
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            _ = try socket.transact(.read(0x0000_0002, length: 2))       // link check before writing anything
            var sent = 0, pieces = 0
            for record in records {
                var offset = 0
                while offset < record.data.count {
                    let piece = Array(record.data[offset..<min(offset + 256, record.data.count)])
                    let command: NovaCommand
                    if let port, let card {
                        command = .write(record.address + UInt32(offset), piece, device: 1, port: UInt8(port), card: UInt16(card))
                    } else {
                        command = .write(record.address + UInt32(offset), piece, destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF)
                    }
                    try socket.transact(command)
                    offset += piece.count
                    sent += piece.count
                    pieces += 1
                    if pieces % 16 == 0 { progress(sent, total) }
                }
                if record.delayMs > 0 { Thread.sleep(forTimeInterval: Double(record.delayMs) / 1000) }
            }
            progress(total, total)
        }
    }
}

// MARK: - Reading a card back into an RCFGX payload

nonisolated extension RCFGXBin {
    /// Bytes of the 0x02000000 block that a file keeps as the template has them: test pattern / black / freeze and
    /// the status area the card fills in itself.
    static let templateOwned: Set<Int> = Set([0x100, 0x101, 0x102]).union(Set(0x13A...0x14D))

    /// Fills every record of `template` (an RCFGX payload of the same cabinet type) with what the card at
    /// port/card holds now, and keeps the header checksum consistent. Records the card does not let be read
    /// (control commands 0x01…, unreadable tables) keep the template's bytes and are listed in `kept`.
    static func readBack(_ endpoint: NovaEndpoint, template: [UInt8], port: Int, card: Int,
                         progress: @escaping @Sendable (Int, Int) -> Void) async throws -> (bin: [UInt8], kept: [UInt32]) {
        var out = template
        func u32(_ k: Int) -> Int { Int(out[k]) | Int(out[k + 1]) << 8 | Int(out[k + 2]) << 16 | Int(out[k + 3]) << 24 }
        func u16(_ k: Int) -> Int { Int(out[k]) | Int(out[k + 1]) << 8 }
        // (data offset in the payload, register address, length) of every record
        var records: [(Int, UInt32, Int)] = []
        var i = 64
        while i + 32 <= out.count {
            let total = u32(i), address = u32(i + 6), length = u32(i + 10)
            guard u16(i + 4) == 1, total == 32 + length, i + total <= out.count else { throw Failure.format("record at \(i)") }
            records.append((i + 32, UInt32(address), length))
            i += total
        }
        let recordList = records          // immutable copy for the background closure
        let readable = recordList.filter { $0.1 >> 24 != 0x01 }
        let totalBytes = readable.reduce(0) { $0 + $1.2 } + 512
        let (fills, kept) = try await NovaLink.run(endpoint, timeout: 2) { socket -> ([(Int, [UInt8])], [UInt32]) in
            func read(_ address: UInt32, _ length: Int) throws -> [UInt8] {
                var data: [UInt8] = []
                var offset = 0
                while offset < length {
                    let n = min(256, length - offset)
                    data += try socket.transact(.read(address + UInt32(offset), length: UInt16(n), device: 1, port: UInt8(port), card: UInt16(card)))
                    offset += n
                }
                return data
            }
            let block = try read(0x0200_0000, 512)
            var done = 512
            var fills: [(Int, [UInt8])] = []
            var kept: [UInt32] = []
            var cache: [UInt32: [UInt8]] = [:]
            for (start, address, length) in recordList {
                if address >> 24 == 0x01 { kept.append(address); continue }
                if address >= 0x0200_0000 && address + UInt32(length) <= 0x0200_0200 {
                    let base = Int(address - 0x0200_0000)
                    let bytes = (0..<length).map { k -> UInt8 in
                        templateOwned.contains(base + k) ? template[start + k] : block[base + k]
                    }
                    fills.append((start, bytes))
                    continue
                }
                do {
                    let data: [UInt8]
                    if let c = cache[address], c.count >= length { data = Array(c.prefix(length)) }
                    else { data = try read(address, length); cache[address] = data }
                    fills.append((start, data))
                } catch NovaLinkError.nack {
                    kept.append(address)
                }
                done += length
                progress(done, totalBytes)
            }
            progress(totalBytes, totalBytes)
            return (fills, kept)
        }
        var delta = 0
        for (start, bytes) in fills {
            for (k, b) in bytes.enumerated() {
                delta += Int(b) - Int(out[start + k])
                out[start + k] = b
            }
        }
        let sum = (u32(8) + delta) & 0xFFFF_FFFF
        for k in 0..<4 { out[8 + k] = UInt8((sum >> (8 * k)) & 0xFF) }
        return (out, kept)
    }
}

// MARK: - Editing (parameters that NovaLCT writes as plain bytes)
//
// Found by exporting single-parameter variants from NovaLCT (21.10.2026, Koala / XC160-1, ICND2065):
// each variant below is reproduced byte-for-byte by patching the base file.
//   block 0x08  DCLK duty ratio (%)              block 0x38  DCLK cycle (DCLK = 125 MHz / cycle)
//   block 0x39  DCLK phase (0…cycle-1)          block 0x3A  DCLK high = round-half-even(cycle × duty / 100)
//   block 0x2C  line changing time (0…ghost end-1)
//   block 0xAD  ghost control ending (1…row blanking-1); NovaLCT lowers line changing below it
//   block 0x18E ghost elimination (enhanced): 0x0D on / 0x15 off (written twice in the file)
// Refresh multiplier, DCLK frequency, GCLK frequency and row blanking rebuild timing/gamma tables
// (hundreds of bytes in 0x03xxxxxx/0x05xxxxxx/0x1Bxxxxxx) and are not edited here.

nonisolated enum RCFGXEdit {
    /// Value the file finally writes at parameter-block offset `offset` (last record wins).
    static func byte(_ records: [RCFGXRecord], _ offset: Int) -> Int? {
        let address = 0x0200_0000 + UInt32(offset)
        guard let r = records.last(where: { $0.address <= address && address < $0.address + UInt32($0.data.count) }) else { return nil }
        return Int(r.data[Int(address - r.address)])
    }

    /// DCLK high time in cycles: round half to even, as NovaLCT computes it (9 × 50 % → 4, 15 × 50 % → 8).
    static func dclkHigh(cycle: Int, duty: Int) -> Int {
        let x = cycle * duty
        var q = x / 100
        let r = x % 100
        if r > 50 || (r == 50 && q % 2 == 1) { q += 1 }
        return max(1, min(cycle - 1, q))
    }

    /// Patches the parameter-block bytes in every record that writes them and keeps the header checksum
    /// (u32 at offset 8 = sum of the record bytes + a constant) consistent.
    static func apply(_ bin: [UInt8], edits: [Int: UInt8]) throws -> [UInt8] {
        guard !edits.isEmpty else { return bin }
        var out = bin
        var delta = 0
        var i = 64
        func u32(_ k: Int) -> Int { Int(out[k]) | Int(out[k + 1]) << 8 | Int(out[k + 2]) << 16 | Int(out[k + 3]) << 24 }
        while i + 32 <= out.count {
            let total = u32(i), address = u32(i + 6), length = u32(i + 10)
            guard total == 32 + length, i + total <= out.count else { throw RCFGXBin.Failure.format("record at \(i)") }
            for (offset, value) in edits {
                let target = 0x0200_0000 + offset
                if target >= address && target < address + length {
                    let k = i + 32 + (target - address)
                    delta += Int(value) - Int(out[k])
                    out[k] = value
                }
            }
            i += total
        }
        let sum = (u32(8) + delta) & 0xFFFF_FFFF
        for k in 0..<4 { out[8 + k] = UInt8((sum >> (8 * k)) & 0xFF) }
        return out
    }

    /// Replaces the value of top-level XML elements (`<Name>value</Name>` at two-space indent).
    static func updateXML(_ xml: String, _ values: [String: String]) -> String {
        var text = xml
        for (name, value) in values {
            guard let open = text.range(of: "\n  <\(name)>"),
                  let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { continue }
            text.replaceSubrange(open.upperBound..<close.lowerBound, with: value)
        }
        return text
    }

    /// Minimal ZIP writer (stored entries), the container format of .rcfgx.
    static func zip(_ entries: [(name: String, data: [UInt8])]) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        for entry in entries {
            let name: [UInt8] = Array(entry.name.utf8)
            let crc = Int(zipCRC32(entry.data))
            let size = entry.data.count
            let offset = out.count
            // local file header
            out += le32(0x0403_4b50); out += le16(20); out += le16(0x0800); out += le16(0)
            out += le16(0); out += le16(0x21); out += le32(crc); out += le32(size); out += le32(size)
            out += le16(name.count); out += le16(0); out += name; out += entry.data
            // central directory entry
            central += le32(0x0201_4b50); central += le16(20); central += le16(20); central += le16(0x0800)
            central += le16(0); central += le16(0); central += le16(0x21); central += le32(crc)
            central += le32(size); central += le32(size); central += le16(name.count); central += le16(0)
            central += le16(0); central += le16(0); central += le16(0); central += le32(0); central += le32(offset)
            central += name
        }
        let start = out.count
        out += central
        out += le32(0x0605_4b50); out += le16(0); out += le16(0); out += le16(entries.count); out += le16(entries.count)
        out += le32(central.count); out += le32(start); out += le16(0)
        return Data(out)
    }

    private static func zipCRC32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}
