import Foundation

// NovaMac — Screen Connection over the controller's own REST API (Unico platform: VX Pro, COEX).
// Captured from the VX1000 Pro web UI (20.10.2026):
//   POST /unico/v1/system/auth/login        {"username":…, "password": base64(password)} → data.token
//   POST /unico/v1/screen/cabinets/topology [{cabinetID, guid, canvasId, cabinetPosition{x,y}, cabinetSize{width,height}}]
//        headers: ip/port/protocol (proxy), Authorization: <token>, Source: <client uuid>, seq, ClientType: 0
// The controller stores this layout itself — verified with a power cycle. No NovaLCT/NSSD file involved.
//
// cabinetID = (last 3 bytes of the controller MAC) << 32 | slot << 24 | portIndex << 16 | cardIndex,
// e.g. 0x25C055_01_09_0000 = MAC …25:C0:55, slot 1, port 10, first card in the chain.

// MARK: - Stored secrets (controller passwords, Agent API token)
// Kept in NovaMac's own preferences (UserDefaults, inside the app's sandbox container), not in the macOS
// Keychain: the Keychain asked for the login password at every launch of a newly built, unsigned app.
// The values are local to this Mac and this app; the VX factory password needs no storage at all.

enum NovaKeychain {
    private static let key = "NovaMac.secrets"

    private static var all: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func password(for account: String) -> String? { all[account] }

    static func save(_ password: String, for account: String) { all[account] = password }

    static func delete(for account: String) { all[account] = nil }
}

// MARK: - Session

/// One logged-in session per controller IP (token + client id), shared by the app.
final class UnicoSession {
    static var sessions: [String: UnicoSession] = [:]
    static func shared(ip: String) -> UnicoSession {
        if let s = sessions[ip] { return s }
        let s = UnicoSession(ip: ip); sessions[ip] = s; return s
    }

    let ip: String
    let source = UUID().uuidString.lowercased()
    private(set) var token: String?
    var username = UserDefaults.standard.string(forKey: "NovaMac.username") ?? "admin"
    private var seq = 0

    init(ip: String) { self.ip = ip }

    var account: String { "\(username)@\(ip)" }
    var hasStoredPassword: Bool { NovaKeychain.password(for: account) != nil }
    var isLoggedIn: Bool { token != nil }

    enum Failure: LocalizedError {
        case needsPassword, rejected(Int, String), badResponse
        var errorDescription: String? {
            switch self {
            case .needsPassword: return "Controller login required."
            case .rejected(let code, let message): return "Controller refused (\(code)): \(message)"
            case .badResponse: return "Unexpected controller response."
            }
        }
    }

    private func request(_ path: String, method: String, body: Data?, authorized: Bool) throws -> URLRequest {
        var c = URLComponents(); c.scheme = "http"; c.host = ip; c.port = 19999; c.path = "/unico/v1/" + path
        guard let url = c.url else { throw UnicoAPIError.invalidURL }
        var r = URLRequest(url: url)
        r.httpMethod = method; r.httpBody = body; r.timeoutInterval = 8
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("0", forHTTPHeaderField: "ClientType")
        r.setValue(ip, forHTTPHeaderField: "ip")
        r.setValue("8088", forHTTPHeaderField: "port")
        r.setValue("http", forHTTPHeaderField: "protocol")
        r.setValue(source, forHTTPHeaderField: "Source")
        r.setValue(String(seq), forHTTPHeaderField: "seq"); seq += 1
        r.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Requestid")
        if authorized, let token { r.setValue(token, forHTTPHeaderField: "Authorization") }
        return r
    }

    private struct Envelope: Decodable {
        let code: Int
        let message: String?
        struct TokenData: Decodable { let token: String? }
        let data: TokenData?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(Int.self, forKey: .code)
            message = try? c.decode(String.self, forKey: .message)
            data = try? c.decode(TokenData.self, forKey: .data)   // data may be {}, a string or null
        }
        enum CodingKeys: String, CodingKey { case code, message, data }
    }

    /// NovaStar's factory password of the "admin" account (VX Pro web interface, seen in the web UI's login request).
    static let factoryPassword = "123456"

    /// Logs in with the given password, else the stored one, else the factory default
    /// (admin / 123456). Only when the default is refused does the user get asked.
    func login(password: String? = nil, remember: Bool = false) async throws {
        let given = password ?? NovaKeychain.password(for: account)
        let usingDefault = given == nil
        guard let pw = given ?? (username == "admin" ? Self.factoryPassword : nil) else { throw Failure.needsPassword }
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": Data(pw.utf8).base64EncodedString()])
        let (data, _) = try await URLSession.shared.data(for: request("system/auth/login", method: "POST", body: body, authorized: false))
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard env.code == 0, let t = env.data?.token, !t.isEmpty else {
            if usingDefault { throw Failure.needsPassword }       // the factory password was changed: ask
            throw Failure.rejected(env.code, env.message ?? "login failed")
        }
        token = t
        UserDefaults.standard.set(username, forKey: "NovaMac.username")
        if !usingDefault && (remember || password == nil) { NovaKeychain.save(pw, for: account) }
    }

    func logout(forget: Bool) {
        token = nil
        if forget { NovaKeychain.delete(for: account) }
    }

    /// GET with query parameters. Reading works without a login on VX1000 Pro (the web UI reads before it logs in);
    /// the token is sent when there is one. Returns the whole JSON envelope.
    func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        var r = try request(path, method: "GET", body: nil, authorized: true)
        if !query.isEmpty, let url = r.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            r.url = c.url
        }
        r.setValue(nil, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.badResponse }
        let code = json["code"] as? Int ?? -1
        guard code == 0 else { throw Failure.rejected(code, json["message"] as? String ?? path) }
        return json
    }

    /// Sends an authorized JSON request; logs in (or re-logs in once on a token error) as needed.
    @discardableResult
    func send(_ path: String, method: String = "POST", json: Any) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        if token == nil { try await login() }
        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: request(path, method: method, body: body, authorized: true))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            if env.code == 0 { return data }
            if env.code == 8273 && attempt == 0 { token = nil; try await login(); continue }   // token expired
            throw Failure.rejected(env.code, env.message ?? "failed")
        }
        throw Failure.badResponse
    }
}

