# Audio Revamp: Diagnosis and Plan

**Location:** `NavigatorImpaired/docs/AUDIO_REVAMP_DIAGNOSIS_AND_PLAN.md`  
**Companion doc:** [`AUDIO_CLARITY_NAVIGATION.md`](AUDIO_CLARITY_NAVIGATION.md) — covers nav/TTS ducking (Phases A–E).  
**Status:** Awaiting approval before any code changes.

**Repo note (Yalehacks iOS):** Spatial rendering uses `AVAudioEngine` + `AVAudioEnvironmentNode` (HRTF). Where this plan refers to “Resonance Audio” sources, interpret as **spatialized nodes in that graph** (not the separate Google Resonance SDK). v1 column depths may come from on-device `ColumnDepthSampler`; Modal `column_depths` matches Phase 1 when the backend ships.

---

## 1. How the CV Pipeline Already Works

The depth-to-obstacle chain runs at 10 Hz and already produces everything the audio system needs. The problem is not the CV — it is how its output reaches the speaker.

```
Camera frame (1920×1080)
    │
    ▼
Depth-Anything-V2  (Modal A100, ~40–60 ms)
    │  → depth_map: [H × W] floats, 0–10 m
    ▼
ObstacleDetector  (Modal, ~10–20 ms)
    │
    ├─ _compute_zones()
    │    splits depth_map into 3 vertical strips (left / center / right)
    │    per zone:
    │      min_dist    — nearest pixel
    │      mean_dist   — average depth
    │      clearance   — fraction of pixels > 2.0 m
    │      status      — critical (<0.5 m) / warning (<1.0 m)
    │                    / caution (<2.0 m) / safe (≥2.0 m)
    │
    ├─ _compute_steering()   (Shepherd gap-seeking)
    │    center safe & clear  → "straight"
    │    else best clearance  → "left" / "right"
    │    all blocked          → "stop"
    │    → recommended_direction
    │
    └─ _compute_urgency()
         global nearest across all zones:
           <0.5 m → 1.0    <1.0 m → 0.7
           <2.0 m → 0.4    ≥2.0 m → 0.1
         → urgency (scalar)
    │
    ▼
FusedNavigator  (iOS, when GPS route active)
    │  merges recommended_direction + urgency + GPS bearing
    │  → final_command, voice_instruction, audio_beacon_azimuth
    ▼
┌──────────────────────────────────────┐
│  AUDIO RENDERING  ← broken part     │
└──────────────────────────────────────┘
```

### What the pipeline gives us

Two levels of output, both useful:

1. **High-level decision** — `recommended_direction`, `urgency`, per-zone `status`. This tells us the *policy state*: is the scene safe, cautious, or critical? Where should the user walk?

2. **Raw depth map** — the full `[H × W]` grid. This contains the *angular detail*: exactly where obstacles are across the horizontal field of view, at pixel-level resolution.

The existing audio system uses neither level well. It pipes the depth map through `WorldObstacleMap` (a 360° bearing buffer with slow decay), inflates it into 8 continuous sub-bass voices, and ignores the high-level decision entirely. The result is a wall of sound that contradicts the algorithm's own judgment about whether the scene is safe.

---

## 2. Diagnosis

### 2.1  The algorithm says "safe"; the audio drones

When all three zones report safe status (min_dist > 2.0 m, clearance > 0.7), urgency is 0.1. This should produce near-silence. Instead, `WorldObstacleMap` bins from previous frames linger above `presenceThreshold` (0.35) for ~3.7 seconds (decay 0.985 at ~60 Hz). The audio plays obstacle sounds for obstacles the algorithm no longer considers relevant.

### 2.2  The algorithm says 3 zones; the audio plays 8 voices

The `WorldObstacleMap` bins into a 360° bearing field and ranks the top 8 above threshold. In any indoor space with walls on multiple sides, all 8 slots fill. But the camera only covers ~60–90° of forward FOV. The 360° map persists and interpolates data the algorithm never produced with high confidence. Result: phantom audio from behind and beside the user.

### 2.3  Continuous modulation overloads the ear

Each `SubBassObstacleVoice` runs a breathing amplitude envelope plus a depth-driven pulse rate (0.4–3 Hz). Eight of these at once, each modulating independently, creates a churning low-frequency texture that the brain cannot parse into discrete spatial cues. It reads as dizziness, not navigation.

