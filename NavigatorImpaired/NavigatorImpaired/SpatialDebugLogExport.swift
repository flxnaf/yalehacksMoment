import UIKit

/// Copies or shares `Documents/debug-3d0606.log` (spatial NDJSON) for Cursor / Xcode debugging.
enum SpatialDebugLogExport {
  /// File URL when the log exists (for `ShareLink` / AirDrop).
  static func documentsLogFileURLIfPresent() -> URL? {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return nil
    }
    let p = docs.appendingPathComponent("debug-3d0606.log")
    return FileManager.default.fileExists(atPath: p.path) ? p : nil
  }

  static func copyDocumentsLogToPasteboard() {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      UIPasteboard.general.string = "(no Documents URL)"
      return
    }
    let p = docs.appendingPathComponent("debug-3d0606.log")
    guard FileManager.default.fileExists(atPath: p.path),
          let data = try? Data(contentsOf: p),
          let s = String(data: data, encoding: .utf8),
          !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      UIPasteboard.general.string =
        "(empty or missing — run with spatial audio / beacon so SpatialAudioEngine writes debug-3d0606.log)"
      return
    }
    UIPasteboard.general.string = s
  }
}