// MARK: - Topology send (saved by the controller)

enum UnicoTopologyWriter {
    private struct Canvas: Decodable { let canvasID: Int }
    private struct CanvasList: Decodable { let canvasList: [Canvas] }
    private struct Env<T: Decodable>: Decodable { let code: Int; let data: T? }

    private static func get<T: Decodable>(_ type: T.Type, ip: String, path: String) async throws -> T {
        var c = URLComponents(); c.scheme = "http"; c.host = ip; c.port = 19999; c.path = "/unico/v1/" + path
        guard let url = c.url else { throw UnicoAPIError.invalidURL }
        var r = URLRequest(url: url); r.timeoutInterval = 6
        r.setValue("127.0.0.1", forHTTPHeaderField: "ip"); r.setValue("8088", forHTTPHeaderField: "port"); r.setValue("http", forHTTPHeaderField: "protocol")
        r.setValue("0", forHTTPHeaderField: "ClientType")
        let (data, _) = try await URLSession.shared.data(for: r)
        let env = try JSONDecoder().decode(Env<T>.self, from: data)
        guard env.code == 0, let value = env.data else { throw UnicoAPIError.api(env.code, path) }
        return value
    }

    /// Builds the topology body from the layout and posts it. The controller applies and stores it.
    static func send(ip: String, layout: ScreenConnectionWriter.Layout, screenGuid: String) async throws -> String {
        let session = UnicoSession.shared(ip: ip)
        let ports = try await UnicoTopology.netports(ip: ip)
        // 0-based port index → controller's netport ID, for every port the layout uses.
        var netportID: [Int: Int] = [:]
        for p in layout.ports {
            guard let netport = ports.first(where: { $0.netportIndex == p }) else {
                throw RCFGXError.invalid("Port \(p + 1) is not reported by the controller.")
            }
            netportID[p] = netport.netportID
        }
        // Card IDs: online cards (same request ReceivingCardAPI uses) + IDs already in the controller's layout.
        let online = (try? await ReceivingCardAPI(ip: ip).cards()) ?? []
        let inLayout = (try? await UnicoTopology.readFromHardware(ip: ip))?.cabinets ?? []
        let canvasID = (try? await get(CanvasList.self, ip: ip, path: "screen/canvas-all"))?.canvasList.first?.canvasID ?? 10000

        // Physical card = (netport, index in chain). Known IDs first; the rest by the ID formula.
        var byKey: [String: String] = [:]
        for c in inLayout { byKey["\(c.netPortID)/\(c.index)"] = c.cabinetID }
        for c in online { byKey["\(c.netPortID)/\(c.cabinetIndex)"] = c.cabinetID }
        let anyID = (online.map(\.cabinetID) + inLayout.map(\.cabinetID)).compactMap { UInt64($0) }.first
        guard let anyID else {
            throw RCFGXError.invalid("The controller reports no receiving cards (online or in its layout), so card IDs cannot be built.")
        }
        let onlineKeys = Set(online.map { "\($0.netPortID)/\($0.cabinetIndex)" })
        let prefix = anyID & 0xFFFF_FFFF_FF00_0000      // MAC bytes + slot
        func key(_ card: ScreenConnectionWriter.Card) -> String { "\(netportID[card.port] ?? -1)/\(card.chainIndex)" }
        func cabinetID(_ card: ScreenConnectionWriter.Card) -> String {
            byKey[key(card)] ?? String(prefix | UInt64(card.port) << 16 | UInt64(card.chainIndex))
        }
        let body: [[String: Any]] = layout.cards.map { card in
            ["cabinetID": cabinetID(card), "guid": screenGuid, "canvasId": canvasID,
             "cabinetPosition": ["x": card.x, "y": card.y],
             "cabinetSize": ["width": card.width, "height": card.height]]
        }
        try await session.send("screen/cabinets/topology", json: body)

        // Read back through the controller's model.
        let want = Dictionary(layout.cards.map { (key($0), [$0.x, $0.y]) }, uniquingKeysWith: { a, _ in a })
        let usedNetports = Set(netportID.values)
        let portText = layout.ports.count == 1 ? "port \(layout.ports[0] + 1)" : "\(layout.ports.count) ports"
        try await Task.sleep(nanoseconds: 1_200_000_000)
        if let read = try? await UnicoTopology.readFromHardware(ip: ip) {
            let got = Dictionary(read.cabinets.filter { usedNetports.contains($0.netPortID) }
                                    .map { ("\($0.netPortID)/\($0.index)", [$0.cabinetPosition.x, $0.cabinetPosition.y]) },
                                 uniquingKeysWith: { a, _ in a })
            let missing = layout.cards.filter { !onlineKeys.contains(key($0)) }.count
            let note = missing == 0 ? "" : " \(missing) card(s) are not online — saved in the layout, they light up when connected."
            if got == want { return "Sent and saved by the controller (REST): \(layout.cards.count) cards on \(portText), read-back matches.\(note)" }
            let differ = want.keys.filter { got[$0] != want[$0] }.count
            return "Sent (REST, code 0), but \(differ) card(s) read back at a different position. Check the LED screen."
        }
        return "Sent and saved by the controller (REST). Read-back unavailable."
    }
}
