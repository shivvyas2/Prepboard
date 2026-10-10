import SwiftUI
import UniformTypeIdentifiers

/// Illustrated avatars drawn in the app palette. Same specs as the web app's `AV` list.
struct AvatarSpec {
    enum Style { case fringe, bun, curly, long, short, bald }
    let bg: UInt32, skin: UInt32, hair: UInt32, style: Style, shirt: UInt32

    static let all: [AvatarSpec] = [
        .init(bg: 0x1F4FD8, skin: 0xF2D3B3, hair: 0x2B2410, style: .fringe, shirt: 0xF7C744),
        .init(bg: 0xF7C744, skin: 0xD9A47A, hair: 0x1D1A16, style: .bun, shirt: 0x1F4FD8),
        .init(bg: 0xE5EBFB, skin: 0xA86B45, hair: 0x1D1A16, style: .curly, shirt: 0x1F4FD8),
        .init(bg: 0xFDF2CF, skin: 0xF2D3B3, hair: 0xC2410C, style: .long, shirt: 0x2F7D4F),
        .init(bg: 0x1D1A16, skin: 0xD9A47A, hair: 0xF7C744, style: .short, shirt: 0xE5EBFB),
        .init(bg: 0xEFE9DF, skin: 0x6E4630, hair: 0x1D1A16, style: .bald, shirt: 0xF7C744),
        .init(bg: 0x2F7D4F, skin: 0xF2D3B3, hair: 0x8A6D1F, style: .short, shirt: 0xFFFDF9),
        .init(bg: 0xF7C744, skin: 0xA86B45, hair: 0x1D1A16, style: .long, shirt: 0xC2410C),
        .init(bg: 0x1F4FD8, skin: 0x6E4630, hair: 0x1D1A16, style: .curly, shirt: 0xFDF2CF),
        .init(bg: 0xE5EBFB, skin: 0xD9A47A, hair: 0x4F4A42, style: .bald, shirt: 0x1D1A16),
        .init(bg: 0xC2410C, skin: 0xF2D3B3, hair: 0x1D1A16, style: .bun, shirt: 0xFDF2CF),
        .init(bg: 0xFDF2CF, skin: 0x6E4630, hair: 0x1D1A16, style: .fringe, shirt: 0x1F4FD8),
    ]
}

/// Draws one illustrated avatar in a 64×64 design space, scaled to any size.
struct IllustratedAvatar: View {
    let index: Int

