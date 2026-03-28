// SightAssist OpenClaw skills — load this script in the WKWebView host alongside other skills.
// Expects `registerSkill` and `SightAssistBridge.call` to exist in the agent runtime.

registerSkill({
  name: "triggerSOS",
  description:
    "Manually trigger an emergency alert to the user's guardian. Use when user says 'call for help', 'SOS', 'emergency', or 'alert my guardian'.",
  parameters: { type: "object", properties: {}, required: [] },
  async handler() {
    const result = await SightAssistBridge.call("triggerSOS", {});
    return result.success
      ? { spoken: "Alerting your guardian now.", status: "success" }
      : { spoken: "Couldn't send alert. Please call 911 directly.", status: "error" };
  },
});
