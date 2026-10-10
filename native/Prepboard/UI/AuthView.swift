import SwiftUI

/// Sign in / create account / reset password. Shown when accounts are configured and nobody is signed in.
struct AuthView: View {
    @Environment(Cloud.self) private var cloud
    enum Mode { case signIn, signUp, reset }
    @State private var mode: Mode = .signIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: (ok: Bool, text: String)?

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 700 {
                // iPad / Mac: full-screen split — brand panel left, form right.
                HStack(spacing: 0) {
                    art.frame(width: geo.size.width * 0.5).frame(maxHeight: .infinity)
                    ScrollView { form.frame(maxWidth: 460).frame(maxWidth: .infinity).frame(minHeight: geo.size.height) }
                        .background(PB.card)
                }
                .ignoresSafeArea()
            } else {
                ScrollView {
                    VStack(spacing: 0) { art; form }
                        .background(PB.card)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(PB.line))
                        .padding(16)
                }
                .background(PB.background)
            }
        }
    }

    private var art: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 12) {
                PrepBoardLogo(size: 52)
                Text("PrepBoard").font(.system(size: 22, weight: .bold)).kerning(-0.5).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Prepare for the job you want, one session at a time.")
                    .font(.system(size: 44, weight: .bold)).kerning(-1.6).foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Plan every interview on a timeline, keep your notes next to the hour you'll use them, and pick up on any device.")
                    .foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
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

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .signUp ? "Create your account" : mode == .reset ? "Reset your password" : "Welcome back")
                .font(.system(size: 24, weight: .bold)).kerning(-0.4)
            if let message {
                Text(message.text).font(.system(size: 13))
                    .foregroundStyle(message.ok ? PB.cobalt : Color(hex: 0x9A3412))
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(message.ok ? PB.cobaltSoft : Color(hex: 0xFBE4D8)))
            }
            if mode == .signUp { PBTextField(label: "Name", text: $name) }
            PBTextField(label: "Email", text: $email)
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                #endif
            if mode != .reset {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Password").pbLabelStyle()
                    SecureField("At least 8 characters", text: $password)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
                        .onSubmit(submit)
                }
            }
            Button(action: submit) {
                Group { if busy { ProgressView().controlSize(.small).tint(.white) } else { Text(mode == .signUp ? "Create account" : mode == .reset ? "Send reset link" : "Sign in") } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(busy || email.isEmpty || (mode != .reset && password.count < 8))
            .keyboardShortcut(.defaultAction)
            HStack {
                if mode == .signIn {
                    Text("New here?").foregroundStyle(PB.ink2)
                    Button("Create an account") { mode = .signUp; message = nil }.buttonStyle(.plain).foregroundStyle(PB.cobalt).fontWeight(.semibold)
                    Spacer()
                    Button("Forgot password?") { mode = .reset; message = nil }.buttonStyle(.plain).foregroundStyle(PB.cobalt).fontWeight(.semibold)
                } else {
                    Text("Have an account?").foregroundStyle(PB.ink2)
                    Button("Sign in") { mode = .signIn; message = nil }.buttonStyle(.plain).foregroundStyle(PB.cobalt).fontWeight(.semibold)
                    Spacer()
                }
            }
            .font(.system(size: 13))
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        let e = email.trimmingCharacters(in: .whitespaces)
        busy = true
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .signIn:
                    try await cloud.signIn(email: e, password: password)
                case .signUp:
                    if try await cloud.signUp(name: name, email: e, password: password) {
                        mode = .signIn
                        message = (true, "Check your email to confirm your account, then sign in.")
                    }
                case .reset:
                    try await cloud.resetPassword(email: e)
                    mode = .signIn
                    message = (true, "If that email has an account, a reset link is on its way.")
                }
            } catch {
                message = (false, error.localizedDescription)
            }
        }
    }
}
