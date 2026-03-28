# Audio clarity: obstacle spatial audio vs navigation guidance

This document **diagnoses** why combining the existing obstacle pipeline with GPS navigation can confuse users, and proposes a **phased plan** to deliver **clear, prioritized audio commands** without guessing implementation details inside `SpatialAudioEngine` until the team is ready.

**Related code (read-only context):**

- [`SpatialAudioEngine.swift`](../NavigatorImpaired/SpatialAudioEngine.swift) — obstacle voice pool + path beacon + haptics  
- [`NavigationHapticEngine.swift`](../NavigatorImpaired/NavigationHapticEngine.swift) — haptics from zones  
- Planned: `NavigationController` + `FusedNavigator` + TTS (`onSpeakInstruction`)  
- [`GeminiSessionViewModel`](../NavigatorImpaired/VisionClaw/Gemini/GeminiSessionViewModel.swift) — Gemini Live playback + mic  

---

## 1. Diagnosis: why audio feels confusing

### 1.1 Multiple independent “meanings” at once

Today the user can hear **several unrelated stories** overlapping:

| Layer | What it communicates | Audio character | Update rate |
| ----- | -------------------- | ----------------- | ----------- |
| **Obstacle voice pool** (8× `SubBassObstacleVoice`) | “There are obstacles around you in 3D space” (world map + HRTF) | Low-frequency pulses / hum, spatialized | Every depth frame |
| **Path beacon** (`ChordBeaconVoice`) | **Clearest walking direction in the *depth map*** (`ClearPath` from `PathFinder`), *not* GPS north | Sustained chord pad, moves in azimuth | After sustain logic (~6 frames) |
| **Haptics** (`NavigationHapticEngine` + `SurfaceMemory`) | Proximity / zones | Vibration | Zone updates |
| **Gemini Live** | Conversational assistant | Full-band speech | User/model turns |

**Critical naming confusion:** In code comments, “beacon” means **safe direction from depth/path finding**. When GPS navigation ships, “beacon” in the **fusion** layer (`NavigationGuidance.beaconAzimuth`) means **direction toward the next waypoint** (or avoidance). Those are **different targets**. Playing both at full strength will feel like two people pointing in different directions.

### 1.2 No global “audio mode” or priority

There is no single state machine that says:

- “During turn-by-turn **speech**, duck obstacle tones.”
- “While **navigating**, repurpose the chord beacon for **route direction** instead of depth clear-path.”
- “When **obstacle urgency is critical**, interrupt or override navigation pad volume.”

Without that, **TTS** (“In 50 feet, veer left”) can overlap **Gemini** (“I see a person…”) and **sub-bass obstacles** at the same time.

### 1.3 Glasses vs phone orientation

In glasses mode, phone IMU heading for spatial audio may be **decoupled** from where the user is actually facing (`setGlassesMode` stops motion tracking). GPS relative bearing uses **compass on the phone**. If head direction and phone direction diverge, **spatialized** cues (beacon azimuth) may not match **spoken** “left/right” unless the pipeline uses a consistent reference (phone vs glasses) and documents it.

### 1.4 Summary

The issue is not “bad audio” — it is **unmediated mixing** of:

1. **Egocentric obstacle alerts** (always on when depth runs)  
2. **Depth-based “safe path” beacon** (ambiguous vs route)  
3. **Navigation speech** (TTS + possibly Gemini)  
4. **No ducking / mode priority**

---

## 2. Goals for “clear audio commands”

1. **One primary intent at a time** for the user’s attention: *navigate* vs *stop for obstacle* vs *talk to assistant*.  
2. **Consistent semantics:** When outdoor navigation is active, “where is safe to walk” should align **either** with route following **or** obstacle avoidance, with an explicit **priority rule** (fusion already defines logic — audio must **reflect** it, not contradict it).  
3. **Speech clarity:** Navigation instructions should be **short**, **throttled**, and **not** spoken on top of Gemini’s full reply unless designed (e.g. interrupt policy).  
4. **Accessibility:** Prefer **distinct timbres** (obstacle = low pulse, route = different band or voice) so users can learn the mapping.

---

## 3. Plan (phased, minimal risk)

### Phase A — Document and instrument (no behavior change)