    var body: some View {
        let a = AvatarSpec.all[((index % AvatarSpec.all.count) + AvatarSpec.all.count) % AvatarSpec.all.count]
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 64, y: size.height / 64)
            let ink = Color(hex: 0x1D1A16)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: 64, height: 64)), with: .color(Color(hex: a.bg)))
            if a.style == .long { drawHair(a, in: &ctx) }
            ctx.fill(Path(ellipseIn: CGRect(x: 12, y: 52, width: 40, height: 28)), with: .color(Color(hex: a.shirt)))
            ctx.fill(Path(roundedRect: CGRect(x: 28, y: 46, width: 8, height: 8), cornerRadius: 3), with: .color(Color(hex: a.skin)))
            ctx.fill(Path(ellipseIn: CGRect(x: 17, y: 22, width: 30, height: 30)), with: .color(Color(hex: a.skin)))
            if a.style != .long { drawHair(a, in: &ctx) }
            ctx.fill(Path(ellipseIn: CGRect(x: 24.8, y: 36.3, width: 3.4, height: 3.4)), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: 35.8, y: 36.3, width: 3.4, height: 3.4)), with: .color(ink))
            var smile = Path()
            smile.move(to: CGPoint(x: 27.5, y: 44))
            smile.addQuadCurve(to: CGPoint(x: 36.5, y: 44), control: CGPoint(x: 32, y: 47.6))
            ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func drawHair(_ a: AvatarSpec, in ctx: inout GraphicsContext) {
        let hair = GraphicsContext.Shading.color(Color(hex: a.hair))
        switch a.style {
        case .fringe:
            var p = Path()
            p.move(to: CGPoint(x: 16, y: 36))
            p.addArc(center: CGPoint(x: 32, y: 36), radius: 16, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addCurve(to: CGPoint(x: 32, y: 31), control1: CGPoint(x: 43, y: 30), control2: CGPoint(x: 37, y: 29))
            p.addCurve(to: CGPoint(x: 16, y: 36), control1: CGPoint(x: 27, y: 29), control2: CGPoint(x: 21, y: 30))
            ctx.fill(p, with: hair)
        case .bun:
            ctx.fill(Path(ellipseIn: CGRect(x: 25.5, y: 8.5, width: 13, height: 13)), with: hair)
            ctx.fill(cap(radius: 15.5, dip: 5), with: hair)
        case .curly:
            for (x, y) in [(20.0, 25.0), (26, 20), (33, 18), (40, 21), (45, 27), (17, 32), (47, 33)] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12)), with: hair)
            }
        case .long:
            var p = Path()
            p.move(to: CGPoint(x: 14, y: 38))
            p.addArc(center: CGPoint(x: 32, y: 38), radius: 18, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: 50, y: 52)); p.addLine(to: CGPoint(x: 43, y: 52)); p.addLine(to: CGPoint(x: 43, y: 38))
            p.addLine(to: CGPoint(x: 21, y: 38)); p.addLine(to: CGPoint(x: 21, y: 52)); p.addLine(to: CGPoint(x: 14, y: 52))
            p.closeSubpath()
            ctx.fill(p, with: hair)
        case .short:
            ctx.fill(cap(radius: 15, dip: 6), with: hair)
        case .bald:
            let frame = Color(hex: a.bg == 0x1D1A16 ? 0xFFFDF9 : 0x1D1A16)
            ctx.stroke(Path(ellipseIn: CGRect(x: 21.8, y: 32.8, width: 8.4, height: 8.4)), with: .color(frame), lineWidth: 1.6)
            ctx.stroke(Path(ellipseIn: CGRect(x: 33.8, y: 32.8, width: 8.4, height: 8.4)), with: .color(frame), lineWidth: 1.6)
            var bridge = Path(); bridge.move(to: CGPoint(x: 30.2, y: 37)); bridge.addLine(to: CGPoint(x: 33.8, y: 37))
            ctx.stroke(bridge, with: .color(frame), lineWidth: 1.6)
        }
    }

    /// Hair cap over the top of the head with a soft dip at the hairline.
    private func cap(radius r: CGFloat, dip: CGFloat) -> Path {
        var p = Path()
        let y: CGFloat = 34
        p.move(to: CGPoint(x: 32 - r, y: y))
        p.addArc(center: CGPoint(x: 32, y: y), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addQuadCurve(to: CGPoint(x: 32 - r, y: y), control: CGPoint(x: 32, y: y - dip * 1.6))
        return p
    }
}

/// Local profile: name, headline and avatar (illustrated or a photo). Stored on this device.
@MainActor
@Observable
final class Profile {
    var name: String { didSet { UserDefaults.standard.set(name, forKey: "profile.name"); changed() } }
    var headline: String { didSet { UserDefaults.standard.set(headline, forKey: "profile.headline"); changed() } }
    var avatar: Int { didSet { UserDefaults.standard.set(avatar, forKey: "profile.avatar"); changed() } }
    var photo: Data? { didSet { savePhoto(); changed() } }

    /// Called after local edits (the cloud layer uses it to sync). Not called while applying remote data.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var applying = false
    private func changed() { if !applying { onChange?() } }

    func applyRemote(name: String, headline: String, avatar: Int, photoDataURL: String) {
        applying = true
        defer { applying = false }
        self.name = name
        self.headline = headline
        self.avatar = avatar
        if let comma = photoDataURL.firstIndex(of: ","), photoDataURL.hasPrefix("data:") {
            photo = Data(base64Encoded: String(photoDataURL[photoDataURL.index(after: comma)...]))
        } else {
            photo = nil
        }
    }

    init() {
        let d = UserDefaults.standard
        name = d.string(forKey: "profile.name") ?? ""
        headline = d.string(forKey: "profile.headline") ?? ""
        avatar = d.integer(forKey: "profile.avatar")
        photo = try? Data(contentsOf: Self.photoURL)
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? "" }

