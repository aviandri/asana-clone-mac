import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// Sign-in, the main split view, or "no workspace", depending on the session.
struct RootView: View {
    let session: AppSession
    @Bindable var router: AppRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                ProgressView("Signing in…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SignInView(session: session)
            case .signedIn:
                if let scope = session.scope {
                    // A new scope (workspace switch or lost access) gets fresh view state.
                    MainView(session: session, scope: scope, router: router)
                        .id(scope.id)
                } else {
                    NoWorkspaceView(session: session)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .overlay(alignment: .bottom) {
            if let notice = session.notice {
                NoticeToast(text: notice)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.notice)
        // mekariproject://task/<id>, mekariproject://project/<id> (SPEC-MAC §5).
        .onOpenURL { url in
            guard let link = DeepLink(url: url) else { return }
            Task { await router.follow(link, in: session) }
        }
        .alert("Can't Open", isPresented: Binding(get: { router.alert != nil }, set: { if !$0 { router.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.alert ?? "")
        }
        .onAppear { router.openMainWindow = { openWindow(id: WindowID.main) } }
        // Each workspace scope: start on My Tasks, and turn new inbox items into banners.
        .onChange(of: session.scope?.id, initial: true) { _, new in
            router.scopeChanged(to: new)
            session.scope?.poller.onNew = { notices in LocalNotifier.shared.post(notices) }
        }
        // Ask for notification permission on the first sign-in (once per install).
        .onChange(of: session.me?.id) { _, id in
            if id != nil { LocalNotifier.shared.requestPermissionIfNeeded() }
        }
        .task(id: session.notice) {
            guard let notice = session.notice else { return }
            // VoiceOver users hear the toast too.
            AccessibilityNotification.Announcement(notice).post()
            try? await Task.sleep(for: .seconds(4))
            session.dismissNotice()
        }
    }
}

/// Signed in but not a member of any workspace: joining or creating one happens on the web (SPEC-MAC §1).
struct NoWorkspaceView: View {
    let session: AppSession
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("No workspace yet", systemImage: "rectangle.stack.badge.person.crop")
        } description: {
            Text("Accept an invite, join your organization or create a workspace in the browser, then come back.")
        } actions: {
            if let url = session.webURL(path: "/") {
                Button("Open in Browser") { openURL(url) }
                    .buttonStyle(.borderedProminent)
            }
            Button("Sign Out") { Task { await session.signOut() } }
        }
    }
}
