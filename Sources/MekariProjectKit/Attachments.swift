// Swift 5.10's Linux Foundation doesn't mark URL Sendable yet (Darwin's and Swift 6's do).
#if canImport(FoundationNetworking) && compiler(<6.0)
@preconcurrency import Foundation
#else
import Foundation
#endif

// MARK: - Attachments & links (BE SPEC §13, SPEC-MAC §8)

public enum AttachmentKind: OpenEnum, CaseIterable {
  case file, link
  /// A value this build doesn't know (the BE added it later).
  case other(String)

  public static let allCases: [AttachmentKind] = [.file, .link]

  public var rawValue: String {
    switch self {
    case .file: return "FILE"
    case .link: return "LINK"
    case .other(let raw): return raw
    }
  }
}

public enum LinkPreviewStatus: OpenEnum, CaseIterable {
  case pending, ready, failed
  /// A value this build doesn't know (the BE added it later).
  case other(String)

  public static let allCases: [LinkPreviewStatus] = [.pending, .ready, .failed]

  public var rawValue: String {
    switch self {
    case .pending: return "PENDING"
    case .ready: return "READY"
    case .failed: return "FAILED"
    case .other(let raw): return raw
    }
  }
}

/// A file or link on a task or a comment. The `…Path` fields are server-relative; pass them to the API as
/// they are and never build attachment URLs by hand (A11).
public struct Attachment: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var workspaceId: String
  public var taskId: String
  /// nil = task-level.
  public var commentId: String?
  public var kind: AttachmentKind
  public var draft: Bool
  public var uploader: UserSummary
  public var createdAt: Date
  // FILE (nil for LINK)
  public var name: String?
  public var mimeType: String?
  public var size: Int64?
  public var width: Int?
  public var height: Int?
  public var hasThumbnail: Bool
  // LINK (nil for FILE)
  public var url: String?
  public var title: String?
  public var description: String?
  public var siteName: String?
  /// Open string (`google_docs`, `figma`, …); unknown values get the generic badge.
  public var provider: String?
  public var previewStatus: LinkPreviewStatus?
  public var hasIcon: Bool
  public var hasImage: Bool
  public var contentPath: String?
  public var thumbnailPath: String?
  public var iconPath: String?
  public var imagePath: String?

  public init(id: String, workspaceId: String, taskId: String, commentId: String? = nil, kind: AttachmentKind, draft: Bool = false,
              uploader: UserSummary, createdAt: Date, name: String? = nil, mimeType: String? = nil, size: Int64? = nil,
              width: Int? = nil, height: Int? = nil, hasThumbnail: Bool = false, url: String? = nil, title: String? = nil,
              description: String? = nil, siteName: String? = nil, provider: String? = nil,
              previewStatus: LinkPreviewStatus? = nil, hasIcon: Bool = false, hasImage: Bool = false,
              contentPath: String? = nil, thumbnailPath: String? = nil, iconPath: String? = nil, imagePath: String? = nil) {
    self.id = id
    self.workspaceId = workspaceId
    self.taskId = taskId
    self.commentId = commentId
    self.kind = kind
    self.draft = draft
    self.uploader = uploader
    self.createdAt = createdAt
    self.name = name
    self.mimeType = mimeType
    self.size = size
    self.width = width
    self.height = height
    self.hasThumbnail = hasThumbnail
    self.url = url
    self.title = title
    self.description = description
    self.siteName = siteName
    self.provider = provider
    self.previewStatus = previewStatus
    self.hasIcon = hasIcon
    self.hasImage = hasImage
    self.contentPath = contentPath
    self.thumbnailPath = thumbnailPath
    self.iconPath = iconPath
    self.imagePath = imagePath
  }

  private enum CodingKeys: String, CodingKey {
    case id, workspaceId, taskId, commentId, kind, draft, uploader, createdAt, name, mimeType, size, width, height
    case hasThumbnail, url, title, description, siteName, provider, previewStatus, hasIcon, hasImage
    case contentPath, thumbnailPath, iconPath, imagePath
  }

  // Booleans default to false so an attachment of a kind added later (with its own fields) still decodes.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    workspaceId = try c.decode(String.self, forKey: .workspaceId)
    taskId = try c.decode(String.self, forKey: .taskId)
    commentId = try c.decodeIfPresent(String.self, forKey: .commentId)
    kind = try c.decode(AttachmentKind.self, forKey: .kind)
    draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
    uploader = try c.decode(UserSummary.self, forKey: .uploader)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    name = try c.decodeIfPresent(String.self, forKey: .name)
    mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
    size = try c.decodeIfPresent(Int64.self, forKey: .size)
    width = try c.decodeIfPresent(Int.self, forKey: .width)
    height = try c.decodeIfPresent(Int.self, forKey: .height)
    hasThumbnail = try c.decodeIfPresent(Bool.self, forKey: .hasThumbnail) ?? false
    url = try c.decodeIfPresent(String.self, forKey: .url)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
    provider = try c.decodeIfPresent(String.self, forKey: .provider)
    previewStatus = try c.decodeIfPresent(LinkPreviewStatus.self, forKey: .previewStatus)
    hasIcon = try c.decodeIfPresent(Bool.self, forKey: .hasIcon) ?? false
    hasImage = try c.decodeIfPresent(Bool.self, forKey: .hasImage) ?? false
    contentPath = try c.decodeIfPresent(String.self, forKey: .contentPath)
    thumbnailPath = try c.decodeIfPresent(String.self, forKey: .thumbnailPath)
    iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath)
    imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
  }

  // Optional fields are always present in BE JSON (as null); encode them that way too.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(workspaceId, forKey: .workspaceId)
    try c.encode(taskId, forKey: .taskId)
    try c.encode(commentId, forKey: .commentId)
    try c.encode(kind, forKey: .kind)
    try c.encode(draft, forKey: .draft)
    try c.encode(uploader, forKey: .uploader)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encode(name, forKey: .name)
    try c.encode(mimeType, forKey: .mimeType)
    try c.encode(size, forKey: .size)
    try c.encode(width, forKey: .width)
    try c.encode(height, forKey: .height)
    try c.encode(hasThumbnail, forKey: .hasThumbnail)
    try c.encode(url, forKey: .url)
    try c.encode(title, forKey: .title)
    try c.encode(description, forKey: .description)
    try c.encode(siteName, forKey: .siteName)
    try c.encode(provider, forKey: .provider)
    try c.encode(previewStatus, forKey: .previewStatus)
    try c.encode(hasIcon, forKey: .hasIcon)
    try c.encode(hasImage, forKey: .hasImage)
    try c.encode(contentPath, forKey: .contentPath)
    try c.encode(thumbnailPath, forKey: .thumbnailPath)
    try c.encode(iconPath, forKey: .iconPath)
    try c.encode(imagePath, forKey: .imagePath)
  }

  /// The LINK's url, only when it is an absolute http(s) URL with a host. Anything else is never opened.
  public var linkURL: URL? {
    guard kind == .link, let url else { return nil }
    return AttachmentLinks.openable(url)
  }

  /// The LINK's host (lowercased, without "www."), for the card's site line.
  public var host: String? {
    guard let host = linkURL?.host?.lowercased() else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  /// FILE: its name. LINK: its title, else its host, else its url.
  public var displayName: String {
    switch kind {
    case .link:
      if let title, !title.isEmpty { return title }
      return host ?? url ?? "Link"
    default:
      return name ?? "file"
    }
  }

  /// A FILE the server identified as an image (`image/*`).
  public var isImage: Bool {
    kind == .file && (mimeType?.lowercased().hasPrefix("image/") ?? false)
  }

  /// `thumbnailPath` with `?size=` (nil when the server has no thumbnail).
  public func thumbnailPath(size: ThumbnailSize) -> String? {
    guard hasThumbnail, let thumbnailPath else { return nil }
    return thumbnailPath + (thumbnailPath.contains("?") ? "&" : "?") + "size=\(size.rawValue)"
  }
}

