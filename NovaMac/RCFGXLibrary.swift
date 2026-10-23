import Foundation

/// NovaMac's own copy of every RCFGX file opened on the Receiving Cards page (the app is sandboxed, so agents
/// cannot hand it arbitrary paths): ~/Library/Containers/<app>/Data/Library/Application Support/NovaMac/RCFGX.
enum RCFGXLibrary {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("NovaMac/RCFGX", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func safeName(_ name: String) -> String {
        var n = (name as NSString).lastPathComponent
        if !n.lowercased().hasSuffix(".rcfgx") { n += ".rcfgx" }
        return n.replacingOccurrences(of: ":", with: "-")
    }

    static func save(_ data: Data, name: String) {
        try? data.write(to: folder.appendingPathComponent(safeName(name)), options: .atomic)
    }

    static func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".rcfgx") }.sorted()
    }

    static func data(_ name: String) throws -> Data {
        let url = folder.appendingPathComponent(safeName(name))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RCFGXError.invalid("No RCFGX \"\(name)\" in NovaMac's library. Open it once on the Receiving Cards page.")
        }
        return try Data(contentsOf: url)
    }

    /// A card read back into `template`'s records (same cabinet type), stored in the library as `name`.
    static func readCard(_ endpoint: NovaEndpoint, port: Int, card: Int, template: String, name: String) async throws -> (name: String, kept: [UInt32]) {
        let archive = try RCFGXArchive(try data(template))
        guard let binEntry = archive.entries.first(where: { $0.name.lowercased().hasSuffix(".bin") }),
              let xmlEntry = archive.entries.first(where: { $0.name.lowercased().hasSuffix(".xml") }) else {
            throw RCFGXError.invalid("\(template) has no .bin/.xml.")
        }
        let bin = [UInt8](try archive.extract(binEntry))
        let xml = String(decoding: try archive.extract(xmlEntry), as: UTF8.self)
        let result = try await RCFGXBin.readBack(endpoint, template: bin, port: port, card: card) { _, _ in }
        let records = try RCFGXBin.records(result.bin)
        var values: [String: String] = [:]
        if let w = RCFGXEdit.byte(records, 0x17), let w2 = RCFGXEdit.byte(records, 0x18), w + w2 * 256 > 0 { values["Width"] = String(w + w2 * 256) }
        if let h = RCFGXEdit.byte(records, 0x19), let h2 = RCFGXEdit.byte(records, 0x1A), h + h2 * 256 > 0 { values["Height"] = String(h + h2 * 256) }
        let file = RCFGXEdit.zip([(xmlEntry.name, Array(RCFGXEdit.updateXML(xml, values).utf8)), (binEntry.name, result.bin)])
        _ = try RCFGXFile(data: file, name: name)        // same validation as opening a file
        let stored = safeName(name)
        try file.write(to: folder.appendingPathComponent(stored), options: .atomic)
        return (stored, result.kept)
    }

    /// The register records of a stored file (same parsing as the Receiving Cards page).
    static func records(_ name: String) throws -> [RCFGXRecord] {
        let url = folder.appendingPathComponent(safeName(name))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RCFGXError.invalid("No RCFGX \"\(name)\" in NovaMac's library. Open it once on the Receiving Cards page.")
        }
        let archive = try RCFGXArchive(try Data(contentsOf: url))
        guard let entry = archive.entries.first(where: { $0.name.lowercased().hasSuffix(".bin") }) else {
            throw RCFGXError.invalid("No .bin payload in \(name).")
        }
        return try RCFGXBin.records([UInt8](try archive.extract(entry)))
    }
}
