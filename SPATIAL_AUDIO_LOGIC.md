# Spatial Audio Pinging — Logic Design

> **Purpose:** Document the full design rationale for converting depth map output + accelerometer orientation into navigational 8D/binaural audio pings. Intended for implementation in the `DepthanythingTest` iOS project.

---

## 1. Overview

The pipeline has four stages:

```
Depth Frame (DepthAnythingV2)
        ↓
  Zone Sampling → nearest-object distance per spatial zone
        ↓
  Accelerometer (CMMotionManager) → listener orientation vector
        ↓
  3D Audio Engine (AVAudioEnvironmentNode + HRTF) → binaural ping
```

The result: a short tone that pings faster and slightly louder as the user approaches an object, positioned in 3D space so the user can hear *where* the obstacle is without looking.

---

## 2. Depth Map → Spatial Zones

### 2.1 Zone Grid

Divide each depth frame into a **3 × 3 grid** of zones:

```
┌──────────┬──────────┬──────────┐
│ TL       │ TC       │ TR       │  ← top row (elevated / overhead)
├──────────┼──────────┼──────────┤
│ ML       │ MC       │ MR       │  ← middle row (eye level — primary)
├──────────┼──────────┼──────────┤
│ BL       │ BC       │ BR       │  ← bottom row (ground / feet)
└──────────┴──────────┴──────────┘
```

For initial testing, **focus on the middle row** (ML, MC, MR). Add top/bottom rows once the core pipeline is stable.

### 2.2 Per-Zone Depth Value

For each zone, sample a **5×5 sub-grid of pixels** from the depth map and take the **5th-percentile value** (i.e. the nearest non-noise object). Raw minimum tends to be noisy; the 5th percentile filters sensor speckle while still reacting quickly to real obstacles.

```swift
// Pseudocode
func sampleZoneDepth(depthMap: [[Float]], zone: CGRect) -> Float {
    let samples = sampleSubgrid(depthMap, rect: zone, gridSize: 5)
    return percentile(samples, 0.05)
}
```

### 2.3 Depth Normalization

DepthAnythingV2 outputs **inverse relative depth** (higher pixel value = closer). Normalize to a `[0, 1]` range per frame and invert so that `0 = far` and `1 = very close`:

```
normalizedDistance = 1.0 - (pixelDepth / frameMax)
```

Then map to an approximate physical distance using a calibration curve (tune empirically with a tape measure):

| normalizedDistance | estimated physical distance |
|--------------------|-----------------------------|
| 0.0 – 0.15         | > 3 m (ignore for pinging)  |
| 0.15 – 0.40        | 1.5 – 3 m (slow ping)       |
| 0.40 – 0.70        | 0.5 – 1.5 m (medium ping)   |
| 0.70 – 1.00        | 0 – 0.5 m (fast ping)       |

> **Note:** DepthAnythingV2 is monocular and scale-free. The calibration above is a rough linear mapping and will drift per scene. For navigation accuracy, fuse with ARKit's `ARDepthData` or a LiDAR scan when available on Pro devices.

---

## 3. Accelerometer → Listener Orientation

### 3.1 CoreMotion Setup

```swift
let motionManager = CMMotionManager()
motionManager.deviceMotionUpdateInterval = 1.0 / 30  // 30 Hz, enough for audio
motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { motion, _ in
    guard let attitude = motion?.attitude else { return }
    updateListenerOrientation(attitude)
}
```

### 3.2 Attitude → Audio Listener

When the phone is held **face-up in front of the eyes** (landscape or portrait), map device attitude to the `AVAudioEnvironmentNode` listener orientation:

| CMAttitude property | Maps to audio space |
|---------------------|---------------------|
| `pitch` (tilt up/down) | **Elevation** of the listener look-vector |
| `yaw` (compass turn)   | **Azimuth** / horizontal facing direction |
| `roll` (tilt left/right) | Minor correction for head tilt |

```swift
// AVAudioEnvironmentNode.listenerAngularOrientation
let orientation = AVAudio3DAngularOrientation(
    yaw:   Float(attitude.yaw   * 180 / .pi),
    pitch: Float(attitude.pitch * 180 / .pi),
    roll:  Float(attitude.roll  * 180 / .pi)
)
environmentNode.listenerAngularOrientation = orientation
```

