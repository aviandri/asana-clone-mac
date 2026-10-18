import Foundation
import MekariProjectKit
import XCTest
@testable import MekariProjectFeatures

/// A clock that only moves when the test calls `advance(by:)`.
final class TestClock: Clock, @unchecked Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration
    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper {
    let id: Int
    let deadline: Instant
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var current = Instant(offset: .zero)
  private var sleepers: [Sleeper] = []
  private var nextID = 0

  var now: Instant { lock.lock(); defer { lock.unlock() }; return current }
  var minimumResolution: Duration { .zero }

  /// How many tasks are waiting on this clock.
  var sleeperCount: Int { lock.lock(); defer { lock.unlock() }; return sleepers.count }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    guard let id = reserve(deadline) else { return }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if !park(Sleeper(id: id, deadline: deadline, continuation: continuation)) {
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      wake(id: id)?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Lets pending work reach its sleep, moves time forward, wakes every sleeper that is due, then
  /// lets them run.
  @MainActor
  func advance(by duration: Duration) async {
    await settle()
    takeDue(after: duration).forEach { $0.continuation.resume() }
    await settle()
  }

  // Locking lives in synchronous helpers (NSLock isn't allowed directly in async code).

  private func reserve(_ deadline: Instant) -> Int? {
    lock.lock(); defer { lock.unlock() }
    guard deadline > current else { return nil }
    nextID += 1
    return nextID
  }

  private func park(_ sleeper: Sleeper) -> Bool {
    lock.lock(); defer { lock.unlock() }
    if Task.isCancelled { return false }
    sleepers.append(sleeper)
    return true
  }

  private func wake(id: Int) -> Sleeper? {
    lock.lock(); defer { lock.unlock() }
    guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
    return sleepers.remove(at: i)
  }

  private func takeDue(after duration: Duration) -> [Sleeper] {
    lock.lock(); defer { lock.unlock() }
    current = current.advanced(by: duration)
    let due = sleepers.filter { $0.deadline <= current }
    sleepers.removeAll { $0.deadline <= current }
    return due
  }
}

/// Lets queued main-actor work (event loops, debounced actions, fake latency) run.
@MainActor
func settle(_ rounds: Int = 50) async {
  for _ in 0..<rounds { await Task.yield() }
}

/// A fixed "today" for bucket tests: 2026-10-18 at noon, Jakarta.
enum TestTime {
  static let today = LocalDate(year: 2026, month: 10, day: 18)
  static let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Jakarta")!
    return c
  }()
  static let now: Date = today.date(in: calendar).addingTimeInterval(12 * 3600)
}

func demoFake(as email: String? = "alice@example.com") -> FakeMekariAPI {
  FakeMekariAPI(seed: .demo(today: TestTime.today), signedInAs: email)
}

let alice = UserSummary(id: DemoIDs.alice, name: "Alice Johnson", email: "alice@example.com", avatarColor: "#e8384f")
let bob = UserSummary(id: DemoIDs.bob, name: "Bob Smith", email: "bob@example.com", avatarColor: "#20aaea")

/// A signed-in session on the demo fake, current workspace Mekari.
@MainActor
func signedInSession(_ fake: FakeMekariAPI, clock: TestClock = TestClock()) async -> AppSession {
  let session = AppSession(settings: InMemoryServerSettings(serverURL: URL(string: "https://demo.invalid")),
                           tokens: InMemoryTokenStore(), apiFactory: { _, _ in fake }, clock: clock,
                           calendar: TestTime.calendar, now: { TestTime.now })
  await session.start()
  await settle()
  return session
}

/// Yields until `condition` holds (bounded; fails the test instead of hanging).
@MainActor
func waitUntil(_ what: String = "condition", file: StaticString = #filePath, line: UInt = #line,
               _ condition: @MainActor () async -> Bool) async {
  for _ in 0..<2_000 {
    if await condition() { return }
    await Task.yield()
  }
  XCTFail("timed out waiting for \(what)", file: file, line: line)
}
