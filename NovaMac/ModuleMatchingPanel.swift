import SwiftUI
import AppKit

/// Calibration coefficients of one screen (CoefficientTable): module and cabinet matching with factors on
/// rectangles, Pixel Razor, backups of the tables, saving them to the cards.
struct ModuleMatchingPanel: View {
    @ObservedObject var screen: ScreenDocument
    @ObservedObject var device: NovaDevice
    /// The cards ignore their coefficients while calibration is disabled.
    let calibrationOff: Bool
    @ObservedObject private var store = CoefficientStore.shared

    /// One module (or whole card) to match: card-local rectangle plus its place on the screen.
    private struct Tile: Hashable {
        let card: CoefficientTable.Card
        let x: Int, y: Int, width: Int, height: Int     // inside the card
        let screenX: Int, screenY: Int
        var local: PixelRect { PixelRect(x: x, y: y, width: width, height: height) }
        var absolute: PixelRect { PixelRect(x: screenX, y: screenY, width: width, height: height) }
    }

    private struct PlacedCard: Hashable {
        let card: CoefficientTable.Card
        let x: Int, y: Int                              // top left on the screen
        var rect: PixelRect { PixelRect(x: x, y: y, width: card.width, height: card.height) }
    }

    @AppStorage("NovaMac.coefficients.moduleWidth") private var moduleWidth = 0
    @AppStorage("NovaMac.coefficients.moduleHeight") private var moduleHeight = 0
    @State private var selected: Set<Tile> = []
    @State private var means: [Tile: CoefficientTable.Mean] = [:]   // base of each selected tile
    @State private var brightness = 1.0
    @State private var red = 1.0
    @State private var green = 1.0
    @State private var blue = 1.0
    @State private var backupWaived = false
    @State private var askBackup = false
    @State private var confirmSave = false
    @State private var restoreChoice: [CoefficientStore.Backup] = []
    @State private var confirmRestore = false
    @State private var razorX = 0
    @State private var razorY = 0
    @State private var cut: CoefficientTable.Cut = .pixel

    private var controller: String { screen.endpoint.key }
    private var activity: CoefficientStore.Activity { store.activity[controller] ?? .init() }
    private var busy: Bool { activity.busy }

    private func update(_ change: (inout CoefficientStore.Activity) -> Void) {
        var a = store.activity[controller] ?? .init()
        change(&a)
        store.activity[controller] = a
    }

    private func isUnsaved(_ card: CoefficientTable.Card) -> Bool { store.unsaved.contains(CoefficientStore.key(controller, card)) }
    private func markUnsaved(_ card: CoefficientTable.Card) { store.unsaved.insert(CoefficientStore.key(controller, card)) }

    private var cards: [PlacedCard] {
        screen.plan.cells.filter { $0.order != nil && !$0.blank }.map {
            let r = screen.plan.rect(of: $0)
            return PlacedCard(card: .init(port: $0.port - 1, card: $0.order! - 1, width: r.width, height: r.height), x: r.x, y: r.y)
        }
    }

    private var ports: [Int] { Array(Set(cards.map(\.card.port))).sorted() }

    private var tiles: [Tile] {
        var result: [Tile] = []
        for c in cards {
            let mw = moduleWidth > 0 ? min(moduleWidth, c.card.width) : c.card.width
            let mh = moduleHeight > 0 ? min(moduleHeight, c.card.height) : c.card.height
            var y = 0
            while y < c.card.height {
                var x = 0
                let h = min(mh, c.card.height - y)
                while x < c.card.width {
                    let w = min(mw, c.card.width - x)
                    result.append(Tile(card: c.card, x: x, y: y, width: w, height: h, screenX: c.x + x, screenY: c.y + y))
                    x += mw
                }
                y += mh
            }
        }
        return result
    }

    private func label(_ card: CoefficientTable.Card) -> String {
        "P\(ControllerModels.portLabel(model: device.models[controller], index: card.port))-\(card.card + 1)"
    }

