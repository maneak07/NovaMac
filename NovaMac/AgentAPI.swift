import SwiftUI
import Network
import Combine
import Security

// NovaMac — local API for AI agents (and scripts).
//
// HTTP + JSON on 127.0.0.1 only (default port 7801), every request needs
//   Authorization: Bearer <token>        (token shown on the Agent API page, kept in NovaMac's preferences)
// Read requests only read registers. Requests that change the LED screen (brightness, gamma, colour,
// calibration, mapping) are refused with 403 until "Allow changes" is switched on in the app.
// Nothing here writes flash (no Save, no Send to HW) — those stay manual for now.
//
// Discovery: GET /v1 lists every endpoint with its parameters. See AGENT-API.md and nova_mcp.py
// (an MCP server that exposes this API as tools to Claude Desktop / other MCP clients).

// MARK: - Minimal HTTP server (Network.framework)

nonisolated struct AgentHTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]     // lower-cased names
    let body: Data
}

nonisolated struct AgentHTTPResponse: Sendable {
    var status: Int
    var body: Data

    static func json(_ status: Int, _ object: [String: Any]) -> AgentHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return AgentHTTPResponse(status: status, body: data)
    }
    static func error(_ status: Int, _ message: String) -> AgentHTTPResponse { json(status, ["error": message]) }
}

