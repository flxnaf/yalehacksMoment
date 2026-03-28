# Spatial audio (SightAssist / NavigatorImpaired)

Navigation and obstacle audio use [`SpatialAudioEngine`](SpatialAudioEngine.swift): `AVAudioEngine` → `AVAudioEnvironmentNode` (HRTF-HQ on iOS 15+) → `AVAudioUnitReverb` → main mixer.

Spoken alerts (falls, guardian countdown) must go through the **same HRTF graph**, not a separate `AVSpeechSynthesizer.speak` route. [`AudioOrchestrator`](AudioOrchestrator.swift) uses `AVSpeechSynthesizer.write(_:toBufferCallback:)` to obtain PCM and schedules it on `AVAudioPlayerNode` attached to `AVAudioEnvironmentNode` (front-center source), reusing `SpatialAudioEngine.sightAssistSpeechPlayer` when the spatial pipeline is running.
