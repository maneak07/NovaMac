import Foundation

struct ScreenConnectionPlan: Codable, Equatable {
    var version = 1
    var columns = 4
    var rows = 1
    var originX = 0
    var originY = 0
    var cells: [Cell] = []
    struct Cell: Codable, Identifiable, Equatable {
        var id: Int
        var width = 160
        var height = 360
        var sender = 1
        var port = 1
        var order: Int?
        var blank = false
        // Filled by "Read from HW"; identifies the physical receiving card for a later write.
        var cabinetID: String? = nil
        var netPortID: Int? = nil
        // Free placement in screen pixels. nil = derived from the rows × columns grid.
        var x: Int? = nil
        var y: Int? = nil
        // From Read from HW: the controller keeps this cabinet in its layout but the card is not answering.
        var offline: Bool? = nil
    }
    static func empty() -> Self {
        var plan = Self()
        plan.cells = (0..<4).map { Cell(id: $0) }
        return plan
    }
    func validate() throws {
        guard version == 1, (1...64).contains(columns), (1...64).contains(rows), columns * rows <= 1024,
              (0...65535).contains(originX), (0...65535).contains(originY),
              cells.count == columns * rows, cells.map(\.id).sorted() == Array(0..<cells.count) else {
            throw RCFGXError.invalid("Invalid screen grid or coordinates.")
        }
        var addresses = Set<String>()
        for cell in cells {
            guard (1...8192).contains(cell.width), (1...8192).contains(cell.height),
                  (1...256).contains(cell.sender), (1...32).contains(cell.port),   // up to 32 outputs (fibre controllers); MEE410: 14
                  (0...65535).contains(cell.x ?? 0), (0...65535).contains(cell.y ?? 0) else {
                throw RCFGXError.invalid("Invalid card size, sender or port.")
            }
            if let order = cell.order {
                guard !cell.blank, (1...1024).contains(order), addresses.insert("\(cell.sender)/\(cell.port)/\(order)").inserted else {
                    throw RCFGXError.invalid("Duplicate or invalid receiving card address.")
                }
            }
        }
    }
    // Eight serpentine routes: rows/columns, starting from each corner.
    func route(_ mode: Int) -> [Int] {
        let vertical = mode % 2 == 1
        let right = mode == 2 || mode == 3 || mode == 6 || mode == 7
        let bottom = mode >= 4
        let outer = vertical ? columns : rows
        let inner = vertical ? rows : columns
        return (0..<outer).flatMap { a in
            (0..<inner).map { b in
                let step = a % 2 == 0 ? b : inner - 1 - b
                var row = vertical ? step : a
                var col = vertical ? a : step
                if right { col = columns - 1 - col }
                if bottom { row = rows - 1 - row }
                return row * columns + col
            }
        }
    }
    /// Right-click "undo mapping back to this card": the clicked card stays connected as the last
    /// one; every card connected after it on the same sender/port is disconnected, so connecting
    /// continues right after it. Returns how many cards were disconnected.
    @discardableResult
    mutating func unmap(after id: Int) -> Int {
        guard let cell = cells.first(where: { $0.id == id }), let order = cell.order else { return 0 }
        var removed = 0
        for i in cells.indices where cells[i].sender == cell.sender && cells[i].port == cell.port {
            if let o = cells[i].order, o > order { cells[i].order = nil; removed += 1 }
        }
        return removed
    }

    /// Makes a cell blank (no card: content skips it as a black area, it cannot be mapped) or active again.
    /// A mapped card that becomes blank leaves its chain; the cards after it move up one number.
    mutating func setBlank(_ id: Int, _ value: Bool) {
        guard let i = cells.firstIndex(where: { $0.id == id }), cells[i].blank != value else { return }
        if value, let order = cells[i].order {
            let sender = cells[i].sender, port = cells[i].port
            for j in cells.indices where cells[j].sender == sender && cells[j].port == port {
                if let o = cells[j].order, o > order { cells[j].order = o - 1 }
            }
        }
        cells[i].blank = value
        if value { cells[i].order = nil }
    }

    mutating func connect(mode: Int, sender: Int, port: Int) {
        var order = 1
        for id in route(mode) {
            let index = cells.firstIndex { $0.id == id }!
            cells[index].order = nil
            guard !cells[index].blank else { continue }
            cells[index].sender = sender; cells[index].port = port
            cells[index].order = order; order += 1
        }
    }
}

// Observed NovaLCT V5.9.2 DSC I profile. Imports a regular single-screen grid
// only. The imported plan is local; opaque SCR settings are not re-exported.
struct NovaLCTSCR {
    static func decode(_ data: Data) throws -> ScreenConnectionPlan {
        func invalid(_ detail: String) -> RCFGXError {
            .invalid("NovaLCT SCR: \(detail) No layout was loaded.")
        }
        let b = Array(data)
        func u16(_ n: Int) -> Int { Int(b[n]) | Int(b[n+1]) << 8 }
        func u32(_ n: Int) -> Int { u16(n) | u16(n+2) << 16 }
        guard b.count >= 414, b.count <= 2_000_000,
              Array(b.prefix(4)) == Array("DSCI".utf8),
              u32(6) == 128, u32(10) == 298,
              u16(54) == 1001,
              u16(182) == 1006,
              b[314] == 1 else { throw invalid("Unsupported format/version.") }
        let length = u32(315), start = 319
        guard length >= 25, length <= b.count - start else { throw invalid("Truncated screen block.") }
        // This profile contains one standard screen and a rectangular grid.
        guard b[start] == 1, b[start+1] == 0 else { throw invalid("Only a single standard screen is supported.") }
        let columns = u16(start+6), rows = u16(start+8)
        guard (1...64).contains(columns), (1...64).contains(rows), columns * rows <= 1024,
              length == 10 + columns * rows * 17 + 15 else {
            throw invalid("Unsupported grid or screen block length.")
        }
        var plan = ScreenConnectionPlan()
        plan.columns = columns; plan.rows = rows
        plan.originX = u16(start+2); plan.originY = u16(start+4)
        var positions: [Int: (Int, Int)] = [:]
        for i in 0..<columns*rows {
            let n = start + 10 + i*17
            let col = u16(n+8), row = u16(n+10)
            guard col < columns, row < rows, b[n+16] == 1 else {
                throw invalid("Blank or irregular cards are not supported in this SCR profile.")
            }
            guard b[n] == 0, b[n+1] == 0 else {
                throw invalid("This SCR profile currently supports sender 1 / port 1 only.")
            }
            let id = row * columns + col
            guard positions[id] == nil else { throw invalid("Duplicate grid position.") }
            positions[id] = (u16(n+4), u16(n+6))
            plan.cells.append(.init(id: id, width: u16(n+12), height: u16(n+14),
                                    sender: Int(b[n])+1, port: Int(b[n+1])+1, order: u16(n+2)+1))
        }
        plan.cells.sort { $0.id < $1.id }
        try plan.validate()
        // The editor currently represents a regular grid. Reject layouts whose
        // pixel positions would be lost rather than silently normalizing them.
        for cell in plan.cells {
            let col = cell.id % columns, row = cell.id / columns
            let x = (0..<col).reduce(0) { $0 + plan.cells[row*columns+$1].width }
            let y = (0..<row).reduce(0) { $0 + plan.cells[$1*columns+col].height }
            guard let position = positions[cell.id], position.0 == x, position.1 == y else {
                throw invalid("Custom pixel positions require a complex-screen editor.")
            }
        }
        return plan
    }
}
