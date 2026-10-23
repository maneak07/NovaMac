import SwiftUI

// Test patterns, black screen and freeze on the receiving cards — register protocol (MCTRL… without a web
// interface). Found by observation: USB captures 23.10.2026 on MCTRL300, NovaLCT Screen Control:
//   receiving cards (device 1), card FFFF, parameter block 0x02000000:
//     0x02000100  black screen   FF = black, 00 = picture
//     0x02000101  test pattern   00 normal, 02 red, 03 green, 04 blue, 05 white, 06 horizontal,
//                                07 vertical, 08 slash, 09 256 grayscale, 0A ageing
//     0x02000102  freeze         FF = frozen, 00 = live
//   Pattern:  0x02000101 = code, 0x02000102 = 00, 0x02000100 = 00.
//   Normal:   0x02000102 = 00, 0x02000101 = 01, 0x02000101 = 00, 0x02000100 = 00.
// NovaLCT sent these to port 01 (pattern, black) and port FF (freeze); NovaMac sends them to the ports of the
// chosen screens, or to every port (FF) — the routing the RGB gains (same block) already use on MCTRL300.

nonisolated enum ReceiverTest {
    static let black: UInt32 = 0x0200_0100
    static let pattern: UInt32 = 0x0200_0101
    static let freeze: UInt32 = 0x0200_0102

    enum Pattern: UInt8, CaseIterable, Identifiable, Sendable {
        case normal = 0x00, red = 0x02, green = 0x03, blue = 0x04, white = 0x05
        case horizontal = 0x06, vertical = 0x07, slash = 0x08, grayscale = 0x09, ageing = 0x0A
        var id: UInt8 { rawValue }
        var title: String {
            switch self {
            case .normal: return "Normal"
            case .red: return "Red"
            case .green: return "Green"
            case .blue: return "Blue"
            case .white: return "White"
            case .horizontal: return "Horizontal"
            case .vertical: return "Vertical"
            case .slash: return "Slash"
            case .grayscale: return "256 Grayscale"
            case .ageing: return "Ageing"
            }
        }
    }

    private static func write(_ socket: NovaSocket, _ address: UInt32, _ value: UInt8, ports: [Int]?) throws {
        for p in ports ?? [0xFF] {
            _ = try socket.transact(.write(address, [value], device: 1, port: UInt8(p), card: 0xFFFF))
        }
    }

    static func show(_ endpoint: NovaEndpoint, _ pattern: Pattern, ports: [Int]?) async throws {
        if pattern == .normal { try await normal(endpoint, ports: ports); return }
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            try write(socket, Self.pattern, pattern.rawValue, ports: ports)
            try write(socket, freeze, 0x00, ports: ports)
            try write(socket, black, 0x00, ports: ports)
        }
    }

    /// Back to the picture: no freeze, no pattern, no black.
    static func normal(_ endpoint: NovaEndpoint, ports: [Int]?) async throws {
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            try write(socket, freeze, 0x00, ports: ports)
            try write(socket, pattern, 0x01, ports: ports)
            try write(socket, pattern, 0x00, ports: ports)
            try write(socket, black, 0x00, ports: ports)
        }
    }

    static func setBlack(_ endpoint: NovaEndpoint, ports: [Int]?) async throws {
        try await NovaLink.run(endpoint, timeout: 2) { socket in try write(socket, black, 0xFF, ports: ports) }
    }

    static func setFreeze(_ endpoint: NovaEndpoint, ports: [Int]?) async throws {
        try await NovaLink.run(endpoint, timeout: 2) { socket in try write(socket, freeze, 0xFF, ports: ports) }
    }
}

/// "Test patterns" box on the Brightness page for controllers driven over the register protocol (MCTRL…).
struct ReceiverTestBox: View {
    /// Controllers and their ports (nil = every port), as the Brightness page addresses them.
    let targets: [(NovaEndpoint, [Int]?)]
    let title: (NovaEndpoint) -> String

    @State private var active: ReceiverTest.Pattern = .normal
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(ReceiverTest.Pattern.allCases) { p in
                        Button {
                            run("\(p.title)") { e, ports in try await ReceiverTest.show(e, p, ports: ports) }
                            active = p
                        } label: {
                            HStack(spacing: 6) {
                                swatch(p)
                                Text(p.title).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(active == p ? .accentColor : nil)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        run("Black screen") { e, ports in try await ReceiverTest.setBlack(e, ports: ports) }
                    } label: { Label("Black Screen", systemImage: "rectangle.fill") }
                    Button {
                        run("Freeze") { e, ports in try await ReceiverTest.setFreeze(e, ports: ports) }
                    } label: { Label("Freeze", systemImage: "pause.rectangle") }
                    Button {
                        run("Normal display") { e, ports in try await ReceiverTest.normal(e, ports: ports) }
                        active = .normal
                    } label: { Label("Normal Display", systemImage: "play.rectangle") }
                        .buttonStyle(.borderedProminent)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(failed ? .red : .secondary).textSelection(.enabled)
                }
                Text("Patterns are made by the receiving cards; they stay until Normal Display (not saved — a power cycle clears them).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(6)
            .disabled(busy || targets.isEmpty)
        } label: {
            Text("Test patterns · " + targets.map { title($0.0) }.joined(separator: ", ")).font(.headline)
        }
    }

    @ViewBuilder
    private func swatch(_ p: ReceiverTest.Pattern) -> some View {
        switch p {
        case .red: Circle().fill(.red).frame(width: 9, height: 9)
        case .green: Circle().fill(.green).frame(width: 9, height: 9)
        case .blue: Circle().fill(.blue).frame(width: 9, height: 9)
        case .white: Circle().fill(.white).frame(width: 9, height: 9)
        case .grayscale:
            Circle().fill(LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)).frame(width: 9, height: 9)
        default: EmptyView()
        }
    }

    private func run(_ what: String, _ action: @escaping @Sendable (NovaEndpoint, [Int]?) async throws -> Void) {
        guard !busy else { return }
        busy = true
        let jobs = targets
        Task {
            defer { busy = false }
            var errors: [String] = []
            for (endpoint, ports) in jobs {
                do { try await action(endpoint, ports) } catch { errors.append(title(endpoint) + ": " + error.localizedDescription) }
            }
            failed = !errors.isEmpty
            message = errors.isEmpty ? "\(what) sent." : errors.joined(separator: "\n")
        }
    }
}