nonisolated final class AgentHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (AgentHTTPRequest) async -> AgentHTTPResponse
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "NovaMac.AgentAPI")
    private let handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    func start(port: UInt16, stateChanged: @escaping @Sendable (String?) -> Void) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: stateChanged(nil)
            case .failed(let error): stateChanged(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() { listener?.cancel(); listener = nil }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 4_000_000 || error != nil { connection.cancel(); return }
            if let request = Self.parse(buffer) {
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            } else if done {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// A complete request (headers + Content-Length body), or nil when more bytes are needed.
    private static func parse(_ data: Data) -> AgentHTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return AgentHTTPRequest(method: "", path: "", query: [:], headers: [:], body: Data()) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        let target = String(first[1])
        let parts = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in parts?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return AgentHTTPRequest(method: String(first[0]).uppercased(), path: parts?.path ?? target,
                                query: query, headers: headers, body: Data(body))
    }

    private func send(_ response: AgentHTTPResponse, on connection: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      409: "Conflict", 500: "Internal Server Error", 502: "Bad Gateway"][response.status] ?? "Status"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - API (routing to the same code the pages use)

final class AgentAPI: ObservableObject {
    static let defaultPort = 7801

    @Published var enabled = UserDefaults.standard.object(forKey: "NovaMac.agentAPI.enabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(enabled, forKey: "NovaMac.agentAPI.enabled"); restart() }
    }
    @Published var allowChanges = UserDefaults.standard.bool(forKey: "NovaMac.agentAPI.allowChanges") {
        didSet { UserDefaults.standard.set(allowChanges, forKey: "NovaMac.agentAPI.allowChanges") }
    }
    @Published var port = UserDefaults.standard.object(forKey: "NovaMac.agentAPI.port") as? Int ?? AgentAPI.defaultPort {
        didSet { UserDefaults.standard.set(port, forKey: "NovaMac.agentAPI.port") }
    }
    @Published private(set) var token: String
    @Published private(set) var running = false
    @Published private(set) var failure: String?
    @Published private(set) var log: [String] = []

    private var server: AgentHTTPServer?
    private weak var device: NovaDevice?
    private weak var workspace: ScreenWorkspace?

    init() {
        if let saved = NovaKeychain.password(for: "agent-api-token") { token = saved }
        else {
            token = Self.newToken()
            NovaKeychain.save(token, for: "agent-api-token")
        }
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func regenerateToken() {
        token = Self.newToken()
        NovaKeychain.save(token, for: "agent-api-token")
    }

    func attach(device: NovaDevice, workspace: ScreenWorkspace) {
        self.device = device
        self.workspace = workspace
        restart()
    }

    func restart() {
        server?.stop(); server = nil; running = false; failure = nil
        guard enabled, device != nil, (1024...65535).contains(port) else { return }
        let server = AgentHTTPServer { [weak self] request in
            guard let self else { return .error(500, "app closing") }
            return await self.handle(request)
        }
        do {
            try server.start(port: UInt16(port)) { [weak self] problem in
                let owner = self
                Task { @MainActor in
                    owner?.running = problem == nil
                    owner?.failure = problem
                }
            }
            self.server = server
        } catch { failure = error.localizedDescription }
    }

    private func note(_ text: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(time)  \(text)", at: 0)
        if log.count > 60 { log.removeLast(log.count - 60) }
    }

    // MARK: Routing

    func handle(_ request: AgentHTTPRequest) async -> AgentHTTPResponse {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            note("401 \(request.method) \(request.path)")
            return .error(401, "Missing or wrong token (Authorization: Bearer <token> from the NovaMac Agent API page).")
        }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let route = "\(request.method) \(request.path)"
        let response: AgentHTTPResponse
        do {
            response = try await dispatch(route, query: request.query, body: body)
        } catch let failure as APIFailure {
            response = .error(failure.status, failure.message)
        } catch {
            response = .error(502, error.localizedDescription)
        }
        note("\(response.status) \(route)")
        return response
    }

    struct APIFailure: Error { let status: Int; let message: String }
    /// Last clone read (source and target), reused by the confirming call within 10 minutes.
    private var cloneJob: (key: String, status: String, done: Bool, result: [String: Any])?
    private func fail(_ status: Int, _ message: String) -> APIFailure { APIFailure(status: status, message: message) }

    private func dispatch(_ route: String, query: [String: String], body: [String: Any]) async throws -> AgentHTTPResponse {
        guard let device, let workspace else { throw fail(500, "not attached") }
        switch route {
        case "GET /v1", "GET /v1/":
            return .json(200, Self.index)

        case "GET /v1/controllers":
            return .json(200, ["controllers": controllers(device)])

        case "POST /v1/controllers/rescan":
            device.scanUSB()
            for endpoint in allEndpoints(device) { await device.ensureModel(endpoint) }
            return .json(200, ["controllers": controllers(device)])

        case "GET /v1/screens":
            return .json(200, ["screens": workspace.screens.map { screenJSON($0, device) }, "reading": workspace.reading])

        case "POST /v1/screens/read":
            await workspace.readAll(device: device)
            return .json(200, ["screens": workspace.screens.map { screenJSON($0, device) }, "note": workspace.readStatus])

        case "GET /v1/picture":
            let endpoint = try controller(query["controller"], device)
            let port = try portIndex(query["port"], endpoint, device) ?? 0
            let s = try await ScreenPicture.read(endpoint, port: port)
            let mode = try? await ScreenCalibration.read(endpoint, port: port)
            return .json(200, [
                "controller": endpoint.key, "port": portLabel(port, endpoint, device),
                "brightness_percent": Int((Double(s.brightness) * 100 / 255).rounded()), "brightness_raw": s.brightness,
                "gamma": Double(s.gamma) / 10, "red": s.red, "green": s.green, "blue": s.blue,
                "calibration": opt(mode.map { ScreenCalibration.Mode(rawValue: $0).map(Self.modeName) ?? String(format: "0x%02X", $0) }),
            ])

        case "GET /v1/receiving-card":
            let endpoint = try controller(query["controller"], device)
            let port = try portIndex(query["port"], endpoint, device) ?? 0
            let card = max(0, (Int(query["card"] ?? "1") ?? 1) - 1)
            let snap = try await ReceivingCardRegisters.read(endpoint, port: port, card: card)
            var result: [String: Any] = [
                "controller": endpoint.key, "port": portLabel(port, endpoint, device), "card": card + 1,
                "width": snap.width, "height": snap.height,
                "model_id": opt(snap.modelID.map { String(format: "0x%04X", $0) }),
                "fpga": opt(snap.fpga.map { "\($0.name) \($0.version)" }),
                "mcu": opt(snap.mcu.map { "\($0.name) \($0.version)" }),
                "parameters_hex": snap.parameters.map { String(format: "%02X", $0) }.joined(),
            ]
            if let xml = snap.cabinetXML {
                result["cabinet"] = Dictionary(CabinetDescription(xml: xml).fields, uniquingKeysWith: { a, _ in a })
            }
            return .json(200, result)

        case "GET /v1/monitor":
            let numbers = Int(query["screen"] ?? "")
            guard let screen = workspace.screens.first(where: { numbers == nil || $0.number == numbers }) else {
                throw fail(409, "No such screen — POST /v1/screens/read first.")
            }
            let cells = screen.plan.cells.filter { $0.order != nil && !$0.blank }
            let list = cells.map { (port: $0.port - 1, card: $0.order! - 1) }
            let status = try await ScreenMonitor.cards(screen.endpoint, list)
            var cabinets: [[String: Any]] = []
            for (cell, s) in zip(cells, status) {
                let r = screen.plan.rect(of: cell)
                cabinets.append(["port": portLabel(s.port, screen.endpoint, device), "card": s.card + 1,
                                 "x": r.x, "y": r.y, "width": r.width, "height": r.height, "answering": s.answered,
                                 "temperature_c": opt(s.temperature), "voltage_v": opt(s.voltage)])
            }
            let ports = Set(cells.map(\.port)).sorted().map { p -> [String: Any] in
                let load = screen.plan.portLoad(sender: 1, port: p)
                return ["port": portLabel(p - 1, screen.endpoint, device), "pixels": load,
                        "load_percent": Double(load) * 100 / Double(ScreenConnectionPlan.portCapacity)]
            }
            var result: [String: Any] = ["screen": screen.number, "controller": screen.endpoint.key,
                                         "cabinets": cabinets, "ports": ports,
                                         "note": "temperature verified against NovaLCT; voltage not yet confirmed"]
            if let inputs = try? await ScreenMonitor.inputs(screen.endpoint), device.ids[screen.endpoint.key]?.family == 0x622B {
                result["inputs"] = inputs.filter { $0.signal || $0.width > 0 }.map {
                    ["input": $0.index, "signal": $0.signal, "width": $0.width, "height": $0.height, "rate_hz": opt($0.rate)] as [String: Any]
                }
            }
            return .json(200, result)

        case "POST /v1/brightness":
            try requireChanges()
            guard let percent = number(body["percent"]) else { throw fail(400, "percent (0…100) is required") }
            let value = Int((min(max(percent, 0), 100) * 255 / 100).rounded())
            let done = try await forEachTarget(body, device, workspace) { endpoint, ports in
                try await ScreenBrightness.set(endpoint, value: value, ports: ports)
            }
            return .json(200, ["set": done, "brightness_raw": value])

        case "POST /v1/gamma":
            try requireChanges()
            guard let g = number(body["gamma"]), (1.0...4.0).contains(g) else { throw fail(400, "gamma (1.0…4.0) is required") }
            let tenth = Int((g * 10).rounded())
            let done = try await forEachTarget(body, device, workspace) { endpoint, ports in
                let now = try await ScreenPicture.read(endpoint, port: ports?.first ?? 0)
                guard let top = now.gammaTop else { throw self.fail(409, "the card's gamma table could not be read — not changed") }
                try await ScreenPicture.setGamma(endpoint, gamma: tenth, table: ScreenPicture.gammaTable(gamma: Double(tenth) / 10, top: top), ports: ports)
            }
            return .json(200, ["set": done, "gamma": Double(tenth) / 10])

        case "POST /v1/color":
            try requireChanges()
            guard let r = number(body["red"]), let g = number(body["green"]), let b = number(body["blue"]) else {
                throw fail(400, "red, green, blue (0…255) are required")
            }
            let done = try await forEachTarget(body, device, workspace) { endpoint, ports in
                try await ScreenPicture.setColor(endpoint, red: Int(r), green: Int(g), blue: Int(b), ports: ports)
            }
            return .json(200, ["set": done])

        case "POST /v1/calibration":
            try requireChanges()
            let name = (body["mode"] as? String ?? "").lowercased()
            guard let mode = ScreenCalibration.Mode.allCases.first(where: { Self.modeName($0) == name }) else {
                throw fail(400, "mode must be off, brightness or chroma")
            }
            let done = try await forEachTarget(body, device, workspace) { endpoint, ports in
                try await ScreenCalibration.set(endpoint, mode: mode, ports: ports)
            }
            return .json(200, ["set": done, "mode": name])

        case "POST /v1/mapping":
            try requireChanges()
            guard let on = body["enabled"] as? Bool else { throw fail(400, "enabled (true/false) is required") }
            let endpoint = try controller(body["controller"] as? String, device)
            try await ScreenMapping.set(endpoint, enabled: on)
            return .json(200, ["controller": endpoint.key, "mapping": on])

        case "GET /v1/receiving-cards/compare":
            return try await compareCards(query, device)

        case "POST /v1/receiving-card/fix":
            return try await fixCard(body, device)

        case "POST /v1/receiving-cards/save":
            return try await saveCards(body, device)

        case "GET /v1/rcfgx":
            return try await listRCFGX(query, device)

        case "POST /v1/receiving-card/read-rcfgx":
            return try await readCardRCFGX(body, device)

        case "POST /v1/receiving-card/rcfgx":
            return try await sendRCFGX(body, device)

        case "POST /v1/receiving-card/clone":
            return try await cloneCard(body, device)

        case "POST /v1/layout":
            return try await sendLayout(body, device, workspace)

        default:
            throw fail(404, "Unknown endpoint \(route). GET /v1 lists them.")
        }
    }

    // MARK: Layout send (register protocol: MCTRL…, MEE410 — not VX Pro, whose web model needs the app)

    /// {controller, port, cards:[{card,x,y,width,height}]} or {controller, port, grid:{columns,rows,card_width,
    /// card_height, path}}. Without "confirm":true only the plan is returned (nothing is sent). With it the layout
    /// is sent like Screen Connection's Send to HW — RAM only, not saved to flash — and the screen is read back.
    private func sendLayout(_ body: [String: Any], _ device: NovaDevice, _ workspace: ScreenWorkspace) async throws -> AgentHTTPResponse {
        let endpoint = try controller(body["controller"] as? String, device)
        await device.ensureModel(endpoint)
        let model = device.models[endpoint.key]
        let connector = number(body["port"]).map { Int($0) } ?? 1
        let p = try portIndex(connector, endpoint, device)

        struct Item { let card: Int; let x: Int; let y: Int; let w: Int; let h: Int }
        var items: [Item] = []
        if let list = body["cards"] as? [[String: Any]] {
            for c in list {
                guard let card = number(c["card"]), let x = number(c["x"]), let y = number(c["y"]),
                      let w = number(c["width"]), let h = number(c["height"]) else {
                    throw fail(400, "each card needs card, x, y, width, height")
                }
                items.append(Item(card: Int(card), x: Int(x), y: Int(y), w: Int(w), h: Int(h)))
            }
        } else if let g = body["grid"] as? [String: Any] {
            guard let cols = number(g["columns"]).map({ Int($0) }), let rows = number(g["rows"]).map({ Int($0) }),
                  let w = number(g["card_width"]).map({ Int($0) }), let h = number(g["card_height"]).map({ Int($0) }),
                  cols >= 1, rows >= 1 else { throw fail(400, "grid needs columns, rows, card_width, card_height") }
            let path = (g["path"] as? String) ?? "rows"
            var cells: [(Int, Int)] = []          // (column, row) in cable order
            switch path {
            case "rows": for r in 0..<rows { for c in 0..<cols { cells.append((c, r)) } }
            case "rows_snake": for r in 0..<rows { for k in 0..<cols { cells.append((r % 2 == 0 ? k : cols - 1 - k, r)) } }
            case "columns": for c in 0..<cols { for r in 0..<rows { cells.append((c, r)) } }
            case "columns_snake": for c in 0..<cols { for k in 0..<rows { cells.append((c, c % 2 == 0 ? k : rows - 1 - k)) } }
            default: throw fail(400, "grid.path is rows | rows_snake | columns | columns_snake")
            }
            items = cells.enumerated().map { i, cell in Item(card: i + 1, x: cell.0 * w, y: cell.1 * h, w: w, h: h) }
        } else {
            throw fail(400, "give cards:[{card,x,y,width,height}] or grid:{columns,rows,card_width,card_height,path}")
        }

        // Checks: cable order 1…N, sizes, the number of cards that actually answer on the port, overlaps.
        let n = items.count
        guard n >= 1, Set(items.map(\.card)) == Set(1...n) else { throw fail(400, "card numbers must be 1…\(max(n, 1)) without gaps or repeats") }
        guard items.allSatisfy({ (1...4096).contains($0.w) && (1...4096).contains($0.h) && $0.x >= 0 && $0.y >= 0 && $0.x <= 65535 && $0.y <= 65535 }) else {
            throw fail(400, "sizes must be 1…4096 and positions 0…65535")
        }
        let answering = try await CardProbe.count(endpoint, portIndex: p, limit: 256)
        var warnings: [String] = []
        if answering != n { warnings.append("\(answering) card(s) answer on port \(connector), the layout has \(n).") }
        for a in items { for b in items where b.card > a.card {
            if a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h { warnings.append("cards \(a.card) and \(b.card) overlap") }
        } }
        let width = items.map { $0.x + $0.w }.max() ?? 0, height = items.map { $0.y + $0.h }.max() ?? 0
        let plan: [String: Any] = [
            "controller": endpoint.key, "port": connector, "width": width, "height": height, "cards_answering": answering,
            "cards": items.sorted { $0.card < $1.card }.map { ["card": $0.card, "x": $0.x, "y": $0.y, "width": $0.w, "height": $0.h] },
            "warnings": warnings,
        ]
        guard body["confirm"] as? Bool == true else {
            return .json(200, ["sent": false, "plan": plan,
                               "next": "Check the plan, then repeat the same request with \"confirm\": true to send it (RAM only, not saved)."])
        }
        try requireChanges()
        guard answering == n else { throw fail(409, "Not sent: \(answering) card(s) answer on port \(connector), the layout has \(n).") }
        guard !warnings.contains(where: { $0.contains("overlap") }) else { throw fail(409, "Not sent: cards overlap.") }

        var layout = ScreenConnectionWriter.Layout(
            cards: items.map { ScreenConnectionWriter.Card(chainIndex: $0.card - 1, x: $0.x, y: $0.y, width: $0.w, height: $0.h, port: p) },
            width: width, height: height, portIndex: p)
        layout.model = model
        // Same path as Screen Connection's Send to HW: a VX Pro (Unico REST) gets the sending-card registers and
        // its web-interface model; other controllers the register sequence, verified by reading it back.
        let result: String
        do {
            if case .network(let ip) = endpoint, let screens = try? await UnicoAPI.fetchScreens(ip: ip),
               let guid = screens.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "MVR" })?.guid {
                try await ScreenConnectionWriter.sendRegistersOnly(ip: ip, layout: layout)
                result = "Registers (NovaLCT protocol) written. " + (try await UnicoTopologyWriter.send(ip: ip, layout: layout, screenGuid: guid))
            } else {
                result = try await ScreenConnectionWriter.send(endpoint, layout: layout)
            }
        } catch UnicoSession.Failure.needsPassword {
            throw fail(409, "The controller's web interface needs a login: log in once on NovaMac's Screen Connection page with \"Remember password\".")
        }
        await workspace.read(endpoint, device: device)
        return .json(200, ["sent": true, "saved": false, "plan": plan, "result": result,
                           "note": "Not saved to flash: a power cycle restores the stored layout. Save from NovaMac (Save to HW) when it looks right."])
    }

    // MARK: Receiving-card parameters (RCFGX) — compare, fix one card from another, save

    /// Offsets of the 512-byte parameter block that belong to each card and must never be copied.
    /// 0x17–0x1A size (Screen Connection), 0x51 the card's number in the chain (MCTRL300 dump, 23.10.2026).
    private static let perCardOffsets: Set<Int> = [0x17, 0x18, 0x19, 0x1A, 0x51]
    /// Names known so far (RCFGX .bin edits, HANDOFF).
    private static let offsetNames: [Int: String] = [
        0x00: "gamma×10", 0x01: "brightness", 0x02: "red gain", 0x03: "green gain", 0x04: "blue gain", 0x05: "VR gain",
        0x08: "duty", 0x17: "width", 0x19: "height", 0x2C: "line changing", 0x38: "DCLK cycle", 0x39: "DCLK phase",
        0x3A: "DCLK high", 0x51: "card number", 0xAD: "ghost end", 0x18E: "ghost",
    ]

    private func hex(_ v: Int) -> String { String(format: "0x%02X", v) }
    private func offsetText(_ o: Int) -> String { String(format: "0x%03X", o) }

    /// Per byte: the value most cards have (if more than half share it).
    private func majority(_ blocks: [[UInt8]], at offset: Int) -> UInt8? {
        var counts: [UInt8: Int] = [:]
        for b in blocks where offset < b.count { counts[b[offset], default: 0] += 1 }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value * 2 > blocks.count else { return nil }
        return best.key
    }

    private func compareCards(_ query: [String: String], _ device: NovaDevice) async throws -> AgentHTTPResponse {
        let endpoint = try controller(query["controller"], device)
        let connector = Int(query["port"] ?? "") ?? 1
        let p = try portIndex(connector, endpoint, device)
        let blocks = try await ReceivingCardRegisters.parameterBlocks(endpoint, port: p)
        guard !blocks.isEmpty else { throw fail(409, "No receiving card answers on port \(connector).") }
        var differences: [[String: Any]] = []
        var suspicion = [Int](repeating: 0, count: blocks.count)
        for o in 0..<ReceivingCardRegisters.parameterSize {
            let values = blocks.map { o < $0.count ? $0[o] : 0 }
            guard Set(values).count > 1 else { continue }
            let common = majority(blocks, at: o)
            let perCard = Self.perCardOffsets.contains(o)
            var entry: [String: Any] = ["offset": offsetText(o), "values": values.map { hex(Int($0)) },
                                        "per_card": perCard, "majority": opt(common.map { hex(Int($0)) })]
            if let name = Self.offsetNames[o] { entry["name"] = name }
            if let common, !perCard {
                let odd = values.indices.filter { values[$0] != common }
                entry["differs_on_cards"] = odd.map { $0 + 1 }
                for i in odd { suspicion[i] += 1 }
            }
            differences.append(entry)
        }
        let suspects = suspicion.indices.filter { suspicion[$0] > 0 }.map { ["card": $0 + 1, "bytes_off_majority": suspicion[$0]] }
        let reference = suspicion.firstIndex(of: 0).map { $0 + 1 }
        var notes = ["values are listed card 1, card 2, … in cable order",
                     "per_card offsets (size, card number) differ by design and are never copied"]
        if blocks.count < 3 { notes.append("only \(blocks.count) card(s): with fewer than 3 the odd card cannot be told by majority") }
        return .json(200, ["controller": endpoint.key, "port": connector, "cards": blocks.count,
                           "suspects": suspects, "reference_card": opt(reference),
                           "differences": differences, "notes": notes])
    }

    private func fixCard(_ body: [String: Any], _ device: NovaDevice) async throws -> AgentHTTPResponse {
        let endpoint = try controller(body["controller"] as? String, device)
        let connector = number(body["port"]).map { Int($0) } ?? 1
        let p = try portIndex(connector, endpoint, device)
        guard let card = number(body["card"]).map({ Int($0) }), let source = number(body["from_card"]).map({ Int($0) }),
              card >= 1, source >= 1, card != source else { throw fail(400, "card and from_card (1-based, different) are required") }
        let blocks = try await ReceivingCardRegisters.parameterBlocks(endpoint, port: p)
        guard card <= blocks.count, source <= blocks.count else {
            throw fail(409, "Only \(blocks.count) card(s) answer on port \(connector).")
        }
        let target = blocks[card - 1], reference = blocks[source - 1]
        var offsets: [Int]
        if let list = body["offsets"] as? [Any] {
            offsets = try list.map { item -> Int in
                if let n = item as? NSNumber { return n.intValue }
                if let t = item as? String, let v = Int(t.hasPrefix("0x") ? String(t.dropFirst(2)) : t, radix: t.hasPrefix("0x") ? 16 : 10) { return v }
                throw fail(400, "offsets are numbers or \"0x…\" strings")
            }
        } else {
            offsets = (0..<min(target.count, reference.count)).filter { target[$0] != reference[$0] }
        }
        offsets = offsets.filter { !Self.perCardOffsets.contains($0) && $0 >= 0 && $0 < min(target.count, reference.count) && target[$0] != reference[$0] }
        var edited = target
        for o in offsets { edited[o] = reference[o] }
        let changes = offsets.map { o -> [String: Any] in
            var e: [String: Any] = ["offset": offsetText(o), "from": hex(Int(target[o])), "to": hex(Int(reference[o]))]
            if let name = Self.offsetNames[o] { e["name"] = name }
            return e
        }
        let plan: [String: Any] = ["controller": endpoint.key, "port": connector, "card": card, "from_card": source, "changes": changes]
        guard !offsets.isEmpty else { return .json(200, ["written": false, "plan": plan, "note": "Nothing to change."]) }
        guard body["confirm"] as? Bool == true else {
            return .json(200, ["written": false, "plan": plan,
                               "next": "Check the changes, then repeat with \"confirm\": true (RAM only; POST /v1/receiving-cards/save keeps it)."])
        }
        try requireChanges()
        let back = try await ReceivingCardRegisters.write(endpoint, port: p, card: card - 1, original: target, edited: edited)
        let wrong = offsets.filter { $0 >= back.count || back[$0] != edited[$0] }
        return .json(200, ["written": true, "saved": false, "plan": plan,
                           "verified": wrong.isEmpty, "not_taken": wrong.map { offsetText($0) },
                           "note": "In RAM. Check the screen, then POST /v1/receiving-cards/save with confirm:true to keep it after power-off."])
    }

    /// Library files, and with ?controller=&port= how well each one matches the cards' running parameters.
    private func listRCFGX(_ query: [String: String], _ device: NovaDevice) async throws -> AgentHTTPResponse {
        let names = RCFGXLibrary.names()
        guard query["controller"] != nil || query["port"] != nil else {
            return .json(200, ["files": names, "folder": RCFGXLibrary.folder.path,
                               "note": "Files appear here when they are opened once on NovaMac's Receiving Cards page."])
        }
        let endpoint = try controller(query["controller"], device)
        let connector = Int(query["port"] ?? "") ?? 1
        let p = try portIndex(connector, endpoint, device)
        let blocks = try await ReceivingCardRegisters.parameterBlocks(endpoint, port: p)
        guard !blocks.isEmpty else { throw fail(409, "No receiving card answers on port \(connector).") }
        // Bytes a file sets but the card owns or rewrites at run time: size, card number, brightness,
        // test pattern, the status area 0x13A–0x14D.
        let ignored = Self.perCardOffsets.union([0x01, 0x100, 0x101, 0x102]).union(Set(0x13A...0x14D))
        var files: [[String: Any]] = []
        for name in names {
            guard let records = try? RCFGXLibrary.records(name) else { files.append(["file": name, "error": "unreadable"]); continue }
            let image = RCFGXBin.parameterImage(records).filter { !ignored.contains($0.key) }
            let perCard: [[String: Any]] = blocks.enumerated().map { i, b -> [String: Any] in
                let off = image.filter { $0.key < b.count && b[$0.key] != $0.value }.keys.sorted()
                return ["card": i + 1, "bytes_differ": off.count, "first": off.prefix(6).map { offsetText($0) }]
            }
            files.append(["file": name, "bytes_compared": image.count, "cards": perCard])
        }
        return .json(200, ["controller": endpoint.key, "port": connector, "files": files,
                           "note": "bytes_differ 0 = the card runs exactly this file's parameter block (size, card number, brightness and status bytes ignored). Only the 0x02000000 block can be compared; the file also writes scan, mapping and gamma tables."])
    }

    /// Reads one card into a new library RCFGX (the template file gives the record list and XML).
    private func readCardRCFGX(_ body: [String: Any], _ device: NovaDevice) async throws -> AgentHTTPResponse {
        let endpoint = try controller(body["controller"] as? String, device)
        let connector = number(body["port"]).map { Int($0) } ?? 1
        let p = try portIndex(connector, endpoint, device)
        guard let card = number(body["card"]).map({ Int($0) }), card >= 1 else { throw fail(400, "card (1-based) is required") }
        guard let template = body["template"] as? String, !template.isEmpty else {
            throw fail(400, "template (a library file of the same cabinet type, from GET /v1/rcfgx) is required")
        }
        let answering = try await CardProbe.count(endpoint, portIndex: p, limit: 256)
        guard card <= answering else { throw fail(409, "Only \(answering) card(s) answer on port \(connector).") }
        let name = (body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\((template as NSString).deletingPathExtension) – port \(connector) card \(card)"
        let result: (name: String, kept: [UInt32])
        do { result = try await RCFGXLibrary.readCard(endpoint, port: p, card: card - 1, template: template, name: name) }
        catch let e as RCFGXError { throw fail(404, e.localizedDescription) }
        return .json(200, ["file": result.name, "read_from": "port \(connector) card \(card)",
                           "kept_from_template": result.kept.map { String(format: "0x%08X", $0) },
                           "next": "send_rcfgx with this file to the card to fix, then save_receiving_cards."])
    }

    /// Writes a library RCFGX to one card (port + card) or to every card of the controller, as the Receiving
    /// Cards page does. Plan first; confirm:true to write (RAM — save with /v1/receiving-cards/save).
    private func sendRCFGX(_ body: [String: Any], _ device: NovaDevice) async throws -> AgentHTTPResponse {
        guard let name = body["file"] as? String, !name.isEmpty else { throw fail(400, "file (a name from GET /v1/rcfgx) is required") }
        let endpoint = try controller(body["controller"] as? String, device)
        let records: [RCFGXRecord]
        do { records = try RCFGXLibrary.records(name) } catch { throw fail(404, error.localizedDescription) }
        var port: Int? = nil, card: Int? = nil
        if let c = number(body["card"]).map({ Int($0) }) {
            let connector = number(body["port"]).map { Int($0) } ?? 1
            port = try portIndex(connector, endpoint, device)
            guard c >= 1 else { throw fail(400, "card is 1-based") }
            let answering = try await CardProbe.count(endpoint, portIndex: port!, limit: 256)
            guard c <= answering else { throw fail(409, "Only \(answering) card(s) answer on port \(connector).") }
            card = c - 1
        }
        let bytes = records.reduce(0) { $0 + $1.data.count }
        let image = RCFGXBin.parameterImage(records)
        let size = (image[0x17].map { Int($0) } ?? 0) + (image[0x18].map { Int($0) * 256 } ?? 0)
        let height = (image[0x19].map { Int($0) } ?? 0) + (image[0x1A].map { Int($0) * 256 } ?? 0)
        let target = card.map { "port \(ControllerModels.portLabel(model: device.models[endpoint.key], index: port!)), card \($0 + 1)" } ?? "every receiving card"
        let plan: [String: Any] = ["controller": endpoint.key, "file": name, "target": target,
                                   "records": records.count, "bytes": bytes, "card_size_in_file": "\(size) × \(height)",
                                   "estimated_seconds": endpoint.isUSB ? bytes / 9000 + 5 : bytes / 200_000 + 3]
        guard body["confirm"] as? Bool == true else {
            return .json(200, ["sent": false, "plan": plan,
                               "next": "Repeat with \"confirm\": true to write (RAM). The file also sets the card size; re-send the layout if it differs."])
        }
        try requireChanges()
        try await RCFGXBin.send(endpoint, records: records, port: port, card: card) { _, _ in }
        return .json(200, ["sent": true, "saved": false, "plan": plan,
                           "note": "Written to RAM. Check the screen; POST /v1/receiving-cards/save with confirm:true keeps it."])
    }

    /// Copies a card's whole configuration (the RCFGX regions + its parameter block without the card's own bytes)
    /// to another card on the same port. Without confirm: a quick comparison (regions sampled to 4 KB) as the plan.
    /// With confirm:true the copy runs in the background (about a minute over USB); call again to see its result.
    private func cloneCard(_ body: [String: Any], _ device: NovaDevice) async throws -> AgentHTTPResponse {
        let endpoint = try controller(body["controller"] as? String, device)
        let connector = number(body["port"]).map { Int($0) } ?? 1
        let p = try portIndex(connector, endpoint, device)
        guard let card = number(body["card"]).map({ Int($0) }), let from = number(body["from_card"]).map({ Int($0) }),
              card >= 1, from >= 1, card != from else { throw fail(400, "card and from_card (1-based, different) are required") }
        let key = "\(endpoint.key)|\(p)|\(from)|\(card)"
        if let job = cloneJob, job.key == key {
            if !job.done { return .json(200, ["running": true, "status": job.status, "next": "Call again in a few seconds."]) }
            if body["confirm"] as? Bool != true { cloneJob = nil; return .json(200, job.result) }
        }
        if let job = cloneJob, !job.done { throw fail(409, "Another clone is running: \(job.status)") }
        let answering = try await CardProbe.count(endpoint, portIndex: p, limit: 256)
        guard card <= answering, from <= answering else { throw fail(409, "Only \(answering) card(s) answer on port \(connector).") }

        let source = try await ReceivingCardClone.snapshot(endpoint, port: p, card: from - 1, sample: 4096)
        let target = try await ReceivingCardClone.snapshot(endpoint, port: p, card: card - 1, sample: 4096)
        var differing: [UInt32] = []
        var regionInfo: [[String: Any]] = []
        for r in ReceivingCardClone.regions {
            let a = source.regions[r.address], b = target.regions[r.address]
            let state: String
            if a == nil { state = "not readable on card \(from)" }
            else if b == nil || a! != b! {
                differing.append(r.address)
                let n = b.map { bb in zip(a!, bb).filter { $0 != $1 }.count } ?? a!.count
                state = "differs (\(n) of \(a!.count) bytes compared)"
            } else { state = r.length > 4096 ? "same in the first 4 KB" : "same" }
            regionInfo.append(["address": String(format: "0x%08X", r.address), "bytes": r.length, "state": state])
        }
        // "regions": ["0x04000000", …] — write these in full even if the 4 KB sample matches (e.g. the pixel map).
        if let forced = body["regions"] as? [Any] {
            for item in forced {
                let text = (item as? String) ?? (item as? NSNumber).map { String($0.intValue) } ?? ""
                let hexText = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
                guard let value = UInt32(hexText, radix: 16),
                      ReceivingCardClone.regions.contains(where: { $0.address == value }) else {
                    throw fail(400, "regions: \(text) is not one of the clone regions")
                }
                if !differing.contains(value) { differing.append(value) }
            }
        }
        let blockOffsets = (0..<min(source.block.count, target.block.count)).filter {
            !ReceivingCardClone.keepInBlock.contains($0) && source.block[$0] != target.block[$0]
        }
        let plan: [String: Any] = [
            "controller": endpoint.key, "port": connector, "from_card": from, "card": card,
            "regions": regionInfo, "regions_to_write": differing.map { String(format: "0x%08X", $0) },
            "parameter_bytes_to_write": blockOffsets.count,
        ]
        guard body["confirm"] as? Bool == true else {
            return .json(200, ["written": false, "plan": plan,
                               "next": "Repeat with \"confirm\": true to write the differing regions to card \(card) (background, ~1 min over USB; RAM)."])
        }
        try requireChanges()
        guard !differing.isEmpty || !blockOffsets.isEmpty else {
            return .json(200, ["written": false, "plan": plan, "note": "Card \(card) already has card \(from)'s configuration."])
        }
        cloneJob = (key, "reading card \(from)…", false, [:])
        let regionsToWrite = Set(differing)
        Task { @MainActor [weak self] in
            do {
                let full = try await ReceivingCardClone.snapshot(endpoint, port: p, card: from - 1)
                self?.cloneJob?.status = "writing card \(card)…"
                try await ReceivingCardClone.write(endpoint, port: p, card: card - 1, source: full,
                                                   addresses: regionsToWrite, blockOffsets: blockOffsets)
                self?.cloneJob?.status = "verifying…"
                let after = try await ReceivingCardClone.snapshot(endpoint, port: p, card: card - 1, sample: 4096)
                let still = ReceivingCardClone.regions.filter { r in
                    guard let a = full.regions[r.address] else { return false }
                    return after.regions[r.address] != Array(a.prefix(4096))
                }.map { String(format: "0x%08X", $0.address) }
                let stillBytes = blockOffsets.filter { $0 >= after.block.count || after.block[$0] != full.block[$0] }
                self?.cloneJob = (key, "done", true, [
                    "written": true, "saved": false, "plan": plan, "verified": still.isEmpty && stillBytes.isEmpty,
                    "regions_still_different": still, "parameter_bytes_still_different": stillBytes.map { String(format: "0x%03X", $0) },
                    "note": "In RAM. Check the screen; save_receiving_cards with confirm:true keeps it after power-off.",
                ])
            } catch {
                self?.cloneJob = (key, "failed", true, ["written": false, "error": error.localizedDescription,
                                                        "note": "Partly written cards are fixed by running the clone again or by a power cycle."])
            }
        }
        return .json(200, ["started": true, "plan": plan,
                           "next": "Writing in the background. Call clone_receiving_card again (same cards, without confirm) for the result."])
    }

    private func saveCards(_ body: [String: Any], _ device: NovaDevice) async throws -> AgentHTTPResponse {
        let endpoint = try controller(body["controller"] as? String, device)
        guard body["confirm"] as? Bool == true else {
            return .json(200, ["saved": false, "next": "Writes the receiving cards' current parameters to their flash (all cards of \(endpoint.key)). Repeat with \"confirm\": true."])
        }
        try requireChanges()
        try await ReceivingCardRegisters.saveAll(endpoint)
        return .json(200, ["saved": true, "controller": endpoint.key])
    }

    // MARK: Helpers

    private static func modeName(_ mode: ScreenCalibration.Mode) -> String {
        switch mode { case .off: return "off"; case .brightness: return "brightness"; case .chroma: return "chroma" }
    }

    private func requireChanges() throws {
        guard allowChanges else { throw fail(403, "Changes are switched off. Turn on \"Allow changes\" on the NovaMac Agent API page.") }
    }

    private func opt(_ value: Any?) -> Any { value ?? NSNull() }

    private func integers(_ any: Any?) -> [Int]? {
        guard let list = any as? [Any] else { return nil }
        return list.compactMap { item in number(item).map { Int($0) } }
    }

    private func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private func allEndpoints(_ device: NovaDevice) -> [NovaEndpoint] {
        device.savedIPs.map { NovaEndpoint.network($0) } + device.usbPorts.map { .usb(path: $0, baud: device.baud(for: $0)) }
    }

    private func controllers(_ device: NovaDevice) -> [[String: Any]] {
        allEndpoints(device).map { e in
            let model = device.models[e.key]
            return ["controller": e.key, "title": device.title(for: e), "model": opt(model),
                    "link": e.isUSB ? "usb" : "ethernet", "ports": opt(ControllerModels.portCount(model: model))]
        }
    }

    /// "ip:192.168.0.10", "192.168.0.10", "usb:/dev/cu.usbserial-140"; nil = the controller selected in the app.
    private func controller(_ text: String?, _ device: NovaDevice) throws -> NovaEndpoint {
        guard let text, !text.isEmpty else { return device.selection }
        if text.hasPrefix("usb:") {
            let path = String(text.dropFirst(4))
            return .usb(path: path, baud: device.baud(for: path))
        }
        let ip = text.hasPrefix("ip:") ? String(text.dropFirst(3)) : text
        guard ip.split(separator: ".").count == 4 else { throw fail(400, "controller \(text) is not ip:<address> or usb:<path>") }
        return .network(ip)
    }

    /// Connector number (as printed on the controller, 1-based) → protocol port index.
    private func portIndex(_ text: String?, _ endpoint: NovaEndpoint, _ device: NovaDevice) throws -> Int? {
        guard let text, let n = Int(text) else { return nil }
        return try portIndex(n, endpoint, device)
    }

    private func portIndex(_ connector: Int, _ endpoint: NovaEndpoint, _ device: NovaDevice) throws -> Int {
        if let list = ControllerModels.physicalPorts(model: device.models[endpoint.key]) {
            guard (1...list.count).contains(connector) else { throw fail(400, "port \(connector) does not exist on this controller") }
            return list[connector - 1]
        }
        guard (1...32).contains(connector) else { throw fail(400, "port must be 1…32") }
        return connector - 1
    }

    private func portLabel(_ index: Int, _ endpoint: NovaEndpoint, _ device: NovaDevice) -> Int {
        ControllerModels.portLabel(model: device.models[endpoint.key], index: index)
    }

    private func ports(of screen: ScreenDocument) -> [Int] {
        Array(Set(screen.plan.cells.filter { $0.order != nil && !$0.blank }.map { $0.port - 1 })).sorted()
    }

    private func screenJSON(_ screen: ScreenDocument, _ device: NovaDevice) -> [String: Any] {
        let cells = screen.plan.cells.filter { $0.order != nil && !$0.blank }
        let rects = cells.map { screen.plan.rect(of: $0) }
        return [
            "screen": screen.number, "name": screen.name, "controller": screen.endpoint.key,
            "controller_title": device.title(for: screen.endpoint),
            "cards": cells.count,
            "ports": ports(of: screen).map { portLabel($0, screen.endpoint, device) },
            "width": rects.map(\.maxX).max() ?? 0, "height": rects.map(\.maxY).max() ?? 0,
            "layout": zip(cells, rects).map { cell, r in
                ["port": portLabel(cell.port - 1, screen.endpoint, device), "card": cell.order ?? 0,
                 "x": r.x, "y": r.y, "width": r.width, "height": r.height] as [String: Int]
            },
        ]
    }

    /// Body targets: {"screens":[1,2]} · {"controller":"ip:…","ports":[1,2]} · {"all":true} · nothing = all screens.
    private func forEachTarget(_ body: [String: Any], _ device: NovaDevice, _ workspace: ScreenWorkspace,
                               _ action: (NovaEndpoint, [Int]?) async throws -> Void) async throws -> [String] {
        var jobs: [(NovaEndpoint, [Int]?)] = []
        if let text = body["controller"] as? String {
            let endpoint = try controller(text, device)
            var indices: [Int]? = nil
            if let list = integers(body["ports"]) {
                indices = []
                for connector in list { indices!.append(try portIndex(connector, endpoint, device)) }
            }
            jobs = [(endpoint, indices)]
        } else {
            let numbers = integers(body["screens"])
            let chosen = workspace.screens.filter { numbers?.contains($0.number) ?? true }
            guard !chosen.isEmpty else {
                throw fail(409, workspace.screens.isEmpty ? "No screens read yet — POST /v1/screens/read first, or name a controller."
                                                          : "None of the screens \(numbers ?? []) exists.")
            }
            var seen = Set<String>()
            for screen in chosen where seen.insert(screen.endpoint.key).inserted {
                let all = workspace.screens.filter { $0.endpoint.key == screen.endpoint.key }
                if all.allSatisfy({ s in chosen.contains { $0 === s } }) { jobs.append((screen.endpoint, nil)) }
                else {
                    let p = Set(chosen.filter { $0.endpoint.key == screen.endpoint.key }.flatMap { ports(of: $0) })
                    jobs.append((screen.endpoint, p.sorted()))
                }
            }
        }
        var done: [String] = []
        for (endpoint, ports) in jobs {
            try await action(endpoint, ports)
            done.append(endpoint.key + (ports.map { " ports " + $0.map { String(portLabel($0, endpoint, device)) }.joined(separator: ",") } ?? " all ports"))
        }
        return done
    }

    // MARK: Self-description (GET /v1)

    static let index: [String: Any] = [
        "name": "NovaMac agent API", "version": 1,
        "auth": "Authorization: Bearer <token>",
        "conventions": [
            "controller": "ip:<address> or usb:<path> (from GET /v1/controllers); omitted = controller selected in the app",
            "port": "connector number as printed on the controller, 1-based",
            "card": "position in the cable chain, 1-based",
            "targets": "{\"screens\":[1,2]} or {\"controller\":\"ip:…\",\"ports\":[1,2]}; omitted = all screens",
            "changes": "POST endpoints that change the picture return 403 until 'Allow changes' is on in the app; nothing writes flash",
        ],
        "endpoints": [
            ["GET /v1/controllers", "controllers in the app: address, model, link, ports"],
            ["POST /v1/controllers/rescan", "rescan USB, read models"],
            ["GET /v1/screens", "screens known to the app with card layout"],
            ["POST /v1/screens/read", "read screens and card layout from the controllers (as 'Read all from HW')"],
            ["GET /v1/picture?controller=&port=", "brightness, gamma, RGB gains, calibration mode of the first card on a port"],
            ["GET /v1/receiving-card?controller=&port=&card=", "size, firmware, cabinet description, raw parameter block"],
            ["GET /v1/monitor?screen=", "input signal (VX), per-cabinet answer/temperature/voltage/position, port load"],
            ["POST /v1/brightness {percent, targets}", "brightness 0…100 %"],
            ["POST /v1/gamma {gamma, targets}", "gamma 1.0…4.0 (standard table scaled to the card's own)"],
            ["POST /v1/color {red, green, blue, targets}", "RGB gains 0…255"],
            ["POST /v1/calibration {mode, targets}", "calibration coefficients: off | brightness | chroma"],
            ["POST /v1/layout {controller, port, cards|grid, confirm}", "screen layout on one port, sent like Screen Connection's Send to HW (VX: registers + web model): plan without confirm, send with confirm:true; not saved"],
            ["GET /v1/receiving-cards/compare?controller=&port=", "compare the parameter blocks (RCFGX settings) of all cards on a port: odd bytes, suspect cards, a reference card"],
            ["POST /v1/receiving-card/fix {controller, port, card, from_card, offsets?, confirm}", "copy the differing bytes from a good card (never size or card number): plan, then confirm:true; RAM"],
            ["GET /v1/rcfgx[?controller=&port=]", "RCFGX files in NovaMac's library; with a port: how each matches every card"],
            ["POST /v1/receiving-card/rcfgx {file, controller, port?, card?, confirm}", "write a library RCFGX to one card (port+card) or all cards: plan, then confirm:true; RAM"],
            ["POST /v1/receiving-card/clone {controller, port, from_card, card, confirm}", "copy a card's whole configuration (RCFGX regions + parameters, not size/card number) to another card: plan with differing regions, then confirm:true; RAM"],
            ["POST /v1/receiving-card/read-rcfgx {controller, port, card, template, name?}", "read a card into a new library RCFGX (analysis/backup only — do not send it to fix a card; send the original file)"],
            ["POST /v1/receiving-cards/save {controller, confirm}", "save the receiving cards' parameters to flash (needs confirm:true)"],
            ["POST /v1/mapping {controller, enabled}", "show card numbers on the LED screen (Enable Mapping)"],
        ],
    ]
}

