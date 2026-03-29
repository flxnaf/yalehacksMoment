import Testing
@testable import NavigatorImpaired

struct GeminiHazardScanModelsTests {

  @Test func parsesHazardDecisionJSON() throws {
    let json = """
    {"shouldAnnounce":true,"primaryObject":"car","relativePosition":"left","suggestedMovement":"step_right","spoken":"Car close on your left—shift right.","severity":"high"}
    """
    let d = try GeminiHazardDecision.parse(jsonString: json)
    #expect(d.shouldAnnounce == true)
    #expect(d.primaryObject == "car")
    #expect(d.relativePosition == "left")
    #expect(d.suggestedMovement == "step_right")
    #expect(d.spoken.contains("Car"))
    #expect(d.severity == "high")
  }

  @Test func sanitizedDropsVagueObstacle() throws {
    let json = """
    {"shouldAnnounce":true,"primaryObject":"obstacle","relativePosition":"ahead","spoken":"obstacle"}
    """
    let d = try GeminiHazardDecision.parse(jsonString: json)
    #expect(d.sanitizedForSpeech() == nil)
  }

  @Test func sanitizedKeepsSpecificLine() throws {
    let json = """
    {"shouldAnnounce":true,"primaryObject":"door","relativePosition":"center","spoken":"Glass door directly ahead—move slightly left."}
    """
    let d = try GeminiHazardDecision.parse(jsonString: json)
    let s = try #require(d.sanitizedForSpeech())
    #expect(s.spoken.contains("door"))
  }

  @Test func sanitizedKeepsLowVisibilityEdgeCase() throws {
    let json = """
    {"shouldAnnounce":true,"primaryObject":"visibility","relativePosition":"unknown","suggestedMovement":"slow_down","spoken":"Hard to see ahead—slow down and use your cane","severity":"medium"}
    """
    let d = try GeminiHazardDecision.parse(jsonString: json)
    let s = try #require(d.sanitizedForSpeech())
    #expect(s.spoken.contains("slow"))
  }
}
