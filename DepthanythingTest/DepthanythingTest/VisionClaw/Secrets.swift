import Foundation

enum Secrets {
  // REQUIRED: Get your key at https://aistudio.google.com/apikey
  static let geminiAPIKey = "AIzaSyD1GKdMX4w9CZsdoUwy7IbrVxkoPiMs5nQ"

  // OPTIONAL: OpenClaw gateway config (for agentic tool-calling)
  // Use your Mac's Bonjour hostname (run: scutil --get LocalHostName)
  static let openClawHost = "http://your_mac_hostname.local/"
  static let openClawPort = 18789
  static let openClawHookToken = "YOUR_OPENCLAW_HOOK_TOKEN"
  static let openClawGatewayToken = "YOUR_OPENCLAW_GATEWAY_TOKEN"

  // OPTIONAL: WebRTC signaling server URL (for live POV streaming)
  // Run: cd samples/CameraAccess/server && npm install && npm start
  static let webrtcSignalingURL = "ws://YOUR_MAC_IP:8080"
}
