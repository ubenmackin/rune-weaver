// Rune Weaver Core — Strict container list plus inspect parsing.

import Foundation

// MARK: - StrictContainerRunner Inspection Parsing

extension StrictContainerRunner {
    /// Parses `container list --all` output into name plus status pairs. Rows carry NAME, IMAGE,
    /// STATUS left to right, so the image column must never read as status.
    public static func parseContainerListOutput(_ output: String) -> [(name: String, status: String)] {
        var entries: [(name: String, status: String)] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        var statusIndex: Int?
        var sawHeader = false
        for line in lines {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let name = parts.first else { continue }
            if !sawHeader, name.lowercased() == "name" {
                sawHeader = true
                statusIndex = parts.firstIndex(where: { $0.lowercased() == "status" })
                continue
            }
            guard name.lowercased() != "name", !name.allSatisfy({ $0 == Character("-") }) else { continue }
            let status: String = if let idx = statusIndex, parts.count > idx {
                parts[idx...].joined(separator: " ")
            } else if parts.count >= 3 {
                parts[2...].joined(separator: " ")
            } else if parts.count == 2, isStatusToken(parts[1]) {
                parts[1]
            } else {
                "unknown"
            }
            entries.append((name: name, status: status.isEmpty ? "unknown" : status))
        }
        return entries
    }

    /// Whether a token reads as a container status marker. Sweep only reaps stopped shapes, so the
    /// fallback must not mistake an image reference for a status; only explicit status vocabulary
    /// counts.
    static func isStatusToken(_ token: String) -> Bool {
        let lowered = token.lowercased()
        return lowered.contains("running")
            || lowered.contains("stopped")
            || lowered.contains("exited")
            || lowered.contains("created")
            || lowered.contains("starting")
            || lowered.contains("stopping")
            || lowered.contains("paused")
            || lowered.contains("unknown")
    }

    /// Whether a status string reports a live container.
    public static func isRunningStatus(_ status: String) -> Bool {
        let lowered = status.lowercased()
        if lowered.contains("not running") || lowered.contains("not-running") || lowered.contains("not_running") {
            return false
        }
        if lowered.contains("was running") {
            return false
        }
        let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.contains(where: { $0 == "running" })
    }

    /// Extracts the container creation instant from one `inspect` dump.
    /// - Parameter output: Combined stdout plus stderr from the inspect probe.
    /// - Returns: Creation date, or nil when the dump carries no parseable stamp.
    public static func inspectCreatedDate(from output: String) -> Date? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: []),
              let raw = firstCreatedValue(in: decoded)
        else { return nil }
        return parsedContainerDate(raw)
    }

    /// Recursively finds the first creation-stamp value in decoded inspect JSON.
    /// - Parameter value: Decoded inspect array or object.
    /// - Returns: Raw stamp value, nil when absent.
    static func firstCreatedValue(in value: Any) -> Any? {
        if let dict = value as? [String: Any] {
            for (key, entry) in dict {
                let flat = key.lowercased()
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: " ", with: "")
                if flat == "created" || flat == "createdat" || flat == "creationtime" {
                    return entry
                }
            }
            for (_, entry) in dict {
                if let found = firstCreatedValue(in: entry) {
                    return found
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for entry in array {
                if let found = firstCreatedValue(in: entry) {
                    return found
                }
            }
        }
        return nil
    }

    /// Parses one raw creation stamp into a date.
    static func parsedContainerDate(_ value: Any) -> Date? {
        // Booleans bridge to NSNumber; never read `true` as epoch 1.
        if value is Bool {
            return nil
        }
        if let number = value as? NSNumber {
            let epoch = number.doubleValue
            guard epoch > 0, epoch < 4_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: epoch)
        }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let epoch = Double(trimmed), epoch > 0, epoch < 4_000_000_000 {
            return Date(timeIntervalSince1970: epoch)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }
        let shortened = truncatedFraction(trimmed)
        if shortened != trimmed, let date = fractional.date(from: shortened) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    /// Truncates an overlong fractional-seconds stamp to milliseconds.
    /// - Parameter text: Raw timestamp text.
    /// - Returns: Text with at most three fraction digits.
    static func truncatedFraction(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        let afterDot = text.index(after: dot)
        var end = afterDot
        while end < text.endIndex, text[end].isNumber {
            end = text.index(after: end)
        }
        let digits = text[afterDot ..< end]
        guard digits.count > 3 else { return text }
        return String(text[..<afterDot]) + String(digits.prefix(3)) + String(text[end...])
    }
}
