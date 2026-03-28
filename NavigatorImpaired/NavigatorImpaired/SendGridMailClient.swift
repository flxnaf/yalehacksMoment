import Foundation
import os

private let sendGridLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NavigatorImpaired", category: "SendGrid")

/// SendGrid v3 Mail Send — silent transactional email (no `MFMailComposeViewController`).
enum SendGridMailClient {
    private static let sendURL = URL(string: "https://api.sendgrid.com/v3/mail/send")!

    private struct MailPayload: Encodable {
        struct Personalization: Encodable {
            let to: [EmailAddress]
        }

        struct EmailAddress: Encodable {
            let email: String
        }

        struct From: Encodable {
            let email: String
        }

        struct ContentBlock: Encodable {
            let type: String
            let value: String
        }

        let personalizations: [Personalization]
        let from: From
        let subject: String
        let content: [ContentBlock]
    }

    /// Returns `true` when SendGrid returns HTTP 202 Accepted.
    static func sendPlainText(
        apiKey: String,
        to guardianEmail: String,
        from fromEmail: String,
        subject: String,
        body: String,
        urlSession: URLSession
    ) async -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = guardianEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = fromEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !to.isEmpty, !from.isEmpty else { return false }

        let payload = MailPayload(
            personalizations: [.init(to: [.init(email: to)])],
            from: .init(email: from),
            subject: subject,
            content: [.init(type: "text/plain", value: body)]
        )

        guard let data = try? JSONEncoder().encode(payload) else { return false }

        var req = URLRequest(url: sendURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        do {
            let (respData, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 202 { return true }
            #if DEBUG
            let snippet = String(data: respData, encoding: .utf8) ?? ""
            print("[SendGrid] HTTP \(http.statusCode): \(snippet.prefix(400))")
            #endif
            sendGridLog.error("SendGrid HTTP \(http.statusCode): \(String(data: respData, encoding: .utf8)?.prefix(300) ?? "")")
            return false
        } catch {
            sendGridLog.error("SendGrid request failed: \(error.localizedDescription)")
            return false
        }
    }
}