The listener's position stays fixed at the **origin** `(0, 0, 0)`. Objects are placed around the listener based on the zone they occupy in the frame.

### 3.3 Zone → 3D Source Position

Map each grid zone to a fixed 3D point in **listener-relative space**:

```
          Y (up)
          │
          │    (ahead)
     ─────┼───────── Z (depth, negative = in front)
          │
          X (right)
```

| Zone | AVAudio3DPoint (x, y, z) |
|------|--------------------------|
| ML   | (-1.0,  0.0, -1.0)       |
| MC   | ( 0.0,  0.0, -1.0)       |
| MR   | ( 1.0,  0.0, -1.0)       |
| TL   | (-1.0,  0.6, -1.0)       |
| TC   | ( 0.0,  0.6, -1.0)       |
| TR   | ( 1.0,  0.6, -1.0)       |
| BL   | (-1.0, -0.6, -1.0)       |
| BC   | ( 0.0, -0.6, -1.0)       |
| BR   | ( 1.0, -0.6, -1.0)       |

The Z component is fixed at `-1.0` (always "in front" of the listener). Distance-to-object is encoded in **volume and ping rate**, not Z-depth of the audio source — this prevents HRTF artifacts from extreme near-field positioning.

---

## 4. Ping Engine

### 4.1 Tone Design

Each ping is a **short sine-wave burst**:

| Parameter       | Value                            |
|-----------------|----------------------------------|
| Base frequency  | 660 Hz (center zone)             |
| Left zone       | 520 Hz (slightly lower = "left") |
| Right zone      | 820 Hz (slightly higher = "right")|
| Duration        | 100 ms total                     |
| Envelope        | 10 ms attack / 70 ms sustain / 20 ms release |
| Waveform        | Sine (clean, low fatigue)        |

Using frequency differentiation on top of 3D positioning gives a **redundant spatial cue** — useful when HRTF binaural rendering is subtle on cheaper earphones.

### 4.2 Ping Rate (Proximity → BPM)

Like a parking sensor, ping rate increases as objects get closer. Use a capped inverse relationship:

```
pingInterval(s) = max(0.15, 2.0 × (1 - normalizedDistance)^-1.2)
```

Practical table:

| normalizedDistance | Approx interval | Feel              |
|--------------------|-----------------|-------------------|
| 0.00 – 0.15        | silent          | nothing nearby    |
| 0.15 – 0.40        | 1.8 – 2.5 s     | slow, relaxed     |
| 0.40 – 0.70        | 0.6 – 1.2 s     | moderate, alert   |
| 0.70 – 0.90        | 0.2 – 0.5 s     | fast, caution     |
| 0.90 – 1.00        | 0.15 s          | urgent (cap here) |

> **Cap at 0.15 s (~6.7 Hz)** — faster than this becomes a tone rather than a ping and loses navigational meaning.

### 4.3 Volume Curve

Volume is intentionally modest. The formula keeps audio informative without causing ear fatigue:

```
volume = clamp(0.15 + 0.45 × normalizedDistance^0.6, 0.15, 0.60)
```

| normalizedDistance | Volume (0–1) |
|--------------------|--------------|
| 0.15               | ~0.20        |
| 0.40               | ~0.35        |
| 0.70               | ~0.50        |
| 1.00               | ~0.60        |

Max volume is **0.60** (60% of full scale). This is the right level to be audible with earphones in a noisy street without causing discomfort. Tune down to 0.45 if testing in quiet indoor environments.

### 4.4 Per-Zone Audio Nodes

Each zone gets its own `AVAudioPlayerNode` attached to the `AVAudioEnvironmentNode`:

```swift
struct ZonePlayer {
    let node: AVAudioPlayerNode
    let position: AVAudio3DPoint
    var pingInterval: TimeInterval = .infinity
    var nextPingTime: Date = .distantFuture
}
```

A single **ping scheduler** (a 30 Hz `DispatchSourceTimer`) iterates all active zones on every tick and fires a ping if `Date.now >= nextPingTime`.

Only zones where `normalizedDistance > 0.15` are active. This prevents phantom pings from sky or empty corridors.

---

## 5. AVAudioEngine Setup

