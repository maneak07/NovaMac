import Foundation

// NovaMac — decoder for the LZMA "alone" format (13-byte header: props, dictionary size, unpacked size).
// Receiving cards keep their cabinet description (an XML file) LZMA-compressed at 0x03004000.
// Written from the public LZMA specification (Igor Pavlov, lzma-specification.txt / LzmaSpec.cpp).

nonisolated enum LZMAError: LocalizedError {
    case header, data, truncated
    var errorDescription: String? {
        switch self {
        case .header: return "Not an LZMA stream."
        case .data: return "Corrupted LZMA data."
        case .truncated: return "LZMA data ends early (read more bytes)."
        }
    }
}

nonisolated enum LZMAAlone {
    /// Decodes a complete LZMA-alone stream. `maxOutput` guards against bad headers.
    static func decode(_ input: [UInt8], maxOutput: Int = 8_000_000) throws -> [UInt8] {
        guard input.count >= 13, input[0] < 9 * 5 * 5 else { throw LZMAError.header }
        var d = Int(input[0])
        let lc = d % 9; d /= 9
        let lp = d % 5
        let pb = d / 5
        var dictSize: UInt32 = 0
        for i in 0..<4 { dictSize |= UInt32(input[1 + i]) << (8 * i) }
        var unpack: UInt64 = 0
        for i in 0..<8 { unpack |= UInt64(input[5 + i]) << (8 * i) }
        let sizeKnown = unpack != UInt64.max
        if sizeKnown && unpack > UInt64(maxOutput) { throw LZMAError.header }
        var decoder = Decoder(input: input, start: 13, lc: lc, lp: lp, pb: pb, dictSize: max(dictSize, 4096))
        return try decoder.run(unpackSize: sizeKnown ? Int(unpack) : nil, maxOutput: maxOutput)
    }

    /// All probability models live in one array (offsets below) so the bit decoder can update them in place.
    private struct Decoder {
        static let isMatch = 0, isRep = 192, isRepG0 = 204, isRepG1 = 216, isRepG2 = 228, isRep0Long = 240
        static let posSlot = 432, posDecoders = 688, align = 803, lenCoder = 819, repLenCoder = 1333, literal = 1847
        // Length model layout (relative): choice 0, choice2 1, low 2 (16 × 8), mid 130 (16 × 8), high 258 (256).

        let input: [UInt8]
        var inPos: Int
        var range: UInt32 = 0xFFFF_FFFF
        var code: UInt32 = 0
        let lc: Int, lp: Int, pb: Int
        let dictSize: UInt32
        var out: [UInt8] = []
        var p: [UInt16]

        init(input: [UInt8], start: Int, lc: Int, lp: Int, pb: Int, dictSize: UInt32) {
            self.input = input; self.inPos = start
            self.lc = lc; self.lp = lp; self.pb = pb; self.dictSize = dictSize
            p = Array(repeating: 1024, count: Self.literal + (0x300 << (lc + lp)))
        }

        mutating func nextByte() throws -> UInt8 {
            guard inPos < input.count else { throw LZMAError.truncated }
            let b = input[inPos]
            inPos += 1
            return b
        }

        mutating func normalize() throws {
            if range < (1 << 24) {
                range <<= 8
                code = (code << 8) | UInt32(try nextByte())
            }
        }

        mutating func bit(_ i: Int) throws -> Int {
            let prob = p[i]
            let bound = (range >> 11) &* UInt32(prob)
            let result: Int
            if code < bound {
                p[i] = prob + ((2048 - prob) >> 5)
                range = bound
                result = 0
            } else {
                p[i] = prob - (prob >> 5)
                code &-= bound
                range &-= bound
                result = 1
            }
            try normalize()
            return result
        }

        mutating func directBits(_ count: Int) throws -> UInt32 {
            var res: UInt32 = 0
            for _ in 0..<count {
                range >>= 1
                code &-= range
                let t: UInt32 = 0 &- (code >> 31)
                code &+= range & t
                if code == range { throw LZMAError.data }
                res = (res << 1) &+ (t &+ 1)
                try normalize()
            }
            return res
        }

        mutating func tree(_ base: Int, bits: Int) throws -> Int {
            var m = 1
            for _ in 0..<bits { m = (m << 1) + (try bit(base + m)) }
            return m - (1 << bits)
        }

        mutating func reverseTree(_ base: Int, bits: Int) throws -> Int {
            var m = 1, symbol = 0
            for i in 0..<bits {
                let b = try bit(base + m)
                m = (m << 1) + b
                symbol |= b << i
            }
            return symbol
        }

        mutating func length(_ model: Int, posState: Int) throws -> Int {
            if try bit(model) == 0 { return try tree(model + 2 + (posState << 3), bits: 3) }
            if try bit(model + 1) == 0 { return 8 + (try tree(model + 130 + (posState << 3), bits: 3)) }
            return 16 + (try tree(model + 258, bits: 8))
        }

        mutating func distance(_ len: Int) throws -> UInt32 {
            let lenState = min(len, 3)
            let slot = try tree(Self.posSlot + (lenState << 6), bits: 6)
            if slot < 4 { return UInt32(slot) }
            let numDirectBits = (slot >> 1) - 1
            var dist = UInt32(2 | (slot & 1)) << UInt32(numDirectBits)
            if slot < 14 {
                dist &+= UInt32(try reverseTree(Self.posDecoders + Int(dist) - slot, bits: numDirectBits))
            } else {
                dist &+= (try directBits(numDirectBits - 4)) << 4
                dist &+= UInt32(try reverseTree(Self.align, bits: 4))
            }
            return dist
        }

        mutating func run(unpackSize: Int?, maxOutput: Int) throws -> [UInt8] {
            guard try nextByte() == 0 else { throw LZMAError.data }
            for _ in 0..<4 { code = (code << 8) | UInt32(try nextByte()) }
            if code == range { throw LZMAError.data }
            out.reserveCapacity(unpackSize ?? 65536)

            var rep0: UInt32 = 0, rep1: UInt32 = 0, rep2: UInt32 = 0, rep3: UInt32 = 0
            var state = 0
            let pbMask = (1 << pb) - 1, lpMask = (1 << lp) - 1

            while true {
                if let unpackSize, out.count >= unpackSize { break }
                guard out.count < maxOutput else { throw LZMAError.data }
                let posState = out.count & pbMask

                if try bit(Self.isMatch + (state << 4) + posState) == 0 {
                    // Literal
                    let prev = out.last.map(Int.init) ?? 0
                    let litState = ((out.count & lpMask) << lc) + (prev >> (8 - lc))
                    let base = Self.literal + 0x300 * litState
                    var symbol = 1
                    if state >= 7 {
                        var matchByte = Int(out[out.count - Int(rep0) - 1])
                        repeat {
                            let matchBit = (matchByte >> 7) & 1
                            matchByte <<= 1
                            let b = try bit(base + ((1 + matchBit) << 8) + symbol)
                            symbol = (symbol << 1) | b
                            if matchBit != b { break }
                        } while symbol < 0x100
                    }
                    while symbol < 0x100 { symbol = (symbol << 1) | (try bit(base + symbol)) }
                    out.append(UInt8(symbol - 0x100))
                    state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6)
                    continue
                }

                var len: Int
                if try bit(Self.isRep + state) != 0 {
                    guard !out.isEmpty else { throw LZMAError.data }
                    if try bit(Self.isRepG0 + state) == 0 {
                        if try bit(Self.isRep0Long + (state << 4) + posState) == 0 {
                            state = state < 7 ? 9 : 11
                            out.append(out[out.count - Int(rep0) - 1])
                            continue
                        }
                    } else {
                        let dist: UInt32
                        if try bit(Self.isRepG1 + state) == 0 {
                            dist = rep1
                        } else {
                            if try bit(Self.isRepG2 + state) == 0 {
                                dist = rep2
                            } else {
                                dist = rep3
                                rep3 = rep2
                            }
                            rep2 = rep1
                        }
                        rep1 = rep0
                        rep0 = dist
                    }
                    len = try length(Self.repLenCoder, posState: posState)
                    state = state < 7 ? 8 : 11
                } else {
                    rep3 = rep2; rep2 = rep1; rep1 = rep0
                    len = try length(Self.lenCoder, posState: posState)
                    state = state < 7 ? 7 : 10
                    rep0 = try distance(len)
                    if rep0 == 0xFFFF_FFFF { break }          // end marker
                    guard rep0 < dictSize, Int(rep0) < out.count else { throw LZMAError.data }
                }
                len += 2
                if let unpackSize { len = min(len, unpackSize - out.count) }
                let from = out.count - Int(rep0) - 1
                for i in 0..<len { out.append(out[from + i]) }
            }
            return out
        }
    }
}
