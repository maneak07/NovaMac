import Foundation

// NovaMac v0.8 — Shared Unico API and screen models
// The controller is a test device. This file implements READ + explicitly requested WRITE
// operations only. Neither controller firmware nor receiving-card flash is modified.

// MARK: - Models

struct UnicoScreensResponse: Decodable, Sendable {
    let code: Int
    let message: String?
    let data: UnicoScreenCollection
}

struct UnicoScreenCollection: Decodable, Sendable {
    let list: [UnicoScreen]
}

struct UnicoScreen: Decodable, Identifiable, Sendable {
    let guid: String
    let name: String
    let deviceList: [UnicoScreenDevice]

    var id: String { guid }
    var info: UnicoScreenInfo? { deviceList.first?.screenInfo }

    var displayName: String {
        let directName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directName.isEmpty { return directName }

        let combinedName = info?.combinedScreenInfo?.combinedScreenName ?? ""
        if !combinedName.isEmpty { return combinedName }

        return "Screen \(info?.screenId ?? 0)"
    }
}

struct UnicoScreenDevice: Decodable, Sendable {
    let sn: String
    let screenInfo: UnicoScreenInfo
}

struct UnicoScreenInfo: Decodable, Sendable {
    let screenId: Int
    let select: Int
    let freeze: Int
    let ftb: UnicoFTB
    let mosaic: UnicoMosaic
    let adjustment: UnicoAdjustment
    let combinedScreenInfo: UnicoCombinedInfo?
    let testPattern: UnicoTestPattern?
}

struct UnicoFTB: Decodable, Sendable {
    let enable: Int
    let time: Int?
}

struct UnicoTestPattern: Decodable, Sendable {
    let enable: Int
    let type: Int?
    let bright: Int?
    let grid: Int?
    let gridType: Int?
    let gridLineWidth: Int?
    let speed: Int?
}

// Verified against VX1000 Pro Unico Network and its own pattern table.
struct UnicoTestPatternWrite: Encodable, Sendable, Equatable {
    let enable: Int
    let type: Int
    let bright: Int
    let grid: Int
    let gridType: Int
    let gridLineWidth: Int
    let speed: Int

    init(current: UnicoTestPattern, type: Int?, colorBarSpacing: Int? = nil) throws {
        guard let oldType = current.type, let bright = current.bright,
              let grid = current.grid, let gridType = current.gridType,
              let width = current.gridLineWidth, let speed = current.speed else {
            throw UnicoAPIError.api(-1, "Incomplete test pattern settings; refresh the screen first.")
        }
        if let colorBarSpacing {
            guard type == 5 || type == 6, (1...8).contains(colorBarSpacing) else {
                throw UnicoAPIError.api(-1, "Color bar spacing must be a level from 1 to 8")
            }
        }
        self.enable = type == nil ? 0 : 1
        self.type = type ?? oldType
        self.bright = bright
        // Unico uses pixel spacing for moving lines/grids, gear spacing otherwise.
        // Normal preserves the existing settings exactly.
        let pixelPattern = type.map { (512...518).contains($0) }
        let previousPixelPattern = (512...518).contains(oldType)
        let changedFamily = pixelPattern.map { $0 != previousPixelPattern } ?? false
        let isColorBar = type == 5 || type == 6
        let wasColorBar = oldType == 5 || oldType == 6
        // Physical LED tests: gear 5 can look solid white on a small canvas.
        // Exact pixel spacing is not visually honored for bars on this firmware.
        let spacing: Int
        if isColorBar {
            spacing = colorBarSpacing ?? (wasColorBar && gridType == 0 && (1...8).contains(grid) ? grid : 1)
        } else {
            spacing = changedFamily ? (pixelPattern == true ? 32 : 5) : grid
        }
        self.grid = spacing
        self.gridType = pixelPattern.map { $0 ? 1 : 0 } ?? gridType
        self.gridLineWidth = type == nil ? width : min(max(1, width), min(spacing, 64))
        self.speed = speed
    }

    func confirmed(by current: UnicoTestPattern?) -> Bool {
        guard let current else { return false }
        return current.enable == enable && current.type == type &&
            current.bright == bright && current.grid == grid &&
            current.gridType == gridType && current.gridLineWidth == gridLineWidth &&
            current.speed == speed
    }
}

