import SwiftUI

// Sending card EDID (MCTRL series, DVI/HDMI input) — found by observation (USB capture 22.10.2026,
// NovaLCT setting 1920×1080@60, 1280×720@60, 1920×1080@50 on MCTRL300):
//   dev 0, port 0, card 0, register 0x08000000, 256 bytes = a standard VESA EDID block (128 bytes + 128 zero).
//   NovaLCT reads the block, changes only the first Detailed Timing Descriptor (bytes 54…71) and the
//   checksum (byte 127), writes the 256 bytes back and reads them again. No separate "apply" command.
//   Blanking stays as it is in the block (H 160, V 35 on MCTRL300);
//   pixel clock = (W + Hblank) · (H + Vblank) · Hz, rounded down to 10 kHz (matches all four observed values).
//   The block's range-limits descriptor (0xFD) gives the source's limits: on MCTRL300 48–123 Hz, max 170 MHz.

nonisolated enum SenderEDID {
    static let register: UInt32 = 0x0800_0000
    static let length = 256
    static let timingOffset = 54

    struct Timing: Sendable, Equatable {
        var width: Int
        var height: Int
        var hBlank: Int
        var vBlank: Int
        var pixelClock10kHz: Int
        var refresh: Double {
            let total = Double((width + hBlank) * (height + vBlank))
            return total > 0 ? Double(pixelClock10kHz) * 10_000 / total : 0
        }
        var pixelClockMHz: Double { Double(pixelClock10kHz) / 100 }
    }

    struct Limits: Sendable, Equatable {
        var minHz: Int, maxHz: Int, maxPixelClockMHz: Int
    }

    static func isValid(_ edid: [UInt8]) -> Bool {
        edid.count >= 128 && Array(edid[0..<8]) == [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    }

    static func timing(_ edid: [UInt8]) -> Timing? {
        guard isValid(edid) else { return nil }
        let d = Array(edid[timingOffset..<timingOffset + 18])
        let clock = Int(d[0]) | Int(d[1]) << 8
        guard clock > 0 else { return nil }
        return Timing(width: Int(d[2]) | Int(d[4] >> 4) << 8,
                      height: Int(d[5]) | Int(d[7] >> 4) << 8,
                      hBlank: Int(d[3]) | Int(d[4] & 0x0F) << 8,
                      vBlank: Int(d[6]) | Int(d[7] & 0x0F) << 8,
                      pixelClock10kHz: clock)
    }

    /// Range limits descriptor (tag 0xFD) in one of the four 18-byte descriptors.
    static func limits(_ edid: [UInt8]) -> Limits? {
        guard isValid(edid) else { return nil }
        for offset in stride(from: 54, through: 108, by: 18) {
            let d = Array(edid[offset..<offset + 18])
            if d[0] == 0, d[1] == 0, d[3] == 0xFD {
                return Limits(minHz: Int(d[5]), maxHz: Int(d[6]), maxPixelClockMHz: Int(d[9]) * 10)
            }
        }
        return nil
    }

    /// The block with a new first timing; blanking and everything else kept from `base`.
    static func patched(_ base: [UInt8], width: Int, height: Int, refresh: Double) -> [UInt8]? {
        guard let old = timing(base), (1...4095).contains(width), (1...4095).contains(height), refresh > 0 else { return nil }
        let total = Double((width + old.hBlank) * (height + old.vBlank))
        let clock = Int((total * refresh / 10_000).rounded(.down))
        guard clock > 0, clock <= 0xFFFF else { return nil }
        var e = base
        if e.count < length { e += [UInt8](repeating: 0, count: length - e.count) }
        let o = timingOffset
        e[o] = UInt8(clock & 0xFF)
        e[o + 1] = UInt8(clock >> 8)
        e[o + 2] = UInt8(width & 0xFF)
        e[o + 4] = UInt8((width >> 8) << 4) | UInt8((old.hBlank >> 8) & 0x0F)
        e[o + 5] = UInt8(height & 0xFF)
        e[o + 7] = UInt8((height >> 8) << 4) | UInt8((old.vBlank >> 8) & 0x0F)
        var sum = 0
        for i in 0..<127 { sum += Int(e[i]) }
        e[127] = UInt8((256 - sum % 256) % 256)
        return e
    }

    static func read(_ endpoint: NovaEndpoint) async throws -> [UInt8] {
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            try socket.transact(.read(register, length: UInt16(length)))
        }
    }

    /// Writes the block and reads it back. Returns the block the card holds after the write.
    static func write(_ endpoint: NovaEndpoint, _ edid: [UInt8]) async throws -> [UInt8] {
        try await NovaLink.run(endpoint, timeout: 2) { socket in
            try socket.transact(.write(register, edid))
            return try socket.transact(.read(register, length: UInt16(length)))
        }
    }
}

