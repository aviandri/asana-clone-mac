import AppKit
import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// Server URL, email, password (SPEC-MAC §5). Errors inline; invites are accepted on the web.
struct SignInView: View {
    let session: AppSession

    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?
    @Environment(\.openURL) private var openURL

    private enum Field { case server, email, password }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Sign in to Mekari Project")
                    .font(.title2.weight(.semibold))
            }

            Form {
                TextField("Server", text: $server, prompt: Text("https://…"))
                    .focused($focus, equals: .server)
                    .accessibilityIdentifier("signin.server")
                TextField("Email", text: $email, prompt: Text("you@company.com"))
                    .textContentType(.username)
                    .focused($focus, equals: .email)
                    .accessibilityIdentifier("signin.email")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .accessibilityIdentifier("signin.password")
                    .onSubmit(submit)
            }
            .formStyle(.columns)
            .frame(width: 340)
            .disabled(session.isSigningIn)

            if let error = session.signInError {
                Label(error.message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: 340, alignment: .leading)
                    .accessibilityIdentifier("signin.error")
            }

            HStack {
                Button("Accept an invite in the browser") {
                    if let url = ServerURL.normalize(server) { openURL(WebLinks.acceptInvite(server: url)) }
                }
                .buttonStyle(.link)
                .disabled(ServerURL.normalize(server) == nil)
                Spacer()
                if session.isSigningIn { ProgressView().controlSize(.small) }
                Button("Sign In", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("signin.submit")
            }
            .frame(width: 340)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            server = session.settings.serverURL?.absoluteString ?? ""
            focus = server.isEmpty ? .server : .email
        }
    }

    private var canSubmit: Bool {
        !session.isSigningIn && !server.trimmingCharacters(in: .whitespaces).isEmpty && !email.isEmpty && !password.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await session.signIn(server: server, email: email, password: password) }
    }
}
