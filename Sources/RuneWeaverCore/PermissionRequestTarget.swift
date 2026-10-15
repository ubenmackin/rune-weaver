// Rune Weaver Core — Engine-derived display target for permission requests.
//
// Purpose: single owner of the display target naming what "this target"
// covers for a permission request, so the chat banner, the inbox card, and
// the dashboard quick actions all present the same host, recipient, command,
// or path instead of re-deriving one per call site.
// Scope: the pure derivation over tool name plus arguments JSON — egress
// host precedence with blank hosts treated as absent, send-tool recipients
// (string or array, comma-joined), bash commands, files paths, and the
// common target-ish key fallback. Scope matching, decision recording, and
// approval policy stay with their owners.
// Architectural role: a stateless derivation beside the approval queue;
// `PermissionRequest.displayTarget` renders it and the decision log stores
// the same rendering when a decision resolves.

import Foundation

/// Single owner of target display derivation for permission requests.
public enum PermissionRequestTarget: Sendable {
    /// Derives the display target naming what "this target" covers.
    /// - Parameters:
    ///   - toolName: Name of the tool requesting approval.
    ///   - argumentsJSON: Raw JSON arguments for the call.
    ///   - egressHost: Target host for unlisted network egress, when present.
    /// - Returns: Display target, or nil when none is derivable.
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
