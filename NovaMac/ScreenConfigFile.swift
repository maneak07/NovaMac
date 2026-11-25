import Foundation

// NovaMac — the screen list NovaLCT keeps in the sending card ("NSSD" file), read the way NovaLCT's
// Screen Connection → Read from HW does it (H2, TCP 5202, capture 25.11.2026). Device 0 (sending card):
//   0x05000000  header: "NSSD", u16 ?, u16 version (1001), u16 length of the props block,
//               u16 ?, u32 packed length of the section index, u32 its unpacked length, u16 checksum
//   0x05000200  props block: u16 n, then n bytes of LZMA properties (5D 00 00 10 00)
//   0x05000400  section index, LZMA (raw stream, the props above) → JSON
//               {"SectionFormat":[{"FileType":"ScreenDataType","Addr":…,"SrcLength":…,"DestLength":…,"DecompressProps":…}]}
//   Addr        the screen data, LZMA → JSON {"ScreenDataInSoftSpace":[screen…]}, every screen with
//               ScrType (1 standard, 2 complex), CabinetCol/Row and CabinetInDevice: DevID, NetPort (0-based),
//               ConnectID (0-based chain index), XPos, YPos, Width, Height (absolute in the input).
// Reads only. It is NovaLCT's own copy: what NovaLCT last saved, not necessarily what the cards run.

