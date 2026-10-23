import Foundation
import Darwin

// NovaMac — NovaStar register protocol over TCP 5200 (the transport NovaLCT uses with VX1000 Pro).
//
// Frame layout (little-endian), documented in "VX Pro Series Control Protocol V1.0.2" and
// confirmed against a NovaLCT capture (665 frames, all checksums valid):
//   0-1  55 AA (request) / AA 55 (response)
//   2    ack (0 = OK in responses)       3   serial number (echoed in the response)
//   4    source (FE = PC)                5   destination (00 = sending card, FF = broadcast)
//   6    device type (0 = sending card, 1 = receiving card)
//   7    Ethernet port index (0-based, FF = all)
//   8-9  receiving card index in the port chain (FFFF = all)
//   10   0 = read, 1 = write          11  reserved / flags
//   12-15 register address           16-17 data length
//   data (write requests, read responses)
//   last 2: checksum = (sum of bytes 2..end-of-data + 0x5555) & 0xFFFF

nonisolated struct NovaCommand: Sendable, Equatable {
    var destination: UInt8 = 0x00
    var device: UInt8 = 0
    var port: UInt8 = 0
    var card: UInt16 = 0
    var write: Bool
    var reserved: UInt8 = 0
    var address: UInt32
    var length: UInt16
    var data: [UInt8] = []

    static func write(_ address: UInt32, _ data: [UInt8], destination: UInt8 = 0x00, device: UInt8 = 0,
                      port: UInt8 = 0, card: UInt16 = 0, reserved: UInt8 = 0) -> NovaCommand {
        NovaCommand(destination: destination, device: device, port: port, card: card, write: true,
                    reserved: reserved, address: address, length: UInt16(data.count), data: data)
    }

    static func read(_ address: UInt32, length: UInt16, device: UInt8 = 0, port: UInt8 = 0, card: UInt16 = 0) -> NovaCommand {
        NovaCommand(device: device, port: port, card: card, write: false, address: address, length: length)
    }

    func frame(serial: UInt8) -> [UInt8] {
        var f: [UInt8] = [0x55, 0xAA, 0x00, serial, 0xFE, destination, device, port,
                          UInt8(card & 0xFF), UInt8(card >> 8), write ? 1 : 0, reserved]
        f += NovaBytes.le32(address)
        f += NovaBytes.le16(length)
        if write { f += data }
        let sum = NovaBytes.checksum(f[2...])
        f += NovaBytes.le16(sum)
        return f
    }
}

nonisolated enum NovaBytes {
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le16(_ v: Int) -> [UInt8] { le16(UInt16(clamping: v)) }
    static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
    static func checksum<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        UInt16(truncatingIfNeeded: bytes.reduce(UInt32(0x5555)) { $0 &+ UInt32($1) })
    }
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
}

nonisolated enum NovaLinkError: LocalizedError {
    case invalidIP
    case socket(Int32)
    case connect(Int32)
    case timeout
    case closed
    case badResponse(String)
    case nack(UInt8, UInt32)
    case failedStep(String)
    case portBusy

    var errorDescription: String? {
        switch self {
        case .invalidIP: return "Invalid controller IPv4 address."
        case .socket(let e): return "Socket error \(e): \(String(cString: strerror(e)))"
        case .connect(let e): return "Cannot connect to port 5200 (\(e): \(String(cString: strerror(e))))."
        case .timeout: return "Sending card did not answer in time."
        case .closed: return "Connection to the sending card was closed."
        case .badResponse(let s): return "Unexpected response: \(s)"
        case .failedStep(let s): return s
        case .portBusy: return "The USB port is used by another program (NovaLCT bridge, Parallels, a terminal). Close it and try again."
        case .nack(let code, let addr): return String(format: "Controller rejected register 0x%08X (ack 0x%02X).", addr, code)
        }
    }
}