### 2.4  Depth noise causes false critical alerts

`min_dist` per zone is the single nearest pixel. Monocular depth estimation has per-frame jitter at edges and reflective surfaces. One noisy pixel at 0.4 m in an otherwise clear zone triggers `critical` status and urgency 1.0. The zone's `clearance` and `mean_dist` are robust aggregates, but `min_dist` — which drives urgency — is an outlier-sensitive metric.

### 2.5  Beacon and obstacle layers have no mutual awareness

`ChordBeaconVoice` plays a sustained pad with reverb. The obstacle voices play sustained sub-bass. Both are always on. Nothing decides which one the user should attend to right now. When `recommended_direction` is "straight" and urgency is low, the user hears two competing layers both saying "you're fine" in different timbres.

---

## 3. Design Goals

**G1 — Audio mirrors the algorithm.** The CV produces a structured decision. The audio should render *that decision*, not elaborate beyond it.

**G2 — Calm by default.** When the algorithm says safe (urgency ≤ 0.1), the speaker should be quiet or silent. The absence of sound is information.

**G3 — One primary attention target.** At any moment the user hears one main thing: the beacon (safe path), a warning (obstacle), or speech (instruction). Secondary cues exist at reduced salience but never compete with the primary.

**G4 — Urgency maps to intensity, not polyphony.** Danger makes one cue louder/faster/harsher — it does not add more simultaneous sources.

**G5 — Angular precision up to the ear's limit.** Binaural audio through glasses speakers can resolve ~5–7 positions in the frontal arc. Use that resolution. Don't snap to 3 coarse zones (too vague) or scatter across 8 (too many to parse).

---

## 4. The Approach: Column-Based Obstacle Audio

### 4.1  From depth map to angular columns

Instead of the `ObstacleDetector`'s 3 zones or `WorldObstacleMap`'s 360° bins, divide the depth map into **6 vertical columns** across the camera's horizontal FOV.

```
Camera FOV (~70° horizontal)
┌──────┬──────┬──────┬──────┬──────┬──────┐
│ col0 │ col1 │ col2 │ col3 │ col4 │ col5 │
│ –35° │ –21° │  –7° │  +7° │ +21° │ +35° │
│ far  │ far  │ near │ near │ far  │ far  │   ← example scene
│ left │      │      │      │      │ right│
└──────┴──────┴──────┴──────┴──────┴──────┘
```

Per column, compute one number: **effective nearest distance**. Not `min` (too noisy); instead the **5th-percentile depth** across all pixels in that column. This rejects single-pixel outliers while still catching real obstacles that occupy meaningful screen area.

```python
# On Modal, inside ObstacleDetector or a new function alongside it
def compute_column_depths(depth_map, num_columns=6):
    """
    Returns list of 6 floats: 5th-percentile depth per column.
    """
    H, W = depth_map.shape
    col_width = W // num_columns
    column_depths = []
    for i in range(num_columns):
        col = depth_map[:, i * col_width : (i + 1) * col_width]
        # 5th percentile: catches real obstacles, rejects pixel noise
        p5 = np.percentile(col, 5)
        column_depths.append(float(p5))
    return column_depths
```

This is **~3 lines of NumPy** added to the existing Modal endpoint. It returns alongside the existing zone data — doesn't replace it.

### 4.2  Why 6 columns

- **Psychoacoustics:** Binaural audio through small speakers reliably resolves 5–7 frontal positions. 6 is inside that range. 3 wastes resolution the ear can use. 8+ causes sources to blur.
- **Computational cost:** 6 percentile calculations on the existing depth map. Negligible.
- **Semantic clarity:** 6 columns at ~12° spacing means an obstacle at –30° sounds distinctly different from one at –10°. With 3 zones, both would be "left."
- **Governed polyphony:** Even with 6 available positions, the policy (Section 5) caps how many play simultaneously. 6 is capacity, not default.

### 4.3  Column-to-audio mapping

Each column maps to one spatial source at a fixed azimuth (HRTF via `AVAudioEnvironmentNode`). Sources are **silent by default** and only activate when their column's depth crosses a threshold.

