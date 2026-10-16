// Rune Weaver Core — Engine-derived display target for permission requests.

import Foundation

/// Single owner of target display derivation for permission requests.
public enum PermissionRequestTarget: Sendable {
    /// Derives the display target naming what "this target" covers. toolName: Name
    /// of the tool requesting approval.
    public static func derive(toolName: String, argumentsJSON: String, egressHost: String?) -> String? {
        if let host = egressHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            return host
        }
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            return nil
        }
        if toolName == "email.send" || toolName == "messages.send" {
            return recipientTarget(in: object)
        }
        if toolName == "bash.exec" {
            return trimmedString(object["command"])
        }
        if toolName.hasPrefix("files.") {
            return trimmedString(object["path"])
        }
        for key in ["target", "url", "address", "destination"] {
            if let value = trimmedString(object[key]) {
                return value
            }
        }
        return nil
    }

    private static func recipientTarget(in object: [String: Any]) -> String? {
        for key in ["to", "recipient"] {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            if let text = raw as? String {
                if let trimmed = trimmedString(text) {
                    return trimmed
                }
                continue
            }
            if let list = raw as? [String] {
                let parts = list
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !parts.isEmpty {
                    return parts.joined(separator: ", ")
                }
                continue
            }
            // JSON arrays bridge as [Any]; accept embedded strings only.
            if let list = raw as? [Any] {
                let parts = list
                    .compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !parts.isEmpty {
                    return parts.joined(separator: ", ")
                }
            }
        }
        return nil
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