public enum ThumbnailSize: String, Sendable, CaseIterable {
  /// Fits 240 px.
  case small
  /// Fits 1600 px.
  case large
}

public enum AttachmentLimits {
  /// A1: 100 MB. Checked before any upload request is made.
  public static let maxUploadBytes: Int64 = 104_857_600
  /// Draft ids on one comment.
  public static let maxPerComment = 20
  /// A12, per user. The client queues the rest instead of collecting 429s.
  public static let maxConcurrentUploads = 3
  /// Shown when a file is over `maxUploadBytes`.
  public static let tooLargeMessage = "Files can be up to 100 MB"

  /// The local pre-check's error: `.payloadTooLarge` with no HTTP status.
  public static func tooLarge() -> APIError {
    APIError(code: .payloadTooLarge, message: tooLargeMessage)
  }
}

/// Bytes moved so far.
public struct TransferProgress: Sendable, Hashable {
  public var completed: Int64
  /// nil when unknown.
  public var total: Int64?

  public init(completed: Int64, total: Int64?) {
    self.completed = completed
    self.total = total
  }

  /// 0…1, nil when the total is unknown.
  public var fraction: Double? {
    guard let total, total > 0 else { return nil }
    return min(1, max(0, Double(completed) / Double(total)))
  }
}

public enum DownloadOutcome: Sendable, Equatable {
  /// 304: the copy the ETag named is still current; the destination was not touched.
  case notModified
  case downloaded(etag: String?)
}

/// Rules for link URLs and attachment paths.
public enum AttachmentLinks {
  /// Every attachment path the API may fetch starts with this (A11: clients never build them).
  public static let pathPrefix = "/api/v1/attachments/"

  /// An absolute http(s) URL with a host, or nil. Only such URLs are ever opened.
  public static func openable(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty else { return nil }
    return url
  }

  /// A server path the client may GET: under `/api/v1/attachments/`, no `..`, no scheme or host.
  public static func isAttachmentPath(_ path: String) -> Bool {
    guard path.hasPrefix(pathPrefix), !path.contains(".."), !path.contains("//"), !path.contains("\\") else { return false }
    return !path.contains(where: { $0.isWhitespace || $0.isNewline })
  }

  /// A file name safe to use as one path component on disk: no separators, controls or leading dots, at most
  /// 200 UTF-8 bytes (keeping the extension); empty → "file".
  public static func safeFileName(_ name: String) -> String {
    var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { scalar in
      !(scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
        || scalar == "/" || scalar == "\\" || scalar == ":")
    }))
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    if cleaned.isEmpty { return "file" }
    guard cleaned.utf8.count > 200 else { return cleaned }
    let ext = (cleaned as NSString).pathExtension
    let suffix = ext.isEmpty || ext.utf8.count > 20 ? "" : "." + ext
    var stem = suffix.isEmpty ? cleaned : String(cleaned.dropLast(suffix.count))
    while stem.utf8.count + suffix.utf8.count > 200 { stem.removeLast() }
    return stem + suffix
  }
}
