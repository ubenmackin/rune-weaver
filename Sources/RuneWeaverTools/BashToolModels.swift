// Rune Weaver Tools — Bash execution models plus capped output buffering.

import Foundation
import os
import RuneWeaverCore

/// Arguments for `bash.exec`.
public struct BashArgs: Codable, Sendable, Equatable {
    /// Shared command carrier so gate and tool decode the same field once.
    public var commandArgs: BashCommandArgs
    /// Shell command string to execute.
    public var command: String {
        commandArgs.command
    }

    /// Working directory for execution (optional).
    public let cwd: String?
    /// Execution timeout in seconds (optional).
    public let timeoutSeconds: Int?
    /// Optional flag to request network access in Seatbelt sandbox.
    public let requestNetwork: Bool
    /// Declared egress hosts constraining this call's network dials (max 10).
    public let networkHosts: [String]

    public init(
        command: String,
        cwd: String? = nil,
        timeoutSeconds: Int? = nil,
        requestNetwork: Bool = false,
        networkHosts: [String] = []
    ) {
        self.commandArgs = BashCommandArgs(command: command)
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
        self.requestNetwork = requestNetwork
        self.networkHosts = networkHosts
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case cwd
        case timeoutSeconds
        case requestNetworkSnake = "request_network"
        case networkHostsSnake = "network_hosts"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let command = try container.decode(String.self, forKey: .command)
        // Flat wire shape stays `{"command": ...}`; the value lands in the
        // shared carrier so trimming rules cannot drift from the gate.
        self.commandArgs = BashCommandArgs(command: command)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        // Strict wire carries only snake `request_network`; the provider rejects the camel spelling
        // via additionalProperties false while the decoder ignores unknown keys and defaults
        // fail-closed to `false`, so a camel `true` never enables network.
        let snakeNet = try container.decodeIfPresent(Bool.self, forKey: .requestNetworkSnake)
        self.requestNetwork = snakeNet ?? false
        // Strict wire carries only snake `network_hosts` for the same reason:
        // a camel spelling never declares destinations, so undeclared dials
        // still deny instead of slipping through on a misspelled key.
        self.networkHosts = try container.decodeIfPresent([String].self, forKey: .networkHostsSnake) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commandArgs.command, forKey: .command)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        if requestNetwork {
            try container.encode(requestNetwork, forKey: .requestNetworkSnake)
        }
        if !networkHosts.isEmpty {
            try container.encode(networkHosts, forKey: .networkHostsSnake)
        }
    }
}

/// How a shell run ended, distinguishing policy refusal from process fate.
public enum BashKillReason: String, Sendable, Codable, Equatable {
    /// The process exited on its own without a timeout or resource kill.
    case clean
    /// The wall-clock watchdog terminated the run.
    case wallTimeout = "wall_timeout"
    /// The CPU limit killed the run (CPU-only; memory kills stay `clean`).
    case resourceLimit = "resource_limit"
    /// Policy refused to spawn the command.
    case denied
}

/// JSON payload returned in `ToolOutput.content` for `bash.exec`.
public struct BashResultEnvelope: Codable, Sendable, Equatable {
    public let command: String
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let approvalRequired: Bool
    public let isChained: Bool
    public let denied: Bool
    public let error: String?
    public let reason: String?
    /// How the run ended; `denied` mirrors a refused spawn while the other
    /// cases distinguish wall-clock kills from CPU-only resource-limit kills
    /// (memory-limit deaths stay `clean`).
    public let killReason: BashKillReason

    private enum CodingKeys: String, CodingKey {
        case command
        case stdout
        case stderr
        case exitCode
        case approvalRequired
        case isChained
        case denied
        case error
        case reason
        case killReason = "kill_reason"
    }

    public init(
        command: String,
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        approvalRequired: Bool = false,
        isChained: Bool = false,
        denied: Bool = false,
        error: String? = nil,
        reason: String? = nil,
        killReason: BashKillReason? = nil
    ) {
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.approvalRequired = approvalRequired
        self.isChained = isChained
        self.denied = denied
        self.error = error
        self.reason = reason
        // An omitted reason stays honest: refused spawns read as denied,
        // everything else reads as a clean exit until the runner proves otherwise.
        if let killReason {
            self.killReason = killReason
        } else if denied {
            self.killReason = .denied
        } else {
            self.killReason = .clean
        }
    }