```
AVAudioEngine
  ├── AVAudioEnvironmentNode (3D mixer, HRTF enabled)
  │     ├── ZonePlayer[ML].node → position (-1, 0, -1)
  │     ├── ZonePlayer[MC].node → position ( 0, 0, -1)
  │     └── ZonePlayer[MR].node → position ( 1, 0, -1)
  └── mainMixerNode → outputNode (earphones)
```

### Key Configuration

```swift
// Enable HRTF (binaural rendering)
environmentNode.renderingAlgorithm = .HRTF

// Soft rolloff — don't let AVAudio auto-silence far nodes
// (we control volume manually via the curve above)
environmentNode.distanceAttenuationParameters.maximumDistance = 1000
environmentNode.distanceAttenuationParameters.rolloffFactor = 0

// Listener stays at origin; orientation updates from CMMotionManager
environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
```

Disable AVAudio's built-in distance attenuation (`rolloffFactor = 0`) because we apply our own volume curve — mixing two attenuation systems causes unpredictable results.

---

## 6. Per-Frame Update Loop

Called every time a new depth frame arrives (target: 15–20 fps, matching inference rate):

```
1. For each active zone (ML, MC, MR):
   a. sampleZoneDepth() → rawDepth
   b. normalize → normalizedDistance
   c. if normalizedDistance < 0.15 → deactivate zone, continue
   d. compute volume = volumeCurve(normalizedDistance)
   e. compute pingInterval = pingRateCurve(normalizedDistance)
   f. set ZonePlayer[zone].node.volume = volume
   g. set ZonePlayer[zone].pingInterval = pingInterval

2. Update listener orientation from latest CMDeviceMotion.attitude

3. Ping scheduler fires independent of frame rate (30 Hz timer)
```

Keep the per-frame update lightweight — only update parameters, never schedule audio synchronously on the inference thread.

---

## 7. Testing Protocol (Phone-as-Glasses Rig)

Since Meta Ray-Bans are not available for initial testing, use the phone held below eye level with earphones:

1. **Setup:** Phone face-up, held at chest height, camera pointing forward. Earphones in.
2. **Environment:** Start in a hallway — single obstacle (wall) directly ahead. Verify center ping activates and accelerates as you approach.
3. **Left/Right calibration:** Place an object off to the left. Confirm ML zone pings and the tone sounds distinctly left-panned in earphones.
4. **Accelerometer test:** Slowly rotate left/right while facing the same obstacle. Confirm the audio source appears to stay anchored to the object (listener orientation rotates, source stays put).
5. **Volume comfort check:** Walk toward a wall until urgent ping rate. Volume should be noticeable but not startling. Adjust `maxVolume` constant if needed.
6. **Multi-zone test:** Stand at a corner where objects are in both ML and MR zones simultaneously. Confirm two independent pings sound without interference.

---

## 8. Known Limitations and Next Steps

| Limitation | Mitigation |
|------------|------------|
| DepthAnythingV2 is scale-free (no absolute meters) | Calibrate normalization curve empirically per environment; consider ARKit depth fusion on LiDAR devices |
| HRTF quality varies by earphone type | Test with in-ear monitors first; over-ear headphones give better HRTF results |
| Accelerometer drift (yaw) indoors | Use `.xMagneticNorthZVertical` reference frame + magnetometer; accept ~5° yaw drift indoors |
| Phone camera FoV ≠ Ray-Ban FoV | Re-map zone X positions when switching to glasses stream (Ray-Ban has narrower FoV ~73°) |
| No elevation differentiation yet | Add TC/BC zones once ML/MC/MR pipeline is validated |
| Monocular depth is relative per-frame | Temporal smoothing (exponential moving average per zone, α=0.3) reduces jitter |

### Immediate Next Implementation Steps

1. Add `SpatialAudioEngine.swift` — wraps `AVAudioEngine`, `AVAudioEnvironmentNode`, zone players
2. Add `DepthZoneSampler.swift` — takes `CVPixelBuffer` from inference output, returns `[Zone: Float]`
3. Add `PingScheduler.swift` — 30 Hz timer, owns ping interval state per zone
4. Wire `DepthBenchmarkViewModel` to call `SpatialAudioEngine.update(zones:)` after each inference pass
5. Add CMMotionManager to `DepthBenchmarkViewModel`, route attitude to `SpatialAudioEngine.updateListenerOrientation(_:)`
6. Add a toggle in `DepthBenchmarkView` to enable/disable audio (mute button)
