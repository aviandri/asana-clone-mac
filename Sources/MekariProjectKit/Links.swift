import Foundation

/// Web app URLs for "Open in Browser" (SPEC-MAC §5). Every link carries `?workspace=<id>` so the web
/// app opens in the same workspace.
public enum WebLinks {
  public static func project(_ id: String, server: URL, workspace: String) -> URL {
    url(server, path: "/projects/\(id)", query: [("workspace", workspace)])
  }

  public static func task(_ task: TaskItem, server: URL, workspace: String) -> URL {
    if let projectID = task.projectId {
      return url(server, path: "/projects/\(projectID)", query: [("task", task.id), ("workspace", workspace)])
    }
    return url(server, path: "/my-tasks", query: [("task", task.id), ("workspace", workspace)])
  }

  public static func workspaceSettings(server: URL, workspace: String) -> URL {
    url(server, path: "/workspace/settings", query: [("workspace", workspace)])
  }

  /// Invites are accepted on the web in v1.
  public static func acceptInvite(server: URL) -> URL {
    url(server, path: "/login", query: [])
  }

  /// `server` + `path`, keeping any query already in `path`, plus `?workspace=` when given.
  public static func url(_ server: URL, path: String, workspace: String?) -> URL {
    let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
    var query: [(String, String)] = []
    if parts.count == 2 {
      for pair in parts[1].split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        query.append((kv[0], kv.count > 1 ? kv[1] : ""))
      }
    }
    if let workspace { query.append(("workspace", workspace)) }
    return url(server, path: parts[0], query: query)
  }

  private static func url(_ server: URL, path: String, query: [(String, String)]) -> URL {
    var components = URLComponents(url: server, resolvingAgainstBaseURL: false) ?? URLComponents()
    let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
    components.path = base + (path.hasPrefix("/") ? path : "/" + path)
    components.percentEncodedQuery = query.isEmpty ? nil : query.map { "\(QueryEncoding.encode($0.0))=\(QueryEncoding.encode($0.1))" }
      .joined(separator: "&")
    return components.url ?? server
  }
}

/// `mekariproject://task/<id>` and `mekariproject://project/<id>` (SPEC-MAC §5). The id must be a
/// UUID (as the BE issues them), so nothing else (e.g. `..%2Fusers`) can reach a request path.
public enum DeepLink: Hashable, Sendable {
  case task(id: String)
  case project(id: String)

  public static let scheme = "mekariproject"

  public init?(url: URL) {
    guard url.scheme?.lowercased() == DeepLink.scheme, let kind = url.host?.lowercased() else { return nil }
    let segments = url.pathComponents.filter { $0 != "/" }
    guard segments.count == 1, let uuid = UUID(uuidString: segments[0]) else { return nil }
    let id = uuid.uuidString.lowercased()
    switch kind {
    case "task": self = .task(id: id)
    case "project": self = .project(id: id)
    default: return nil
    }
  }

  public var url: URL {
    switch self {
    case .task(let id): return URL(string: "\(DeepLink.scheme)://task/\(id)")!
    case .project(let id): return URL(string: "\(DeepLink.scheme)://project/\(id)")!
    }
  }
}

/// Float positions for ordering tasks and sections (BE §2): between neighbours `(a+b)/2`, after the
/// last `last+1000`, before the first `first/2`.
public enum Reorder {
  public static let step: Double = 1000
  /// Below this gap between neighbours, the list should be renumbered first.
  public static let minimumGap: Double = 1e-6

  public static func position(between before: Double?, and after: Double?) -> Double {
    switch (before, after) {
    case (nil, nil): return step
    case (let b?, nil): return b + step
    case (nil, let a?): return a > 0 ? a / 2 : a - step
    case (let b?, let a?): return (b + a) / 2
    }
  }

  /// Whether a position between `before` and `after` would be too close to a neighbour.
  public static func needsRenumbering(between before: Double?, and after: Double?) -> Bool {
    guard let b = before, let a = after else {
      if let a = after { return a > 0 && a / 2 < minimumGap }
      return false
    }
    return a - b < minimumGap * 2
  }

  /// Even positions (`step`, `2*step`, …) for `count` items.
  public static func renumbered(count: Int) -> [Double] {
    (0..<count).map { Double($0 + 1) * step }
  }
}