/// Blocking TCP client. Use only from a background task (see `NovaLink.run`).
nonisolated final class NovaSocket {
    private var fd: Int32 = -1
    private var serial: UInt8 = 0
    private var isSerial = false
    private var timeoutMs: Int32 = 3000

    init(host: String, port: UInt16 = 5200, timeout: Int = 3) throws {
        self.timeoutMs = Int32(timeout * 1000)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw NovaLinkError.invalidIP }

        fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw NovaLinkError.socket(errno) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking connect with a timeout, then back to blocking mode.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { let e = errno; Darwin.close(fd); fd = -1; throw NovaLinkError.connect(e) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { Darwin.close(fd); fd = -1; throw NovaLinkError.timeout }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { Darwin.close(fd); fd = -1; throw NovaLinkError.connect(err) }
        }
        _ = fcntl(fd, F_SETFL, flags)
    }

    /// Opens a serial port (USB-UART of a sending card), raw 8N1, no flow control.
    init(serialPath: String, baud: Int = 115_200, timeout: Int = 1) throws {
        self.timeoutMs = Int32(timeout * 1000)
        fd = Darwin.open(serialPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let e = errno
            if e == EBUSY { throw NovaLinkError.portBusy }
            throw NovaLinkError.connect(e)
        }
        // Exclusive use (TIOCEXCL = _IO('t', 13)): nobody else can open the port while NovaMac talks to it.
        // A second reader (NovaLCT bridge, a terminal) would otherwise take bytes out of the answers.
        _ = ioctl(fd, UInt(0x2000_740D))
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { let e = errno; Darwin.close(fd); fd = -1; throw NovaLinkError.socket(e) }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        t.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CCTS_OFLOW | CRTS_IFLOW)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        cfsetspeed(&t, speed_t(baud))
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { let e = errno; Darwin.close(fd); fd = -1; throw NovaLinkError.socket(e) }
        tcflush(fd, TCIOFLUSH)
        isSerial = true
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    private func wait(for events: Int16) throws {
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        let r = Darwin.poll(&pfd, 1, timeoutMs)
        if r == 0 { throw NovaLinkError.timeout }
        if r < 0 { throw NovaLinkError.socket(errno) }
    }

    private func sendAll(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { buf -> Int in
                let p = buf.baseAddress! + offset, len = bytes.count - offset
                return isSerial ? Darwin.write(fd, p, len) : Darwin.send(fd, p, len, 0)
            }
            if n > 0 { offset += n; continue }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { try wait(for: Int16(POLLOUT)); continue }
            throw NovaLinkError.socket(errno)
        }
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try wait(for: Int16(POLLIN))
            let n = buffer.withUnsafeMutableBytes { buf -> Int in
                let p = buf.baseAddress! + offset, len = count - offset
                return isSerial ? Darwin.read(fd, p, len) : Darwin.recv(fd, p, len, 0)
            }
            if n > 0 { offset += n; continue }
            if n == 0 { throw NovaLinkError.closed }
            if errno == EAGAIN || errno == EINTR { continue }
            throw NovaLinkError.socket(errno)
        }
        return buffer
    }

    /// Discards whatever is waiting in the receive buffer (late or broken frames).
    private func drain() {
        usleep(30_000)
        if isSerial { tcflush(fd, TCIFLUSH); return }
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pfd, 1, 20) == 1 else { return }
            let n = scratch.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, 4096, 0) }
            if n <= 0 { return }
        }
    }

    /// Sends one command and waits for the response with the same serial number.
    /// Returns the response data (empty for writes). Throws on a non-zero ack.
    /// A broken frame (bad header or checksum — e.g. the tail of a late answer to an earlier request)
    /// clears the receive buffer and repeats the request, up to 3 attempts.
    @discardableResult
    func transact(_ command: NovaCommand) throws -> [UInt8] {
        var lastError: Error = NovaLinkError.badResponse("no response")
        for attempt in 0..<3 {
            do {
                return try transactOnce(command)
            } catch NovaLinkError.badResponse(let reason) {
                let place = String(format: " at register 0x%08X (device %d)", command.address, Int(command.device))
                let hint = isSerial && attempt == 2 ? " — answers keep arriving broken: is another program (nova_bridge.py, Parallels USB) reading the same USB port?" : ""
                lastError = NovaLinkError.badResponse(reason + place + (attempt == 2 ? ", 3 attempts" : "") + hint)
                drain()
            }
        }
        throw lastError
    }

    private func transactOnce(_ command: NovaCommand) throws -> [UInt8] {
        serial &+= 1
        let mySerial = serial
        try sendAll(command.frame(serial: mySerial))
        for _ in 0..<16 {
            let header = try readExactly(18)
            guard header[0] == 0xAA, header[1] == 0x55 else {
                throw NovaLinkError.badResponse(NovaBytes.hex(Array(header.prefix(4))))
            }
            let length = Int(header[16]) | Int(header[17]) << 8
            let dataLength = header[10] == 1 ? 0 : length
            let rest = try readExactly(dataLength + 2)
            let data = Array(rest.prefix(dataLength))
            let expected = NovaBytes.checksum(header[2...] + data)
            let received = UInt16(rest[dataLength]) | UInt16(rest[dataLength + 1]) << 8
            guard expected == received else { throw NovaLinkError.badResponse("checksum mismatch") }
            guard header[3] == mySerial else { continue }   // stale frame from an earlier request
            guard header[2] == 0 else { throw NovaLinkError.nack(header[2], command.address) }
            return data
        }
        throw NovaLinkError.badResponse("no response with serial \(mySerial)")
    }
}

