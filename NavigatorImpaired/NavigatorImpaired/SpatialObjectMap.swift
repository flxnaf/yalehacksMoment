import Foundation
import simd
import UIKit

struct ScanKeyframe {
  let image: UIImage
  let depthResult: DepthResult
  let cameraPose: simd_float4x4
  let timestamp: Date
}

struct MappedObject {
  let label: String
  let worldPosition: simd_float3
  let confidence: Float
  let lastSeen: Date
}

// MARK: - Persistence

private struct PersistedMappedObject: Codable {
  let label: String
  let x: Float
  let y: Float
  let z: Float
  let confidence: Float
  let lastSeenSince1970: TimeInterval
}

private struct PersistedMapPayload: Codable {
  var objects: [PersistedMappedObject]
}

@MainActor
final class SpatialObjectMap {
  static let shared = SpatialObjectMap()

  private(set) var objects: [MappedObject] = []

  private static var persistenceURL: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("spatial_object_map.json", isDirectory: false)
  }

  private init() {
    loadFromDisk()
  }

  private func loadFromDisk() {
    let url = Self.persistenceURL
    guard let data = try? Data(contentsOf: url) else { return }
    guard let decoded = try? JSONDecoder().decode(PersistedMapPayload.self, from: data) else { return }
    objects = decoded.objects.map { o in
      MappedObject(
        label: o.label,
        worldPosition: simd_float3(o.x, o.y, o.z),
        confidence: o.confidence,
        lastSeen: Date(timeIntervalSince1970: o.lastSeenSince1970)
      )
    }
  }

  private func saveToDisk() {
    let payload = PersistedMapPayload(
      objects: objects.map { o in
        PersistedMappedObject(
          label: o.label,
          x: o.worldPosition.x,
          y: o.worldPosition.y,
          z: o.worldPosition.z,
          confidence: o.confidence,
          lastSeenSince1970: o.lastSeen.timeIntervalSince1970
        )
      }
    )
    do {
      let data = try JSONEncoder().encode(payload)
      try data.write(to: Self.persistenceURL, options: [.atomic])
    } catch {
      NSLog("[SpatialObjectMap] save failed: %@", String(describing: error))
    }
  }

  func upsert(_ object: MappedObject) {
    if let idx = objects.firstIndex(where: {
      $0.label.lowercased() == object.label.lowercased()
        && simd_distance($0.worldPosition, object.worldPosition) < 0.5
    }) {
      objects[idx] = object
    } else {
      objects.append(object)
    }
    saveToDisk()
  }

  func find(query: String) -> MappedObject? {
    let qNorm = Self.normalizeForMatch(query)
    guard !qNorm.isEmpty else { return nil }
    let qCompact = Self.compactAlphanumeric(qNorm)
    let qTokens = Self.matchTokens(from: qNorm)

    var best: (MappedObject, Int)?
    for obj in objects {
      let labelNorm = Self.normalizeForMatch(obj.label)
      let lCompact = Self.compactAlphanumeric(labelNorm)
      let labelTokens = Self.matchTokens(from: labelNorm)

      var score = 0
      if labelNorm == qNorm { score += 100 }
      if !qCompact.isEmpty, qCompact == lCompact { score += 90 }
      if labelNorm.contains(qNorm) { score += 55 }
      if qNorm.contains(labelNorm), labelNorm.count >= 3 { score += 45 }
      if !qCompact.isEmpty, !lCompact.isEmpty {
        if lCompact.contains(qCompact) || qCompact.contains(lCompact) { score += 50 }
      }
      let overlap = qTokens.intersection(labelTokens).count
      score += overlap * 18
      for t in qTokens where t.count >= 3 && labelNorm.contains(t) { score += 12 }

      guard score > 0 else { continue }
      if let cur = best {
        if score > cur.1 { best = (obj, score) }
        else if score == cur.1 {
          if obj.confidence > cur.0.confidence { best = (obj, score) }
          else if obj.confidence == cur.0.confidence, obj.lastSeen > cur.0.lastSeen { best = (obj, score) }
        }
      } else {
        best = (obj, score)
      }
    }
    return best?.0
  }

  /// Lowercase, strip punctuation, collapse whitespace.
  private static func normalizeForMatch(_ raw: String) -> String {
    let lower = raw.lowercased()
    let letters = lower.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    return letters.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func compactAlphanumeric(_ s: String) -> String {
    String(s.filter { $0.isLetter || $0.isNumber })
  }

  private static func matchTokens(from normalized: String) -> Set<String> {
    Set(
      normalized.split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
        .filter { $0.count >= 2 }
    )
  }

  func allObjects() -> [MappedObject] { objects }

  func clear() {
    objects = []
    saveToDisk()
  }
}
