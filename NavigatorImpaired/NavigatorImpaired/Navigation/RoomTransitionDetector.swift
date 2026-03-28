import Foundation

/// Detects room transitions by monitoring the depth profile for doorway → open
/// space patterns, and tracks the entry heading so the user can be guided back.
///
/// A "doorway" requires a very specific pattern: most of the frame is blocked
/// (>65%) with only a narrow sliver of clearance — a real door frame, not just
/// a corridor with walls on the sides.
///
/// Conservative by design: it's better to miss a real room entry than to
/// constantly announce false transitions.
@MainActor
final class RoomTransitionDetector {

    // MARK: - Published state

    struct RoomState {
        let inRoom: Bool
        let entryHeading: Float?
        let secondsSinceEntry: Float?
    }

    private(set) var currentState = RoomState(inRoom: false, entryHeading: nil, secondsSinceEntry: nil)

    // MARK: - Configuration (conservative)

    /// Doorway: at least 65% of columns must be blocked — corridors typically
    /// only block ~40-50% (the two walls), so this filters them out.
    private let doorwayMinBlockedFraction: Float = 0.65
    /// The clear gap in a doorway must be narrow (≤30% of frame width).
    private let doorwayMaxGapFraction: Float = 0.30
    /// "Open space" requires ≥70% of columns to be clear.
    private let openMinClearFraction: Float = 0.70
    /// Need 6 consecutive doorway frames (~0.6s at 10Hz) — transient occlusions won't trigger.
    private let requiredDoorwayFrames = 6
    /// Need 8 consecutive open frames after the doorway.
    private let requiredOpenFrames = 8
    /// Don't allow re-entry within 15 seconds of leaving.
    private let exitCooldown: TimeInterval = 15
    /// Must be in the room for at least 5 seconds before exit can be detected.
    private let minTimeInRoom: TimeInterval = 5

    // MARK: - Internal state

    private var doorwayFrameCount = 0
    private var openFrameCount = 0
    private var sawDoorway = false
    private var entryHeading: Float?
    private var entryTime: Date?
    private var lastExitTime: Date = .distantPast
    private var inRoom = false

    // MARK: - API

    func update(profile: [Float], clearThreshold: Float, heading: Float) -> String? {
        let n = profile.count
        guard n >= 6 else { return nil }

        let clearCount = profile.filter { $0 < clearThreshold }.count
        let clearFrac = Float(clearCount) / Float(n)
        let blockedFrac = 1.0 - clearFrac

        // Additional doorway check: the gap must be contiguous and centered-ish.
        // A corridor has gaps spread across the center third; a real doorway is
        // a single narrow slot.
        let hasNarrowContiguousGap = checkContiguousGap(
            profile: profile, clearThreshold: clearThreshold, maxGapFraction: doorwayMaxGapFraction
        )

        let now = Date()

        let isDoorway = blockedFrac >= doorwayMinBlockedFraction
            && clearFrac > 0.05
            && clearFrac <= doorwayMaxGapFraction
            && hasNarrowContiguousGap

        let isOpen = clearFrac >= openMinClearFraction

        if isDoorway {
            doorwayFrameCount += 1
            openFrameCount = 0
        } else if isOpen {
            openFrameCount += 1
            if doorwayFrameCount >= requiredDoorwayFrames {
                sawDoorway = true
            }
            doorwayFrameCount = 0
        } else {
            // Decay counters — ambiguous frames erode confidence
            doorwayFrameCount = max(0, doorwayFrameCount - 2)
            openFrameCount = max(0, openFrameCount - 2)
        }

        // Room entry: saw a doorway then sustained open space
        if sawDoorway && openFrameCount >= requiredOpenFrames && !inRoom {
            guard now.timeIntervalSince(lastExitTime) > exitCooldown else {
                sawDoorway = false
                return nil
            }
            inRoom = true
            entryHeading = heading
            entryTime = now
            sawDoorway = false
            updatePublishedState(now: now)
            return "Entered new room. Turn around to exit."
        }

        // Room exit: must have been in room for minimum time
        if inRoom && sawDoorway && openFrameCount >= requiredOpenFrames {
            if let entry = entryTime, now.timeIntervalSince(entry) >= minTimeInRoom {
                inRoom = false
                lastExitTime = now
                entryHeading = nil
                entryTime = nil
                sawDoorway = false
                updatePublishedState(now: now)
                return "Left room."
            } else {
                sawDoorway = false
            }
        }

        updatePublishedState(now: now)
        return nil
    }

    func exitBearingDegrees(currentHeading: Float) -> Float? {
        guard inRoom, let entry = entryHeading else { return nil }
        let exitBearing = entry + .pi
        var diff = exitBearing - currentHeading
        while diff > .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        return diff * 180 / .pi
    }

    func reset() {
        doorwayFrameCount = 0
        openFrameCount = 0
        sawDoorway = false
        inRoom = false
        entryHeading = nil
        entryTime = nil
        currentState = RoomState(inRoom: false, entryHeading: nil, secondsSinceEntry: nil)
    }

    // MARK: - Private

    /// Returns true only if there is exactly one contiguous run of clear columns
    /// and it's narrower than `maxGapFraction` of the total profile width.
    private func checkContiguousGap(profile: [Float], clearThreshold: Float, maxGapFraction: Float) -> Bool {
        let n = profile.count
        var gapCount = 0
        var inGap = false
        var gapWidth = 0
        var maxWidth = 0

        for i in 0..<n {
            if profile[i] < clearThreshold {
                if !inGap {
                    inGap = true
                    gapWidth = 0
                    gapCount += 1
                }
                gapWidth += 1
            } else {
                if inGap {
                    maxWidth = max(maxWidth, gapWidth)
                    inGap = false
                }
            }
        }
        if inGap { maxWidth = max(maxWidth, gapWidth) }

        // Must be exactly 1 gap (not multiple scattered clear columns)
        // and the gap must be narrow
        let gapFrac = Float(maxWidth) / Float(n)
        return gapCount == 1 && gapFrac <= maxGapFraction
    }

    private func updatePublishedState(now: Date) {
        let elapsed = entryTime.map { Float(now.timeIntervalSince($0)) }
        currentState = RoomState(
            inRoom: inRoom,
            entryHeading: entryHeading,
            secondsSinceEntry: elapsed
        )
    }
}