/// Where the register protocol goes: the controller's TCP 5200 or a USB sending card (MCTRL300…).
nonisolated enum NovaEndpoint: Sendable, Hashable {
    case network(String)
    case usb(path: String, baud: Int)

    var isUSB: Bool { if case .usb = self { return true } else { return false } }
    /// Identity of the controller regardless of the baud rate: "ip:192.168.0.10" / "usb:/dev/cu.usbserial-140".
    var key: String {
        switch self {
        case .network(let ip): return "ip:" + ip
        case .usb(let path, _): return "usb:" + path
        }
    }
    var label: String {
        switch self {
        case .network(let ip): return ip
        case .usb(let path, let baud): return "USB \((path as NSString).lastPathComponent) (\(baud) baud)"
        }
    }
}

nonisolated enum NovaLink {
    /// One serial port can only be opened by one session at a time.
    static let serialLock = NSLock()

    /// Same as `run(ip:)` but over a serial port (USB sending cards such as MCTRL300).
    static func run<T: Sendable>(serialPath: String, baud: Int, timeout: Int = 1,
                                 _ body: @escaping @Sendable (NovaSocket) throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try serialLock.withLock {
                let port = try NovaSocket(serialPath: serialPath, baud: baud, timeout: timeout)
                return try body(port)
            }
        }.value
    }

    static func run<T: Sendable>(_ endpoint: NovaEndpoint, timeout: Int = 3,
                                 _ body: @escaping @Sendable (NovaSocket) throws -> T) async throws -> T {
        switch endpoint {
        case .network(let ip): return try await run(ip: ip, timeout: timeout, body)
        case .usb(let path, let baud): return try await run(serialPath: path, baud: baud, timeout: timeout, body)
        }
    }

    /// Opens one TCP 5200 session on a background thread, runs `body`, and closes it.
    static func run<T: Sendable>(ip: String, timeout: Int = 3, _ body: @escaping @Sendable (NovaSocket) throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            let socket = try NovaSocket(host: ip, timeout: timeout)
            return try body(socket)
        }.value
    }
}

