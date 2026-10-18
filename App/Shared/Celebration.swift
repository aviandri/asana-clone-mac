import AppKit
import SwiftUI

/// The occasional celebration: a ~1.2 s burst of brand-magenta petals from the checkbox that finished
/// a section, a project or today's list (when, and whether Celebrations is on, is decided in
/// Features: `CompletionFeedback`). Like the web's
/// "Celebrations", it is decorative only: a click-through, non-activating panel above the app that
/// never takes input or focus. Skipped with Reduce Motion or with the setting off.
@MainActor
final class CelebrationPresenter {
    static let shared = CelebrationPresenter()

    private var lastPoint: (point: CGPoint, at: Date)?
    private var panels: [NSPanel] = []

    /// Where the last completion click happened (screen coordinates), for the burst's origin.
    func noteCompletionPoint(_ point: CGPoint) {
        lastPoint = (point, Date())
    }

    /// Shows a burst at the last completion click (if recent), else near the top of the key window.
    func celebrate() {
        // The Celebrations setting is honoured in Features (no event when off); motion is ours.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let origin: CGPoint
        if let lastPoint, Date().timeIntervalSince(lastPoint.at) < 3 {
            origin = lastPoint.point
        } else if let frame = NSApp.keyWindow?.frame {
            origin = CGPoint(x: frame.midX, y: frame.maxY - frame.height / 3)
        } else {
            return
        }
        show(at: origin)
    }

    private func show(at origin: CGPoint) {
        let side: CGFloat = 320
        let panel = NSPanel(
            contentRect: NSRect(x: origin.x - side / 2, y: origin.y - side / 2, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PetalBurst(start: Date()).frame(width: side, height: side))
        panel.orderFrontRegardless()
        panels.append(panel)
        // At most two bursts at once, like the web.
        if panels.count > 2 { panels.removeFirst().close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + PetalBurst.duration + 0.1) { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let panel else { return }
                panel.close()
                self?.panels.removeAll { $0 === panel }
            }
        }
    }
}

/// 14 petals (the Mekari flower's petal, as on the web) flying out from the centre with a little
/// gravity, spinning and fading.
struct PetalBurst: View {
    static let duration: TimeInterval = 1.2
    static let colors: [Color] = ["#E0257F", "#FF5FA2", "#651FFF", "#8F5CFF", "#B0136B", "#FFD1E6"].map { Color(hex: $0) }
    private static let count = 14

    let start: Date

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = min(1, timeline.date.timeIntervalSince(start) / Self.duration)
                let eased = 1 - pow(1 - t, 3) // ease-out cubic
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in 0..<Self.count {
                    let angle = Double(i) / Double(Self.count) * 2 * .pi + Double(i % 2) * 0.2
                    let distance = 80 + Double((i * 37) % 60)
                    let x = centre.x + cos(angle) * distance * eased
                    let y = centre.y + sin(angle) * distance * eased + 40 * t * t // gravity (y grows down)
                    let spin = Double(i % 2 == 0 ? -1 : 1) * (120 + Double(i) * 12) * eased
                    var petal = context
                    petal.opacity = 1 - t
                    petal.translateBy(x: x, y: y)
                    petal.rotate(by: .degrees(spin))
                    let scale = 0.5 + 0.7 * eased
                    petal.scaleBy(x: scale, y: scale)
                    petal.fill(Self.petalPath, with: .color(Self.colors[i % Self.colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The web's petal (viewBox 0 0 10 14), centred on the origin.
    private static let petalPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 5, y: 0))
        p.addCurve(to: CGPoint(x: 8.6, y: 9.4), control1: CGPoint(x: 7.8, y: 2.6), control2: CGPoint(x: 9.6, y: 6))
        p.addCurve(to: CGPoint(x: 5, y: 14), control1: CGPoint(x: 7.9, y: 11.9), control2: CGPoint(x: 6.4, y: 13.4))
        p.addCurve(to: CGPoint(x: 1.4, y: 9.4), control1: CGPoint(x: 3.6, y: 13.4), control2: CGPoint(x: 2.1, y: 11.9))
        p.addCurve(to: CGPoint(x: 5, y: 0), control1: CGPoint(x: 0.4, y: 6), control2: CGPoint(x: 2.2, y: 2.6))
        p.closeSubpath()
        return p.applying(CGAffineTransform(translationX: -5, y: -7))
    }()
}
