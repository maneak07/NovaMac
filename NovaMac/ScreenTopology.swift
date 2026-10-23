import Foundation

// NovaMac — Screen Connection: READ from hardware.
// Source: GET /unico/v1/ucenter/screen/topology (same call the VX1000 Pro web UI makes).
// Verified against NovaLCT on the test screen: `index` is the zero-based position of the
// receiving card in the cable chain of its Ethernet port (index 0 = first card after the port).
// This file performs GET requests only. Nothing is written to the controller.

enum UnicoTopology {
    struct Envelope<T: Decodable>: Decodable {
        let code: Int
        let message: String?
        let data: T?
    }

    struct TopologyData: Decodable { let screenList: [Screen]? }

    struct Screen: Decodable, Sendable {
        let guid: String?
        let screenId: Int?
        let canvasInfoList: [Canvas]?
        var cabinets: [Cabinet] { (canvasInfoList ?? []).flatMap { $0.topologyList ?? [] } }
    }

    struct Canvas: Decodable, Sendable {
        let canvasID: Int?
        let topologyList: [Cabinet]?
    }

    struct Cabinet: Decodable, Sendable {
        struct Point: Decodable, Sendable { let x: Int; let y: Int }
        struct Size: Decodable, Sendable { let width: Int; let height: Int }
        let cabinetID: String
        let cabinetPosition: Point
        let cabinetSize: Size
        let netPortID: Int
        let index: Int
        let isOnline: Int?
        let angle: Int?
    }

    struct NetportList: Decodable { let list: [Netport]? }
    struct Netport: Decodable, Sendable {
        let netportID: Int
        let netportIndex: Int
        let linkState: Int?     // 1 = Ethernet link up (cable to a receiving card)
    }

    /// 1-based Ethernet port numbers whose link is up.
    static func activePorts(ip: String) async throws -> Set<Int> {
        Set(try await netports(ip: ip).filter { $0.linkState == 1 }.map { $0.netportIndex + 1 })
    }

    /// Result of a hardware read: the editable plan plus the raw data needed later for writing.
    struct Snapshot: Sendable {
        var name = ""
        let screenGuid: String
        let screenId: Int
        let cabinets: [Cabinet]
        let plan: ScreenConnectionPlan
    }

    // MARK: Requests

