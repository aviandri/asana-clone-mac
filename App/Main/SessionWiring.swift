import MekariProjectFeatures
import MekariProjectKit
import Observation

/// App-level reactions to the session, independent of which windows are open (the app can run with
/// only the menu bar): every new workspace scope gets its poller wired to banners and resets the
/// router; a link that arrived before sign-in finished is replayed once signed in; notification
/// permission is asked on the first sign-in. Observes with `withObservationTracking` (no Combine).
@MainActor
final class SessionWiring {
    private let session: AppSession
    private let router: AppRouter
    private let notifier: LocalNotifier
    private var wiredScope: ObjectIdentifier?
    private var wiredGeneration: Int?
    private var replaying = false

    init(session: AppSession, router: AppRouter, notifier: LocalNotifier = .shared) {
        self.session = session
        self.router = router
        self.notifier = notifier
        observe()
    }

    private func observe() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            // Fires once, before the change lands; re-read and re-arm on the main actor.
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    /// Reads (and so tracks) state, generation, scope and the pending link, then reacts.
    func apply() {
        let generation = session.generation
        let scope = session.scope
        let scopeObject = scope.map(ObjectIdentifier.init)

        // A new scope object (switch, lost-access recovery, sign-in), even with the same workspace id.
        if scopeObject != wiredScope || generation != wiredGeneration {
            wiredScope = scopeObject
            wiredGeneration = generation
            router.scopeChanged(to: scope?.id)
            scope?.poller.onNew = { [notifier] notices in notifier.post(notices) }
        }

        guard case .signedIn = session.state else { return }
        notifier.requestPermissionIfNeeded()
        if router.pendingLink != nil, !replaying, !session.isSwitching {
            replaying = true
            Task { @MainActor in
                await router.replayPendingLink(in: session)
                replaying = false
            }
        }
    }
}
