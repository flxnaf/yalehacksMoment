import Foundation

struct GuardianConfig: Codable, Equatable {
    /// Wearer / user label (used in alert copy: who may need help).
    var name: String
    var guardianEmail: String
    /// E.164 or local digits; used for fall-alert SMS after the countdown (Messages compose or sms: URL).
    var guardianPhone: String
    /// Guardian WhatsApp (E.164, e.g. +15551234567). Sent via OpenClaw `fall_alert` tool after countdown when gateway is configured.
    var guardianWhatsApp: String

    enum CodingKeys: String, CodingKey {
        case name, guardianEmail, guardianPhone, guardianWhatsApp
        case legacyPhoneNumber = "phoneNumber"
        case twilioAccountSid, twilioAuthToken, twilioFromNumber
    }

    init(name: String = "", guardianEmail: String = "", guardianPhone: String = "", guardianWhatsApp: String = "") {
        self.name = name
        self.guardianEmail = guardianEmail
        self.guardianPhone = guardianPhone
        self.guardianWhatsApp = guardianWhatsApp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        guardianEmail = try c.decodeIfPresent(String.self, forKey: .guardianEmail) ?? ""
        if let p = try c.decodeIfPresent(String.self, forKey: .guardianPhone) {
            guardianPhone = p
        } else {
            guardianPhone = try c.decodeIfPresent(String.self, forKey: .legacyPhoneNumber) ?? ""
        }
        guardianWhatsApp = try c.decodeIfPresent(String.self, forKey: .guardianWhatsApp) ?? ""
        _ = try? c.decodeIfPresent(String.self, forKey: .twilioAccountSid)
        _ = try? c.decodeIfPresent(String.self, forKey: .twilioAuthToken)
        _ = try? c.decodeIfPresent(String.self, forKey: .twilioFromNumber)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(guardianEmail, forKey: .guardianEmail)
        try c.encode(guardianPhone, forKey: .guardianPhone)
        try c.encode(guardianWhatsApp, forKey: .guardianWhatsApp)
    }
}
