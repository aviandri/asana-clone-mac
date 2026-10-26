// Swift 5.10's Linux Foundation doesn't mark URL Sendable yet (Darwin's and Swift 6's do).
#if canImport(FoundationNetworking) && compiler(<6.0)
@preconcurrency import Foundation
#else
import Foundation
#endif

/// The upload body: one multipart part `file`, written to a temp file so `uploadTask(fromFile:)` streams it.
enum Multipart {
  struct Body: Sendable {
    let url: URL
    let boundary: String
    /// Total bytes.
    let length: Int64
    /// Bytes before the file's first byte (for progress in file bytes).
    let headerLength: Int64
  }

  static let chunkSize = 1 << 20

  static func fileSize(_ file: URL) throws -> Int64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
          (attributes[.type] as? FileAttributeType) != .typeDirectory,
          let size = (attributes[.size] as? NSNumber)?.int64Value else {
      throw APIError(code: .validation, message: "Can't read that file")
    }
    return size
  }

  /// Copies `file` into a temp multipart body in `chunkSize` pieces (never the whole file in memory).
  static func writeTempFile(copying file: URL, fileName: String, directory: URL = FileManager.default.temporaryDirectory) throws -> Body {
    let boundary = "MekariProject-\(UUID().uuidString)"
    let header = Data(("--\(boundary)\r\n" + "Content-Disposition: \(disposition(fileName))\r\n"
      + "Content-Type: application/octet-stream\r\n\r\n").utf8)
    let footer = Data("\r\n--\(boundary)--\r\n".utf8)
    let url = directory.appendingPathComponent("mekari-upload-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw APIError(code: .unknown("client"), message: "Couldn't prepare the upload")
    }
    do {
      let output = try FileHandle(forWritingTo: url)
      defer { try? output.close() }
      guard let input = try? FileHandle(forReadingFrom: file) else { throw APIError(code: .validation, message: "Can't read that file") }
      defer { try? input.close() }
      try output.write(contentsOf: header)
      var copied: Int64 = 0
      while true {
        try Task.checkCancellation()
        guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
        copied += Int64(chunk.count)
        // The file grew after the size check: refuse rather than send more than the server allows.
        guard copied <= AttachmentLimits.maxUploadBytes else { throw AttachmentLimits.tooLarge() }
        try output.write(contentsOf: chunk)
      }
      try output.write(contentsOf: footer)
      return Body(url: url, boundary: boundary, length: Int64(header.count) + copied + Int64(footer.count),
                  headerLength: Int64(header.count))
    } catch {
      try? FileManager.default.removeItem(at: url)
      if error is APIError || error is CancellationError { throw error }
      throw APIError(code: .validation, message: "Can't read that file")
    }
  }

  /// `form-data; name="file"; filename="<UTF-8 name>"`, escaped the way browsers do (HTML's multipart/form-data
  /// encoding: `"` → `%22`, CR → `%0D`, LF → `%0A`). The BE (busboy) reads `filename` as UTF-8 and ignores
  /// `filename*`; the server sanitises the name again anyway.
  static func disposition(_ fileName: String) -> String {
    var escaped = ""
    for scalar in fileName.unicodeScalars {
      switch scalar {
      case "\"": escaped += "%22"
      case "\r": escaped += "%0D"
      case "\n": escaped += "%0A"
      default: escaped.unicodeScalars.append(scalar)
      }
    }
    return "form-data; name=\"file\"; filename=\"\(escaped)\""
  }
}
