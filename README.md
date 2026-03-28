# Depth Anything V2 — iOS Benchmark

Real-time monocular depth estimation on iPhone and Meta Ray-Ban glasses, using [Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2) via CoreML.

**Typical inference: ~40–60 ms on iPhone (CPU+GPU), dropping to ~35 ms as Neural Engine warms up.**

---

## Setup

### 1. Download the CoreML model

The model file is too large for git. Run the setup script once:

```bash
./setup_model.sh
```

This requires Python 3 and downloads `DepthAnythingV2SmallF16.mlpackage` from Hugging Face. Alternatively, download manually:

```bash
pip3 install huggingface_hub
python3 -m huggingface_hub.cli.hf download apple/coreml-depth-anything-v2-small \
  --repo-type model \
  --local-dir DepthanythingTest/DepthanythingTest \
  --include "DepthAnythingV2SmallF16.mlpackage/*"
```

### 2. Open in Xcode

```
open DepthanythingTest/DepthanythingTest.xcodeproj
```

Xcode resolves **Meta Wearables DAT** and **WebRTC** (stasel, pinned to 140.0.0) via Swift Package Manager.

### 3. Build and run on a physical iPhone

The app will not work on simulator (camera required). Select your device and hit Run.

> **First launch takes ~60 seconds** while the Neural Engine compiles the model. Subsequent launches are instant (model is cached on device).

---

## Ray-Ban Glasses (optional)

To use the Meta Ray-Ban camera instead of the phone camera:

1. Register a Meta developer app at [developers.facebook.com](https://developers.facebook.com)
2. Add your **Meta App ID** and **Client Token** as Xcode build settings:
   - In Xcode → Target → Build Settings → search `META_APP_ID` and `CLIENT_TOKEN`
   - Set both values from your Meta developer dashboard
3. Pair your glasses in the **Meta View** app
4. In the app, tap **Ray-Ban** in the source picker at the bottom

---

## Features

- Live camera feed (phone or Ray-Ban glasses)
- Depth map overlay with Turbo colormap (red = close, blue = far)
- Per-frame latency stats (now / avg / min / max)
- Toggle depth overlay on/off
- Adjustable overlay opacity
- **Vision** tab: VisionClaw features (Gemini Live, WebRTC viewer, OpenClaw) — configure `VisionClaw/Secrets.swift` from `Secrets.swift.example` for API keys.

---

## Depth → Spatial Audio (planned)

The depth map can drive 8D/spatial audio:
- Divide the frame into spatial zones (left/center/right × near/far)
- Map each zone's average depth to a 3D position
- Use `AVAudioEnvironmentNode` + `AVAudioPlayerNode` for HRTF binaural rendering
- Closer objects → higher volume, less reverb; position → stereo pan + elevation
