import SwiftUI

/// Sign in, iPhone-first and modeled on LifeOS: email first, then the 6-digit code from the email
/// (works for new and returning accounts), with password sign-in and a reset link as options.
/// Keyboard-safe: the form scrolls, the primary button rides above the keyboard, and Return moves focus.
struct AuthView: View {
    @Environment(Cloud.self) private var cloud

    enum Step: Equatable { case email, code, password, forgot }
    enum Field: Hashable { case email, password }

    @State private var step: Step = .email
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var message: (ok: Bool, text: String)?
    @State private var resendAt = Date.distantPast
    @FocusState private var focus: Field?
    @FocusState private var codeFocused: Bool

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 700 {
                // iPad / Mac: brand panel left, form right.
                HStack(spacing: 0) {
                    brandPanel.frame(width: geo.size.width * 0.5).frame(maxHeight: .infinity)
                    formScroll(maxWidth: 420).background(PB.card)
                }
                .ignoresSafeArea(.container)
            } else {
                formScroll(maxWidth: .infinity).background(PB.background)
            }
        }
    }

    // MARK: layout

    private func formScroll(maxWidth: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                fields
                if let message { banner(message) }
                secondaryActions
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            primaryButton
                .frame(maxWidth: maxWidth)
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12)
                .frame(maxWidth: .infinity)
        }
    }

    private var brandPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                PrepBoardLogo(size: 52)
                Text("PrepBoard").font(.system(size: 22, weight: .bold)).kerning(-0.5).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Prepare for the job you want, one session at a time.")
                    .font(.system(size: 44, weight: .bold)).kerning(-1.6).foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Plan every interview on a timeline, keep your notes next to the hour you'll use them, and pick up on any device.")
                    .foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: -10) {
                ForEach(0..<5) { i in
                    IllustratedAvatar(index: i).frame(width: 50, height: 50).clipShape(Circle())
                        .overlay(Circle().strokeBorder(PB.cobalt, lineWidth: 3))
                }
            }
        }
        .padding(.horizontal, 48).padding(.vertical, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(PB.cobalt)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PrepBoardLogo(size: 36)
                Text("PrepBoard").font(.system(size: 17, weight: .bold)).kerning(-0.3)
            }
            .padding(.bottom, 8)
            Text(title).font(.system(size: 32, weight: .bold, design: .serif)).kerning(-0.6)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 15)).foregroundStyle(PB.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch step {
        case .email: "Sign in or create an account"
        case .code: "Check your email"
        case .password: "Sign in with password"
        case .forgot: "Reset your password"
        }
    }

    private var subtitle: String {
        switch step {
        case .email: "Enter your email and we'll send a 6-digit code. No password needed."
        case .code: "Enter the 6-digit code we sent to \(email). It can take a minute; check spam too."
        case .password: "Use the password you set for PrepBoard or LifeOS."
        case .forgot: "We'll email you a reset link. Open it on any device to choose a new password, then sign in here."
        }
    }

    // MARK: fields

    @ViewBuilder
    private var fields: some View {
        switch step {
        case .email, .forgot:
            field("Email") {
                TextField("you@example.com", text: $email)
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.continue)
                    .onSubmit(primaryAction)
            }
            .onAppear { focus = .email }
        case .password:
            field("Email") {
                TextField("you@example.com", text: $email)
                    .textContentType(.username)
                    #if os(iOS)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
            }
            field("Password") {
                SecureField("Your password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(primaryAction)
            }
            .onAppear { focus = email.isEmpty ? .email : .password }
        case .code:
            CodeField(code: $code, focused: $codeFocused) { primaryAction() }
                .onAppear { codeFocused = true }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).pbLabelStyle()
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .padding(.horizontal, 16).frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).fill(PB.card))
                .overlay(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).strokeBorder(PB.line2))
        }
    }

    private func banner(_ m: (ok: Bool, text: String)) -> some View {
        Text(m.text).font(.system(size: 14))
            .foregroundStyle(m.ok ? PB.cobalt : PB.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(m.ok ? PB.cobaltSoft : PB.redSoft))
    }

    // MARK: actions

    private var primaryTitle: String {
        switch step {
        case .email: "Continue"
        case .code: "Verify"
        case .password: "Sign in"
        case .forgot: "Email me a reset link"
        }
    }

    private var primaryDisabled: Bool {
        switch step {
        case .email, .forgot: !email.contains("@")
        case .code: code.count != 6
        case .password: !email.contains("@") || password.isEmpty
        }
    }

    private var primaryButton: some View {
        Button(action: primaryAction) {
            Group {
                if busy { ProgressView().tint(.white) } else { Text(primaryTitle) }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Capsule().fill(PB.cobalt.opacity(primaryDisabled ? 0.45 : 1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy || primaryDisabled)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .email:
                link("Use password instead") { go(.password) }
            case .code:
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let wait = max(0, Int(resendAt.timeIntervalSince(ctx.date).rounded(.up)))
                    link(wait > 0 ? "Resend code in \(wait)s" : "Resend code") { resend() }.disabled(wait > 0)
                }
                link("Use a different email") { code = ""; go(.email) }
            case .password:
                link("Forgot password?") { go(.forgot) }
                link("Email me a code instead") { go(.email) }
            case .forgot:
                link("Back to sign in") { go(.password) }
            }
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(PB.cobalt)
    }

    private func go(_ s: Step) { message = nil; step = s }

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private func primaryAction() {
        guard !busy, !primaryDisabled else { return }
        let e = cleanEmail
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                switch step {
                case .email:
                    try await cloud.sendCode(email: e)
                    resendAt = .now.addingTimeInterval(60)
                    code = ""
                    step = .code
                case .code:
                    try await cloud.verifyCode(email: e, code: code)
                case .password:
                    try await cloud.signIn(email: e, password: password)
                case .forgot:
                    try await cloud.sendResetLink(email: e)
                    step = .password
                    message = (true, "Check your email for a reset link. Open it on any device, choose a new password, then sign in here.")
                }
            } catch {
                if step == .code { code = "" }
                message = (false, Self.friendly(error))
            }
        }
    }

    private func resend() {
        let e = cleanEmail
        Task {
            do {
                try await cloud.sendCode(email: e)
                resendAt = .now.addingTimeInterval(60)
                message = (true, "A new code is on its way.")
            } catch {
                message = (false, Self.friendly(error))
            }
        }
    }

    static func friendly(_ error: Error) -> String {
        let m = error.localizedDescription
        func has(_ s: String) -> Bool { m.localizedCaseInsensitiveContains(s) }
        if has("rate limit") || has("security purposes") { return "Please wait a minute before asking for another email." }
        if has("expired") || (has("invalid") && has("token")) { return "That code is wrong or has expired. Check the latest email, or resend." }
        if has("invalid login") { return "That email and password don't match. Try a code instead." }
        if has("email not confirmed") { return "Confirm your email first: use “Email me a code instead”." }
        return m
    }
}

/// Six boxes over one hidden field, so iOS can autofill the code from Mail.
struct CodeField: View {
    @Binding var code: String
    var focused: FocusState<Bool>.Binding
    var onComplete: () -> Void

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .textContentType(.oneTimeCode)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .focused(focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .onChange(of: code) {
                    let digits = String(code.filter(\.isNumber).prefix(6))
                    if digits != code { code = digits; return }
                    if digits.count == 6 { onComplete() }
                }
            HStack(spacing: 8) {
                let chars = Array(code)
                ForEach(0..<6, id: \.self) { i in
                    let active = focused.wrappedValue && i == min(chars.count, 5)
                    Text(i < chars.count ? String(chars[i]) : "")
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: 56).frame(height: 62)
                        .background(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).fill(PB.card))
                        .overlay(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous)
                            .strokeBorder(active ? PB.cobalt : PB.line2, lineWidth: active ? 2 : 1))
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verification code")
    }
}