struct UnicoTestPatternRequest: Encodable, Sendable {
    let testPattern: UnicoTestPatternWrite
    let screenId: Int
}

struct UnicoMosaic: Decodable, Sendable {
    let window: UnicoWindow
}

struct UnicoWindow: Decodable, Sendable {
    let width: Int
    let height: Int
}

struct UnicoAdjustment: Decodable, Sendable {
    let brightness: UnicoBrightnessRatio
}

struct UnicoBrightnessRatio: Decodable, Sendable {
    let ratio: Int
    let ratioScale: Int

    // This is a value in screenInfo.adjustment, not necessarily the
    // actual receiving-card/cabinet brightness used by /cabinet/brightness.
    var displayedPercent: Double? {
        guard ratioScale > 0 else { return nil }
        return 100.0 * Double(ratio) / Double(ratioScale)
    }
}

struct UnicoCombinedInfo: Decodable, Sendable {
    let combinedScreenName: String
}

struct UnicoActionResponse: Decodable, Sendable {
    let code: Int
    let message: String?
}

struct UnicoFreezeRequest: Encodable, Sendable {
    let freeze: Int
    let screenGuidList: [String]
}

struct UnicoFTBRequest: Encodable, Sendable {
    struct Settings: Encodable, Sendable {
        let enable: Int
        let time: Int
    }

    let ftb: Settings
    let screenGuidList: [String]
}

struct UnicoCabinetBrightnessRequest: Encodable, Sendable {
    struct Settings: Encodable, Sendable {
        let ratio: Int
        let ratioScale: Int
        let nitType: Int
    }

    let brightness: Settings
    let guidList: [String]
}

enum UnicoAPIError: LocalizedError {
    case invalidIP
    case invalidURL
    case unexpectedHTTPStatus(Int)
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidIP:
            return "Некорректный IPv4-адрес контроллера."
        case .invalidURL:
            return "Не удалось построить URL Unico API."
        case .unexpectedHTTPStatus(let status):
            return "Неожиданный HTTP status: \(status)."
        case .api(let code, let message):
            return "Unico API code \(code): \(message)"
        }
    }
}

enum ScreenAction: Sendable {
    case freeze(Int)
    case ftb(Int)
    case brightness(Int)

    var description: String {
        switch self {
        case .freeze(let value): return "Freeze \(value == 1 ? "ON" : "OFF")"
        case .ftb(let value): return "FTB \(value == 1 ? "ON" : "OFF")"
        case .brightness(let value): return "Brightness \(value)%"
        }
    }

    func confirmed(in screen: UnicoScreen) -> Bool {
        guard let info = screen.info else { return false }
        switch self {
        case .freeze(let desired): return info.freeze == desired
        case .ftb(let desired): return info.ftb.enable == desired
        case .brightness:
            // /screen/normal-screen has no independently verified field
            // representing actual receiving-card brightness. Do not claim
            // a cabinet brightness write was confirmed from this response.
            return false
        }
    }

    var isBrightness: Bool {
        if case .brightness = self { return true }
        return false
    }
}

// MARK: - Unico API

enum UnicoAPI {
    static let projectID = "defaultProject-vx"

