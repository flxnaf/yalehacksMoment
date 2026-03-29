import Foundation
import MessageUI
import ObjectiveC
import UIKit

/// Native bridge for SightAssist JS skills. `sendMessage` requires `phone` or `to` in params.
@MainActor
final class SightAssistBridge: NSObject {
    /// In-app fall alerts and other native callers (same behavior as JS `sendMessage`).
    static func sendTextMessage(phone: String, body: String) async -> Bool {
        let bridge = SightAssistBridge()
        let result = await bridge.handleCallAsync(
            method: "sendMessage",
            params: ["phone": phone, "message": body]
        )
        return (result["success"] as? Bool) == true
    }

    private static var assocKey: UInt8 = 0

    private final class ComposeDelegate: NSObject, MFMessageComposeViewControllerDelegate {
        var onComplete: ((Bool) -> Void)?

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            let ok = (result == .sent)
            controller.dismiss(animated: true) { [weak self] in
                self?.onComplete?(ok)
                self?.onComplete = nil
            }
        }
    }

    func handleCallAsync(method: String, params: [String: Any]) async -> [String: Any] {
        switch method {
        case "triggerSOS":
            FallDetectionCoordinator.shared.triggerManualSOS()
            return ["success": true]
        case "sendMessage":
            return await deliverSendMessage(params: params)
        default:
            return ["success": false, "error": "unknown_method"]
        }
    }

    /// Known limitation: `sms:` fallback opens Messages with a prefilled draft; the user may still need to tap Send.
    private func deliverSendMessage(params: [String: Any]) async -> [String: Any] {
        let message = params["message"] as? String ?? ""
        let rawPhone = (params["phone"] as? String) ?? (params["to"] as? String) ?? ""
        let phone = rawPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else {
            return ["success": false, "error": "missing_phone"]
        }

        if MFMessageComposeViewController.canSendText(), let presenter = Self.topViewController() {
            let sent = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let compose = MFMessageComposeViewController()
                compose.recipients = [phone]
                compose.body = message
                let del = ComposeDelegate()
                del.onComplete = { cont.resume(returning: $0) }
                compose.messageComposeDelegate = del
                objc_setAssociatedObject(compose, &Self.assocKey, del, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                presenter.present(compose, animated: true)
            }
            return ["success": sent]
        }

        return await openSMSURL(phone: phone, body: message)
    }

    private func openSMSURL(phone: String, body: String) async -> [String: Any] {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        let encBody = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let pEnc = phone.replacingOccurrences(of: "+", with: "%2B")
        let candidates = ["sms:\(phone)&body=\(encBody)", "sms:\(pEnc)&body=\(encBody)"]
        for raw in candidates {
            if let url = URL(string: raw) {
                let opened = await UIApplication.shared.open(url)
                return ["success": opened]
            }
        }
        return ["success": false, "error": "bad_sms_url"]
    }

    private static func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let root: UIViewController?
        if let base {
            root = base
        } else {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            root = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
        }
        guard let root else { return nil }
        if let nav = root as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(base: tab.selectedViewController)
        }
        if let presented = root.presentedViewController {
            return topViewController(base: presented)
        }
        return root
    }
}
