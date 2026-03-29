import Foundation

/// Distance-based ping cadence and 8-zone bearing snap (single shared `AVAudioEngine` — no second engine).
enum SheikahPinger {
    /// Shorter interval when closer to the current ping target (seconds).
    static func sheikahInterval(distanceMeters: Float) -> Float {
        let d = max(3, distanceMeters)
        if d > 80 { return 3.0 }
        if d > 40 { return 2.2 }
        if d > 20 { return 1.5 }
        if d > 10 { return 1.1 }
        return 0.85
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
