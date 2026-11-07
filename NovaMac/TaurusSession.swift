import Foundation
import Darwin

// NovaMac — Taurus multimedia players (TB30 …) over TCP 5200.
//
// A Taurus answers the register protocol on TCP 5200, but rejects nearly every register (ack 4 =
// unknown command) until a client is logged in on TCP 16603 (media player login):
//
//   AVON frame: 24-byte header + JSON body (little-endian)
//     0-3   "AVON"                 4-7   sequence number (0 for heartbeats)
//     8-9   type: "OP" heartbeat, "QR" request, "PR" response
//     10-11 subtype (3 for heartbeats, 0 otherwise)
//     12-15 zero                   16-17 body length
//     18-21 zero                   22-23 checksum = sum of bytes 0…21
//   Login:  QR {"sn":"<sending card SN, register 0x16, 8 bytes as hex>","username":"admin","password":"…","loginType":3}
//   Answer: PR {"logined":true,"token":"…",…}
//
// The registers stay open only while that login connection lives (heartbeat every 2 s); after it is
// closed the next read is rejected again. Afterwards the sending card uses the classic MCTRL register map
// (port area 0x02000050 + 9·p). A Taurus takes one client at a time: NovaLCT or ViPlex cannot log in
// while NovaMac holds the session, so the session is closed after `idleSeconds` without use.