- [ ] Add a short **Audio layer matrix** in code comments or this doc: obstacle pool / path beacon / nav TTS / Gemini.  
- [ ] Log (debug only) when `NavigationController.isNavigating` toggles vs `SpatialAudioEngine.isEnabled`.  
- [ ] Confirm where `NavigationGuidance.beaconAzimuth` will feed (new input to `SpatialAudioEngine` vs separate channel).

**Exit:** Team agrees on **one** definition of “beacon” during `navigatingOutdoor`.

### Phase B — Introduce `NavigationAudioPolicy` (single place for rules)

Create a small type (e.g. `NavigationAudioPolicy` or extend `SightAssistController`) that exposes:

```text
enum NavigationAudioPriority {
  case idle
  case obstacleCritical   // urgency high — obstacle wins
  case navigating         // route + fusion wins
  case assistantSpeaking  // optional: duck others
}
```

Rules (example — tune in implementation):

- If `obstacle.urgency > 0.8` → **priority = obstacleCritical** (duck route beacon / reduce chord pad; keep or increase obstacle layer).  
- Else if `isNavigating` → **priority = navigating** (route beacon / TTS lead; **reduce** depth-only beacon volume or **retarget** it to fusion azimuth).  
- Else → default obstacle + depth beacon as today.

**Exit:** Policy is unit-testable from `NavigationGuidance` + `ObstacleAnalysis` without touching DSP internals first.

### Phase C — Integrate policy into `SpatialAudioEngine` (surgical)

Coordinate with teammate owning [`SpatialAudioEngine`](../NavigatorImpaired/SpatialAudioEngine.swift):

- [ ] Add **published** inputs: e.g. `navigationBeaconAzimuth: Float?` (nil = use depth beacon only), `navigationPriority: NavigationAudioPriority`, `duckingLevel: Float` (0…1).  
- [ ] In `applyBeacon` / mixer: **blend or select** between depth clear-path azimuth and navigation azimuth based on priority.  
- [ ] Apply **volume scaling** to obstacle pool when `navigating` and urgency low (so constant obstacle hum doesn’t mask TTS).  
- [ ] Optional: **duck** `ChordBeaconVoice` when `AVSpeechSynthesizer` is speaking (use `AVSpeechSynthesizerDelegate` or a shared “speech active” flag from `NavigationController`).

**Exit:** User testing: “I can tell route vs obstacle by ear.”

### Phase D — TTS and Gemini coordination

- [ ] **Queue** navigation TTS: never fire two lines within N seconds unless urgency overrides.  
- [ ] When Gemini Live is **actively speaking**, delay non-urgent nav TTS OR lower spatial bed (policy).  
- [ ] Consider **VoiceOver** / **system** voice for nav vs Gemini voice so they’re distinguishable.

**Exit:** No more “two voices talking over each other” in the common case.

### Phase E — User-facing validation

- [ ] Blindfolded / low-vision tester protocol: walk a known route with obstacles.  
- [ ] Metrics: wrong-turn count, “which sound meant what” questionnaire.

---

## 4. What *not* to do first

- Rewriting the entire spatial audio graph before Phase B.  
- Using the word “beacon” in user-facing copy for two different meanings.  
- Feeding raw GPS into `PathFinder` — fusion belongs in **`FusedNavigator`** + **`NavigationAudioPolicy`**, not in depth scan.

---

## 5. Open questions (resolve in design review)

1. During navigation, should the **chord pad** represent **fused** direction only, or **dual** (obstacle + route) with stereo split?  
2. Should **critical obstacle** pause **waypoint advance** (snap to safety) or only audio?  
3. Glasses mode: is **phone compass** acceptable for route bearing, or do we need **head-tracked** azimuth from glasses firmware later?

---

## 6. Traceability to SightAssist navigation spec

The main implementation plan (`sightassist_gps_navigation_0d91d9f1.plan.md` in Cursor plans) covers **route fetch, fusion, TTS hook**. **This document** is the **audio clarity overlay**: Phases A–E should be linked as **follow-up tasks** after `NavigationController` + `FusedNavigator` exist, ideally owned by the **audio teammate** with small integration points from navigation code.

---

*Last updated: product/architecture note — not a substitute for on-device tuning.*