nonisolated enum ScreenConfigFile {
    struct Cabinet: Sendable {
        let device: Int, port: Int, index: Int     // 0-based
        let x: Int, y: Int, width: Int, height: Int
    }
    struct Screen: Sendable {
        let number: Int            // ScreenIndex + 1
        let complex: Bool
        let columns: Int, rows: Int
        let cabinets: [Cabinet]
    }

    static func read(_ endpoint: NovaEndpoint) async throws -> [Screen] {
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            func get(_ address: UInt32, _ length: Int) throws -> [UInt8] {
                var out: [UInt8] = []
                while out.count < length {
                    let n = min(512, length - out.count)
                    out += try socket.transact(.read(address + UInt32(out.count), length: UInt16(n)))
                }
                return out
            }
            func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
            func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }
            func unpack(_ raw: [UInt8], props: [UInt8], size: Int) throws -> [UInt8] {
                var header = props
                for k in 0..<8 { header.append(UInt8((UInt64(size) >> (8 * UInt64(k))) & 0xFF)) }
                return try LZMAAlone.decode(header + raw, maxOutput: 4_000_000)
            }

            let head = try get(0x0500_0000, 32)
            guard head.count >= 22, Array(head[0..<4]) == Array("NSSD".utf8) else {
                throw NovaLinkError.badResponse("no NovaLCT screen file in this controller")
            }
            let block = try get(0x0500_0200, max(2, u16(head, 8)))
            let props = Array(block[2..<min(block.count, 2 + u16(block, 0))])
            guard props.count == 5 else { throw NovaLinkError.badResponse("screen file: unexpected LZMA properties") }
            let indexPacked = u32(head, 12), indexSize = u32(head, 16)
            guard (1...65536).contains(indexPacked), (1...1_000_000).contains(indexSize) else {
                throw NovaLinkError.badResponse("screen file: bad index length")
            }
            let index = try unpack(try get(0x0500_0400, indexPacked), props: props, size: indexSize)

            struct Section: Decodable {
                let FileType: String, Addr: Int, SrcLength: Int, DestLength: Int
                let DecompressProps: String?
            }
            struct Index: Decodable { let SectionFormat: [Section] }
            guard let section = try JSONDecoder().decode(Index.self, from: Data(index)).SectionFormat
                    .first(where: { $0.FileType == "ScreenDataType" }),
                  (1...4_000_000).contains(section.DestLength), section.SrcLength > 0 else {
                throw NovaLinkError.badResponse("screen file: no screen section")
            }
            let sectionProps = section.DecompressProps.map { $0.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } } ?? props
            let data = try unpack(try get(UInt32(section.Addr), section.DestLength),
                                  props: sectionProps.count == 5 ? sectionProps : props, size: section.SrcLength)

            struct Cab: Decodable { let DevID: Int?, NetPort: Int, ConnectID: Int, XPos: Int, YPos: Int, Width: Int, Height: Int }
            struct Scr: Decodable { let ScrType: Int?, CabinetCol: Int?, CabinetRow: Int?, ScreenIndex: Int?, CabinetInDevice: [Cab] }
            struct Root: Decodable { let ScreenDataInSoftSpace: [Scr] }
            let root = try JSONDecoder().decode(Root.self, from: Data(data))
            return root.ScreenDataInSoftSpace.enumerated().compactMap { k, s -> Screen? in
                guard !s.CabinetInDevice.isEmpty else { return nil }
                return Screen(number: (s.ScreenIndex ?? k) + 1, complex: s.ScrType == 2,
                              columns: s.CabinetCol ?? 0, rows: s.CabinetRow ?? 0,
                              cabinets: s.CabinetInDevice.map {
                                  Cabinet(device: $0.DevID ?? 0, port: $0.NetPort, index: $0.ConnectID,
                                          x: $0.XPos, y: $0.YPos, width: $0.Width, height: $0.Height)
                              })
            }
        }
    }

    /// NovaLCT's file says which ports belong to which screen, but its cabinet positions can be stale or
    /// wrong (complex screens especially), while the receiving cards' own coordinate tables are what the
    /// LED screen shows. So: grouping by port from the file, cabinets and positions from the cards.
    /// Ports the file does not mention go to its complex screen when it has exactly one, otherwise to a
    /// screen of their own. A file screen whose ports have no answering card keeps the file's cabinets.
    static func merge(_ screens: [Screen], hardware: [RegisterInventory.Card]) -> (screens: [Screen], changed: Set<Int>) {
        guard !hardware.isEmpty else { return (screens, []) }
        var owner: [Int: Int] = [:]                      // port → index in screens
        for (k, s) in screens.enumerated() { for c in s.cabinets where owner[c.port] == nil { owner[c.port] = k } }
        let leftovers = hardware.filter { owner[$0.port] == nil }
        let complex = screens.indices.filter { screens[$0].complex }
        var extraTarget: Int? = complex.count == 1 ? complex[0] : nil
        var result = screens
        if !leftovers.isEmpty, extraTarget == nil {
            result.append(Screen(number: (screens.map(\.number).max() ?? 0) + 1, complex: true, columns: 0, rows: 0, cabinets: []))
            extraTarget = result.count - 1
        }
        var changed: Set<Int> = []
        for k in result.indices {
            let ports = Set(result[k].cabinets.map(\.port))
            let cards = hardware.filter { ports.contains($0.port) || (k == extraTarget && owner[$0.port] == nil) }
            guard !cards.isEmpty else { continue }
            let old = result[k]
            let cabinets = cards.map { card -> Cabinet in
                let filed = old.cabinets.first { $0.port == card.port && $0.index == card.index }
                return Cabinet(device: filed?.device ?? 0, port: card.port, index: card.index,
                               x: card.x ?? filed?.x ?? 0, y: card.y ?? filed?.y ?? 0,
                               width: (card.width ?? 0) > 0 ? card.width! : (filed?.width ?? 160),
                               height: (card.height ?? 0) > 0 ? card.height! : (filed?.height ?? 360))
            }
            func key(_ c: Cabinet) -> [Int] { [c.port, c.index, c.x, c.y, c.width, c.height] }
            let same = cabinets.map(key).sorted { $0.lexicographicallyPrecedes($1) }
                == old.cabinets.map(key).sorted { $0.lexicographicallyPrecedes($1) }
            if !same { changed.insert(old.number) }
            let keepGrid = same || cabinets.count == old.cabinets.count
            result[k] = Screen(number: old.number, complex: old.complex, columns: keepGrid ? old.columns : 0,
                               rows: keepGrid ? old.rows : 0, cabinets: cabinets)
        }
        return (result, changed)
    }

    /// Editable plan of one screen: cards at their absolute positions on the controller's output (Send to HW
    /// writes absolute positions; the screen's place is the box around its cards).
    @MainActor static func plan(_ screen: Screen) -> ScreenConnectionPlan {
        var plan = ScreenConnectionPlan()
        let n = screen.cabinets.count
        if screen.columns > 0, screen.rows > 0, screen.columns <= 64, screen.rows <= 64, screen.columns * screen.rows >= n {
            plan.columns = screen.columns; plan.rows = screen.rows
        } else {
            plan.columns = min(64, max(1, n)); plan.rows = max(1, (n + 63) / 64)
        }
        plan.cells = screen.cabinets.enumerated().map { i, c in
            var cell = ScreenConnectionPlan.Cell(id: i, width: c.width, height: c.height, sender: c.device + 1,
                                                 port: c.port + 1, order: c.index + 1)
            cell.x = c.x; cell.y = c.y
            return cell
        }
        return plan
    }
}
