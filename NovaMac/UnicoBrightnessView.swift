import SwiftUI
import Foundation

// NovaMac v0.8: separate Brightness page, with live controls.

private enum DisplayPattern: String, CaseIterable, Identifiable {
    case off = "Normal"
    case black = "Black"
    case red = "Red"
    case green = "Green"
    case blue = "Blue"
    case white = "White"
    case bars = "Vertical Color Bars"
    case horizontalBars = "Horizontal Color Bars"
    case checker = "Checkerboard"
    case redGradient = "Red Gradient →"
    case greenGradient = "Green Gradient →"
    case blueGradient = "Blue Gradient →"
    case gradient = "Gray Gradient →"
    case redVertical = "Red Gradient ↓"
    case greenVertical = "Green Gradient ↓"
    case blueVertical = "Blue Gradient ↓"
    case grayVertical = "Gray Gradient ↓"
    case horizontalLines = "Horizontal Lines"
    case verticalLines = "Vertical Lines"
    case diagonalDown = "Diagonal Lines ↘"
    case diagonalUp = "Diagonal Lines ↗"
    case grid = "Grid"
    case diagonalGrid = "Diagonal Grid"

    // VX Unico's Dnt / Bur tables; gridType is selected by the API model.
    var typeID: Int? {
        switch self {
        case .off: return nil
        case .black: return 0
        case .red: return 1
        case .green: return 2
        case .blue: return 3
        case .white: return 4
        case .bars: return 5
        case .horizontalBars: return 6
        case .checker: return 7
        case .redGradient: return 256
        case .greenGradient: return 257
        case .blueGradient: return 258
        case .gradient: return 259
        case .redVertical: return 260
        case .greenVertical: return 261
        case .blueVertical: return 262
        case .grayVertical: return 263
        case .horizontalLines: return 512
        case .verticalLines: return 513
        case .diagonalDown: return 514
        case .diagonalUp: return 515
        case .grid: return 516
        case .diagonalGrid: return 517
        }
    }
    var id: String { rawValue }
}


struct UnicoBrightnessView: View {
    let ip: String

    @State private var screens: [UnicoScreen] = []
    @State private var loading = false
    @State private var hasLoaded = false
    @State private var writingScreen: String?
    @State private var errorMessage: String?
    @State private var actionMessage: String?
    @State private var noticeMessage: String?
    @State private var progressMessage: String?
    @State private var lastRefresh: Date?
    @State private var autoRefresh = true
    // Live brightness: one serialized, coalescing POST stream per screen.
    // Interim slider positions are applied while dragging; the exact final
    // value is explicitly POSTed again upon release.
    @State private var brightnessInput: [String: String] = [:]
    @State private var brightnessInputErrors: [String: String] = [:]
    // Brightness queue values use 0...255; the slider displays their percentage.
    @State private var brightnessDrafts: [String: Int] = [:]
    @State private var brightnessDragging: Set<String> = []
    @State private var brightnessPending: [String: Int] = [:]
    @State private var brightnessFinal: [String: Int] = [:]
    @State private var brightnessRunners: [String: Task<Void, Never>] = [:]
    @State private var brightnessAcknowledged: [String: Int] = [:]
    @State private var brightnessLastSendAt: [String: Date] = [:]
    @State private var brightnessStatuses: [String: String] = [:]
    @State private var brightnessErrors: [String: String] = [:]

