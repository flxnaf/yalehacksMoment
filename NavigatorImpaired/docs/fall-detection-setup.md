# Fall Detection → WhatsApp Alert: Step-by-Step Setup

This guide matches **this repo** (NavigatorImpaired / SightAssist / VisionClaw). Stages 1–2 are MyClaw / OpenClaw dashboard work; stages 3–4 reference the actual Swift files and settings names here.

## Overview

1. Fix WhatsApp in OpenClaw (MyClaw dashboard)
2. Deploy the `fall_alert` skill on the gateway
3. Configure the iOS app (already wired — verify settings)
4. Test end-to-end

---

## Stage 1 — Fix WhatsApp in OpenClaw

### Step 1.1 — Link your WhatsApp

1. Open your **MyClaw** dashboard.
2. Go to **Control → OpenClaw → Settings → Communications → Channels**.
3. On the **WhatsApp** card, click **Show QR**.
4. On your phone: WhatsApp → **Linked Devices → Link a Device** → scan the QR.
5. Wait until status shows **Linked: Yes** and **Connected: Yes**.

### Step 1.2 — Fix the "Unsupported type" error

1. On the WhatsApp card, find the config input box.
2. Set **Type** / **Mode** to **Raw**, or set JSON to:
   ```json
   { "type": "raw" }
   ```
3. **Save** → **Reload** and confirm the error banner is gone.

---

## Stage 2 — Deploy the Skill to OpenClaw

### Step 2.1 — Add the skill file

1. **Control → OpenClaw → Agent → Skills** → **New Skill**.
2. Name: **`fall_alert`** (must match what the app invokes).
3. Paste the contents of repo file **`NavigatorImpaired/skills/fall_alert.js`** (or copy from your backup).
4. **Save**.

### Step 2.2 — Attach the skill to your agent

1. **Control → OpenClaw → Agent → Agents** → open your agent (e.g. EyeMeta.Ai).
2. Under **Skills**, add **`fall_alert`**.
3. **Save**.

### Step 2.3 — Gateway URL and API key for the iPhone

1. **Control → OpenClaw → Config**.
2. Copy **Gateway URL** (e.g. `https://your-instance.myclaw.ai` or `http://your-mac.local:18789`).
3. Copy **API key** / **Agent token**.

In **this app**, there is no `OpenClawConfig.swift`. Enter them in:

- **VisionClaw → Settings** (in-app): **Host**, **Port**, **Gateway Token** (and hook token if your setup needs it), **or**
- **`NavigatorImpaired/VisionClaw/Secrets.swift`** as defaults (`openClawHost`, `openClawPort`, `openClawGatewayToken`).

The app calls **`POST {host}:{port}/tools/invoke`** with tool **`fall_alert`** and the same bearer token as chat completions. Payload includes **`contact_name`**, **`contact_number`** (E.164), **`location`** (`lat,lng`), and when a camera frame exists **`image_jpeg_base64`** (downscaled JPEG, capped ~450 KB so the JSON body stays gateway-friendly). See `OpenClawBridge.invokeTool` and `GuardianAlertManager.sendFallAlertWhatsAppViaOpenClaw`.

---

## Stage 3 — iOS app (already integrated)

You do **not** need to add duplicate Swift files if you are building this target as-is.

| Guide (generic) | This repo |
|-----------------|-----------|
| `FallDetector.swift` | `NavigatorImpaired/FallDetector.swift` + `FallDetectionCoordinator.swift` |
| `FallDetector.shared.start()` in `App` | `NavigatorImpairedApp.init()` → `FallDetectionCoordinator.shared.start()` |
| `EmergencyContactSettingsView` | **Settings** → **Guardian / Fall alert** → **Guardian WhatsApp (E.164)** + other guardian fields |
| `OpenClawConfig` | `GeminiConfig` / `SettingsManager` / `Secrets.swift` |

### Permissions (`Info.plist`)

Already present at **`NavigatorImpaired/Info.plist`**:

- **`NSLocationWhenInUseUsageDescription`** — walking navigation and fall-alert location.
- **`NSMotionUsageDescription`** — motion / fall-related use (Core Motion transparency).

If Apple prompts for motion, accept it on device.

---

## Stage 4 — Test End-to-End

### Step 4.1 — Configure contacts

1. Run on a **physical iPhone** (accelerometer behavior is realistic; simulator is limited).
2. Open **Settings** (VisionClaw settings sheet).
3. Under **Guardian / Fall alert**:
   - Set **Your name** (wearer label in the message).
   - Set **Guardian WhatsApp** to international format, e.g. `+1XXXXXXXXXX`.
   - Ensure **OpenClaw** host/port/gateway token match Stage 2.3.
4. **Save**.

After a real fall (above confidence threshold), the app runs the **10-second countdown** (double-tap to cancel), then invokes **`fall_alert`** via the gateway (alongside email/SMS if configured).

### Step 4.2 — Simulate without falling

**Do not** ship a public “simulate fall” button for demos.

For **DEBUG** builds, the stream UI includes a **Test SOS** control that runs the full guardian pipeline (`FallDetectionCoordinator.shared.triggerManualSOS()`). Use that for testing, then rely on real-device accelerometer tests or remove/hide the control before a public demo.

### Step 4.3 — Confirm in OpenClaw

**Control → OpenClaw → Logs** — look for **`fall_alert`** / `tools/invoke` activity after the countdown completes.

### Step 4.4 — Confirm on WhatsApp

The linked WhatsApp account should show an outbound **text** fall alert to the **Guardian WhatsApp** number you saved. If the app had a frame (last Gemini video frame or a fresh camera capture), the skill sends a **second** message with the JPEG when the gateway accepts `media` on `whatsapp.send` (see `skills/fall_alert.js`).

---

## Troubleshooting

| Problem | Fix |
|--------|-----|
| WhatsApp **Unsupported type** | Set channel config to **raw**; hard-refresh dashboard. |
| No WhatsApp after alert | Confirm **Guardian WhatsApp** is set, OpenClaw is reachable, skill name is exactly **`fall_alert`**, and WhatsApp is linked (Stage 1). |
| Skill not found in logs | Skill name in OpenClaw must match **`fall_alert`** (see `OpenClawBridge` / `GuardianAlertManager`). |
| Location missing in message | Grant **When In Use** location; `GuardianAlertManager` uses `CLLocationManager`. |
| Text alert works but **no photo** on WhatsApp | Redeploy the latest **`skills/fall_alert.js`** from this repo. If it still fails, your OpenClaw build may expect a different `whatsapp.send` media shape — check [OpenClaw WhatsApp](https://docs.openclaw.ai/channels/whatsapp.md) / CLI `openclaw message send --media` and adjust the second `whatsapp.send` in the skill. |
| **`tools/invoke` errors or timeouts** with photo | The app omits `image_jpeg_base64` if the JPEG cannot be compressed under ~450 KB; very large gateways may still reject huge bodies — reduce `maxOpenClawFallImageBytes` in `GuardianAlertManager` if needed. |
| QR expired | Regenerate QR in dashboard (~20 s lifetime). |

---

## Before a public demo

Remove or hide **Test SOS** / debug fall triggers so judges cannot accidentally send real alerts. Keep the **double-tap to cancel** behavior during any staged fall test.
