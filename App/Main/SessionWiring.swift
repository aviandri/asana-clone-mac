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

    init(session: AppSession, router: AppRouter, notifier: LocalNotifier) {
        self.session = session
        self.router = router
        self.notifier = notifier
        observe()
    }

    /// What the wiring reacts to, read inside the tracking scope.
    private struct Inputs {
        let generation: Int
        let scope: WorkspaceScope?
        let signedIn: Bool
        let hasPendingLink: Bool
        let isSwitching: Bool
    }

    private func observe() {
        // Only reads happen inside the tracking scope. The reactions run after it: they write to the
        // router and poller, and must never run (or spin anything) while an access list is active.
        let inputs = withObservationTracking {
            read()
        } onChange: { [weak self] in
            // Fires once, before the change lands; re-read and re-arm on the main actor.
            Task { @MainActor [weak self] in self?.observe() }
        }
        react(to: inputs)
    }

    private func read() -> Inputs {
        let signedIn: Bool
        if case .signedIn = session.state { signedIn = true } else { signedIn = false }
        return Inputs(
            generation: session.generation,
            scope: session.scope,
            signedIn: signedIn,
            hasPendingLink: router.pendingLink != nil,
            isSwitching: session.isSwitching
        )
    }

    private func react(to inputs: Inputs) {
        let scopeObject = inputs.scope.map(ObjectIdentifier.init)

        // A new scope object (switch, lost-access recovery, sign-in), even with the same workspace id.
        if scopeObject != wiredScope || inputs.generation != wiredGeneration {
            wiredScope = scopeObject
            wiredGeneration = inputs.generation
            router.scopeChanged(to: inputs.scope?.id)
            inputs.scope?.poller.onNew = { [notifier] notices in notifier.post(notices) }
        }

        guard inputs.signedIn else { return }
        notifier.requestPermissionIfNeeded()
        if inputs.hasPendingLink, !replaying, !inputs.isSwitching {
            replaying = true
            Task { @MainActor in
                await router.replayPendingLink(in: session)
                replaying = false
            }
        }
    }
}
