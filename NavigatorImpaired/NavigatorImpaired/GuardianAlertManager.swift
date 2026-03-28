import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

@MainActor
final class GuardianAlertManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = GuardianAlertManager()

    private static let configKey = "guardianConfig"
    static let imgbbKeyDefaults = "imgbbApiKey"
    static let gx10BaseURLKey = "gx10BaseURL"
    static let gx10ModelKey = "gx10Model"

    private let locationManager = CLLocationManager()
    private(set) var currentLocation: CLLocation?

    /// True during the 10s pre-send countdown (fall or SOS). Drives cancel overlay in `StreamView`.
    @Published private(set) var isCountdownActive = false

    private var fallFrame: UIImage?
    private var countdownTask: Task<Void, Never>?

    var onCountdownTick: ((Int) -> Void)?
    var onCountdownCancelled: (() -> Void)?
    var onAlertSent: ((String) -> Void)?

    private let urlSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }()

    private let speechSynthesizer = AVSpeechSynthesizer()

    private func stopGuardianSpeech() {
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    private func speakGuardian(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        speechSynthesizer.speak(u)
    }

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

    /// Removes persisted guardian contact / Twilio settings (e.g. user cleared all fields in Settings).
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
        stopGuardianSpeech()
        speakGuardian("Alert cancelled.")
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

        speakGuardian(
            "Fall detected. Alerting your guardian in 10 seconds. Double-tap to cancel."
        )

        for i in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }

            let remaining = 10 - i - 1
            onCountdownTick?(remaining)

            if remaining == 5 {
                speakGuardian("5 seconds. Double-tap to cancel.")
            }
            if remaining == 3 {
                speakGuardian("3 seconds. Double-tap to cancel.")
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
            speakGuardian("No guardian configured.")
            return
        }

        var sceneText = ""
        if let frame, let data = frame.jpegData(compressionQuality: 0.75) {
            do {
                sceneText = try await GX10InferenceClient.shared.describeImage(
                    imageData: data,
                    prompt: "Describe this scene in one sentence for an emergency contact. Focus on where the person is and what's around them."
                )
            } catch {
                sceneText = ""
            }
        }

        var imageURL: String?
        if let key = UserDefaults.standard.string(forKey: Self.imgbbKeyDefaults), !key.isEmpty,
           let frame, let jpeg = frame.jpegData(compressionQuality: 0.75) {
            imageURL = await uploadImgbb(jpeg: jpeg, apiKey: key)
        }

        let timeStr = Self.shortDateTime.string(from: Date())
        let locStr = Self.formatMapsLink(location: currentLocation)

        var message = """
        🚨 Guardian Fall Alert
        A NavigatorImpaired user may have fallen and needs help.

        🕐 Time: \(timeStr)
        📍 Last location: \(locStr)
        """
        if !sceneText.isEmpty {
            message += "\n📷 Last scene: \(sceneText)"
        }
        message += "\n\nReply SAFE if they are okay."

        let smsBody = message
        let mediaURL = imageURL
        let twilioOK = await sendTwilioSMS(config: config, body: smsBody, mediaURL: mediaURL)

        if twilioOK {
            speakGuardian("Guardian alerted. Help is on the way.")
            onAlertSent?(smsBody)
        } else {
            speakGuardian("Alert failed to send. Please call for help manually.")
            onAlertSent?("")
        }
    }

    private func sendTwilioSMS(config: GuardianConfig, body: String, mediaURL: String?) async -> Bool {
        let sid = config.twilioAccountSid.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = config.twilioFromNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty, !config.twilioAuthToken.isEmpty, !from.isEmpty else { return false }

        var parts: [String] = [
            formURLEncode("To", config.phoneNumber),
            formURLEncode("From", from),
            formURLEncode("Body", body),
        ]
        if let mediaURL, !mediaURL.isEmpty {
            parts.append(formURLEncode("MediaUrl", mediaURL))
        }
        let form = parts.joined(separator: "&")

        guard let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(sid)/Messages.json") else {
            return false
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let auth = Data("\(sid):\(config.twilioAuthToken)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.utf8)

        do {
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 201 { return true }
            #if DEBUG
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            print("[GuardianAlert] Twilio HTTP \(http.statusCode): \(String(bodyStr.prefix(500)))")
            #endif
            return false
        } catch {
            #if DEBUG
            print("[GuardianAlert] Twilio request error: \(error)")
            #endif
            return false
        }
    }

    private func uploadImgbb(jpeg: Data, apiKey: String) async -> String? {
        let boundary = "Boundary-\(UUID().uuidString)"
        var c = URLComponents(string: "https://api.imgbb.com/1/upload")
        c?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = c?.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"
                .data(using: .utf8)!
        )
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        do {
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let dataObj = json["data"] as? [String: Any],
                let urlStr = dataObj["url"] as? String
            else {
                return nil
            }
            return urlStr
        } catch {
            return nil
        }
    }

    private func formURLEncode(_ key: String, _ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
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
