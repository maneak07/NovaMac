import SwiftUI

// VX Pro device settings over the controller's REST API (Unico, port 19999) — captured from the VX1000 Pro
// web UI in Opera (23.10.2026, vx-settings.har / vx-load.har):
//   Name     GET /unico/v1/node/detail?nodeId=1        → data.general.name
//            PUT /unico/v1/node/general                {"nodeId":1,"general":{"name":"Office"}}
//   Network  GET /unico/v1/node/ethernet?nodeId=1      → data.ethernet {mode, infos[{index, mac, dhcp, ip, netmask, gateway, autoDNS, dns}]}
//            PUT /unico/v1/node/ethernet               {"nodeId":1,"ethernet":{"mode":0,"infos":[{"index":0,"dhcp":0,"netmask":…,"ip":…,"gateway":…,"autoDNS":0,"dns":[]}]}}
//   HDCP     GET /unico/v1/interface/list-detail       → list[] {interfaceId, general.name, hdcp{enable, preset, actual}}
//            PUT /unico/v1/interface/hdcp              [{"interfaceId":2,"hdcp":{"enable":1,"preset":3}}, …]  (the HDMI inputs: 2, 3, 4)

enum VXSettings {
    struct Network: Equatable {
        var dhcp: Bool
        var ip: String
        var netmask: String
        var gateway: String
        var mac: String = ""
        var mode: Int = 0
        var autoDNS: Int = 0
        var dns: [String] = []
    }

    struct HDCPInput: Identifiable, Equatable {
        let id: Int            // interfaceId
        let name: String
        var enable: Bool
        let preset: Int
    }

    static func name(ip: String) async throws -> String {
        let json = try await UnicoSession.shared(ip: ip).get("node/detail", query: ["nodeId": "1"])
        let data = json["data"] as? [String: Any]
        return (data?["general"] as? [String: Any])?["name"] as? String ?? ""
    }

    static func setName(ip: String, _ name: String) async throws {
        try await UnicoSession.shared(ip: ip).send("node/general", method: "PUT",
                                                   json: ["nodeId": 1, "general": ["name": name]])
    }

    static func network(ip: String) async throws -> Network {
        let json = try await UnicoSession.shared(ip: ip).get("node/ethernet", query: ["nodeId": "1"])
        guard let eth = (json["data"] as? [String: Any])?["ethernet"] as? [String: Any],
              let info = (eth["infos"] as? [[String: Any]])?.first else { throw UnicoSession.Failure.badResponse }
        return Network(dhcp: (info["dhcp"] as? Int ?? 0) != 0,
                       ip: info["ip"] as? String ?? "", netmask: info["netmask"] as? String ?? "",
                       gateway: info["gateway"] as? String ?? "", mac: info["mac"] as? String ?? "",
                       mode: eth["mode"] as? Int ?? 0, autoDNS: info["autoDNS"] as? Int ?? 0,
                       dns: info["dns"] as? [String] ?? [])
    }

    static func setNetwork(ip: String, _ n: Network) async throws {
        let info: [String: Any] = ["index": 0, "dhcp": n.dhcp ? 1 : 0, "netmask": n.netmask, "ip": n.ip,
                                   "gateway": n.gateway, "autoDNS": n.autoDNS, "dns": n.dns]
        try await UnicoSession.shared(ip: ip).send("node/ethernet", method: "PUT",
                                                   json: ["nodeId": 1, "ethernet": ["mode": n.mode, "infos": [info]]])
    }

