import SwiftUI
import UniformTypeIdentifiers

// NovaMac — register dump of a sending card and its receiving cards, for working out an unknown model
// (port layout, coordinate tables). Reads only.

nonisolated enum SenderDump {
    static func hex(_ bytes: [UInt8], base: UInt32) -> String {
        var lines: [String] = []
        for o in stride(from: 0, to: bytes.count, by: 16) {
            let row = bytes[o..<min(o + 16, bytes.count)].map { String(format: "%02X", Int($0)) }.joined(separator: " ")
            lines.append(String(format: "%08X  ", Int(base) + o) + row)
        }
        return lines.joined(separator: "\n")
    }

    static func run(_ endpoint: NovaEndpoint, ports: Int) async -> String {
        (try? await NovaLink.run(endpoint, timeout: 2) { socket -> String in
            var out: [String] = ["NovaMac register dump · \(endpoint.label) · \(Date())"]
            func read(_ address: UInt32, _ length: Int, device: UInt8 = 0, port: UInt8 = 0, card: UInt16 = 0) -> String {
                var bytes: [UInt8] = []
                var offset = 0
                while offset < length {
                    let n = min(256, length - offset)
                    do { bytes += try socket.transact(.read(address + UInt32(offset), length: UInt16(n), device: device, port: port, card: card)) }
                    catch { return String(format: "%08X  ", Int(address) + offset) + "error: \(error.localizedDescription)" }
                    offset += n
                }
                return hex(bytes, base: address)
            }
            out.append("\n== sending card: IDs 0x00000000 (32)\n" + read(0x0000_0000, 32))
            out.append("\n== sending card: 0x02000000 (1024) — screen / port blocks\n" + read(0x0200_0000, 1024))
            out.append("\n== sending card: 0x03100000 (1024) — card count per port\n" + read(0x0310_0000, 1024))
            for p in 0..<ports {
                out.append("\n== sending card: coordinate table port \(p + 1) 0x\(String(format: "%08X", 0x0300_0000 + 0x1000 * p)) (64)\n"
                           + read(0x0300_0000 + 0x1000 * UInt32(p), 64))
            }
            out.append("\n== receiving cards: register 0x00000000 per port, cards 1–4")
            for p in 0..<ports {
                var line = "port \(p + 1):"
                for c in 0..<4 {
                    do {
                        let b = try socket.transact(.read(0x0000_0000, length: 2, device: 1, port: UInt8(p), card: UInt16(c)))
                        line += " c\(c + 1)=" + b.map { String(format: "%02X", Int($0)) }.joined()
                    } catch {
                        line += " c\(c + 1)=" + {
                            if case NovaLinkError.nack(let code, _) = error { return String(format: "NACK%02X", Int(code)) }
                            if case NovaLinkError.timeout = error { return "timeout" }
                            return "err"
                        }()
                    }
                }
                out.append(line)
            }
            return out.joined(separator: "\n")
        }) ?? "Dump failed: the controller does not answer."
    }
}

struct SenderDumpView: View {
    let endpoint: NovaEndpoint
    let ports: Int
    @State private var text = ""
    @State private var busy = false
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Dump registers of \(endpoint.label)") {
                    busy = true
                    Task { @MainActor in
                        text = await SenderDump.run(endpoint, ports: ports)
                        busy = false
                    }
                }
                .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if !text.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button("Save…") { exporting = true }
                }
            }
            if !text.isEmpty {
                ScrollView {
                    Text(text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 260)
            }
        }
        .fileExporter(isPresented: $exporting, document: RCFGXExportDocument(data: Data(text.utf8)), contentType: .plainText,
                      defaultFilename: "novamac-dump.txt") { _ in }
    }
}
