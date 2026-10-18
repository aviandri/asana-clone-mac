import MekariProjectKit
import SwiftUI

// Small building blocks shared by the screens. Presentation only: no networking, no business rules.

extension Color {
    /// `#RRGGBB` from the BE (workspace, project and avatar colours). Falls back to gray.
    init(hex: String) {
        self = HexColor.rgb(hex).map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .gray
    }
}

enum HexColor {
    /// Parses `#RRGGBB` (or `RRGGBB`) into 0…1 components; nil for anything else.
    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        return (Double((n >> 16) & 0xFF) / 255, Double((n >> 8) & 0xFF) / 255, Double(n & 0xFF) / 255)
    }

    /// White or near-black text, whichever reads better on `hex` (WCAG relative luminance).
    static func prefersDarkText(on hex: String) -> Bool {
        guard let c = rgb(hex) else { return false }
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        return (l + 0.05) / 0.05 > 1.05 / (l + 0.05)
    }
}

enum Initials {
    /// "Alice Johnson" → "AJ", "bob" → "B".
    static func of(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// Round avatar with initials on the user's colour.
@MainActor
struct Avatar: View {
    let user: UserSummary?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let user {
                Text(Initials.of(user.name))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(HexColor.prefersDarkText(on: user.avatarColor) ? Color.black.opacity(0.85) : .white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color(hex: user.avatarColor)))
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Square workspace tile with its initial (Slack-style, like the web).
@MainActor
struct WorkspaceTile: View {
    let name: String
    let color: String
    var size: CGFloat = 22

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased())
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(HexColor.prefersDarkText(on: color) ? Color.black.opacity(0.85) : .white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Color(hex: color)))
            .accessibilityHidden(true)
    }
}

/// "Guest" capsule (SPEC-MAC §5; pickers per W8).
@MainActor
struct GuestPill: View {
    var body: some View {
        Text("Guest")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.orange)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
            .accessibilityLabel("Guest")
    }
}

/// Inline, dismissible error from a store's `lastError`.
@MainActor
struct ErrorBanner: View {
    let error: APIError?
    let dismiss: () -> Void

    var body: some View {
        if let error {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error.message).textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
            .accessibilityElement(children: .combine)
        }
    }
}

/// A transient app-level notice ("Switched to Acme Pilot"), shown at the bottom of the window.
@MainActor
struct NoticeToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 2)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