/// Counts the receiving cards that actually answer in a port's cable chain: reads register 0 of
/// card 0, 1, 2… (the same read NovaLCT does for every card) until one does not answer.
/// Ground truth — the controller's own card list can be a cached result of an earlier scan.
nonisolated enum CardProbe {
    static func count(ip: String, portIndex: Int, limit: Int = 256) async throws -> Int {
        try await count(.network(ip), portIndex: portIndex, limit: limit)
    }

    static func count(_ endpoint: NovaEndpoint, portIndex: Int, limit: Int = 256) async throws -> Int {
        try await NovaLink.run(endpoint, timeout: 1) { socket in count(socket, portIndex: portIndex, limit: limit) }
    }

    /// Ports (0-based) whose first receiving card answers — "link up" for sending cards without a web
    /// interface, which report no link state of their own.
    static func activePorts(_ endpoint: NovaEndpoint, ports: [Int]) async throws -> Set<Int> {
        try await NovaLink.run(endpoint, timeout: 1) { socket in
            var active = Set<Int>()
            for p in ports {
                if (try? socket.transact(.read(0x0000_0000, length: 2, device: 1, port: UInt8(p), card: 0))) != nil { active.insert(p) }
            }
            return active
        }
    }

    static func count(_ socket: NovaSocket, portIndex: Int, limit: Int = 256) -> Int {
        var n = 0
        while n < limit, ask(socket, 0x0000_0000, length: 2, port: portIndex, card: n) != nil { n += 1 }
        return n
    }

    /// Reads a receiving-card register. A "no such card" answer (non-zero ack — the sending card needs
    /// about 0.25 s for it, measured on MEE410) ends at once; a lost or broken answer is asked again once.
    static func ask(_ socket: NovaSocket, _ register: UInt32, length: Int, port: Int, card: Int) -> [UInt8]? {
        for _ in 0..<2 {
            do {
                let b = try socket.transact(.read(register, length: UInt16(length), device: 1, port: UInt8(port), card: UInt16(card)))
                return b.count == length ? b : nil
            } catch NovaLinkError.nack {
                return nil
            } catch {
                continue
            }
        }
        return nil
    }
}

/// Reads a sending card without a web interface (USB MCTRL…, or any card over TCP 5200) straight
/// from its registers: cards answering on each port, their size (0x02000017 / 0x02000019 — the
/// registers Send to HW writes) and their position from the sending card's coordinate table
/// (0x03000000 + 0x1000·port, UInt32 x | y << 16 per chain position). Size and position are
/// best-effort: nil when the card does not let them be read.
nonisolated enum RegisterInventory {
    struct Card: Sendable, Identifiable, Equatable {
        let port: Int          // 0-based Ethernet port
        let index: Int         // 0-based position in the cable chain
        var width: Int?
        var height: Int?
        var x: Int?
        var y: Int?
        var id: String { "\(port)-\(index)" }
    }

    static func read(_ endpoint: NovaEndpoint, ports: Int, limit: Int = 128, model: String? = nil) async throws -> [Card] {
        try await read(endpoint, portList: Array(0..<ports), limit: limit, model: model)
    }

    /// `model` selects where the sending card keeps each port's area (see `ControllerModels.portBlock`):
    /// the coordinate table holds positions inside the port's area, the area's X/Y is added.
    static func read(_ endpoint: NovaEndpoint, portList: [Int], limit: Int = 128, model: String? = nil) async throws -> [Card] {
        try await NovaLink.run(endpoint, timeout: 1) { socket in
            _ = try socket.transact(.read(0x0000_0002, length: 2))      // link check, throws if silent
            var cards: [Card] = []
            for p in portList {
                // One read per card: width and height (0x02000017…1A) — an answer also means the card is there.
                var sizes: [[UInt8]] = []
                while sizes.count < limit, let b = CardProbe.ask(socket, 0x0200_0017, length: 4, port: p, card: sizes.count) {
                    sizes.append(b)
                }
                let n = sizes.count
                guard n > 0 else { continue }
                let table = try? socket.transact(.read(0x0300_0000 + 0x1000 * UInt32(p), length: UInt16(4 * n)))
                // Port area: [flag, W16, H16, X16, Y16]. Used only when it looks like a real area.
                var originX = 0, originY = 0
                if let block = ControllerModels.portBlock(model: model, port: p),
                   let b = try? socket.transact(.read(block, length: 9)), b.count == 9 {
                    let w = Int(b[1]) + Int(b[2]) * 256, h = Int(b[3]) + Int(b[4]) * 256
                    let x = Int(b[5]) + Int(b[6]) * 256, y = Int(b[7]) + Int(b[8]) * 256
                    if (1...16384).contains(w), (1...16384).contains(h), x + w <= 65535, y + h <= 65535 { originX = x; originY = y }
                }
                for i in 0..<n {
                    var card = Card(port: p, index: i)
                    let b = sizes[i]
                    card.width = Int(b[0]) + Int(b[1]) * 256
                    card.height = Int(b[2]) + Int(b[3]) * 256
                    if let table, table.count >= 4 * (i + 1) {
                        let o = 4 * i
                        card.x = originX + Int(table[o]) + Int(table[o + 1]) * 256
                        card.y = originY + Int(table[o + 2]) + Int(table[o + 3]) * 256
                    }
                    cards.append(card)
                }
            }
            return cards
        }
    }

}

