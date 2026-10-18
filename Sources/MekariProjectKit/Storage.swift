import Foundation
#if canImport(Security)
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

#if canImport(Security)
/// The Keychain (generic password, service "com.mekari.project"). The account is the server host,
/// so signing in to a different server never reuses a token.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
  private let service = "com.mekari.project"
  private let account: String

  public init(account: String) {
    self.account = account
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  public func load() -> String? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public func save(_ token: String) {
    let data = Data(token.utf8)
    let update = [kSecValueData as String: data]
    if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      SecItemAdd(add as CFDictionary, nil)
    }
  }

  public func clear() {
    SecItemDelete(query as CFDictionary)
  }
}
#endif

/// The one server this install talks to (SPEC-MAC §4).
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
