import Foundation

/// Distance-based ping cadence and 8-zone bearing snap (single shared `AVAudioEngine` — no second engine).
enum SheikahPinger {
    /// Sonar-style cadence: fast when close (~0.3 s), slower when far (caps at 2 s). Used for nav + object beacons.
    static func sheikahInterval(distanceMeters: Float) -> Float {
        let d = max(0.5, distanceMeters)
        return min(2.0, max(0.3, d * 0.4))
    }

    /// Snap relative bearing to nearest 45° bin (listener-relative, degrees).
    static func snapToZone(relativeBearingDegrees: Float) -> Float {
        let z = round(relativeBearingDegrees / 45) * 45
        var v = z
        while v > 180 { v -= 360 }
        while v < -180 { v += 360 }
        return v
    }
}