    private static func makeURL(ip: String, path: String, project: Bool = false) throws -> URL {
        let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else {
            throw UnicoAPIError.invalidIP
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = ip
        components.port = 19999
        components.path = path
        if project {
            components.queryItems = [
                URLQueryItem(name: "projectId", value: projectID)
            ]
        }
        guard let url = components.url else { throw UnicoAPIError.invalidURL }
        return url
    }

    static func fetchScreens(ip: String) async throws -> [UnicoScreen] {
        let url = try makeURL(
            ip: ip,
            path: "/unico/v1/ucenter/screen/normal-screen",
            project: true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
        let result = try JSONDecoder().decode(UnicoScreensResponse.self, from: data)
        guard result.code == 0 else {
            throw UnicoAPIError.api(result.code, result.message ?? "Unknown error")
        }

        // The tested VX1000 Pro returned count=0 even with two entries in list.
        return result.data.list
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw UnicoAPIError.unexpectedHTTPStatus(-1)
        }
        guard http.statusCode == 200 else {
            throw UnicoAPIError.unexpectedHTTPStatus(http.statusCode)
        }
    }

    private static func post<T: Encodable>(
        ip: String, path: String, body: T
    ) async throws {
        let url = try makeURL(ip: ip, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
        let result = try JSONDecoder().decode(UnicoActionResponse.self, from: data)
        guard result.code == 0 else {
            throw UnicoAPIError.api(result.code, result.message ?? "Unknown error")
        }
    }

    // Separate PUT transport: the existing Brightness/Freeze/FTB POST path is unchanged.
    static func setTestPattern(
        ip: String, guid: String, screenID: Int, settings: UnicoTestPatternWrite
    ) async throws {
        let url = try makeURL(ip: ip, path: "/unico/v1/screen/test-pattern")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Routing observed on this directly connected VX1000 Pro.
        // No browser Authorization or Cookie is copied or persisted.
        request.setValue(guid, forHTTPHeaderField: "Guid")
        request.setValue(ip, forHTTPHeaderField: "Ip")
        request.setValue("8088", forHTTPHeaderField: "Port")
        request.setValue("http", forHTTPHeaderField: "Protocol")
        request.httpBody = try JSONEncoder().encode([
            UnicoTestPatternRequest(testPattern: settings, screenId: screenID)
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
        let result = try JSONDecoder().decode(UnicoActionResponse.self, from: data)
        guard result.code == 0 else {
            throw UnicoAPIError.api(result.code, result.message ?? "Unknown error")
        }
    }

    // Attempt every reset, so one failed request cannot prevent the others.
    static func restoreNormal(ip: String, screen: UnicoScreen) async throws {
        var failures: [String] = []
        do {
            guard screen.deviceList.count == 1, let info = screen.info,
                  let pattern = info.testPattern else {
                throw UnicoAPIError.api(-1, "Test pattern state unavailable")
            }
            try await setTestPattern(ip: ip, guid: screen.guid, screenID: info.screenId,
                                     settings: UnicoTestPatternWrite(current: pattern, type: nil))
        } catch { failures.append("Test Pattern: \(error.localizedDescription)") }
        do { try await perform(ip: ip, guid: screen.guid, action: .freeze(0)) }
        catch { failures.append("Freeze: \(error.localizedDescription)") }
        do { try await perform(ip: ip, guid: screen.guid, action: .ftb(0)) }
        catch { failures.append("Black: \(error.localizedDescription)") }
        if !failures.isEmpty {
            throw UnicoAPIError.api(-1, "Normal partially failed; refresh to check state. " +
                                    failures.joined(separator: "; "))
        }
    }

    static func brightnessRequest(level: Int, guid: String) throws -> UnicoCabinetBrightnessRequest {
        guard (0...255).contains(level) else {
            throw UnicoAPIError.api(-1, "Brightness must be an integer from 0 to 255")
        }
        // Preserve all 256 input levels; do not round through integer percentages.
        let ratio = Int((Double(level) * 10000.0 / 255.0).rounded())
        return UnicoCabinetBrightnessRequest(
            brightness: .init(ratio: ratio, ratioScale: 10000, nitType: 0), guidList: [guid]
        )
    }

    static func setBrightnessLevel(ip: String, guid: String, level: Int) async throws {
        try await post(ip: ip, path: "/unico/v1/ucenter/cabinet/brightness",
                       body: brightnessRequest(level: level, guid: guid))
    }

    static func perform(ip: String, guid: String, action: ScreenAction) async throws {
        switch action {
        case .freeze(let value):
            try await post(
                ip: ip,
                path: "/unico/v1/ucenter/screen/freeze",
                body: UnicoFreezeRequest(freeze: value, screenGuidList: [guid])
            )
        case .ftb(let value):
            try await post(
                ip: ip,
                path: "/unico/v1/ucenter/screen/ftb",
                body: UnicoFTBRequest(
                    ftb: .init(enable: value, time: 700),
                    screenGuidList: [guid]
                )
            )
        case .brightness(let percent):
            guard (0...100).contains(percent) else {
                throw UnicoAPIError.api(-1, "Brightness must be 0...100%")
            }
            try await post(
                ip: ip,
                path: "/unico/v1/ucenter/cabinet/brightness",
                body: UnicoCabinetBrightnessRequest(
                    brightness: .init(
                        ratio: percent * 100,
                        ratioScale: 10000,
                        nitType: 0
                    ),
                    guidList: [guid]
                )
            )
        }
    }
}