    /// The video inputs whose HDCP the web UI switches (HDMI 1…3 on VX1000 Pro).
    static func hdcp(ip: String) async throws -> [HDCPInput] {
        let json = try await UnicoSession.shared(ip: ip).get("interface/list-detail")
        let list = ((json["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            guard let id = item["interfaceId"] as? Int, let h = item["hdcp"] as? [String: Any] else { return nil }
            let name = (item["general"] as? [String: Any])?["name"] as? String ?? ""
            let upper = name.uppercased()
            guard upper.hasPrefix("HDMI") || upper.hasPrefix("DVI") || upper.hasPrefix("DP") else { return nil }
            return HDCPInput(id: id, name: name, enable: (h["enable"] as? Int ?? 0) != 0, preset: h["preset"] as? Int ?? 0)
        }
    }

    static func setHDCP(ip: String, _ inputs: [HDCPInput], enable: Bool) async throws {
        let body: [[String: Any]] = inputs.map { ["interfaceId": $0.id, "hdcp": ["enable": enable ? 1 : 0, "preset": $0.preset]] }
        try await UnicoSession.shared(ip: ip).send("interface/hdcp", method: "PUT", json: body)
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}

/// Settings sheet for one VX Pro controller (opened from its Dashboard tile).
struct VXSettingsSheet: View {
    let ip: String
    @ObservedObject var device: NovaDevice
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var savedName = ""
    @State private var net = VXSettings.Network(dhcp: false, ip: "", netmask: "", gateway: "")
    @State private var savedNet: VXSettings.Network?
    @State private var inputs: [VXSettings.HDCPInput] = []
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false
    @State private var needsPassword = false
    @State private var password = ""
    @State private var confirmNetwork = false

    private var hdcpOn: Bool { !inputs.isEmpty && inputs.allSatisfy(\.enable) }
    private var networkValid: Bool {
        net.dhcp || (VXSettings.isIPv4(net.ip) && VXSettings.isIPv4(net.netmask) && (net.gateway.isEmpty || VXSettings.isIPv4(net.gateway)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Controller settings · \(device.models["ip:" + ip] ?? "VX") · \(ip)").font(.title3.bold())
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Read") { load() }.disabled(busy)
            }

            GroupBox("Name") {
                HStack {
                    TextField("Controller name", text: $name).textFieldStyle(.roundedBorder).onSubmit(applyName)
                    Button("Apply", action: applyName).disabled(busy || name.isEmpty || name == savedName)
                }.padding(6)
            }

            GroupBox("Network") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Mode", selection: $net.dhcp) {
                        Text("Manual").tag(false)
                        Text("DHCP").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 220)
                    row("IP address", $net.ip)
                    row("Subnet mask", $net.netmask)
                    row("Gateway", $net.gateway)
                    if !net.mac.isEmpty { Text("MAC \(net.mac)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    HStack {
                        Button("Apply") { confirmNetwork = true }
                            .disabled(busy || !networkValid || savedNet == nil || net == savedNet)
                        Button("Reset") { if let savedNet { net = savedNet } }.disabled(net == savedNet)
                        if !networkValid { Text("Enter IPv4 addresses (four numbers 0–255).").font(.caption).foregroundStyle(.orange) }
                    }
                }.padding(6)
            }

            GroupBox("HDCP") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("HDCP on inputs", isOn: Binding(get: { hdcpOn }, set: { applyHDCP($0) }))
                        .toggleStyle(.switch).disabled(busy || inputs.isEmpty)
                    Text(inputs.isEmpty ? "Inputs not read yet." : inputs.map { "\($0.name): \($0.enable ? "on" : "off")" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }

            if needsPassword {
                HStack {
                    SecureField("Controller password (user \(UnicoSession.shared(ip: ip).username))", text: $password)
                        .textFieldStyle(.roundedBorder).onSubmit(login)
                    Button("Log in", action: login).disabled(password.isEmpty)
                }
            }
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(failed ? .red : .secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520)
        .task { load() }
        .alert("Apply network settings to \(ip)?", isPresented: $confirmNetwork) {
            Button("Apply", role: .destructive, action: applyNetwork)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(net.dhcp
                 ? "The controller will take an address from DHCP. NovaMac cannot know it in advance — add the new IP on the Dashboard afterwards."
                 : net.ip == ip ? "Mask \(net.netmask), gateway \(net.gateway)."
                 : "The controller moves to \(net.ip). It must stay reachable from this Mac (same subnet), or it will disappear until the Mac's network matches.")
        }
    }

    private func row(_ title: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            TextField("", text: value).textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 180)
                .disabled(net.dhcp)
        }
    }

    // MARK: Actions

    private func run(_ what: String, _ body: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await body()
                failed = false
                if !what.isEmpty { message = what }
            } catch UnicoSession.Failure.needsPassword {
                needsPassword = true; failed = true; message = "Log in to the controller to change settings."
            } catch {
                failed = true; message = error.localizedDescription
            }
        }
    }

    private func load() {
        run("") {
            let n = try await VXSettings.name(ip: ip)
            let e = try await VXSettings.network(ip: ip)
            let h = try await VXSettings.hdcp(ip: ip)
            name = n; savedName = n
            net = e; savedNet = e
            inputs = h
            message = ""
        }
    }

    private func login() {
        let pw = password
        run("Logged in.") {
            try await UnicoSession.shared(ip: ip).login(password: pw, remember: true)
            needsPassword = false; password = ""
        }
    }

    private func applyName() {
        guard !name.isEmpty, name != savedName else { return }
        let new = name
        run("Name changed to \(new).") {
            try await VXSettings.setName(ip: ip, new)
            savedName = try await VXSettings.name(ip: ip)
            name = savedName
        }
    }

    private func applyHDCP(_ on: Bool) {
        let list = inputs
        run("HDCP \(on ? "on" : "off") on \(list.map(\.name).joined(separator: ", ")).") {
            try await VXSettings.setHDCP(ip: ip, list, enable: on)
            inputs = try await VXSettings.hdcp(ip: ip)
        }
    }

    private func applyNetwork() {
        let target = net, old = ip
        run("") {
            do {
                try await VXSettings.setNetwork(ip: old, target)
            } catch let error as URLError where target.dhcp || target.ip != old {
                // The controller may switch address before it answers: check it at the new address.
                _ = error
            }
            guard !target.dhcp, target.ip != old else {
                savedNet = target
                message = target.dhcp ? "DHCP on. Add the controller's new IP on the Dashboard when it is known." : "Network settings applied."
                return
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            var reached = false
            for _ in 0..<5 where !reached {
                if (try? await VXSettings.name(ip: target.ip)) != nil { reached = true } else { try await Task.sleep(nanoseconds: 2_000_000_000) }
            }
            device.renameIP(old, to: target.ip)
            savedNet = target
            message = reached
                ? "The controller now answers at \(target.ip). The Dashboard entry was moved there."
                : "Sent. The controller does not answer at \(target.ip) yet — if this Mac is on another subnet, change the Mac's network. The Dashboard entry was moved to \(target.ip)."
            if reached { dismiss() }
        }
    }
}