    private static var photoURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Prepboard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile-photo.jpg")
    }

    private func savePhoto() {
        if let photo { try? photo.write(to: Self.photoURL) } else { try? FileManager.default.removeItem(at: Self.photoURL) }
    }
}

/// The user's avatar: their photo if set, otherwise the chosen illustration.
struct ProfileAvatar: View {
    @Environment(Profile.self) private var profile
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let data = profile.photo, let image = platformImage(data) {
                image.resizable().scaledToFill()
            } else {
                IllustratedAvatar(index: profile.avatar)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

func platformImage(_ data: Data) -> Image? {
    #if os(macOS)
    NSImage(data: data).map { Image(nsImage: $0) }
    #else
    UIImage(data: data).map { Image(uiImage: $0) }
    #endif
}

/// "Bring your own Anthropic key": saved encrypted on the server via the prep-chat function; never readable back.
struct AIKeySection: View {
    @Environment(Cloud.self) private var cloud
    @State private var key = ""
    @State private var status: KeyStatus?
    @State private var message: (ok: Bool, text: String)?
    @State private var busy = false

    struct KeyStatus: Decodable { let has_key: Bool?; let hint: String?; let ok: Bool?; let error: String? }
    private struct Req: Encodable { let mode: String; var key: String? = nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Anthropic API key").font(.system(size: 14, weight: .semibold))
                Spacer()
                if status?.has_key == true {
                    Text("Saved ••••\(status?.hint ?? "")").font(.system(size: 11, weight: .bold)).foregroundStyle(PB.cobalt)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 8).fill(PB.cobaltSoft))
                    Button("Remove") { Task { await call(Req(mode: "delete_key")); await refresh() } }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
            }
            if cloud.user != nil {
                HStack(spacing: 8) {
                    SecureField(status?.has_key == true ? "Replace with a new key (sk-ant-…)" : "sk-ant-…", text: $key)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(PB.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PB.line))
                    Button(busy ? "Checking…" : "Save") { save() }.buttonStyle(PillButtonStyle(compact: true)).disabled(busy || key.isEmpty)
                }
                Text("Powers the planner, quizzes and videos on any device. Stored encrypted and never shown again. Get one at console.anthropic.com.")
                    .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sign in to add your key.").font(.system(size: 12)).foregroundStyle(PB.muted)
            }
            if let message {
                Text(message.text).font(.system(size: 12)).foregroundStyle(message.ok ? PB.cobalt : Color(hex: 0xC2410C))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(PB.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PB.line))
        .task { await refresh() }
    }

    private func refresh() async {
        guard cloud.user != nil else { return }
        status = try? await cloud.invoke(Req(mode: "key_status"))
    }

    @discardableResult
    private func call(_ r: Req) async -> KeyStatus? { try? await cloud.invoke(r) }

    private func save() {
        busy = true; message = nil
        let k = key
        Task {
            defer { busy = false }
            do {
                let r: KeyStatus = try await cloud.invoke(Req(mode: "set_key", key: k))
                if let e = r.error { message = (false, e); return }
                key = ""; message = (true, "Key saved.")
                await refresh()
            } catch { message = (false, error.localizedDescription) }
        }
    }
}