/// "EDID" box on the Screen Connection page — shown for MCTRL sending cards only.
struct SenderEDIDBox: View {
    let endpoint: NovaEndpoint

    @State private var current: [UInt8] = []
    @State private var width = 1920
    @State private var height = 1080
    @State private var refresh = 60.0
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false

    private var timing: SenderEDID.Timing? { SenderEDID.timing(current) }
    private var limits: SenderEDID.Limits? { SenderEDID.limits(current) }

    /// Pixel clock the new values need, with the card's present blanking.
    private var neededMHz: Double? {
        guard let t = timing else { return nil }
        return (Double((width + t.hBlank) * (height + t.vBlank)) * refresh / 10_000).rounded(.down) / 100
    }

    private var warning: String? {
        guard let limits, let mhz = neededMHz else { return nil }
        if mhz > Double(limits.maxPixelClockMHz) {
            return String(format: "Needs %.2f MHz, above the input limit %d MHz — lower the size or Hz.", mhz, limits.maxPixelClockMHz)
        }
        if refresh < Double(limits.minHz) || refresh > Double(limits.maxHz) {
            return "Refresh outside \(limits.minHz)–\(limits.maxHz) Hz of the input."
        }
        return nil
    }

    var body: some View {
        GroupBox("EDID (input resolution)") {
            VStack(alignment: .leading, spacing: 8) {
                if let t = timing {
                    Text("Now: \(t.width) × \(t.height) @ \(String(format: "%.2f", t.refresh)) Hz")
                        .font(.caption)
                    Text(String(format: "Pixel clock %.2f MHz", t.pixelClockMHz))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(busy ? "Reading…" : "Not read").font(.caption).foregroundStyle(.secondary)
                }
                field("Width", value: $width)
                field("Height", value: $height)
                HStack {
                    Text("Hz").frame(width: 44, alignment: .leading)
                    TextField("", value: $refresh, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { apply() }
                }
                if let mhz = neededMHz {
                    Text(String(format: "Needs %.2f MHz", mhz)).font(.caption2).foregroundStyle(.secondary)
                }
                if let warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Read") { load() }
                    Button("Apply") { apply() }.buttonStyle(.borderedProminent)
                        .disabled(timing == nil || warning != nil)
                }
                .disabled(busy)
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
        }
        .help("The resolution the sending card announces to the video source (EDID). The source sees it after Apply.")
        .task(id: endpoint.key) { load() }
    }

    private func field(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).frame(width: 44, alignment: .leading)
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .onSubmit { apply() }
        }
    }

    private func load() {
        guard !busy else { return }
        busy = true
        let target = endpoint
        Task {
            defer { busy = false }
            do {
                let data = try await SenderEDID.read(target)
                guard SenderEDID.isValid(data) else {
                    failed = true; message = "The card returned no valid EDID."; return
                }
                current = data
                if let t = SenderEDID.timing(data) {
                    width = t.width; height = t.height; refresh = (t.refresh * 100).rounded() / 100
                }
                failed = false; message = ""
            } catch {
                failed = true; message = error.localizedDescription
            }
        }
    }

    private func apply() {
        guard !busy, warning == nil else { return }
        guard let block = SenderEDID.patched(current, width: width, height: height, refresh: refresh) else {
            failed = true; message = "Width and height must be 1…4095; read the EDID first."; return
        }
        busy = true
        let target = endpoint
        Task {
            defer { busy = false }
            do {
                let back = try await SenderEDID.write(target, block)
                current = back
                if Array(back.prefix(128)) == Array(block.prefix(128)) {
                    failed = false
                    message = "Sent \(width) × \(height) @ \(refresh.formatted()) Hz. The source should switch now (re-plug the cable if it does not)."
                } else {
                    failed = true
                    message = "Written, but the card reads back a different EDID."
                }
            } catch {
                failed = true; message = error.localizedDescription
            }
        }
    }
}