    /// Decodes an envelope, defaulting absent reasons for payloads written
    /// before the kill-reason contract so old success JSON still reads clean
    /// and old refusals still read denied.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        stdout = try container.decodeIfPresent(String.self, forKey: .stdout) ?? ""
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr) ?? ""
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode) ?? 0
        approvalRequired = try container.decodeIfPresent(Bool.self, forKey: .approvalRequired) ?? false
        isChained = try container.decodeIfPresent(Bool.self, forKey: .isChained) ?? false
        denied = try container.decodeIfPresent(Bool.self, forKey: .denied) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        if let decoded = try container.decodeIfPresent(BashKillReason.self, forKey: .killReason) {
            killReason = decoded
        } else if denied {
            killReason = .denied
        } else {
            killReason = .clean
        }
    }

    /// Encodes an envelope with the snake-case kill reason beside the
    /// existing camel-case keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(stderr, forKey: .stderr)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(approvalRequired, forKey: .approvalRequired)
        try container.encode(isChained, forKey: .isChained)
        try container.encode(denied, forKey: .denied)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(killReason, forKey: .killReason)
    }
}

/// Thread-safe capped output buffer for process stdout/stderr streams.
final class BashOutputBuffer: Sendable {
    private struct State: Sendable {
        var data = Data()
        let maxBytes: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    init(maxBytes: Int = 1024 * 1024) {
        self.state = OSAllocatedUnfairLock(initialState: State(data: Data(), maxBytes: maxBytes))
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        state.withLock { buffer in
            if buffer.data.count < buffer.maxBytes {
                buffer.data.append(chunk.prefix(buffer.maxBytes - buffer.data.count))
            }
        }
    }

    var stringValue: String {
        state.withLock { buffer in
            String(data: buffer.data, encoding: .utf8) ?? ""
        }
    }
}

// MARK: - BashTool Static Helpers

extension BashTool {
    /// Classifies how a run ended from its wait status. The timeout flag wins because a signal
    /// death landing near the deadline still reads as a wall kill only when the watchdog set the
    /// flag.
    public static func killReason(
        didTimeOut: Bool,
        terminationReason: Process.TerminationReason,
        terminationStatus: Int32,
        stderr: String = ""
    ) -> BashKillReason {
        if didTimeOut {
            return .wallTimeout
        }
        // Raw signal numbers avoid a Darwin/Glibc import split; 24 is SIGXCPU (CPU limit). The
        // signal death itself is the corroboration, so no diagnostic is required.
        if terminationReason == .uncaughtSignal,
           terminationStatus == 24
        {
            return .resourceLimit
        }
        // Wrappers report signals as 128 + signal instead of a signal death; only the SIGXCPU
        // spelling (152) counts, never the SIGKILL one (137), and only with the shell diagnostic so
        // a voluntary `exit 152` stays clean.
        if terminationReason == .exit,
           terminationStatus == 152,
           !stderr.isEmpty,
           stderr.localizedCaseInsensitiveContains("cpu time limit")
        {
            return .resourceLimit
        }
        return .clean
    }

    public static func encodeEnvelope(_ envelope: BashResultEnvelope) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(envelope), let str = String(data: data, encoding: .utf8) {
            return str
        }
        // Encoder failure stays escaped and fail-closed: never interpolate
        // raw command or output text into JSON. JSONSerialization escapes
        // quotes, backslashes, and control characters.
        var fallback: [String: Any] = [
            "command": envelope.command,
            "stdout": envelope.stdout,
            "stderr": envelope.stderr,
            "exitCode": Int(envelope.exitCode),
            "approvalRequired": envelope.approvalRequired,
            "isChained": envelope.isChained,
            "denied": envelope.denied,
            "kill_reason": envelope.killReason.rawValue
        ]
        if let error = envelope.error {
            fallback["error"] = error
        }
        if let reason = envelope.reason {
            fallback["reason"] = reason
        }
        if let data = try? JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8)
        {
            return str
        }
        // JSONSerialization cannot fail on string, number, and bool values,
        // but the static literal keeps the contract total without interpolation.
        return "{\"command\":\"\",\"denied\":true,\"kill_reason\":\"denied\"}"
    }
}
