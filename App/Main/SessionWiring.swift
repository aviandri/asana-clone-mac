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
    /// The last celebration event shown (per scope), so a new scope never replays an old one.
    private var shownCelebration: Int?

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
        let celebrationID: Int?
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
            isSwitching: session.isSwitching,
            celebrationID: session.scope?.completionFeedback.lastEvent?.id
        )
    }

    private func react(to inputs: Inputs) {
        let scopeObject = inputs.scope.map(ObjectIdentifier.init)

        // A new scope object (switch, lost-access recovery, sign-in), even with the same workspace id.
        if scopeObject != wiredScope || inputs.generation != wiredGeneration {
            wiredScope = scopeObject
            wiredGeneration = inputs.generation
            router.scopeChanged(to: inputs.scope?.id)
            // Sign-out, a switch or lost access: no download error naming another session's files stays.
            AttachmentErrors.shared.clearAll()
            inputs.scope?.poller.onNew = { [notifier] notices in notifier.post(notices) }
            shownCelebration = inputs.celebrationID
        }

        // A completion that finished a section, a project or today's list (decided, and gated by the
        // Celebrations setting, in Features' CompletionFeedback; sent only once the server agreed).
        if let id = inputs.celebrationID, id != shownCelebration {
            shownCelebration = id
            CelebrationPresenter.shared.celebrate()
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
