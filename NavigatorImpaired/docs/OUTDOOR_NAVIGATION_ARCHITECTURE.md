# Outdoor navigation — architecture map

This document mirrors the authoritative wiring for “outdoor” (GPS + walking route + turn guidance + spatial pings). **Do not assume** `AppMode.navigatingOutdoor` / `SightAssistController` drive the live feature; the executable path is VisionClaw + `NavigationController` (see below).

## What “outdoor navigation” is here

Outdoor nav is the GPS + Google Maps walking route + turn guidance + spatial pings path. It is not labeled everywhere as “outdoor”; the main implementation is `NavigationController` and related types. The enum case `AppMode.navigatingOutdoor` exists for mode management, but it is only referenced in `SightAssistController` (which is not used elsewhere in the Swift tree), so the live feature is wired through `MainAppView` / `StreamSessionViewModel` / `NavigationController` instead.

## Core navigation (routes, GPS loop, fusion)

| File | Role |
|------|------|
| `NavigatorImpaired/Navigation/NavigationController.swift` | Starts/stops navigation, GPS loop, reroutes, TTS hooks, obstacle fusion, Gemini handoff |
| `NavigatorImpaired/Navigation/RouteService.swift` | Places text search + Directions API → route |
| `NavigatorImpaired/Navigation/FusedNavigator.swift` | Combines heading, waypoint, obstacles → `NavigationGuidance` + voice strings |
| `NavigatorImpaired/Navigation/RouteSegmenter.swift`, `RouteSegmentationModels.swift`, `RouteGeometry.swift`, `PolylineDecoder.swift`, `TurnPointExtractor.swift` | Route geometry, segments, turns |
| `NavigatorImpaired/Navigation/ObstacleAnalyzer.swift` | Obstacle urgency from depth (used with nav) |
| `NavigatorImpaired/Navigation/NavigationAudioPolicy.swift` | Ducking / policy when nav + other audio |
| `NavigatorImpaired/Navigation/NavigationVerbalCueController.swift` | Verbal cues tied to stream/nav |
| `NavigatorImpaired/Navigation/SheikahPinger.swift` | Ping / beacon behavior for waypoints |

## Location

| File | Role |
|------|------|
| `NavigatorImpaired/Location/LocationManager.swift` | GPS, high accuracy for navigation |

## Models

| File | Role |
|------|------|
| `NavigatorImpaired/Models/ObstacleAnalysis.swift` | Obstacle analysis struct |
| `NavigatorImpaired/Models/RouteWaypoint.swift` | Waypoint / route-related types (if used by routing) |

## AI / voice / tools

| File | Role |
|------|------|
| `NavigatorImpaired/VisionClaw/OpenClaw/ToolCallRouter.swift` | Calls `NavigationController.startNavigation(to:)` for voice/tool-driven destinations |
| `NavigatorImpaired/VisionClaw/NavSpeechCoordinator.swift` | `AVSpeech` for nav when not using Gemini voice |
| `NavigatorImpaired/VisionClaw/Gemini/GeminiSessionViewModel.swift` | Nav voice + handoff from `NavigationController` |
| `NavigatorImpaired/Navigation/NavigationHazardScanCoordinator.swift` | Periodic hazard scans while `isNavigating` |
| `NavigatorImpaired/Navigation/GeminiNavigationHazardClient.swift`, `GeminiHazardScanModels.swift` | Gemini hazard API for outdoor nav |

## UI & wiring

| File | Role |
|------|------|
| `NavigatorImpaired/VisionClaw/Views/MainAppView.swift` | Creates `NavigationControllerHolder`, wires `NavigationController` to Gemini, stream VM, hazard coordinator |
| `NavigatorImpaired/VisionClaw/NavigationControllerHolder.swift` | Owns shared `NavigationController` |
| `NavigatorImpaired/VisionClaw/ViewModels/StreamSessionViewModel.swift` | Holds `navigationController`, depth, `ObstacleAnalyzer`, `NavigationAudioPolicyEngine`, spatial audio for nav context |
| `NavigatorImpaired/VisionClaw/Views/RouteDebugMapView.swift` | Debug map over route / checkpoints (DEBUG) |

## Spatial audio & haptics

| File | Role |
|------|------|
| `NavigatorImpaired/SpatialAudioEngine.swift` | Spatial pings / nav audio (used from stream/nav path) |
| `NavigatorImpaired/NavigationHapticEngine.swift` | Haptics during navigation |

## Mode enum (outdoor vs other modes)

| File | Role |
|------|------|
| `NavigatorImpaired/Core/AppMode.swift` | Defines `navigatingOutdoor` |
| `NavigatorImpaired/Core/SightAssistController.swift` | On leaving `.navigatingOutdoor`, calls `navigationController?.stopNavigation()` — standalone; not wired into main app UI from grep |

## Docs (behavior, not executable)

- `NavigatorImpaired/docs/AUDIO_CLARITY_NAVIGATION.md` — audio/nav behavior notes

## Summary

The executable outdoor navigation feature is centered on `NavigationController.swift` plus `RouteService`, `FusedNavigator`, `LocationManager`, `StreamSessionViewModel` (integration), `MainAppView`, `NavigationControllerHolder`, `ToolCallRouter`, speech (`NavSpeechCoordinator`, `GeminiSessionViewModel`), `NavigationHazardScanCoordinator`, and `SpatialAudioEngine`. The name “outdoor” appears explicitly in `AppMode.navigatingOutdoor` and `SightAssistController` (cleanup on mode change), but the primary user-facing wiring is through the VisionClaw stream + navigation stack above, not through `SightAssistController` in the current codebase.
