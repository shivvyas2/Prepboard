import SwiftUI

/// Sign in, in the same look as the rest of the app: one card on the app background, sans-serif type, pill buttons.
/// Password first (the project sends no custom emails yet, so 6-digit codes stay off until `emailCodes` is true),
/// with account creation and a reset link. Keyboard-safe: the form scrolls and Return moves focus.
struct AuthView: View {
    @Environment(Cloud.self) private var cloud

    /// 6-digit email codes need a custom SMTP provider on the Supabase project; turn on once one is set up.
    static let emailCodes = false

    enum Step: Equatable { case password, create, forgot, email, code }
    enum Field: Hashable { case email, password }

    @State private var step: Step = .password
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var message: (ok: Bool, text: String)?
    @State private var resendAt = Date.distantPast
    @FocusState private var focus: Field?
    @FocusState private var codeFocused: Bool

    var body: some View {
        ZStack {
            PB.background
            ScrollView {
                VStack(spacing: PB.s6) {
                    VStack(alignment: .leading, spacing: PB.s6) {
                        header
                        fields
                        if let message { banner(message) }
                        primaryButton
                        secondaryActions
                    }
                    .pbCard(padding: PB.s8)
                    Text("Your roles, notes and applications stay in sync on your Mac, iPhone and the web.")
                        .font(.system(size: 12)).foregroundStyle(PB.muted).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, PB.s4)
                .padding(.vertical, PB.s12)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: layout

    private var header: some View {
        VStack(alignment: .leading, spacing: PB.s2) {
            HStack(spacing: PB.s2) {
                PrepBoardLogo(size: 28)
                Text("PrepBoard").font(.system(size: 15, weight: .semibold)).kerning(-0.2).foregroundStyle(PB.ink)
            }
            .padding(.bottom, PB.s3)
            Text(title).font(.system(size: 26, weight: .bold)).kerning(-0.6).foregroundStyle(PB.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(PB.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch step {
        case .password: "Sign in"
        case .create: "Create your account"
        case .forgot: "Reset your password"
        case .email: "Sign in with a code"
        case .code: "Check your email"
        }
    }

    private var subtitle: String {
        switch step {
        case .password: "Welcome back. Use your PrepBoard email and password."
        case .create: "Choose an email and a password of at least 8 characters. You'll use them on every device."
        case .forgot: "We'll email you a link to choose a new password. Then come back and sign in."
        case .email: "We'll email you a 6-digit code. No password needed."
        case .code: "Enter the 6-digit code sent to \(email). It can take a minute, so check spam too."
        }
    }

    // MARK: fields

    @ViewBuilder
    private var fields: some View {
        switch step {
        case .email, .forgot:
            emailField(submit: .continue) { primaryAction() }
                .onAppear { focus = .email }
        case .password, .create:
            emailField(submit: .next) { focus = .password }
            field("Password") {
                SecureField(step == .create ? "At least 8 characters" : "Your password", text: $password)
                    .textContentType(step == .create ? .newPassword : .password)
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

    private func emailField(submit: SubmitLabel, onSubmit: @escaping () -> Void) -> some View {
        field("Email") {
            TextField("you@example.com", text: $email)
                .textContentType(step == .password ? .username : .emailAddress)
                #if os(iOS)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .email)
                .submitLabel(submit)
                .onSubmit(onSubmit)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).pbLabelStyle()
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).fill(PB.surface))
                .overlay(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).strokeBorder(PB.line2))
        }
    }

    private func banner(_ m: (ok: Bool, text: String)) -> some View {
        Label(m.text, systemImage: m.ok ? "checkmark.circle" : "exclamationmark.circle")
            .font(.system(size: 13))
            .foregroundStyle(m.ok ? PB.cobalt : PB.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(PB.s3).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).fill(m.ok ? PB.cobaltSoft : PB.redSoft))
    }

    // MARK: actions

    private var primaryTitle: String {
        switch step {
        case .password: "Sign in"
        case .create: "Create account"
        case .forgot: "Email me a reset link"
        case .email: "Email me a code"
        case .code: "Verify"
        }
    }

    private var primaryDisabled: Bool {
        switch step {
        case .email, .forgot: !email.contains("@")
        case .code: code.count != 6
        case .password: !email.contains("@") || password.isEmpty
        case .create: !email.contains("@") || password.count < 8
        }
    }

    private var primaryButton: some View {
        Button(action: primaryAction) {
            Group {
                if busy { ProgressView().controlSize(.small).tint(.white) } else { Text(primaryTitle) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle())
        .disabled(busy || primaryDisabled)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: PB.s3) {
            switch step {
            case .password:
                link("Forgot password?") { go(.forgot) }
                prompt("New to PrepBoard?", "Create an account") { go(.create) }
                if Self.emailCodes { link("Email me a code instead") { go(.email) } }
            case .create:
                prompt("Already have an account?", "Sign in") { go(.password) }
            case .forgot:
                link("Back to sign in") { go(.password) }
            case .email:
                link("Use password instead") { go(.password) }
            case .code:
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let wait = max(0, Int(resendAt.timeIntervalSince(ctx.date).rounded(.up)))
                    link(wait > 0 ? "Resend code in \(wait)s" : "Resend code") { resend() }.disabled(wait > 0)
                }
                link("Use a different email") { code = ""; go(.email) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(PB.cobalt)
    }

    private func prompt(_ text: String, _ action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 13)).foregroundStyle(PB.muted)
            link(action, action: perform)
        }
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
                case .create:
                    if try await !cloud.signUp(email: e, password: password) {
                        step = .password
                        message = (true, "Account created. Open the confirmation email we sent to \(e), then sign in here.")
                    }
                case .forgot:
                    try await cloud.sendResetLink(email: e)
                    step = .password
                    message = (true, "Check your email for a reset link. Choose a new password there, then sign in here.")
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
        if has("rate limit") || has("security purposes") { return "Too many tries. Wait a minute and try again." }
        if has("expired") || (has("invalid") && has("token")) { return "That code is wrong or has expired. Check the latest email, or resend." }
        if has("invalid login") { return "That email and password don't match. Check them, or reset your password." }
        if has("already registered") || has("already exists") { return "There's already an account with this email. Sign in instead." }
        if has("email not confirmed") { return "This account isn't confirmed yet. Reset your password to confirm it." }
        if has("password") && (has("short") || has("at least") || has("weak")) { return "Choose a longer password: at least 8 characters." }
        if has("network") || has("offline") || has("internet") { return "You're offline. Connect to the internet and try again." }
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
