import Foundation
#if canImport(Security)
import os
import Security
#endif

/// Where the session token (`sid`) lives between launches.
public protocol TokenStore: Sendable {
  func load() -> String?
  func save(_ token: String)
  func clear()
}

/// For Linux, tests, previews and UI tests.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: String?

  public init(token: String? = nil) {
    self.token = token
  }

  public func load() -> String? { lock.locked { token } }
  public func save(_ token: String) { lock.locked { self.token = token } }
  public func clear() { lock.locked { token = nil } }
}

/// Raw secure storage for one secret, as OSStatus-style results (0 = success).
public protocol SecretBackend: Sendable {
  /// The stored secret; a non-success status (denied, missing, …) when there is none to read.
  func read() -> (status: Int32, value: String?)
  func update(_ value: String) -> Int32
  func add(_ value: String) -> Int32
  func delete() -> Int32
}

public enum SecretStatus {
  public static let success: Int32 = 0          // errSecSuccess
  public static let itemNotFound: Int32 = -25300 // errSecItemNotFound
}

/// A `TokenStore` that reads its backend ONCE (at init) and writes through on save/clear. With the
/// Keychain and an ad-hoc signed app, every read can raise a "wants to use confidential information"
/// prompt after an update; reading once keeps that to at most one per launch.
///
/// - A failed or denied read counts as signed out; signing in writes the item again.
/// - Save: update; if the item is missing, add; on any other failure, delete and add.
/// - Only status codes are logged, never the token.
public final class CachedTokenStore: TokenStore, @unchecked Sendable {
  private let backend: SecretBackend
  private let log: @Sendable (String) -> Void
  private let lock = NSLock()
  private var token: String?

  public init(backend: SecretBackend, log: @escaping @Sendable (String) -> Void = { _ in }) {
    self.backend = backend
    self.log = log
    let (status, value) = backend.read()
    if status != SecretStatus.success, status != SecretStatus.itemNotFound { log("token read failed: \(status)") }
    token = status == SecretStatus.success ? value : nil
  }

  public func load() -> String? { lock.locked { token } }

  public func save(_ token: String) {
    lock.locked { self.token = token }
    var status = backend.update(token)
    if status == SecretStatus.itemNotFound {
      status = backend.add(token)
    } else if status != SecretStatus.success {
      log("token update failed: \(status); re-adding")
      _ = backend.delete()
      status = backend.add(token)
    }
    if status != SecretStatus.success { log("token save failed: \(status)") }
  }

  public func clear() {
    lock.locked { token = nil }
    let status = backend.delete()
    if status != SecretStatus.success, status != SecretStatus.itemNotFound { log("token delete failed: \(status)") }
  }
}

#if canImport(Security)
/// The Keychain item for the session token (generic password, service "com.mekari.project").
public struct KeychainSecretBackend: SecretBackend {
  private let service = "com.mekari.project"
  private let account: String

  public init(account: String) {
    self.account = account
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  public func read() -> (status: Int32, value: String?) {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return (status, nil) }
    return (status, String(data: data, encoding: .utf8))
  }

  public func update(_ value: String) -> Int32 {
    SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
  }

  public func add(_ value: String) -> Int32 {
    var add = query
    add[kSecValueData as String] = Data(value.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(add as CFDictionary, nil)
  }

  public func delete() -> Int32 {
    SecItemDelete(query as CFDictionary)
  }
}

/// The app's token store: the Keychain, read once at launch, written through (see `CachedTokenStore`).
/// One server per install, so the app uses a fixed account (e.g. "session"); signing out to change
/// servers clears it.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
  private let store: CachedTokenStore

  public init(account: String) {
    store = CachedTokenStore(backend: KeychainSecretBackend(account: account)) { message in
      // Made per call: `Logger` isn't Sendable in the macOS 14 SDK (Xcode 15.4), so a shared one
      // can't be a global or be captured here. Only Keychain failures get here, so it's cheap.
      Logger(subsystem: "com.mekari.project", category: "keychain").error("\(message, privacy: .public)")
    }
  }

  public func load() -> String? { store.load() }
  public func save(_ token: String) { store.save(token) }
  public func clear() { store.clear() }
}

#endif

/// The one server this install talks to (SPEC-MAC §4). Setting it must persist before returning: sign-in
/// stores the URL, then the token, and relies on that order.
public protocol ServerSettings: AnyObject, Sendable {
  var serverURL: URL? { get set }
}

public final class UserDefaultsServerSettings: ServerSettings, @unchecked Sendable {
  private let defaults: UserDefaults
  private let key = "serverURL"

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var serverURL: URL? {
    get { defaults.string(forKey: key).flatMap(URL.init(string:)) }
    set { defaults.set(newValue?.absoluteString, forKey: key) }
  }
}

public final class InMemoryServerSettings: ServerSettings, @unchecked Sendable {
  private let lock = NSLock()
  private var url: URL?

  public init(serverURL: URL? = nil) {
    url = serverURL
  }

  public var serverURL: URL? {
    get { lock.locked { url } }
    set { lock.locked { url = newValue } }
  }
}

extension NSLock {
  /// Like `withLock` (not on every Linux Foundation); named differently to avoid ambiguity where it exists.
  @inline(__always)
  func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