extension RegisterInventory {
    /// Cabinets as a rows × columns grid: every distinct X is a column, every distinct Y a row
    /// (36 cards in 6 × 6 → 6 columns, 6 rows). Places without a card stay unconnected cells.
    /// nil when positions are missing or two cards share a place — then the flat plan below is used.
    @MainActor static func gridPlan(_ cards: [Card], defaultSize: (width: Int, height: Int)) -> ScreenConnectionPlan? {
        guard cards.allSatisfy({ $0.x != nil && $0.y != nil }) else { return nil }
        let xs = Array(Set(cards.map { $0.x! })).sorted(), ys = Array(Set(cards.map { $0.y! })).sorted()
        guard (1...64).contains(xs.count), (1...64).contains(ys.count), xs.count * ys.count <= 1024 else { return nil }
        func w(_ c: Card) -> Int { min((c.width ?? 0) > 0 ? c.width! : defaultSize.width, 8192) }
        func h(_ c: Card) -> Int { min((c.height ?? 0) > 0 ? c.height! : defaultSize.height, 8192) }
        var plan = ScreenConnectionPlan()
        plan.columns = xs.count; plan.rows = ys.count
        var cells: [ScreenConnectionPlan.Cell?] = Array(repeating: nil, count: xs.count * ys.count)
        for card in cards {
            let col = xs.firstIndex(of: card.x!)!, row = ys.firstIndex(of: card.y!)!
            let id = row * xs.count + col
            guard cells[id] == nil else { return nil }
            var cell = ScreenConnectionPlan.Cell(id: id, width: w(card), height: h(card), sender: 1,
                                                 port: card.port + 1, order: card.index + 1)
            cell.x = card.x; cell.y = card.y
            cells[id] = cell
        }
        for id in cells.indices where cells[id] == nil {
            let col = id % xs.count, row = id / xs.count
            let width = cards.filter { $0.x == xs[col] }.map(w).max() ?? defaultSize.width
            let height = cards.filter { $0.y == ys[row] }.map(h).max() ?? defaultSize.height
            var cell = ScreenConnectionPlan.Cell(id: id, width: width, height: height, sender: 1, port: 1, order: nil)
            cell.x = xs[col]; cell.y = ys[row]
            cells[id] = cell
        }
        plan.cells = cells.map { $0! }
        guard (try? plan.validate()) != nil else { return nil }
        return plan
    }

    /// Editable plan from the inventory (one cell per card, exact positions when known).
    @MainActor static func plan(_ cards: [Card], defaultSize: (width: Int, height: Int)) throws -> ScreenConnectionPlan {
        guard !cards.isEmpty else { throw RCFGXError.invalid("No receiving cards answer on any port.") }
        guard cards.count <= 64 else { throw RCFGXError.invalid("More than 64 cards over USB are not supported yet (\(cards.count)).") }
        if let grid = gridPlan(cards, defaultSize: defaultSize) { return grid }
        var plan = ScreenConnectionPlan()
        plan.columns = cards.count; plan.rows = 1
        var nextX = 0
        for (n, card) in cards.enumerated() {
            let w = (card.width ?? 0) > 0 ? card.width! : defaultSize.width
            let h = (card.height ?? 0) > 0 ? card.height! : defaultSize.height
            var cell = ScreenConnectionPlan.Cell(id: n, width: min(w, 8192), height: min(h, 8192), sender: 1,
                                                 port: card.port + 1, order: card.index + 1)
            cell.x = card.x ?? nextX
            cell.y = card.y ?? 0
            nextX = max(nextX, (cell.x ?? 0) + cell.width)
            plan.cells.append(cell)
        }
        try plan.validate()
        return plan
    }
}

