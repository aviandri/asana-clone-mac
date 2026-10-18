import AppKit
import SwiftUI

/// The complete/incomplete checkbox on every task surface (lists, board cards, subtasks, menu bar).
/// The circle fills with the accent colour while the checkmark draws in, with a small spring pop.
/// The animation follows `completed`, so an optimistic completion the server rejects (TaskCache rolls
/// it back) plays in reverse by itself. With Reduce Motion: a quick crossfade, no pop.
@MainActor
struct CompletionCheckbox: View {
    let completed: Bool
    let title: String
    var size: CGFloat = 15
    var canEdit = true
    let action: () -> Void
    @State private var expectation: CompletionExpectation?

    var body: some View {
        Button {
            expectation = CompletionExpectation(target: !completed)
            CompletionEffects.play(completing: !completed, title: title)
            action()
        } label: {
            CompletionMark(completed: completed, size: size)
        }
        .buttonStyle(.plain)
        .disabled(!canEdit)
        .accessibilityLabel(completed ? "Mark \(title) incomplete" : "Mark \(title) complete")
        .onChange(of: completed) { _, new in CompletionExpectation.check(&expectation, completed: new, title: title) }
    }
}

/// The inspector's "Mark Complete" / "Completed" button, with the same feedback as the checkbox.
@MainActor
struct CompleteTaskButton: View {
    let completed: Bool
    let title: String
    var canEdit = true
    let action: () -> Void
    @State private var expectation: CompletionExpectation?

    var body: some View {
        Button {
            expectation = CompletionExpectation(target: !completed)
            CompletionEffects.play(completing: !completed, title: title)
            action()
        } label: {
            Label {
                Text(completed ? "Completed" : "Mark Complete")
            } icon: {
                CompletionMark(completed: completed, size: 14)
            }
        }
        .disabled(!canEdit)
        .onChange(of: completed) { _, new in CompletionExpectation.check(&expectation, completed: new, title: title) }
    }
}

/// What a click asked for, so a rollback (the server said no; TaskCache reverted the optimistic
/// change) is announced to VoiceOver instead of silently undoing the "Completed …" it just heard.
struct CompletionExpectation {
    let target: Bool
    let at = Date()

    @MainActor
    static func check(_ expectation: inout CompletionExpectation?, completed: Bool, title: String) {
        guard let current = expectation else { return }
        guard Date().timeIntervalSince(current.at) < 15 else {
            expectation = nil
            return
        }
        if completed == current.target { return } // the optimistic change landing
        expectation = nil
        AccessibilityNotification.Announcement(current.target ? "Couldn't complete \(title)" : "Couldn't reopen \(title)").post()
    }
}

/// The animated mark itself (also the icon of the inspector's Complete button).
@MainActor
struct CompletionMark: View {
    let completed: Bool
    var size: CGFloat = 15
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // keyframeAnimator's content closure is @Sendable: capture the value, not the environment.
        let popScale = !reduceMotion
        ZStack {
            Circle()
                .strokeBorder(Color.secondary, lineWidth: max(1, size * 0.08))
                .opacity(completed ? 0 : 1)
            Circle()
                .fill(Color.accentColor)
                .opacity(completed ? 1 : 0)
            CheckShape()
                .trim(from: 0, to: reduceMotion || completed ? 1 : 0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: max(1.4, size * 0.12), lineCap: .round, lineJoin: .round))
                .opacity(completed ? 1 : 0)
                .padding(size * 0.27)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeOut(duration: 0.22), value: completed)
        .keyframeAnimator(initialValue: 1.0, trigger: completed) { content, scale in
            content.scaleEffect(popScale ? scale : 1)
        } keyframes: { _ in
            SpringKeyframe(1.15, duration: 0.11, spring: .snappy)
            SpringKeyframe(1.0, duration: 0.2, spring: .bouncy)
        }
        .accessibilityHidden(true)
    }
}

/// A checkmark drawn from the left: short stroke down, long stroke up.
private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return path
    }
}

/// A task title whose strike-through sweeps in from the leading edge as it completes, dimming the text.
@MainActor
struct CompletionTitle: View {
    let title: String
    let completed: Bool
    var font: Font = .body
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(title)
            .font(font)
            .lineLimit(1)
            .foregroundStyle(completed ? .secondary : .primary)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.secondary)
                    .frame(height: 1)
                    .scaleEffect(x: reduceMotion || completed ? 1 : 0, y: 1, anchor: .leading)
                    .opacity(completed ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeOut(duration: 0.3), value: completed)
    }
}

/// What a click on a checkbox does besides the state change: haptic, the optional tick, the
/// VoiceOver announcement, and where a celebration (if Features decides on one) should burst from.
@MainActor
enum CompletionEffects {
    static func play(completing: Bool, title: String) {
        // Force Touch trackpads only; a no-op elsewhere.
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        if completing {
            // The burst starts at the click; a keyboard completion has none (the presenter falls back
            // to the window).
            if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type) {
                CelebrationPresenter.shared.noteCompletionPoint(NSEvent.mouseLocation)
            }
            if UserDefaults.standard.bool(forKey: SettingsKey.completionSound) {
                NSSound(named: "Tink")?.play()
            }
        }
        AccessibilityNotification.Announcement(completing ? "Completed \(title)" : "Marked \(title) incomplete").post()
    }
}
