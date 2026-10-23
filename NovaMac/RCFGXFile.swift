import Foundation
import zlib

struct RCFGXFile: Sendable {
    let data: Data
    let name: String
    let fields: [String: String]
    let entries: [String]

    init(data: Data, name: String) throws {
        guard data.count <= 32 * 1024 * 1024 else { throw RCFGXError.invalid("File exceeds 32 MB.") }
        let archive = try RCFGXArchive(data)
        let xmlEntries = archive.entries.filter { $0.name.lowercased().hasSuffix(".xml") }
        guard xmlEntries.count == 1, archive.entries.contains(where: { $0.name.lowercased().hasSuffix(".bin") }) else {
            throw RCFGXError.invalid("Expected one XML configuration and a BIN payload.")
        }
        // Validate every member, including the binary payload, before allowing export.
        var xml = Data()
        for entry in archive.entries {
            let content = try archive.extract(entry)
            if entry.name == xmlEntries[0].name { xml = content }
        }
        let reader = RCFGXXMLReader()
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.root == "ScanBoardProperty", !reader.forbidden else {
            throw RCFGXError.invalid("Invalid ScanBoardProperty XML.")
        }
        for key in ["Width", "Height", "StandardLedModuleProp/ModulePixelCols", "StandardLedModuleProp/ModulePixelRows"] {
            guard let value = Int(reader.values[key] ?? ""), value > 0 else { throw RCFGXError.invalid("Missing or invalid \(key).") }
        }
        self.data = data
        self.name = name
        fields = reader.values
        entries = archive.entries.map(\.name)
    }

    func value(_ path: String) -> String { fields[path].flatMap { $0.isEmpty ? nil : $0 } ?? "—" }
    var moduleSize: String { "\(value("StandardLedModuleProp/ModulePixelCols")) × \(value("StandardLedModuleProp/ModulePixelRows"))" }
    var cabinetSize: String { "\(value("Width")) × \(value("Height"))" }
}

enum RCFGXError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return "RCFGX: \(message)" }; return nil }
}

private final class RCFGXXMLReader: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    var stack: [String] = []
    var texts: [String] = []
    var root = ""
    var forbidden = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if stack.isEmpty { root = name }
        stack.append(name); texts.append("")
        if stack.count > 100 { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !texts.isEmpty { texts[texts.count - 1] += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let text = texts.removeLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let key = stack.dropFirst().joined(separator: "/")
        if !text.isEmpty, values[key] == nil { values[key] = text }
        stack.removeLast()
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { forbidden = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { forbidden = true; parser.abortParsing() }
}

struct RCFGXArchive {
    struct Entry { let name: String; let method: Int; let crc: UInt32; let packed: Int; let size: Int; let offset: Int }
    let data: Data
    let entries: [Entry]
    init(_ data: Data) throws {
        self.data = data
        func fail() -> RCFGXError { .invalid("Unsupported or damaged ZIP archive.") }
        func uint(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= data.count else { throw fail() }
            return (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
        }
        guard data.count >= 22 else { throw fail() }
        var endOffset: Int?
        for candidate in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try uint(candidate, 4) == 0x06054b50 {
                let commentLength = try uint(candidate + 20, 2)
                if candidate + 22 + commentLength == data.count { endOffset = candidate; break }
            }
        }
        guard let end = endOffset else { throw fail() }
        guard try uint(end + 4, 2) == 0, try uint(end + 6, 2) == 0 else { throw fail() }
        let count = try uint(end + 10, 2)
        guard count > 0, count <= 128, try uint(end + 8, 2) == count else { throw fail() }
        let directorySize = try uint(end + 12, 4)
        var cursor = try uint(end + 16, 4)
        guard cursor + directorySize == end else { throw fail() }
        var found: [Entry] = []; var total = 0
        for _ in 0..<count {
            guard try uint(cursor, 4) == 0x02014b50, try uint(cursor + 8, 2) & 1 == 0 else { throw fail() }
            let method = try uint(cursor + 10, 2)
            let packed = try uint(cursor + 20, 4), size = try uint(cursor + 24, 4)
            let length = try uint(cursor + 28, 2), extra = try uint(cursor + 30, 2), comment = try uint(cursor + 32, 2)
            guard [0, 8].contains(method), size <= 32 * 1024 * 1024, cursor + 46 + length + extra + comment <= end else { throw fail() }
            guard let name = String(data: data.subdata(in: cursor+46..<cursor+46+length), encoding: .utf8), !found.contains(where: { $0.name == name }) else { throw fail() }
            total += size
            guard total <= 64 * 1024 * 1024 else { throw fail() }
            found.append(Entry(name: name, method: method, crc: UInt32(try uint(cursor + 16, 4)), packed: packed, size: size, offset: try uint(cursor + 42, 4)))
            cursor += 46 + length + extra + comment
        }
        guard cursor == end else { throw fail() }
        entries = found
    }
    func extract(_ entry: Entry) throws -> Data {
        func uint(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= data.count else { throw RCFGXError.invalid("Truncated ZIP member.") }
            return (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
        }
        let offset = entry.offset
        guard try uint(offset, 4) == 0x04034b50, try uint(offset + 8, 2) == entry.method else { throw RCFGXError.invalid("Invalid ZIP member header.") }
        let start = try offset + 30 + uint(offset + 26, 2) + uint(offset + 28, 2)
        guard start + entry.packed <= data.count else { throw RCFGXError.invalid("Truncated ZIP member.") }
        let packed = data.subdata(in: start..<start+entry.packed)
        let output: Data
        if entry.method == 0 { output = packed }
        else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw RCFGXError.invalid("Cannot initialize decompressor.") }
            defer { inflateEnd(&stream) }
            var bytes = [UInt8](repeating: 0, count: max(1, entry.size))
            let status = packed.withUnsafeBytes { source in
                bytes.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(packed.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size, stream.total_in == entry.packed else { throw RCFGXError.invalid("Damaged compressed member.") }
            output = Data(bytes.prefix(entry.size))
        }
        let crc = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)) }
        guard output.count == entry.size, UInt32(crc) == entry.crc else { throw RCFGXError.invalid("ZIP checksum mismatch.") }
        return output
    }
}
