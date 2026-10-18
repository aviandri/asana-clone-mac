import Foundation
import MekariProjectKit

public enum LoadState: Equatable, Sendable {
  case idle, loading, loaded
  case failed(APIError)

  public var isLoading: Bool { self == .loading }
}

/// Where the app should go: the task inspector or a project.
public enum NavigationTarget: Hashable, Sendable {
  case task(id: String, projectID: String?)
  case project(id: String)
}

public enum DeepLinkResult: Equatable, Sendable {
  case open(NavigationTarget)
  case noAccess
}

/// Runs the latest scheduled action after a quiet period; earlier ones are cancelled.
@MainActor
final class Debouncer {
  private let clock: any Clock<Duration>
  private let delay: Duration
  private var pending: Task<Void, Never>?

  init(clock: any Clock<Duration>, delay: Duration) {
    self.clock = clock
    self.delay = delay
  }

  func schedule(_ action: @escaping @MainActor () async -> Void) {
    pending?.cancel()
    pending = Task { [clock, delay] in
      do {
        try await clock.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await action()
    }
  }

  func cancel() {
    pending?.cancel()
    pending = nil
  }
}

extension Error {
  /// Every `MekariAPI` error is an `APIError`; anything else is wrapped.
  var asAPIError: APIError {
    (self as? APIError) ?? APIError(code: .unknown("client"), message: localizedDescription)
  }
}
