import Foundation

/// The backend a Mekari Project install talks to (SPEC-MAC §4: one server per install in v1).
/// Placeholder for the scaffold; the Kit PR adds the APIClient on top of it.
public struct ServerConfiguration: Equatable, Sendable {
    /// What the user typed on the sign-in screen, e.g. `https://project.mekari.example`.
    public let serverURL: URL

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    /// `serverURL` + `/api/v1`, tolerating a trailing slash on the server URL.
    public var apiBaseURL: URL {
        serverURL.appendingPathComponent("api").appendingPathComponent("v1")
    }

    /// `GET /health`, used to validate the server URL before signing in.
    public var healthURL: URL {
        serverURL.appendingPathComponent("health")
    }
}
