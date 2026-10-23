import SwiftUI

// NovaMac — seam brightness (NovaLCT "Seam Brightness Adjustment"), captured on VX1000 Pro 21.10.2026.
// A seam is corrected by scaling the pixel rows (or columns) next to it. One write per line and card:
//   dev1, port p, card c, register 0x01000024, 45 bytes:
//     [0] 01   [1-2] x   [3-4] y   [5-6] width   [7-8] height   — a rectangle inside the card
//     (row: x 0, y 179, 160 × 1;  column: x 159, y 1, 1 × 178 — both captured)
//     3 × { u16 coefficient, 8 × 00 }  (R, G, B)   00 00   05   u16 (coefficient | 0x5000)   00
//   coefficient = value × 2048 (1.000 = 0x0800, 0.300 = 0x0266), NovaLCT range 0.300 … 1.200.
// Save to HW: dev1 port p card FFFF 0x01000004 = A2 (confirmed with a second capture).

nonisolated enum SeamBrightness {
    struct Line: Sendable, Hashable {
        let port: Int      // 0-based
        let card: Int      // 0-based chain index
        let x: Int         // rectangle inside the card
        let y: Int
        let width: Int
        let height: Int
    }

    static let register: UInt32 = 0x0100_0024
    static let range = 0.3...1.2

    static func coefficient(_ value: Double) -> Int { Int(min(max(value, range.lowerBound), range.upperBound) * 2048) }

    static func payload(_ line: Line, coefficient c: Int) -> [UInt8] {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        var b: [UInt8] = [0x01] + le16(line.x) + le16(line.y) + le16(line.width) + le16(line.height)
        for _ in 0..<3 { b += le16(c) + [UInt8](repeating: 0, count: 8) }
        b += [0, 0, 0x05] + le16(c | 0x5000) + [0]
        return b
    }

    static func apply(_ endpoint: NovaEndpoint, lines: [Line], value: Double) async throws {
        let c = coefficient(value)
        let frames = lines.map { ($0, payload($0, coefficient: c)) }
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            for (line, data) in frames {
                try socket.transact(.write(register, data, device: 1, port: UInt8(line.port), card: UInt16(line.card)))
            }
        }
    }

    static func save(_ endpoint: NovaEndpoint, ports: [Int]) async throws {
        try await NovaLink.run(endpoint, timeout: 3) { socket in
            for p in ports {
                try socket.transact(.write(0x0100_0004, [0xA2], device: 1, port: UInt8(p), card: 0xFFFF))
            }
        }
    }
}

/// Seams of one screen, module by module: every module edge that touches another module or cabinet
/// is its own segment (as in NovaLCT). "Whole lines" selects every segment on the same line at once.
struct SeamPanel: View {
    @ObservedObject var screen: ScreenDocument
    @ObservedObject var device: NovaDevice

    /// Absolute screen coordinates. Row: seam at y, from x0 to x1. Column: seam at x, from y0 to y1.
    enum Seam: Hashable {
        case row(y: Int, x0: Int, x1: Int)
        case column(x: Int, y0: Int, y1: Int)
        var isRow: Bool { if case .row = self { return true } else { return false } }
        var line: Int { switch self { case .row(let y, _, _): return y; case .column(let x, _, _): return x } }
    }

    @State private var moduleWidth = 0           // 0 = card width
    @State private var moduleHeight = 0          // 0 = card height
    @State private var wholeLines = false
    @State private var selected: Set<Seam> = []
    @State private var values: [Seam: Double] = [:] // set in this session
    @State private var value = 1.0
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?

    private struct Card { let port: Int, card: Int, rect: PixelRect }

    private var cards: [Card] {
        screen.plan.cells.filter { $0.order != nil && !$0.blank }.map {
            Card(port: $0.port - 1, card: $0.order! - 1, rect: screen.plan.rect(of: $0))
        }
    }