/// USB sending cards (CP210x / CH34x / FTDI USB-UART) seen by macOS.
nonisolated enum SerialPorts {
    static func list() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") && ($0.contains("usbserial") || $0.contains("SLAB") || $0.contains("wchusbserial") || $0.contains("usbmodem")) }
            .sorted().map { "/dev/" + $0 }
    }

    struct Identity: Sendable {
        let path: String
        let baud: Int
        let modelID: UInt16
        let extra: [UInt8]
    }

    /// Opens the port and reads the sending card model (register 0x00000002, the first read NovaLCT does),
    /// trying common baud rates until the card answers.
    static func identify(path: String, bauds: [Int] = [115_200, 230_400, 460_800, 921_600, 57_600]) async throws -> Identity {
        var lastError: Error = NovaLinkError.timeout
        for baud in bauds {
            do {
                return try await NovaLink.run(serialPath: path, baud: baud, timeout: 1) { port in
                    let id = try port.transact(.read(0x0000_0002, length: 2))
                    let extra = (try? port.transact(.read(0x0000_0016, length: 8))) ?? []
                    return Identity(path: path, baud: baud, modelID: UInt16(id.first ?? 0) | UInt16(id.count > 1 ? id[1] : 0) << 8, extra: extra)
                }
            } catch { lastError = error }
        }
        throw lastError
    }
}

