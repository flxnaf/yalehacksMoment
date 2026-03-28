import Foundation

struct GuardianConfig: Codable, Equatable {
    var name: String
    var phoneNumber: String
    var twilioAccountSid: String
    var twilioAuthToken: String
    var twilioFromNumber: String
}
