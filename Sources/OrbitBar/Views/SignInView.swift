import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var linkPassword = ""
    @FocusState private var focus: Field?

    private enum Field { case server, email, password, code, linkPassword }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                OrbitLogo().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Orbit").font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Quit")
            }

            if let error = model.errorMessage {
                ErrorBanner(message: error) { model.errorMessage = nil }
            }

            switch model.signInStep {
            case .credentials: credentials
            case .twoFactor: twoFactor
            case .linkPassword(_, _, let provider, let email): linkStep(provider: provider, email: email)
            }

            Spacer()
        }
        .padding(20)
        .disabled(model.isLoading)
        .overlay(alignment: .bottomTrailing) {
            if model.isLoading { ProgressView().controlSize(.small).padding(20) }
        }
        .onAppear { focus = model.serverInput.isEmpty ? .server : .email }
        .task(id: model.serverInput) {
            try? await Task.sleep(for: .milliseconds(450))
            await model.loadAuthOptions()
        }
    }

    private var subtitle: String {
        switch model.signInStep {
        case .credentials: return "Connect to your Orbit instance"
        case .twoFactor: return "Two-factor authentication"
        case .linkPassword: return "Connect your account"
        }
    }

    @ViewBuilder private var credentials: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            labeled("Server") {
                TextField("orbit.example.com", text: $model.serverInput)
                    .focused($focus, equals: .server)
                    .onSubmit { focus = .email }
            }
            labeled("Email") {
                TextField("you@example.com", text: $email)
                    .textContentType(.username)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
            }
            labeled("Password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
            }
            HStack {
                Spacer()
                Button("Sign In", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.serverInput.isEmpty || email.isEmpty || password.isEmpty)
            }

            if let providers = model.authOptions?.providers, !providers.isEmpty {
                HStack {
                    VStack { Divider() }
                    Text("or").font(.caption).foregroundStyle(.secondary)
                    VStack { Divider() }
                }
                .padding(.vertical, 4)
                ForEach(providers, id: \.self) { provider in
                    Button {
                        Task { await model.signIn(provider: provider) }
                    } label: {
                        Text("Continue with \(label(provider))").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder private var twoFactor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter the 6-digit code from your authenticator app, or a recovery code.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("123456", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .textContentType(.oneTimeCode)
                .focused($focus, equals: .code)
                .onSubmit { Task { await model.submitSecondFactor(code) } }
                .onAppear { focus = .code }
            HStack {
                Button("Back") { model.cancelSignInStep() }
                Spacer()
                Button("Verify") { Task { await model.submitSecondFactor(code) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder private func linkStep(provider: String, email: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("An Orbit account for \(email) already exists. Enter its password to connect your \(label(provider)) account. You only do this once.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $linkPassword)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .linkPassword)
                .onSubmit { Task { await model.linkProvider(password: linkPassword) } }
                .onAppear { focus = .linkPassword }
            HStack {
                Button("Back") { model.cancelSignInStep() }
                Spacer()
                Button("Connect") { Task { await model.linkProvider(password: linkPassword) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(linkPassword.isEmpty)
            }
        }
    }

    private func submit() {
        guard !model.serverInput.isEmpty, !email.isEmpty, !password.isEmpty else { return }
        Task { await model.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password) }
    }

    private func label(_ provider: String) -> String {
        switch provider {
        case "google": return "Google"
        case "github": return "GitHub"
        case "oidc": return model.authOptions?.oidcName ?? "SSO"
        default: return provider.capitalized
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
}