| Column | Azimuth | When active | Ping rate |
|--------|---------|------------|-----------|
| col0 | –35° | depth < 2.0 m | from depth |
| col1 | –21° | depth < 2.0 m | from depth |
| col2 | –7° | depth < 2.0 m | from depth |
| col3 | +7° | depth < 2.0 m | from depth |
| col4 | +21° | depth < 2.0 m | from depth |
| col5 | +35° | depth < 2.0 m | from depth |

**Ping rate curve** (same thresholds as `ObstacleDetector`):

```
depth ≥ 2.0 m  →  silent           (safe — nothing to report)
depth 1.0–2.0  →  0.75 Hz          (caution — slow tick)
depth 0.5–1.0  →  2.0 Hz           (warning — attention)
depth < 0.5 m  →  4.0 Hz           (critical — act now)
```

**Ping sound:** 50 ms burst, square wave. Frequency encodes distance:

```
depth ≥ 2.0 m  →  silent
depth 1.0–2.0  →  400 Hz           (low, gentle)
depth 0.5–1.0  →  650 Hz           (mid, noticeable)
depth < 0.5 m  →  900 Hz           (high, urgent)
```

Between pings: **silence**. No sustained tone, no breathing, no modulation. The ear rests between ticks. This is the single biggest change from the current system.

### 4.4  Temporal smoothing

Apply per-column EMA before the audio mapping:

```swift
// On each 10 Hz navigation frame
for i in 0..<6 {
    smoothedDepth[i] = 0.35 * newColumnDepth[i] + 0.65 * smoothedDepth[i]
}
```