nonisolated enum TaurusSession {
    /// Family IDs (register 0x00000002) of Taurus players verified on hardware.
    static let families: [Int: String] = [0x9620: "TB30"]
    static let loginPort: UInt16 = 16603
    static let factoryPassword = "SN2008@+"
    static let idleSeconds: TimeInterval = 90

    private final class Session: @unchecked Sendable {
        var fd: Int32            // -1 once closed; guarded by registryLock
        var lastUse = Date()
        var alive = true
        let lock = NSLock()      // one 5200 session at a time on this player
        init(fd: Int32) { self.fd = fd }
    }

    private enum State { case plain, taurus(Session) }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: State] = [:]
    nonisolated(unsafe) private static var known: Set<String> = []    // IPs seen as Taurus once

    /// True when the IP was identified as a Taurus in this run of the app.
    static func isTaurus(_ ip: String) -> Bool { registryLock.withLock { known.contains(ip) } }

    /// Password for the player at `ip`: stored as "taurus:<ip>" in NovaMac's secrets, else the factory one.
    static func password(for ip: String) -> String {
        let stored = UserDefaults.standard.dictionary(forKey: "NovaMac.secrets") as? [String: String]
        return stored?["taurus:" + ip] ?? factoryPassword
    }

    /// Makes sure the registers of `ip` are open before a 5200 session and returns the lock that keeps
    /// sessions to one Taurus in sequence (nil for any other controller). Blocking; call off the main thread.
    static func prepare(ip: String) throws -> NSLock? {
        registryLock.lock()
        defer { registryLock.unlock() }
        switch registry[ip] {
        case .plain?:
            return nil
        case .taurus(let session)? where session.alive:
            session.lastUse = Date()
            return session.lock
        default:
            break
        }
        guard let identity = probe(ip: ip) else { return nil }   // unreachable: let the real session report it
        guard let sn = identity else { registry[ip] = .plain; return nil }
        known.insert(ip)                          // also when the login below fails: the UI offers the password
        let session = try login(ip: ip, sn: sn)
        registry[ip] = .taurus(session)
        startHeartbeat(ip: ip, session)
        return session.lock
    }

    /// Stores the password for the player at `ip` (empty = factory password again) and drops its session,
    /// so the next access logs in with it.
    static func setPassword(_ password: String, for ip: String) {
        var stored = UserDefaults.standard.dictionary(forKey: "NovaMac.secrets") as? [String: String] ?? [:]
        stored["taurus:" + ip] = password.isEmpty ? nil : password
        UserDefaults.standard.set(stored, forKey: "NovaMac.secrets")
        forget(ip: ip)
    }

    static func hasStoredPassword(_ ip: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: "NovaMac.secrets") as? [String: String])?["taurus:" + ip] != nil
    }

    /// Closes the login of `ip` (if any); the next session logs in again.
    static func forget(ip: String) {
        registryLock.withLock {
            if case .taurus(let session)? = registry[ip] {
                session.alive = false
                if session.fd >= 0 { Darwin.close(session.fd); session.fd = -1 }
            }
            registry[ip] = nil
        }
    }

    /// nil = no answer on 5200; .some(nil) = not a Taurus; .some(sn) = Taurus with that sending-card SN.
    private static func probe(ip: String) -> String?? {
        guard let socket = try? NovaSocket(host: ip, timeout: 2) else { return nil }
        guard let id = try? socket.transact(.read(0x0000_0002, length: 2)), id.count == 2 else { return nil }
        let family = Int(id[0]) | Int(id[1]) << 8
        if families[family] == nil {
            // Unknown family: a Taurus refuses the hardware ID before login and listens on 16603.
            do { _ = try socket.transact(.read(0x0000_0000, length: 2)); return .some(nil) }
            catch NovaLinkError.nack(4, _) { guard canConnect(ip: ip, port: loginPort) else { return .some(nil) } }
            catch { return .some(nil) }
        }
        guard let sn = try? socket.transact(.read(0x0000_0016, length: 8)), sn.count == 8 else { return .some(nil) }
        return .some(sn.map { String(format: "%02X", $0) }.joined())
    }

    // MARK: AVON

    static func frame(sequence: UInt32, type: String, subtype: UInt16, body: [UInt8] = []) -> [UInt8] {
        var h: [UInt8] = Array("AVON".utf8) + NovaBytes.le32(sequence) + Array(type.utf8.prefix(2)) + NovaBytes.le16(subtype)
        h += [0, 0, 0, 0] + NovaBytes.le16(body.count) + [0, 0, 0, 0]
        h += NovaBytes.le16(UInt16(truncatingIfNeeded: h.reduce(0) { $0 + Int($1) }))
        return h + body
    }

    static func loginBody(sn: String, password: String) -> [UInt8] {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return Array("{\"sn\":\(quoted(sn)),\"username\":\"admin\",\"password\":\(quoted(password)),\"loginType\":3}".utf8)
    }

    private static func login(ip: String, sn: String) throws -> Session {
        let fd = try connect(ip: ip, port: loginPort, timeout: 3)
        func fail(_ text: String) -> Error { Darwin.close(fd); return NovaLinkError.failedStep("Taurus login on \(ip): " + text) }
        do {
            try send(fd, frame(sequence: 0, type: "OP", subtype: 3))
            try send(fd, frame(sequence: 1, type: "QR", subtype: 0, body: loginBody(sn: sn, password: password(for: ip))))
            for _ in 0..<16 {
                let header = try receive(fd, 24)
                guard header.starts(with: Array("AVON".utf8)) else { throw fail("unexpected answer") }
                let body = try receive(fd, Int(header[16]) | Int(header[17]) << 8)
                guard header[8] == UInt8(ascii: "P"), header[9] == UInt8(ascii: "R") else { continue }
                let answer = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
                guard answer?["logined"] as? Bool == true else {
                    throw fail("password rejected — set it with Password… on the Dashboard tile")
                }
                return Session(fd: fd)
            }
            throw fail("no answer to the login")
        } catch let error as NovaLinkError {
            if case .failedStep = error { throw error }
            throw fail(error.localizedDescription)
        }
    }

    private static func startHeartbeat(ip: String, _ session: Session) {
        let thread = Thread {
            let beat = frame(sequence: 0, type: "OP", subtype: 3)
            var scratch = [UInt8](repeating: 0, count: 4096)
            while true {
                Thread.sleep(forTimeInterval: 2)
                registryLock.lock()
                // A 5200 session running right now counts as use.
                if session.lock.try() { session.lock.unlock() } else { session.lastUse = Date() }
                let idle = Date().timeIntervalSince(session.lastUse) > idleSeconds
                var ok = session.alive && !idle && (try? send(session.fd, beat)) != nil
                // Throw away what the player sends (its own heartbeats); 0 bytes = connection closed.
                while ok {
                    let n = scratch.withUnsafeMutableBytes { Darwin.recv(session.fd, $0.baseAddress!, 4096, MSG_DONTWAIT) }
                    if n == 0 { ok = false } else if n < 0 { break }
                }
                if !ok {
                    session.alive = false
                    if session.fd >= 0 { Darwin.close(session.fd); session.fd = -1 }
                    if case .taurus(let s)? = registry[ip], s === session { registry[ip] = nil }
                }
                registryLock.unlock()
                if !ok { return }
            }
        }
        thread.name = "NovaMac Taurus heartbeat \(ip)"
        thread.start()
    }

    // MARK: Plain TCP

    private static func canConnect(ip: String, port: UInt16) -> Bool {
        guard let fd = try? connect(ip: ip, port: port, timeout: 2) else { return false }
        Darwin.close(fd)
        return true
    }

    private static func connect(ip: String, port: UInt16, timeout: Int) throws -> Int32 {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { throw NovaLinkError.invalidIP }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw NovaLinkError.socket(errno) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { let e = errno; Darwin.close(fd); throw NovaLinkError.connect(e) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { Darwin.close(fd); throw NovaLinkError.timeout }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { Darwin.close(fd); throw NovaLinkError.connect(err) }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    private static func send(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + offset, bytes.count - offset, 0) }
            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { throw NovaLinkError.closed }
        }
    }

    private static func receive(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress! + offset, count - offset, 0) }
            if n > 0 { offset += n; continue }
            if n == 0 { throw NovaLinkError.closed }
            if errno == EINTR { continue }
            throw errno == EAGAIN ? NovaLinkError.timeout : NovaLinkError.socket(errno)
        }
        return buffer
    }
}
