import Testing
@testable import NavigatorImpaired

struct NavigationAudioPolicyTests {

    @Test func safeOpenSpaceProducesNoObstaclePings() {
        let engine = NavigationAudioPolicyEngine()
        let obstacle = ObstacleAnalysis(
            leftClearance: 1,
            centerClearance: 1,
            rightClearance: 1,
            closestDistance: 9.5,
            urgency: 0.02,
            recommendedDirection: "straight"
        )
        let input = AudioPolicyInput(
            obstacle: obstacle,
            columnDepthsMeters: [10, 10, 10, 10, 10, 10],
            navigationActive: false,
            guidance: nil,
            geminiSpeaking: false,
            verbalCueSpeaking: false
        )
        let out = engine.evaluate(input)
        #expect(out.obstacleColumnsActive.allSatisfy { !$0 })
    }

    @Test func closeColumnProducesPing() {
        let engine = NavigationAudioPolicyEngine()
        engine.reset()
        var cols = [Float](repeating: 10, count: 6)
        cols[2] = 0.4
        let obstacle = ObstacleAnalysis(
            leftClearance: 0.2,
            centerClearance: 0.2,
            rightClearance: 1,
            closestDistance: 0.4,
            urgency: 0.95,
            recommendedDirection: "stop"
        )
        let input = AudioPolicyInput(
            obstacle: obstacle,
            columnDepthsMeters: cols,
            navigationActive: false,
            guidance: nil,
            geminiSpeaking: false,
            verbalCueSpeaking: false
        )
        var out = engine.evaluate(input)
        for _ in 0..<20 {
            out = engine.evaluate(input)
        }
        #expect(out.obstacleColumnsActive.contains(true))
        #expect(out.beaconEnabled == false)
    }

    @Test func duckNonSpeechMatchesSpeechState() {
        let engine = NavigationAudioPolicyEngine()
        engine.reset()
        let obstacle = ObstacleAnalysis(
            leftClearance: 1,
            centerClearance: 1,
            rightClearance: 1,
            closestDistance: 9,
            urgency: 0.02,
            recommendedDirection: "straight"
        )
        let cols = [Float](repeating: 10, count: 6)
        let withSpeech = AudioPolicyInput(
            obstacle: obstacle,
            columnDepthsMeters: cols,
            navigationActive: false,
            guidance: nil,
            geminiSpeaking: true,
            verbalCueSpeaking: false
        )
        #expect(engine.evaluate(withSpeech).duckNonSpeech == 0.15)
        let noSpeech = AudioPolicyInput(
            obstacle: obstacle,
            columnDepthsMeters: cols,
            navigationActive: false,
            guidance: nil,
            geminiSpeaking: false,
            verbalCueSpeaking: false
        )
        #expect(engine.evaluate(noSpeech).duckNonSpeech == 1.0)
    }

    @Test func intrinsicPingVolumeNotPremultipliedByDuck() {
        let engine = NavigationAudioPolicyEngine()
        engine.reset()
        var cols = [Float](repeating: 10, count: 6)
        cols[1] = 0.6
        let obstacle = ObstacleAnalysis(
            leftClearance: 0.5,
            centerClearance: 0.5,
            rightClearance: 0.5,
            closestDistance: 0.6,
            urgency: 0.55,
            recommendedDirection: "straight"
        )
        let input = AudioPolicyInput(
            obstacle: obstacle,
            columnDepthsMeters: cols,
            navigationActive: false,
            guidance: nil,
            geminiSpeaking: false,
            verbalCueSpeaking: false
        )
        for _ in 0..<8 {
            _ = engine.evaluate(input)
        }
        let out = engine.evaluate(input)
        #expect(out.duckNonSpeech == 1.0)
        if let i = out.obstacleColumnsActive.firstIndex(of: true) {
            #expect(out.obstacleVolume[i] >= 0.35 && out.obstacleVolume[i] <= 0.55)
        }
    }

    @Test func criticalHysteresisRequiresTwoFrames() {
        let engine = NavigationAudioPolicyEngine()
        engine.reset()
        var cols = [Float](repeating: 10, count: 6)
        cols[3] = 0.3
        let high = ObstacleAnalysis(
            leftClearance: 0.1,
            centerClearance: 0.1,
            rightClearance: 0.1,
            closestDistance: 0.3,
            urgency: 0.95,
            recommendedDirection: "left"
        )
        let input = AudioPolicyInput(
            obstacle: high,
            columnDepthsMeters: cols,
            navigationActive: false,
            guidance: nil,
            geminiSpeaking: false,
            verbalCueSpeaking: false
        )
        let o1 = engine.evaluate(input)
        _ = engine.evaluate(input)
        let o3 = engine.evaluate(input)
        #expect(o1.obstacleColumnsActive.filter { $0 }.count <= 2)
        #expect(o3.obstacleColumnsActive.filter { $0 }.count <= 4)
    }
}