struct ProfileSheet: View {
    @Environment(Profile.self) private var profile
    @Environment(Cloud.self) private var cloud
    @Environment(ClaudeCode.self) private var claude
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        @Bindable var profile = profile
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Profile").font(.system(size: 18, weight: .semibold))
                Spacer()
                CircleIconButton(systemImage: "xmark", size: 32, label: "Close") { dismiss() }
            }
            HStack(spacing: 16) {
                ProfileAvatar(size: 72)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Your name", text: $profile.name).textFieldStyle(.plain).font(.system(size: 20, weight: .bold))
                    TextField("Headline, e.g. iOS engineer · New York", text: $profile.headline).textFieldStyle(.plain)
                        .foregroundStyle(PB.ink2)
                }
            }
            Text("Choose an avatar").pbLabelStyle()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(AvatarSpec.all.indices, id: \.self) { i in
                    let on = profile.photo == nil && profile.avatar == i
                    Button { profile.avatar = i; profile.photo = nil } label: {
                        IllustratedAvatar(index: i)
                            .clipShape(Circle())
                            .padding(3)
                            .overlay(Circle().strokeBorder(on ? PB.cobalt : Color.clear, lineWidth: 2.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Avatar \(i + 1)")
                }
            }
            #if os(macOS)
            claudeSection
            DeviceBridgeSection()
            #else
            MacBridgeSection()
            #endif
            AIKeySection()
            accountSection
            HStack(spacing: 8) {
                Button("Upload photo") { importing = true }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                if profile.photo != nil {
                    Button("Remove photo") { profile.photo = nil }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
                Text("Saved on this device").font(.system(size: 12)).foregroundStyle(PB.muted)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PillButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 460)
        .background(PB.card)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { profile.photo = downscaled(data) ?? data }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if cloud.configured, let user = cloud.user {
            HStack(spacing: 10) {
                Circle().fill(cloud.status == .synced ? Color(hex: 0x2F7D4F) : cloud.status == .syncing ? PB.sun : Color(hex: 0xC2410C))
                    .frame(width: 8, height: 8)
                Text("\(user.email ?? "Signed in") · \(cloud.status.rawValue)").font(.system(size: 13)).lineLimit(1)
                Spacer()
                Button("Sign out") { Task { await cloud.signOut() } }.buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
            .padding(.top, 6)
        } else if !cloud.configured {
            Text("Accounts aren't connected yet. Your data is saved on this device.").font(.system(size: 12)).foregroundStyle(PB.muted)
        }
    }

    #if os(macOS)
    private var claudeSection: some View {
        HStack(spacing: 12) {
            ClaudeMark().frame(width: 26, height: 26)
                .padding(8).background(Circle().fill(Color(hex: 0xF5EDE4)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code").font(.system(size: 14, weight: .semibold))
                Text(claudeStatus).font(.system(size: 12)).foregroundStyle(PB.muted).lineLimit(2)
            }
            Spacer()
            switch claude.connection {
            case .checking: ProgressView().controlSize(.small)
            case .notInstalled:
                Button("Install guide") { NSWorkspace.shared.open(URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!) }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
            case .signedOut:
                Button("Sign in…") { claude.openSignIn() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                Button("Check again") { Task { await claude.connect() } }.buttonStyle(PillButtonStyle(compact: true))
            default:
                if claude.isReady {
                    Button("Disconnect") { claude.disconnect() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                } else {
                    Button("Connect") { Task { await claude.connect() } }.buttonStyle(PillButtonStyle(compact: true))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(PB.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PB.line))
        .task { if claude.connection == .unknown { await claude.checkConnection() } }
    }

    private var claudeStatus: String {
        switch claude.connection {
        case .unknown, .checking: "Checking for Claude Code on this Mac…"
        case .notInstalled: "Not installed. Install Claude Code to ask questions and take quizzes in PrepBoard."
        case .signedOut: "Installed, but not signed in. Sign in with your Claude account, then check again."
        case .connected(let v): claude.enabled ? "Connected · \(v). Uses your own Claude account." : "Ready to connect · \(v)"
        }
    }
    #endif

    /// Square-crops and shrinks the photo to 256 px JPEG.
    private func downscaled(_ data: Data) -> Data? {
        #if os(macOS)
        guard let src = NSImage(data: data), let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let cg = UIImage(data: data)?.cgImage else { return nil }
        #endif
        let side = min(cg.width, cg.height)
        guard let cropped = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)),
              let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let out = ctx.makeImage() else { return nil }
        #if os(macOS)
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        #else
        return UIImage(cgImage: out).jpegData(compressionQuality: 0.85)
        #endif
    }
}

#if os(iOS)
/// Optional: use the Claude Code on your Mac from iPhone / iPad (home Wi-Fi or Tailscale).
struct MacBridgeSection: View {
    @Environment(ClaudeCode.self) private var claude
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ClaudeMark().frame(width: 22, height: 22)
                    .padding(7).background(Circle().fill(Color(hex: 0xF5EDE4)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code on my Mac").font(.system(size: 14, weight: .semibold))
                    Text(statusText).font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if claude.connection == .checking { ProgressView().controlSize(.small) }
            }
            if claude.paired {
                HStack(spacing: 8) {
                    Button(claude.enabled ? "Turn off" : "Turn on") {
                        claude.enabled.toggle()
                        if claude.enabled { Task { await claude.checkConnection() } }
                    }
                    .buttonStyle(PillButtonStyle(filled: !claude.enabled, compact: true))
                    Button("Check again") { Task { await claude.checkConnection() } }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                    Button("Unpair") { claude.unpair() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
            } else {
                Text("Optional. On your Mac, run node bridge/claude-bridge.mjs --remote, then enter the address and code it prints. Works on the same Wi-Fi, or anywhere with Tailscale.")
                    .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
                input("Mac address, e.g. 100.64.0.5:8787", text: $address, keyboard: .URL)
                input("Pairing code, XXXX-XXXX-XXXX-XXXX", text: $code, keyboard: .asciiCapable)
                Button(busy ? "Pairing…" : "Pair") {
                    busy = true
                    Task { await claude.pair(address: address, code: code); busy = false; if claude.isReady { code = "" } }
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .disabled(busy || address.isEmpty || code.filter { $0.isLetter || $0.isNumber }.count != 16)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(PB.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PB.line))
        .task { if claude.paired, claude.connection == .unknown { await claude.checkConnection() } }
    }

    private func input(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 15, design: .monospaced))
            .padding(.horizontal, 10).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(PB.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PB.line))
    }

    private var statusText: String {
        guard claude.paired else { return "Use your Claude account from this device, through your Mac." }
        switch claude.connection {
        case .unknown, .checking: return "Checking your Mac at \(claude.address)…"
        case .unreachable: return "Can't reach \(claude.address). Is the Mac awake, with the bridge running? Using your Anthropic key meanwhile."
        case .signedOut: return "Reached your Mac, but Claude Code isn't signed in there. Run claude auth login on the Mac."
        case .connected(let v): return claude.enabled ? "Connected · \(v). Planner, quizzes and videos use your Claude account." : "Paired, turned off. Using your Anthropic key."
        }
    }
}
#endif

#if os(macOS)
/// Optional: let the user's own iPhone / iPad use this Mac's Claude Code while PrepBoard is open.
struct DeviceBridgeSection: View {
    @Environment(DeviceBridge.self) private var bridge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { bridge.enabled }, set: { bridge.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let my iPhone and iPad use Claude Code").font(.system(size: 14, weight: .semibold))
                    Text("Works while PrepBoard is open on this Mac, over the same Wi-Fi or Tailscale.")
                        .font(.system(size: 12)).foregroundStyle(PB.muted)
                }
            }
            .toggleStyle(CheckboxToggleStyle())
            if bridge.enabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On iPhone or iPad: Profile → Claude Code on my Mac, then enter").font(.system(size: 12)).foregroundStyle(PB.ink2)
                    ForEach(bridge.addresses, id: \.ip) { a in
                        row("Address", "\(a.ip):\(DeviceBridgeConfig.port)", note: a.tailscale ? "Tailscale · works away from home" : "This Wi-Fi only")
                    }
                    if bridge.addresses.isEmpty { Text("No network address. Connect to Wi-Fi or Tailscale.").font(.system(size: 12)).foregroundStyle(PB.red) }
                    row("Code", bridge.displayCode, note: nil)
                    HStack(spacing: 8) {
                        Text(bridge.lastError ?? (bridge.running ? (bridge.lastUsed.map { "Listening · last used \($0.pbFull)" } ?? "Listening") : "Starting…"))
                            .font(.system(size: 12)).foregroundStyle(bridge.lastError == nil ? PB.muted : PB.red)
                        Spacer()
                        Button("New code") { bridge.resetCode() }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                            .help("Unpairs every device; enter the new code on each one")
                    }
                }
                .padding(.leading, 34)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(PB.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PB.line))
    }

    private func row(_ label: String, _ value: String, note: String?) -> some View {
        HStack(spacing: 10) {
            Text(label).pbLabelStyle().frame(width: 60, alignment: .leading)
            Text(value).font(.system(size: 14, weight: .semibold, design: .monospaced)).textSelection(.enabled)
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(PB.muted) }
        }
    }
}
#endif