    private var factors: CoefficientTable.Factors {
        .init(red: brightness * red, green: brightness * green, blue: brightness * blue)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if calibrationOff {
                    Text("Calibration is disabled: the cards ignore their coefficients, so neither factors nor Pixel Razor show. Choose a calibration mode above.")
                        .font(.caption).foregroundStyle(.orange)
                }
                moduleRow
                layout
                factorRows
                Divider()
                razorRows
                Divider()
                actionRow
                if let progress = activity.progress { ProgressView(value: progress).frame(maxWidth: 360) }
                if !activity.status.isEmpty { Text(activity.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if let error = activity.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(6)
        } label: {
            Text("Module matching and Pixel Razor — \(screen.name)").font(.headline)
        }
        .onChange(of: store.reloads[controller]) { _, reload in
            if let reload { reloaded(reload.cards) }
        }
        .alert("No coefficient backup yet", isPresented: $askBackup) {
            Button("Back up first") { backup(then: applyFactors) }
            Button("Continue without backup", role: .destructive) { backupWaived = true; applyFactors() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Factors change the coefficients of the selected modules. Until they are saved to the cards, 1.000 brings them back; after saving only a backup can. A backup of a card takes about 4 minutes over Wi-Fi.")
        }
        .alert("Save the coefficients?", isPresented: $confirmSave) {
            Button("Cancel", role: .cancel) {}
            Button("Save") { save() }
        } message: {
            Text("Writes the coefficient tables of every card of \(screen.name) to flash, with the current factors and Pixel Razor cuts. The seam brightness is saved in Seam correction.")
        }
        .alert("Restore from backup?", isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Restore") { restore(restoreChoice) }
        } message: {
            Text("Writes the backed-up tables back into \(restoreChoice.map { label($0.card) }.joined(separator: ", ")). Not saved until you press Save to cards.")
        }
    }

    // MARK: Modules and factors

    private var moduleRow: some View {
        HStack(spacing: 12) {
            Text("Module").font(.callout)
            TextField("W", value: $moduleWidth, format: .number).frame(width: 60)
                .onSubmit { select([]) }
            Text("×")
            TextField("H", value: $moduleHeight, format: .number).frame(width: 60)
                .onSubmit { select([]) }
            Text("px (0 = whole card)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Whole cards") {
                select(Set(cards.map { Tile(card: $0.card, x: 0, y: 0, width: $0.card.width, height: $0.card.height, screenX: $0.x, screenY: $0.y) }))
            }
            Button("Deselect") { select([]) }
        }
    }

    private var meanText: String {
        let chosen = selected.compactMap { t in means[t].map { (t, $0) } }
        guard !chosen.isEmpty else { return selected.isEmpty ? "Click modules to select them." : "Reading the selection…" }
        let w = chosen.reduce(0.0) { $0 + Double($1.0.width * $1.0.height) }
        func avg(_ k: KeyPath<CoefficientTable.Mean, Double>) -> Double { chosen.reduce(0.0) { $0 + $1.1[keyPath: k] * Double($1.0.width * $1.0.height) } / w }
        let r = avg(\.red), g = avg(\.green), b = avg(\.blue)
        let f = factors
        return String(format: "Selection (%d): coefficients R %.1f %% · G %.1f %% · B %.1f %%  →  R %.1f %% · G %.1f %% · B %.1f %%",
                      selected.count, r * 100, g * 100, b * 100, r * f.red * 100, g * f.green * 100, b * f.blue * 100)
    }

    private var factorRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meanText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            factorSlider("Brightness", $brightness)
            factorSlider("Red", $red)
            factorSlider("Green", $green)
            factorSlider("Blue", $blue)
            HStack {
                Button("All 1.000") { brightness = 1; red = 1; green = 1; blue = 1; applyFactors() }
                    .disabled(selected.isEmpty)
                Text("Factors multiply the coefficients the selection had when it was chosen; 1.000 returns to them until you save. Brightness scales all three colours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(selected.isEmpty || busy)
    }

    private func factorSlider(_ title: LocalizedStringKey, _ value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.callout).frame(width: 80, alignment: .leading)
            Slider(value: value, in: 0.5...1.2, step: 0.005) { EmptyView() } onEditingChanged: { editing in
                if !editing { applyFactors() }
            }
            .frame(maxWidth: 360)
            Text(String(format: "%.3f", value.wrappedValue)).font(.callout.monospaced()).frame(width: 50)
            Stepper("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, 0.5), 1.2); applyFactors() }),
                    in: 0.5...1.2, step: 0.005).labelsHidden()
        }
    }

    // MARK: Pixel Razor

    private var razorEntries: [CoefficientStore.RazorEntry] {
        store.razor(controller: controller, cards: Set(cards.map(\.card)))
    }

    private var razorRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Pixel Razor").font(.callout.weight(.medium))
                Text("x").font(.callout)
                TextField("x", value: $razorX, format: .number).frame(width: 60)
                Text("y").font(.callout)
                TextField("y", value: $razorY, format: .number).frame(width: 60)
                Picker("", selection: $cut) {
                    ForEach(CoefficientTable.Cut.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                Button("Switch off") { razor() }.disabled(busy)
                Spacer()
                Text("Test").font(.caption).foregroundStyle(.secondary)
                ForEach([ReceiverTest.Pattern.white, .red, .green, .blue, .normal]) { p in
                    Button(p.title) { show(p) }.disabled(busy)
                }
            }
            ForEach(razorEntries) { e in
                HStack(spacing: 8) {
                    Text("x \(e.screenX), y \(e.screenY)").font(.callout.monospacedDigit())
                    Text("\(label(e.card)) \(e.x)/\(e.y) · \(e.cut.title) · \(e.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Restore") { unrazor(e) }.disabled(busy)
                }
            }
            Text("Switches off a pixel or one of its LEDs in the coefficient table (screen coordinates, top left = 0/0) — for an LED that shows a wrong colour. An LED that lights without being driven stays on. The old coefficients are kept here for Restore; Save to cards keeps the cut after a power cycle.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button("Back up coefficients") { backup(then: nil) }
                .help("Reads the coefficient table of every card of this screen into NovaMac (about 4 minutes per card over Wi-Fi)")
            Menu("Restore") {
                let groups = backupSets
                if groups.isEmpty { Text("No backups of these cards") }
                ForEach(groups.indices, id: \.self) { i in
                    Button(groups[i].title) { restoreChoice = groups[i].backups; confirmRestore = true }
                }
            }
            .frame(width: 110)
            Button("Show backups") { NSWorkspace.shared.activateFileViewerSelecting([store.folder]) }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Save to cards") { confirmSave = true }
                .help("Writes the coefficient tables of this screen's cards to their flash (about 10 s per port)")
        }
        .disabled(busy)
    }

    /// Backups of this screen's cards, grouped by ten-minute slots (one "Back up" run).
    private var backupSets: [(title: String, backups: [CoefficientStore.Backup])] {
        let mine = Set(cards.map(\.card))
        let all = store.backups.filter { $0.controller == controller && mine.contains($0.card) }
        let groups = Dictionary(grouping: all) { Int($0.date.timeIntervalSince1970 / 600) }
        return groups.keys.sorted(by: >).map { k in
            let b = groups[k]!.sorted { $0.card.port * 1000 + $0.card.card < $1.card.port * 1000 + $1.card.card }
            let date = b.map(\.date).min()!.formatted(date: .abbreviated, time: .shortened)
            return (date + " — " + b.map { label($0.card) }.joined(separator: ", "), b)
        }
    }

    private func run(_ text: String, _ work: @escaping @MainActor () async throws -> String) {
        guard !busy else { return }
        update { $0 = .init(busy: true, progress: nil, status: text, error: nil) }
        Task { @MainActor in
            do {
                let done = try await work()
                update { $0.busy = false; $0.progress = nil; $0.status = done }
            } catch {
                update { $0.busy = false; $0.progress = nil; $0.status = ""; $0.error = error.localizedDescription }
            }
        }
    }

    private func select(_ new: Set<Tile>) {
        selected = new
        means = [:]
        brightness = 1; red = 1; green = 1; blue = 1
        guard !new.isEmpty else { return }
        let endpoint = screen.endpoint
        run("Reading the selection…") {
            for (card, list) in Dictionary(grouping: Array(new), by: \.card) {
                for t in list {
                    let m = try await CoefficientTable.setBase(endpoint, card, [t.local])
                    if selected.contains(t) { means[t] = m }
                }
            }
            return ""
        }
    }

    private func tap(_ t: Tile) {
        var s = selected
        if s.contains(t) { s.remove(t) } else { s.insert(t) }
        select(s)
    }

    private func applyFactors() {
        guard !selected.isEmpty else { return }
        let byCard = Dictionary(grouping: Array(selected), by: \.card)
        if !backupWaived, byCard.keys.contains(where: { !store.hasBackup(controller: controller, card: $0) }) {
            askBackup = true
            return
        }
        let endpoint = screen.endpoint, f = factors
        run("Applying…") {
            for (card, list) in byCard {
                try await CoefficientTable.apply(endpoint, card, list.map(\.local), f)
                markUnsaved(card)
            }
            return String(format: "R %.3f · G %.3f · B %.3f on %d module(s). Not saved yet — press Save to cards.", f.red, f.green, f.blue, selected.count)
        }
    }

    private func backup(then next: (() -> Void)?) {
        let endpoint = screen.endpoint, list = cards.map(\.card), title = device.title(for: endpoint)
        guard !list.isEmpty else { return }
        run("Backing up…") {
            update { $0.progress = 0 }
            var done: [String] = []
            for (i, card) in list.enumerated() {
                update { $0.status = "Backing up \(label(card)) (\(i + 1) of \(list.count))…" }
                let table = try await CoefficientTable.readTable(endpoint, card) { p in
                    update { $0.progress = (Double(i) + p) / Double(list.count) }
                }
                _ = try store.add(table, controller: endpoint.key, title: title, card: card)
                done.append(label(card))
            }
            if let next { Task { @MainActor in next() } }
            return "Backed up " + done.joined(separator: ", ") + "."
        }
    }

    private func restore(_ backups: [CoefficientStore.Backup]) {
        let endpoint = screen.endpoint
        run("Restoring…") {
            update { $0.progress = 0 }
            for (i, b) in backups.enumerated() {
                let table = try store.table(b)
                update { $0.status = "Restoring \(label(b.card)) (\(i + 1) of \(backups.count))…" }
                try await CoefficientTable.writeTable(endpoint, b.card, table) { p in
                    update { $0.progress = (Double(i) + p) / Double(backups.count) }
                }
                // Razor entries whose pixel is back to its old bytes are done.
                for e in store.razor where e.controller == b.controller && e.card == b.card {
                    let at = b.card.offset(x: e.x, y: e.y)
                    if [UInt8](table[at..<at + CoefficientTable.pixelSize]) == e.original { store.removeRazor(e) }
                }
                markUnsaved(b.card)
            }
            select([])
            return "Restored \(backups.map { label($0.card) }.joined(separator: ", ")). Not saved yet — press Save to cards."
        }
    }

    private func save() {
        let endpoint = screen.endpoint
        let list = cards.map(\.card).sorted { ($0.port, $0.card) < ($1.port, $1.card) }
        let targets = list.map { [$0.port, $0.card] }
        run("Saving to the cards (about 10 s)…") {
            let refused = try await CalibrationCoefficients.runAll(endpoint, .saveToCard, targets: targets)
            store.cardsRan(.saveToCard, controller: endpoint.key,
                           cards: targets.enumerated().filter { refused[$0.offset] == nil }.map(\.element))
            guard refused.isEmpty else {
                let names = refused.keys.sorted().map { label(list[$0]) }
                throw NovaLinkError.failedStep("Not saved in " + names.joined(separator: ", ") + ".")
            }
            return "Coefficients saved to the receiving cards."
        }
    }

    /// The Calibration coefficients box loaded other coefficients into `list` ([port, card]): the bases of the
    /// selection are gone, and cuts that were not saved may be undone.
    private func reloaded(_ list: [[Int]]) {
        select([])
        let mine = cards.map(\.card).filter { c in list.contains { $0 == [c.port, c.card] } }
        let entries = store.razor(controller: controller, cards: Set(mine))
        guard !entries.isEmpty else { return }
        let endpoint = screen.endpoint
        run("Checking the Pixel Razor list…") {
            var gone = 0
            for (card, group) in Dictionary(grouping: entries, by: \.card) {
                let now = try await CoefficientTable.pixels(endpoint, card, group.map { [$0.x, $0.y] })
                for (e, bytes) in zip(group, now) where !CoefficientTable.isCut(bytes, e.cut) {
                    store.removeRazor(e)
                    gone += 1
                }
            }
            return gone == 0 ? "" : "\(gone) Pixel Razor cut(s) undone by the reload — removed from the list."
        }
    }

    private func placed(_ x: Int, _ y: Int) -> PlacedCard? {
        cards.first { $0.x <= x && x < $0.x + $0.card.width && $0.y <= y && y < $0.y + $0.card.height }
    }

    private func razor() {
        let x = razorX, y = razorY, what = cut
        guard let c = placed(x, y) else { update { $0.error = "No card at x \(x), y \(y) on \(screen.name)." }; return }
        let endpoint = screen.endpoint, lx = x - c.x, ly = y - c.y
        run("Switching off…") {
            let old = try await CoefficientTable.cut(endpoint, c.card, x: lx, y: ly, what)
            let original = store.original(controller: endpoint.key, card: c.card, x: lx, y: ly) ?? old
            store.addRazor(.init(controller: endpoint.key, card: c.card, x: lx, y: ly, screenX: x, screenY: y,
                                 cut: what, original: original, date: Date()))
            markUnsaved(c.card)
            return "\(what.title) of pixel x \(x), y \(y) switched off. Not saved yet — press Save to cards."
        }
    }

    private func unrazor(_ e: CoefficientStore.RazorEntry) {
        let endpoint = screen.endpoint
        run("Restoring pixel…") {
            try await CoefficientTable.restorePixel(endpoint, e.card, x: e.x, y: e.y, e.original)
            store.removeRazor(e)
            markUnsaved(e.card)
            return "Pixel x \(e.screenX), y \(e.screenY) restored. Not saved yet — press Save to cards."
        }
    }

    private func show(_ p: ReceiverTest.Pattern) {
        let endpoint = screen.endpoint, list = ports
        run("") {
            try await ReceiverTest.show(endpoint, p, ports: list.isEmpty ? nil : list)
            return p == .normal ? "" : "Test pattern \(p.title) — Normal returns to the picture."
        }
    }

    // MARK: Layout

    private var layout: some View {
        let rects = cards.map(\.rect)
        let minX = rects.map(\.x).min() ?? 0, minY = rects.map(\.y).min() ?? 0
        let maxX = rects.map(\.maxX).max() ?? 1, maxY = rects.map(\.maxY).max() ?? 1
        let w = Double(max(1, maxX - minX)), h = Double(max(1, maxY - minY))
        let scale = min(640 / w, 360 / h)
        let cuts = razorEntries
        return ZStack(alignment: .topLeading) {
            ForEach(tiles, id: \.self) { t in
                Rectangle()
                    .fill(selected.contains(t) ? Color.green.opacity(0.55) : Color.secondary.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                    .frame(width: Double(t.width) * scale, height: Double(t.height) * scale)
                    .offset(x: Double(t.screenX - minX) * scale, y: Double(t.screenY - minY) * scale)
                    .onTapGesture { if !busy { tap(t) } }
                    .help("\(label(t.card)) x \(t.x)…\(t.x + t.width - 1), y \(t.y)…\(t.y + t.height - 1)")
            }
            ForEach(cards, id: \.self) { c in
                Rectangle()
                    .stroke(isUnsaved(c.card) ? Color.orange : Color.secondary.opacity(0.8), lineWidth: isUnsaved(c.card) ? 2 : 1)
                    .overlay(Text(label(c.card)).font(.caption2).foregroundStyle(.secondary))
                    .frame(width: Double(c.card.width) * scale, height: Double(c.card.height) * scale)
                    .offset(x: Double(c.x - minX) * scale, y: Double(c.y - minY) * scale)
                    .allowsHitTesting(false)
            }
            ForEach(cuts) { e in
                Circle().fill(Color.red)
                    .frame(width: max(4, scale), height: max(4, scale))
                    .offset(x: Double(e.screenX - minX) * scale - max(4, scale) / 2 + scale / 2,
                            y: Double(e.screenY - minY) * scale - max(4, scale) / 2 + scale / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: w * scale, height: h * scale, alignment: .topLeading)
        .padding(4)
    }
}