/// Sending card / controller model from its identification registers (device 0):
///   0x00000000 (u16) hardware ID, 0x00000002 (u16) family ID.
/// Only models verified on real hardware are listed; others can be named by the user (stored per ID).
nonisolated enum ControllerModels {
    struct ID: Hashable, Sendable {
        let hardware: Int      // register 0x00000000
        let family: Int        // register 0x00000002
        var key: String { String(format: "%04X-%04X", hardware, family) }
        var text: String { String(format: "0x%04X / 0x%04X", hardware, family) }
    }

    /// Verified: MCTRL300 over USB (21.10.2026) reads F639 / 0001; VX1000 Pro reads family 0x622B.
    static let byHardware: [Int: String] = [0xF639: "MCTRL300"]
    static let byFamily: [Int: String] = [0x622B: "VX1000 Pro", 0x1113: "MEE410"]   // MEE410: FFFF / 1113 (21.10.2026)

    /// Address of the sending card's area record for port `port` (0-based): flag, W, H, X, Y (u16).
    /// MCTRL300 (captured): 0x02000050 + 9·p. VX Pro (captured): 0x02000050 + 0x13·p.
    /// MEE410 (register dump + NovaLCT read, 21.10.2026): units of 4 ports, 9 bytes each, at
    /// 0x02000050, 0x020000B0, 0x02000130, 0x02000154, 0x02010240, 0x02010264 (ports 1–4 … 21–24).
    static func portBlock(model: String?, port: Int) -> UInt32? {
        let name = model?.uppercased().replacingOccurrences(of: " ", with: "") ?? ""
        if name == "MEE410" {
            let units: [UInt32] = [0x0200_0050, 0x0200_00B0, 0x0200_0130, 0x0200_0154, 0x0201_0240, 0x0201_0264]
            guard port / 4 < units.count else { return nil }
            return units[port / 4] + 9 * UInt32(port % 4)
        }
        if name == "VX1000PRO" { return 0x0200_0050 + 0x13 * UInt32(port) }
        return port < 16 ? 0x0200_0050 + 9 * UInt32(port) : nil
    }

    /// Protocol port numbers (0-based) in the order of the physical connectors, when they differ.
    /// MEE410: the protocol numbers ports in units of 4 and skips some (NovaLCT shows 1–6, 9–14, 17–19, 21–23);
    /// the connectors on the device are numbered 1, 2, 3 … in that same order.
    static func physicalPorts(model: String?) -> [Int]? {
        let name = model?.uppercased().replacingOccurrences(of: " ", with: "") ?? ""
        if name == "MEE410" { return [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 16, 17, 18, 20, 21, 22] }
        return nil
    }

    /// Number printed on the connector for protocol port `index` (0-based).
    static func portLabel(model: String?, index: Int) -> Int {
        if let list = physicalPorts(model: model), let k = list.firstIndex(of: index) { return k + 1 }
        return index + 1
    }

    /// Ethernet outputs per model (NovaStar specifications). nil = unknown → found by probing.
    static func portCount(model: String?) -> Int? {
        guard let model = model?.uppercased().replacingOccurrences(of: " ", with: "") else { return nil }
        let table: [String: Int] = ["MCTRL300": 2, "MCTRL500": 2, "MCTRL600": 4, "MCTRL660": 4, "MCTRL660PRO": 6,
                                    "MCTRL700": 6, "MCTRLR5": 8, "MCTRL4K": 16, "VX1000PRO": 10, "VX600PRO": 6, "VX400PRO": 4,
                                    // MEE410: port numbers in the protocol go in groups of 8 with 6 used
                                    // (0–5, 8–13, 16–21 answer; 6, 7, 14, 15 never do — register dump 21.10.2026),
                                    // so 24 port numbers are searched to reach every connected port.
                                    "MEE410": 24]
        return table[model]
    }

    static func read(_ socket: NovaSocket) throws -> ID {
        func u16(_ b: [UInt8]) -> Int { b.count >= 2 ? Int(b[0]) + Int(b[1]) * 256 : 0 }
        let family = u16(try socket.transact(.read(0x0000_0002, length: 2)))
        let hardware = (try? socket.transact(.read(0x0000_0000, length: 2))).map(u16) ?? 0
        return ID(hardware: hardware, family: family)
    }

    static func identify(_ endpoint: NovaEndpoint) async throws -> ID {
        try await NovaLink.run(endpoint, timeout: 1) { socket in try read(socket) }
    }

    private static let namesKey = "NovaMac.modelNames"

    /// User's name for an ID first, then the verified table.
    static func name(_ id: ID) -> String? {
        if let custom = (UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String])?[id.key], !custom.isEmpty { return custom }
        return byHardware[id.hardware] ?? byFamily[id.family]
    }

    static func setName(_ name: String, for id: ID) {
        var names = (UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String]) ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id.key] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(names, forKey: namesKey)
    }
}

/// Screen brightness — NovaStar's documented command ("VX Pro Series Control Protocol" 3.2.1):
///   write 1 byte (0…255) to register 0x02000001 of the receiving cards: dst FF, device 1, port FF, card FFFF.
/// The same register on MCTRL cards (it is the receiving card that dims; byte 0x01 of its parameter block).
/// A screen that uses only some Ethernet ports is addressed port by port.
nonisolated enum ScreenBrightness {
    static let register: UInt32 = 0x0200_0001

    /// `ports` 0-based; nil = every port of the controller.
    static func set(_ endpoint: NovaEndpoint, value: Int, ports: [Int]?) async throws {
        let byte = UInt8(max(0, min(255, value)))
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            if let ports, !ports.isEmpty {
                for p in ports {
                    try socket.transact(.write(register, [byte], destination: 0xFF, device: 1, port: UInt8(p), card: 0xFFFF))
                }
            } else {
                try socket.transact(.write(register, [byte], destination: 0xFF, device: 1, port: 0xFF, card: 0xFFFF))
            }
        }
    }

    /// Brightness the first receiving card on `port` (0-based) runs now.
    static func get(_ endpoint: NovaEndpoint, port: Int) async throws -> Int? {
        let data = try await NovaLink.run(endpoint, timeout: 1) { socket in
            try socket.transact(.read(register, length: 1, device: 1, port: UInt8(port), card: 0))
        }
        return data.first.map(Int.init)
    }
}
