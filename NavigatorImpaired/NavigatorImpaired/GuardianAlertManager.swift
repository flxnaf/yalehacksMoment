import Combine
import CoreLocation
import Foundation
import UIKit

@MainActor
final class GuardianAlertManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = GuardianAlertManager()

    private static let configKey = "guardianConfig"
    static let sendGridRelayBaseURLKey = "sendGridRelayBaseURL"
    static let sendGridRelaySecretKey = "sendGridRelaySecret"

    private let locationManager = CLLocationManager()
    private(set) var currentLocation: CLLocation?

    @Published private(set) var isCountdownActive = false

    private var fallFrame: UIImage?
    private var countdownTask: Task<Void, Never>?

    var onCountdownTick: ((Int) -> Void)?
    var onCountdownCancelled: (() -> Void)?
    var onAlertSent: ((String) -> Void)?

    private let urlSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 180
        return URLSession(configuration: c)
    }()

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func saveConfig(_ config: GuardianConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.configKey)
    }

    func clearGuardianConfig() {
        UserDefaults.standard.removeObject(forKey: Self.configKey)
    }

    func loadConfig() -> GuardianConfig? {
        guard let data = UserDefaults.standard.data(forKey: Self.configKey) else { return nil }
        return try? JSONDecoder().decode(GuardianConfig.self, from: data)
    }

    func cancelAlert() async {
        isCountdownActive = false
        countdownTask?.cancel()
        countdownTask = nil
        AudioOrchestrator.shared.stopAllSpeech()
        AudioOrchestrator.shared.enqueue("Alert cancelled.", priority: .hazard)
        onCountdownCancelled?()
    }

    func triggerAlert(confidence _: Float, lastFrame: UIImage?) async {
        fallFrame = lastFrame
        countdownTask?.cancel()

        countdownTask = Task { [weak self] in
            guard let self else { return }
            await self.runCountdownThenSend()
        }
    }

    private func runCountdownThenSend() async {
        isCountdownActive = true
        defer {
            if Task.isCancelled {
                isCountdownActive = false
            }
        }

        AudioOrchestrator.shared.enqueue(
            "Fall detected. Alerting your guardian in 10 seconds. Double-tap to cancel.",
            priority: .hazard
        )

        for i in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }

            let remaining = 10 - i - 1
            onCountdownTick?(remaining)

            if remaining == 5 {
                AudioOrchestrator.shared.enqueue("5 seconds. Double-tap to cancel.", priority: .hazard)
            }
            if remaining == 3 {
                AudioOrchestrator.shared.enqueue("3 seconds. Double-tap to cancel.", priority: .hazard)
            }
        }

        if Task.isCancelled { return }
        await sendAlerts()
    }

    private func sendAlerts() async {
        isCountdownActive = false

        let frame = fallFrame
        defer { fallFrame = nil }

        guard let config = loadConfig() else {
            AudioOrchestrator.shared.enqueue("No guardian configured.", priority: .hazard)
            return
        }

        let sceneText = ""

        let timeStr = Self.shortDateTime.string(from: Date())
        let locStr = Self.formatMapsLink(location: currentLocation)

        let snapshotJPEG: Data? = {
            guard let frame else { return nil }
            guard let data = frame.jpegData(compressionQuality: 0.82), !data.isEmpty else { return nil }
            return data
        }()

        var message = """
        🚨 SightAssist Fall Alert
        A SightAssist user may have fallen and needs help.

        🕐 Time: \(timeStr)
        📍 Last location: \(locStr)
        """
        if !sceneText.isEmpty {
            message += "\n📷 Last scene: \(sceneText)"
        }
        if snapshotJPEG != nil {
            message += "\n\n📎 A JPEG of the last camera frame is attached to this email."
        } else {
            message += "\n\n⚠️ Camera frame unavailable — email has no photo attachment."
        }
        message += "\n\nReply SAFE if they are okay."

        let smsBody = Self.fallAlertSMSBody(config: config, timeStr: timeStr, locStr: locStr, sceneText: sceneText)

        let emailOk = await sendFallAlertEmailViaNodeRelay(config: config, message: message, jpegAttachment: snapshotJPEG)

        let phone = config.guardianPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        let smsOk: Bool
        if phone.isEmpty {
            smsOk = false
        } else {
            smsOk = await SightAssistBridge.sendTextMessage(phone: phone, body: smsBody)
        }

        let whatsappJPEG: Data? = {
            guard let frame else { return nil }
            return GuardianAlertManager.jpegDataForOpenClawFallAlert(from: frame)
        }()
        let whatsappOk = await sendFallAlertWhatsAppViaOpenClaw(config: config, jpegForWhatsApp: whatsappJPEG)

        let anyOk = emailOk || smsOk || whatsappOk
        if !anyOk {
            AudioOrchestrator.shared.enqueue("Alert failed to send. Please call for help manually.", priority: .hazard)
            onAlertSent?("")
            return
        }

        onAlertSent?(message)

        if emailOk, smsOk, whatsappOk {
            AudioOrchestrator.shared.enqueue("Guardian alerted by email, text, and WhatsApp.", priority: .hazard)
        } else if emailOk, smsOk {
            AudioOrchestrator.shared.enqueue("Guardian alerted by email and text.", priority: .hazard)
        } else if emailOk, whatsappOk {
            AudioOrchestrator.shared.enqueue("Guardian alerted by email and WhatsApp.", priority: .hazard)
        } else if smsOk, whatsappOk {
            AudioOrchestrator.shared.enqueue("Guardian alerted by text and WhatsApp.", priority: .hazard)
        } else if whatsappOk {
            AudioOrchestrator.shared.enqueue("Guardian alerted on WhatsApp.", priority: .hazard)
        } else if emailOk {
            if phone.isEmpty {
                AudioOrchestrator.shared.enqueue("Guardian alerted. Help is on the way.", priority: .hazard)
            } else {
                AudioOrchestrator.shared.enqueue(
                    "Guardian emailed. Send the text message if Messages opened with a draft.",
                    priority: .hazard
                )
            }
        } else if smsOk {
            AudioOrchestrator.shared.enqueue(
                "Email could not be sent. Text to your guardian was sent or opened in Messages.",
                priority: .hazard
            )
        }
    }

    /// OpenClaw gateway tool `fall_alert` (register `skills/fall_alert.js` or equivalent on the gateway).
    private func sendFallAlertWhatsAppViaOpenClaw(config: GuardianConfig, jpegForWhatsApp: Data?) async -> Bool {
        let wa = config.guardianWhatsApp.trimmingCharacters(in: .whitespacesAndNewlines)
        let ocConfigured = GeminiConfig.isOpenClawConfigured

        guard !wa.isEmpty, ocConfigured else {
            let skipReason: String
            if wa.isEmpty { skipReason = "guardianWhatsApp_empty" }
            else if !ocConfigured { skipReason = "openclaw_not_configured" }
            else { skipReason = "unknown" }
            NSLog(
                "[GuardianAlert] WhatsApp fall_alert skipped (%@) waEmpty=%@ openClawConfigured=%@",
                skipReason,
                wa.isEmpty ? "YES" : "NO",
                ocConfigured ? "YES" : "NO"
            )
            return false
        }

        let who = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let contactName = who.isEmpty ? "SightAssist user" : who
        let locPair: String = {
            guard let loc = currentLocation else { return "" }
            let lat = String(format: "%.6f", loc.coordinate.latitude)
            let lng = String(format: "%.6f", loc.coordinate.longitude)
            return "\(lat),\(lng)"
        }()

        var args: [String: Any] = [
            "contact_name": contactName,
            "contact_number": wa,
            "location": locPair,
        ]
        if let jpeg = jpegForWhatsApp, !jpeg.isEmpty {
            args["image_jpeg_base64"] = jpeg.base64EncodedString()
        }

        let bridge = OpenClawBridge()
        let result = await bridge.invokeTool(
            name: "fall_alert",
            args: args
        )

        if result.ok {
            NSLog("[GuardianAlert] fall_alert tool: %@", String(result.detail.prefix(200)))
            return true
        }
        NSLog("[GuardianAlert] fall_alert tool failed: %@", result.detail)
        return false
    }

    private static func fallAlertSMSBody(config: GuardianConfig, timeStr: String, locStr: String, sceneText: String) -> String {
        let who = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = who.isEmpty ? "SightAssist user" : who
        var s = """
🚨 FALL ALERT
Person: \(label)
Time: \(timeStr)
Location: \(locStr)
"""
        if !sceneText.isEmpty {
            s += "\nScene: \(String(sceneText.prefix(100)))"
        }
        s += "\n\nReply SAFE if they are okay."
        return s
    }

    private struct FallRelayPayload: Encodable {
        let to: String
        let toName: String
        let subject: String
        let text: String
        let attachments: [FallRelayAttachment]?
    }

    private struct FallRelayAttachment: Encodable {
        let content: String
        let filename: String
        let type: String
    }

    /// Smaller JPEG for OpenClaw fall_alert args (same scene as email: last Gemini / camera frame).
    private static let maxOpenClawFallImageBytes = 450_000

    private static func jpegDataForOpenClawFallAlert(from image: UIImage) -> Data? {
        var img = image
        let maxEdge: CGFloat = 1024
        let w = img.size.width * img.scale
        let h = img.size.height * img.scale
        guard w > 0, h > 0 else { return nil }
        if max(w, h) > maxEdge {
            let scale = maxEdge / max(w, h)
            let newSize = CGSize(width: floor(w * scale), height: floor(h * scale))
            let renderer = UIGraphicsImageRenderer(size: newSize)
            img = renderer.image { _ in
                img.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        var quality: CGFloat = 0.72
        guard var data = img.jpegData(compressionQuality: quality) else { return nil }
        while data.count > maxOpenClawFallImageBytes && quality > 0.35 {
            quality -= 0.08
            guard let next = img.jpegData(compressionQuality: quality) else { break }
            data = next
        }
        if data.count > maxOpenClawFallImageBytes {
            return nil
        }
        return data
    }

    /// POST to Node `sgQuickstart`: SendGrid sends plain text + optional JPEG attachment (base64).
    private func sendFallAlertEmailViaNodeRelay(
        config: GuardianConfig,
        message: String,
        jpegAttachment: Data?
    ) async -> Bool {
        let baseRaw = UserDefaults.standard.string(forKey: Self.sendGridRelayBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !baseRaw.isEmpty else {
            NSLog("[GuardianAlert] Fall email skipped: relay URL empty — set Settings → fall alert relay URL (e.g. http://YOUR_MAC_IP:8787)")
            return false
        }

        let to = config.guardianEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else {
            NSLog("[GuardianAlert] Fall email skipped: guardian email empty")
            return false
        }

        if let issue = Self.relayURLHostValidationIssue(baseRaw: baseRaw) {
            NSLog("[GuardianAlert] Fall email skipped: %@", issue)
            return false
        }

        guard let url = Self.fallAlertRelayEndpointURL(baseRaw: baseRaw) else {
            NSLog("[GuardianAlert] Fall email skipped: invalid relay URL %@", baseRaw)
            return false
        }

        let timeStr = Self.shortDateTime.string(from: Date())
        let subject = "SightAssist Fall Alert – \(timeStr)"

        var attachments: [FallRelayAttachment]?
        if let jpeg = jpegAttachment {
            attachments = [
                FallRelayAttachment(
                    content: jpeg.base64EncodedString(),
                    filename: "sightassist_fall_\(Int(Date().timeIntervalSince1970)).jpg",
                    type: "image/jpeg"
                ),
            ]
        }

        let displayName = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = FallRelayPayload(
            to: to,
            toName: displayName.isEmpty ? "Guardian" : displayName,
            subject: subject,
            text: message,
            attachments: attachments
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = UserDefaults.standard.string(forKey: Self.sendGridRelaySecretKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Relay-Secret")
        }

        do {
            req.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 202 {
                NSLog("[GuardianAlert] Fall email sent (HTTP 202), attachment=%@", attachments != nil ? "yes" : "no")
                return true
            }
            NSLog("[GuardianAlert] Fall email failed HTTP %d", http.statusCode)
            switch http.statusCode {
            case 401:
                NSLog(
                    "[GuardianAlert] hint: relay rejected the secret — Settings “Relay shared secret” must exactly match sgQuickstart/.env RELAY_SECRET, or clear both."
                )
            case 400:
                NSLog("[GuardianAlert] hint: relay said bad request — check guardian email in Settings.")
            case 500:
                NSLog(
                    "[GuardianAlert] hint: relay server error — on the Mac, confirm .env has SENDGRID_API_KEY and SENDGRID_FROM_EMAIL; read the terminal stack trace."
                )
            default:
                break
            }
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                NSLog("[GuardianAlert] relay response body: %@", String(s.prefix(500)))
            }
            return false
        } catch {
            NSLog("[GuardianAlert] relay request failed: %@", error.localizedDescription)
            Self.logRelayFailureHints(error: error)
            return false
        }
    }

    private static func logRelayFailureHints(error: Error) {
        var err: NSError? = error as NSError
        var depth = 0
        while let e = err, depth < 6 {
            if e.userInfo["_NSURLErrorPrivacyProxyFailureKey"] as? Bool == true {
                NSLog(
                    "[GuardianAlert] hint: iCloud Private Relay (or a privacy proxy) is blocking your Mac’s LAN IP — Settings → Apple ID → iCloud → Private Relay → Off while testing, or disconnect from networks that force relay."
                )
            }
            let path = (e.userInfo["_NSURLErrorNWPathKey"] as? String) ?? ""
            if path.contains("Local network prohibited") {
                NSLog(
                    "[GuardianAlert] hint: Local Network access is denied — Settings → Privacy & Security → Local Network → enable this app."
                )
            }
            err = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
    }

    /// Catches hosts that ATS blocks or that cannot reach the Mac relay from an iPhone (e.g. copy-paste from `npm start` showing `0.0.0.0`).
    private static func relayURLHostValidationIssue(baseRaw: String) -> String? {
        var s = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            s = "http://" + s
        }
        while s.last == "/" {
            s.removeLast()
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        if scheme == "https" {
            return "relay URL must use http:// — sgQuickstart has no TLS on port 8787. Example: http://192.168.1.42:8787"
        }
        if host == "0.0.0.0" {
            return "relay URL uses 0.0.0.0 — that is only where the Mac listens, not an address the phone can use. Set Settings to http://YOUR_MAC_LAN_IP:8787 (e.g. from System Settings → Network)."
        }
        if host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]" {
            return "relay URL uses loopback — on the phone that means the phone itself, not your Mac. Use your Mac’s LAN IP (e.g. http://192.168.1.5:8787)."
        }
        return nil
    }

    /// Base URL from Settings (e.g. `http://192.168.1.5:8787`) → POST endpoint. Accepts optional `/fall-alert` suffix so we never double-append.
    private static func fallAlertRelayEndpointURL(baseRaw: String) -> URL? {
        var s = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.last == "/" {
            s.removeLast()
        }
        let suffix = "/fall-alert"
        if s.lowercased().hasSuffix(suffix) {
            return URL(string: s)
        }
        return URL(string: s + suffix)
    }

    private static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static func formatMapsLink(location: CLLocation?) -> String {
        guard let location else { return "Location unavailable." }
        let lat = String(format: "%.6f", location.coordinate.latitude)
        let lng = String(format: "%.6f", location.coordinate.longitude)
        return "https://maps.google.com/?q=\(lat),\(lng)"
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            Self.shared.currentLocation = loc
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