// MARK: - Page

struct AgentAPIPage: View {
    @ObservedObject var api: AgentAPI
    @State private var showToken = false

    private var base: String { "http://127.0.0.1:\(api.port)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable the local API (127.0.0.1 only)", isOn: $api.enabled)
                    HStack {
                        Text("Port")
                        TextField("", value: $api.port, format: .number.grouping(.never)).frame(width: 80)
                            .onSubmit { api.restart() }
                        Circle().fill(api.running ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        Text(api.running ? "Listening on \(base)" : api.enabled ? (api.failure ?? "Starting…") : "Off")
                            .font(.callout).foregroundStyle(api.failure == nil ? Color.secondary : .red)
                    }
                    HStack {
                        Text("Token")
                        Text(showToken ? api.token : String(repeating: "•", count: 24)).font(.callout.monospaced()).textSelection(.enabled)
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(api.token, forType: .string) }
                        Button("New token") { api.regenerateToken() }
                    }
                    Toggle("Allow changes (brightness, gamma, color, calibration, mapping)", isOn: $api.allowChanges)
                    Text("Off: agents can only read. Saving to flash and Send to HW are never available through the API.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: { Text("Agent API").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Try it in Terminal:").font(.callout)
                    Text("curl -H 'Authorization: Bearer <token>' \(base)/v1").font(.caption.monospaced()).textSelection(.enabled)
                    Text("curl -H 'Authorization: Bearer <token>' -d '{\"percent\":50}' \(base)/v1/brightness").font(.caption.monospaced()).textSelection(.enabled)
                    Text("For Claude Desktop and other MCP clients use nova_mcp.py from the project folder (see AGENT-API.md).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: { Text("Connect").font(.headline) }

            GroupBox {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(api.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if api.log.isEmpty { Text("No requests yet.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .frame(height: 180)
                .padding(6)
            } label: { Text("Requests").font(.headline) }
        }
    }
}