At 10 Hz, this gives ~250 ms effective smoothing. Fast enough to catch a real obstacle appearing (you'll hear it within 1–2 frames), slow enough to kill single-frame depth jitter. The smoothing applies *before* the threshold check, so a transient noisy pixel doesn't trigger a ping at all.

### 4.5  Polyphony cap (policy-enforced)

6 columns can play, but the policy (Section 5) limits how many are active simultaneously:

| Scene state | Max simultaneous pings | Which columns | Rationale |
|-------------|----------------------|---------------|-----------|
| Safe (urgency ≤ 0.1) | 0 | None | Silence = "you're fine" |
| Caution (0.1 < urgency ≤ 0.4) | 2 | Nearest 2 | Awareness without overload |
| Warning (0.4 < urgency ≤ 0.7) | 3 | Nearest 3 | Spatial picture of threat |
| Critical (urgency > 0.7) | 4 | Nearest 4 | Full frontal awareness |

"Nearest N" means: rank all 6 columns by smoothed depth ascending, take the N closest, silence the rest. This guarantees the user hears the most dangerous obstacles and never gets more simultaneous sources than they can parse.

---

## 5. `NavigationAudioPolicy` — The Single Router

Everything flows through one policy object. No sound reaches the speaker or haptic motor without its permission.

### 5.1  Inputs

All of these already exist in the system. Nothing new to compute.

```swift
struct AudioPolicyInput {
    // From ObstacleDetector (existing)
    let zoneStatuses: (left: ZoneStatus, center: ZoneStatus, right: ZoneStatus)
    let recommendedDirection: Direction   // .left / .right / .straight / .stop
    let urgency: Float                    // 0.0–1.0

    // From new column depth computation (3 lines of NumPy)
    let columnDepths: [Float]             // 6 smoothed depths

    // From system state (existing)
    let navigationActive: Bool            // GPS or indoor route
    let beaconAzimuth: Float?             // from FusedNavigator or indoor target
    let speechActive: Bool                // Gemini or TTS producing audio
    let fallDetected: Bool                // from FallDetector
}
```

### 5.2  Outputs

```swift
struct AudioPolicyOutput {
    // Obstacle layer
    let activeColumns: [Int]              // indices of columns allowed to ping
    let pingRates: [Float]                // Hz per active column
    let pingFrequencies: [Float]          // Hz (tone) per active column

    // Beacon layer
    let beaconEnabled: Bool
    let beaconAzimuth: Float              // degrees
    let beaconVolume: Float               // 0.0–1.0

    // Haptics
    let hapticIntensity: Float            // 0.0–1.0

    // Speech coordination
    let duckNonSpeechTo: Float            // volume multiplier for everything else
}
```

### 5.3  Policy states

| State | Entry condition | Active columns | Beacon | Haptics | Speech |
|-------|----------------|---------------|--------|---------|--------|
| **idle** | No nav, urgency ≤ 0.1 | 0 | Off | Off | Normal |
| **navigating** | Nav active, urgency ≤ 0.1 | 0 | Full (1.0) | Off | Periodic |
| **caution** | 0.1 < urgency ≤ 0.4 | ≤ 2 nearest | 80% | Light (0.2) | Normal |
| **warning** | 0.4 < urgency ≤ 0.7 | ≤ 3 nearest | 50% | Medium (0.5) | Queue |
| **critical** | urgency > 0.7 | ≤ 4 nearest | 20% | Full (1.0) | Duck / interrupt |
| **speaking** | TTS or Gemini active | ≤ 1 (critical only) | 15% | Off | Priority |
| **emergency** | Fall detected | 0 | Off | Off | Emergency only |

### 5.4  Hysteresis

Transitions use frame-count thresholds to prevent flicker from depth noise:

```swift
// Enter critical: urgency > 0.7 for 2 consecutive frames (200 ms at 10 Hz)
// Exit critical:  urgency < 0.5 for 5 consecutive frames (500 ms)
// Enter caution:  urgency > 0.1 for 3 consecutive frames (300 ms)
// Exit caution:   urgency ≤ 0.1 for 5 consecutive frames (500 ms)
```

Uses the algorithm's own 10 Hz update rate as the clock. No separate timer.

### 5.5  The policy is a pure function

`NavigationAudioPolicy.evaluate(input:) → output` has no side effects, no internal timers, no audio engine references. It takes data in, returns constraints out. This makes it trivially unit-testable:

```swift
// Test: safe scene → silence
let input = AudioPolicyInput(urgency: 0.05, columnDepths: [5, 5, 5, 5, 5, 5], ...)
let output = policy.evaluate(input)
assert(output.activeColumns.isEmpty)
assert(output.beaconEnabled == true)

// Test: critical left → 4 columns, beacon ducked
let input = AudioPolicyInput(urgency: 0.9, columnDepths: [0.3, 0.8, 3, 3, 3, 3], ...)
let output = policy.evaluate(input)
assert(output.activeColumns.count <= 4)
assert(output.beaconVolume <= 0.2)
```

---

## 6. Beacon: Tied to the Algorithm's Clear-Path Output

The beacon is the "walk here" cue. Its position comes directly from the algorithm's existing outputs — no new computation.

### 6.1  Azimuth source (priority order)

1. **GPS route active:** use `FusedNavigator.audio_beacon_azimuth` (already computed — fuses GPS bearing with obstacle avoidance and user heading)
2. **Indoor target active:** use 3D position of target object from indoor mapper
3. **Neither:** use `recommended_direction` mapped to azimuth:
   - `left` → –30°
   - `straight` → 0°
   - `right` → +30°
4. **`recommended_direction == stop`:** beacon **off** — no clear path to point toward

### 6.2  Sound design

Sine pulse. 800 Hz. 100 ms duration. 1 Hz rate (1 pulse per second).

No sustained pad. No reverb. Let the environment node's HRTF provide the spatial cue. This is intentionally simpler than the current `ChordBeaconVoice` — the point is that it sounds *obviously different* from the obstacle pings (sine vs square wave, 800 Hz vs 400–900 Hz variable, periodic vs urgency-driven).

### 6.3  Interaction with obstacle pings

Volume is set by the policy based on urgency:

| Urgency | Beacon volume | Rationale |
|---------|--------------|-----------|
| ≤ 0.1 (safe) | 1.0 | Only sound playing — full attention |
| 0.1–0.4 (caution) | 0.8 | Slightly quieter, pings beginning |
| 0.4–0.7 (warning) | 0.5 | Pings are primary, beacon secondary |
| > 0.7 (critical) | 0.2 | Danger dominates, beacon barely audible |
| Speech active | 0.15 | Background reference only |

---

## 7. Verbal Commands: Triggered by Algorithm State Changes

Optional layer — product decision whether to include. Short spoken cues for significant algorithm output transitions.

### 7.1  Triggers

These are derived directly from changes in the `ObstacleDetector` output between consecutive frames:

| Algorithm transition | Cue | Throttle |
|---------------------|-----|---------|
| urgency crosses ≤ 0.4 → > 0.7 | "Stop" or "Obstacle [direction]" | 1 per 3 s |
| `recommended_direction` changes value | "Veer left" / "Veer right" | 1 per 5 s |
| urgency drops > 0.4 → ≤ 0.1 | "Path clear" | 1 per 10 s |
| `recommended_direction` becomes `stop` | "No clear path" | 1 per 5 s |
| GPS waypoint reached | Turn instruction from `FusedNavigator.voice_instruction` | Per waypoint |

### 7.2  Pipeline arbitration

- Gemini speaking → queue nav cue (unless urgency > 0.7 — "Stop" always interrupts)
- Nav cue playing → duck obstacle pings to 30%, beacon to 15%
- Restore volumes 200 ms after cue finishes
- Use `AVSpeechSynthesizer` or pre-recorded clips (pre-recorded preferred: consistent voice, known duration, no synthesis latency)

---

## 8. Haptics: Scaled to Algorithm Urgency

Direct mapping from the number the algorithm already produces:

```swift
let hapticIntensity: Float = {
    if speechActive { return 0.0 }        // vibration blocks speech comprehension
    switch urgency {
    case ..<0.1:  return 0.0              // safe
    case ..<0.4:  return 0.0              // caution — audio alone is enough
    case ..<0.7:  return 0.3              // warning — light pulse
    case ..<0.9:  return 0.7              // high warning — strong pulse
    default:      return 1.0              // critical — max
    }
}()
```

User toggle to disable entirely. `NavigationHapticEngine` is already a separate class — this is just wiring it to the policy output instead of raw depth.

---

## 9. What Changes on the Backend (Modal)

Almost nothing. One small addition to the existing `/detect_obstacles` endpoint:

### 9.1  Add `column_depths` to the response

```python
# In obstacle_detector.py, inside detect_obstacles()
# After existing zone computation, add:

column_depths = self._compute_column_depths(depth_map, num_columns=6)

return {
    # existing fields (unchanged)
    'left': zone_stats['left'],
    'center': zone_stats['center'],
    'right': zone_stats['right'],
    'recommended_direction': recommended_direction,
    'urgency': urgency,

    # new field
    'column_depths': column_depths
}

def _compute_column_depths(self, depth_map, num_columns=6):
    """5th-percentile depth per vertical column."""
    H, W = depth_map.shape
    col_width = W // num_columns
    return [
        float(np.percentile(depth_map[:, i*col_width:(i+1)*col_width], 5))
        for i in range(num_columns)
    ]
```

That's it. ~6 lines of Python. The existing zone stats, recommended_direction, and urgency remain unchanged. iOS gets both the high-level decision (for the policy) and the angular detail (for the pings) in a single API response.

### 9.2  Hardening `min_dist` (optional improvement)

The current per-zone `min_dist` uses `np.min` — a single noisy pixel can dominate. Change to 5th-percentile, matching the column logic:

```python
# Before:
min_dist = np.min(zone_depth)

# After:
min_dist = np.percentile(zone_depth, 5)
```

This makes urgency (which is derived from `min_dist`) more robust to depth estimation noise. One-line change.

---

## 10. Architecture: Before and After

### Before

```
DepthFrame
    ▼
WorldObstacleMap  (360° bins, 0.985 decay, presenceThreshold 0.35)
    ▼
Rank top 8 bins
    ▼
8 × SubBassObstacleVoice  (continuous breathing, independent pulse rates)
    +
ChordBeaconVoice  (sustained pad + reverb, always on)
    +
NavigationHapticEngine  (zone-based, always on)
    +
Gemini TTS  (uncoordinated)
    =
Wall of sound
```

### After

```
Camera frame
    ▼
Modal: Depth-Anything-V2 → depth_map
    ▼
Modal: ObstacleDetector
    ├─ zone stats + recommended_direction + urgency  (existing, unchanged)
    └─ column_depths × 6  (new, ~6 lines of Python)
    ▼
iOS: per-column EMA smoothing  (kill depth noise)
    ▼
NavigationAudioPolicy.evaluate()
    │
    ├─► Obstacle pings  (≤ 4 of 6 columns, discrete pings, policy-governed)
    ├─► Beacon pulse    (1 source, at recommended_direction or GPS azimuth)
    ├─► Haptics         (intensity = f(urgency), off during speech)
    └─► Speech          (duck/queue coordination)
    =
Algorithm output → directly audible, governed by policy
```

**Key differences:**

- `WorldObstacleMap` is **removed from the audio path**. It can remain for visualization/logging.
- Obstacle audio tracks the **current frame's** depth data. No multi-second decay. When the obstacle leaves the FOV, the ping stops on the next frame (~100 ms).
- **Polyphony is capped** by the policy (0–4 sources depending on urgency), not by how many WorldObstacleMap bins happen to be above threshold.
- **Silence is the default.** Safe scene = no obstacle audio. This is new.

---

## 11. What to Avoid

1. **Don't rebuild the CV pipeline.** The `ObstacleDetector` works. We're adding 6 lines of NumPy for column depths. Everything else stays.

2. **Don't use `WorldObstacleMap` for audio.** Its 360° persistence with slow decay is the root cause of the drone. The algorithm runs at 10 Hz — that *is* temporal continuity. No decay buffer needed.

3. **Don't go beyond 6 columns.** More positions won't be audibly distinguishable through glasses speakers. 6 is at the perceptual limit. If anything, test whether 5 is enough.

4. **Don't add layers.** Every new sound type must pass through `NavigationAudioPolicy`. Default answer to "should we add a new audio layer?" is no.

5. **Don't rewrite the AVAudioEngine graph.** The existing spatial/HRTF graph is fine. The problem is what gets sent to it, not how it renders. Policy first.

6. **Don't use continuous tones.** The switch from sustained modulated voices to discrete pings-with-silence is load-bearing. Do not revert to any form of sustained audio for obstacles.

---

## 12. Implementation Phases and Order of Work

### Phase 1: Column depths on Modal + iOS parsing  
Add `_compute_column_depths()` to `ObstacleDetector`. Parse the new `column_depths` field in `ModalClient.swift`. Apply per-column EMA smoothing on iOS.  
**Touches:** `obstacle_detector.py` (~6 lines), `ModalClient.swift`  
**Time:** 1–2 h

### Phase 2: Replace 8-voice obstacle audio with 6-column pings  
Remove `WorldObstacleMap` from the audio path. Create 6 spatial sources at fixed azimuths (–35° to +35°). Implement the ping generator (50 ms square-wave bursts, rate and frequency from smoothed column depth).  
**Touches:** `SpatialAudioEngine.swift` (major refactor of obstacle rendering)  
**Time:** 3–4 h

### Phase 3: `NavigationAudioPolicy`  
Implement the pure-function policy (Section 5). Wire its output to the obstacle sources (which columns are active, capped at 0–4), beacon (volume), haptics (intensity), and speech (duck factor). Add hysteresis for state transitions.  
**Touches:** New `NavigationAudioPolicy.swift`, modifications to `SpatialAudioEngine.swift`, `NavigationHapticEngine.swift`, Gemini audio routing  
**Time:** 4–5 h

### Phase 4: Beacon refactor  
Replace `ChordBeaconVoice` sustained pad with sine pulse (800 Hz, 100 ms, 1 Hz). Position at `recommended_direction` azimuth or `FusedNavigator.audio_beacon_azimuth`. Mute when `recommended_direction == stop`.  
**Touches:** Beacon source in `SpatialAudioEngine.swift`  
**Time:** 2 h  
**Can run parallel to Phase 3.**

### Phase 5: Real-walk test + tune (iteration 1)  
Walk 5 scenarios. Tune EMA factor, ping durations, rate curve, beacon duck levels, hysteresis thresholds.  
**Time:** 2–3 h

### Phase 6: Verbal commands (optional)  
Implement throttled `AVSpeechSynthesizer` cues triggered by algorithm state transitions. Wire through policy for duck/queue.  
**Touches:** New speech cue module, policy modifications  
**Time:** 2–3 h

### Phase 7: Haptic scaling  
Wire `NavigationHapticEngine` intensity to policy output instead of raw depth.  
**Touches:** `NavigationHapticEngine.swift`, policy wiring  
**Time:** 1 h

### Phase 8: Real-walk test (iteration 2)  
Full system test including verbal commands and haptics.  
**Time:** 2–3 h

### Summary

| Step | Phase | Parallel? | Time |
|------|-------|-----------|------|
| 1 | Column depths (Modal + iOS) | — | 1–2 h |
| 2 | 6-column ping audio | After Step 1 | 3–4 h |
| 3 | AudioPolicy | After Step 2 | 4–5 h |
| 4 | Beacon refactor | Parallel to Step 3 | 2 h |
| 5 | Walk test iter 1 | After Steps 3–4 | 2–3 h |
| 6 | Verbal commands (optional) | After Step 3 | 2–3 h |
| 7 | Haptic scaling | After Step 3 | 1 h |
| 8 | Walk test iter 2 | After Steps 6–7 | 2–3 h |
| | **Critical path (Steps 1–5)** | | **~13–16 h** |
| | **Full plan** | | **~19–23 h** |

---

## 13. Tunable Parameters (All in One Place)

Collected here for easy reference during walk testing:

| Parameter | Default | Where | Tunes what |
|-----------|---------|-------|------------|
| `numColumns` | 6 | Modal | Angular resolution |
| `percentile` | 5 | Modal | Noise rejection (lower = more sensitive) |
| `emaAlpha` | 0.35 | iOS | Smoothing (higher = more responsive) |
| `pingDurationMs` | 50 | iOS | Ping length (longer = more audible in noise) |
| `cautionRateHz` | 0.75 | iOS | Tick rate for 1–2 m obstacles |
| `warningRateHz` | 2.0 | iOS | Tick rate for 0.5–1 m obstacles |
| `criticalRateHz` | 4.0 | iOS | Tick rate for <0.5 m obstacles |
| `cautionFreqHz` | 400 | iOS | Tone for distant obstacles |
| `warningFreqHz` | 650 | iOS | Tone for mid-range obstacles |
| `criticalFreqHz` | 900 | iOS | Tone for close obstacles |
| `beaconFreqHz` | 800 | iOS | Beacon tone |
| `beaconRateHz` | 1.0 | iOS | Beacon pulse rate |
| `beaconDurationMs` | 100 | iOS | Beacon pulse length |
| `maxSimultaneousPings` | see policy table | iOS | Cap per urgency level |
| `hysteresis_enterCriticalFrames` | 2 | iOS | Frames above 0.7 to enter critical |
| `hysteresis_exitCriticalFrames` | 5 | iOS | Frames below 0.5 to exit critical |
| `speechDuckFactor` | 0.15 | iOS | Non-speech volume when speaking |

---

## 14. Links

- [`AUDIO_CLARITY_NAVIGATION.md`](AUDIO_CLARITY_NAVIGATION.md) — Nav/TTS ducking phases (A–E)
- [`SPATIAL_AUDIO_LOGIC.md`](../../SPATIAL_AUDIO_LOGIC.md) — Original parking-sensor design spec (repo root)
- [`SpatialAudioEngine.swift`](../NavigatorImpaired/SpatialAudioEngine.swift) — Current 8-voice renderer (to be replaced)
- [`WorldObstacleMap.swift`](../NavigatorImpaired/WorldObstacleMap.swift) — 360° map (remove from audio path)
- [`NavigationHapticEngine.swift`](../NavigatorImpaired/NavigationHapticEngine.swift) — Haptic feedback
- `obstacle_detector.py` — Shepherd-based ObstacleDetector (add `column_depths`; not in this repo)
- `fused_navigator.py` — GPS + obstacle fusion (unchanged; not in this repo)

---

### Appendix: v1 iOS (no Modal yet)

- **Column depths:** On-device [`ColumnDepthSampler`](../NavigatorImpaired/Navigation/ColumnDepthSampler.swift) from the depth map; same 6-column / 5th-percentile contract as Modal.
- **Urgency:** [`ObstacleAnalyzer`](../NavigatorImpaired/Navigation/ObstacleAnalyzer.swift) → [`ObstacleAnalysis.urgency`](../NavigatorImpaired/Models/ObstacleAnalysis.swift).

### Walk-test checklist (device QA)

- [ ] Open corridor: silence or near-silence when safe (urgency ≤ 0.1).
- [ ] Single doorway: one or two frontal pings, no 360° phantom.
- [ ] Navigation on: beacon direction matches guidance; beacon ducks when obstacle critical.
- [ ] Gemini speaking: bed ducked; critical “stop” cue can still fire.
- [ ] Glasses mode: listener orientation per existing `setGlassesMode`.
