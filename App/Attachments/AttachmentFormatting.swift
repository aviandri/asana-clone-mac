import AppKit
import MekariProjectKit
import SwiftUI
import UniformTypeIdentifiers

/// Presentation helpers for attachments (BE SPEC §13 Clients, same copy as the web app).
enum AttachmentFormatting {
    /// "2.3 MB": binary units, like the 100 MB limit (100 × 1024²).
    static func bytes(_ count: Int64?) -> String {
        guard let count, count >= 0 else { return "" }
        if count < 1024 { return "\(count) B" }
        let units = ["KB", "MB", "GB"]
        var value = Double(count) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        var number = value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        if number.hasSuffix(".0") { number.removeLast(2) }
        return "\(number) \(units[unit])"
    }

    /// The VoiceOver name of a tile: "Attachment, report.pdf, 2.3 MB" / "Link, Design spec".
    static func accessibilityLabel(_ a: Attachment) -> String {
        if a.kind == .link { return "Link, \(a.displayName)" }
        return ["Attachment", a.name ?? "file", bytes(a.size)].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The uniform type of a file attachment: the server-sniffed MIME type first, then the extension.
    static func contentType(mimeType: String?, name: String?) -> UTType {
        if let mime = mimeType?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
           mime != "application/octet-stream", let type = UTType(mimeType: mime) {
            return type
        }
        let ext = (name as NSString?)?.pathExtension ?? ""
        return UTType(filenameExtension: ext) ?? .data
    }

    /// Finder's icon for the file's type (no download needed).
    static func icon(mimeType: String?, name: String?) -> NSImage {
        NSWorkspace.shared.icon(for: contentType(mimeType: mimeType, name: name))
    }

    /// The message for a failed upload or link (web v1.3 copy; 429/507 show the server's words).
    static func errorMessage(_ error: APIError, name: String) -> String {
        switch error.code {
        case .payloadTooLarge:
            return "\(name) is larger than 100 MB."
        case .rateLimited:
            return error.status != nil && !error.message.isEmpty ? error.message : "Too many uploads. Try again in a few minutes."
        case .insufficientStorage:
            return error.status != nil && !error.message.isEmpty ? error.message : "The server is out of storage space. Try again later."
        case .forbidden:
            return "You can't add attachments here."
        default:
            return error.message.isEmpty ? "Upload failed." : error.message
        }
    }

    /// Whether Retry can help (a file over the limit stays over it).
    static func isRetryable(_ error: APIError) -> Bool {
        error.code != .payloadTooLarge && error.code != .forbidden
    }

    static let commentFullMessage = "A comment can have up to \(AttachmentLimits.maxPerComment) attachments."

    /// The problem with an Add Link error, for the popover: the server's (or local) issue on `url`, else its message.
    static func linkProblem(_ error: Error) -> String {
        guard let error = error as? APIError else { return "Couldn't add the link." }
        if let issue = error.issue(for: "url") { return issue.message }
        return error.message.isEmpty ? "Couldn't add the link." : error.message
    }
}

/// The §13 link providers as neutral, app-drawn badges (A11: initials + name, no third-party logos; the
/// web and Android apps use the same set). Unknown providers get the generic link glyph.
struct ProviderBadge: Equatable {
    let name: String
    let initials: String
    let tone: Color

    static func of(_ provider: String?) -> ProviderBadge? {
        provider.flatMap { all[$0] }
    }

    private static let all: [String: ProviderBadge] = [
        "google_drive": ProviderBadge(name: "Google Drive", initials: "Dr", tone: .green),
        "google_docs": ProviderBadge(name: "Google Docs", initials: "Do", tone: Color(red: 0.01, green: 0.52, blue: 0.78)),
        "google_sheets": ProviderBadge(name: "Google Sheets", initials: "Sh", tone: Color(red: 0.02, green: 0.59, blue: 0.41)),
        "google_slides": ProviderBadge(name: "Google Slides", initials: "Sl", tone: Color(red: 0.96, green: 0.62, blue: 0.04)),
        "dropbox": ProviderBadge(name: "Dropbox", initials: "Db", tone: Color(red: 0.01, green: 0.41, blue: 0.63)),
        "onedrive": ProviderBadge(name: "OneDrive", initials: "Od", tone: Color(red: 0.05, green: 0.65, blue: 0.91)),
        "box": ProviderBadge(name: "Box", initials: "Bx", tone: Color(red: 0.03, green: 0.35, blue: 0.52)),
        "figma": ProviderBadge(name: "Figma", initials: "Fg", tone: Color(red: 0.49, green: 0.23, blue: 0.93)),
        "youtube": ProviderBadge(name: "YouTube", initials: "Yt", tone: Color(red: 0.86, green: 0.15, blue: 0.15)),
        "loom": ProviderBadge(name: "Loom", initials: "Lm", tone: Color(red: 0.31, green: 0.27, blue: 0.9)),
        "github": ProviderBadge(name: "GitHub", initials: "Gh", tone: Color(red: 0.07, green: 0.09, blue: 0.15)),
        "gitlab": ProviderBadge(name: "GitLab", initials: "Gl", tone: Color(red: 0.92, green: 0.35, blue: 0.05)),
        "notion": ProviderBadge(name: "Notion", initials: "No", tone: Color(red: 0.12, green: 0.16, blue: 0.22)),
        "miro": ProviderBadge(name: "Miro", initials: "Mi", tone: Color(red: 0.92, green: 0.7, blue: 0.03)),
        "jira": ProviderBadge(name: "Jira", initials: "Ji", tone: Color(red: 0.11, green: 0.31, blue: 0.85)),
        "confluence": ProviderBadge(name: "Confluence", initials: "Cf", tone: Color(red: 0.15, green: 0.39, blue: 0.92)),
        "slack": ProviderBadge(name: "Slack", initials: "Sk", tone: Color(red: 0.64, green: 0.11, blue: 0.69)),
        "zoom": ProviderBadge(name: "Zoom", initials: "Zm", tone: Color(red: 0.23, green: 0.51, blue: 0.96)),
    ]
}