    private var orderedScreens: [UnicoScreen] {
        screens.filter { $0.info?.select == 1 } + screens.filter { $0.info?.select != 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Brightness & Display Control", systemImage: "sun.max")
                .font(.headline)

                Spacer()

                Toggle("Auto Refresh (5 s)", isOn: $autoRefresh)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
                    .fixedSize()

                if loading { ProgressView().controlSize(.small) }

                Button {
                    Task { await refreshScreens() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(loading || writingScreen != nil || !brightnessRunners.isEmpty)
            }

            HStack(spacing: 10) {
                Text("Unico REST API · Project: \(UnicoAPI.projectID)")
                Spacer()
                if let lastRefresh {
                    Text("Last read: \(lastRefresh.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let actionMessage {
                Label(actionMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            }

            if let noticeMessage {
                Label(noticeMessage, systemImage: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let progressMessage {
                Label(progressMessage, systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.yellow)
                    .textSelection(.enabled)
            }

            if hasLoaded && screens.isEmpty && errorMessage == nil {
                Text("No screen objects returned.")
                    .foregroundStyle(.secondary)
            }

            ForEach(orderedScreens) { screen in
                screenControlCard(screen)
                    .id("\(ip)/\(screen.guid)")
            }

            Label(
                "TEST MODE · Brightness / Freeze / FTB send real POST commands. " +
                "Test Pattern / Normal send real PUT commands. " +
                "Flash persistence is not verified.",
                systemImage: "exclamationmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .task(id: ip) {
            await refreshScreens()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    break
                }
                if autoRefresh && !loading && writingScreen == nil &&
                    brightnessRunners.isEmpty && brightnessDragging.isEmpty {
                    await refreshScreens(silent: true)
                }
            }
        }
    }

    // Brightness is the single home for brightness, Freeze, FTB and patterns.
    private func screenControlCard(_ screen: UnicoScreen) -> some View {
        UnicoScreenCard(screen: screen, initiallyExpanded: screen.guid == orderedScreens.first?.guid) {
            VStack(alignment: .leading, spacing: 16) {
                if let info = screen.info {
                    HStack {
                        Label("Screen \(info.screenId)", systemImage: "display")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(info.mosaic.window.width) × \(info.mosaic.window.height)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    brightnessControl(screen: screen, info: info)

                    Divider()
                    Text("Display Control")
                        .font(.headline)
                    actionControl(
                        label: "Freeze",
                        isEnabled: info.freeze != 0,
                        screen: screen,
                        action: .freeze(info.freeze == 0 ? 1 : 0),
                        onIcon: "pause.circle.fill",
                        offIcon: "play.circle"
                    )
                    actionControl(
                        label: "Fade to Black",
                        isEnabled: info.ftb.enable != 0,
                        screen: screen,
                        action: .ftb(info.ftb.enable == 0 ? 1 : 0),
                        onIcon: "moon.fill",
                        offIcon: "moon"
                    )
                    Text("FTB transition: 700 ms")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.65))

                    Divider()
                    patternControl(screen: screen, info: info)
                } else {
                    Text("Screen details unavailable")
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
        }
    }

    // Highlight only state returned by the controller, never an optimistic selection.
    private func patternControl(screen: UnicoScreen, info: UnicoScreenInfo) -> some View {
        let selected: DisplayPattern? = info.testPattern.flatMap { current in
            current.enable == 0 ? .off : DisplayPattern.allCases.first { $0.typeID == current.type }
        }
        let busy = loading || writingScreen != nil || !brightnessRunners.isEmpty ||
            !brightnessDragging.isEmpty
        let blocked = info.freeze != 0 || info.ftb.enable != 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Test Patterns", systemImage: "square.grid.3x3.square")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await sendPattern(.off, for: screen) }
                } label: {
                    Label("Normal", systemImage: "play.display")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || screen.deviceList.count != 1)
                .help("Disable Test Pattern, Freeze and Fade to Black")
            }

            if let pattern = info.testPattern {
                HStack {
                    Text("Controller: " + (pattern.enable == 0 ? "Off" : "On"))
                    Spacer()
                    Text("Raw type: \(pattern.type.map { String($0) } ?? "—")")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                if pattern.enable != 0 {
                    HStack(spacing: 16) {
                        if let bright = pattern.bright {
                            Text("Bright raw: \(bright)")
                        }
                        if let grid = pattern.grid {
                            Text("Grid raw: \(grid)")
                        }
                        if let speed = pattern.speed {
                            Text("Speed raw: \(speed)")
                        }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("Pattern status unavailable via this GET response.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if blocked {
                Label("Disable Freeze and FTB before using a real test pattern.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Select a test pattern, or Normal to return to the input image.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                ForEach(DisplayPattern.allCases.filter { $0 != .off }) { pattern in
                    Button {
                        Task { await sendPattern(pattern, for: screen) }
                    } label: {
                        VStack(spacing: 7) {
                            patternThumbnail(pattern)
                                .frame(height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(pattern.rawValue)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                        .padding(7)
                        .frame(maxWidth: .infinity)
                        .background(
                            selected == pattern ? Color.blue.opacity(0.22) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(selected == pattern ? Color.blue : Color.clear, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || info.testPattern == nil ||
                              screen.deviceList.count != 1 || (blocked && pattern != .off))
                }
            }

            if let pattern = info.testPattern, pattern.enable == 1,
               pattern.type == 5 || pattern.type == 6 {
                Picker("Color bar spacing", selection: Binding(
                    get: { min(8, max(1, pattern.grid ?? 1)) },
                    set: { level in
                        let selected: DisplayPattern = pattern.type == 5 ? .bars : .horizontalBars
                        Task { await sendPattern(selected, for: screen, colorBarSpacing: level) }
                    }
                )) {
                    ForEach(1...8, id: \.self) { level in
                        Text("Level \(level)").tag(level)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300)
                .disabled(busy || blocked)
                Text("Higher levels make wider bars. Built-in bars may repeat or be cropped; exact fit is not available here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Normal turns off Test Pattern, Freeze and Black.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func patternThumbnail(_ pattern: DisplayPattern) -> some View {
        switch pattern {
        case .off: Color.clear
        case .black: Color.black
        case .white: Color.white
        case .red: Color.red
        case .green: Color.green
        case .blue: Color.blue
        case .bars, .horizontalBars:
            let colors: [Color] = [.white, .yellow, .cyan, .green,
                                  Color(red: 1, green: 0, blue: 1), .red, .blue, .black]
            if pattern == .bars {
                HStack(spacing: 0) { ForEach(colors.indices, id: \.self) { colors[$0] } }
            } else {
                VStack(spacing: 0) { ForEach(colors.indices, id: \.self) { colors[$0] } }
            }
        case .checker:
            VStack(spacing: 0) {
                HStack(spacing: 0) { Color.black; Color.white }
                HStack(spacing: 0) { Color.white; Color.black }
            }
        case .redGradient, .greenGradient, .blueGradient, .gradient,
             .redVertical, .greenVertical, .blueVertical, .grayVertical:
            let vertical = (260...263).contains(pattern.typeID ?? 0)
            let color: Color = [.redGradient, .redVertical].contains(pattern) ? .red :
                [.greenGradient, .greenVertical].contains(pattern) ? .green :
                [.blueGradient, .blueVertical].contains(pattern) ? .blue : .white
            LinearGradient(colors: [.black, color],
                           startPoint: vertical ? .top : .leading,
                           endPoint: vertical ? .bottom : .trailing)
        case .horizontalLines, .verticalLines, .diagonalDown, .diagonalUp, .grid, .diagonalGrid:
            Canvas { context, size in
                var path = Path()
                let step: CGFloat = 12
                if pattern == .horizontalLines || pattern == .grid {
                    for y in stride(from: CGFloat(0), through: size.height, by: step) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                if pattern == .verticalLines || pattern == .grid {
                    for x in stride(from: CGFloat(0), through: size.width, by: step) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                }
                for x in stride(from: -size.height, through: size.width + size.height, by: step) {
                    if pattern == .diagonalDown || pattern == .diagonalGrid {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    }
                    if pattern == .diagonalUp || pattern == .diagonalGrid {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x - size.height, y: size.height))
                    }
                }
                context.stroke(path, with: .color(.white), lineWidth: 1)
            }
            .background(Color.black)
        }
    }

    private func actionControl(
        label: String,
        isEnabled: Bool,
        screen: UnicoScreen,
        action: ScreenAction,
        onIcon: String,
        offIcon: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(isEnabled ? "ON" : "OFF")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isEnabled ? Color.orange : Color.secondary)
            if writingScreen == screen.guid {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await sendAction(action, for: screen) }
            } label: {
                Label(isEnabled ? "Turn OFF" : "Turn ON",
                      systemImage: isEnabled ? onIcon : offIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(loading || writingScreen != nil || !brightnessRunners.isEmpty)
        }
        .font(.system(size: 12))
        .padding(.vertical, 3)
    }

    private func brightnessControl(
        screen: UnicoScreen,
        info: UnicoScreenInfo
    ) -> some View {
        let guid = screen.guid
        let chosen = brightnessDrafts[guid] ?? brightnessAcknowledged[guid] ?? 128
        let dragging = brightnessDragging.contains(guid)
        let sending = brightnessRunners[guid] != nil

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Cabinet Brightness · Live", systemImage: "sun.max")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if sending {
                    ProgressView().controlSize(.small)
                }
                Text("\((Double(chosen) * 100 / 255).formatted(.number.precision(.fractionLength(1))))%")
                    .font(.system(.subheadline, design: .monospaced).bold())
            }

            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: {
                            Double(brightnessDrafts[guid] ??
                                   brightnessAcknowledged[guid] ?? 128) * 100 / 255
                        },
                        set: { newValue in
                            let value = min(255, max(0, Int((newValue * 255 / 100).rounded())))
                            brightnessInput.removeValue(forKey: guid)
                            brightnessInputErrors.removeValue(forKey: guid)
                            if brightnessDrafts[guid] != value {
                                brightnessDrafts[guid] = value
                                // Only user interaction sends writes, not GET updates.
                                if brightnessDragging.contains(guid) {
                                    queueBrightness(value, for: guid, final: false)
                                }
                            }
                        }
                    ),
                    in: 0...100,
                    step: 100.0 / 255.0,
                    onEditingChanged: { editing in
                        if editing {
                            brightnessInput.removeValue(forKey: guid)
                            brightnessInputErrors.removeValue(forKey: guid)
                            brightnessDragging.insert(guid)
                            brightnessFinal.removeValue(forKey: guid)
                        } else {
                            brightnessDragging.remove(guid)
                            // Do not rely on the last preview request: always POST
                            // the precise slider value again on release.
                            let finalValue = brightnessDrafts[guid] ??
                                brightnessAcknowledged[guid] ?? 128
                            queueBrightness(finalValue, for: guid, final: true)
                        }
                    }
                )
                .disabled(loading || writingScreen != nil)
                .accessibilityLabel("Cabinet brightness, \(screen.displayName)")

                TextField("0–255", text: Binding(
                    get: { brightnessInput[guid] ?? String(chosen) },
                    set: {
                        brightnessInput[guid] = $0
                        brightnessInputErrors.removeValue(forKey: guid)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .onSubmit { submitBrightness(for: guid) }
                .disabled(loading || writingScreen != nil || dragging)
                .accessibilityLabel("Brightness 0 to 255, \(screen.displayName)")
                .help("Enter an integer from 0 to 255 and press Return")
                Text("/ 255")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let inputError = brightnessInputErrors[guid] {
                Text(inputError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }


            HStack {
                Text(dragging ? "Live adjustment…" :
                    (sending ? "Sending final value…" : "Drag or enter 0–255, then press Return"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let last = brightnessAcknowledged[guid] {
                    Text("Last API ACK: \(last)/255")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if let status = brightnessStatuses[guid] {
                Label(status, systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            }
            if let error = brightnessErrors[guid] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if brightnessDrafts[guid] == nil && brightnessAcknowledged[guid] == nil {
                Text("Initial brightness (128/255) is a placeholder, not device readback.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if let percent = info.adjustment.brightness.displayedPercent {
                Text("Screen adjustment GET: " +
                     "\(percent.formatted(.number.precision(.fractionLength(0...2))))%. " +
                     "Not a verified cabinet brightness measurement.")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary.opacity(0.65))
            }

            Text("Preview POSTs are throttled to ~6 per second; " +
                 "release sends an exact final POST. " +
                 "Flash persistence is NOT verified.")
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.65))
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func sendPattern(_ pattern: DisplayPattern, for screen: UnicoScreen,
                             colorBarSpacing: Int? = nil) async {
        guard !loading, writingScreen == nil, brightnessRunners.isEmpty,
              brightnessDragging.isEmpty else { return }
        let sessionIP = ip
        writingScreen = screen.guid
        errorMessage = nil
        actionMessage = nil
        noticeMessage = nil
        progressMessage = "Reading current pattern settings…"
        var accepted = false
        defer {
            writingScreen = nil
            progressMessage = nil
        }
        do {
            // Preserve current pattern parameters, including settings changed in Unico.
            let latest = try await UnicoAPI.fetchScreens(ip: sessionIP)
            guard ip == sessionIP else { return }
            guard let current = latest.first(where: { $0.guid == screen.guid }),
                  current.deviceList.count == 1,
                  let info = current.info, let previous = info.testPattern else {
                throw UnicoAPIError.api(-1, "A single-device screen with test pattern settings is required.")
            }
            guard pattern == .off || (info.freeze == 0 && info.ftb.enable == 0) else {
                throw UnicoAPIError.api(-1, "Disable Freeze and FTB before enabling a test pattern.")
            }
            let settings = try UnicoTestPatternWrite(current: previous, type: pattern.typeID,
                                                     colorBarSpacing: colorBarSpacing)
            progressMessage = "Sending \(pattern.rawValue)…"
            if pattern == .off {
                try await UnicoAPI.restoreNormal(ip: sessionIP, screen: current)
            } else {
                try await UnicoAPI.setTestPattern(
                    ip: sessionIP, guid: current.guid, screenID: info.screenId, settings: settings
                )
            }
            accepted = true
            for delay: UInt64 in [0, 250_000_000, 500_000_000, 1_000_000_000] {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                guard ip == sessionIP else { return }
                progressMessage = "Reading controller state…"
                let readback = try await UnicoAPI.fetchScreens(ip: sessionIP)
                guard ip == sessionIP else { return }
                screens = readback
                lastRefresh = Date()
                hasLoaded = true
                if let updated = readback.first(where: { $0.guid == screen.guid }),
                   settings.confirmed(by: updated.info?.testPattern),
                   pattern != .off || (updated.info?.freeze == 0 && updated.info?.ftb.enable == 0) {
                    actionMessage = "\(screen.displayName): \(pattern.rawValue) — verified by GET"
                    return
                }
            }
            noticeMessage = "\(pattern.rawValue): Commands accepted, but state was not confirmed. Try Refresh."
        } catch {
            guard ip == sessionIP else { return }
            errorMessage = accepted
                ? "Commands accepted, but verification failed: \(error.localizedDescription)"
                : "Pattern request failed or timed out; final state unknown: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func submitBrightness(for guid: String) {
        guard !loading, writingScreen == nil, !brightnessDragging.contains(guid),
              let input = brightnessInput[guid] else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let level = Int(trimmed), (0...255).contains(level) else {
            brightnessInputErrors[guid] = "Enter a whole number from 0 to 255."
            return
        }
        brightnessDrafts[guid] = level
        brightnessInput.removeValue(forKey: guid)
        brightnessInputErrors.removeValue(forKey: guid)
        queueBrightness(level, for: guid, final: true)
    }

    // MARK: - Live brightness POST queue
    // Coalesces slider events and avoids overlapping writes to the same screen.
    // The queue is independent of the Freeze/FTB request path.

    @MainActor
    private func queueBrightness(_ level: Int, for guid: String, final: Bool) {
        guard (0...255).contains(level) else { return }
        brightnessPending[guid] = level
        if final {
            brightnessFinal[guid] = level
            brightnessStatuses.removeValue(forKey: guid)
        } else {
            // A resumed drag supersedes an older final request not yet sent.
            brightnessFinal.removeValue(forKey: guid)
        }
        brightnessErrors.removeValue(forKey: guid)

        guard brightnessRunners[guid] == nil else { return }
        let sessionIP = ip
        brightnessRunners[guid] = Task { @MainActor in
            await drainBrightnessQueue(guid: guid, ip: sessionIP)
        }
    }

    @MainActor
    private func drainBrightnessQueue(guid: String, ip: String) async {
        defer { brightnessRunners.removeValue(forKey: guid) }

        while !Task.isCancelled {
            guard brightnessPending[guid] != nil else { break }

            // Enforce at least 160 ms between POST starts even when the prior
            // writer task finished before the next slider event arrived.
            if let previous = brightnessLastSendAt[guid] {
                let remaining = 0.16 - Date().timeIntervalSince(previous)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds:
                        UInt64(remaining * 1_000_000_000))
                }
            }

            // Take the newest coalesced value only AFTER the throttle delay.
            guard let level = brightnessPending.removeValue(forKey: guid) else {
                continue
            }

            // The stream runs serially. No new write for this GUID starts
            // before its previous POST completes.
            let isFinal = brightnessFinal[guid] == level &&
                !brightnessDragging.contains(guid)

            brightnessLastSendAt[guid] = Date()
            do {
                try await UnicoAPI.setBrightnessLevel(ip: ip, guid: guid, level: level)
                brightnessAcknowledged[guid] = level
                brightnessErrors.removeValue(forKey: guid)

                if isFinal && brightnessFinal[guid] == level &&
                    brightnessPending[guid] == nil {
                    brightnessFinal.removeValue(forKey: guid)
                    brightnessStatuses[guid] =
                        "Final \(level)/255 accepted by Unico API. " +
                        "Nonvolatile save not verified."
                }
            } catch {
                // With a network timeout the controller might have applied
                // the value; do not falsely claim it was rejected.
                brightnessErrors[guid] =
                    "\(isFinal ? "Final" : "Live") \(level)/255: " +
                    "API result uncertain (\(error.localizedDescription))."
                if isFinal && brightnessFinal[guid] == level {
                    brightnessFinal.removeValue(forKey: guid)
                }
            }

            // If a final release arrived during an in-flight preview, make
            // sure that final value is still POSTed after the preview.
            if let final = brightnessFinal[guid],
               brightnessPending[guid] == nil,
               !brightnessDragging.contains(guid) {
                brightnessPending[guid] = final
            }

        }
    }

    // MARK: - GET, including auto refresh

    @MainActor
    private func refreshScreens(silent: Bool = false) async {
        guard !loading && writingScreen == nil &&
              brightnessRunners.isEmpty && brightnessDragging.isEmpty else { return }
        loading = true
        if !silent {
            errorMessage = nil
            actionMessage = nil
            noticeMessage = nil
            progressMessage = nil
        }
        defer {
            loading = false
            hasLoaded = true
        }

        do {
            screens = try await UnicoAPI.fetchScreens(ip: ip)
            lastRefresh = Date()
        } catch {
            // Preserve last known cards. Auto-refresh does not wipe the last
            // command result or generate transient error banners every 5 sec.
            if !silent {
                errorMessage = "Reading screens: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - WRITE + GET verification

    @MainActor
    private func sendAction(_ action: ScreenAction, for screen: UnicoScreen) async {
        guard !loading, writingScreen == nil,
              brightnessRunners.isEmpty && brightnessDragging.isEmpty else { return }

        writingScreen = screen.guid
        errorMessage = nil
        actionMessage = nil
        noticeMessage = nil
        progressMessage = "Sending \(action.description) to \(screen.displayName)…"
        var accepted = false

        defer {
            writingScreen = nil
            progressMessage = nil
        }

        do {
            try await UnicoAPI.perform(ip: ip, guid: screen.guid, action: action)
            accepted = true
            progressMessage = "POST accepted. Reading controller state…"

            // Allow the controller time to apply commands asynchronously.
            let delays: [UInt64] = action.isBrightness
                ? [0, 350_000_000, 750_000_000]
                : [0, 250_000_000, 500_000_000, 1_000_000_000,
                   1_500_000_000, 2_500_000_000]
            var lastScreen: UnicoScreen?
            var readError: String?

            for (index, delay) in delays.enumerated() {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                progressMessage = "Read-back \(index + 1)/\(delays.count)…"

                do {
                    let newScreens = try await UnicoAPI.fetchScreens(ip: ip)
                    screens = newScreens
                    lastRefresh = Date()
                    hasLoaded = true
                    readError = nil
                    lastScreen = newScreens.first(where: { $0.guid == screen.guid })

                    if let current = lastScreen, action.confirmed(in: current) {
                        actionMessage = "\(screen.displayName): \(action.description) — verified by GET"
                        return
                    }
                } catch {
                    readError = error.localizedDescription
                }
            }

            if action.isBrightness {
                // The documented cabinet write has no confirmed readback in
                // /screen/normal-screen. An API acknowledgement is not physical
                // validation, especially on a controller without LED cabinets.
                if let lastScreen {
                    let percent = lastScreen.info?.adjustment.brightness.displayedPercent
                    let note = percent.map {
                        " Screen adjustment reads \($0.formatted(.number.precision(.fractionLength(0...2))))%."
                    } ?? ""
                    noticeMessage = "\(screen.displayName): \(action.description) — POST accepted. " +
                                    "Cabinet brightness is NOT verified." + note
                    brightnessDrafts.removeValue(forKey: screen.guid)
                } else {
                    errorMessage = "POST accepted, but no screen state was read back. " +
                                   (readError ?? "Try Refresh.")
                }
                return
            }

            if let current = lastScreen?.info {
                let observed: String
                switch action {
                case .freeze: observed = "Freeze=\(current.freeze)"
                case .ftb: observed = "FTB=\(current.ftb.enable)"
                case .brightness: observed = "n/a"
                }
                errorMessage = "POST accepted, but \(action.description) was not confirmed " +
                               "after \(delays.count) reads (\(observed)). Try Refresh."
            } else {
                errorMessage = "POST accepted, but read-back was unavailable: " +
                               (readError ?? "screen not found")
            }
        } catch {
            errorMessage = accepted
                ? "POST accepted but verification stopped: \(error.localizedDescription)"
                : "Write request failed or timed out; final state unknown: \(error.localizedDescription)"
        }
    }
}