    private static func request(ip: String, path: String, query: String? = nil) throws -> URLRequest {
        let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { throw UnicoAPIError.invalidIP }
        var components = URLComponents()
        components.scheme = "http"
        components.host = ip
        components.port = 19999
        components.path = "/unico/v1/" + path
        if let query { components.percentEncodedQuery = query }
        guard let url = components.url else { throw UnicoAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("0", forHTTPHeaderField: "ClientType")
        // node/* calls are proxied by the controller to its internal service; it needs these
        // headers (same values as ReceivingCardAPI, verified there). Harmless for ucenter/* calls.
        request.setValue("127.0.0.1", forHTTPHeaderField: "Ip")
        request.setValue("8088", forHTTPHeaderField: "Port")
        request.setValue("http", forHTTPHeaderField: "Protocol")
        return request
    }

    private static func get<T: Decodable>(_ type: T.Type, ip: String, path: String, query: String? = nil) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request(ip: ip, path: path, query: query))
        guard let http = response as? HTTPURLResponse else { throw UnicoAPIError.unexpectedHTTPStatus(-1) }
        guard http.statusCode == 200 else { throw UnicoAPIError.unexpectedHTTPStatus(http.statusCode) }
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            let head = String(decoding: data.prefix(400), as: UTF8.self)
            throw RCFGXError.invalid("Cannot decode \(path): \(describe(error)). Response starts: \(head)")
        }
        guard envelope.code == 0, let value = envelope.data else {
            throw UnicoAPIError.api(envelope.code, "\(path): \(envelope.message ?? "no data")")
        }
        return value
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func at(_ c: DecodingError.Context) -> String { c.codingPath.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, let c): return "missing \(at(c)).\(key.stringValue)"
        case .typeMismatch(let t, let c): return "\(at(c)) is not \(t)"
        case .valueNotFound(let t, let c): return "\(at(c)) is null (expected \(t))"
        case .dataCorrupted(let c): return "corrupted at \(at(c)): \(c.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    static func topology(ip: String, guid: String) async throws -> [Screen] {
        let encoded = guid.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? guid
        return try await get(TopologyData.self, ip: ip, path: "ucenter/screen/topology",
                             query: "guidList%5B%5D=\(encoded)").screenList ?? []
    }

    static func netports(ip: String) async throws -> [Netport] {
        try await get(NetportList.self, ip: ip, path: "node/sender-netport").list ?? []
    }

    /// Every LED screen of the controller that has receiving cards mapped (MVR left out), in the controller's order.
    static func readAllScreens(ip: String) async throws -> [Snapshot] {
        let screens = try await UnicoAPI.fetchScreens(ip: ip)
        let ledScreens = screens.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "MVR" }
        let ports = try await netports(ip: ip)
        let portIndex = Dictionary(ports.map { ($0.netportID, $0.netportIndex) }, uniquingKeysWith: { a, _ in a })
        var result: [Snapshot] = []
        for screen in ledScreens {
            guard let topologies = try? await topology(ip: ip, guid: screen.guid) else { continue }
            for topo in topologies where !topo.cabinets.isEmpty {
                guard let plan = try? makePlan(topo.cabinets, portIndex: portIndex) else { continue }
                var snapshot = Snapshot(screenGuid: topo.guid ?? screen.guid, screenId: topo.screenId ?? 0, cabinets: topo.cabinets, plan: plan)
                snapshot.name = screen.displayName
                result.append(snapshot)
            }
        }
        return result
    }

    /// Reads one screen by GUID (nil = the first screen that has cabinets).
    static func readFromHardware(ip: String, guid: String?) async throws -> Snapshot {
        guard let guid else { return try await readFromHardware(ip: ip) }
        let all = try await readAllScreens(ip: ip)
        guard let match = all.first(where: { $0.screenGuid == guid }) else {
            throw RCFGXError.invalid("The controller has no cards mapped on this screen any more.")
        }
        return match
    }

    /// Reads every screen the controller reports and returns the first one that has cabinets.
    static func readFromHardware(ip: String) async throws -> Snapshot {
        let screens: [UnicoScreen]
        do { screens = try await UnicoAPI.fetchScreens(ip: ip) }
        catch { throw RCFGXError.invalid("ucenter/screen/normal-screen: \(describe(error))") }
        // The MVR (multiviewer monitoring output) is not an LED screen; leave it out entirely.
        let ledScreens = screens.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "MVR" }
        guard !ledScreens.isEmpty else { throw RCFGXError.invalid("The controller returned no LED screens (only MVR).") }
        let ports = try await netports(ip: ip)
        let portIndex = Dictionary(ports.map { ($0.netportID, $0.netportIndex) }, uniquingKeysWith: { a, _ in a })
        var problems: [String] = []
        for screen in ledScreens {
            do {
                for topo in try await topology(ip: ip, guid: screen.guid) where !topo.cabinets.isEmpty {
                    let plan = try makePlan(topo.cabinets, portIndex: portIndex)
                    return Snapshot(screenGuid: topo.guid ?? screen.guid, screenId: topo.screenId ?? 0,
                                    cabinets: topo.cabinets, plan: plan)
                }
            } catch {
                problems.append("\(screen.displayName): \(error.localizedDescription)")
            }
        }
        throw RCFGXError.invalid(problems.isEmpty ? "No receiving cards are mapped on any screen." : problems.joined(separator: " | "))
    }

    // MARK: Conversion to the editor's grid

    /// The web API can keep cabinets of an older layout that lie exactly under the current ones (seen on the
    /// VX1000 Pro after NovaLCT changed 4 × 1 to 2 × 1: cards 3 and 4 stayed, offline, at the positions of
    /// cards 1 and 2). A real screen has no overlapping cabinets, so of two that overlap the one that is
    /// online — or else the one earlier in the chain — is kept.
    static func withoutStale(_ cabinets: [Cabinet]) -> [Cabinet] {
        let ranked = cabinets.sorted { a, b in
            let ao = (a.isOnline ?? 1) == 0, bo = (b.isOnline ?? 1) == 0
            return ao != bo ? !ao : a.index < b.index
        }
        var kept: [Cabinet] = []
        for cab in ranked {
            let overlaps = kept.contains { k in
                k.cabinetPosition.x < cab.cabinetPosition.x + cab.cabinetSize.width && cab.cabinetPosition.x < k.cabinetPosition.x + k.cabinetSize.width &&
                k.cabinetPosition.y < cab.cabinetPosition.y + cab.cabinetSize.height && cab.cabinetPosition.y < k.cabinetPosition.y + k.cabinetSize.height
            }
            if !overlaps { kept.append(cab) }
        }
        return kept
    }

    static func makePlan(_ all: [Cabinet], portIndex: [Int: Int]) throws -> ScreenConnectionPlan {
        let cabinets = withoutStale(all)
        guard !cabinets.isEmpty, cabinets.count <= 1024 else { throw RCFGXError.invalid("Unsupported number of cards (\(cabinets.count)).") }
        guard cabinets.allSatisfy({ ($0.angle ?? 0) == 0 }) else {
            throw RCFGXError.invalid("Rotated cabinets are not supported yet.")
        }
        let xs = Array(Set(cabinets.map(\.cabinetPosition.x))).sorted()
        let ys = Array(Set(cabinets.map(\.cabinetPosition.y))).sorted()
        // Rows × columns when the cards form a full grid; otherwise one logical row, positions kept as read.
        let regular = (1...64).contains(xs.count) && (1...64).contains(ys.count) && xs.count * ys.count == cabinets.count
        let ordered = cabinets.sorted { ($0.cabinetPosition.y, $0.cabinetPosition.x) < ($1.cabinetPosition.y, $1.cabinetPosition.x) }
        var plan = ScreenConnectionPlan()
        plan.columns = regular ? xs.count : cabinets.count
        plan.rows = regular ? ys.count : 1
        guard plan.columns <= 64 || !regular else { throw RCFGXError.invalid("Too many columns.") }
        for (n, cab) in ordered.enumerated() {
            guard let port = portIndex[cab.netPortID] else {
                throw RCFGXError.invalid("Unknown Ethernet port ID \(cab.netPortID).")
            }
            let id = regular ? ys.firstIndex(of: cab.cabinetPosition.y)! * xs.count + xs.firstIndex(of: cab.cabinetPosition.x)! : n
            var cell = ScreenConnectionPlan.Cell(id: id, width: cab.cabinetSize.width, height: cab.cabinetSize.height,
                                                 sender: 1, port: port + 1, order: cab.index + 1)
            cell.cabinetID = cab.cabinetID
            cell.netPortID = cab.netPortID
            cell.x = cab.cabinetPosition.x       // exact hardware coordinates
            cell.y = cab.cabinetPosition.y
            if (cab.isOnline ?? 1) == 0 { cell.offline = true }
            plan.cells.append(cell)
        }
        plan.cells.sort { $0.id < $1.id }
        if plan.columns > 64 {
            // validate() caps the logical grid at 64 columns; wrap the logical row (positions stay explicit).
            plan.columns = 64
            plan.rows = (plan.cells.count + 63) / 64
            guard plan.cells.count == plan.columns * plan.rows else {
                throw RCFGXError.invalid("Irregular layout with \(plan.cells.count) cards cannot be shown yet.")
            }
        }
        try plan.validate()
        return plan
    }
}
