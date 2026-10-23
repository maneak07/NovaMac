import Foundation

// NovaMac — Screen Connection geometry: pixel positions, bounds, overlaps and magnetic snapping.
// A cell without explicit x/y sits where the rows × columns grid puts it (cards touching).

struct PixelRect: Equatable, Sendable {
    var x: Int, y: Int, width: Int, height: Int
    var maxX: Int { x + width }
    var maxY: Int { y + height }
    func intersects(_ o: PixelRect) -> Bool { x < o.maxX && o.x < maxX && y < o.maxY && o.y < maxY }
}

extension ScreenConnectionPlan {
    /// Hard limit of pixels per Ethernet port (sum of W × H of the cards connected to it).
    static let portCapacity = 650_000

    /// Pixels loaded on a sender/port by its connected, non-blank cards.
    func portLoad(sender: Int, port: Int) -> Int {
        cells.filter { !$0.blank && $0.order != nil && $0.sender == sender && $0.port == port }
            .reduce(0) { $0 + $1.width * $1.height }
    }

    struct PortLoad: Hashable, Identifiable {
        let sender: Int, port: Int, pixels: Int
        var id: String { "\(sender)/\(port)" }
    }

    /// Every used sender/port with its load, sorted.
    var portLoads: [PortLoad] {
        var pairs = Set<[Int]>()
        for cell in cells where !cell.blank && cell.order != nil { pairs.insert([cell.sender, cell.port]) }
        return pairs.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
            .map { PortLoad(sender: $0[0], port: $0[1], pixels: portLoad(sender: $0[0], port: $0[1])) }
    }

    /// True if connecting `cell` to sender/port keeps the port within the limit.
    func canConnect(_ cell: Cell, sender: Int, port: Int) -> Bool {
        let already = !cell.blank && cell.order != nil && cell.sender == sender && cell.port == port
        return already || portLoad(sender: sender, port: port) + cell.width * cell.height <= Self.portCapacity
    }

    /// Grid-derived position of a cell (cumulative sizes along its row and column).
    func gridPosition(of id: Int) -> (x: Int, y: Int) {
        let col = id % columns, row = id / columns
        let byID = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let x = (0..<col).reduce(0) { $0 + (byID[row * columns + $1]?.width ?? 0) }
        let y = (0..<row).reduce(0) { $0 + (byID[$1 * columns + col]?.height ?? 0) }
        return (x, y)
    }

    func rect(of cell: Cell) -> PixelRect {
        if let x = cell.x, let y = cell.y { return PixelRect(x: x, y: y, width: cell.width, height: cell.height) }
        let grid = gridPosition(of: cell.id)
        return PixelRect(x: cell.x ?? grid.x, y: cell.y ?? grid.y, width: cell.width, height: cell.height)
    }

    var rects: [Int: PixelRect] { Dictionary(cells.map { ($0.id, rect(of: $0)) }, uniquingKeysWith: { a, _ in a }) }

    /// Bounding size of all cards (from 0,0).
    var pixelBounds: (width: Int, height: Int) {
        let all = rects.values
        return (all.map(\.maxX).max() ?? 0, all.map(\.maxY).max() ?? 0)
    }

    /// IDs of non-blank cells that overlap another non-blank cell.
    var overlappingIDs: Set<Int> {
        let list = cells.filter { !$0.blank }.map { ($0.id, rect(of: $0)) }
        var result = Set<Int>()
        for i in list.indices {
            for j in list.indices where j > i && list[i].1.intersects(list[j].1) {
                result.insert(list[i].0); result.insert(list[j].0)
            }
        }
        return result
    }

    /// True when every card sits exactly where the rows × columns grid would put it.
    var isRegularGrid: Bool {
        cells.allSatisfy { cell in
            let g = gridPosition(of: cell.id), r = rect(of: cell)
            return r.x == g.x && r.y == g.y
        }
    }

    /// Freezes all positions so that moving one card does not shift the others.
    mutating func pinPositions() {
        let current = rects
        for i in cells.indices { cells[i].x = current[cells[i].id]?.x; cells[i].y = current[cells[i].id]?.y }
    }

    /// Clears explicit positions (back to the rows × columns grid).
    mutating func unpinPositions() {
        for i in cells.indices { cells[i].x = nil; cells[i].y = nil }
    }

    /// Magnetic snapping for a card being moved to `proposed`.
    /// 1) edges of other cards (and 0) within `threshold` pixels win; 2) otherwise the grid step.
    func snapped(id: Int, proposedX: Int, proposedY: Int, threshold: Int, magnet: Bool, gridStep: Int?,
                 limitWidth: Int = 65535, limitHeight: Int = 65535) -> (x: Int, y: Int) {
        guard let me = cells.first(where: { $0.id == id }) else { return (proposedX, proposedY) }
        let others = cells.filter { $0.id != id }.map { rect(of: $0) }
        func pick(_ value: Int, candidates: [Int]) -> Int {
            if magnet, let best = candidates.min(by: { abs($0 - value) < abs($1 - value) }), abs(best - value) <= threshold {
                return best
            }
            if let step = gridStep, step > 1 { return Int((Double(value) / Double(step)).rounded()) * step }
            return value
        }
        let xs = [0] + others.flatMap { [$0.x, $0.maxX, $0.x - me.width, $0.maxX - me.width] }
        let ys = [0] + others.flatMap { [$0.y, $0.maxY, $0.y - me.height, $0.maxY - me.height] }
        let x = pick(proposedX, candidates: xs)
        let y = pick(proposedY, candidates: ys)
        return (min(max(x, 0), max(0, limitWidth - me.width)), min(max(y, 0), max(0, limitHeight - me.height)))
    }
}
