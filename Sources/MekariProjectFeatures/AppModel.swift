import MekariProjectKit
import Observation

/// Root app state. Placeholder for the scaffold; the Features PR replaces it with the session,
/// workspace and list stores (SPEC-MAC §3: Features imports Kit and Observation only).
@MainActor
@Observable
public final class AppModel {
    public private(set) var server: ServerConfiguration?

    public init(server: ServerConfiguration? = nil) {
        self.server = server
    }

    public var greeting: String {
        server.map { "Hello from Mekari Project (\($0.serverURL.host ?? "server"))" } ?? "Hello from Mekari Project"
    }

    public func connect(to server: ServerConfiguration) {
        self.server = server
    }
}
