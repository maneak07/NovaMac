import Foundation

struct ReceivingCard: Decodable, Identifiable, Sendable {
    let cabinetID: String
    let netPortID: Int
    let cabinetIndex: Int
    let cabinetBaseInfo: Base
    let cabinetPhysicalInfo: Size
    var id: String { cabinetID }
    struct Base: Decodable, Sendable {
        let modelName: String
        let workVer: String
        let grayScale: Int
        let refreshRate: Int
        let scanNumber: Int
        let driverChip: String
        let decodeType: String
    }
    struct Size: Decodable, Sendable { let width: Int; let height: Int }
}

// Contracts from the VX1000 Pro's own Unico client. Local proxy routing was
// verified with GET info-v2 and packet/list; no credentials are logged or stored.
struct ReceivingCardAPI {
    let ip: String
    var session: URLSession = .shared
    private struct Envelope<T: Decodable>: Decodable { let code: Int; let message: String?; let data: T? }
    private struct Imported: Decodable {
        let rcfgxList: [Item]
        struct Item: Decodable { let id: Int }
    }
    func request(path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json") throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"; components.host = ip; components.port = 19999
        components.path = "/unico/v1/" + path
        guard let url = components.url, !ip.isEmpty else { throw RCFGXError.invalid("Enter the controller IP address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 300
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("127.0.0.1", forHTTPHeaderField: "Ip")
        request.setValue("8088", forHTTPHeaderField: "Port")
        request.setValue("http", forHTTPHeaderField: "Protocol")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }
    private func response(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw RCFGXError.invalid("Controller request failed.") }
        return data
    }
    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard envelope.code == 0, let value = envelope.data else { throw RCFGXError.invalid("Controller error \(envelope.code): \(envelope.message ?? "No data")") }
        return value
    }
    func cards() async throws -> [ReceivingCard] {
        try decode([ReceivingCard].self, data: await response(request(path: "cabinet/info-v2")))
    }
    // Import uploads to the device library. Only apply() changes receiving cards.
    func upload(_ file: RCFGXFile) async throws -> Int {
        let boundary = "NovaMac-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"NovaMac-\(UUID().uuidString).rcfgx\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(file.data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let data = try await response(request(path: "cabinet/ncp/import", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)"))
        let imported = try decode(Imported.self, data: data)
        guard imported.rcfgxList.count == 1, let item = imported.rcfgxList.first, item.id > 0 else { throw RCFGXError.invalid("Controller did not identify exactly one imported RCFGX.") }
        return item.id
    }
    func apply(rcfgxID: Int, cabinetIDs: [String]) async throws {
        guard rcfgxID > 0, !cabinetIDs.isEmpty else { throw RCFGXError.invalid("Select receiving cards first.") }
        let body = try JSONSerialization.data(withJSONObject: ["cabinetIds": cabinetIDs, "type": 1, "rcfgxId": rcfgxID])
        let data = try await response(request(path: "cabinet/ncp/upgrade", method: "PUT", body: body))
        struct Result: Decodable { let code: Int; let message: String? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard result.code == 0 else { throw RCFGXError.invalid("Apply failed (\(result.code)): \(result.message ?? "Unknown error")") }
    }
    struct Library: Decodable, Sendable {
        let rcfgxList: [LibraryFile]
    }
    struct LibraryFile: Decodable, Identifiable, Sendable {
        let id: Int
        let cabinetInfo: Info
        struct Info: Decodable, Sendable { let name: String }
    }
    func library() async throws -> [LibraryFile] {
        try decode(Library.self, data: await response(request(path: "cabinet/packet/list"))).rcfgxList
    }
    func exportLibraryFile(_ item: LibraryFile) async throws -> RCFGXFile {
        let body = try JSONSerialization.data(withJSONObject: ["ncp": [], "rcfgx": [item.id]])
        let data = try await response(request(path: "cabinet/ncp/export", method: "POST", body: body))
        let outer = try RCFGXArchive(data)
        guard let nested = outer.entries.first(where: { $0.name == "rcfgx.zip" }) else { throw RCFGXError.invalid("Missing RCFGX export archive.") }
        let archive = try RCFGXArchive(outer.extract(nested))
        let files = archive.entries.filter { $0.name.lowercased().hasSuffix(".rcfgx") }
        guard files.count == 1, let member = files.first else { throw RCFGXError.invalid("Expected one exported RCFGX.") }
        return try RCFGXFile(data: archive.extract(member), name: (member.name as NSString).lastPathComponent)
    }
    func readback(cardID: String) async throws -> Data {
        var request = try request(path: "cabinet/format-painter")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "cabinetId", value: cardID)]
        request.url = components.url
        let data = try await response(request)
        let archive = try RCFGXArchive(data)
        guard Set(archive.entries.map(\.name)) == Set(["bin", "firmware"]) else { throw RCFGXError.invalid("Unexpected card backup format.") }
        for member in archive.entries { _ = try archive.extract(member) }
        return data
    }

}