    private var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let r = cards.map(\.rect)
        return (r.map(\.x).min() ?? 0, r.map(\.y).min() ?? 0, r.map(\.maxX).max() ?? 1, r.map(\.maxY).max() ?? 1)
    }

    /// Module tiles of every card (absolute).
    private var modules: [PixelRect] {
        var tiles: [PixelRect] = []
        for c in cards {
            let mw = moduleWidth > 0 ? min(moduleWidth, c.rect.width) : c.rect.width
            let mh = moduleHeight > 0 ? min(moduleHeight, c.rect.height) : c.rect.height
            var y = c.rect.y
            while y < c.rect.maxY {
                var x = c.rect.x
                let h = min(mh, c.rect.maxY - y)
                while x < c.rect.maxX {
                    tiles.append(PixelRect(x: x, y: y, width: min(mw, c.rect.maxX - x), height: h))
                    x += mw
                }
                y += mh
            }
        }
        return tiles
    }

    /// Module edges inside the screen (outer edges of the screen are not seams).
    private var seams: [Seam] {
        let b = bounds
        let tiles = modules
        func covered(_ x: Int, _ y: Int) -> Bool { tiles.contains { $0.x <= x && x < $0.maxX && $0.y <= y && y < $0.maxY } }
        var set = Set<Seam>()
        for t in tiles {
            let midX = t.x + t.width / 2, midY = t.y + t.height / 2
            if t.y > b.minY, covered(midX, t.y - 1) { set.insert(.row(y: t.y, x0: t.x, x1: t.maxX)) }
            if t.maxY < b.maxY, covered(midX, t.maxY) { set.insert(.row(y: t.maxY, x0: t.x, x1: t.maxX)) }
            if t.x > b.minX, covered(t.x - 1, midY) { set.insert(.column(x: t.x, y0: t.y, y1: t.maxY)) }
            if t.maxX < b.maxX, covered(t.maxX, midY) { set.insert(.column(x: t.maxX, y0: t.y, y1: t.maxY)) }
        }
        return Array(set)
    }

    /// Pixel lines next to a seam segment on every card that touches it. A column segment leaves out the
    /// first and last row of the module (NovaLCT: x 159, y 1, 1 × 178 for a 180-row module) — the corners
    /// belong to the row seams.
    private func lines(_ seam: Seam) -> [SeamBrightness.Line] {
        var result: [SeamBrightness.Line] = []
        for c in cards {
            let r = c.rect
            switch seam {
            case .row(let y, let x0, let x1):
                let a = max(x0, r.x), e = min(x1, r.maxX)
                guard a < e else { continue }
                var rows: [Int] = []
                if r.y < y && y < r.maxY { rows = [y - 1 - r.y, y - r.y] }
                else if y == r.y { rows = [0] }
                else if y == r.maxY { rows = [r.height - 1] }
                for row in rows { result.append(.init(port: c.port, card: c.card, x: a - r.x, y: row, width: e - a, height: 1)) }
            case .column(let x, let y0, let y1):
                let a = max(y0 + 1, r.y), e = min(y1 - 1, r.maxY)
                guard a < e else { continue }
                var cols: [Int] = []
                if r.x < x && x < r.maxX { cols = [x - 1 - r.x, x - r.x] }
                else if x == r.x { cols = [0] }
                else if x == r.maxX { cols = [r.width - 1] }
                for col in cols { result.append(.init(port: c.port, card: c.card, x: col, y: a - r.y, width: 1, height: e - a)) }
            }
        }
        return result
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Module").font(.callout)
                    TextField("W", value: $moduleWidth, format: .number).frame(width: 60)
                        .onSubmit { selected.removeAll() }
                    Text("×")
                    TextField("H", value: $moduleHeight, format: .number).frame(width: 60)
                        .onSubmit { selected.removeAll() }
                    Text("px (0 = whole card)").font(.caption).foregroundStyle(.secondary)
                    Toggle("Whole lines", isOn: $wholeLines)
                        .help("Clicking a segment selects every segment on the same line")
                    Spacer()
                    Button("All rows") { selected = Set(seams.filter(\.isRow)) }
                    Button("All columns") { selected = Set(seams.filter { !$0.isRow }) }
                    Button("Deselect") { selected.removeAll() }
                }
                layout
                HStack(spacing: 12) {
                    Text("Seam brightness").font(.callout)
                    Slider(value: $value, in: SeamBrightness.range, step: 0.005) { EmptyView() } onEditingChanged: { editing in
                        if !editing { apply(value) }
                    }
                    .frame(maxWidth: 360)
                    Text(String(format: "%.3f", value)).font(.callout.monospaced()).frame(width: 50)
                    Stepper("", value: Binding(get: { value }, set: { value = min(max($0, 0.3), 1.2); apply(value) }),
                            in: SeamBrightness.range, step: 0.005).labelsHidden()
                    Button("1.000") { value = 1; apply(1) }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Save to HW") { save() }
                        .help("Stores the seam values in the receiving cards")
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Text("Click module edges to select them (several possible). The cards do not report seam values, so colours show what was set in this session (orange = not 1.000).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Text("Seam correction — \(screen.name)").font(.headline)
        }
    }

    private func color(_ seam: Seam) -> Color {
        if selected.contains(seam) { return .green.opacity(0.85) }
        if let v = values[seam], abs(v - 1) > 0.0001 { return .orange.opacity(0.75) }
        return .blue.opacity(0.25)
    }

    private func tap(_ seam: Seam) {
        let group = wholeLines ? seams.filter { $0.isRow == seam.isRow && $0.line == seam.line } : [seam]
        if selected.contains(seam) { selected.subtract(group) } else { selected.formUnion(group) }
        if let v = values[seam] { value = v }
    }

    private func describe(_ seam: Seam) -> String {
        let v = values[seam].map { String(format: ": %.3f", $0) } ?? ""
        switch seam {
        case .row(let y, let x0, let x1): return "Row seam y = \(y), x \(x0)…\(x1 - 1)" + v
        case .column(let x, let y0, let y1): return "Column seam x = \(x), y \(y0)…\(y1 - 1)" + v
        }
    }

    private var layout: some View {
        let b = bounds
        let w = Double(max(1, b.maxX - b.minX)), h = Double(max(1, b.maxY - b.minY))
        let scale = min(640 / w, 360 / h)
        let model = device.models[screen.endpoint.key]
        let all = seams
        return ZStack(alignment: .topLeading) {
            ForEach(Array(modules.enumerated()), id: \.offset) { _, t in
                Rectangle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    .frame(width: Double(t.width) * scale, height: Double(t.height) * scale)
                    .offset(x: Double(t.x - b.minX) * scale, y: Double(t.y - b.minY) * scale)
            }
            ForEach(Array(cards.enumerated()), id: \.offset) { _, c in
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.7), lineWidth: 1))
                    .overlay(Text("P\(ControllerModels.portLabel(model: model, index: c.port))-\(c.card + 1)")
                        .font(.caption2).foregroundStyle(.secondary))
                    .frame(width: Double(c.rect.width) * scale, height: Double(c.rect.height) * scale)
                    .offset(x: Double(c.rect.x - b.minX) * scale, y: Double(c.rect.y - b.minY) * scale)
                    .allowsHitTesting(false)
            }
            ForEach(all, id: \.self) { seam in
                segment(seam, origin: b, scale: scale)
            }
        }
        .frame(width: w * scale, height: h * scale, alignment: .topLeading)
        .padding(4)
    }

    @ViewBuilder
    private func segment(_ seam: Seam, origin b: (minX: Int, minY: Int, maxX: Int, maxY: Int), scale: Double) -> some View {
        switch seam {
        case .row(let y, let x0, let x1):
            Rectangle().fill(color(seam))
                .frame(width: max(2, Double(x1 - x0) * scale - 4), height: 7)
                .offset(x: Double(x0 - b.minX) * scale + 2, y: Double(y - b.minY) * scale - 3.5)
                .onTapGesture { tap(seam) }
                .help(describe(seam))
        case .column(let x, let y0, let y1):
            Rectangle().fill(color(seam))
                .frame(width: 7, height: max(2, Double(y1 - y0) * scale - 4))
                .offset(x: Double(x - b.minX) * scale - 3.5, y: Double(y0 - b.minY) * scale + 2)
                .onTapGesture { tap(seam) }
                .help(describe(seam))
        }
    }

    private func apply(_ v: Double) {
        let chosen = Array(selected)
        guard !chosen.isEmpty else { status = "Select a seam first."; return }
        let all = chosen.flatMap { lines($0) }
        let endpoint = screen.endpoint
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await SeamBrightness.apply(endpoint, lines: all, value: v)
                for seam in chosen { values[seam] = v }
                status = String(format: "%.3f on %d segment(s), %d line writes. Not saved yet — press Save to HW.", v, chosen.count, all.count)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        let ports = Array(Set(cards.map(\.port))).sorted()
        let endpoint = screen.endpoint
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await SeamBrightness.save(endpoint, ports: ports)
                status = "Saved to the receiving cards."
            } catch { self.error = error.localizedDescription }
        }
    }
}
