import Foundation
import Combine

/// Coefficient backups and the pixels switched off with Pixel Razor, kept in NovaMac's container:
/// ~/Library/Containers/<app>/Data/Library/Application Support/NovaMac/Coefficients
///   index.json            backups (one table per card) and razor entries with each pixel's old bytes
///   <uuid>.bin            raw table of one card, CoefficientTable layout
@MainActor
final class CoefficientStore: ObservableObject {
    static let shared = CoefficientStore()

    struct Backup: Codable, Identifiable, Hashable {
        var id = UUID()
        let controller: String        // NovaEndpoint.key
        let controllerTitle: String
        let card: CoefficientTable.Card
        let date: Date
        let sha256: String
        var file: String { id.uuidString + ".bin" }
    }

    struct RazorEntry: Codable, Identifiable, Hashable {
        var id = UUID()
        let controller: String
        let card: CoefficientTable.Card
        let x: Int, y: Int            // inside the card
        let screenX: Int, screenY: Int
        let cut: CoefficientTable.Cut
        let original: [UInt8]         // the pixel's 32 bytes before the cut
        let date: Date
    }

    private struct Index: Codable {
        var backups: [Backup] = []
        var razor: [RazorEntry] = []
    }

    /// What a Coefficients box is doing for one controller. Kept here, not in the view: switching pages rebuilds
    /// the box, while its running task (a backup or restore of several minutes) goes on.
    struct Activity: Equatable {
        var busy = false
        var progress: Double?
        var status = ""
        var error: String?
    }

    @Published var activity: [String: Activity] = [:]
    /// Cards changed since they last stored their coefficients, as "controller|port|card".
    @Published var unsaved: Set<String> = []

    static func key(_ controller: String, _ card: CoefficientTable.Card) -> String { key(controller, port: card.port, card: card.card) }
    static func key(_ controller: String, port: Int, card: Int) -> String { "\(controller)|\(port)|\(card)" }

    /// Cards that loaded other working coefficients from outside the module matching box (Calibration coefficients:
    /// Read from receiving cards / modules), per controller. The box drops the bases it read before.
    struct Reload: Equatable {
        var generation = 0
        var cards: [[Int]] = []       // [port, card], 0-based
    }
    @Published private(set) var reloads: [String: Reload] = [:]

    /// Called by the Calibration coefficients box after `cards` ([port, card]) ran `operation`.
    func cardsRan(_ operation: CalibrationCoefficients.Operation, controller: String, cards: [[Int]]) {
        guard !cards.isEmpty else { return }
        let keys = cards.map { Self.key(controller, port: $0[0], card: $0[1]) }
        switch operation {
        case .saveToCard:
            unsaved.subtract(keys)
            return
        case .readFromCard:
            unsaved.subtract(keys)            // working memory = what the cards store
        case .readFromModules:
            unsaved.formUnion(keys)           // the modules' coefficients are not stored in the cards yet
        }
        let generation = (reloads[controller]?.generation ?? 0) + 1
        reloads[controller] = Reload(generation: generation, cards: cards)
    }

    @Published private(set) var backups: [Backup] = []
    @Published private(set) var razor: [RazorEntry] = []

    let folder: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("NovaMac/Coefficients", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder.iso.decode(Index.self, from: data) {
            backups = index.backups
            razor = index.razor
        }
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    private func persist() {
        let index = Index(backups: backups, razor: razor)
        if let data = try? JSONEncoder.iso.encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }

    // MARK: Backups

    func backups(controller: String, card: CoefficientTable.Card) -> [Backup] {
        backups.filter { $0.controller == controller && $0.card == card }.sorted { $0.date > $1.date }
    }

    func hasBackup(controller: String, card: CoefficientTable.Card) -> Bool {
        !backups(controller: controller, card: card).isEmpty
    }

    func add(_ table: Data, controller: String, title: String, card: CoefficientTable.Card) throws -> Backup {
        let backup = Backup(controller: controller, controllerTitle: title, card: card, date: Date(), sha256: table.sha256Hex)
        try table.write(to: folder.appendingPathComponent(backup.file), options: .atomic)
        backups.append(backup)
        persist()
        return backup
    }

    func table(_ backup: Backup) throws -> Data {
        let data = try Data(contentsOf: folder.appendingPathComponent(backup.file))
        guard data.count == backup.card.tableBytes, data.sha256Hex == backup.sha256 else {
            throw NovaLinkError.failedStep("Backup file \(backup.file) is damaged (size or checksum).")
        }
        return data
    }

    func url(_ backup: Backup) -> URL { folder.appendingPathComponent(backup.file) }

    // MARK: Pixel Razor

    func razor(controller: String, cards: Set<CoefficientTable.Card>) -> [RazorEntry] {
        razor.filter { $0.controller == controller && cards.contains($0.card) }.sorted { ($0.screenY, $0.screenX) < ($1.screenY, $1.screenX) }
    }

    /// The bytes from before the first cut of this pixel (a second cut keeps them, so undo returns to the original).
    func original(controller: String, card: CoefficientTable.Card, x: Int, y: Int) -> [UInt8]? {
        razor.first { $0.controller == controller && $0.card == card && $0.x == x && $0.y == y }?.original
    }

    func addRazor(_ entry: RazorEntry) {
        razor.removeAll { $0.controller == entry.controller && $0.card == entry.card && $0.x == entry.x && $0.y == entry.y }
        razor.append(entry)
        persist()
    }

    func removeRazor(_ entry: RazorEntry) {
        razor.removeAll { $0.id == entry.id }
        persist()
    }
}

import CryptoKit

extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
